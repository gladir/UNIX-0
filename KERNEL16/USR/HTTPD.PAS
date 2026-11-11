{ @author: Sylvain Maltais (support@gladir.com)
  @created: 2026
  @website(https://www.gladir.com/unix-0)
  @abstract(Target: Unix Pascal (UPC /X))
  @description: Petit serveur HTTP/1.0 (RFC 1945) de UNIX-0 : sert les
   fichiers d'un repertoire, une connexion a la fois.
     httpd [-p port] [repertoire]        (port 80, /usr/www par defaut)
   GET et HEAD; un repertoire donne son index.html ou la liste de ses
   fichiers; types MIME d'apres l'extension; ".." refuse; un journal des
   requetes est ecrit sur la sortie d'erreur. Lance par /etc/rc si
   /usr/www existe (voir /etc/rc).
   Compilation : UPC /X HTTPD.PAS  -> /bin/httpd
}

Program HttpD;

{$I-}

{$M 8192,0,0}

{$I NET.INC}

Var
 Root,Req,Meth,Path,Line: String;
 PortN,Code,L,S,K,N: Integer;
 A: Longint;
 P: Word;
 Buf: Array[0..1023] Of Byte;
 St: TStat;

Procedure Log(T: String);
{ journal sur la sortie d'erreur }
Begin
 T:=T+#10;
 SysWrite(2,T[1],Length(T));
End;

Procedure Out(Sk: Integer; T: String);
Begin
 If T<>'' Then Send(Sk,T[1],Length(T));
End;

Function Mime(N: String): String;
Var E: String; K: Integer;
Begin
 E:='';
 For K:=Length(N) DownTo 1 Do If N[K]='.' Then Begin E:=Lower(Copy(N,K+1,9)); Break End;
 If (E='html') Or (E='htm') Then Mime:='text/html'
 Else If (E='txt') Or (E='pas') Or (E='inc') Or (E='md') Or (E='') Then Mime:='text/plain'
 Else If E='gif' Then Mime:='image/gif'
 Else If (E='jpg') Or (E='jpeg') Then Mime:='image/jpeg'
 Else If E='png' Then Mime:='image/png'
 Else Mime:='application/octet-stream';
End;

Procedure Header(Sk, Code: Integer; Msg, Typ: String; Len: Longint);
Begin
 Out(Sk,'HTTP/1.0 '+IStr(Code)+' '+Msg+#13#10'Server: httpd (UNIX-0)'#13#10);
 If Typ<>'' Then Out(Sk,'Content-Type: '+Typ+#13#10);
 If Len>=0 Then Out(Sk,'Content-Length: '+IStr(Len)+#13#10);
 Out(Sk,#13#10);
End;

Procedure Error(Sk, Code: Integer; Msg: String);
Var B: String;
Begin
 B:='<html><body><h1>'+IStr(Code)+' '+Msg+'</h1></body></html>'#13#10;
 Header(Sk,Code,Msg,'text/html',Length(B));
 If Meth<>'HEAD' Then Out(Sk,B);
End;

Procedure Listing(Sk: Integer; Dir, Url: String);
Var Fd,N,K,L: Integer; Ent: Array[0..15] Of Byte; Name: String;
Begin
 Header(Sk,200,'OK','text/html',-1);
 If Meth='HEAD' Then Exit;
 Out(Sk,'<html><body><h1>Index de '+Url+'</h1><ul>'#13#10);
 Fd:=SysOpen(Dir,O_RDONLY,0);
 If Fd>=0 Then Begin
  { entrees de repertoire de UNIX V7 : 16 octets }
  While SysRead(Fd,Ent,16)=16 Do Begin
   If (Ent[0]=0) And (Ent[1]=0) Then Continue;
   Name:='';
   For K:=2 To 15 Do If Ent[K]<>0 Then Name:=Name+Chr(Ent[K]) Else Break;
   If (Name='.') Or (Name='..') Then Continue;
   If Url[Length(Url)]<>'/' Then L:=1 Else L:=0;
   If L=1 Then Out(Sk,'<li><a href="'+Url+'/'+Name+'">'+Name+'</a>'#13#10)
   Else Out(Sk,'<li><a href="'+Url+Name+'">'+Name+'</a>'#13#10);
  End;
  SysClose(Fd);
 End;
 Out(Sk,'</ul></body></html>'#13#10);
End;

Procedure Serve(Sk: Integer);
Var File_,Url: String; Fd,N,Fin: Integer;
Begin
 { ligne de requete, puis en-tetes jusqu'a la ligne vide }
 Req:=''; Line:=''; Fin:=0;
 Repeat
  N:=Recv(Sk,Buf,SizeOf(Buf));
  If N<=0 Then Exit;
  For K:=0 To N-1 Do
   If Buf[K]=10 Then Begin
    If (Line<>'') And (Line[Length(Line)]=#13) Then Delete(Line,Length(Line),1);
    If Req='' Then Req:=Line Else If Line='' Then Fin:=1;
    Line:='';
   End Else If Length(Line)<255 Then Line:=Line+Chr(Buf[K]);
 Until Fin=1;
 Meth:=Copy(Req,1,Pos(' ',Req)-1);
 Url:=Copy(Req,Pos(' ',Req)+1,255);
 If Pos(' ',Url)>0 Then Url:=Copy(Url,1,Pos(' ',Url)-1);
 If Pos('?',Url)>0 Then Url:=Copy(Url,1,Pos('?',Url)-1);
 Log('httpd : '+InetNtoA(A)+' '+Req);
 If (Meth<>'GET') And (Meth<>'HEAD') Then Begin Error(Sk,501,'Non implemente'); Exit End;
 If (Url='') Or (Url[1]<>'/') Or (Pos('..',Url)>0) Then Begin
  Error(Sk,400,'Requete invalide'); Exit;
 End;
 File_:=Root+Url;
 If SysStat(File_,St)<>0 Then Begin Error(Sk,404,'Introuvable'); Exit End;
 If St.Mode And S_IFMT=S_IFDIR Then Begin
  If File_[Length(File_)]<>'/' Then File_:=File_+'/';
  If SysStat(File_+'index.html',St)=0 Then File_:=File_+'index.html'
  Else If SysStat(File_+'index.htm',St)=0 Then File_:=File_+'index.htm'
  Else Begin Listing(Sk,File_,Url); Exit End;
 End;
 Fd:=SysOpen(File_,O_RDONLY,0);
 If Fd<0 Then Begin Error(Sk,403,'Interdit'); Exit End;
 Header(Sk,200,'OK',Mime(File_),St.Size);
 If Meth='GET' Then
  Repeat
   N:=SysRead(Fd,Buf,SizeOf(Buf));
   If N>0 Then If Send(Sk,Buf,N)<0 Then N:=0;
  Until N<=0;
 SysClose(Fd);
End;

BEGIN
 Root:='/usr/www'; PortN:=80;
 K:=1;
 While K<ArgCount Do Begin
  If (ArgStr(K)='-p') And (K+1<ArgCount) Then Begin
   Inc(K); Val(ArgStr(K),PortN,Code);
   If (Code<>0) Or (PortN<=0) Then Begin WriteLn('httpd : port invalide'); Halt(2) End;
  End Else Root:=ArgStr(K);
  Inc(K);
 End;
 If (Length(Root)>1) And (Root[Length(Root)]='/') Then Delete(Root,Length(Root),1);
 L:=Socket(AF_INET,SOCK_STREAM,0);
 If L<0 Then Begin WriteLn('httpd : socket : ',NetErrorText(Errno)); Halt(1) End;
 SetSockOpt(L,SO_REUSEADDR,1);
 If Bind(L,0,PortN)<0 Then Begin
  WriteLn('httpd : port ',PortN,' : ',NetErrorText(Errno)); Halt(1);
 End;
 If Listen(L,4)<0 Then Begin WriteLn('httpd : listen : ',NetErrorText(Errno)); Halt(1) End;
 Log('httpd : port '+IStr(PortN)+', '+Root);
 Repeat
  S:=Accept(L,A,P);
  If S<0 Then Begin
   Log('httpd : accept : '+NetErrorText(Errno));
   SysSleep(1);
   Continue;
  End;
  Serve(S);
  SysClose(S);
 Until False;
END.
