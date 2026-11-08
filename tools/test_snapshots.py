"""Put .msxsnap snapshots back in openMSX with KCMFS's code, the way the board would, and check
the MSX is as it was when the game goes on.

    python tools/test_snapshots.py --openmsx D:/winapps/OpenMSX/openmsx.exe --out sd-rapport/snaptest \
        [--as MSX2] -j 4 Game.msxsnap ...

There is no board, so a 64K RAM cartridge (openMSX's ram64k, put in once BASIC is up) stands in
for it, holding what the board would show (kcmfs/menu.rom, the control block and the snapshot's
banks, mirrored as the board mirrors them), and Tcl watchpoints do what the board does when the
MSX writes 0x8001 and 0x8002 (bank at 0xA000 and 0x6000) or the control block (shown at 0x0000
too). Then menu.rom's init is run. In the stub that goes on to the game (before an interrupt can
come), RAM, VRAM and the registers are compared with the snapshot (all but the stub's 9 bytes
below SP, what kcmfs keeps of the MSX's own, and R). Then the game's PC has to come round with its
SP, and screenshots are kept. report.html has them.
"""
import argparse, html, os, struct, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from test_disks import minimised

MACHINES = {'MSX1': 'Philips_VG_8020', 'MSX2': 'Philips_NMS_8250'}
BANK = 0x2000
CTRL_SNAP = 0x0B

TCL = r'''
set out "%(out)s"
after realtime 120 {exit}
set f [open "%(image)s" rb] ; set img [read $f] ; close $f
proc bank {b} { return [string range $::img [expr {$b * 8192}] [expr {$b * 8192 + 8191}]] }
proc log {msg} { set f [open "$::out.log" a] ; puts $f $msg ; close $f }
set ram {}
proc board_write {} {
    set a $::wp_last_address
    set v $::wp_last_value
    debug write $::ram [expr {$a & 0x00FF}] $v
    if {($a & 0xFF) == 1} {
        debug write_block $::ram 0x2000 [bank [expr {$v & 63}]]
        debug write_block $::ram 0xA000 [bank [expr {$v & 63}]]
    } elseif {($a & 0xFF) == 2} {
        debug write_block $::ram 0x6000 [bank [expr {$v & 63}]]
        debug write_block $::ram 0xE000 [bank [expr {$v & 63}]]
    }
}
# in the stub, all but A, F, PC and the slots are the game's, and no interrupt has come yet
proc at_stub {} {
    set r {}
    foreach n {af bc de hl ix iy sp pc af2 bc2 de2 hl2 i im iff} { lappend r [reg $n] }
    set f [open "$::out.regs" w] ; puts $f $r ; close $f
    set f [open "$::out.ram" wb] ; puts -nonewline $f [debug read_block {Main RAM} 0 65536] ; close $f
    set f [open "$::out.vram" wb] ; puts -nonewline $f [debug read_block {physical VRAM} 0 16384] ; close $f
    set f [open "$::out.vdp" wb] ; puts -nonewline $f [debug read_block {VDP regs} 0 8] ; close $f
    set f [open "$::out.psg" wb] ; puts -nonewline $f [debug read_block {PSG regs} 0 16] ; close $f
    set f [open "$::out.stub" wb] ; puts -nonewline $f [debug read_block memory [reg pc] 9] ; close $f
    set f [open "$::out.map" w] ; foreach p {0xFC 0xFD 0xFE 0xFF} { puts -nonewline $f "[debug read ioports $p] " } ; close $f
    debug remove_bp $::bp_stub
}
proc resumed {} {
    set f [open "$::out.back" w] ; puts $f [format %%02X [debug read ioports 0xA8]] ; close $f
    debug remove_bp $::bp
    after time 3 { set ::throttle on ; after realtime 0.5 { screenshot -raw "$::out.3s.png" ; set ::throttle off } }
    after time 10 { set ::throttle on ; after realtime 0.5 { screenshot -raw "$::out.10s.png" ; exit } }
}
after time %(boot)d {
    set before [debug list]
    ext ram64k
    foreach d [debug list] { if {[lsearch -exact $before $d] < 0 && [debug size $d] == 65536} { set ::ram $d } }
    log "cartridge RAM: $::ram"
    log [slotmap]
    # what the board shows: menu.rom at 0x4000 (bank 0 and 1), the control block at 0x0000 and
    # 0x8000 (bank 2), the window at 0x2000 and 0xA000 (bank 3 to start with)
    foreach {addr b} {0x0000 2 0x2000 3 0x4000 0 0x6000 1 0x8000 2 0xA000 3 0xC000 0 0xE000 1} {
        debug write_block $::ram $addr [bank $b]
    }
    log "slots: [slotselect]"
    debug set_watchpoint write_mem {0x8000 0x80FF} {[watch_in_slot %(slot)s]} board_write
    set ::bp_stub [debug set_bp %(stub)d {[reg sp] == %(stub)d + 5} at_stub]
    set ::bp [debug set_bp %(pc)d {[reg sp] == %(sp)d} resumed]
    debug break
    set a8 [debug read ioports 0xA8]
    debug write ioports 0xA8 [expr {($a8 & 0xF3) | (%(slot)s << 2)}]
    reg pc %(init)d
    debug cont
    set ::throttle off
}
'''


