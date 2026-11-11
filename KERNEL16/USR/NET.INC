{ Interface des sockets de UNIX-0 pour les programmes du reseau (directive
  d'inclusion I NET.INC) : appels systeme de 4.2BSD (socket, bind, connect, listen,
  accept, sendto, recvfrom, shutdown, options), ioctl de configuration
  (interfaces, routes, ARP, sockets, statistiques), adresses IP en texte et
  resolution des noms : notation pointee, /etc/hosts, puis serveur DNS de
  /etc/resolv.conf (requete UDP de type A, deux essais de 3 secondes).
  Les adresses IP sont des Longint dont les octets sont dans l'ordre du
  reseau (comme in_addr); les ports sont dans l'ordre de l'hote. }

Const
 AF_INET=2;
 SOCK_STREAM=1; SOCK_DGRAM=2; SOCK_RAW=3;
 IPPROTO_ICMP=1; IPPROTO_TCP=6; IPPROTO_UDP=17;
 SO_REUSEADDR=4; SO_KEEPALIVE=8; SO_BROADCAST=$20; SO_ERROR=$1007;
 SO_IFINDEX=$7F01;            { UNIX-0 : interface de la diffusion }
 SYS_socket=97; SYS_connect=98; SYS_accept=99; SYS_bind=104;
 SYS_setsockopt=105; SYS_listen=106; SYS_getsockopt=118;
 SYS_recvfrom=125; SYS_sendto=133; SYS_shutdown=134;
 SYS_getpeername=141; SYS_getsockname=150;
 SYS_gethostname=87; SYS_sethostname=88;
 SIOCGIFINFO=$6901; SIOCSIFADDR=$6902; SIOCSIFFLAGS=$6903; SIOCSIFIRQ=$6904;
 SIOCADDRT=$6910; SIOCDELRT=$6911; SIOCGRTENTRY=$6912;
 SIOCGARPENT=$6920; SIOCDARP=$6921;
 SIOCGSOCK=$6930; SIOCGNSTAT=$6940;
 FIONBIO=$667E;
 IFF_UP=1; IFF_BROADCAST=2; IFF_LOOPBACK=8; IFF_RUNNING=$40;
 RTF_UP=1; RTF_GATEWAY=2; RTF_HOST=4;
 DRV_LOOP=1; DRV_NE2000=2; DRV_PKT=3;
 EWOULDBLOCK=35; EINPROGRESS=36; EALREADY=37; ENOTSOCK=38;
 EDESTADDRREQ=39; EMSGSIZE=40; EPROTOTYPE=41; ENOPROTOOPT=42;
 EPROTONOSUPPORT=43; ESOCKTNOSUPPORT=44; EOPNOTSUPP=45; EAFNOSUPPORT=47;
 EADDRINUSE=48; EADDRNOTAVAIL=49; ENETDOWN=50; ENETUNREACH=51;
 ECONNABORTED=53; ECONNRESET=54; ENOBUFS=55; EISCONN=56; ENOTCONN=57;
 ESHUTDOWN=58; ETIMEDOUT=60; ECONNREFUSED=61; EHOSTUNREACH=65;
 TCPStates: Array[0..10] Of String[11]=('CLOSED','LISTEN','SYN_SENT',
  'SYN_RCVD','ESTABLISHED','CLOSE_WAIT','FIN_WAIT_1','CLOSING','LAST_ACK',
  'FIN_WAIT_2','TIME_WAIT');

