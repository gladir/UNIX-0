#!/usr/bin/env python3
# @author: Sylvain Maltais (support@gladir.com)
# @created: 2026
# @website(https://www.gladir.com/unix-0)
# @description: Integre le source de l'unite UNIX (TOOLS/UNIX.PAS) dans le
#   compilateur Unix Pascal (TOOLS/UPC.PAS), sous la forme de la constante
#   UnixSource, comme les autres unites integrees (DOS, CRT, ...).
#   python3 MKEMBED.PY   (depuis le repertoire TOOLS)
import os, sys
here = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(here, 'UNIX.PAS'), encoding='latin-1').read().split('\n')
while src and src[-1] == '':
    src.pop()
lines = []
for l in src:
    l = l.rstrip()
    if len(l) > 250:
        sys.exit('ligne trop longue dans UNIX.PAS: ' + l)
    lines.append(" '" + l.replace("'", "''") + "'")
block = 'const UnixSource: array[1..%d] of string[255] = (\n' % len(lines)
block += ',\n'.join(lines) + ');\n'
upc_path = os.path.join(here, 'UPC.PAS')
upc = open(upc_path, encoding='latin-1').read()
start_mark = '{ --- debut UnixSource (genere par MKEMBED.PY) --- }\n'
end_mark = '{ --- fin UnixSource --- }\n'
if start_mark in upc:
    a = upc.index(start_mark) + len(start_mark)
    b = upc.index(end_mark)
    upc = upc[:a] + block + upc[b:]
else:
    anchor = 'const DosSource:'
    i = upc.index(anchor)
    upc = upc[:i] + start_mark + block + end_mark + upc[i:]
open(upc_path, 'w', encoding='latin-1').write(upc)
print('UnixSource : %d lignes' % len(lines))
