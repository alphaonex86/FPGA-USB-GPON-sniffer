// SPDX-License-Identifier: CERN-OHL-S-2.0
// In-line sniffer ECP5 top: the DCU (gpon_dcu.v, both transmitters) and the pins around InlineSniffer.
// Lasers: DS_LASER_DIS, US_LASER_DIS and US_BEN have board pulls to "dark", so an unconfigured FPGA emits nothing.
module inline_ecp5 (
  input        REFCLK_P, REFCLK_N,
  input        DS_RX_P, DS_RX_N, US_RX_P, US_RX_N,
  output       DS_TX_P, DS_TX_N, US_TX_P, US_TX_N,
  input        DS_LOS,         // no light at the OLT port (its limiting amp)
  output       DS_LASER_DIS,   // downstream laser off
  output       US_LASER_DIS,   // upstream laser off
  output       US_BEN,         // upstream laser burst enable
  input        US_ABOVE,       // comparator: the upstream APD current is over the level DAC's
  output       VCXO_PWM,
  inout  [7:0] FT_D,           // FT2232H channel A, asynchronous 245 FIFO
  input        FT_RXF_N, FT_TXE_N,
  output       FT_RD_N, FT_WR_N,
  inout        SCL, SDA,       // level DAC/ADC
  output       LED_SYNC
);
  wire ref_clk, ds_clk, out_clk, ref_rst, ds_rst, out_rst, ds_ready;
  wire [19:0] ds_rx, us_rx, ds_tx, us_tx;
  gpon_dcu #(.US_TX(1)) dcu (
    .REFCLK_P(REFCLK_P), .REFCLK_N(REFCLK_N), .DS_RX_P(DS_RX_P), .DS_RX_N(DS_RX_N), .US_RX_P(US_RX_P), .US_RX_N(US_RX_N),
    .DS_TX_P(DS_TX_P), .DS_TX_N(DS_TX_N), .US_TX_P(US_TX_P), .US_TX_N(US_TX_N),
    .ds_tx(ds_tx), .us_tx(us_tx), .ds_rx(ds_rx), .us_rx(us_rx),
    .ref_clk(ref_clk), .ds_clk(ds_clk), .out_clk(out_clk), .fwd_clk(),
    .ref_rst(ref_rst), .ds_rst(ds_rst), .out_rst(out_rst), .ds_ready(ds_ready));

  wire ds_laser, us_laser, scl_low, sda_low, ft_drive;
  wire [1:0] us_ben;
  wire [7:0] ft_write;
  InlineSniffer sniffer (
    .clk(ref_clk), .reset(ref_rst), .ds_clk(ds_clk), .ds_reset(ds_rst), .out_clk(out_clk), .out_reset(out_rst),
    .io_dsRx(ds_rx), .io_usRx(us_rx), .io_dsSignal(!DS_LOS && ds_ready),
    .io_dsTx(ds_tx), .io_dsLaser(ds_laser), .io_usTx(us_tx), .io_usBen(us_ben), .io_usLaser(us_laser), .io_usAbove(US_ABOVE), .io_vcxo(VCXO_PWM),
    .io_link_rxfN(FT_RXF_N), .io_link_txeN(FT_TXE_N), .io_link_rdN(FT_RD_N), .io_link_wrN(FT_WR_N),
    .io_link_read(FT_D), .io_link_write(ft_write), .io_link_drive(ft_drive),
    .io_sclLow(scl_low), .io_sdaLow(sda_low), .io_scl(SCL), .io_sda(SDA), .io_synced(LED_SYNC));

  assign DS_LASER_DIS = !ds_laser;
  assign US_LASER_DIS = !us_laser;
  assign FT_D = ft_drive ? ft_write : 8'bz;
  assign SCL = scl_low ? 1'b0 : 1'bz;
  assign SDA = sda_low ? 1'b0 : 1'bz;
  // the first half of each word on the rising edge
  ODDRX1F ben (.D0(us_ben[1]), .D1(us_ben[0]), .SCLK(ref_clk), .RST(ref_rst), .Q(US_BEN));
endmodule
