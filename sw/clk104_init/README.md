# clk104_init: program the CLK104 from Vitis

The chirp design has no processor, so nothing programs the CLK104 after
power-up and DAC tile 228 stops at state 6 (no PLL reference). This small
bare-metal program writes AMD's 245.76 MHz LMK04828 configuration over the
PS I2C1 bus. It needs no programmable-logic support, so it works whichever
bitstream is loaded. The CLK104 keeps the setting until the board is powered off.

## One-time setup in Vitis (Unified IDE, 2023.2 or newer)

You need a ZCU208 **platform** whose processing system has I2C1 enabled. Any
platform built from a design that used the ZCU208 board preset qualifies,
for example the `zcu208_platform` from an earlier RFDC project.

1. **File → New Component → Application.**
2. Name it `clk104_init`, select the ZCU208 platform, and select the
   `standalone_psu_cortexa53_0` domain. Finish the wizard.
3. Copy `clk104_init.c` and `lmk04828_245m76.h` from this folder into the new
   component's `src` folder: right-click `src` → Import → Files, or copy them
   in Windows Explorer.
4. In the **FLOW** panel, select `clk104_init` as the component and click **Build**.

## Every power-up

1. Board in JTAG boot mode, USB JTAG connected, power on.
2. Vitis: FLOW → component `clk104_init` → **Run**. The launch loads the
   platform's bitstream, initializes the processing system and runs the
   program. With a serial terminal open (USB-UART, 115200 baud) you see:
   ```
   clk104_init: LMK04828 245.76 MHz reference
   clk104_init: done, 128 registers written. Now load the chirp design and run rfdc_restart.
   ```
3. **Keep the board powered.** In Vivado Hardware Manager, program the chirp
   design's `.bit` and `.ltx`, then in the Tcl console:
   ```tcl
   source <repo>/tcl/chirp_ctrl.tcl
   hw_init
   rfdc_restart
   rfdc_status      ;# expect state 15, PLL locked 1, DAC MMCM locked 1
   ```

## If it fails

| Message | Cause |
|---|---|
| `ERROR: PS I2C1 is not available in this platform` (or a build error about `XIicPs`) | The platform's processing system has no I2C1. Use a platform made with the ZCU208 board preset. |
| `ERROR: no answer from the CLK104 I2C-to-SPI bridge` | The CLK104 is not fitted or not seated, or the I2C bus is held by another master. Power-cycle and try again. |
| Program runs, but `rfdc_status` still shows state 6 | Check the CLK104 seating and that the board was not power-cycled between the two steps. |

## How it works

This follows AMD's `xrfclk` driver for ZCU216/ZCU208 (embeddedsw,
`XilinxProcessorIPLib/drivers/board_common/src/rfclk`):
PS I2C1 → I2C switch `0x74` (channel 5) → I2C-to-SPI bridge `0x2F`
(configured with `F0 03`) → slave select `0x02` → LMK04828. Each of the 128
words becomes one bridge write `{02, reg[23:16], reg[15:8], reg[7:0]}`. The
switch channel is selected before every write and checked afterwards, because
other masters share the bus. AMD's driver also uses a PL GPIO, but only to read
registers back; this program only writes, so it doesn't need one. The
register table is AMD's `LMK_CKin[0]` (`245M76_PL_122M88_SYSREF_7M68`),
MIT-licensed.
