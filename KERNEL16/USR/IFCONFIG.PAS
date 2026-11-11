{ @author: Sylvain Maltais (support@gladir.com)
  @created: 2026
  @website(https://www.gladir.com/unix-0)
  @abstract(Target: Unix Pascal (UPC /X))
  @description: Configuration des interfaces reseau de UNIX-0, comme
   ifconfig de 4.2BSD :
     ifconfig                      toutes les interfaces
     ifconfig ne0                  une interface
     ifconfig ne0 10.0.2.15 [netmask 255.255.255.0] [up|down] [irq 3]
   L'adresse et le masque ajoutent la route du reseau de l'interface; "up"
   demarre la carte (et la boucle locale lo0 la premiere fois).
   Compilation : UPC /X IFCONFIG.PAS  -> /bin/ifconfig
}

Program IfConfig;

{$I-}

{$M 8192,0,0}

{$I NET.INC}

Var
 F: TIfInfo;
 I,K,E,Code: Integer;
 Name,W: String;
 A,M: Longint;
 SetA,Up,Down: Boolean;
 Irq: Integer;

Procedure Show(Var F: TIfInfo);
Var S: String;
Begin
 S:='';
 If F.Flags And IFF_UP<>0 Then S:=S+',UP';
 If F.Flags And IFF_BROADCAST<>0 Then S:=S+',BROADCAST';
 If F.Flags And IFF_LOOPBACK<>0 Then S:=S+',LOOPBACK';
 If F.Flags And IFF_RUNNING<>0 Then S:=S+',RUNNING';
 Delete(S,1,1);
 WriteLn(CStr(F.Name,8),': flags=',HexB(Hi(F.Flags)),HexB(Lo(F.Flags)),'<',S,'> mtu ',F.Mtu);
 If F.Addr<>0 Then Begin
  Write(#9'inet ',InetNtoA(F.Addr),' netmask ',InetNtoA(F.Mask));
  If F.Flags And IFF_BROADCAST<>0 Then Write(' broadcast ',InetNtoA(F.Bcast));
  WriteLn;
 End;
 If F.Drv<>DRV_LOOP Then WriteLn(#9'ether ',MacText(F.Mac));
 Write(#9,CStr(F.Model,24));
 If F.Drv=DRV_NE2000 Then Begin
  Write(', port ',HexB(Hi(F.IoBase)),HexB(Lo(F.IoBase)),'h');
  If F.Irq<>0 Then Write(', IRQ ',F.Irq) Else Write(', sans IRQ (scrutation)');
 End Else If F.Drv=DRV_PKT Then Write(', INT ',HexB(Lo(F.IoBase)),'h');
 WriteLn;
 WriteLn(#9'recus : ',F.IPackets,' paquets, ',F.IBytes,' octets, ',F.IErrors,
   ' erreurs; envoyes : ',F.OPackets,' paquets, ',F.OBytes,' octets, ',
   F.OErrors,' erreurs');
End;

Procedure Fail(S: String);
Begin
 WriteLn('ifconfig : ',S);
 Halt(1);
End;

BEGIN
 If ArgCount<2 Then Begin
  For I:=0 To 7 Do If IfInfo(I,F) Then Show(F);
  Halt(0);
 End;
 Name:=ArgStr(1);
 If Not IfByName(Name,F) Then Fail(Name+' : interface inexistante');
 If ArgCount=2 Then Begin Show(F); Halt(0) End;
 SetA:=False; Up:=False; Down:=False; Irq:=-1; A:=F.Addr; M:=0;
 K:=2;
 While K<ArgCount Do Begin
  W:=ArgStr(K);
  If W='up' Then Up:=True
  Else If W='down' Then Down:=True
  Else If (W='netmask') And (K+1<ArgCount) Then Begin
   Inc(K);
   If Not InetAddr(ArgStr(K),M) Then Fail('masque invalide : '+ArgStr(K));
   SetA:=True;
  End Else If (W='irq') And (K+1<ArgCount) Then Begin
   Inc(K); Val(ArgStr(K),Irq,Code);
   If (Code<>0) Or (Irq<2) Or (Irq>15) Then Fail('IRQ invalide : '+ArgStr(K));
  End Else If (W='inet') Then
  Else If InetAddr(W,A) Then SetA:=True
  Else Fail('argument inconnu : '+W);
  Inc(K);
 End;
 If Irq>=0 Then Begin
  F.Irq:=Irq;
  If NetCtl(SIOCSIFIRQ,F)<0 Then Fail('irq : '+NetErrorText(Errno));
 End;
 If SetA Then Begin
  If M=0 Then M:=F.Mask;
  F.Addr:=A; F.Mask:=M;
  If NetCtl(SIOCSIFADDR,F)<0 Then Fail(Name+' : '+NetErrorText(Errno));
  { une adresse demarre l'interface, comme sous BSD }
  If Not Down Then Up:=True;
 End;
 If Up Or Down Then Begin
  If Up Then F.Flags:=F.Flags Or IFF_UP Else F.Flags:=F.Flags And Not IFF_UP;
  If NetCtl(SIOCSIFFLAGS,F)<0 Then Fail(Name+' : '+NetErrorText(Errno));
 End;
END.
