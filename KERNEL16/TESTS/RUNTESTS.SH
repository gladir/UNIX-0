#!/bin/bash
# @author: Sylvain Maltais (support@gladir.com)
# @created: 2026
# @website(https://www.gladir.com/unix-0)
# @description: Tests du noyau UNIX-0 sous QEMU (apres KERNEL16/BUILD.SH) :
#   chaque programme de test est installe comme /etc/init sur une copie du
#   disque dur, la console serie (COM1) est recueillie, puis les systemes de
#   fichiers sont verifies : UFS1 par TOOLS/UFSCHK.PY, FAT16 par fsck.vfat
#   (paquet dosfstools), s'il est present; enfin TESTS/SESSION.PY ouvre une
#   session complete (getty, login, sh) par la console serie.
#   Usage : KERNEL16/TESTS/RUNTESTS.SH   (W = repertoire de BUILD.SH)
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
W=${W:-/tmp/unix0-build}
[ -x "$W/bin/upc" ] || { echo "lancer d'abord KERNEL16/BUILD.SH"; exit 2; }
T="$W/tests"; rm -rf "$T"; mkdir -p "$T"
fail=0
for t in TPROC TFS; do
  cp "$HERE/$t.PAS" "$T/"
  ( cd "$T" && "$W/bin/upc" /X $t.PAS > $t.log ) || { echo "ECHEC compilation $t"; fail=1; continue; }
  rm -rf "$T/root"; cp -r "$W/hd" "$T/root"; cp "$T/$t" "$T/root/etc/init"
  "$W/bin/mkimage" HD "$T/$t.img" "$ROOT/KERNEL16/MBR.BIN" "$ROOT/KERNEL16/BOOTSECT.BIN" \
    "$T/root" 24 "$W/ufs.img" > /dev/null
  rm -f "$T/$t.out"
  timeout 90 qemu-system-i386 -m 1 -display none -no-reboot -boot c \
    -drive file="$T/$t.img",format=raw,if=ide -serial file:"$T/$t.out" 2>/dev/null &
  Q=$!
  for i in $(seq 1 85); do grep -q "TERMINE\|panique" "$T/$t.out" 2>/dev/null && break; sleep 1; done
  sleep 1; kill $Q 2>/dev/null; wait $Q 2>/dev/null
  sed -n '/^==/,$p' "$T/$t.out" | grep -v "tour"
  if ! grep -q TERMINE "$T/$t.out" || grep -q "ECHEC\|panique" "$T/$t.out"; then
    echo "ECHEC $t"; fail=1
  else echo "OK $t"; fi
  if [ $t = TFS ]; then
    python3 "$ROOT/TOOLS/UFSCHK.PY" --hd "$T/$t.img" | tail -1 | sed 's/^/UFS : /'
    python3 "$ROOT/TOOLS/UFSCHK.PY" --hd "$T/$t.img" > /dev/null || fail=1
    if command -v fsck.vfat > /dev/null; then
      dd if="$T/$t.img" of="$T/fat.img" bs=512 skip=63 count=$(python3 -c "
import struct;d=open('$T/$t.img','rb').read(512);print(struct.unpack_from('<I',d,458)[0])") 2>/dev/null
      if fsck.vfat -n "$T/fat.img" > "$T/fsck.log" 2>&1; then echo "FAT16 : fsck.vfat sans erreur"
      else echo "FAT16 : fsck.vfat signale des erreurs"; cat "$T/fsck.log"; fail=1; fi
    fi
  fi
done
# session complete : getty, login, sh (console serie)
echo "== Session (getty, login, sh)"
python3 "$HERE/SESSION.PY" "$ROOT/IMAGES/UNIX0-HD.IMG" > "$T/session.out" 2>&1 || fail=1
grep -c "^ok" "$T/session.out" | sed 's/^/controles reussis : /'
grep "^ECHEC" "$T/session.out"
tail -1 "$T/session.out"
[ $fail = 0 ] && echo "Tous les tests passent." || { echo "Des tests echouent."; exit 1; }
