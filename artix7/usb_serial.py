# SPDX-License-Identifier: CERN-OHL-S-2.0
"""Writes usb_serial.v: LUNA's high-speed USB serial device (CDC-ACM, a /dev/ttyACM on the host) on a ULPI PHY in
output clock mode (USB3320). Its `usb` domain is the PHY's 60 MHz CLKOUT; `rst` high holds the PHY in reset (RESETB =
!ulpi_rst). Streams of bytes: rx from the host, tx to it; a tx byte with `last` ends its packet (sent at once).
Usage: python usb_serial.py OUT.v  (with amaranth and luna-usb, see build.sh)"""
import sys
from types import SimpleNamespace
from amaranth import ClockDomain, Elaboratable, Module, ResetSignal, Signal
from amaranth.back import verilog
from luna.full_devices import USBSerialDevice


def pins(**fields):
    return SimpleNamespace(**{k: Signal(w, name=f'{prefix}') for k, (prefix, w) in fields.items()})


class UsbSerial(Elaboratable):
    def __init__(self):
        self.ulpi = SimpleNamespace(
            data=pins(i=('ulpi_data_i', 8), o=('ulpi_data_o', 8), oe=('ulpi_data_oe', 1)),
            dir=pins(i=('ulpi_dir', 1)), nxt=pins(i=('ulpi_nxt', 1)), stp=pins(o=('ulpi_stp', 1)),
            rst=pins(o=('ulpi_rst', 1)), clk=pins(i=('ulpi_clk', 1)))   # the usb domain's clock: LUNA ties it
        for name, width in (('tx_data', 8), ('tx_valid', 1), ('tx_last', 1), ('tx_ready', 1), ('rx_data', 8), ('rx_valid', 1),
                            ('rx_ready', 1), ('rst', 1)):
            setattr(self, name, Signal(width, name=name))

    def elaborate(self, platform):
        m = Module()
        m.domains.usb = ClockDomain()
        m.d.comb += ResetSignal('usb').eq(self.rst)
        m.submodules.serial = serial = USBSerialDevice(bus=self.ulpi, idVendor=0x1209, idProduct=0x0001,
                                                       manufacturer_string='CatchChallenger',
                                                       product_string='GPON in-line sniffer', max_packet_size=512)
        m.d.comb += [
            serial.connect.eq(1),
            serial.tx.payload.eq(self.tx_data), serial.tx.valid.eq(self.tx_valid), serial.tx.last.eq(self.tx_last),
            self.tx_ready.eq(serial.tx.ready),
            self.rx_data.eq(serial.rx.payload), self.rx_valid.eq(serial.rx.valid), serial.rx.ready.eq(self.rx_ready),
        ]
        return m


if __name__ == '__main__':
    top = UsbSerial()
    u = top.ulpi
    ports = [u.clk.i, top.rst, u.data.i, u.data.o, u.data.oe, u.dir.i, u.nxt.i, u.stp.o, u.rst.o,
             top.tx_data, top.tx_valid, top.tx_last, top.tx_ready, top.rx_data, top.rx_valid, top.rx_ready]
    with open(sys.argv[1], 'w') as f:
        f.write(verilog.convert(top, name='usb_serial', ports=ports))
