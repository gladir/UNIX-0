{ @author: Sylvain Maltais (support@gladir.com)
  @created: 2026
  @website(https://www.gladir.com/unix-0)
  @abstract(Target: Unix Pascal (UPC /X))
  @description: Client TELNET (RFC 854) de UNIX-0 :
     telnet hote [port]           (port 23 par defaut)
   Negociation des options (RFC 855) : le client accepte ECHO et SUPPRESS
   GO AHEAD du serveur (passage en mode caractere, sans echo local) et
   refuse les autres. Sans ECHO du serveur, les lignes sont tapees en mode
   ligne avec l'echo du terminal et envoyees terminees par CR LF.
   ^] donne l'invite "telnet>" : quit (ou q) ferme la connexion, Entree
   reprend la session.
   Compilation : UPC /X TELNET.PAS  -> /bin/telnet
}

Program Telnet;

{$I-}

{$M 8192,0,0}

{$I NET.INC}

Const
 IAC=255; DONT=254; DO_=253; WONT=252; WILL=251; SB=250; SE=240;
 OPT_ECHO=1; OPT_SGA=3;
 ESCAPE=#29;                  { ^] }

Var
 S,R,K,Code: Integer;
 Host: String;
 PortN: Integer;
 A: Longint;
 Buf: Array[0..511] Of Byte;
 Out: Array[0..1023] Of Byte;
 NOut: Integer;
 Old,Cur: TSgttyb;
 Tty,CharMode,Done: Boolean;
 One: Word;
 State,Verb: Byte;

Procedure SendBytes(Var B; L: Integer);
Var D,X: Integer;
Begin
 D:=0;
 While D<L Do Begin
  X:=Send(S,Mem[Seg(B):Ofs(B)+D],L-D);
  If X<0 Then Begin
   If Errno=EWOULDBLOCK Then Begin SysNap(20); Continue End;
   Done:=True; Exit;
  End;
  Inc(D,X);
 End;
End;

Procedure Reply(V, Opt: Byte);
Var B: Array[0..2] Of Byte;
Begin
 B[0]:=IAC; B[1]:=V; B[2]:=Opt;
 SendBytes(B,3);
End;

Procedure SetMode(Chars: Boolean);
Begin
 If Not Tty Then Exit;
 CharMode:=Chars;
 Cur:=Old;
 If Chars Then Cur.Flags:=(Old.Flags Or RAW) And Not ECHO
 Else Cur.Flags:=Old.Flags;
 STty(0,Cur);
End;

Procedure Negotiate(V, Opt: Byte);
{ le serveur propose (WILL) ou demande (DO) une option }
Begin
 Case V Of
  WILL: If (Opt=OPT_ECHO) Or (Opt=OPT_SGA) Then Begin
         Reply(DO_,Opt);
         If Opt=OPT_ECHO Then SetMode(True);
        End Else Reply(DONT,Opt);
  WONT: Begin
         Reply(DONT,Opt);
         If Opt=OPT_ECHO Then SetMode(False);
        End;
  DO_: If Opt=OPT_SGA Then Reply(WILL,Opt) Else Reply(WONT,Opt);
  DONT: Reply(WONT,Opt);
 End;
End;

Procedure FromNet(L: Integer);
{ donnees du serveur : commandes TELNET retirees, le reste a l'ecran }
Var I: Integer; C: Byte;
Begin
 NOut:=0;
 For I:=0 To L-1 Do Begin
  C:=Buf[I];
  Case State Of
   0: If C=IAC Then State:=1
      Else Begin Out[NOut]:=C; Inc(NOut) End;
   1: Case C Of
       IAC: Begin Out[NOut]:=C; Inc(NOut); State:=0 End;
       WILL,WONT,DO_,DONT: Begin Verb:=C; State:=2 End;
       SB: State:=3;
       Else State:=0;
      End;
   2: Begin Negotiate(Verb,C); State:=0 End;
   3: If C=IAC Then State:=4;          { sous-negociation ignoree }
   4: If C=SE Then State:=0 Else State:=3;
  End;
 End;
 If NOut>0 Then SysWrite(1,Out,NOut);
End;

Function Command: Boolean;
{ ^] : invite locale; Faux pour quitter }
Var L: String;
Begin
 SysIoctl(0,TIOCSETP,Old);
 Write(#13#10'telnet> ');
 ReadLn(L);
 Command:=Not ((L='quit') Or (L='q') Or (L='close'));
 SetMode(CharMode);
End;

Procedure FromKeyboard;
Var N,I: Integer; C: Char; L: Array[0..255] Of Byte; Q: Integer;
Begin
 One:=0;
 SysIoctl(0,FIONREAD,One);
 If One=0 Then Exit;
 If One>255 Then One:=255;
 N:=SysRead(0,Buf,One);
 If N<=0 Then Begin Done:=True; Exit End;
 Q:=0;
 For I:=0 To N-1 Do Begin
  C:=Chr(Buf[I]);
  If C=ESCAPE Then Begin
   If Q>0 Then SendBytes(L,Q);
   Q:=0;
   If Not Command Then Begin Done:=True; Exit End;
   Continue;
  End;
  If C=#10 Then Begin                  { fin de ligne : CR LF }
   L[Q]:=13; L[Q+1]:=10; Inc(Q,2);
  End Else If (C=#13) And CharMode Then Begin
   L[Q]:=13; L[Q+1]:=0; Inc(Q,2);
  End Else If C=Chr(IAC) Then Begin
   L[Q]:=IAC; L[Q+1]:=IAC; Inc(Q,2);
  End Else Begin L[Q]:=Ord(C); Inc(Q) End;
  If Q>250 Then Begin SendBytes(L,Q); Q:=0 End;
 End;
 If Q>0 Then SendBytes(L,Q);
End;

BEGIN
 If ArgCount<2 Then Begin WriteLn('Syntaxe : telnet hote [port]'); Halt(2) End;
 Host:=ArgStr(1); PortN:=23;
 If ArgCount>2 Then Begin
  Val(ArgStr(2),PortN,Code);
  If (Code<>0) Or (PortN<=0) Then Begin WriteLn('telnet : port invalide'); Halt(2) End;
 End;
 If Not Resolve(Host,A) Then Begin WriteLn('telnet : hote inconnu : ',Host); Halt(1) End;
 WriteLn('Essai de ',InetNtoA(A),'...');
 S:=Socket(AF_INET,SOCK_STREAM,0);
 If S<0 Then Begin WriteLn('telnet : socket : ',NetErrorText(Errno)); Halt(1) End;
 If Connect(S,A,PortN)<0 Then Begin
  WriteLn('telnet : ',Host,' : ',NetErrorText(Errno)); Halt(1);
 End;
 WriteLn('Connecte a ',Host,'.');
 WriteLn('Le caractere d''echappement est ''^]''.');
 Tty:=GTty(0,Old)=0;
 CharMode:=False;
 One:=1; SysIoctl(S,FIONBIO,One);
 Done:=False; State:=0;
 Repeat
  R:=Recv(S,Buf,SizeOf(Buf));
  If R>0 Then FromNet(R)
  Else If (R=0) Or (Errno<>EWOULDBLOCK) Then Done:=True
  Else Begin
   FromKeyboard;
   If Not Done Then SysNap(30);
  End;
 Until Done;
 If Tty Then STty(0,Old);
 SysClose(S);
 WriteLn;
 WriteLn('Connexion fermee.');
END.
