// -----------------------------------------------------------------------------
// tb_chirp_gen.sv  --  self-checking behavioural testbench for chirp_gen_wrapper
//
// Works in Vivado xsim (Run Behavioral Simulation) and in Icarus Verilog 12.
//  * Drives the AXI-Lite registers exactly like the Tcl scripts do on hardware.
//  * A bit-exact reference model (same math as chirp_core, same sine table)
//    checks EVERY output sample: model value while trig_out is high, zero otherwise.
//  * Signals for the waveform window:
//      i_ser, q_ser   : output samples serialised to 737.28 MSPS (set Waveform
//                       Style = Analog, radix = Signed Decimal)
//      f_inst_mhz     : instantaneous baseband frequency (real, show as Analog)
//      trig           : pulse gate / scope trigger
//  * Define DUMP_FILES to also write sim/out/*.txt for analyze.py (Python plots).
//
// Needs sincos_qw.mem in the simulator's working directory (Vivado copies it
// automatically when it is part of the project sources).
// -----------------------------------------------------------------------------
`timescale 1ps/1ps
module tb_chirp_gen;
    localparam int  LANES   = 4;
    localparam real FS_BB   = 737.28e6;          // complex sample rate at the AXIS port
    localparam int  T_DCLK  = 5426;              // 184.32 MHz fabric clock period (ps)

    // ------------------------------------------------------------ clocks/resets
    logic aclk = 0, dclk = 0;
    always #5000 aclk = ~aclk;                   // 100 MHz AXI clock
    always #(T_DCLK/2) dclk = ~dclk;
    logic aresetn = 0, drst_n = 0;

    // ------------------------------------------------------------------- DUT
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
        .dac_clk(dclk), .dac_rst_n(drst_n),
        .m_axis_tdata(tdata), .m_axis_tvalid(tvalid), .m_axis_tready(1'b1),
        .trig_out(trig)
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
        @(negedge aclk);
        arvalid = 0;
        do @(posedge aclk); while (!rvalid);
        d = rdata;
    endtask

    task automatic apply_and_wait();
        logic [31:0] st;
        axi_write(16'h20, 32'h1);
        do axi_read(16'h24, st); while (st[1]);
    endtask

    function automatic logic [31:0] freq_word(input real f_hz);
        return $rtoi(f_hz / FS_BB * 4294967296.0 + (f_hz >= 0 ? 0.5 : -0.5));
    endfunction

    // ------------------------------------------------ test-side configuration
    // The scoreboard uses these; tests change them only while the output is off.
    logic [31:0] cfg_f = 0, cfg_k = 0, cfg_p0 = 0;
    logic [15:0] cfg_amp = 0;
    logic        cfg_cw = 0, cfg_swap = 0, cfg_ilv = 0;

    task automatic setup_gen(input logic en, input logic cw, input logic swap, input logic ilv,
                           input real f_hz, input logic [31:0] krate,
                           input int pw, input int pri, input real amp, input real phase_deg);
        cfg_f   = freq_word(f_hz);
        cfg_k   = krate;
        cfg_p0  = $rtoi(phase_deg / 360.0 * 4294967296.0);
        cfg_amp = $rtoi(amp * 32767.0 + 0.5);
        cfg_cw  = cw; cfg_swap = swap; cfg_ilv = ilv;
        axi_write(16'h08, cfg_f);
        axi_write(16'h0C, cfg_k);
        axi_write(16'h10, pw);
        axi_write(16'h14, pri);
        axi_write(16'h18, {16'd0, cfg_amp});
        axi_write(16'h1C, cfg_p0);
        axi_write(16'h04, {28'd0, ilv, swap, cw, en});
        apply_and_wait();
    endtask

    task automatic gen_off();
        axi_write(16'h04, {28'd0, cfg_ilv, cfg_swap, 2'b00});
        apply_and_wait();
        repeat (20) @(posedge dclk);
    endtask

    // chirp rate in KRATE units (Q24.8) for a sweep of bw_hz over pw clocks
    function automatic logic [31:0] krate_for(input real bw_hz, input int pw);
        real kw;
        kw = (bw_hz / FS_BB * 4294967296.0) / (pw * LANES);
        return $rtoi(kw * 256.0 + (kw >= 0 ? 0.5 : -0.5));
    endfunction

    // --------------------------------------------------- reference model
    logic [15:0] rom [0:4095];
    initial $readmemh("sincos_qw.mem", rom);

    function automatic logic signed [15:0] lut(input logic [13:0] p);
        logic [11:0] a;
        a = p[12] ? ~p[11:0] : p[11:0];
        return p[13] ? -$signed(rom[a]) : $signed(rom[a]);
    endfunction

    function automatic logic signed [15:0] scale(input logic signed [15:0] x);
        logic signed [32:0] pr;
        logic [15:0] a;
        a  = cfg_amp[15] ? 16'h7FFF : cfg_amp;
        pr = x * $signed({1'b0, a}) + 33'sd16384;
        return pr[30:15];
    endfunction

    // expected {I,Q} for sample n of the current pulse (n = 0 at trig rising edge)
    function automatic logic [31:0] ref_iq(input logic [63:0] n);
        logic [63:0] F0, K, P0, phi, tri_n;
        logic [13:0] p;
        logic signed [15:0] ci, sq;
        F0    = {{16{cfg_f[31]}}, cfg_f, 16'd0};
        K     = cfg_cw ? 64'd0 : {{24{cfg_k[31]}}, cfg_k, 8'd0};
        P0    = {16'd0, cfg_p0, 16'd0};
        tri_n = (n * (n - 64'd1)) >> 1;
        phi   = P0 + F0 * n + K * tri_n;          // wraps mod 2^64, we only need mod 2^48
        p     = phi[47:34];
        ci    = scale(lut(p + 14'd4096));         // cos = sin(p + 90 deg)
        sq    = scale(lut(p));
        return {ci, sq};
    endfunction

    // ------------------------------------------------------ scoreboard
    logic [63:0] n_smp = 0;                        // sample index inside the current pulse
    logic        trig_q = 0;
    int          checked = 0, mism = 0, gated = 0;
    logic signed [15:0] lane_i [LANES];
    logic signed [15:0] lane_q [LANES];

    always @(posedge dclk) begin
        #1;
        // unpack the AXIS word as the RF-DAC would, undoing the swap option
        for (int m = 0; m < LANES; m++) begin
            logic signed [15:0] a, b;
            if (cfg_ilv) begin a = tdata[32*m +: 16]; b = tdata[32*m + 16 +: 16]; end
            else         begin a = tdata[16*m +: 16]; b = tdata[16*(m + LANES) +: 16]; end
            lane_i[m] = cfg_swap ? b : a;
            lane_q[m] = cfg_swap ? a : b;
        end
        if (drst_n) begin
            if (trig && !trig_q) n_smp = 0;        // new pulse (or CW start)
            for (int m = 0; m < LANES; m++) begin
                logic [31:0] e;
                e = trig ? ref_iq(n_smp + m) : 32'd0;
                checked++;
                if (trig) gated++;
                if ({lane_i[m], lane_q[m]} !== e) begin
                    mism++;
                    if (mism <= 10)
                        $display("MISMATCH t=%0t n=%0d lane=%0d got I=%0d Q=%0d exp I=%0d Q=%0d",
                                 $time, n_smp + m, m, lane_i[m], lane_q[m],
                                 $signed(e[31:16]), $signed(e[15:0]));
                end
            end
            if (trig) n_smp = n_smp + LANES;
            trig_q = trig;
        end
    end

    // ------------------------------------ waveform helpers (serialised view)
    logic signed [15:0] i_ser = 0, q_ser = 0;
    real f_inst_mhz = 0.0;
    real prev_ph = 0.0, ph = 0.0, d = 0.0;
    always @(posedge dclk) begin
        #2;
        for (int m = 0; m < LANES; m++) begin
            i_ser = lane_i[m];
            q_ser = lane_q[m];
            if (i_ser != 0 || q_ser != 0) begin
                ph = $atan2($itor(q_ser), $itor(i_ser));
                d  = ph - prev_ph;
                if (d >  3.14159265358979) d = d - 6.28318530717959;
                if (d < -3.14159265358979) d = d + 6.28318530717959;
                f_inst_mhz = d / 6.28318530717959 * FS_BB / 1.0e6;
                prev_ph = ph;
            end else begin
                f_inst_mhz = 0.0;
            end
            #(T_DCLK/LANES - 1);
        end
    end

`ifdef DUMP_FILES
    task automatic capture(input string fname, input int nclk);
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
    task automatic capture(input string fname, input int nclk);
        repeat (nclk) @(posedge dclk);
    endtask
