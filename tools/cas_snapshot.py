"""Load tapes in openMSX the real way and keep a snapshot of the MSX when the tape motor goes off
for the last time: for tapes the menu's own tape loading can not do (loaders that use all 64K of
RAM and switch the BIOS ROM back in). MENU restores the snapshot and the game carries on.

The snapshot is not taken at the motor off itself (the CPU is in the BIOS then, and another MSX's
BIOS has other code there) but at the first instruction after it in RAM with no return address
into the BIOS in the 16 words on the stack ("clean"). If that does not come in 2 seconds, at the
first in RAM ("ram"), and if that does not either, 2 seconds later ("bios").

    python tools/cas_snapshot.py --openmsx D:/winapps/OpenMSX/openmsx.exe --sd D:/winapps/OpenMSX/sd \
        --out sd-rapport/snapshots -j 6 tape.cas ... | --list tapes.txt

The MSX is a Philips VG-8020 (MSX1, 64K of RAM in slot 3, no disk drive). Each tape gets
Game.msxsnap in --out (under its path below --sd), a screenshot of the moment and one of five
seconds later, and report.html shows them. The .msxsnap (82176 bytes):

    0x00000  64K of RAM, 0x0000-0xFFFF
    0x10000  16K of VRAM
    0x14000  256 bytes of state:
               0  "KCMFSNAP"
               8  version (1)
               9  what each page (0-3) was: 0 RAM, 1 the BIOS/BASIC ROM
              13  PSG registers 0-15
              29  VDP registers 0-7
              37  PPI port C
              38  AF BC DE HL IX IY SP PC AF' BC' DE' HL' (16 bit, low byte first)
              62  I, R, IM, IFF (1 if interrupts were on)
              66  tape seconds read, tape seconds in all (16 bit each)
              70  when it was taken: 0 clean, 1 ram, 2 bios
"""
import argparse, html, os, struct, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_disks import minimised

SNAP_SIZE = 0x14000 + 256
HOW = ('clean', 'ram', 'bios')

# Snapshot after every motor off (the last one stays), and a screenshot 5 seconds later
TCL = r'''
set out "%(out)s"
after realtime %(limit)d {exit}
set autoruncassettes on
cassetteplayer insert {%(tape)s}
reset
set throttle off
set motor 0
set offs 0
set cond ""
set loose 0
proc save {name data} { set f [open "$::out.$name" wb] ; puts -nonewline $f $data ; close $f }
proc dump {how} {
    save ram [debug read_block {Main RAM} 0 65536]
    save vram [debug read_block {physical VRAM} 0 16384]
    save psg [debug read_block {PSG regs} 0 16]
    save vdp [debug read_block {VDP regs} 0 8]
    set r {}
    foreach n {af bc de hl ix iy sp pc af2 bc2 de2 hl2 i r im iff} { lappend r [reg $n] }
    lappend r [debug read ioports 0xA8] [debug read ioports 0xAA]
    lappend r [cassetteplayer getpos] [cassetteplayer getlength] [machine_info time] $how
    set f [open "$::out.regs" w] ; puts $f $r ; close $f
    set n $::offs
    after time 5 "if {\$::offs == $n} { set ::throttle on ; after realtime 0.5 {screenshot -raw \"$::out.later.png\" ; set ::throttle off} }"
    set ::throttle on
    after realtime 0.5 { screenshot -raw "$::out.now.png" ; set ::throttle off }
}
# the VG-8020's RAM is in slot 3
proc in_ram {a} { expr {(([debug read ioports 0xA8] >> (($a >> 14) * 2)) & 3) == 3} }
proc clean_stack {} {
    set sp [reg sp]
    for {set i 0} {$i < 32} {incr i 2} {
        set a [expr {($sp + $i) & 0xFFFF}]
        set w [expr {[debug read memory $a] | ([debug read memory [expr {($a + 1) & 0xFFFF}]] << 8)}]
        if {$w >= 0x160 && ![in_ram $w]} { return 0 }
    }
    return 1
}
proc ready {} {
    if {![in_ram [reg pc]]} { return 0 }
    if {$::loose} { return 1 }
    return [clean_stack]
}
proc disarm {} {
    if {$::cond ne ""} { debug remove_condition $::cond ; set ::cond "" }
}
proc take {how} { disarm ; dump $how }
proc arm {} {
    disarm
    incr ::offs
    set n $::offs
    set ::loose 0
    set ::cond [debug set_condition {[ready]} {take [expr {$::loose ? "ram" : "clean"}]}]
    after time 2 "if {\$::offs == $n && \$::cond ne {}} { set ::loose 1 }"
    after time 4 "if {\$::offs == $n && \$::cond ne {}} { take bios }"
}
proc poll {} {
    set on [expr {!([debug read ioports 0xAA] & 0x10)}]
    if {$on != $::motor} {
        set ::motor $on
        if {$on} {
            disarm
        } elseif {[cassetteplayer getpos] > 0.5} {
            arm
        }
    }
    after time 0.02 poll
}
after time 1 poll
after time %(wait)d {exit}
'''


