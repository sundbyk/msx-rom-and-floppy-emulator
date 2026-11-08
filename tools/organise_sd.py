"""Build the SD card for msx-rom-and-floppy-emulator from an MSX collection.

    python tools/organise_sd.py --src D:/winapps/OpenMSX/msx --out D:/winapps/OpenMSX/sd \
        --report D:/winapps/OpenMSX/sd-rapport --db D:/winapps/OpenMSX/share/softwaredb.xml \
        --diskrom nms8250_disk.rom --msxdos Msxdos.dsk

The source is left as it is. The SD card gets

    menu.rom, disk.rom
    msx/MSX1/ROM, msx/MSX1/Disk, msx/MSX1/Kassett, msx/MSX2/ROM, msx/MSX2/Disk

- ROMs: the mapper and the name come from openMSX's softwaredb.xml (by SHA1). One file per
  game: the best dump of those the firmware can run. The extension tells the firmware the
  mapper (.rom .konami4 .konami5 .ascii8 .ascii16). Mappers it can not do are left out.
- Disks: 180K and other 40 track disks are copied file by file to 720K, since the disk rom
  (NMS 8250) does not read them. Images of several disks in one file are split. A game on
  several disks becomes a folder with Disk 1.dsk, Disk 2.dsk ...
- BIN games (zips of a BASIC loader and its files) become a 720K disk with an AUTOEXEC.BAS that
  starts it, or AUTOEXEC.BAT and MSX-DOS for .COM programs. Games there is a ROM or disk of
  already are left out.
- Tapes (.cas) go to Kassett, as they are.
- Music: the MIDI files in Midis/ (zipped or not) become msx/Musikk/Name.vgm (mid2vgm.py), which
  MENU plays on the PSG.
- Covers: the cassette fronts in the tape zips, covers/ and Flyers/ are matched to the games by
  name and made into Game.sc2 next to each version of the game (cover.sc2 in a folder) by
  make_covers.ps1, which this runs on Windows.

The report folder gets organise.csv (what went where, and why things were left out),
bin_disks.txt (the made disks, for test_disks.py), covers.csv (pictures that go with a game),
and covers/ with the pictures and a preview .png of each cover.

--covers-only does the covers again for an SD card made before: from organise.csv and the tape
covers in covers.csv, into the --out there is. --music-only does msx/Musikk the same way.

--snapshots DIR puts the snapshots cas_snapshot.py made (DIR/msx/.../Game.msxsnap, by the tape's
place on the SD card) next to the tapes on an SD card made before, and moves each of those tapes
(which MENU can not load) into a "Virker ikke" folder below. Take out the ones test_snapshots.py
does not like first.
"""
import argparse, collections, csv, hashlib, io, os, re, shutil, struct, subprocess, sys, unicodedata, zipfile
import xml.etree.ElementTree as ET

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import msxdisk
import mid2vgm

DISK_720K = 737280
DISK_360K = 368640

# softwaredb mapper type -> file extension. Anything else can not be run by the firmware
MAPPER_EXT = {
    'Mirrored': '.rom', 'Normal': '.rom', '0x4000': '.rom', 'Page2': '.rom', 'Page1': '.rom',
    'Konami': '.konami4', 'Majutsushi': '.konami4',
    'KonamiSCC': '.konami5',
    'ASCII8': '.ascii8', 'ASCII8SRAM2': '.ascii8', 'ASCII8SRAM8': '.ascii8',
    'ASCII16': '.ascii16', 'ASCII16SRAM2': '.ascii16', 'ASCII16SRAM8': '.ascii16',
}
# Roms without a mapper that need another layout than the board's (first 16K at 0x4000, the next at
# 0x8000, all of it again at 0x0000 and 0xC000). Found with tools/test_roms.py
BOARD_LAYOUT = {
    # Juno First (set 2) has its start at 0x0000 and 0x8000: swap the two 16K halves
    'c5b4fdca8887a8aba203b311c5519f8e4863d910': lambda d: d[0x4000:] + d[:0x4000],
    # Jet Set Willy runs code in the copy of its 16K at 0x8000: make it 32K
    'cb352e97e9416f4c3032118758fc77d6d0f3ad73': lambda d: d + d,
}
NO_MAPPER_MAX = 32 * 1024	# the board does not see A15, so more than 32K without a mapper does not work
MAX_ROM = 128 * 1024		# more than this runs from flash, on a board with 1MB of it ('needs flash')

NOT_MSX_FILES = {'.txt', '.doc', '.gif', '.jpg', '.jpeg', '.png', '.bmp', '.nfo', '.diz', '.htm',
                 '.html', '.url', '.exe', '.pif', '.ini', '.db', '.ico', '.lnk', '.wav', '.mid', '.zip'}

report_rows = []
covers = []


def note(kind, source, result, status, detail=''):
    report_rows.append((kind, source, result, status, detail))


# ---------------------------------------------------------------------------------------------
# names

def ascii_name(s):
    s = unicodedata.normalize('NFKD', s)
    s = ''.join(c for c in s if not unicodedata.combining(c))
    s = s.encode('ascii', 'replace').decode('ascii').replace('?', '')
    s = re.sub(r'[\\/:*"<>|]', '-', s)
    s = re.sub(r'\s+', ' ', s).strip(' .-')
    return s or 'Unnamed'


