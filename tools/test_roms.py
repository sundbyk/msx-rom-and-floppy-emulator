"""Start every rom on the SD card in openMSX the way the board presents it, and see what is on the screen.

    python tools/test_roms.py --openmsx D:/winapps/OpenMSX/openmsx.exe --sd D:/winapps/OpenMSX/sd \
        --out sd-rapport/test_roms -j 6 [--reference] [rom ...]

The extension picks the mapper, as in util.c get_romtype_from_filename():
.konami4 .konami5 .ascii8 .ascii16 run with that openMSX romtype. Anything else is generic, and
for those the 64K the MSX sees in the slot is built here as the board shows it (an 8K or 16K rom at
0x4000 or 0x8000 with 0xFF round it, a bigger one as banks 0-3 at 0x4000-0xBFFF and the same again
at 0x0000 and 0xC000, so only its first 32K shows) and run as a 64K Normal0000 rom.

Roms below msx/MSX2 start on a Philips NMS 8250, below msx/MSX+ on a Panasonic FS-A1WSX, below
msx/TurboR on a Panasonic FS-A1GT, the rest on a Philips VG-8020.
--reference starts the files as they are and lets openMSX pick the mapper from its database, so the
two can be compared (report.html puts the roms whose result differs first).
"""
import argparse, csv, html, os, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_disks import minimised, verdict

MACHINES = {'MSX1': ['-machine', 'Philips_VG_8020'],
            'MSX2': ['-machine', 'Philips_NMS_8250'],
            'MSX+': ['-machine', 'Panasonic_FS-A1WSX'],
            'TurboR': ['-machine', 'Panasonic_FS-A1GT']}
ROMTYPES = {'.konami4': 'Konami', '.konami5': 'KonamiSCC', '.ascii8': 'ASCII8', '.ascii16': 'ASCII16'}
ROM_EXT = ('.rom', '.mx1', '.mx2', '.ri') + tuple(ROMTYPES)

