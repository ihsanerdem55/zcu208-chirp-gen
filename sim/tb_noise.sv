// -----------------------------------------------------------------------------
// tb_noise.sv  --  self-checking testbench for the band-limited noise mode
//
// Drives chirp_gen_wrapper over AXI-Lite exactly like tcl/chirp_ctrl.tcl, turns
// on noise mode (CTRL[4]) and checks the properties that matter for a noise
// source, rather than a bit-exact reference:
//   * bandwidth: with a sample-and-hold decimation D the sample stream repeats
//     in runs of length D, so the fraction of equal adjacent samples ~ (D-1)/D.
//     A wide band (D=1) draws a fresh value almost every sample.
//   * zero mean and a plausible amplitude that scales with AMP.
//   * pulsing: zero between pulses, non-zero inside, correct duty cycle.
//   * reproducibility: the same configuration after a reset gives identical data.
//
// All captures use RFDC interleaved packing (I0,Q0,..,I3,Q3), ilv = 1.
// -----------------------------------------------------------------------------
`timescale 1ps/1ps
module tb_noise;
    localparam int  LANES  = 4;
    localparam real FS_BB  = 737.28e6;
    localparam int  T_DCLK = 5426;

    logic aclk = 0, dclk = 0;
    always #5000 aclk = ~aclk;
    always #(T_DCLK/2) dclk = ~dclk;
    logic aresetn = 0, drst_n = 0;

    logic [15:0] awaddr = 0, araddr = 0;
    logic awvalid = 0, wvalid = 0, bready = 1, arvalid = 0, rready = 1;
    logic awready, wready, bvalid, arready, rvalid;
    logic [31:0] wdata = 0, rdata;
    logic [1:0]  bresp, rresp;
    logic [LANES*32-1:0] tdata;
    logic tvalid, trig;

    chirp_gen_wrapper #(.LANES(LANES)) dut (
        .s_axi_aclk(aclk), .s_axi_aresetn(aresetn),
        .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(4'hF), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .dac_mmcm_locked(1'b1), .dac_mmcm_reset(), .dac_domain_reset(),
        .dac_clk(dclk), .dac_rst_n(drst_n),
        .m_axis_tdata(tdata), .m_axis_tvalid(tvalid), .m_axis_tready(1'b1),
        .trig_out(trig),
        .mon_data(), .mon_valid(), .mon_ready(), .mon_gate()
    );

    // --------------------------------------------------------- AXI-Lite BFM
    task automatic axi_write(input logic [15:0] a, input logic [31:0] d);
        @(negedge aclk);
        awaddr = a; wdata = d; awvalid = 1; wvalid = 1;
        fork
            begin do @(posedge aclk); while (!awready); @(negedge aclk); awvalid = 0; end
            begin do @(posedge aclk); while (!wready);  @(negedge aclk); wvalid = 0; end
        join
        do @(posedge aclk); while (!bvalid);
        if (bresp != 0) $fatal(1, "AXI write rejected at %h", a);
    endtask

    task automatic axi_read(input logic [15:0] a, output logic [31:0] d);
        @(negedge aclk);
        araddr = a; arvalid = 1;
        do @(posedge aclk); while (!arready);
        @(negedge aclk); arvalid = 0;
        do @(posedge aclk); while (!rvalid);
        d = rdata;
    endtask

    task automatic apply_and_wait();
        logic [31:0] st;
        axi_write(16'h20, 32'h1);
        do axi_read(16'h24, st); while (st[1]);
    endtask

    // en, cw (1 = continuous, 0 = pulsed), swap, ninc, pw, pri, amp (0..1)
    task automatic setup_noise(input logic en, input logic cw, input logic swap,
                               input logic [31:0] ninc, input int pw, input int pri,
                               input real amp);
        axi_write(16'h08, 32'd0);                       // FSTART unused
        axi_write(16'h0C, ninc);                        // KRATE reused as ninc
        axi_write(16'h10, pw);
        axi_write(16'h14, pri);
        axi_write(16'h18, {16'd0, $rtoi(amp*32767.0+0.5)});
        axi_write(16'h1C, 32'd0);
        axi_write(16'h04, {27'd0, 1'b1, 1'b1, swap, cw, en}); // noise=1, ilv=1
        apply_and_wait();
    endtask

    task automatic gen_off();
        axi_write(16'h04, 32'h0000_0008);               // disable, keep ilv
        apply_and_wait();
        repeat (20) @(posedge dclk);
    endtask

    task automatic reset_dut();
        aresetn = 0; drst_n = 0;
        repeat (5) @(posedge aclk);
        @(negedge aclk); aresetn = 1;
        repeat (5) @(posedge dclk);
        @(negedge dclk); drst_n = 1;
        repeat (5) @(posedge aclk);
    endtask

    // ---------------------------------------------------------- capture buffer
    localparam int MAXCLK = 3000;
    logic signed [15:0] bi [0:LANES*MAXCLK-1];
    logic signed [15:0] bq [0:LANES*MAXCLK-1];
    logic               bt [0:MAXCLK-1];
    int   capclk = 0;
    logic capturing = 0;

    always @(posedge dclk) begin
        #1;
        if (capturing && capclk < MAXCLK) begin
            for (int m = 0; m < LANES; m++) begin
                bi[capclk*LANES + m] = $signed(tdata[32*m      +: 16]);
                bq[capclk*LANES + m] = $signed(tdata[32*m + 16 +: 16]);
            end
            bt[capclk] = trig;
            capclk = capclk + 1;
        end
    end

    task automatic grab(input int nclk);
        capclk = 0; capturing = 1;
        wait (capclk >= nclk);
        @(posedge dclk); capturing = 0;
    endtask

    // ------------------------------------------------------------ tests
    int errors = 0;
    logic [31:0] v;
    // second buffer for the reproducibility test
    logic signed [15:0] ci [0:LANES*MAXCLK-1];
    logic signed [15:0] cq [0:LANES*MAXCLK-1];

    // stats over the current buffer's first nsamp samples
    task automatic stats(input int nsamp, output real mean_i, output real mean_q,
                         output real rms, output real frac_eq, output int nz);
        real si, sq, ss, ri, rq; int eq; int k;
        si = 0; sq = 0; ss = 0; eq = 0; nz = 0;
        for (k = 0; k < nsamp; k++) begin
            ri = bi[k]; rq = bq[k];             // widen to real before squaring
            si = si + ri; sq = sq + rq;
            ss = ss + ri*ri + rq*rq;
            if (bi[k] != 0 || bq[k] != 0) nz = nz + 1;
            if (k > 0 && bi[k] == bi[k-1] && bq[k] == bq[k-1]) eq = eq + 1;
        end
        mean_i = si / nsamp;
        mean_q = sq / nsamp;
        rms    = $sqrt(ss / (2.0*nsamp));
        frac_eq = eq * 1.0 / (nsamp - 1);
    endtask

    real mi, mq, rms, feq, rms2;
    int  nz, k, ntrig, nz_hi, nz_lo, nsamp;

    initial begin
        reset_dut();

        // T0: register access
        axi_read(16'h00, v);
        if (v !== 32'h43485250) begin $display("FAIL T0: ID=%h", v); errors++; end
        else $display("PASS T0: ID register = %h (CHRP)", v);

        // T1: wide-band continuous noise, D ~ 1 (fresh nearly every sample)
        $display("T1: wide-band continuous noise (D=1), full amplitude");
        setup_noise(1, 1, 0, 32'hFFFF_FFFF, 100, 1000, 1.0);
        repeat (30) @(posedge dclk);
        grab(2000);
        nsamp = 2000*LANES;
        stats(nsamp, mi, mq, rms, feq, nz);
        $display("     mean I=%.1f Q=%.1f, rms=%.1f, frac_eq=%.4f, nonzero=%0d/%0d",
                 mi, mq, rms, feq, nz, nsamp);
        if (feq > 0.05)          begin $display("FAIL T1: too many held samples for D=1"); errors++; end
        if (nz < nsamp*9/10)     begin $display("FAIL T1: too many zero samples"); errors++; end
        if (rms < 3000.0 || rms > 6500.0) begin $display("FAIL T1: rms out of range"); errors++; end
        if (mi < -150.0 || mi > 150.0 || mq < -150.0 || mq > 150.0)
                                 begin $display("FAIL T1: noise not zero-mean"); errors++; end
        if (errors == 0) $display("PASS T1");

        // T2: narrow-band continuous noise, D = 16 -> runs of 16 equal samples
        $display("T2: narrow-band continuous noise, D=16");
        setup_noise(1, 1, 0, 32'h1000_0000, 100, 1000, 1.0);  // ninc = 2^32/16
        repeat (30) @(posedge dclk);
        grab(2000);
        stats(2000*LANES, mi, mq, rms, feq, nz);
        $display("     frac_eq=%.4f (expect ~0.9375), avg run=%.2f", feq, 1.0/(1.0-feq));
        if (feq < 0.90 || feq > 0.96) begin $display("FAIL T2: run length not ~16"); errors++; end
        else $display("PASS T2");

        // T3: amplitude scaling, full vs quarter (same band)
        $display("T3: amplitude scaling 1.0 vs 0.25");
        setup_noise(1, 1, 0, 32'hFFFF_FFFF, 100, 1000, 1.0);
        repeat (30) @(posedge dclk); grab(1500); stats(1500*LANES, mi, mq, rms,  feq, nz);
        setup_noise(1, 1, 0, 32'hFFFF_FFFF, 100, 1000, 0.25);
        repeat (30) @(posedge dclk); grab(1500); stats(1500*LANES, mi, mq, rms2, feq, nz);
        $display("     rms(1.0)=%.1f  rms(0.25)=%.1f  ratio=%.2f (expect ~4)", rms, rms2, rms/rms2);
        if (rms/rms2 < 3.2 || rms/rms2 > 4.8) begin $display("FAIL T3: amplitude does not scale"); errors++; end
        else $display("PASS T3");

        // T4: pulsed noise -- zero between pulses, non-zero inside, duty ~ PW/PRI
        $display("T4: pulsed noise, PW=100 PRI=400 (duty 0.25)");
        setup_noise(1, 0, 0, 32'hFFFF_FFFF, 100, 400, 1.0);
        repeat (30) @(posedge dclk);
        grab(2000);
        ntrig = 0; nz_hi = 0; nz_lo = 0;
        for (k = 0; k < 2000; k++) begin
            logic anynz;
            anynz = 0;
            for (int m = 0; m < LANES; m++)
                if (bi[k*LANES+m] != 0 || bq[k*LANES+m] != 0) anynz = 1;
            if (bt[k]) begin ntrig++; if (anynz) nz_hi++; end
            else if (anynz) nz_lo++;
        end
        $display("     trig-high clocks=%0d/2000 (expect ~500), nonzero-while-low=%0d", ntrig, nz_lo);
        if (nz_lo != 0)                    begin $display("FAIL T4: output non-zero between pulses"); errors++; end
        if (ntrig < 400 || ntrig > 600)    begin $display("FAIL T4: pulse duty wrong"); errors++; end
        if (nz_hi < ntrig*8/10)            begin $display("FAIL T4: pulse mostly zero"); errors++; end
        if (errors == 0 || nz_lo == 0)     $display("PASS T4 (gating)");

        // T5: reproducibility -- identical config after a reset gives identical data
        $display("T5: reproducibility across reset");
        reset_dut();
        setup_noise(1, 1, 0, 32'h0400_0000, 100, 1000, 1.0);
        repeat (30) @(posedge dclk); grab(1000);
        for (k = 0; k < 1000*LANES; k++) begin ci[k] = bi[k]; cq[k] = bq[k]; end
        reset_dut();
        setup_noise(1, 1, 0, 32'h0400_0000, 100, 1000, 1.0);
        repeat (30) @(posedge dclk); grab(1000);
        begin
            int diff; diff = 0;
            for (k = 0; k < 1000*LANES; k++) if (bi[k] != ci[k] || bq[k] != cq[k]) diff++;
            if (diff != 0) begin $display("FAIL T5: %0d samples differ between runs", diff); errors++; end
            else $display("PASS T5: identical %0d samples", 1000*LANES);
        end

        $display("--------------------------------------------------------------");
        if (errors == 0) $display("*** NOISE TEST PASSED ***");
        else             $fatal(1, "*** NOISE TEST FAILED (%0d errors) ***", errors);
        $display("--------------------------------------------------------------");
        $finish;
    end

    initial begin
        #(64'd40_000_000_000);
        $fatal(1, "*** NOISE TEST FAILED: timeout ***");
    end
endmodule