def nice_name(stem):
    """'BEACH_HEAD' or 'Beach_Head' -> 'Beach Head'"""
    s = stem.replace('_', ' ')
    if s.upper() == s and any(c.isalpha() for c in s):
        s = s.title()
    return ascii_name(s)


def key(title):
    """For matching the same game under slightly different names"""
    t = title.lower()
    t = re.sub(r'\(.*?\)|\[.*?\]', '', t)
    t = re.sub(r'^the |, the$', '', t.strip())
    return re.sub(r'[^a-z0-9]', '', t)


def natural(s):
    return [int(p) if p.isdigit() else p.lower() for p in re.split(r'(\d+)', s)]


class Namer:
    """Unique names per output folder"""

    def __init__(self):
        self.used = collections.defaultdict(set)

    def take(self, folder, name, ext=''):
        n, i = name, 2
        while (n + ext).lower() in self.used[folder]:
            n = '%s (%d)' % (name, i)
            i += 1
        self.used[folder].add((n + ext).lower())
        return n + ext


# ---------------------------------------------------------------------------------------------
# softwaredb

def load_db(path):
    db = {}
    for sw in ET.parse(path).getroot().iter('software'):
        for r in sw.iter('rom'):
            db[r.get('sha1').lower()] = dict(title=sw.get('title'), type=r.get('type') or 'Mirrored',
                                              system=sw.get('system') or '', company=sw.get('company') or '',
                                              year=sw.get('year') or '', status=r.get('status') or '',
                                              remark=r.get('remark') or '')
    return db


def machine_of(system, default):
    if system == 'MSX':
        return 'MSX1'
    if 'turbo' in system.lower():
        return 'TurboR'
    if system.startswith('MSX2+'):
        return 'MSX+'
    if system.startswith('MSX2'):
        return 'MSX2'
    return default


# ---------------------------------------------------------------------------------------------
# ROMs

