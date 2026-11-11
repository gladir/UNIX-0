{ @author: Sylvain Maltais (support@gladir.com)
  @created: 2026
  @website(https://www.gladir.com/unix-0)
  @abstract(Target: Unix Pascal (UPC /X))
  @description: Affiche ou change le nom de la machine (gethostname et
   sethostname de 4.2BSD; aussi le champ nodename de uname) :
     hostname           affiche le nom
     hostname nom       le change (super-utilisateur)
   Au demarrage, /etc/rc le prend dans /etc/myname.
   Compilation : UPC /X HOSTNAME.PAS  -> /bin/hostname
}

Program HostName;

{$I-}

{$M 4096,0,0}

Var S: String;

BEGIN
 If ArgCount<2 Then Begin
  S:='';
  SAX:=87; SBX:=0; SCX:=0; SDX:=Ofs(S); SSI:=0; SDI:=0; SDS:=Seg(S); SES:=DSeg;
  DoSys;
  WriteLn(S);
 End Else Begin
  S:=ArgStr(1);
  If Length(S)>31 Then S[0]:=#31;
  SAX:=88; SBX:=0; SCX:=0; SDX:=Ofs(S); SSI:=0; SDI:=0; SDS:=Seg(S); SES:=DSeg;
  DoSys;
  If Not SysOk Then Begin
   WriteLn('hostname : ',SysErrorText(Errno)); Halt(1);
  End;
 End;
END.
