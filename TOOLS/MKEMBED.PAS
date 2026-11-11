{ @author: Sylvain Maltais (support@gladir.com)
  @created: 2026
  @website(https://www.gladir.com/unix-0)
  @abstract(Target: Free Pascal)
  @description: Integre le source de l'unite UNIX (TOOLS/UNIX.PAS) dans le
  compilateur Unix Pascal (TOOLS/UPC.PAS), sous la forme de la constante
  UnixSource, comme les autres unites integrees (DOS, CRT, ...). A relancer
  apres chaque modification de UNIX.PAS.

  Syntaxe :
   MKEMBED [repertoire_TOOLS]       (par defaut, le repertoire courant)
}

Program MKEMBED;

{$MODE OBJFPC}{$H+}

Const
 StartMark = '{ --- debut UnixSource (genere par MKEMBED) --- }';
 OldMark = '{ --- debut UnixSource (genere par MKEMBED.PY) --- }';
 EndMark = '{ --- fin UnixSource --- }';
 Anchor = 'const DosSource:';

Type
 TLines = Array of String;

Var
 Dir: String;
 Src, Upc, Res: TLines;
 I, A, B, N: Longint;

Procedure Fail(S: String);
Begin
 WriteLn(StdErr, 'MKEMBED : ', S);
 Halt(1);
End;

Procedure Push(Var L: TLines; S: String);
Begin
 SetLength(L, Length(L) + 1);
 L[High(L)] := S;
End;

Function ReadLines(Path: String): TLines;
Var T: Text; S: String;
Begin
 Result := Nil;
 Assign(T, Path);
 {$I-} Reset(T); {$I+}
 If IOResult <> 0 Then Fail(Path + ' introuvable');
 While Not Eof(T) Do Begin
  ReadLn(T, S);
  Push(Result, S);
 End;
 Close(T);
End;

Function RTrim(S: String): String;
Var N: Integer;
Begin
 N := Length(S);
 While (N > 0) And (S[N] In [' ', #9, #10, #11, #12, #13]) Do Dec(N);
 RTrim := Copy(S, 1, N);
End;

Function Quote(S: String): String;
Var K: Integer;
Begin
 Result := '';
 For K := 1 To Length(S) Do
  If S[K] = '''' Then Result := Result + '''''' Else Result := Result + S[K];
End;

Function Find(Const L: TLines; S: String; From: Longint): Longint;
Var K: Longint;
Begin
 For K := From To High(L) Do
  If L[K] = S Then Exit(K);
 Result := -1;
End;

Var T: Text; S: String;

BEGIN
 If ParamCount > 0 Then Dir := ParamStr(1) + '/' Else Dir := '';
 Src := ReadLines(Dir + 'UNIX.PAS');
 For I := 0 To High(Src) Do Src[I] := RTrim(Src[I]);
 N := Length(Src);
 While (N > 0) And (Src[N - 1] = '') Do Dec(N);
 Upc := ReadLines(Dir + 'UPC.PAS');
 Res := Nil;
 A := Find(Upc, StartMark, 0);
 If A < 0 Then A := Find(Upc, OldMark, 0);
 If A >= 0 Then Begin
  B := Find(Upc, EndMark, A);
  If B < 0 Then Fail('marque de fin absente dans UPC.PAS');
 End Else Begin
  For I := 0 To High(Upc) Do
   If Copy(Upc[I], 1, Length(Anchor)) = Anchor Then Begin A := I; Break End;
  If A < 0 Then Fail('"' + Anchor + '" absent de UPC.PAS');
  B := A - 1;                       { rien a remplacer : insertion }
 End;
 For I := 0 To A - 1 Do Push(Res, Upc[I]);
 Push(Res, StartMark);
 Str(N, S);
 Push(Res, 'const UnixSource: array[1..' + S + '] of string[255] = (');
 For I := 0 To N - 1 Do Begin
  If Length(Src[I]) > 250 Then Fail('ligne trop longue dans UNIX.PAS : ' + Src[I]);
  S := ' ''' + Quote(Src[I]) + '''';
  If I < N - 1 Then S := S + ',' Else S := S + ');';
  Push(Res, S);
 End;
 Push(Res, EndMark);
 For I := B + 1 To High(Upc) Do Push(Res, Upc[I]);
 Assign(T, Dir + 'UPC.PAS');
 Rewrite(T);
 For I := 0 To High(Res) Do Write(T, Res[I], #10);
 Close(T);
 WriteLn('UnixSource : ', N, ' lignes');
END.
