// -----------------------------------------------------------------------------
// chirp_gen_wrapper.v  --  plain-Verilog top for "Add Module" in the block design.
// Vivado block designs cannot reference a SystemVerilog file as the top of a
// module reference, so this wrapper only renames/attributes ports.
// The X_INTERFACE attributes make Vivado infer s_axi / m_axis bus interfaces.
// -----------------------------------------------------------------------------
module chirp_gen_wrapper #(
    parameter LANES  = 8,
    parameter ADDR_W = 16
) (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 s_axi_aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi, ASSOCIATED_RESET s_axi_aresetn:dac_mmcm_reset:dac_domain_reset, FREQ_HZ 100000000" *)
    input  wire                  s_axi_aclk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 s_axi_aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire                  s_axi_aresetn,
    input  wire [ADDR_W-1:0]     s_axi_awaddr,
    input  wire                  s_axi_awvalid,
    output wire                  s_axi_awready,
    input  wire [31:0]           s_axi_wdata,
    input  wire [3:0]            s_axi_wstrb,
    input  wire                  s_axi_wvalid,
    output wire                  s_axi_wready,
    output wire [1:0]            s_axi_bresp,
    output wire                  s_axi_bvalid,
    input  wire                  s_axi_bready,
    input  wire [ADDR_W-1:0]     s_axi_araddr,
    input  wire                  s_axi_arvalid,
    output wire                  s_axi_arready,
    output wire [31:0]           s_axi_rdata,
    output wire [1:0]            s_axi_rresp,
    output wire                  s_axi_rvalid,
    input  wire                  s_axi_rready,

    // DAC fabric-clock MMCM supervision (clk_wiz_dac locked/reset, DAC reset controller)
    input  wire                  dac_mmcm_locked,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 dac_mmcm_reset RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_HIGH" *)
    output wire                  dac_mmcm_reset,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 dac_domain_reset RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_HIGH" *)
    output wire                  dac_domain_reset,

    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 dac_clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF m_axis, ASSOCIATED_RESET dac_rst_n, FREQ_HZ 184320000" *)
    input  wire                  dac_clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 dac_rst_n RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire                  dac_rst_n,
    // m_axis is declared explicitly so that it carries TDATA_NUM_BYTES itself;
    // otherwise validation copies it from the RF-DAC and reports [BD 41-926].
    // 32 bytes = LANES (8) x 4; keep it equal to LANES*4 if LANES changes.
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TDATA" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME m_axis, TDATA_NUM_BYTES 32" *)
    output wire [LANES*32-1:0]   m_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TVALID" *)
    output wire                  m_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TREADY" *)
    input  wire                  m_axis_tready,
    output wire                  trig_out,

    // ILA monitor copies of the stream and pulse gate, one DAC clock later.
    // In a block design, wiring a net to a pin of the connected m_axis
    // interface removes that pin from the interface, so the ILA taps these
    // plain ports. The extra register lets the RFDC-facing output flops sit
    // next to the RFDC while the ILA's copies sit next to the ILA.
    (* X_INTERFACE_IGNORE = "true" *)
    output reg  [LANES*32-1:0]   mon_data,
    (* X_INTERFACE_IGNORE = "true" *)
    output reg                   mon_valid,
    (* X_INTERFACE_IGNORE = "true" *)
    output reg                   mon_ready,
    (* X_INTERFACE_IGNORE = "true" *)
    output reg                   mon_gate
);
    always @(posedge dac_clk) begin
        mon_data  <= m_axis_tdata;
        mon_valid <= m_axis_tvalid;
        mon_ready <= m_axis_tready;
        mon_gate  <= trig_out;
    end

    chirp_gen_top #(
        .LANES    (LANES),
        .ADDR_W   (ADDR_W),
        .MEM_FILE ("sincos_qw.mem")
    ) u_top (
        .s_axi_aclk    (s_axi_aclk),
        .s_axi_aresetn (s_axi_aresetn),
        .s_axi_awaddr  (s_axi_awaddr),
        .s_axi_awvalid (s_axi_awvalid),
        .s_axi_awready (s_axi_awready),
        .s_axi_wdata   (s_axi_wdata),
        .s_axi_wstrb   (s_axi_wstrb),
        .s_axi_wvalid  (s_axi_wvalid),
        .s_axi_wready  (s_axi_wready),
        .s_axi_bresp   (s_axi_bresp),
        .s_axi_bvalid  (s_axi_bvalid),
        .s_axi_bready  (s_axi_bready),
        .s_axi_araddr  (s_axi_araddr),
        .s_axi_arvalid (s_axi_arvalid),
        .s_axi_arready (s_axi_arready),
        .s_axi_rdata   (s_axi_rdata),
        .s_axi_rresp   (s_axi_rresp),
        .s_axi_rvalid  (s_axi_rvalid),
        .s_axi_rready  (s_axi_rready),
        .dac_mmcm_locked  (dac_mmcm_locked),
        .dac_mmcm_reset   (dac_mmcm_reset),
        .dac_domain_reset (dac_domain_reset),
        .dac_clk       (dac_clk),
        .dac_rst_n     (dac_rst_n),
        .m_axis_tdata  (m_axis_tdata),
        .m_axis_tvalid (m_axis_tvalid),
        .m_axis_tready (m_axis_tready),
        .trig_out      (trig_out)
    );
endmodule
