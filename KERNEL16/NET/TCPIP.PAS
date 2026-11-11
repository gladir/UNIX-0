{ @author: Sylvain Maltais (support@gladir.com)
  @created: 2026
  @website(https://www.gladir.com/unix-0)
  @abstract(Target: Unix Pascal (UPC /K), inclus par KERNEL16/KERNEL.PAS)
  @description: Protocoles TCP/IP de UNIX-0 et sockets de 4.2BSD, en trois
   segments-unites :
   - KInet : table de routage (route la plus precise), ARP (RFC 826, cache
     avec une trame en attente par entree, trois demandes au plus), IP
     (RFC 791 : en-tete sans options a l'emission, pas de fragmentation :
     les fragments recus sont ignores, pas de relais entre interfaces),
     ICMP (RFC 792 : reponse aux demandes d'echo, port injoignable), UDP
     (RFC 768) et sockets bruts (le datagramme IP entier est remis, comme
     sous BSD : ping);
   - KTcp : TCP (RFC 793) : ouverture active et passive (file d'attente
     d'ecoute), option MSS, fenetre egale a la place libre du tampon de
     reception, retransmission depuis le premier octet non acquitte avec
     delai double a chaque essai (1 s, puis jusqu'a 64 s; abandon apres 12
     essais, 6 pour le SYN), sondage de fenetre nulle, fermeture des deux
     cotes, TIME_WAIT de 4 s, RST pour les segments sans destinataire.
     Les segments hors sequence sont ignores (l'acquittement repete
     provoque la retransmission de l'emetteur);
   - KSock : couche socket utilisee par les appels systeme (socket, bind,
     connect, listen, accept, sendto, recvfrom, shutdown, options),
     ioctl de configuration (interfaces, routes, ARP, statistiques) et
     NetIsr, appelee par l'ordonnanceur hors interruption (comme le
     netisr de BSD) : scrutation des cartes, traitement des trames recues,
     minuteries.
}

{ ====================================================================== }
SegmentUnit KInet;
Uses KTypes,KLib,KSched,KNetIf,KNe2000,KPktDrv;
SegmentInterface

Const
 NRT=8;               { routes }
 NARP=10;             { entrees du cache ARP }
 RTF_UP=1; RTF_GATEWAY=2; RTF_HOST=4;
 IPPROTO_ICMP=1; IPPROTO_TCP=6; IPPROTO_UDP=17;
 IPOFS=ETHHDR;        { en-tete IP dans un tampon }
 DATAOFS=ETHHDR+20;   { donnees d'un datagramme emis }
 LOOPADDR=$0100007F;  { 127.0.0.1 }
 ARP_FREE=0; ARP_PENDING=1; ARP_DONE=2;

Type
 TRoute=Record
  Used: Boolean;
  Dst, Mask, Gw: Longint;
  IfI: ShortInt;
  Flags: Word;
 End;
 TArp=Record
  State: Byte;
  Ip: Longint;
  Mac: TMac;
  IfI: ShortInt;
  Time: Longint;
  Tries: Byte;
  Hold: ShortInt;      { trame en attente de l'adresse (-1) }
 End;
 TNetStat=Record
  IpIn, IpOut, IpBad, IpFrag, IpNoProto, IpNoRoute,
  IcmpIn, IcmpOut, UdpIn, UdpOut, UdpNoPort,
  TcpIn, TcpOut, TcpRexmt, TcpConn, TcpAccept, TcpDrop, TcpRstOut, TcpBad,
  ArpIn, ArpOut: Longint;
 End;

Var
 Routes: Array[0..NRT-1] Of TRoute;
 ArpTab: Array[0..NARP-1] Of TArp;
 NStat: TNetStat;
 IpId: Word;
 NextPort: Word;
 LoopIf: Integer;

Function IfStart(I: Integer): Boolean;
Procedure IfStop(I: Integer);
Procedure IfPoll(I: Integer);
Procedure IfSetAddr(I: Integer; A, M: Longint);
Function RtAdd(Dst, Mask, Gw: Longint; IfI: Integer; Flags: Word): Boolean;
Function RtDel(Dst, Mask: Longint): Boolean;
Function RtLookup(Dst: Longint; Var IfI: Integer; Var Hop: Longint): Boolean;
Function LocalIf(A: Longint): Integer;
Function SrcFor(Dst: Longint; Hint: Integer): Longint;
Function PseudoSum(Src, Dst: Longint; Proto: Byte; Len: Word): Longint;
Function IpOutput(P: Integer; Src, Dst: Longint; Proto: Byte; Len: Word;
  Hint: Integer): Integer;
Function IpInput(P: Integer; Var Proto: Byte; Var Src, Dst: Longint;
  Var DOfs, DLen: Word): Boolean;
Function ArpInput(P: Integer): Boolean;
Procedure ArpTimer;
Function IcmpInput(P: Integer; Src, Dst: Longint; DOfs, DLen: Word): Boolean;
Procedure UdpInput(P: Integer; Src, Dst: Longint; DOfs, DLen: Word);
Procedure RawInput(P: Integer; Proto: Byte; Src: Longint);
Function UdpOutput(S: Integer; Dst: Longint; DPort: Word; Sg, Os, N: Word): Integer;
Function RawOutput(S: Integer; Dst: Longint; Sg, Os, N: Word): Integer;
Function SockAlloc(Typ, Proto: Byte): Integer;
Procedure SockFree(S: Integer);
Function PortUsed(Typ: Byte; Port: Word; Addr: Longint): Boolean;
Function EphemeralPort(Typ: Byte): Word;
Function IsBcast(A: Longint): Boolean;

SegmentImplementation

Var
 DgHdr: Array[0..7] Of Byte;    { en-tete d'un datagramme dans un tampon }

{ --- interfaces ---------------------------------------------------------- }

Function IfStart(I: Integer): Boolean;
Var Ok: Boolean;
Begin
 IfStart:=False;
 If Not NetAlloc Then Exit;
 Case Ifs[I].Drv Of
  DRVLOOP: Ok:=True;
  DRVNE2000: Ok:=Ne2000Init(I);
  DRVPKT: Ok:=PktInit(I);
  Else Ok:=False;
 End;
 If Ok Then Ifs[I].Flags:=Ifs[I].Flags Or IFF_UP Or IFF_RUNNING;
 IfStart:=Ok;
End;

Procedure IfStop(I: Integer);
Begin
 Case Ifs[I].Drv Of
  DRVNE2000: Ne2000Stop(I);
  DRVPKT: PktStop(I);
 End;
 Ifs[I].Flags:=Ifs[I].Flags And Not (IFF_UP Or IFF_RUNNING);
End;

Procedure IfPoll(I: Integer);
Begin
 Case Ifs[I].Drv Of
  DRVNE2000: If Ifs[I].Flags And IFF_UP<>0 Then Ne2000Poll(I);
  DRVPKT: PktPoll(I);
 End;
End;

Procedure IfTransmit(I, P: Integer);
Begin
 Case Ifs[I].Drv Of
  DRVNE2000: Ne2000Send(I,P);
  DRVPKT: PktSend(I,P);
 End;
 PktFree(P);
End;

Function MaskBits(M: Longint): Integer;
Var K,N: Integer;
Begin
 N:=0;
 For K:=0 To 31 Do If (M Shr K) And 1<>0 Then Inc(N);
 MaskBits:=N;
End;

Function DefaultMask(A: Longint): Longint;
Var B: Byte;
Begin
 B:=A And $FF;
 If B<128 Then DefaultMask:=$000000FF
 Else If B<192 Then DefaultMask:=$0000FFFF
 Else DefaultMask:=$00FFFFFF;
End;

Procedure IfSetAddr(I: Integer; A, M: Longint);
Var K: Integer;
Begin
 { ancienne route de l'interface }
 For K:=0 To NRT-1 Do
  If Routes[K].Used And (Routes[K].IfI=I) And (Routes[K].Flags And RTF_GATEWAY=0) Then
   Routes[K].Used:=False;
 If M=0 Then M:=DefaultMask(A);
 Ifs[I].Addr:=A; Ifs[I].Mask:=M;
 Ifs[I].Bcast:=A Or Not M;
 If A<>0 Then RtAdd(A And M,M,0,I,RTF_UP);
End;

{ --- routes -------------------------------------------------------------- }

Function RtAdd(Dst, Mask, Gw: Longint; IfI: Integer; Flags: Word): Boolean;
Var K,F: Integer;
Begin
 RtAdd:=False; F:=-1;
 For K:=0 To NRT-1 Do
  If Routes[K].Used Then Begin
   If (Routes[K].Dst=Dst And Mask) And (Routes[K].Mask=Mask) Then F:=K;
  End Else If F<0 Then F:=K;
 If F<0 Then Exit;
 Routes[F].Used:=True; Routes[F].Dst:=Dst And Mask; Routes[F].Mask:=Mask;
 Routes[F].Gw:=Gw; Routes[F].IfI:=IfI; Routes[F].Flags:=Flags Or RTF_UP;
 RtAdd:=True;
End;

Function RtDel(Dst, Mask: Longint): Boolean;
Var K: Integer;
Begin
 RtDel:=False;
 For K:=0 To NRT-1 Do
  If Routes[K].Used And (Routes[K].Dst=Dst And Mask) And (Routes[K].Mask=Mask) Then Begin
   Routes[K].Used:=False; RtDel:=True;
  End;
End;

Function RtLookup(Dst: Longint; Var IfI: Integer; Var Hop: Longint): Boolean;
{ route la plus precise (masque le plus long) vers Dst }
Var K,Best,B: Integer;
Begin
 RtLookup:=False; Best:=-1; IfI:=-1;
 For K:=0 To NRT-1 Do
  If Routes[K].Used And (Routes[K].IfI>=0) And (Dst And Routes[K].Mask=Routes[K].Dst) Then
   If Ifs[Routes[K].IfI].Flags And IFF_UP<>0 Then Begin
    B:=MaskBits(Routes[K].Mask);
    If B>Best Then Begin
     Best:=B; IfI:=Routes[K].IfI; Hop:=Dst;
     If Routes[K].Flags And RTF_GATEWAY<>0 Then Hop:=Routes[K].Gw;
     RtLookup:=True;
    End;
   End;
End;

Function LocalIf(A: Longint): Integer;
{ interface qui porte l'adresse A (-1) }
Var I: Integer;
Begin
 LocalIf:=-1;
 If A=0 Then Exit;
 For I:=0 To NIF-1 Do
  If Ifs[I].Used And (Ifs[I].Addr=A) Then Begin LocalIf:=I; Exit End;
End;

Function IsBcast(A: Longint): Boolean;
Var I: Integer;
Begin
 IsBcast:=A=-1;
 For I:=0 To NIF-1 Do
  If Ifs[I].Used And (Ifs[I].Addr<>0) And (Ifs[I].Flags And IFF_BROADCAST<>0) And
    (Ifs[I].Bcast=A) Then IsBcast:=True;
End;

Function FirstIf: Integer;
{ premiere interface active qui n'est pas la boucle locale }
Var I: Integer;
Begin
 FirstIf:=-1;
 For I:=0 To NIF-1 Do
  If Ifs[I].Used And (Ifs[I].Drv<>DRVLOOP) And (Ifs[I].Flags And IFF_UP<>0) Then Begin
   FirstIf:=I; Exit;
  End;
End;

Function SrcFor(Dst: Longint; Hint: Integer): Longint;
{ adresse source d'un datagramme vers Dst (0 : pas de route) }
Var I: Integer; Hop: Longint;
Begin
 SrcFor:=0;
 If Dst And $FF=127 Then Begin SrcFor:=LOOPADDR; Exit End;
 If LocalIf(Dst)>=0 Then Begin SrcFor:=Dst; Exit End;
 If Dst=-1 Then Begin
  If Hint<0 Then Hint:=FirstIf;
  If Hint>=0 Then SrcFor:=Ifs[Hint].Addr;
  Exit;
 End;
 If RtLookup(Dst,I,Hop) Then SrcFor:=Ifs[I].Addr;
End;

Function PseudoSum(Src, Dst: Longint; Proto: Byte; Len: Word): Longint;
{ pseudo-en-tete de TCP et UDP, en mots lus tels quels en memoire }
Begin
 PseudoSum:=Longint(Word(Src))+Word(Src Shr 16)+Word(Dst)+Word(Dst Shr 16)+
   (Word(Proto) Shl 8)+Swap(Len);
End;

{ --- ARP ----------------------------------------------------------------- }

Procedure ArpSend(I: Integer; Op: Word; Tip: Longint; Var Tha: TMac; Dest: Boolean);
Var P,K: Integer; O: Word;
Begin
 P:=PktGet;
 If P<0 Then Exit;
 O:=PktOfs(P);
 For K:=0 To 5 Do Begin
  If Dest Then Mem[NetSeg:O+K]:=Tha[K] Else Mem[NetSeg:O+K]:=$FF;
  Mem[NetSeg:O+6+K]:=Ifs[I].Mac[K];
 End;
 PutN16(NetSeg,O+12,ETHERTYPE_ARP);
 Inc(O,ETHHDR);
 PutN16(NetSeg,O,1); PutN16(NetSeg,O+2,ETHERTYPE_IP);
 Mem[NetSeg:O+4]:=6; Mem[NetSeg:O+5]:=4;
 PutN16(NetSeg,O+6,Op);
 For K:=0 To 5 Do Mem[NetSeg:O+8+K]:=Ifs[I].Mac[K];
 MemL[NetSeg:O+14]:=Ifs[I].Addr;
 For K:=0 To 5 Do
  If Dest Then Mem[NetSeg:O+18+K]:=Tha[K] Else Mem[NetSeg:O+18+K]:=0;
 MemL[NetSeg:O+24]:=Tip;
 PktLen[P]:=ETHHDR+28;
 Inc(NStat.ArpOut);
 IfTransmit(I,P);
End;

Function ArpFind(I: Integer; Ip: Longint): Integer;
Var K: Integer;
Begin
 ArpFind:=-1;
 For K:=0 To NARP-1 Do
  If (ArpTab[K].State<>ARP_FREE) And (ArpTab[K].Ip=Ip) And (ArpTab[K].IfI=I) Then Begin
   ArpFind:=K; Exit;
  End;
End;

Function ArpNew: Integer;
{ entree libre, sinon la plus ancienne }
Var K,Old: Integer;
Begin
 Old:=0;
 For K:=0 To NARP-1 Do Begin
  If ArpTab[K].State=ARP_FREE Then Begin ArpNew:=K; Exit End;
  If ArpTab[K].Time<ArpTab[Old].Time Then Old:=K;
 End;
 If ArpTab[Old].Hold>=0 Then PktFree(ArpTab[Old].Hold);
 ArpTab[Old].State:=ARP_FREE;
 ArpNew:=Old;
End;

Procedure EtherSend(I, P: Integer; Var Mac: TMac);
Var K: Integer; O: Word;
Begin
 O:=PktOfs(P);
 For K:=0 To 5 Do Begin
  Mem[NetSeg:O+K]:=Mac[K]; Mem[NetSeg:O+6+K]:=Ifs[I].Mac[K];
 End;
 PutN16(NetSeg,O+12,ETHERTYPE_IP);
 IfTransmit(I,P);
End;

Procedure EtherOutput(I, P: Integer; Hop: Longint);
{ trame IP du tampon P vers le prochain saut Hop de l'interface I }
Var K: Integer; Mac: TMac;
Begin
 If Ifs[I].Drv=DRVLOOP Then Begin
  FarFill(NetSeg,PktOfs(P),12,0);
  PutN16(NetSeg,PktOfs(P)+12,ETHERTYPE_IP);
  PktIf[P]:=I;
  Inc(Ifs[I].OPackets); Inc(Ifs[I].IPackets);
  InEnqueue(P);
  Exit;
 End;
 If (Hop=-1) Or (Hop=Ifs[I].Bcast) Then Begin
  For K:=0 To 5 Do Mac[K]:=$FF;
  EtherSend(I,P,Mac);
  Exit;
 End;
 K:=ArpFind(I,Hop);
 If (K>=0) And (ArpTab[K].State=ARP_DONE) Then Begin
  EtherSend(I,P,ArpTab[K].Mac);
  Exit;
 End;
 If K<0 Then Begin
  K:=ArpNew;
  ArpTab[K].State:=ARP_PENDING; ArpTab[K].Ip:=Hop; ArpTab[K].IfI:=I;
  ArpTab[K].Hold:=-1; ArpTab[K].Tries:=0;
 End;
 If ArpTab[K].Hold>=0 Then PktFree(ArpTab[K].Hold);
 ArpTab[K].Hold:=P;
 If ArpTab[K].Tries=0 Then Begin
  ArpTab[K].Tries:=1; ArpTab[K].Time:=Ticks;
  ArpSend(I,1,Hop,Mac,False);
 End;
End;

Function ArpInput(P: Integer): Boolean;
{ requete ou reponse ARP; Vrai si le tampon a ete repris }
Var I,K: Integer; O: Word; Op: Word; Spa,Tpa: Longint; Sha: TMac; H: Integer;
Begin
 ArpInput:=False;
 Inc(NStat.ArpIn);
 I:=PktIf[P]; O:=PktOfs(P)+ETHHDR;
 If PktLen[P]<ETHHDR+28 Then Exit;
 If (GetN16(NetSeg,O)<>1) Or (GetN16(NetSeg,O+2)<>ETHERTYPE_IP) Or
   (Mem[NetSeg:O+4]<>6) Or (Mem[NetSeg:O+5]<>4) Then Exit;
 Op:=GetN16(NetSeg,O+6);
 For K:=0 To 5 Do Sha[K]:=Mem[NetSeg:O+8+K];
 Spa:=MemL[NetSeg:O+14]; Tpa:=MemL[NetSeg:O+24];
 If (Ifs[I].Addr=0) Or (Spa=0) Then Exit;
 { mise a jour du cache : l'emetteur, s'il est connu ou s'il s'adresse a nous }
 K:=ArpFind(I,Spa);
 If (K<0) And (Tpa=Ifs[I].Addr) Then Begin
  K:=ArpNew;
  ArpTab[K].Ip:=Spa; ArpTab[K].IfI:=I; ArpTab[K].Hold:=-1;
 End;
 If K>=0 Then Begin
  ArpTab[K].Mac:=Sha; ArpTab[K].State:=ARP_DONE;
  ArpTab[K].Time:=Ticks; ArpTab[K].Tries:=0;
  H:=ArpTab[K].Hold; ArpTab[K].Hold:=-1;
  If H>=0 Then EtherSend(I,H,Sha);
 End;
 If (Op=1) And (Tpa=Ifs[I].Addr) Then ArpSend(I,2,Spa,Sha,True);
End;

Procedure ArpTimer;
Var K: Integer;
Begin
 For K:=0 To NARP-1 Do With ArpTab[K] Do
  Case State Of
   ARP_PENDING:
    If Ticks-Time>=18 Then Begin
     If Tries>=3 Then Begin
      If Hold>=0 Then PktFree(Hold);
      Hold:=-1; State:=ARP_FREE;
      Inc(NStat.IpNoRoute);
     End Else Begin
      Inc(Tries); Time:=Ticks;
      If Ifs[IfI].Flags And IFF_UP<>0 Then ArpSend(IfI,1,Ip,Mac,False);
     End;
    End;
   ARP_DONE:
    If Ticks-Time>=21840 Then State:=ARP_FREE;   { 20 minutes }
  End;
End;

{ --- IP ------------------------------------------------------------------ }

Function IpOutput(P: Integer; Src, Dst: Longint; Proto: Byte; Len: Word;
  Hint: Integer): Integer;
{ datagramme dont les donnees (Len octets) sont a DATAOFS dans le tampon P;
  le tampon est toujours consomme. Resultat : 0 ou code d'erreur. }
Var I: Integer; Hop: Longint; O: Word;
Begin
 IpOutput:=0;
 I:=-1; Hop:=Dst;
 If (Dst And $FF=127) Or (LocalIf(Dst)>=0) Then I:=LoopIf
 Else If Dst=-1 Then Begin
  I:=Hint;
  If I<0 Then I:=FirstIf;
 End Else If Not RtLookup(Dst,I,Hop) Then I:=-1;
 If (I<0) Or (Ifs[I].Flags And IFF_UP=0) Then Begin
  PktFree(P); Inc(NStat.IpNoRoute);
  If I<0 Then IpOutput:=ENETUNREACH Else IpOutput:=ENETDOWN;
  Exit;
 End;
 If Src=0 Then Src:=Ifs[I].Addr;
 O:=PktOfs(P)+IPOFS;
 Mem[NetSeg:O]:=$45; Mem[NetSeg:O+1]:=0;
 PutN16(NetSeg,O+2,20+Len);
 PutN16(NetSeg,O+4,IpId); Inc(IpId);
 MemW[NetSeg:O+6]:=0;
 Mem[NetSeg:O+8]:=64; Mem[NetSeg:O+9]:=Proto;
 MemW[NetSeg:O+10]:=0;
 MemL[NetSeg:O+12]:=Src; MemL[NetSeg:O+16]:=Dst;
 CkSum(NetSeg,O,20,0);
 MemW[NetSeg:O+10]:=CkResult;
 PktLen[P]:=DATAOFS+Len;
 Inc(NStat.IpOut);
 EtherOutput(I,P,Hop);
End;

Function IpInput(P: Integer; Var Proto: Byte; Var Src, Dst: Longint;
  Var DOfs, DLen: Word): Boolean;
Var I: Integer; O,Hl,Tl: Word;
Begin
 IpInput:=False;
 Inc(NStat.IpIn);
 I:=PktIf[P]; O:=PktOfs(P)+IPOFS;
 If PktLen[P]<IPOFS+20 Then Begin Inc(NStat.IpBad); Exit End;
 If Mem[NetSeg:O] Shr 4<>4 Then Begin Inc(NStat.IpBad); Exit End;
 Hl:=(Mem[NetSeg:O] And 15)*4;
 Tl:=GetN16(NetSeg,O+2);
 If (Hl<20) Or (Tl<Hl) Or (Tl>PktLen[P]-IPOFS) Then Begin Inc(NStat.IpBad); Exit End;
 CkSum(NetSeg,O,Hl,0);
 If CkResult<>0 Then Begin Inc(NStat.IpBad); Exit End;
 If GetN16(NetSeg,O+6) And $3FFF<>0 Then Begin Inc(NStat.IpFrag); Exit End;
 Src:=MemL[NetSeg:O+12]; Dst:=MemL[NetSeg:O+16];
 { destinataire : une de nos adresses, une diffusion, ou n'importe qui si
   l'interface n'a pas encore d'adresse (DHCP) }
 If (Ifs[I].Drv<>DRVLOOP) And (Ifs[I].Addr<>0) And (LocalIf(Dst)<0) And
   (Dst<>-1) And (Dst<>Ifs[I].Bcast) Then Exit;
 Proto:=Mem[NetSeg:O+9];
 DOfs:=O+Hl; DLen:=Tl-Hl;
 IpInput:=True;
End;

{ --- sockets : table ----------------------------------------------------- }

Function SockAlloc(Typ, Proto: Byte): Integer;
Var S: Integer;
Begin
 SockAlloc:=-1;
 For S:=0 To NSOCK-1 Do If Not Socks[S].Used Then Begin
  FillChar(Socks[S],SizeOf(TSock),0);
  Socks[S].Used:=True; Socks[S].Typ:=Typ; Socks[S].Proto:=Proto;
  Socks[S].IfIdx:=-1; Socks[S].Head:=-1; Socks[S].Mss:=536;
  SockAlloc:=S; Exit;
 End;
End;

Procedure SockFree(S: Integer);
Begin
 Socks[S].Used:=False;
 Wakeup(CHSOCK+S);
End;

Function PortUsed(Typ: Byte; Port: Word; Addr: Longint): Boolean;
Var S: Integer;
Begin
 PortUsed:=False;
 For S:=0 To NSOCK-1 Do With Socks[S] Do
  If Used And (Socks[S].Typ=Typ) And (LPort=Port) And
    ((LAddr=0) Or (Addr=0) Or (LAddr=Addr)) Then PortUsed:=True;
End;

Function EphemeralPort(Typ: Byte): Word;
Var K: Integer;
Begin
 If NextPort<1024 Then NextPort:=1024+Word(Ticks Mod 2000);
 For K:=1 To 4000 Do Begin
  Inc(NextPort);
  If NextPort>=5000 Then NextPort:=1024;
  If Not PortUsed(Typ,NextPort,0) Then Begin EphemeralPort:=NextPort; Exit End;
 End;
 EphemeralPort:=0;
End;

Function DgramAppend(S: Integer; Src: Longint; Port: Word; Sg, Os, N: Word): Boolean;
{ datagramme recu : enregistrement [longueur, adresse, port] + donnees }
Begin
 DgramAppend:=False;
 With Socks[S] Do Begin
  If SFlags And SS_CANTRCVMORE<>0 Then Exit;
  If SBSIZE-RcvCnt<N+8 Then Exit;
  MemW[DSeg:Ofs(DgHdr)]:=N;
  MemL[DSeg:Ofs(DgHdr)+2]:=Src;
  MemW[DSeg:Ofs(DgHdr)+6]:=Port;
  RingPut(SbRcvOfs(S),RcvHead,RcvCnt,DSeg,Ofs(DgHdr),8);
  RingPut(SbRcvOfs(S),RcvHead,RcvCnt,Sg,Os,N);
 End;
 Wakeup(CHSOCK+S);
 DgramAppend:=True;
End;

{ --- ICMP ---------------------------------------------------------------- }

Procedure RawInput(P: Integer; Proto: Byte; Src: Longint);
{ copie du datagramme IP entier pour chaque socket brut du protocole }
Var S: Integer; O: Word;
Begin
 O:=PktOfs(P)+IPOFS;
 For S:=0 To NSOCK-1 Do With Socks[S] Do
  If Used And (Typ=SOCK_RAW) And ((Socks[S].Proto=0) Or (Socks[S].Proto=Proto)) Then
   DgramAppend(S,Src,0,NetSeg,O,GetN16(NetSeg,O+2));
End;

Procedure IcmpError(P: Integer; Typ, Code: Byte);
{ message d'erreur ICMP (injoignable) sur le datagramme recu P }
Var Q: Integer; O,Ip,Hl,N: Word; Src: Longint;
Begin
 Ip:=PktOfs(P)+IPOFS;
 Src:=MemL[NetSeg:Ip+12];
 If IsBcast(MemL[NetSeg:Ip+16]) Or IsBcast(Src) Or (Src=0) Then Exit;
 Q:=PktGet;
 If Q<0 Then Exit;
 Hl:=(Mem[NetSeg:Ip] And 15)*4;
 N:=Hl+8;
 O:=PktOfs(Q)+DATAOFS;
 Mem[NetSeg:O]:=Typ; Mem[NetSeg:O+1]:=Code; MemW[NetSeg:O+2]:=0;
 MemL[NetSeg:O+4]:=0;
 FarMove(NetSeg,Ip,NetSeg,O+8,N);
 CkSum(NetSeg,O,8+N,0); MemW[NetSeg:O+2]:=CkResult;
 Inc(NStat.IcmpOut);
 IpOutput(Q,0,Src,IPPROTO_ICMP,8+N,-1);
End;

Function IcmpInput(P: Integer; Src, Dst: Longint; DOfs, DLen: Word): Boolean;
{ Vrai si le tampon a ete repris (reponse d'echo) }
Var O: Word;
Begin
 IcmpInput:=False;
 Inc(NStat.IcmpIn);
 If DLen<8 Then Exit;
 CkSum(NetSeg,DOfs,DLen,0);
 If CkResult<>0 Then Begin Inc(NStat.IpBad); Exit End;
 RawInput(P,IPPROTO_ICMP,Src);
 If (Mem[NetSeg:DOfs]=8) And Not IsBcast(Dst) Then Begin
  { demande d'echo : la reponse reprend le meme tampon }
  O:=PktOfs(P)+DATAOFS;
  If DOfs<>O Then FarMove(NetSeg,DOfs,NetSeg,O,DLen);
  Mem[NetSeg:O]:=0; MemW[NetSeg:O+2]:=0;
  CkSum(NetSeg,O,DLen,0); MemW[NetSeg:O+2]:=CkResult;
  Inc(NStat.IcmpOut);
  IpOutput(P,Dst,Src,IPPROTO_ICMP,DLen,-1);
  IcmpInput:=True;
 End;
End;

{ --- UDP ----------------------------------------------------------------- }

Procedure UdpInput(P: Integer; Src, Dst: Longint; DOfs, DLen: Word);
Var S,Best: Integer; SPort,DPort,L: Word;
Begin
 Inc(NStat.UdpIn);
 If DLen<8 Then Begin Inc(NStat.IpBad); Exit End;
 SPort:=GetN16(NetSeg,DOfs); DPort:=GetN16(NetSeg,DOfs+2);
 L:=GetN16(NetSeg,DOfs+4);
 If (L<8) Or (L>DLen) Then Begin Inc(NStat.IpBad); Exit End;
 If MemW[NetSeg:DOfs+6]<>0 Then Begin
  CkSum(NetSeg,DOfs,L,PseudoSum(Src,Dst,IPPROTO_UDP,L));
  If CkResult<>0 Then Begin Inc(NStat.IpBad); Exit End;
 End;
 Best:=-1;
 For S:=0 To NSOCK-1 Do With Socks[S] Do
  If Used And (Typ=SOCK_DGRAM) And (LPort=DPort) Then
   If (LAddr=0) Or (LAddr=Dst) Or IsBcast(Dst) Then
    If (FAddr=0) Or ((FAddr=Src) And (FPort=SPort)) Then
     If (Best<0) Or (FAddr<>0) Then Best:=S;
 If Best<0 Then Begin
  Inc(NStat.UdpNoPort);
  IcmpError(P,3,3);
  Exit;
 End;
 DgramAppend(Best,Src,SPort,NetSeg,DOfs+8,L-8);
End;

Function UdpOutput(S: Integer; Dst: Longint; DPort: Word; Sg, Os, N: Word): Integer;
Var P: Integer; O: Word; Src: Longint;
Begin
 With Socks[S] Do Begin
  If N>1472 Then Begin UdpOutput:=EMSGSIZE; Exit End;
  Src:=LAddr;
  If Src=0 Then Src:=SrcFor(Dst,IfIdx);
  If (Src=0) And (Dst<>-1) Then Begin UdpOutput:=ENETUNREACH; Exit End;
  P:=PktGet;
  If P<0 Then Begin UdpOutput:=ENOBUFS; Exit End;
  O:=PktOfs(P)+DATAOFS;
  PutN16(NetSeg,O,LPort); PutN16(NetSeg,O+2,DPort);
  PutN16(NetSeg,O+4,N+8); MemW[NetSeg:O+6]:=0;
  FarMove(Sg,Os,NetSeg,O+8,N);
  CkSum(NetSeg,O,N+8,PseudoSum(Src,Dst,IPPROTO_UDP,N+8));
  If CkResult=0 Then CkResult:=$FFFF;
  MemW[NetSeg:O+6]:=CkResult;
  Inc(NStat.UdpOut);
  UdpOutput:=IpOutput(P,Src,Dst,IPPROTO_UDP,N+8,IfIdx);
 End;
End;

Function RawOutput(S: Integer; Dst: Longint; Sg, Os, N: Word): Integer;
Var P: Integer;
Begin
 If N>1480 Then Begin RawOutput:=EMSGSIZE; Exit End;
 P:=PktGet;
 If P<0 Then Begin RawOutput:=ENOBUFS; Exit End;
 FarMove(Sg,Os,NetSeg,PktOfs(P)+DATAOFS,N);
 If Socks[S].Proto=IPPROTO_ICMP Then Inc(NStat.IcmpOut);
 RawOutput:=IpOutput(P,Socks[S].LAddr,Dst,Socks[S].Proto,N,Socks[S].IfIdx);
End;

SegmentEnd;

{ ====================================================================== }
SegmentUnit KTcp;
Uses KTypes,KLib,KSched,KNetIf,KInet;
SegmentInterface

Procedure TcpInput(P: Integer; Src, Dst: Longint; DOfs, DLen: Word);
Procedure TcpOutput(S: Integer);
Procedure TcpTimer;
Procedure TcpConnect(S: Integer);
Procedure TcpClose(S: Integer);
Procedure TcpShutdown(S: Integer);
Procedure TcpDrop(S: Integer; Err: Word);
Procedure TcpRcvd(S: Integer);

SegmentImplementation

Const
 TH_FIN=1; TH_SYN=2; TH_RST=4; TH_PUSH=8; TH_ACK=$10;
 TCP_MSS=1460;
 RTOBASE=18;          { 1 seconde }
 MAXRXT=12;
 MAXSYNRXT=6;
 TWTICKS=73;          { TIME_WAIT : 4 secondes }
 FW2TICKS=1092;       { FIN_WAIT_2 sans descripteur : 60 secondes }

Var
 IssSeed: Longint;

Function SeqLT(A, B: Longint): Boolean;
Begin SeqLT:=A-B<0 End;

Function SeqLE(A, B: Longint): Boolean;
Begin SeqLE:=A-B<=0 End;

Function SeqGT(A, B: Longint): Boolean;
Begin SeqGT:=A-B>0 End;

Function NewIss: Longint;
Begin
 IssSeed:=IssSeed+64000+Ticks*125;
 NewIss:=IssSeed;
End;

Function Rto(S: Integer): Longint;
Var K: Integer;
Begin
 K:=Socks[S].RxtShift; If K>6 Then K:=6;
 Rto:=Longint(RTOBASE) Shl K;
End;

Procedure SendSeg(S: Integer; Src, Dst: Longint; SPort, DPort: Word;
  Seq, Ack: Longint; Flags: Byte; Win: Word; DOff, DLen: Word);
{ segment TCP; S >= 0 : les donnees viennent du tampon d'emission de S }
Var P: Integer; O,Hl: Word;
Begin
 P:=PktGet;
 If P<0 Then Exit;
 O:=PktOfs(P)+DATAOFS;
 Hl:=20;
 If Flags And TH_SYN<>0 Then Hl:=24;
 PutN16(NetSeg,O,SPort); PutN16(NetSeg,O+2,DPort);
 PutN32(NetSeg,O+4,Seq); PutN32(NetSeg,O+8,Ack);
 Mem[NetSeg:O+12]:=(Hl Div 4) Shl 4; Mem[NetSeg:O+13]:=Flags;
 PutN16(NetSeg,O+14,Win);
 MemW[NetSeg:O+16]:=0; MemW[NetSeg:O+18]:=0;
 If Hl=24 Then Begin
  Mem[NetSeg:O+20]:=2; Mem[NetSeg:O+21]:=4; PutN16(NetSeg,O+22,TCP_MSS);
 End;
 If (DLen>0) And (S>=0) Then
  RingPeek(SbSndOfs(S),Socks[S].SndHead,DOff,NetSeg,O+Hl,DLen);
 CkSum(NetSeg,O,Hl+DLen,PseudoSum(Src,Dst,IPPROTO_TCP,Hl+DLen));
 MemW[NetSeg:O+16]:=CkResult;
 Inc(NStat.TcpOut);
 IpOutput(P,Src,Dst,IPPROTO_TCP,Hl+DLen,-1);
End;

Procedure Respond(Src, Dst: Longint; SPort, DPort: Word; Seq, Ack: Longint; Flags: Byte);
Begin
 Inc(NStat.TcpRstOut);
 SendSeg(-1,Src,Dst,SPort,DPort,Seq,Ack,Flags,0,0,0);
End;

Procedure TcpOutput(S: Integer);
Var Off,Avail,Win,Usable,Len: Longint; Flags: Byte; FinSeq: Longint;
    N: Integer; Fin: Boolean; W: Word;
Begin
 N:=0;
 With Socks[S] Do
 Repeat
  Inc(N);
  If (State=TCPS_CLOSED) Or (State=TCPS_LISTEN) Then Exit;
  W:=SBSIZE-RcvCnt;
  If (State=TCPS_SYN_SENT) Or (State=TCPS_SYN_RCVD) Then Begin
   If SndNxt=Iss Then Begin
    If State=TCPS_SYN_SENT Then
     SendSeg(S,LAddr,FAddr,LPort,FPort,Iss,0,TH_SYN,W,0,0)
    Else SendSeg(S,LAddr,FAddr,LPort,FPort,Iss,RcvNxt,TH_SYN Or TH_ACK,W,0,0);
    RcvAdv:=W;
    SndNxt:=Iss+1;
    If SeqGT(SndNxt,SndMax) Then SndMax:=SndNxt;
    If RxtAt=0 Then RxtAt:=Ticks+Rto(S);
   End;
   Exit;
  End;
  Off:=SndNxt-SndUna;
  If Off>SndCnt Then Avail:=0 Else Avail:=SndCnt-Off;
  Win:=SndWnd;
  If Probe And (Win=0) Then Win:=1;
  If Win>Off Then Usable:=Win-Off Else Usable:=0;
  Len:=Avail;
  If Len>Usable Then Len:=Usable;
  If Len>Mss Then Len:=Mss;
  FinSeq:=SndUna+SndCnt;
  Fin:=FinQueued And (Off+Len=SndCnt) And Not SeqGT(SndNxt,FinSeq);
  If (Len=0) And Not Fin And Not AckNow Then Begin
   { fenetre nulle avec des donnees en attente : sondage periodique }
   If (Avail>0) And (SndWnd=0) And (RxtAt=0) Then RxtAt:=Ticks+Rto(S);
   Exit;
  End;
  Flags:=TH_ACK;
  If (Len>0) And (Off+Len=SndCnt) Then Flags:=Flags Or TH_PUSH;
  If Fin Then Flags:=Flags Or TH_FIN;
  SendSeg(S,LAddr,FAddr,LPort,FPort,SndNxt,RcvNxt,Flags,W,Word(Off),Word(Len));
  RcvAdv:=W;
  AckNow:=False; Probe:=False;
  SndNxt:=SndNxt+Len;
  If Fin Then Begin SndNxt:=SndNxt+1; FinSent:=True; FinSeq:=SndNxt-1 End;
  If SeqGT(SndNxt,SndMax) Then SndMax:=SndNxt;
  If ((Len>0) Or Fin) And (RxtAt=0) Then RxtAt:=Ticks+Rto(S);
 Until (Len=0) Or (N>=8);
End;

Procedure Finish(S: Integer);
{ connexion terminee : le socket est libere s'il n'a plus de descripteur }
Var H: Integer;
Begin
 With Socks[S] Do Begin
  State:=TCPS_CLOSED; RxtAt:=0; TimerAt:=0;
  H:=Head;
  If (H>=0) Or (SFlags And SS_NOFDREF<>0) Then Begin
   If H>=0 Then If Socks[H].QLen>0 Then Dec(Socks[H].QLen);
   SockFree(S);
  End Else Wakeup(CHSOCK+S);
 End;
End;

Procedure TcpDrop(S: Integer; Err: Word);
Begin
 With Socks[S] Do Begin
  If State>=TCPS_SYN_RCVD Then
   Respond(LAddr,FAddr,LPort,FPort,SndNxt,RcvNxt,TH_RST Or TH_ACK);
  If State<>TCPS_CLOSED Then Inc(NStat.TcpDrop);
  Error:=Err;
 End;
 Finish(S);
End;

Procedure TcpConnect(S: Integer);
Begin
 With Socks[S] Do Begin
  Iss:=NewIss; SndUna:=Iss; SndNxt:=Iss; SndMax:=Iss;
  State:=TCPS_SYN_SENT; RxtShift:=0; RxtAt:=0; Error:=0;
  SndHead:=0; SndCnt:=0; RcvHead:=0; RcvCnt:=0;
  FinQueued:=False; FinSent:=False;
 End;
 Inc(NStat.TcpConn);
 TcpOutput(S);
End;

Procedure TcpClose(S: Integer);
{ dernier descripteur ferme }
Var C: Integer;
Begin
 With Socks[S] Do Begin
  SFlags:=SFlags Or SS_NOFDREF Or SS_CANTRCVMORE;
  Case State Of
   TCPS_CLOSED, TCPS_SYN_SENT: Finish(S);
   TCPS_LISTEN: Begin
    For C:=0 To NSOCK-1 Do
     If Socks[C].Used And (Socks[C].Head=S) Then Begin
      Socks[C].Head:=-1; Socks[C].SFlags:=Socks[C].SFlags Or SS_NOFDREF;
      TcpDrop(C,ECONNABORTED);
     End;
    State:=TCPS_CLOSED;
    SockFree(S);
   End;
   TCPS_SYN_RCVD, TCPS_ESTABLISHED:
    If RcvCnt>0 Then TcpDrop(S,ECONNRESET)
    Else Begin
     FinQueued:=True; State:=TCPS_FIN_WAIT_1; TcpOutput(S);
    End;
   TCPS_CLOSE_WAIT: Begin
    FinQueued:=True; State:=TCPS_LAST_ACK; TcpOutput(S);
   End;
   TCPS_FIN_WAIT_2: TimerAt:=Ticks+FW2TICKS;
  End;
 End;
End;

Procedure TcpShutdown(S: Integer);
Begin
 With Socks[S] Do Begin
  If SFlags And SS_CANTSENDMORE<>0 Then Exit;
  SFlags:=SFlags Or SS_CANTSENDMORE;
  Case State Of
   TCPS_SYN_RCVD, TCPS_ESTABLISHED: Begin
    FinQueued:=True; State:=TCPS_FIN_WAIT_1; TcpOutput(S);
   End;
   TCPS_CLOSE_WAIT: Begin
    FinQueued:=True; State:=TCPS_LAST_ACK; TcpOutput(S);
   End;
  End;
 End;
End;

Procedure TcpRcvd(S: Integer);
{ des donnees ont ete lues : fenetre rouverte }
Var W: Word;
Begin
 With Socks[S] Do Begin
  If State<TCPS_ESTABLISHED Then Exit;
  W:=SBSIZE-RcvCnt;
  If (RcvAdv<Mss) And (W>=Mss) Or (W>=RcvAdv+SBSIZE Div 2) Then Begin
   AckNow:=True; TcpOutput(S);
  End;
 End;
End;

Procedure TcpTimer;
Var S: Integer;
Begin
 For S:=0 To NSOCK-1 Do With Socks[S] Do
  If Used And (Typ=SOCK_STREAM) Then Begin
   If (RxtAt<>0) And (Ticks>=RxtAt) Then Begin
    RxtAt:=0;
    If (State>=TCPS_ESTABLISHED) And (SndWnd=0) And (SndNxt=SndUna) And (SndCnt>0) Then Begin
     { sondage de fenetre nulle }
     Probe:=True; TcpOutput(S);
     If RxtShift<6 Then Inc(RxtShift);
     RxtAt:=Ticks+Rto(S);
    End Else If SndNxt<>SndUna Then Begin
     Inc(RxtShift);
     If ((State<=TCPS_SYN_RCVD) And (RxtShift>MAXSYNRXT)) Or (RxtShift>MAXRXT) Then
      TcpDrop(S,ETIMEDOUT)
     Else Begin
      Inc(NStat.TcpRexmt);
      SndNxt:=SndUna;
      TcpOutput(S);
     End;
    End;
   End;
   If Used And (TimerAt<>0) And (Ticks>=TimerAt) Then
    If (State=TCPS_TIME_WAIT) Or (State=TCPS_FIN_WAIT_2) Then Finish(S);
  End;
End;

Function Lookup(Src, Dst: Longint; SPort, DPort: Word): Integer;
Var S: Integer;
Begin
 Lookup:=-1;
 For S:=0 To NSOCK-1 Do With Socks[S] Do
  If Used And (Typ=SOCK_STREAM) And (State>TCPS_LISTEN) And (LPort=DPort) And
    (FPort=SPort) And (FAddr=Src) And ((LAddr=0) Or (LAddr=Dst)) Then Begin
   Lookup:=S; Exit;
  End;
 For S:=0 To NSOCK-1 Do With Socks[S] Do
  If Used And (Typ=SOCK_STREAM) And (State=TCPS_LISTEN) And (LPort=DPort) And
    ((LAddr=0) Or (LAddr=Dst)) Then Begin
   Lookup:=S; Exit;
  End;
End;

Procedure TcpInput(P: Integer; Src, Dst: Longint; DOfs, DLen: Word);
Var S,C,K: Integer; SPort,DPort,Win,Hl,OMss,Ol: Word; Seq,Ack,Acked,FinSeq: Longint;
    Flags: Byte; DO_,DL,N: Word; Dup: Longint; FinAcked,Fin: Boolean;
Begin
 Inc(NStat.TcpIn);
 If DLen<20 Then Begin Inc(NStat.TcpBad); Exit End;
 CkSum(NetSeg,DOfs,DLen,PseudoSum(Src,Dst,IPPROTO_TCP,DLen));
 If CkResult<>0 Then Begin Inc(NStat.TcpBad); Exit End;
 SPort:=GetN16(NetSeg,DOfs); DPort:=GetN16(NetSeg,DOfs+2);
 Seq:=GetN32(NetSeg,DOfs+4); Ack:=GetN32(NetSeg,DOfs+8);
 Hl:=(Mem[NetSeg:DOfs+12] Shr 4)*4;
 Flags:=Mem[NetSeg:DOfs+13] And $3F;
 Win:=GetN16(NetSeg,DOfs+14);
 If (Hl<20) Or (Hl>DLen) Then Begin Inc(NStat.TcpBad); Exit End;
 DO_:=DOfs+Hl; DL:=DLen-Hl;
 { option MSS }
 OMss:=536;
 If Flags And TH_SYN<>0 Then Begin
  K:=20;
  While K<Hl Do Begin
   Case Mem[NetSeg:DOfs+K] Of
    0: K:=Hl;
    1: Inc(K);
    Else Begin
     Ol:=Mem[NetSeg:DOfs+K+1];
     If (Mem[NetSeg:DOfs+K]=2) And (Ol=4) Then OMss:=GetN16(NetSeg,DOfs+K+2);
     If Ol<2 Then K:=Hl Else Inc(K,Ol);
    End;
   End;
  End;
  If OMss>TCP_MSS Then OMss:=TCP_MSS;
  If OMss<64 Then OMss:=64;
 End;
 If IsBcast(Dst) Then Exit;
 S:=Lookup(Src,Dst,SPort,DPort);
 If S<0 Then Begin
  If Flags And TH_RST=0 Then
   If Flags And TH_ACK<>0 Then Respond(Dst,Src,DPort,SPort,Ack,0,TH_RST)
   Else Begin
    N:=DL;
    If Flags And TH_SYN<>0 Then Inc(N);
    If Flags And TH_FIN<>0 Then Inc(N);
    Respond(Dst,Src,DPort,SPort,0,Seq+N,TH_RST Or TH_ACK);
   End;
  Exit;
 End;
 With Socks[S] Do Begin
  Case State Of
   TCPS_LISTEN: Begin
    If Flags And TH_RST<>0 Then Exit;
    If Flags And TH_ACK<>0 Then Begin Respond(Dst,Src,DPort,SPort,Ack,0,TH_RST); Exit End;
    If Flags And TH_SYN=0 Then Exit;
    If QLen>=QLimit Then Exit;
    C:=SockAlloc(SOCK_STREAM,IPPROTO_TCP);
    If C<0 Then Exit;
    Socks[C].LAddr:=Dst; Socks[C].LPort:=DPort;
    Socks[C].FAddr:=Src; Socks[C].FPort:=SPort;
    Socks[C].Head:=S; Socks[C].Opts:=Opts;
    Socks[C].State:=TCPS_SYN_RCVD;
    Socks[C].Irs:=Seq; Socks[C].RcvNxt:=Seq+1;
    Socks[C].Iss:=NewIss; Socks[C].SndUna:=Socks[C].Iss;
    Socks[C].SndNxt:=Socks[C].Iss; Socks[C].SndMax:=Socks[C].Iss;
    Socks[C].SndWnd:=Win; Socks[C].Mss:=OMss;
    Inc(QLen);
    TcpOutput(C);
    Exit;
   End;
   TCPS_SYN_SENT: Begin
    If (Flags And TH_ACK<>0) And (SeqLE(Ack,Iss) Or SeqGT(Ack,SndMax)) Then Begin
     If Flags And TH_RST=0 Then Respond(Dst,Src,DPort,SPort,Ack,0,TH_RST);
     Exit;
    End;
    If Flags And TH_RST<>0 Then Begin
     If Flags And TH_ACK<>0 Then TcpDrop(S,ECONNREFUSED);
     Exit;
    End;
    If Flags And TH_SYN=0 Then Exit;
    Irs:=Seq; RcvNxt:=Seq+1; SndWnd:=Win; Mss:=OMss;
    If Flags And TH_ACK<>0 Then Begin
     SndUna:=Ack;
     If SeqLT(SndNxt,SndUna) Then SndNxt:=SndUna;
     State:=TCPS_ESTABLISHED; SFlags:=SFlags Or SS_ISCONNECTED;
     RxtAt:=0; RxtShift:=0;
     AckNow:=True;
     Wakeup(CHSOCK+S);
    End Else Begin
     State:=TCPS_SYN_RCVD; SndNxt:=Iss;
    End;
    TcpOutput(S);
    Exit;
   End;
  End;
  { etats synchronises }
  Fin:=Flags And TH_FIN<>0;
  If Flags And TH_SYN<>0 Then Begin
   { SYN repete (notre acquittement s'est perdu) }
   AckNow:=True; TcpOutput(S);
   Exit;
  End;
  If SeqLT(Seq,RcvNxt) Then Begin
   Dup:=RcvNxt-Seq;
   If Dup>=DL Then Begin
    If DL>0 Then AckNow:=True;
    If Fin And (Dup>DL) Then Begin Fin:=False; AckNow:=True End;
    If Dup>DL Then Dup:=DL;
   End Else AckNow:=True;
   Inc(DO_,Word(Dup)); Dec(DL,Word(Dup)); Seq:=Seq+Dup;
  End Else If SeqGT(Seq,RcvNxt) Then Begin
   { hors sequence : ignore, acquittement repete }
   DL:=0; Fin:=False; AckNow:=True;
   If Flags And TH_RST<>0 Then Exit;
  End;
  If Flags And TH_RST<>0 Then Begin
   If State=TCPS_SYN_RCVD Then Begin
    If Head>=0 Then Finish(S) Else TcpDrop(S,ECONNREFUSED);
   End Else Begin
    Error:=ECONNRESET;
    If State in [TCPS_CLOSE_WAIT,TCPS_LAST_ACK,TCPS_CLOSING,TCPS_TIME_WAIT] Then Error:=0;
    Inc(NStat.TcpDrop);
    Finish(S);
   End;
   Exit;
  End;
  If Flags And TH_ACK=0 Then Exit;
  If State=TCPS_SYN_RCVD Then Begin
   If SeqGT(Ack,SndUna) And SeqLE(Ack,SndMax) Then Begin
    State:=TCPS_ESTABLISHED; SFlags:=SFlags Or SS_ISCONNECTED;
    SndUna:=SndUna+1;              { le SYN }
    SndWnd:=Win;
    If Head>=0 Then Begin Inc(NStat.TcpAccept); Wakeup(CHSOCK+Head) End
    Else Wakeup(CHSOCK+S);
   End Else Begin
    Respond(Dst,Src,DPort,SPort,Ack,0,TH_RST);
    Exit;
   End;
  End;
  { acquittement }
  FinAcked:=False;
  If SeqGT(Ack,SndMax) Then Begin
   AckNow:=True; TcpOutput(S);
   Exit;
  End;
  If SeqGT(Ack,SndUna) Then Begin
   Acked:=Ack-SndUna;
   FinSeq:=SndUna+SndCnt;
   If Acked>SndCnt Then RingDrop(SndHead,SndCnt,SndCnt)
   Else RingDrop(SndHead,SndCnt,Word(Acked));
   SndUna:=Ack;
   If SeqLT(SndNxt,SndUna) Then SndNxt:=SndUna;
   RxtShift:=0;
   If SndUna=SndMax Then RxtAt:=0 Else RxtAt:=Ticks+Rto(S);
   FinAcked:=FinSent And SeqGT(Ack,FinSeq);
   Wakeup(CHSOCK+S);
  End;
  SndWnd:=Win;
  If FinAcked Then
   Case State Of
    TCPS_FIN_WAIT_1: Begin
     State:=TCPS_FIN_WAIT_2;
     If SFlags And SS_NOFDREF<>0 Then TimerAt:=Ticks+FW2TICKS;
    End;
    TCPS_CLOSING: Begin State:=TCPS_TIME_WAIT; TimerAt:=Ticks+TWTICKS End;
    TCPS_LAST_ACK: Begin Finish(S); Exit End;
   End;
  { donnees }
  If (DL>0) And (State In [TCPS_ESTABLISHED,TCPS_FIN_WAIT_1,TCPS_FIN_WAIT_2]) Then Begin
   If SFlags And SS_NOFDREF<>0 Then Begin TcpDrop(S,0); Exit End;
   N:=SBSIZE-RcvCnt;
   If N>DL Then N:=DL;
   If N>0 Then RingPut(SbRcvOfs(S),RcvHead,RcvCnt,NetSeg,DO_,N);
   RcvNxt:=RcvNxt+N;
   If N<DL Then Fin:=False;
   AckNow:=True;
   Wakeup(CHSOCK+S);
  End Else If DL>0 Then Fin:=False;
  { fin de l'autre cote }
  If Fin Then Begin
   RcvNxt:=RcvNxt+1;
   SFlags:=SFlags Or SS_CANTRCVMORE;
   AckNow:=True;
   Wakeup(CHSOCK+S);
   Case State Of
    TCPS_SYN_RCVD, TCPS_ESTABLISHED: State:=TCPS_CLOSE_WAIT;
    TCPS_FIN_WAIT_1:
     If FinAcked Then Begin State:=TCPS_TIME_WAIT; TimerAt:=Ticks+TWTICKS End
     Else State:=TCPS_CLOSING;
    TCPS_FIN_WAIT_2: Begin State:=TCPS_TIME_WAIT; TimerAt:=Ticks+TWTICKS End;
    TCPS_TIME_WAIT: TimerAt:=Ticks+TWTICKS;
   End;
  End;
  TcpOutput(S);
 End;
End;

SegmentEnd;

{ ====================================================================== }
SegmentUnit KSock;
Uses KTypes,KLib,KMem,KSched,KNetIf,KNe2000,KPktDrv,KInet,KTcp;
SegmentInterface

Const
 AF_INET=2;
 { ioctl de configuration du reseau (UNIX-0) }
 SIOCGIFINFO=$6901; SIOCSIFADDR=$6902; SIOCSIFFLAGS=$6903; SIOCSIFIRQ=$6904;
 SIOCADDRT=$6910; SIOCDELRT=$6911; SIOCGRTENTRY=$6912;
 SIOCGARPENT=$6920; SIOCDARP=$6921;
 SIOCGSOCK=$6930; SIOCGNSTAT=$6940;
 FIONBIO=$667E;

Procedure NetInit;
Procedure NetIsr;
Function SoCreate(Typ, Proto: Integer; Var S: Integer): Integer;
Function SoBind(S: Integer; Sg, Os: Word): Integer;
Function SoConnect(S: Integer; Sg, Os: Word): Integer;
Function SoListen(S, Backlog: Integer): Integer;
Function SoAccept(S: Integer; Var NS: Integer): Integer;
Function SoSend(S: Integer; Sg, Os, N: Word; ASg, AOs: Word): Integer;
Function SoRecv(S: Integer; Sg, Os, N: Word; ASg, AOs: Word): Integer;
Function SoShutdown(S, How: Integer): Integer;
Procedure SoClose(S: Integer);
Function SoSetOpt(S: Integer; Opt, Val: Word): Integer;
Function SoGetOpt(S: Integer; Opt: Word; Var Val: Word): Integer;
Function SoName(S: Integer; Peer: Boolean; Sg, Os: Word): Integer;
Function SoIoctl(S: Integer; Req: Word; Sg, Os: Word; Root: Boolean): Integer;
Function SoAvail(S: Integer): Word;

SegmentImplementation

Var
 InIsr: Boolean;
 LastTick, LastSlow: Longint;

Function Hx(W: Word): String;
{ hexadecimal sans zeros de tete }
Var S: String;
Begin
 S:=HexStr(W);
 While (Length(S)>1) And (S[1]='0') Do Delete(S,1,1);
 Hx:=S;
End;

{ --- demarrage --------------------------------------------------------- }

Procedure NetInit;
{ boucle locale, cartes presentes (le segment des tampons n'est reserve
  qu'a la premiere utilisation) }
Var I,N: Integer; S: String;
Begin
 LoopIf:=IfAdd('lo0',DRVLOOP);
 Ifs[LoopIf].Flags:=IFF_LOOPBACK; Ifs[LoopIf].Mtu:=1500;
 Ifs[LoopIf].Model:='boucle locale';
 N:=Ne2000Probe+PktProbe;
 For I:=0 To NIF-1 Do With Ifs[I] Do
  If Used And (Drv<>DRVLOOP) Then Begin
   S:=Name+' : '+Model;
   If Drv=DRVNE2000 Then Begin
    S:=S+', port '+Hx(IoBase)+'h';
    If Irq<>0 Then S:=S+', IRQ '+IntStr(Irq) Else S:=S+', sans IRQ';
    S:=S+', '+MacStr(Mac);
   End Else S:=S+', INT '+Hx(IoBase)+'h';
   KPrintLn(S);
  End;
 If N>0 Then Begin
  For I:=0 To NIF-1 Do
   If Ifs[I].Used And (Ifs[I].Drv=DRVNE2000) And (Ifs[I].Irq<>0) And (NetIrqLine=0) Then
    NetIrqAttach(Ifs[I].Irq);
 End;
End;

Function NetStart: Boolean;
{ premiere utilisation : tampons, boucle locale 127.0.0.1 active }
Begin
 NetStart:=False;
 If Not NetAlloc Then Exit;
 If Ifs[LoopIf].Flags And IFF_UP=0 Then Begin
  IfSetAddr(LoopIf,LOOPADDR,$000000FF);
  IfStart(LoopIf);
 End;
 NetStart:=True;
End;

Procedure EtherInput(P: Integer);
Var Typ: Word; Proto: Byte; Src,Dst: Longint; DOfs,DLen: Word; Kept: Boolean;
Begin
 Kept:=False;
 Typ:=GetN16(NetSeg,PktOfs(P)+12);
 If Typ=ETHERTYPE_ARP Then Kept:=ArpInput(P)
 Else If Typ=ETHERTYPE_IP Then
  If IpInput(P,Proto,Src,Dst,DOfs,DLen) Then
   Case Proto Of
    IPPROTO_ICMP: Kept:=IcmpInput(P,Src,Dst,DOfs,DLen);
    IPPROTO_TCP: TcpInput(P,Src,Dst,DOfs,DLen);
    IPPROTO_UDP: UdpInput(P,Src,Dst,DOfs,DLen);
    Else Begin Inc(NStat.IpNoProto); RawInput(P,Proto,Src) End;
   End;
 If Not Kept Then PktFree(P);
End;

Procedure NetIsr;
{ appelee par l'ordonnanceur (Swtch), jamais pendant une interruption :
  cartes, trames recues, minuteries. Une carte dont les tampons du noyau
  etaient pleins (NetMore) est relue apres le traitement de la file. }
Var I,P,N,R: Integer;
Begin
 If Not NetOn Or InIsr Then Exit;
 InIsr:=True;
 R:=0;
 Repeat
  NetMore:=False;
  For I:=0 To NIF-1 Do If Ifs[I].Used Then IfPoll(I);
  If R=0 Then NetIrqAck;
  N:=0;
  Repeat
   P:=InDequeue;
   If P<0 Then Break;
   EtherInput(P);
   Inc(N);
  Until N>=32;
  Inc(R);
 Until (Not NetMore And (InHead<0)) Or (R>=8);
 If Ticks<>LastTick Then Begin
  LastTick:=Ticks;
  TcpTimer;
  If (Ticks-LastSlow>=9) Or (Ticks<LastSlow) Then Begin
   LastSlow:=Ticks; ArpTimer;
  End;
 End;
 InIsr:=False;
End;

{ --- adresses ---------------------------------------------------------- }

Function GetAddr(Sg, Os: Word; Var A: Longint; Var Port: Word): Integer;
{ struct sockaddr_in : sin_family, sin_port (ordre du reseau), sin_addr }
Begin
 GetAddr:=0;
 If MemW[Sg:Os]<>AF_INET Then Begin GetAddr:=EAFNOSUPPORT; Exit End;
 Port:=GetN16(Sg,Os+2);
 A:=MemL[Sg:Os+4];
End;

Procedure PutAddr(Sg, Os: Word; A: Longint; Port: Word);
Begin
 If (Sg=0) And (Os=0) Then Exit;
 FarFill(Sg,Os,16,0);
 MemW[Sg:Os]:=AF_INET;
 PutN16(Sg,Os+2,Port);
 MemL[Sg:Os+4]:=A;
End;

{ --- appels des sockets ----------------------------------------------- }

Function SoCreate(Typ, Proto: Integer; Var S: Integer): Integer;
Begin
 SoCreate:=0;
 If (Typ<SOCK_STREAM) Or (Typ>SOCK_RAW) Then Begin SoCreate:=ESOCKTNOSUPPORT; Exit End;
 If (Typ=SOCK_STREAM) And (Proto<>0) And (Proto<>IPPROTO_TCP) Then Begin
  SoCreate:=EPROTONOSUPPORT; Exit;
 End;
 If (Typ=SOCK_DGRAM) And (Proto<>0) And (Proto<>IPPROTO_UDP) Then Begin
  SoCreate:=EPROTONOSUPPORT; Exit;
 End;
 If Not NetStart Then Begin SoCreate:=ENOBUFS; Exit End;
 If Typ=SOCK_STREAM Then Proto:=IPPROTO_TCP;
 If Typ=SOCK_DGRAM Then Proto:=IPPROTO_UDP;
 S:=SockAlloc(Typ,Proto);
 If S<0 Then SoCreate:=ENOBUFS;
End;

Function SoBind(S: Integer; Sg, Os: Word): Integer;
Var A: Longint; Port: Word; E: Integer;
Begin
 E:=GetAddr(Sg,Os,A,Port);
 SoBind:=E;
 If E<>0 Then Exit;
 With Socks[S] Do Begin
  If LPort<>0 Then Begin SoBind:=EINVAL; Exit End;
  If (A<>0) And (A And $FF<>127) And (LocalIf(A)<0) Then Begin SoBind:=EADDRNOTAVAIL; Exit End;
  If (Port<>0) And (Port<1024) And (Procs[Cur].Uid<>0) Then Begin SoBind:=EACCES; Exit End;
  If Port=0 Then Begin
   If Typ<>SOCK_RAW Then Port:=EphemeralPort(Typ);
  End Else If (Opts And SO_REUSEADDR=0) And PortUsed(Typ,Port,A) Then Begin
   SoBind:=EADDRINUSE; Exit;
  End;
  LAddr:=A; LPort:=Port;
 End;
End;

Function SoConnect(S: Integer; Sg, Os: Word): Integer;
Var A: Longint; Port: Word; E: Integer; Src: Longint;
Begin
 E:=GetAddr(Sg,Os,A,Port);
 SoConnect:=E;
 If E<>0 Then Exit;
 With Socks[S] Do Begin
  If A=0 Then A:=LOOPADDR;
  If Typ<>SOCK_STREAM Then Begin
   FAddr:=A; FPort:=Port;
   If (LPort=0) And (Typ=SOCK_DGRAM) Then LPort:=EphemeralPort(Typ);
   SFlags:=SFlags Or SS_ISCONNECTED;
   Exit;
  End;
  Case State Of
   TCPS_CLOSED: ;
   TCPS_SYN_SENT, TCPS_SYN_RCVD: Begin SoConnect:=EALREADY; Exit End;
   TCPS_LISTEN: Begin SoConnect:=EOPNOTSUPP; Exit End;
   Else Begin SoConnect:=EISCONN; Exit End;
  End;
  If Port=0 Then Begin SoConnect:=EADDRNOTAVAIL; Exit End;
  Src:=SrcFor(A,IfIdx);
  If Src=0 Then Begin SoConnect:=ENETUNREACH; Exit End;
  If LAddr=0 Then LAddr:=Src;
  If LPort=0 Then LPort:=EphemeralPort(Typ);
  FAddr:=A; FPort:=Port;
  TcpConnect(S);
  If SFlags And SS_NBIO<>0 Then Begin SoConnect:=EINPROGRESS; Exit End;
 End;
 While Socks[S].State In [TCPS_SYN_SENT,TCPS_SYN_RCVD] Do
  If Not SleepIntr(CHSOCK+S) Then Begin SoConnect:=EINTR; Exit End;
 With Socks[S] Do
  If Not (State In [TCPS_ESTABLISHED,TCPS_CLOSE_WAIT]) Then Begin
   E:=Error; If E=0 Then E:=ECONNREFUSED;
   Error:=0; SoConnect:=E;
   { un nouvel essai repartira d'un socket ferme }
   LPort:=0; LAddr:=0;
  End;
End;

Function SoListen(S, Backlog: Integer): Integer;
Begin
 SoListen:=0;
 With Socks[S] Do Begin
  If Typ<>SOCK_STREAM Then Begin SoListen:=EOPNOTSUPP; Exit End;
  If (State<>TCPS_CLOSED) And (State<>TCPS_LISTEN) Then Begin SoListen:=EINVAL; Exit End;
  If LPort=0 Then LPort:=EphemeralPort(Typ);
  If Backlog<1 Then Backlog:=1;
  If Backlog>4 Then Backlog:=4;
  QLimit:=Backlog;
  State:=TCPS_LISTEN;
 End;
End;

Function SoAccept(S: Integer; Var NS: Integer): Integer;
Var C: Integer;
Begin
 SoAccept:=0;
 If (Socks[S].Typ<>SOCK_STREAM) Or (Socks[S].State<>TCPS_LISTEN) Then Begin
  SoAccept:=EINVAL; Exit;
 End;
 Repeat
  For C:=0 To NSOCK-1 Do With Socks[C] Do
   If Used And (Head=S) And (State>=TCPS_ESTABLISHED) Then Begin
    Head:=-1;
    If Socks[S].QLen>0 Then Dec(Socks[S].QLen);
    NS:=C; Exit;
   End;
  If Socks[S].SFlags And SS_NBIO<>0 Then Begin SoAccept:=EWOULDBLOCK; Exit End;
  If Not SleepIntr(CHSOCK+S) Then Begin SoAccept:=EINTR; Exit End;
 Until Not Socks[S].Used Or (Socks[S].State<>TCPS_LISTEN);
 SoAccept:=ECONNABORTED;
End;

Function SoSend(S: Integer; Sg, Os, N: Word; ASg, AOs: Word): Integer;
{ nombre d'octets envoyes, ou -erreur }
Var Done,K,Space: Word; A: Longint; Port: Word; E: Integer;
Begin
 With Socks[S] Do Begin
  If Typ<>SOCK_STREAM Then Begin
   If (ASg<>0) Or (AOs<>0) Then Begin
    E:=GetAddr(ASg,AOs,A,Port);
    If E<>0 Then Begin SoSend:=-E; Exit End;
   End Else If FAddr<>0 Then Begin A:=FAddr; Port:=FPort End
   Else Begin SoSend:=-EDESTADDRREQ; Exit End;
   If IsBcast(A) And (Opts And SO_BROADCAST=0) Then Begin SoSend:=-EACCES; Exit End;
   If Typ=SOCK_DGRAM Then Begin
    If LPort=0 Then LPort:=EphemeralPort(Typ);
    E:=UdpOutput(S,A,Port,Sg,Os,N);
   End Else E:=RawOutput(S,A,Sg,Os,N);
   If E<>0 Then SoSend:=-E Else SoSend:=N;
   Exit;
  End;
 End;
 Done:=0;
 While Done<N Do With Socks[S] Do Begin
  If Error<>0 Then Begin
   If Done>0 Then Break;
   SoSend:=-Error; Error:=0; Exit;
  End;
  If (SFlags And SS_CANTSENDMORE<>0) Or Not (State In [TCPS_ESTABLISHED,TCPS_CLOSE_WAIT]) Then Begin
   If Done>0 Then Break;
   If State In [TCPS_CLOSED,TCPS_LISTEN] Then
    If SFlags And SS_ISCONNECTED=0 Then Begin SoSend:=-ENOTCONN; Exit End;
   PostSig(Cur,SIGPIPE);
   SoSend:=-EPIPE; Exit;
  End;
  Space:=SBSIZE-SndCnt;
  If Space=0 Then Begin
   TcpOutput(S);
   If SFlags And SS_NBIO<>0 Then Begin
    If Done>0 Then Break;
    SoSend:=-EWOULDBLOCK; Exit;
   End;
   If Not SleepIntr(CHSOCK+S) Then Begin
    If Done>0 Then Break;
    SoSend:=-EINTR; Exit;
   End;
   Continue;
  End;
  K:=N-Done; If K>Space Then K:=Space;
  RingPut(SbSndOfs(S),SndHead,SndCnt,Sg,Os+Done,K);
  Inc(Done,K);
  TcpOutput(S);
 End;
 SoSend:=Done;
End;

Function SoRecv(S: Integer; Sg, Os, N: Word; ASg, AOs: Word): Integer;
Var K,L: Word; Hdr: Array[0..7] Of Byte; E: Integer;
Begin
 With Socks[S] Do Begin
  While RcvCnt=0 Do Begin
   If Error<>0 Then Begin SoRecv:=-Error; Error:=0; Exit End;
   If Typ=SOCK_STREAM Then Begin
    If SFlags And SS_CANTRCVMORE<>0 Then Begin SoRecv:=0; Exit End;
    If Not (State In [TCPS_SYN_SENT,TCPS_SYN_RCVD,TCPS_ESTABLISHED,TCPS_FIN_WAIT_1,
      TCPS_FIN_WAIT_2]) Then Begin
     If SFlags And SS_ISCONNECTED<>0 Then SoRecv:=0 Else SoRecv:=-ENOTCONN;
     Exit;
    End;
   End;
   If SFlags And SS_NBIO<>0 Then Begin SoRecv:=-EWOULDBLOCK; Exit End;
   If Not SleepIntr(CHSOCK+S) Then Begin SoRecv:=-EINTR; Exit End;
   If Not Used Then Begin SoRecv:=-ECONNABORTED; Exit End;
  End;
  If Typ=SOCK_STREAM Then Begin
   K:=N; If K>RcvCnt Then K:=RcvCnt;
   RingGet(SbRcvOfs(S),RcvHead,RcvCnt,Sg,Os,K);
   PutAddr(ASg,AOs,FAddr,FPort);
   TcpRcvd(S);
   SoRecv:=K;
   Exit;
  End;
  { datagramme : [longueur, adresse, port] + donnees }
  RingGet(SbRcvOfs(S),RcvHead,RcvCnt,Seg(Hdr),Ofs(Hdr),8);
  L:=Hdr[0] Or (Word(Hdr[1]) Shl 8);
  K:=L; If K>N Then K:=N;
  RingGet(SbRcvOfs(S),RcvHead,RcvCnt,Sg,Os,K);
  If L>K Then RingDrop(RcvHead,RcvCnt,L-K);
  PutAddr(ASg,AOs,MemL[Seg(Hdr):Ofs(Hdr)+2],Hdr[6] Or (Word(Hdr[7]) Shl 8));
  SoRecv:=K;
 End;
End;

Function SoShutdown(S, How: Integer): Integer;
Begin
 SoShutdown:=0;
 With Socks[S] Do Begin
  If How<>1 Then Begin
   SFlags:=SFlags Or SS_CANTRCVMORE;
   Wakeup(CHSOCK+S);
  End;
  If How<>0 Then
   If Typ=SOCK_STREAM Then TcpShutdown(S)
   Else SFlags:=SFlags Or SS_CANTSENDMORE;
 End;
End;

Procedure SoClose(S: Integer);
Begin
 If Not Socks[S].Used Then Exit;
 If Socks[S].Typ=SOCK_STREAM Then TcpClose(S) Else SockFree(S);
End;

Function SoSetOpt(S: Integer; Opt, Val: Word): Integer;
Var I: Integer;
Begin
 SoSetOpt:=0;
 With Socks[S] Do
  Case Opt Of
   SO_REUSEADDR, SO_KEEPALIVE, SO_BROADCAST:
    If Val<>0 Then Opts:=Opts Or Opt Else Opts:=Opts And Not Opt;
   $1001..$1003: ;                    { tailles des tampons : fixes }
   $7F01: If Val=$FFFF Then IfIdx:=-1 Else Begin
    { UNIX-0 : interface de la diffusion (numero d'interface) }
    If (Val<NIF) And Ifs[Val].Used Then IfIdx:=Val Else SoSetOpt:=ENXIO;
   End;
   Else SoSetOpt:=ENOPROTOOPT;
  End;
End;

Function SoGetOpt(S: Integer; Opt: Word; Var Val: Word): Integer;
Begin
 SoGetOpt:=0; Val:=0;
 With Socks[S] Do
  Case Opt Of
   SO_REUSEADDR, SO_KEEPALIVE, SO_BROADCAST: Val:=Ord(Opts And Opt<>0);
   $1001,$1002: Val:=SBSIZE;
   $1007: Begin Val:=Error; Error:=0 End;   { SO_ERROR }
   $1008: Val:=Typ;                          { SO_TYPE }
   Else SoGetOpt:=ENOPROTOOPT;
  End;
End;

Function SoName(S: Integer; Peer: Boolean; Sg, Os: Word): Integer;
Begin
 SoName:=0;
 With Socks[S] Do
  If Peer Then Begin
   If (FAddr=0) And (SFlags And SS_ISCONNECTED=0) Then SoName:=ENOTCONN
   Else PutAddr(Sg,Os,FAddr,FPort);
  End Else PutAddr(Sg,Os,LAddr,LPort);
End;

Function SoAvail(S: Integer): Word;
Begin
 With Socks[S] Do
  If Typ=SOCK_STREAM Then SoAvail:=RcvCnt
  Else If RcvCnt>=8 Then SoAvail:=MemW[NetSeg:SbRcvOfs(S)+RcvHead]
  Else SoAvail:=0;
End;

{ --- ioctl de configuration -------------------------------------------- }

Function SoIoctl(S: Integer; Req: Word; Sg, Os: Word; Root: Boolean): Integer;
{ struct ifinfo (96 octets) : nom[8], numero, drapeaux, mtu, mac[6],
  adresse, masque, diffusion, pilote, irq, port, 6 compteurs, modele[24].
  struct rtentry (24) : destination, masque, passerelle, drapeaux, nom[8],
  numero. struct arpent (18) : numero, ip, mac[6], etat, interface, age.
  struct sockinfo (24) : numero, type, etat, adresse et port locaux et
  distants, octets recus et a envoyer, protocole, drapeaux, utilise. }
Var I,K: Integer; N: String[7]; A,M,G: Longint;

 Function IfByName: Integer;
 Begin
  N:=FarStr(Sg,Os,7);
  IfByName:=IfFind(N);
 End;

Begin
 SoIoctl:=0;
 Case Req Of
  FIONBIO:
   If MemW[Sg:Os]<>0 Then Socks[S].SFlags:=Socks[S].SFlags Or SS_NBIO
   Else Socks[S].SFlags:=Socks[S].SFlags And Not SS_NBIO;
  SIOCGIFINFO: Begin
   I:=MemW[Sg:Os+8];
   If (I<0) Or (I>=NIF) Or Not Ifs[I].Used Then Begin SoIoctl:=ENXIO; Exit End;
   FarFill(Sg,Os,96,0);
   With Ifs[I] Do Begin
    PutFarStr(Sg,Os,Name);
    MemW[Sg:Os+8]:=I; MemW[Sg:Os+10]:=Flags; MemW[Sg:Os+12]:=Mtu;
    For K:=0 To 5 Do Mem[Sg:Os+14+K]:=Mac[K];
    MemL[Sg:Os+20]:=Addr; MemL[Sg:Os+24]:=Mask; MemL[Sg:Os+28]:=Bcast;
    Mem[Sg:Os+32]:=Drv; Mem[Sg:Os+33]:=Irq; MemW[Sg:Os+34]:=IoBase;
    MemL[Sg:Os+36]:=IPackets; MemL[Sg:Os+40]:=OPackets;
    MemL[Sg:Os+44]:=IErrors; MemL[Sg:Os+48]:=OErrors;
    MemL[Sg:Os+52]:=IBytes; MemL[Sg:Os+56]:=OBytes;
    PutFarStr(Sg,Os+60,Model);
   End;
  End;
  SIOCSIFADDR, SIOCSIFFLAGS, SIOCSIFIRQ: Begin
   If Not Root Then Begin SoIoctl:=EPERM; Exit End;
   I:=IfByName;
   If I<0 Then Begin SoIoctl:=ENXIO; Exit End;
   Case Req Of
    SIOCSIFADDR: IfSetAddr(I,MemL[Sg:Os+20],MemL[Sg:Os+24]);
    SIOCSIFFLAGS:
     If MemW[Sg:Os+10] And IFF_UP<>0 Then Begin
      If Not IfStart(I) Then SoIoctl:=ENXIO;
     End Else IfStop(I);
    SIOCSIFIRQ:
     If (Ifs[I].Drv=DRVNE2000) And (NetIrqLine=0) Then Begin
      Ifs[I].Irq:=Mem[Sg:Os+33];
      NetIrqAttach(Ifs[I].Irq);
      If Ifs[I].Flags And IFF_UP<>0 Then IfStart(I);
     End Else SoIoctl:=EBUSY;
   End;
  End;
  SIOCADDRT, SIOCDELRT: Begin
   If Not Root Then Begin SoIoctl:=EPERM; Exit End;
   A:=MemL[Sg:Os]; M:=MemL[Sg:Os+4]; G:=MemL[Sg:Os+8];
   If Req=SIOCDELRT Then Begin
    If Not RtDel(A,M) Then SoIoctl:=ESRCH;
    Exit;
   End;
   { interface : celle qui atteint la passerelle, ou celle nommee }
   N:=FarStr(Sg,Os+14,7);
   I:=-1;
   If N<>'' Then I:=IfFind(N)
   Else If G<>0 Then Begin
    If Not RtLookup(G,I,A) Then I:=-1;
    A:=MemL[Sg:Os];
   End;
   If I<0 Then Begin SoIoctl:=ENETUNREACH; Exit End;
   If G<>0 Then K:=RTF_GATEWAY Else K:=0;
   If M=-1 Then K:=K Or RTF_HOST;
   If Not RtAdd(A,M,G,I,K) Then SoIoctl:=ENOBUFS;
  End;
  SIOCGRTENTRY: Begin
   I:=MemW[Sg:Os+22];
   If (I<0) Or (I>=NRT) Then Begin SoIoctl:=ENXIO; Exit End;
   FarFill(Sg,Os,22,0);
   With Routes[I] Do If Used Then Begin
    MemL[Sg:Os]:=Dst; MemL[Sg:Os+4]:=Mask; MemL[Sg:Os+8]:=Gw;
    MemW[Sg:Os+12]:=Flags;
    If IfI>=0 Then PutFarStr(Sg,Os+14,Ifs[IfI].Name);
   End;
  End;
  SIOCGARPENT: Begin
   I:=MemW[Sg:Os];
   If (I<0) Or (I>=NARP) Then Begin SoIoctl:=ENXIO; Exit End;
   FarFill(Sg,Os+2,16,0);
   With ArpTab[I] Do Begin
    MemL[Sg:Os+2]:=Ip;
    For K:=0 To 5 Do Mem[Sg:Os+6+K]:=Mac[K];
    Mem[Sg:Os+12]:=State; Mem[Sg:Os+13]:=Byte(IfI);
    MemL[Sg:Os+14]:=(Ticks-Time) Div 18;
   End;
  End;
  SIOCDARP: Begin
   If Not Root Then Begin SoIoctl:=EPERM; Exit End;
   A:=MemL[Sg:Os+2]; SoIoctl:=ENXIO;
   For I:=0 To NARP-1 Do
    If (ArpTab[I].State<>ARP_FREE) And (ArpTab[I].Ip=A) Then Begin
     If ArpTab[I].Hold>=0 Then PktFree(ArpTab[I].Hold);
     ArpTab[I].Hold:=-1; ArpTab[I].State:=ARP_FREE; SoIoctl:=0;
    End;
  End;
  SIOCGSOCK: Begin
   I:=MemW[Sg:Os];
   If (I<0) Or (I>=NSOCK) Then Begin SoIoctl:=ENXIO; Exit End;
   FarFill(Sg,Os+2,22,0);
   With Socks[I] Do If Used Then Begin
    Mem[Sg:Os+2]:=Typ; Mem[Sg:Os+3]:=State;
    MemL[Sg:Os+4]:=LAddr; MemW[Sg:Os+8]:=LPort;
    MemL[Sg:Os+10]:=FAddr; MemW[Sg:Os+14]:=FPort;
    MemW[Sg:Os+16]:=RcvCnt; MemW[Sg:Os+18]:=SndCnt;
    Mem[Sg:Os+20]:=Proto; Mem[Sg:Os+21]:=Lo(SFlags); Mem[Sg:Os+22]:=1;
   End;
  End;
  SIOCGNSTAT: FarMove(DSeg,Ofs(NStat),Sg,Os,SizeOf(NStat));
  Else SoIoctl:=EINVAL;
 End;
End;

SegmentEnd;