Type
 TSockAddr=Record            { struct sockaddr_in (16 octets) }
  Family: Word;
  Port: Word;                { ordre du reseau }
  Addr: Longint;
  Zero: Array[0..7] Of Byte;
 End;
 TIfInfo=Record              { 96 octets }
  Name: Array[0..7] Of Char;
  Index, Flags, Mtu: Word;
  Mac: Array[0..5] Of Byte;
  Addr, Mask, Bcast: Longint;
  Drv, Irq: Byte;
  IoBase: Word;
  IPackets, OPackets, IErrors, OErrors, IBytes, OBytes: Longint;
  Model: Array[0..23] Of Char;
  Pad: Array[0..11] Of Byte;
 End;
 TRtEntry=Record             { 24 octets }
  Dst, Mask, Gw: Longint;
  Flags: Word;
  IfName: Array[0..7] Of Char;
  Index: Word;
 End;
 TArpEnt=Record              { 18 octets }
  Index: Word;
  Ip: Longint;
  Mac: Array[0..5] Of Byte;
  State, IfIdx: Byte;
  Age: Longint;
 End;
 TSockInfo=Record            { 24 octets }
  Index: Word;
  Typ, State: Byte;
  LAddr: Longint; LPort: Word;
  FAddr: Longint; FPort: Word;
  RcvCnt, SndCnt: Word;
  Proto, Flags, Used, Pad: Byte;
 End;
 TNetStat=Record
  IpIn, IpOut, IpBad, IpFrag, IpNoProto, IpNoRoute,
  IcmpIn, IcmpOut, UdpIn, UdpOut, UdpNoPort,
  TcpIn, TcpOut, TcpRexmt, TcpConn, TcpAccept, TcpDrop, TcpRstOut, TcpBad,
  ArpIn, ArpOut: Longint;
 End;

Var
 NetTimedOut: Boolean;
 DnsBuf: Array[0..511] Of Byte;

{ --- appels systeme ----------------------------------------------------- }

Procedure NetSys(N, B, C, D: Word);
Begin
 SAX:=N; SBX:=B; SCX:=C; SDX:=D; SSI:=0; SDI:=0; SDS:=DSeg; SES:=0;
End;

Function NetResult: Integer;
Begin
 DoSys;
 If SysOk Then NetResult:=SAX Else NetResult:=-1;
End;

Procedure MakeAddr(Var SA: TSockAddr; A: Longint; Port: Word);
Begin
 FillChar(SA,SizeOf(SA),0);
 SA.Family:=AF_INET; SA.Port:=Swap(Port); SA.Addr:=A;
End;

Function Socket(Domain, Typ, Proto: Integer): Integer;
Begin
 NetSys(SYS_socket,Domain,Typ,Proto);
 Socket:=NetResult;
End;

Function Bind(Fd: Integer; A: Longint; Port: Word): Integer;
Var SA: TSockAddr;
Begin
 MakeAddr(SA,A,Port);
 NetSys(SYS_bind,Fd,SizeOf(SA),Ofs(SA)); SDS:=Seg(SA);
 Bind:=NetResult;
End;

Function Connect(Fd: Integer; A: Longint; Port: Word): Integer;
Var SA: TSockAddr;
Begin
 MakeAddr(SA,A,Port);
 NetSys(SYS_connect,Fd,SizeOf(SA),Ofs(SA)); SDS:=Seg(SA);
 Connect:=NetResult;
End;

Function Listen(Fd, Backlog: Integer): Integer;
Begin
 NetSys(SYS_listen,Fd,Backlog,0);
 Listen:=NetResult;
End;

Function Accept(Fd: Integer; Var A: Longint; Var Port: Word): Integer;
Var SA: TSockAddr; R: Integer;
Begin
 FillChar(SA,SizeOf(SA),0);
 NetSys(SYS_accept,Fd,0,Ofs(SA)); SDS:=Seg(SA);
 R:=NetResult;
 A:=SA.Addr; Port:=Swap(SA.Port);
 Accept:=R;
End;

Function SendTo(Fd: Integer; Var Buf; Len: Word; A: Longint; Port: Word): Integer;
Var SA: TSockAddr;
Begin
 MakeAddr(SA,A,Port);
 NetSys(SYS_sendto,Fd,Len,Ofs(Buf)); SDS:=Seg(Buf);
 SES:=Seg(SA); SDI:=Ofs(SA);
 SendTo:=NetResult;
End;

Function Send(Fd: Integer; Var Buf; Len: Word): Integer;
Begin
 NetSys(SYS_sendto,Fd,Len,Ofs(Buf)); SDS:=Seg(Buf);
 Send:=NetResult;
End;

Function RecvFrom(Fd: Integer; Var Buf; Len: Word; Var A: Longint; Var Port: Word): Integer;
Var SA: TSockAddr; R: Integer;
Begin
 FillChar(SA,SizeOf(SA),0);
 NetSys(SYS_recvfrom,Fd,Len,Ofs(Buf)); SDS:=Seg(Buf);
 SES:=Seg(SA); SDI:=Ofs(SA);
 R:=NetResult;
 A:=SA.Addr; Port:=Swap(SA.Port);
 RecvFrom:=R;
