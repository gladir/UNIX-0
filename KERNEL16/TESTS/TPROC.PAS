{ @author: Sylvain Maltais (support@gladir.com)
  @created: 2026
  @website(https://www.gladir.com/unix-0)
  @abstract(Target: Unix Pascal (UPC /X))
  @description: Test des processus de UNIX-0 : fork (copie de la memoire),
   ordonnanceur preemptif (3 fils en calcul), tubes, kill, exec, codes de
   sortie de waitpid.
   Lance comme /etc/init par TESTS/RUNTESTS.SH; affiche TERMINE a la fin.
}

Program TPROC;
Var P:Array[1..3] of Integer; I,J,St,W,R,Wf,Pid:Integer; X:Longint; V:Integer; Buf:Array[0..63] of Char; S:String;
Begin
 WriteLn('== fork : copie de la memoire');
 V:=10;
 Pid:=Fork;
 If Pid=0 Then Begin V:=99; WriteLn('fils pid=',GetPid,' ppid=',GetPPid,' V=',V); SysExit(7) End;
 W:=WaitPid(Pid,St,0); WriteLn('pere V=',V,' fils ',W,' etat ',St);
 WriteLn('== ordonnanceur : 3 fils en calcul');
 For I:=1 To 3 Do Begin
  P[I]:=Fork;
  If P[I]=0 Then Begin
   For J:=1 To 4 Do Begin
    X:=0; While X<8000000 Do Inc(X);
    WriteLn('  fils ',I,' tour ',J);
   End;
   SysExit(I);
  End;
 End;
 For I:=1 To 3 Do Begin W:=WaitPid(-1,St,0); WriteLn('termine ',W,' code ',St) End;
 WriteLn('== tube');
 SysPipe(R,Wf);
 Pid:=Fork;
 If Pid=0 Then Begin
  SysClose(R); S:='message par le tube'; SysWrite(Wf,S[1],Length(S)); SysClose(Wf); SysExit(0);
 End;
 SysClose(Wf);
 J:=SysRead(R,Buf,63); Buf[J]:=#0; Write('lu ',J,' : '); For I:=0 To J-1 Do Write(Buf[I]); WriteLn;
 J:=SysRead(R,Buf,63); WriteLn('fin de tube : ',J);
 SysClose(R); WaitPid(Pid,St,0);
 WriteLn('== kill');
 Pid:=Fork;
 If Pid=0 Then Begin Repeat X:=X+1 Until False End;
 SysSleep(1);
 WriteLn('kill -> ',SysKill(Pid,SIGTERM));
 W:=WaitPid(Pid,St,0); WriteLn('tue ',W,' signal ',Hi(St));
 WriteLn('== exec');
 Pid:=Fork;
 If Pid=0 Then Begin Execv('/bin/echo','bonjour depuis echo'); SysExit(127) End;
 WaitPid(Pid,St,0); WriteLn('echo etat ',St);
 WriteLn('TERMINE');
 Repeat SysSleep(100) Until False;
End.