def build(base):
    """The .msxsnap from the files the Tcl wrote, or None"""
    if not os.path.exists(base + '.regs'):
        return None
    v = open(base + '.regs').read().split()
    regs = [int(x) for x in v[:16]]
    a8, ppic = int(v[16]), int(v[17])
    pos, length = float(v[18]), float(v[19])
    how = v[21] if len(v) > 21 else 'bios'
    ram = open(base + '.ram', 'rb').read()
    vram = open(base + '.vram', 'rb').read()
    psg = open(base + '.psg', 'rb').read()
    vdp = open(base + '.vdp', 'rb').read()
    state = bytearray(256)
    state[0:8] = b'KCMFSNAP'
    state[8] = 1
    for p in range(4):
        slot = (a8 >> (2 * p)) & 3
        state[9 + p] = 1 if slot == 0 else 0	# VG-8020: slot 0 BIOS/BASIC, 3 RAM
    state[13:29] = psg
    state[29:37] = vdp
    state[37] = ppic
    af, bc, de, hl, ix, iy, sp, pc, af2, bc2, de2, hl2, i, r, im, iff = regs
    struct.pack_into('<12H', state, 38, af, bc, de, hl, ix, iy, sp, pc, af2, bc2, de2, hl2)
    state[62:66] = bytes((i & 0xFF, r & 0xFF, im & 3, 1 if iff & 1 else 0))
    struct.pack_into('<HH', state, 66, int(pos), int(length))
    state[70] = HOW.index(how)
    return ram + vram + bytes(state), dict(pc=pc, sp=sp, a8=a8, iff=iff & 1, im=im, pos=pos, length=length, how=how)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--openmsx', required=True)
    ap.add_argument('--sd', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--list', help='tapes, one a line, below --sd')
    ap.add_argument('-j', type=int, default=4)
    ap.add_argument('tapes', nargs='*')
    args = ap.parse_args()

    tapes = [os.path.join(args.sd, t) for t in args.tapes] if args.tapes else []
    if args.list:
        tapes += [os.path.join(args.sd, l.strip()) for l in open(args.list, encoding='utf-8') if l.strip()]
    work = os.path.join(args.out, 'work')
    os.makedirs(work, exist_ok=True)
    items = [('s%04d' % i, t) for i, t in enumerate(tapes)]
    todo = [(i, t) for i, t in items if not os.path.exists(os.path.join(work, i + '.done'))]
    running = []
    while todo or running:
        still = []
        for p, i in running:
            if p.poll() is None:
                still.append((p, i))
            else:
                open(os.path.join(work, i + '.done'), 'w').close()
        running = still
        while todo and len(running) < args.j:
            i, tape = todo.pop(0)
            size = os.path.getsize(tape)
            # a .cas byte takes about 11 bits at 1200 baud on a real tape
            wait = int(size * 11 / 1200) + 90
            script = os.path.join(work, i + '.tcl')
            with open(script, 'w', encoding='utf-8') as fh:
                fh.write(TCL % dict(out=os.path.join(work, i).replace('\\', '/'), tape=os.path.abspath(tape).replace('\\', '/'),
                                    wait=wait, limit=900))
            running.append((subprocess.Popen([args.openmsx, '-machine', 'Philips_VG_8020', '-script', script],
                                             cwd=os.path.dirname(args.openmsx), startupinfo=minimised()), i))
        print('\r%d/%d' % (len(items) - len(todo) - len(running), len(items)), end='', flush=True)
        time.sleep(0.5)
    print()

    with open(os.path.join(args.out, 'report.html'), 'w', encoding='utf-8') as fh:
        fh.write('<!doctype html><meta charset="utf-8"><title>Snapshots</title><style>body{font-family:sans-serif;'
                 'background:#222;color:#ddd;font-size:12px} td{vertical-align:top;padding:4px} img{width:256px}</style><table>')
        for i, tape in items:
            rel = os.path.relpath(tape, args.sd)
            got = build(os.path.join(work, i))
            if not got:
                fh.write('<tr><td>%s</td><td colspan=2>no snapshot (the motor never went off)</td></tr>' % html.escape(rel))
                print('%-50s no snapshot' % rel)
                continue
            snap, info = got
            dest = os.path.join(args.out, os.path.splitext(rel)[0] + '.msxsnap')
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            open(dest, 'wb').write(snap)
            pages = ''.join('R' if not snap[0x14009 + p] else 'B' for p in range(4))
            line = 'PC %04X SP %04X pages %s IFF %d IM %d, %s, tape %d/%d s' % (info['pc'], info['sp'], pages, info['iff'],
                                                                                 info['im'], info['how'], info['pos'], info['length'])
            print('%-50s %s' % (rel, line))
            fh.write('<tr><td>%s<br>%s</td><td><img src="work/%s.now.png"></td><td><img src="work/%s.later.png"></td></tr>' %
                     (html.escape(rel), line, i, i))
        fh.write('</table>')


if __name__ == '__main__':
    main()
