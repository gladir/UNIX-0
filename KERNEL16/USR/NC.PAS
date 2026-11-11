{ @author: Sylvain Maltais (support@gladir.com)
  @created: 2026
  @website(https://www.gladir.com/unix-0)
  @abstract(Target: Unix Pascal (UPC /X))
  @description: Relie l'entree et la sortie standard a une connexion TCP (ou
   a des datagrammes UDP), comme netcat :
     nc [-u] [-w secondes] hote port      client
     nc -l [-u] port [-e programme]       serveur : attend une connexion
     nc -z hote port                      teste seulement la connexion
   Sur un terminal, le clavier et le socket sont surveilles ensemble
   (FIONREAD, socket non bloquant); sinon l'entree standard est envoyee
   jusqu'a sa fin, la connexion est fermee dans ce sens (shutdown) puis la
   reponse est lue jusqu'au bout. Avec -e, le programme est lance sur la
   connexion acceptee (entree, sorties standard et erreurs).
   Compilation : UPC /X NC.PAS  -> /bin/nc
}

Program NetCat;

{$I-}

{$M 8192,0,0}

{$I NET.INC}

Var
 Fd,S,N,K,Code: Integer;
 Listen_,Udp,Scan: Boolean;
 Host,Prog: String;
 PortS,Wait: Integer;
 A,From: Longint;
 P,FPort: Word;
 Buf: Array[0..1023] Of Byte;
 Out: Array[0..1023] Of Byte;
 One: Word;
 TtyIn: Boolean;

Procedure Usage;
Begin
 WriteLn('Syntaxe : nc [-u] [-w secondes] hote port');
 WriteLn('          nc -l [-u] port [-e programme]');
 WriteLn('          nc -z hote port');
 Halt(2);
End;

Procedure Fail(S: String);
Begin
 WriteLn('nc : ',S,' : ',NetErrorText(Errno));
 Halt(1);
End;

Function Avail(F: Integer): Integer;
Var W: Word;
Begin
 W:=0;
 If SysIoctl(F,FIONREAD,W)<0 Then Avail:=-1 Else Avail:=W;
End;

Procedure WriteAll(F: Integer; Var B; L: Integer);
Var D,R: Integer;
Begin
 D:=0;
 While D<L Do Begin
  R:=SysWrite(F,Mem[Seg(B):Ofs(B)+D],L-D);
  If R<=0 Then Halt(1);
  Inc(D,R);
 End;
End;


Function DrainSocket: Boolean;
{ donnees du socket non bloquant vers la sortie; Faux a la fin }
Var R: Integer;
Begin
 DrainSocket:=True;
 Repeat
  If Udp Then R:=RecvFrom(S,Buf,SizeOf(Buf),From,FPort)
  Else R:=Recv(S,Buf,SizeOf(Buf));
  If R>0 Then WriteAll(1,Buf,R)
  Else If R=0 Then Begin DrainSocket:=Udp; Exit End
  Else Begin
   If Errno<>EWOULDBLOCK Then DrainSocket:=False;
   Exit;
  End;
 Until False;
End;

