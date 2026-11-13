# SPDX-License-Identifier: CERN-OHL-S-2.0
# inline_artix7: the transceiver sites (the board follows them) and the clock relations; the cores bring the
# periods of their own output clocks.
# Lane 0 = downstream (RX B8/A8, TX B4/A4), lane 1 = upstream (RX D11/C11, TX D5/C5), oscillator on MGTREFCLK0 (F6/E6).
set_property LOC GTPE2_CHANNEL_X0Y0 [get_cells -hier -filter {NAME =~ ds/*gtpe2_i}]
set_property LOC GTPE2_CHANNEL_X0Y1 [get_cells -hier -filter {NAME =~ us/*gtpe2_i}]
set_property LOC IBUFDS_GTE2_X0Y0 [get_cells refbuf]
create_clock -name refclk -period 6.430 [get_ports REFCLK_P]
# every crossing goes through a synchroniser or a dual-clock queue (the dump's clock too, although made from ds TXOUTCLK)
set_clock_groups -asynchronous -group refclk \
  -group [get_clocks -of_objects [get_pins -hier -filter {NAME =~ ds/*gtpe2_i/TXOUTCLK}]] \
  -group [get_clocks -of_objects [get_pins -hier -filter {NAME =~ ds/*gtpe2_i/RXOUTCLK}]] \
  -group [get_clocks -include_generated_clocks -of_objects [get_pins -hier -filter {NAME =~ us/*gtpe2_i/TXOUTCLK}]] \
  -group [get_clocks -of_objects [get_pins outpll/CLKOUT0]]
# bank 0 at 3.3 V, the bitstream from the SPI flash (W25Q32, one data line)
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 1 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 33 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
