// -----------------------------------------------------------------------------
// chirp_axil_regs.sv  --  AXI4-Lite register file + clock-domain crossing
//
// Register map (byte offsets from the slave base address):
//   0x00 ID      RO  0x43485250 ("CHRP")
//   0x04 CTRL    RW  [0] enable  [1] cw_mode  [2] iq_swap  [3] pack_ilv
//   0x08 FSTART  RW  signed start frequency word  (f = FSTART * fs_bb / 2^32)
//   0x0C KRATE   RW  signed chirp rate, Q24.8      (slope = KRATE/256 * fs_bb^2 / 2^32)
//   0x10 PW      RW  pulse width, fabric clocks
//   0x14 PRI     RW  pulse repetition interval, fabric clocks (>= 1)
//   0x18 AMP     RW  [15:0] amplitude, Q1.15 (0x7FFF = full scale)
//   0x1C PHASE0  RW  start phase (2*pi = 2^32)
//   0x20 APPLY   WO  write any value: copy all RW registers into the DAC clock domain
//   0x24 STATUS  RO  [0] DAC-domain reset released  [1] apply pending  [2] DAC-clock heartbeat
//
// Nothing written to 0x04..0x1C reaches the generator until APPLY is written.
// CDC: toggle handshake. Software must wait for STATUS[1] = 0 before changing
// registers again (the Tcl helpers do this).
// -----------------------------------------------------------------------------
module chirp_axil_regs #(
    parameter int ADDR_W = 16
) (
    // AXI4-Lite slave, s_axi_aclk domain
    input  logic               s_axi_aclk,
    input  logic               s_axi_aresetn,
    input  logic [ADDR_W-1:0]  s_axi_awaddr,
    input  logic               s_axi_awvalid,
    output logic               s_axi_awready,
    input  logic [31:0]        s_axi_wdata,
    input  logic [3:0]         s_axi_wstrb,
    input  logic               s_axi_wvalid,
    output logic               s_axi_wready,
    output logic [1:0]         s_axi_bresp,
    output logic               s_axi_bvalid,
    input  logic               s_axi_bready,
    input  logic [ADDR_W-1:0]  s_axi_araddr,
    input  logic               s_axi_arvalid,
    output logic               s_axi_arready,
    output logic [31:0]        s_axi_rdata,
    output logic [1:0]         s_axi_rresp,
    output logic               s_axi_rvalid,
    input  logic               s_axi_rready,
    // parameter outputs, dac_clk domain
    input  logic               dac_clk,
    input  logic               dac_rst_n,
    output logic               enable,
    output logic               cw_mode,
    output logic               iq_swap,
    output logic               pack_ilv,
    output logic signed [31:0] f_start,
    output logic signed [31:0] k_rate,
    output logic        [31:0] pw,
    output logic        [31:0] pri,
    output logic        [15:0] amp,
    output logic        [31:0] phase0,
    output logic               params_load
);
    localparam logic [31:0] ID_VALUE = 32'h4348_5250;

    // ======================================================= AXI-Lite slave
    logic [31:0] r_ctrl, r_fstart, r_krate, r_pw, r_pri, r_amp, r_phase0;
    logic        req_tgl;                         // flips on every APPLY
    logic [31:0] status;

    logic [ADDR_W-1:0] awaddr_q;
    logic              aw_have, w_have;
    logic [31:0]       wdata_q;
    logic [3:0]        wstrb_q;

    assign s_axi_awready = !aw_have && !s_axi_bvalid;
    assign s_axi_wready  = !w_have  && !s_axi_bvalid;
    assign s_axi_bresp   = 2'b00;
    assign s_axi_rresp   = 2'b00;

    function automatic logic [31:0] merge(input logic [31:0] old_v,
                                          input logic [31:0] new_v,
                                          input logic [3:0]  strb);
        logic [31:0] r;
        for (int b = 0; b < 4; b++)
            r[8*b +: 8] = strb[b] ? new_v[8*b +: 8] : old_v[8*b +: 8];
        return r;
    endfunction

    always_ff @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            aw_have      <= 1'b0;
            w_have       <= 1'b0;
            s_axi_bvalid <= 1'b0;
            req_tgl      <= 1'b0;
            r_ctrl       <= 32'h0000_0008;       // RFDC interleaved I/Q
            r_fstart     <= '0;
            r_krate      <= '0;
            r_pw         <= 32'd100;
            r_pri        <= 32'd1000;
            r_amp        <= 32'h0000_4000;          // -6 dBFS
            r_phase0     <= '0;
        end else begin
            if (s_axi_awvalid && s_axi_awready) begin
                awaddr_q <= s_axi_awaddr;
                aw_have  <= 1'b1;
            end
            if (s_axi_wvalid && s_axi_wready) begin
                wdata_q <= s_axi_wdata;
                wstrb_q <= s_axi_wstrb;
                w_have  <= 1'b1;
            end
            if (aw_have && w_have) begin
                case (awaddr_q[5:2])
                    4'h1: r_ctrl   <= merge(r_ctrl,   wdata_q, wstrb_q);
                    4'h2: r_fstart <= merge(r_fstart, wdata_q, wstrb_q);
                    4'h3: r_krate  <= merge(r_krate,  wdata_q, wstrb_q);
                    4'h4: r_pw     <= merge(r_pw,     wdata_q, wstrb_q);
                    4'h5: r_pri    <= merge(r_pri,    wdata_q, wstrb_q);
                    4'h6: r_amp    <= merge(r_amp,    wdata_q, wstrb_q);
                    4'h7: r_phase0 <= merge(r_phase0, wdata_q, wstrb_q);
                    4'h8: req_tgl  <= ~req_tgl;         // APPLY
                    default: ;                          // read-only / unused
                endcase
                aw_have      <= 1'b0;
                w_have       <= 1'b0;
                s_axi_bvalid <= 1'b1;
            end
            if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 1'b0;
        end
    end

    // read channel
    assign s_axi_arready = !s_axi_rvalid;
    always_ff @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            s_axi_rvalid <= 1'b0;
            s_axi_rdata  <= '0;
        end else begin
            if (s_axi_arvalid && s_axi_arready) begin
                s_axi_rvalid <= 1'b1;
                case (s_axi_araddr[5:2])
                    4'h0: s_axi_rdata <= ID_VALUE;
                    4'h1: s_axi_rdata <= r_ctrl;
                    4'h2: s_axi_rdata <= r_fstart;
                    4'h3: s_axi_rdata <= r_krate;
                    4'h4: s_axi_rdata <= r_pw;
                    4'h5: s_axi_rdata <= r_pri;
                    4'h6: s_axi_rdata <= r_amp;
                    4'h7: s_axi_rdata <= r_phase0;
                    4'h9: s_axi_rdata <= status;
                    default: s_axi_rdata <= 32'hDEAD_BEEF;
                endcase
            end else if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
            end
        end
    end

    // ============================================ CDC: AXI -> DAC (toggle)
    (* ASYNC_REG = "TRUE" *) logic [1:0] req_sync;
    logic req_seen;
    logic ack_tgl;                                 // dac domain copy of req_tgl

    always_ff @(posedge dac_clk) begin
        if (!dac_rst_n) begin
            req_sync    <= '0;
            req_seen    <= 1'b0;
            ack_tgl     <= 1'b0;
            params_load <= 1'b0;
            enable      <= 1'b0;
            cw_mode     <= 1'b0;
            iq_swap     <= 1'b0;
            pack_ilv    <= 1'b1;
            f_start     <= '0;
            k_rate      <= '0;
            pw          <= 32'd100;
            pri         <= 32'd1000;
            amp         <= 16'h4000;
            phase0      <= '0;
        end else begin
            req_sync    <= {req_sync[0], req_tgl};
            req_seen    <= req_sync[1];
            params_load <= 1'b0;
            if (req_sync[1] != req_seen) begin
                // AXI-side registers are quasi-static here (software waits on STATUS[1])
                enable      <= r_ctrl[0];
                cw_mode     <= r_ctrl[1];
                iq_swap     <= r_ctrl[2];
                pack_ilv    <= r_ctrl[3];
                f_start     <= r_fstart;
                k_rate      <= r_krate;
                pw          <= r_pw;
                pri         <= (r_pri == 0) ? 32'd1 : r_pri;
                amp         <= r_amp[15:0];
                phase0      <= r_phase0;
                params_load <= 1'b1;
                ack_tgl     <= req_sync[1];
            end
        end
    end

    // ============================================== CDC: DAC -> AXI (status)
    logic [23:0] hb_cnt = '0;
    always_ff @(posedge dac_clk) hb_cnt <= hb_cnt + 1'b1;   // heartbeat, ~11 Hz toggle

    (* ASYNC_REG = "TRUE" *) logic [1:0] ack_sync = '0, rdy_sync = '0, hb_sync = '0;
    always_ff @(posedge s_axi_aclk) begin
        ack_sync <= {ack_sync[0], ack_tgl};
        rdy_sync <= {rdy_sync[0], dac_rst_n};
        hb_sync  <= {hb_sync[0],  hb_cnt[23]};
    end
    assign status = {29'd0, hb_sync[1], (req_tgl != ack_sync[1]), rdy_sync[1]};
endmodule
