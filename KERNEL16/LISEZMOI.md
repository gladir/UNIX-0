# KERNEL16 : noyau UNIX-0 16 bits

Noyau UNIX pour IBM PC (8086/8088, mode réel), écrit en Pascal dans **un seul
fichier source**, `KERNEL.PAS`, et compilé par **Unix Pascal** (`TOOLS/UPC.PAS`)
en **une seule image monolithique** de plus de 64 Ko (environ 175 Ko : 152 Ko
de code répartis en segments, 26 Ko de données).

## Fichiers

| Fichier | Rôle |
|---|---|
| `KERNEL.PAS` | le noyau (segments-unités KTypes, KLib, KMem, KSched, KDisk, KTty, KFat, KUfs, KVfs, KProc, KSys et le programme principal) |
| `INIT.PAS` | processus 1 (`/etc/init`) : lance `/bin/sh` et le relance, récupère les orphelins |
| `BOOTSECT.ASM` / `.BIN` | secteur d'amorce FAT12/FAT16 : charge le fichier `UNIX` à 1000:0000 |
| `MBR.ASM` / `.BIN` | secteur de partition du disque dur |
| `BUILD.SH` | construit le compilateur, le noyau, toutes les commandes et les images de `IMAGES/` |
| `TESTS/` | tests sous QEMU (processus, systèmes de fichiers) et `RUNTESTS.SH` |

## Construction et essai

```bash
KERNEL16/BUILD.SH
```

```bash
KERNEL16/TESTS/RUNTESTS.SH
```

```bash
qemu-system-i386 -drive file=IMAGES/UNIX0-HD.IMG,format=raw,if=ide -boot c
```

Dans l'IDE **DEVENV** (dépôt DEV-COOLS), UNIX-0 s'exécute dans un onglet
« Émulateur 8086 » : lancer `devenv /DISK0:IMAGES/UNIX0-144.IMG` puis taper
`BOOT A:` dans le terminal CMD de l'IDE (ou `devenv /DISK80:IMAGES/UNIX0-HD.IMG`
puis `BOOT C:`). `KERNEL16/TESTS/DEVENV.SH` refait l'essai automatiquement avec
le banc d'essai sans interface de DEVENV (`/KERNELTEST`, `/KTBOOTIMG`).

Prérequis sur l'hôte : Free Pascal (`fpc`) pour compiler UPC et MKIMAGE, et
facultativement `nasm` (secteurs d'amorce, déjà fournis en `.BIN`), `makefs`
(partition UFS du disque dur) et `qemu-system-i386`.

Compilation du noyau seul : `UPC /K KERNEL.PAS` produit `KERNEL.SYS`, image
plate chargée à 1000:0000, copiée sous le nom `UNIX` à la racine du disque.

## Segments-unités

Le noyau ne peut pas utiliser d'unités (un seul fichier, une seule image) :
Unix Pascal ajoute les **segments-unités** :

```pascal
SegmentUnit KFat;
Uses KTypes,KLib,KDisk;        { segments-unites utilises }
SegmentInterface
 Function FatMount(M: Integer): Integer;
SegmentImplementation
 Function FatMount(M: Integer): Integer;
 Begin ... End;
SegmentEnd;
```

Chaque segment-unité a sa propre portée (des constantes ou variables de même
nom peuvent exister dans deux segments-unités), est accessible par
`KFat.FatMount` et reçoit son propre segment de code. Les données restent
dans un segment DS commun de 64 Ko au plus.

## Organisation (inspirée de UNIX V6 et de xv6, MIT 6.828)

* **Processus** (`KSched`, `KProc`) : table `Procs` de 16 entrées, une pile
  noyau de 4 Ko par processus, commutation `KSwitch` (équivalent de
  `swtch`/`savu`/`retu`), `Sleep`/`Wakeup` sur des canaux, sommeils
  interruptibles par les signaux, réveils temporisés.
* **Ordonnanceur** : tourniquet préemptif ; l'horloge (IRQ 0, INT 08h,
  18,2 Hz) retire le processeur à un processus en mode utilisateur après un
  quantum de 3 tops. Le noyau lui-même n'est pas préemptif (comme UNIX).
  Sans processus prêt, le noyau attend une interruption (`HLT`).
* **Mémoire** (`KMem`) : table des zones libres (*coremap*) en paragraphes,
  allocation au premier ajustement (`malloc` de UNIX V6). Les images 8086
  contiennent des adresses de segments absolues : un fils de `fork` ne peut
  pas être déplacé, il partage l'adresse d'exécution du père et les deux
  images sont **échangées** à chaque commutation (comme le *swapping* de
  UNIX V1). `vfork` évite la copie quand le fils appelle aussitôt `exec`.
* **exec** : chargeur d'exécutables **COFF** (format natif de UNIX-0,
  produit par `UPC /X`) et, pour les programmes DOS, MZ ; préfixe de
  programme compatible PSP (ligne de commande, environnement), `argc/argv`.

## Format des exécutables : COFF

Les commandes de UNIX-0 (`/etc/init`, `/bin/*`) sont des fichiers COFF
(*Common Object File Format* de UNIX System V) produits par `UPC /X` :