End;

Function Recv(Fd: Integer; Var Buf; Len: Word): Integer;
Begin
 NetSys(SYS_recvfrom,Fd,Len,Ofs(Buf)); SDS:=Seg(Buf);
 Recv:=NetResult;
End;

Function Shutdown(Fd, How: Integer): Integer;
Begin
 NetSys(SYS_shutdown,Fd,How,0);
 Shutdown:=NetResult;
End;

Function SetSockOpt(Fd: Integer; Opt, Val: Word): Integer;
Begin
 NetSys(SYS_setsockopt,Fd,Opt,Val);
 SetSockOpt:=NetResult;
End;

Function GetSockOpt(Fd: Integer; Opt: Word): Integer;
Begin
 NetSys(SYS_getsockopt,Fd,Opt,0);
 GetSockOpt:=NetResult;
End;

Function SockName(Fd: Integer; Peer: Boolean; Var A: Longint; Var Port: Word): Integer;
Var SA: TSockAddr; R: Integer;
Begin
 FillChar(SA,SizeOf(SA),0);
 If Peer Then NetSys(SYS_getpeername,Fd,0,Ofs(SA))
 Else NetSys(SYS_getsockname,Fd,0,Ofs(SA));
 SDS:=Seg(SA);
 R:=NetResult;
 A:=SA.Addr; Port:=Swap(SA.Port);
 SockName:=R;
End;

Function GetHostName: String;
Var S: String;
Begin
 S:='';
 NetSys(SYS_gethostname,0,0,Ofs(S)); SDS:=Seg(S);
 DoSys;
 GetHostName:=S;
End;

Function SetHostName(S: String): Integer;
Begin
 NetSys(SYS_sethostname,0,0,Ofs(S)); SDS:=Seg(S);
 SetHostName:=NetResult;
End;

{ --- textes ------------------------------------------------------------- }

Function CStr(Var A; Max: Integer): String;
{ chaine terminee par un nul }
Var S: String; I: Integer;
Begin
 S:='';
 I:=0;
 While (I<Max) And (Mem[Seg(A):Ofs(A)+I]<>0) Do Begin
  S:=S+Chr(Mem[Seg(A):Ofs(A)+I]); Inc(I);
 End;
 CStr:=S;
End;

Procedure PutCStr(Var A; Max: Integer; S: String);
Var I: Integer;
Begin
 FillChar(A,Max,0);
 For I:=1 To Length(S) Do If I<Max Then Mem[Seg(A):Ofs(A)+I-1]:=Ord(S[I]);
End;

Function IStr(L: Longint): String;
Var S: String;
Begin
 Str(L,S); IStr:=S;
End;

Function InetNtoA(A: Longint): String;
Begin
 InetNtoA:=IStr(A And $FF)+'.'+IStr((A Shr 8) And $FF)+'.'+
   IStr((A Shr 16) And $FF)+'.'+IStr((A Shr 24) And $FF);
End;

Function InetAddr(S: String; Var A: Longint): Boolean;
{ notation pointee a.b.c.d }
Var K,N,V,E: Integer; Part: String;
Begin
 InetAddr:=False; A:=0; N:=0;
 S:=S+'.';
 While S<>'' Do Begin
  K:=Pos('.',S);
  Part:=Copy(S,1,K-1); Delete(S,1,K);
  If (Part='') Or (Length(Part)>3) Then Exit;
  Val(Part,V,E);
  If (E<>0) Or (V<0) Or (V>255) Then Exit;
  If N>3 Then Exit;
  A:=A Or (Longint(V) Shl (8*N));
  Inc(N);
 End;
 InetAddr:=N=4;
End;

Function HexB(B: Byte): String;
Const H: String[16]='0123456789abcdef';
Begin
 HexB:=H[(B Shr 4)+1]+H[(B And 15)+1];
End;

Function MacText(Var M): String;
Var S: String; I: Integer;
Begin
 S:='';
 For I:=0 To 5 Do Begin
  If I>0 Then S:=S+':';
  S:=S+HexB(Mem[Seg(M):Ofs(M)+I]);
 End;
 MacText:=S;
End;

Function MaskBits(M: Longint): Integer;
Var K,N: Integer;
Begin
 N:=0;
 For K:=0 To 31 Do If (M Shr K) And 1<>0 Then Inc(N);
 MaskBits:=N;
