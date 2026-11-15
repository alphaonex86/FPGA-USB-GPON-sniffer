# SPDX-License-Identifier: CERN-OHL-S-2.0
# inline_artix7: the transceiver sites (the board follows them) and the clock relations; the cores bring the
# periods of their own output clocks.
# Lane 0 = downstream (RX B8/A8, TX B4/A4), lane 1 = upstream (RX D11/C11, TX D5/C5), oscillator on MGTREFCLK0 (F6/E6).
set_property LOC GTPE2_CHANNEL_X0Y0 [get_cells -hier -filter {NAME =~ ds/*gtpe2_i}]
set_property LOC GTPE2_CHANNEL_X0Y1 [get_cells -hier -filter {NAME =~ us/*gtpe2_i}]
set_property LOC IBUFDS_GTE2_X0Y0 [get_cells refbuf]
create_clock -name refclk -period 6.430 [get_ports REFCLK_P]
# Lane 2 = USB 3 (RX B10/A10, TX B6/A6) on PLL1, its 125 MHz oscillator on MGTREFCLK1 (F10/E10); the lane's 250 MHz
# word clock is LUNA's PIPE clock
set_property LOC GTPE2_CHANNEL_X0Y2 [get_cells -hier -filter {REF_NAME == GTPE2_CHANNEL && NAME =~ usb3/*}]
set_property LOC IBUFDS_GTE2_X0Y1 [get_cells usbrefbuf]
create_clock -name usbref -period 8.000 [get_ports USB_REFCLK_P]
create_clock -name sspipe -period 4.000 [get_pins -hier -filter {NAME =~ usb3/*/TXOUTCLK}]
create_clock -name ulpi -period 16.667 [get_ports ULPI_CLK]
# every crossing goes through a synchroniser or a dual-clock queue (the dump's clock too, although made from ds TXOUTCLK)
set_clock_groups -asynchronous -group refclk \
  -group [get_clocks -of_objects [get_pins -hier -filter {NAME =~ ds/*gtpe2_i/TXOUTCLK}]] \
  -group [get_clocks -of_objects [get_pins -hier -filter {NAME =~ ds/*gtpe2_i/RXOUTCLK}]] \
  -group [get_clocks -include_generated_clocks -of_objects [get_pins -hier -filter {NAME =~ us/*gtpe2_i/TXOUTCLK}]] \
  -group [get_clocks -of_objects [get_pins outpll/CLKOUT0]] \
  -group [get_clocks -include_generated_clocks ulpi] \
  -group usbref -group sspipe
# ULPI (USB3320, output clock mode, its Table 4-3): its outputs change 1.0 to 3.5 ns after CLKOUT, its inputs want
# 5.0 ns of setup and no hold; + 0.2 ns of board trace each way (the max only). LUNA turns the bus around in the
# same cycle (DIR to D, port to port): fast pads.
set_input_delay -clock ulpi -max 3.7 [get_ports {ULPI_D[*] ULPI_DIR ULPI_NXT}]
set_input_delay -clock ulpi -min 1.0 [get_ports {ULPI_D[*] ULPI_DIR ULPI_NXT}]
set_output_delay -clock ulpi -max 5.2 [get_ports {ULPI_D[*] ULPI_STP}]
set_output_delay -clock ulpi -min 0.0 [get_ports {ULPI_D[*] ULPI_STP}]
set_property SLEW FAST [get_ports {ULPI_D[*] ULPI_STP}]
set_false_path -to [get_ports {ULPI_RST_N ULPI_REFCLK}]
# bank 0 at 3.3 V, the bitstream from the SPI flash (W25Q32, one data line)
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 1 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 33 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
