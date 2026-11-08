"""MIDI -> VGM for the MSX's PSG (AY-3-8910), for the menu's music player.

    python tools/mid2vgm.py song.mid song.vgm [--rate 60] [--stats]

The PSG has three square wave voices and a noise generator, so a MIDI file is boiled down to:
  A  the melody: the highest note playing
  B  the bass: the lowest note playing
  C  the drums (channel 10) as noise when they hit, otherwise the loudest note left
Notes keep their voice while they last, get louder or softer with velocity, channel volume and
expression, and fade a little after they start, so repeated notes can be told apart. Pitch bend
is followed. The VGM has AY8910 writes (command 0xA0) and waits of 1/60 s, at 44100 samples a
second as VGM has it; the player works through it at 50 or 60 Hz, whichever the MSX runs at.
"""
import argparse, math, struct, sys

SAMPLE_RATE = 44100
PSG_CLOCK = 1789773		# 3.579545 MHz / 2 on an MSX
DRUM_CHANNEL = 9


# ---------------------------------------------------------------------------------------------
# MIDI

def vlq(data, i):
    v = 0
    while True:
        b = data[i]
        i += 1
        v = (v << 7) | (b & 0x7F)
        if not b & 0x80:
            return v, i


def read_midi(data):
    """events: (tick, order, kind, channel, a, b) with kind in note, cc, bend, program, tempo"""
    if data[:4] != b'MThd':
        raise ValueError('not a MIDI file')
    hlen = struct.unpack('>I', data[4:8])[0]
    fmt, ntrks, division = struct.unpack('>HHH', data[8:14])
    pos = 8 + hlen
    events = []
    order = 0
    for t in range(ntrks):
        while pos + 8 <= len(data) and data[pos:pos + 4] != b'MTrk':
            pos += 8 + struct.unpack('>I', data[pos + 4:pos + 8])[0]
        if pos + 8 > len(data):
            break
        tlen = struct.unpack('>I', data[pos + 4:pos + 8])[0]
        i, end = pos + 8, min(pos + 8 + tlen, len(data))
        pos = end
        tick = 0
        status = 0
        while i < end:
            delta, i = vlq(data, i)
            tick += delta
            b = data[i]
            if b & 0x80:
                status = b
                i += 1
            if status == 0xFF:
                kind = data[i]
                n, i = vlq(data, i + 1)
                if kind == 0x51 and n == 3:
                    events.append((tick, order, 'tempo', 0, int.from_bytes(data[i:i + 3], 'big'), 0))
                i += n
                if kind == 0x2F:
                    break
                continue
            if status in (0xF0, 0xF7):
                n, i = vlq(data, i)
                i += n
                continue
            hi, ch = status & 0xF0, status & 0x0F
            if hi in (0xC0, 0xD0):
                a = data[i]
                i += 1
                if hi == 0xC0:
                    events.append((tick, order, 'program', ch, a, 0))
            else:
                a, b2 = data[i], data[i + 1]
                i += 2
                if hi == 0x90 and b2 > 0:
                    events.append((tick, order, 'on', ch, a, b2))
                elif hi == 0x80 or hi == 0x90:
                    events.append((tick, order, 'off', ch, a, 0))
                elif hi == 0xB0:
                    events.append((tick, order, 'cc', ch, a, b2))
                elif hi == 0xE0:
                    events.append((tick, order, 'bend', ch, a | (b2 << 7), 0))
            order += 1
    events.sort(key=lambda e: (e[0], e[1]))
    # ticks -> seconds with the tempo map
    if division & 0x8000:
        fps = 256 - (division >> 8)
        per_tick = 1.0 / (fps * (division & 0xFF))
        return [(e[0] * per_tick,) + e[2:] for e in events if e[2] != 'tempo']
    out = []
    tempo = 500000
    last_tick, last_sec = 0, 0.0
    for e in events:
        sec = last_sec + (e[0] - last_tick) * tempo / 1e6 / division
        last_tick, last_sec = e[0], sec
        if e[2] == 'tempo':
            tempo = e[4]
        else:
            out.append((sec,) + e[2:])
    return out


