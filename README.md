# FPGA USB GPON sniffer

The cheapest in-line GPON dumper we could design: a USB device that sits in one ONU's drop fibre, regenerates
both directions and dumps that ONU's exchange with the OLT (activation PLOAM, BWmap, OMCI managed entities, low-rate
GEM traffic), every record tagged with its direction. Goal: diagnose and complete the open source Linux GPON stack.

Status: RTL and host tool written; the Artix-7 build meets timing and the whole chip, transceivers included, is
simulated (bursts regenerated bit for bit at a constant delay). Board routed (design rules clean). Nothing has been built or
measured.

## Why in-line and not a passive tap

A passive tap (the sniffer card of [FPGA-ONU-1GPON-1GE](https://github.com/alphaonex86/FPGA-ONU-1GPON-1GE)) takes about
4 dB from the ONU: it only fits homes that receive -23 dBm or better. This device receives each direction and emits
it again on the other side at the received level + 1 dB (floor -26 dBm, configurable), so the ONU and the OLT see
what they saw on the bare fibre.

## Block diagram

```
            OLT port (ONU-type optics)                              ONU port (OLT-type optics)
 OLT ====== RX 1490 nm --> CH0 RX --[ FIFO ]-----------> CH0 TX --> TX 1490 nm ==[ pad ]====== ONU
  fibre     TX 1310 nm <-- CH1 TX <--[ burst regen ]<--- CH1 RX <-- RX 1310 nm
                               |        Artix-7           |
                               +---> frame sync, filter <-+      155.52 MHz fixed oscillator
                                          records
                                             |
                                  USB3320 ULPI (USB 2.0 HS) ---- USB-C: power, dump
```

## Design

- 3R through the FPGA (re-amplify, re-shape, re-time). An analog burst repeater eats preamble bits (receiver
  settling, laser turn-on) the OLT needs; here the burst's head is rebuilt and the burst keeps its slot. The added
  latency is constant (about 100 ns each way): ranging absorbs it as 20 m of fibre.
- FPGA: AMD Artix-7 XC7A35T-2FGG484I, two GTP lanes: downstream duplex at 2488.32 Mb/s, upstream at 4976.64 Mb/s
  (4 samples per bit); Vivado.
- No VCXO: the downstream transmitter follows the received clock with the GTP's TX phase interpolator. The upstream
  receiver runs on the fixed oscillator and tracks the ONU's bit phase, so the bursts leave at a constant delay.
- Downstream bits pass unchanged (no FEC correction, no decryption): the ONU still does both.
- Upstream laser: on only while a burst arrives from the ONU, off at its last bit; dark with the FPGA unconfigured
  or hung (pull-ups and an independent maximum-burst cutoff).
- Dump: frame sync, FEC parity skip, GEM delineation and a filter (the ONU's Alloc-IDs and Port-IDs) in hardware;
  records of four kinds: PLOAM, BWmap entry, GEM fragment (downstream), burst (upstream). Low traffic is the target:
  records beyond what USB 2.0 high speed carries are lost under load, and counted.
- USB: a USB3320 ULPI PHY and LUNA's serial device (CDC-ACM) in the FPGA: the record stream and the register writes
  on a plain /dev/ttyACM under Linux (no host library). Bitstream: a DIP-8 SPI flash in a socket, written in any
  programmer (`out/artix7/inline.bin`); no JTAG probe needed (the header's pads stay, unfitted, for rescue).
- Levels: both received powers measured, both lasers set by DAC; the fixed pad on the ONU port keeps the ONU's
  bursts under the receiver's overload. The host tool sets them ("Levels" below): without a host the lasers stay
  dark, and they keep their last levels when it leaves.
- Sensitivity: an APD receiver at the OLT port, for homes at -27 dBm and below. The dump does not correct FEC: on a
  link that only works thanks to FEC the ONU still does, the dump loses frames.

## Layout

- RTL, PCB generator and the host tool are shared with FPGA-ONU-1GPON-1GE, checked out next to this folder
  (`../FPGA-ONU-1GPON-1GE/common`).
- Host: `make -C ../FPGA-ONU-1GPON-1GE/common/sw/sniffer`, then `sniffer -i /dev/ttyACM0 -w dump.bin` (decoded
  records on stdout; `-r dump.bin` decodes a dump again; the port's raw bytes are such a dump).
- Here: `levels.example` (a unit's level file), `artix7/` (top level; `sh artix7/build.sh` builds the bitstream, `sh artix7/sim.sh` simulates the chip with
  the transceiver models), `pcb/inline/` (board, 84 x 54 mm; `lcsc.csv` parts list, `order-notes.md`; JLCPCB files:
  `python3 ../FPGA-ONU-1GPON-1GE/common/pcb/gen/fab.py inline`).

## Levels

`sniffer -i /dev/ttyACM0 -L unit.levels` sets the unit's levels from its level file (`levels.example`): lasers dark,
APD bias set and switched on, then every second each laser is aimed at what the other port receives + `gain_db`,
between `floor_dbm` and its `tx_max_dbm`. Starting with `-L` restarts both lasers from dark: the ONU activates again,
which is the exchange to dump. Without `-L` nothing is touched. Nothing is switched on when a DAC or the ADC does
not answer or when a current flows on the OLT port's APD lead before its bias is on; over 2 mA there later, bias and
lasers go off (VCC and APD leads exchanged on that BOSA, or a bias over the breakdown).

A unit's file is measured once, powers taken at the box's connectors with a power meter:

1. `olt_apd_v`, `onu_apd_v`: from each BOSA's test sheet. With only these two lines the tool prints the readings.
2. OLT port receiver: the drop fibre's power P on the meter, then the fibre on the port: `olt_rx_a_per_w` =
   printed APD mV / 1200 / P in mW.
3. ONU port laser (lit while the downstream is received): `onu_tx_bias_ma` at two values, `onu_tx_mod_ma = 0`, the
   meter on the ONU port: the two powers give `onu_tx_mw_per_ma` and `onu_tx_threshold_ma`, the printed monitor mV
   over the power `onu_tx_md_mv_per_mw`.
4. Bursts (a power meter does not read them, and the maximum-burst cutoff forbids a continuous upstream laser):
   `onu_rx_a_per_w` = printed APD mV / 1200 / the ONU's transmit power in mW (its ANI-G attribute, in the dump);
   the OLT port laser's threshold and slope from the BOSA's test sheet, corrected with the level the OLT reports
   for this ONU where it can be read.

## License

CERN-OHL-S-2.0.
