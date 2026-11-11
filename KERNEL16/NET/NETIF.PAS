{ @author: Sylvain Maltais (support@gladir.com)
  @created: 2026
  @website(https://www.gladir.com/unix-0)
  @abstract(Target: Unix Pascal (UPC /K), inclus par KERNEL16/KERNEL.PAS)
  @description: Reseau de UNIX-0, couche de base (segment-unite KNetIf) :
   - table des interfaces (ifnet de BSD) : nom (lo0, ne0, pk0), pilote,
     adresse Ethernet, adresse IP, masque, diffusion, drapeaux, compteurs;
   - tampons de trames (mbufs simplifies) : NPKT tampons de 1536 octets,
     chaine des tampons libres et file d'entree (trames recues en attente
     de traitement par NetIsr, comme ipintrq);
   - tampons circulaires des sockets (emission et reception);
   - somme de controle de l'Internet (RFC 1071), ordre des octets;
   - interruption materielle d'une carte : le gestionnaire masque la ligne
     au 8259 et ne touche pas a la carte; la reception se fait ensuite dans
     NetIsr (appelee par l'ordonnanceur, hors interruption), qui demasque.
  Les tampons (29,5 Ko) occupent la memoire basse de 00600h a 07FFFh,
  libre apres l'amorce (pile du processus 0 et secteur d'amorce, qui ne
  servent plus une fois init lance) : le reseau ne prend rien a la memoire
  des processus. Ils sont prepares a la premiere utilisation (ifconfig,
  socket), toujours apres le demarrage d'init.
  Les adresses IP sont des Longint dont les octets, en memoire, sont dans
  l'ordre du reseau (127.0.0.1 = 7F 00 00 01) : elles se recopient telles
  quelles dans les en-tetes; les ports sont gardes dans l'ordre de l'hote.
}

{ ====================================================================== }
SegmentUnit KNetIf;
Uses KTypes,KLib,KMem,KSched;
SegmentInterface

