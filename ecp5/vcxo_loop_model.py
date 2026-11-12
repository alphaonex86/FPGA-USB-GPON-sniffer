#!/usr/bin/env python3
# SPDX-License-Identifier: CERN-OHL-S-2.0
# Closed-loop model of VcxoLoop in its in-line setting (../FPGA-ONU-1GPON-1GE/common/hw/spinal/pon/sniffer/
# SnifferBridge.scala): update every 2^10 clocks of 124.416 MHz, error 2 x fill + 1 (never zero: a bang-bang where
# the crossing FIFO's fill toggles), duty -> two RC poles at 1 kHz -> VCXO. Prints the lock time and the phase
# excursion once locked, in downstream bits (a word is 20), for several VCXO ranges and start offsets.
import math
F = 124.416e6; T = 2**10 / F; KP = 1 << 5; KI = 1 << 13; RC_HZ = 1000
def run(f0_ppm, range_ppm, seconds=4.0):
    a = 1 - math.exp(-T * 2 * math.pi * RC_HZ)
    integral = 0x8000 << 16; duty = 0x8000; v1 = v2 = 0.5; phase = 3.3; lock = None; lo = hi = None
    for n in range(int(seconds / T)):
        v1 += a * (duty / 65536 - v1); v2 += a * (v1 - v2)
        f_ref = (f0_ppm + range_ppm * (v2 - 0.5)) * 1e-6      # ref relative to the downstream
        phase = max(-8, min(7.999, phase - f_ref * F * T))    # words from the FIFO's middle
        e = 2 * math.floor(phase) + 1
        integral = max(0, min(0xFFFF << 16, integral + e * KI))
        duty = max(0, min(0xFFFF, (integral >> 16) + KP * e))
        if lock is None and abs(phase) < 0.5: lock = n * T
        if n * T > seconds / 2:
            lo = phase if lo is None else min(lo, phase); hi = phase if hi is None else max(hi, phase)
    return lock, (hi - lo) * 20, duty
for range_ppm in (33, 100, 300):
    for f0 in (-0.4, 0.1, 0.4):
        lock, swing, duty = run(f0 * range_ppm, range_ppm)
        print(f"range {range_ppm} ppm, start {f0 * range_ppm:+.0f} ppm: lock {('%.2f s' % lock) if lock is not None else 'NEVER'}, "
              f"phase within {swing:.2f} bits, duty 0x{duty:04X}")