class Note:
    __slots__ = ('start', 'end', 'ch', 'key', 'vel', 'loud')

    def __init__(self, start, ch, key, vel):
        self.start, self.end, self.ch, self.key, self.vel = start, None, ch, key, vel
        self.loud = 1.0


def notes_of(events):
    """Notes with their loudness (velocity x volume x expression), and the pitch bend of each
    channel over time as a list of (time, semitones)"""
    playing = {}
    notes = []
    volume = [100] * 16
    expression = [127] * 16
    bend_range = [2.0] * 16
    rpn = [(127, 127)] * 16
    bends = [[(0.0, 0.0)] for _ in range(16)]
    for t, kind, ch, a, b in events:
        if kind == 'on':
            old = playing.pop((ch, a), None)
            if old:
                old.end = t
            n = Note(t, ch, a, b)
            n.loud = (b / 127.0) * (volume[ch] / 127.0) * (expression[ch] / 127.0)
            playing[(ch, a)] = n
            notes.append(n)
        elif kind == 'off':
            n = playing.pop((ch, a), None)
            if n:
                n.end = t
        elif kind == 'cc':
            if a == 7:
                volume[ch] = b
            elif a == 11:
                expression[ch] = b
            elif a == 101:
                rpn[ch] = (b, rpn[ch][1])
            elif a == 100:
                rpn[ch] = (rpn[ch][0], b)
            elif a == 6 and rpn[ch] == (0, 0):
                bend_range[ch] = float(b)
            elif a in (120, 123):
                for k in [k for k in playing if k[0] == ch]:
                    playing.pop(k).end = t
        elif kind == 'bend':
            bends[ch].append((t, (a - 8192) / 8192.0 * bend_range[ch]))
    end = max([e[0] for e in events] + [0.0])
    for n in playing.values():
        n.end = end
    notes = [n for n in notes if n.end > n.start]
    return notes, bends


# ---------------------------------------------------------------------------------------------
# PSG

def tone_period(key, bend=0.0):
    f = 440.0 * 2 ** ((key + bend - 69) / 12.0)
    return max(1, min(4095, int(round(PSG_CLOCK / (16.0 * f)))))


def volume_of(loud, age, rate):
    """PSG volume (0-15, about 3 dB a step) for a note this loud, age seconds after it started:
    a little louder at the start, then down 2 steps over the first half second"""
    if loud <= 0:
        return 0
    v = 15 + 2 * math.log2(loud)
    v -= min(2.0, age * 4.0)
    return max(0, min(15, int(round(v))))


# GM drum keys -> (noise period, start volume, how fast it fades in steps a frame, low tone or not)
def drum_sound(key):
    if key in (35, 36):			# bass drum
        return 28, 14, 3.0
    if key in (37, 38, 39, 40):		# snare, clap
        return 10, 14, 2.0
    if key in (42, 44, 51, 53, 59):	# closed hi-hat, ride
        return 1, 11, 4.0
    if key in (46, 49, 52, 55, 57):	# open hi-hat, crash
        return 2, 12, 1.0
    if 41 <= key <= 50:			# toms
        return 18, 13, 2.5
    return 6, 10, 3.0


