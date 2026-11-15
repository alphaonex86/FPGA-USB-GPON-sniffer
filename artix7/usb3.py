# SPDX-License-Identifier: CERN-OHL-S-2.0
"""Writes usb3.v: LUNA's SuperSpeed device on one GTP lane, a bulk IN pipe of 32-bit words (the wide dump). The quad's
one GTPE2_COMMON is in the Verilog top: PLL1 (2.5 GHz from 125 MHz) comes in as pll_clk / pll_refclk / pll_lock, the
PHY asks its reset by pll_reset. `clk` is that same 125 MHz (the words must leave at the lane's rate), `rst` its reset.
A word of the stream: 4 bytes, the first sent in data[7:0].
Usage: python usb3.py OUT.v  (with amaranth and luna-usb patched by luna.patch, see build.sh)"""
import sys
from types import SimpleNamespace
from amaranth import Array, Cat, ClockDomain, ClockSignal, Const, Elaboratable, Module, Mux, ResetSignal, Signal
from amaranth.back import verilog
from amaranth.lib.memory import Memory
from usb_protocol.emitters import SuperSpeedDeviceDescriptorCollection
from luna.usb3 import USBSuperSpeedDevice
from luna.gateware.usb.usb3.protocol.endpoint import SuperSpeedEndpointInterface
from luna.gateware.interface.pipe import AsyncPIPEInterface
from luna.gateware.interface.serdes_phy import xc7_gtp

CLOCK = 125e6
ENDPOINT, PACKET = 1, 1024
SLOTS, WORDS = 16, PACKET // 4   # one slot per packet of the largest burst
if not hasattr(SuperSpeedEndpointInterface(), 'tx_end_of_burst'):
    sys.exit('LUNA is not patched: build.sh applies luna.patch')


class SharedPll(xc7_gtp.GTPQuadPLL):
    """LUNA's PLL without its GTPE2_COMMON: the top's PLL1, by the signals in `pins`."""
    pins = None

    def __init__(self, refclk, refclk_freq, linerate):
        super().__init__(refclk, refclk_freq, linerate, channel=1)
        self.clk, self.refclk, self.lock, self.reset = self.pins

    def elaborate(self, platform):
        return Module()


class FieldController(xc7_gtp.DRPFieldController):
    """LUNA 0.2.3's own constructor fails (`init=reset`, a name it does not have): the same, with its argument."""
    def __init__(self, *, addr, bits, init=0):
        self._addr, self._bits = addr, bits
        self.drp = xc7_gtp.DRPInterface()
        self.value = Signal(bits.stop - bits.start, init=init)


xc7_gtp.GTPQuadPLL = SharedPll
xc7_gtp.DRPFieldController = FieldController


class Constraints:
    """The platform LUNA asks for clock constraints: the Verilog top's XDC has them."""
    def add_clock_constraint(self, clock, frequency):
        pass


def descriptors():
    d = SuperSpeedDeviceDescriptorCollection()
    with d.DeviceDescriptor() as dev:
        dev.idVendor, dev.idProduct = 0x1209, 0x0002
        dev.bcdUSB = 3.2
        dev.bMaxPacketSize0 = 9   # 2^9 bytes
        dev.iManufacturer, dev.iProduct = 'CatchChallenger', 'GPON in-line sniffer dump'
        dev.bNumConfigurations = 1
    with d.ConfigurationDescriptor() as conf:
        conf.bMaxPower = 112      # 900 mA in 8 mA units
        with conf.InterfaceDescriptor() as intf:
            intf.bInterfaceNumber = 0
            intf.bInterfaceClass = 0xFF
            with intf.EndpointDescriptor() as ep:
                ep.bEndpointAddress = 0x80 | ENDPOINT
                ep.wMaxPacketSize = PACKET
                with ep.SuperSpeedCompanion() as companion:
                    companion.bMaxBurst = SLOTS - 1
    return d


