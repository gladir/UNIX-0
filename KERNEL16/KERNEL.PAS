{ @author: Sylvain Maltais (support@gladir.com)
  @created: 2026
  @website(https://www.gladir.com/unix-0)
  @abstract(Target: Unix Pascal (UPC /K))
  @description: Noyau UNIX-0 16 bits (IBM PC, 8086/8088, mode reel).

  Compilation (un seul fichier, une seule image) :
    UPC /K KERNEL.PAS      -> KERNEL.SYS, copie sous le nom UNIX a la racine
                              du disque d'amorce (voir KERNEL16/BUILD.SH).

  Le noyau est monolithique et ecrit dans un seul fichier source, decoupe en
  segments-unites (SegmentUnit) de Unix Pascal : chaque segment-unite a sa
  propre portee et son propre segment de code, ce qui permet de depasser la
  limite de 64 Ko de code d'un segment 8086. Les donnees du noyau occupent un
  segment de 64 Ko (DS).

  Organisation inspiree de UNIX V6 (Lions) et de xv6 (MIT 6.828) :
   - table des processus (Procs), pile noyau par processus, swtch (KSwitch),
     sleep/wakeup sur des canaux, ordonnanceur a tourniquet preemptif
     (interruption 08h de l'horloge, quantum de 3 tops);
   - appels systeme par INT 80h (numeros proches de Linux i386);
   - memoire : table des zones libres (coremap) en paragraphes; fork par
     echange de memoire (les images 8086 contiennent des segments absolus :
     le fils partage l'adresse du pere et les images sont permutees a chaque
     commutation, comme le swapping de UNIX V1), exec charge un executable MZ
     dans une nouvelle zone;
   - systemes de fichiers : FAT12, FAT16 et UFS1 (FreeBSD), /dev, tubes;
     montage par chemin (table des montages), cache de secteurs;
   - console : ecran et clavier du BIOS, recopie sur COM1, discipline de
     ligne canonique (effacement, ^U, ^C = SIGINT, ^D = fin de fichier).

  Carte memoire :
   00000-003FF vecteurs d'interruption  00400-004FF donnees du BIOS
   00500-07BFF pile du processus 0 (amorce)   07C00 secteur d'amorce
   08000-0FFFF cache disque (64 tampons de 512 octets)
   10000-...   noyau (code, puis donnees DS de 64 Ko)
   ...-A0000   memoire des processus et piles noyau (coremap)
}

Program Kernel;

{$S-,R-,I-,Q-,B-}

{ ====================================================================== }
SegmentUnit KTypes;
{ Constantes, types et tables partagees par tout le noyau. }
SegmentInterface

Const
 KVersion='0.1';
 NPROC=16;          { processus }
 NOFILE=20;         { descripteurs par processus }
 NFILE=64;          { table des fichiers ouverts }
 NVNODE=64;         { table des noeuds (vnodes) }
 NMOUNT=8;          { systemes de fichiers montes }
 NBUF=64;           { tampons du cache disque }
 NPIPE=4;           { tubes }
 PIPESIZE=512;
 NDISK=8;           { peripheriques disques connus }
 BUFBASE=$0800;      { segment du cache disque (08000h-0FFFFh) }
 KSTKPARAS=192;     { pile noyau : 3 Ko par processus }
 KSTKTOP=KSTKPARAS*16;
 QUANTUM=3;         { tops d'horloge par tranche de temps }
 DEFHEAP=1024;      { tas par defaut d'un programme (paragraphes, 16 Ko) }

 { etats des processus }
 PFREE=0; PRUN=1; PSLEEP=2; PZOMB=3;

 { types de vnode }
 VNON=0; VREG=1; VDIR=2; VCHR=3; VFIFO=4;

 { systemes de fichiers }
 FSNONE=0; FSFAT12=1; FSFAT16=2; FSUFS=3; FSDEV=4;

 { peripheriques de /dev (Minor) }
 DEVTTY=1; DEVNULL=2; DEVZERO=3; DEVDISK=16;   { DEVDISK+n = Disks[n] }

 { canaux de sommeil }
 CHTTY=1; CHPIPE=16; CHWAIT=32; CHPAUSE=64; CHSLEEP=96; CHVFORK=128;

 { modes }
 S_IFMT=$F000; S_IFDIR=$4000; S_IFCHR=$2000; S_IFREG=$8000; S_IFIFO=$1000;

 { open }
 O_RDONLY=0; O_WRONLY=1; O_RDWR=2; O_ACCMODE=3; O_CREAT=$40; O_EXCL=$80;
 O_TRUNC=$200; O_APPEND=$400;

 { signaux }
 SIGHUP=1; SIGINT=2; SIGQUIT=3; SIGILL=4; SIGFPE=8; SIGKILL=9; SIGSEGV=11;
 SIGPIPE=13; SIGALRM=14; SIGTERM=15; SIGCHLD=17; SIGSYS=31;

 { codes d'erreur }
 EPERM=1; ENOENT=2; ESRCH=3; EINTR=4; EIO=5; ENXIO=6; E2BIG=7; ENOEXEC=8;
 EBADF=9; ECHILD=10; EAGAIN=11; ENOMEM=12; EACCES=13; EFAULT=14; EBUSY=16;
 EEXIST=17; EXDEV=18; ENODEV=19; ENOTDIR=20; EISDIR=21; EINVAL=22;
 ENFILE=23; EMFILE=24; ENOTTY=25; EFBIG=27; ENOSPC=28; ESPIPE=29;
 EROFS=30; EPIPE=32; ERANGE=34; ENAMETOOLONG=36; ENOSYS=38; ENOTEMPTY=39;

Type
 TPath=String[127];
 TName=String[63];

 TProc=Record
  Stat: Byte;          { PFREE, PRUN, PSLEEP, PZOMB }
  Intr: Boolean;       { sommeil interruptible par un signal }
  Pid, PPid: Integer;
  Chan: Word;          { canal de sommeil }
  Wake: Longint;       { reveil a ce top d'horloge (0 = aucun) }
  KSP, KSS: Word;      { contexte noyau sauve par KSwitch }
  KStack: Word;        { segment de la pile noyau }
  USP, USS: Word;      { trame utilisateur (registres sur la pile) }
  Home: Word;          { segment ou l'image doit s'executer }
  Where: Word;         { segment ou se trouve l'image }
  Size: Word;          { taille en paragraphes }
  PSP: Word;           { prefixe du programme }
  DosOfs, DosSeg: Word;{ point d'entree libc pour INT 21h }
  Status: Word;        { code de sortie (octet bas) et signal (octet haut) }
  SigPend, SigIgn: Word;
  Borrowed: Boolean;   { vfork : la memoire est celle du pere }
  Ticks: Longint;
  Fd: Array[0..NOFILE-1] Of Byte;  { 0 = libre, sinon index fichier }
  Cwd: TPath;
  Name: String[15];
 End;

 TVNode=Record
  Ref: Byte;
  Typ: Byte;           { VREG, VDIR, VCHR, VFIFO }
  Mnt: Byte;           { index du montage }
  Dirty: Boolean;
  Ino: Longint;        { UFS : inode; FAT : DirLBA*16+entree (racine 0) }
  Size: Longint;
  Mode: Word;
  NLink: Word;
  MTime: Longint;
  First: Longint;      { FAT : premier cluster }
  DirLBA: Longint;     { FAT : secteur de l'entree de repertoire }
  DirIdx: Word;        { FAT : entree dans le secteur }
  Minor: Word;         { peripherique ou numero de tube }
  CIdx, CClus: Longint;{ FAT : dernier cluster parcouru (index, numero) }
 End;

 TFile=Record
  Ref: Byte;
  Vn: Byte;
  Flags: Word;
  Off: Longint;
 End;

 TMount=Record
  Used: Boolean;
  Typ: Byte;
  Drive: Byte;         { index dans Disks }
  RO: Boolean;
  Start: Longint;      { premier secteur absolu }
  Sectors: Longint;
  Dir: String[31];
  Special: String[15];
  RootVn: Byte;
  { FAT }
  SecPerClus: Word;
  NFats: Word;
  RootEnt: Word;
  SecPerFat: Longint;
  FatLBA, RootLBA, DataLBA, Clusters, FreeHint: Longint;
  { UFS1 }
  FSize, BSize, Frag, Ipg, Fpg, Ncg, Iblkno, Cblkno, Dblkno: Longint;
  Inopb, Nindir, CsAddr, CgSize: Longint;
  FsbToDb: Word;
  CgOffset, CgMask: Longint;
 End;

 TDisk=Record
  Bios: Byte;          { unite BIOS }
  Present: Boolean;
  Spt, Heads: Word;
  Cyls: Word;
  Start, Sectors: Longint; { partition (0 = disque entier) }
  PartType: Byte;
  Name: String[7];
 End;

Var
 Procs: Array[0..NPROC-1] Of TProc;
 VNodes: Array[1..NVNODE] Of TVNode;
 Files: Array[1..NFILE] Of TFile;
 Mounts: Array[1..NMOUNT] Of TMount;
 Disks: Array[0..NDISK-1] Of TDisk;
 DiskCount: Integer;
 Cur: Integer;                  { processus courant }
 CurUSS, CurUSP, CurKStack: Word;
 InKernel: Byte;
 Ticks: Longint;                { tops d'horloge depuis l'amorce }
 BootTime: Longint;             { secondes depuis 1970 a l'amorce }
 KDataSeg: Word;
 MemTop: Word;                  { fin de la memoire conventionnelle }
 KernelEnd: Word;               { premier paragraphe libre apres le noyau }
 BootDrive: Byte;
 BootStart: Longint;
 SysHook, PreemptHook, FaultHook: Pointer;
 ZeroBuf: Array[0..511] Of Byte;

SegmentImplementation
SegmentEnd;

{ ====================================================================== }
SegmentUnit KLib;
{ Console du noyau (BIOS + COM1), chaines, copie de memoire, panique. }
Uses KTypes;
SegmentInterface

Var
 SerialPort: Word;              { 0 = pas de port serie }
 ConPage: Byte;

Procedure SerialInit;
Procedure ConPutC(C: Char);
Procedure KPrint(S: String);
Procedure KPrintLn(S: String);
Function IntStr(L: Longint): String;
Function HexStr(W: Word): String;
Procedure Panic(S: String);
Procedure FarMove(SS_, SO, DS_, DO_, N: Word);
Procedure FarFill(DS_, DO_, N: Word; B: Byte);
Procedure ParaCopy(Src, Dst, Paras: Word);
Procedure ParaXchg(A, B, Paras: Word);
Procedure ParaZero(Dst, Paras: Word);
Function FarStr(Sg, Os: Word; Max: Integer): String;
Procedure PutFarStr(Sg, Os: Word; S: String);
Function UpStr(S: String): String;
Function LowStr(S: String): String;
Function KTime: Longint;
Function ReadRTC: Longint;
Procedure CliHlt;

SegmentImplementation

Procedure SerialInit;
Begin
 SerialPort:=MemW[$40:0];
 If SerialPort<>0 Then Begin
  Port[SerialPort+1]:=0;        { pas d'interruptions }
  Port[SerialPort+3]:=$80;      { DLAB }
  Port[SerialPort]:=12;         { 9600 bauds }
  Port[SerialPort+1]:=0;
  Port[SerialPort+3]:=3;        { 8N1 }
  Port[SerialPort+2]:=$C7;      { FIFO }
  Port[SerialPort+4]:=3;
 End;
End;

Procedure ConPutC(C: Char);
Var B: Byte; N: Word;
Begin
 B:=Ord(C);
 Asm
  MOV AL,B
  MOV AH,0Eh
  MOV BH,ConPage
  MOV BL,7
  PUSH BP
  INT 10h
  POP BP
 End;
 If SerialPort<>0 Then Begin
  N:=0;
  While (Port[SerialPort+5] And $20=0) And (N<10000) Do Inc(N);
  Port[SerialPort]:=B;
 End;
End;

Procedure KPrint(S: String);
Var I: Integer;
Begin
 For I:=1 To Length(S) Do Begin
  If S[I]=#10 Then ConPutC(#13);
  ConPutC(S[I]);
 End;
End;

Procedure KPrintLn(S: String);
Begin
 KPrint(S); ConPutC(#13); ConPutC(#10);
End;

Function IntStr(L: Longint): String;
Var S: String;
Begin
 Str(L,S); IntStr:=S;
End;

Function HexStr(W: Word): String;
Const H: String[16]='0123456789ABCDEF';
Begin
 HexStr:=H[(W Shr 12)+1]+H[((W Shr 8) And 15)+1]+H[((W Shr 4) And 15)+1]+
   H[(W And 15)+1];
End;

Procedure CliHlt; Assembler;
Asm
@L:
 CLI
 HLT
 JMP @L
End;

Procedure Panic(S: String);
Begin
 KPrintLn('');
 KPrintLn('panique : '+S);
 CliHlt;
End;

Procedure FarMove(SS_, SO, DS_, DO_, N: Word); Assembler;
Asm
 PUSH DS
 MOV CX,N
 JCXZ @Fin
 MOV AX,SS_
 MOV SI,SO
 MOV ES,DS_
 MOV DI,DO_
 MOV DS,AX
 CLD
 SHR CX,1
 REP MOVSW
 JNC @Fin
 MOVSB
@Fin:
 POP DS
End;

Procedure FarFill(DS_, DO_, N: Word; B: Byte); Assembler;
Asm
 MOV CX,N
 JCXZ @Fin
 MOV ES,DS_
 MOV DI,DO_
 MOV AL,B
 CLD
 REP STOSB
@Fin:
End;

Procedure ParaCopy(Src, Dst, Paras: Word);
{ copie de Paras paragraphes (zones disjointes ou Dst < Src) }
Var N: Word;
Begin
 While Paras>0 Do Begin
  If Paras>$800 Then N:=$800 Else N:=Paras;
  FarMove(Src,0,Dst,0,N*16);
  Inc(Src,N); Inc(Dst,N); Dec(Paras,N);
 End;
End;

Procedure ParaZero(Dst, Paras: Word);
Var N: Word;
Begin
 While Paras>0 Do Begin
  If Paras>$800 Then N:=$800 Else N:=Paras;
  FarFill(Dst,0,N*16,0);
  Inc(Dst,N); Dec(Paras,N);
 End;
End;

Procedure XchgBlock(A, B, Words: Word); Assembler;
Asm
 PUSH DS
 MOV CX,Words
 JCXZ @Fin
 MOV ES,B
 MOV AX,A
 MOV DS,AX
 XOR SI,SI
@L:
 MOV AX,[SI]
 MOV DX,ES:[SI]
 MOV ES:[SI],AX
 MOV [SI],DX
 ADD SI,2
 LOOP @L
@Fin:
 POP DS
End;

Procedure ParaXchg(A, B, Paras: Word);
{ permute deux zones disjointes de Paras paragraphes }
Var N: Word;
Begin
 While Paras>0 Do Begin
  If Paras>$800 Then N:=$800 Else N:=Paras;
  XchgBlock(A,B,N*8);
  Inc(A,N); Inc(B,N); Dec(Paras,N);
 End;
End;

Function FarStr(Sg, Os: Word; Max: Integer): String;
Var S: String;
Begin
 S:='';
 While (Mem[Sg:Os]<>0) And (Length(S)<Max) Do Begin
  S:=S+Chr(Mem[Sg:Os]); Inc(Os);
 End;
 FarStr:=S;
End;

Procedure PutFarStr(Sg, Os: Word; S: String);
Var I: Integer;
Begin
 For I:=1 To Length(S) Do Mem[Sg:Os+I-1]:=Ord(S[I]);
 Mem[Sg:Os+Length(S)]:=0;
End;

Function UpStr(S: String): String;
Var I: Integer;
Begin
 For I:=1 To Length(S) Do S[I]:=UpCase(S[I]);
 UpStr:=S;
End;

Function LowStr(S: String): String;
Var I: Integer;
Begin
 For I:=1 To Length(S) Do If S[I] In ['A'..'Z'] Then S[I]:=Chr(Ord(S[I])+32);
 LowStr:=S;
End;

Function Bcd(B: Byte): Word;
Begin
 Bcd:=(B Shr 4)*10+(B And 15);
End;

Function ReadRTC: Longint;
{ secondes depuis 1970 lues dans l'horloge temps reel (INT 1Ah) }
Var H,M,S,C,Y,Mo,D,Ok: Byte; Days: Longint; I,Yr: Word;
Const MDays: Array[1..12] Of Word=(31,28,31,30,31,30,31,31,30,31,30,31);
Begin
 Ok:=0;
 Asm
  MOV AH,2
  INT 1Ah
  MOV H,CH
  MOV M,CL
  MOV S,DH
  MOV AH,4
  INT 1Ah
  JC @NoRtc
  MOV C,CH
  MOV Y,CL
  MOV Mo,DH
  MOV D,DL
  MOV Ok,1
 @NoRtc:
 End;
 If (Ok=0) Or (Mo=0) Then Begin ReadRTC:=1767225600; Exit End; { 2026-01-01 }
 Yr:=Bcd(C)*100+Bcd(Y);
 If Yr<1980 Then Yr:=2026;
 Days:=0;
 For I:=1970 To Yr-1 Do If I Mod 4=0 Then Inc(Days,366) Else Inc(Days,365);
 For I:=1 To Bcd(Mo)-1 Do Begin
  If I<=12 Then Inc(Days,MDays[I]);
  If (I=2) And (Yr Mod 4=0) Then Inc(Days);
 End;
 Inc(Days,Bcd(D)-1);
 ReadRTC:=Days*86400+Longint(Bcd(H))*3600+Bcd(M)*60+Bcd(S);
End;

Function KTime: Longint;
Begin
 KTime:=BootTime+(Ticks*10) Div 182;
End;

SegmentEnd;

{ ====================================================================== }
SegmentUnit KMem;
{ Gestion de la memoire physique : table des zones libres (coremap) en
  paragraphes, allocation premier ajustement (malloc de UNIX V6). }
Uses KTypes,KLib;
SegmentInterface

Const NMAP=64;

Var
 MapAddr, MapSize: Array[1..NMAP] Of Word;
 MapCount: Integer;
 TotalParas: Word;

Procedure CoreInit(Start, Top: Word);
Function CoreAlloc(Paras: Word): Word;
Procedure CoreFree(Sg, Paras: Word);
Function CoreFreeTotal: Word;
Function CoreLargest: Word;

SegmentImplementation

Procedure CoreInit(Start, Top: Word);
Begin
 MapCount:=1; MapAddr[1]:=Start; MapSize[1]:=Top-Start;
 TotalParas:=Top-Start;
End;

Function CoreAlloc(Paras: Word): Word;
Var I,J: Integer;
Begin
 CoreAlloc:=0;
 If Paras=0 Then Exit;
 For I:=1 To MapCount Do
  If MapSize[I]>=Paras Then Begin
   CoreAlloc:=MapAddr[I];
   Inc(MapAddr[I],Paras); Dec(MapSize[I],Paras);
   If MapSize[I]=0 Then Begin
    For J:=I To MapCount-1 Do Begin
     MapAddr[J]:=MapAddr[J+1]; MapSize[J]:=MapSize[J+1];
    End;
    Dec(MapCount);
   End;
   Exit;
  End;
End;

Procedure CoreFree(Sg, Paras: Word);
Var I,J: Integer;
Begin
 If (Sg=0) Or (Paras=0) Then Exit;
 I:=1;
 While (I<=MapCount) And (MapAddr[I]<Sg) Do Inc(I);
 { fusion avec la zone precedente }
 If (I>1) And (MapAddr[I-1]+MapSize[I-1]=Sg) Then Begin
  Inc(MapSize[I-1],Paras);
  If (I<=MapCount) And (Sg+Paras=MapAddr[I]) Then Begin
   Inc(MapSize[I-1],MapSize[I]);
   For J:=I To MapCount-1 Do Begin
    MapAddr[J]:=MapAddr[J+1]; MapSize[J]:=MapSize[J+1];
   End;
   Dec(MapCount);
  End;
  Exit;
 End;
 { fusion avec la zone suivante }
 If (I<=MapCount) And (Sg+Paras=MapAddr[I]) Then Begin
  MapAddr[I]:=Sg; Inc(MapSize[I],Paras); Exit;
 End;
 If MapCount=NMAP Then Begin KPrintLn('coremap pleine'); Exit End;
 For J:=MapCount DownTo I Do Begin
  MapAddr[J+1]:=MapAddr[J]; MapSize[J+1]:=MapSize[J];
 End;
 MapAddr[I]:=Sg; MapSize[I]:=Paras; Inc(MapCount);
End;

Function CoreFreeTotal: Word;
Var I: Integer; T: Word;
Begin
 T:=0;
 For I:=1 To MapCount Do Inc(T,MapSize[I]);
 CoreFreeTotal:=T;
End;

Function CoreLargest: Word;
Var I: Integer; T: Word;
Begin
 T:=0;
 For I:=1 To MapCount Do If MapSize[I]>T Then T:=MapSize[I];
 CoreLargest:=T;
End;

SegmentEnd;

{ ====================================================================== }
SegmentUnit KSched;
{ Ordonnanceur : commutation de contexte, sommeil et reveil, horloge,
  points d'entree des interruptions (appels systeme, horloge, fautes). }
Uses KTypes,KLib,KMem;
SegmentInterface

Var
 SwSave, SwLoad: Word;         { decalages (DS) des contextes KSP/KSS }
 Quantum: Integer;
 RunRun: Boolean;              { une commutation est demandee }
 SchedOn: Boolean;             { preemption active }
 OldInt08, OldInt1B: Pointer;
 BreakFlag: Boolean;           { Ctrl+Break }
 IdleHook: Pointer;            { scrutation du terminal (KTty) }
 NextPid: Integer;
 IdleTicks: Longint;

Procedure KSwitch;
Procedure ForkRet;
Procedure Int80Stub;
Procedure Int08Stub;
Procedure Int1BStub;
Procedure Int00Stub;
Procedure NoDosStub;
Procedure SetVector(N: Byte; Sg, Os: Word);
Function GetVector(N: Byte): Pointer;
Procedure SetDosVector(P: Integer);
Procedure MakeResident(P: Integer);
Procedure Swtch;
Procedure Sleep(Chan: Word);
Function SleepIntr(Chan: Word): Boolean;
Procedure Wakeup(Chan: Word);
Procedure WakeProc(P: Integer);
Function FindPid(Pid: Integer): Integer;
Procedure PostSig(P: Integer; Sig: Integer);
Function UserW(Off: Word): Word;
Procedure SetUserW(Off: Word; W: Word);
Procedure CallIdleHook;

SegmentImplementation

Procedure KSwitch; Assembler;
{ Sauve le contexte noyau courant dans [SwSave] (SP, SS) et reprend celui de
  [SwLoad]. Appelee par Swtch : le retour se fait dans le processus elu. }
Asm
 PUSH BP
 PUSH SI
 PUSH DI
 MOV BX,SwSave
 MOV [BX],SP
 MOV [BX+2],SS
 MOV BX,SwLoad
 CLI
 MOV SS,[BX+2]
 MOV SP,[BX]
 STI
 POP DI
 POP SI
 POP BP
End;

Procedure ForkRet; Assembler;
{ Premier passage d'un processus cree par fork ou par le noyau : retour
  direct en mode utilisateur avec la trame de CurUSS:CurUSP. }
Asm
 MOV AX,SEG @DATA
 MOV DS,AX
 CLI
 MOV InKernel,0
 MOV SS,CurUSS
 MOV SP,CurUSP
 POP AX
 POP BX
 POP CX
 POP DX
 POP SI
 POP DI
 POP BP
 POP ES
 POP DS
 IRET
End;

Procedure Int80Stub; Assembler;
{ INT 80h : appel systeme. Registres sauves sur la pile utilisateur, puis
  passage sur la pile noyau du processus et appel de SysHook. }
Asm
 PUSH DS
 PUSH ES
 PUSH BP
 PUSH DI
 PUSH SI
 PUSH DX
 PUSH CX
 PUSH BX
 PUSH AX
 MOV AX,SEG @DATA
 MOV DS,AX
 MOV CurUSS,SS
 MOV CurUSP,SP
 MOV AX,CurKStack
 MOV SS,AX
 MOV SP,KSTKTOP
 MOV InKernel,1
 MOV ES,AX
 STI
 CLD
 CALL DWORD PTR SysHook
 MOV AX,SEG @DATA
 MOV DS,AX
 CLI
 MOV InKernel,0
 MOV SS,CurUSS
 MOV SP,CurUSP
 POP AX
 POP BX
 POP CX
 POP DX
 POP SI
 POP DI
 POP BP
 POP ES
 POP DS
 IRET
End;

Procedure Int00Stub; Assembler;
{ Faute du processeur (division par zero) : SIGFPE au processus courant. }
Asm
 PUSH DS
 PUSH ES
 PUSH BP
 PUSH DI
 PUSH SI
 PUSH DX
 PUSH CX
 PUSH BX
 PUSH AX
 MOV AX,SEG @DATA
 MOV DS,AX
 CMP InKernel,0
 JE @User
 CALL CliHlt
@User:
 MOV CurUSS,SS
 MOV CurUSP,SP
 MOV AX,CurKStack
 MOV SS,AX
 MOV SP,KSTKTOP
 MOV InKernel,1
 STI
 CLD
 CALL DWORD PTR FaultHook
 MOV AX,SEG @DATA
 MOV DS,AX
 CLI
 MOV InKernel,0
 MOV SS,CurUSS
 MOV SP,CurUSP
 POP AX
 POP BX
 POP CX
 POP DX
 POP SI
 POP DI
 POP BP
 POP ES
 POP DS
 IRET
End;

Procedure NoDosStub; Assembler;
{ INT 21h d'un processus sans couche libc : appel systeme exit(SIGSYS). }
Asm
 MOV AX,1
 MOV BX,7F00h
 INT 80h
@L:
 JMP @L
End;

Procedure Int08Stub; Assembler;
{ IRQ0 (horloge, 18,2 Hz) : BIOS, puis preemption du processus courant si
  son quantum est epuise et qu'il est en mode utilisateur. }
Asm
 PUSH DS
 PUSH ES
 PUSH BP
 PUSH DI
 PUSH SI
 PUSH DX
 PUSH CX
 PUSH BX
 PUSH AX
 MOV AX,SEG @DATA
 MOV DS,AX
 PUSHF
 CALL DWORD PTR OldInt08
 ADD WORD PTR Ticks,1
 ADC WORD PTR Ticks+2,0
 CMP SchedOn,0
 JE @Out
 CMP InKernel,0
 JNE @Out
 MOV BP,SP
 MOV AX,[BP+20]
 CMP AX,0A000h
 JAE @Out
 DEC Quantum
 JLE @Preempt
 CMP BreakFlag,0
 JNE @Preempt
 JMP @Out
@Preempt:
 MOV CurUSS,SS
 MOV CurUSP,SP
 MOV AX,CurKStack
 MOV SS,AX
 MOV SP,KSTKTOP
 MOV InKernel,1
 STI
 CLD
 CALL DWORD PTR PreemptHook
 MOV AX,SEG @DATA
 MOV DS,AX
 CLI
 MOV InKernel,0
 MOV SS,CurUSS
 MOV SP,CurUSP
@Out:
 POP AX
 POP BX
 POP CX
 POP DX
 POP SI
 POP DI
 POP BP
 POP ES
 POP DS
 IRET
End;

Procedure Int1BStub; Assembler;
{ Ctrl+Break du BIOS }
Asm
 PUSH DS
 PUSH AX
 MOV AX,SEG @DATA
 MOV DS,AX
 MOV BreakFlag,1
 POP AX
 POP DS
 IRET
End;

Procedure SetVector(N: Byte; Sg, Os: Word);
Begin
 Asm CLI End;
 MemW[0:N*4]:=Os; MemW[0:N*4+2]:=Sg;
 Asm STI End;
End;

Function GetVector(N: Byte): Pointer;
Begin
 GetVector:=Ptr(MemW[0:N*4+2],MemW[0:N*4]);
End;

Procedure SetDosVector(P: Integer);
Begin
 If (P>0) And (Procs[P].DosSeg<>0) Then
   SetVector($21,Procs[P].DosSeg,Procs[P].DosOfs)
 Else SetVector($21,Seg(NoDosStub),Ofs(NoDosStub));
End;

Function UserW(Off: Word): Word;
{ mot Off de la trame utilisateur du processus courant }
Begin
 UserW:=MemW[CurUSS:CurUSP+Off];
End;

Procedure SetUserW(Off: Word; W: Word);
Begin
 MemW[CurUSS:CurUSP+Off]:=W;
End;

Procedure MakeResident(P: Integer);
{ L'image de P doit etre a son adresse d'execution (Home). Si un autre
  processus (fork) occupe cette adresse, les deux images sont permutees. }
Var O: Integer;
Begin
 With Procs[P] Do Begin
  If (Size=0) Or (Where=Home) Then Exit;
  For O:=0 To NPROC-1 Do
   If (O<>P) And (Procs[O].Stat<>PFREE) And (Procs[O].Size<>0) And
     (Procs[O].Home=Home) And (Procs[O].Where=Home) Then Begin
    ParaXchg(Home,Where,Size);
    Procs[O].Where:=Where; Where:=Home;
    Exit;
   End;
  { personne a l'adresse : simple copie }
  ParaCopy(Where,Home,Size);
  CoreFree(Where,Size); Where:=Home;
 End;
End;

Procedure CallIdleHook; Assembler;
Asm
 CMP WORD PTR IdleHook+2,0
 JE @Fin
 CALL DWORD PTR IdleHook
@Fin:
End;

Procedure CheckTimers;
Var I: Integer;
Begin
 For I:=1 To NPROC-1 Do With Procs[I] Do
  If (Stat=PSLEEP) And (Wake<>0) And (Ticks>=Wake) Then Begin
   Wake:=0; Stat:=PRUN;
  End;
End;

Procedure Swtch;
{ Elit le prochain processus pret (tourniquet) et lui donne le processeur.
  Si aucun n'est pret, attend une interruption (HLT). }
Var N,I: Integer; T: Longint;
Begin
 { controle de debordement de la pile noyau (motif CCh au fond) }
 If (Cur>0) And (MemW[Procs[Cur].KStack:0]<>$CCCC) Then
  Panic('debordement de la pile noyau (pid '+IntStr(Procs[Cur].Pid)+')');
 Procs[Cur].USS:=CurUSS; Procs[Cur].USP:=CurUSP;
 RunRun:=False;
 Repeat
  CallIdleHook;
  CheckTimers;
  N:=-1; I:=Cur;
  Repeat
   Inc(I); If I>=NPROC Then I:=1;
   If Procs[I].Stat=PRUN Then N:=I;
  Until (N>=0) Or (I=Cur);
  If (N<0) And (Cur>0) And (Procs[Cur].Stat=PRUN) Then N:=Cur;
  If N<0 Then Begin
   T:=Ticks;
   Asm
    STI
    HLT
   End;
   Inc(IdleTicks,Ticks-T);
  End;
 Until N>=0;
 Quantum:=QUANTUM;
 If N=Cur Then Exit;
 MakeResident(N);
 SwSave:=Ofs(Procs[Cur].KSP); SwLoad:=Ofs(Procs[N].KSP);
 Cur:=N;
 CurUSS:=Procs[N].USS; CurUSP:=Procs[N].USP; CurKStack:=Procs[N].KStack;
 SetDosVector(N);
 KSwitch;
End;

Procedure Sleep(Chan: Word);
Begin
 Procs[Cur].Chan:=Chan; Procs[Cur].Intr:=False; Procs[Cur].Stat:=PSLEEP;
 Swtch;
End;

Function SleepIntr(Chan: Word): Boolean;
{ Sommeil interruptible : False si un signal est arrive. }
Begin
 If Procs[Cur].SigPend And Not Procs[Cur].SigIgn<>0 Then Begin
  SleepIntr:=False; Exit;
 End;
 Procs[Cur].Chan:=Chan; Procs[Cur].Intr:=True; Procs[Cur].Stat:=PSLEEP;
 Swtch;
 Procs[Cur].Intr:=False;
 SleepIntr:=Procs[Cur].SigPend And Not Procs[Cur].SigIgn=0;
End;

Procedure Wakeup(Chan: Word);
Var I: Integer;
Begin
 For I:=1 To NPROC-1 Do
  If (Procs[I].Stat=PSLEEP) And (Procs[I].Chan=Chan) Then Begin
   Procs[I].Stat:=PRUN; Procs[I].Wake:=0;
  End;
End;

Procedure WakeProc(P: Integer);
Begin
 If Procs[P].Stat=PSLEEP Then Begin Procs[P].Stat:=PRUN; Procs[P].Wake:=0 End;
End;

Function FindPid(Pid: Integer): Integer;
Var I: Integer;
Begin
 FindPid:=-1;
 For I:=1 To NPROC-1 Do
  If (Procs[I].Stat<>PFREE) And (Procs[I].Pid=Pid) Then Begin
   FindPid:=I; Exit;
  End;
End;

Procedure PostSig(P: Integer; Sig: Integer);
Begin
 If (Sig<1) Or (Sig>15) Then Exit;
 With Procs[P] Do Begin
  If Stat In [PFREE,PZOMB] Then Exit;
  If (SigIgn And (1 Shl Sig)<>0) And (Sig<>SIGKILL) Then Exit;
  SigPend:=SigPend Or (1 Shl Sig);
  If (Stat=PSLEEP) And Intr Then Begin Stat:=PRUN; Wake:=0 End;
 End;
End;

SegmentEnd;

{ ====================================================================== }
SegmentUnit KDisk;
{ Disques du BIOS (INT 13h) et cache de secteurs (ecriture immediate). }
Uses KTypes,KLib;
SegmentInterface

Var
 BufDev: Array[1..NBUF] Of Byte;     { $FF = libre }
 BufLBA: Array[1..NBUF] Of Longint;
 BufAge: Array[1..NBUF] Of Longint;
 BufClock: Longint;
 DiskErrors: Word;

Procedure DiskInit;
Function DiskIO(D: Integer; LBA: Longint; Sg, Os: Word; Wr: Boolean): Boolean;
Function BRead(D: Integer; LBA: Longint): Integer;
Function BGet(D: Integer; LBA: Longint): Integer;
Function BWrite(B: Integer): Boolean;
Function BufSeg(B: Integer): Word;
Procedure BInval(D: Integer);
Function AddDisk(Bios: Byte; Name: String; Start, Sectors: Longint;
  PType: Byte): Integer;

SegmentImplementation

Function AddDisk(Bios: Byte; Name: String; Start, Sectors: Longint;
  PType: Byte): Integer;
Var I,N: Integer;
Begin
 AddDisk:=-1;
 If DiskCount>=NDISK Then Exit;
 N:=DiskCount;
 Disks[N].Bios:=Bios; Disks[N].Present:=True;
 Disks[N].Spt:=0; Disks[N].Heads:=0; Disks[N].Cyls:=0;
 For I:=0 To N-1 Do If Disks[I].Bios=Bios Then Begin
  Disks[N].Spt:=Disks[I].Spt; Disks[N].Heads:=Disks[I].Heads;
  Disks[N].Cyls:=Disks[I].Cyls;
 End;
 Disks[N].Start:=Start; Disks[N].Sectors:=Sectors;
 Disks[N].PartType:=PType; Disks[N].Name:=Name;
 AddDisk:=N;
 Inc(DiskCount);
End;

Function Geometry(Bios: Byte; Var Spt, Heads, Cyls: Word): Boolean;
Var S,H,C1,C2,Ok: Byte;
Begin
 Ok:=0;
 Asm
  PUSH ES
  PUSH DI
  MOV AH,8
  MOV DL,Bios
  PUSH BP
  INT 13h
  POP BP
  JC @Err
  MOV S,CL
  MOV C1,CH
  MOV H,DH
  MOV Ok,1
 @Err:
  POP DI
  POP ES
 End;
 Geometry:=(Ok=1) And (S And 63<>0);
 Spt:=S And 63; Heads:=Word(H)+1;
 Cyls:=(Word(S And $C0) Shl 2)+C1+1;
End;

Procedure DiskInit;
Var I: Integer;
Begin
 For I:=1 To NBUF Do Begin BufDev[I]:=$FF; BufAge[I]:=0 End;
 BufClock:=0;
End;

Procedure SetGeometry(D: Integer);
Var Spt_,Heads_,Cyls_: Word; I: Integer;
Begin
 If Disks[D].Spt<>0 Then Exit;
 If Geometry(Disks[D].Bios,Spt_,Heads_,Cyls_) Then Begin
  Disks[D].Spt:=Spt_; Disks[D].Heads:=Heads_; Disks[D].Cyls:=Cyls_;
 End Else Begin
  Disks[D].Spt:=18; Disks[D].Heads:=2; Disks[D].Cyls:=80;
 End;
 For I:=0 To DiskCount-1 Do If Disks[I].Bios=Disks[D].Bios Then Begin
  Disks[I].Spt:=Disks[D].Spt; Disks[I].Heads:=Disks[D].Heads;
  Disks[I].Cyls:=Disks[D].Cyls;
 End;
End;

Function DiskIO(D: Integer; LBA: Longint; Sg, Os: Word; Wr: Boolean): Boolean;
Var C,H,S,Cmd,Drv,Tries,Ok: Byte; Cyl: Word; T: Longint;
Begin
 DiskIO:=False;
 If (D<0) Or (D>=DiskCount) Then Exit;
 SetGeometry(D);
 With Disks[D] Do Begin
  If (Sectors<>0) And (LBA>=Sectors) Then Exit;
  T:=LBA+Start;
  S:=(T Mod Spt)+1; T:=T Div Spt;
  H:=T Mod Heads; Cyl:=T Div Heads;
  Drv:=Bios;
 End;
 If Cyl>1023 Then Exit;
 C:=Lo(Cyl); S:=S Or ((Hi(Cyl) And 3) Shl 6);
 If Wr Then Cmd:=3 Else Cmd:=2;
 Tries:=0;
 Repeat
  Ok:=0;
  Asm
   PUSH ES
   MOV AH,Cmd
   MOV AL,1
   MOV CH,C
   MOV CL,S
   MOV DH,H
   MOV DL,Drv
   MOV ES,Sg
   MOV BX,Os
   PUSH BP
   INT 13h
   POP BP
   POP ES
   JC @Err
   MOV Ok,1
  @Err:
  End;
  If Ok=1 Then Begin DiskIO:=True; Exit End;
  Asm
   MOV AH,0
   MOV DL,Drv
   PUSH BP
   INT 13h
   POP BP
  End;
  Inc(Tries);
 Until Tries>=4;
 Inc(DiskErrors);
End;

Function BufSeg(B: Integer): Word;
Begin
 BufSeg:=BUFBASE+(B-1)*32;
End;

Function Find(D: Integer; LBA: Longint): Integer;
Var I: Integer;
Begin
 Find:=0;
 For I:=1 To NBUF Do
  If (BufDev[I]=D) And (BufLBA[I]=LBA) Then Begin Find:=I; Exit End;
End;

Function Victim: Integer;
Var I,V: Integer;
Begin
 V:=1;
 For I:=1 To NBUF Do Begin
  If BufDev[I]=$FF Then Begin Victim:=I; Exit End;
  If BufAge[I]<BufAge[V] Then V:=I;
 End;
 Victim:=V;
End;

Function BGet(D: Integer; LBA: Longint): Integer;
{ tampon pour le secteur (sans lecture : il sera entierement ecrit) }
Var B: Integer;
Begin
 B:=Find(D,LBA);
 If B=0 Then Begin
  B:=Victim; BufDev[B]:=D; BufLBA[B]:=LBA;
 End;
 Inc(BufClock); BufAge[B]:=BufClock;
 BGet:=B;
End;

Function BRead(D: Integer; LBA: Longint): Integer;
{ tampon contenant le secteur LBA (relatif a Disks[D]), 0 si erreur }
Var B: Integer;
Begin
 B:=Find(D,LBA);
 If B=0 Then Begin
  B:=Victim;
  If Not DiskIO(D,LBA,BufSeg(B),0,False) Then Begin
   BufDev[B]:=$FF; BRead:=0; Exit;
  End;
  BufDev[B]:=D; BufLBA[B]:=LBA;
 End;
 Inc(BufClock); BufAge[B]:=BufClock;
 BRead:=B;
End;

Function BWrite(B: Integer): Boolean;
Begin
 BWrite:=DiskIO(BufDev[B],BufLBA[B],BufSeg(B),0,True);
End;

Procedure BInval(D: Integer);
Var I: Integer;
Begin
 For I:=1 To NBUF Do If BufDev[I]=D Then BufDev[I]:=$FF;
End;

SegmentEnd;

{ ====================================================================== }
SegmentUnit KTty;
{ Terminal console : ecran (BIOS INT 10h), clavier (BIOS INT 16h) et port
  serie COM1. Discipline de ligne canonique ou brute. }
Uses KTypes,KLib,KSched;
SegmentInterface

Const
 TTYRAW=1; TTYNOECHO=2;

Var
 TtyMode: Word;
 TtyWaiting: Integer;

Procedure TtyPoll;
Procedure TtyCheckIntr;
Procedure TtyIntr;
Function TtyRead(Sg, Os, N: Word; Var Err: Integer): Integer;
Function TtyWrite(Sg, Os, N: Word): Integer;
Function TtyAvail: Integer;

SegmentImplementation

Var
 InBuf: Array[0..511] Of Char;     { caracteres prets a lire }
 InHead, InTail: Word;
 InEof: Integer;                   { fins de fichier (^D) en attente }
 Line: Array[0..255] Of Char;      { ligne en cours d'edition }
 LineLen: Integer;

Procedure PutIn(C: Char);
Var N: Word;
Begin
 N:=(InTail+1) And 511;
 If N<>InHead Then Begin InBuf[InTail]:=C; InTail:=N End;
End;

Function InCount: Integer;
Begin
 InCount:=(InTail-InHead) And 511;
End;

Procedure Echo(C: Char);
Begin
 If TtyMode And TTYNOECHO<>0 Then Exit;
 If C=#10 Then ConPutC(#13);
 ConPutC(C);
End;

Procedure TtyIntr;
{ ^C : SIGINT aux processus d'avant-plan (ceux qui ne lisent pas le
  terminal et n'attendent pas un fils). }
Var I: Integer;
Begin
 For I:=1 To NPROC-1 Do With Procs[I] Do
  If (Stat In [PRUN,PSLEEP]) And (Pid>1) And
    Not ((Stat=PSLEEP) And ((Chan=CHTTY) Or (Chan=CHWAIT+I))) Then
   PostSig(I,SIGINT);
End;

Procedure Input(C: Char; Scan: Byte);
Var I: Integer;
Begin
 If TtyMode And TTYRAW<>0 Then Begin
  If (C=#0) Or (C=#$E0) Then Begin
   If Scan<>0 Then Begin PutIn(#0); PutIn(Chr(Scan)) End;
  End Else PutIn(C);
  Wakeup(CHTTY);
  Exit;
 End;
 Case C Of
  #0,#$E0: ;
  #3: Begin
       Echo('^'); Echo('C'); Echo(#10);
       LineLen:=0;
       TtyIntr;
       If TtyWaiting>0 Then PutIn(#10);
      End;
  #8,#127: If LineLen>0 Then Begin
       Dec(LineLen); Echo(#8); Echo(' '); Echo(#8);
      End;
  #21: Begin
       While LineLen>0 Do Begin Dec(LineLen); Echo(#8); Echo(' '); Echo(#8) End;
      End;
  #4: Begin
       If LineLen=0 Then Inc(InEof)
       Else Begin
        For I:=0 To LineLen-1 Do PutIn(Line[I]);
        LineLen:=0;
       End;
      End;
  #13,#10: Begin
       For I:=0 To LineLen-1 Do PutIn(Line[I]);
       PutIn(#10); LineLen:=0; Echo(#10);
      End;
  Else If (C>=' ') Or (C=#9) Or (C=#27) Then Begin
   If LineLen<255 Then Begin Line[LineLen]:=C; Inc(LineLen); Echo(C) End;
  End;
 End;
 Wakeup(CHTTY);
End;

Procedure PollKeys;
Var A,S,Have: Byte;
Begin
 Repeat
  Have:=0;
  Asm
   MOV AH,1
   INT 16h
   JZ @None
   MOV AH,0
   INT 16h
   MOV A,AL
   MOV S,AH
   MOV Have,1
  @None:
  End;
  If Have=1 Then Input(Chr(A),S);
 Until Have=0;
 If SerialPort<>0 Then
  While Port[SerialPort+5] And 1<>0 Do Begin
   A:=Port[SerialPort];
   If (A=127) And (TtyMode And TTYRAW=0) Then A:=8;
   If (A=13) Or (A<>10) Then Input(Chr(A),0);
  End;
End;

Procedure TtyPoll;
{ appelee par l'ordonnanceur : lit le clavier si un processus attend }
Begin
 If TtyWaiting>0 Then PollKeys;
 If BreakFlag Then Begin BreakFlag:=False; TtyIntr End;
End;

Procedure TtyCheckIntr;
{ appelee a la preemption : ^C en tete du tampon clavier, Ctrl+Break }
Var A,Have: Byte;
Begin
 If BreakFlag Then Begin BreakFlag:=False; TtyIntr; Exit End;
 If TtyMode And TTYRAW<>0 Then Exit;
 Have:=0;
 Asm
  MOV AH,1
  INT 16h
  JZ @None
  CMP AL,3
  JNE @None
  MOV AH,0
  INT 16h
  MOV Have,1
 @None:
 End;
 If (Have=0) And (SerialPort<>0) Then
  If Port[SerialPort+5] And 1<>0 Then Begin
   A:=Port[SerialPort];
   If A=3 Then Have:=1 Else Input(Chr(A),0);
  End;
 If Have=1 Then Begin Echo('^'); Echo('C'); Echo(#10); TtyIntr End;
End;

Function TtyAvail: Integer;
Begin
 PollKeys;
 TtyAvail:=InCount;
End;

Function TtyRead(Sg, Os, N: Word; Var Err: Integer): Integer;
Var Got: Word; C: Char;
Begin
 Err:=0; TtyRead:=0;
 If N=0 Then Exit;
 Inc(TtyWaiting);
 PollKeys;
 While (InCount=0) And (InEof=0) Do Begin
  If Not SleepIntr(CHTTY) Then Begin
   Dec(TtyWaiting); Err:=EINTR; TtyRead:=-1; Exit;
  End;
  PollKeys;
 End;
 Dec(TtyWaiting);
 Got:=0;
 If InCount=0 Then Begin Dec(InEof); TtyRead:=0; Exit End;
 While (Got<N) And (InCount>0) Do Begin
  C:=InBuf[InHead]; InHead:=(InHead+1) And 511;
  Mem[Sg:Os+Got]:=Ord(C); Inc(Got);
  If (C=#10) And (TtyMode And TTYRAW=0) Then Break;
 End;
 TtyRead:=Got;
End;

Function TtyWrite(Sg, Os, N: Word): Integer;
Var I: Word; C: Char;
Begin
 For I:=0 To N-1 Do Begin
  C:=Chr(Mem[Sg:Os+I]);
  If C=#10 Then ConPutC(#13);
  ConPutC(C);
 End;
 TtyWrite:=N;
End;

SegmentEnd;

{ ====================================================================== }
SegmentUnit KFat;
{ Systemes de fichiers FAT12 et FAT16 (noms 8.3, presentes en minuscules). }
Uses KTypes,KLib,KDisk;
SegmentInterface

Const FATEOC=$FFFF;

Function FatMount(M: Integer): Integer;
Procedure FatRoot(M: Integer; Var V: TVNode);
Function FatGet(M: Integer; C: Longint): Longint;
Function FatLookup(Var Dir: TVNode; Name: TName; Var V: TVNode): Integer;
Function FatRead(Var V: TVNode; Off: Longint; Sg, Os, N: Word): Integer;
Function FatWrite(Var V: TVNode; Off: Longint; Sg, Os, N: Word): Integer;
Function FatTrunc(Var V: TVNode): Integer;
Function FatReadDir(Var V: TVNode; Var Pos: Longint; Var Name: TName;
  Var Ino: Longint; Var Typ: Byte): Boolean;
Function FatCreate(Var Dir: TVNode; Name: TName; IsDir: Boolean;
  Var V: TVNode): Integer;
Function FatRemove(Var Dir: TVNode; Name: TName; IsDir: Boolean): Integer;
Function FatRename(Var D1: TVNode; N1: TName; Var D2: TVNode;
  N2: TName): Integer;
Procedure FatUpdate(Var V: TVNode);
Function FatFreeKB(M: Integer): Longint;
Function DosStamp(T: Longint): Longint;
Function UnixStamp(D, T: Word): Longint;

SegmentImplementation

Var


Function DosStamp(T: Longint): Longint;
{ secondes depuis 1970 -> date (mot haut) et heure (mot bas) DOS }
Var Days,Secs: Longint; Y,M,D,DM: Word;
Begin
 If T<315532800 Then T:=315532800;
 Days:=T Div 86400; Secs:=T Mod 86400;
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
 DosStamp:=(Longint((Y-1980) Shl 9 Or (M Shl 5) Or D) Shl 16) Or
   ((Secs Div 3600) Shl 11) Or (((Secs Mod 3600) Div 60) Shl 5) Or
   ((Secs Mod 60) Div 2);
End;

Function UnixStamp(D, T: Word): Longint;
Var Y,M,I: Word; Days: Longint;
Const MD: Array[1..12] Of Word=(31,28,31,30,31,30,31,31,30,31,30,31);
Begin
 Y:=(D Shr 9)+1980; M:=(D Shr 5) And 15;
 If (M<1) Or (M>12) Then Begin UnixStamp:=315532800; Exit End;
 Days:=0;
 For I:=1970 To Y-1 Do If I Mod 4=0 Then Inc(Days,366) Else Inc(Days,365);
 For I:=1 To M-1 Do Begin
  Inc(Days,MD[I]); If (I=2) And (Y Mod 4=0) Then Inc(Days);
 End;
 Inc(Days,(D And 31)-1);
 UnixStamp:=Days*86400+Longint(T Shr 11)*3600+((T Shr 5) And 63)*60+
   (T And 31)*2;
End;

Function Fat16(M: Integer): Boolean;
Begin
 Fat16:=Mounts[M].Typ=FSFAT16;
End;

Function FatMount(M: Integer): Integer;
Var B: Integer; S: Word; Tot: Longint;
Begin
 FatMount:=EIO;
 With Mounts[M] Do Begin
  B:=BRead(Drive,0);
  If B=0 Then Exit;
  S:=BufSeg(B);
  FatMount:=EINVAL;
  If (MemW[S:11]<>512) Or (Mem[S:13]=0) Or (Mem[S:16]=0) Then Exit;
  SecPerClus:=Mem[S:13];
  NFats:=Mem[S:16];
  RootEnt:=MemW[S:17];
  Tot:=MemW[S:19]; If Tot=0 Then Tot:=MemL[S:32];
  SecPerFat:=MemW[S:22];
  If SecPerFat=0 Then Exit; { FAT32 non gere }
  FatLBA:=MemW[S:14];
  RootLBA:=FatLBA+NFats*SecPerFat;
  DataLBA:=RootLBA+(Longint(RootEnt)*32+511) Div 512;
  Clusters:=(Tot-DataLBA) Div SecPerClus;
  Sectors:=Tot;
  If Clusters<4085 Then Typ:=FSFAT12 Else Typ:=FSFAT16;
  FreeHint:=2;
 End;
 FatMount:=0;
End;

Procedure FatRoot(M: Integer; Var V: TVNode);
Begin
 FillChar(V,SizeOf(V),0);
 V.Typ:=VDIR; V.Mnt:=M; V.Ino:=0; V.First:=0; V.Mode:=S_IFDIR Or $1ED;
 V.NLink:=2; V.MTime:=BootTime;
End;

Function ClusLBA(M: Integer; C: Longint): Longint;
Begin
 ClusLBA:=Mounts[M].DataLBA+(C-2)*Mounts[M].SecPerClus;
End;

Function FatGet(M: Integer; C: Longint): Longint;
Var Off,Sec: Longint; B: Integer; O,V: Word; Lo_,Hi_: Byte;
Begin
 FatGet:=FATEOC;
 With Mounts[M] Do Begin
  If (C<2) Or (C>Clusters+1) Then Exit;
  If Typ=FSFAT16 Then Begin
   Off:=C*2; B:=BRead(Drive,FatLBA+Off Div 512);
   If B=0 Then Exit;
   V:=MemW[BufSeg(B):Off Mod 512];
   If V>=$FFF8 Then FatGet:=FATEOC Else FatGet:=V;
  End Else Begin
   Off:=C+C Div 2; Sec:=FatLBA+Off Div 512; O:=Off Mod 512;
   B:=BRead(Drive,Sec); If B=0 Then Exit;
   Lo_:=Mem[BufSeg(B):O];
   If O=511 Then Begin
    B:=BRead(Drive,Sec+1); If B=0 Then Exit;
    Hi_:=Mem[BufSeg(B):0];
   End Else Hi_:=Mem[BufSeg(B):O+1];
   V:=Lo_+Word(Hi_) Shl 8;
   If Odd(C) Then V:=V Shr 4 Else V:=V And $FFF;
   If V>=$FF8 Then FatGet:=FATEOC Else FatGet:=V;
  End;
 End;
End;

Procedure FatSet(M: Integer; C, Val: Longint);
Var Off,Sec: Longint; B,K: Integer; O,V: Word; S: Word;
Begin
 With Mounts[M] Do Begin
  If (C<2) Or (C>Clusters+1) Then Exit;
  For K:=0 To NFats-1 Do Begin
   If Typ=FSFAT16 Then Begin
    Off:=C*2; B:=BRead(Drive,FatLBA+K*SecPerFat+Off Div 512);
    If B=0 Then Exit;
    MemW[BufSeg(B):Off Mod 512]:=Word(Val); BWrite(B);
   End Else Begin
    V:=Word(Val) And $FFF;
    Off:=C+C Div 2; Sec:=FatLBA+K*SecPerFat+Off Div 512; O:=Off Mod 512;
    B:=BRead(Drive,Sec); If B=0 Then Exit;
    S:=BufSeg(B);
    If Odd(C) Then Mem[S:O]:=(Mem[S:O] And $0F) Or Lo(V Shl 4)
    Else Mem[S:O]:=Lo(V);
    If O=511 Then Begin
     BWrite(B);
     B:=BRead(Drive,Sec+1); If B=0 Then Exit;
     S:=BufSeg(B); O:=0;
    End Else Inc(O);
    If Odd(C) Then Mem[S:O]:=Hi(V Shl 4)
    Else Mem[S:O]:=(Mem[S:O] And $F0) Or Hi(V);
    BWrite(B);
   End;
  End;
 End;
End;

Function FatAlloc(M: Integer): Longint;
{ cluster libre marque fin de chaine, 0 si le disque est plein }
Var C,N: Longint;
Begin
 FatAlloc:=0;
 With Mounts[M] Do Begin
  C:=FreeHint; If (C<2) Or (C>Clusters+1) Then C:=2;
  For N:=1 To Clusters Do Begin
   If FatGet(M,C)=0 Then Begin
    FatSet(M,C,FATEOC); FreeHint:=C+1; FatAlloc:=C; Exit;
   End;
   Inc(C); If C>Clusters+1 Then C:=2;
  End;
 End;
End;

Procedure FreeChain(M: Integer; C: Longint);
Var N: Longint; K: Longint;
Begin
 K:=0;
 While (C>=2) And (C<>FATEOC) And (K<=Mounts[M].Clusters) Do Begin
  N:=FatGet(M,C); FatSet(M,C,0);
  If C<Mounts[M].FreeHint Then Mounts[M].FreeHint:=C;
  C:=N; Inc(K);
 End;
End;

Function FatFreeKB(M: Integer): Longint;
Var C,N: Longint;
Begin
 N:=0;
 For C:=2 To Mounts[M].Clusters+1 Do If FatGet(M,C)=0 Then Inc(N);
 FatFreeKB:=N*Mounts[M].SecPerClus Div 2;
End;

Procedure ZeroCluster(M: Integer; C: Longint);
Var I: Integer; B: Integer;
Begin
 For I:=0 To Mounts[M].SecPerClus-1 Do Begin
  B:=BGet(Mounts[M].Drive,ClusLBA(M,C)+I);
  FarFill(BufSeg(B),0,512,0); BWrite(B);
 End;
End;

Function DirSector(Var D: TVNode; Index: Longint; Grow: Boolean;
  Var LBA: Longint; Var Idx: Word): Boolean;
{ secteur et position de l'entree Index du repertoire D }
Var Sec,CI,K,C,N: Longint; M: Integer;
Begin
 DirSector:=False; M:=D.Mnt;
 Idx:=Index Mod 16; Sec:=Index Div 16;
 With Mounts[M] Do
 If D.First=0 Then Begin
  If Index>=RootEnt Then Exit;
  LBA:=RootLBA+Sec;
 End Else Begin
  CI:=Sec Div SecPerClus; C:=D.First; K:=0;
  While K<CI Do Begin
   N:=FatGet(M,C);
   If (N<2) Or (N=FATEOC) Then Begin
    If Not Grow Then Exit;
    N:=FatAlloc(M); If N=0 Then Exit;
    ZeroCluster(M,N); FatSet(M,C,N);
   End;
   C:=N; Inc(K);
  End;
  LBA:=ClusLBA(M,C)+Sec Mod SecPerClus;
 End;
 DirSector:=True;
End;

Function To83(Name: TName; Var R: String): Boolean;
Var I,P: Integer; B,E: String;
Begin
 To83:=False;
 If (Name='') Or (Name='.') Or (Name='..') Then Begin
  If Name='.' Then R:='.          ' Else If Name='..' Then R:='..         '
  Else Exit;
  To83:=True; Exit;
 End;
 Name:=UpStr(Name);
 P:=0; For I:=Length(Name) DownTo 2 Do If Name[I]='.' Then Begin P:=I; Break End;
 If P>0 Then Begin B:=Copy(Name,1,P-1); E:=Copy(Name,P+1,255) End
 Else Begin B:=Name; E:='' End;
 If (Length(B)>8) Or (Length(E)>3) Or (B='') Then Exit;
 For I:=1 To Length(B) Do If B[I] In ['.',' ','"','*','+',',','/',':',';',
   '<','=','>','?','[','\',']','|'] Then Exit;
 For I:=1 To Length(E) Do If E[I] In ['.',' ','"','*','+',',','/',':',';',
   '<','=','>','?','[','\',']','|'] Then Exit;
 While Length(B)<8 Do B:=B+' ';
 While Length(E)<3 Do E:=E+' ';
 R:=B+E; To83:=True;
End;

Function From83(Sg, Os: Word): TName;
Var B,E: String; I: Integer;
Begin
 B:=''; E:='';
 For I:=0 To 7 Do B:=B+Chr(Mem[Sg:Os+I]);
 For I:=8 To 10 Do E:=E+Chr(Mem[Sg:Os+I]);
 While (B<>'') And (B[Length(B)]=' ') Do Dec(B[0]);
 While (E<>'') And (E[Length(E)]=' ') Do Dec(E[0]);
 If B[1]=#5 Then B[1]:=#$E5;
 If E<>'' Then B:=B+'.'+E;
 From83:=LowStr(B);
End;

Procedure FillVn(M: Integer; Sg, Os: Word; LBA: Longint; Idx: Word;
  Var V: TVNode);
Var A: Byte;
Begin
 FillChar(V,SizeOf(V),0);
 A:=Mem[Sg:Os+11];
 V.Mnt:=M; V.First:=MemW[Sg:Os+26]; V.Size:=MemL[Sg:Os+28];
 V.DirLBA:=LBA; V.DirIdx:=Idx; V.Ino:=LBA*16+Idx;
 V.MTime:=UnixStamp(MemW[Sg:Os+24],MemW[Sg:Os+22]);
 If A And $10<>0 Then Begin
  V.Typ:=VDIR; V.Mode:=S_IFDIR Or $1ED; V.NLink:=2; V.Size:=0;
 End Else Begin
  V.Typ:=VREG; V.Mode:=S_IFREG Or $1ED; V.NLink:=1;
 End;
 If A And 1<>0 Then V.Mode:=V.Mode And Not $92;
End;

Function Search(Var Dir: TVNode; N83: String; Var LBA: Longint;
  Var Idx: Word): Boolean;
Var I: Longint; B: Integer; S,O: Word; K: Integer; Ok: Boolean; A: Byte;
Begin
 Search:=False; I:=0;
 While DirSector(Dir,I,False,LBA,Idx) Do Begin
  B:=BRead(Mounts[Dir.Mnt].Drive,LBA);
  If B=0 Then Exit;
  S:=BufSeg(B); O:=Idx*32;
  If Mem[S:O]=0 Then Exit;
  A:=Mem[S:O+11];
  If (Mem[S:O]<>$E5) And (A<>$0F) And (A And 8=0) Then Begin
   Ok:=True;
   For K:=0 To 10 Do If Mem[S:O+K]<>Ord(N83[K+1]) Then Begin
    Ok:=False; Break;
   End;
   If Ok Then Begin Search:=True; Exit End;
  End;
  Inc(I);
 End;
End;

Function FatLookup(Var Dir: TVNode; Name: TName; Var V: TVNode): Integer;
Var N83: String; LBA,C: Longint; Idx: Word; B: Integer;
Begin
 If Not To83(Name,N83) Then Begin FatLookup:=ENOENT; Exit End;
 If Not Search(Dir,N83,LBA,Idx) Then Begin FatLookup:=ENOENT; Exit End;
 B:=BRead(Mounts[Dir.Mnt].Drive,LBA);
 If B=0 Then Begin FatLookup:=EIO; Exit End;
 FillVn(Dir.Mnt,BufSeg(B),Idx*32,LBA,Idx,V);
 { ".." vers la racine (cluster 0) }
 If (V.Typ=VDIR) And (V.First=0) Then FatRoot(Dir.Mnt,V);
 FatLookup:=0;
End;

Function ClusterAt(Var V: TVNode; Idx: Longint): Longint;
Var C,I: Longint;
Begin
 If (V.CClus>=2) And (Idx>=V.CIdx) Then Begin C:=V.CClus; I:=V.CIdx End
 Else Begin C:=V.First; I:=0 End;
 While (I<Idx) And (C>=2) And (C<>FATEOC) Do Begin
  C:=FatGet(V.Mnt,C); Inc(I);
 End;
 If (C<2) Or (C=FATEOC) Then Begin ClusterAt:=0; Exit End;
 V.CIdx:=Idx; V.CClus:=C;
 ClusterAt:=C;
End;

Function FatRead(Var V: TVNode; Off: Longint; Sg, Os, N: Word): Integer;
Var Done,Chunk,O: Word; CB: Longint; C: Longint; B: Integer; M: Integer;
Begin
 FatRead:=0;
 If Off>=V.Size Then Exit;
 If Off+N>V.Size Then N:=V.Size-Off;
 M:=V.Mnt; CB:=Longint(Mounts[M].SecPerClus)*512; Done:=0;
 While Done<N Do Begin
  C:=ClusterAt(V,Off Div CB);
  If C=0 Then Break;
  O:=Off Mod 512; Chunk:=512-O; If Chunk>N-Done Then Chunk:=N-Done;
  B:=BRead(Mounts[M].Drive,ClusLBA(M,C)+(Off Mod CB) Div 512);
  If B=0 Then Begin FatRead:=-EIO; Exit End;
  FarMove(BufSeg(B),O,Sg,Os+Done,Chunk);
  Inc(Done,Chunk); Inc(Off,Chunk);
 End;
 FatRead:=Done;
End;

Procedure FatUpdate(Var V: TVNode);
Var B: Integer; S,O: Word; T: Longint;
Begin
 If (V.Ino=0) Or (V.Typ<>VREG) Then Exit;
 B:=BRead(Mounts[V.Mnt].Drive,V.DirLBA);
 If B=0 Then Exit;
 S:=BufSeg(B); O:=V.DirIdx*32;
 MemW[S:O+26]:=Word(V.First); MemL[S:O+28]:=V.Size;
 T:=DosStamp(V.MTime);
 MemW[S:O+22]:=Word(T); MemW[S:O+24]:=Word(T Shr 16);
 MemW[S:O+18]:=Word(T Shr 16);
 BWrite(B);
 V.Dirty:=False;
End;

Function Extend(Var V: TVNode; Idx: Longint): Longint;
{ cluster numero Idx du fichier, alloue si besoin }
Var C,N,I: Longint;
Begin
 Extend:=0;
 If V.First<2 Then Begin
  N:=FatAlloc(V.Mnt); If N=0 Then Exit;
  V.First:=N; V.CIdx:=0; V.CClus:=N; V.Dirty:=True;
 End;
 C:=ClusterAt(V,Idx);
 If C<>0 Then Begin Extend:=C; Exit End;
 { aller a la fin de la chaine }
 C:=V.First; I:=0;
 While True Do Begin
  N:=FatGet(V.Mnt,C);
  If (N<2) Or (N=FATEOC) Then Break;
  C:=N; Inc(I);
 End;
 While I<Idx Do Begin
  N:=FatAlloc(V.Mnt); If N=0 Then Exit;
  FatSet(V.Mnt,C,N); C:=N; Inc(I);
 End;
 V.CIdx:=Idx; V.CClus:=C;
 Extend:=C;
End;

Function FatWrite(Var V: TVNode; Off: Longint; Sg, Os, N: Word): Integer;
Var Done,Chunk,O: Word; CB: Longint; C: Longint; B: Integer; M: Integer;
  Pad: Longint;
Begin
 M:=V.Mnt; CB:=Longint(Mounts[M].SecPerClus)*512;
 If Mounts[M].RO Then Begin FatWrite:=-EROFS; Exit End;
 { trou : rempli de zeros }
 While V.Size<Off Do Begin
  Pad:=Off-V.Size; If Pad>512 Then Pad:=512;
  C:=FatWrite(V,V.Size,Seg(ZeroBuf),Ofs(ZeroBuf),Pad);
  If C<=0 Then Begin FatWrite:=C; Exit End;
 End;
 Done:=0;
 While Done<N Do Begin
  C:=Extend(V,Off Div CB);
  If C=0 Then Begin
   If Done=0 Then Begin FatWrite:=-ENOSPC; Exit End;
   Break;
  End;
  O:=Off Mod 512; Chunk:=512-O; If Chunk>N-Done Then Chunk:=N-Done;
  If (O=0) And ((Chunk=512) Or (Off+Chunk>=V.Size)) Then Begin
   B:=BGet(Mounts[M].Drive,ClusLBA(M,C)+(Off Mod CB) Div 512);
   If Chunk<512 Then FarFill(BufSeg(B),0,512,0);
  End Else B:=BRead(Mounts[M].Drive,ClusLBA(M,C)+(Off Mod CB) Div 512);
  If B=0 Then Begin FatWrite:=-EIO; Exit End;
  FarMove(Sg,Os+Done,BufSeg(B),O,Chunk);
  If Not BWrite(B) Then Begin FatWrite:=-EIO; Exit End;
  Inc(Done,Chunk); Inc(Off,Chunk);
  If Off>V.Size Then V.Size:=Off;
 End;
 V.MTime:=KTime;
 FatUpdate(V);
 FatWrite:=Done;
End;

Function FatTrunc(Var V: TVNode): Integer;
Begin
 FatTrunc:=0;
 If V.Typ<>VREG Then Exit;
 If Mounts[V.Mnt].RO Then Begin FatTrunc:=EROFS; Exit End;
 FreeChain(V.Mnt,V.First);
 V.First:=0; V.Size:=0; V.CIdx:=0; V.CClus:=0; V.MTime:=KTime;
 FatUpdate(V);
End;

Function FatReadDir(Var V: TVNode; Var Pos: Longint; Var Name: TName;
  Var Ino: Longint; Var Typ: Byte): Boolean;
Var LBA: Longint; Idx: Word; B: Integer; S,O: Word; A: Byte;
Begin
 FatReadDir:=False;
 While DirSector(V,Pos,False,LBA,Idx) Do Begin
  B:=BRead(Mounts[V.Mnt].Drive,LBA);
  If B=0 Then Exit;
  S:=BufSeg(B); O:=Idx*32;
  If Mem[S:O]=0 Then Exit;
  Inc(Pos);
  A:=Mem[S:O+11];
  If (Mem[S:O]<>$E5) And (A<>$0F) And (A And 8=0) Then Begin
   Name:=From83(S,O); Ino:=LBA*16+Idx;
   If A And $10<>0 Then Typ:=VDIR Else Typ:=VREG;
   FatReadDir:=True; Exit;
  End;
 End;
End;

Function FreeSlot(Var Dir: TVNode; Var LBA: Longint; Var Idx: Word): Boolean;
Var I: Longint; B: Integer; S: Word;
Begin
 FreeSlot:=False; I:=0;
 While DirSector(Dir,I,Dir.First<>0,LBA,Idx) Do Begin
  B:=BRead(Mounts[Dir.Mnt].Drive,LBA);
  If B=0 Then Exit;
  S:=BufSeg(B);
  If (Mem[S:Idx*32]=0) Or (Mem[S:Idx*32]=$E5) Then Begin
   FreeSlot:=True; Exit;
  End;
  Inc(I);
  If I>65535 Then Exit;
 End;
End;

Procedure PutEntry(S, O: Word; N83: String; Attr: Byte; First: Longint);
Var I: Integer; T: Longint;
Begin
 FarFill(S,O,32,0);
 For I:=0 To 10 Do Mem[S:O+I]:=Ord(N83[I+1]);
 Mem[S:O+11]:=Attr;
 T:=DosStamp(KTime);
 MemW[S:O+14]:=Word(T); MemW[S:O+16]:=Word(T Shr 16);
 MemW[S:O+18]:=Word(T Shr 16);
 MemW[S:O+22]:=Word(T); MemW[S:O+24]:=Word(T Shr 16);
 MemW[S:O+26]:=Word(First);
End;

Function FatCreate(Var Dir: TVNode; Name: TName; IsDir: Boolean;
  Var V: TVNode): Integer;
Var N83: String; LBA,C: Longint; Idx: Word; B: Integer; S: Word;
Begin
 If Mounts[Dir.Mnt].RO Then Begin FatCreate:=EROFS; Exit End;
 If Not To83(Name,N83) Or (Name='.') Or (Name='..') Then Begin
  FatCreate:=ENAMETOOLONG; Exit;
 End;
 If Search(Dir,N83,LBA,Idx) Then Begin FatCreate:=EEXIST; Exit End;
 If Not FreeSlot(Dir,LBA,Idx) Then Begin FatCreate:=ENOSPC; Exit End;
 C:=0;
 If IsDir Then Begin
  C:=FatAlloc(Dir.Mnt);
  If C=0 Then Begin FatCreate:=ENOSPC; Exit End;
  ZeroCluster(Dir.Mnt,C);
  B:=BRead(Mounts[Dir.Mnt].Drive,ClusLBA(Dir.Mnt,C));
  If B=0 Then Begin FatCreate:=EIO; Exit End;
  PutEntry(BufSeg(B),0,'.          ',$10,C);
  PutEntry(BufSeg(B),32,'..         ',$10,Dir.First);
  BWrite(B);
 End;
 B:=BRead(Mounts[Dir.Mnt].Drive,LBA);
 If B=0 Then Begin FatCreate:=EIO; Exit End;
 S:=BufSeg(B);
 If IsDir Then PutEntry(S,Idx*32,N83,$10,C) Else PutEntry(S,Idx*32,N83,$20,0);
 If Not BWrite(B) Then Begin FatCreate:=EIO; Exit End;
 FillVn(Dir.Mnt,S,Idx*32,LBA,Idx,V);
 FatCreate:=0;
End;

Function DirEmpty(Var D: TVNode): Boolean;
Var Pos,Ino: Longint; Name: TName; Typ: Byte;
Begin
 DirEmpty:=True; Pos:=0;
 While FatReadDir(D,Pos,Name,Ino,Typ) Do
  If (Name<>'.') And (Name<>'..') Then Begin DirEmpty:=False; Exit End;
End;

Function FatRemove(Var Dir: TVNode; Name: TName; IsDir: Boolean): Integer;
Var N83: String; LBA: Longint; Idx: Word; B: Integer; V: TVNode;
Begin
 If Mounts[Dir.Mnt].RO Then Begin FatRemove:=EROFS; Exit End;
 If (Name='.') Or (Name='..') Then Begin FatRemove:=EINVAL; Exit End;
 If Not To83(Name,N83) Then Begin FatRemove:=ENOENT; Exit End;
 If Not Search(Dir,N83,LBA,Idx) Then Begin FatRemove:=ENOENT; Exit End;
 B:=BRead(Mounts[Dir.Mnt].Drive,LBA);
 If B=0 Then Begin FatRemove:=EIO; Exit End;
 FillVn(Dir.Mnt,BufSeg(B),Idx*32,LBA,Idx,V);
 If IsDir And (V.Typ<>VDIR) Then Begin FatRemove:=ENOTDIR; Exit End;
 If Not IsDir And (V.Typ=VDIR) Then Begin FatRemove:=EISDIR; Exit End;
 If IsDir And Not DirEmpty(V) Then Begin FatRemove:=ENOTEMPTY; Exit End;
 FreeChain(Dir.Mnt,V.First);
 B:=BRead(Mounts[Dir.Mnt].Drive,LBA);
 If B=0 Then Begin FatRemove:=EIO; Exit End;
 Mem[BufSeg(B):Idx*32]:=$E5;
 BWrite(B);
 FatRemove:=0;
End;

Function FatRename(Var D1: TVNode; N1: TName; Var D2: TVNode;
  N2: TName): Integer;
Var A,B83: String; L1,L2: Longint; I1,I2: Word; B,E: Integer;
  Raw: Array[0..31] Of Byte; V: TVNode;
Begin
 If Mounts[D1.Mnt].RO Then Begin FatRename:=EROFS; Exit End;
 If Not To83(N1,A) Or Not Search(D1,A,L1,I1) Then Begin
  FatRename:=ENOENT; Exit;
 End;
 If Not To83(N2,B83) Then Begin FatRename:=ENAMETOOLONG; Exit End;
 If Search(D2,B83,L2,I2) Then Begin
  E:=FatRemove(D2,N2,False);
  If E<>0 Then Begin FatRename:=EEXIST; Exit End;
  If Not Search(D1,A,L1,I1) Then Begin FatRename:=ENOENT; Exit End;
 End;
 B:=BRead(Mounts[D1.Mnt].Drive,L1);
 If B=0 Then Begin FatRename:=EIO; Exit End;
 FarMove(BufSeg(B),I1*32,Seg(Raw),Ofs(Raw),32);
 If Not FreeSlot(D2,L2,I2) Then Begin FatRename:=ENOSPC; Exit End;
 B:=BRead(Mounts[D1.Mnt].Drive,L2);
 If B=0 Then Begin FatRename:=EIO; Exit End;
 FarMove(Seg(Raw),Ofs(Raw),BufSeg(B),I2*32,32);
 For E:=0 To 10 Do Mem[BufSeg(B):I2*32+E]:=Ord(B83[E+1]);
 BWrite(B);
 B:=BRead(Mounts[D1.Mnt].Drive,L1);
 If B=0 Then Begin FatRename:=EIO; Exit End;
 Mem[BufSeg(B):I1*32]:=$E5;
 BWrite(B);
 { repertoire deplace : mise a jour de ".." }
 If (Raw[11] And $10<>0) And (D1.First<>D2.First) Then Begin
  V.Mnt:=D1.Mnt;
  B:=BRead(Mounts[D1.Mnt].Drive,ClusLBA(D1.Mnt,Raw[26]+Word(Raw[27]) Shl 8));
  If B<>0 Then Begin
   MemW[BufSeg(B):32+26]:=Word(D2.First); BWrite(B);
  End;
 End;
 FatRename:=0;
End;

SegmentEnd;

{ ====================================================================== }
SegmentUnit KUfs;
{ Systeme de fichiers UFS1 (Unix File System de FreeBSD, "makefs -t ffs",
  "newfs -O 1") : superbloc a l'octet 8192, groupes de cylindres, inodes de
  128 octets, blocs et fragments, blocs indirects simples et doubles,
  repertoires a entrees de longueur variable (d_type). En ecriture, les
  blocs sont alloues entiers puis le dernier bloc direct est ramene au
  nombre de fragments necessaire (regle de FFS) a la fermeture; les cartes
  des blocs libres, des grappes (clusters), les resumes frsum et les
  compteurs (groupe, table csum, superbloc) sont tenus a jour. }
Uses KTypes,KLib,KDisk;
SegmentInterface

Const UFSMAGIC=$011954; ROOTINO=2;

Function UfsMount(M: Integer): Integer;
Function UfsIGet(M: Integer; Ino: Longint; Var V: TVNode): Integer;
Function UfsLookup(Var Dir: TVNode; Name: TName; Var V: TVNode): Integer;
Function UfsRead(Var V: TVNode; Off: Longint; Sg, Os, N: Word): Integer;
Function UfsWrite(Var V: TVNode; Off: Longint; Sg, Os, N: Word): Integer;
Function UfsTrunc(Var V: TVNode): Integer;
Procedure UfsClose(Var V: TVNode);
Function UfsReadDir(Var V: TVNode; Var Pos: Longint; Var Name: TName;
  Var Ino: Longint; Var Typ: Byte): Boolean;
Function UfsCreate(Var Dir: TVNode; Name: TName; IsDir: Boolean;
  Var V: TVNode): Integer;
Function UfsRemove(Var Dir: TVNode; Name: TName; IsDir: Boolean): Integer;
Function UfsRename(Var D1: TVNode; N1: TName; Var D2: TVNode;
  N2: TName): Integer;
Function UfsLink(Var Dir: TVNode; Name: TName; Var V: TVNode): Integer;
Function UfsChmod(Var V: TVNode; Mode: Word): Integer;
Function UfsFreeKB(M: Integer): Longint;

SegmentImplementation

Var
 DirBuf: Array[0..511] Of Byte;
 GenCount: Longint;

{ --- acces au disque ------------------------------------------------- }

Function FragLBA(M: Integer; F: Longint): Longint;
Begin
 FragLBA:=F Shl Mounts[M].FsbToDb;
End;

Function SbGetL(M: Integer; Off: Word): Longint;
Var B: Integer;
Begin
 SbGetL:=0;
 B:=BRead(Mounts[M].Drive,16+Off Div 512);
 If B<>0 Then SbGetL:=MemL[BufSeg(B):Off Mod 512];
End;

Procedure SbAddL(M: Integer; Off: Word; D: Longint);
Var B: Integer;
Begin
 B:=BRead(Mounts[M].Drive,16+Off Div 512);
 If B=0 Then Exit;
 MemL[BufSeg(B):Off Mod 512]:=MemL[BufSeg(B):Off Mod 512]+D;
 BWrite(B);
End;

Function CgStart(M: Integer; Cg: Longint): Longint;
Begin
 With Mounts[M] Do CgStart:=Fpg*Cg+CgOffset*(Cg And Not CgMask);
End;

Function CgLBA(M: Integer; Cg: Longint; Off: Word): Longint;
Begin
 CgLBA:=FragLBA(M,CgStart(M,Cg)+Mounts[M].Cblkno)+Off Div 512;
End;

Function CgGetL(M: Integer; Cg: Longint; Off: Word): Longint;
Var B: Integer;
Begin
 CgGetL:=0;
 B:=BRead(Mounts[M].Drive,CgLBA(M,Cg,Off));
 If B<>0 Then CgGetL:=MemL[BufSeg(B):Off Mod 512];
End;

Procedure CgPutL(M: Integer; Cg: Longint; Off: Word; L: Longint);
Var B: Integer;
Begin
 B:=BRead(Mounts[M].Drive,CgLBA(M,Cg,Off));
 If B=0 Then Exit;
 MemL[BufSeg(B):Off Mod 512]:=L; BWrite(B);
End;

Function CgGetB(M: Integer; Cg: Longint; Off: Word): Byte;
Var B: Integer;
Begin
 CgGetB:=0;
 B:=BRead(Mounts[M].Drive,CgLBA(M,Cg,Off));
 If B<>0 Then CgGetB:=Mem[BufSeg(B):Off Mod 512];
End;

Procedure CgPutB(M: Integer; Cg: Longint; Off: Word; V: Byte);
Var B: Integer;
Begin
 B:=BRead(Mounts[M].Drive,CgLBA(M,Cg,Off));
 If B=0 Then Exit;
 Mem[BufSeg(B):Off Mod 512]:=V; BWrite(B);
End;

Function CgBit(M: Integer; Cg: Longint; MapOff: Word; Bit: Longint): Boolean;
Begin
 CgBit:=CgGetB(M,Cg,MapOff+Bit Div 8) And (1 Shl (Bit Mod 8))<>0;
End;

Procedure CgSetBit(M: Integer; Cg: Longint; MapOff: Word; Bit: Longint;
  On: Boolean);
Var V: Byte; O: Word;
Begin
 O:=MapOff+Bit Div 8;
 V:=CgGetB(M,Cg,O);
 If On Then V:=V Or (1 Shl (Bit Mod 8)) Else V:=V And Not (1 Shl (Bit Mod 8));
 CgPutB(M,Cg,O,V);
End;

Procedure Account(M: Integer; Cg: Longint; Field: Integer; D: Longint);
{ Field : 0 ndir, 1 nbfree, 2 nifree, 3 nffree. Groupe, table csum et
  superbloc (UFS1 32 bits et copie 64 bits). }
Var B: Integer; Off: Longint;
Begin
 CgPutL(M,Cg,24+Field*4,CgGetL(M,Cg,24+Field*4)+D);
 Off:=Cg*16+Field*4;
 B:=BRead(Mounts[M].Drive,FragLBA(M,Mounts[M].CsAddr)+Off Div 512);
 If B<>0 Then Begin
  MemL[BufSeg(B):Off Mod 512]:=MemL[BufSeg(B):Off Mod 512]+D; BWrite(B);
 End;
 SbAddL(M,192+Field*4,D);
 SbAddL(M,1008+Field*8,D);
End;

{ --- montage --------------------------------------------------------- }

Function UfsMount(M: Integer): Integer;
Var B: Integer; S: Word;
Begin
 UfsMount:=EIO;
 B:=BRead(Mounts[M].Drive,18);
 If B=0 Then Exit;
 UfsMount:=EINVAL;
 If MemL[BufSeg(B):1372-1024]<>UFSMAGIC Then Exit;
 B:=BRead(Mounts[M].Drive,16);
 If B=0 Then Begin UfsMount:=EIO; Exit End;
 S:=BufSeg(B);
 With Mounts[M] Do Begin
  Cblkno:=MemL[S:12]; Iblkno:=MemL[S:16]; Dblkno:=MemL[S:20];
  CgOffset:=MemL[S:24]; CgMask:=MemL[S:28];
  Sectors:=MemL[S:36];
  Ncg:=MemL[S:44]; BSize:=MemL[S:48]; FSize:=MemL[S:52]; Frag:=MemL[S:56];
  FsbToDb:=MemL[S:100]; Nindir:=MemL[S:116]; Inopb:=MemL[S:120];
  CsAddr:=MemL[S:152]; CgSize:=MemL[S:160];
  Ipg:=MemL[S:184]; Fpg:=MemL[S:188];
  If (BSize<4096) Or (FSize<512) Or (Frag<1) Or (Frag>8) Or (Ncg<1) Then Exit;
  Sectors:=Sectors Shl FsbToDb;
  Typ:=FSUFS;
 End;
 UfsMount:=0;
End;

Function UfsFreeKB(M: Integer): Longint;
Begin
 With Mounts[M] Do
  UfsFreeKB:=SbGetL(M,196)*(BSize Div 1024)+SbGetL(M,204)*(FSize Div 1024);
End;

{ --- inodes ---------------------------------------------------------- }

Procedure ILoc(M: Integer; Ino: Longint; Var LBA: Longint; Var Off: Word);
Var Cg,F,BO: Longint;
Begin
 With Mounts[M] Do Begin
  Cg:=Ino Div Ipg;
  F:=CgStart(M,Cg)+Iblkno+((Ino Mod Ipg) Div Inopb)*Frag;
  BO:=(Ino Mod Inopb)*128;
  LBA:=FragLBA(M,F)+BO Div 512; Off:=BO Mod 512;
 End;
End;

Function IGetL(Var V: TVNode; Field: Word): Longint;
Var LBA: Longint; O: Word; B: Integer;
Begin
 IGetL:=0;
 ILoc(V.Mnt,V.Ino,LBA,O);
 B:=BRead(Mounts[V.Mnt].Drive,LBA);
 If B<>0 Then IGetL:=MemL[BufSeg(B):O+Field];
End;

Procedure IPutL(Var V: TVNode; Field: Word; L: Longint);
Var LBA: Longint; O: Word; B: Integer;
Begin
 ILoc(V.Mnt,V.Ino,LBA,O);
 B:=BRead(Mounts[V.Mnt].Drive,LBA);
 If B=0 Then Exit;
 MemL[BufSeg(B):O+Field]:=L; BWrite(B);
End;

Procedure IUpdate(Var V: TVNode);
{ taille, mode, liens et dates de V dans l'inode }
Var LBA: Longint; O: Word; B: Integer; S: Word;
Begin
 ILoc(V.Mnt,V.Ino,LBA,O);
 B:=BRead(Mounts[V.Mnt].Drive,LBA);
 If B=0 Then Exit;
 S:=BufSeg(B);
 MemW[S:O]:=V.Mode; MemW[S:O+2]:=V.NLink;
 MemL[S:O+8]:=V.Size; MemL[S:O+12]:=0;
 MemL[S:O+24]:=V.MTime; MemL[S:O+32]:=V.MTime;
 BWrite(B);
End;

Function UfsIGet(M: Integer; Ino: Longint; Var V: TVNode): Integer;
Var LBA: Longint; O: Word; B: Integer; S: Word;
Begin
 UfsIGet:=EIO;
 FillChar(V,SizeOf(V),0);
 V.Mnt:=M; V.Ino:=Ino;
 If (Ino<2) Or (Ino>=Mounts[M].Ipg*Mounts[M].Ncg) Then Begin
  UfsIGet:=ENOENT; Exit;
 End;
 ILoc(M,Ino,LBA,O);
 B:=BRead(Mounts[M].Drive,LBA);
 If B=0 Then Exit;
 S:=BufSeg(B);
 V.Mode:=MemW[S:O]; V.NLink:=MemW[S:O+2];
 V.Size:=MemL[S:O+8]; V.MTime:=MemL[S:O+24];
 Case V.Mode And S_IFMT Of
  S_IFDIR: V.Typ:=VDIR;
  S_IFREG: V.Typ:=VREG;
  S_IFCHR: V.Typ:=VCHR;
  S_IFIFO: V.Typ:=VFIFO;
  Else V.Typ:=VREG;
 End;
 UfsIGet:=0;
End;

{ --- allocation des blocs, fragments et inodes ----------------------- }

Procedure FragAcct(M: Integer; Cg: Longint; Map: Byte; Cnt: Integer);
{ resume frsum : chaque suite de fragments libres de longueur L (< Frag)
  dans le bloc decrit par Map }
Var I,L: Integer; F: Integer;
Begin
 F:=Mounts[M].Frag; L:=0;
 For I:=0 To F Do Begin
  If (I<F) And (Map And (1 Shl I)<>0) Then Inc(L)
  Else Begin
   If (L>0) And (L<F) Then CgPutL(M,Cg,52+L*4,CgGetL(M,Cg,52+L*4)+Cnt);
   L:=0;
  End;
 End;
End;

Procedure ClusterAcct(M: Integer; Cg, Blk: Longint; Cnt: Integer);
{ carte et resume des grappes de blocs libres (ffs_clusteracct) }
Var COff,SOff: Word; NBlk,I,Fwd,Back,Sz: Longint;
Begin
 If CgGetL(M,Cg,112)=0 Then Exit;
 SOff:=CgGetL(M,Cg,104); COff:=CgGetL(M,Cg,108);
 NBlk:=CgGetL(M,Cg,112);
 Sz:=SbGetL(M,1316);
 If Sz<=0 Then Exit;
 CgSetBit(M,Cg,COff,Blk,Cnt>0);
 Fwd:=0; I:=Blk+1;
 While (I<NBlk) And (Fwd<Sz) And CgBit(M,Cg,COff,I) Do Begin Inc(Fwd); Inc(I) End;
 Back:=0; I:=Blk-1;
 While (I>=0) And (Back<Sz) And CgBit(M,Cg,COff,I) Do Begin Inc(Back); Dec(I) End;
 I:=Back+Fwd+1; If I>Sz Then I:=Sz;
 CgPutL(M,Cg,SOff+I*4,CgGetL(M,Cg,SOff+I*4)+Cnt);
 If Back>0 Then CgPutL(M,Cg,SOff+Back*4,CgGetL(M,Cg,SOff+Back*4)-Cnt);
 If Fwd>0 Then CgPutL(M,Cg,SOff+Fwd*4,CgGetL(M,Cg,SOff+Fwd*4)-Cnt);
End;

Function BlockMap(M: Integer; Cg, Bno: Longint; FreeOff: Word): Byte;
{ bits des fragments du bloc commencant au fragment Bno (relatif au groupe) }
Var I: Integer; R: Byte;
Begin
 R:=0;
 For I:=0 To Mounts[M].Frag-1 Do
  If CgBit(M,Cg,FreeOff,Bno+I) Then R:=R Or (1 Shl I);
 BlockMap:=R;
End;

Function AllocBlock(M: Integer; Pref: Longint): Longint;
{ bloc entier libre (adresse en fragments), 0 si le disque est plein }
Var C,K,Bno,NB,FullB: Longint; FreeOff: Word; Map,Full: Byte; I: Integer;
Begin
 AllocBlock:=0;
 With Mounts[M] Do Begin
  Full:=(1 Shl Frag)-1;
  C:=Pref; If (C<0) Or (C>=Ncg) Then C:=0;
  For K:=1 To Ncg Do Begin
   If CgGetL(M,C,28)>0 Then Begin
    FreeOff:=CgGetL(M,C,96);
    NB:=CgGetL(M,C,20) Div Frag;
    For FullB:=0 To NB-1 Do Begin
     Bno:=FullB*Frag;
     If Frag=8 Then Map:=CgGetB(M,C,FreeOff+FullB)
     Else Map:=BlockMap(M,C,Bno,FreeOff);
     If Map=Full Then Begin
      For I:=0 To Frag-1 Do CgSetBit(M,C,FreeOff,Bno+I,False);
      Account(M,C,1,-1);
      ClusterAcct(M,C,FullB,-1);
      AllocBlock:=CgStart(M,C)-CgOffset*(C And Not CgMask)+Bno;
      Exit;
     End;
    End;
   End;
   Inc(C); If C>=Ncg Then C:=0;
  End;
 End;
End;

Procedure FreeFrags(M: Integer; Addr: Longint; Cnt: Integer);
{ libere Cnt fragments a partir de Addr (dans un meme bloc) }
Var C,Bno,BStart: Longint; FreeOff: Word; Before,After,Full: Byte; I: Integer;
Begin
 If (Addr<=0) Or (Cnt<=0) Then Exit;
 With Mounts[M] Do Begin
  C:=Addr Div Fpg; Bno:=Addr Mod Fpg; BStart:=Bno-Bno Mod Frag;
  FreeOff:=CgGetL(M,C,96);
  Full:=(1 Shl Frag)-1;
  Before:=BlockMap(M,C,BStart,FreeOff);
  If (Before<>0) And (Before<>Full) Then FragAcct(M,C,Before,-1);
  For I:=0 To Cnt-1 Do CgSetBit(M,C,FreeOff,Bno+I,True);
  After:=BlockMap(M,C,BStart,FreeOff);
  If Before=Full Then Exit; { deja libre (incoherence) }
  If Before<>0 Then Begin
   { le bloc contenait deja des fragments libres }
   Account(M,C,3,Cnt);
  End Else Account(M,C,3,Cnt);
  If After=Full Then Begin
   Account(M,C,3,-Frag); Account(M,C,1,1);
   ClusterAcct(M,C,BStart Div Frag,1);
  End Else FragAcct(M,C,After,1);
 End;
End;

Function AllocInode(M: Integer; IsDir: Boolean): Longint;
Var C,K,I: Longint; IOff: Word;
Begin
 AllocInode:=0;
 With Mounts[M] Do
  For K:=0 To Ncg-1 Do Begin
   C:=K;
   If CgGetL(M,C,32)>0 Then Begin
    IOff:=CgGetL(M,C,92);
    For I:=0 To Ipg-1 Do
     If ((C>0) Or (I>ROOTINO)) And Not CgBit(M,C,IOff,I) Then Begin
      CgSetBit(M,C,IOff,I,True);
      Account(M,C,2,-1);
      If IsDir Then Account(M,C,0,1);
      AllocInode:=C*Ipg+I;
      Exit;
     End;
   End;
  End;
End;

Procedure FreeInode(M: Integer; Ino: Longint; IsDir: Boolean);
Var C: Longint;
Begin
 With Mounts[M] Do Begin
  C:=Ino Div Ipg;
  CgSetBit(M,C,CgGetL(M,C,92),Ino Mod Ipg,False);
  Account(M,C,2,1);
  If IsDir Then Account(M,C,0,-1);
 End;
End;

{ --- correspondance blocs logiques -> fragments ---------------------- }

Function IndGet(M: Integer; Blk, Idx: Longint): Longint;
Var B: Integer;
Begin
 IndGet:=0;
 If Blk=0 Then Exit;
 B:=BRead(Mounts[M].Drive,FragLBA(M,Blk)+(Idx*4) Div 512);
 If B<>0 Then IndGet:=MemL[BufSeg(B):(Idx*4) Mod 512];
End;

Procedure IndPut(M: Integer; Blk, Idx, Val: Longint);
Var B: Integer;
Begin
 B:=BRead(Mounts[M].Drive,FragLBA(M,Blk)+(Idx*4) Div 512);
 If B=0 Then Exit;
 MemL[BufSeg(B):(Idx*4) Mod 512]:=Val; BWrite(B);
End;

Procedure ZeroBlock(M: Integer; Blk: Longint);
Var I: Integer; B: Integer;
Begin
 For I:=0 To (Mounts[M].BSize Div 512)-1 Do Begin
  B:=BGet(Mounts[M].Drive,FragLBA(M,Blk)+I);
  FarFill(BufSeg(B),0,512,0); BWrite(B);
 End;
End;

Function NewBlock(Var V: TVNode; Zero: Boolean): Longint;
Var A: Longint;
Begin
 A:=AllocBlock(V.Mnt,V.Ino Div Mounts[V.Mnt].Ipg);
 If A<>0 Then Begin
  If Zero Then ZeroBlock(V.Mnt,A);
  IPutL(V,104,IGetL(V,104)+Mounts[V.Mnt].BSize Div 512);
 End;
 NewBlock:=A;
End;

Function BMap(Var V: TVNode; Lbn: Longint; Alloc: Boolean): Longint;
{ fragment de debut du bloc logique Lbn (0 = trou) }
Var M: Integer; A,Ind,Ind2,L: Longint;
Begin
 BMap:=0; M:=V.Mnt;
 With Mounts[M] Do Begin
  If Lbn<12 Then Begin
   A:=IGetL(V,40+Lbn*4);
   If (A=0) And Alloc Then Begin
    A:=NewBlock(V,False); If A<>0 Then IPutL(V,40+Lbn*4,A);
   End;
   BMap:=A; Exit;
  End;
  L:=Lbn-12;
  If L<Nindir Then Begin
   Ind:=IGetL(V,88);
   If Ind=0 Then Begin
    If Not Alloc Then Exit;
    Ind:=NewBlock(V,True); If Ind=0 Then Exit;
    IPutL(V,88,Ind);
   End;
   A:=IndGet(M,Ind,L);
   If (A=0) And Alloc Then Begin
    A:=NewBlock(V,False); If A<>0 Then IndPut(M,Ind,L,A);
   End;
   BMap:=A; Exit;
  End;
  L:=L-Nindir;
  If L Div Nindir>=Nindir Then Exit;
  Ind2:=IGetL(V,92);
  If Ind2=0 Then Begin
   If Not Alloc Then Exit;
   Ind2:=NewBlock(V,True); If Ind2=0 Then Exit;
   IPutL(V,92,Ind2);
  End;
  Ind:=IndGet(M,Ind2,L Div Nindir);
  If Ind=0 Then Begin
   If Not Alloc Then Exit;
   Ind:=NewBlock(V,True); If Ind=0 Then Exit;
   IndPut(M,Ind2,L Div Nindir,Ind);
  End;
  A:=IndGet(M,Ind,L Mod Nindir);
  If (A=0) And Alloc Then Begin
   A:=NewBlock(V,False); If A<>0 Then IndPut(M,Ind,L Mod Nindir,A);
  End;
  BMap:=A;
 End;
End;

Function FragsOf(M: Integer; Size, Lbn: Longint): Longint;
{ fragments occupes par le bloc Lbn d'un fichier de Size octets (FFS) }
Var R: Longint;
Begin
 With Mounts[M] Do Begin
  If (Lbn>=12) Or ((Lbn+1)*BSize<=Size) Then Begin FragsOf:=Frag; Exit End;
  R:=Size-Lbn*BSize;
  If R<=0 Then FragsOf:=0 Else FragsOf:=(R+FSize-1) Div FSize;
 End;
End;

Function GrowTail(Var V: TVNode): Boolean;
{ le dernier bloc direct (fragments) devient un bloc entier; V.Dirty indique
  ensuite que tous les blocs du fichier sont entiers }
Var M: Integer; K,Old,New_,Cnt: Longint; I: Integer; B,B2: Integer;
Begin
 GrowTail:=True;
 M:=V.Mnt;
 If V.Dirty Then Exit;
 If V.Size=0 Then Begin V.Dirty:=True; Exit End;
 K:=(V.Size-1) Div Mounts[M].BSize;
 If K>=12 Then Begin V.Dirty:=True; Exit End;
 Cnt:=FragsOf(M,V.Size,K);
 If Cnt>=Mounts[M].Frag Then Begin V.Dirty:=True; Exit End;
 Old:=IGetL(V,40+K*4);
 If Old=0 Then Begin V.Dirty:=True; Exit End;
 New_:=AllocBlock(M,V.Ino Div Mounts[M].Ipg);
 If New_=0 Then Begin GrowTail:=False; Exit End;
 For I:=0 To (Cnt*Mounts[M].FSize) Div 512-1 Do Begin
  B:=BRead(Mounts[M].Drive,FragLBA(M,Old)+I);
  If B<>0 Then Begin
   B2:=BGet(Mounts[M].Drive,FragLBA(M,New_)+I);
   FarMove(BufSeg(B),0,BufSeg(B2),0,512); BWrite(B2);
  End;
 End;
 IPutL(V,40+K*4,New_);
 FreeFrags(M,Old,Cnt);
 IPutL(V,104,IGetL(V,104)+((Mounts[M].Frag-Cnt)*Mounts[M].FSize) Div 512);
 V.Dirty:=True;
End;

Procedure UfsClose(Var V: TVNode);
{ ramene le dernier bloc direct au nombre de fragments necessaire }
Var M: Integer; K,A,Cnt: Longint;
Begin
 If Not V.Dirty Then Exit;
 V.Dirty:=False;
 If V.Size=0 Then Exit;
 M:=V.Mnt;
 K:=(V.Size-1) Div Mounts[M].BSize;
 If K>=12 Then Exit;
 Cnt:=FragsOf(M,V.Size,K);
 A:=IGetL(V,40+K*4);
 If (A=0) Or (Cnt>=Mounts[M].Frag) Then Exit;
 FreeFrags(M,A+Cnt,Mounts[M].Frag-Cnt);
 IPutL(V,104,IGetL(V,104)-((Mounts[M].Frag-Cnt)*Mounts[M].FSize) Div 512);
End;

{ --- lecture et ecriture --------------------------------------------- }

Function UfsRead(Var V: TVNode; Off: Longint; Sg, Os, N: Word): Integer;
Var Done,Chunk,O: Word; A: Longint; B: Integer; M: Integer; BS: Longint;
Begin
 UfsRead:=0;
 If Off>=V.Size Then Exit;
 If Off+N>V.Size Then N:=V.Size-Off;
 M:=V.Mnt; BS:=Mounts[M].BSize; Done:=0;
 While Done<N Do Begin
  O:=Off Mod 512; Chunk:=512-O; If Chunk>N-Done Then Chunk:=N-Done;
  A:=BMap(V,Off Div BS,False);
  If A=0 Then FarFill(Sg,Os+Done,Chunk,0)
  Else Begin
   B:=BRead(Mounts[M].Drive,FragLBA(M,A)+(Off Mod BS) Div 512);
   If B=0 Then Begin UfsRead:=-EIO; Exit End;
   FarMove(BufSeg(B),O,Sg,Os+Done,Chunk);
  End;
  Inc(Done,Chunk); Inc(Off,Chunk);
 End;
 UfsRead:=Done;
End;

Function UfsWrite(Var V: TVNode; Off: Longint; Sg, Os, N: Word): Integer;
Var Done,Chunk,O: Word; A: Longint; B: Integer; M: Integer; BS,Pad: Longint;
  R: Integer;
Begin
 M:=V.Mnt; BS:=Mounts[M].BSize;
 If Mounts[M].RO Then Begin UfsWrite:=-EROFS; Exit End;
 If N=0 Then Begin UfsWrite:=0; Exit End;
 If Off+N>V.Size Then
  If Not GrowTail(V) Then Begin UfsWrite:=-ENOSPC; Exit End;
 While V.Size<Off Do Begin
  Pad:=Off-V.Size; If Pad>512 Then Pad:=512;
  R:=UfsWrite(V,V.Size,Seg(ZeroBuf),Ofs(ZeroBuf),Pad);
  If R<=0 Then Begin UfsWrite:=R; Exit End;
 End;
 Done:=0;
 While Done<N Do Begin
  A:=BMap(V,Off Div BS,True);
  If A=0 Then Begin
   If Done=0 Then Begin UfsWrite:=-ENOSPC; Exit End;
   Break;
  End;
  O:=Off Mod 512; Chunk:=512-O; If Chunk>N-Done Then Chunk:=N-Done;
  If (O=0) And ((Chunk=512) Or (Off+Chunk>=V.Size)) Then Begin
   B:=BGet(Mounts[M].Drive,FragLBA(M,A)+(Off Mod BS) Div 512);
   If Chunk<512 Then FarFill(BufSeg(B),0,512,0);
  End Else B:=BRead(Mounts[M].Drive,FragLBA(M,A)+(Off Mod BS) Div 512);
  If B=0 Then Begin UfsWrite:=-EIO; Exit End;
  FarMove(Sg,Os+Done,BufSeg(B),O,Chunk);
  If Not BWrite(B) Then Begin UfsWrite:=-EIO; Exit End;
  Inc(Done,Chunk); Inc(Off,Chunk);
  If Off>V.Size Then V.Size:=Off;
 End;
 V.MTime:=KTime;
 IUpdate(V);
 UfsWrite:=Done;
End;

Function UfsTrunc(Var V: TVNode): Integer;
Var M: Integer; I,J,A,Ind,Ind2: Longint;
Begin
 UfsTrunc:=0; M:=V.Mnt;
 If Mounts[M].RO Then Begin UfsTrunc:=EROFS; Exit End;
 If V.Typ<>VREG Then Exit;
 With Mounts[M] Do Begin
  For I:=0 To 11 Do Begin
   A:=IGetL(V,40+I*4);
   If A<>0 Then Begin
    If V.Dirty Then FreeFrags(M,A,Frag) Else FreeFrags(M,A,FragsOf(M,V.Size,I));
    IPutL(V,40+I*4,0);
   End;
  End;
  Ind:=IGetL(V,88);
  If Ind<>0 Then Begin
   For J:=0 To Nindir-1 Do Begin
    A:=IndGet(M,Ind,J); If A<>0 Then FreeFrags(M,A,Frag);
   End;
   FreeFrags(M,Ind,Frag); IPutL(V,88,0);
  End;
  Ind2:=IGetL(V,92);
  If Ind2<>0 Then Begin
   For I:=0 To Nindir-1 Do Begin
    Ind:=IndGet(M,Ind2,I);
    If Ind<>0 Then Begin
     For J:=0 To Nindir-1 Do Begin
      A:=IndGet(M,Ind,J); If A<>0 Then FreeFrags(M,A,Frag);
     End;
     FreeFrags(M,Ind,Frag);
    End;
   End;
   FreeFrags(M,Ind2,Frag); IPutL(V,92,0);
  End;
 End;
 IPutL(V,104,0);
 V.Size:=0; V.Dirty:=False; V.MTime:=KTime;
 IUpdate(V);
End;

{ --- repertoires ----------------------------------------------------- }

Function UfsReadDir(Var V: TVNode; Var Pos: Longint; Var Name: TName;
  Var Ino: Longint; Var Typ: Byte): Boolean;
Var Base: Longint; O,RecLen: Word; NL,I: Integer; T: Byte;
Begin
 UfsReadDir:=False;
 While Pos<V.Size Do Begin
  Base:=Pos-Pos Mod 512;
  If UfsRead(V,Base,Seg(DirBuf),Ofs(DirBuf),512)<=0 Then Exit;
  O:=Pos Mod 512;
  RecLen:=DirBuf[O+4]+Word(DirBuf[O+5]) Shl 8;
  If (RecLen<8) Or (O+RecLen>512) Then Begin Pos:=Base+512; Continue End;
  Inc(Pos,RecLen);
  Ino:=MemL[Seg(DirBuf):Ofs(DirBuf)+O];
  If Ino<>0 Then Begin
   NL:=DirBuf[O+7]; Name:='';
   For I:=0 To NL-1 Do If Length(Name)<63 Then Name:=Name+Chr(DirBuf[O+8+I]);
   T:=DirBuf[O+6];
   Case T Of
    4: Typ:=VDIR;
    2: Typ:=VCHR;
    1: Typ:=VFIFO;
    Else Typ:=VREG;
   End;
   UfsReadDir:=True; Exit;
  End;
 End;
End;

Function Find(Var Dir: TVNode; Name: TName; Var Ino: Longint): Boolean;
Var Pos,I: Longint; N: TName; T: Byte; U: TName;
Begin
 Find:=False; Pos:=0;
 While UfsReadDir(Dir,Pos,N,I,T) Do
  If N=Name Then Begin Ino:=I; Find:=True; Exit End;
 { noms DOS (majuscules) : comparaison sans tenir compte de la casse }
 U:=UpStr(Name); Pos:=0;
 While UfsReadDir(Dir,Pos,N,I,T) Do
  If UpStr(N)=U Then Begin Ino:=I; Find:=True; Exit End;
End;

Function UfsLookup(Var Dir: TVNode; Name: TName; Var V: TVNode): Integer;
Var Ino: Longint;
Begin
 If Not Find(Dir,Name,Ino) Then Begin UfsLookup:=ENOENT; Exit End;
 UfsLookup:=UfsIGet(Dir.Mnt,Ino,V);
End;

Function DType(Typ: Byte): Byte;
Begin
 Case Typ Of VDIR: DType:=4; VCHR: DType:=2; VFIFO: DType:=1; Else DType:=8; End;
End;

Function AddEntry(Var Dir: TVNode; Name: TName; Ino: Longint;
  Typ: Byte): Integer;
Var Base: Longint; O,RecLen,Act,Need: Word; I: Integer; Done: Boolean;
Begin
 AddEntry:=0;
 Need:=8+((Length(Name)+1+3) And Not 3);
 Base:=0; Done:=False;
 While (Base<Dir.Size) And Not Done Do Begin
  If UfsRead(Dir,Base,Seg(DirBuf),Ofs(DirBuf),512)<=0 Then Begin
   AddEntry:=EIO; Exit;
  End;
  O:=0;
  While O<512 Do Begin
   RecLen:=DirBuf[O+4]+Word(DirBuf[O+5]) Shl 8;
   If RecLen<8 Then Break;
   If MemL[Seg(DirBuf):Ofs(DirBuf)+O]=0 Then Act:=0
   Else Act:=8+((DirBuf[O+7]+1+3) And Not 3);
   If RecLen-Act>=Need Then Begin
    If Act>0 Then Begin
     DirBuf[O+4]:=Lo(Act); DirBuf[O+5]:=Hi(Act);
     O:=O+Act; RecLen:=RecLen-Act;
    End;
    MemL[Seg(DirBuf):Ofs(DirBuf)+O]:=Ino;
    DirBuf[O+4]:=Lo(RecLen); DirBuf[O+5]:=Hi(RecLen);
    DirBuf[O+6]:=DType(Typ); DirBuf[O+7]:=Length(Name);
    For I:=1 To Length(Name) Do DirBuf[O+7+I]:=Ord(Name[I]);
    For I:=Length(Name)+1 To ((Length(Name)+1+3) And Not 3) Do
      DirBuf[O+7+I]:=0;
    Done:=True; Break;
   End;
   O:=O+RecLen;
  End;
  If Done Then Begin
   If UfsWrite(Dir,Base,Seg(DirBuf),Ofs(DirBuf),512)<>512 Then AddEntry:=EIO;
   Exit;
  End;
  Inc(Base,512);
 End;
 { nouveau bloc de repertoire }
 FillChar(DirBuf,SizeOf(DirBuf),0);
 MemL[Seg(DirBuf):Ofs(DirBuf)]:=Ino;
 DirBuf[4]:=0; DirBuf[5]:=2;
 DirBuf[6]:=DType(Typ); DirBuf[7]:=Length(Name);
 For I:=1 To Length(Name) Do DirBuf[7+I]:=Ord(Name[I]);
 If UfsWrite(Dir,Dir.Size,Seg(DirBuf),Ofs(DirBuf),512)<>512 Then
   AddEntry:=ENOSPC;
 UfsClose(Dir);
End;

Function DelEntry(Var Dir: TVNode; Name: TName): Integer;
Var Base: Longint; O,P,RecLen: Word; NL,I: Integer; Ok: Boolean;
Begin
 DelEntry:=ENOENT; Base:=0;
 While Base<Dir.Size Do Begin
  If UfsRead(Dir,Base,Seg(DirBuf),Ofs(DirBuf),512)<=0 Then Begin
   DelEntry:=EIO; Exit;
  End;
  O:=0; P:=$FFFF;
  While O<512 Do Begin
   RecLen:=DirBuf[O+4]+Word(DirBuf[O+5]) Shl 8;
   If RecLen<8 Then Break;
   If MemL[Seg(DirBuf):Ofs(DirBuf)+O]<>0 Then Begin
    NL:=DirBuf[O+7]; Ok:=NL=Length(Name);
    If Ok Then For I:=1 To NL Do If DirBuf[O+7+I]<>Ord(Name[I]) Then Ok:=False;
    If Ok Then Begin
     If P=$FFFF Then MemL[Seg(DirBuf):Ofs(DirBuf)+O]:=0
     Else Begin
      RecLen:=RecLen+DirBuf[P+4]+Word(DirBuf[P+5]) Shl 8;
      DirBuf[P+4]:=Lo(RecLen); DirBuf[P+5]:=Hi(RecLen);
     End;
     If UfsWrite(Dir,Base,Seg(DirBuf),Ofs(DirBuf),512)<>512 Then
       DelEntry:=EIO Else DelEntry:=0;
     UfsClose(Dir);
     Exit;
    End;
   End;
   P:=O; O:=O+RecLen;
  End;
  Inc(Base,512);
 End;
End;

Function InitInode(Var V: TVNode; M: Integer; Ino: Longint; Mode: Word;
  NLink: Word): Integer;
Var LBA: Longint; O: Word; B: Integer; S: Word; T: Longint;
Begin
 InitInode:=EIO;
 ILoc(M,Ino,LBA,O);
 B:=BRead(Mounts[M].Drive,LBA);
 If B=0 Then Exit;
 S:=BufSeg(B);
 FarFill(S,O,128,0);
 T:=KTime; Inc(GenCount);
 MemW[S:O]:=Mode; MemW[S:O+2]:=NLink;
 MemL[S:O+16]:=T; MemL[S:O+24]:=T; MemL[S:O+32]:=T;
 MemL[S:O+108]:=T Xor GenCount;
 If Not BWrite(B) Then Exit;
 FillChar(V,SizeOf(V),0);
 V.Mnt:=M; V.Ino:=Ino; V.Mode:=Mode; V.NLink:=NLink; V.MTime:=T;
 If Mode And S_IFMT=S_IFDIR Then V.Typ:=VDIR Else V.Typ:=VREG;
 InitInode:=0;
End;

Function UfsCreate(Var Dir: TVNode; Name: TName; IsDir: Boolean;
  Var V: TVNode): Integer;
Var M: Integer; Ino,X: Longint; E: Integer;
Begin
 M:=Dir.Mnt;
 If Mounts[M].RO Then Begin UfsCreate:=EROFS; Exit End;
 If (Name='') Or (Name='.') Or (Name='..') Then Begin UfsCreate:=EINVAL; Exit End;
 If Length(Name)>63 Then Begin UfsCreate:=ENAMETOOLONG; Exit End;
 If Find(Dir,Name,X) Then Begin UfsCreate:=EEXIST; Exit End;
 Ino:=AllocInode(M,IsDir);
 If Ino=0 Then Begin UfsCreate:=ENOSPC; Exit End;
 If IsDir Then E:=InitInode(V,M,Ino,S_IFDIR Or $1ED,2)
 Else E:=InitInode(V,M,Ino,S_IFREG Or $1A4,1);
 If E<>0 Then Begin UfsCreate:=E; Exit End;
 If IsDir Then Begin
  { "." et ".." }
  FillChar(DirBuf,SizeOf(DirBuf),0);
  MemL[Seg(DirBuf):Ofs(DirBuf)]:=Ino; DirBuf[4]:=12; DirBuf[6]:=4;
  DirBuf[7]:=1; DirBuf[8]:=Ord('.');
  MemL[Seg(DirBuf):Ofs(DirBuf)+12]:=Dir.Ino; DirBuf[16]:=Lo(500);
  DirBuf[17]:=Hi(500); DirBuf[18]:=4; DirBuf[19]:=2; DirBuf[20]:=Ord('.');
  DirBuf[21]:=Ord('.');
  If UfsWrite(V,0,Seg(DirBuf),Ofs(DirBuf),512)<>512 Then Begin
   UfsCreate:=ENOSPC; Exit;
  End;
  UfsClose(V);
  Inc(Dir.NLink); IUpdate(Dir);
 End;
 E:=AddEntry(Dir,Name,Ino,V.Typ);
 UfsCreate:=E;
End;

Function DirEmpty(Var D: TVNode): Boolean;
Var Pos,Ino: Longint; N: TName; T: Byte;
Begin
 DirEmpty:=True; Pos:=0;
 While UfsReadDir(D,Pos,N,Ino,T) Do
  If (N<>'.') And (N<>'..') Then Begin DirEmpty:=False; Exit End;
End;

Function UfsRemove(Var Dir: TVNode; Name: TName; IsDir: Boolean): Integer;
Var Ino: Longint; V: TVNode; E: Integer;
Begin
 If Mounts[Dir.Mnt].RO Then Begin UfsRemove:=EROFS; Exit End;
 If (Name='.') Or (Name='..') Then Begin UfsRemove:=EINVAL; Exit End;
 If Not Find(Dir,Name,Ino) Then Begin UfsRemove:=ENOENT; Exit End;
 E:=UfsIGet(Dir.Mnt,Ino,V);
 If E<>0 Then Begin UfsRemove:=E; Exit End;
 If IsDir And (V.Typ<>VDIR) Then Begin UfsRemove:=ENOTDIR; Exit End;
 If Not IsDir And (V.Typ=VDIR) Then Begin UfsRemove:=EISDIR; Exit End;
 If IsDir And Not DirEmpty(V) Then Begin UfsRemove:=ENOTEMPTY; Exit End;
 E:=DelEntry(Dir,Name);
 If E<>0 Then Begin UfsRemove:=E; Exit End;
 If IsDir Then Begin
  V.NLink:=0;
  If Dir.NLink>2 Then Dec(Dir.NLink);
  IUpdate(Dir);
 End Else If V.NLink>0 Then Dec(V.NLink);
 If V.NLink=0 Then Begin
  V.Typ:=VREG; UfsTrunc(V);
  V.Mode:=0; IUpdate(V);
  FreeInode(Dir.Mnt,Ino,IsDir);
 End Else IUpdate(V);
 UfsRemove:=0;
End;

Function UfsLink(Var Dir: TVNode; Name: TName; Var V: TVNode): Integer;
Var X: Longint; E: Integer;
Begin
 If Mounts[Dir.Mnt].RO Then Begin UfsLink:=EROFS; Exit End;
 If V.Typ=VDIR Then Begin UfsLink:=EPERM; Exit End;
 If Find(Dir,Name,X) Then Begin UfsLink:=EEXIST; Exit End;
 E:=AddEntry(Dir,Name,V.Ino,V.Typ);
 If E=0 Then Begin Inc(V.NLink); IUpdate(V) End;
 UfsLink:=E;
End;

Function UfsRename(Var D1: TVNode; N1: TName; Var D2: TVNode;
  N2: TName): Integer;
Var Ino,X: Longint; V: TVNode; E: Integer;
Begin
 If Mounts[D1.Mnt].RO Then Begin UfsRename:=EROFS; Exit End;
 If Not Find(D1,N1,Ino) Then Begin UfsRename:=ENOENT; Exit End;
 E:=UfsIGet(D1.Mnt,Ino,V);
 If E<>0 Then Begin UfsRename:=E; Exit End;
 If Find(D2,N2,X) Then Begin
  If X=Ino Then Begin UfsRename:=0; Exit End;
  E:=UfsRemove(D2,N2,False);
  If E<>0 Then Begin UfsRename:=E; Exit End;
 End;
 E:=AddEntry(D2,N2,Ino,V.Typ);
 If E<>0 Then Begin UfsRename:=E; Exit End;
 E:=DelEntry(D1,N1);
 If (V.Typ=VDIR) And (D1.Ino<>D2.Ino) Then Begin
  { ".." du repertoire deplace }
  If UfsRead(V,0,Seg(DirBuf),Ofs(DirBuf),512)=512 Then Begin
   MemL[Seg(DirBuf):Ofs(DirBuf)+12]:=D2.Ino;
   UfsWrite(V,0,Seg(DirBuf),Ofs(DirBuf),512); UfsClose(V);
  End;
  If D1.NLink>2 Then Dec(D1.NLink); IUpdate(D1);
  Inc(D2.NLink); IUpdate(D2);
 End;
 UfsRename:=E;
End;

Function UfsChmod(Var V: TVNode; Mode: Word): Integer;
Begin
 If Mounts[V.Mnt].RO Then Begin UfsChmod:=EROFS; Exit End;
 V.Mode:=(V.Mode And S_IFMT) Or (Mode And $FFF);
 IUpdate(V);
 UfsChmod:=0;
End;

SegmentEnd;

{ ====================================================================== }
SegmentUnit KVfs;
{ Systeme de fichiers virtuel : table des vnodes, resolution des chemins
  (namei), table des montages, fichiers ouverts, /dev et tubes. }
Uses KTypes,KLib,KSched,KDisk,KTty,KFat,KUfs;
SegmentInterface

Var
 PipeUsed: Array[0..NPIPE-1] Of Boolean;
 PipeReaders, PipeWriters, PipeHead, PipeCount: Array[0..NPIPE-1] Of Word;

Function NormPath(Base: TPath; Path: String): TPath;
Function VGet(Var T: TVNode): Integer;
Procedure VPut(I: Integer);
Procedure VRef(I: Integer);
Function Namei(Path: String; Var Vn: Integer): Integer;
Function NameiParent(Path: String; Var Dir: Integer; Var Last: TName): Integer;
Function VRead(Vn: Integer; Off: Longint; Sg, Os, N: Word): Integer;
Function VWrite(Vn: Integer; Off: Longint; Sg, Os, N: Word): Integer;
Function VTrunc(Vn: Integer): Integer;
Function VReadDir(Vn: Integer; Var Pos: Longint; Var Name: TName;
  Var Ino: Longint; Var Typ: Byte): Boolean;
Function VCreate(Dir: Integer; Name: TName; IsDir: Boolean;
  Var Vn: Integer): Integer;
Function VRemove(Dir: Integer; Name: TName; IsDir: Boolean): Integer;
Function VRename(D1: Integer; N1: TName; D2: Integer; N2: TName): Integer;
Function VLink(Dir: Integer; Name: TName; Vn: Integer): Integer;
Function VChmod(Vn: Integer; Mode: Word): Integer;
Function DoMount(Special, Dir: String; FsType: Word): Integer;
Function DoUmount(Dir: String): Integer;
Function MountFree(M: Integer): Longint;
Function IsMountDir(P: TPath): Boolean;
Function FAlloc(Vn: Integer; Flags: Word): Integer;
Procedure FRef(F: Integer);
Procedure FClose(F: Integer);
Function PipeAlloc(Var R, W: Integer): Integer;
Function DevName(Minor: Word): TName;
Procedure DevRegisterDisks;

SegmentImplementation

Var
 PipeBuf: Array[0..NPIPE-1,0..PIPESIZE-1] Of Byte;

Function NormPath(Base: TPath; Path: String): TPath;
{ chemin absolu sans ".", ".." ni "/" doubles }
Var R: String; C: String; I,J: Integer;
Begin
 If (Path='') Or (Path[1]<>'/') Then Path:=Base+'/'+Path;
 R:=''; I:=1;
 While I<=Length(Path) Do Begin
  While (I<=Length(Path)) And (Path[I]='/') Do Inc(I);
  C:='';
  While (I<=Length(Path)) And (Path[I]<>'/') Do Begin C:=C+Path[I]; Inc(I) End;
  If (C='') Or (C='.') Then Continue;
  If C='..' Then Begin
   J:=Length(R);
   While (J>0) And (R[J]<>'/') Do Dec(J);
   If J>0 Then R:=Copy(R,1,J-1) Else R:='';
  End Else R:=R+'/'+C;
 End;
 If R='' Then R:='/';
 If Length(R)>127 Then R:=Copy(R,1,127);
 NormPath:=R;
End;

Function VGet(Var T: TVNode): Integer;
{ vnode de la table equivalent a T (meme systeme, meme inode), reference }
Var I,F: Integer;
Begin
 F:=0;
 For I:=1 To NVNODE Do
  If VNodes[I].Ref>0 Then Begin
   If (T.Typ<>VFIFO) And (VNodes[I].Typ=T.Typ) And (VNodes[I].Mnt=T.Mnt) And
     (VNodes[I].Ino=T.Ino) Then Begin
    Inc(VNodes[I].Ref); VGet:=I; Exit;
   End;
  End Else If F=0 Then F:=I;
 If F=0 Then Begin VGet:=0; Exit End;
 VNodes[F]:=T; VNodes[F].Ref:=1;
 VGet:=F;
End;

Procedure VRef(I: Integer);
Begin
 If I>0 Then Inc(VNodes[I].Ref);
End;

Procedure VPut(I: Integer);
Begin
 If (I<=0) Or (VNodes[I].Ref=0) Then Exit;
 Dec(VNodes[I].Ref);
 If VNodes[I].Ref=0 Then
  If VNodes[I].Mnt>0 Then
   If Mounts[VNodes[I].Mnt].Typ=FSUFS Then UfsClose(VNodes[I]);
End;

{ --- /dev ------------------------------------------------------------- }

Function DevName(Minor: Word): TName;
Begin
 Case Minor Of
  DEVTTY: DevName:='tty';
  DEVNULL: DevName:='null';
  DEVZERO: DevName:='zero';
  Else If (Minor>=DEVDISK) And (Minor<DEVDISK+DiskCount) Then
   DevName:=Disks[Minor-DEVDISK].Name
  Else DevName:='';
 End;
End;

Procedure DevRegisterDisks;
Begin
End;

Function DevMinor(Name: TName): Integer;
Var I: Integer;
Begin
 DevMinor:=0;
 If Name='console' Then Begin DevMinor:=DEVTTY; Exit End;
 For I:=1 To DEVDISK+DiskCount-1 Do
  If (DevName(I)<>'') And (DevName(I)=Name) Then Begin DevMinor:=I; Exit End;
End;

Procedure DevVn(M: Integer; Minor: Word; Var T: TVNode);
Begin
 FillChar(T,SizeOf(T),0);
 T.Mnt:=M; T.Typ:=VCHR; T.Ino:=Minor; T.Minor:=Minor;
 T.Mode:=S_IFCHR Or $1B6; T.NLink:=1; T.MTime:=BootTime;
 If Minor>=DEVDISK Then
  T.Size:=Disks[Minor-DEVDISK].Sectors*512;
End;

Function DevLookup(M: Integer; Name: TName; Var T: TVNode): Integer;
Var N: Integer;
Begin
 N:=DevMinor(Name);
 If N=0 Then Begin DevLookup:=ENOENT; Exit End;
 DevVn(M,N,T);
 DevLookup:=0;
End;

Function DevReadDir(Var Pos: Longint; Var Name: TName; Var Ino: Longint;
  Var Typ: Byte): Boolean;
Begin
 DevReadDir:=False;
 While Pos<DEVDISK+DiskCount Do Begin
  Inc(Pos);
  Name:=DevName(Pos);
  If Name<>'' Then Begin Ino:=Pos; Typ:=VCHR; DevReadDir:=True; Exit End;
 End;
End;

Function DiskSize(D: Integer): Longint;
Begin
 With Disks[D] Do
  If Sectors<>0 Then DiskSize:=Sectors
  Else DiskSize:=Longint(Spt)*Heads*Cyls;
End;

Function DevRW(Minor: Word; Off: Longint; Sg, Os, N: Word;
  Wr: Boolean): Integer;
Var D,B: Integer; Done,Chunk,O: Word; Err: Integer; Lim: Longint;
Begin
 Case Minor Of
  DEVTTY: If Wr Then DevRW:=TtyWrite(Sg,Os,N)
          Else Begin
           DevRW:=TtyRead(Sg,Os,N,Err);
           If Err<>0 Then DevRW:=-Err;
          End;
  DEVNULL: If Wr Then DevRW:=N Else DevRW:=0;
  DEVZERO: Begin If Not Wr Then FarFill(Sg,Os,N,0); DevRW:=N End;
  Else Begin
   D:=Minor-DEVDISK;
   If (D<0) Or (D>=DiskCount) Then Begin DevRW:=-ENXIO; Exit End;
   Lim:=DiskSize(D)*512;
   If (Lim>0) And (Off>=Lim) Then Begin DevRW:=0; Exit End;
   If (Lim>0) And (Off+N>Lim) Then N:=Lim-Off;
   Done:=0;
   While Done<N Do Begin
    O:=Off Mod 512; Chunk:=512-O; If Chunk>N-Done Then Chunk:=N-Done;
    If Wr And (Chunk=512) Then B:=BGet(D,Off Div 512)
    Else B:=BRead(D,Off Div 512);
    If B=0 Then Begin
     If Done=0 Then DevRW:=-EIO Else DevRW:=Done;
     Exit;
    End;
    If Wr Then Begin
     FarMove(Sg,Os+Done,BufSeg(B),O,Chunk);
     If Not BWrite(B) Then Begin DevRW:=-EIO; Exit End;
    End Else FarMove(BufSeg(B),O,Sg,Os+Done,Chunk);
    Inc(Done,Chunk); Inc(Off,Chunk);
   End;
   DevRW:=Done;
  End;
 End;
End;

{ --- tubes ------------------------------------------------------------ }

Function PipeAlloc(Var R, W: Integer): Integer;
Var P,V: Integer; T: TVNode;
Begin
 PipeAlloc:=ENFILE;
 For P:=0 To NPIPE-1 Do If Not PipeUsed[P] Then Begin
  FillChar(T,SizeOf(T),0);
  T.Typ:=VFIFO; T.Minor:=P; T.Mode:=S_IFIFO Or $180; T.NLink:=1;
  T.MTime:=KTime; T.Ino:=P;
  V:=VGet(T);
  If V=0 Then Exit;
  R:=FAlloc(V,O_RDONLY);
  If R=0 Then Begin VPut(V); Exit End;
  VRef(V);
  W:=FAlloc(V,O_WRONLY);
  If W=0 Then Begin FClose(R); VPut(V); Exit End;
  PipeUsed[P]:=True; PipeReaders[P]:=1; PipeWriters[P]:=1;
  PipeHead[P]:=0; PipeCount[P]:=0;
  PipeAlloc:=0; Exit;
 End;
End;

Function PipeRead(P: Integer; Sg, Os, N: Word): Integer;
Var Done: Word;
Begin
 While PipeCount[P]=0 Do Begin
  If PipeWriters[P]=0 Then Begin PipeRead:=0; Exit End;
  If Not SleepIntr(CHPIPE+P) Then Begin PipeRead:=-EINTR; Exit End;
 End;
 Done:=0;
 While (Done<N) And (PipeCount[P]>0) Do Begin
  Mem[Sg:Os+Done]:=PipeBuf[P,PipeHead[P]];
  PipeHead[P]:=(PipeHead[P]+1) Mod PIPESIZE; Dec(PipeCount[P]); Inc(Done);
 End;
 Wakeup(CHPIPE+P);
 PipeRead:=Done;
End;

Function PipeWrite(P: Integer; Sg, Os, N: Word): Integer;
Var Done: Word;
Begin
 Done:=0;
 While Done<N Do Begin
  If PipeReaders[P]=0 Then Begin
   PostSig(Cur,SIGPIPE); PipeWrite:=-EPIPE; Exit;
  End;
  If PipeCount[P]=PIPESIZE Then Begin
   Wakeup(CHPIPE+P);
   If Not SleepIntr(CHPIPE+P) Then Begin
    If Done>0 Then PipeWrite:=Done Else PipeWrite:=-EINTR;
    Exit;
   End;
   Continue;
  End;
  PipeBuf[P,(PipeHead[P]+PipeCount[P]) Mod PIPESIZE]:=Mem[Sg:Os+Done];
  Inc(PipeCount[P]); Inc(Done);
 End;
 Wakeup(CHPIPE+P);
 PipeWrite:=Done;
End;

{ --- fichiers ouverts ------------------------------------------------- }

Function FAlloc(Vn: Integer; Flags: Word): Integer;
Var I: Integer;
Begin
 FAlloc:=0;
 For I:=1 To NFILE Do If Files[I].Ref=0 Then Begin
  Files[I].Ref:=1; Files[I].Vn:=Vn; Files[I].Flags:=Flags; Files[I].Off:=0;
  FAlloc:=I; Exit;
 End;
End;

Procedure FRef(F: Integer);
Begin
 If F>0 Then Inc(Files[F].Ref);
End;

Procedure FClose(F: Integer);
Var V,P: Integer;
Begin
 If (F<=0) Or (Files[F].Ref=0) Then Exit;
 Dec(Files[F].Ref);
 If Files[F].Ref>0 Then Exit;
 V:=Files[F].Vn;
 If (V>0) And (VNodes[V].Typ=VFIFO) Then Begin
  P:=VNodes[V].Minor;
  If Files[F].Flags And O_ACCMODE=O_RDONLY Then Begin
   If PipeReaders[P]>0 Then Dec(PipeReaders[P]);
  End Else If PipeWriters[P]>0 Then Dec(PipeWriters[P]);
  Wakeup(CHPIPE+P);
  If (PipeReaders[P]=0) And (PipeWriters[P]=0) Then PipeUsed[P]:=False;
 End;
 VPut(V);
End;

{ --- montages --------------------------------------------------------- }

Function IsMountDir(P: TPath): Boolean;
Var M: Integer;
Begin
 IsMountDir:=False;
 For M:=1 To NMOUNT Do If Mounts[M].Used And (Mounts[M].Dir=P) Then
   IsMountDir:=True;
End;

Function MountOf(P: TPath; Var Rest: TPath): Integer;
{ montage dont le repertoire est le plus long prefixe de P }
Var M,Best,L: Integer;
Begin
 Best:=0; L:=-1;
 For M:=1 To NMOUNT Do With Mounts[M] Do
  If Used Then
   If (Dir='/') Or (P=Dir) Or (Copy(P,1,Length(Dir)+1)=Dir+'/') Then
    If Length(Dir)>L Then Begin Best:=M; L:=Length(Dir) End;
 MountOf:=Best;
 If Best=0 Then Begin Rest:=''; Exit End;
 If Mounts[Best].Dir='/' Then Rest:=Copy(P,2,255)
 Else Rest:=Copy(P,Length(Mounts[Best].Dir)+2,255);
End;

Function VLookup(D: Integer; Name: TName; Var T: TVNode): Integer;
Var M: Integer;
Begin
 M:=VNodes[D].Mnt;
 Case Mounts[M].Typ Of
  FSFAT12,FSFAT16: VLookup:=FatLookup(VNodes[D],Name,T);
  FSUFS: VLookup:=UfsLookup(VNodes[D],Name,T);
  FSDEV: VLookup:=DevLookup(M,Name,T);
  Else VLookup:=ENOENT;
 End;
End;

Function Namei(Path: String; Var Vn: Integer): Integer;
Var P,Rest: TPath; M,V,I,E: Integer; C: TName; T: TVNode;
Begin
 Vn:=0;
 If Path='' Then Begin Namei:=ENOENT; Exit End;
 P:=NormPath(Procs[Cur].Cwd,Path);
 M:=MountOf(P,Rest);
 If M=0 Then Begin Namei:=ENOENT; Exit End;
 V:=Mounts[M].RootVn; VRef(V);
 I:=1;
 While I<=Length(Rest) Do Begin
  C:='';
  While (I<=Length(Rest)) And (Rest[I]<>'/') Do Begin
   If Length(C)<63 Then C:=C+Rest[I]; Inc(I);
  End;
  Inc(I);
  If VNodes[V].Typ<>VDIR Then Begin VPut(V); Namei:=ENOTDIR; Exit End;
  E:=VLookup(V,C,T);
  VPut(V);
  If E<>0 Then Begin Namei:=E; Exit End;
  V:=VGet(T);
  If V=0 Then Begin Namei:=ENFILE; Exit End;
 End;
 Vn:=V; Namei:=0;
End;

Function NameiParent(Path: String; Var Dir: Integer; Var Last: TName): Integer;
Var P: TPath; I,E: Integer;
Begin
 Dir:=0;
 P:=NormPath(Procs[Cur].Cwd,Path);
 If (P='/') Or IsMountDir(P) Then Begin NameiParent:=EBUSY; Exit End;
 I:=Length(P);
 While (I>0) And (P[I]<>'/') Do Dec(I);
 Last:=Copy(P,I+1,63);
 If I<=1 Then E:=Namei('/',Dir) Else E:=Namei(Copy(P,1,I-1),Dir);
 If (E=0) And (VNodes[Dir].Typ<>VDIR) Then Begin
  VPut(Dir); Dir:=0; E:=ENOTDIR;
 End;
 NameiParent:=E;
End;

Function FsType(Vn: Integer): Byte;
Begin
 If VNodes[Vn].Mnt=0 Then FsType:=FSNONE
 Else FsType:=Mounts[VNodes[Vn].Mnt].Typ;
End;

Function VRead(Vn: Integer; Off: Longint; Sg, Os, N: Word): Integer;
Begin
 Case VNodes[Vn].Typ Of
  VFIFO: VRead:=PipeRead(VNodes[Vn].Minor,Sg,Os,N);
  VCHR: VRead:=DevRW(VNodes[Vn].Minor,Off,Sg,Os,N,False);
  VDIR: VRead:=-EISDIR;
  Else Case FsType(Vn) Of
   FSFAT12,FSFAT16: VRead:=FatRead(VNodes[Vn],Off,Sg,Os,N);
   FSUFS: VRead:=UfsRead(VNodes[Vn],Off,Sg,Os,N);
   Else VRead:=-EIO;
  End;
 End;
End;

Function VWrite(Vn: Integer; Off: Longint; Sg, Os, N: Word): Integer;
Begin
 Case VNodes[Vn].Typ Of
  VFIFO: VWrite:=PipeWrite(VNodes[Vn].Minor,Sg,Os,N);
  VCHR: VWrite:=DevRW(VNodes[Vn].Minor,Off,Sg,Os,N,True);
  VDIR: VWrite:=-EISDIR;
  Else Case FsType(Vn) Of
   FSFAT12,FSFAT16: VWrite:=FatWrite(VNodes[Vn],Off,Sg,Os,N);
   FSUFS: VWrite:=UfsWrite(VNodes[Vn],Off,Sg,Os,N);
   Else VWrite:=-EIO;
  End;
 End;
End;

Function VTrunc(Vn: Integer): Integer;
Begin
 VTrunc:=0;
 If VNodes[Vn].Typ<>VREG Then Exit;
 Case FsType(Vn) Of
  FSFAT12,FSFAT16: VTrunc:=FatTrunc(VNodes[Vn]);
  FSUFS: VTrunc:=UfsTrunc(VNodes[Vn]);
 End;
End;

Function VReadDir(Vn: Integer; Var Pos: Longint; Var Name: TName;
  Var Ino: Longint; Var Typ: Byte): Boolean;
Begin
 Case FsType(Vn) Of
  FSFAT12,FSFAT16: VReadDir:=FatReadDir(VNodes[Vn],Pos,Name,Ino,Typ);
  FSUFS: VReadDir:=UfsReadDir(VNodes[Vn],Pos,Name,Ino,Typ);
  FSDEV: VReadDir:=DevReadDir(Pos,Name,Ino,Typ);
  Else VReadDir:=False;
 End;
End;

Function VCreate(Dir: Integer; Name: TName; IsDir: Boolean;
  Var Vn: Integer): Integer;
Var T: TVNode; E: Integer;
Begin
 Vn:=0;
 Case FsType(Dir) Of
  FSFAT12,FSFAT16: E:=FatCreate(VNodes[Dir],Name,IsDir,T);
  FSUFS: E:=UfsCreate(VNodes[Dir],Name,IsDir,T);
  Else E:=EROFS;
 End;
 If E=0 Then Begin
  Vn:=VGet(T);
  If Vn=0 Then E:=ENFILE;
 End;
 VCreate:=E;
End;

Function VRemove(Dir: Integer; Name: TName; IsDir: Boolean): Integer;
Begin
 Case FsType(Dir) Of
  FSFAT12,FSFAT16: VRemove:=FatRemove(VNodes[Dir],Name,IsDir);
  FSUFS: VRemove:=UfsRemove(VNodes[Dir],Name,IsDir);
  Else VRemove:=EROFS;
 End;
End;

Function VRename(D1: Integer; N1: TName; D2: Integer; N2: TName): Integer;
Begin
 If VNodes[D1].Mnt<>VNodes[D2].Mnt Then Begin VRename:=EXDEV; Exit End;
 Case FsType(D1) Of
  FSFAT12,FSFAT16: VRename:=FatRename(VNodes[D1],N1,VNodes[D2],N2);
  FSUFS: VRename:=UfsRename(VNodes[D1],N1,VNodes[D2],N2);
  Else VRename:=EROFS;
 End;
End;

Function VLink(Dir: Integer; Name: TName; Vn: Integer): Integer;
Begin
 If VNodes[Dir].Mnt<>VNodes[Vn].Mnt Then Begin VLink:=EXDEV; Exit End;
 If FsType(Dir)=FSUFS Then VLink:=UfsLink(VNodes[Dir],Name,VNodes[Vn])
 Else VLink:=EPERM;
End;

Function VChmod(Vn: Integer; Mode: Word): Integer;
Begin
 Case FsType(Vn) Of
  FSUFS: VChmod:=UfsChmod(VNodes[Vn],Mode);
  Else VChmod:=0;
 End;
End;

Function MountFree(M: Integer): Longint;
Begin
 Case Mounts[M].Typ Of
  FSFAT12,FSFAT16: MountFree:=FatFreeKB(M);
  FSUFS: MountFree:=UfsFreeKB(M);
  Else MountFree:=0;
 End;
End;

Function DoMount(Special, Dir: String; FsType: Word): Integer;
Var M,D,V,E,I: Integer; P: TPath; T: TVNode; S: TName;
Begin
 P:=NormPath('/',Dir);
 For M:=1 To NMOUNT Do If Mounts[M].Used And (Mounts[M].Dir=P) Then Begin
  DoMount:=EBUSY; Exit;
 End;
 M:=0;
 For I:=1 To NMOUNT Do If (M=0) And Not Mounts[I].Used Then M:=I;
 If M=0 Then Begin DoMount:=ENFILE; Exit End;
 FillChar(Mounts[M],SizeOf(TMount),0);
 Mounts[M].Dir:=P;
 S:=Special;
 If Copy(S,1,5)='/dev/' Then Delete(S,1,5);
 Mounts[M].Special:=S;
 If S='devfs' Then Begin
  Mounts[M].Typ:=FSDEV;
  FillChar(T,SizeOf(T),0);
  T.Typ:=VDIR; T.Mnt:=M; T.Mode:=S_IFDIR Or $1ED; T.NLink:=2;
  T.MTime:=BootTime; T.Ino:=0;
 End Else Begin
  D:=DevMinor(S)-DEVDISK;
  If (D<0) Or (D>=DiskCount) Then Begin DoMount:=ENODEV; Exit End;
  For I:=1 To NMOUNT Do
   If Mounts[I].Used And (Mounts[I].Typ<>FSDEV) And (Mounts[I].Drive=D) Then
   Begin DoMount:=EBUSY; Exit End;
  Mounts[M].Drive:=D; Mounts[M].Start:=Disks[D].Start;
  BInval(D);
  E:=EINVAL;
  If FsType<>1 Then E:=UfsMount(M);
  If (E<>0) And (FsType<>2) Then E:=FatMount(M);
  If E<>0 Then Begin DoMount:=E; Exit End;
  If Mounts[M].Typ=FSUFS Then Begin
   E:=UfsIGet(M,ROOTINO,T);
   If E<>0 Then Begin DoMount:=E; Exit End;
  End Else FatRoot(M,T);
 End;
 Mounts[M].Used:=True;
 V:=VGet(T);
 If V=0 Then Begin Mounts[M].Used:=False; DoMount:=ENFILE; Exit End;
 Mounts[M].RootVn:=V;
 DoMount:=0;
End;

Function DoUmount(Dir: String): Integer;
Var M,I: Integer; P: TPath;
Begin
 P:=NormPath('/',Dir);
 For M:=1 To NMOUNT Do If Mounts[M].Used And (Mounts[M].Dir=P) Then Begin
  If P='/' Then Begin DoUmount:=EBUSY; Exit End;
  For I:=1 To NVNODE Do
   If (VNodes[I].Ref>0) And (VNodes[I].Mnt=M) And (I<>Mounts[M].RootVn) Then
   Begin DoUmount:=EBUSY; Exit End;
  If VNodes[Mounts[M].RootVn].Ref>1 Then Begin DoUmount:=EBUSY; Exit End;
  VPut(Mounts[M].RootVn);
  Mounts[M].Used:=False;
  If Mounts[M].Typ<>FSDEV Then BInval(Mounts[M].Drive);
  DoUmount:=0; Exit;
 End;
 DoUmount:=EINVAL;
End;

SegmentEnd;

{ ====================================================================== }
SegmentUnit KProc;
{ Processus : chargement des executables MZ (exec), fork, exit, wait,
  signaux, liberation de la memoire. }
Uses KTypes,KLib,KMem,KSched,KVfs;
SegmentInterface

Var
 KArgs: Array[0..2047] Of Char;   { arguments et environnement d'exec }
 SwitchStamp: Longint;

Function NewProc: Integer;
Procedure ReleaseMemory(P: Integer);
Function DoFork: Integer;
Function DoVFork: Integer;
Function DoExec(Path: String; ArgSeg, ArgOfs, ArgLen: Word): Integer;
Procedure DoExit(Status: Word);
Function DoWait(Pid: Integer; Options: Word; Var Status: Word): Integer;
Procedure CheckSignals;
Procedure CloseAll(P: Integer);
Procedure SetupKStack(P: Integer);

SegmentImplementation

Function NewProc: Integer;
Var I: Integer;
Begin
 NewProc:=-1;
 For I:=1 To NPROC-1 Do If Procs[I].Stat=PFREE Then Begin
  NewProc:=I; Exit;
 End;
End;

Procedure SetupKStack(P: Integer);
{ pile noyau d'un nouveau processus : KSwitch y retrouvera DI, SI, BP et
  l'adresse de retour FAR de ForkRet }
Var K: Word;
Begin
 K:=Procs[P].KStack;
 MemW[K:KSTKTOP-10]:=0;            { DI }
 MemW[K:KSTKTOP-8]:=0;             { SI }
 MemW[K:KSTKTOP-6]:=0;             { BP }
 MemW[K:KSTKTOP-4]:=Ofs(ForkRet);
 MemW[K:KSTKTOP-2]:=Seg(ForkRet);
 Procs[P].KSP:=KSTKTOP-10; Procs[P].KSS:=K;
End;

Procedure ReleaseMemory(P: Integer);
{ libere l'image de P; si un autre processus partage la meme adresse
  d'execution (fork), il y est ramene. Un fils de vfork rend la memoire
  empruntee a son pere et le reveille. }
Var O: Integer;
Begin
 With Procs[P] Do Begin
  If Borrowed Then Begin
   Borrowed:=False; Home:=0; Where:=0; Size:=0;
   Wakeup(CHVFORK+P);
   Exit;
  End;
  If Size=0 Then Exit;
  If Where<>Home Then CoreFree(Where,Size)
  Else Begin
   For O:=1 To NPROC-1 Do
    If (O<>P) And (Procs[O].Stat<>PFREE) And (Procs[O].Size<>0) And
      (Procs[O].Home=Home) Then Begin
     ParaCopy(Procs[O].Where,Home,Size);
     CoreFree(Procs[O].Where,Size);
     Procs[O].Where:=Home;
     Home:=0; Where:=0; Size:=0;
     Exit;
    End;
   CoreFree(Home,Size);
  End;
  Home:=0; Where:=0; Size:=0;
 End;
End;

Procedure CloseAll(P: Integer);
Var I: Integer;
Begin
 For I:=0 To NOFILE-1 Do If Procs[P].Fd[I]<>0 Then Begin
  FClose(Procs[P].Fd[I]); Procs[P].Fd[I]:=0;
 End;
End;

Function DoFork: Integer;
Var C,I: Integer; A,FS: Word; K: Word;
Begin
 C:=NewProc;
 If C<0 Then Begin DoFork:=-EAGAIN; Exit End;
 If Procs[Cur].Size=0 Then Begin DoFork:=-EINVAL; Exit End;
 A:=CoreAlloc(Procs[Cur].Size);
 If A=0 Then Begin DoFork:=-ENOMEM; Exit End;
 ParaCopy(Procs[Cur].Home,A,Procs[Cur].Size);
 K:=Procs[C].KStack;
 Procs[C]:=Procs[Cur];
 With Procs[C] Do Begin
  KStack:=K;
  Inc(NextPid); If NextPid>30000 Then NextPid:=2;
  While FindPid(NextPid)>=0 Do Inc(NextPid);
  Pid:=NextPid; PPid:=Procs[Cur].Pid;
  Where:=A; Ticks:=0; SigPend:=0; Chan:=0; Wake:=0; Intr:=False;
  USS:=CurUSS; USP:=CurUSP;
  For I:=0 To NOFILE-1 Do If Fd[I]<>0 Then FRef(Fd[I]);
  { trame du fils (dans sa copie) : AX = 0, CF = 0 }
  FS:=A+(CurUSS-Procs[Cur].Home);
  MemW[FS:CurUSP]:=0;
  MemW[FS:CurUSP+22]:=MemW[FS:CurUSP+22] And $FFFE;
 End;
 SetupKStack(C);
 Procs[C].Stat:=PRUN;
 DoFork:=Procs[C].Pid;
End;

Var
 VSave: Array[0..NPROC-1,0..255] Of Byte;   { pile du pere pendant vfork }

Function DoVFork: Integer;
{ vfork : le fils s'execute dans la memoire du pere, suspendu jusqu'a ce
  que le fils appelle exec ou exit. Les 256 octets de pile utilisateur du
  pere (trame de l'appel systeme comprise) sont sauvegardes et restaures. }
Var C,I,O: Integer; K: Word;
Begin
 For O:=1 To NPROC-1 Do
  If (O<>Cur) And (Procs[O].Stat<>PFREE) And (Procs[O].Size<>0) And
    (Procs[O].Home=Procs[Cur].Home) Then Begin
   DoVFork:=DoFork; Exit;  { memoire deja partagee : fork ordinaire }
  End;
 C:=NewProc;
 If C<0 Then Begin DoVFork:=-EAGAIN; Exit End;
 If Procs[Cur].Size=0 Then Begin DoVFork:=-EINVAL; Exit End;
 K:=Procs[C].KStack;
 Procs[C]:=Procs[Cur];
 With Procs[C] Do Begin
  KStack:=K; Borrowed:=True;
  Inc(NextPid); If NextPid>30000 Then NextPid:=2;
  While FindPid(NextPid)>=0 Do Inc(NextPid);
  Pid:=NextPid; PPid:=Procs[Cur].Pid;
  Ticks:=0; SigPend:=0; Chan:=0; Wake:=0; Intr:=False;
  USS:=CurUSS; USP:=CurUSP;
  For I:=0 To NOFILE-1 Do If Fd[I]<>0 Then FRef(Fd[I]);
 End;
 FarMove(CurUSS,CurUSP,Seg(VSave),Ofs(VSave[Cur]),256);
 { trame du fils : AX = 0 }
 MemW[CurUSS:CurUSP]:=0;
 MemW[CurUSS:CurUSP+22]:=MemW[CurUSS:CurUSP+22] And $FFFE;
 SetupKStack(C);
 Procs[C].Stat:=PRUN;
 { le pere attend la fin de l'emprunt }
 While Procs[C].Borrowed And (Procs[C].Stat<>PFREE) Do Sleep(CHVFORK+C);
 FarMove(Seg(VSave),Ofs(VSave[Cur]),CurUSS,CurUSP,256);
 DoVFork:=Procs[C].Pid;
End;

Function DoExec(Path: String; ArgSeg, ArgOfs, ArgLen: Word): Integer;
Var
 Vn,I,N,Argc: Integer;
 H: Array[0..15] Of Word;
 ImgBytes,Off,Rem: Longint;
 HdrParas,LoadParas,EnvParas,Total,Extra,MinA,MaxA: Longint;
 Mem_,Load,PSP_,EnvS,SS_,SP_: Word;
 R: Array[0..1] Of Word;
 Chunk,Sg,O,K,EnvLen,EnvStart,EnvEnd,TailLen: Word;
 Name: String;
 E: Integer;
Begin
 { arguments recopies dans le noyau avant de liberer l'ancienne image }
 If ArgLen>SizeOf(KArgs)-2 Then Begin DoExec:=E2BIG; Exit End;
 If ArgLen>0 Then FarMove(ArgSeg,ArgOfs,Seg(KArgs),Ofs(KArgs),ArgLen);
 KArgs[ArgLen]:=#0; KArgs[ArgLen+1]:=#0;
 E:=Namei(Path,Vn);
 If E<>0 Then Begin DoExec:=E; Exit End;
 If VNodes[Vn].Typ<>VREG Then Begin VPut(Vn); DoExec:=EACCES; Exit End;
 FillChar(H,SizeOf(H),0);
 If (VRead(Vn,0,Seg(H),Ofs(H),32)<>32) Or (H[0]<>$5A4D) Then Begin
  VPut(Vn); DoExec:=ENOEXEC; Exit;
 End;
 If H[1]=0 Then ImgBytes:=Longint(H[2])*512 Else ImgBytes:=Longint(H[2]-1)*512+H[1];
 HdrParas:=H[4];
 ImgBytes:=ImgBytes-HdrParas*16;
 If ImgBytes<=0 Then Begin VPut(Vn); DoExec:=ENOEXEC; Exit End;
 LoadParas:=(ImgBytes+15) Div 16;
 MinA:=H[5]; MaxA:=H[6];
 { environnement : argv et env tels quels, nom du programme, argc et argv
   (extension UNIX-0) }
 I:=0; Argc:=0;
 While (I<ArgLen) And (KArgs[I]<>#0) Do Begin
  While (I<ArgLen) And (KArgs[I]<>#0) Do Inc(I);
  Inc(I); Inc(Argc);
 End;
 EnvStart:=I+1;   { apres la chaine vide qui termine argv }
 EnvParas:=(Longint(ArgLen)+Length(Path)+64) Div 16+1;
 { tas : le runtime de Unix Pascal reserve ses blocs par la libc (service
   48h), dans la zone qui suit l'image et sa pile (maxalloc = minalloc) }
 Extra:=DEFHEAP;
 Total:=EnvParas+16+LoadParas+MinA+Extra;
 If Total>$A000 Then Begin VPut(Vn); DoExec:=ENOMEM; Exit End;
 Mem_:=CoreAlloc(Total);
 If Mem_=0 Then Begin VPut(Vn); DoExec:=ENOMEM; Exit End;
 ParaZero(Mem_,EnvParas+16);
 EnvS:=Mem_; PSP_:=Mem_+EnvParas; Load:=PSP_+16;
 { chargement de l'image }
 Off:=HdrParas*16; Rem:=ImgBytes; Sg:=Load;
 While Rem>0 Do Begin
  If Rem>$4000 Then Chunk:=$4000 Else Chunk:=Rem;
  If VRead(Vn,Off,Sg,0,Chunk)<>Chunk Then Begin
   VPut(Vn); CoreFree(Mem_,Total); DoExec:=EIO; Exit;
  End;
  Inc(Off,Chunk); Dec(Rem,Chunk); Inc(Sg,Chunk Div 16);
 End;
 { relocalisations }
 For I:=0 To H[3]-1 Do Begin
  If VRead(Vn,H[12]+Longint(I)*4,Seg(R),Ofs(R),4)<>4 Then Begin
   VPut(Vn); CoreFree(Mem_,Total); DoExec:=ENOEXEC; Exit;
  End;
  MemW[Load+R[1]:R[0]]:=MemW[Load+R[1]:R[0]]+Load;
 End;
 VPut(Vn);
 ParaZero(Load+LoadParas,MinA);
 { environnement : VAR=VAL..., 0, mot 1, chemin, puis argc et argv }
 O:=0;
 I:=EnvStart;
 While (I<ArgLen) And (KArgs[I]<>#0) Do Begin
  While (I<ArgLen) And (KArgs[I]<>#0) Do Begin
   Mem[EnvS:O]:=Ord(KArgs[I]); Inc(O); Inc(I);
  End;
  Mem[EnvS:O]:=0; Inc(O); Inc(I);
 End;
 Mem[EnvS:O]:=0; Inc(O);
 MemW[EnvS:O]:=1; Inc(O,2);
 Name:=NormPath(Procs[Cur].Cwd,Path);
 PutFarStr(EnvS,O,Name); Inc(O,Length(Name)+1);
 MemW[EnvS:O]:=Argc; Inc(O,2);
 For I:=0 To EnvStart-2 Do Begin Mem[EnvS:O]:=Ord(KArgs[I]); Inc(O) End;
 Mem[EnvS:O]:=0;
 { prefixe du programme (disposition du PSP) }
 Mem[PSP_:0]:=$CD; Mem[PSP_:1]:=$20;
 MemW[PSP_:2]:=Mem_+Total;
 MemW[PSP_:$2C]:=EnvS;
 MemW[PSP_:$48]:=Load+LoadParas+MinA;   { debut du tas (libc) }
 { ligne de commande : argv[1..] separes par des espaces }
 TailLen:=0; I:=0;
 While (I<ArgLen) And (KArgs[I]<>#0) Do Inc(I);
 Inc(I);
 While (I<EnvStart-1) And (TailLen<126) Do Begin
  If KArgs[I]=#0 Then Begin
   If I<EnvStart-2 Then Begin Mem[PSP_:$81+TailLen]:=32; Inc(TailLen) End;
  End Else Begin Mem[PSP_:$81+TailLen]:=Ord(KArgs[I]); Inc(TailLen) End;
  Inc(I);
 End;
 If TailLen>0 Then Begin
  { la ligne de commande DOS commence par un espace }
  For K:=TailLen DownTo 1 Do Mem[PSP_:$81+K]:=Mem[PSP_:$80+K];
  Mem[PSP_:$81]:=32; Inc(TailLen);
 End;
 Mem[PSP_:$80]:=TailLen; Mem[PSP_:$81+TailLen]:=13;
 { l'ancienne image est liberee, la nouvelle devient celle du processus }
 ReleaseMemory(Cur);
 With Procs[Cur] Do Begin
  Home:=Mem_; Where:=Mem_; Size:=Total; PSP:=PSP_;
  DosOfs:=0; DosSeg:=0;
  I:=Length(Name);
  While (I>0) And (Name[I]<>'/') Do Dec(I);
  Procs[Cur].Name:=Copy(Name,I+1,15);
 End;
 SetDosVector(Cur);
 { trame initiale : registres, puis IP, CS, FLAGS }
 SS_:=Load+H[7]; SP_:=H[8]-24;
 For K:=0 To 11 Do MemW[SS_:SP_+K*2]:=0;
 MemW[SS_:SP_+14]:=PSP_;          { ES }
 MemW[SS_:SP_+16]:=PSP_;          { DS }
 MemW[SS_:SP_+18]:=H[10];         { IP }
 MemW[SS_:SP_+20]:=Load+H[11];    { CS }
 MemW[SS_:SP_+22]:=$0202;         { FLAGS (IF) }
 CurUSS:=SS_; CurUSP:=SP_;
 Procs[Cur].USS:=SS_; Procs[Cur].USP:=SP_;
 DoExec:=0;
End;

Procedure DoExit(Status: Word);
Var I: Integer; Parent: Integer;
Begin
 If Procs[Cur].Pid=1 Then Begin
  KPrintLn('init termine (etat '+IntStr(Status)+')');
  Panic('init est mort');
 End;
 CloseAll(Cur);
 ReleaseMemory(Cur);
 Procs[Cur].Status:=Status;
 Procs[Cur].DosSeg:=0;
 Parent:=FindPid(Procs[Cur].PPid);
 { les fils deviennent ceux d'init }
 For I:=1 To NPROC-1 Do
  If (Procs[I].Stat<>PFREE) And (Procs[I].PPid=Procs[Cur].Pid) Then Begin
   Procs[I].PPid:=1;
   If Procs[I].Stat=PZOMB Then Wakeup(CHWAIT+FindPid(1));
  End;
 Procs[Cur].Stat:=PZOMB;
 If Parent>=0 Then Wakeup(CHWAIT+Parent) Else Wakeup(CHWAIT+FindPid(1));
 Swtch;
 Panic('zombie reveille');
End;

Function DoWait(Pid: Integer; Options: Word; Var Status: Word): Integer;
Var I: Integer; Have: Boolean;
Begin
 Repeat
  Have:=False;
  For I:=1 To NPROC-1 Do
   If (Procs[I].Stat<>PFREE) And (Procs[I].PPid=Procs[Cur].Pid) And
     ((Pid=-1) Or (Pid=0) Or (Procs[I].Pid=Pid)) Then Begin
    Have:=True;
    If Procs[I].Stat=PZOMB Then Begin
     Status:=Procs[I].Status;
     DoWait:=Procs[I].Pid;
     Inc(Procs[Cur].Ticks,Procs[I].Ticks);
     Procs[I].Stat:=PFREE; Procs[I].Pid:=0;
     Exit;
    End;
   End;
  If Not Have Then Begin DoWait:=-ECHILD; Exit End;
  If Options And 1<>0 Then Begin DoWait:=0; Exit End;
  If Not SleepIntr(CHWAIT+Cur) Then Begin DoWait:=-EINTR; Exit End;
 Until False;
End;

Procedure CheckSignals;
Var S: Word; I: Integer;
Begin
 With Procs[Cur] Do Begin
  SigPend:=SigPend And Not SigIgn And Not (1 Shl SIGCHLD);
  If SigPend=0 Then Exit;
  For I:=1 To 15 Do If SigPend And (1 Shl I)<>0 Then Begin
   SigPend:=0;
   DoExit(Word(I) Shl 8);
  End;
 End;
End;

SegmentEnd;

{ ====================================================================== }
SegmentUnit KSys;
{ Appels systeme (INT 80h) : lecture de la trame, aiguillage, retour. }
Uses KTypes,KLib,KMem,KSched,KDisk,KTty,KVfs,KProc;
SegmentInterface

Procedure SysDispatch;
Procedure PreemptEntry;
Procedure FaultEntry;

SegmentImplementation

Var
 RAX,RBX,RCX,RDX,RSI,RDI,RDS,RES: Word;
 Ret,Ret2: Longint;
 SetDX: Boolean;

Function UStr(Sg, Os: Word): String;
Begin
 UStr:=FarStr(Sg,Os,127);
End;

Function GetFile(Fd: Word; Var F: Integer): Integer;
Begin
 GetFile:=EBADF; F:=0;
 If Fd>=NOFILE Then Exit;
 F:=Procs[Cur].Fd[Fd];
 If F=0 Then Exit;
 GetFile:=0;
End;

Function NewFd(F: Integer): Integer;
Var I: Integer;
Begin
 NewFd:=-1;
 For I:=0 To NOFILE-1 Do If Procs[Cur].Fd[I]=0 Then Begin
  Procs[Cur].Fd[I]:=F; NewFd:=I; Exit;
 End;
End;

Function SysRead: Integer;
Var F,N: Integer;
Begin
 SysRead:=GetFile(RBX,F);
 If F=0 Then Exit;
 If Files[F].Flags And O_ACCMODE=O_WRONLY Then Begin SysRead:=EBADF; Exit End;
 N:=VRead(Files[F].Vn,Files[F].Off,RDS,RDX,RCX);
 If N<0 Then Begin SysRead:=-N; Exit End;
 Inc(Files[F].Off,N); Ret:=N; SysRead:=0;
End;

Function SysWrite: Integer;
Var F,N: Integer;
Begin
 SysWrite:=GetFile(RBX,F);
 If F=0 Then Exit;
 If Files[F].Flags And O_ACCMODE=O_RDONLY Then Begin SysWrite:=EBADF; Exit End;
 If Files[F].Flags And O_APPEND<>0 Then Files[F].Off:=VNodes[Files[F].Vn].Size;
 N:=VWrite(Files[F].Vn,Files[F].Off,RDS,RDX,RCX);
 If N<0 Then Begin SysWrite:=-N; Exit End;
 Inc(Files[F].Off,N); Ret:=N; SysWrite:=0;
End;

Function SysOpen(Path: String; Flags: Word): Integer;
Var E,Vn,D,F,Fd: Integer; Last: TName;
Begin
 E:=Namei(Path,Vn);
 If (E=ENOENT) And (Flags And O_CREAT<>0) Then Begin
  E:=NameiParent(Path,D,Last);
  If E=0 Then Begin
   E:=VCreate(D,Last,False,Vn);
   VPut(D);
  End;
 End Else If (E=0) And (Flags And O_CREAT<>0) And (Flags And O_EXCL<>0) Then
 Begin
  VPut(Vn); E:=EEXIST;
 End;
 If E<>0 Then Begin SysOpen:=E; Exit End;
 If (VNodes[Vn].Typ=VDIR) And (Flags And O_ACCMODE<>O_RDONLY) Then Begin
  VPut(Vn); SysOpen:=EISDIR; Exit;
 End;
 If (Flags And O_TRUNC<>0) And (Flags And O_ACCMODE<>O_RDONLY) Then Begin
  E:=VTrunc(Vn);
  If E<>0 Then Begin VPut(Vn); SysOpen:=E; Exit End;
 End;
 F:=FAlloc(Vn,Flags);
 If F=0 Then Begin VPut(Vn); SysOpen:=ENFILE; Exit End;
 Fd:=NewFd(F);
 If Fd<0 Then Begin FClose(F); SysOpen:=EMFILE; Exit End;
 Ret:=Fd; SysOpen:=0;
End;

Function SysClose: Integer;
Var F: Integer;
Begin
 SysClose:=GetFile(RBX,F);
 If F=0 Then Exit;
 Procs[Cur].Fd[RBX]:=0; FClose(F);
End;

Procedure FillStat(Vn: Integer; Sg, Os: Word);
Begin
 FarFill(Sg,Os,32,0);
 With VNodes[Vn] Do Begin
  MemW[Sg:Os]:=Mnt;
  MemL[Sg:Os+2]:=Ino;
  MemW[Sg:Os+6]:=Mode;
  MemW[Sg:Os+8]:=NLink;
  MemW[Sg:Os+14]:=Minor;
  MemL[Sg:Os+16]:=Size;
  MemL[Sg:Os+20]:=MTime; MemL[Sg:Os+24]:=MTime; MemL[Sg:Os+28]:=MTime;
 End;
End;

Function SysGetDents: Integer;
Var F,Vn: Integer; Pos,Save,Ino: Longint; Name: TName; Typ: Byte;
  Done,RecLen: Word; I: Integer;
Begin
 SysGetDents:=GetFile(RBX,F);
 If F=0 Then Exit;
 Vn:=Files[F].Vn;
 If VNodes[Vn].Typ<>VDIR Then Begin SysGetDents:=ENOTDIR; Exit End;
 Pos:=Files[F].Off; Done:=0;
 Repeat
  Save:=Pos;
  If Not VReadDir(Vn,Pos,Name,Ino,Typ) Then Break;
  RecLen:=(8+Length(Name)+1+1) And $FFFE;
  If Done+RecLen>RCX Then Begin
   Pos:=Save;
   If Done=0 Then Begin SysGetDents:=EINVAL; Exit End;
   Break;
  End;
  MemL[RDS:RDX+Done]:=Ino;
  MemW[RDS:RDX+Done+4]:=RecLen;
  Mem[RDS:RDX+Done+6]:=Typ;
  Mem[RDS:RDX+Done+7]:=Length(Name);
  For I:=1 To Length(Name) Do Mem[RDS:RDX+Done+7+I]:=Ord(Name[I]);
  Mem[RDS:RDX+Done+8+Length(Name)]:=0;
  Inc(Done,RecLen);
 Until False;
 Files[F].Off:=Pos;
 Ret:=Done;
End;

Function SysLSeek: Integer;
Var F: Integer; O: Longint;
Begin
 SysLSeek:=GetFile(RBX,F);
 If F=0 Then Exit;
 If VNodes[Files[F].Vn].Typ In [VFIFO,VCHR] Then
  If (VNodes[Files[F].Vn].Typ=VFIFO) Or (VNodes[Files[F].Vn].Minor<DEVDISK) Then
  Begin SysLSeek:=ESPIPE; Exit End;
 O:=Longint(RCX) Shl 16+RDX;
 Case RSI Of
  0: ;
  1: O:=O+Files[F].Off;
  2: O:=O+VNodes[Files[F].Vn].Size;
  Else Begin SysLSeek:=EINVAL; Exit End;
 End;
 If O<0 Then Begin SysLSeek:=EINVAL; Exit End;
 Files[F].Off:=O; Ret:=O; SetDX:=True;
End;

Function SysPathOp(Op: Integer): Integer;
{ unlink (10), mkdir (39), rmdir (40), chdir (12), chmod (15) }
Var E,D,Vn: Integer; Last: TName; P: String;
Begin
 P:=UStr(RDS,RDX);
 Case Op Of
  10,39,40: Begin
   E:=NameiParent(P,D,Last);
   If E=0 Then Begin
    Case Op Of
     10: E:=VRemove(D,Last,False);
     39: Begin E:=VCreate(D,Last,True,Vn); If E=0 Then VPut(Vn) End;
     40: E:=VRemove(D,Last,True);
    End;
    VPut(D);
   End;
  End;
  12: Begin
   E:=Namei(P,Vn);
   If E=0 Then Begin
    If VNodes[Vn].Typ<>VDIR Then E:=ENOTDIR
    Else Procs[Cur].Cwd:=NormPath(Procs[Cur].Cwd,P);
    VPut(Vn);
   End;
  End;
  15: Begin
   E:=Namei(P,Vn);
   If E=0 Then Begin E:=VChmod(Vn,RCX); VPut(Vn) End;
  End;
 End;
 SysPathOp:=E;
End;

Function SysRename(Link: Boolean): Integer;
Var E,D1,D2,Vn: Integer; L1,L2: TName; P1,P2: String;
Begin
 P1:=UStr(RDS,RDX); P2:=UStr(RES,RDI);
 E:=NameiParent(P2,D2,L2);
 If E<>0 Then Begin SysRename:=E; Exit End;
 If Link Then Begin
  E:=Namei(P1,Vn);
  If E=0 Then Begin E:=VLink(D2,L2,Vn); VPut(Vn) End;
 End Else Begin
  E:=NameiParent(P1,D1,L1);
  If E=0 Then Begin E:=VRename(D1,L1,D2,L2); VPut(D1) End;
 End;
 VPut(D2);
 SysRename:=E;
End;

Function SysKill: Integer;
Var I,P,N: Integer;
Begin
 SysKill:=0; N:=0;
 If Integer(RBX)=-1 Then Begin
  For I:=1 To NPROC-1 Do
   If (Procs[I].Stat In [PRUN,PSLEEP]) And (Procs[I].Pid>1) And (I<>Cur) Then
   Begin PostSig(I,RCX); Inc(N) End;
  If N=0 Then SysKill:=ESRCH;
  Exit;
 End;
 P:=FindPid(RBX);
 If (P<0) Or (Procs[P].Stat=PZOMB) Then Begin SysKill:=ESRCH; Exit End;
 If RCX<>0 Then PostSig(P,RCX);
End;

Function SysIoctl: Integer;
Var F: Integer; IsTty: Boolean;
Begin
 SysIoctl:=GetFile(RBX,F);
 If F=0 Then Exit;
 IsTty:=(VNodes[Files[F].Vn].Typ=VCHR) And (VNodes[Files[F].Vn].Minor=DEVTTY);
 Case RCX Of
  0: If IsTty Then Ret:=1 Else Ret:=0;
  1: If IsTty Then Ret:=TtyMode Else SysIoctl:=ENOTTY;
  2: If IsTty Then TtyMode:=RDX And 3 Else SysIoctl:=ENOTTY;
  3: If IsTty Then Ret:=TtyAvail Else SysIoctl:=ENOTTY;
  Else SysIoctl:=EINVAL;
 End;
End;

Procedure PutPStr(Sg, Os: Word; S: String; Max: Integer);
Var I: Integer;
Begin
 If Length(S)>Max Then S[0]:=Chr(Max);
 For I:=0 To Length(S) Do Mem[Sg:Os+I]:=Ord(S[I]);
End;

Function SysProcInfo: Integer;
Var P: Integer;
Begin
 SysProcInfo:=0;
 If RBX>=NPROC Then Begin SysProcInfo:=EINVAL; Exit End;
 P:=RBX; Ret:=0;
 If (P=0) Or (Procs[P].Stat=PFREE) Then Exit;
 With Procs[P] Do Begin
  MemW[RDS:RDX]:=Pid; MemW[RDS:RDX+2]:=PPid;
  If Stat=PRUN Then Mem[RDS:RDX+4]:=1 Else If Stat=PSLEEP Then
    Mem[RDS:RDX+4]:=2 Else Mem[RDS:RDX+4]:=3;
  Mem[RDS:RDX+5]:=Ord(P=Cur);
  MemW[RDS:RDX+6]:=Size;
  MemL[RDS:RDX+8]:=Ticks;
  PutPStr(RDS,RDX+12,Name,15);
 End;
 Ret:=1;
End;

Function SysMountInfo: Integer;
Var M: Integer;
Begin
 SysMountInfo:=0; Ret:=0;
 If (RBX<1) Or (RBX>NMOUNT) Then Begin SysMountInfo:=EINVAL; Exit End;
 M:=RBX;
 If Not Mounts[M].Used Then Exit;
 FarFill(RDS,RDX,64,0);
 With Mounts[M] Do Begin
  Case Typ Of FSFAT12: Mem[RDS:RDX]:=1; FSFAT16: Mem[RDS:RDX]:=2;
   FSUFS: Mem[RDS:RDX]:=3; Else Mem[RDS:RDX]:=4; End;
  Mem[RDS:RDX+1]:=Drive; Mem[RDS:RDX+2]:=Ord(RO);
  MemL[RDS:RDX+4]:=Start;
  MemL[RDS:RDX+8]:=Sectors Div 2;
  MemL[RDS:RDX+12]:=MountFree(M);
  PutPStr(RDS,RDX+16,Dir,31);
  PutPStr(RDS,RDX+48,Special,15);
 End;
 Ret:=1;
End;

Procedure SysDispatch;
Var E,F,Fd,R,W,I: Integer; St: Word; P: String; Vn: Integer;
Begin
 RAX:=UserW(0); RBX:=UserW(2); RCX:=UserW(4); RDX:=UserW(6);
 RSI:=UserW(8); RDI:=UserW(10); RES:=UserW(14); RDS:=UserW(16);
 E:=0; Ret:=0; Ret2:=0; SetDX:=False;
 Case RAX Of
  1: DoExit(RBX);
  2: Begin Ret:=DoFork; If Ret<0 Then Begin E:=-Ret; Ret:=0 End End;
  190: Begin Ret:=DoVFork; If Ret<0 Then Begin E:=-Ret; Ret:=0 End End;
  3: E:=SysRead;
  4: E:=SysWrite;
  5: E:=SysOpen(UStr(RDS,RDX),RBX);
  6: E:=SysClose;
  7: Begin
      Ret:=DoWait(Integer(RBX),RCX,St);
      If Ret<0 Then Begin E:=-Ret; Ret:=0 End
      Else Begin Ret2:=St; SetDX:=True; Ret:=Ret And $FFFF End;
     End;
  8: E:=SysOpen(UStr(RDS,RDX),O_WRONLY Or O_CREAT Or O_TRUNC);
  9: E:=SysRename(True);
  10,12,15,39,40: E:=SysPathOp(RAX);
  11: Begin
       If RCX=0 Then RCX:=SizeOf(KArgs)-2;
       E:=DoExec(UStr(RDS,RDX),RES,RDI,RCX);
      End;
  13: Begin Ret:=KTime; SetDX:=True End;
  19: E:=SysLSeek;
  20: Ret:=Procs[Cur].Pid;
  21: Begin
       E:=Namei(UStr(RES,RDI),Vn);
       If E=0 Then Begin
        If VNodes[Vn].Typ<>VDIR Then E:=ENOTDIR;
        VPut(Vn);
       End;
       If E=0 Then E:=DoMount(UStr(RDS,RDX),UStr(RES,RDI),RBX);
      End;
  22: E:=DoUmount(UStr(RDS,RDX));
  24: Ret:=0;
  29: If Not SleepIntr(CHPAUSE+Cur) Then E:=EINTR;
  36: Ret:=0;
  37: E:=SysKill;
  38: E:=SysRename(False);
  41: Begin
       E:=GetFile(RBX,F);
       If F<>0 Then Begin
        Fd:=NewFd(F); If Fd<0 Then E:=EMFILE Else Begin FRef(F); Ret:=Fd End;
       End;
      End;
  42: Begin
       E:=PipeAlloc(R,W);
       If E=0 Then Begin
        Fd:=NewFd(R);
        If Fd<0 Then Begin FClose(R); FClose(W); E:=EMFILE End
        Else Begin
         Ret:=Fd; Fd:=NewFd(W);
         If Fd<0 Then Begin
          Procs[Cur].Fd[Ret]:=0; FClose(R); FClose(W); E:=EMFILE;
         End Else Begin Ret2:=Fd; SetDX:=True End;
        End;
       End;
      End;
  45: Ret:=Procs[Cur].Size;
  48: Begin
       If (RBX<1) Or (RBX>15) Or (RBX=SIGKILL) Then E:=EINVAL
       Else Begin
        Ret:=Ord(Procs[Cur].SigIgn And (1 Shl RBX)<>0);
        If RCX=1 Then Procs[Cur].SigIgn:=Procs[Cur].SigIgn Or (1 Shl RBX)
        Else Procs[Cur].SigIgn:=Procs[Cur].SigIgn And Not (1 Shl RBX);
       End;
      End;
  54: E:=SysIoctl;
  63: Begin
       E:=GetFile(RBX,F);
       If (F<>0) And (RCX>=NOFILE) Then E:=EBADF;
       If (E=0) And (RBX<>RCX) Then Begin
        If Procs[Cur].Fd[RCX]<>0 Then FClose(Procs[Cur].Fd[RCX]);
        Procs[Cur].Fd[RCX]:=F; FRef(F);
       End;
       Ret:=RCX;
      End;
  64: Ret:=Procs[Cur].PPid;
  88: Begin
       KPrintLn('Redemarrage du systeme...');
       Asm
        CLI
        MOV AX,40h
        MOV DS,AX
        MOV WORD PTR DS:[72h],1234h
        DB 0EAh
        DW 0000h,0FFFFh
       End;
      End;
  106,108: Begin
       If RAX=106 Then E:=Namei(UStr(RDS,RDX),Vn)
       Else Begin
        E:=GetFile(RBX,F);
        If F<>0 Then Begin Vn:=Files[F].Vn; VRef(Vn) End;
       End;
       If E=0 Then Begin FillStat(Vn,RES,RDI); VPut(Vn) End;
      End;
  122: Begin
       PutPStr(RDS,RDX,'UNIX-0',15);
       PutPStr(RDS,RDX+16,'unix0',15);
       PutPStr(RDS,RDX+32,KVersion,15);
       PutPStr(RDS,RDX+48,'2026',15);
       PutPStr(RDS,RDX+64,'i8086',15);
      End;
  141: E:=SysGetDents;
  158: RunRun:=True;
  162: Begin
       Procs[Cur].Wake:=Ticks+(Longint(RBX)*182) Div 10+1;
       If Not SleepIntr(CHSLEEP) Then E:=EINTR;
       Procs[Cur].Wake:=0;
      End;
  183: Begin
       P:=Procs[Cur].Cwd;
       If Length(P)+1>RCX Then E:=ERANGE
       Else PutFarStr(RDS,RDX,P);
       Ret:=Length(P);
      End;
  200: E:=SysProcInfo;
  201: Begin
       Procs[Cur].DosOfs:=RBX; Procs[Cur].DosSeg:=RCX;
       SetDosVector(Cur);
      End;
  202: Begin
       MemW[RDS:RDX]:=TotalParas;
       MemW[RDS:RDX+2]:=CoreFreeTotal;
       MemW[RDS:RDX+4]:=KernelEnd-$1000;
       MemW[RDS:RDX+6]:=NBUF;
       F:=0; For I:=1 To NPROC-1 Do If Procs[I].Stat<>PFREE Then Inc(F);
       MemW[RDS:RDX+8]:=F;
       MemW[RDS:RDX+10]:=NPROC-1;
      End;
  203: E:=SysMountInfo;
  Else E:=ENOSYS;
 End;
 If E<>0 Then Begin
  SetUserW(0,E); SetUserW(22,UserW(22) Or 1);
 End Else Begin
  SetUserW(0,Word(Ret)); SetUserW(22,UserW(22) And $FFFE);
  If SetDX Then Begin
   If RAX In [7,42] Then SetUserW(6,Word(Ret2)) Else SetUserW(6,Word(Ret Shr 16));
  End;
 End;
 CheckSignals;
 If RunRun Then Swtch;
End;

Procedure PreemptEntry;
{ fin de quantum en mode utilisateur (horloge) }
Begin
 TtyCheckIntr;
 Swtch;
 CheckSignals;
End;

Procedure FaultEntry;
Begin
 PostSig(Cur,SIGFPE);
 CheckSignals;
End;

SegmentEnd;

{ ====================================================================== }
{ Programme principal : initialisation du noyau (processus 0).            }
{ ====================================================================== }

Var
 InitArgs: Array[0..63] Of Char;
 MbrBuf: Array[0..511] Of Byte;

Procedure ProbeDisks;
{ disquettes (liste d'equipement du BIOS), disques durs et leurs
  partitions (table du MBR) }
Var Equip: Word; NF,NH,I,J,D: Integer; T: Byte; S,N: Longint;
Const Letters: String[4]='abcd';
Begin
 Equip:=MemW[$40:$10];
 NF:=0;
 If Equip And 1<>0 Then NF:=((Equip Shr 6) And 3)+1;
 For I:=0 To NF-1 Do If I<2 Then AddDisk(I,'fd'+Chr(48+I),0,0,0);
 NH:=Mem[$40:$75]; If NH>2 Then NH:=2;
 For I:=0 To NH-1 Do Begin
  D:=AddDisk($80+I,'hd'+Letters[I+1],0,0,0);
  If D<0 Then Exit;
  If DiskIO(D,0,Seg(MbrBuf),Ofs(MbrBuf),False) And (MbrBuf[510]=$55) And
    (MbrBuf[511]=$AA) Then
   For J:=0 To 3 Do Begin
    T:=MbrBuf[446+J*16+4];
    S:=MemL[Seg(MbrBuf):Ofs(MbrBuf)+446+J*16+8];
    N:=MemL[Seg(MbrBuf):Ofs(MbrBuf)+446+J*16+12];
    If (T<>0) And (N<>0) Then
     AddDisk($80+I,'hd'+Letters[I+1]+Chr(49+J),S,N,T);
   End;
 End;
End;

Function RootDevice: String;
Var I: Integer;
Begin
 RootDevice:='';
 For I:=0 To DiskCount-1 Do With Disks[I] Do
  If Bios=BootDrive Then Begin
   If BootDrive<$80 Then Begin RootDevice:=Name; Exit End;
   If Start=BootStart Then Begin RootDevice:=Name; Exit End;
  End;
End;

Procedure ShowDisks;
Var I: Integer; S: String;
Begin
 For I:=0 To DiskCount-1 Do With Disks[I] Do Begin
  S:='  '+Name+' : unite BIOS '+HexStr(Bios);
  If Start<>0 Then S:=S+', partition de type '+HexStr(PartType)+', '+
    IntStr(Sectors Div 2048)+' Mo';
  KPrintLn(S);
 End;
End;

Procedure StartInit;
{ processus 1 : /etc/init (ou /bin/sh) }
Var P,Fd,F,Vn,E,L: Integer; Path: String;

 Procedure SetArgs(A: String);
 Var I: Integer;
 Begin
  For I:=1 To Length(A) Do InitArgs[I-1]:=A[I];
  InitArgs[Length(A)]:=#0; InitArgs[Length(A)+1]:=#0;
  { env : PATH et HOME }
  L:=Length(A)+2;
  A:='PATH=/bin:/usr/bin';
  For I:=1 To Length(A) Do InitArgs[L+I-1]:=A[I];
  Inc(L,Length(A)); InitArgs[L]:=#0; Inc(L);
  A:='HOME=/';
  For I:=1 To Length(A) Do InitArgs[L+I-1]:=A[I];
  Inc(L,Length(A)); InitArgs[L]:=#0; Inc(L);
  InitArgs[L]:=#0; Inc(L);
 End;

Begin
 P:=1;
 FillChar(Procs[P].Fd,SizeOf(Procs[P].Fd),0);
 Procs[P].Pid:=1; Procs[P].PPid:=0; Procs[P].Cwd:='/';
 Procs[P].Name:='init'; Procs[P].Size:=0;
 Procs[P].Stat:=PSLEEP;
 Cur:=P;
 { descripteurs 0, 1 et 2 : la console }
 E:=Namei('/dev/tty',Vn);
 If E<>0 Then Panic('/dev/tty introuvable');
 F:=FAlloc(Vn,O_RDWR);
 Procs[P].Fd[0]:=F; Procs[P].Fd[1]:=F; Procs[P].Fd[2]:=F;
 FRef(F); FRef(F);
 Path:='/etc/init'; SetArgs(Path);
 E:=DoExec(Path,Seg(InitArgs),Ofs(InitArgs),L);
 If E<>0 Then Begin
  Path:='/bin/sh'; SetArgs(Path);
  E:=DoExec(Path,Seg(InitArgs),Ofs(InitArgs),L);
 End;
 If E<>0 Then Panic('impossible de lancer /etc/init ou /bin/sh (erreur '+
   IntStr(E)+')');
 KPrintLn('init : '+Path+' (pid 1)');
 SetupKStack(P);
 Procs[P].Stat:=PRUN;
 Cur:=0;
End;

Const
 CSegStart=$1000;   { paragraphe de chargement du noyau (UPC /K) }

Var
 I,E: Integer;
 KStk: Word;
 Root: String;

BEGIN
 { le secteur d'amorce (0000:7C00) contient encore le BPB }
 BootDrive:=Mem[0:$7C24];
 BootStart:=MemL[0:$7C1C];
 KDataSeg:=DSeg;
 ConPage:=Mem[$40:$62];
 SerialInit;
 KPrintLn('');
 KPrintLn('UNIX-0 version '+KVersion+' (noyau 16 bits pour IBM PC 8086)');
 BootTime:=ReadRTC;
 MemTop:=MemW[$40:$13]*64;
 { fin des donnees du noyau : les longueurs des donnees stockees et du BSS
   sont dans le code de demarrage (mov di,n ; mov cx,m a 1000:000C) }
 KernelEnd:=DSeg+(Longint(MemW[CSegStart:$0D])+MemW[CSegStart:$10]+15) Div 16+1;
 KPrintLn('memoire : '+IntStr(MemW[$40:$13])+' Ko, noyau '+
   IntStr((Longint(KernelEnd)-$1000) Div 64)+' Ko a 1000:0000, donnees a '+
   HexStr(DSeg)+':0000');
 CoreInit(KernelEnd,MemTop);
 KStk:=CoreAlloc(NPROC*KSTKPARAS);
 If KStk=0 Then Panic('pas de memoire pour les piles noyau');
 FarFill(KStk,0,NPROC*KSTKPARAS*16,$CC);
 For I:=0 To NPROC-1 Do Begin
  FillChar(Procs[I],SizeOf(TProc),0);
  Procs[I].KStack:=KStk+I*KSTKPARAS;
  Procs[I].Cwd:='/';
 End;
 { processus 0 : contexte d'amorce, ne redevient jamais pret }
 Procs[0].Stat:=PSLEEP; Procs[0].Pid:=0; Procs[0].Name:='swapper';
 Procs[0].KStack:=0;
 Cur:=0; NextPid:=1;
 KPrintLn('memoire libre : '+IntStr(Longint(CoreFreeTotal)*16 Div 1024)+' Ko');
 { disques }
 DiskInit;
 ProbeDisks;
 ShowDisks;
 { vecteurs d'interruption }
 SysHook:=@SysDispatch; PreemptHook:=@PreemptEntry; FaultHook:=@FaultEntry;
 IdleHook:=@TtyPoll;
 OldInt08:=GetVector($08); OldInt1B:=GetVector($1B);
 SetVector($80,Seg(Int80Stub),Ofs(Int80Stub));
 SetVector($00,Seg(Int00Stub),Ofs(Int00Stub));
 SetVector($1B,Seg(Int1BStub),Ofs(Int1BStub));
 SetVector($21,Seg(NoDosStub),Ofs(NoDosStub));
 SetVector($08,Seg(Int08Stub),Ofs(Int08Stub));
 { systemes de fichiers }
 Root:=RootDevice;
 If Root='' Then Panic('unite d''amorce inconnue');
 E:=DoMount(Root,'/',0);
 If E<>0 Then Panic('montage de la racine impossible ('+IntStr(E)+')');
 KPrintLn('racine : /dev/'+Root+' ('+
   Copy('FAT12FAT16UFS  ',(Mounts[1].Typ-1)*5+1,5)+')');
 E:=DoMount('devfs','/dev',0);
 { partitions UFS (FreeBSD, type A5h) montees sur /usr }
 For I:=0 To DiskCount-1 Do
  If Disks[I].PartType In [$A5,$A6,$A9] Then
   If Not IsMountDir('/usr') Then Begin
    E:=DoMount(Disks[I].Name,'/usr',2);
    If E=0 Then KPrintLn('/usr : /dev/'+Disks[I].Name+' (UFS)')
    Else KPrintLn('/dev/'+Disks[I].Name+' : pas de systeme UFS ('+IntStr(E)+')');
   End;
 StartInit;
 SchedOn:=True;
 Swtch;
 Panic('retour au processus 0');
END.
