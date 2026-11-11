#!/usr/bin/env python3
# @author: Sylvain Maltais (support@gladir.com)
# @created: 2026
# @website(https://www.gladir.com/unix-0)
# @description: Essai du reseau de UNIX-0 sous QEMU (apres KERNEL16/BUILD.SH) :
#   une image de disque dur dont /unix est le noyau avec le reseau (/unixnet)
#   demarre avec une carte NE2000 ISA (ne2k_isa, port 300h, IRQ 3), puis
#   PCI (ne2k_pci, RTL8029), sur le reseau "user" de QEMU (passerelle et
#   serveur DHCP 10.0.2.2, DNS 10.0.2.3; ports de l'invite rediriges vers
#   l'hote). Controles :
#   - detection de la carte au demarrage, dhclient (adresse, route, DNS);
#   - ping de la passerelle, de 127.0.0.1 et de sa propre adresse;
#   - fetch d'un fichier d'un serveur HTTP de l'hote (texte, puis 100 Ko);
#   - nc : envoi de 100 Ko vers un serveur TCP de l'hote (contenu compare),
#     echo UDP, serveur TCP de l'invite (nc -l 7 -e /bin/cat) joint par
#     l'hote;
#   - httpd de l'invite interroge par l'hote (page, liste d'un repertoire);
#   - netstat, route, arp, host.
#   Usage : python3 NET.PY   (W = repertoire de BUILD.SH; code 0 si OK)
import functools, http.server, os, re, shutil, socket, subprocess, sys
import tempfile, threading, time, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
W = os.environ.get('W', '/tmp/unix0-build')
TMP = tempfile.mkdtemp()
fails = 0


def ok(cond, what):
    global fails
    print(('ok    ' if cond else 'ECHEC ') + what)
    if not cond:
        fails += 1


def make_image():
    # racine UFS de BUILD.SH, avec le noyau reseau comme /unix
    tree = os.path.join(TMP, 'root')
    subprocess.run(['cp', '-a', os.path.join(W, 'ufsroot'), tree], check=True)
    shutil.copy(os.path.join(tree, 'unixnet'), os.path.join(tree, 'unix'))
    ufs = os.path.join(TMP, 'ufs.img')
    subprocess.run([os.environ.get('MAKEFS', 'makefs'), '-t', 'ffs', '-o', 'version=1',
                    '-s', '16m', '-f', '1024', ufs, tree], check=True, stdout=subprocess.DEVNULL)
    img = os.path.join(TMP, 'net.img')
    subprocess.run([os.path.join(W, 'bin', 'mkimage'), 'UFS', img,
                    os.path.join(ROOT, 'KERNEL16', 'MBR.BIN'),
                    os.path.join(ROOT, 'KERNEL16', 'UFSBOOT.BIN'), ufs, '4'],
                   check=True, stdout=subprocess.DEVNULL)
    return img


class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a):
        pass


