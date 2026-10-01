// -----------------------------------------------------------------------------
// sincos_qw_rom.sv
// Phase (14-bit, full cycle = 16384) -> cos and sin, 16-bit signed.
// One dual-port quarter-wave block ROM (4096 x 16) serves both outputs:
//   port A looks up sin(p), port B looks up cos(p) = sin(p + quarter cycle).
// Latency: 4 clocks (address/quadrant register, BRAM read, BRAM output
// register, sign stage). The second BRAM stage has no logic in front of it, so
// it maps onto the block RAM's own output register (DOA_REG/DOB_REG) and the
// sign stage starts from a register instead of the slower BRAM read latch.
// Table contents: rtl/sincos_qw.mem  (made by scripts/gen_sincos_mem.py)
// -----------------------------------------------------------------------------
module sincos_qw_rom #(
    parameter        MEM_FILE = "sincos_qw.mem"
) (
    input  logic               clk,
    input  logic [13:0]        phase,     // top 14 bits of the phase accumulator
    output logic signed [15:0] cos_o,
    output logic signed [15:0] sin_o
);
    localparam int QW = 12;               // quarter-wave address bits

    (* rom_style = "block" *) logic [15:0] rom [0:(1<<QW)-1];
    initial $readmemh(MEM_FILE, rom);

    // ---- stage 1: fold phase into quarter-wave address + remember sign ----
    logic [1:0]    q_sin, q_cos;
    logic [QW-1:0] i;
    logic [QW-1:0] a_sin, a_cos;
    logic          neg_sin_1, neg_cos_1;

    assign q_sin = phase[13:12];
    assign q_cos = phase[13:12] + 2'd1;   // cos(p) = sin(p + 90 deg)
    assign i     = phase[QW-1:0];

    always_ff @(posedge clk) begin
        a_sin     <= q_sin[0] ? ~i : i;   // ~i == 4095 - i  (mirror in quadrants 1 and 3)
        a_cos     <= q_cos[0] ? ~i : i;
        neg_sin_1 <= q_sin[1];            // quadrants 2 and 3 are negative
        neg_cos_1 <= q_cos[1];
    end

    // ---- stages 2 and 3: BRAM read, BRAM output register ----
    logic [15:0] d_sin, d_cos, d_sin_q, d_cos_q;
    logic        neg_sin_2, neg_cos_2, neg_sin_3, neg_cos_3;
    always_ff @(posedge clk) begin
        d_sin     <= rom[a_sin];
        d_cos     <= rom[a_cos];
        d_sin_q   <= d_sin;
        d_cos_q   <= d_cos;
        neg_sin_2 <= neg_sin_1;
        neg_cos_2 <= neg_cos_1;
        neg_sin_3 <= neg_sin_2;
        neg_cos_3 <= neg_cos_2;
    end

    // ---- stage 4: apply sign (table is 0..32767, so negation never overflows) ----
    always_ff @(posedge clk) begin
        sin_o <= neg_sin_3 ? -$signed(d_sin_q) : $signed(d_sin_q);
        cos_o <= neg_cos_3 ? -$signed(d_cos_q) : $signed(d_cos_q);
    end
endmodule
