# SPDX-License-Identifier: CERN-OHL-S-2.0
"""Simulation of usb3.py's burst endpoint against a model of the host: python usb3_test.py (in build.sh's environment)."""
import random, sys
from amaranth import ClockDomain, Elaboratable, Module
from amaranth.sim import Simulator
from usb3 import BurstInEndpoint, ENDPOINT, SLOTS, WORDS

FLUSH, STALE, ANSWER = 200, 600, 50   # clocks; ANSWER: the device's time to answer a request (400 ns)


class Bench(Elaboratable):
    def __init__(self):
        self.dut = BurstInEndpoint(ENDPOINT, flush=FLUSH, stale=STALE)

    def elaborate(self, platform):
        m = Module()
        m.domains.ss = ClockDomain()
        m.submodules.dut = self.dut
        return m


class Host:
    """What a host does with a bulk IN pipe; it complains when the device does what a host would not accept."""
    def __init__(self, rng, errors=0.0, slow=False):
        self.rng, self.errors, self.slow = rng, errors, slow
        self.expected, self.limit, self.mode, self.discard, self.resync = 0, 0, 'idle', False, False
        self.words, self.acks, self.next_request, self.asked, self.last_due = [], [], 0, None, 0
        self.counts = dict(packets=0, short=0, zero=0, eob=0, nrdy=0, erdy=0, retries=0, lost=0, longest=0)
        self.run = 0

    def ack(self, now, count, retry=False):
        self.last_due = max(self.last_due + 1, now + self.rng.randint(2, 40))
        self.acks.append((self.last_due, self.expected, count, retry))
        self.limit = self.expected + count

    def request(self, now):
        self.mode, self.asked = 'wait', None
        self.ack(now, self.rng.randint(1, SLOTS))

    def rest(self, now, mode):
        self.mode, self.run = mode, 0
        self.next_request = now + self.rng.choice([0, 3, 300, 3000] if self.slow else [0, 3, 60])

    def cancel(self, now):
        """The transfer is dropped: nothing is heard until the next one asks again from the packet still expected.
        resync: until that packet comes, another one is answered by a retry request (and no answer time is asked)."""
        self.acks.clear()
        self.mode, self.discard, self.resync, self.asked, self.run = 'deaf', False, True, None, 0
        self.next_request = self.last_due = max(self.last_due, now) + self.rng.choice([3, STALE // 2, 2 * STALE])

    def started(self, now):
        assert self.mode in ('wait', 'deaf'), f'{now}: a packet while the host is {self.mode}'
        self.asked = None

    def packet(self, now, seq, words, eob):
        self.counts['packets'] += 1
        assert len(words) <= WORDS and not (eob and len(words) < WORDS), f'{now}: {len(words)} words, eob {eob}'
        if self.mode == 'deaf':
            self.counts['lost'] += 1
            return
        if self.discard and seq != self.expected % 32:
            return
        if self.resync and seq != self.expected % 32:
            self.counts['retries'] += 1
            self.discard = True
            return self.ack(now, self.rng.randint(1, SLOTS), retry=True)
        self.resync = False
        assert seq == self.expected % 32, f'{now}: packet {seq}, expected {self.expected % 32}'
        assert self.expected < self.limit, f'{now}: packet {seq} beyond the window'
        if self.rng.random() < self.errors:
            self.counts['retries'] += 1
            self.discard = True
            return self.ack(now, self.rng.randint(1, SLOTS), retry=True)
        self.discard = False
        self.words += words
        self.expected += 1
        self.run += 1
        self.counts['longest'] = max(self.counts['longest'], self.run)
        if len(words) < WORDS:
            self.counts['short' if words else 'zero'] += 1
            self.ack(now, 0)
            self.rest(now, 'idle')
        elif eob:
            self.counts['eob'] += 1
            self.ack(now, 0)
            self.rest(now, 'flow')
        else:
            self.ack(now, self.rng.randint(max(0, self.limit - self.expected), SLOTS))
            if self.limit == self.expected:
                self.rest(now, 'idle')

    def handshake(self, now, nrdy, erdy):
        if nrdy:
            self.counts['nrdy'] += 1
            assert self.mode == 'wait' and self.asked is not None, f'{now}: NRDY while the host is {self.mode}'
            self.asked = None
            self.rest(now, 'flow')
        if erdy:
            self.counts['erdy'] += 1
            assert self.mode in ('flow', 'deaf') or self.discard, f'{now}: ERDY while the host is {self.mode}'

    def clock(self, now, erdy, sending):
        """The ACK the device sees this clock, or None; sending: a packet is on its way."""
        if (self.mode in ('idle', 'deaf') or self.mode == 'flow' and erdy) and now >= self.next_request and not self.discard:
            self.request(now)
        if self.acks and self.acks[0][0] <= now:
            _, seq, count, retry = self.acks.pop(0)
            if count and not retry and seq == self.expected and self.mode == 'wait' and not sending and not self.resync:
                self.asked = now
            return seq, count, retry
        assert self.asked is None or now - self.asked <= ANSWER, f'{now}: request of {self.asked} not answered'
        return None


def simulate(name, source, host, clocks, cancels=()):
    """source(now) -> True when a word is offered this clock; cancels: the clocks where the host drops its transfer."""
    bench = Bench()
    dut, bus = bench.dut, bench.dut.interface
    sent, rng = [], host.rng

    async def run(ctx):
        packet, erdy_seen = None, False
        ctx.set(bus.handshakes_out.ready, 1)
        for now in range(clocks):
            if now in cancels:
                host.cancel(now)
            ack = host.clock(now, erdy_seen, packet is not None)
            erdy_seen = erdy_seen and host.mode == 'flow'
            seq, count, retry = ack or (0, 0, False)
            ctx.set(bus.handshakes_in.ack_received, ack is not None)
            ctx.set(bus.handshakes_in.endpoint_number, ENDPOINT)
            ctx.set(bus.handshakes_in.next_sequence, seq % 32)
            ctx.set(bus.handshakes_in.number_of_packets, count)
            ctx.set(bus.handshakes_in.retry_required, retry)
            ctx.set(dut.valid, source(now))
            ctx.set(dut.data, len(sent))
            ctx.set(bus.tx.ready, rng.random() < 0.9)
            if ctx.get(dut.valid) and ctx.get(dut.ready):
                sent.append(len(sent))
            if ctx.get(bus.tx.valid):
                if packet is None:
                    host.started(now)
                    packet = (ctx.get(bus.tx_sequence_number), ctx.get(bus.tx_length), ctx.get(bus.tx_end_of_burst), [])
                if ctx.get(bus.tx.ready):
                    packet[3].append(ctx.get(bus.tx.data))
                    if ctx.get(bus.tx.last):
                        assert packet[1] == 4 * len(packet[3]), f'{now}: length {packet[1]} for {len(packet[3])} words'
                        host.packet(now, packet[0], packet[3], packet[2])
                        packet = None
            elif ctx.get(bus.tx_zlp):
                assert ctx.get(bus.tx_length) == 0
                host.started(now)
                host.packet(now, ctx.get(bus.tx_sequence_number), [], ctx.get(bus.tx_end_of_burst))
            nrdy, erdy = ctx.get(bus.handshakes_out.send_nrdy), ctx.get(bus.handshakes_out.send_erdy)
            host.handshake(now, nrdy, erdy)
            erdy_seen = erdy_seen or (erdy and host.mode == 'flow')
            await ctx.tick('ss')

    sim = Simulator(bench)
    sim.add_clock(8e-9, domain='ss')
    sim.add_testbench(run)
    sim.run()
    assert host.words == sent, f'{name}: {len(host.words)} words received of {len(sent)} sent'
    print(f'ok   {name}: {len(sent)} words', host.counts)
    return host


def phases(rng, plan):
    """plan: [(clocks, probability of a word per clock)...], then nothing."""
    ends, total = [], 0
    for clocks, p in plan:
        total += clocks
        ends.append((total, p))
    return lambda now: next((rng.random() < p for end, p in ends if now < end), False)


if __name__ == '__main__':
    seed = int(sys.argv[1]) if len(sys.argv) > 1 else 1
    rng = random.Random(seed)
    simulate('trickle: every record leaves within the flush time', phases(rng, [(20000, 0.002)]), Host(rng), 22000)
    full = simulate('full rate, then exactly whole packets', lambda now: now < 40 * WORDS, Host(rng), 16000)
    assert full.counts['longest'] > 4 and full.counts['zero'] == 1, 'no burst, or no zero-length packet after it'
    simulate('mixed rates', phases(rng, [(8000, 1), (3000, 0.01), (8000, 0.4), (2000, 0), (6000, 1)]), Host(rng), 40000)
    slow = simulate('slow host: the ring fills and holds the source', phases(rng, [(30000, 1)]), Host(rng, slow=True), 200000)
    assert len(slow.words) < 30000, 'the source was never held'
    retry = simulate('errors: packets asked again', phases(rng, [(8000, 1), (3000, 0.02), (8000, 0.5)]),
                     Host(rng, errors=0.1), 60000)
    assert retry.counts['retries'] > 3
    again = simulate('transfer cancelled and started again', phases(rng, [(30000, 1)]), Host(rng), 60000,
                     range(2000, 30000, 4000))
    assert again.counts['lost'] > 3, 'no packet was sent into the cancelled transfer'
    print('RESULT PASS')
