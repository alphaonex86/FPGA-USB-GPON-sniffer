// SPDX-License-Identifier: CERN-OHL-S-2.0
// inline_artix7 on the vendor's GTP models (sim.sh). Measures the transmit phase interpolator (direction, ppm),
// then checks the downstream sent again bit for bit while its clock follows a source DS_PPM off the oscillator, and
// the upstream bursts regenerated at a constant delay inside US_BEN. Lines starting with RESULT / FAIL are the outcome.
`timescale 1ps/1fs
module tb;
  parameter real DS_PPM = 40.0, US_PPM = -50.0;
  parameter integer BURSTS = 4;
  localparam real T_REF = 1.0e6 / 155.52;
  localparam real T_DS = 1.0e6 / 2488.32 / (1.0 + DS_PPM * 1.0e-6);
  localparam real T_US = 1.0e6 / 1244.16 / (1.0 + US_PPM * 1.0e-6);
  localparam real T_WORD = 20.0e6 / 2488.32;  // ref_clk, when the interpolator rests
  integer fails = 0;

  reg refclk = 0;
  always #(T_REF / 2) refclk = !refclk;

  // downstream source: PRBS23, its last 8192 bits kept
  reg [22:0] ds_lfsr = 23'h1;
  reg ds_bit = 0;
  reg ds_past [0:8191];
  integer ds_count = 0;
  real ds_time = 0;
  always #(T_DS) begin
    ds_bit = ds_lfsr[22] ^ ds_lfsr[17];
    ds_lfsr = {ds_lfsr[21:0], ds_bit};
    ds_count = ds_count + 1;
    ds_past[ds_count % 8192] = ds_bit;
    ds_time = $realtime;
  end

  // the host: no USB model (LUNA's tests cover the protocol), its bytes put straight on the serial core's streams at the
  // PHY's 60 MHz; bytes to it counted
  reg [7:0] host [0:5];
  integer host_left = 0, device_bytes = 0;
  reg [7:0] device [0:31];  // the bytes to the host: the dump stays disabled, a register read's reply only
  reg ulpi_clk = 0;
  always #8333 ulpi_clk = !ulpi_clk;
  wire scl, scl2, sda, ds_tx_p, ds_tx_n, us_tx_p, us_tx_n, ds_laser_dis, us_laser_dis, us_ben, led, ulpi_rst_n;
  initial begin
    force dut.to_host_ready = 1'b1;
    force dut.from_host_valid = 1'b0;
  end
  always @(posedge dut.usb_clk) begin
    if (dut.to_host_valid) begin
      device_bytes = device_bytes + 1;
      if (device_bytes <= 32) device[device_bytes - 1] = dut.to_host;
    end
    if (host_left > 0 && dut.from_host_valid && dut.from_host_ready) host_left = host_left - 1;
  end
  always @(negedge dut.usb_clk) begin  // half a clock off the edge the core samples on
    force dut.from_host_valid = host_left > 0;
    force dut.from_host = host[6 - host_left];
  end
  always @(posedge dut.out_clk) if (dut.sniffer.dump.command_phase == 2 && dut.sniffer.dump.command_shift[7])
    $display("%t register %0d <- %h", $realtime, dut.sniffer.dump.command_shift[5:0], dut.sniffer.dump.apb_PWDATA);
  task command(input [7:0] number, input [31:0] value);  // number bit 7: write
    begin
      host[0] = 8'h5A; host[1] = number;
      {host[5], host[4], host[3], host[2]} = value;
      host_left = 6;
      wait (host_left == 0);
    end
  endtask
  task write_register(input [6:0] number, input [31:0] value);
    command({1'b1, number}, value);
  endtask
  pullup (scl);
  pullup (scl2);
  pullup (sda);

  reg us_bit = 0;
  inline_artix7 dut (
    .REFCLK_P(refclk), .REFCLK_N(!refclk), .DS_RX_P(ds_bit), .DS_RX_N(!ds_bit), .US_RX_P(us_bit), .US_RX_N(!us_bit),
    .DS_TX_P(ds_tx_p), .DS_TX_N(ds_tx_n), .US_TX_P(us_tx_p), .US_TX_N(us_tx_n),
    .DS_LOS(1'b0), .DS_LASER_DIS(ds_laser_dis), .US_LASER_DIS(us_laser_dis), .US_BEN(us_ben), .US_ABOVE(1'b0), .BURST_CUT(1'b0), .APD_EN(),
    .ULPI_CLK(ulpi_clk && ulpi_rst_n), .ULPI_D(), .ULPI_DIR(1'b1), .ULPI_NXT(1'b0), .ULPI_STP(), .ULPI_RST_N(ulpi_rst_n),
    .ULPI_REFCLK(), .SCL(scl), .SCL2(scl2), .SDA(sda), .LED_SYNC(led));
  defparam dut.ds.inst.EXAMPLE_SIMULATION = 1, dut.us.inst.EXAMPLE_SIMULATION = 1;
  defparam dut.ds.inst.EXAMPLE_SIM_GTRESET_SPEEDUP = "TRUE", dut.us.inst.EXAMPLE_SIM_GTRESET_SPEEDUP = "TRUE";
  // The fast-reset GTP model drops RXPMARESETDONE for 20 ps only; the cores' reset sequence waits for that fall to set
  // the receiver back from 16 to 20 bits and misses it. The fall is shown to it for one of its clocks.
`define SHOW_FALL(seq) \
  always @(negedge seq.RXPMARESETDONE) if (seq.state == 5) begin \
    force seq.rxpmaresetdone_ss = 1'b0; \
    force seq.rxpmaresetdone_sss = 1'b1; \
    @(posedge seq.DRPCLK); \
    @(negedge seq.DRPCLK); \
    release seq.rxpmaresetdone_ss; \
    release seq.rxpmaresetdone_sss; \
  end
  `SHOW_FALL(dut.ds.inst.gt_ds_i.gt0_gt_ds_i.gtrxreset_seq_i)
  `SHOW_FALL(dut.us.inst.gt_us_i.gt0_gt_us_i.gtrxreset_seq_i)

  // ref_clk against its nominal rate over `span` ps, in ppm
  task clock_ppm(input real span, output real ppm);
    real first;
    integer n;
    begin
      @(posedge dut.ref_clk) first = $realtime;
      n = 0;
      while ($realtime - first < span) @(posedge dut.ref_clk) n = n + 1;
      ppm = (n * T_WORD / ($realtime - first) - 1.0) * 1.0e6;
    end
  endtask

  // downstream monitor: a sampler restarted half a bit after each edge of the line; once `ds_checking`, every bit
  // against the source bit it follows (found once in the source's past) and its latency
  reg ds_checking = 0, ds_resync = 0, ds_found = 0;
  reg [22:0] ds_seen = 0;
  integer ds_source = 0, ds_errors = 0, ds_checked = 0, lag, i, fill, fill_min = 99, fill_max = 0;
  real ds_latency, ds_latency_min = 1.0e30, ds_latency_max = 0;
  reg same;
  always begin : ds_sampler
    if (ds_resync) begin
      ds_resync = 0;
      #(T_DS / 2);
    end else #(T_DS);
    ds_seen = {ds_seen[21:0], ds_tx_p};
    ds_source = ds_source + 1;
    if (ds_checking && !ds_found && ds_seen != 0) begin
      for (lag = 23; lag < 8000 && !ds_found; lag = lag + 1) begin
        same = 1;
        for (i = 0; i < 23; i = i + 1) if (ds_past[(ds_count - lag - i) % 8192] !== ds_seen[i]) same = 0;
        if (same) begin
          ds_found = 1;
          ds_source = ds_count - lag;
        end
      end
    end else if (ds_checking && ds_found) begin
      ds_checked = ds_checked + 1;
      if (ds_count - ds_source >= 8192 || ds_past[ds_source % 8192] !== ds_tx_p) ds_errors = ds_errors + 1;
      ds_latency = $realtime - T_DS / 2 - (ds_time - (ds_count - ds_source) * T_DS);
      if (ds_latency < ds_latency_min) ds_latency_min = ds_latency;
      if (ds_latency > ds_latency_max) ds_latency_max = ds_latency;
    end
  end
  always @(ds_tx_p) begin
    ds_resync = 1;
    disable ds_sampler;
  end
  always @(posedge dut.ref_clk) if (ds_checking) begin
    fill = dut.sniffer.bridge.crossing_io_popOccupancy;
    if (fill < fill_min) fill_min = fill;
    if (fill > fill_max) fill_max = fill;
  end

  // upstream: a burst (preamble, delimiter, PRBS payload) from the ONU, the line to the OLT sampled 8 times per bit
  localparam integer PREAMBLE = 44, BURST = 564, SAMPLES = 16384, TAIL = 40;  // dark bits checked after a burst
  reg burst_bit [0:BURST - 1];
  reg line [0:SAMPLES - 1];
  reg [14:0] us_lfsr = 15'h5A5A;
  reg [19:0] delimiter = 20'hB5983;
  real burst_start = 0, ben_rise = 0, ben_fall = 0, delay_first = -1;
  integer k, s, d, wrong, best, best_from, best_to, head_wrong, start_wrong;
  always @(posedge us_ben) ben_rise = $realtime;
  always @(negedge us_ben) ben_fall = $realtime;
  function expected(input integer n);  // the preamble goes on before the burst: the regenerator's head
    expected = n < 0 ? (n % 2 == 0) : n < BURST ? burst_bit[n] : 1'b0;
  endfunction
  task mismatches(input integer shift, input integer from, input integer to, output integer count);
    begin
      count = 0;
      for (k = from; k < to; k = k + 1) if (line[shift + 8 * k + 4] !== expected(k)) count = count + 1;
    end
  endtask
  task burst(input integer number);
    real delay;
    begin
      for (k = 0; k < BURST; k = k + 1) begin
        if (k < PREAMBLE) burst_bit[k] = (k % 2 == 0);
        else if (k < PREAMBLE + 20) burst_bit[k] = delimiter[PREAMBLE + 19 - k];
        else begin
          burst_bit[k] = us_lfsr[14] ^ us_lfsr[13];
          us_lfsr = {us_lfsr[13:0], burst_bit[k]};
        end
      end
      burst_start = $realtime;
      for (s = 0; s < SAMPLES; s = s + 1) begin
        us_bit = s / 8 < BURST ? burst_bit[s / 8] : 1'b0;
        line[s] = us_tx_p && us_ben;
        #(T_US / 8);
      end
      // the delays (in samples) at which every bit past the rebuilt start reads right
      best = 0; best_from = -1; best_to = -1;
      for (d = 0; d < SAMPLES - 8 * BURST - 8 * TAIL; d = d + 1) begin
        mismatches(d, 32, BURST + TAIL, wrong);
        if (wrong == 0) begin
          if (best_from < 0) best_from = d;
          best_to = d;
        end
      end
      if (best_from < 0) begin
        $display("FAIL burst %0d: not sent as received, or light after it", number);
        fails = fails + 1;
      end else begin
        best = (best_from + best_to) / 2;
        if ($test$plusargs("trace")) for (d = best_from - 1; d <= best_to + 1; d = d + best_to - best_from + 2)
          for (k = 32; k < BURST + TAIL; k = k + 1) if (line[d + 8 * k + 4] !== expected(k)) begin
            $display("  shift %0d: bit %0d wrong; samples around it %b%b%b%b%b%b%b%b|%b%b%b%b%b%b%b%b|%b%b%b%b%b%b%b%b, bits %b%b%b", d, k,
              line[d+8*k-8],line[d+8*k-7],line[d+8*k-6],line[d+8*k-5],line[d+8*k-4],line[d+8*k-3],line[d+8*k-2],line[d+8*k-1],
              line[d+8*k],line[d+8*k+1],line[d+8*k+2],line[d+8*k+3],line[d+8*k+4],line[d+8*k+5],line[d+8*k+6],line[d+8*k+7],
              line[d+8*k+8],line[d+8*k+9],line[d+8*k+10],line[d+8*k+11],line[d+8*k+12],line[d+8*k+13],line[d+8*k+14],line[d+8*k+15],
              expected(k - 1), expected(k), expected(k + 1));
            k = BURST + TAIL;
          end
        delay = best * T_US / 8;
        mismatches(best, -15, 0, head_wrong);
        mismatches(best, 0, 32, start_wrong);
        $display("RESULT burst %0d: delay %0.2f ns (%0.1f bits), eye %0d/8 bit, head wrong %0d/15, first 32 bits wrong %0d, laser enable from %0.2f bits before the first bit to %0.2f bits after the last",
          number, delay / 1000, delay / T_US, best_to - best_from + 1, head_wrong, start_wrong,
          (burst_start + delay - ben_rise) / T_US, (ben_fall - burst_start - delay) / T_US - BURST);
        if (delay_first < 0) delay_first = delay;
        if (delay - delay_first > T_US / 2 || delay_first - delay > T_US / 2) begin
          $display("FAIL burst %0d: delay moved by %0.2f bits", number, (delay - delay_first) / T_US);
          fails = fails + 1;
        end
        if (ben_rise < burst_start || ben_fall < ben_rise) begin
          $display("FAIL burst %0d: no laser enable", number);
          fails = fails + 1;
        end
      end
      #(T_US * number * 0.3);  // another phase for the next one
    end
  endtask

  reg [39:0] line_now = 0;
  always @(dut.sniffer.upstream_clean.p) if ($test$plusargs("trace")) $display("%t phase %0d (burst began %0.1f bits ago)", $realtime, dut.sniffer.upstream_clean.p, ($realtime - burst_start) / T_US);
  // +trace: the upstream lane's words around the first burst
  integer traced = 0;
  always @(posedge dut.us_clk) if ($test$plusargs("trace") && burst_start > 0 && traced < 110) begin
    traced = traced + 1;
    $display("%t rx %h tx %h ben %b laser %b", $realtime, dut.us_rx, dut.us_tx, dut.us_ben, !us_laser_dis);
    $display("  raw %b k %b d %b buf %b line %b", dut.us.inst.gt_us_i.gt0_gt_us_i.rxdata_i,
      dut.us.inst.gt_us_i.gt0_gt_us_i.rxcharisk_i[3:0], dut.us.inst.gt_us_i.gt0_gt_us_i.rxdisperr_i,
      dut.us.inst.gt_us_i.gt0_gt_us_i.gtpe2_i.RXBUFSTATUS, line_now);
  end
  // the line as the lane should sample it: its last 40 samples (4 per bit), newest in bit 39
  always #(T_US / 4) line_now = {us_bit, line_now[39:1]};
  // +trace: the downstream words received and sent against the PRBS rule, first bit in bit 0
  reg [59:0] rx_words = 0, tx_words = 0;
  integer rx_traced = 0, rx_rule = 0, tx_traced = 0, tx_rule = 0, rk, tk;
  always @(posedge dut.ds_clk) if ($test$plusargs("trace") && ds_checking && rx_traced < 200) begin
    rx_words = {dut.ds_rx, rx_words[59:20]};
    rx_traced = rx_traced + 1;
    for (rk = 40; rk < 60; rk = rk + 1) if (rx_traced > 3 && rx_words[rk] !== (rx_words[rk - 18] ^ rx_words[rk - 23])) rx_rule = rx_rule + 1;
    if (rx_traced == 200) $display("RESULT trace: received words break the PRBS rule on %0d of 3940 bits; last %b", rx_rule, dut.ds_rx);
  end
  always @(posedge dut.ref_clk) if ($test$plusargs("trace") && ds_checking && tx_traced < 200) begin
    tx_words = {dut.ds_tx, tx_words[59:20]};
    tx_traced = tx_traced + 1;
    for (tk = 40; tk < 60; tk = tk + 1) if (tx_traced > 3 && tx_words[tk] !== (tx_words[tk - 18] ^ tx_words[tk - 23])) tx_rule = tx_rule + 1;
    if (tx_traced == 200) $display("RESULT trace: words sent break the PRBS rule on %0d of 3940 bits; last %b", tx_rule, dut.ds_tx);
  end

  real faster, slower, pull;
  integer n;
  reg [15:0] settled;
  integer sweep;
  initial begin
    $timeformat(-9, 2, " ns", 0);
    wait (dut.ds_tx_done === 1'b1 && dut.us_tx_done === 1'b1);
    $display("RESULT transmitters ready at %t", $realtime);
    wait (dut.ds_rx_done === 1'b1 && dut.us_rx_done === 1'b1);
    $display("RESULT receivers ready at %t", $realtime);
    if ($test$plusargs("rxonly")) begin  // with +trace: the received words only (a one-minute check of the receiver)
      #20000000 ds_checking = 1;
      wait (rx_traced == 200);
      $display("RESULT receiver only; %0s", rx_rule == 0 ? "PASS" : "FAILED");
      $finish;
    end
    if (dut.ds.inst.gt_ds_i.gt0_gt_ds_i.gtrxreset_seq_i.state != 0 || dut.us.inst.gt_us_i.gt0_gt_us_i.gtrxreset_seq_i.state != 0) begin
      $display("FAIL a receiver's reset sequence did not finish");
      $finish;
    end
    wait (dut.out_r === 2'b00);
    #1000000 write_register(5, 3);  // LASERS: both
    command(5, 0);  // read back: its reply record is the only traffic to the host (the dump stays disabled)
    #2000000;
    if ($test$plusargs("sweep")) for (sweep = 4; sweep <= 6; sweep = sweep + 1) begin
      write_register(6, 32'h23 | sweep << 8);  // REGEN: head 3, garble 2
      $display("RESULT benDelay %0d", sweep);
      for (n = 0; n < BURSTS; n = n + 1) burst(n);
    end else
      for (n = 0; n < BURSTS; n = n + 1) burst(n);

    force dut.tx_faster = 1'b1;
    #10000000 clock_ppm(50.0e6, faster);
    force dut.tx_faster = 1'b0;
    #10000000 clock_ppm(50.0e6, slower);
    release dut.tx_faster;
    pull = (faster - slower) / 2;
    $display("RESULT interpolator: txFaster %0.1f ppm, slower %0.1f ppm", faster, slower);
    if (pull < DS_PPM + 10.0) begin
      $display("FAIL the interpolator cannot follow %0.0f ppm", DS_PPM);
      $finish;
    end

    // the loop's integrator put where it would settle (it takes tens of ms), the 34 ms of proven crossing cut short
    settled = $rtoi(32768.0 + (DS_PPM - (faster + slower) / 2) / pull * 32768.0);
    force dut.sniffer.bridge.loop_1.integral = {2'b00, settled, 16'h0000};
    repeat (2) @(posedge dut.ref_clk);
    release dut.sniffer.bridge.loop_1.integral;
    #100000000;
    wait (dut.sniffer.bridge.popping === 1'b1);
    #50000000;
    force dut.sniffer.steady = 23'h3FFFF0;
    @(posedge dut.ref_clk);
    release dut.sniffer.steady;
    #2000000;
    if (ds_laser_dis !== 1'b0 || us_laser_dis !== 1'b0) begin
      $display("FAIL lasers not let on: DS_LASER_DIS %b US_LASER_DIS %b", ds_laser_dis, us_laser_dis);
      fails = fails + 1;
    end
    ds_checking = 1;
    #400000000;
    $display("RESULT downstream: %0d bits checked, %0d wrong, latency %0.3f to %0.3f ns (%0.2f bits wide), crossing fill %0d to %0d, duty %0d",
      ds_checked, ds_errors, ds_latency_min / 1000, ds_latency_max / 1000, (ds_latency_max - ds_latency_min) / T_DS,
      fill_min, fill_max, dut.sniffer.bridge.loop_1.duty);
    if (ds_checked < 100000 || ds_errors != 0 || ds_latency_max - ds_latency_min > 2 * T_DS || ds_laser_dis !== 1'b0) begin
      $display("FAIL downstream (DS_LASER_DIS %b)", ds_laser_dis);
      fails = fails + 1;
    end
    // reply record: 4 head bytes, 8 of time, the register number, its value (LE), padded to 20
    if (device_bytes != 20 || device[12] != 5 || {device[16], device[15], device[14], device[13]} != 3) begin
      $display("FAIL LASERS read back: %0d bytes to the host, number %0d, value %h", device_bytes, device[12],
        {device[16], device[15], device[14], device[13]});
      fails = fails + 1;
    end
    $display("RESULT %0d bytes to the host; %0s", device_bytes, fails == 0 ? "PASS" : "FAILED");
    $finish;
  end
endmodule
