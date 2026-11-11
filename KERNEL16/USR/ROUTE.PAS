{ @author: Sylvain Maltais (support@gladir.com)
  @created: 2026
  @website(https://www.gladir.com/unix-0)
  @abstract(Target: Unix Pascal (UPC /X))
  @description: Table de routage de UNIX-0, comme route de 4.2BSD :
     route                                  affiche la table
     route add default 10.0.2.2             route par defaut
     route add 192.168.1.0 10.0.2.9 -netmask 255.255.255.0
     route add -host 10.1.1.1 10.0.2.9
     route add 10.9.0.0 -netmask 255.255.0.0 -interface ne0
     route delete default | destination [-netmask masque]
   Sans -netmask, le masque est celui de la classe de l'adresse (A, B, C).
   Compilation : UPC /X ROUTE.PAS  -> /bin/route
}

Program Route;

{$I-}

{$M 8192,0,0}

{$I NET.INC}

Var
 RT: TRtEntry;
 Cmd,W: String;
 K,I: Integer;
 Dst,Mask,Gw: Longint;
 HostR,HaveMask: Boolean;
 IfN: String;

Procedure Usage;
Begin
 WriteLn('Syntaxe : route [add | delete] [-host] destination [passerelle]');
 WriteLn('              [-netmask masque] [-interface nom]');
 Halt(2);
End;

Procedure Fail(S: String);
Begin
 WriteLn('route : ',S);
 Halt(1);
End;

Function ClassMask(A: Longint): Longint;
Var B: Byte;
Begin
 B:=A And $FF;
 If A=0 Then ClassMask:=0
 Else If B<128 Then ClassMask:=$000000FF
 Else If B<192 Then ClassMask:=$0000FFFF
 Else ClassMask:=$00FFFFFF;
End;

Function Addr(S: String): Longint;
Var A: Longint;
Begin
 If S='default' Then A:=0
 Else If Not Resolve(S,A) Then Fail('adresse inconnue : '+S);
 Addr:=A;
End;

Procedure Show;
Var D,G: String; F: String;
Begin
 WriteLn('Destination        Passerelle         Masque             Drapeaux Interface');
 For I:=0 To 15 Do Begin
  FillChar(RT,SizeOf(RT),0); RT.Index:=I;
  If NetCtl(SIOCGRTENTRY,RT)<>0 Then Break;
  If RT.Flags=0 Then Continue;
  If (RT.Dst=0) And (RT.Mask=0) Then D:='default' Else D:=InetNtoA(RT.Dst);
  If RT.Flags And RTF_GATEWAY<>0 Then G:=InetNtoA(RT.Gw) Else G:='lien';
  F:='U';
  If RT.Flags And RTF_GATEWAY<>0 Then F:=F+'G';
  If RT.Flags And RTF_HOST<>0 Then F:=F+'H';
  While Length(D)<19 Do D:=D+' ';
  While Length(G)<19 Do G:=G+' ';
  W:=InetNtoA(RT.Mask);
  While Length(W)<19 Do W:=W+' ';
  While Length(F)<9 Do F:=F+' ';
  WriteLn(D,G,W,F,CStr(RT.IfName,8));
 End;
End;

BEGIN
 If ArgCount<2 Then Begin Show; Halt(0) End;
 Cmd:=ArgStr(1);
 If (Cmd<>'add') And (Cmd<>'delete') And (Cmd<>'del') Then Usage;
 HostR:=False; HaveMask:=False; Dst:=-2; Gw:=0; Mask:=0; IfN:='';
 K:=2;
 While K<ArgCount Do Begin
  W:=ArgStr(K);
  If W='-host' Then HostR:=True
  Else If W='-net' Then
  Else If (W='-netmask') And (K+1<ArgCount) Then Begin
   Inc(K); If Not InetAddr(ArgStr(K),Mask) Then Fail('masque invalide : '+ArgStr(K));
   HaveMask:=True;
  End Else If (W='-interface') And (K+1<ArgCount) Then Begin Inc(K); IfN:=ArgStr(K) End
  Else If Dst=-2 Then Dst:=Addr(W)
  Else Gw:=Addr(W);
  Inc(K);
 End;
 If Dst=-2 Then Usage;
 If HostR Then Mask:=-1
 Else If Not HaveMask Then Mask:=ClassMask(Dst);
 FillChar(RT,SizeOf(RT),0);
 RT.Dst:=Dst And Mask; RT.Mask:=Mask; RT.Gw:=Gw;
 PutCStr(RT.IfName,8,IfN);
 If Cmd='add' Then Begin
  If (Gw=0) And (IfN='') Then Fail('passerelle ou interface requise');
  If NetCtl(SIOCADDRT,RT)<>0 Then Fail(NetErrorText(Errno));
 End Else If NetCtl(SIOCDELRT,RT)<>0 Then Fail('route inexistante');
END.
