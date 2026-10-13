param([string]$GameDir, [string]$InstallRoot, [switch]$NoShortcut, [switch]$NoLaunch, [switch]$Uninstall, [switch]$Rollback, [switch]$TestFailure)
$ErrorActionPreference = 'Stop'
$source = $PSScriptRoot
$manifest = Get-Content -LiteralPath (Join-Path $source 'manifest.json') -Raw | ConvertFrom-Json
$explicitRoot = [bool]$InstallRoot
if (-not $InstallRoot) { $InstallRoot = Join-Path $env:LOCALAPPDATA 'ToyboxTogether' }
$InstallRoot = [IO.Path]::GetFullPath($InstallRoot)
$program = Join-Path $InstallRoot 'program'
$rollbackRoot = Join-Path $InstallRoot 'rollback'
$configPath = Join-Path $InstallRoot 'config.json'
$config = if (Test-Path -LiteralPath $configPath) { Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json } else { $null }
function Assert-Child([string]$Path, [string]$Parent) {
 $absolute = [IO.Path]::GetFullPath($Path)
 $base = [IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
 if (-not $absolute.StartsWith($base,[StringComparison]::OrdinalIgnoreCase)) { throw "Недопустимый путь: $Path" }
}
function Remove-Owned([string]$Path,[string]$Parent) {
 Assert-Child $Path $Parent
 if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force }
}
if (-not ('ToyboxPhysicalPath' -as [type])) { Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class ToyboxPhysicalPath {
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateFileW(string path,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern uint GetFinalPathNameByHandleW(IntPtr handle,StringBuilder path,uint length,uint flags);
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
 public static string Resolve(string path) {
  IntPtr h=CreateFileW(path,0,7,IntPtr.Zero,3,0x02000000,IntPtr.Zero);
  if(h==new IntPtr(-1)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
  try { var b=new StringBuilder(32768); if(GetFinalPathNameByHandleW(h,b,32768,0)==0) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error()); var s=b.ToString(); return s.StartsWith(@"\\?\UNC\")?@"\\"+s.Substring(8):s.StartsWith(@"\\?\")?s.Substring(4):s; }
  finally { CloseHandle(h); }
 }
}
'@
}
function Set-DataPaths {
 $script:program=Join-Path $InstallRoot 'program'
 $script:rollbackRoot=Join-Path $InstallRoot 'rollback'
 $script:configPath=Join-Path $InstallRoot 'config.json'
 $script:config=if(Test-Path -LiteralPath $configPath){Get-Content -LiteralPath $configPath -Raw|ConvertFrom-Json}else{$null}
}
if (-not $GameDir -and $config) { $GameDir = $config.gameDir }
if (-not $GameDir) {
 $libraries = [Collections.Generic.List[string]]::new()
 $steam = (Get-ItemProperty -LiteralPath 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
 if ($steam) {
  $libraries.Add($steam)
  $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
  if (Test-Path -LiteralPath $vdf) { foreach ($match in [regex]::Matches((Get-Content -LiteralPath $vdf -Raw),'"path"\s+"([^"]+)"')) { $libraries.Add($match.Groups[1].Value.Replace('\\','\')) } }
 }
 foreach ($library in $libraries) {
  $acf = Join-Path $library ('steamapps\appmanifest_' + $manifest.appId + '.acf')
  if (Test-Path -LiteralPath $acf) {
   $text = Get-Content -LiteralPath $acf -Raw
   $match = [regex]::Match($text,'"installdir"\s+"([^"]+)"')
   if ($match.Success) { $GameDir = Join-Path $library ('steamapps\common\' + $match.Groups[1].Value); break }
  }
 }
}
if (-not $GameDir) {
 Add-Type -AssemblyName System.Windows.Forms
 $picker = New-Object Windows.Forms.FolderBrowserDialog
 $picker.Description = 'Выберите папку Put Your Toys Away Together!'
 if ($picker.ShowDialog() -ne 'OK') { throw 'Папка игры не выбрана.' }
 $GameDir = $picker.SelectedPath
}
$GameDir = [IO.Path]::GetFullPath($GameDir)
$exe = [IO.Path]::GetFullPath((Join-Path $GameDir $manifest.executable))
if (-not (Test-Path -LiteralPath $exe)) { throw 'В выбранной папке нет файла игры.' }
$running = Get-Process -Name 'MyToyStore-Win64-Shipping' -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe }
if ($running) { throw 'Закройте игру перед установкой, обновлением или удалением мода.' }
$bin = Split-Path $exe
$loader = Join-Path $bin 'ue4ss'
$proxy = Join-Path $bin 'dwmapi.dll'
$marker = Join-Path $bin 'ToyboxInstalled.json'
if (-not $explicitRoot -and (Test-Path -LiteralPath $marker)) {
 $owned=Get-Content -LiteralPath $marker -Raw|ConvertFrom-Json
 if ($owned.name -eq $manifest.name -and $owned.dataRoot) { $InstallRoot=[IO.Path]::GetFullPath($owned.dataRoot) }
}
if (Test-Path -LiteralPath $InstallRoot) { $InstallRoot=[ToyboxPhysicalPath]::Resolve($InstallRoot) }
Set-DataPaths
function Stop-Backend {
 try { $service=Invoke-RestMethod -Uri ('http://127.0.0.1:'+$manifest.port+'/api/status') -TimeoutSec 2 } catch { $service=$null }
 if ($service -and $service.service.program -and $service.service.program.Equals($program,[StringComparison]::OrdinalIgnoreCase)) {
  if ($service.operation -and $service.operation.status -eq 'running') { throw 'Дождитесь завершения операции в панели.' }
  Invoke-RestMethod -Uri ('http://127.0.0.1:'+$manifest.port+'/api/shutdown') -Method Post -ContentType 'application/json' -Body '{}' -TimeoutSec 3|Out-Null
  Start-Sleep -Milliseconds 700
 }
 Get-Process -Name 'pythonw','python' -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($program + '\',[StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { Stop-Process -Id $_.Id -Force }
}
function Restore-Previous {
 if (-not (Test-Path -LiteralPath (Join-Path $rollbackRoot 'state.json'))) { throw 'Предыдущая версия отсутствует.' }
 $old = Get-Content -LiteralPath (Join-Path $rollbackRoot 'state.json') -Raw | ConvertFrom-Json
 Remove-Owned $program $InstallRoot
 if (Test-Path -LiteralPath (Join-Path $rollbackRoot 'program')) { Copy-Item -LiteralPath (Join-Path $rollbackRoot 'program') -Destination $program -Recurse }
 Remove-Owned $loader $bin
 if (Test-Path -LiteralPath (Join-Path $rollbackRoot 'ue4ss')) { Copy-Item -LiteralPath (Join-Path $rollbackRoot 'ue4ss') -Destination $loader -Recurse }
 foreach ($name in @('dwmapi.dll','ToyboxInstalled.json')) {
  $target = Join-Path $bin $name
  if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force }
  if (Test-Path -LiteralPath (Join-Path $rollbackRoot $name)) { Copy-Item -LiteralPath (Join-Path $rollbackRoot $name) -Destination $target }
 }
 if (Test-Path -LiteralPath (Join-Path $rollbackRoot 'config.json')) { Copy-Item -LiteralPath (Join-Path $rollbackRoot 'config.json') -Destination $configPath -Force }
}
if ($Uninstall) {
 if (-not (Test-Path -LiteralPath $marker)) { throw 'В этой папке нет установленного Toybox Together.' }
 Stop-Backend
 Remove-Owned $loader $bin
 foreach ($p in @($proxy,$marker)) { if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force } }
 Remove-Owned $program $InstallRoot
 if (-not $NoShortcut) {
  $shell=New-Object -ComObject WScript.Shell
  foreach ($p in @((Join-Path ([Environment]::GetFolderPath('Desktop')) 'Toybox Together.lnk'),(Join-Path ([Environment]::GetFolderPath('Startup')) 'Toybox Together.lnk'))) {
   if (Test-Path -LiteralPath $p) { $link=$shell.CreateShortcut($p); if ($link.Arguments.IndexOf('"'+(Join-Path $program 'Start.vbs')+'"',[StringComparison]::OrdinalIgnoreCase) -ge 0) { Remove-Item -LiteralPath $p -Force } }
  }
 }
 Write-Host 'Мод удалён. Сохранения, настройки и снапшоты сохранены.'
 exit 0
}
if ($Rollback) { Stop-Backend; Restore-Previous; Write-Host 'Предыдущая версия восстановлена. Снапшоты сохранены.'; exit 0 }
if (-not (Test-Path -LiteralPath (Join-Path $source 'payload\loader\dwmapi.dll'))) { throw 'Для обновления распакуйте новый пакет и запустите Install.cmd из него.' }
if ((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLower() -ne $manifest.sha256) { throw 'Эта версия игры пока не поддерживается пакетом. Игровые файлы не изменены.' }
if ((Test-Path -LiteralPath $proxy) -and -not (Test-Path -LiteralPath $marker)) { throw 'В игре уже есть другой загрузчик модов. Автоматическая установка не будет его перезаписывать.' }
# Stop only the owned local backend before replacing its runtime.
Stop-Backend
New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
$InstallRoot=[ToyboxPhysicalPath]::Resolve($InstallRoot)
Set-DataPaths
Remove-Owned $rollbackRoot $InstallRoot
New-Item -ItemType Directory -Path $rollbackRoot -Force | Out-Null
foreach ($pair in @(@($program,'program'),@($loader,'ue4ss'))) { if (Test-Path -LiteralPath $pair[0]) { Copy-Item -LiteralPath $pair[0] -Destination (Join-Path $rollbackRoot $pair[1]) -Recurse } }
foreach ($pair in @(@($proxy,'dwmapi.dll'),@($marker,'ToyboxInstalled.json'),@($configPath,'config.json'))) { if (Test-Path -LiteralPath $pair[0]) { Copy-Item -LiteralPath $pair[0] -Destination (Join-Path $rollbackRoot $pair[1]) } }
@{version=if($config){$config.version}else{''}} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $rollbackRoot 'state.json') -Encoding utf8
try {
 Remove-Owned $program $InstallRoot
 New-Item -ItemType Directory -Path $program -Force | Out-Null
 foreach ($name in @('app','runtime','Start.vbs','manifest.json','Install.ps1','Remove.cmd','Rollback.cmd','README.md','VERIFICATION.md','THIRD_PARTY.md')) { if (Test-Path -LiteralPath (Join-Path $source $name)) { Copy-Item -LiteralPath (Join-Path $source $name) -Destination $program -Recurse } }
 if ($TestFailure) { throw 'Тестовый сбой обновления.' }
 Remove-Owned $loader $bin
 Copy-Item -LiteralPath (Join-Path $source 'payload\loader\ue4ss') -Destination $loader -Recurse
 Copy-Item -LiteralPath (Join-Path $source 'payload\loader\dwmapi.dll') -Destination $proxy -Force
 New-Item -ItemType Directory -Path (Join-Path $loader 'Mods\ToyboxTogether\Scripts') -Force | Out-Null
 foreach ($name in @('main.lua','json.lua','toytool.lua','replay.lua','shelves.lua')) { Copy-Item -LiteralPath (Join-Path $source ('payload\'+$name)) -Destination (Join-Path $loader ('Mods\ToyboxTogether\Scripts\'+$name)) }
 [IO.File]::WriteAllText((Join-Path $loader 'Mods\ToyboxTogether\Scripts\ToyboxRoot.lua'),('return '+($InstallRoot.Replace('\','/')|ConvertTo-Json -Compress)),[Text.UTF8Encoding]::new($false))
 [IO.File]::WriteAllText((Join-Path $loader 'Mods\mods.txt'),"ToyboxTogether : 1`r`n",[Text.UTF8Encoding]::new($false))
 New-Item -ItemType Directory -Path (Join-Path $InstallRoot 'bridge') -Force | Out-Null
 if ($config) { $config | Add-Member -NotePropertyName gameDir -NotePropertyValue $GameDir -Force; $config | Add-Member -NotePropertyName installDir -NotePropertyValue $program -Force; $config | Add-Member -NotePropertyName version -NotePropertyValue $manifest.version -Force }
 else { $config = [pscustomobject]@{gameDir=$GameDir;installDir=$program;version=$manifest.version;settings=@{}} }
 $config | Add-Member -NotePropertyName gameSavedDir -NotePropertyValue (Join-Path $env:LOCALAPPDATA 'MyToyStore\Saved') -Force
 $config | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $configPath -Encoding utf8
 $manifest|Add-Member -NotePropertyName dataRoot -NotePropertyValue $InstallRoot -Force
 $manifest | ConvertTo-Json | Set-Content -LiteralPath $marker -Encoding utf8
 if (-not $NoShortcut) {
  $shell = New-Object -ComObject WScript.Shell
  $shortcut = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) 'Toybox Together.lnk'))
  $shortcut.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'; $shortcut.Arguments = '"' + (Join-Path $program 'Start.vbs') + '" open'; $shortcut.WorkingDirectory=$program; $shortcut.Save()
 }
 if (-not $NoLaunch) { Start-Process -FilePath (Join-Path $env:WINDIR 'System32\wscript.exe') -ArgumentList ('"'+(Join-Path $program 'Start.vbs')+'"'),'open' -WindowStyle Hidden }
 Write-Host ('Toybox Together '+$manifest.version+' установлен. Откройте ярлык на рабочем столе.')
} catch {
 Restore-Previous
 throw ('Установка не завершена, предыдущая версия восстановлена. '+$_.Exception.Message)
}
