#!/usr/bin/env python3
# @author: Sylvain Maltais (support@gladir.com)
# @created: 2026
# @website(https://www.gladir.com/unix-0)
# @description: Decoupe une arborescence UNIX-0 en volumes d'installation au
#   format tar (ustar), a la maniere des bandes de distribution de UNIX V7 :
#   chaque volume tient sur une disquette de 1,44 Mo, sans systeme de
#   fichiers (l'archive est ecrite directement a partir du secteur 0), et
#   commence par le fichier VOLUME ("UNIX-0 numero total"). Les repertoires
#   sont dans le premier volume de donnees; un fichier n'est jamais coupe
#   entre deux volumes. Modes, proprietaires et dates sont ceux de
#   l'arborescence (l'installateur les applique).
#
#   python3 MKVOL.PY arbre prefixe premier_numero
#     -> prefixeN.TAR (volumes, pour le CD-ROM) et prefixeN.IMG (images de
#        disquette de 1 474 560 octets), N = premier_numero, ...
import os, sys, tarfile

FLOPPY = 1474560


def header(name, st, kind, size, uid=None, gid=None):
    ti = tarfile.TarInfo(name)
    ti.mode = st.st_mode & 0o7777 if st else 0o644
    ti.uid = st.st_uid if uid is None else uid
    ti.gid = st.st_gid if gid is None else gid
    ti.mtime = int(st.st_mtime) if st else 0
    ti.type = kind
    ti.size = size
    ti.uname = ti.gname = ''
    return ti.tobuf(format=tarfile.USTAR_FORMAT)


def padded(data):
    return data + bytes((-len(data)) % 512)


def main():
    if len(sys.argv) != 4:
        sys.exit('usage: MKVOL.PY arbre prefixe premier_numero')
    tree, prefix, first = sys.argv[1], sys.argv[2], int(sys.argv[3])
    dirs, files = [], []
    for root, dn, fn in os.walk(tree):
        dn.sort()
        rel = os.path.relpath(root, tree)
        if rel != '.':
            dirs.append(rel)
        for f in sorted(fn):
            files.append(os.path.join(rel, f) if rel != '.' else f)
    # capacite d'un volume : etiquette (2 blocs) et fin d'archive (2 blocs)
    cap = FLOPPY - 4 * 512
    vols = [[]]
    used = 0
    entries = [('d', d, 512) for d in dirs] + \
              [('f', f, 512 + ((os.path.getsize(os.path.join(tree, f)) + 511) // 512) * 512)
               for f in files]
    for kind, name, size in entries:
        if size > cap:
            sys.exit('fichier trop gros pour une disquette : ' + name)
        if used + size > cap:
            vols.append([])
            used = 0
        vols[-1].append((kind, name))
        used += size
    total = len(vols)
    last = first + total - 1
    for k, vol in enumerate(vols):
        num = first + k
        out = bytearray()
        label = ('UNIX-0 %d %d\n' % (num, last)).encode()
        out += header('VOLUME', None, tarfile.REGTYPE, len(label), 0, 0) + padded(label)
        nf = 0
        for kind, name in vol:
            p = os.path.join(tree, name)
            st = os.lstat(p)
            if kind == 'd':
                out += header(name, st, tarfile.DIRTYPE, 0)
            else:
                data = open(p, 'rb').read()
                out += header(name, st, tarfile.REGTYPE, len(data)) + padded(data)
                nf += 1
        out += bytes(1024)
        open('%s%d.TAR' % (prefix, num), 'wb').write(out)
        open('%s%d.IMG' % (prefix, num), 'wb').write(bytes(out).ljust(FLOPPY, b'\0'))
        print('  volume %d/%d : %d fichiers, %d Ko' % (num, last, nf, len(out) // 1024))
    print('%d volume(s) de donnees : disquettes %d a %d' % (total, first, last))


if __name__ == '__main__':
    main()