def convert(midi, rate=60):
    events = read_midi(midi)
    notes, bends = notes_of(events)
    tones = [n for n in notes if n.ch != DRUM_CHANNEL]
    drums = sorted([n for n in notes if n.ch == DRUM_CHANNEL], key=lambda n: n.start)
    length = max([n.end for n in notes] + [0.0])
    steps = int(length * rate) + rate // 2
    tones.sort(key=lambda n: n.start)
    # a little louder overall: the loudest note should be near full volume
    top = max([n.loud for n in tones] + [0.01])
    for n in tones:
        n.loud = min(1.0, n.loud / top)

    def bend_at(ch, t):
        b = 0.0
        for when, v in bends[ch]:
            if when > t:
                break
            b = v
        return b

    regs = [None] * 14
    out = bytearray()
    wait = 0
    voices = [None, None, None]		# the note on A, B, C
    di = 0
    drum = None				# (start step, noise period, volume, fade)
    ni = 0
    playing = []
    for step in range(steps):
        t = step / float(rate)
        # notes playing now, and drums that just hit
        while ni < len(tones) and tones[ni].start <= t:
            playing.append(tones[ni])
            ni += 1
        playing = [n for n in playing if n.end > t]
        while di < len(drums) and drums[di].start <= t:
            p, v, f = drum_sound(drums[di].key)
            v = max(0, v + 2 * math.log2(max(0.01, drums[di].vel / 127.0)))
            if drum is None or v >= drum[2] - (step - drum[0]) * drum[3]:
                drum = (step, p, v, f)
            di += 1
        drum_vol = 0
        if drum:
            drum_vol = int(round(drum[2] - (step - drum[0]) * drum[3]))
            if drum_vol <= 0:
                drum, drum_vol = None, 0
        # A melody, B bass, C the next one (unless a drum sounds)
        want = [None, None, None]
        if playing:
            by_key = sorted(playing, key=lambda n: (n.key, n.loud))
            want[0] = by_key[-1]
            if len(by_key) > 1:
                want[1] = by_key[0]
            if len(by_key) > 2 and not drum_vol:
                rest = [n for n in by_key[1:-1]]
                keep = voices[2] if voices[2] in rest else None
                want[2] = keep or max(rest, key=lambda n: (n.loud, n.start))
        voices = want
        new = [None] * 14
        mixer = 0xB8			# tone A, B, C on, noise off (bit 7 port B out, 6 port A in)
        for v in range(3):
            n = voices[v]
            if v == 2 and drum_vol:
                new[6] = drum[1]
                new[10] = drum_vol
                mixer = (mixer | 0x04) & ~0x20	# C: noise, no tone
                continue
            if n is None:
                new[8 + v] = 0
                continue
            p = tone_period(n.key, bend_at(n.ch, t))
            new[v * 2] = p & 0xFF
            new[v * 2 + 1] = p >> 8
            new[8 + v] = volume_of(n.loud, t - n.start, rate)
        new[7] = mixer
        changes = []
        for r in range(14):
            if new[r] is not None and new[r] != regs[r]:
                changes.append((r, new[r]))
                regs[r] = new[r]
        if changes:
            out += wait_bytes(wait)
            wait = 0
            for r, v in changes:
                out += bytes((0xA0, r, v))
        wait += SAMPLE_RATE // rate
    out += wait_bytes(wait)
    for r in (8, 9, 10):
        out += bytes((0xA0, r, 0))
    out.append(0x66)
    return vgm_file(out, steps * (SAMPLE_RATE // rate)), {
        'notes': len(tones), 'drums': len(drums), 'seconds': round(length, 1),
        'channels': sorted({n.ch + 1 for n in notes})}


def wait_bytes(samples):
    out = bytearray()
    while samples > 0:
        if samples == 735:
            out.append(0x62)
            samples = 0
        elif samples == 882:
            out.append(0x63)
            samples = 0
        elif samples <= 16:
            out.append(0x70 + samples - 1)
            samples = 0
        else:
            n = min(samples, 0xFFFF)
            out += bytes((0x61, n & 0xFF, n >> 8))
            samples -= n
    return out


def vgm_file(data, samples):
    """A VGM 1.51 file with an AY8910 at the MSX's clock, no loop"""
    h = bytearray(0x80)
    h[0:4] = b'Vgm '
    struct.pack_into('<I', h, 0x04, 0x80 + len(data) - 4)
    struct.pack_into('<I', h, 0x08, 0x151)
    struct.pack_into('<I', h, 0x18, samples)
    struct.pack_into('<I', h, 0x34, 0x80 - 0x34)
    struct.pack_into('<I', h, 0x74, PSG_CLOCK)
    h[0x78] = 0x00				# AY8910
    h[0x79] = 0x01				# legacy output
    return bytes(h + data)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('mid')
    ap.add_argument('vgm')
    ap.add_argument('--rate', type=int, default=60, choices=(50, 60))
    ap.add_argument('--stats', action='store_true')
    args = ap.parse_args()
    vgm, stats = convert(open(args.mid, 'rb').read(), args.rate)
    open(args.vgm, 'wb').write(vgm)
    if args.stats:
        print(args.mid, len(vgm), stats)


if __name__ == '__main__':
    main()
