#!/bin/sh
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Runs tb.v on the GTP models with Vivado's simulator; build.sh first (it makes the cores).
set -e
here=$(cd "$(dirname "$0")" && pwd)
bin=$(dirname "${VIVADO:-/mnt/data/perso/FPGA/AMD/Xilinx/2025.2/Vivado/bin/vivado}")
rtl=$here/../../FPGA-ONU-1GPON-1GE/out/rtl/InlineSniffer.v
out=$here/../out/artix7
[ -f "$out/ip/gt_us/gt_us.v" ] || { echo "$out/ip missing: run build.sh first" >&2; exit 1; }
mkdir -p "$out/sim"
cd "$out/sim"
export LD_LIBRARY_PATH="$out/compat${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
cores=$(find "$out/ip/gt_ds" "$out/ip/gt_us" -name '*.v' ! -path '*/doc/*')
"$bin/xvlog" -nolog "$here/tb.v" "$here/inline_artix7.v" "$rtl" $cores "$bin/../data/verilog/src/glbl.v"
"$bin/xelab" -nolog -L unisims_ver -L secureip -s inline tb glbl
ln -sf "$(dirname "$rtl")"/InlineSniffer.v_*.bin .   # its RAMs' initial contents, read from the working directory
"$bin/xsim" -nolog inline -R ${TRACE:+-testplusarg trace} ${SWEEP:+-testplusarg sweep} \
  ${RXONLY:+-testplusarg trace -testplusarg rxonly} | tee sim.log
grep -q '^RESULT .*PASS$' sim.log
