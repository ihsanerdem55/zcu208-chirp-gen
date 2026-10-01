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
//   * reproducibility: every APPLY restarts the sequence from the seed, so the
//     same configuration gives identical data whatever ran before; another
//     seed (PHASE0) gives different data.
//   * bit-exact: a sequential per-sample model of noise_src (one draw decision
//     per sample, in order) must match every gated output sample. It catches
//     lane ordering and draw-index errors that the statistics above cannot.
//
// All captures use RFDC interleaved packing (I0,Q0,..,I7,Q7), ilv = 1.
// Define DUMP_FILES to also write out/noise_bw200.txt for analyze.py (spectrum).
// -----------------------------------------------------------------------------
`timescale 1ps/1ps
module tb_noise;
    localparam int  LANES  = 8;
    localparam real FS_BB  = 1474.56e6;
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


    // --------------------------------------------- bit-exact noise_src model
    // Evaluated #1 after every DAC clock edge P_k. It replays the clock cycle
    // that ended at P_k one sample at a time and queues that cycle's LANES
    // noise values; they reach m_axis six clocks later (noise_src stage 2,
    // three DSP stages, packing and output registers). noise_src restarts one
    // clock after reset or params_load (its restart flop).
    localparam logic [31:0] POLY = 32'hEDB8_8320;
    function automatic logic [31:0] lfsr_adv(input logic [31:0] s, input int steps);
        for (int i = 0; i < steps; i++) s = s[0] ? ((s >> 1) ^ POLY) : (s >> 1);
        return s;
    endfunction
    function automatic logic signed [15:0] slice_sum(input logic [31:0] a, input logic [31:0] b,
                                                     input logic [31:0] c, input logic [31:0] d);
        return $signed(a[31:19]) + $signed(b[31:19]) + $signed(c[31:19]) + $signed(d[31:19]);
    endfunction
    function automatic logic signed [15:0] scale_amp(input logic signed [15:0] x, input logic [15:0] a);
        logic signed [32:0] pr;
        pr = x * $signed({1'b0, (a[15] ? 16'h7FFF : a)}) + 33'sd16384;
        return pr[30:15];
    endfunction

    function automatic logic [31:0] seed_of(input int g, input logic [31:0] sel);
        logic [31:0] base, r;
        case (g)
            0: base = 32'h1234_5678;  1: base = 32'h9E37_79B9;
            2: base = 32'hDEAD_BEEF;  3: base = 32'h0BAD_F00D;
            4: base = 32'hCAFE_BABE;  5: base = 32'h5A5A_A5A5;
            6: base = 32'hF00D_1234;  default: base = 32'h1357_9BDF;
        endcase
        r = base;
        for (int b = 0; b < 32; b++) if (sel[b]) r[(b + 4*g) % 32] = ~r[(b + 4*g) % 32];
        return (r == 0) ? base : r;
    endfunction

    localparam int MODEL_LAT = 6;
    logic [31:0]  m_lf [8];
    logic         m_reseed = 0;                 // params_load seen in the previous cycle
    logic         m_rq = 1;                     // noise_src restart flop, cycle being replayed
    logic [31:0]  seed_cfg = 0, seed_now = 0;   // written by the tests / in effect since APPLY
    logic [32:0]  m_acc;                        // nacc, plus a carry bit per sample
    logic [31:0]  m_inc = 0, m_ninc_last = 0;   // ninc of cycles k-2 and k-1
    logic signed [15:0] m_hold_i = 0, m_hold_q = 0;
    logic [LANES*32-1:0] m_q [MODEL_LAT+1];     // [0] newest; interleaved {Q,I} per lane
    logic [15:0]  amp_cfg = 0, amp_now = 0;     // written by the tests / in effect since APPLY
    int           m_skip = 0, m_cmp = 0, m_mis = 0;
    longint       n_dclk = 0, load_dclk = 0;    // DAC clock count, at the last params_load
    always @(posedge dclk) begin
        logic [31:0] st [8];
        logic [LANES*32-1:0] w;
        int k;
        #1;
        for (int i = MODEL_LAT; i > 0; i--) m_q[i] = m_q[i-1];
        if (m_rq) begin                         // reset, or reseed by an APPLY
            for (int g = 0; g < 8; g++) m_lf[g] = seed_of(g, seed_now);
            m_acc = 33'h0_FFFF_FFFF;
            m_hold_i = 0; m_hold_q = 0;
            w = '0;
        end else begin
            k = 0;                              // draws taken in this cycle
            for (int m = 0; m < LANES; m++) begin
                m_acc = {1'b0, m_acc[31:0]} + {1'b0, m_inc};
                if (m_acc[32]) begin
                    for (int g = 0; g < 8; g++) st[g] = lfsr_adv(m_lf[g], k);
                    m_hold_i = slice_sum(st[0], st[1], st[2], st[3]);
                    m_hold_q = slice_sum(st[4], st[5], st[6], st[7]);
                    k++;
                end
                w[32*m +: 32] = {m_hold_q, m_hold_i};
            end
            for (int g = 0; g < 8; g++) m_lf[g] = lfsr_adv(m_lf[g], LANES);
        end
        m_q[0] = w;
        m_rq = !drst_n || m_reseed;             // restart flop for the next cycle
        if (!drst_n) seed_now = 0;              // PHASE0 resets to 0
        m_inc = m_ninc_last;                    // noise_src registers (m+1)*ninc
        m_ninc_last = dut.u_top.u_core.u_noise.ninc;
        // compare the gated output with the model; skip clocks right after a
        // load, whose blocks may still carry the previous amplitude
        m_reseed = dut.u_top.params_load;
        if (m_reseed) begin m_skip = 16; amp_now = amp_cfg; seed_now = seed_cfg; load_dclk = n_dclk; end
        else if (m_skip > 0) m_skip--;
        n_dclk++;
        if (drst_n && trig && m_skip == 0) begin
            for (int m = 0; m < LANES; m++) begin
                logic [15:0] ei, eq;
                ei = scale_amp($signed(m_q[MODEL_LAT][32*m      +: 16]), amp_now);
                eq = scale_amp($signed(m_q[MODEL_LAT][32*m + 16 +: 16]), amp_now);
                m_cmp++;
                if (tdata[32*m +: 32] !== {eq, ei}) begin
                    m_mis++;
                    if (m_mis <= 8)
                        $display("NOISE MISMATCH t=%0t lane=%0d got I=%0d Q=%0d exp I=%0d Q=%0d", $time, m,
                                 $signed(tdata[32*m +: 16]), $signed(tdata[32*m + 16 +: 16]),
                                 $signed(ei), $signed(eq));
                end
            end
        end
    end

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

    // en, cw (1 = continuous, 0 = pulsed), swap, ninc, pw, pri, amp (0..1), seed
    task automatic setup_noise(input logic en, input logic cw, input logic swap,
                               input logic [31:0] ninc, input int pw, input int pri,
                               input real amp, input logic [31:0] seed = 0);
        axi_write(16'h08, 32'd0);                       // FSTART unused
        axi_write(16'h0C, ninc);                        // KRATE reused as ninc
        axi_write(16'h10, pw);
        axi_write(16'h14, pri);
        amp_cfg = $rtoi(amp*32767.0+0.5);
        axi_write(16'h18, {16'd0, amp_cfg});
        seed_cfg = seed;
        axi_write(16'h1C, seed);                        // PHASE0 reused as the seed
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

    // wait until n DAC clocks after the last parameter load (load-aligned capture)
    task automatic after_load(input int n);
        while (n_dclk < load_dclk + n) @(posedge dclk);
    endtask

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
    int  nz, k, ntrig, nz_hi, nz_lo, nsamp, e0;

    // samples of the current buffer that differ from the saved one
    function automatic int ndiff(input int nsamp);
        int d = 0;
        for (int i = 0; i < nsamp; i++) if (bi[i] != ci[i] || bq[i] != cq[i]) d++;
        return d;
    endfunction

`ifdef DUMP_FILES
    task automatic dump(input string fname, input int nclk);
        int fd;
        fd = $fopen(fname, "w");
        repeat (nclk) begin
            @(posedge dclk);
            #1;
            $fdisplay(fd, "%h %0d", tdata, trig);
        end
        $fclose(fd);
    endtask
