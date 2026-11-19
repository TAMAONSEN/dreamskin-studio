[CmdletBinding()]
param([switch]$NoLaunch, [ValidateSet('OpenCodex','Manager')][string]$DesktopMode)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object Text.UTF8Encoding($false)
$root = $PSScriptRoot
$engine = Join-Path $env:LOCALAPPDATA 'CodexDreamSkin\engine'
$managerFolder = Join-Path $engine 'assets\theme-manager'
$destination = Join-Path $managerFolder 'DreamSkin.ThemeManager.exe'
$source = Join-Path $root 'DreamSkinStudio.exe'
$bridgeSource = Join-Path $root 'backend\studio-bridge.ps1'
$linkSource = Join-Path $root 'backend\wallpaper-link.ps1'
$recorderSource = Join-Path $root 'backend\record-wallpaper.ps1'
$backupFolder = Join-Path $root 'rollback'
$backup = Join-Path $backupFolder 'DreamSkin.ThemeManager.original.exe'
$manifestPath = Join-Path $root 'installation.json'
. (Join-Path $root 'Desktop-Entry.ps1')

function Assert-LocalPath([string]$Path) {
  for ($item = [IO.Path]::GetFullPath($Path); $item; $item = [IO.Path]::GetDirectoryName($item)) {
    if ([IO.File]::Exists($item) -or [IO.Directory]::Exists($item)) {
      if (([IO.File]::GetAttributes($item) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Redirected paths are not supported.' }
    }
  }
}
function Stop-KnownManagerProcesses {
  $known = @($destination, (Join-Path $root 'DreamSkin.ThemeManager.exe'), $source)
  $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  try { $signal = [Threading.EventWaitHandle]::OpenExisting("Local\CodexDreamSkin.$sid.ThemeManager.Close"); try { [void]$signal.Set() } finally { $signal.Dispose() } } catch [Threading.WaitHandleCannotBeOpenedException] { }
  $processes = @(Get-Process -Name 'DreamSkin.ThemeManager','DreamSkinStudio' -ErrorAction SilentlyContinue |
    Where-Object { $candidate = $_.Path; $candidate -and @($known | Where-Object { $_ -ieq $candidate }).Count -gt 0 })
  foreach ($handle in $processes) {
    if (-not $handle.HasExited) { [void]$handle.CloseMainWindow() }
  }
  $deadline = (Get-Date).AddSeconds(15)
  do {
    $remaining = @(Get-Process -Name 'DreamSkin.ThemeManager','DreamSkinStudio' -ErrorAction SilentlyContinue |
      Where-Object { $candidate = $_.Path; $candidate -and @($known | Where-Object { $_ -ieq $candidate }).Count -gt 0 })
    if ($remaining.Count -eq 0) { return }
    Start-Sleep -Milliseconds 250
  } while ((Get-Date) -lt $deadline)
  throw 'The theme manager is still completing an operation. Close it and retry; no Codex process was stopped.'
}

foreach ($path in @($source, $bridgeSource, $linkSource, $destination, $managerFolder, $backupFolder)) { Assert-LocalPath $path }
if (-not [IO.File]::Exists($linkSource)) { throw 'The Wallpaper Engine link backend is missing.' }
Assert-LocalPath $recorderSource
if (-not [IO.File]::Exists($recorderSource)) { throw 'The scene recorder backend is missing.' }
if (-not [IO.File]::Exists($source) -or -not [IO.File]::Exists($bridgeSource) -or -not [IO.File]::Exists($destination)) { throw 'The new package or installed original manager is missing.' }
if (([IO.File]::ReadAllText((Join-Path $engine 'VERSION'))).Trim() -cne '1.7.3') { throw 'This GUI was verified with DreamSkin 1.7.3; check compatibility before replacing another version.' }
$newHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
$bridgeHash = (Get-FileHash -LiteralPath $bridgeSource -Algorithm SHA256).Hash
$linkHash = (Get-FileHash -LiteralPath $linkSource -Algorithm SHA256).Hash
$recorderHash = (Get-FileHash -LiteralPath $recorderSource -Algorithm SHA256).Hash
$oldHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
$activeFile = Join-Path $env:LOCALAPPDATA 'CodexDreamSkin\active-theme\theme.json'
$preferencesFile = Join-Path $env:LOCALAPPDATA 'CodexDreamSkin\theme-preferences.json'
Stop-KnownManagerProcesses
. (Join-Path $engine 'scripts\common-windows.ps1')
$maintenanceLease = Enter-DreamSkinThemeManagerMaintenance
$operationLease = $null
try {
$operationLease = Enter-DreamSkinOperationLock -TimeoutMilliseconds 1000
if (([IO.File]::ReadAllText((Join-Path $engine 'VERSION'))).Trim() -cne '1.7.3') { throw 'The engine version changed while the manager was closing.' }
$beforeActive = (Get-FileHash -LiteralPath $activeFile).Hash
$beforePreferences = (Get-FileHash -LiteralPath $preferencesFile).Hash
$iconTarget = Join-Path $managerFolder 'dreamskin-aurora.ico'
$iconSource = Join-Path $root 'dreamskin-aurora.ico'
Assert-LocalPath $iconSource
Assert-LocalPath $iconTarget
[IO.File]::Copy($iconSource, $iconTarget, $true)
if ((Get-FileHash -LiteralPath $iconSource).Hash -cne (Get-FileHash -LiteralPath $iconTarget).Hash) { throw 'Installed desktop icon checksum mismatch.' }
[void][IO.Directory]::CreateDirectory($backupFolder)
if (-not [IO.File]::Exists($backup)) { [IO.File]::Copy($destination, $backup, $false) }
$backupHash = (Get-FileHash -LiteralPath $backup).Hash
if ([IO.File]::Exists($manifestPath)) {
  $prior = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
  if ($prior.originalSha256 -and $backupHash -cne $prior.originalSha256) { throw 'Original manager backup checksum changed.' }
}
$backendTarget = Join-Path $managerFolder 'backend'
Assert-LocalPath $backendTarget
[void][IO.Directory]::CreateDirectory($backendTarget)
[IO.File]::Copy($bridgeSource, (Join-Path $backendTarget 'studio-bridge.ps1'), $true)
if ((Get-FileHash -LiteralPath (Join-Path $backendTarget 'studio-bridge.ps1')).Hash -cne $bridgeHash) { throw 'Installed backend checksum did not verify.' }
[IO.File]::Copy($linkSource, (Join-Path $backendTarget 'wallpaper-link.ps1'), $true)
if ((Get-FileHash -LiteralPath (Join-Path $backendTarget 'wallpaper-link.ps1')).Hash -cne $linkHash) { throw 'Installed Wallpaper Engine link checksum did not verify.' }
[IO.File]::Copy($recorderSource, (Join-Path $backendTarget 'record-wallpaper.ps1'), $true)
if ((Get-FileHash -LiteralPath (Join-Path $backendTarget 'record-wallpaper.ps1')).Hash -cne $recorderHash) { throw 'Installed recorder checksum did not verify.' }
$staged = Join-Path $managerFolder ('studio-stage-' + [guid]::NewGuid().ToString('N') + '.exe')
[IO.File]::Copy($source, $staged, $false)
if ((Get-FileHash -LiteralPath $staged).Hash -cne $newHash) { throw 'The staged executable checksum does not match.' }
try { [IO.File]::Replace($staged, $destination, [System.Management.Automation.Language.NullString]::Value) }
catch { if ([IO.File]::Exists($staged)) { [IO.File]::Delete($staged) }; throw }
if ((Get-FileHash -LiteralPath $destination).Hash -cne $newHash) { throw 'Installed executable checksum did not verify.' }
$preserved = ((Get-FileHash -LiteralPath $activeFile).Hash -ceq $beforeActive) -and ((Get-FileHash -LiteralPath $preferencesFile).Hash -ceq $beforePreferences)
if (-not $preserved) { throw 'Theme data changed during deployment; inspect before continuing.' }
$manifest = [ordered]@{ installedAt = (Get-Date).ToString('o'); engineVersion = '1.7.3'; designEdition = '10 - Nebula'; managerPath = $destination; originalBackup = $backup; originalSha256 = $backupHash; studioSha256 = $newHash; bridgeSha256 = $bridgeHash; wallpaperLinkSha256 = $linkHash; recorderSha256 = $recorderHash; currentThemePreserved = $preserved; modifiesCodexExecutable = $false; payloadOriginalKept = $true }
if (-not $DesktopMode) { $DesktopMode = if ($prior.desktopMode -eq 'Manager') { 'Manager' } else { 'OpenCodex' } }
$manifest['desktopMode'] = $DesktopMode
$manifest['desktopUpdated'] = Set-StudioDesktopEntry -Manager $destination -Mode $DesktopMode
[IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 4), $utf8)
} finally {
  try {
    if ($null -ne $operationLease) { Exit-DreamSkinOperationLock -Mutex $operationLease }
  } finally {
    if ($null -ne $maintenanceLease) { try { $maintenanceLease.ReleaseMutex() } finally { $maintenanceLease.Dispose() } }
  }
}
if (-not $NoLaunch) {
  $launch = Start-Process -FilePath $destination -WorkingDirectory $managerFolder -PassThru -ErrorAction Stop
  $manifest['managerPid'] = $launch.Id
  [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 4), $utf8)
}
$manifest | ConvertTo-Json -Depth 4
