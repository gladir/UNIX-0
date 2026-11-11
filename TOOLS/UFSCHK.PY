#!/usr/bin/env python3
# @author: Sylvain Maltais (support@gladir.com)
# @created: 2026
# @website(https://www.gladir.com/unix-0)
# @description: Verification de la coherence d'un systeme de fichiers UFS1
#   (FreeBSD), a la maniere de fsck_ffs (passes 1, 2, 4 et 5), pour tester
#   le pilote UFS du noyau UNIX-0 sur la machine hote.
#
#   python3 UFSCHK.PY image [debut_en_secteurs]
#   python3 UFSCHK.PY --hd IMAGES/UNIX0-HD.IMG   (partition de type A5h)
#
#   Verifie : carte des fragments libres de chaque groupe de cylindres
#   (fragments references par les inodes, regle de FFS pour le dernier bloc
#   direct, blocs indirects), compteurs nbfree/nffree/nifree/ndir (groupe,
#   table csum, superbloc 32 et 64 bits), resume frsum, carte et resume des
#   grappes, carte des inodes, entrees de repertoires et nombres de liens.
import struct, sys

def main():
    args = sys.argv[1:]
    if not args:
        sys.exit(__doc__ or 'usage: UFSCHK.PY image [debut]')
    if args[0] == '--hd':
        d = open(args[1], 'rb').read()
        start = None
        for i in range(4):
            e = d[446 + 16 * i:462 + 16 * i]
            if e[4] in (0xA5, 0xA6, 0xA9):
                start = struct.unpack_from('<I', e, 8)[0]
        if start is None:
            sys.exit('aucune partition UFS')
        d = d[start * 512:]
    else:
        d = open(args[0], 'rb').read()
        if len(args) > 1:
            d = d[int(args[1]) * 512:]
    errors = check(d)
    for e in errors[:60]:
        print('ERREUR', e)
    if len(errors) > 60:
        print('...', len(errors) - 60, 'autres erreurs')
    print('%d erreur(s)' % len(errors))
    sys.exit(1 if errors else 0)

