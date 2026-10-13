Option Explicit
Dim shell, fs, root, cmd
Set shell = CreateObject("WScript.Shell")
Set fs = CreateObject("Scripting.FileSystemObject")
root = fs.GetParentFolderName(WScript.ScriptFullName)
cmd = Chr(34) & root & "\runtime\pythonw.exe" & Chr(34) & " " & Chr(34) & root & "\app\launch.py" & Chr(34)
If WScript.Arguments.Count > 0 Then
  If WScript.Arguments(0) = "open" Then cmd = cmd & " --open"
End If
shell.Run cmd, 0, False
