{ @author: Sylvain Maltais (support@gladir.com)
  @created: 2026
  @website(https://www.gladir.com/unix-0)
  @abstract(Target: Unix Pascal (UPC /X))
  @description: Unite UNIX de Unix Pascal : interface des appels systeme du
   noyau UNIX-0 (INT 80h) et bibliotheque "libc" de la cible UNIX-0.

  Cette unite est integree au compilateur UPC (regeneree dans UPC.PAS par
  TOOLS/MKEMBED.PY) et liee automatiquement a tout programme compile avec
  l'option /X, avant toute autre unite.

  Convention des appels systeme UNIX-0 (INT 80h) :
   AX = numero de l'appel, BX, CX, DX, SI, DI = arguments, DS:DX = premier
   pointeur, ES:DI = second pointeur. Retour : AX (DX:AX pour 32 bits),
   CF=1 en cas d'erreur avec AX = errno.

  Couche libc : la bibliotheque d'execution de Turbo Pascal (et les unites
  DOS, CRT, PRINTER) s'adressent aux services de MS-DOS par INT 21h. Sous
  UNIX-0, le vecteur 21h est propre a chaque processus : le noyau y place
  l'adresse de DosEntry, enregistree par l'appel systeme 201 (setdos) lors de
  l'initialisation de cette unite. DosEntry traduit alors, dans le
  processus lui-meme, chaque service DOS en appels systeme UNIX-0 (open,
  read, write, getdents, fork/execve/waitpid, ...), comme le ferait une libc :
  le programme n'appelle jamais de service MS-DOS.
}

Unit Unix;

{$S-,R-,I-}

Interface