def check(d):
    err = []
    sb = d[8192:8192 + 2048]
    I = lambda o: struct.unpack_from('<i', sb, o)[0]
    if I(1372) != 0x011954:
        return ['superbloc UFS1 absent']
    cblkno, iblkno, dblkno = I(12), I(16), I(20)
    ncg, bsize, fsize, frag = I(44), I(48), I(52), I(56)
    nindir, inopb, csaddr, ipg, fpg = I(116), I(120), I(152), I(184), I(188)
    fsize_total = I(36)
    contig = I(1316)
    frag_of = lambda a: d[a * fsize:(a + 1) * fsize]

    def blk(a):
        return d[a * fsize:a * fsize + bsize]

    def cg(c):
        return d[(fpg * c + cblkno) * fsize:(fpg * c + cblkno) * fsize + I(160)]

    def dinode(n):
        c = n // ipg
        a = fpg * c + iblkno + ((n % ipg) // inopb) * frag
        o = a * fsize + (n % inopb) * 128
        return d[o:o + 128]

    used = {}          # fragment -> inode

    def mark(a, cnt, ino, what):
        for k in range(cnt):
            f = a + k
            if f in used:
                err.append('fragment %d (%s inode %d) deja utilise par %s' % (f, what, ino, used[f]))
            used[f] = 'inode %d' % ino

    # passe 1 : inodes alloues
    inodes = {}
    for c in range(ncg):
        g = cg(c)
        if struct.unpack_from('<i', g, 4)[0] != 0x090255:
            err.append('groupe %d : signature invalide' % c)
            continue
        ioff = struct.unpack_from('<i', g, 92)[0]
        for i in range(ipg):
            n = c * ipg + i
            if g[ioff + i // 8] & (1 << (i % 8)):
                if n < 2:
                    continue
                di = dinode(n)
                mode, nlink = struct.unpack_from('<Hh', di, 0)
                if mode == 0:
                    err.append('inode %d marque utilise mais libre (mode 0)' % n)
                    continue
                inodes[n] = di
            else:
                di = dinode(n)
                if n >= 2 and struct.unpack_from('<H', di, 0)[0] != 0:
                    err.append('inode %d non marque mais mode %o' % (n, struct.unpack_from('<H', di, 0)[0]))
    for n, di in inodes.items():
        size = struct.unpack_from('<q', di, 8)[0]
        db = struct.unpack_from('<12i', di, 40)
        ib = struct.unpack_from('<3i', di, 88)
        blocks = struct.unpack_from('<i', di, 104)[0]
        nfr = 0
        nblk = (size + bsize - 1) // bsize
        for l in range(12):
            if db[l]:
                if l < nblk - 1 or size >= (l + 1) * bsize:
                    cnt = frag
                else:
                    r = size - l * bsize
                    cnt = (r + fsize - 1) // fsize if r > 0 else 0
                    if cnt == 0:
                        err.append('inode %d : bloc %d au-dela de la taille' % (n, l))
                        cnt = frag
                mark(db[l], cnt, n, 'direct')
                nfr += cnt
        if ib[0]:
            mark(ib[0], frag, n, 'indirect')
            nfr += frag
            for a in struct.unpack_from('<%di' % nindir, blk(ib[0])):
                if a:
                    mark(a, frag, n, 'donnee')
                    nfr += frag
        if ib[1]:
            mark(ib[1], frag, n, 'indirect double')
            nfr += frag
            for a1 in struct.unpack_from('<%di' % nindir, blk(ib[1])):
                if a1:
                    mark(a1, frag, n, 'indirect')
                    nfr += frag
                    for a in struct.unpack_from('<%di' % nindir, blk(a1)):
                        if a:
                            mark(a, frag, n, 'donnee')
                            nfr += frag
        if blocks != nfr * fsize // 512:
            err.append('inode %d : di_blocks=%d, attendu %d' % (n, blocks, nfr * fsize // 512))

    # passe 2 et 4 : repertoires et liens
    links = {}
    ndirs = 0
    for n, di in inodes.items():
        mode = struct.unpack_from('<H', di, 0)[0]
        if mode & 0xF000 != 0x4000:
            continue
        ndirs += 1
        size = struct.unpack_from('<q', di, 8)[0]
        db = struct.unpack_from('<12i', di, 40)
        data = b''.join(blk(a) if a else bytes(bsize) for a in db)[:size]
        for base in range(0, size, 512):
            ch = data[base:base + 512]
            p = 0
            while p < 512:
                ino, rl, ty, nl = struct.unpack_from('<IHBB', ch, p)
                if rl < 8 or p + rl > 512:
                    err.append('repertoire %d : entree corrompue a %d' % (n, base + p))
                    break
                if ino:
                    name = ch[p + 8:p + 8 + nl].decode('latin-1')
                    if ino not in inodes:
                        err.append('repertoire %d : "%s" -> inode %d libre' % (n, name, ino))
                    links[ino] = links.get(ino, 0) + 1
                p += rl
    for n, di in inodes.items():
        nl = struct.unpack_from('<h', di, 2)[0]
        if links.get(n, 0) != nl:
            err.append('inode %d : %d lien(s) indiques, %d trouves' % (n, nl, links.get(n, 0)))

    # passe 5 : cartes et compteurs
    tot = [0, 0, 0, 0]
    cs = d[csaddr * fsize:]
    for c in range(ncg):
        g = cg(c)
        base = fpg * c
        ndblk = struct.unpack_from('<i', g, 20)[0]
        foff = struct.unpack_from('<i', g, 96)[0]
        ioff = struct.unpack_from('<i', g, 92)[0]
        # metadonnees : de cgbase a dblkno (et la table csum dans le groupe 0)
        meta = set(range(base, base + dblkno))
        if c == 0:
            cssize = I(156)
            meta |= set(range(csaddr, csaddr + (cssize + fsize - 1) // fsize))
        nffree = nbfree = 0
        frsum = [0] * 8
        clmap = []
        for b in range(ndblk // frag):
            m = 0
            for k in range(frag):
                f = base + b * frag + k
                isfree = bool(g[foff + (b * frag + k) // 8] & (1 << ((b * frag + k) % 8)))
                inuse = f in used or f in meta
                if isfree and inuse:
                    err.append('groupe %d : fragment %d libre mais utilise (%s)' % (c, f, used.get(f, 'meta')))
                if not isfree and not inuse:
                    err.append('groupe %d : fragment %d perdu (ni libre ni utilise)' % (c, f))
                if isfree:
                    m |= 1 << k
            if m == (1 << frag) - 1:
                nbfree += 1
                clmap.append(1)
            else:
                clmap.append(0)
                L = 0
                for k in range(frag + 1):
                    if k < frag and m & (1 << k):
                        L += 1
                    else:
                        if L:
                            frsum[L] += 1
                            nffree += L
                        L = 0
        nifree = sum(1 for i in range(ipg) if not g[ioff + i // 8] & (1 << (i % 8)))
        ndir = sum(1 for n, di in inodes.items() if n // ipg == c and struct.unpack_from('<H', di, 0)[0] & 0xF000 == 0x4000)
        hdr = struct.unpack_from('<4i', g, 24)
        if list(hdr) != [ndir, nbfree, nifree, nffree]:
            err.append('groupe %d : compteurs %s, attendu %s' % (c, list(hdr), [ndir, nbfree, nifree, nffree]))
        csum = struct.unpack_from('<4i', cs, c * 16)
        if list(csum) != [ndir, nbfree, nifree, nffree]:
            err.append('csum %d : %s, attendu %s' % (c, list(csum), [ndir, nbfree, nifree, nffree]))
        fs = list(struct.unpack_from('<8i', g, 52))
        if fs[1:frag] != frsum[1:frag]:
            err.append('groupe %d : frsum %s, attendu %s' % (c, fs[1:frag], frsum[1:frag]))
        if struct.unpack_from('<i', g, 112)[0] and contig > 0:
            coff = struct.unpack_from('<i', g, 108)[0]
            soff = struct.unpack_from('<i', g, 104)[0]
            sums = [0] * (contig + 1)
            run = 0
            for b, fr in enumerate(clmap + [0]):
                bit = b < len(clmap) and bool(g[coff + b // 8] & (1 << (b % 8)))
                if b < len(clmap) and bit != bool(fr):
                    err.append('groupe %d : grappe %d, carte %d, attendu %d' % (c, b, bit, fr))
                if fr:
                    run += 1
                elif run:
                    sums[min(run, contig)] += 1
                    run = 0
            got = list(struct.unpack_from('<%di' % (contig + 1), g, soff))
            if got[1:] != sums[1:]:
                err.append('groupe %d : resume des grappes %s, attendu %s' % (c, got[1:], sums[1:]))
        for k, v in enumerate([ndir, nbfree, nifree, nffree]):
            tot[k] += v
    old = list(struct.unpack_from('<4i', sb, 192))
    new = list(struct.unpack_from('<4q', sb, 1008))
    if old != tot:
        err.append('superbloc (32 bits) %s, attendu %s' % (old, tot))
    if new != tot:
        err.append('superbloc (64 bits) %s, attendu %s' % (new, tot))
    return err

if __name__ == '__main__':
    main()