def do_roms(args, db, namer, titles):
    groups = collections.defaultdict(list)
    for sub, default_machine in (('MSX 1 - 48k', 'MSX1'), ('MSX 1 - Megaram', 'MSX1'), ('MSX 2', 'MSX2')):
        d = os.path.join(args.src, 'Jogos', 'ROMs', sub)
        if not os.path.isdir(d):
            continue
        for f in sorted(os.listdir(d)):
            p = os.path.join(d, f)
            src = os.path.relpath(p, args.src)
            if not f.lower().endswith('.rom'):
                note('rom', src, '', 'left out', 'not a .rom')
                continue
            data = open(p, 'rb').read()
            info = db.get(hashlib.sha1(data).hexdigest())
            if not info:
                note('rom', src, '', 'left out', 'not in softwaredb, mapper unknown')
                continue
            machine = machine_of(info['system'], default_machine)
            groups[(machine, info['title'])].append((p, src, data, info))

    def score(item):
        p, src, data, info = item
        s = 0
        if info['type'] in MAPPER_EXT:
            s += 1000
        if len(data) <= MAX_ROM:
            s += 500
        s += {'GoodMSX': 50, 'Verified': 40, 'Author': 30}.get(info['status'], 0)
        if info['status'] in ('Hack', 'Bad', 'Alternative', 'Unofficial', 'Translated'):
            s -= 100
        if 'set 1' in src.lower():
            s += 1
        return s

    for (machine, title), items in sorted(groups.items()):
        items.sort(key=score, reverse=True)
        p, src, data, info = items[0]
        for other in items[1:]:
            note('rom', other[1], '', 'left out', 'another dump of ' + title)
        ext = MAPPER_EXT.get(info['type'])
        if not ext:
            note('rom', src, '', 'left out', 'mapper %s is not supported' % info['type'])
            continue
        if ext == '.rom' and len(data) > NO_MAPPER_MAX:
            note('rom', src, '', 'left out', '%dK without a mapper (the board shows 32K)' % (len(data) // 1024))
            continue
        fix = BOARD_LAYOUT.get(hashlib.sha1(data).hexdigest())
        if fix:
            data = fix(data)
        folder = os.path.join('msx', machine, 'ROM')
        name = namer.take(folder, ascii_name(title), ext)
        out = os.path.join(args.out, folder, name)
        os.makedirs(os.path.dirname(out), exist_ok=True)
        with open(out, 'wb') as fh:
            fh.write(data)
        status = 'ok' if len(data) <= MAX_ROM else 'needs flash'
        note('rom', src, os.path.join(folder, name), status, '%s %dK %s %s' % (info['type'], len(data) // 1024, info['company'], info['year']))
        titles[machine].add(key(title))


# ---------------------------------------------------------------------------------------------
# disks

def fix_disk(data):
    """A disk image the NMS 8250 disk rom can read: 360K or 720K. 40 track disks (180K, 360K
    two sided) are copied file by file to 720K. Returns (bytes, what was done)."""
    if len(data) == DISK_720K:
        return data, ''
    try:
        img = msxdisk.Image(data)
    except msxdisk.DiskError as e:
        return data, 'unreadable: %s' % e
    if len(data) == DISK_360K and img.media == 0xF8:
        return data, ''
    files = [(n, img.read(n), attr) for n, attr, c, s in img.files() if not attr & 0x10]
    if not files:
        return data, 'no files, can not convert %d byte disk' % len(data)
    return msxdisk.make_720k(BOOT, files), 'copied to 720K (was %dK, media %02X)' % (len(data) // 1024, img.media)


def split_images(data):
    """One file holding several 720K disks -> a list of disk images"""
    if len(data) > DISK_720K and len(data) % DISK_720K == 0:
        return [data[i:i + DISK_720K] for i in range(0, len(data), DISK_720K)]
    return [data]


OVERRIDES = {}


def load_overrides(path):
    """overrides.csv: source (as in organise.csv), machine (MSX1/MSX2, or empty), suffix for the
    name (eg. ' (CTRL)'), folder below Disk (eg. 'Virker ikke'). Made from test_disks.py results"""
    if path and os.path.exists(path):
        for r in csv.DictReader(open(path, encoding='utf-8')):
            OVERRIDES[r['source']] = r


def disk_folder(machine, name, src):
    """Where a disk game goes, after overrides.csv. Returns (machine, folder, name)"""
    o = OVERRIDES.get(src)
    if o:
        machine = o.get('machine') or machine
        if (o.get('suffix') or '').strip():
            name = name + ' ' + o['suffix'].strip()
        if o.get('folder'):
            return machine, os.path.join('msx', machine, 'Disk', o['folder']), name
    return machine, os.path.join('msx', machine, 'Disk'), name


def write_game_disks(args, namer, machine, name, disks, src, kind='disk'):
    """disks: list of image bytes. One -> Name.dsk, more -> Name/Disk n.dsk"""
    machine, folder, name = disk_folder(machine, name, src)
    if len(disks) > 9:
        note(kind, src, '', 'left out', '%d disks, NEXT/PREV only go to 9' % len(disks))
        return None
    done = []
    fixed = []
    for d in disks:
        f, what = fix_disk(d)
        if what.startswith('unreadable') or what.startswith('no files'):
            note(kind, src, '', 'left out', what)
            return None
        fixed.append(f)
        if what:
            done.append(what)
    if len(fixed) == 1:
        rel = os.path.join(folder, namer.take(folder, name, '.dsk'))
        os.makedirs(os.path.join(args.out, folder), exist_ok=True)
        open(os.path.join(args.out, rel), 'wb').write(fixed[0])
    else:
        rel = os.path.join(folder, namer.take(folder, name))
        os.makedirs(os.path.join(args.out, rel), exist_ok=True)
        for i, f in enumerate(fixed, 1):
            open(os.path.join(args.out, rel, 'Disk %d.dsk' % i), 'wb').write(f)
    note(kind, src, rel, 'ok', '; '.join(sorted(set(done))) + (' (%d disks)' % len(fixed) if len(fixed) > 1 else ''))
    return rel


def disk_files_in(folder):
    """The disk images in a game folder, in order. .xsa/.ddi only when there is nothing else"""
    imgs = []
    for f in sorted(os.listdir(folder), key=natural):
        p = os.path.join(folder, f)
        if not os.path.isfile(p):
            continue
        ext = os.path.splitext(f)[1].lower()
        size = os.path.getsize(p)
        if ext in ('.dsk', '.720', '.360') or re.fullmatch(r'\.\d', ext) or (ext == '' and size % DISK_360K == 0):
            if size % DISK_360K == 0 or size == 184320:
                imgs.append(p)
    return imgs


def xsa_cache(args, xsa):
    """Where the plain image of a compressed .xsa goes once openMSX has unpacked it (see
    xsa_to_dsk.tcl, made in the report folder)"""
    h = hashlib.sha1(open(xsa, 'rb').read()).hexdigest()[:16]
    return os.path.join(args.report, 'xsa', h + '.dsk')


def do_disks(args, namer, titles):
    base = os.path.join(args.src, 'Jogos', 'DSKs')
    xsa_todo = []
    for sub, machine in (('MSX 1', 'MSX1'), ('MSX 2', 'MSX2'), ('MSX 1 - Megaram', None)):
        d = os.path.join(base, sub)
        if not os.path.isdir(d):
            continue
        for f in sorted(os.listdir(d), key=natural):
            p = os.path.join(d, f)
            src = os.path.relpath(p, args.src)
            if machine is None:
                note('disk', src, '', 'left out', 'needs a MegaRAM')
                continue
            if os.path.isfile(p):
                if not f.lower().endswith('.dsk'):
                    continue
                name = ascii_name(os.path.splitext(f)[0])
                if write_game_disks(args, namer, machine, name, split_images(open(p, 'rb').read()), src):
                    titles[machine].add(key(name))
                continue
            # A game folder. Language versions can be in folders below it. Compressed .xsa
            # images are only used where there is no plain disk image
            dsk_leaves, xsa_leaves = [], []
            for dp, dn, fn in os.walk(p):
                if disk_files_in(dp):
                    dsk_leaves.append(dp)
                elif any(x.lower().endswith('.xsa') for x in fn):
                    xsa_leaves.append(dp)
            # (a folder of .xsa next to one of plain images is the same game twice, but
            # English/Japanese folders are two versions)
            leaves = dsk_leaves + [l for l in xsa_leaves if not dsk_leaves or 'xsa' not in os.path.basename(l).lower()]
            if not leaves:
                note('disk', src, '', 'left out', 'no disk images in it')
                continue
            for leaf in sorted(leaves, key=natural):
                rel_leaf = os.path.relpath(leaf, p)
                if len(leaves) == 1 or rel_leaf == '.':
                    name = ascii_name(f)
                else:
                    name = ascii_name('%s (%s)' % (f, rel_leaf.replace(os.sep, ', ')))
                imgs = disk_files_in(leaf)
                if not imgs:
                    xsas = sorted([os.path.join(leaf, x) for x in os.listdir(leaf) if x.lower().endswith('.xsa')], key=natural)
                    cached = [xsa_cache(args, x) for x in xsas]
                    if not all(os.path.exists(c) for c in cached):
                        xsa_todo.append((machine, name, xsas, os.path.relpath(leaf, args.src)))
                        continue
                    imgs = cached
                disks = []
                for i in imgs:
                    disks += split_images(open(i, 'rb').read())
                if write_game_disks(args, namer, machine, name, disks, os.path.relpath(leaf, args.src)):
                    titles[machine].add(key(f))
    return xsa_todo


# ---------------------------------------------------------------------------------------------
# BIN games

def is_tokenised_basic(b):
    return len(b) > 4 and b[0] == 0xFF


def basic_strings(b):
    """Quoted strings in a BASIC program, upper case"""
    return [s.upper() for s in re.findall(rb'"([^"\r\n\x00]{1,20})', b)]


def pick_start(files, title):
    """What AUTOEXEC.BAS should start: ('RUN', name) or ('BLOAD', name), or None"""
    names = {n.upper(): d for n, d in files}
    basics = [n for n, d in names.items() if is_tokenised_basic(d) or n.endswith('.BAS')]
    if basics:
        referenced = set()
        for n in basics:
            for s in basic_strings(names[n]):
                s = s.decode('latin-1').strip()
                s = s.split(':')[-1]
                referenced.add(s)
                referenced.add(s.split('.')[0])
        roots = [n for n in basics if n not in referenced and n.split('.')[0] not in referenced]
        cands = roots or basics
        k = key(title)
        cands.sort(key=lambda n: (not (k.startswith(key(n.split('.')[0])) or key(n.split('.')[0]).startswith(k[:4])),
                                  not n.endswith(('.BAS', '.LDR')), len(n), n))
        return ('RUN', cands[0])
    bins = [n for n, d in names.items() if d[:1] == b'\xFE' and len(d) > 7]
    if len(bins) == 1:
        return ('BLOAD', bins[0])
    # Several: the loader is usually the one without a number on the end (SOCCER, SOCCE1 ...)
    plain = [n for n in bins if not re.search(r'\d$', n.split('.')[0])]
    if len(plain) == 1:
        return ('BLOAD', plain[0])
    return None


def zip_game_files(z):
    """The files of the game in the zip, flattened, without pictures and text. If the zip holds
    the game twice in two folders, only the first folder is used."""
    entries = [i for i in z.infolist() if not i.is_dir()]
    dirs = collections.OrderedDict()
    for i in entries:
        d = os.path.dirname(i.filename.replace('\\', '/'))
        dirs.setdefault(d, []).append(i)
    if len(dirs) > 1 and '' not in dirs:
        first = max(dirs, key=lambda d: len(dirs[d]))
        entries = dirs[first]
    files = []
    for i in entries:
        n = os.path.basename(i.filename.replace('\\', '/'))
        if os.path.splitext(n)[1].lower() in NOT_MSX_FILES:
            continue
        files.append((n, z.read(i)))
    return files


DDI_HEADER = 4608		# DiskDupe images: a header, then the plain 720K


def zip_disks(args, z):
    """Disk images in a zip, whatever they are called: .dsk, .1 .2 ..., no extension, DiskDupe
    .ddi, compressed .xsa. If they are in more than one folder (two versions of the game),
    only the first folder is used. Returns (images, xsa files still to unpack)"""
    by_dir = collections.defaultdict(list)
    for i in z.infolist():
        if i.is_dir():
            continue
        n = i.filename.replace('\\', '/')
        ext = os.path.splitext(n)[1].lower()
        size = i.file_size
        if ext == '.xsa' or ext == '.ddi' or ext == '.dsk' or \
                (ext not in NOT_MSX_FILES and 184320 <= size <= 9 * DISK_720K and
                 (size % DISK_360K == 0 or size == 184320)):
            by_dir[os.path.dirname(n)].append(i)
    if not by_dir:
        return [], []
    first = sorted(by_dir, key=natural)[0]
    images, xsas = [], []
    for i in sorted(by_dir[first], key=lambda i: natural(i.filename)):
        ext = os.path.splitext(i.filename)[1].lower()
        data = z.read(i)
        if ext == '.xsa':
            src = os.path.join(args.report, 'xsa', 'src', hashlib.sha1(data).hexdigest()[:16] + '.xsa')
            os.makedirs(os.path.dirname(src), exist_ok=True)
            open(src, 'wb').write(data)
            if os.path.exists(xsa_cache(args, src)):
                images.append(open(xsa_cache(args, src), 'rb').read())
            else:
                xsas.append(src)
        elif ext == '.ddi' or len(data) == DISK_720K + DDI_HEADER:
            images.append(data[DDI_HEADER:])
        else:
            images += split_images(data)
    return images, xsas


def unpatch_cas(data):
    """BLOAD"CAS:NAME" -> BLOAD"NAME". Tokenised BASIC links its lines again when it is loaded"""
    return re.sub(rb'"CAS:', b'"', data, flags=re.I)


def do_bins(args, namer, titles, msxdos, xsa_todo):
    base = os.path.join(args.src, 'Jogos', 'BINs')
    made = []
    for dp, dn, fn in os.walk(base):
        dn.sort()
        rel = os.path.relpath(dp, base)
        top = rel.split(os.sep)[0]
        machine = {'MSX 2': 'MSX2', 'MSX Turbo-R': 'TurboR', 'Megaram': None}.get(top, 'MSX1')
        for f in sorted(fn, key=natural):
            if not f.lower().endswith('.zip'):
                continue
            p = os.path.join(dp, f)
            src = os.path.relpath(p, args.src)
            if machine is None:
                note('bin', src, '', 'left out', 'needs a MegaRAM')
                continue
            title = nice_name(os.path.splitext(f)[0])
            try:
                z = zipfile.ZipFile(p)
                files = zip_game_files(z)
            except Exception as e:
                note('bin', src, '', 'left out', 'bad zip: %s' % e)
                continue
            if key(title) in titles[machine]:
                note('bin', src, '', 'left out', 'there is a ROM or disk of it already')
                continue
            disks, xsas = zip_disks(args, z)
            cas = [(n, d) for n, d in files if n.lower().endswith('.cas')]
            if xsas:
                xsa_todo.append((machine, title, xsas, src))
                continue
            if disks:
                if write_game_disks(args, namer, machine, title, disks, src, 'bin'):
                    titles[machine].add(key(title))
                continue
            if cas:
                for n, d in cas:
                    write_tape(args, namer, nice_name(os.path.splitext(n)[0]) if len(cas) > 1 else title, d, src)
                continue
            if not files:
                note('bin', src, '', 'left out', 'nothing for the MSX in it')
                continue
            bad = [n for n, d in files if msxdisk.dos_name(n) is None]
            if bad:
                note('bin', src, '', 'left out', 'not 8.3 names: ' + ', '.join(bad[:3]))
                continue
            upper = {n.upper() for n, d in files}
            detail = []
            patched = [(n.upper(), unpatch_cas(d) if is_tokenised_basic(d) else d) for n, d in files]
            if patched != [(n.upper(), d) for n, d in files]:
                detail.append('CAS: taken out of the loader')
            files = patched
            if 'AUTOEXEC.BAS' in upper or 'AUTOEXEC.BAT' in upper:
                start = 'own autoexec'
                if 'AUTOEXEC.BAT' in upper and 'MSXDOS.SYS' not in upper:
                    files = msxdos + files
            else:
                coms = [n for n, d in files if n.endswith('.COM') and n != 'COMMAND.COM']
                if coms:
                    coms.sort(key=lambda n: (not key(title).startswith(key(n[:-4])[:4]), len(n)))
                    files = msxdos + files + [('AUTOEXEC.BAT', (coms[0][:-4] + '\r\n').encode())]
                    start = 'MSX-DOS ' + coms[0]
                else:
                    how = pick_start(files, title)
                    if not how:
                        note('bin', src, '', 'left out', 'can not tell what to start')
                        continue
                    line = '10 RUN"%s"' % how[1] if how[0] == 'RUN' else '10 BLOAD"%s",R' % how[1]
                    files = files + [('AUTOEXEC.BAS', (line + '\r\n').encode() + b'\x1a')]
                    start = line[3:]
            try:
                img = msxdisk.make_720k(BOOT, [(n, d) for n, d in files])
            except msxdisk.DiskError as e:
                note('bin', src, '', 'left out', str(e))
                continue
            to_machine, folder, to_title = disk_folder(machine, title, src)
            name = namer.take(folder, to_title, '.dsk')
            os.makedirs(os.path.join(args.out, folder), exist_ok=True)
            open(os.path.join(args.out, folder, name), 'wb').write(img)
            note('bin', src, os.path.join(folder, name), 'made', '; '.join([start] + detail))
            titles[machine].add(key(title))
            made.append((to_machine, os.path.join(folder, name), src, start))
    return made


# ---------------------------------------------------------------------------------------------
# tapes

NOT_WORKING = 'Virker ikke'


def do_snapshots(args):
    """Game.msxsnap next to Game.cas, and Game.cas into NOT_WORKING below. organise.csv says so"""
    moved = {}
    for root, dirs, files in os.walk(args.snapshots):
        dirs[:] = [d for d in dirs if d != 'work']
        for f in sorted(files, key=natural):
            if not f.lower().endswith('.msxsnap'):
                continue
            rel = os.path.relpath(os.path.join(root, f), args.snapshots)
            cas = os.path.splitext(rel)[0] + '.cas'
            away = os.path.join(os.path.dirname(cas), NOT_WORKING, os.path.basename(cas))
            if os.path.exists(os.path.join(args.out, cas)):
                os.makedirs(os.path.join(args.out, os.path.dirname(away)), exist_ok=True)
                os.replace(os.path.join(args.out, cas), os.path.join(args.out, away))
            elif not os.path.exists(os.path.join(args.out, away)):
                print('no tape for', rel)
                continue
            shutil.copyfile(os.path.join(root, f), os.path.join(args.out, rel))
            moved[cas] = away
            note('snapshot', cas, rel, 'ok')
    for i, row in enumerate(report_rows):
        if row[0] == 'tape' and row[2] in moved:
            report_rows[i] = (row[0], row[1], moved[row[2]], 'ok', 'MENU can not load it: the snapshot instead')
    return len(moved)


def write_tape(args, namer, name, data, src, folder_name=None):
    folder = os.path.join('msx', 'MSX1', 'Kassett')
    if folder_name:
        folder = os.path.join(folder, folder_name)
    os.makedirs(os.path.join(args.out, folder), exist_ok=True)
    out = namer.take(folder, name, '.cas')
    open(os.path.join(args.out, folder, out), 'wb').write(data)
    note('tape', src, os.path.join(folder, out), 'ok')
    return os.path.join(folder, out)


def do_tapes(args, namer):
    base = os.path.join(args.src, 'tape_cas_images')
    if not os.path.isdir(base):
        return
    for f in sorted(os.listdir(base), key=natural):
        p = os.path.join(base, f)
        src = os.path.relpath(p, args.src)
        if f.lower().endswith('.cas'):
            write_tape(args, namer, nice_name(f[:-4]), open(p, 'rb').read(), src)
        elif f.lower().endswith('.zip'):
            try:
                z = zipfile.ZipFile(p)
            except Exception as e:
                note('tape', src, '', 'left out', 'bad zip: %s' % e)
                continue
            names = [i.filename for i in z.infolist() if not i.is_dir()]
            cas = [n for n in names if n.lower().endswith('.cas')]
            if not cas:
                note('tape', src, '', 'left out', 'no .cas in it')
                continue
            group = nice_name(os.path.splitext(f)[0]) if len(cas) > 1 else None
            for n in sorted(cas, key=natural):
                stem = os.path.splitext(os.path.basename(n))[0]
                rel = write_tape(args, namer, nice_name(stem), z.read(n), src, group)
                fronts = [x for x in names if x.lower().endswith(('_front.jpg', '_front.gif')) and
                          key(os.path.basename(x).rsplit('_front', 1)[0]) == key(stem)]
                if fronts:
                    covers.append((rel, src + '!' + fronts[0]))
            # a front cover of the whole compilation goes with the folder
            if group:
                fronts = [x for x in names if x.lower().endswith('_front.jpg') and
                          key(os.path.basename(x).rsplit('_front', 1)[0]) == key(os.path.splitext(f)[0])]
                if fronts:
                    covers.append((os.path.join('msx', 'MSX1', 'Kassett', group), src + '!' + fronts[0]))
        else:
            note('tape', src, '', 'left out', 'not a tape')


# ---------------------------------------------------------------------------------------------
# music: Midis/ (zips of MIDI files of game music) -> msx/Musikk/Name.vgm, for MENU to play

MUSIC_FOLDER = os.path.join('msx', 'Musikk')
MUSIC_NAMES = {'nenesis': 'nemesis'}	# spelling in the collection


def music_name(stem):
    """'metal_gear_2-night' -> 'Metal Gear 2-Night', 'sd_snatcher_1' -> 'SD Snatcher 1'"""
    s = stem.lower()
    for wrong, right in MUSIC_NAMES.items():
        s = s.replace(wrong, right)
    s = s.replace('_', ' ').title()
    s = re.sub(r'\bSd\b', 'SD', s)
    return ascii_name(s)


def do_music(args, namer):
    base = os.path.join(args.src, 'Midis')
    if not os.path.isdir(base):
        return
    os.makedirs(os.path.join(args.out, MUSIC_FOLDER), exist_ok=True)
    for f in sorted(os.listdir(base), key=natural):
        p = os.path.join(base, f)
        src = os.path.relpath(p, args.src)
        stem, ext = os.path.splitext(f)
        try:
            if ext.lower() == '.zip':
                z = zipfile.ZipFile(p)
                mids = [(n, z.read(n)) for n in z.namelist() if n.lower().endswith(('.mid', '.midi'))]
            elif ext.lower() in ('.mid', '.midi'):
                mids = [(f, open(p, 'rb').read())]
            else:
                continue
        except Exception as e:
            note('music', src, '', 'left out', 'bad zip: %s' % e)
            continue
        for n, data in mids:
            name = music_name(stem if len(mids) == 1 else stem + ' ' + os.path.splitext(os.path.basename(n))[0])
            try:
                vgm, stats = mid2vgm.convert(data)
            except Exception as e:
                note('music', src, '', 'left out', 'not a MIDI file we can read: %s' % e)
                continue
            rel = os.path.join(MUSIC_FOLDER, namer.take(MUSIC_FOLDER, name, '.vgm'))
            open(os.path.join(args.out, rel), 'wb').write(vgm)
            note('music', src, rel, 'ok', '%s s' % stats['seconds'])


# ---------------------------------------------------------------------------------------------
# pictures that may go with a game: covers/ (box fronts and inlays) and Flyers/ (adverts)

# covers/ names that are too short to find the game by (key of the picture: key of the game)
COVER_ALIASES = {
    'akumaju': 'vampirekillerakumajodracula',
    'batmanmovie': 'batmanthemovie',
    'contra': 'gryzorcontra',
    'f1spiritjap': 'f1spiritthewaytoformula1',
    'gradius2msx': 'gradius2nemesis2',
    'ysmsx': 'ys1',
    'chicago30s': 'chicagos30s',
    'peterbeardsleysinternfootball': 'peterbeardsleysinternationalfootball',
    'spyvsspy2theislandcaper': 'spyvsspytheislandcaper',
    # other games than the ones with the start of their name
    'nemesisthefinalchallenge': None,
    'mastersoftheuniversethemovie': None,
}


def roman(s):
    """'Match Day II' -> 'Match Day 2', as the pictures have it"""
    return re.sub(r'\b(III|II|IV)\b', lambda m: {'II': '2', 'III': '3', 'IV': '4'}[m.group(1)], s)


def cover_key(stem):
    """Key of a picture's name: 'Elite_2', 'MunstersThe', 'gamemaster2-front' ..."""
    s = re.sub(r'_\d+$', '', stem)
    s = re.sub(r'-front$', '', s, flags=re.I)
    s = re.sub(r'(?<=[a-z])The$', '', s)
    k = key(roman(s))
    return COVER_ALIASES.get(k, k)


def find_game(games, k):
    """The key in games the picture key k goes with, or None"""
    if not k:
        return None
    if k in games:
        return k
    # 'Robocop1' is the first Robocop
    if k.endswith('1') and not k[-2:-1].isdigit() and k[:-1] in games:
        return k[:-1]
    # the game's name and a subtitle: 'JackTheNipper2-InCoconutCapers', 'MadMixGame'. Not
    # 'CrazyCars2' for Crazy Cars
    best = None
    for g in games:
        if len(g) >= 6 and k.startswith(g) and k[len(g)].isalpha() and (best is None or len(g) > len(best)):
            best = g
    return best


def game_key(args, result):
    """Key of a game on the SD card, from its file or folder name"""
    name = os.path.basename(result)
    if not os.path.isdir(os.path.join(args.out, result)):
        name = os.path.splitext(name)[0]
    return key(roman(name))


def do_covers(args):
    games = collections.defaultdict(list)
    for kind, src, result, status, detail in report_rows:
        if result and status in ('ok', 'made', 'needs flash'):
            k = game_key(args, result)
            if result not in games[k]:
                games[k].append(result)
    have = {r for r, s in covers}
    for sub in ('covers', 'Flyers'):
        d = os.path.join(args.src, sub)
        if not os.path.isdir(d):
            continue
        for f in sorted(os.listdir(d), key=natural):
            stem, ext = os.path.splitext(f)
            if ext.lower() not in ('.jpg', '.jpeg', '.gif', '.png') or re.search(r'-(back|spine|inside)', stem, re.I):
                continue
            g = find_game(games, cover_key(stem))
            # every version of the game (rom, disk, tape) gets it
            for hit in games.get(g, []):
                if hit not in have:
                    covers.append((hit, os.path.join(sub, f)))
                    have.add(hit)
    # and the cassette front of a game goes with its rom or disk too
    picture = {}
    for r, s in covers:
        picture.setdefault(game_key(args, r), s)
    for k, results in games.items():
        for hit in results:
            if k in picture and hit not in have:
                covers.append((hit, picture[k]))
                have.add(hit)


def write_covers(args):
    """The pictures in covers go to report/covers (unpacked if they are in a zip), and
    covers.txt gets a line for each for make_covers.ps1: crop|picture|Game.sc2|preview.png.
    Game.sc2 goes next to Game.rom (.dsk, .cas), cover.sc2 into a folder"""
    d = os.path.join(args.report, 'covers')
    os.makedirs(d, exist_ok=True)
    lines = []
    for i, (sd, pic) in enumerate(covers):
        local = os.path.join(d, '%04d%s' % (i, os.path.splitext(pic)[1].lower()))
        if '.zip!' in pic.lower():
            # zip!member. Some zip names have a ! in them too
            n = pic.lower().index('.zip!') + 4
            data = zipfile.ZipFile(os.path.join(args.src, pic[:n])).read(pic[n + 1:])
        else:
            data = open(os.path.join(args.src, pic), 'rb').read()
        open(local, 'wb').write(data)
        target = os.path.join(args.out, sd)
        out = os.path.join(target, 'cover.sc2') if os.path.isdir(target) else os.path.splitext(target)[0] + '.sc2'
        # box scans in covers/ can be a whole inlay
        crop = 1 if pic.startswith('covers' + os.sep) else 0
        lines.append('%d|%s|%s|%s' % (crop, os.path.abspath(local), os.path.abspath(out),
                                      os.path.abspath(os.path.join(d, '%04d.png' % i))))
    txt = os.path.join(args.report, 'covers.txt')
    open(txt, 'w', encoding='utf-8').write('\n'.join(lines) + '\n')
    with open(os.path.join(args.report, 'covers.csv'), 'w', newline='', encoding='utf-8') as fh:
        w = csv.writer(fh)
        w.writerow(['sd', 'picture'])
        w.writerows(covers)
    ps1 = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'make_covers.ps1')
    cmd = ['powershell.exe', '-ExecutionPolicy', 'Bypass', '-File', ps1, '-List', txt]
    if shutil.which('powershell.exe'):
        print('making the covers ...')
        subprocess.run(cmd)
    else:
        print('make the covers with:', ' '.join(cmd))


# ---------------------------------------------------------------------------------------------

def write_report(args):
    with open(os.path.join(args.report, 'organise.csv'), 'w', newline='', encoding='utf-8') as fh:
        w = csv.writer(fh)
        w.writerow(['kind', 'source', 'sd', 'status', 'detail'])
        w.writerows(report_rows)


def main():
    global BOOT
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--src', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--report', required=True)
    ap.add_argument('--covers-only', action='store_true', help='only make the covers again')
    ap.add_argument('--music-only', action='store_true', help='only make msx/Musikk again')
    ap.add_argument('--snapshots', help="cas_snapshot.py's --out: put its snapshots next to the tapes")
    ap.add_argument('--db', help="openMSX's share/softwaredb.xml")
    ap.add_argument('--diskrom', help='copied to disk.rom (eg. nms8250_disk.rom)')
    ap.add_argument('--menu', help='menu.rom to copy to the root')
    ap.add_argument('--msxdos', help='a disk with MSXDOS.SYS and COMMAND.COM, for .COM games')
    ap.add_argument('--boot', default=os.path.join(os.path.dirname(os.path.abspath(__file__)), 'bootsector720.bin'))
    ap.add_argument('--overrides', help='overrides.csv: other machine, name suffix or folder for some games')
    args = ap.parse_args()
    load_overrides(args.overrides)

    if args.covers_only:
        report_rows.extend(tuple(r) for r in list(csv.reader(open(os.path.join(args.report, 'organise.csv'), encoding='utf-8')))[1:])
        covers.extend((r['sd'], r['picture']) for r in csv.DictReader(open(os.path.join(args.report, 'covers.csv'), encoding='utf-8'))
                      if r['picture'].startswith('tape_cas_images'))
        do_covers(args)
        write_covers(args)
        print('covers', len(covers))
        return
    if args.music_only:
        for r in list(csv.reader(open(os.path.join(args.report, 'organise.csv'), encoding='utf-8')))[1:]:
            if r[0] != 'music':
                report_rows.append(tuple(r))
            elif r[2] and os.path.exists(os.path.join(args.out, r[2])):
                os.remove(os.path.join(args.out, r[2]))		# made last time
        do_music(args, Namer())
        write_report(args)
        print('music', sum(1 for r in report_rows if r[0] == 'music' and r[3] == 'ok'))
        return
    if args.snapshots:
        report_rows.extend(tuple(r) for r in list(csv.reader(open(os.path.join(args.report, 'organise.csv'), encoding='utf-8')))[1:]
                           if r[0] != 'snapshot')
        n = do_snapshots(args)
        write_report(args)
        print('snapshots', n)
        return
    if not args.db:
        sys.exit('--db is needed')
    if os.path.exists(os.path.join(args.out, 'msx')):
        sys.exit('%s already has an msx folder. Move it away first' % args.out)
    BOOT = open(args.boot, 'rb').read()[:512]
    os.makedirs(args.out, exist_ok=True)
    os.makedirs(args.report, exist_ok=True)
    if args.diskrom:
        shutil.copyfile(args.diskrom, os.path.join(args.out, 'disk.rom'))
    if args.menu:
        shutil.copyfile(args.menu, os.path.join(args.out, 'menu.rom'))
    msxdos = []
    if args.msxdos:
        img = msxdisk.Image(open(args.msxdos, 'rb').read())
        msxdos = [('MSXDOS.SYS', img.read('MSXDOS.SYS')), ('COMMAND.COM', img.read('COMMAND.COM'))]

    namer = Namer()
    titles = collections.defaultdict(set)
    db = load_db(args.db)
    do_roms(args, db, namer, titles)
    xsa_todo = do_disks(args, namer, titles)
    made = do_bins(args, namer, titles, msxdos, xsa_todo)
    do_tapes(args, namer)
    do_music(args, namer)
    do_covers(args)

    # Compressed .xsa images not unpacked yet: a Tcl script for openMSX to do it. Run it, then run
    # this again (into an empty --out)
    if xsa_todo:
        os.makedirs(os.path.join(args.report, 'xsa'), exist_ok=True)
        with open(os.path.join(args.report, 'xsa_to_dsk.tcl'), 'w') as fh:
            for machine, name, xsas, src in xsa_todo:
                note('disk', src, '', 'xsa', 'run xsa_to_dsk.tcl in openMSX, then this again')
                for x in xsas:
                    fh.write('diska {%s}\ndiskmanipulator savedsk diska {%s}\n' %
                             (x.replace('\\', '/'), xsa_cache(args, x).replace('\\', '/')))
            fh.write('diska eject\nexit\n')

    write_report(args)
    with open(os.path.join(args.report, 'bin_disks.txt'), 'w', encoding='utf-8') as fh:
        for machine, rel, src, start in made:
            fh.write('%s\t%s\t%s\n' % (machine, rel, start))
    write_covers(args)

    c = collections.Counter((k, s) for k, src, r, s, d in report_rows)
    for (k, s), n in sorted(c.items()):
        print('%-5s %-12s %d' % (k, s, n))
    print('covers', len(covers))


if __name__ == '__main__':
    main()
