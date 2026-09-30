// -----------------------------------------------------------------------------
// chirp_core.sv  --  pulsed LFM chirp / CW generator, LANES complex samples per clock
//
// Runs in the DAC fabric clock domain (184.32 MHz for the reference design).
// Sample rate seen by the math: fs_bb = LANES * f_clk = 737.28 MSPS complex.
//
// Discrete chirp (per sample n inside a pulse):
//     f[n]   = F0 + K*n                   (frequency word, turns/sample * 2^32)
//     phi[n] = P0 + F0*n + K*n*(n-1)/2    (phase word)
// For a block of LANES samples starting at sample N:
//     phi[N+m] = phi[N] + m*f[N] + K*m*(m-1)/2      m = 0..LANES-1
//     phi[N+L] = phi[N] + L*f[N] + K*L*(L-1)/2
//     f[N+L]   = f[N]   + L*K
// All accumulators are 48-bit Q32.16 (16 fractional bits) and wrap modulo 2^48.
//
// Timing structure (LANES = 4, 184.32 MHz): the multiples of f and K are kept
// in their own accumulators, so every recurrence is one 2-operand 48-bit add:
//     g = 4f + 6K   ->  phi' = phi + g,   g' = g + 16K
//     h = 3f + 3K   ->  lane 3 = phi + h, h' = h + 12K
//     f' = f + 4K;  lane 1 = phi + f;  lane 2 = phi + 2f + K
// Constants derived from the parameters are registered every clock. The first
// block after a parameter load is generated one clock after params_load, so the
// registered constants are always current when used.
//
// Register units (captured on params_load):
//   f_start : signed 32-bit, f_Hz  = f_start * fs_bb / 2^32
//   k_rate  : signed Q24.8,  slope = (k_rate/256) * fs_bb^2 / 2^32   [Hz/s]
//   phase0  : unsigned 32-bit, start phase = phase0 * 2*pi / 2^32
//   pw, pri : clocks (1 clock = LANES samples)
//   amp     : unsigned Q1.15, 0x7FFF = full scale (values above are clamped)
// -----------------------------------------------------------------------------
module chirp_core #(
    parameter int    LANES    = 4,
    parameter        MEM_FILE = "sincos_qw.mem"
) (
    input  logic                     clk,
    input  logic                     rst_n,
    // parameters (stable, updated together with a params_load pulse)
    input  logic                     enable,
    input  logic                     cw_mode,     // 1 = continuous tone at f_start, no pulsing
    input  logic                     iq_swap,     // 1 = swap I and Q (mirrors the spectrum)
    input  logic                     pack_ilv,    // 0 = {Q3..Q0,I3..I0}, 1 = {Q3,I3,..,Q0,I0}
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

    if (LANES != 4) begin : g_lanes_check
        $error("chirp_core: the phase datapath is written for LANES = 4");
    end

    // ------------------------------------------------------------------ params
    logic [W-1:0] F0, K, P0;
    assign F0 = {f_start, 16'd0};
    assign K  = cw_mode ? '0 : {{8{k_rate[31]}}, k_rate, 8'd0};
    assign P0 = {phase0, 16'd0};

    logic [15:0] amp_c;                    // clamp to <= 0x7FFF so the product never overflows
    assign amp_c = amp[15] ? 16'h7FFF : amp;

    // ------------------------------------------------------ derived constants
    // Registered every clock from quasi-static parameters (see header).
    logic [W-1:0] k4, k12, k16, g0, h0;
    logic [31:0]  pri_m1, pw_m1;
    logic         pw_nz;
    always_ff @(posedge clk) begin
        k4     <= K << 2;
        k12    <= (K << 3) + (K << 2);
        k16    <= K << 4;
        g0     <= ((F0 + K) << 2) + (K << 1);  // 4*F0 + 6*K
        h0     <= (F0 + K) + ((F0 + K) << 1);  // 3*F0 + 3*K
        pri_m1 <= pri - 32'd1;                 // pri >= 1 (register block clamps 0)
        pw_m1  <= pw - 32'd1;
        pw_nz  <= (pw != 0);
    end

    // ------------------------------------------------------------ pulse timer
    // cnt, start and gate all describe the block being generated this clock.
    // The wrap and pulse-width compares run in parallel on the current count:
    // cnt never exceeds pri-1 (it restarts on every load), so cnt+1 < pw is
    // cnt < pw-1 when pw > 0, and the next count is 0 exactly when it wraps.
    logic [31:0] cnt;
    logic        gate, wrap;
    (* max_fanout = 32 *) logic start;     // selects 4 x 48 accumulator bits

    assign wrap = (cnt >= pri_m1);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            cnt   <= '0;
            start <= 1'b1;
            gate  <= 1'b0;
        end else if (params_load || !enable) begin
            // restart the pulse train (and the chirp phase) on every parameter load
            cnt   <= '0;
            start <= 1'b1;
            gate  <= enable && (cw_mode || (pw != 0));
        end else begin
            cnt   <= wrap ? 32'd0 : cnt + 32'd1;
            start <= !cw_mode && wrap;                   // CW: phase runs freely
            gate  <= cw_mode || (wrap ? pw_nz : (pw_nz && (cnt < pw_m1)));
        end
    end

    // -------------------------------------------------- chirp accumulators
    logic [W-1:0] phi_r, f_r, g_r, h_r;    // state for the *next* block
    logic [W-1:0] blk_phi, blk_f, blk_g, blk_h;  // state for *this* block
    assign blk_phi = start ? P0 : phi_r;
    assign blk_f   = start ? F0 : f_r;
    assign blk_g   = start ? g0 : g_r;
    assign blk_h   = start ? h0 : h_r;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            phi_r <= '0;
            f_r   <= '0;
            g_r   <= '0;
            h_r   <= '0;
        end else begin
            phi_r <= blk_phi + blk_g;      // phi + 4f + 6K
            f_r   <= blk_f   + k4;         // f + 4K
            g_r   <= blk_g   + k16;        // 4(f + 4K) + 6K
            h_r   <= blk_h   + k12;        // 3(f + 4K) + 3K
        end
    end

    // lane phases: stage A registers the block terms, stage B adds them
    //   lane m = phi + m*f + K*m*(m-1)/2  ->  phi, phi + f, phi + 2f + K, phi + h
    logic [W-1:0] phi_a, t1_a, t2_a, t3_a;
    logic [W-1:0] lane_phi [LANES];
    always_ff @(posedge clk) begin
        phi_a       <= blk_phi;
        t1_a        <= blk_f;
        t2_a        <= (blk_f << 1) + K;
        t3_a        <= blk_h;
        lane_phi[0] <= phi_a;
        lane_phi[1] <= phi_a + t1_a;
        lane_phi[2] <= phi_a + t2_a;
        lane_phi[3] <= phi_a + t3_a;
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
    // Reuses the KRATE register (k_rate) as the noise bandwidth word (ninc).
    // noise_src free-runs; the mux below selects it in place of the sin/cos
    // lookup, so the amplitude, pulse gate, I/Q swap and packing stages are
    // shared with the chirp path unchanged.
    logic [LANES*16-1:0] noise_i, noise_q;
    noise_src #(.LANES(LANES)) u_noise (
        .clk     (clk),
        .rst_n   (rst_n),
        .ninc    (k_rate),
        .noise_i (noise_i),
        .noise_q (noise_q)
    );

    // --------------------------------------------- amplitude scaling (DSP)
    logic signed [15:0] i_s [LANES];
    logic signed [15:0] q_s [LANES];
    logic signed [16:0] amp_s;
    assign amp_s = $signed({1'b0, amp_c});

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
            src_i[m] = noise_mode ? $signed(noise_i[16*m +: 16]) : cos_l[m];
            src_q[m] = noise_mode ? $signed(noise_q[16*m +: 16]) : sin_l[m];
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
                iv = gate_al ? (iq_swap ? q_s[m] : i_s[m]) : 16'sd0;
                qv = gate_al ? (iq_swap ? i_s[m] : q_s[m]) : 16'sd0;
                if (pack_ilv) begin
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
