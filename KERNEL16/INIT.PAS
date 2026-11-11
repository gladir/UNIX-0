{ @author: Sylvain Maltais (support@gladir.com)
  @created: 2026
  @website(https://www.gladir.com/unix-0)
  @abstract(Target: Unix Pascal (UPC /X))
  @description: Processus init (pid 1) de UNIX-0 : lance l'interpreteur de
   commandes sur la console et le relance s'il se termine; recupere les
   processus orphelins (zombies).
   Compilation : UPC /X INIT.PAS  -> /etc/init
}

Program Init;

{$M 4096,0,0}

Var
 Pid,W,St,Tries:Integer;
 Shell:String;

Function Exists(S:String):Boolean;
Var St:TStat;
Begin
 Exists:=SysStat(S,St)=0;
End;

BEGIN
 WriteLn('init : demarrage de UNIX-0');
 Tries:=0;
 Repeat
  If Exists('/bin/sh')Then Shell:='/bin/sh' Else Shell:='/bin/bash';
  Pid:=VFork;
  If Pid=0 Then Begin
   Execv(Shell,'');
   WriteLn('init : impossible de lancer ',Shell,' : ',SysErrorText(Errno));
   SysExit(127);
  End;
  If Pid<0 Then Begin
   WriteLn('init : fork impossible : ',SysErrorText(Errno));
   SysSleep(5);
  End Else Begin
   Repeat
    W:=WaitPid(-1,St,0);
   Until (W=Pid)Or(W<0);
   If St=127 Then Begin
    Inc(Tries);
    If Tries>3 Then Begin
     WriteLn('init : aucun interpreteur de commandes, arret.');
     Repeat SysSleep(60) Until False;
    End;
   End;
   WriteLn;
   WriteLn('init : l''interpreteur s''est termine, nouvelle session.');
  End;
 Until False;
END.
