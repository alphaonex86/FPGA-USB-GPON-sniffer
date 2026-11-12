#!/bin/sh
# SPDX-License-Identifier: CERN-OHL-S-2.0
# In-line sniffer bitstream, out/ecp5/inline.bit, from this folder's root. Needs ../FPGA-ONU-1GPON-1GE with its
# out/rtl/InlineSniffer.v (there: sbt "runMain pon.Generate"), yosys, nextpnr-ecp5 and ecppack.
# Without a routed board (pcb/inline/inline.kicad_pcb) the pins are left to the tools: fit and timing only, no bitstream.
set -e
HERE=$(pwd)
ONU=$HERE/../FPGA-ONU-1GPON-1GE
O=$HERE/out/ecp5
B=$HERE/pcb/inline/inline.kicad_pcb
[ -f $ONU/out/rtl/InlineSniffer.v ] || { echo "$ONU/out/rtl/InlineSniffer.v missing: sbt \"runMain pon.Generate\" there"; exit 1; }
mkdir -p $O
if [ -f $B ]; then python3 ecp5/gen.py $O $B; LOOSE=; else python3 ecp5/gen.py $O; LOOSE=--lpf-allow-unconstrained; fi
# from the RTL's folder: its memories are read from files next to it
(cd $ONU/out/rtl && nice -n 19 yosys -q -l $O/yosys.log -p "read_verilog -I$O $HERE/ecp5/inline_ecp5.v \
  $ONU/common/hw/ecp5/gpon_dcu.v InlineSniffer.v; synth_ecp5 -top inline_ecp5 -json $O/inline.json")
nice -n 19 nextpnr-ecp5 --um-45k --package CABGA381 --speed 8 --json $O/inline.json --lpf $O/inline.lpf $LOOSE \
  --textcfg $O/inline.config --log $O/nextpnr.log -q || true
grep -E "Max frequency for clock|ERROR|Warning: .*(constrain|unrouted)|TRELLIS_COMB:|DP16KD:" $O/nextpnr.log | tail -12
grep -q "^ERROR" $O/nextpnr.log && exit 1
if [ -f $B ]; then ecppack --compress $O/inline.config $O/inline.bit && echo "wrote $O/inline.bit"; fi
