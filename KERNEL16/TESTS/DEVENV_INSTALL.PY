#!/usr/bin/env python3
# @author: Sylvain Maltais (support@gladir.com)
# @created: 2026
# @website(https://www.gladir.com/unix-0)
# @description: Installation de UNIX-0 dans l'onglet "Emulateur 8086" de
#   DEVENV (depot DEV-COOLS), pilote comme le ferait un utilisateur :
#   - l'IDE est lance en plein ecran (-maxscreen) avec un fichier .bat pour
#     l'Invite de commandes : IMGMOUNT A: UNIX0-INST1.IMG, IMGMOUNT C: disque
#     vierge, BOOT A: (ou BOOT /CDROM:UNIX0-CD.ISO puis IMGMOUNT D: disque);
#   - les reponses a l'installateur sont tapees dans l'onglet emulateur;
#   - a chaque "Inserez la disquette N", la disquette est changee dans
#     l'Invite de commandes (IMGMOUNT -u A puis IMGMOUNT A: UNIX0-INSTN.IMG);
#   - le disque installe est ensuite monte sur C: et amorce par BOOT C:.
#   Sans reconnaissance de caracteres, l'avancement se suit par la stabilite
#   de l'ecran de l'emulateur (l'installateur attend une reponse); chaque
#   etape est capturee en PNG dans le dossier de sortie. Le disque installe
#   est verifie (TOOLS/UFSCHK.PY) et redemarre sous QEMU s'il est present.
#   Usage : DEVENV=/chemin/devenv python3 DEVENV_INSTALL.PY [disquettes|cd]
#           [dossier_de_sortie]
#   Sous Linux : Xvfb, xdotool et ImageMagick (import) sont necessaires.
import os, shutil, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
DEVENV = os.environ.get('DEVENV') or sys.exit('definir DEVENV (executable de DEVENV)')
MODE = sys.argv[1] if len(sys.argv) > 1 else 'disquettes'
OUT = os.path.abspath(sys.argv[2] if len(sys.argv) > 2 else 'devenv-install-' + MODE)
DISPLAY = ':78'
EMU = (0, 90, 640, 380)          # zone de texte de l'onglet emulateur
TERM_XY = (400, 1050)            # Invite de commandes (plein ecran 1920x1200)
EMU_XY = (300, 300)
env = dict(os.environ, DISPLAY=DISPLAY)
shots = 0


def sh(*cmd):
    return subprocess.run(cmd, env=env, capture_output=True, text=True).stdout


def shot(name, crop='640x480+0+0'):
    global shots
    shots += 1
    p = os.path.join(OUT, '%02d-%s.png' % (shots, name))
    sh('import', '-window', 'root', '-crop', crop, p)
    return p


def screen_grab():
    """texte de l'onglet emulateur, en octets RGB bruts"""
    return subprocess.run(['import', '-window', 'root', '-crop',
                           '%dx%d+%d+%d' % (EMU[2], EMU[3], EMU[0], EMU[1]), '-depth', '8', 'rgb:-'],
                          env=env, capture_output=True).stdout


def same(a, b):
    """meme ecran au curseur clignotant pres (quelques centaines d'octets)"""
    if len(a) != len(b):
        return False
    return sum(1 for x, y in zip(a[::3], b[::3]) if x != y) < 300


def wait_stable(stable=30, changed=True, limit=1800):
    """attend un changement de l'ecran (si changed), puis stable secondes
    sans changement : l'installateur attend une reponse"""
    end = time.time() + limit
    ref = screen_grab()
    if changed:
        while time.time() < end and same(screen_grab(), ref):
            time.sleep(5)
    last, since = screen_grab(), time.time()
    while time.time() < end:
        time.sleep(5)
        h = screen_grab()
        if not same(h, last):
            last, since = h, time.time()
        elif time.time() - since >= stable:
            return True
    return False


def win():
    return sh('xdotool', 'search', '--onlyvisible', '--name', '.').split()[0]


