#!/usr/bin/env python3
# SPDX-License-Identifier: CERN-OHL-S-2.0
"""Writes <out>/pins.xdc: each top-level port of inline_artix7 on the ball the board netlist (common/pcb/gen, inline())
gives its net. Usage: pins.py <out dir>"""
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '../../FPGA-ONU-1GPON-1GE/common/pcb/gen'))
from boards import inline  # noqa: E402

TOP = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'inline_artix7.v')
GT = ('DS_RX', 'DS_TX', 'US_RX', 'US_TX', 'REFCLK')  # transceiver pads: no IO standard


def ports():
    """{net: port} of the top's ports: ULPI_D[3] is net ULPI_D3."""
    head = open(TOP).read().split(');', 1)[0]
    out = {}
    for kind, width, names in re.findall(r'(input|output|inout)\s+(\[\d+:0\])?\s*([A-Z0-9_, ]+?)\s*(?:,|$)\s*(?://.*)?$', head, re.M):
        for name in (n.strip() for n in names.split(',') if n.strip()):
            if width:
                out.update({f'{name}{i}': f'{name}[{i}]' for i in range(int(width[1:-1].split(':')[0]) + 1)})
            else:
                out[name] = name
    return out


def main(out):
    fpga = next(p for p in inline().parts if p.value.startswith('XC7A'))
    ball = {net: b for b, net in fpga.conns.items()}
    wanted = ports()
    missing = sorted(n for n in wanted if n not in ball)
    if missing:
        sys.exit(f'no ball on the board for {missing}')
    with open(f'{out}/pins.xdc', 'w') as f:
        for net, port in sorted(wanted.items()):
            f.write(f'set_property PACKAGE_PIN {ball[net]} [get_ports {{{port}}}]\n')
            if not net.startswith(GT):
                f.write(f'set_property IOSTANDARD LVCMOS33 [get_ports {{{port}}}]\n')


if __name__ == '__main__':
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