Const
 NIF=4;              { interfaces }
 NPKT=7;             { tampons de trames }
 PKTSIZE=1536;
 NRXQ=2;             { trames recues par le pilote de paquets (INT 60h) }
 NSOCK=8;            { sockets }
 SBSIZE=1024;        { tampon d'emission, et de reception, d'un socket }
 RXQBASE=NPKT*PKTSIZE;
 SBBASE=RXQBASE+NRXQ*PKTSIZE;
 NETBYTES=Longint(SBBASE)+Longint(NSOCK)*2*SBSIZE;
 NETSEGMENT=$0060;   { memoire basse : 00600h-07FFFh (7A00h octets) }
 NETMAX=$7A00;

 ETHHDR=14;          { en-tete Ethernet }
 ETHERTYPE_IP=$0800;
 ETHERTYPE_ARP=$0806;
 ETHERMIN=60;

 { pilotes }
 DRVLOOP=1; DRVNE2000=2; DRVPKT=3;

 { drapeaux d'interface (valeurs de BSD) }
 IFF_UP=1; IFF_BROADCAST=2; IFF_LOOPBACK=8; IFF_RUNNING=$40;

 { types et etats de sockets }
 SOCK_STREAM=1; SOCK_DGRAM=2; SOCK_RAW=3;
 SS_NOFDREF=1; SS_CANTRCVMORE=2; SS_CANTSENDMORE=4; SS_NBIO=8;
 SS_ISCONNECTED=16;
 SO_REUSEADDR=4; SO_KEEPALIVE=8; SO_BROADCAST=$20;

 { etats TCP (numeros de BSD) }
 TCPS_CLOSED=0; TCPS_LISTEN=1; TCPS_SYN_SENT=2; TCPS_SYN_RCVD=3;
 TCPS_ESTABLISHED=4; TCPS_CLOSE_WAIT=5; TCPS_FIN_WAIT_1=6; TCPS_CLOSING=7;
 TCPS_LAST_ACK=8; TCPS_FIN_WAIT_2=9; TCPS_TIME_WAIT=10;

 { canaux de sommeil des sockets }
 CHSOCK=192;

 { erreurs du reseau (valeurs de 4.2BSD) }
 EWOULDBLOCK=35; EINPROGRESS=36; EALREADY=37; ENOTSOCK=38;
 EDESTADDRREQ=39; EMSGSIZE=40; EPROTOTYPE=41; ENOPROTOOPT=42;
 EPROTONOSUPPORT=43; ESOCKTNOSUPPORT=44; EOPNOTSUPP=45; EAFNOSUPPORT=47;
 EADDRINUSE=48; EADDRNOTAVAIL=49; ENETDOWN=50; ENETUNREACH=51;
 ECONNABORTED=53; ECONNRESET=54; ENOBUFS=55; EISCONN=56; ENOTCONN=57;
 ESHUTDOWN=58; ETIMEDOUT=60; ECONNREFUSED=61; EHOSTUNREACH=65;

Type
 TMac=Array[0..5] Of Byte;

 TIf=Record
  Used: Boolean;
  Name: String[7];
  Drv: Byte;            { DRVLOOP, DRVNE2000, DRVPKT }
  Flags: Word;          { IFF_... }
  Mtu: Word;
  Mac: TMac;
  Addr, Mask, Bcast: Longint;
  IoBase: Word;         { NE2000 : ports; pilote de paquets : vecteur }
  Irq: Byte;            { 0 = scrutation seule }
  Model: String[23];    { description du materiel }
  Wide: Boolean;        { NE2000 : bus de 16 bits }
  Handle: Word;         { pilote de paquets : poignee de access_type }
  IPackets, OPackets, IErrors, OErrors, IBytes, OBytes: Longint;
 End;

 TSock=Record
  Used: Boolean;
  Typ: Byte;            { SOCK_STREAM, SOCK_DGRAM, SOCK_RAW }
  Proto: Byte;
  Opts: Word;           { SO_... }
  SFlags: Word;         { SS_... }
  Error: Word;          { erreur en attente (so_error) }
  IfIdx: ShortInt;      { interface imposee pour la diffusion (-1) }
  LAddr, FAddr: Longint;
  LPort, FPort: Word;
  RcvHead, RcvCnt: Word;   { tampons circulaires dans NetSeg }
  SndHead, SndCnt: Word;
  { TCP }
  State: Byte;
  Iss, Irs, SndUna, SndNxt, SndMax, RcvNxt: Longint;
  SndWnd: Word;         { fenetre annoncee par le pair }
  RcvAdv: Word;         { fenetre que nous avons annoncee }
  Mss: Word;
  RxtAt: Longint;       { echeance de retransmission (tops, 0 = arretee) }
  RxtShift: Byte;
  TimerAt: Longint;     { TIME_WAIT, FIN_WAIT_2 orphelin }
  FinQueued, FinSent: Boolean;
  FinSeq: Longint;
  AckNow, Probe: Boolean;
  Head: ShortInt;       { socket d'ecoute d'origine (-1) }
  QLimit, QLen: Byte;   { ecoute : file des connexions }
 End;

Var
 NetSeg: Word;                  { segment des tampons (0 = pas encore) }
 Ifs: Array[0..NIF-1] Of TIf;
 Socks: Array[0..NSOCK-1] Of TSock;
 PktLen: Array[0..NPKT-1] Of Word;
 PktIf: Array[0..NPKT-1] Of Byte;
 PktNext: Array[0..NPKT-1] Of ShortInt;
 FreeHead, InHead, InTail: ShortInt;
 PktFreeCount: Integer;
 { pilote de paquets : trames deposees par la fonction de reception }
 RxqLen: Array[0..NRXQ-1] Of Word;
 RxqOfs: Array[0..NRXQ-1] Of Word;
 RxqHead, RxqTail, RxqCount, RxqPending: Word;
 RxqDrops: Longint;
 { interruption de la carte }
 NetIrqHit: Byte;
 NetIrqLine: Byte;              { 0 = aucune }
 NetPicPort: Word;              { 21h ou A1h }
 NetIrqBit: Byte;
 OldNetVec: Pointer;
 CkResult: Word;
 NetOn: Boolean;                { pile active (segment alloue) }
 NetMore: Boolean;              { une carte garde des trames (tampons pleins) }

Function NetAlloc: Boolean;
Function PktOfs(P: Integer): Word;
Function PktGet: Integer;
Procedure PktFree(P: Integer);
Procedure InEnqueue(P: Integer);
Function InDequeue: Integer;
Function IfAdd(Name: String; Drv: Byte): Integer;
Function IfFind(Name: String): Integer;
Procedure CkSum(Sg, Os, Len: Word; Init: Longint);
Function GetN16(Sg, Os: Word): Word;
Procedure PutN16(Sg, Os, V: Word);
Function GetN32(Sg, Os: Word): Longint;
Procedure PutN32(Sg, Os: Word; V: Longint);
Function IpStr(A: Longint): String;
Function MacStr(Var M: TMac): String;
Function SbRcvOfs(S: Integer): Word;
Function SbSndOfs(S: Integer): Word;
Procedure RingPut(Base: Word; Var Head, Cnt: Word; Sg, Os, N: Word);
Procedure RingGet(Base: Word; Var Head, Cnt: Word; Sg, Os, N: Word);
Procedure RingPeek(Base, Head, Off: Word; Sg, Os, N: Word);
Procedure RingDrop(Var Head, Cnt: Word; N: Word);
Procedure NetIrqStub;
Procedure NetIrqAttach(Line: Byte);
Procedure NetIrqAck;

SegmentImplementation

Function NetAlloc: Boolean;
{ tampons en memoire basse, libre une fois l'amorce terminee (jamais
  pendant le demarrage : la pile du processus 0 y est encore) }