def run(img, card, model):
    base = 7400 + os.getpid() % 300
    ser, fwd80, fwd7, http_port, sink, udp = base, base + 1, base + 2, base + 3, base + 4, base + 5
    www = os.path.join(TMP, 'www')
    os.makedirs(www, exist_ok=True)
    data = bytes((i * 7 + 3) & 255 for i in range(100000))
    open(os.path.join(www, 'data.bin'), 'wb').write(data)
    open(os.path.join(www, 'hello.txt'), 'w').write('bonjour du serveur HTTP de l hote\n')
    hs = http.server.HTTPServer(('127.0.0.1', http_port), functools.partial(Quiet, directory=www))
    threading.Thread(target=hs.serve_forever, daemon=True).start()
    got = {}

    def tcp_sink():
        ls = socket.socket()
        ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        ls.bind(('127.0.0.1', sink)); ls.listen(1); ls.settimeout(300)
        try:
            c, _ = ls.accept()
            d = b''
            while True:
                x = c.recv(65536)
                if not x:
                    break
                d += x
            got['sink'] = d
            c.close()
        except OSError:
            pass

    def udp_echo():
        u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        u.bind(('127.0.0.1', udp)); u.settimeout(300)
        try:
            d, a = u.recvfrom(2048)
            u.sendto(d.upper(), a)
        except OSError:
            pass

    threading.Thread(target=tcp_sink, daemon=True).start()
    threading.Thread(target=udp_echo, daemon=True).start()
    q = subprocess.Popen(['qemu-system-i386', '-m', '1', '-display', 'none', '-no-reboot',
                          '-drive', 'file=%s,format=raw,if=ide,snapshot=on' % img, '-boot', 'c',
                          '-serial', 'tcp:127.0.0.1:%d,server,nowait' % ser,
                          '-netdev', 'user,id=n0,hostfwd=tcp:127.0.0.1:%d-:80,'
                          'hostfwd=tcp:127.0.0.1:%d-:7' % (fwd80, fwd7),
                          '-device', card + ',netdev=n0'],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    s = None
    for i in range(50):
        try:
            s = socket.create_connection(('127.0.0.1', ser))
            break
        except OSError:
            time.sleep(0.2)
    s.settimeout(0.3)
    st = {'out': ''}

    def pump(t):
        end = time.time() + t
        while time.time() < end:
            try:
                d = s.recv(4096)
                if d:
                    st['out'] += d.decode('latin-1')
            except socket.timeout:
                pass

    def expect(p, t=60, since=0):
        end = time.time() + t
        while time.time() < end:
            m = re.search(p, st['out'][since:])
            if m:
                return m
            pump(0.3)
        return None

    def cmd(c, t=60):
        b = len(st['out'])
        for ch in c + '\r':
            s.send(ch.encode('latin-1'))
            time.sleep(0.01)
        expect(r'\n# $', t, b + len(c))
        return st['out'][b:].replace('\r', '')

    try:
        ok(expect(r'login: ', 120) is not None, '%s : demarrage' % model)
        boot = st['out']
        ok('reseau TCP/IP' in boot and re.search(r'ne0 : %s' % re.escape(model), boot) is not None,
           '%s : carte detectee (%s)' % (model, re.search(r'ne0 : [^\r\n]*', boot).group(0)
                                        if 'ne0 :' in boot else '?'))
        for ch in 'root\r':
            s.send(ch.encode()); time.sleep(0.01)
        expect(r'# $', 30)
        r = cmd('dhclient', 60)
        ok('10.0.2.15/24' in r and 'passerelle 10.0.2.2' in r and 'DNS 10.0.2.3' in r,
           '%s : dhclient (%s)' % (model, r.strip().splitlines()[-2] if r.strip() else '?'))
        r = cmd('ping -c 2 10.0.2.2; ping -c 1 127.0.0.1; ping -c 1 10.0.2.15', 60)
        ok(r.count('0 % de perte') == 3, '%s : ping passerelle, boucle locale, propre adresse' % model)
        r = cmd('route; cat /etc/resolv.conf; host localhost', 30)
        ok('default' in r and 'nameserver 10.0.2.3' in r and '127.0.0.1' in r,
           '%s : route, resolv.conf, host' % model)
        r = cmd('fetch -o - http://10.0.2.2:%d/hello.txt' % http_port, 60)
        ok('bonjour du serveur HTTP de l hote' in r, '%s : fetch (texte)' % model)
        t = time.time()
        r = cmd('fetch -o /tmp/data.bin http://10.0.2.2:%d/data.bin' % http_port, 240)
        ok('100000 octets' in r, '%s : fetch de 100 Ko (%.1f s)' % (model, time.time() - t))
        t = time.time()
        cmd('nc 10.0.2.2 %d < /tmp/data.bin' % sink, 240)
        time.sleep(1)
        ok(got.get('sink') == data, '%s : nc, 100 Ko vers l\'hote, contenu identique (%.1f s)'
           % (model, time.time() - t))
        r = cmd('echo bonjour-udp | nc -u -w 2 10.0.2.2 %d' % udp, 60)
        ok('BONJOUR-UDP' in r, '%s : nc -u, echo UDP' % model)
        cmd('nc -l 7 -e /bin/cat &', 20)
        time.sleep(2)
        try:
            c = socket.create_connection(('127.0.0.1', fwd7), timeout=20)
            c.sendall(b'echo TCP de l hote\n'); time.sleep(1); c.shutdown(socket.SHUT_WR)
            d = b''
            while True:
                x = c.recv(4096)
                if not x:
                    break
                d += x
            ok(d == b'echo TCP de l hote\n', '%s : serveur TCP de l\'invite (nc -l -e cat)' % model)
        except OSError as e:
            ok(False, '%s : serveur TCP de l\'invite : %s' % (model, e))
        pump(1)
        cmd('httpd 2> /dev/null &', 20)
        time.sleep(2)
        try:
            p = urllib.request.urlopen('http://127.0.0.1:%d/' % fwd80, timeout=30).read()
            l = urllib.request.urlopen('http://127.0.0.1:%d/doc/' % fwd80, timeout=30).read()
            ok(b'<h1>UNIX-0</h1>' in p and b'LISEZMOI.md' in l, '%s : httpd (page, liste)' % model)
        except OSError as e:
            ok(False, '%s : httpd : %s' % (model, e))
        r = cmd('netstat; arp -a; netstat -i', 60)
        ok('*.80' in r and 'LISTEN' in r and '10.0.2.2 a 52:55:0a:00:02:02' in r,
           '%s : netstat, arp' % model)
        m = re.search(r'ne0 +1500 +10\.0\.2\.0/24 +10\.0\.2\.15 +(\d+) +(\d+) +(\d+) +(\d+)', r)
        ok(m is not None and m.group(2) == '0' and m.group(4) == '0',
           '%s : compteurs de ne0 sans erreur (%s)' % (model, m.group(0) if m else '?'))
    finally:
        q.kill()
        q.wait()
        hs.shutdown()


img = make_image()
print('== Carte NE2000 ISA')
run(img, 'ne2k_isa,iobase=0x300,irq=3', 'NE2000 ISA')
print('== Carte NE2000 PCI')
run(img, 'ne2k_pci', 'NE2000 PCI (RTL8029)')
shutil.rmtree(TMP)
print('Reseau : %d echec(s)' % fails)
sys.exit(1 if fails else 0)