def board_image(menu, snap):
    """The 16 banks the board has for a snapshot: menu.rom, the control block, VRAM, the state, RAM"""
    img = bytearray(16 * BANK)
    img[0:len(menu)] = menu
    img[2 * BANK + CTRL_SNAP] = 1
    img[3 * BANK:3 * BANK + 0x4000] = snap[0x10000:0x14000]
    img[5 * BANK:5 * BANK + 256] = snap[0x14000:0x14100]
    img[8 * BANK:16 * BANK] = snap[0:0x10000]
    return bytes(img)


def logical_ram(base, machine):
    """The 64K the CPU sees as RAM: on the MSX2 'Main RAM' is the memory mapper's, page by page as
    ports FC to FF select its segments"""
    ram = open(base + '.ram', 'rb').read()
    if machine == 'MSX1':
        return ram
    segs = [int(x) & 7 for x in open(base + '.map').read().split()]
    return b''.join(ram[s * 0x4000:(s + 1) * 0x4000] for s in segs)


def check(base, snap, machine):
    """What differs from the snapshot in the stub, and whether the game's PC came round after it"""
    if not os.path.exists(base + '.regs'):
        return ['never got to the stub']
    bad = []
    if not os.path.exists(base + '.back'):
        bad.append('never got back to its PC')
    regs = [int(x) for x in open(base + '.regs').read().split()]
    st = snap[0x14000:]
    af, bc, de, hl, ix, iy, sp, pc, af2, bc2, de2, hl2 = struct.unpack_from('<12H', st, 38)
    i, im, iff = st[62], st[64], st[65]
    ram = logical_ram(base, machine)
    # the stub (out (0xA8),a / pop af / ei or nop / ret) runs with SP 4 below the game's, F, A and
    # the PC on the stack and A for 0xA8. Both machines have the main ROM in slot 0 and the RAM in
    # primary slot 3
    a8 = sum((0 if st[9 + p] else 3) << (2 * p) for p in range(4))
    want = {'bc': bc, 'de': de, 'hl': hl, 'ix': ix, 'iy': iy, 'sp': (sp - 4) & 0xFFFF, 'pc': (sp - 9) & 0xFFFF,
            'af2': af2, 'bc2': bc2, 'de2': de2, 'hl2': hl2, 'i': i, 'im': im}
    got = dict(zip('af bc de hl ix iy sp pc af2 bc2 de2 hl2 i im iff'.split(), regs))
    for n, exp in want.items():
        if got[n] != exp:
            bad.append('%s %X, not %X' % (n, got[n], exp))
    if got['af'] >> 8 != a8:
        bad.append('A8 %02X, not %02X' % (got['af'] >> 8, a8))
    stub = open(base + '.stub', 'rb').read()
    if stub != bytes([0xD3, 0xA8, 0xF1, 0xFB if iff else 0, 0xC9]) + struct.pack('<HH', af, pc):
        bad.append('stub %s' % stub.hex())
    # the MSX's own slot tables (EXPTBL, SLTTBL), and on an MSX2 its MSX2 variables (where the
    # game's stack is not) and the secondary slot register, stay (kcmfs/menu.asm CB_KEEP)
    kept = [(0xFCC1, 0xFCC9), (sp - 9, sp)]
    if snap[0xF341:0xF345] == b'\x03' * 4:
        kept += [(0xF341, 0xF345)]		# RAMAD0-3: the RAM's slot on this MSX
    if machine != 'MSX1':
        kept += [(0xFFFF, 0x10000)]
        if sp >> 8 not in (0xFA, 0xFB):
            kept += [(0xFAF5, 0xFB03)]
        if sp >> 8 not in (0xFF, 0x00):
            kept += [(0xFFE7, 0xFFFF)]
    diff = [a for a in range(65536) if ram[a] != snap[a] and not any(lo <= a < hi for lo, hi in kept)]
    if diff:
        bad.append('RAM: %d bytes, %s' % (len(diff), ' '.join('%04X:%02X/%02X' % (a, ram[a], snap[a]) for a in diff[:6])))
    vram = open(base + '.vram', 'rb').read()
    vd =[a for a in range(16384) if vram[a] != snap[0x10000 + a]]
    if vd:
        bad.append('VRAM: %d bytes, first at %04X' % (len(vd), vd[0]))
    vdp = bytearray(open(base + '.vdp', 'rb').read())
    want_vdp = bytearray(st[29:37])
    if machine != 'MSX1':
        # the V9938 has no 4K/16K bit in R1
        vdp[1] &= 0x7F
        want_vdp[1] &= 0x7F
    if vdp != want_vdp:
        bad.append('VDP registers %s, not %s' % (vdp.hex(), want_vdp.hex()))
    psg = open(base + '.psg', 'rb').read()
    if psg[:14] != st[13:27][:7] + bytes([(st[20] & 0x3F) | 0x80]) + st[21:27]:
        bad.append('PSG registers')
    return bad


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--openmsx', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--menu', default=os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'kcmfs', 'menu.rom'))
    ap.add_argument('--as', dest='as_machine', choices=sorted(MACHINES), default='MSX1')
    ap.add_argument('-j', type=int, default=4)
    ap.add_argument('snaps', nargs='+')
    args = ap.parse_args()

    menu = open(args.menu, 'rb').read()
    init = menu[2] | menu[3] << 8
    os.makedirs(args.out, exist_ok=True)
    items = [('r%04d' % i, s) for i, s in enumerate(args.snaps)]
    todo = list(items)
    running = []
    while todo or running:
        running = [p for p in running if p.poll() is None]
        while todo and len(running) < args.j:
            i, s = todo.pop(0)
            base = os.path.join(args.out, i)
            for ext in ('.regs', '.log'):
                if os.path.exists(base + ext):
                    os.remove(base + ext)
            snap = open(s, 'rb').read()
            open(base + '.img', 'wb').write(board_image(menu, snap))
            st = snap[0x14000:]
            sp, pc = struct.unpack_from('<HH', st, 50)
            script = base + '.tcl'
            with open(script, 'w', encoding='utf-8') as fh:
                fh.write(TCL % dict(out=base.replace('\\', '/'), image=(base + '.img').replace('\\', '/'),
                                    slot=1, init=init, pc=pc, sp=sp, stub=(sp - 9) & 0xFFFF,
                                    boot=8 if args.as_machine == 'MSX1' else 16))
            running.append(subprocess.Popen([args.openmsx, '-machine', MACHINES[args.as_machine], '-script', script],
                                            cwd=os.path.dirname(args.openmsx), startupinfo=minimised()))
        time.sleep(0.5)

    with open(os.path.join(args.out, 'report.html'), 'w', encoding='utf-8') as fh:
        fh.write('<!doctype html><meta charset="utf-8"><title>Snapshot test</title><style>body{font-family:sans-serif;'
                 'background:#222;color:#ddd;font-size:12px} td{vertical-align:top;padding:4px} img{width:256px}'
                 '.bad{color:#f66}.ok{color:#6f6}</style><h1>Snapshots put back (%s)</h1><table>' % args.as_machine)
        for i, s in items:
            bad = check(os.path.join(args.out, i), open(s, 'rb').read(), args.as_machine)
            name = os.path.basename(s)
            print('%-40s %s' % (name, '; '.join(bad) if bad else 'as it was'))
            fh.write('<tr><td>%s<br><span class="%s">%s</span></td><td><img src="%s.3s.png"></td><td><img src="%s.10s.png"></td></tr>' %
                     (html.escape(name), 'bad' if bad else 'ok', html.escape('; '.join(bad) or 'as it was'), i, i))
        fh.write('</table>')


if __name__ == '__main__':
    main()
