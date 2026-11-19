# Called by the Studio installer and rollback after validating the manager.
function Set-StudioDesktopEntry {
  param([string]$Manager, [ValidateSet('OpenCodex','Manager','Restore')][string]$Mode)
  $desktop = [Environment]::GetFolderPath('DesktopDirectory')
  $linkPath = Join-Path $desktop 'Codex 动态壁纸.lnk'
  $backupPath = Join-Path $PSScriptRoot 'rollback\desktop-before-aurora.lnk'
  $iconPath = Join-Path (Split-Path -Parent $Manager) 'dreamskin-aurora.ico'
  foreach ($file in @($linkPath, $backupPath, $iconPath)) { Assert-LocalPath $file }
  if (-not [IO.File]::Exists($linkPath)) { return $false }
  $shell = New-Object -ComObject WScript.Shell
  $link = $shell.CreateShortcut($linkPath)
  $bootstrap = Join-Path $env:LOCALAPPDATA 'Programs\CodexDreamSkin\setup-bootstrap.ps1'
  $ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $oldArgs = '-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy RemoteSigned -File "' + $bootstrap + '" -LaunchTray -ShowWindow'
  $original = $link.TargetPath -ieq $ps -and $link.Arguments -ieq $oldArgs
  $ours = $link.TargetPath -ieq $Manager -and $link.Arguments -in @('', '--open-codex') -and $link.IconLocation -ieq ($iconPath + ',0')
  if (-not ($original -or $ours)) { return $false }
  if ($Mode -eq 'Restore' -and (-not $ours -or -not [IO.File]::Exists($backupPath))) { return $false }
  if ($Mode -ne 'Restore' -and -not [IO.File]::Exists($backupPath)) {
    if (-not $original) { throw 'Original desktop shortcut backup missing.' }
    [IO.File]::Copy($linkPath, $backupPath, $false)
  }
  $saved = $shell.CreateShortcut($backupPath)
  if ($saved.TargetPath -ine $ps -or $saved.Arguments -ine $oldArgs) { throw 'Unexpected original shortcut in rollback.' }
  $temp = Join-Path $desktop ('DreamSkin-' + [guid]::NewGuid().ToString('N') + '.lnk')
  try {
    if ($Mode -eq 'Restore') {
      [IO.File]::Copy($backupPath, $temp, $false)
    } else {
      [IO.File]::Copy($linkPath, $temp, $false)
      $newLink = $shell.CreateShortcut($temp)
      $newLink.TargetPath = $Manager
      $newLink.Arguments = if ($Mode -eq 'OpenCodex') { '--open-codex' } else { '' }
      $newLink.WorkingDirectory = Split-Path -Parent $Manager
      $newLink.IconLocation = $iconPath + ',0'
      $newLink.WindowStyle = 1
      $newLink.Description = if ($Mode -eq 'OpenCodex') { '打开带背景的 Codex' } else { '打开 DreamSkin 主题管理器' }
      $newLink.Save()
    }
    [IO.File]::Replace($temp, $linkPath, [System.Management.Automation.Language.NullString]::Value)
  } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
  if (-not ('DreamSkin.ShortcutNotice' -as [type])) {
    Add-Type -Namespace DreamSkin -Name ShortcutNotice -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("shell32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern void SHChangeNotify(int action, uint flags, string item, IntPtr unused);
'@
  }
  [DreamSkin.ShortcutNotice]::SHChangeNotify(0x2000, 5, $linkPath, [IntPtr]::Zero)
  return $true
}
