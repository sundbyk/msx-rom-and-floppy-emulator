"""Start disk images in openMSX, one after the other, and see what is on the screen after a while.

    python tools/test_disks.py --openmsx D:/winapps/OpenMSX/openmsx.exe --sd D:/winapps/OpenMSX/sd \
        --list sd-rapport/test_list.txt --out sd-rapport/test -j 6

--list has a line per disk: the machine (MSX1/MSX2) and the path below --sd, tab separated (the
first two columns of organise_sd.py's bin_disks.txt). MSX1 disks run on a Philips VG-8020 with an
NMS 1200 disk drive, MSX2 disks on an NMS 8250, MSX+ (MSX2+) on a Panasonic FS-A1WSX and TurboR on a
Panasonic FS-A1GT. openMSX needs their system roms.

For each disk the screen mode, the text on the screen (text modes) and a screenshot are kept.
The verdict:
  error    an error message on a text screen (Disk I/O error, File not found ...)
  basic    back at the BASIC prompt or the MSX-DOS prompt. It may have started and stopped
  text     some other text screen (a menu, a question, a game in text mode)
  running  a graphics screen: most likely the game
report.html shows them all, the doubtful ones first.
"""
import argparse, csv, html, os, subprocess, sys, time

MACHINES = {'MSX1': ['-machine', 'Philips_VG_8020', '-ext', 'Philips_NMS_1200'],
            'MSX2': ['-machine', 'Philips_NMS_8250'],
            'MSX+': ['-machine', 'Panasonic_FS-A1WSX'],
            'TurboR': ['-machine', 'Panasonic_FS-A1GT']}

# One openMSX per disk (given with -diska): switching disks and powering off and on from a
# script left the old game running
TCL = r'''
after realtime %(limit)d {exit}
set throttle off
%(ctrl)s
proc screen_text {} { if {[catch {set t [get_screen]}]} { return "" } ; return $t }
after time %(wait)d {
    catch {screenshot -raw "%(out)s/shots/%(id)s.png"}
    set f [open "%(out)s/result/%(id)s.txt" w]
    puts $f [get_screen_mode]
    puts $f [screen_text]
    close $f
    exit
}
'''


def minimised():
    """On Windows, start the openMSX windows minimised and without taking the focus"""
    if os.name != 'nt':
        return None
    si = subprocess.STARTUPINFO()
    si.dwFlags |= subprocess.STARTF_USESHOWWINDOW
    si.wShowWindow = 7		# SW_SHOWMINNOACTIVE
    return si


ERRORS = ('error', 'not found', 'disk offline', 'bad file', 'out of memory', 'illegal', 'no file')