Var I: Integer;
Begin
 If NetSeg=0 Then Begin
  If (Cur=0) Or (NETBYTES>NETMAX) Then Begin NetAlloc:=False; Exit End;
  NetSeg:=NETSEGMENT;
  FarFill(NetSeg,0,Word(NETBYTES),0);
  FreeHead:=-1;
  For I:=NPKT-1 DownTo 0 Do Begin PktNext[I]:=FreeHead; FreeHead:=I End;
  PktFreeCount:=NPKT;
  InHead:=-1; InTail:=-1;
  For I:=0 To NRXQ-1 Do RxqOfs[I]:=RXQBASE+Word(I)*PKTSIZE;
  RxqHead:=0; RxqTail:=0; RxqCount:=0;
  NetOn:=True;
 End;
 NetAlloc:=True;
End;

Function PktOfs(P: Integer): Word;
Begin
 PktOfs:=Word(P)*PKTSIZE;
End;

Function PktGet: Integer;
Var P: Integer;
Begin
 P:=FreeHead;
 If P>=0 Then Begin
  FreeHead:=PktNext[P]; PktNext[P]:=-1; PktLen[P]:=0; Dec(PktFreeCount);
 End;
 PktGet:=P;
End;

Procedure PktFree(P: Integer);
Begin
 If (P<0) Or (P>=NPKT) Then Exit;
 PktNext[P]:=FreeHead; FreeHead:=P; Inc(PktFreeCount);
End;

Procedure InEnqueue(P: Integer);
Begin
 PktNext[P]:=-1;
 If InTail<0 Then InHead:=P Else PktNext[InTail]:=P;
 InTail:=P;
End;

Function InDequeue: Integer;
Var P: Integer;
Begin
 P:=InHead;
 If P>=0 Then Begin
  InHead:=PktNext[P];
  If InHead<0 Then InTail:=-1;
  PktNext[P]:=-1;
 End;
 InDequeue:=P;
End;

Function IfAdd(Name: String; Drv: Byte): Integer;
Var I: Integer;
Begin
 IfAdd:=-1;
 For I:=0 To NIF-1 Do If Not Ifs[I].Used Then Begin
  FillChar(Ifs[I],SizeOf(TIf),0);
  Ifs[I].Used:=True; Ifs[I].Name:=Name; Ifs[I].Drv:=Drv; Ifs[I].Mtu:=1500;
  IfAdd:=I; Exit;
 End;
End;

Function IfFind(Name: String): Integer;
Var I: Integer;
Begin
 IfFind:=-1;
 For I:=0 To NIF-1 Do
  If Ifs[I].Used And (Ifs[I].Name=Name) Then Begin IfFind:=I; Exit End;
End;

Procedure CkSum(Sg, Os, Len: Word; Init: Longint); Assembler;
{ somme de controle de l'Internet : complement a un de la somme des mots
  de 16 bits (lus tels quels en memoire; le resultat, range tel quel, est
  dans le bon ordre), plus Init (somme partielle, pseudo-en-tete) ->
  CkResult }
Asm
 PUSH DS
 MOV BX,WORD PTR Init
 MOV DX,WORD PTR Init+2
 MOV CX,Len
 MOV SI,Os
 MOV AX,Sg
 MOV DS,AX
 CLD
 SHR CX,1
 PUSHF
 JCXZ @Odd
@L:
 LODSW
 ADD BX,AX
 ADC DX,0
 LOOP @L
@Odd:
 POPF
 JNC @Fold
 LODSB
 XOR AH,AH
 ADD BX,AX
 ADC DX,0
@Fold:
 ADD BX,DX
 ADC BX,0
 NOT BX
 POP DS
 MOV CkResult,BX
End;

Function GetN16(Sg, Os: Word): Word;
Begin
 GetN16:=Swap(MemW[Sg:Os]);
End;

Procedure PutN16(Sg, Os, V: Word);
Begin
 MemW[Sg:Os]:=Swap(V);
End;

