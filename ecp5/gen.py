#!/usr/bin/env python3
# SPDX-License-Identifier: CERN-OHL-S-2.0
"""Writes the ECP5 build inputs: dcu_params.vh (the sniffer card's DCU tables, both transmitters on) and inline.lpf
(the clocks, and every pin's ball read from the routed board when there is one).
Usage: gen.py <out dir> [board.kicad_pcb]"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '../../FPGA-ONU-1GPON-1GE/sniffer/ecp5'))
import gen as card  # noqa: E402

SERDES = card.SERDES + ['DS_TX_P', 'DS_TX_N', 'US_TX_P', 'US_TX_N']  # dedicated pads: no IO type
PINS = (['DS_LOS', 'DS_LASER_DIS', 'US_LASER_DIS', 'US_BEN', 'US_ABOVE', 'VCXO_PWM', 'FT_RXF_N', 'FT_TXE_N', 'FT_RD_N', 'FT_WR_N', 'SCL', 'SDA',
         'LED_SYNC'] + [f'FT_D{i}' for i in range(8)])


def port(net):
    """Top-level port of a net: FT_D3 -> FT_D[3]."""
    return f'FT_D[{net[4:]}]' if net.startswith('FT_D') else net


def main(out, pcb=None):
    card.write_params(out, {0: card.TX_ON, 1: card.TX_ON})
    with open(f'{out}/inline.lpf', 'w') as f:
        if pcb:
            pins = card.board_pins(pcb, lambda net: net in PINS or net in SERDES)
            missing = [n for n in PINS + SERDES if n not in pins]
            if missing:
                sys.exit(f'{pcb}: no ECP5 ball for {missing}')
            for net in PINS:
                f.write(f'LOCATE COMP "{port(net)}" SITE "{pins[net]}";\nIOBUF PORT "{port(net)}" IO_TYPE=LVCMOS33;\n')
            for net in SERDES:
                f.write(f'LOCATE COMP "{net}" SITE "{pins[net]}";\n')
        else:  # fit only: the DDR output needs a ball, any left-bank one
            f.write('LOCATE COMP "US_BEN" SITE "C4";\nIOBUF PORT "US_BEN" IO_TYPE=LVCMOS33;\n')
        f.write('FREQUENCY NET "ref_clk" 124.416 MHZ;\nFREQUENCY NET "ds_clk" 124.416 MHZ;\n'
                'FREQUENCY NET "out_clk" 77.76 MHZ;\n')


if __name__ == '__main__':
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    main(*sys.argv[1:])
