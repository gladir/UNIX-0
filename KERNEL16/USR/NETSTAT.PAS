{ @author: Sylvain Maltais (support@gladir.com)
  @created: 2026
  @website(https://www.gladir.com/unix-0)
  @abstract(Target: Unix Pascal (UPC /X))
  @description: Etat du reseau de UNIX-0, comme netstat de 4.2BSD :
     netstat        sockets (TCP, UDP et bruts) et leur etat
     netstat -r     table de routage
     netstat -i     interfaces et compteurs
     netstat -s     statistiques des protocoles
   Compilation : UPC /X NETSTAT.PAS  -> /bin/netstat
}

Program NetStat;

{$I-}

{$M 8192,0,0}

{$I NET.INC}

Var
 Opt: String;
 I: Integer;
 SI: TSockInfo;
 RT: TRtEntry;
 F: TIfInfo;
 NS: TNetStat;

Function Pad(S: String; N: Integer): String;
Begin
 While Length(S)<N Do S:=S+' ';
 Pad:=S;
End;

Function LPad(S: String; N: Integer): String;
Begin
 While Length(S)<N Do S:=' '+S;
 LPad:=S;
End;

Function AddrPort(A: Longint; P: Word): String;
Var S: String;
Begin
 If A=0 Then S:='*' Else S:=InetNtoA(A);
 If P=0 Then AddrPort:=S+'.*' Else AddrPort:=S+'.'+IStr(P);
End;

Procedure Sockets;
Var Proto: String;
Begin
 WriteLn('Connexions Internet');
 WriteLn('Proto Recv-Q Send-Q  Adresse locale        Adresse distante      Etat');
 For I:=0 To 15 Do Begin
  FillChar(SI,SizeOf(SI),0); SI.Index:=I;
  If NetCtl(SIOCGSOCK,SI)<>0 Then Break;
  If SI.Used=0 Then Continue;
  { socket UDP non lie (celui de netstat lui-meme) }
  If (SI.Typ=SOCK_DGRAM) And (SI.LPort=0) And (SI.FAddr=0) Then Continue;
  Case SI.Typ Of
   SOCK_STREAM: Proto:='tcp';
   SOCK_DGRAM: Proto:='udp';
   Else Proto:='raw';
  End;
  Write(Pad(Proto,6),LPad(IStr(SI.RcvCnt),6),LPad(IStr(SI.SndCnt),7),'  ',
    Pad(AddrPort(SI.LAddr,SI.LPort),22),Pad(AddrPort(SI.FAddr,SI.FPort),22));
  If SI.Typ=SOCK_STREAM Then Write(TCPStates[SI.State]);
  WriteLn;
 End;
End;

Procedure Routes;
Var D,G,Fl: String;
Begin
 WriteLn('Table de routage');
 WriteLn('Destination        Passerelle         Drapeaux  Interface');
 For I:=0 To 15 Do Begin
  FillChar(RT,SizeOf(RT),0); RT.Index:=I;
  If NetCtl(SIOCGRTENTRY,RT)<>0 Then Break;
  If RT.Flags=0 Then Continue;
  If (RT.Dst=0) And (RT.Mask=0) Then D:='default'
  Else D:=InetNtoA(RT.Dst)+'/'+IStr(MaskBits(RT.Mask));
  If RT.Flags And RTF_GATEWAY<>0 Then G:=InetNtoA(RT.Gw) Else G:='lien';
  Fl:='U';
  If RT.Flags And RTF_GATEWAY<>0 Then Fl:=Fl+'G';
  If RT.Flags And RTF_HOST<>0 Then Fl:=Fl+'H';
  WriteLn(Pad(D,19),Pad(G,19),Pad(Fl,10),CStr(RT.IfName,8));
 End;
End;

Procedure Interfaces;
Begin
 WriteLn('Nom   Mtu   Reseau           Adresse          Ipkts  Ierrs  Opkts  Oerrs');
 For I:=0 To 7 Do
  If IfInfo(I,F) Then Begin
   Write(Pad(CStr(F.Name,8),6),Pad(IStr(F.Mtu),6));
   If F.Addr<>0 Then Write(Pad(InetNtoA(F.Addr And F.Mask)+'/'+IStr(MaskBits(F.Mask)),17),
     Pad(InetNtoA(F.Addr),17))
   Else Write(Pad('-',17),Pad('-',17));
   WriteLn(LPad(IStr(F.IPackets),5),LPad(IStr(F.IErrors),7),LPad(IStr(F.OPackets),7),
     LPad(IStr(F.OErrors),7));
  End;
End;

Procedure Stats;
Begin
 If NetCtl(SIOCGNSTAT,NS)<>0 Then Begin
  WriteLn('netstat : ',NetErrorText(Errno)); Halt(1);
 End;
 With NS Do Begin
  WriteLn('ip :');
  WriteLn(#9,IpIn,' paquets recus, ',IpBad,' incorrects, ',IpFrag,' fragments ignores, ',
    IpNoProto,' protocoles inconnus');
  WriteLn(#9,IpOut,' paquets envoyes, ',IpNoRoute,' sans route');
  WriteLn('icmp :');
  WriteLn(#9,IcmpIn,' messages recus, ',IcmpOut,' envoyes');
  WriteLn('udp :');
  WriteLn(#9,UdpIn,' datagrammes recus, ',UdpNoPort,' sans destinataire, ',UdpOut,' envoyes');
  WriteLn('tcp :');
  WriteLn(#9,TcpIn,' segments recus, ',TcpBad,' incorrects, ',TcpOut,' envoyes, ',
    TcpRexmt,' retransmissions');
  WriteLn(#9,TcpConn,' connexions demandees, ',TcpAccept,' acceptees, ',TcpDrop,
    ' rompues, ',TcpRstOut,' RST envoyes');
  WriteLn('arp :');
  WriteLn(#9,ArpIn,' paquets recus, ',ArpOut,' envoyes');
 End;
End;

BEGIN
 Opt:='';
 If ArgCount>1 Then Opt:=ArgStr(1);
 If (Opt='') Or (Opt='-a') Or (Opt='-n') Then Sockets
 Else If Opt='-r' Then Routes
 Else If Opt='-i' Then Interfaces
 Else If Opt='-s' Then Stats
 Else Begin
  WriteLn('Syntaxe : netstat [-a | -r | -i | -s]'); Halt(2);
 End;
END.