`else
    task automatic dump(input string fname, input int nclk);
        repeat (nclk) @(posedge dclk);
    endtask
`endif

    initial begin
        reset_dut();

        // T0: register access
        axi_read(16'h00, v);
        if (v !== 32'h43485250) begin $display("FAIL T0: ID=%h", v); errors++; end
        else $display("PASS T0: ID register = %h (CHRP)", v);

        // T1: wide-band continuous noise, D ~ 1 (fresh nearly every sample)
        $display("T1: wide-band continuous noise (D=1), full amplitude");
        e0 = errors;
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
        if (errors == e0) $display("PASS T1");

        // T2: narrow-band continuous noise, D = 16 -> runs of 16 equal samples
        $display("T2: narrow-band continuous noise, D=16");
        setup_noise(1, 1, 0, 32'h1000_0000, 100, 1000, 1.0);  // ninc = 2^32/16
        repeat (30) @(posedge dclk);
        grab(2000);
        stats(2000*LANES, mi, mq, rms, feq, nz);
        $display("     frac_eq=%.4f (expect ~0.9375), avg run=%.2f", feq, 1.0/(1.0-feq));
        if (feq < 0.90 || feq > 0.96) begin $display("FAIL T2: run length not ~16"); errors++; end
        else $display("PASS T2");

        // T2b: fractional hold, D = 2.5 -> runs alternate 2 and 3 (mean 2.5)
        $display("T2b: fractional hold, D=2.5");
        setup_noise(1, 1, 0, 32'h6666_6666, 100, 1000, 1.0);  // ninc = 2^32/2.5
        repeat (30) @(posedge dclk);
        grab(2000);
        stats(2000*LANES, mi, mq, rms, feq, nz);
        $display("     frac_eq=%.4f (expect ~0.6), avg run=%.3f", feq, 1.0/(1.0-feq));
        if (feq < 0.58 || feq > 0.62) begin $display("FAIL T2b: run length not ~2.5"); errors++; end
        else $display("PASS T2b");

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
        e0 = errors;
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
        if (errors == e0)                  $display("PASS T4 (gating)");

        // T5: reproducibility -- the same command gives identical data after a
        // reset and after other commands; another seed gives different data
        $display("T5: reproducibility across reset and reloads, seed selection");
        reset_dut();
        setup_noise(1, 1, 0, 32'h0400_0000, 100, 1000, 1.0);
        after_load(60); grab(1000);
        for (k = 0; k < 1000*LANES; k++) begin ci[k] = bi[k]; cq[k] = bq[k]; end
        reset_dut();
        repeat (37) @(posedge dclk);                   // a different reset-to-APPLY delay
        setup_noise(1, 1, 0, 32'h0400_0000, 100, 1000, 1.0);
        after_load(60); grab(1000);
        if (ndiff(1000*LANES) != 0) begin $display("FAIL T5: data differ after a reset"); errors++; end
        setup_noise(1, 0, 0, 32'h1000_0000, 50, 70, 0.5, 32'd7);      // something else
        repeat (300) @(posedge dclk);
        setup_noise(1, 1, 0, 32'h0400_0000, 100, 1000, 1.0);
        after_load(60); grab(1000);
        if (ndiff(1000*LANES) != 0) begin $display("FAIL T5: data differ after another command"); errors++; end
        setup_noise(1, 1, 0, 32'h0400_0000, 100, 1000, 1.0, 32'h0000_0001);
        after_load(60); grab(1000);
        if (ndiff(1000*LANES) < 1000*LANES*9/10) begin
            $display("FAIL T5: seed 1 repeats the seed 0 data (%0d samples differ)", ndiff(1000*LANES)); errors++;
        end
        else $display("PASS T5: identical %0d samples per command; seed 1 differs", 1000*LANES);

        // T6: 200 MHz band (ninc as tcl/chirp_ctrl.tcl computes it), continuous,
        // for the spectrum check in analyze.py
        $display("T6: continuous noise, bw 200 MHz");
        setup_noise(1, 1, 0, $rtoi(4294967296.0 * 200.0e6 / FS_BB + 0.5), 100, 1000, 1.0);
        repeat (30) @(posedge dclk);
        dump("out/noise_bw200.txt", 4096);
        gen_off();

        // every gated sample of the tests above against the sequential model
        $display("Noise model: %0d gated samples compared bit-exact, %0d mismatches", m_cmp, m_mis);
        if (m_mis != 0 || m_cmp < 50000) begin $display("FAIL: noise model check"); errors++; end
        else $display("PASS: noise output bit-exact against the per-sample model");

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