Procedure SendAll(L: Integer);
{ socket non bloquant : tampon d'emission plein -> la reponse est lue en
  attendant (le correspondant peut attendre qu'on le lise) }
Var D,R: Integer;
Begin
 D:=0;
 While D<L Do Begin
  If Udp And Listen_ Then R:=SendTo(S,Out[D],L-D,From,FPort)
  Else R:=Send(S,Out[D],L-D);
  If R<0 Then Begin
   If Errno<>EWOULDBLOCK Then Fail('envoi');
   If Not DrainSocket Then Halt(0);
   SysNap(20);
   Continue;
  End;
  Inc(D,R);
 End;
End;

Procedure Relay;
Var R: Integer; Eof_: Boolean;
Begin
 TtyIn:=IsATty(0);
 { terminal : socket non bloquant, clavier et socket surveilles tour a
   tour; sinon socket bloquant (l'emission attend les acquittements dans
   le noyau) et la reponse deja arrivee est lue au passage (FIONREAD) }
 One:=Ord(TtyIn);
 SysIoctl(S,FIONBIO,One);
 Eof_:=False;
 If TtyIn Then Begin
  { terminal : clavier et socket surveilles tour a tour }
  Repeat
   If Not DrainSocket Then Exit;
   R:=Avail(0);
   If R>0 Then Begin
    If R>SizeOf(Out) Then R:=SizeOf(Out);
    R:=SysRead(0,Out,R);
    If R<=0 Then Eof_:=True Else SendAll(R);
   End Else SysNap(50);
  Until Eof_;
 End Else Begin
  Repeat
   R:=SysRead(0,Out,SizeOf(Out));
   If R>0 Then SendAll(R);
   While Avail(S)>0 Do Begin
    If Udp Then K:=RecvFrom(S,Buf,SizeOf(Buf),From,FPort)
    Else K:=Recv(S,Buf,SizeOf(Buf));
    If K<=0 Then Exit;
    WriteAll(1,Buf,K);
   End;
  Until R<=0;
 End;
 If Not Udp Then Shutdown(S,1);
 { la suite de la reponse : socket bloquant }
 One:=0;
 SysIoctl(S,FIONBIO,One);
 If Udp And Not TtyIn Then Begin
  SysAlarm(Wait);
  SysSignal(SIGALRM,@NetAlarm);
 End;
 Repeat
  If Udp Then R:=RecvFrom(S,Buf,SizeOf(Buf),From,FPort)
  Else R:=Recv(S,Buf,SizeOf(Buf));
  If R>0 Then WriteAll(1,Buf,R);
 Until R<=0;
End;

BEGIN
 Listen_:=False; Udp:=False; Scan:=False; Prog:=''; Host:=''; PortS:=-1;
 Wait:=2;
 K:=1;
 While K<ArgCount Do Begin
  If ArgStr(K)='-l' Then Listen_:=True
  Else If ArgStr(K)='-u' Then Udp:=True
  Else If ArgStr(K)='-z' Then Scan:=True
  Else If (ArgStr(K)='-e') And (K+1<ArgCount) Then Begin Inc(K); Prog:=ArgStr(K) End
  Else If (ArgStr(K)='-w') And (K+1<ArgCount) Then Begin
   Inc(K); Val(ArgStr(K),Wait,Code); If Code<>0 Then Usage;
  End Else If (Host='') And Not Listen_ Then Host:=ArgStr(K)
  Else If PortS<0 Then Begin
   Val(ArgStr(K),PortS,Code); If (Code<>0) Or (PortS<=0) Then Usage;
  End Else Usage;
  Inc(K);
 End;
 If PortS<0 Then Usage;
 If Not Listen_ And (Host='') Then Usage;
 If Udp Then Fd:=Socket(AF_INET,SOCK_DGRAM,0)
 Else Fd:=Socket(AF_INET,SOCK_STREAM,0);
 If Fd<0 Then Fail('socket');
 If Listen_ Then Begin
  SetSockOpt(Fd,SO_REUSEADDR,1);
  If Bind(Fd,0,PortS)<0 Then Fail('bind');
  If Udp Then Begin
   { premier datagramme : son expediteur devient le correspondant }
   N:=RecvFrom(Fd,Buf,SizeOf(Buf),From,FPort);
   If N<0 Then Fail('reception');
   WriteAll(1,Buf,N);
   S:=Fd;
  End Else Begin
   If Listen(Fd,1)<0 Then Fail('listen');
   S:=Accept(Fd,From,FPort);
   If S<0 Then Fail('accept');
   SysClose(Fd);
  End;
  If Prog<>'' Then Begin
   SysDup2(S,0); SysDup2(S,1); SysDup2(S,2);
   If S>2 Then SysClose(S);
   ArgReset; ArgAdd(Prog);
   ArgExec(Prog);
   Halt(127);
  End;
 End Else Begin
  If Not Resolve(Host,A) Then Begin WriteLn('nc : hote inconnu : ',Host); Halt(1) End;
  S:=Fd;
  If Connect(S,A,PortS)<0 Then Begin
   If Scan Then Halt(1);
   Fail(Host+' port '+IStr(PortS));
  End;
  If Scan Then Begin
   WriteLn('Connexion a ',Host,' port ',PortS,' reussie');
   Halt(0);
  End;
 End;
 Relay;
 SysClose(S);
END.
