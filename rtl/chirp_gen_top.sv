// -----------------------------------------------------------------------------
// chirp_gen_top.sv  --  AXI-Lite registers + chirp core
// -----------------------------------------------------------------------------
module chirp_gen_top #(
    parameter int    LANES    = 4,
    parameter int    ADDR_W   = 16,
    parameter        MEM_FILE = "sincos_qw.mem"
) (
    input  logic                    s_axi_aclk,
    input  logic                    s_axi_aresetn,
    input  logic [ADDR_W-1:0]       s_axi_awaddr,
    input  logic                    s_axi_awvalid,
    output logic                    s_axi_awready,
    input  logic [31:0]             s_axi_wdata,
    input  logic [3:0]              s_axi_wstrb,
    input  logic                    s_axi_wvalid,
    output logic                    s_axi_wready,
    output logic [1:0]              s_axi_bresp,
    output logic                    s_axi_bvalid,
    input  logic                    s_axi_bready,
    input  logic [ADDR_W-1:0]       s_axi_araddr,
    input  logic                    s_axi_arvalid,
    output logic                    s_axi_arready,
    output logic [31:0]             s_axi_rdata,
    output logic [1:0]              s_axi_rresp,
    output logic                    s_axi_rvalid,
    input  logic                    s_axi_rready,
    input  logic                    dac_mmcm_locked,
    output logic                    dac_mmcm_reset,
    output logic                    dac_domain_reset,

    input  logic                    dac_clk,
    input  logic                    dac_rst_n,
    output logic [LANES*32-1:0]     m_axis_tdata,
    output logic                    m_axis_tvalid,
    input  logic                    m_axis_tready,
    output logic                    trig_out
);
    logic               enable, cw_mode, iq_swap, pack_ilv, params_load;
    logic signed [31:0] f_start, k_rate;
    logic        [31:0] pw, pri, phase0;
    logic        [15:0] amp;

    chirp_axil_regs #(.ADDR_W(ADDR_W)) u_regs (
        .s_axi_aclk, .s_axi_aresetn,
        .s_axi_awaddr, .s_axi_awvalid, .s_axi_awready,
        .s_axi_wdata, .s_axi_wstrb, .s_axi_wvalid, .s_axi_wready,
        .s_axi_bresp, .s_axi_bvalid, .s_axi_bready,
        .s_axi_araddr, .s_axi_arvalid, .s_axi_arready,
        .s_axi_rdata, .s_axi_rresp, .s_axi_rvalid, .s_axi_rready,
        .dac_mmcm_locked, .dac_mmcm_reset, .dac_domain_reset,
        .dac_clk, .dac_rst_n,
        .enable, .cw_mode, .iq_swap, .pack_ilv,
        .f_start, .k_rate, .pw, .pri, .amp, .phase0,
        .params_load
    );

    chirp_core #(.LANES(LANES), .MEM_FILE(MEM_FILE)) u_core (
        .clk   (dac_clk),
        .rst_n (dac_rst_n),
        .enable, .cw_mode, .iq_swap, .pack_ilv,
        .f_start, .k_rate, .phase0, .pw, .pri, .amp,
        .params_load,
        .m_axis_tdata, .m_axis_tvalid, .m_axis_tready,
        .trig_out
    );
endmodule
