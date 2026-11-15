// SPDX-License-Identifier: CERN-OHL-S-2.0
// In-line sniffer Artix-7 top: one GTP quad on a fixed 155.52 MHz oscillator (PLL0, 2488.32 MHz) around InlineSniffer.
// gt_ds: downstream both ways at 2488.32 Mb/s; its transmitter is pulled onto the received downstream by its phase
// interpolator (no VCXO), its TXOUTCLK is the DS-locked ref_clk. gt_us: upstream both ways at 4976.64 Mb/s, 4 samples
// per bit, receiver in lock-to-reference, on the oscillator's own us_clk. The two cores are made by build.tcl.
// Lasers: DS_LASER_DIS, US_LASER_DIS and US_BEN have board pulls to "dark", so an unconfigured FPGA emits nothing.
// USB: a USB3320 ULPI PHY in output clock mode (its 60 MHz CLKOUT is usb_clk; its 24 MHz reference from here, no
// crystal) under LUNA's serial device (usb_serial.v, made by build.sh): the host sees a /dev/ttyACM.
// USB 3: GTP lane 2 at 5 Gb/s on PLL1 (2.5 GHz from its own 125 MHz oscillator, which is also ss_clk) under LUNA's
// SuperSpeed device (usb3.v): a second, bulk IN only device beside the serial one, for the wide dump.
module inline_artix7 (
  input        REFCLK_P, REFCLK_N,
  input        USB_REFCLK_P, USB_REFCLK_N,   // 125 MHz
  input        SS_RX_P, SS_RX_N,
  output       SS_TX_P, SS_TX_N,
  input        DS_RX_P, DS_RX_N, US_RX_P, US_RX_N,
  output       DS_TX_P, DS_TX_N, US_TX_P, US_TX_N,
  input        DS_LOS,         // no light at the OLT port (its limiting amp)
  output       DS_LASER_DIS,   // downstream laser off
  output       US_LASER_DIS,   // upstream laser off
  output       US_BEN,         // upstream laser burst enable
  input        US_ABOVE,       // comparator: the upstream APD current is over the level DAC's
  input        BURST_CUT,      // the max-burst cutoff holds the upstream laser off
  output       APD_EN,         // both APD bias supplies on (pulled down: off while unconfigured)
  input        ULPI_CLK,       // USB3320 ULPI
  inout  [7:0] ULPI_D,
  input        ULPI_DIR, ULPI_NXT,
  output       ULPI_STP,
  output       ULPI_RST_N,     // RESETB: low until ULPI_REFCLK runs; no CLKOUT before it rises
  output       ULPI_REFCLK,    // 24 MHz (REFSEL = 111)
  inout        SCL, SDA,       // level DACs / ADC
  output       SCL2,           // the second DAC's clock (same address as the first)
  output       LED_SYNC
);
  wire refclk, sys_clk, ref_clk, ds_clk, us_clk, us_clk2x, out_clk;
  IBUFDS_GTE2 refbuf (.I(REFCLK_P), .IB(REFCLK_N), .CEB(1'b0), .O(refclk), .ODIV2());
  BUFG sysbuf (.I(refclk), .O(sys_clk));
  wire usb_refclk, ss_clk, ss_pll_clk, ss_pll_refclk, ss_pll_lock, ss_pll_reset;
  IBUFDS_GTE2 usbrefbuf (.I(USB_REFCLK_P), .IB(USB_REFCLK_N), .CEB(1'b0), .O(usb_refclk), .ODIV2());
  BUFG ssbufg (.I(usb_refclk), .O(ss_clk));

  // start, and the downstream receiver held in reset while its limiting amp sees no light
  reg [7:0] por = 0;
  reg [1:0] los = 2'b11;
  always @(posedge sys_clk) begin
    if (!(&por)) por <= por + 1'b1;
    los <= {los[0], DS_LOS};
  end
  wire start = !(&por);

  // no clock but the oscillator's: no lost-clock detector (PLL0LOCKDETCLK only drives it, UG482), the lock is enough
  wire pll_clk, pll_refclk, pll_lock, ds_pll_reset, us_pll_reset;
  GTPE2_COMMON #(
    .PLL0_FBDIV(4), .PLL0_FBDIV_45(4), .PLL0_REFCLK_DIV(1), .PLL1_FBDIV(4), .PLL1_FBDIV_45(5), .PLL1_REFCLK_DIV(1),
    .BIAS_CFG(64'h0000000000050001), .COMMON_CFG(32'h00000000), .PLL0_CFG(27'h01F03DC), .PLL0_DMON_CFG(1'b0),
    .PLL0_INIT_CFG(24'h00001E), .PLL0_LOCK_CFG(9'h1E8), .PLL1_CFG(27'h01F03DC), .PLL1_DMON_CFG(1'b0),
    .PLL1_INIT_CFG(24'h00001E), .PLL1_LOCK_CFG(9'h1E8), .PLL_CLKOUT_CFG(8'h00), .RSVD_ATTR0(16'h0000), .RSVD_ATTR1(16'h0000)
  ) common (
    .GTREFCLK0(refclk), .GTREFCLK1(usb_refclk), .GTEASTREFCLK0(1'b0), .GTEASTREFCLK1(1'b0), .GTWESTREFCLK0(1'b0), .GTWESTREFCLK1(1'b0),
    .GTGREFCLK0(1'b0), .GTGREFCLK1(1'b0),
    .PLL0OUTCLK(pll_clk), .PLL0OUTREFCLK(pll_refclk), .PLL0LOCK(pll_lock), .PLL0REFCLKLOST(), .PLL0FBCLKLOST(),
    .PLL0LOCKDETCLK(1'b0), .PLL0LOCKEN(1'b1), .PLL0PD(1'b0), .PLL0REFCLKSEL(3'b001), .PLL0RESET(ds_pll_reset || us_pll_reset),
    .PLL1OUTCLK(ss_pll_clk), .PLL1OUTREFCLK(ss_pll_refclk), .PLL1LOCK(ss_pll_lock), .PLL1REFCLKLOST(), .PLL1FBCLKLOST(),
    .PLL1LOCKDETCLK(1'b0), .PLL1LOCKEN(1'b1), .PLL1PD(1'b0), .PLL1REFCLKSEL(3'b010), .PLL1RESET(ss_pll_reset),
    .DRPADDR(8'd0), .DRPCLK(1'b0), .DRPDI(16'd0), .DRPDO(), .DRPEN(1'b0), .DRPRDY(), .DRPWE(1'b0),
    .BGRCALOVRDENB(1'b1), .BGBYPASSB(1'b1), .BGMONITORENB(1'b1), .BGPDB(1'b1), .BGRCALOVRD(5'b11111), .RCALENB(1'b1),
    .PLLRSVD1(16'd0), .PLLRSVD2(5'd0), .PMARSVD(8'd0), .PMARSVDOUT(), .DMONITOROUT(), .REFCLKOUTMONITOR0(), .REFCLKOUTMONITOR1());

  // downstream lane; one interpolator step (1/256 bit) per clock, its direction from the loop: +-195 ppm on the GTP
  // model (tb.v), where TXPIPPMSTEPSIZE[4] = 1 lowers the frequency
  wire [19:0] ds_rx, ds_tx;
  wire ds_txoutclk, ds_rxoutclk, ds_tx_done, ds_rx_done, tx_faster;
  gt_ds ds (
    .sysclk_in(sys_clk), .soft_reset_tx_in(start), .soft_reset_rx_in(start || los[1]), .dont_reset_on_data_error_in(1'b1),
    .gt0_tx_fsm_reset_done_out(ds_tx_done), .gt0_rx_fsm_reset_done_out(ds_rx_done), .gt0_data_valid_in(1'b1),
    .gt0_drpaddr_in(9'd0), .gt0_drpclk_in(sys_clk), .gt0_drpdi_in(16'd0), .gt0_drpen_in(1'b0), .gt0_drpwe_in(1'b0),
    .gt0_eyescanreset_in(1'b0), .gt0_eyescantrigger_in(1'b0), .gt0_rxuserrdy_in(1'b1), .gt0_txuserrdy_in(1'b1),
    .gt0_gtrxreset_in(1'b0), .gt0_gttxreset_in(1'b0), .gt0_rxlpmreset_in(1'b0), .gt0_rxlpmhfhold_in(1'b0), .gt0_rxlpmlfhold_in(1'b0),
    .gt0_gtprxp_in(DS_RX_P), .gt0_gtprxn_in(DS_RX_N), .gt0_rxdata_out(ds_rx), .gt0_rxoutclk_out(ds_rxoutclk),
    .gt0_rxusrclk_in(ds_clk), .gt0_rxusrclk2_in(ds_clk),
    .gt0_gtptxp_out(DS_TX_P), .gt0_gtptxn_out(DS_TX_N), .gt0_txdata_in(ds_tx), .gt0_txoutclk_out(ds_txoutclk),
    .gt0_txusrclk_in(ref_clk), .gt0_txusrclk2_in(ref_clk),
    .gt0_txpippmen_in(1'b1), .gt0_txpippmovrden_in(1'b0), .gt0_txpippmpd_in(1'b0), .gt0_txpippmsel_in(1'b1),
    .gt0_txpippmstepsize_in({!tx_faster, 4'b0001}),
    .gt0_pll0outclk_in(pll_clk), .gt0_pll0outrefclk_in(pll_refclk), .gt0_pll0lock_in(pll_lock), .gt0_pll0refclklost_in(1'b0),
    .gt0_pll0reset_out(ds_pll_reset), .gt0_pll1outclk_in(1'b0), .gt0_pll1outrefclk_in(1'b0));
  BUFG refbufg (.I(ds_txoutclk), .O(ref_clk));
  BUFG dsbufg (.I(ds_rxoutclk), .O(ds_clk));

  // upstream lane: 40-bit words at half its 248.832 MHz TXOUTCLK; equaliser loops held (bursts)
  wire [39:0] us_rx, us_tx;
  // (the transceivers' clock region has no PLL: TXOUTCLK reaches one through a global buffer)
  wire us_txoutclk, us_txclk, us_tx_done, us_rx_done, us_pll_fb, us_pll_lock, us_pll_rst, us_fast, us_slow;
  BUFG ustxbufg (.I(us_txoutclk), .O(us_txclk));
  PLLE2_BASE #(.CLKIN1_PERIOD(4.018), .CLKFBOUT_MULT(4), .CLKOUT0_DIVIDE(4), .CLKOUT1_DIVIDE(8))
    uspll (.CLKIN1(us_txclk), .CLKFBIN(us_pll_fb), .CLKFBOUT(us_pll_fb), .RST(us_pll_rst), .PWRDWN(1'b0),
           .CLKOUT0(us_fast), .CLKOUT1(us_slow), .LOCKED(us_pll_lock));
  BUFG us2xbufg (.I(us_fast), .O(us_clk2x));
  BUFG usbufg (.I(us_slow), .O(us_clk));
  gt_us us (
    .sysclk_in(sys_clk), .soft_reset_tx_in(start), .soft_reset_rx_in(start), .dont_reset_on_data_error_in(1'b1),
    .gt0_tx_fsm_reset_done_out(us_tx_done), .gt0_rx_fsm_reset_done_out(us_rx_done), .gt0_data_valid_in(1'b1),
    .gt0_tx_mmcm_lock_in(us_pll_lock), .gt0_tx_mmcm_reset_out(us_pll_rst), .gt0_rx_mmcm_lock_in(us_pll_lock), .gt0_rx_mmcm_reset_out(),
    .gt0_drpaddr_in(9'd0), .gt0_drpclk_in(sys_clk), .gt0_drpdi_in(16'd0), .gt0_drpen_in(1'b0), .gt0_drpwe_in(1'b0),
    .gt0_eyescanreset_in(1'b0), .gt0_eyescantrigger_in(1'b0), .gt0_rxuserrdy_in(1'b1), .gt0_txuserrdy_in(1'b1),
    .gt0_gtrxreset_in(1'b0), .gt0_gttxreset_in(1'b0), .gt0_rxlpmreset_in(1'b0), .gt0_rxlpmhfhold_in(1'b1), .gt0_rxlpmlfhold_in(1'b1),
    .gt0_rxcdrhold_in(1'b1),
    .gt0_gtprxp_in(US_RX_P), .gt0_gtprxn_in(US_RX_N), .gt0_rxdata_out(us_rx),
    .gt0_rxusrclk_in(us_clk2x), .gt0_rxusrclk2_in(us_clk),
    .gt0_gtptxp_out(US_TX_P), .gt0_gtptxn_out(US_TX_N), .gt0_txdata_in(us_tx), .gt0_txoutclk_out(us_txoutclk),
    .gt0_txusrclk_in(us_clk2x), .gt0_txusrclk2_in(us_clk),
    .gt0_pll0outclk_in(pll_clk), .gt0_pll0outrefclk_in(pll_refclk), .gt0_pll0lock_in(pll_lock), .gt0_pll0refclklost_in(1'b0),
    .gt0_pll0reset_out(us_pll_reset), .gt0_pll1outclk_in(1'b0), .gt0_pll1outrefclk_in(1'b0));

  // the dump's 77.76 MHz: ref_clk x 5/8
  wire out_pll_fb, out_pll_lock, out_pll_clk;
  PLLE2_BASE #(.CLKIN1_PERIOD(8.037), .CLKFBOUT_MULT(10), .CLKOUT0_DIVIDE(16))
    outpll (.CLKIN1(ref_clk), .CLKFBIN(out_pll_fb), .CLKFBOUT(out_pll_fb), .RST(!ds_tx_done), .PWRDWN(1'b0),
            .CLKOUT0(out_pll_clk), .LOCKED(out_pll_lock));
  BUFG outbufg (.I(out_pll_clk), .O(out_clk));

  // resets: asserted at once, released two clocks after their condition clears, in each domain
  wire ds_ok = ds_rx_done && !los[1];
  wire us_ok = us_tx_done && us_rx_done;
  wire out_ok = ds_tx_done && out_pll_lock;
  reg [1:0] ref_r = 2'b11, ds_r = 2'b11, us_r = 2'b11, out_r = 2'b11;
  always @(posedge ref_clk or negedge ds_tx_done) if (!ds_tx_done) ref_r <= 2'b11; else ref_r <= {ref_r[0], 1'b0};
  always @(posedge ds_clk or negedge ds_ok) if (!ds_ok) ds_r <= 2'b11; else ds_r <= {ds_r[0], 1'b0};
  always @(posedge us_clk or negedge us_ok) if (!us_ok) us_r <= 2'b11; else us_r <= {us_r[0], 1'b0};
  always @(posedge out_clk or negedge out_ok) if (!out_ok) out_r <= 2'b11; else out_r <= {out_r[0], 1'b0};

  // USB: the PHY's reference, 155.52 MHz x 6.25 / 40.5 = 24.000 MHz; its CLKOUT starts only once RESETB is high, so
  // the usb domain leaves reset on that clock
  wire phy_fb, phy_ref_raw, phy_ref, phy_lock, usb_clk;
  MMCME2_BASE #(.CLKIN1_PERIOD(6.430), .CLKFBOUT_MULT_F(6.25), .CLKOUT0_DIVIDE_F(40.5))
    phypll (.CLKIN1(sys_clk), .CLKFBIN(phy_fb), .CLKFBOUT(phy_fb), .RST(start), .PWRDWN(1'b0), .CLKOUT0(phy_ref_raw),
            .LOCKED(phy_lock));
  BUFG phyrefbufg (.I(phy_ref_raw), .O(phy_ref));
  ODDR #(.DDR_CLK_EDGE("SAME_EDGE")) phyref (.C(phy_ref), .CE(1'b1), .D1(1'b1), .D2(1'b0), .R(1'b0), .S(1'b0), .Q(ULPI_REFCLK));
  wire phy_reset = start || !phy_lock;
  assign ULPI_RST_N = !phy_reset;
  // CLKOUT deskewed (zero-delay MMCM, 960 MHz VCO): the BUFG's 4.5 ns would eat LUNA's combinational ULPI outputs'
  // margin; while unlocked (no CLKOUT yet, or lost) the MMCM is reset again every 210 us, past its 100 us lock time
  wire usb_fb, usb_lock;
  reg [1:0] usb_lock_s = 0;
  reg [14:0] usb_wait = 0;
  always @(posedge sys_clk) begin
    usb_lock_s <= {usb_lock_s[0], usb_lock};
    usb_wait <= usb_lock_s[1] ? 15'd0 : usb_wait + 1'b1;
  end
  MMCME2_BASE #(.CLKIN1_PERIOD(16.667), .CLKFBOUT_MULT_F(16))
    usbpll (.CLKIN1(ULPI_CLK), .CLKFBIN(usb_clk), .CLKFBOUT(usb_fb), .RST(phy_reset || &usb_wait[14:4]), .PWRDWN(1'b0),
            .LOCKED(usb_lock));
  BUFG usbbufg (.I(usb_fb), .O(usb_clk));
  reg [1:0] usb_r = 2'b11;
  always @(posedge usb_clk or negedge usb_lock) if (!usb_lock) usb_r <= 2'b11; else usb_r <= {usb_r[0], 1'b0};
  wire [7:0] ulpi_in, ulpi_out, to_host, from_host;
  wire ulpi_oe, to_host_valid, to_host_ready, to_host_last, from_host_valid, from_host_ready;
  genvar b;
  generate for (b = 0; b < 8; b = b + 1) begin : ulpi_pad
    IOBUF pad (.IO(ULPI_D[b]), .I(ulpi_out[b]), .O(ulpi_in[b]), .T(!ulpi_oe));
  end endgenerate
  usb_serial usb (
    .ulpi_clk(usb_clk), .rst(usb_r[1]), .ulpi_data_i(ulpi_in), .ulpi_data_o(ulpi_out), .ulpi_data_oe(ulpi_oe),
    .ulpi_dir(ULPI_DIR), .ulpi_nxt(ULPI_NXT), .ulpi_stp(ULPI_STP), .ulpi_rst(),
    .tx_data(to_host), .tx_valid(to_host_valid), .tx_last(to_host_last), .tx_ready(to_host_ready),
    .rx_data(from_host), .rx_valid(from_host_valid), .rx_ready(from_host_ready));

  // USB 3: the wide dump's words to the host
  reg [7:0] ss_por = 0;
  always @(posedge ss_clk) if (!(&ss_por)) ss_por <= ss_por + 1'b1;
  wire ss_reset = !(&ss_por);
  wire [31:0] ss_word;
  wire ss_valid, ss_ready, ss_trained;
  usb3 usb3 (
    .clk(ss_clk), .rst(ss_reset), .pll_clk(ss_pll_clk), .pll_refclk(ss_pll_refclk), .pll_lock(ss_pll_lock),
    .pll_reset(ss_pll_reset), .tx_p(SS_TX_P), .tx_n(SS_TX_N), .rx_p(SS_RX_P), .rx_n(SS_RX_N),
    .data(ss_word), .valid(ss_valid), .ready(ss_ready), .trained(ss_trained));

  wire ds_laser, us_laser, scl_low, scl2_low, sda_low;
  wire [1:0] us_ben;
  InlineSniffer sniffer (
    .clk(ref_clk), .reset(ref_r[1]), .ds_clk(ds_clk), .ds_reset(ds_r[1]), .out_clk(out_clk), .out_reset(out_r[1]),
    .us_clk(us_clk), .us_reset(us_r[1]), .usb_clk(usb_clk), .usb_reset(usb_r[1]), .ss_clk(ss_clk),
    .io_dsRx(ds_rx), .io_usRx(us_rx), .io_dsSignal(ds_ok),
    .io_dsTx(ds_tx), .io_dsLaser(ds_laser), .io_usTx(us_tx), .io_usBen(us_ben), .io_usLaser(us_laser), .io_usAbove(US_ABOVE), .io_burstCut(BURST_CUT), .io_apdOn(APD_EN),
    .io_txFaster(tx_faster),
    .io_usb_tx_valid(to_host_valid), .io_usb_tx_ready(to_host_ready), .io_usb_tx_payload(to_host), .io_usb_txLast(to_host_last),
    .io_usb_rx_valid(from_host_valid), .io_usb_rx_ready(from_host_ready), .io_usb_rx_payload(from_host),
    .io_ss_tx_valid(ss_valid), .io_ss_tx_ready(ss_ready), .io_ss_tx_payload(ss_word), .io_ss_up(ss_trained),
    .io_sclLow(scl_low), .io_scl2Low(scl2_low), .io_sdaLow(sda_low), .io_scl(SCL), .io_sda(SDA), .io_synced(LED_SYNC));

  assign DS_LASER_DIS = !ds_laser;
  assign US_LASER_DIS = !us_laser;
  assign SCL = scl_low ? 1'b0 : 1'bz;
  assign SCL2 = scl2_low ? 1'b0 : 1'bz;
  assign SDA = sda_low ? 1'b0 : 1'bz;
  // the first half of each word on the rising edge
  ODDR #(.DDR_CLK_EDGE("SAME_EDGE")) ben (.C(us_clk), .CE(1'b1), .D1(us_ben[1]), .D2(us_ben[0]), .R(us_r[1]), .S(1'b0), .Q(US_BEN));
endmodule
