{ @author: Sylvain Maltais (support@gladir.com)
  @created: 2026
  @website(https://www.gladir.com/unix-0)
  @abstract(Target: Unix Pascal (UPC /K), inclus par KERNEL16/KERNEL.PAS)
  @description: Pilote des cartes Ethernet NE2000 et NE1000 (Novell/Eagle,
   controleur National Semiconductor DP8390) pour UNIX-0, interfaces ne0,
   ne1 (segment-unite KNe2000) :
   - carte ISA : recherche aux ports 300h, 280h, 320h, 340h, 360h et 240h
     (remise a zero, signature "WW" de la PROM de la NE2000, bus de 16 ou
     8 bits), IRQ trouvee en observant le registre IRR des 8259 pendant que
     la carte demande une interruption (fin de DMA distant);
   - carte PCI compatible NE2000 (Realtek RTL8029, 10EC:8029) : port et IRQ
     lus dans l'espace de configuration par le BIOS PCI (INT 1Ah, fonctions
     B1xxh, registres de 16 bits seulement);
   - memoire de la carte (16 Ko de 4000h a 7FFFh, 8 Ko pour la NE1000) :
     6 pages d'emission, puis l'anneau de reception;
   - emission : copie par DMA distant (port de donnees 10h), puis
     commande TXP; reception (NetIsr) : trames de l'anneau entre BNRY et
     CURR copiees dans les tampons du noyau, puis file d'entree; debordement
     de l'anneau : la carte est reinitialisee.
}

{ ====================================================================== }
SegmentUnit KNe2000;
Uses KTypes,KLib,KNetIf;
SegmentInterface

Function Ne2000Probe: Integer;
Function Ne2000Init(I: Integer): Boolean;
Procedure Ne2000Stop(I: Integer);
Procedure Ne2000Send(I, P: Integer);
Procedure Ne2000Poll(I: Integer);

SegmentImplementation

Const
 { registres (page 0, sauf mention) }
 RCR_=0; RPSTART=1; RPSTOP=2; RBNRY=3; RTPSR=4; RTBCR0=5; RTBCR1=6;
 RISR=7; RRSAR0=8; RRSAR1=9; RRBCR0=$A; RRBCR1=$B; RRCR=$C; RTCR=$D;
 RDCR=$E; RIMR=$F; RDATA=$10; RRESET=$1F;
 RPAR0=1; RCURR=7; RMAR0=8;            { page 1 }
 { registre de commande }
 CR_STP=1; CR_STA=2; CR_TXP=4; CR_RREAD=8; CR_RWRITE=$10; CR_NODMA=$20;
 CR_PAGE1=$40;
 { ISR }
 ISR_PRX=1; ISR_PTX=2; ISR_RXE=4; ISR_TXE=8; ISR_OVW=$10; ISR_RDC=$40;
 ISR_RST=$80;
 NIOPORTS=6;
 IoPorts: Array[1..NIOPORTS] Of Word=($300,$280,$320,$340,$360,$240);