def verdict(mode, text):
    t = text.lower()
    # openMSX gives SCREEN 1 as GRAPHIC1 or as 1
    if mode.startswith('TEXT') or mode in ('GRAPHIC1', '1'):
        if any(e in t for e in ERRORS):
            return 'error'
        last = [l.strip() for l in text.splitlines() if l.strip()]
        lines = [l for l in last if not set(l.split()) <= {'color', 'auto', 'goto', 'list', 'run', 'load', 'save', 'cont', 'key', 'screen'}]
        if lines and (lines[-1] == 'Ok' or lines[-1].endswith('>')):
            return 'basic'
        return 'text'
    return 'running'


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--openmsx', required=True)
    ap.add_argument('--sd', required=True)
    ap.add_argument('--list', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('-j', type=int, default=4)
    ap.add_argument('--wait', type=int, default=40, help='emulated seconds after power on')
    ap.add_argument('--ctrl', action='store_true',
                    help='hold CTRL while the MSX starts. The disk rom then only sets up one drive, '
                         'which leaves more memory free (many games ask for it)')
    ap.add_argument('--as', dest='as_machine', choices=sorted(MACHINES),
                    help='run every disk on this machine, whatever the list says')
    ap.add_argument('--ext', action='append', default=[],
                    help='an openMSX extension to plug in as well, eg. ram512k (a 512K memory mapper)')
    args = ap.parse_args()

    os.makedirs(os.path.join(args.out, 'shots'), exist_ok=True)
    os.makedirs(os.path.join(args.out, 'result'), exist_ok=True)
    os.makedirs(os.path.join(args.out, 'script'), exist_ok=True)
    items = []
    for line in open(args.list, encoding='utf-8'):
        parts = line.rstrip('\n').split('\t')
        if len(parts) >= 2:
            items.append((parts[0], parts[1]))
    ids = {rel: 'd%04d' % i for i, (m, rel) in enumerate(items)}

    # a few openMSX at a time, one per disk
    todo = [(m, ids[rel], rel) for m, rel in items
            if not os.path.exists(os.path.join(args.out, 'result', ids[rel] + '.txt'))]
    running = []
    started = 0
    while todo or running:
        running = [(p, s) for p, s in running if p.poll() is None]
        while todo and len(running) < args.j:
            machine, i, rel = todo.pop(0)
            script = os.path.join(args.out, 'script', i + '.tcl')
            with open(script, 'w', encoding='utf-8') as fh:
                ctrl = 'keymatrixdown 6 0x02\nafter time 15 {keymatrixup 6 0x02}' if args.ctrl else ''
                fh.write(TCL % dict(limit=90, out=args.out.replace('\\', '/'), id=i, wait=args.wait, ctrl=ctrl))
            p = subprocess.Popen([args.openmsx] + MACHINES[args.as_machine or machine] +
                                 [a for e in args.ext for a in ('-ext', e)] +
                                 ['-diska', os.path.join(args.sd, rel), '-script', script],
                                 cwd=os.path.dirname(args.openmsx), startupinfo=minimised())
            running.append((p, script))
            started += 1
        print('\r%d/%d' % (started - len(running), len(items)), end='', flush=True)
        time.sleep(0.5)
    print()
    rows = []
    for m, rel in items:
        i = ids[rel]
        p = os.path.join(args.out, 'result', i + '.txt')
        if not os.path.exists(p):
            rows.append((i, m, rel, 'no result', ''))
            continue
        lines = open(p, encoding='latin-1').read().splitlines()
        mode = lines[0] if lines else ''
        text = '\n'.join(lines[1:])
        rows.append((i, m, rel, verdict(mode, text), text))
    with open(os.path.join(args.out, 'results.csv'), 'w', newline='', encoding='utf-8') as fh:
        w = csv.writer(fh)
        w.writerow(['id', 'machine', 'disk', 'verdict', 'screen text'])
        w.writerows(rows)

    order = {'no result': 0, 'error': 1, 'basic': 2, 'text': 3, 'running': 4}
    rows.sort(key=lambda r: (order.get(r[3], 9), r[2].lower()))
    with open(os.path.join(args.out, 'report.html'), 'w', encoding='utf-8') as fh:
        counts = {}
        for r in rows:
            counts[r[3]] = counts.get(r[3], 0) + 1
        fh.write('<!doctype html><meta charset="utf-8"><title>Disk test</title><style>'
                 'body{font-family:sans-serif;background:#222;color:#ddd} div{display:inline-block;width:330px;'
                 'margin:6px;vertical-align:top;font-size:12px} img{width:320px;image-rendering:pixelated}'
                 '.error{color:#f66}.basic{color:#fc6}.text{color:#6cf}.running{color:#6f6}</style>')
        fh.write('<h1>Disk test</h1><p>%s</p>' % ', '.join('%s: %d' % kv for kv in sorted(counts.items(), key=lambda kv: order.get(kv[0], 9))))
        for i, m, rel, v, text in rows:
            fh.write('<div><img src="shots/%s.png" title="%s"><br><b class="%s">%s</b> %s %s</div>' %
                     (i, html.escape(text), v, v, m, html.escape(rel)))
    print({k: v for k, v in counts.items()})


if __name__ == '__main__':
    main()
