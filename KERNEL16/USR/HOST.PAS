{ @author: Sylvain Maltais (support@gladir.com)
  @created: 2026
  @website(https://www.gladir.com/unix-0)
  @abstract(Target: Unix Pascal (UPC /X))
  @description: Adresse IP d'un hote : /etc/hosts, puis le serveur DNS de
   /etc/resolv.conf (requete de type A), comme host de BIND :
     host nom [...]
   Compilation : UPC /X HOST.PAS  -> /bin/host
}

Program Host;

{$I-}

{$M 8192,0,0}

{$I NET.INC}

Var
 I,Bad: Integer;
 A: Longint;

BEGIN
 If ArgCount<2 Then Begin WriteLn('Syntaxe : host nom [...]'); Halt(2) End;
 Bad:=0;
 For I:=1 To ArgCount-1 Do
  If Resolve(ArgStr(I),A) Then WriteLn(ArgStr(I),' a l''adresse ',InetNtoA(A))
  Else Begin WriteLn('host : ',ArgStr(I),' : hote inconnu'); Bad:=1 End;
 Halt(Bad);
END.