class BurstInEndpoint(Elaboratable):
    """Bulk IN endpoint that bursts. Words go into a ring of SLOTS packets, the slot is the packet's sequence number:
    a packet stays until the host acknowledges it and is sent again from there when the host asks (Rty).
    A packet leaves full, or `flush` clocks after its first word (short, it ends the host's transfer; after a full
    one with nothing behind, a zero-length packet does). The host's ACK gives the window (its sequence + NumP).
    The last packet we have carries End Of Burst: the host then waits for our ERDY, as after an NRDY.
    Packets still not acknowledged `stale` clocks after the last one were not heard (a transfer cancelled): they go
    again, at once when the host asked meanwhile, else at its next request."""
    GAP = 8   # clocks between two packets: LUNA's transmitter takes the next header's fields when valid rises again

    def __init__(self, number, flush=int(CLOCK * 1e-3), stale=int(CLOCK * 100e-6)):
        self.number, self.flush, self.stale = number, flush, stale
        self.data, self.valid, self.ready = Signal(32), Signal(), Signal()
        self.interface = SuperSpeedEndpointInterface()

    def elaborate(self, platform):
        m = Module()
        bus, tx, ack, reply = self.interface, self.interface.tx, self.interface.handshakes_in, self.interface.handshakes_out
        m.submodules.ring = ring = Memory(shape=32, depth=SLOTS * WORDS, init=[])
        write, read = ring.write_port(domain='ss'), ring.read_port(domain='ss')
        length = Array(Signal(range(WORDS + 1), name=f'length{i}') for i in range(SLOTS))   # in words
        wr_seq, ack_seq, tx_seq, limit = (Signal(5, name=n) for n in ('wr_seq', 'ack_seq', 'tx_seq', 'limit'))
        fill, age, unended = Signal(range(WORDS)), Signal(range(self.flush + 1)), Signal()
        ended, flow, nrdy, erdy_sent, asked = (Signal(name=n) for n in ('ended', 'flow', 'nrdy', 'erdy_sent', 'asked'))
        since = Signal(range(self.stale + 1))
        behind = lambda a, b: (a - b)[:5]

        # Filling: a packet closes full, or by age (unended: full packets went and no short one closed the transfer)
        take, full = self.valid & self.ready, Signal()
        flush = ~take & self.ready & (age == self.flush)
        m.d.comb += [self.ready.eq(behind(wr_seq, ack_seq) < SLOTS), full.eq(take & (fill == WORDS - 1)),
                     write.addr.eq(Cat(fill, wr_seq[:4])), write.data.eq(self.data), write.en.eq(take)]
        with m.If(take):
            m.d.ss += fill.eq(fill + 1)
        with m.If(full | flush):
            m.d.ss += [length[wr_seq[:4]].eq(Mux(full, WORDS, fill)), wr_seq.eq(wr_seq + 1), fill.eq(0),
                       unended.eq(full), age.eq(0)]
        with m.Elif(((fill != 0) | take | unended) & (age != self.flush)):
            m.d.ss += age.eq(age + 1)

        # NRDY, then ERDY once a packet waits (and the End Of Burst packet has left: the host must see it first)
        idle = Signal()
        m.d.comb += [reply.endpoint_number.eq(self.number), reply.send_nrdy.eq(nrdy),
                     reply.send_erdy.eq(~nrdy & flow & (tx_seq != wr_seq) & ~erdy_sent & idle)]
        with m.If(reply.ready):
            m.d.ss += nrdy.eq(0)
            with m.If(reply.send_erdy):
                m.d.ss += erdy_sent.eq(1)

        # The host's ACK: it has all before `seq` and takes `count` from there; all we sent when seq is tx_seq
        seq, count = ack.next_sequence, ack.number_of_packets
        to_us = ack.ack_received & (ack.endpoint_number == self.number) & (behind(seq, ack_seq) <= behind(tx_seq, ack_seq))
        retry = to_us & ack.retry_required & (seq != tx_seq)
        with m.If(to_us):
            m.d.ss += [ack_seq.eq(seq), limit.eq(seq + count), asked.eq((count != 0) & (seq != tx_seq))]
            with m.If(seq == tx_seq):
                m.d.ss += ended.eq(0)
                with m.If(count != 0):
                    m.d.ss += [flow.eq(seq == wr_seq), nrdy.eq(seq == wr_seq), erdy_sent.eq(0)]
        with m.If(since != self.stale):
            m.d.ss += since.eq(since + 1)

        # Sending
        cur, words, pos, gap = Signal(5), Signal(range(WORDS + 1)), Signal(range(WORDS + 1)), Signal(range(self.GAP))
        eob, start, window = Signal(), Signal(), behind(limit, tx_seq)
        m.d.comb += [bus.tx_endpoint_number.eq(self.number), bus.tx_sequence_number.eq(cur), bus.tx_length.eq(words << 2),
                     bus.tx_end_of_burst.eq(eob), read.addr.eq(Cat(pos[:8], cur[:4]))]
        with m.FSM(domain='ss'):
            with m.State('IDLE'):
                m.d.comb += [idle.eq(1), read.addr.eq(Cat(Const(0, 8), tx_seq[:4]))]
                with m.If((tx_seq != wr_seq) & (window != 0) & (window <= SLOTS) & ~ended & ~flow):
                    short, alone = length[tx_seq[:4]] != WORDS, (tx_seq + 1)[:5] == wr_seq
                    m.d.comb += start.eq(1)
                    m.d.ss += [cur.eq(tx_seq), words.eq(length[tx_seq[:4]]), eob.eq(alone & ~short), pos.eq(0),
                               tx_seq.eq(tx_seq + 1), ended.eq(short | alone)]
                    with m.If(alone & ~short):
                        m.d.ss += [flow.eq(1), erdy_sent.eq(0)]
                    m.next = 'SEND'
                    with m.If(length[tx_seq[:4]] == 0):
                        m.next = 'ZLP'
            with m.State('SEND'):
                m.d.ss += since.eq(0)
                with m.If(~tx.valid.any() | tx.ready):
                    m.d.comb += read.addr.eq(Cat((pos + 1)[:8], cur[:4]))
                    m.d.ss += [pos.eq(pos + 1), tx.data.eq(read.data), tx.valid.eq(0b1111), tx.first.eq(pos == 0),
                               tx.last.eq(pos == words - 1)]
                    with m.If(pos == words - 1):
                        m.next = 'END'
            with m.State('END'):
                m.d.ss += since.eq(0)
                with m.If(tx.ready):
                    m.d.ss += [tx.valid.eq(0), gap.eq(self.GAP - 1)]
                    m.next = 'GAP'
            with m.State('ZLP'):
                m.d.comb += bus.tx_zlp.eq(1)
                m.d.ss += [since.eq(0), gap.eq(self.GAP - 1)]
                m.next = 'GAP'
            with m.State('GAP'):
                m.d.ss += gap.eq(gap - 1)
                with m.If(gap == 0):
                    m.next = 'IDLE'

        with m.If(idle & ~start & (tx_seq != ack_seq) & (since == self.stale)):   # not heard
            m.d.ss += [tx_seq.eq(ack_seq), ended.eq(0), flow.eq(0), asked.eq(0)]
            with m.If(~asked):
                m.d.ss += limit.eq(ack_seq)
        with m.If(retry):   # after the state machine: a packet starting this clock does not count
            m.d.ss += [tx_seq.eq(seq), ended.eq(0), flow.eq(0)]
        with m.If(bus.ep_reset):
            m.d.ss += [s.eq(0) for s in (wr_seq, ack_seq, tx_seq, limit, fill, age, unended, ended, flow, nrdy, erdy_sent, asked)]
        return m