End;

Function NetErrorText(E: Integer): String;
Begin
 Case E Of
  EWOULDBLOCK: NetErrorText:='Operation bloquante';
  EINPROGRESS: NetErrorText:='Operation en cours';
  EALREADY: NetErrorText:='Operation deja en cours';
  ENOTSOCK: NetErrorText:='N''est pas un socket';
  EDESTADDRREQ: NetErrorText:='Adresse de destination requise';
  EMSGSIZE: NetErrorText:='Message trop long';
  EPROTONOSUPPORT: NetErrorText:='Protocole non supporte';
  ESOCKTNOSUPPORT: NetErrorText:='Type de socket non supporte';
  EOPNOTSUPP: NetErrorText:='Operation non supportee';
  EAFNOSUPPORT: NetErrorText:='Famille d''adresses non supportee';
  EADDRINUSE: NetErrorText:='Adresse deja utilisee';
  EADDRNOTAVAIL: NetErrorText:='Adresse non disponible';
  ENETDOWN: NetErrorText:='Le reseau est arrete';
  ENETUNREACH: NetErrorText:='Reseau injoignable';
  ECONNABORTED: NetErrorText:='Connexion abandonnee';
  ECONNRESET: NetErrorText:='Connexion reinitialisee par le correspondant';
  ENOBUFS: NetErrorText:='Plus de tampons disponibles';
  EISCONN: NetErrorText:='Socket deja connecte';
  ENOTCONN: NetErrorText:='Socket non connecte';
  ETIMEDOUT: NetErrorText:='Delai de connexion depasse';
  ECONNREFUSED: NetErrorText:='Connexion refusee';
  EHOSTUNREACH: NetErrorText:='Hote injoignable';
  Else NetErrorText:=SysErrorText(E);
 End;
End;

{ --- configuration ------------------------------------------------------- }

Function NetCtl(Req: Word; Var Arg): Integer;
{ ioctl de configuration sur un socket UDP temporaire }
Var Fd,R: Integer;
Begin
 Fd:=Socket(AF_INET,SOCK_DGRAM,0);
 If Fd<0 Then Begin NetCtl:=-1; Exit End;
 R:=SysIoctl(Fd,Req,Arg);
 SysClose(Fd);
 NetCtl:=R;
End;

Function IfInfo(I: Integer; Var F: TIfInfo): Boolean;
Begin
 FillChar(F,SizeOf(F),0);
 F.Index:=I;
 IfInfo:=NetCtl(SIOCGIFINFO,F)=0;
End;

Function IfByName(N: String; Var F: TIfInfo): Boolean;
Var I: Integer;
Begin
 IfByName:=False;
 For I:=0 To 7 Do
  If IfInfo(I,F) Then
   If CStr(F.Name,8)=N Then Begin IfByName:=True; Exit End;
End;

{ --- resolution des noms ------------------------------------------------ }

Procedure NetAlarm(Sig: Integer); Far;
Begin
 NetTimedOut:=True;
End;

Function Lower(S: String): String;
Var I: Integer;
Begin
 For I:=1 To Length(S) Do If S[I] In ['A'..'Z'] Then S[I]:=Chr(Ord(S[I])+32);
 Lower:=S;
End;

