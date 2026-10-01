// -----------------------------------------------------------------------------
// chirp_core.sv  --  pulsed LFM chirp / CW generator, LANES complex samples per clock
//
// Runs in the DAC fabric clock domain (184.32 MHz for the reference design).
// Sample rate seen by the math: fs_bb = LANES * f_clk = 1474.56 MSPS complex
// (LANES = 8, RF-DAC 4x interpolation at 5.89824 GSPS).
//
// Discrete chirp (per sample n inside a pulse):
//     f[n]   = F0 + K*n                   (frequency word, turns/sample * 2^32)
//     phi[n] = P0 + F0*n + K*n*(n-1)/2    (phase word)
// For a block of L = LANES samples starting at sample N, lane m has
//     phi[N+m] = phi[N] + T_m[N],   T_m[N] = m*f[N] + K*m*(m-1)/2
//     T_m[N+L] = T_m[N] + m*L*K                       m = 1..L
//     phi[N+L] = phi[N] + T_L[N]
// All accumulators are 48-bit Q32.16 (16 fractional bits) and wrap modulo 2^48.
//
// Timing structure: every T_m is its own accumulator, so each recurrence is a
// single 2-operand 48-bit add behind the start mux, whatever LANES is. The lane
// phases are one more 2-operand add (phi + T_m) in a separate stage.
// The start values T_m[0] = m*F0 + K*m*(m-1)/2 and the increments m*L*K are
// shift-add products of the quasi-static parameters, registered every clock in
// two stages (the start phase P0 is delayed to match). A parameter load holds
// the pulse timer in restart for one extra clock: the first block after
// params_load is generated two clocks later, when the registered constants are
// current, and is the first one gated.
//
// Reload while running: the blocks already in flight finish with the old
// parameters, because amplitude, noise select, I/Q swap and packing travel down
// the pipeline with the gate. Exactly one block of zeros separates the old and
// the new waveform, so a pulse start is always a rising edge of trig_out.
//
// Register units (captured on params_load):
//   f_start : signed 32-bit, f_Hz  = f_start * fs_bb / 2^32
//   k_rate  : signed Q24.8,  slope = (k_rate/256) * fs_bb^2 / 2^32   [Hz/s]
//   phase0  : unsigned 32-bit, start phase = phase0 * 2*pi / 2^32
//   pw, pri : clocks (1 clock = LANES samples)
//   amp     : unsigned Q1.15, 0x7FFF = full scale (values above are clamped)
// -----------------------------------------------------------------------------
module chirp_core #(
    parameter int    LANES    = 8,
    parameter        MEM_FILE = "sincos_qw.mem"
) (
    input  logic                     clk,
    input  logic                     rst_n,
    // parameters (stable, updated together with a params_load pulse)
    input  logic                     enable,
    input  logic                     cw_mode,     // 1 = continuous output at f_start, no pulsing
    input  logic                     iq_swap,     // 1 = swap I and Q (mirrors the spectrum)
    input  logic                     pack_ilv,    // 0 = {Q[L-1]..Q0,I[L-1]..I0}, 1 = {Q[L-1],I[L-1],..,Q0,I0}
    input  logic                     noise_mode,  // 1 = band-limited noise instead of chirp/CW
    input  logic signed [31:0]       f_start,
    input  logic signed [31:0]       k_rate,
    input  logic        [31:0]       phase0,
    input  logic        [31:0]       pw,
    input  logic        [31:0]       pri,
    input  logic        [15:0]       amp,
    input  logic                     params_load, // 1-clock pulse: new parameters valid
    // AXI4-Stream to RF-DAC
    output logic [LANES*32-1:0]      m_axis_tdata,
    output logic                     m_axis_tvalid,
    input  logic                     m_axis_tready, // RFDC startup indicator; see PG269 (TVALID does not gate DAC data)
    // pulse gate aligned with the samples at m_axis_tdata
    output logic                     trig_out
);
    localparam int W        = 48;          // accumulator width, Q32.16
    localparam int ROM_LAT  = 3;           // sincos_qw_rom latency
    localparam int PIPE     = 2 + ROM_LAT + 1; // lane stages A/B + ROM + amplitude stage

    if (LANES < 2 || LANES > 16) begin : g_lanes_check
        $error("chirp_core: LANES must be 2..16");
    end

    // x * c for an elaboration-time constant c, as signed-digit shift-adds:
    // at most three terms for every product used here, and no DSP inference.
    function automatic logic [W-1:0] mulc(input logic [W-1:0] x, input int c);
        logic [W-1:0] r;
        int n;
        r = '0;
        n = c;
        for (int b = 0; b < 16; b++) begin
            if (n % 2 != 0) begin
                if (n % 4 == 1) begin r = r + (x << b); n = n - 1; end
                else            begin r = r - (x << b); n = n + 1; end
            end
            n = n / 2;
        end
        return r;
    endfunction

    // ------------------------------------------------------------------ params
    logic [W-1:0] F0, K;
    assign F0 = {f_start, 16'd0};
    assign K  = cw_mode ? '0 : {{8{k_rate[31]}}, k_rate, 8'd0};

    logic [15:0] amp_c;                    // clamp to <= 0x7FFF so the product never overflows
    assign amp_c = amp[15] ? 16'h7FFF : amp;

    // ------------------------------------------------------ derived constants
    // Registered every clock from quasi-static parameters (see header).
    //   stage 1: m*F0, K*m*(m-1)/2, increments m*L*K, timer limits
    //   stage 2: start values T_m[0] = m*F0 + K*m*(m-1)/2
    logic [W-1:0] fm   [1:LANES];
    logic [W-1:0] ktri [1:LANES];
    logic [W-1:0] kinc [1:LANES];
    logic [W-1:0] t0   [1:LANES];
    for (genvar m = 1; m <= LANES; m++) begin : g_const
        always_ff @(posedge clk) begin
            fm[m]   <= mulc(F0, m);
            ktri[m] <= mulc(K, m * (m - 1) / 2);
            kinc[m] <= mulc(K, m * LANES);
            t0[m]   <= fm[m] + ktri[m];
        end
    end

    logic [W-1:0] p0_1, P0;                // start phase, delayed like t0
    logic [31:0]  pri_m1, pw_m1;
    logic         pw_nz;
    always_ff @(posedge clk) begin
        p0_1   <= {phase0, 16'd0};
        P0     <= p0_1;
        pri_m1 <= pri - 32'd1;             // pri >= 1 (register block clamps 0)
        pw_m1  <= pw - 32'd1;
        pw_nz  <= (pw != 0);
    end

    // ------------------------------------------------------------ pulse timer
    // cnt, start and gate all describe the block being generated this clock.
    // The wrap and pulse-width compares run in parallel on the current count:
    // cnt never exceeds pri-1 (it restarts on every load), so cnt+1 < pw is
    // cnt < pw-1 when pw > 0, and the next count is 0 exactly when it wraps.
    // A load restarts the timer for two clocks (params_load, ld_d) and gates
    // only the second restart, so the first gated block uses settled constants.
    logic [31:0] cnt;
    logic        gate, wrap, ld_d;
    (* max_fanout = 32 *) logic start;     // selects (LANES+1) x 48 accumulator bits

    assign wrap = (cnt >= pri_m1);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            cnt   <= '0;
            start <= 1'b1;
            gate  <= 1'b0;
            ld_d  <= 1'b0;
        end else begin
            ld_d <= params_load;
            if (params_load || ld_d || !enable) begin
                // restart the pulse train (and the chirp phase) on every parameter load
                cnt   <= '0;
                start <= 1'b1;
                gate  <= !params_load && enable && (cw_mode || (pw != 0));
            end else begin
                cnt   <= wrap ? 32'd0 : cnt + 32'd1;
                start <= !cw_mode && wrap;                   // CW: phase runs freely
                gate  <= cw_mode || (wrap ? pw_nz : (pw_nz && (cnt < pw_m1)));
            end
        end
    end

    // -------------------------------------------------- chirp accumulators
    // phi_r / t_r hold the state for the *next* block, blk_* for *this* block.
    logic [W-1:0] phi_r, blk_phi;
    logic [W-1:0] t_r   [1:LANES];
    logic [W-1:0] blk_t [1:LANES];
    assign blk_phi = start ? P0 : phi_r;

    always_ff @(posedge clk) begin
        if (!rst_n) phi_r <= '0;
        else        phi_r <= blk_phi + blk_t[LANES];
    end

    for (genvar m = 1; m <= LANES; m++) begin : g_acc
        assign blk_t[m] = start ? t0[m] : t_r[m];
        always_ff @(posedge clk) begin
            if (!rst_n) t_r[m] <= '0;
            else        t_r[m] <= blk_t[m] + kinc[m];
        end
    end

    // lane phases: stage A registers the block terms, stage B adds them
    //   lane 0 = phi,  lane m = phi + T_m
    logic [W-1:0] phi_a;
    logic [W-1:0] ta       [1:LANES-1];
    logic [W-1:0] lane_phi [LANES];
    always_ff @(posedge clk) begin
        phi_a       <= blk_phi;
        lane_phi[0] <= phi_a;
    end
    for (genvar m = 1; m < LANES; m++) begin : g_lane_phase
        always_ff @(posedge clk) begin
            ta[m]       <= blk_t[m];
            lane_phi[m] <= phi_a + ta[m];
        end
    end

    // -------------------------------------------- sin/cos lookup per lane
    logic signed [15:0] cos_l [LANES];
    logic signed [15:0] sin_l [LANES];

    for (genvar g = 0; g < LANES; g++) begin : g_lane
        sincos_qw_rom #(.MEM_FILE(MEM_FILE)) u_rom (
            .clk   (clk),
            .phase (lane_phi[g][W-1 -: 14]),
            .cos_o (cos_l[g]),
            .sin_o (sin_l[g])
        );
    end

    // ------------------------------------------- band-limited noise source
    // Reuses KRATE (k_rate) as the noise bandwidth word (ninc) and PHASE0 as the
    // seed selector. noise_src free-runs and restarts from its seed on every
    // load; the mux below selects it in place of the sin/cos lookup, so the
    // amplitude, pulse gate, I/Q swap and packing stages are shared with the
    // chirp path unchanged.
    logic [LANES*16-1:0] noise_i, noise_q;
    noise_src #(.LANES(LANES)) u_noise (
        .clk      (clk),
        .rst_n    (rst_n),
        .reseed   (params_load),
        .seed_sel (phase0),
        .ninc     (k_rate),
        .noise_i  (noise_i),
        .noise_q  (noise_q)
    );

    // ------------------------------------------- per-block output controls
    // Captured on the same edges as gate, so ctl_d[i] describes the same block
    // as gate_d[i]: the amplitude stage uses ctl_d[PIPE-2], packing ctl_d[PIPE-1].
    localparam int CTL_W = 19;             // {pack_ilv, iq_swap, noise_mode, amp}
    logic [CTL_W-1:0] ctl_g;
    logic [CTL_W-1:0] ctl_d [PIPE];
    always_ff @(posedge clk) begin
        ctl_g    <= {pack_ilv, iq_swap, noise_mode, amp_c};
        ctl_d[0] <= ctl_g;
        for (int i = 1; i < PIPE; i++) ctl_d[i] <= ctl_d[i-1];
    end
    logic        noise_sel, swap_o, ilv_o;
    logic [15:0] amp_sel;
    assign {noise_sel, amp_sel} = ctl_d[PIPE-2][16:0];
    assign {ilv_o, swap_o}      = ctl_d[PIPE-1][18:17];

    // --------------------------------------------- amplitude scaling (DSP)
    logic signed [15:0] i_s [LANES];
    logic signed [15:0] q_s [LANES];
    logic signed [16:0] amp_s;
    assign amp_s = $signed({1'b0, amp_sel});

    function automatic logic signed [15:0] scale(input logic signed [15:0] x,
                                                  input logic signed [16:0] a);
        logic signed [32:0] p;
        p = x * a + 33'sd16384;            // round to nearest
        return p[30:15];
    endfunction

    logic signed [15:0] src_i [LANES];
    logic signed [15:0] src_q [LANES];
    always_comb begin
        for (int m = 0; m < LANES; m++) begin
            src_i[m] = noise_sel ? $signed(noise_i[16*m +: 16]) : cos_l[m];
            src_q[m] = noise_sel ? $signed(noise_q[16*m +: 16]) : sin_l[m];
        end
    end

    always_ff @(posedge clk) begin
        for (int m = 0; m < LANES; m++) begin
            i_s[m] <= scale(src_i[m], amp_s);
            q_s[m] <= scale(src_q[m], amp_s);
        end
    end

    // ------------------------------------------------ gate delay matching
    logic [PIPE-1:0] gate_d;
    always_ff @(posedge clk) begin
        if (!rst_n) gate_d <= '0;
        else        gate_d <= {gate_d[PIPE-2:0], gate};
    end
    wire gate_al = gate_d[PIPE-1];         // aligned with i_s / q_s

    // ------------------------------------------------------ output packing
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            m_axis_tdata  <= '0;
            m_axis_tvalid <= 1'b0;
            trig_out      <= 1'b0;
        end else begin
            m_axis_tvalid <= 1'b1;
            trig_out      <= gate_al;
            for (int m = 0; m < LANES; m++) begin
                logic signed [15:0] iv, qv;
                iv = gate_al ? (swap_o ? q_s[m] : i_s[m]) : 16'sd0;
                qv = gate_al ? (swap_o ? i_s[m] : q_s[m]) : 16'sd0;
                if (ilv_o) begin
                    m_axis_tdata[32*m      +: 16] <= iv;
                    m_axis_tdata[32*m + 16 +: 16] <= qv;
                end else begin
                    m_axis_tdata[16*m            +: 16] <= iv;
                    m_axis_tdata[16*(m + LANES)  +: 16] <= qv;
                end
            end
        end
    end
endmodule