class Usb3(Elaboratable):
    def __init__(self):
        def sig(name, width=1):
            return Signal(width, name=name)
        self.clk, self.rst = sig('clk'), sig('rst')
        self.pll = [sig('pll_clk'), sig('pll_refclk'), sig('pll_lock'), sig('pll_reset')]
        self.tx = SimpleNamespace(p=sig('tx_p'), n=sig('tx_n'))
        self.rx = SimpleNamespace(p=sig('rx_p'), n=sig('rx_n'))
        self.data, self.valid, self.ready = sig('data', 32), sig('valid'), sig('ready')
        self.trained = sig('trained')

    def ports(self):
        return [self.clk, self.rst, *self.pll, self.tx.p, self.tx.n, self.rx.p, self.rx.n, self.data, self.valid,
                self.ready, self.trained]

    def elaborate(self, platform):
        m = Module()
        for name in ('ss', 'sync'):   # LUNA's link in ss, its PHY bring-up timers in sync: one clock here
            m.domains += ClockDomain(name)
            m.d.comb += [ClockSignal(name).eq(self.clk), ResetSignal(name).eq(self.rst)]
        SharedPll.pins = self.pll
        m.submodules.serdes = serdes = xc7_gtp.XC7GTPSerDesPIPE(tx_pads=self.tx, rx_pads=self.rx,
                                                              refclk_frequency=CLOCK, ss_clock_frequency=CLOCK)
        m.submodules.phy = phy = AsyncPIPEInterface(serdes, width=4, domain='ss')
        m.submodules.usb = usb = USBSuperSpeedDevice(phy=phy, sync_frequency=CLOCK)
        usb.add_standard_control_endpoint(descriptors())
        dump = BurstInEndpoint(ENDPOINT)
        usb.add_endpoint(dump)
        m.d.comb += [dump.data.eq(self.data), dump.valid.eq(self.valid), self.ready.eq(dump.ready),
                     self.trained.eq(usb.link_trained)]
        return m


if __name__ == '__main__':
    top = Usb3()
    with open(sys.argv[1], 'w') as f:
        f.write(verilog.convert(top, name='usb3', ports=top.ports(), platform=Constraints()))