| Partie | Contenu |
|---|---|
| en-tête de fichier (20 octets) | `f_magic` = 0153h (I286LMAGIC : Intel 286/8086, modèle large), `f_nscns`, `f_opthdr` = 28, `f_flags` = F_EXEC, F_LNNO, F_LSYMS, F_AR16WR |
| en-tête a.out (28 octets) | `magic` = 0107h (OMAGIC), `tsize`, `dsize`, `bsize`, `entry` (adresse linéaire du point d'entrée), `text_start`, `data_start` |
| sections (40 octets chacune) | `.text`, `.text1`, … (un segment de code 8086 chacune), `.data`, `.bss`, `.stack` (SS = chargement + `s_vaddr`/16, SP = `s_size`), `.heap` (tas minimal de `{$M}`, facultative) |
| relocalisations (10 octets) | `r_vaddr`, `r_symndx` = -1, `r_type` = R_SEG12 (011) : le mot à `r_vaddr` reçoit le paragraphe de chargement |

`s_vaddr` est l'adresse de la section par rapport au début de l'image ; le
noyau charge chaque section à `chargement + s_vaddr`, met à zéro `.bss` et la
pile, puis applique les relocalisations. `TOOLS/COFFINFO.PY` affiche et
vérifie un exécutable COFF.
* **Systèmes de fichiers** (`KFat`, `KUfs`, `KVfs`) : **FAT12**, **FAT16**
  et **UFS1** (FreeBSD : superbloc, groupes de cylindres, inodes de 128
  octets, blocs/fragments, indirections simple et double, cartes et résumés
  tenus à jour), `/dev` (tty, null, zero, disques et partitions), tubes ;
  montages par chemin, cache de 64 secteurs à écriture immédiate.
* **Console** (`KTty`) : écran BIOS, clavier BIOS et COM1, mode canonique
  (effacement, `^U`, `^C` = SIGINT, `^D` = fin de fichier) ou brut. Le
  tampon clavier du BIOS (15 touches) est vidé dans la file du terminal à
  chaque commutation et à chaque fin de quantum. L'écran est écrit sans la
  fonction télétype (curseur AH=02h, caractère AH=09h, défilement AH=06h),
  pour que la position du curseur de la zone BIOS, lue par l'unité CRT des
  programmes, soit juste sur tous les BIOS et émulateurs.
* **Disques** (`KDisk`) : BIOS INT 13h, disquettes et disques durs,
  partitions du MBR.

À l'amorce, la racine est le disque d'amorce (disquette ou partition FAT16
active), `/dev` est monté, et la première partition UFS (type A5h, A6h ou
A9h) est montée sur `/usr`.

## Carte mémoire

| Adresses | Contenu |
|---|---|
| 00000-003FF | vecteurs d'interruption |
| 00400-004FF | données du BIOS |
| 00500-07BFF | pile du processus 0 (amorce) |
| 07C00-07DFF | secteur d'amorce (BPB relu par le noyau) |
| 08000-0FFFF | cache disque (64 tampons de 512 octets) |
| 10000-...   | noyau : code (segments), puis données |
| ...-9FFFF   | piles noyau et mémoire des processus (coremap) |

## Appels système (INT 80h)

AX = numéro, arguments dans BX, CX, DX, SI, DI ; DS:DX = premier pointeur,
ES:DI = second pointeur ; retour dans AX (DX:AX sur 32 bits), CF = 1 et
AX = errno en cas d'erreur. Les numéros suivent ceux de Linux i386.

| N° | Appel | N° | Appel | N° | Appel |
|---|---|---|---|---|---|
| 1 | exit | 2 | fork | 3 | read |
| 4 | write | 5 | open | 6 | close |
| 7 | waitpid | 8 | creat | 9 | link |
| 10 | unlink | 11 | execve | 12 | chdir |
| 13 | time | 15 | chmod | 19 | lseek |
| 20 | getpid | 21 | mount | 22 | umount |
| 24 | getuid | 29 | pause | 36 | sync |
| 37 | kill | 38 | rename | 39 | mkdir |
| 40 | rmdir | 41 | dup | 42 | pipe |
| 45 | brk | 48 | signal | 54 | ioctl |
| 63 | dup2 | 64 | getppid | 88 | reboot |
| 106 | stat | 108 | fstat | 122 | uname |
| 141 | getdents | 158 | sched_yield | 162 | sleep |
| 183 | getcwd | 190 | vfork | 200 | procinfo (ps) |
| 201 | setdos (libc) | 202 | meminfo | 203 | mountinfo |

L'interface Pascal de ces appels est l'unité `UNIX` (`TOOLS/UNIX.PAS`),
intégrée à UPC et liée à tout programme compilé avec `UPC /X`.

## Programmes UNIX-0

`UPC /X PROGRAMME.PAS` compile un programme pour UNIX-0. La bibliothèque
d'exécution de Turbo Pascal et les unités DOS, CRT et PRINTER n'appellent
plus MS-DOS : le vecteur INT 21h est propre à chaque processus et pointe sur
la couche « libc » de l'unité UNIX, qui traduit chaque service (fichiers,
répertoires, FindFirst, Exec, mémoire, date, clavier...) en appels système
UNIX-0, dans le processus lui-même. Les 52 commandes du dépôt (cat, ls, sh,
grep, vi, ...) se compilent ainsi sans modification.

## Limites connues

* Pas de protection mémoire (8086) : un programme peut écraser le noyau.
* Utilisateur unique (root), pas de permissions vérifiées.
* Noms FAT au format 8.3 (présentés en minuscules) ; les recherches UFS
  retombent sur une comparaison sans casse pour les programmes DOS.
* Fichiers de 16 Mo au plus sur UFS (indirection double), pas de liens
  symboliques.
* QEMU 8.2 exécute mal un saut proche 16 bits qui fait le tour des 64 Ko
  d'un segment non aligné sur 4 Ko ; pour les cibles UNIX-0, UPC limite donc
  les segments de code à 32 Ko (aucun saut ne fait le tour du segment).
