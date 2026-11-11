#!/bin/bash
# @author: Sylvain Maltais (support@gladir.com)
# @created: 2026
# @website(https://www.gladir.com/unix-0)
# @description: Construit UNIX-0 et les images de disque amorcables de IMAGES/.
#
#  1. compile le compilateur Unix Pascal (TOOLS/UPC.PAS) et l'outil
#     TOOLS/MKIMAGE.PAS avec Free Pascal (fpc), sur la machine hote;
#  2. assemble le secteur d'amorce et le MBR (nasm), si nasm est present
#     (sinon les fichiers BOOTSECT.BIN et MBR.BIN deja fournis sont utilises);
#  3. compile le noyau : UPC /K KERNEL.PAS -> KERNEL.SYS (copie sous le nom
#     UNIX a la racine des disques);
#  4. compile /etc/init et toutes les commandes UNIX-0 du depot (*.PAS) avec
#     UPC /X (appels systeme UNIX-0);
#  5. fabrique les images :
#       IMAGES/UNIX0-144.IMG  disquette 1,44 Mo FAT12 (commandes essentielles)
#       IMAGES/UNIX0-288.IMG  disquette 2,88 Mo FAT12 (toutes les commandes)
#       IMAGES/UNIX0-HD.IMG   disque dur : partition 1 FAT16 amorcable (racine)
#                             et partition 2 UFS1 (FreeBSD) montee sur /usr
#                             (makefs -t ffs, s'il est present).
#
#  Usage : KERNEL16/BUILD.SH            (depuis n'importe quel repertoire)
#  Variables : FPC (defaut fpc), NASM (defaut nasm), MAKEFS (defaut makefs),
#              W (repertoire de travail, defaut /tmp/unix0-build)
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
W=${W:-/tmp/unix0-build}
FPC=${FPC:-fpc}
NASM=${NASM:-nasm}
MAKEFS=${MAKEFS:-makefs}
rm -rf "$W"; mkdir -p "$W/bin" "$W/src" "$W/log"

echo "== Outils (Free Pascal)"
# copies : TOOLS/UNIX.PAS (unite de UNIX-0) masquerait l'unite unix de FPC
mkdir -p "$W/tools"; cp "$ROOT/TOOLS/UPC.PAS" "$ROOT/TOOLS/MKIMAGE.PAS" "$W/tools/"
( cd "$W/tools" && $FPC -Mtp -O1 -FE"$W/bin" -o"$W/bin/upc" UPC.PAS ) > "$W/log/upc.log" 2>&1 ||
  { tail -20 "$W/log/upc.log"; exit 1; }
( cd "$W/tools" && $FPC -Mtp -O1 -FE"$W/bin" -o"$W/bin/mkimage" MKIMAGE.PAS ) > "$W/log/mkimage.log" 2>&1 ||
  { tail -20 "$W/log/mkimage.log"; exit 1; }
rm -f "$W/bin"/*.o
UPC="$W/bin/upc"

echo "== Secteurs d'amorce"
if command -v "$NASM" >/dev/null; then
  $NASM -f bin -o "$HERE/BOOTSECT.BIN" "$HERE/BOOTSECT.ASM"
  $NASM -f bin -o "$HERE/MBR.BIN" "$HERE/MBR.ASM"
fi

echo "== Noyau"
cp "$HERE/KERNEL.PAS" "$W/src/"
( cd "$W/src" && "$UPC" /K KERNEL.PAS ) | tail -2

echo "== Programmes (UPC /X)"
cp "$ROOT"/*.PAS "$HERE/INIT.PAS" "$W/src/"
fail=0
for f in "$W"/src/*.PAS; do
  n=$(basename "$f" .PAS)
  [ "$n" = KERNEL ] && continue
  if ! ( cd "$W/src" && "$UPC" /X "$n.PAS" > "$W/log/$n.log" 2>&1 ); then
    echo "ECHEC $n"; tail -2 "$W/log/$n.log"; fail=1
  fi
done
[ $fail = 0 ] || exit 1

# arborescence commune
mkroot() {   # mkroot REPERTOIRE LISTE_DE_COMMANDES
  local d=$1; shift
  rm -rf "$d"; mkdir -p "$d/bin" "$d/etc" "$d/dev" "$d/tmp" "$d/usr" "$d/mnt" "$d/home"
  cp "$W/src/KERNEL.SYS" "$d/UNIX"
  cp "$W/src/INIT" "$d/etc/init"
  printf 'Bienvenue sous UNIX-0 !\n' > "$d/etc/motd"
  printf 'root::0:0:root:/:/bin/sh\n' > "$d/etc/passwd"
  for c in "$@"; do
    local l=$(echo "$c" | tr 'A-Z' 'a-z')
    cp "$W/src/$c" "$d/bin/$l"
  done
}
ALL=$(cd "$W/src" && ls *.PAS | sed 's/\.PAS$//' | grep -v -x -e KERNEL -e INIT)
CORE="SH CAT LS ECHO PWD CP MV CHMOD TOUCH HEAD TAIL WC GREP DF DU UNAME CLEAR TRUE FALSE SLEEP REBOOT ENV DD STAT"

mkdir -p "$ROOT/IMAGES"
echo "== Disquette 1,44 Mo"
mkroot "$W/fd144" $CORE
"$W/bin/mkimage" FLOPPY "$ROOT/IMAGES/UNIX0-144.IMG" "$HERE/BOOTSECT.BIN" "$W/fd144" 1440
echo "== Disquette 2,88 Mo"
mkroot "$W/fd288" $ALL
"$W/bin/mkimage" FLOPPY "$ROOT/IMAGES/UNIX0-288.IMG" "$HERE/BOOTSECT.BIN" "$W/fd288" 2880
echo "== Disque dur (FAT16 + UFS)"
mkroot "$W/hd" $ALL
UFSIMG=""
if command -v "$MAKEFS" >/dev/null; then
  rm -rf "$W/ufs"; mkdir -p "$W/ufs/src" "$W/ufs/doc" "$W/ufs/tmp"
  cp "$ROOT"/*.PAS "$HERE/KERNEL.PAS" "$HERE/INIT.PAS" "$W/ufs/src/"
  cp "$ROOT/README.md" "$W/ufs/doc/" 2>/dev/null || true
  printf 'Ce systeme de fichiers est un UFS1 (FreeBSD) monte sur /usr.\n' > "$W/ufs/LISEZMOI"
  $MAKEFS -t ffs -o version=1 -s 8m -f 1024 "$W/ufs.img" "$W/ufs" > "$W/log/makefs.log"
  UFSIMG="$W/ufs.img"
fi
"$W/bin/mkimage" HD "$ROOT/IMAGES/UNIX0-HD.IMG" "$HERE/MBR.BIN" "$HERE/BOOTSECT.BIN" "$W/hd" 24 $UFSIMG
ls -l "$ROOT/IMAGES"
