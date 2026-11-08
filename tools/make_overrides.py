"""overrides.csv for organise_sd.py, from test_disks.py runs.

    python tools/make_overrides.py --report sd-rapport --out sd-rapport/overrides.csv \
        test test_ctrl test_msx2 test_msx2_ctrl

The first run is the normal one. The others are the same disks tested again: with CTRL held
(--ctrl), on an MSX2 (--as MSX2), and on an MSX2 with CTRL held. A disk that failed (error or
back at BASIC) gets
  ' (CTRL)' on its name   if it works when CTRL is held while the MSX starts
  MSX2                    if it only works on an MSX2
  the folder Virker ikke  if nothing helped
Overrides already in --out are kept.
"""
import argparse, csv, os

GOOD = ('running', 'text')


def results(path):
    return {r['disk']: r['verdict'] for r in csv.DictReader(open(os.path.join(path, 'results.csv'), encoding='utf-8'))}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--report', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('runs', nargs=4, metavar='RUN', help='normal, ctrl, msx2, msx2+ctrl result folders')
    args = ap.parse_args()
    normal, ctrl, msx2, msx2ctrl = [results(os.path.join(args.report, r)) for r in args.runs]

    source = {}
    for r in csv.DictReader(open(os.path.join(args.report, 'organise.csv'), encoding='utf-8')):
        if r['sd']:
            source[r['sd']] = r['source']

    rows = {}
    if os.path.exists(args.out):
        for r in csv.DictReader(open(args.out, encoding='utf-8')):
            rows[r['source']] = r
    for disk, v in normal.items():
        if v in GOOD:
            continue
        src = source.get(disk) or source.get(os.path.dirname(disk))
        if not src:
            continue
        machine = 'MSX2' if disk.split(os.sep)[1:2] == ['MSX2'] or '\\MSX2\\' in disk else 'MSX1'
        if ctrl.get(disk) in GOOD:
            o = dict(machine='', suffix=' (CTRL)', folder='')
        elif machine == 'MSX1' and msx2.get(disk) in GOOD:
            o = dict(machine='MSX2', suffix='', folder='')
        elif machine == 'MSX1' and msx2ctrl.get(disk) in GOOD:
            o = dict(machine='MSX2', suffix=' (CTRL)', folder='')
        else:
            o = dict(machine='', suffix='', folder='Virker ikke')
        o['source'] = src
        o['why'] = '%s: %s' % (disk, v)
        rows[src] = o
    with open(args.out, 'w', newline='', encoding='utf-8') as fh:
        w = csv.DictWriter(fh, ['source', 'machine', 'suffix', 'folder', 'why'])
        w.writeheader()
        for k in sorted(rows):
            w.writerow({f: rows[k].get(f, '') for f in ['source', 'machine', 'suffix', 'folder', 'why']})
    print(len(rows), 'overrides')


if __name__ == '__main__':
    main()
