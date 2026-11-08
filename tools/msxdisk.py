"""MSX-DOS 1 (FAT12) disk images: read the files on one, and make a new one.

Only what organise_sd.py needs: the root directory (MSX-DOS 1 has no folders), 360K/720K and
the old 180K/360K 40 track formats for reading, 720K for writing.
"""
import struct

SECTOR = 512


class DiskError(Exception):
    pass


class Image:
    """A disk image in memory, read through its boot sector (BPB)."""

    def __init__(self, data):
        if len(data) < SECTOR * 4:
            raise DiskError('too small')
        self.data = bytearray(data)
        b = self.data
        self.bytes_per_sector, self.sectors_per_cluster, self.reserved, self.fats, \
            self.root_entries, self.total_sectors, self.media, self.sectors_per_fat = \
            struct.unpack_from('<HBHBHHBH', b, 0x0B)
        if self.bytes_per_sector != SECTOR or self.fats not in (1, 2) or \
                self.sectors_per_cluster not in (1, 2, 4) or not 0 < self.sectors_per_fat < 10:
            # Some old disks have no BPB. The media byte at the start of the FAT says what it is
            self._from_media(b[SECTOR])
        self.fat_start = self.reserved * SECTOR
        self.root_start = self.fat_start + self.fats * self.sectors_per_fat * SECTOR
        self.data_start = self.root_start + self.root_entries * 32

    def _from_media(self, media):
        # sectors per cluster, root entries, sectors, sectors per FAT (MSX-DOS 1 defaults)
        table = {0xF8: (2, 112, 720, 2), 0xF9: (2, 112, 1440, 3), 0xFA: (1, 112, 640, 1),
                 0xFB: (2, 112, 1280, 2), 0xFC: (1, 64, 360, 2), 0xFD: (2, 112, 720, 2),
                 0xFE: (1, 64, 320, 1), 0xFF: (2, 112, 640, 1)}
        if media not in table:
            raise DiskError('no BPB and unknown media byte %02X' % media)
        self.bytes_per_sector = SECTOR
        self.sectors_per_cluster, self.root_entries, self.total_sectors, self.sectors_per_fat = table[media]
        self.reserved, self.fats, self.media = 1, 2, media

    def _fat(self, n):
        o = self.fat_start + n * 3 // 2
        v = self.data[o] | (self.data[o + 1] << 8)
        return (v >> 4) if n & 1 else (v & 0xFFF)

    def files(self):
        """[(name 'NAME.EXT', attributes, first cluster, size)] in the root directory."""
        out = []
        for i in range(self.root_entries):
            e = self.data[self.root_start + i * 32:self.root_start + i * 32 + 32]
            if len(e) < 32 or e[0] == 0:
                break
            if e[0] == 0xE5 or e[11] & 0x08:	# deleted, volume label
                continue
            name = e[0:8].decode('latin-1').rstrip()
            ext = e[8:11].decode('latin-1').rstrip()
            cluster, size = struct.unpack_from('<HI', e, 26)
            out.append((name + ('.' + ext if ext else ''), e[11], cluster, size))
        return out

    def read(self, name):
        for n, attr, cluster, size in self.files():
            if n.upper() == name.upper():
                out = bytearray()
                csize = self.sectors_per_cluster * SECTOR
                seen = 0
                while 2 <= cluster < 0xFF0 and len(out) < size and seen < 4096:
                    o = self.data_start + (cluster - 2) * csize
                    out += self.data[o:o + csize]
                    cluster = self._fat(cluster)
                    seen += 1
                return bytes(out[:size])
        raise DiskError('no file ' + name)


def dos_name(name):
    """'game.bin' -> (b'GAME    ', b'BIN'), or None if it is not a plain 8.3 name."""
    name = name.upper()
    base, dot, ext = name.partition('.')
    ok = set('ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&\'()-@^_`{}~')
    if not base or len(base) > 8 or len(ext) > 3 or not set(base + ext) <= ok:
        return None
    return base.ljust(8).encode(), ext.ljust(3).encode()


def make_720k(boot_sector, files):
    """A 720K MSX-DOS disk (media F9) with files [(name, bytes)] or [(name, bytes, attributes)]
    in the root directory.
    boot_sector is a 512 byte MSX boot sector to use (from a disk openMSX formatted)."""
    spc, root_entries, total, spf, fats = 2, 112, 1440, 3, 2
    img = bytearray(total * SECTOR)
    img[0:SECTOR] = boot_sector
    struct.pack_into('<HBHBHHBHHHH', img, 0x0B, SECTOR, spc, 1, fats, root_entries, total, 0xF9, spf, 9, 2, 0)
    fat = bytearray(spf * SECTOR)
    fat[0:3] = b'\xF9\xFF\xFF'
    root = bytearray(root_entries * 32)
    data_start = (1 + fats * spf) * SECTOR + root_entries * 32
    csize = spc * SECTOR
    clusters = (total * SECTOR - data_start) // csize
    next_cluster = 2

    def set_fat(n, v):
        o = n * 3 // 2
        if n & 1:
            fat[o] = (fat[o] & 0x0F) | ((v << 4) & 0xF0)
            fat[o + 1] = (v >> 4) & 0xFF
        else:
            fat[o] = v & 0xFF
            fat[o + 1] = (fat[o + 1] & 0xF0) | ((v >> 8) & 0x0F)

    if len(files) > root_entries:
        raise DiskError('too many files')
    for i, entry in enumerate(files):
        name, data = entry[0], entry[1]
        attr = (entry[2] & 0x27) if len(entry) > 2 else 0x20
        dn = dos_name(name)
        if dn is None:
            raise DiskError('not an 8.3 name: ' + name)
        need = (len(data) + csize - 1) // csize
        if next_cluster - 2 + need > clusters:
            raise DiskError('does not fit on 720K')
        first = next_cluster if need else 0
        for c in range(need):
            n = next_cluster + c
            set_fat(n, n + 1 if c < need - 1 else 0xFFF)
            o = data_start + (n - 2) * csize
            img[o:o + csize] = data[c * csize:(c + 1) * csize].ljust(csize, b'\0')
        next_cluster += need
        e = dn[0] + dn[1] + bytes([attr]) + b'\0' * 10 + struct.pack('<HHHI', 0, 0x0021, first, len(data))
        root[i * 32:i * 32 + 32] = e
    for f in range(fats):
        o = (1 + f * spf) * SECTOR
        img[o:o + len(fat)] = fat
    o = (1 + fats * spf) * SECTOR
    img[o:o + len(root)] = root
    return bytes(img)
