"""List what is on a .cas tape: the files, their type and name, and the start of BASIC saved as text.

    python tools/casinfo.py tape.cas [--text N]
"""
import argparse

HEADER = bytes([0x1F, 0xA6, 0xDE, 0xBA, 0xCC, 0x13, 0x7D, 0x74])
KINDS = {0xD0: 'machine code (BLOAD)', 0xD3: 'tokenised BASIC (CLOAD)', 0xEA: 'BASIC as text (LOAD/RUN)'}


def blocks(data):
    """The data of each block, between the headers"""
    pos = [i for i in range(0, len(data) - 7) if data.startswith(HEADER, i)]
    return [data[p + 8:(pos[n + 1] if n + 1 < len(pos) else len(data))] for n, p in enumerate(pos)]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('tape')
    ap.add_argument('--text', type=int, default=8, help='lines of BASIC text to show')
    args = ap.parse_args()
    bl = blocks(open(args.tape, 'rb').read())
    i = 0
    while i < len(bl):
        b = bl[i]
        if len(b) >= 16 and b[0] in KINDS and b[:10] == bytes([b[0]]) * 10:
            kind = b[0]
            name = b[10:16].decode('latin-1')
            print('%-26s "%s"' % (KINDS[kind], name), end='')
            if kind == 0xD0 and i + 1 < len(bl):
                s, e, x = (int.from_bytes(bl[i + 1][j:j + 2], 'little') for j in (0, 2, 4))
                print('  %04X-%04X run %04X' % (s, e, x), end='')
                i += 1
            elif kind == 0xEA:
                text = b''
                while i + 1 < len(bl) and not (len(bl[i + 1]) >= 16 and bl[i + 1][0] in KINDS and bl[i + 1][:10] == bytes([bl[i + 1][0]]) * 10):
                    i += 1
                    text += bl[i]
                    if 0x1A in bl[i]:
                        break
                lines = text.split(b'\x1a')[0].decode('latin-1').replace('\r', '').split('\n')
                print()
                for l in lines[:args.text]:
                    print('    ' + l)
                i += 1
                continue
            elif kind == 0xD3:
                i += 1
            print()
        else:
            print('data block, %d bytes' % len(b))
        i += 1


if __name__ == '__main__':
    main()