Function NextWord(Var S: String): String;
Var K: Integer;
Begin
 While (S<>'') And (S[1] In [' ',#9]) Do Delete(S,1,1);
 K:=1;
 While (K<=Length(S)) And Not (S[K] In [' ',#9]) Do Inc(K);
 NextWord:=Copy(S,1,K-1);
 Delete(S,1,K-1);
End;

Function HostsLookup(Name: String; Var A: Longint): Boolean;
Var F: Text; S,W,Ad: String; T: Longint;
Begin
 HostsLookup:=False;
 Assign(F,'/etc/hosts'); Reset(F);
 If IOResult<>0 Then Exit;
 While Not EOF(F) Do Begin
  ReadLn(F,S);
  If Pos('#',S)>0 Then S:=Copy(S,1,Pos('#',S)-1);
  Ad:=NextWord(S);
  If Not InetAddr(Ad,T) Then Continue;
  Repeat
   W:=NextWord(S);
   If (W<>'') And (Lower(W)=Lower(Name)) Then Begin
    A:=T; HostsLookup:=True; Close(F); Exit;
   End;
  Until W='';
 End;
 Close(F);
End;

Function NameServer(Var A: Longint): Boolean;
Var F: Text; S,W: String;
Begin
 NameServer:=False;
 Assign(F,'/etc/resolv.conf'); Reset(F);
 If IOResult<>0 Then Exit;
 While Not EOF(F) Do Begin
  ReadLn(F,S);
  W:=NextWord(S);
  If W='nameserver' Then
   If InetAddr(NextWord(S),A) Then Begin NameServer:=True; Close(F); Exit End;
 End;
 Close(F);
End;

Function SkipName(P: Integer; N: Integer): Integer;
{ nom de domaine du message DNS (etiquettes ou pointeur) }
Begin
 While (P<N) And (DnsBuf[P]<>0) Do Begin
  If DnsBuf[P] And $C0=$C0 Then Begin SkipName:=P+2; Exit End;
  P:=P+DnsBuf[P]+1;
 End;
 SkipName:=P+1;
End;

Function DnsLookup(Name: String; Var A: Longint): Boolean;
Var Ns,From: Longint; Fd,N,P,K,Q,Try,An,Id: Integer; Port: Word; Part: String;
    Old: Pointer; T,C,L: Word;
Begin
 DnsLookup:=False;
 If Not NameServer(Ns) Then Exit;
 Fd:=Socket(AF_INET,SOCK_DGRAM,0);
 If Fd<0 Then Exit;
 Id:=GetPid And $7FFF;
 { question : en-tete, nom en etiquettes, type A, classe IN }
 FillChar(DnsBuf,12,0);
 DnsBuf[0]:=Hi(Id); DnsBuf[1]:=Lo(Id); DnsBuf[2]:=1; DnsBuf[5]:=1;
 P:=12; Part:=Name+'.';
 While Part<>'.' Do Begin
  K:=Pos('.',Part);
  If (K<=1) Or (K>64) Then Begin SysClose(Fd); Exit End;
  DnsBuf[P]:=K-1;
  Move(Part[1],DnsBuf[P+1],K-1);
  P:=P+K; Delete(Part,1,K);
  If Part='' Then Part:='.';
 End;
 DnsBuf[P]:=0; DnsBuf[P+1]:=0; DnsBuf[P+2]:=1; DnsBuf[P+3]:=0; DnsBuf[P+4]:=1;
 Q:=P+5;
 Old:=SysSignal(SIGALRM,@NetAlarm);
 For Try:=1 To 2 Do Begin
  If SendTo(Fd,DnsBuf,Q,Ns,53)<0 Then Break;
  NetTimedOut:=False;
  SysAlarm(3);
  Repeat
   N:=RecvFrom(Fd,DnsBuf,SizeOf(DnsBuf),From,Port);
  Until (N<0) Or ((N>=12) And (DnsBuf[0]=Hi(Id)) And (DnsBuf[1]=Lo(Id)));
  SysAlarm(0);
  If N>=12 Then Begin
   An:=DnsBuf[6]*256+DnsBuf[7];
   P:=SkipName(12,N)+4;
   While (An>0) And (P+10<=N) Do Begin
    P:=SkipName(P,N);
    T:=DnsBuf[P]*256+DnsBuf[P+1]; C:=DnsBuf[P+2]*256+DnsBuf[P+3];
    L:=DnsBuf[P+8]*256+DnsBuf[P+9];
    P:=P+10;
    If (T=1) And (C=1) And (L=4) And (P+4<=N) Then Begin
     Move(DnsBuf[P],A,4);
     DnsLookup:=True;
     SysSignal(SIGALRM,Old); SysClose(Fd);
     Exit;
    End;
    P:=P+L; Dec(An);
   End;
   Break;
  End;
 End;
 SysSignal(SIGALRM,Old);
 SysClose(Fd);
End;

Function Resolve(Name: String; Var A: Longint): Boolean;
{ adresse d'un hote : notation pointee, /etc/hosts, DNS }
Begin
 Resolve:=True;
 If InetAddr(Name,A) Then Exit;
 If Lower(Name)='localhost' Then Begin A:=$0100007F; Exit End;
 If HostsLookup(Name,A) Then Exit;
 Resolve:=DnsLookup(Name,A);
End;