Const
 { Numeros des appels systeme (proches de Linux i386) }
 SYS_exit=1;      SYS_fork=2;      SYS_read=3;      SYS_write=4;
 SYS_open=5;      SYS_close=6;     SYS_waitpid=7;   SYS_creat=8;
 SYS_link=9;      SYS_unlink=10;   SYS_execve=11;   SYS_chdir=12;
 SYS_time=13;     SYS_chmod=15;    SYS_lseek=19;    SYS_getpid=20;
 SYS_mount=21;    SYS_umount=22;   SYS_getuid=24;   SYS_stime=25;
 SYS_pause=29;    SYS_sync=36;     SYS_kill=37;     SYS_rename=38;
 SYS_mkdir=39;    SYS_rmdir=40;    SYS_dup=41;      SYS_pipe=42;
 SYS_brk=45;      SYS_signal=48;   SYS_ioctl=54;    SYS_dup2=63;
 SYS_getppid=64;  SYS_reboot=88;   SYS_stat=106;    SYS_fstat=108;
 SYS_uname=122;   SYS_getdents=141; SYS_yield=158;  SYS_sleep=162;
 SYS_getcwd=183;  SYS_vfork=190;   SYS_procinfo=200; SYS_setdos=201;
 SYS_meminfo=202;
 SYS_mountinfo=203;

 { open }
 O_RDONLY=0; O_WRONLY=1; O_RDWR=2; O_CREAT=$40; O_EXCL=$80; O_TRUNC=$200;
 O_APPEND=$400;
 { lseek }
 SEEK_SET=0; SEEK_CUR=1; SEEK_END=2;
 { waitpid }
 WNOHANG=1;
 { signaux }
 SIGHUP=1; SIGINT=2; SIGQUIT=3; SIGILL=4; SIGKILL=9; SIGSEGV=11; SIGPIPE=13;
 SIGALRM=14; SIGTERM=15; SIGCHLD=17; SIGSYS=31;
 SIG_DFL=0; SIG_IGN=1;
 { ioctl de la console }
 TIOCISATTY=0; TIOCGETMODE=1; TIOCSETMODE=2; TIOCNREAD=3;
 TTY_RAW=1; TTY_NOECHO=2;
 { types de fichiers (st_mode) }
 S_IFMT=$F000; S_IFDIR=$4000; S_IFCHR=$2000; S_IFREG=$8000; S_IFIFO=$1000;
 { types de systemes de fichiers pour mount }
 FS_AUTO=0; FS_FAT=1; FS_UFS=2;
 { codes d'erreur (errno) }
 EPERM=1; ENOENT=2; ESRCH=3; EINTR=4; EIO=5; ENXIO=6; E2BIG=7; ENOEXEC=8;
 EBADF=9; ECHILD=10; EAGAIN=11; ENOMEM=12; EACCES=13; EFAULT=14; EBUSY=16;
 EEXIST=17; EXDEV=18; ENODEV=19; ENOTDIR=20; EISDIR=21; EINVAL=22;
 ENFILE=23; EMFILE=24; ENOTTY=25; EFBIG=27; ENOSPC=28; ESPIPE=29;
 EROFS=30; EPIPE=32; ENAMETOOLONG=36; ENOSYS=38; ENOTEMPTY=39;

Type
 TStat=Record
  Dev: Word;
  Ino: Longint;
  Mode: Word;
  NLink: Word;
  Uid: Word;
  Gid: Word;
  RDev: Word;
  Size: Longint;
  ATime: Longint;
  MTime: Longint;
  CTime: Longint;
 End;
 TProcInfo=Record
  Pid: Integer;
  PPid: Integer;
  Stat: Byte;     { 1=pret, 2=en attente, 3=zombie }
  Flags: Byte;
  Paras: Word;    { memoire en paragraphes }
  Ticks: Longint; { temps processeur en tops d'horloge (18,2 par seconde) }
  Name: String[15];
 End;
 TUtsName=Record
  SysName: String[15];
  NodeName: String[15];
  Release: String[15];
  Version: String[15];
  Machine: String[15];
 End;
 TMemInfo=Record
  TotalParas: Word;   { memoire geree par le noyau, en paragraphes }
  FreeParas: Word;
  KernelParas: Word;  { taille du noyau (code + donnees) }
  BufCount: Word;     { tampons du cache disque }
  ProcCount: Word;    { processus actifs }
  ProcMax: Word;
 End;
 TMountInfo=Record
  FsType: Byte;       { 1=FAT12, 2=FAT16, 3=UFS, 4=dev }
  Drive: Byte;
  ReadOnly: Byte;
  Pad: Byte;
  Start: Longint;     { premier secteur }
  Blocks: Longint;    { taille en Ko }
  Free: Longint;      { libre en Ko }
  Dir: String[31];
  Special: String[15];
 End;

Var
 Errno: Integer;
 { registres de l'appel systeme brut }
 SAX,SBX,SCX,SDX,SSI,SDI,SDS,SES,SFL: Word;

Procedure DoSys;
Function SysOk: Boolean;
Function SysExit(Status: Integer): Integer;
Function Fork: Integer;
Function VFork: Integer;
Function SysRead(Fd: Integer; Var Buf; Count: Word): Integer;
Function SysWrite(Fd: Integer; Var Buf; Count: Word): Integer;
Function SysOpen(Path: String; Flags, Mode: Word): Integer;
Function SysClose(Fd: Integer): Integer;
Function WaitPid(Pid: Integer; Var Status: Integer; Options: Word): Integer;
Function SysCreat(Path: String; Mode: Word): Integer;
Function SysLink(OldPath, NewPath: String): Integer;
Function SysUnlink(Path: String): Integer;
Function Execv(Path: String; Args: String): Integer;
Function Execve(Path: String; Var Block; BlockLen: Word): Integer;
Function SysChdir(Path: String): Integer;
Function SysTime: Longint;
Function SysChmod(Path: String; Mode: Word): Integer;
Function SysLSeek(Fd: Integer; Offset: Longint; Whence: Word): Longint;
Function GetPid: Integer;
Function GetPPid: Integer;
Function SysMount(Special, Dir: String; FsType: Word): Integer;
Function SysUmount(Dir: String): Integer;
Function SysSync: Integer;
Function SysKill(Pid, Sig: Integer): Integer;
Function SysRename(OldPath, NewPath: String): Integer;
Function SysMkdir(Path: String; Mode: Word): Integer;
Function SysRmdir(Path: String): Integer;
Function SysDup(Fd: Integer): Integer;
Function SysDup2(Fd, Fd2: Integer): Integer;
Function SysPipe(Var ReadFd, WriteFd: Integer): Integer;
Function SysSignal(Sig, Action: Integer): Integer;
Function SysIoctl(Fd, Request, Arg: Integer): Integer;
Function SysReboot: Integer;
Function SysStat(Path: String; Var St: TStat): Integer;
Function SysFStat(Fd: Integer; Var St: TStat): Integer;
Function SysUname(Var U: TUtsName): Integer;
Function SysGetDents(Fd: Integer; Var Buf; Count: Word): Integer;
Function SysYield: Integer;
Function SysSleep(Seconds: Word): Integer;
Function SysGetCwd: String;
Function SysProcInfo(Index: Integer; Var P: TProcInfo): Boolean;
Function SysMemInfo(Var M: TMemInfo): Integer;
Function SysMountInfo(Index: Integer; Var M: TMountInfo): Boolean;
Function SysErrorText(E: Integer): String;
Function UnixPath(S: String): String;

Implementation

Type
 PByte=^Byte;
 TBytes=Array[0..65519] Of Byte;
 PBytes=^TBytes;
 TFind=Record           { etat d'une recherche FindFirst/FindNext }
  Used: Boolean;
  Fd: Integer;
  Attr: Byte;
  Dir: String[79];
  Pattern: String[12];
  BufLen, BufPos: Integer;  { entrees getdents en attente }
  Buf: Array[0..255] Of Byte;
 End;

Var
 { registres de l'appel DOS en cours de traduction }
 RAX,RBX,RCX,RDX,RSI,RDI,RBP,RDS,RES,RFL: Word;
 DtaSeg,DtaOfs: Word;
 LastExit: Word;
 Finds: Array[0..7] Of TFind;
 FindNo: Byte;
 HeapFirst,HeapTop: Word;   { zone du tas (paragraphes) }
 PathBuf: Array[0..255] Of Char;
 PathBuf2: Array[0..255] Of Char;
 ArgBlock: Array[0..1023] Of Char;
 DirBuf: Array[0..1023] Of Byte;
 KbdAhead: Integer;

{ ------------------------------------------------------------------ }
{ Appels systeme                                                     }
{ ------------------------------------------------------------------ }

Procedure DoSys; Assembler;
Asm
 PUSH BP
 PUSH SI
 PUSH DI
 PUSH DS
 MOV BX,SBX
 MOV CX,SCX
 MOV DX,SDX
 MOV SI,SSI
 MOV DI,SDI
 MOV ES,SES
 MOV AX,SAX
 MOV BP,SDS
 MOV DS,BP
 INT 80h
 PUSHF
 PUSH DS
 PUSH AX
 MOV AX,SEG @DATA
 MOV DS,AX
 POP AX
 MOV SAX,AX
 POP AX
 MOV SDS,AX
 POP AX
 MOV SFL,AX
 MOV SBX,BX
 MOV SCX,CX
 MOV SDX,DX
 MOV SSI,SI
 MOV SDI,DI
 MOV SES,ES
 POP DS
 POP DI
 POP SI
 POP BP
End;

Function SysOk: Boolean;
Begin
 If SFL And 1<>0 Then Begin Errno:=SAX; SysOk:=False End
 Else Begin Errno:=0; SysOk:=True End;
End;

Procedure SetRegs(N,B,C,D: Word);
Begin
 SAX:=N; SBX:=B; SCX:=C; SDX:=D; SSI:=0; SDI:=0; SDS:=DSeg; SES:=DSeg;
End;

Function Result16: Integer;
Begin
 DoSys;
 If SysOk Then Result16:=SAX Else Result16:=-1;
End;

Procedure SetPath(S: String);
{ DS:DX = chemin ASCIIZ (PathBuf) }
Var I: Integer;
Begin
 For I:=1 To Length(S) Do PathBuf[I-1]:=S[I];
 PathBuf[Length(S)]:=#0;
 SDS:=Seg(PathBuf); SDX:=Ofs(PathBuf);
End;

Procedure SetPath2(S: String);
{ ES:DI = second chemin ASCIIZ (PathBuf2) }
Var I: Integer;
Begin
 For I:=1 To Length(S) Do PathBuf2[I-1]:=S[I];
 PathBuf2[Length(S)]:=#0;
 SES:=Seg(PathBuf2); SDI:=Ofs(PathBuf2);
End;

Function SysExit(Status: Integer): Integer;
Begin
 SetRegs(SYS_exit,Status,0,0); DoSys; SysExit:=-1;
End;

Function Fork: Integer;
Begin
 SetRegs(SYS_fork,0,0,0); Fork:=Result16;
End;

Function VFork: Integer;
{ comme Fork, mais le fils s'execute dans la memoire du pere (suspendu)
  jusqu'a son appel a Execv/Execve ou SysExit : sans copie de la memoire.
  Le fils ne doit rien faire d'autre que Execv/Execve puis SysExit. }
Begin
 SetRegs(SYS_vfork,0,0,0); VFork:=Result16;
End;

Function SysRead(Fd: Integer; Var Buf; Count: Word): Integer;
Begin
 SetRegs(SYS_read,Fd,Count,Ofs(Buf)); SDS:=Seg(Buf); SysRead:=Result16;
End;

Function SysWrite(Fd: Integer; Var Buf; Count: Word): Integer;
Begin
 SetRegs(SYS_write,Fd,Count,Ofs(Buf)); SDS:=Seg(Buf); SysWrite:=Result16;
End;

Function SysOpen(Path: String; Flags, Mode: Word): Integer;
Begin
 SetRegs(SYS_open,Flags,Mode,0); SetPath(Path); SysOpen:=Result16;
End;

Function SysClose(Fd: Integer): Integer;
Begin
 SetRegs(SYS_close,Fd,0,0); SysClose:=Result16;
End;

Function WaitPid(Pid: Integer; Var Status: Integer; Options: Word): Integer;
Begin
 SetRegs(SYS_waitpid,Pid,Options,0); DoSys;
 If SysOk Then Begin WaitPid:=SAX; Status:=SDX End Else WaitPid:=-1;
End;

Function SysCreat(Path: String; Mode: Word): Integer;
Begin
 SetRegs(SYS_creat,0,Mode,0); SetPath(Path); SysCreat:=Result16;
End;

Function SysLink(OldPath, NewPath: String): Integer;
Begin
 SetRegs(SYS_link,0,0,0); SetPath(OldPath); SetPath2(NewPath);
 SysLink:=Result16;
End;

Function SysUnlink(Path: String): Integer;
Begin
 SetRegs(SYS_unlink,0,0,0); SetPath(Path); SysUnlink:=Result16;
End;

Function Execve(Path: String; Var Block; BlockLen: Word): Integer;
{ Block : argv[0], argv[1], ... (chaines ASCIIZ), chaine vide, puis
  l'environnement (VAR=VALEUR ASCIIZ), chaine vide. }
Begin
 SetRegs(SYS_execve,0,BlockLen,0); SetPath(Path);
 SES:=Seg(Block); SDI:=Ofs(Block);
 Execve:=Result16;
End;

Function AddArg(Var Len: Word; S: String): Boolean;
Var I: Integer;
Begin
 AddArg:=False;
 If Len+Length(S)+1>SizeOf(ArgBlock)-2 Then Exit;
 For I:=1 To Length(S) Do ArgBlock[Len+I-1]:=S[I];
 Inc(Len,Length(S)); ArgBlock[Len]:=#0; Inc(Len);
 AddArg:=True;
End;

Function CopyEnv(Var Len: Word): Boolean;
{ Recopie l'environnement du processus (segment PSP:2Ch). }
Var E,O: Word; S: String;
Begin
 CopyEnv:=True;
 E:=MemW[PrefixSeg:$2C]; O:=0;
 If E=0 Then Exit;
 While Mem[E:O]<>0 Do Begin
  S:='';
  While (Mem[E:O]<>0) And (Length(S)<255) Do Begin
   S:=S+Chr(Mem[E:O]); Inc(O);
  End;
  While Mem[E:O]<>0 Do Inc(O);
  Inc(O);
  If Not AddArg(Len,S) Then Begin CopyEnv:=False; Exit End;
 End;
End;

Function BuildArgs(Path: String; Args: String; Var Len: Word): Boolean;
{ argv[0] = Path, puis les mots de Args separes par des espaces (les
  guillemets regroupent), puis l'environnement courant. }
Var I: Integer; W: String; Quote: Boolean;
Begin
 BuildArgs:=False; Len:=0;
 If Not AddArg(Len,Path) Then Exit;
 I:=1;
 While I<=Length(Args) Do Begin
  While (I<=Length(Args)) And (Args[I] In [' ',#9]) Do Inc(I);
  If I>Length(Args) Then Break;
  W:=''; Quote:=False;
  While (I<=Length(Args)) And (Quote Or Not (Args[I] In [' ',#9])) Do Begin
   If Args[I]='"' Then Quote:=Not Quote Else W:=W+Args[I];
   Inc(I);
  End;
  If Not AddArg(Len,W) Then Exit;
 End;
 If Not AddArg(Len,'') Then Exit;
 If Not CopyEnv(Len) Then Exit;
 If Not AddArg(Len,'') Then Exit;
 BuildArgs:=True;
End;

Function Execv(Path: String; Args: String): Integer;
Var Len: Word;
Begin
 If Not BuildArgs(Path,Args,Len) Then Begin Errno:=E2BIG; Execv:=-1; Exit End;
 Execv:=Execve(Path,ArgBlock,Len);
End;

Function SysChdir(Path: String): Integer;
Begin
 SetRegs(SYS_chdir,0,0,0); SetPath(Path); SysChdir:=Result16;
End;

Function SysTime: Longint;
Begin
 SetRegs(SYS_time,0,0,0); DoSys;
 SysTime:=Longint(SDX) Shl 16+SAX;
End;

Function SysChmod(Path: String; Mode: Word): Integer;
Begin
 SetRegs(SYS_chmod,0,Mode,0); SetPath(Path); SysChmod:=Result16;
End;

Function SysLSeek(Fd: Integer; Offset: Longint; Whence: Word): Longint;
Begin
 SetRegs(SYS_lseek,Fd,Word(Offset Shr 16),Word(Offset)); SSI:=Whence;
 DoSys;
 If SysOk Then SysLSeek:=Longint(SDX) Shl 16+SAX Else SysLSeek:=-1;
End;

Function GetPid: Integer;
Begin
 SetRegs(SYS_getpid,0,0,0); GetPid:=Result16;
End;

Function GetPPid: Integer;
Begin
 SetRegs(SYS_getppid,0,0,0); GetPPid:=Result16;
End;

Function SysMount(Special, Dir: String; FsType: Word): Integer;
Begin
 SetRegs(SYS_mount,FsType,0,0); SetPath(Special); SetPath2(Dir);
 SysMount:=Result16;
End;

Function SysUmount(Dir: String): Integer;
Begin
 SetRegs(SYS_umount,0,0,0); SetPath(Dir); SysUmount:=Result16;
End;

Function SysSync: Integer;
Begin
 SetRegs(SYS_sync,0,0,0); SysSync:=Result16;
End;

Function SysKill(Pid, Sig: Integer): Integer;
Begin
 SetRegs(SYS_kill,Pid,Sig,0); SysKill:=Result16;
End;

Function SysRename(OldPath, NewPath: String): Integer;
Begin
 SetRegs(SYS_rename,0,0,0); SetPath(OldPath); SetPath2(NewPath);
 SysRename:=Result16;
End;

Function SysMkdir(Path: String; Mode: Word): Integer;
Begin
 SetRegs(SYS_mkdir,0,Mode,0); SetPath(Path); SysMkdir:=Result16;
End;

Function SysRmdir(Path: String): Integer;
Begin
 SetRegs(SYS_rmdir,0,0,0); SetPath(Path); SysRmdir:=Result16;
End;

Function SysDup(Fd: Integer): Integer;
Begin
 SetRegs(SYS_dup,Fd,0,0); SysDup:=Result16;
End;

Function SysDup2(Fd, Fd2: Integer): Integer;
Begin
 SetRegs(SYS_dup2,Fd,Fd2,0); SysDup2:=Result16;
End;

Function SysPipe(Var ReadFd, WriteFd: Integer): Integer;
Begin
 SetRegs(SYS_pipe,0,0,0); DoSys;
 If SysOk Then Begin ReadFd:=SAX; WriteFd:=SDX; SysPipe:=0 End
 Else SysPipe:=-1;
End;

Function SysSignal(Sig, Action: Integer): Integer;
Begin
 SetRegs(SYS_signal,Sig,Action,0); SysSignal:=Result16;
End;

Function SysIoctl(Fd, Request, Arg: Integer): Integer;
Begin
 SetRegs(SYS_ioctl,Fd,Request,Arg); SysIoctl:=Result16;
End;

Function SysReboot: Integer;
Begin
 SetRegs(SYS_reboot,0,0,0); SysReboot:=Result16;
End;

Function SysStat(Path: String; Var St: TStat): Integer;
Begin
 SetRegs(SYS_stat,0,0,0); SetPath(Path); SES:=Seg(St); SDI:=Ofs(St);
 SysStat:=Result16;
End;

Function SysFStat(Fd: Integer; Var St: TStat): Integer;
Begin
 SetRegs(SYS_fstat,Fd,0,0); SES:=Seg(St); SDI:=Ofs(St);
 SysFStat:=Result16;
End;

Function SysUname(Var U: TUtsName): Integer;
Begin
 SetRegs(SYS_uname,0,0,Ofs(U)); SDS:=Seg(U); SysUname:=Result16;
End;

Function SysGetDents(Fd: Integer; Var Buf; Count: Word): Integer;
Begin
 SetRegs(SYS_getdents,Fd,Count,Ofs(Buf)); SDS:=Seg(Buf);
 SysGetDents:=Result16;
End;

Function SysYield: Integer;
Begin
 SetRegs(SYS_yield,0,0,0); SysYield:=Result16;
End;

Function SysSleep(Seconds: Word): Integer;
Begin
 SetRegs(SYS_sleep,Seconds,0,0); SysSleep:=Result16;
End;

Function SysGetCwd: String;
Var I: Integer; S: String;
Begin
 SetRegs(SYS_getcwd,0,255,Ofs(PathBuf)); SDS:=Seg(PathBuf);
 S:='';
 If Result16>=0 Then Begin
  I:=0;
  While (I<255) And (PathBuf[I]<>#0) Do Begin S:=S+PathBuf[I]; Inc(I) End;
 End;
 SysGetCwd:=S;
End;

Function SysProcInfo(Index: Integer; Var P: TProcInfo): Boolean;
Begin
 SetRegs(SYS_procinfo,Index,0,Ofs(P)); SDS:=Seg(P);
 SysProcInfo:=Result16>0;
End;

Function SysMemInfo(Var M: TMemInfo): Integer;
Begin
 SetRegs(SYS_meminfo,0,0,Ofs(M)); SDS:=Seg(M); SysMemInfo:=Result16;
End;

Function SysMountInfo(Index: Integer; Var M: TMountInfo): Boolean;
Begin
 SetRegs(SYS_mountinfo,Index,0,Ofs(M)); SDS:=Seg(M);
 SysMountInfo:=Result16>0;
End;

Function SysErrorText(E: Integer): String;
Var S: String;
Begin
 Case E Of
  EPERM: S:='Operation non permise';
  ENOENT: S:='Fichier ou repertoire inexistant';
  ESRCH: S:='Processus inexistant';
  EINTR: S:='Appel systeme interrompu';
  EIO: S:='Erreur d''entree/sortie';
  ENXIO: S:='Peripherique inexistant';
  E2BIG: S:='Liste d''arguments trop longue';
  ENOEXEC: S:='Format d''executable invalide';
  EBADF: S:='Descripteur de fichier invalide';
  ECHILD: S:='Aucun processus fils';
  EAGAIN: S:='Ressource temporairement indisponible';
  ENOMEM: S:='Memoire insuffisante';
  EACCES: S:='Permission refusee';
  EBUSY: S:='Peripherique ou ressource occupe';
  EEXIST: S:='Le fichier existe';
  EXDEV: S:='Lien entre peripheriques';
  ENODEV: S:='Peripherique inexistant';
  ENOTDIR: S:='N''est pas un repertoire';
  EISDIR: S:='Est un repertoire';
  EINVAL: S:='Argument invalide';
  ENFILE: S:='Table des fichiers pleine';
  EMFILE: S:='Trop de fichiers ouverts';
  ENOTTY: S:='N''est pas un terminal';
  EFBIG: S:='Fichier trop gros';
  ENOSPC: S:='Plus d''espace sur le peripherique';
  ESPIPE: S:='Deplacement illegal';
  EROFS: S:='Systeme de fichiers en lecture seule';
  EPIPE: S:='Tube brise';
  ENAMETOOLONG: S:='Nom trop long';
  ENOSYS: S:='Fonction non implementee';
  ENOTEMPTY: S:='Repertoire non vide';
  Else Begin Str(E,S); S:='Erreur '+S End;
 End;
 SysErrorText:=S;
End;

{ ------------------------------------------------------------------ }
{ Traduction des services DOS (INT 21h) en appels systeme UNIX-0     }
{ ------------------------------------------------------------------ }

Function UnixPath(S: String): String;
{ Chemin DOS -> chemin UNIX : unite "X:" retiree, "\" -> "/", noms de
  peripheriques DOS -> /dev. }
Var I: Integer; U: String;
Begin
 If (Length(S)>=2) And (S[2]=':') Then Delete(S,1,2);
 For I:=1 To Length(S) Do If S[I]='\' Then S[I]:='/';
 U:=S;
 For I:=1 To Length(U) Do U[I]:=UpCase(U[I]);
 If (U='NUL') Or (U='/DEV/NUL') Or (U='PRN') Or (U='LPT1') Or (U='AUX') Or
   (U='COM1') Then S:='/dev/null'
 Else If (U='CON') Or (U='/DEV/CON') Then S:='/dev/tty';
 If S='' Then S:='.';
 UnixPath:=S;
End;

Function FarString(Sg,Os: Word): String;
{ Chaine ASCIIZ Sg:Os -> chaine Pascal }
Var S: String;
Begin
 S:='';
 While (Mem[Sg:Os]<>0) And (Length(S)<255) Do Begin
  S:=S+Chr(Mem[Sg:Os]); Inc(Os);
 End;
 FarString:=S;
End;

Procedure SetCarry(Err: Word);
Begin
 RAX:=Err; RFL:=RFL Or 1;
End;

Function DosError(E: Integer): Word;
{ errno -> code d'erreur DOS }
Begin
 Case E Of
  ENOENT: DosError:=2;
  ENOTDIR: DosError:=3;
  EMFILE,ENFILE: DosError:=4;
  EACCES,EPERM,EISDIR,EEXIST,EROFS,ENOTEMPTY,EBUSY: DosError:=5;
  EBADF: DosError:=6;
  ENOMEM: DosError:=8;
  ENOEXEC: DosError:=11;
  ENOSPC: DosError:=29;
  EXDEV: DosError:=17;
  Else DosError:=31;
 End;
End;

Procedure Fail;
Begin
 SetCarry(DosError(Errno));
End;

Function FileExistsU(S: String): Boolean;
Var St: TStat;
Begin
 FileExistsU:=(SysStat(S,St)=0) And (St.Mode And S_IFMT<>S_IFDIR);
End;

Function ExecPath(S: String): String;
{ Programme DOS (X.EXE, X.COM) -> executable UNIX-0 (X) si besoin. }
Var U: String; I: Integer;
Begin
 ExecPath:=S;
 If FileExistsU(S) Then Exit;
 U:=S; For I:=1 To Length(U) Do U[I]:=UpCase(U[I]);
 If (Length(S)>4) And ((Copy(U,Length(U)-3,4)='.EXE') Or
   (Copy(U,Length(U)-3,4)='.COM')) Then Begin
  U:=Copy(S,1,Length(S)-4);
  If FileExistsU(U) Then Begin ExecPath:=U; Exit End;
  For I:=1 To Length(U) Do U[I]:=Chr(Ord(U[I]) Or (Ord(U[I] In ['A'..'Z'])*32));
  If FileExistsU(U) Then ExecPath:=U;
 End;
End;

Procedure DosExec;
{ 4B00h : DS:DX programme, ES:BX bloc de parametres -> fork, execve, waitpid }
Var Path,Tail: String; TSeg,TOfs: Word; L,I: Integer; Pid,St: Integer;
  Len: Word;
Begin
 Path:=ExecPath(UnixPath(FarString(RDS,RDX)));
 TOfs:=MemW[RES:RBX+2]; TSeg:=MemW[RES:RBX+4];
 L:=Mem[TSeg:TOfs]; Tail:='';
 For I:=1 To L Do If Mem[TSeg:TOfs+I]<>13 Then Tail:=Tail+Chr(Mem[TSeg:TOfs+I]);
 If Not FileExistsU(Path) Then Begin SetCarry(2); Exit End;
 If Not BuildArgs(Path,Tail,Len) Then Begin SetCarry(10); Exit End;
 Pid:=VFork;
 If Pid<0 Then Begin Fail; Exit End;
 If Pid=0 Then Begin
  Execve(Path,ArgBlock,Len);
  SysExit(127);
 End;
 If WaitPid(Pid,St,0)<0 Then Begin Fail; Exit End;
 { St : code de sortie dans l'octet bas, signal dans l'octet haut }
 If Hi(St)<>0 Then LastExit:=$100 Or Hi(St) Else LastExit:=Lo(St);
 RAX:=0;
End;

Function Lower(C: Char): Char;
Begin
 If C In ['A'..'Z'] Then Lower:=Chr(Ord(C)+32) Else Lower:=C;
End;

Function Match(Pat, Name: String): Boolean;
{ Correspondance DOS : * et ?, sans tenir compte de la casse; "*.*"
  correspond aussi aux noms sans point. }
Var P,N: Integer;
 Function M(P,N: Integer): Boolean;
 Begin
  While P<=Length(Pat) Do Begin
   If Pat[P]='*' Then Begin
    While (P<=Length(Pat)) And (Pat[P]='*') Do Inc(P);
    If P>Length(Pat) Then Begin M:=True; Exit End;
    While N<=Length(Name)+1 Do Begin
     If M(P,N) Then Begin M:=True; Exit End;
     Inc(N);
    End;
    M:=False; Exit;
   End;
   If N>Length(Name) Then Begin
    { "X.*" correspond a "X" }
    If (Pat[P]='.') And (P<Length(Pat)) And (Pat[P+1]='*') Then Begin
     Inc(P,2); Continue;
    End;
    M:=(Pat[P]='.') And (P=Length(Pat)); Exit;
   End;
   If (Pat[P]<>'?') And (Lower(Pat[P])<>Lower(Name[N])) Then Begin
    M:=False; Exit;
   End;
   Inc(P); Inc(N);
  End;
  M:=N>Length(Name);
 End;
Begin
 If (Pat='*.*') Or (Pat='*') Then Begin Match:=True; Exit End;
 P:=1; N:=1;
 Match:=M(P,N);
End;

Function DosTime(T: Longint): Longint;
{ secondes depuis 1970 -> date/heure DOS compactee }
Var Days,Secs: Longint; Y,M,D: Word; DM: Word;
Begin
 If T<315532800 Then T:=315532800;
 Days:=T Div 86400; Secs:=T Mod 86400;
 Y:=1970;
 While True Do Begin
  If (Y Mod 4=0) Then DM:=366 Else DM:=365;
  If Days<DM Then Break;
  Dec(Days,DM); Inc(Y);
 End;
 M:=1;
 While True Do Begin
  Case M Of
   1,3,5,7,8,10,12: DM:=31;
   4,6,9,11: DM:=30;
   Else If Y Mod 4=0 Then DM:=29 Else DM:=28;
  End;
  If Days<DM Then Break;
  Dec(Days,DM); Inc(M);
 End;
 D:=Days+1;
 DosTime:=(Longint(Y-1980) Shl 25) Or (Longint(M) Shl 21) Or
   (Longint(D) Shl 16) Or ((Secs Div 3600) Shl 11) Or
   (((Secs Mod 3600) Div 60) Shl 5) Or ((Secs Mod 60) Div 2);
End;

Procedure FindRead(K: Integer);
{ Entree suivante de la recherche K, placee dans la DTA }
Var
 N,Pos,RecLen,I: Integer;
 Name,Full: String;
 St: TStat;
 A: Byte;
 T: Longint;
Begin
 With Finds[K] Do
 While True Do Begin
  If BufPos>=BufLen Then Begin
   N:=SysGetDents(Fd,Buf,SizeOf(Buf));
   If N<=0 Then Begin
    SysClose(Fd); Used:=False; SetCarry(18); Exit;
   End;
   BufLen:=N; BufPos:=0;
  End;
  Pos:=BufPos;
  RecLen:=Buf[Pos+4]+Buf[Pos+5]*256;
  If RecLen<8 Then RecLen:=BufLen-Pos;
  Inc(BufPos,RecLen);
  Name:='';
  For I:=0 To Buf[Pos+7]-1 Do
   If Length(Name)<255 Then Name:=Name+Chr(Buf[Pos+8+I]);
  If Not Match(Pattern,Name) Then Continue;
  If Dir='' Then Full:=Name Else
  If Dir[Length(Dir)]='/' Then Full:=Dir+Name Else Full:=Dir+'/'+Name;
  If SysStat(Full,St)<>0 Then Continue;
  A:=$20;
  If St.Mode And S_IFMT=S_IFDIR Then A:=$10;
  If (Name[1]='.') And (Name<>'.') And (Name<>'..') Then A:=A Or 2;
  If (A And $10<>0) And (Attr And $10=0) Then Continue;
  If (A And 2<>0) And (Attr And 2=0) Then Continue;
  If St.Mode And $80=0 Then A:=A Or 1;
  { DTA : 21 octets reserves (0 = numero de recherche), attribut, heure,
    taille, nom ASCIIZ (13 octets) }
  Mem[DtaSeg:DtaOfs]:=K; Mem[DtaSeg:DtaOfs+1]:=$55;
  Mem[DtaSeg:DtaOfs+21]:=A;
  T:=DosTime(St.MTime);
  MemW[DtaSeg:DtaOfs+22]:=Word(T); MemW[DtaSeg:DtaOfs+24]:=Word(T Shr 16);
  MemW[DtaSeg:DtaOfs+26]:=Word(St.Size); MemW[DtaSeg:DtaOfs+28]:=Word(St.Size Shr 16);
  If Length(Name)>12 Then Name[0]:=#12;
  For I:=1 To Length(Name) Do Mem[DtaSeg:DtaOfs+29+I]:=Ord(Name[I]);
  Mem[DtaSeg:DtaOfs+30+Length(Name)]:=0;
  RAX:=0;
  Exit;
 End;
End;

Procedure DosFindFirst;
Var S,D,P: String; I,K: Integer;
Begin
 S:=UnixPath(FarString(RDS,RDX));
 I:=Length(S);
 While (I>0) And (S[I]<>'/') Do Dec(I);
 If I=0 Then Begin D:=''; P:=S End
 Else Begin D:=Copy(S,1,I); P:=Copy(S,I+1,255); If D<>'/' Then Dec(D[0]) End;
 If P='' Then P:='*';
 { sans joker : recherche d'un nom precis }
 K:=FindNo; FindNo:=(FindNo+1) And 7;
 If Finds[K].Used Then SysClose(Finds[K].Fd);
 Finds[K].Used:=False;
 If D='' Then Finds[K].Fd:=SysOpen('.',O_RDONLY,0)
 Else Finds[K].Fd:=SysOpen(D,O_RDONLY,0);
 If Finds[K].Fd<0 Then Begin SetCarry(3); Exit End;
 Finds[K].Used:=True; Finds[K].Attr:=Lo(RCX); Finds[K].Dir:=D;
 Finds[K].BufLen:=0; Finds[K].BufPos:=0;
 Finds[K].Pattern:=P;
 FindRead(K);
 If (RFL And 1<>0) Then RAX:=2;
End;

Procedure DosFindNext;
Var K: Integer;
Begin
 K:=Mem[DtaSeg:DtaOfs];
 If (K>7) Or (Mem[DtaSeg:DtaOfs+1]<>$55) Or Not Finds[K].Used Then Begin
  SetCarry(18); Exit;
 End;
 FindRead(K);
End;

{ Gestion du tas : blocs de paragraphes, en-tete d'un paragraphe
  (octet 0 : 'M' utilise / 'Z' libre, mots 1 : taille en paragraphes
  donnees comprises, 3 : signature 'U0') }
Procedure HeapInit;
Begin
 HeapFirst:=MemW[PrefixSeg:$48];
 HeapTop:=MemW[PrefixSeg:2];
 If (HeapFirst=0) Or (HeapFirst>=HeapTop) Then Begin
  HeapFirst:=0; Exit;
 End;
 Mem[HeapFirst:0]:=Ord('Z'); MemW[HeapFirst:1]:=HeapTop-HeapFirst;
 MemW[HeapFirst:3]:=$3055;
End;

Procedure HeapMerge;
Var S,N: Word;
Begin
 S:=HeapFirst;
 While (S<>0) And (S<HeapTop) Do Begin
  N:=S+MemW[S:1];
  If (Mem[S:0]=Ord('Z')) And (N<HeapTop) And (Mem[N:0]=Ord('Z')) Then
   MemW[S:1]:=MemW[S:1]+MemW[N:1]
  Else S:=N;
 End;
End;

Procedure DosAlloc;
{ 48h : BX paragraphes -> AX segment; BX = plus grand bloc si echec }
Var S,Best,Need,Sz: Word;
Begin
 If HeapFirst=0 Then Begin RBX:=0; SetCarry(8); Exit End;
 HeapMerge;
 Need:=RBX+1; If RBX=$FFFF Then Need:=$FFFF;
 S:=HeapFirst; Best:=0;
 While S<HeapTop Do Begin
  Sz:=MemW[S:1];
  If Mem[S:0]=Ord('Z') Then Begin
   If (Sz>=Need) And (Need<>$FFFF) Then Begin
    If Sz>Need+1 Then Begin
     Mem[S+Need:0]:=Ord('Z'); MemW[S+Need:1]:=Sz-Need;
     MemW[S+Need:3]:=$3055;
     MemW[S:1]:=Need;
    End;
    Mem[S:0]:=Ord('M'); MemW[S:3]:=$3055;
    RAX:=S+1; Exit;
   End;
   If Sz-1>Best Then Best:=Sz-1;
  End;
  S:=S+Sz;
 End;
 RBX:=Best; SetCarry(8);
End;

Procedure DosFree;
{ 49h : ES = segment du bloc }
Var S: Word;
Begin
 S:=RES-1;
 If (HeapFirst=0) Or (S<HeapFirst) Or (S>=HeapTop) Or (MemW[S:3]<>$3055) Then
 Begin
  SetCarry(9); Exit;
 End;
 Mem[S:0]:=Ord('Z'); HeapMerge;
End;

Procedure DosResize;
{ 4Ah : ES = segment, BX = nouvelle taille }
Var S,Sz,Need,N: Word;
Begin
 If RES=PrefixSeg Then Exit; { bloc du programme : accepte sans effet }
 S:=RES-1;
 If (HeapFirst=0) Or (S<HeapFirst) Or (S>=HeapTop) Or (MemW[S:3]<>$3055) Then
 Begin
  SetCarry(9); Exit;
 End;
 HeapMerge;
 Sz:=MemW[S:1]; Need:=RBX+1;
 If Need<=Sz Then Begin
  If Sz>Need+1 Then Begin
   Mem[S+Need:0]:=Ord('Z'); MemW[S+Need:1]:=Sz-Need; MemW[S+Need:3]:=$3055;
   MemW[S:1]:=Need; HeapMerge;
  End;
  Exit;
 End;
 N:=S+Sz;
 If (N<HeapTop) And (Mem[N:0]=Ord('Z')) And (Sz+MemW[N:1]>=Need) Then Begin
  MemW[S:1]:=Sz+MemW[N:1];
  If MemW[S:1]>Need+1 Then Begin
   Mem[S+Need:0]:=Ord('Z'); MemW[S+Need:1]:=MemW[S:1]-Need;
   MemW[S+Need:3]:=$3055; MemW[S:1]:=Need;
  End;
  Exit;
 End;
 RBX:=Sz-1; If N<HeapTop Then If Mem[N:0]=Ord('Z') Then Inc(RBX,MemW[N:1]);
 SetCarry(8);
End;

Function ReadKey(Echo: Boolean): Byte;
{ un caractere de l'entree standard, mode brut }
Var M: Integer; B: Byte; N: Integer;
Begin
 If KbdAhead>=0 Then Begin ReadKey:=KbdAhead; KbdAhead:=-1; Exit End;
 M:=SysIoctl(0,TIOCGETMODE,0);
 If M>=0 Then SysIoctl(0,TIOCSETMODE,TTY_RAW Or TTY_NOECHO);
 N:=SysRead(0,B,1);
 If M>=0 Then SysIoctl(0,TIOCSETMODE,M);
 If N<=0 Then B:=26;
 If Echo And (B>=32) Then SysWrite(1,B,1);
 ReadKey:=B;
End;

Function KeyReady: Boolean;
Var N: Integer;
Begin
 If KbdAhead>=0 Then Begin KeyReady:=True; Exit End;
 N:=SysIoctl(0,TIOCNREAD,0);
 KeyReady:=N>0;
End;

Procedure DateOf(Var Y,M,D,W,H,Mi,S: Word);
Var T,Days: Longint; DM: Word;
Begin
 T:=SysTime;
 Days:=T Div 86400; W:=(Days+4) Mod 7;
 H:=(T Mod 86400) Div 3600; Mi:=(T Mod 3600) Div 60; S:=T Mod 60;
 Y:=1970;
 While True Do Begin
  If Y Mod 4=0 Then DM:=366 Else DM:=365;
  If Days<DM Then Break;
  Dec(Days,DM); Inc(Y);
 End;
 M:=1;
 While True Do Begin
  Case M Of
   1,3,5,7,8,10,12: DM:=31;
   4,6,9,11: DM:=30;
   Else If Y Mod 4=0 Then DM:=29 Else DM:=28;
  End;
  If Days<DM Then Break;
  Dec(Days,DM); Inc(M);
 End;
 D:=Days+1;
End;

Procedure DosDiskFree;
{ 36h : unite 0 (par defaut) ou 3 (C:) = systeme de fichiers du repertoire
  courant (racine sinon); grappes de 1 Ko }
Var M: TMountInfo; I,Best,L: Integer; Cwd: String; T,F: Longint;
Begin
 If Not (Lo(RDX) In [0,3]) Then Begin RAX:=$FFFF; Exit End;
 Cwd:=SysGetCwd; Best:=0; L:=-1;
 For I:=1 To 8 Do
  If SysMountInfo(I,M) Then
   If (M.Dir='/') Or (Copy(Cwd,1,Length(M.Dir))=M.Dir) Then
    If Length(M.Dir)>L Then Begin Best:=I; L:=Length(M.Dir) End;
 If (Best=0) Or Not SysMountInfo(Best,M) Then Begin RAX:=$FFFF; Exit End;
 T:=M.Blocks; F:=M.Free;
 If T>65535 Then Begin T:=65535 End;
 If F>T Then F:=T;
 RAX:=2; RCX:=512; RBX:=F; RDX:=T;
End;

Procedure DosService;
{ Traduit le service DOS dont les registres sont dans RAX..RFL }
Var
 AH,AL: Byte;
 Fd,N,I,Flags: Integer;
 S,T: String;
 St: TStat;
 L: Longint;
 B: Byte;
 Y,M,D,W,H,Mi,Se: Word;
Begin
 AH:=Hi(RAX); AL:=Lo(RAX); RFL:=RFL And Not 1;
 Case AH Of
  $00: SysExit(0);
  $01: Begin RAX:=(RAX And $FF00) Or ReadKey(True) End;
  $02: Begin B:=Lo(RDX); If B=10 Then Begin B:=10; SysWrite(1,B,1) End
       Else If B<>13 Then SysWrite(1,B,1) End;
  $06: If Lo(RDX)=$FF Then Begin
        If KeyReady Then Begin
         RAX:=(RAX And $FF00) Or ReadKey(False); RFL:=RFL And Not $40;
        End Else Begin RAX:=RAX And $FF00; RFL:=RFL Or $40 End;
       End Else Begin B:=Lo(RDX); If B<>13 Then SysWrite(1,B,1) End;
  $07,$08: RAX:=(RAX And $FF00) Or ReadKey(False);
  $09: Begin
        N:=0;
        While (N<4096) And (Mem[RDS:RDX+N]<>Ord('$')) Do Inc(N);
        For I:=0 To N-1 Do Begin
         B:=Mem[RDS:RDX+I];
         If B<>13 Then SysWrite(1,B,1);
        End;
       End;
  $0A: Begin
        { lecture d'une ligne : DS:DX tampon (taille, lus, caracteres) }
        N:=SysRead(0,DirBuf,Mem[RDS:RDX]);
        If N<0 Then N:=0;
        I:=0;
        While (I<N) And (DirBuf[I]<>10) And (DirBuf[I]<>13) Do Begin
         Mem[RDS:RDX+2+I]:=DirBuf[I]; Inc(I);
        End;
        Mem[RDS:RDX+1]:=I; Mem[RDS:RDX+2+I]:=13;
       End;
  $0B: If KeyReady Then RAX:=(RAX And $FF00) Or $FF Else RAX:=RAX And $FF00;
  $0C: Begin
        While KeyReady Do ReadKey(False);
        If AL In [1,6,7,8,$A] Then Begin RAX:=(RAX And $FF) Or (AL Shl 8);
          DosService; End;
       End;
  $0D: SysSync;
  $0E: RAX:=(RAX And $FF00) Or 26;
  $19: RAX:=(RAX And $FF00) Or 2;
  $1A: Begin DtaSeg:=RDS; DtaOfs:=RDX End;
  $2F: Begin RES:=DtaSeg; RBX:=DtaOfs End;
  $25: ; { vecteurs geres par le noyau : sans effet }
  $35: Begin RBX:=MemW[0:AL*4]; RES:=MemW[0:AL*4+2] End;
  $2A: Begin DateOf(Y,M,D,W,H,Mi,Se); RCX:=Y; RDX:=M*256+D;
         RAX:=(RAX And $FF00) Or W End;
  $2C: Begin DateOf(Y,M,D,W,H,Mi,Se); RCX:=H*256+Mi; RDX:=Se*256 End;
  $2B,$2D: RAX:=RAX And $FF00;
  $2E,$54: RAX:=RAX And $FF00;
  $30: Begin RAX:=$0005; RBX:=$FF00; RCX:=0 End; { version 5.0 }
  $33: RDX:=RDX And $FF00;
  $36: DosDiskFree;
  $39: If SysMkdir(UnixPath(FarString(RDS,RDX)),$1ED)<0 Then Fail;
  $3A: If SysRmdir(UnixPath(FarString(RDS,RDX)))<0 Then Fail;
  $3B: If SysChdir(UnixPath(FarString(RDS,RDX)))<0 Then SetCarry(3);
  $3C,$5B: Begin
        Flags:=O_RDWR Or O_CREAT Or O_TRUNC;
        If AH=$5B Then Flags:=O_RDWR Or O_CREAT Or O_EXCL;
        Fd:=SysOpen(UnixPath(FarString(RDS,RDX)),Flags,$1A4);
        If Fd<0 Then Fail Else RAX:=Fd;
       End;
  $3D: Begin
        Fd:=SysOpen(UnixPath(FarString(RDS,RDX)),AL And 3,0);
        If Fd<0 Then Fail Else RAX:=Fd;
       End;
  $3E: If SysClose(RBX)<0 Then SetCarry(6);
  $3F: Begin
        N:=SysRead(RBX,Mem[RDS:RDX],RCX);
        If N<0 Then Fail Else RAX:=N;
       End;
  $40: Begin
        If RCX=0 Then Begin
         { ecriture de 0 octet : troncature a la position courante }
         RAX:=0;
        End Else Begin
         N:=SysWrite(RBX,Mem[RDS:RDX],RCX);
         If N<0 Then Fail Else RAX:=N;
        End;
       End;
  $41: If SysUnlink(UnixPath(FarString(RDS,RDX)))<0 Then Fail;
  $42: Begin
        L:=SysLSeek(RBX,Longint(RCX) Shl 16+RDX,AL);
        If L<0 Then Fail Else Begin RAX:=Word(L); RDX:=Word(L Shr 16) End;
       End;
  $43: Begin
        S:=UnixPath(FarString(RDS,RDX));
        If SysStat(S,St)<0 Then Fail
        Else If AL=0 Then Begin
         RCX:=$20;
         If St.Mode And S_IFMT=S_IFDIR Then RCX:=$10;
         If St.Mode And $80=0 Then RCX:=RCX Or 1;
         RAX:=RCX;
        End Else Begin
         If RCX And 1<>0 Then SysChmod(S,St.Mode And $16D)
         Else SysChmod(S,St.Mode Or $80);
        End;
       End;
  $44: Case AL Of
        0: Begin
            N:=SysIoctl(RBX,TIOCISATTY,0);
            If N>0 Then RDX:=$80D3 Else If SysFStat(RBX,St)<0 Then Fail
            Else RDX:=0;
            RAX:=RDX;
           End;
        1: ;
        6: Begin
            If SysIoctl(RBX,TIOCISATTY,0)>0 Then Begin
             If KeyReady Then RAX:=$FF Else RAX:=0;
            End Else RAX:=$FF;
           End;
        7: RAX:=$FF;
        8: RAX:=1;
        Else SetCarry(1);
       End;
  $45: Begin N:=SysDup(RBX); If N<0 Then Fail Else RAX:=N End;
  $46: If SysDup2(RBX,RCX)<0 Then Fail;
  $47: Begin
        S:=SysGetCwd;
        If (S<>'') And (S[1]='/') Then Delete(S,1,1);
        For I:=1 To Length(S) Do Mem[RDS:RSI+I-1]:=Ord(S[I]);
        Mem[RDS:RSI+Length(S)]:=0;
       End;
  $48: DosAlloc;
  $49: DosFree;
  $4A: DosResize;
  $4B: If AL=0 Then DosExec Else SetCarry(1);
  $4C: SysExit(AL);
  $4D: Begin RAX:=LastExit; LastExit:=0 End;
  $4E: DosFindFirst;
  $4F: DosFindNext;
  $50: ;
  $51,$62: RBX:=PrefixSeg;
  $56: If SysRename(UnixPath(FarString(RDS,RDX)),
          UnixPath(FarString(RES,RDI)))<0 Then Fail;
  $57: Begin
        If AL=0 Then Begin
         If SysFStat(RBX,St)<0 Then Fail Else Begin
          L:=DosTime(St.MTime); RCX:=Word(L); RDX:=Word(L Shr 16);
         End;
        End;
       End;
  $59: Begin RAX:=0; RBX:=0; RCX:=0 End;
  $5A: Begin
        { fichier temporaire : DS:DX repertoire termine par \ }
        S:=UnixPath(FarString(RDS,RDX));
        If (S<>'') And (S[Length(S)]<>'/') Then S:=S+'/';
        I:=0;
        Repeat
         Str(GetPid*100+I,T); T:=S+'TMP'+T+'.$$$'; Inc(I);
         Fd:=SysOpen(T,O_RDWR Or O_CREAT Or O_EXCL,$1A4);
        Until (Fd>=0) Or (I>99);
        If Fd<0 Then Fail Else Begin
         RAX:=Fd;
         T:=Copy(T,Length(S)+1,255);
         N:=0; While Mem[RDS:RDX+N]<>0 Do Inc(N);
         For I:=1 To Length(T) Do Mem[RDS:RDX+N+I-1]:=Ord(T[I]);
         Mem[RDS:RDX+N+Length(T)]:=0;
        End;
       End;
  $63,$65,$66,$38: SetCarry(1);
  Else SetCarry(1);
 End;
End;

Procedure DosEntry; Assembler;
{ Point d'entree INT 21h du processus : FLAGS, CS, IP sur la pile. }
Asm
 PUSH DS
 PUSH AX
 MOV AX,SEG @DATA
 MOV DS,AX
 POP AX
 MOV RAX,AX
 POP AX
 MOV RDS,AX
 MOV RBX,BX
 MOV RCX,CX
 MOV RDX,DX
 MOV RSI,SI
 MOV RDI,DI
 MOV RBP,BP
 MOV RES,ES
 MOV BP,SP
 MOV AX,[BP+4]
 MOV RFL,AX
 STI
 CLD
 CALL DosService
 MOV AX,SEG @DATA
 MOV DS,AX
 MOV BP,SP
 MOV AX,[BP+4]
 AND AX,0FFBEh
 MOV BX,RFL
 AND BX,41h
 OR AX,BX
 MOV [BP+4],AX
 MOV BX,RBX
 MOV CX,RCX
 MOV DX,RDX
 MOV SI,RSI
 MOV DI,RDI
 MOV ES,RES
 MOV BP,RBP
 MOV AX,RDS
 PUSH AX
 MOV AX,RAX
 POP DS
 IRET
End;

Procedure Int20Entry; Assembler;
Asm
 MOV AX,SEG @DATA
 MOV DS,AX
 MOV SAX,SYS_exit
 MOV SBX,0
 CALL DoSys
End;

Begin
 KbdAhead:=-1; FindNo:=0; LastExit:=0;
 DtaSeg:=PrefixSeg; DtaOfs:=$80;
 HeapInit;
 { enregistre la couche libc aupres du noyau (vecteur 21h du processus) }
 SetRegs(SYS_setdos,Ofs(DosEntry),Seg(DosEntry),0);
 DoSys;
End.
