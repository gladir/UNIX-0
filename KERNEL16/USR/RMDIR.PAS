{ @author: Sylvain Maltais (support@gladir.com)
  @created: 2026
  @website(https://www.gladir.com/unix-0)
  @abstract(Target: Unix Pascal (UPC /X))
  @description: rmdir de UNIX-0 : supprime des repertoires vides.
   Usage : rmdir repertoire...
}

Program RmDir_;

Var
 I,R:Integer;

BEGIN
 R:=0;
 If ArgCount<2 Then Begin WriteLn('usage : rmdir repertoire...'); Halt(2) End;
 For I:=1 To ArgCount-1 Do
  If SysRmdir(ArgStr(I))<0 Then Begin
   WriteLn('rmdir : ',ArgStr(I),' : ',SysErrorText(Errno)); R:=1;
  End;
 Halt(R);
END.
