// -----------------------------------------------------------------------------
// noise_src.sv  --  band-limited pseudo-random noise, LANES complex samples/clock
//
// Runs in the DAC fabric clock domain alongside chirp_core. It produces a single
// complex noise time series at fs_bb = LANES * f_clk (737.28 MSPS for the
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
// Randomness: eight independent 32-bit Galois LFSRs (CRC-32 primitive polynomial,
// maximal length 2^32-1). Each complex draw sums four 13-bit slices for I and
// four for Q, giving an approximately Gaussian amplitude (Bates distribution),
// zero mean, peak magnitude +/- 16384 (about -6 dBFS after full-scale AMP, so it
// never clips the 16-bit datapath). The state resets to fixed seeds, so a capture
// is reproducible run to run.
//
// Up to LANES fresh values may be needed in one clock (wide bands), so the LFSRs
// advance 0..LANES steps per clock. The datapath is written for LANES = 4 and all
// outputs are registered. Written with constant array indices only, so it also
// simulates correctly in Icarus Verilog.
// -----------------------------------------------------------------------------
module noise_src #(
    parameter int LANES = 4
) (
    input  logic                    clk,
    input  logic                    rst_n,
    input  logic [31:0]             ninc,       // Q0.32 new-draw fraction per sample
    output logic [LANES*16-1:0]     noise_i,    // signed 16-bit per lane, lane m = [16*m +: 16]
    output logic [LANES*16-1:0]     noise_q
);
    if (LANES != 4) begin : g_lanes_check
        $error("noise_src: the datapath is written for LANES = 4");
    end

    localparam logic [31:0] POLY = 32'hEDB8_8320;   // CRC-32 (reversed) primitive poly

    function automatic logic [31:0] nextL(input logic [31:0] s);
        return s[0] ? ((s >> 1) ^ POLY) : (s >> 1);
    endfunction

    function automatic logic [31:0] seed(input int g);
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

    // one complex slice: sum of four 13-bit signed LFSR slices (approx. Gaussian)
    function automatic logic signed [15:0] draw4(input logic [31:0] a, input logic [31:0] b,
                                                 input logic [31:0] c, input logic [31:0] d);
        return $signed(a[31:19]) + $signed(b[31:19]) + $signed(c[31:19]) + $signed(d[31:19]);
    endfunction

    // ------------------------------------------------------------ LFSR bank
    logic [31:0] lf [8];
    logic [31:0] st1 [8], st2 [8], st3 [8], nlf [8];
    genvar g;
    generate
        for (g = 0; g < 8; g++) begin : g_adv
            assign st1[g] = nextL(lf[g]);      // advance 1
            assign st2[g] = nextL(st1[g]);     // advance 2
            assign st3[g] = nextL(st2[g]);     // advance 3
        end
    endgenerate

    // ------------------------------------------------- accumulator / crossings
    // cum_m = nacc + (m+1)*ninc; a new value is drawn on lane m when the integer
    // (>> 32) part increments. ninc < 2^32 => at most one new draw per lane.
    logic [31:0] nacc;
    logic [34:0] c0, c1, c2, c3;
    assign c0 = {3'b0, nacc} + {3'b0, ninc};
    assign c1 = c0 + {3'b0, ninc};
    assign c2 = c1 + {3'b0, ninc};
    assign c3 = c2 + {3'b0, ninc};

    logic w0, w1, w2, w3;
    assign w0 = (c0[34:32] != 3'd0);
    assign w1 = (c1[34:32] != c0[34:32]);
    assign w2 = (c2[34:32] != c1[34:32]);
    assign w3 = (c3[34:32] != c2[34:32]);
    logic [2:0] ndraws;
    assign ndraws = c3[34:32];                  // 0..LANES

    // draw index used by each lane = number of wraps strictly before it
    logic [1:0] d1, d2, d3;
    assign d1 = w0;
    assign d2 = w0 + w1;
    assign d3 = w0 + w1 + w2;

    // candidate fresh draws (index 0..3) from the LFSR states advanced 0..3 times
    logic signed [15:0] fi0, fi1, fi2, fi3, fq0, fq1, fq2, fq3;
    assign fi0 = draw4(lf[0],  lf[1],  lf[2],  lf[3]);
    assign fi1 = draw4(st1[0], st1[1], st1[2], st1[3]);
    assign fi2 = draw4(st2[0], st2[1], st2[2], st2[3]);
    assign fi3 = draw4(st3[0], st3[1], st3[2], st3[3]);
    assign fq0 = draw4(lf[4],  lf[5],  lf[6],  lf[7]);
    assign fq1 = draw4(st1[4], st1[5], st1[6], st1[7]);
    assign fq2 = draw4(st2[4], st2[5], st2[6], st2[7]);
    assign fq3 = draw4(st3[4], st3[5], st3[6], st3[7]);

    function automatic logic signed [15:0] pick(input logic [1:0] idx,
                                                input logic signed [15:0] a,
                                                input logic signed [15:0] b,
                                                input logic signed [15:0] c,
                                                input logic signed [15:0] d);
        case (idx)
            2'd0:    return a;
            2'd1:    return b;
            2'd2:    return c;
            default: return d;
        endcase
    endfunction

    // ------------------------------------------------------ held sample selection
    logic signed [15:0] hold_i, hold_q;
    logic signed [15:0] vi0, vi1, vi2, vi3, vq0, vq1, vq2, vq3;
    assign vi0 = w0 ? fi0 : hold_i;                       // d0 = 0
    assign vi1 = w1 ? pick(d1, fi0, fi1, fi2, fi3) : vi0;
    assign vi2 = w2 ? pick(d2, fi0, fi1, fi2, fi3) : vi1;
    assign vi3 = w3 ? pick(d3, fi0, fi1, fi2, fi3) : vi2;
    assign vq0 = w0 ? fq0 : hold_q;
    assign vq1 = w1 ? pick(d1, fq0, fq1, fq2, fq3) : vq0;
    assign vq2 = w2 ? pick(d2, fq0, fq1, fq2, fq3) : vq1;
    assign vq3 = w3 ? pick(d3, fq0, fq1, fq2, fq3) : vq2;

    // next LFSR state = advance by the number of draws this clock
    generate
        for (g = 0; g < 8; g++) begin : g_next
            assign nlf[g] = (ndraws == 3'd0) ? lf[g]  :
                            (ndraws == 3'd1) ? st1[g] :
                            (ndraws == 3'd2) ? st2[g] :
                            (ndraws == 3'd3) ? st3[g] : nextL(st3[g]);
        end
    endgenerate

    generate
        for (g = 0; g < 8; g++) begin : g_lf
            always_ff @(posedge clk) begin
                if (!rst_n) lf[g] <= seed(g);
                else        lf[g] <= nlf[g];
            end
        end
    endgenerate

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            nacc    <= 32'hFFFF_FFFF;     // force a fresh draw on the first clock
            hold_i  <= 16'sd0;
            hold_q  <= 16'sd0;
            noise_i <= '0;
            noise_q <= '0;
        end else begin
            nacc   <= c3[31:0];
            hold_i <= vi3;
            hold_q <= vq3;
            noise_i[ 0 +: 16] <= vi0;
            noise_i[16 +: 16] <= vi1;
            noise_i[32 +: 16] <= vi2;
            noise_i[48 +: 16] <= vi3;
            noise_q[ 0 +: 16] <= vq0;
            noise_q[16 +: 16] <= vq1;
            noise_q[32 +: 16] <= vq2;
            noise_q[48 +: 16] <= vq3;
        end
    end
endmodule
