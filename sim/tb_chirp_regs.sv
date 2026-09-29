// CDC recovery and AXI-Lite protocol regressions, independent of RFDC IP.
`timescale 1ns/1ps
module tb_chirp_regs;
    logic ac = 0, dc = 0, run_dc = 1, ar = 0, dr = 0;
    always #5 ac = ~ac;
    always #2.713 if (run_dc) dc = ~dc;
    logic [15:0] awaddr = 0, araddr = 0;
    logic [31:0] wd = 0, rd;
    logic [3:0] ws = 15;
    logic av = 0, wv = 0, rv = 0, br = 0, rr = 0;
    wire awready, wready, bv, arready, rvalid;
    wire [1:0] bp, rp;
    wire en, cw, swap, ilv, load;
    wire [31:0] f, k, pw, pri, phase0;
    wire [15:0] amp;
    chirp_axil_regs dut (
        .s_axi_aclk(ac), .s_axi_aresetn(ar),
        .s_axi_awaddr(awaddr), .s_axi_awvalid(av), .s_axi_awready(awready),
        .s_axi_wdata(wd), .s_axi_wstrb(ws), .s_axi_wvalid(wv), .s_axi_wready(wready),
        .s_axi_bresp(bp), .s_axi_bvalid(bv), .s_axi_bready(br),
        .s_axi_araddr(araddr), .s_axi_arvalid(rv), .s_axi_arready(arready),
        .s_axi_rdata(rd), .s_axi_rresp(rp), .s_axi_rvalid(rvalid), .s_axi_rready(rr),
        .dac_clk(dc), .dac_rst_n(dr), .enable(en), .cw_mode(cw), .iq_swap(swap),
        .pack_ilv(ilv), .f_start(f), .k_rate(k), .pw(pw), .pri(pri), .amp(amp),
        .phase0(phase0), .params_load(load)
    );
    // Deliberately separate AW and W and hold BREADY low.
    task automatic write_reg(input logic [15:0] addr, input logic [31:0] data,
                             input logic [3:0] strb = 15, input logic [1:0] resp = 0);
        @(negedge ac); awaddr = addr; av = 1;
        do @(posedge ac); while (!awready);
        @(negedge ac); av = 0;
        repeat (2) @(negedge ac);
        wd = data; ws = strb; wv = 1;
        do @(posedge ac); while (!wready);
        @(negedge ac); wv = 0;
        do @(negedge ac); while (!bv);
        repeat (3) begin
            if (!bv || bp != resp) $fatal(1, "Write response %h: %b expected %b", addr, bp, resp);
            @(negedge ac);
        end
        br = 1;
        @(negedge ac); br = 0;
    endtask
    task automatic read_reg(input logic [15:0] addr, output logic [31:0] data);
        @(negedge ac); araddr = addr; rv = 1;
        do @(posedge ac); while (!arready);
        @(negedge ac); rv = 0;
        while (!rvalid) @(negedge ac);
        data = rd;
        repeat (3) begin
            @(negedge ac);
            if (!rvalid || rd !== data) $fatal(1, "Read response changed while stalled");
        end
        rr = 1;
        @(negedge ac); rr = 0;
    endtask
    task automatic idle;
        logic [31:0] st;
        do read_reg('h24, st); while ((st & 3) != 1);
    endtask
    task automatic dac_reset;
        @(negedge dc); dr = 0;
        repeat (8) @(negedge ac);
        @(negedge dc); dr = 1;
        idle();
        repeat (10) @(negedge dc);
        if (en) $fatal(1, "Old enabled parameters replayed after DAC reset");
    endtask
    logic [31:0] value;
    initial begin
        repeat (6) @(negedge ac); ar = 1;
        repeat (4) @(negedge dc); dr = 1;
        idle();
        write_reg('h08, 'h12345678);
        write_reg('h08, 'hABCDEF01, 4'b0101);
        read_reg('h08, value);
        if (value != 'h12CD5601) $fatal(1, "WSTRB merge failed");
        write_reg('h04, 11);
        write_reg('h20, 1); idle(); // odd toggle
        if (!en || f != 'h12CD5601) $fatal(1, "Apply failed");
        dac_reset();
        write_reg('h20, 1); idle(); // even toggle, fresh re-enable
        if (!en) $fatal(1, "Fresh apply after reset lost");
        dac_reset();
        write_reg('h20, 1); idle();
        if (!en) $fatal(1, "Fresh apply after even reset lost");
        // Stop clock without reset: exactly one request must remain pending.
        @(negedge dc); run_dc = 0;
        write_reg('h08, 'h87654321);
        write_reg('h20, 1);
        read_reg('h24, value);
        if (!value[1]) $fatal(1, "Pending request not reported");
        write_reg('h20, 1, 15, 2); // cannot cancel the pending toggle
        write_reg('h08, 'hBAD, 15, 2); // cannot corrupt bundled parameters
        write_reg('h20, 1, 0); // zero strobe is a no-op
        read_reg('h24, value);
        if (!value[1]) $fatal(1, "Pending request was cancelled");
        run_dc = 1; idle();
        if (f != 'h87654321) $fatal(1, "Pending snapshot corrupted");
        // APPLY while reset is rejected; a reset recovery never arms output.
        @(negedge dc); dr = 0;
        repeat (8) @(negedge ac);
        write_reg('h20, 1, 15, 2);
        @(negedge dc); dr = 1; idle();
        if (en) $fatal(1, "Reset enabled output");
        write_reg('h20, 1, 0); idle();
        if (en) $fatal(1, "Zero-strobe APPLY had side effects");
        write_reg('h20, 1); idle();
        if (!en) $fatal(1, "Valid APPLY lost");
        $display("PASS: CDC odd/even reset recovery, stopped clock, busy writes, WSTRB and AXI backpressure");
        $finish;
    end
    initial begin #100000; $fatal(1, "Timeout"); end
endmodule