`endif

    // ------------------------------------------------------------ tests
    logic [31:0] v;
    int errors = 0, g0;

    initial begin
        repeat (10) @(posedge aclk);
        @(negedge aclk); aresetn = 1;
        repeat (5) @(posedge dclk);
        @(negedge dclk); drst_n = 1;
        repeat (5) @(posedge aclk);

        // T0: register access
        axi_read(16'h00, v);
        if (v !== 32'h43485250) begin $display("FAIL T0: ID = %h", v); errors++; end
        else $display("PASS T0: ID register = %h (CHRP)", v);
        axi_read(16'h24, v);
        if (v[0] !== 1'b1) begin $display("FAIL T0: STATUS ready bit = %b", v[0]); errors++; end
        else $display("PASS T0: DAC clock domain reported ready");

        // T1: CW +10 MHz, full scale
        $display("T1: CW +10 MHz, full scale, split packing");
        setup_gen(1, 1, 0, 0, 10.0e6, 0, 100, 1000, 1.0, 0.0);
        repeat (20) @(posedge dclk);
        capture("out/cw_split.txt", 4096);
        gen_off();

        // T2: pulsed up-chirp -200 -> +200 MHz, PW 368 clk (2.0 us), PRI 500 clk (2.7 us)
        $display("T2: pulsed LFM -200 -> +200 MHz, PW 2.0 us, PRI 2.7 us");
        setup_gen(1, 0, 0, 0, -200.0e6, krate_for(400.0e6, 368), 368, 500, 1.0, 0.0);
        capture("out/chirp_split.txt", 1200);
        repeat (400) @(posedge dclk);
        gen_off();

        // T3: down-chirp +150 -> -50 MHz, half amplitude, 90 deg start phase, short PRI
        $display("T3: pulsed LFM +150 -> -50 MHz, amp 0.5, phase 90 deg, PW 100 clk, PRI 150 clk");
        setup_gen(1, 0, 0, 0, 150.0e6, krate_for(-200.0e6, 100), 100, 150, 0.5, 90.0);
        repeat (700) @(posedge dclk);
        gen_off();

        // T4: CW -200 MHz with interleaved packing and I/Q swap
        $display("T4: CW -200 MHz, interleaved packing + I/Q swap");
        setup_gen(1, 1, 1, 1, -200.0e6, 0, 100, 1000, 1.0, 0.0);
        repeat (20) @(posedge dclk);
        capture("out/cw_ilv_swap.txt", 1024);
        gen_off();

        // T5: disabled -> zeros (checked by the scoreboard)
        $display("T5: output disabled");
        g0 = gated;
        repeat (200) @(posedge dclk);
        if (gated != g0) begin $display("FAIL T5: trig_out active while disabled"); errors++; end

        // T6: actual RFDC hardware format: interleaved I0,Q0,...,I3,Q3.
        $display("T6: pulsed LFM in RFDC interleaved format");
        setup_gen(1, 0, 0, 1, -200.0e6, krate_for(400.0e6, 368), 368, 1843, 0.5, 0.0);
        capture("out/chirp_interleaved.txt", 4096);
        gen_off();

        // summary
        $display("--------------------------------------------------------------");
        $display("Scoreboard: %0d samples checked (%0d inside pulses), %0d mismatches",
                 checked, gated, mism);
        if (mism != 0 || gated < 10000) errors++;
        if (errors == 0) $display("*** TEST PASSED ***");
        else             $fatal(1, "*** TEST FAILED (%0d errors) ***", errors);
        $display("--------------------------------------------------------------");
        $finish;
    end

    // safety net
    initial begin
        #(64'd20_000_000_000);   // 20 ms
        $fatal(1, "*** TEST FAILED: timeout ***");
    end
endmodule

