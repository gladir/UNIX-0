{ @author: Sylvain Maltais (support@gladir.com)
  @created: 2026
  @website(https://www.gladir.com/unix-0)
  @abstract(Target: Unix Pascal (UPC /X))
  @description: Cache ARP (adresses IP -> adresses Ethernet) de UNIX-0, comme
   arp de 4.2BSD :
     arp -a          toutes les entrees
     arp hote        l'entree d'un hote
     arp -d hote     supprime l'entree (super-utilisateur)
   Compilation : UPC /X ARP.PAS  -> /bin/arp
}

Program Arp;

{$I-}

{$M 8192,0,0}

{$I NET.INC}

Var
 E: TArpEnt;
 F: TIfInfo;
 I,N: Integer;
 A: Longint;
 Host: String;

Procedure Show(Only: Longint);
Var S: String;
Begin
 N:=0;
 For I:=0 To 31 Do Begin
  FillChar(E,SizeOf(E),0); E.Index:=I;
  If NetCtl(SIOCGARPENT,E)<>0 Then Break;
  If (E.State=0) Or ((Only<>0) And (E.Ip<>Only)) Then Continue;
  Inc(N);
  Write(InetNtoA(E.Ip),' a ');
  If E.State=2 Then Write(MacText(E.Mac)) Else Write('(incomplet)');
  If IfInfo(E.IfIdx,F) Then Write(' sur ',CStr(F.Name,8));
  WriteLn(' (',E.Age,' s)');
 End;
 If (N=0) And (Only<>0) Then Begin
  WriteLn(InetNtoA(Only),' : pas d''entree'); Halt(1);
 End;
End;

Procedure Usage;
Begin
 WriteLn('Syntaxe : arp -a | arp hote | arp -d hote');
 Halt(2);
End;

BEGIN
 If ArgCount<2 Then Usage;
 If ArgStr(1)='-a' Then Show(0)
 Else If ArgStr(1)='-d' Then Begin
  If ArgCount<3 Then Usage;
  Host:=ArgStr(2);
  If Not Resolve(Host,A) Then Begin WriteLn('arp : hote inconnu : ',Host); Halt(1) End;
  FillChar(E,SizeOf(E),0); E.Ip:=A;
  If NetCtl(SIOCDARP,E)<>0 Then Begin
   WriteLn('arp : ',Host,' : ',NetErrorText(Errno)); Halt(1);
  End;
 End Else Begin
  Host:=ArgStr(1);
  If Not Resolve(Host,A) Then Begin WriteLn('arp : hote inconnu : ',Host); Halt(1) End;
  Show(A);
 End;
END.
