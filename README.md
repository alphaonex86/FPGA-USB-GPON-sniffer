# FPGA USB GPON sniffer

The cheapest in-line GPON dumper we could design: a USB device that sits in one ONU's drop fibre, regenerates
both directions and dumps that ONU's exchange with the OLT (activation PLOAM, BWmap, OMCI managed entities, low-rate
GEM traffic), every record tagged with its direction. Goal: diagnose and complete the open source Linux GPON stack.

Status: design. Nothing here has been built or measured yet.

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
                               |          ECP5            |
                               +---> frame sync, filter <-+      155.52 MHz VCXO locked to the downstream
                                          records
                                             |
                                    FT2232H (USB 2.0 HS) ---- USB-C: power, bitstream, dump
```

## Design

- 3R through the FPGA (re-amplify, re-shape, re-time). An analog burst repeater eats preamble bits (receiver
  settling, laser turn-on) the OLT needs; here the burst's head is rebuilt and the burst keeps its slot. The added
  latency is constant (about 100 ns each way): ranging absorbs it as 20 m of fibre.
- FPGA: Lattice ECP5 LFE5UM-25F, one DCU, both channels duplex at 2488.32 Mb/s; open toolchain (yosys, nextpnr).
- One VCXO locked to the downstream clocks everything, so the ONU's bursts are synchronous to the FPGA.
- Downstream bits pass unchanged (no FEC correction, no decryption): the ONU still does both.
- Upstream laser: on only while a burst arrives from the ONU, off at its last bit; dark with the FPGA unconfigured
  or hung (pull-ups and an independent maximum-burst cutoff).
- Dump: frame sync, FEC parity skip, GEM delineation and a filter (the ONU's Alloc-IDs and Port-IDs) in hardware;
  records of four kinds: PLOAM, BWmap entry, GEM fragment (downstream), burst (upstream). Low traffic is the target:
  about 8 MB/s over USB, records lost under load are counted.
- USB: FT2232H; channel A is the record stream and the register writes (a plain serial port under Linux: no host
  library), channel B is JTAG (openFPGALoader).
- Levels: both received powers measured, both lasers set by DAC; the fixed pad on the ONU port keeps the ONU's
  bursts under the receiver's overload.

## Layout

- RTL, PCB generator and the decoder are shared with FPGA-ONU-1GPON-1GE, checked out next to this folder
  (`../FPGA-ONU-1GPON-1GE/common`).
- Here: the board, the ECP5 top level and build, the USB side of the host tool.

## License

CERN-OHL-S-2.0.
