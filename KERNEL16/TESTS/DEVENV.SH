#!/bin/bash
# @author: Sylvain Maltais (support@gladir.com)
# @created: 2026
# @website(https://www.gladir.com/unix-0)
# @description: Essai de UNIX-0 dans l'emulateur 8086 de DEVENV (depot
#   DEV-COOLS), en mode banc d'essai sans interface (/KERNELTEST,
#   /KTBOOTIMG) : amorcage de la disquette et du disque dur de IMAGES/, puis
#   commandes tapees dans l'interpreteur et verification de l'ecran.
#   Usage : DEVENV=/chemin/devenv KERNEL16/TESTS/DEVENV.SH
#   Sous Linux, devenv se construit avec DEV-COOLS/OSSPAS_TESTS/
#   devenv_linux_build.py (Free Pascal, unites ptc/graph, X11) et s'execute
#   sous Xvfb (xvfb-run). Dans l'IDE, le meme essai se fait dans un onglet
#   d'emulateur : devenv /DISK0:UNIX0-144.IMG puis BOOT A: dans le terminal
#   CMD (ou /DISK80:UNIX0-HD.IMG puis BOOT C:).
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
DEVENV=${DEVENV:?definir DEVENV (executable de DEVENV)}
T=$(mktemp -d); mkdir -p "$T/kt"
cat > "$T/script.txt" <<'EOS'
run 150000000
type ls
run 40000000
type cat /etc/motd
run 40000000
type cd /bin
run 20000000
type exec uname -o
run 80000000
screen
EOS
fail=0
for img in UNIX0-144 UNIX0-HD; do
  cp "$ROOT/IMAGES/$img.IMG" "$T/$img.img"
  ( cd "$T" && timeout 900 xvfb-run -a "$DEVENV" /KERNELTEST,kt /KTBOOTIMG:$img.img \
      /KTSCRIPT:script.txt /KTSTEPS:900000000 ) > "$T/$img.out" 2>&1
  sed -n '/ECRAN/,/^+----$/p' "$T/$img.out" | tail -14
  if grep -q "UNIX-0$\||UNIX-0 *$" "$T/$img.out" && grep -q "Bienvenue sous UNIX-0" "$T/$img.out"; then
    echo "OK $img (DEVENV)"
  else echo "ECHEC $img (DEVENV)"; fail=1; fi
done
rm -rf "$T"
exit $fail
