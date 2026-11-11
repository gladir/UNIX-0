#!/usr/bin/env python3
# @author: Sylvain Maltais (support@gladir.com)
# @created: 2026
# @website(https://www.gladir.com/unix-0)
# @description: Affiche et verifie un executable COFF de UNIX-0 (produit par
#   UPC /X) : en-tete de fichier, en-tete a.out, sections et relocalisations.
#   python3 COFFINFO.PY fichier [...]     (code de sortie 1 si incoherent)
import struct, sys

def check(path):
    d = open(path, 'rb').read()
    err = []
    magic, nscns, timdat, symptr, nsyms, opthdr, flags = struct.unpack_from('<HHIIIHH', d, 0)
    print('%s : f_magic=%04Xh f_nscns=%d f_opthdr=%d f_flags=%04Xh' % (path, magic, nscns, opthdr, flags))
    if magic != 0x0153:
        return ['f_magic %04Xh, attendu 0153h (I286LMAGIC)' % magic]
    if not flags & 2:
        err.append('F_EXEC absent')
    om, vs, tsize, dsize, bsize, entry, tstart, dstart = struct.unpack_from('<HHIIIIII', d, 20)
    print('  a.out : magic=%04Xh tsize=%d dsize=%d bsize=%d entry=%05Xh data_start=%05Xh' % (om, tsize, dsize, bsize, entry, dstart))
    end = 0
    secs = []
    for i in range(nscns):
        o = 20 + opthdr + i * 40
        name = d[o:o + 8].rstrip(b'\0').decode('latin-1')
        paddr, vaddr, size, scnptr, relptr, lnno, nrel, nlnno, sflags = struct.unpack_from('<IIIIIIHHI', d, o + 8)
        secs.append((name, vaddr, size, scnptr, relptr, nrel, sflags))
        print('  %-8s vaddr=%05Xh taille=%6d fichier=%6d reloc=%4d flags=%02Xh' % (name, vaddr, size, scnptr, nrel, sflags))
        if vaddr % 16 and name != '.bss':   # .bss prolonge .data dans DS
            err.append('%s : s_vaddr non aligne sur un paragraphe' % name)
        if not sflags & 0x80 and size and scnptr + size > len(d):
            err.append('%s : contenu hors du fichier' % name)
        for r in range(nrel):
            rv, sym, typ = struct.unpack_from('<IiH', d, relptr + r * 10)
            if typ != 9:
                err.append('%s : r_type %d inconnu' % (name, typ))
            if not (vaddr <= rv and rv + 2 <= vaddr + size):
                err.append('%s : relocalisation %05Xh hors section' % (name, rv))
    names = [s[0] for s in secs]
    if '.stack' not in names:
        err.append('section .stack absente')
    for a in secs:
        for b in secs:
            if a is not b and a[1] < b[1] + b[2] and b[1] < a[1] + a[2] and a[2] and b[2]:
                err.append('sections %s et %s se recouvrent' % (a[0], b[0]))
    return err

bad = 0
for p in sys.argv[1:]:
    e = check(p)
    for x in e:
        print('  ERREUR', x)
    bad |= bool(e)
sys.exit(1 if bad else 0)
