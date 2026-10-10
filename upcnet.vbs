Option Explicit
' UPCNet 校园网自动登录 —— 后台启动器
' 作用：把 PowerShell 程序以“完全隐藏窗口”的方式启动。
' 特点：自己算出自己在哪个文件夹，所以程序被移到别处也能用。

Dim shell, fso, scriptDir, cmd
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)

cmd = QuoteArg("powershell.exe") & _
      " -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File " & _
      QuoteArg(scriptDir & "\upcnet.ps1") & " -Action daemon"

' 0 = 完全隐藏窗口；False = 不等待（后台常驻）
shell.Run cmd, 0, False

Function QuoteArg(value)
    QuoteArg = Chr(34) & Replace(value, Chr(34), Chr(34) & Chr(34)) & Chr(34)
End Function
