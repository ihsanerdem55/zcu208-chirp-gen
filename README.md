# ZCU208 pulsed LFM chirp generator

RF-DAC **tile 228 / channel 0**, CLK104 245.76 MHz reference, local RFDC PLL,
5.89824 GSPS, **4x interpolation**, eight complex samples per 184.32 MHz fabric
cycle (256-bit AXI4-Stream, 1474.56 MSPS complex). Chirps and noise can use
about ±590 MHz around the NCO, **~1.18 GHz of instantaneous bandwidth** (twice
the earlier 8x build). Vivado JTAG-to-AXI control; no Vitis/PetaLinux required.

**Clock correction:** CLK104's connector reference goes to DAC tile 228.
Tile 230 uses a separate external SMA clock path. The original tile-230 assumption
and default split-I/Q packing were incorrect for this setup.

**Status:** the 4x build has been implemented in Vivado and verified working on
a ZCU208 board. The reset/CDC fixes and bring-up checks are described in the
[29 September review](docs/review_2026-09-29.md) and the
[1 October review and 4x interpolation notes](docs/review_2026-10-01.md).
DAC-domain reset now leaves output disabled until a fresh APPLY; a tile restart
also leaves output off. The DAC fabric-clock MMCM is supervised from the
independent AXI clock: it is reset automatically until it relocks (late CLK104
profile, `rfdc_restart`), and the generator returns disabled after any clock loss.

## Build and run

**First time on a board? Follow the [step-by-step hardware bring-up guide](docs/bringup.md)**:
each step has a pass check, and there's a troubleshooting table. The summary below
assumes a board that has already been brought up.

Vivado 2022.2+ with production ZCU208 board files, from the repository root:

```tcl
source tcl/build_bd.tcl
```

Generate Bitstream, then program matching `.bit` and `.ltx` files. The ILA is
included by default. An implementation hook ties its debug hub to the independent
100 MHz AXI clock; its sample clock remains in the DAC domain.

Program the CLK104 for a **245.76 MHz DAC reference** after every power-up;
the design itself has no processor to do it. Use the bare-metal Vitis program
in [`sw/clk104_init`](sw/clk104_init/README.md), or a BoardUI profile. If you
program it after the bitstream, run `rfdc_restart`.

```tcl
source tcl/chirp_ctrl.tcl
hw_init
rfdc_status                 ;# tile 228: state 15, power-up 1, PLL locked 1, MMCM locked 1
                            ;# DAC ch0: interpolation 4x, I/Q input 1, datapath mode 0
clock_check                 ;# changing DAC fabric heartbeat
# rfdc_restart              ;# if clocks were configured after the bitstream
nco_set 500e6
cw 10e6 0.1                 ;# first check: ~510 MHz tone at low amplitude
chirp -bw 400e6 -pw 2e-6 -pri 10e-6 -amp 0.1
noise -bw 200e6 -amp 0.1   ;# band-limited noise, ~400..600 MHz, continuous
# Wideband: put the NCO where the whole band fits the output path
# nco_set 1.5e9; chirp -bw 1e9 -pw 2e-6 -pri 10e-6 -amp 0.1   ;# 1.0..2.0 GHz
source tcl/ila_capture.tcl
ila_capture out/chirp.csv
# gen_off
```

### Band-limited noise

`noise` fills a chosen bandwidth around the NCO with pseudo-random samples
(sample-and-hold, so the band has a sinc² envelope; set the NCO for the RF
centre and trim `-bw` against the analyzer):

```tcl
nco_set 500e6
noise -bw 200e6 -amp 0.1                 ;# continuous, ~400..600 MHz
noise -bw 100e6 -amp 0.1 -pw 2e-6 -pri 10e-6   ;# pulsed noise, 2 us every 10 us
noise -bw 200e6 -amp 0.1 -seed 7         ;# another, uncorrelated realisation
ila_capture out/noise.csv immediate      ;# then plot_ila shows the spectrum panel
```

It reuses the DAC datapath (amplitude, pulse gate, I/Q swap, packing), the
`KRATE` register as the bandwidth word and `PHASE0` as the seed. Bandwidths up
to ~1.18 GHz pass the RFDC interpolation filter. Every `noise` command restarts
the same sequence for its seed, whatever ran before. The noise is zero-mean and
never clips (about −17 dBFS RMS, −6 dBFS peaks at full `-amp`). See the
[noise notes](docs/bringup.md#band-limited-noise).

`cw`, `chirp` and `noise` warn when the RF band (NCO ± the baseband band) would
cross 0 Hz or the first Nyquist zone edge (2949 MHz) at the current NCO.

## View the chirp

The ILA samples registered copies of the stream (one DAC clock after the RFDC
input), so its probes never load the RFDC-facing flops. It contains the full
256-bit stream, pulse gate, TVALID/TREADY and sixteen 16-bit I/Q lane probes
(I0, Q0 … I7, Q7). View lanes as **Signed Decimal / Analog** in Vivado.
To reconstruct all eight samples per clock and plot the chirp correctly:

```sh
python -m pip install -r sim/requirements.txt
python scripts/plot_ila.py out/chirp.csv
```

This writes `out/chirp.png` with I/Q samples, pulse gate, instantaneous
**baseband** frequency and an averaged spectrum. ILA observes digital samples
before the RFDC; actual analog RF output requires a scope/analyzer or a
separate ADC loopback capture. Captures from an older 8x build need
`--lanes 4 --fs-bb 737.28e6`.

**[Türkçe kurulum, saat teşhisi ve ILA rehberi](docs/bringup_tr.md)** includes the
probe map, expected results, clock path, balun bandwidth and hardware checks.

## Tests

```sh
# Icarus Verilog 12+, Python with requirements above, Tcl 8.5+
bash sim/run_iverilog.sh
# Alternative: Verilator 5+ and a C++20 compiler
# bash sim/run_verilator.sh
```

The RTL testbench checks every sample against a bit-exact reference, including
1 GHz chirps, back-to-back pulses (PW = PRI) and reloads of a running output.
The noise testbench checks every gated sample against a sequential per-sample
model, plus bandwidth, amplitude, gating and reproducibility; the Python analysis
checks the noise spectrum against the documented sinc² band. A register
testbench covers CDC recovery and the DAC MMCM reset/lock supervision. Tcl tests
mock AXI accesses and RFDC read-back; Python tests check signed lane
reconstruction and invalid captures. For Vivado xsim use
`source tcl/sim_project.tcl` or `sim/run_xsim.bat` / `sim/run_xsim.sh`.

Vivado IP validation, synthesis/implementation timing and board measurements
remain required; host tests cannot validate the RFDC PLL or analog output.

## Verified RTL example

![Interleaved chirp RTL simulation](docs/chirp_interleaved_sim.png)

This plot comes from RTL simulation, not a ZCU208 hardware capture.

