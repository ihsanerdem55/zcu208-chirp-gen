/*
 * clk104_init.c -- program the CLK104 LMK04828 for the chirp generator.
 *
 * Bare-metal application for the ZCU208 Cortex-A53 (standalone domain). It
 * writes the 245.76 MHz LMK04828 configuration, which gives DAC tile 228 its
 * PLL reference, then halts. It uses only the PS I2C1 controller, so it works
 * with any bitstream loaded, including the JTAG-controlled chirp design.
 *
 * Path (same as AMD's xrfclk driver for ZCU216/ZCU208):
 *   PS I2C1 -> I2C switch 0x74 (channel 5) -> I2C-to-SPI bridge 0x2F
 *   -> SPI slave select 1 -> LMK04828
 * Each bridge write is { slave-select mask, reg[23:16], reg[15:8], reg[7:0] }.
 * Register readback needs a GPIO-controlled SDO multiplexer in the PL; writes
 * do not, so this program never reads the clock chips.
 */
#include "xiicps.h"
#include "xil_printf.h"
#include "xstatus.h"
#include "sleep.h"
#include "lmk04828_245m76.h"

#define I2C1_BASEADDR        0xFF030000U  /* Zynq UltraScale+ PS I2C1 */
#define I2C_SCLK_HZ          100000U
#define I2C_ADDR_SWITCH      0x74U        /* I2C bus switch */
#define SWITCH_SEL_BRIDGE    (1U << 5)    /* channel to the I2C-to-SPI bridge */
#define I2C_ADDR_BRIDGE      0x2FU        /* I2C-to-SPI bridge on the CLK104 */
#define BRIDGE_CFG_FUNC      0xF0U        /* bridge "configure SPI" function */
#define BRIDGE_CFG_VALUE     0x03U        /* SPI settings used by AMD's xrfclk */
#define SS_LMK04828          0x02U        /* slave select for the LMK04828 */
#define I2C_SETTLE_US        1000U
#define I2C_RETRIES          5

static XIicPs iic;

static XIicPs_Config *lookup_i2c1(void)
{
#ifdef SDT
    return XIicPs_LookupConfig(I2C1_BASEADDR);
#else
    for (u16 id = 0; id < XPAR_XIICPS_NUM_INSTANCES; id++) {
        XIicPs_Config *cfg = XIicPs_LookupConfig(id);
        if (cfg != NULL && cfg->BaseAddress == I2C1_BASEADDR) {
            return cfg;
        }
    }
    return NULL;
#endif
}

static int i2c_send(u8 addr, u8 *buf, s32 len)
{
    if (XIicPs_MasterSendPolled(&iic, buf, len, addr) != XST_SUCCESS) {
        return XST_FAILURE;
    }
    while (XIicPs_BusIsBusy(&iic)) {
    }
    usleep(I2C_SETTLE_US);
    return XST_SUCCESS;
}

static int i2c_recv(u8 addr, u8 *buf, s32 len)
{
    if (XIicPs_MasterRecvPolled(&iic, buf, len, addr) != XST_SUCCESS) {
        return XST_FAILURE;
    }
    while (XIicPs_BusIsBusy(&iic)) {
    }
    usleep(I2C_SETTLE_US);
    return XST_SUCCESS;
}

/* The I2C1 switch is shared with other bus masters on the board, so select
 * the bridge channel before every transfer and confirm it stayed selected. */
static int bridge_write(u8 *buf, s32 len)
{
    for (int i = 0; i < I2C_RETRIES; i++) {
        u8 sel = SWITCH_SEL_BRIDGE;
        u8 now = 0;
        if (i2c_send(I2C_ADDR_SWITCH, &sel, 1) != XST_SUCCESS) {
            continue;
        }
        if (i2c_send(I2C_ADDR_BRIDGE, buf, len) != XST_SUCCESS) {
            continue;
        }
        if (i2c_recv(I2C_ADDR_SWITCH, &now, 1) != XST_SUCCESS) {
            continue;
        }
        if (now == SWITCH_SEL_BRIDGE) {
            return XST_SUCCESS;
        }
        usleep(100U * (u32)(i + 1));
    }
    return XST_FAILURE;
}

int main(void)
{
    xil_printf("\r\nclk104_init: LMK04828 245.76 MHz reference\r\n");

    XIicPs_Config *cfg = lookup_i2c1();
    if (cfg == NULL ||
        XIicPs_CfgInitialize(&iic, cfg, cfg->BaseAddress) != XST_SUCCESS ||
        XIicPs_SetSClk(&iic, I2C_SCLK_HZ) != XST_SUCCESS) {
        xil_printf("ERROR: PS I2C1 is not available in this platform\r\n");
        return XST_FAILURE;
    }

    u8 spi_cfg[2] = { BRIDGE_CFG_FUNC, BRIDGE_CFG_VALUE };
    if (bridge_write(spi_cfg, 2) != XST_SUCCESS) {
        xil_printf("ERROR: no answer from the CLK104 I2C-to-SPI bridge\r\n");
        return XST_FAILURE;
    }

    for (u32 i = 0; i < LMK04828_245M76_COUNT; i++) {
        u32 w = lmk04828_245m76[i];
        u8 tx[4] = { SS_LMK04828, (u8)(w >> 16), (u8)(w >> 8), (u8)w };
        if (bridge_write(tx, 4) != XST_SUCCESS) {
            xil_printf("ERROR: LMK04828 write %d (0x%06x) failed\r\n", (int)i, w);
            return XST_FAILURE;
        }
    }

    xil_printf("clk104_init: done, %d registers written. "
               "Now load the chirp design and run rfdc_restart.\r\n",
               LMK04828_245M76_COUNT);
    return XST_SUCCESS;
}
