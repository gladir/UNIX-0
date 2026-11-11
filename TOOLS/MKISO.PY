#!/usr/bin/env python3
# @author: Sylvain Maltais (support@gladir.com)
# @created: 2026
# @website(https://www.gladir.com/unix-0)
# @description: Fabrique un CD-ROM ISO 9660 amorcable (El Torito) de UNIX-0.
#   L'image amorcable est une image de disque dur (MBR + partitions) en mode
#   "emulation de disque dur" d'El Torito : le BIOS la presente comme le
#   disque 80h (le premier disque dur reel devient 81h), le noyau UNIX-0 la
#   lit donc par l'INT 13h comme un disque ordinaire, sans pilote de CD-ROM.
#   Les autres fichiers donnes sont copies a la racine du CD (lisibles par
#   n'importe quel systeme).
#
#   python3 MKISO.PY cd.iso disque_amorce.img [fichier...]
import os, struct, sys, time

SECTOR = 2048


def both16(v):
    return struct.pack('<H', v) + struct.pack('>H', v)


def both32(v):
    return struct.pack('<I', v) + struct.pack('>I', v)


def dtime(t):
    tm = time.gmtime(t)
    return bytes([tm.tm_year - 1900, tm.tm_mon, tm.tm_mday, tm.tm_hour,
                  tm.tm_min, tm.tm_sec, 0])


def vtime(t):
    tm = time.gmtime(t)
    return (time.strftime('%Y%m%d%H%M%S', tm) + '00').encode() + b'\0'


def dirrec(lba, size, name, flags, t):
    n = len(name)
    r = struct.pack('<BB', 0, 0) + both32(lba) + both32(size) + dtime(t) + \
        bytes([flags, 0, 0]) + both16(1) + bytes([n]) + name
    if len(r) % 2:
        r += b'\0'
    return bytes([len(r)]) + r[1:]


def iso_name(n):
    base, _, ext = os.path.basename(n).upper().partition('.')
    keep = lambda s, k: ''.join(c if c.isalnum() or c == '_' else '_' for c in s)[:k]
    return (keep(base, 8) + '.' + keep(ext, 3) + ';1').encode()


def main():
    if len(sys.argv) < 3:
        sys.exit('usage: MKISO.PY cd.iso disque_amorce.img [fichier...]')
    out, bootimg, extra = sys.argv[1], sys.argv[2], sys.argv[3:]
    now = time.time()
    files = [(iso_name(bootimg), open(bootimg, 'rb').read())]
    for f in extra:
        files.append((iso_name(f), open(f, 'rb').read()))
    # disposition : 16 secteurs systeme, PVD (16), El Torito (17),
    # terminateur (18), tables des chemins (19, 20), racine (21),
    # catalogue d'amorce (22), puis les fichiers
    lba = 23
    placed = []
    for name, data in files:
        placed.append((name, lba, data))
        lba += (len(data) + SECTOR - 1) // SECTOR
    total = lba
    root = dirrec(21, SECTOR, b'\0', 2, now) + dirrec(21, SECTOR, b'\1', 2, now)
    for name, l, data in sorted(placed):
        root += dirrec(l, len(data), name, 0, now)
    root = root.ljust(SECTOR, b'\0')
    pt_le = struct.pack('<BBIH', 1, 0, 21, 1) + b'\0\0'
    pt_be = struct.pack('>BBIH', 1, 0, 21, 1) + b'\0\0'
    pvd = b'\x01CD001\x01\0' + b' ' * 32 + b'UNIX0'.ljust(32) + bytes(8) + \
        both32(total) + bytes(32) + both16(1) + both16(1) + both16(SECTOR) + \
        both32(len(pt_le)) + struct.pack('<I', 19) + struct.pack('<I', 0) + \
        struct.pack('>I', 20) + struct.pack('>I', 0) + \
        dirrec(21, SECTOR, b'\0', 2, now) + b' ' * 128 + \
        b'GLADIR.COM'.ljust(128) + b'UNIX0 BUILD.SH'.ljust(128) + \
        b'MKISO.PY'.ljust(128) + b' ' * 37 * 3 + vtime(now) * 2 + \
        b'0' * 16 + b'\0' + b'0' * 16 + b'\0' + b'\x01\0'
    pvd = pvd.ljust(SECTOR, b'\0')
    eltorito = b'\0CD001\x01EL TORITO SPECIFICATION'.ljust(71, b'\0') + \
        struct.pack('<I', 22)
    eltorito = eltorito.ljust(SECTOR, b'\0')
    term = b'\xffCD001\x01'.ljust(SECTOR, b'\0')
    # catalogue : entree de validation puis entree initiale (media 4 =
    # emulation de disque dur, chargement a 07C0:0000, un secteur virtuel)
    val = struct.pack('<BBH24sH', 1, 0, 0, b'UNIX-0'.ljust(24, b'\0'), 0) + b'\x55\xaa'
    s = sum(struct.unpack('<16H', val)) & 0xFFFF
    val = val[:28] + struct.pack('<H', (-s) & 0xFFFF) + val[30:]
    boot_lba = placed[0][1]
    init = struct.pack('<BBHBBHI', 0x88, 4, 0, 0, 0, 1, boot_lba).ljust(32, b'\0')
    cat = (val + init).ljust(SECTOR, b'\0')
    with open(out, 'wb') as f:
        f.write(bytes(16 * SECTOR))
        f.write(pvd + eltorito + term)
        f.write(pt_le.ljust(SECTOR, b'\0') + pt_be.ljust(SECTOR, b'\0'))
        f.write(root + cat)
        for name, l, data in placed:
            f.write(data.ljust(((len(data) + SECTOR - 1) // SECTOR) * SECTOR, b'\0'))
    print('CD-ROM %s : %d Ko, amorce El Torito (emulation de disque dur) %s'
          % (out, total * 2, placed[0][0].decode()))


if __name__ == '__main__':
    main()
