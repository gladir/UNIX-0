{ @author: Sylvain Maltais (support@gladir.com)
  @created: 2026
  @website(https://www.gladir.com/unix-0)
  @abstract(Target: Unix Pascal (UPC /X))
  @description: Client DHCP (RFC 2131 et 2132) de UNIX-0 : obtient l'adresse
   d'une interface, son masque, la passerelle et le serveur de noms :
     dhclient [interface]            (par defaut la premiere carte)
   Echanges DHCPDISCOVER, DHCPOFFER, DHCPREQUEST, DHCPACK par diffusion
   (port 68 -> 67), quatre essais de 3 secondes; puis l'interface est
   configuree (ifconfig), la route par defaut ajoutee (route add default)
   et /etc/resolv.conf ecrit. Le bail n'est pas renouvele : la commande
   est relancee a chaque demarrage par /etc/rc.
   Compilation : UPC /X DHCLIENT.PAS  -> /bin/dhclient
}

Program DhClient;

{$I-}

{$M 8192,0,0}

{$I NET.INC}

Const
 BOOTREQUEST=1;
 DHCPDISCOVER=1; DHCPOFFER=2; DHCPREQUEST=3; DHCPACK=5; DHCPNAK=6;

Var
 F: TIfInfo;
 IfName: String;
 Fd,I,N,Try: Integer;
 Xid: Longint;
 Pkt: Array[0..575] Of Byte;
 Rep: Array[0..575] Of Byte;
 From,MyIp,Server,Mask,Router,Dns,Lease: Longint;
 Port: Word;
 Typ: Byte;
 RT: TRtEntry;
 T: Text;

Procedure Fail(S: String);
Begin
 WriteLn('dhclient : ',S);
 Halt(1);
End;

Function Build(MsgType: Byte): Integer;
{ message BOOTP/DHCP (RFC 2131) : en-tete fixe de 236 octets, cookie, options }
Var P: Integer;
Begin
 FillChar(Pkt,SizeOf(Pkt),0);
 Pkt[0]:=BOOTREQUEST; Pkt[1]:=1; Pkt[2]:=6;
 Move(Xid,Pkt[4],4);
 Pkt[10]:=$80;                          { reponse par diffusion }
 Move(F.Mac,Pkt[28],6);
 Pkt[236]:=99; Pkt[237]:=130; Pkt[238]:=83; Pkt[239]:=99;
 P:=240;
 Pkt[P]:=53; Pkt[P+1]:=1; Pkt[P+2]:=MsgType; Inc(P,3);
 Pkt[P]:=61; Pkt[P+1]:=7; Pkt[P+2]:=1; Move(F.Mac,Pkt[P+3],6); Inc(P,9);
 If MsgType=DHCPREQUEST Then Begin
  Pkt[P]:=50; Pkt[P+1]:=4; Move(MyIp,Pkt[P+2],4); Inc(P,6);
  Pkt[P]:=54; Pkt[P+1]:=4; Move(Server,Pkt[P+2],4); Inc(P,6);
 End;
 Pkt[P]:=55; Pkt[P+1]:=4; Pkt[P+2]:=1; Pkt[P+3]:=3; Pkt[P+4]:=6; Pkt[P+5]:=51;
 Inc(P,6);
 Pkt[P]:=255; Inc(P);
 If P<300 Then P:=300;
 Build:=P;
End;

Function Parse(Len: Integer): Byte;
{ reponse : type DHCP et options utiles }
Var P,L: Integer; Code: Byte;
Begin
 Parse:=0;
 If (Len<240) Or (Rep[0]<>2) Then Exit;
 If (Rep[4]<>Pkt[4]) Or (Rep[5]<>Pkt[5]) Or (Rep[6]<>Pkt[6]) Or (Rep[7]<>Pkt[7]) Then Exit;
 If (Rep[236]<>99) Or (Rep[237]<>130) Or (Rep[238]<>83) Or (Rep[239]<>99) Then Exit;
 Move(Rep[16],MyIp,4);
 P:=240;
 While P<Len Do Begin
  Code:=Rep[P];
  If Code=255 Then Break;
  If Code=0 Then Begin Inc(P); Continue End;
  L:=Rep[P+1];
  Case Code Of
   1: Move(Rep[P+2],Mask,4);
   3: Move(Rep[P+2],Router,4);
   6: Move(Rep[P+2],Dns,4);
   51: Lease:=(Longint(Rep[P+2]) Shl 24) Or (Longint(Rep[P+3]) Shl 16) Or
         (Longint(Rep[P+4]) Shl 8) Or Rep[P+5];
   53: Parse:=Rep[P+2];
   54: Move(Rep[P+2],Server,4);
  End;
  Inc(P,L+2);
 End;
End;

Function Exchange(MsgType, Want: Byte): Boolean;
{ envoie le message et attend la reponse voulue (DHCPNAK : echec) }
Var L: Integer; K: Byte;
Begin
 Exchange:=False;
 For Try:=1 To 4 Do Begin
  L:=Build(MsgType);
  If SendTo(Fd,Pkt,L,-1,67)<0 Then Fail('envoi : '+NetErrorText(Errno));
  NetTimedOut:=False;
  SysSignal(SIGALRM,@NetAlarm);
  SysAlarm(3);
  Repeat
   N:=RecvFrom(Fd,Rep,SizeOf(Rep),From,Port);
   If N>0 Then Begin
    K:=Parse(N);
    If K=DHCPNAK Then Begin SysAlarm(0); Fail('refus du serveur (DHCPNAK)') End;
    If K=Want Then Begin SysAlarm(0); Exchange:=True; Exit End;
   End;
  Until N<0;
  SysAlarm(0);
 End;
End;

BEGIN
 IfName:='';
 If ArgCount>1 Then IfName:=ArgStr(1);
 If IfName='' Then Begin
  For I:=0 To 7 Do
   If IfInfo(I,F) Then
    If (F.Drv<>DRV_LOOP) And (IfName='') Then IfName:=CStr(F.Name,8);
  If IfName='' Then Fail('aucune carte reseau');
 End;
 If Not IfByName(IfName,F) Then Fail(IfName+' : interface inexistante');
 { l'interface doit fonctionner, meme sans adresse }
 F.Flags:=F.Flags Or IFF_UP;
 If NetCtl(SIOCSIFFLAGS,F)<>0 Then Fail(IfName+' : '+NetErrorText(Errno));
 Fd:=Socket(AF_INET,SOCK_DGRAM,0);
 If Fd<0 Then Fail('socket : '+NetErrorText(Errno));
 SetSockOpt(Fd,SO_REUSEADDR,1);
 SetSockOpt(Fd,SO_BROADCAST,1);
 SetSockOpt(Fd,SO_IFINDEX,F.Index);
 If Bind(Fd,0,68)<0 Then Fail('port 68 : '+NetErrorText(Errno));
 Xid:=SysTime Xor (Longint(GetPid) Shl 16);
 Mask:=0; Router:=0; Dns:=0; Lease:=0; Server:=0; MyIp:=0;
 Write('dhclient : ',IfName,' : ');
 If Not Exchange(DHCPDISCOVER,DHCPOFFER) Then Begin
  WriteLn('pas de serveur DHCP'); Halt(1);
 End;
 If Not Exchange(DHCPREQUEST,DHCPACK) Then Begin
  WriteLn('pas d''acquittement (DHCPACK)'); Halt(1);
 End;
 SysClose(Fd);
 { configuration de l'interface, de la route par defaut, du DNS }
 F.Addr:=MyIp; F.Mask:=Mask;
 If NetCtl(SIOCSIFADDR,F)<>0 Then Fail('adresse : '+NetErrorText(Errno));
 Write(InetNtoA(MyIp));
 If Mask<>0 Then Write('/',MaskBits(Mask));
 If Router<>0 Then Begin
  FillChar(RT,SizeOf(RT),0);
  NetCtl(SIOCDELRT,RT);
  RT.Gw:=Router;
  If NetCtl(SIOCADDRT,RT)=0 Then Write(', passerelle ',InetNtoA(Router));
 End;
 If Dns<>0 Then Begin
  Assign(T,'/etc/resolv.conf'); Rewrite(T);
  If IOResult=0 Then Begin
   WriteLn(T,'nameserver ',InetNtoA(Dns));
   Close(T);
  End;
  Write(', DNS ',InetNtoA(Dns));
 End;
 If Lease<>0 Then Write(', bail de ',Lease,' s');
 WriteLn;
END.