Var
 TxPage, RxStart, RxStop: Array[0..NIF-1] Of Byte;
 RingMore: Array[0..NIF-1] Of Boolean;   { trames laissees dans l'anneau }
 Prom: Array[0..15] Of Byte;

Procedure Wait(B: Word; Bit: Byte);
{ attend un bit de l'ISR (limite : environ 50 ms) }
Var K: Word;
Begin
 K:=0;
 While (Port[B+RISR] And Bit=0) And (K<60000) Do Inc(K);
End;

Procedure InWords(P, Sg, Os, N: Word); Assembler;
Asm
 MOV DX,P
 MOV CX,N
 JCXZ @F
 MOV ES,Sg
 MOV DI,Os
 CLD
@L:
 IN AX,DX
 STOSW
 LOOP @L
@F:
End;

Procedure InBytes(P, Sg, Os, N: Word); Assembler;
Asm
 MOV DX,P
 MOV CX,N
 JCXZ @F
 MOV ES,Sg
 MOV DI,Os
 CLD
@L:
 IN AL,DX
 STOSB
 LOOP @L
@F:
End;

Procedure OutWords(P, Sg, Os, N: Word); Assembler;
Asm
 PUSH DS
 MOV DX,P
 MOV CX,N
 JCXZ @F
 MOV SI,Os
 MOV AX,Sg
 MOV DS,AX
 CLD
@L:
 LODSW
 OUT DX,AX
 LOOP @L
@F:
 POP DS
End;

Procedure OutBytes(P, Sg, Os, N: Word); Assembler;
Asm
 PUSH DS
 MOV DX,P
 MOV CX,N
 JCXZ @F
 MOV SI,Os
 MOV AX,Sg
 MOV DS,AX
 CLD
@L:
 LODSB
 OUT DX,AL
 LOOP @L
@F:
 POP DS
End;

Procedure RemoteRead(B: Word; Wide: Boolean; Addr, Sg, Os, N: Word);
{ copie N octets de la memoire de la carte (Addr) vers Sg:Os }
Var C: Word;
Begin
 C:=N; If Wide And Odd(C) Then Inc(C);
 Port[B+RCR_]:=CR_NODMA Or CR_STA;
 Port[B+RRBCR0]:=Lo(C); Port[B+RRBCR1]:=Hi(C);
 Port[B+RRSAR0]:=Lo(Addr); Port[B+RRSAR1]:=Hi(Addr);
 Port[B+RCR_]:=CR_RREAD Or CR_STA;
 If Wide Then Begin
  InWords(B+RDATA,Sg,Os,N Shr 1);
  If Odd(N) Then Mem[Sg:Os+N-1]:=Lo(PortW[B+RDATA]);
 End Else InBytes(B+RDATA,Sg,Os,N);
 Wait(B,ISR_RDC);
 Port[B+RISR]:=ISR_RDC;
End;

Function Reset(B: Word): Boolean;
Var V: Byte; K: Word;
Begin
 Reset:=False;
 V:=Port[B+RCR_];
 If V=$FF Then Exit;
 V:=Port[B+RRESET];
 Port[B+RRESET]:=V;
 K:=0;
 While (Port[B+RISR] And ISR_RST=0) And (K<30000) Do Inc(K);
 If K>=30000 Then Exit;
 Port[B+RISR]:=$FF;
 Port[B+RCR_]:=CR_NODMA Or CR_STP;
 Reset:=(Port[B+RCR_] And (CR_STP Or CR_STA Or CR_PAGE1 Or $80))=CR_STP;
End;

Function ReadProm(B: Word; Var Wide: Boolean): Boolean;
{ adresse Ethernet : PROM de la carte (en mode 16 bits, chaque octet de la
  PROM est lu double) }
Var Buf: Array[0..31] Of Byte; K: Integer;
Begin
 ReadProm:=False;
 Port[B+RDCR]:=$49;                { mots, FIFO de 8 octets }
 Port[B+RRBCR0]:=0; Port[B+RRBCR1]:=0;
 Port[B+RIMR]:=0; Port[B+RISR]:=$FF;
 Port[B+RRCR]:=$20;                { reception arretee }
 Port[B+RTCR]:=$02;                { emission en boucle interne }
 RemoteRead(B,True,0,Seg(Buf),Ofs(Buf),32);
 For K:=0 To 15 Do Prom[K]:=Buf[K*2];
 If (Prom[14]=$57) And (Prom[15]=$57) Then Begin
  Wide:=True; ReadProm:=True; Exit;
 End;
 { NE1000 : bus de 8 bits }
 Port[B+RDCR]:=$48;
 RemoteRead(B,False,0,Seg(Buf),Ofs(Buf),32);
 For K:=0 To 15 Do Prom[K]:=Buf[K];
 Wide:=False;
 ReadProm:=Not ((Prom[0]=$FF) And (Prom[1]=$FF)) And
   Not ((Prom[0]=0) And (Prom[1]=0) And (Prom[2]=0));
End;

Function ProbeIrq(B: Word; Wide: Boolean): Byte;
{ la carte demande une interruption (fin de DMA distant) : la ligne qui
  apparait dans les registres IRR des 8259 est la sienne }
Var I0,I1,A0,A1: Byte; Diff: Word; K: Integer; Dummy: Array[0..3] Of Byte;
Begin
 ProbeIrq:=0;
 Asm CLI End;
 Port[$20]:=$0A; I0:=Port[$20];
 Port[$A0]:=$0A; I1:=Port[$A0];
 Port[B+RISR]:=$FF;
 Port[B+RIMR]:=ISR_RDC;
 Port[B+RCR_]:=CR_NODMA Or CR_STA;
 Port[B+RRBCR0]:=4; Port[B+RRBCR1]:=0;
 Port[B+RRSAR0]:=0; Port[B+RRSAR1]:=0;
 Port[B+RCR_]:=CR_RREAD Or CR_STA;
 If Wide Then InWords(B+RDATA,Seg(Dummy),Ofs(Dummy),2)
 Else InBytes(B+RDATA,Seg(Dummy),Ofs(Dummy),4);
 For K:=1 To 2000 Do ;
 Port[$20]:=$0A; A0:=Port[$20];
 Port[$A0]:=$0A; A1:=Port[$A0];
 Port[B+RIMR]:=0; Port[B+RISR]:=$FF;
 Port[B+RCR_]:=CR_NODMA Or CR_STP;
 Asm STI End;
 Diff:=(Word(A1 And Not I1) Shl 8) Or (A0 And Not I0);
 Diff:=Diff And Not $0007;        { horloge, clavier, cascade }
 For K:=3 To 15 Do
  If Diff=(1 Shl K) Then ProbeIrq:=K;
End;

Function Attach(B: Word; Pci: Boolean; Irq: Byte): Integer;
Var I,K: Integer; Wide: Boolean; N: String[7];
Begin
 Attach:=-1;
 If Not Reset(B) Then Exit;
 If Not ReadProm(B,Wide) Then Exit;
 N:='ne0';
 While IfFind(N)>=0 Do N[3]:=Succ(N[3]);
 I:=IfAdd(N,DRVNE2000);
 If I<0 Then Exit;
 Ifs[I].IoBase:=B;
 Ifs[I].Wide:=Wide;
 For K:=0 To 5 Do Ifs[I].Mac[K]:=Prom[K];
 Ifs[I].Flags:=IFF_BROADCAST;
 If Pci Then Ifs[I].Model:='NE2000 PCI (RTL8029)'
 Else If Wide Then Ifs[I].Model:='NE2000 ISA'
 Else Ifs[I].Model:='NE1000 ISA';
 If Wide Then Begin TxPage[I]:=$40; RxStart[I]:=$46; RxStop[I]:=$80 End
 Else Begin TxPage[I]:=$20; RxStart[I]:=$26; RxStop[I]:=$40 End;
 If Not Pci Then Irq:=ProbeIrq(B,Wide);
 Ifs[I].Irq:=Irq;
 Attach:=I;
End;

Function PciFind(Index: Word; Var BusDev: Word): Boolean;
Var Ok: Boolean; BD: Word;
Begin
 Ok:=False; BD:=0;
 Asm
  PUSH BP
  PUSH SI
  PUSH DI
  MOV AX,0B101h
  INT 1Ah
  JC @Non
  OR AH,AH
  JNZ @Non
  CMP DX,4350h            { 'PC' de "PCI " }
  JNE @Non
  MOV AX,0B102h
  MOV CX,8029h            { RTL8029 }
  MOV DX,10ECh            { Realtek }
  MOV SI,Index
  INT 1Ah
  JC @Non
  OR AH,AH
  JNZ @Non
  MOV BD,BX
  MOV Ok,1
 @Non:
  POP DI
  POP SI
  POP BP
 End;
 BusDev:=BD;
 PciFind:=Ok;
End;

Function PciRead(BusDev, Reg: Word): Word;
Var V: Word;
Begin
 V:=$FFFF;
 Asm
  PUSH BP
  PUSH SI
  PUSH DI
  MOV AX,0B109h
  MOV BX,BusDev
  MOV DI,Reg
  INT 1Ah
  JC @Err
  MOV V,CX
 @Err:
  POP DI
  POP SI
  POP BP
 End;
 PciRead:=V;
End;

Procedure PciWrite(BusDev, Reg, Val: Word);
Begin
 Asm
  PUSH BP
  PUSH SI
  PUSH DI
  MOV AX,0B10Ch
  MOV BX,BusDev
  MOV DI,Reg
  MOV CX,Val
  INT 1Ah
  POP DI
  POP SI
  POP BP
 End;
End;

Function Ne2000Probe: Integer;
Var N,K: Integer; BD,Bar,Cmd: Word; Irq: Byte;
Begin
 N:=0;
 { PCI }
 For K:=0 To 1 Do
  If PciFind(K,BD) Then Begin
   Bar:=PciRead(BD,$10);
   Irq:=Lo(PciRead(BD,$3C));
   Cmd:=PciRead(BD,4);
   If Cmd And 1=0 Then PciWrite(BD,4,Cmd Or 1);
   If (Bar And 1<>0) And (Bar And $FFFC<>0) Then
    If Attach(Bar And $FFFC,True,Irq)>=0 Then Inc(N);
  End;
 { ISA }
 For K:=1 To NIOPORTS Do
  If Attach(IoPorts[K],False,0)>=0 Then Inc(N);
 Ne2000Probe:=N;
End;

Function Ne2000Init(I: Integer): Boolean;
Var B: Word; K: Integer;
Begin
 B:=Ifs[I].IoBase;
 Ne2000Init:=False;
 If Not Reset(B) Then Exit;
 Port[B+RCR_]:=CR_NODMA Or CR_STP;
 If Ifs[I].Wide Then Port[B+RDCR]:=$49 Else Port[B+RDCR]:=$48;
 Port[B+RRBCR0]:=0; Port[B+RRBCR1]:=0;
 Port[B+RRCR]:=$20;                { surveillance pendant l'initialisation }
 Port[B+RTCR]:=$02;                { boucle interne }
 Port[B+RTPSR]:=TxPage[I];
 Port[B+RPSTART]:=RxStart[I];
 Port[B+RBNRY]:=RxStart[I];
 Port[B+RPSTOP]:=RxStop[I];
 Port[B+RISR]:=$FF;
 Port[B+RIMR]:=0;
 Port[B+RCR_]:=CR_PAGE1 Or CR_NODMA Or CR_STP;
 For K:=0 To 5 Do Port[B+RPAR0+K]:=Ifs[I].Mac[K];
 For K:=0 To 7 Do Port[B+RMAR0+K]:=$FF;
 Port[B+RCURR]:=RxStart[I]+1;
 Port[B+RCR_]:=CR_NODMA Or CR_STA;
 Port[B+RISR]:=$FF;
 If Ifs[I].Irq<>0 Then Port[B+RIMR]:=ISR_PRX Or ISR_RXE Or ISR_OVW;
 Port[B+RTCR]:=0;
 Port[B+RRCR]:=$04;                { trames de diffusion acceptees }
 Ne2000Init:=True;
End;

Procedure Ne2000Stop(I: Integer);
Var B: Word;
Begin
 B:=Ifs[I].IoBase;
 Port[B+RIMR]:=0;
 Port[B+RCR_]:=CR_NODMA Or CR_STP;
End;

Procedure Ne2000Send(I, P: Integer);
Var B,L,C,O: Word; K: Word;
Begin
 B:=Ifs[I].IoBase; L:=PktLen[P]; O:=PktOfs(P);
 If L<ETHERMIN Then Begin
  FarFill(NetSeg,O+L,ETHERMIN-L,0); L:=ETHERMIN;
 End;
 { emission precedente terminee }
 K:=0;
 While (Port[B+RCR_] And CR_TXP<>0) And (K<60000) Do Inc(K);
 C:=L; If Ifs[I].Wide And Odd(C) Then Inc(C);
 Port[B+RCR_]:=CR_NODMA Or CR_STA;
 Port[B+RISR]:=ISR_RDC;
 Port[B+RRBCR0]:=Lo(C); Port[B+RRBCR1]:=Hi(C);
 Port[B+RRSAR0]:=0; Port[B+RRSAR1]:=TxPage[I];
 Port[B+RCR_]:=CR_RWRITE Or CR_STA;
 If Ifs[I].Wide Then OutWords(B+RDATA,NetSeg,O,C Shr 1)
 Else OutBytes(B+RDATA,NetSeg,O,C);
 Wait(B,ISR_RDC);
 Port[B+RISR]:=ISR_RDC;
 Port[B+RTBCR0]:=Lo(L); Port[B+RTBCR1]:=Hi(L);
 Port[B+RTPSR]:=TxPage[I];
 Port[B+RCR_]:=CR_NODMA Or CR_TXP Or CR_STA;
 Inc(Ifs[I].OPackets); Inc(Ifs[I].OBytes,L);
End;

Procedure Ne2000Poll(I: Integer);
Var B: Word; Isr,Curr,Next,Nxt,Status: Byte; L,Count: Word;
    Hdr: Array[0..3] Of Byte; P,N: Integer;
Begin
 B:=Ifs[I].IoBase;
 Isr:=Port[B+RISR];
 If (Isr=0) And Not RingMore[I] Then Exit;
 If Isr And ISR_OVW<>0 Then Begin
  { debordement de l'anneau : la carte repart de zero }
  Inc(Ifs[I].IErrors);
  Ne2000Init(I);
  Exit;
 End;
 If (Isr And (ISR_PRX Or ISR_RXE)<>0) Or RingMore[I] Then Begin
  Port[B+RISR]:=ISR_PRX Or ISR_RXE;
  If Isr And ISR_RXE<>0 Then Inc(Ifs[I].IErrors);
  RingMore[I]:=False;
  N:=0;
  Repeat
   { plus de tampon libre : les trames restent dans l'anneau de la carte
     (NetIsr les reprendra apres avoir traite la file d'entree) }
   If FreeHead<0 Then Begin RingMore[I]:=True; NetMore:=True; Break End;
   Port[B+RCR_]:=CR_PAGE1 Or CR_NODMA Or CR_STA;
   Curr:=Port[B+RCURR];
   Port[B+RCR_]:=CR_NODMA Or CR_STA;
   Next:=Port[B+RBNRY]+1;
   If Next>=RxStop[I] Then Next:=RxStart[I];
   If Next=Curr Then Break;
   RemoteRead(B,Ifs[I].Wide,Word(Next) Shl 8,Seg(Hdr),Ofs(Hdr),4);
   Status:=Hdr[0]; Nxt:=Hdr[1];
   Count:=Hdr[2] Or (Word(Hdr[3]) Shl 8);
   L:=Count-4;
   If (Nxt<RxStart[I]) Or (Nxt>=RxStop[I]) Or (Count<4+ETHHDR) Or
     (L>1518) Then Begin
    { en-tete incoherent : l'anneau est reinitialise }
    Inc(Ifs[I].IErrors);
    Ne2000Init(I);
    Exit;
   End;
   If (Status And 1<>0) And (L<=PKTSIZE) Then Begin
    P:=PktGet;
    RemoteRead(B,Ifs[I].Wide,(Word(Next) Shl 8)+4,NetSeg,PktOfs(P),L);
    PktLen[P]:=L; PktIf[P]:=I;
    InEnqueue(P);
    Inc(Ifs[I].IPackets); Inc(Ifs[I].IBytes,L);
   End Else Inc(Ifs[I].IErrors);
   If Nxt=RxStart[I] Then Port[B+RBNRY]:=RxStop[I]-1
   Else Port[B+RBNRY]:=Nxt-1;
   Inc(N);
  Until N>=16;
  If N>=16 Then Begin RingMore[I]:=True; NetMore:=True End;
 End;
 If Isr And (ISR_PTX Or ISR_TXE)<>0 Then Begin
  If Isr And ISR_TXE<>0 Then Inc(Ifs[I].OErrors);
  Port[B+RISR]:=ISR_PTX Or ISR_TXE;
 End;
 If Isr And $20<>0 Then Port[B+RISR]:=$20;      { compteurs }
End;

SegmentEnd;
