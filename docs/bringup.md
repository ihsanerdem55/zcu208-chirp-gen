# ZCU208 chirp generator: hardware bring-up guide

This is the procedure for the first power-on of the design on a ZCU208. It
takes you from a fresh build to a verified pulsed chirp on the RF-DAC output.
Every step ends with a **pass check**. Do not move on until it passes; the
[troubleshooting table](#troubleshooting) maps each failure message to a cause.

The design has passed RTL simulation only. No bitstream from it has yet been
run on a board, so treat each step as a test and record what you see.

What the design does: DAC tile 228 / channel 0, 245.76 MHz CLK104 reference,
on-tile PLL, 5.89824 GSPS, 4x interpolation, fine-mixer NCO. Samples go in at
1474.56 MSPS complex (eight samples per 184.32 MHz fabric clock, 256 bits), so
a chirp or noise band can be up to ~1.18 GHz wide around the NCO. Control is
over JTAG-to-AXI from the Vivado Tcl console; no Vitis or PetaLinux is needed.

## 0. What you need

**Hardware**

- ZCU208 (production), CLK104 clock card fitted, XM655 breakout and its cables.
- Spectrum analyzer covering at least 10 MHz to 1 GHz. An oscilloscope is optional.
- 50-ohm attenuator(s) that keep the DAC output within your instrument's input limit.
- The board's USB JTAG cable, and normal cooling (fan running).

**Software**

- Vivado 2022.2 or newer with the **production** ZCU208 board files
  (Tools > Vivado Store > Boards).
- A tool to program the CLK104: BoardUI / System Controller. This repository
  does not program it.
- Python 3 with `python -m pip install -r sim/requirements.txt`, for the ILA plots.
- This repository at `main`.

## 1. Run the host regressions

This confirms your checkout is intact before you spend an hour building.
It needs Icarus Verilog 12+, Tcl 8.5+ and the Python packages above.

```sh
bash sim/run_iverilog.sh
```

**Pass:** the script runs to the end, which it only does if every stage passed,
and prints `OK` last. Along the way you should see `*** TEST PASSED ***` with
`0 mismatches`, `*** NOISE TEST PASSED ***` and `SUMMARY: 14/14 checks passed`.

## 2. Build the bitstream

In the Vivado Tcl console:

```tcl
cd <path-to>/zcu208-chirp-gen
source tcl/build_bd.tcl
```

The script creates `vivado/zcu208_chirp`, builds the block design and stops
with an error if anything required is missing. That includes a broken
chirp→RFDC stream connection or wrong ILA probe widths. The Messages window
must not show [BD 41-1271] (pin detached from an interface), [BD 41-759]
(inputs tied to 0) or [BD 41-2383] (width mismatch). [BD 41-926] about
`TDATA_NUM_BYTES = 32` on `chirp_gen_0/m_axis` can appear and is harmless:
both ends agree on 32 bytes. Then open the **rfdc** block
once, confirm these settings, and close it with **Cancel** so nothing changes:

| Setting | Expected |
|---|---|
| Enabled converters | DAC tile 228, channel 0 only; no ADCs |
| Clock | PLL on, reference 245.76 MHz, source tile 228, no distribution |
| Sampling rate | 5.89824 GSPS |
| Interpolation | 4x |
| Mixer | Fine, I/Q to Real, Nyquist zone 1, inverse sinc on |
| AXI4-Stream | 256-bit (16 words = 8 complex samples, I/Q interleaved) at 184.32 MHz; the script checks both |
| Datapath | Full-bandwidth DUC (not IMR) |
| Multi-tile sync | Off |

Generate the bitstream (Flow Navigator > Generate Bitstream), or:

```tcl
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
```

**Pass:** the run completes and `vivado/zcu208_chirp/zcu208_chirp.runs/impl_1/`
contains `chirp_bd_wrapper.bit` plus the matching `.ltx` probes file. The
implementation log shows `INFO: dbg_hub uses independent 100 MHz AXI clock`.

## 3. Check the implementation reports

```tcl
open_run impl_1
file mkdir out
report_timing_summary -file out/timing.rpt
report_cdc            -file out/cdc.rpt
report_bus_skew       -file out/bus_skew.rpt
report_methodology    -file out/methodology.rpt
report_drc            -file out/drc.rpt
```

**Pass:**

- Timing reports "All user specified timing constraints are met".
- In `report_clock_interaction`, the rows between `clk_out1_chirp_bd_clk_wiz_axi_0`
  and `clk_out1_chirp_bd_clk_wiz_dac_0` show 0 failing endpoints. The
  [Timing 38-127] "No common period" warnings for that pair are expected.
- The implementation log has no critical warning that a `chirp_timing.xdc`
  query found no objects.
- No DRC errors.
- In the CDC report, every crossing is either constrained or one of the
  intended ones: the first stage of `req_sync`, `ack_sync`, `rdy_sync`,
  `hb_sync` and `lock_sync`, the bundled parameter bus (bounded to 5.425 ns),
  and the reset IPs' own synchronizers.
- `trig_out` (scope marker) and `cpu_reset` (push-button) are intentionally
  false-pathed. No other port or internal path is unconstrained.

Investigate any other unsafe crossing or unconstrained internal path before
you power RF.

## 4. Set up the board (power off)

1. Fit the CLK104 and the XM655 as described in UG1410.
2. Connect the XM655 output for **DAC tile 228, channel 0** to the attenuator,
   then to the spectrum analyzer. The 500 MHz examples below assume a balun
   path covering roughly 10 MHz to 1 GHz; confirm the one you use.
3. Optional: put a scope probe on the LED side of user LED0's level shifter.
   The design drives its pulse marker (`trig_out`) on LED0 (FPGA pin AR19).
4. Recommended: set the boot mode to JTAG (switch settings in UG1410), so an
   SD-card image does not load its own bitstream.
5. Connect the USB JTAG cable and power on.

**Pass:** the board powers up normally and the fan runs.

## 5. Program the CLK104 reference

The chirp design has no processor, so nothing programs the CLK104 after
power-up. Without it, DAC tile 228 stops at state 6. Use one of:

- **Vitis (recommended):** run the small bare-metal program in
  [`sw/clk104_init`](../sw/clk104_init/README.md). It writes AMD's 245.76 MHz
  LMK04828 configuration over the PS I2C1 bus and works whichever bitstream is
  loaded. The README covers the one-time Vitis setup.
- **BoardUI / System Controller:** load a CLK104 profile with the 245.76 MHz
  DAC reference enabled. Check the output's frequency and enable state, not
  just the profile's name.

The CLK104 keeps its setting until power-off. If you program it after the
bitstream, run `rfdc_restart` in step 7.

## 6. Program the FPGA

1. Open Hardware Manager, then Open Target > Auto Connect.
2. Set the JTAG frequency to 10 MHz or lower.
3. Program Device with the `.bit` **and** the matching `.ltx` from step 2.
4. Refresh Device.

**Pass:** the hardware tree shows the JTAG-to-AXI master (`hw_axi_1`) and one
ILA whose cell name contains `ila_dac`. If Vivado warns that the ILA clock is
not running, the DAC fabric clock is missing; step 7 diagnoses it.

## 7. Connect the control scripts and check the clocks

In the Hardware Manager Tcl console:

```tcl
cd <path-to>/zcu208-chirp-gen
source tcl/chirp_ctrl.tcl
hw_init
rfdc_status
clock_check
```

**Pass:** all of these appear:

```text
Using hw_axi_1
chirp_gen found (ID CHRP)
DAC tile 228: state 15 (15 = running), power-up 1, PLL locked 1
chirp_gen: DAC MMCM locked 1, handshake ready 1, apply pending 0
DAC ch0: interpolation 4x, I/Q input 1, datapath mode 0, fabric words <N> (expected 16)
DAC fabric heartbeat is changing
```

Write down `<N>`: the fabric-word read-back has not yet been checked on silicon.
For this build it should be 16 (eight I/Q pairs per clock).

If the tile is not at state 15, fix the CLK104 profile (step 5), then run:

```tcl
rfdc_restart
```

This silences the generator, restarts the tile, waits for state 15, checks
the heartbeat and leaves the output off. The fabric-clock MMCM relocks by
itself: while unlocked, the hardware resets it every ~2.6 ms.

## 8. First RF: low-amplitude CW tone

Start small. The digital amplitude is a fraction of full scale, not a
calibrated power.

```tcl
nco_set 500e6          ;# prints: NCO = 500.000000 MHz
cw 10e6 0.1            ;# prints: CW at NCO +10.000000 MHz, amplitude 0.100
```

**Pass on the analyzer:** a single tone at about **510 MHz**, with the mirror
at 490 MHz well below it. A dominant tone at 490 MHz instead means I and Q are
swapped: run `iq_options 1 1`, repeat `cw 10e6 0.1`, and note it.

Check the digital samples with the ILA:

```tcl
source tcl/ila_capture.tcl
ila_capture out/cw.csv immediate
```

Then, from a shell in the repository root:

```sh
python scripts/plot_ila.py out/cw.csv
```

**Pass in `out/cw.png`:** steady I/Q sinusoids with peak about ±3277
(0.1 x 32767), and a flat +10 MHz line in the frequency panel. The ILA shows
the digital input to the RFDC, not the analog output.

## 9. Pulsed chirp

```tcl
chirp -bw 400e6 -pw 2e-6 -pri 10e-6 -amp 0.1
```

It prints
`LFM 400.000 MHz in 2.002 us (slope 199.8049 MHz/us), PRI 9.999 us, NCO -200.0..+200.0 MHz`.
The timings are rounded to whole fabric clocks: 369 clocks of pulse and 1843
clocks of PRI.

Capture and plot one pulse:

```tcl
ila_capture out/chirp.csv          ;# triggers on the next pulse rising edge
```

```sh
python scripts/plot_ila.py out/chirp.csv
```

**Pass:**

- In `out/chirp.png`, each pulse ramps linearly from −200 to +200 MHz over
  about 2 µs, with zero samples between pulses. The 4096-clock ILA window
  (22.2 µs, 32768 samples) holds two full pulses.
- The analyzer (max hold) shows energy across about 300–700 MHz.
- On the scope, if fitted, LED0 shows 2 µs pulses every 10 µs. The marker is
  digital: it does not include the DAC's analog latency.

Raise `-amp` in steps only after the analog chain is known to be safe for it.

### Wideband chirp (up to ~1.18 GHz)

The 4x build passes about ±590 MHz around the NCO. Put the NCO where the whole
RF band fits both the first Nyquist zone (0 to 2949 MHz) and your output path:
the XM655 balun used for the 500 MHz examples covers roughly 10 MHz to 1 GHz,
so a 1 GHz sweep needs a wider path (or a band at a higher NCO with a matching
balun). `cw`, `chirp` and `noise` print a warning when the band crosses 0 Hz or
2949 MHz at the current NCO.

```tcl
nco_set 1.5e9
chirp -bw 1e9 -pw 2e-6 -pri 10e-6 -amp 0.1   ;# RF 1.0 .. 2.0 GHz
```

**Pass:** `out/chirp.png` ramps from −500 to +500 MHz; the spectrum panel is
flat across ±500 MHz.

## Band-limited noise

`noise` is a separate signal mode for filling a chosen bandwidth with
pseudo-random samples (receiver sensitivity/BER tests, noise-figure and
calibration measurements, channel emulation). It uses the same DAC datapath as
the chirp, so `nco_set` sets the RF centre and `-amp` the level; `gen_off` stops
it; `cw`/`chirp` switch back.

```tcl
nco_set 500e6
noise -bw 200e6 -amp 0.1                       ;# continuous, ~400..600 MHz
# noise -bw 100e6 -amp 0.1 -pw 2e-6 -pri 10e-6 ;# pulsed noise, 2 us every 10 us
# noise -bw 200e6 -amp 0.1 -seed 7             ;# another noise realisation
```

How it works: a fresh random complex value is drawn every `D = fs_bb/bw` samples
and held in between (sample-and-hold), so the baseband band is about ±`bw`/2 wide
(−3 dB) with a sinc² envelope whose first nulls sit at ±`bw` and −13 dB shoulders
beyond. Widen or narrow `-bw` to taste; the RFDC interpolation filter passes
roughly ±0.4·fs_bb (±590 MHz), so bandwidths up to ~1.18 GHz are usable.

Each `noise` command restarts the pseudo-random sequence from its seed, so the
same command always produces the same samples, whatever ran before. `-seed`
(0 to 2³²−1, default 0) selects another, equally valid realisation, for
example to compare runs with uncorrelated noise.

**Pass on the analyzer:** a raised noise floor spread across about `bw` around the
centre (≈500 MHz), symmetric, dropping back to the floor outside it. Use
**Trace → Average** to see the band shape. The amplitude is a digital fraction,
not a calibrated power; raise `-amp` only once the analog chain is known safe.

Capture and plot as for the chirp:

```tcl
ila_capture out/noise.csv immediate
```

```sh
python scripts/plot_ila.py out/noise.csv
```

The bottom **Spectrum (dB)** panel of `out/noise.png` (an averaged spectrum)
shows the band centred at 0 (the NCO) with the sinc² shape and nulls at ±`bw`;
the instantaneous-frequency panel is noisy by nature and not meaningful here.

## 10. Check recovery once

With a tone running (`cw 10e6 0.1`):

```tcl
rfdc_restart
rfdc_status
cw 10e6 0.1
```

**Pass:** the tone disappears during the restart and stays off afterwards.
`rfdc_status` shows `DAC MMCM locked 1` and `handshake ready 1`, and `cw`
brings the tone back, all without reprogramming. This confirms the MMCM reset
supervision on real hardware.

## 11. Switch off

```tcl
gen_off                ;# prints: output off
```

`gen_off` confirms silence only when the DAC domain acknowledges it or is
held in reset. If it times out, the fabric clock is stopped and silence is
**not** confirmed.

Pressing CPU_RESET resets the control logic and the DAC domain, which turns
the generator off. None of these controls is an analog emergency shutdown:
to remove RF for certain, disconnect it or power the board down.

## Troubleshooting

| Symptom or message | Likely cause | What to do |
|---|---|---|
| `No JTAG-to-AXI master found` | Not programmed, or no `.ltx` loaded | Program with the matching `.bit` and `.ltx`, then Refresh Device. |
| `JTAG-to-AXI ... failed` on every access | The AXI clock or reset is not running. It comes from `USER_SI570_C0`, which must be 300 MHz. Or the JTAG link is unstable. | Check the Si570 frequency in BoardUI. Lower the JTAG clock. Run `reset_hw_axi [get_hw_axis]`, then `hw_init`. |
| `chirp_gen ID = 0x..., expected 0x43485250` | Wrong bitstream, or a changed address map | Rebuild from `main`, and reprogram with the matching files. |
| `state` below 15 (often 6), `PLL locked 0` | No 245.76 MHz reference on tile 228 | Program the CLK104 exactly as for a previously working DAC-228 design (245.76 MHz reference), then run `rfdc_restart`. A DAC-228 sine design with this clocking (source Tile228, no distribution) has run on the target board, so a persistent failure points to the CLK104 setup or cabling. |
| State 15, but `DAC MMCM locked 0` | The fabric clock from `clk_dac0` is wrong, or the MMCM cannot lock | Hardware retries every ~2.6 ms. If it stays unlocked, check the RFDC output-clock and fabric-clock settings (184.32 MHz). |
| `No DAC fabric heartbeat (MMCM locked X)` | No DAC fabric clock | See the two rows above. The ILA cannot capture without this clock either. |
| `DAC handshake not ready (DAC domain in reset...)` | The DAC side is held in reset: MMCM unlocked, or CPU_RESET held | Get the MMCM locked. Recovery takes microseconds once the clock is stable. |
| `APPLY still pending...` | The DAC clock stopped with a request in flight | Do not re-issue APPLY. Restore the clock (`rfdc_restart`) or reprogram. |
| `DAC tile 228 ch0 does not match this script` | The RFDC IP is configured differently from the frequency math | Fix the IP to match the step 2 table, then rebuild. Use `set ::RFDC_CONFIG_CHECK 0` only to diagnose the read-back. |
| Tone at 490 MHz, not 510 MHz | I/Q sideband convention inverted | `iq_options 1 1`, then re-run the command. |
| ILA samples correct but no RF | Analog path | Check the XM655 channel, balun band, cables and attenuation, that `nco_set` was run, and the analyzer settings. |
| `Expected one ila_dac` | `.ltx` missing or mismatched | Load the `.ltx` from the same build, then Refresh Device. |
| `plot_ila.py`: `DAC not streaming (TREADY/TVALID low)` | Captured before the RFDC accepted data | Capture again after `rfdc_status` shows state 15. |
| Implementation: a critical warning that a `chirp_timing.xdc` constraint matched no objects, or `Expected one independent 100 MHz AXI clock net` | Synthesis renamed cells or nets that the CDC constraints and debug-hub hook look up | Find the real names with `get_cells`/`get_nets` and update the patterns. Never delete these constraints. |
| Negative WNS only on `*_sync_reg[0]/D` endpoints between the AXI and DAC clocks | The synchronizer exceptions in `chirp_timing.xdc` were not applied | Check that the file is in the implementation constraint set, and look for the critical warning above. |

## Reference

**STATUS register (0x24)**

| Bit | Meaning |
|---|---|
| 0 | DAC handshake ready |
| 1 | APPLY pending |
| 2 | DAC-clock heartbeat (toggles every ~45 ms) |
| 3 | DAC fabric-clock MMCM locked |

**Commands** (`tcl/chirp_ctrl.tcl`, `tcl/ila_capture.tcl`)

| Command | Purpose |
|---|---|
| `hw_init` | Find the JTAG-to-AXI master and check the design ID |
| `rfdc_status` | Tile state, MMCM and handshake state, RFDC configuration read-back |
| `clock_check` | Confirm the DAC fabric clock is running |
| `rfdc_restart` | Restart tile 228 with the output silenced |
| `nco_set <Hz>` | Set the fine-mixer NCO (the RF centre frequency) |
| `cw <offset Hz> <amp 0..1>` | Continuous tone at NCO + offset |
| `chirp ?-bw Hz? ?-pw s? ?-pri s? ?-offset Hz? ?-amp 0..1? ?-phase_deg deg?` | Pulsed LFM around NCO + offset (negative `-bw` sweeps down) |
| `noise ?-bw Hz? ?-amp 0..1? ?-pw s? ?-pri s? ?-seed n?` | Band-limited noise around the NCO; `-pw 0` (default) is continuous |
| `iq_options <swap> <ilv>` | I/Q swap and packing, applied on the next `cw`/`chirp`/`noise` |
| `gen_off` | Disable the generator |
| `chirp_dump` | Print all generator registers |
| `ila_capture <csv> ?immediate?` | Capture 4096 clocks, by default on the next pulse |

Background and review history: [review_2026-09-29.md](review_2026-09-29.md),
[review_2026-10-01.md](review_2026-10-01.md) (4x interpolation).
Turkish guide: [bringup_tr.md](bringup_tr.md).
