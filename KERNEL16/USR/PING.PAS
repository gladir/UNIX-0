{ @author: Sylvain Maltais (support@gladir.com)
  @created: 2026
  @website(https://www.gladir.com/unix-0)
  @abstract(Target: Unix Pascal (UPC /X))
  @description: Envoie des demandes d'echo ICMP (RFC 792) a un hote et
   affiche les reponses, comme ping de 4.3BSD : un paquet par seconde,
   statistiques a la fin (ou a ^C).
     ping [-c nombre] [-s taille] hote
   Le socket brut ICMP est reserve au super-utilisateur : /bin/ping est
   installe set-uid root (mode 4755).
   Compilation : UPC /X PING.PAS  -> /bin/ping
}

Program Ping;

{$I-}

{$M 8192,0,0}

{$I NET.INC}

Type
 TTimeB=Record
  Time: Longint;
  Millitm: Word;
  Zone, Dst: Integer;
 End;

Var
 Fd,N,K,Code,Count,Size,Sent,Recvd,Id,Seq,Hl,Tries: Integer;
 Dst,From: Longint;
 Port: Word;
 Host: String;
 Pkt: Array[0..1535] Of Byte;
 Buf: Array[0..1535] Of Byte;
 Stop: Boolean;
 TMin,TMax,TSum,T: Longint;

Procedure OnInt(Sig: Integer); Far;
Begin
 Stop:=True;
End;

Function NowMs: Longint;
Var TB: TTimeB;
Begin
 SAX:=35; SBX:=0; SCX:=0; SDX:=Ofs(TB); SDS:=Seg(TB); SES:=DSeg; SDI:=0;
 DoSys;
 NowMs:=(TB.Time Mod 100000)*1000+TB.Millitm;
End;

Function Cksum(Var B; Len: Integer): Word;
Var S: Longint; I: Integer;
Begin
 S:=0; I:=0;
 While I+1<Len Do Begin
  S:=S+MemW[Seg(B):Ofs(B)+I]; Inc(I,2);
 End;
 If I<Len Then S:=S+Mem[Seg(B):Ofs(B)+I];
 While S Shr 16<>0 Do S:=(S And $FFFF)+(S Shr 16);
 Cksum:=Not Word(S);
End;

Procedure Usage;
Begin
 WriteLn('Syntaxe : ping [-c nombre] [-s taille] hote');
 Halt(2);
End;

Procedure SendOne;
Var L: Longint;
Begin
 FillChar(Pkt,8+Size,0);
 Pkt[0]:=8;                         { demande d'echo }
 Pkt[4]:=Hi(Id); Pkt[5]:=Lo(Id);
 Pkt[6]:=Hi(Seq); Pkt[7]:=Lo(Seq);
 L:=NowMs;
 If Size>=4 Then Move(L,Pkt[8],4);
 For K:=12 To 8+Size-1 Do Pkt[K]:=K And $FF;
 MemW[Seg(Pkt):Ofs(Pkt)+2]:=Cksum(Pkt,8+Size);
 If SendTo(Fd,Pkt,8+Size,Dst,0)<0 Then
  WriteLn('ping : envoi : ',NetErrorText(Errno))
 Else Inc(Sent);
 Inc(Seq); Inc(Tries);
End;

Procedure Receive;
{ reponses jusqu'a la fin de la seconde (SIGALRM) }
Var L: Longint; S: Integer;
Begin
 Repeat
  N:=RecvFrom(Fd,Buf,SizeOf(Buf),From,Port);
  If N<0 Then Exit;
  Hl:=(Buf[0] And 15)*4;
  If (N<Hl+8) Or (Buf[Hl]<>0) Then Continue;          { echo reply }
  If (Buf[Hl+4]*256+Buf[Hl+5])<>Id Then Continue;
  S:=Buf[Hl+6]*256+Buf[Hl+7];
  Inc(Recvd);
  Write(N-Hl,' octets de ',InetNtoA(From),' : icmp_seq=',S,' ttl=',Buf[8]);
  If N-Hl>=12 Then Begin
   Move(Buf[Hl+8],L,4);
   T:=NowMs-L; If T<0 Then T:=0;
   If (Recvd=1) Or (T<TMin) Then TMin:=T;
   If T>TMax Then TMax:=T;
   TSum:=TSum+T;
   Write(' temps=',T,' ms');
  End;
  WriteLn;
 Until False;
End;

BEGIN
 Count:=-1; Size:=56; Host:='';
 K:=1;
 While K<ArgCount Do Begin
  If (ArgStr(K)='-c') And (K+1<ArgCount) Then Begin
   Inc(K); Val(ArgStr(K),Count,Code); If (Code<>0) Or (Count<1) Then Usage;
  End Else If (ArgStr(K)='-s') And (K+1<ArgCount) Then Begin
   Inc(K); Val(ArgStr(K),Size,Code); If (Code<>0) Or (Size<0) Or (Size>1400) Then Usage;
  End Else If Host='' Then Host:=ArgStr(K)
  Else Usage;
  Inc(K);
 End;
 If Host='' Then Usage;
 If Not Resolve(Host,Dst) Then Begin
  WriteLn('ping : hote inconnu : ',Host); Halt(1);
 End;
 Fd:=Socket(AF_INET,SOCK_RAW,IPPROTO_ICMP);
 If Fd<0 Then Begin WriteLn('ping : socket : ',NetErrorText(Errno)); Halt(1) End;
 { le socket brut n'est plus utile au-dela : droits ordinaires }
 SetUid(GetUid);
 Id:=GetPid; Seq:=1; Sent:=0; Recvd:=0; TMin:=0; TMax:=0; TSum:=0; Tries:=0;
 Stop:=False;
 SysSignal(SIGINT,@OnInt);
 SysSignal(SIGALRM,@NetAlarm);
 WriteLn('PING ',Host,' (',InetNtoA(Dst),') : ',Size,' octets de donnees');
 While Not Stop Do Begin
  SendOne;
  SysAlarm(1);
  Receive;
  SysAlarm(0);
  SysSignal(SIGALRM,@NetAlarm);
  If (Count>0) And (Tries>=Count) Then Stop:=True;
 End;
 WriteLn;
 WriteLn('--- statistiques de ping vers ',Host,' ---');
 Write(Sent,' paquets envoyes, ',Recvd,' recus');
 If Sent>0 Then Write(', ',(Longint(Sent-Recvd)*100) Div Sent,' % de perte');
 WriteLn;
 If Recvd>0 Then
  WriteLn('temps min/moy/max = ',TMin,'/',TSum Div Recvd,'/',TMax,' ms');
 If Recvd=0 Then Halt(1);
END.
