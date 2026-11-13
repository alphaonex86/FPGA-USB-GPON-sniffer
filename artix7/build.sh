#!/bin/sh
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Builds out/artix7/inline.bit; the balls come from the board netlist (pins.py).
# The RTL comes from the common project: sbt "runMain pon.Generate" in ../FPGA-ONU-1GPON-1GE.
set -e
here=$(cd "$(dirname "$0")" && pwd)
vivado=${VIVADO:-/mnt/data/perso/FPGA/AMD/Xilinx/2025.2/Vivado/bin/vivado}
rtl=$here/../../FPGA-ONU-1GPON-1GE/out/rtl/InlineSniffer.v
out=$here/../out/artix7
[ -f "$rtl" ] || { echo "$rtl missing: generate the RTL first" >&2; exit 1; }
[ -x "$vivado" ] || { echo "$vivado missing: set VIVADO" >&2; exit 1; }
mkdir -p "$out/compat"
# Vivado wants the ncurses 5 names: the system's version 6 serves
for lib in ncurses tinfo; do
  [ -e "/lib64/lib$lib.so.5" ] || ln -sf "/lib64/lib$lib.so.6" "$out/compat/lib$lib.so.5"
done
python3 "$here/pins.py" "$out"
cd "$out"
LD_LIBRARY_PATH="$out/compat${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$vivado" -mode batch -nojournal -log "$out/vivado.log" \
  -source "$here/build.tcl" -tclargs "$out" "$rtl" "$out/pins.xdc"