TCL = r'''
after realtime %(limit)d {exit}
set throttle off
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


def board_view(rom):
    """The 64K the MSX sees for a generic rom (util.c load_rom and the EXTI2 read code)"""
    rom = rom[:0x10000]
    if len(rom) <= 0x4000:
        base = 0
        if len(rom) >= 0x10 and rom[:2] == b'AB':
            for p in range(2, 10, 2):
                if 0x8000 <= rom[p] | rom[p + 1] << 8 < 0xC000:
                    base = 0x4000
        low = bytearray(b'\xff' * 0x10000)
        low[base:base + len(rom)] = rom
        if len(rom) <= 0x2000:
            low[base + 0x2000:base + 0x4000] = low[base:base + 0x2000]
    else:
        low = bytearray(rom) + b'\xff' * (0x10000 - len(rom))
    # A15-A13 -> bank: 0x4000 bank 0, 0x6000 1, 0x8000 2, 0xA000 3, and round again every 32K
    banks = [low[b * 0x2000:(b + 1) * 0x2000] for b in range(4)]
    view = bytearray()
    for a in range(0, 0x10000, 0x2000):
        view += banks[((a >> 13) + 2) & 3]
    return bytes(view)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--openmsx', required=True)
    ap.add_argument('--sd', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('-j', type=int, default=4)
    ap.add_argument('--wait', type=int, default=25, help='emulated seconds after power on')
    ap.add_argument('--reference', action='store_true', help='the files as they are, mapper from the openMSX database')
    ap.add_argument('--compare', help='the --out of a --reference run, to put the roms that differ first')
    ap.add_argument('roms', nargs='*')
    args = ap.parse_args()

    roms = [os.path.abspath(r) for r in args.roms]
    if not roms:
        for d, dirs, files in os.walk(os.path.join(args.sd, 'msx')):
            dirs.sort()
            roms += [os.path.join(d, f) for f in sorted(files) if f.lower().endswith(ROM_EXT)]
    out = os.path.abspath(args.out)
    for sub in ('shots', 'result', 'script', 'rom'):
        os.makedirs(os.path.join(out, sub), exist_ok=True)
    items = [('r%04d' % i, r) for i, r in enumerate(roms)]

    def machine(rom):
        parts = os.path.relpath(rom, args.sd).split(os.sep)
        return next((m for m in ('TurboR', 'MSX+', 'MSX2') if m in parts), 'MSX1')

    todo = [(i, r) for i, r in items if not os.path.exists(os.path.join(out, 'result', i + '.txt'))]
    running = []
    started = 0
    while todo or running:
        running = [p for p in running if p.poll() is None]
        while todo and len(running) < args.j:
            i, rom = todo.pop(0)
            script = os.path.join(out, 'script', i + '.tcl')
            with open(script, 'w', encoding='utf-8') as fh:
                fh.write(TCL % dict(limit=120, out=out.replace('\\', '/'), id=i, wait=args.wait))
            ext = os.path.splitext(rom)[1].lower()
            if args.reference:
                media = ['-cart', rom]
            elif ext in ROMTYPES:
                media = ['-cart', rom, '-romtype', ROMTYPES[ext]]
            else:
                img = os.path.join(out, 'rom', i + '.rom')
                open(img, 'wb').write(board_view(open(rom, 'rb').read()))
                media = ['-cart', img, '-romtype', 'Normal0000']
            running.append(subprocess.Popen([args.openmsx] + MACHINES[machine(rom)] + media + ['-script', script],
                                            cwd=os.path.dirname(args.openmsx), startupinfo=minimised()))
            started += 1
        print('\r%d/%d' % (started - len(running), len(items)), end='', flush=True)
        time.sleep(0.5)
    print()

    def result(d, i):
        p = os.path.join(d, 'result', i + '.txt')
        if not os.path.exists(p):
            return 'no result', ''
        lines = open(p, encoding='latin-1').read().splitlines()
        return verdict(lines[0] if lines else '', '\n'.join(lines[1:])), '\n'.join(lines[1:])

    rows = []
    for i, rom in items:
        v, text = result(out, i)
        ref = result(os.path.abspath(args.compare), i)[0] if args.compare else ''
        rows.append((i, os.path.relpath(rom, args.sd), machine(rom), v, ref, text))
    with open(os.path.join(out, 'results.csv'), 'w', newline='', encoding='utf-8') as fh:
        w = csv.writer(fh)
        w.writerow(['id', 'rom', 'machine', 'verdict', 'reference', 'screen text'])
        w.writerows(rows)

    order = {'no result': 0, 'error': 1, 'basic': 2, 'text': 3, 'running': 4}
    rows.sort(key=lambda r: (r[4] == '' or r[3] == r[4], order.get(r[3], 9), r[1].lower()))
    counts = {}
    for r in rows:
        counts[r[3]] = counts.get(r[3], 0) + 1
    ref_dir = os.path.relpath(os.path.abspath(args.compare), out).replace('\\', '/') if args.compare else ''
    with open(os.path.join(out, 'report.html'), 'w', encoding='utf-8') as fh:
        fh.write('<!doctype html><meta charset="utf-8"><title>Rom test</title><style>'
                 'body{font-family:sans-serif;background:#222;color:#ddd} div{display:inline-block;width:%dpx;'
                 'margin:6px;vertical-align:top;font-size:12px} img{width:320px;image-rendering:pixelated}'
                 '.error{color:#f66}.basic{color:#fc6}.text{color:#6cf}.running{color:#6f6}</style>' %
                 (660 if args.compare else 330))
        fh.write('<h1>Rom test%s</h1><p>%s</p>' % (' (reference)' if args.reference else '', ', '.join(
            '%s: %d' % kv for kv in sorted(counts.items(), key=lambda kv: order.get(kv[0], 9)))))
        for i, name, m, v, ref, text in rows:
            refimg = '<img src="%s/shots/%s.png">' % (ref_dir, i) if args.compare else ''
            fh.write('<div><img src="shots/%s.png" title="%s">%s<br><b class="%s">%s</b>%s %s (%s)</div>' %
                     (i, html.escape(text), refimg, v, v, (' / ref <b class="%s">%s</b>' % (ref, ref)) if ref else '',
                      html.escape(name), m))
    print(counts)


if __name__ == '__main__':
    main()