def click(xy):
    w = win()
    sh('xdotool', 'mousemove', '--window', w, str(xy[0]), str(xy[1]))
    time.sleep(0.3)
    sh('xdotool', 'mousedown', '--window', w, '1')
    time.sleep(0.3)
    sh('xdotool', 'mouseup', '--window', w, '1')
    time.sleep(1)


def type_line(text):
    w = win()
    if text:
        sh('xdotool', 'type', '--window', w, '--delay', '120', text)
    sh('xdotool', 'key', '--window', w, 'Return')


def emulator(text):
    click(EMU_XY)
    type_line(text)


def terminal(*cmds):
    click(TERM_XY)
    for c in cmds:
        type_line(c)
        time.sleep(3)


def main():
    os.makedirs(OUT, exist_ok=True)
    work = os.path.join(OUT, 'images')
    os.makedirs(work, exist_ok=True)
    for f in os.listdir(os.path.join(ROOT, 'IMAGES')):
        if f.startswith('UNIX0-INST') or f == 'UNIX0-CD.ISO':
            shutil.copy(os.path.join(ROOT, 'IMAGES', f), work)
    disk = os.path.join(work, 'disque.img')
    with open(disk, 'wb') as f:
        f.truncate(64 * 1024 * 1024)
    bat = os.path.join(work, 'inst.bat')
    if MODE == 'cd':
        lines = ['BOOT /CDROM:%s/UNIX0-CD.ISO' % work, 'IMGMOUNT D: %s' % disk]
    else:
        lines = ['IMGMOUNT A: %s/UNIX0-INST1.IMG' % work, 'IMGMOUNT C: %s' % disk, 'BOOT A:']
    open(bat, 'w').write('\r\n'.join(lines) + '\r\n')
    xvfb = subprocess.Popen(['Xvfb', DISPLAY, '-screen', '0', '1920x1200x24'],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(2)
    ide = subprocess.Popen([DEVENV, '-maxscreen', '/TERMINALDOS:' + bat], cwd=work, env=env,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    ok = False
    try:
        time.sleep(15)
        wait_stable(20, changed=False)
        shot('amorce')
        emulator('install')                     # connexion "install"
        wait_stable(15)
        shot('type-installation')
        emulator('' if MODE != 'cd' else '2')   # UFS seul / FAT16 + UFS
        time.sleep(5)
        emulator('oui')
        n = 2
        disks = sorted(x for x in os.listdir(work) if x.startswith('UNIX0-INST'))
        last = len(disks)
        while True:
            wait_stable(30)
            shot('etape')
            if MODE == 'cd' or n > last:
                break
            # "Inserez la disquette n" : changement par l'Invite de commandes
            terminal('IMGMOUNT -u A', 'IMGMOUNT A: %s/UNIX0-INST%d.IMG' % (work, n))
            shot('invite-de-commandes', '1360x200+0+880')
            emulator('')
            n += 1
        shot('installation-terminee')
        emulator('non')                         # pas de redemarrage
        time.sleep(15)
        if MODE == 'cd':
            terminal('IMGMOUNT -u C', 'IMGMOUNT -u D', 'IMGMOUNT C: %s' % disk, 'BOOT C:')
        else:
            terminal('IMGMOUNT -u A', 'IMGMOUNT A: %s/UNIX0-INST1.IMG' % work)
            emulator('')
            time.sleep(10)
            terminal('IMGMOUNT -u A', 'BOOT C:')
        wait_stable(20, changed=False)
        time.sleep(30)
        shot('amorce-disque-installe')
        emulator('invite')
        time.sleep(8)
        emulator('invite')
        time.sleep(15)
        emulator('id; ls /; ls /bin | wc -l')
        time.sleep(40)
        shot('session-invite')
        r = subprocess.run([sys.executable, os.path.join(ROOT, 'TOOLS', 'UFSCHK.PY'), '--hd', disk],
                           capture_output=True, text=True)
        print('UFS1 du disque installe : ' + r.stdout.strip().splitlines()[-1])
        ok = r.returncode == 0
    finally:
        ide.kill()
        xvfb.kill()
    print('captures : ' + OUT)
    print('OK DEVENV (%s)' % MODE if ok else 'ECHEC DEVENV (%s)' % MODE)
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
