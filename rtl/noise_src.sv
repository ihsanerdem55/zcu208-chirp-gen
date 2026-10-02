// -----------------------------------------------------------------------------
// noise_src.sv  --  band-limited pseudo-random noise, LANES complex samples/clock
//
// Runs in the DAC fabric clock domain alongside chirp_core. It produces a single
// complex noise time series at fs_bb = LANES * f_clk (1474.56 MSPS for the
// reference design), delivered LANES samples at a time.
//
// Bandwidth control (zero-order hold / sample-and-hold resampling):
//   A fresh random complex value is drawn every D samples and held in between.
//   D is set as a Q0.32 "new-draw fraction per sample":
//       ninc = round(2^32 * bw / fs_bb)   ->   D = fs_bb / bw = 2^32 / ninc
//   The held sequence is white up to ~bw/2 either side of 0 Hz with a sinc^2
//   envelope whose first nulls sit at +/- bw = fs_bb / D. The RF-DAC's own
//   interpolation filter passes roughly +/- 0.4*fs_bb, and the RFDC fine mixer
//   (NCO) shifts the whole band to the wanted RF centre. ninc = 0 freezes the
//   output (no new draws); the software keeps ninc >= 1.
//
// Draw schedule: with nacc the fractional accumulator at the start of a clock,
//   c_m = nacc + (m+1)*ninc,   n_m = floor(c_m / 2^32)   (m = 0..LANES-1)
// n_m is the number of draws up to and including lane m, so lane m shows the
// value held from the previous clock if n_m = 0, otherwise this clock's draw
// number n_m - 1. All c_m are independent 2-operand adds of registered
// constants (m+1)*ninc, so the depth does not grow with LANES.
//
// Randomness: eight independent 32-bit Galois LFSRs (CRC-32 primitive polynomial,
// maximal length 2^32-1) advance a fixed LANES steps every clock; candidate draw
// k (k = 0..LANES-1) comes from the states advanced k steps. Draws a clock does
// not need are discarded, so the LFSR update needs no variable-length advance.
// Each complex draw sums four 13-bit slices for I and four for Q, giving an
// approximately Gaussian amplitude (Bates distribution), zero mean, peak
// magnitude +/- 16384 (about -6 dBFS after full-scale AMP, so it never clips
// the 16-bit datapath).
//
// Reproducibility: reset and every reseed pulse (each APPLY) restart the
// generator from its seeds (one clock later, from a replicated register), so
// the same command always produces the same sequence whatever ran before.
// seed_sel (0 = default) XORs a rotated copy into each LFSR seed to select a
// different, equally valid noise realisation.
//
// Pipeline: stage 1 registers the draw counts and candidate draws, stage 2
// selects (a flat one-hot AND-OR mux) and registers the outputs (2 clocks
// latency, irrelevant for noise).
// Written with generate loops and constant array indices so that it also
// simulates in Icarus Verilog.
// -----------------------------------------------------------------------------
module noise_src #(
    parameter int LANES = 8
) (
    input  logic                    clk,
    input  logic                    rst_n,
    input  logic                    reseed,     // 1-clock pulse: restart from the seeds
    input  logic [31:0]             seed_sel,   // noise realisation, sampled on reseed
    input  logic [31:0]             ninc,       // Q0.32 new-draw fraction per sample
    output logic [LANES*16-1:0]     noise_i,    // signed 16-bit per lane, lane m = [16*m +: 16]
    output logic [LANES*16-1:0]     noise_q
);
    localparam int NB = $clog2(LANES + 1);           // bits of a per-clock draw count
    localparam int CW = 32 + NB;                     // accumulator sum width
    localparam logic [31:0] POLY = 32'hEDB8_8320;    // CRC-32 (reversed) primitive poly

    if (LANES < 1 || LANES > 16) begin : g_lanes_check
        $error("noise_src: LANES must be 1..16");
    end

    function automatic logic [31:0] adv(input logic [31:0] s, input int steps);
        logic [31:0] r;
        r = s;
        for (int i = 0; i < steps; i++) r = r[0] ? ((r >> 1) ^ POLY) : (r >> 1);
        return r;
    endfunction

    function automatic logic [31:0] base_seed(input int g);
        case (g)
            0:       return 32'h1234_5678;
            1:       return 32'h9E37_79B9;
            2:       return 32'hDEAD_BEEF;
            3:       return 32'h0BAD_F00D;
            4:       return 32'hCAFE_BABE;
            5:       return 32'h5A5A_A5A5;
            6:       return 32'hF00D_1234;
            default: return 32'h1357_9BDF;
        endcase
    endfunction

    // LFSR g start state for realisation sel; never the all-zero lock-up state
    function automatic logic [31:0] seed(input int g, input logic [31:0] sel);
        logic [31:0] r;
        r = base_seed(g) ^ ((sel << (4*g)) | (sel >> ((32 - 4*g) % 32)));
        return (r == 32'd0) ? base_seed(g) : r;
    endfunction

    // registered restart: drives the synchronous reset of ~350 flops, so the
    // tools may replicate it next to its loads
    (* max_fanout = 64 *) logic restart;
    always_ff @(posedge clk) restart <= !rst_n || reseed;

    // one real value: sum of four 13-bit signed LFSR slices (approx. Gaussian)
    function automatic logic signed [15:0] draw4(input logic [31:0] a, input logic [31:0] b,
                                                 input logic [31:0] c, input logic [31:0] d);
        return $signed({{3{a[31]}}, a[31:19]}) + $signed({{3{b[31]}}, b[31:19]}) +
               $signed({{3{c[31]}}, c[31:19]}) + $signed({{3{d[31]}}, d[31:19]});
    endfunction

    // x * c for a small elaboration-time constant c (adders only)
    function automatic logic [CW-1:0] mulc(input logic [31:0] x, input int c);
        logic [CW-1:0] r;
        r = '0;
        for (int b = 0; b < NB; b++)
            if (((c >> b) & 1) != 0) r = r + ({{NB{1'b0}}, x} << b);
        return r;
    endfunction

    // ------------------------------------------------------------ LFSR bank
    logic [31:0] lf [8];
    for (genvar g = 0; g < 8; g++) begin : g_lf
        always_ff @(posedge clk) begin
            if (restart) lf[g] <= seed(g, seed_sel);
            else         lf[g] <= adv(lf[g], LANES);
        end
    end

    // ----------------------------------------- draw counts (stage 1, registered)
    logic [CW-1:0] kn [LANES];                 // (m+1)*ninc, quasi-static
    logic [31:0]   nacc;
    logic [NB-1:0] n_q [LANES];                // draws up to and including lane m
    for (genvar m = 0; m < LANES; m++) begin : g_cnt
        logic [CW-1:0] c;
        assign c = {{NB{1'b0}}, nacc} + kn[m];
        always_ff @(posedge clk) begin
            kn[m] <= mulc(ninc, m + 1);
            if (restart) n_q[m] <= '0;
            else         n_q[m] <= c[CW-1:32];
        end
        if (m == LANES - 1) begin : g_last
            always_ff @(posedge clk) begin
                if (restart) nacc <= 32'hFFFF_FFFF;   // force a fresh draw on the first clock
                else         nacc <= c[31:0];
            end
        end
    end

    // ------------------------------------ candidate draws (stage 1, registered)
    logic [LANES*16-1:0] fi_q, fq_q;           // candidate k at [16*k +: 16]
    for (genvar k = 0; k < LANES; k++) begin : g_draw
        always_ff @(posedge clk) begin
            fi_q[16*k +: 16] <= draw4(adv(lf[0], k), adv(lf[1], k), adv(lf[2], k), adv(lf[3], k));
            fq_q[16*k +: 16] <= draw4(adv(lf[4], k), adv(lf[5], k), adv(lf[6], k), adv(lf[7], k));
        end
    end

    // ------------------------------------------ held value selection (stage 2)
    // lane m: the held value if n_q = 0, else candidate n_q - 1 (one-hot AND-OR)
    logic signed [15:0] hold_i, hold_q;
    logic [LANES*16-1:0] vi, vq;
    for (genvar m = 0; m < LANES; m++) begin : g_sel
        always_comb begin
            logic [15:0] si, sq;
            si = (n_q[m] == 0) ? hold_i : 16'd0;
            sq = (n_q[m] == 0) ? hold_q : 16'd0;
            for (int k = 0; k < LANES; k++) begin
                if ({{(32-NB){1'b0}}, n_q[m]} == k + 1) begin
                    si = si | fi_q[16*k +: 16];
                    sq = sq | fq_q[16*k +: 16];
                end
            end
            vi[16*m +: 16] = si;
            vq[16*m +: 16] = sq;
        end
    end

    always_ff @(posedge clk) begin
        if (restart) begin
            hold_i <= 16'sd0;
            hold_q <= 16'sd0;
        end else begin
            hold_i <= vi[16*(LANES-1) +: 16];
            hold_q <= vq[16*(LANES-1) +: 16];
        end
        noise_i <= vi;                    // follows hold/n_q, which reset
        noise_q <= vq;
    end
endmodule
