{ @author: Sylvain Maltais (support@gladir.com)
  @created: 2026
  @website(https://www.gladir.com/unix-0)
  @abstract(Target: Unix Pascal (UPC /X))
  @description: Telecharge un document par HTTP/1.0 (RFC 1945), comme fetch
   de FreeBSD :
     fetch [-o fichier] [-v] http://hote[:port]/chemin
   Le document est ecrit dans le fichier nomme d'apres la fin du chemin
   (index.html pour un repertoire), ou dans celui de -o ("-o -" : sortie
   standard). -v affiche aussi la ligne d'etat et les en-tetes de la
   reponse. Code de sortie 1 si l'etat n'est pas 2xx.
   Compilation : UPC /X FETCH.PAS  -> /bin/fetch
}

Program Fetch;

{$I-}

{$M 8192,0,0}

{$I NET.INC}

Var
 Url,Host,Path,OutName,Req,Line,Status: String;
 PortN,K,Code,S,Fd,N,P,HLen: Integer;
 A: Longint;
 Verbose,InHead: Boolean;
 Buf: Array[0..1023] Of Byte;
 Total: Longint;
 T0: Longint;
 St: Integer;

Procedure Fail(M: String);
Begin
 WriteLn('fetch : ',M);
 Halt(1);
End;

Procedure Usage;
Begin
 WriteLn('Syntaxe : fetch [-o fichier] [-v] http://hote[:port]/chemin');
 Halt(2);
End;

BEGIN
 Url:=''; OutName:=''; Verbose:=False;
 K:=1;
 While K<ArgCount Do Begin
  If (ArgStr(K)='-o') And (K+1<ArgCount) Then Begin Inc(K); OutName:=ArgStr(K) End
  Else If ArgStr(K)='-v' Then Verbose:=True
  Else If Url='' Then Url:=ArgStr(K)
  Else Usage;
  Inc(K);
 End;
 If Url='' Then Usage;
 If Copy(Url,1,7)='http://' Then Delete(Url,1,7)
 Else If Pos('://',Url)>0 Then Fail('seul le protocole http est connu');
 K:=Pos('/',Url);
 If K=0 Then Begin Host:=Url; Path:='/' End
 Else Begin Host:=Copy(Url,1,K-1); Path:=Copy(Url,K,255) End;
 PortN:=80;
 K:=Pos(':',Host);
 If K>0 Then Begin
  Val(Copy(Host,K+1,10),PortN,Code);
  If Code<>0 Then Fail('port invalide');
  Host:=Copy(Host,1,K-1);
 End;
 If OutName='' Then Begin
  OutName:=Path;
  While Pos('/',OutName)>0 Do Delete(OutName,1,Pos('/',OutName));
  If Pos('?',OutName)>0 Then OutName:=Copy(OutName,1,Pos('?',OutName)-1);
  If OutName='' Then OutName:='index.html';
 End;
 If Not Resolve(Host,A) Then Fail('hote inconnu : '+Host);
 S:=Socket(AF_INET,SOCK_STREAM,0);
 If S<0 Then Fail('socket : '+NetErrorText(Errno));
 If Connect(S,A,PortN)<0 Then Fail(Host+' : '+NetErrorText(Errno));
 Req:='GET '+Path+' HTTP/1.0'#13#10'Host: '+Host+#13#10+
   'User-Agent: fetch (UNIX-0)'#13#10'Connection: close'#13#10#13#10;
 If Send(S,Req[1],Length(Req))<0 Then Fail('envoi : '+NetErrorText(Errno));
 If OutName='-' Then Fd:=1
 Else Begin
  Fd:=SysCreat(OutName,$1A4);
  If Fd<0 Then Fail(OutName+' : '+SysErrorText(Errno));
 End;
 { en-tetes jusqu'a la ligne vide, puis le document }
 InHead:=True; Line:=''; Status:=''; Total:=0; St:=0;
 T0:=SysTime;
 Repeat
  N:=Recv(S,Buf,SizeOf(Buf));
  If N<0 Then Fail('reception : '+NetErrorText(Errno));
  P:=0;
  While InHead And (P<N) Do Begin
   If Buf[P]=10 Then Begin
    If (Line<>'') And (Line[Length(Line)]=#13) Then Delete(Line,Length(Line),1);
    If Status='' Then Begin
     Status:=Line;
     If Pos(' ',Line)>0 Then Val(Copy(Line,Pos(' ',Line)+1,3),St,Code);
    End;
    If Verbose Then WriteLn('< ',Line);
    If Line='' Then InHead:=False;
    Line:='';
   End Else If Length(Line)<255 Then Line:=Line+Chr(Buf[P]);
   Inc(P);
  End;
  If Not InHead And (P<N) Then Begin
   SysWrite(Fd,Buf[P],N-P);
   Inc(Total,N-P);
  End;
 Until N=0;
 SysClose(S);
 If Fd<>1 Then SysClose(Fd);
 If (St<200) Or (St>299) Then Begin
  WriteLn('fetch : ',Url,' : ',Status);
  Halt(1);
 End;
 If Fd<>1 Then
  WriteLn(OutName,' : ',Total,' octets en ',SysTime-T0,' s');
END.
