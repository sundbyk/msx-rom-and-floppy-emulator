"""Load .cas tapes in openMSX the way the KCMFS menu does, and see what is on the screen after a while.

    python tools/test_tapes.py --openmsx D:/winapps/OpenMSX/openmsx.exe --sd D:/winapps/OpenMSX/sd \
        --out sd-rapport/test_tapes -j 6 [--as MSX2] [tape.cas ...]

Without tapes named, every .cas below --sd/msx is tried. Each one is put in a copy of
kcmfs/menu-simtape.rom (an ASCII8 rom with the tape from bank 8 on, where the board would have
it) and started on a Philips VG-8020 (MSX1, no disk drive) or with --as MSX2 an NMS 8250. The
menu's tape code puts the BIOS in RAM with its own TAPION and TAPIN and types the command that
loads the tape, as it does on the board.

--reference loads them with openMSX's own cassette player instead (autoruncassettes), to tell a
tape that does not work at all from one that does not work this way.

The verdicts are as in test_disks.py; report.html shows them all, the doubtful ones first.
"""
import argparse, csv, html, os, struct, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_disks import minimised, verdict

MACHINES = {'MSX1': ['-machine', 'Philips_VG_8020'],
            'MSX2': ['-machine', 'Philips_NMS_8250']}
BANK = 0x2000
TAPE_BANK_FIRST = 8
SIZE_AT = 0x1FFC		# sim_tape_size in menu-simtape.rom

# openMSX runs flat out, then at normal speed for a moment so the screenshot is of the screen as it is
TCL = r'''
after realtime %(limit)d {exit}
set throttle off
%(shift)s
proc screen_text {} { if {[catch {set t [get_screen]}]} { return "" } ; return $t }
after time %(wait)d {
    set throttle on
    after realtime 1 {
        catch {screenshot -raw "%(out)s/shots/%(id)s.png"}
        set f [open "%(out)s/result/%(id)s.txt" w]
        puts $f [get_screen_mode]
        puts $f [screen_text]
        close $f
        exit
    }
}
'''

# openMSX's own cassette player, which types the command that loads the tape
REFERENCE = r'''
set autoruncassettes on
cassetteplayer insert {%(tape)s}
reset
'''


def make_rom(base, cas):
    rom = bytearray(base)
    rom += b'\xff' * (TAPE_BANK_FIRST * BANK - len(rom))
    rom += cas
    rom += b'\xff' * (-len(rom) % BANK)
    rom[SIZE_AT:SIZE_AT + 4] = struct.pack('<I', len(cas))
    return bytes(rom)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--openmsx', required=True)
    ap.add_argument('--sd', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--rom', default=os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'kcmfs', 'menu-simtape.rom'))
    ap.add_argument('-j', type=int, default=4)
    ap.add_argument('--wait', type=int, default=90, help='emulated seconds after power on')
    ap.add_argument('--as', dest='as_machine', choices=sorted(MACHINES), default='MSX1')
    ap.add_argument('--reference', action='store_true', help="openMSX's cassette player instead of KCMFS")
    ap.add_argument('--shift', action='store_true',
                    help='hold SHIFT while the MSX starts, so a disk ROM is left out (a name without CAS: '
                         'then means the tape, as on an MSX without disks)')
    ap.add_argument('tapes', nargs='*')
    args = ap.parse_args()

    base = open(args.rom, 'rb').read()
    tapes = args.tapes
    if not tapes:
        for d, dirs, files in os.walk(os.path.join(args.sd, 'msx')):
            dirs.sort()
            tapes += [os.path.join(d, f) for f in sorted(files) if f.lower().endswith('.cas')]
    for sub in ('shots', 'result', 'script', 'rom'):
        os.makedirs(os.path.join(args.out, sub), exist_ok=True)
    items = [(('t%04d' % i), t) for i, t in enumerate(tapes)]

    todo = [(i, t) for i, t in items if not os.path.exists(os.path.join(args.out, 'result', i + '.txt'))]
    running = []
    started = 0
    while todo or running:
        running = [p for p in running if p.poll() is None]
        while todo and len(running) < args.j:
            i, tape = todo.pop(0)
            script = os.path.join(args.out, 'script', i + '.tcl')
            with open(script, 'w', encoding='utf-8') as fh:
                if args.reference:
                    fh.write(REFERENCE % dict(tape=os.path.abspath(tape).replace('\\', '/')))
                shift = 'keymatrixdown 6 0x01\nafter time 15 {keymatrixup 6 0x01}' if args.shift else ''
                fh.write(TCL % dict(limit=900 if args.reference else 150, out=args.out.replace('\\', '/'), id=i,
                                    wait=args.wait, shift=shift))
            if args.reference:
                media = []
            else:
                rom = os.path.join(args.out, 'rom', i + '.rom')
                open(rom, 'wb').write(make_rom(base, open(tape, 'rb').read()))
                media = ['-cart', rom, '-romtype', 'ASCII8']
            running.append(subprocess.Popen([args.openmsx] + MACHINES[args.as_machine] + media + ['-script', script],
                                            cwd=os.path.dirname(args.openmsx), startupinfo=minimised()))
            started += 1
        print('\r%d/%d' % (started - len(running), len(items)), end='', flush=True)
        time.sleep(0.5)
    print()

    rows = []
    for i, tape in items:
        name = os.path.relpath(tape, args.sd)
        p = os.path.join(args.out, 'result', i + '.txt')
        if not os.path.exists(p):
            rows.append((i, name, 'no result', ''))
            continue
        lines = open(p, encoding='latin-1').read().splitlines()
        mode = lines[0] if lines else ''
        text = '\n'.join(lines[1:])
        rows.append((i, name, verdict(mode, text), text))
    with open(os.path.join(args.out, 'results.csv'), 'w', newline='', encoding='utf-8') as fh:
        w = csv.writer(fh)
        w.writerow(['id', 'tape', 'verdict', 'screen text'])
        w.writerows(rows)

    order = {'no result': 0, 'error': 1, 'basic': 2, 'text': 3, 'running': 4}
    rows.sort(key=lambda r: (order.get(r[2], 9), r[1].lower()))
    counts = {}
    for r in rows:
        counts[r[2]] = counts.get(r[2], 0) + 1
    with open(os.path.join(args.out, 'report.html'), 'w', encoding='utf-8') as fh:
        fh.write('<!doctype html><meta charset="utf-8"><title>Tape test</title><style>'
                 'body{font-family:sans-serif;background:#222;color:#ddd} div{display:inline-block;width:330px;'
                 'margin:6px;vertical-align:top;font-size:12px} img{width:320px;image-rendering:pixelated}'
                 '.error{color:#f66}.basic{color:#fc6}.text{color:#6cf}.running{color:#6f6}</style>')
        fh.write('<h1>Tape test (%s%s)</h1><p>%s</p>' % (args.as_machine, ', reference' if args.reference else '', ', '.join(
            '%s: %d' % kv for kv in sorted(counts.items(), key=lambda kv: order.get(kv[0], 9)))))
        for i, name, v, text in rows:
            fh.write('<div><img src="shots/%s.png" title="%s"><br><b class="%s">%s</b> %s</div>' %
                     (i, html.escape(text), v, v, html.escape(name)))
    print(counts)


if __name__ == '__main__':
    main()
