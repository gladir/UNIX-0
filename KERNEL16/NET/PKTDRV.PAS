{ @author: Sylvain Maltais (support@gladir.com)
  @created: 2026
  @website(https://www.gladir.com/unix-0)
  @abstract(Target: Unix Pascal (UPC /K), inclus par KERNEL16/KERNEL.PAS)
  @description: Interface pk0 de UNIX-0 : pilote de paquets de FTP Software
   (Packet Driver Specification 1.11, segment-unite KPktDrv). Un pilote de
   paquets deja present en memoire au demarrage (vecteur 60h a 80h dont le
   gestionnaire porte la signature "PKT DRVR") sert de carte reseau : par
   exemple un pilote charge par une ROM d'amorce, ou celui d'un emulateur
   (l'option Reseau LAN de DEVENV en emule un, mais ses appels INT 60h
   n'aboutissent pas encore depuis un systeme amorce : voir
   KERNEL16/LISEZMOI.md).
   - access_type (classe 1 : Ethernet DIX, tous les types de trames),
     get_address, set_rcv_mode (adresse propre et diffusion), send_pkt;
   - la fonction de reception (appelee par le pilote, souvent pendant une
     interruption) depose la trame dans une petite file du segment des
     tampons (NRXQ trames); NetIsr la recopie ensuite dans un tampon du
     noyau et la traite hors interruption.
}

{ ====================================================================== }
SegmentUnit KPktDrv;
Uses KTypes,KLib,KSched,KNetIf;
SegmentInterface

Function PktProbe: Integer;
Function PktInit(I: Integer): Boolean;
Procedure PktStop(I: Integer);
Procedure PktSend(I, P: Integer);
Procedure PktPoll(I: Integer);

SegmentImplementation

Var
 { appel du pilote : registres d'entree et de sortie }
 RAX, RBX, RCX, RDX, RSI, RDI, RDS, RES, RFL: Word;
 Stub: Array[0..3] Of Byte;       { INT n ; RETF }
 StubOfs, StubSeg: Word;

Procedure CallDriver; Assembler;
{ INT n du pilote de paquets (instruction INT reelle : certains emulateurs
  n'interceptent que celle-ci), registres R.. }
Asm
 PUSH BP
 PUSH SI
 PUSH DI
 PUSH DS
 PUSH ES
 PUSH WORD PTR StubSeg
 PUSH WORD PTR StubOfs
 MOV AX,RES
 MOV ES,AX
 MOV BX,RBX
 MOV CX,RCX
 MOV DX,RDX
 MOV SI,RSI
 MOV DI,RDI
 PUSH WORD PTR RDS
 MOV AX,RAX
 POP DS
 MOV BP,SP
 CALL DWORD PTR [BP]
 PUSHF
 PUSH DS
 PUSH AX
 MOV AX,SEG @DATA
 MOV DS,AX
 POP AX
 MOV RAX,AX
 POP AX
 MOV RDS,AX
 POP AX
 MOV RFL,AX
 MOV RBX,BX
 MOV RCX,CX
 MOV RDX,DX
 MOV RSI,SI
 MOV RDI,DI
 MOV AX,ES
 MOV RES,AX
 ADD SP,4
 POP ES
 POP DS
 POP DI
 POP SI
 POP BP
End;

Procedure Receiver; Assembler;
{ appelee par le pilote : AX=0, CX = longueur -> ES:DI = tampon (0:0 pour
  refuser la trame); AX=1 : la trame a ete copiee }
Asm
 PUSH BX
 PUSH SI
 PUSH DS
 MOV BX,SEG @DATA
 MOV DS,BX
 OR AX,AX
 JNZ @Copiee
 CMP CX,PKTSIZE
 JA @Refus
 CMP RxqCount,NRXQ
 JAE @Refus
 MOV BX,RxqHead
 SHL BX,1
 MOV SI,OFFSET RxqOfs
 MOV DI,[SI+BX]
 MOV SI,OFFSET RxqLen
 MOV [SI+BX],CX
 MOV BX,NetSeg
 MOV ES,BX
 MOV RxqPending,1
 JMP @Fin
@Refus:
 ADD WORD PTR RxqDrops,1
 ADC WORD PTR RxqDrops+2,0
 XOR DI,DI
 MOV ES,DI
 JMP @Fin
@Copiee:
 CMP RxqPending,0
 JE @Fin
 MOV RxqPending,0
 MOV BX,RxqHead
 INC BX
 CMP BX,NRXQ
 JB @Tour
 XOR BX,BX
@Tour:
 MOV RxqHead,BX
 INC RxqCount
@Fin:
 POP DS
 POP SI
 POP BX
 RETF
End;

Function PktProbe: Integer;
{ premier vecteur de 60h a 80h dont le gestionnaire porte "PKT DRVR" }
Var V: Integer; P: Pointer; S,O: Word; K,I: Integer; Ok: Boolean;
    Name: String[23]; Sig: String[8];
Begin
 PktProbe:=0;
 For V:=$60 To $80 Do Begin
  P:=GetVector(V);
  S:=Seg(P^); O:=Ofs(P^);
  If (S=0) And (O=0) Then Continue;
  Sig:='';
  For K:=0 To 7 Do Sig:=Sig+Chr(Mem[S:O+3+K]);
  If Sig<>'PKT DRVR' Then Continue;
  Stub[0]:=$CD; Stub[1]:=V; Stub[2]:=$CB;
  StubSeg:=Seg(Stub); StubOfs:=Ofs(Stub);
  { driver_info : classe 1 (Ethernet) seulement }
  RAX:=$01FF; RBX:=$FFFF; RCX:=0; RDX:=0; RSI:=0; RDI:=0;
  RDS:=DSeg; RES:=DSeg;
  CallDriver;
  If (RFL And 1<>0) Or (Hi(RCX)<>1) Then Continue;
  Name:='';
  For K:=0 To 22 Do Begin
   If Mem[RDS:RSI+K]=0 Then Break;
   Name:=Name+Chr(Mem[RDS:RSI+K]);
  End;
  I:=IfAdd('pk0',DRVPKT);
  If I<0 Then Exit;
  Ifs[I].IoBase:=V;
  Ifs[I].Flags:=IFF_BROADCAST;
  If Name='' Then Name:='pilote de paquets';
  Ifs[I].Model:=Name;
  PktProbe:=1;
  Exit;
 End;
End;

Function PktInit(I: Integer): Boolean;
Var K: Integer;
Begin
 PktInit:=False;
 If Not NetAlloc Then Exit;
 If Ifs[I].Handle=0 Then Begin
  { access_type : classe 1, tout type d'interface, tous les types de
    trames (longueur de filtre 0) }
  RAX:=$0201; RBX:=$FFFF; RDX:=0; RCX:=0;
  RDS:=DSeg; RSI:=Ofs(Stub);
  RES:=Seg(Receiver); RDI:=Ofs(Receiver);
  CallDriver;
  If RFL And 1<>0 Then Exit;
  Ifs[I].Handle:=RAX;
 End;
 { get_address }
 RAX:=$0600; RBX:=Ifs[I].Handle; RCX:=6;
 RES:=Seg(Ifs[I].Mac); RDI:=Ofs(Ifs[I].Mac);
 RDS:=DSeg; RSI:=0;
 CallDriver;
 { set_rcv_mode 3 : propres trames et diffusion (erreur sans importance
   avec un pilote de niveau 1) }
 RAX:=$1400; RBX:=Ifs[I].Handle; RCX:=3;
 CallDriver;
 PktInit:=True;
End;

Procedure PktStop(I: Integer);
Begin
 { le pilote reste reserve : les trames recues sont ignorees par NetIsr }
End;

Procedure PktSend(I, P: Integer);
Var L: Word;
Begin
 L:=PktLen[P];
 If L<ETHERMIN Then Begin
  FarFill(NetSeg,PktOfs(P)+L,ETHERMIN-L,0); L:=ETHERMIN;
 End;
 RAX:=$0400; RBX:=Ifs[I].Handle; RCX:=L;
 RDS:=NetSeg; RSI:=PktOfs(P);
 RES:=DSeg; RDI:=0;
 CallDriver;
 If RFL And 1<>0 Then Inc(Ifs[I].OErrors)
 Else Begin Inc(Ifs[I].OPackets); Inc(Ifs[I].OBytes,L) End;
End;

Procedure PktPoll(I: Integer);
{ trames deposees par Receiver -> tampons du noyau, file d'entree }
Var P: Integer; L: Word;
Begin
 While RxqCount>0 Do Begin
  L:=RxqLen[RxqTail];
  If Ifs[I].Flags And IFF_UP<>0 Then Begin
   { plus de tampon libre : la trame attend dans la file du pilote }
   P:=PktGet;
   If P<0 Then Begin NetMore:=True; Exit End;
   FarMove(NetSeg,RxqOfs[RxqTail],NetSeg,PktOfs(P),L);
   PktLen[P]:=L; PktIf[P]:=I;
   InEnqueue(P);
   Inc(Ifs[I].IPackets); Inc(Ifs[I].IBytes,L);
  End;
  RxqTail:=(RxqTail+1) Mod NRXQ;
  Asm CLI End;
  Dec(RxqCount);
  Asm STI End;
 End;
End;

SegmentEnd;