Function GetN32(Sg, Os: Word): Longint;
Begin
 GetN32:=(Longint(Swap(MemW[Sg:Os])) Shl 16) Or Swap(MemW[Sg:Os+2]);
End;

Procedure PutN32(Sg, Os: Word; V: Longint);
Begin
 MemW[Sg:Os]:=Swap(Word(V Shr 16));
 MemW[Sg:Os+2]:=Swap(Word(V));
End;

Function IpStr(A: Longint): String;
Begin
 IpStr:=IntStr(A And $FF)+'.'+IntStr((A Shr 8) And $FF)+'.'+
   IntStr((A Shr 16) And $FF)+'.'+IntStr((A Shr 24) And $FF);
End;

Function MacStr(Var M: TMac): String;
Var S: String; I: Integer;
Begin
 S:='';
 For I:=0 To 5 Do Begin
  If I>0 Then S:=S+':';
  S:=S+LowStr(Copy(HexStr(M[I]),3,2));
 End;
 MacStr:=S;
End;

Function SbRcvOfs(S: Integer): Word;
Begin
 SbRcvOfs:=SBBASE+Word(S)*(2*SBSIZE);
End;

Function SbSndOfs(S: Integer): Word;
Begin
 SbSndOfs:=SBBASE+Word(S)*(2*SBSIZE)+SBSIZE;
End;

Procedure RingPut(Base: Word; Var Head, Cnt: Word; Sg, Os, N: Word);
{ ajoute N octets (Sg:Os) a la fin du tampon circulaire Base }
Var T,K: Word;
Begin
 T:=(Head+Cnt) Mod SBSIZE;
 K:=SBSIZE-T; If K>N Then K:=N;
 FarMove(Sg,Os,NetSeg,Base+T,K);
 If N>K Then FarMove(Sg,Os+K,NetSeg,Base,N-K);
 Inc(Cnt,N);
End;

Procedure RingPeek(Base, Head, Off: Word; Sg, Os, N: Word);
{ copie N octets a partir de la position Off (depuis la tete) }
Var T,K: Word;
Begin
 T:=(Head+Off) Mod SBSIZE;
 K:=SBSIZE-T; If K>N Then K:=N;
 FarMove(NetSeg,Base+T,Sg,Os,K);
 If N>K Then FarMove(NetSeg,Base,Sg,Os+K,N-K);
End;

Procedure RingDrop(Var Head, Cnt: Word; N: Word);
Begin
 If N>Cnt Then N:=Cnt;
 Head:=(Head+N) Mod SBSIZE; Dec(Cnt,N);
End;

Procedure RingGet(Base: Word; Var Head, Cnt: Word; Sg, Os, N: Word);
Begin
 RingPeek(Base,Head,0,Sg,Os,N);
 RingDrop(Head,Cnt,N);
End;

Procedure NetIrqStub; Assembler;
{ IRQ de la carte : la ligne est masquee au 8259 (la carte garde sa demande
  jusqu'a ce que NetIsr la traite et demasque), fin d'interruption }
Asm
 PUSH AX
 PUSH DX
 PUSH DS
 MOV AX,SEG @DATA
 MOV DS,AX
 MOV NetIrqHit,1
 MOV DX,NetPicPort
 IN AL,DX
 OR AL,NetIrqBit
 OUT DX,AL
 MOV AL,20h
 CMP DX,21h
 JE @Maitre
 OUT 0A0h,AL
@Maitre:
 OUT 20h,AL
 POP DS
 POP DX
 POP AX
 IRET
End;

Procedure NetIrqAttach(Line: Byte);
Var V: Byte;
Begin
 If (Line=0) Or (Line>15) Or (Line=2) Then Exit;
 NetIrqLine:=Line;
 If Line<8 Then Begin
  V:=8+Line; NetPicPort:=$21; NetIrqBit:=1 Shl Line;
 End Else Begin
  V:=$70+Line-8; NetPicPort:=$A1; NetIrqBit:=1 Shl (Line-8);
  { cascade du 8259 esclave (IRQ 2) }
  Port[$21]:=Port[$21] And Not 4;
 End;
 OldNetVec:=GetVector(V);
 SetVector(V,Seg(NetIrqStub),Ofs(NetIrqStub));
 Port[NetPicPort]:=Port[NetPicPort] And Not NetIrqBit;
End;

Procedure NetIrqAck;
{ apres le traitement de la carte : la ligne est de nouveau autorisee }
Begin
 If NetIrqLine=0 Then Exit;
 NetIrqHit:=0;
 Port[NetPicPort]:=Port[NetPicPort] And Not NetIrqBit;
End;

SegmentEnd;
