[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$manifestPath = Join-Path $root 'installation.json'
$backup = Join-Path $root 'rollback\DreamSkin.ThemeManager.original.exe'
$engine = Join-Path $env:LOCALAPPDATA 'CodexDreamSkin\engine'
$expected = Join-Path $env:LOCALAPPDATA 'CodexDreamSkin\engine\assets\theme-manager\DreamSkin.ThemeManager.exe'

function Assert-LocalPath([string]$Path) {
  for ($item = [IO.Path]::GetFullPath($Path); $item; $item = [IO.Path]::GetDirectoryName($item)) {
    if (([IO.File]::Exists($item) -or [IO.Directory]::Exists($item)) -and (([IO.File]::GetAttributes($item) -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw 'Redirected rollback paths are not supported.' }
  }
}
function Read-ValidatedRollbackManifest {
  foreach ($path in @($manifestPath, $backup, $expected)) { Assert-LocalPath $path }
  $record = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
  if (-not $record.managerPath -or [IO.Path]::GetFullPath($record.managerPath) -ine [IO.Path]::GetFullPath($expected)) { throw 'The rollback target is not the expected DreamSkin manager.' }
  if (-not $record.originalBackup -or [IO.Path]::GetFullPath($record.originalBackup) -ine [IO.Path]::GetFullPath($backup)) { throw 'The rollback backup is not the expected packaged original manager.' }
  if ((Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash -cne $record.originalSha256) { throw 'Original backup checksum does not match.' }
  if ((Get-FileHash -LiteralPath $expected -Algorithm SHA256).Hash -cne $record.studioSha256) { throw 'The installed manager changed after Studio was installed. Refusing to overwrite a newer or different file.' }
  return $record
}

$manifest = Read-ValidatedRollbackManifest
. (Join-Path $root 'Desktop-Entry.ps1')
$processes = @(Get-CimInstance Win32_Process -Filter "Name = 'DreamSkin.ThemeManager.exe'" -ErrorAction Stop | Where-Object { $_.ExecutablePath -ieq $expected })
foreach ($record in $processes) { $handle = Get-Process -Id $record.ProcessId -ErrorAction SilentlyContinue; if ($handle) { [void]$handle.CloseMainWindow() } }
$deadline = (Get-Date).AddSeconds(15)
do {
  $remaining = @(Get-CimInstance Win32_Process -Filter "Name = 'DreamSkin.ThemeManager.exe'" -ErrorAction Stop | Where-Object { $_.ExecutablePath -ieq $expected })
  if ($remaining.Count -eq 0) { break }; Start-Sleep -Milliseconds 250
} while ((Get-Date) -lt $deadline)
if ($remaining.Count -gt 0) { throw 'Close DreamSkin Studio after its current operation finishes, then retry.' }
$common = Join-Path $engine 'scripts\common-windows.ps1'
Assert-LocalPath $common
. $common
$maintenanceLease = Enter-DreamSkinThemeManagerMaintenance
$operationLease = $null
try {
  $operationLease = Enter-DreamSkinOperationLock -TimeoutMilliseconds 1000
  # Recheck after both locks: closing the GUI alone cannot prevent another
  # tray activation, installer, or restore operation from changing the files.
  $manifest = Read-ValidatedRollbackManifest
  $stage = Join-Path ([IO.Path]::GetDirectoryName($expected)) ('restore-stage-' + [guid]::NewGuid().ToString('N') + '.exe')
  try {
    [IO.File]::Copy($backup, $stage, $false)
    if ((Get-FileHash -LiteralPath $stage -Algorithm SHA256).Hash -cne $manifest.originalSha256) { throw 'Staged rollback checksum verification failed.' }
    [IO.File]::Replace($stage, $expected, [System.Management.Automation.Language.NullString]::Value)
    if ((Get-FileHash -LiteralPath $expected -Algorithm SHA256).Hash -cne $manifest.originalSha256) { throw 'Rollback checksum verification failed.' }
    if ($manifest.desktopUpdated) { [void](Set-StudioDesktopEntry -Manager $expected -Mode Restore) }
  } finally {
    if ([IO.File]::Exists($stage)) { [IO.File]::Delete($stage) }
  }
} finally {
  try {
    if ($null -ne $operationLease) { Exit-DreamSkinOperationLock -Mutex $operationLease }
  } finally {
    if ($null -ne $maintenanceLease) { try { $maintenanceLease.ReleaseMutex() } finally { $maintenanceLease.Dispose() } }
  }
}
Add-Type -AssemblyName System.Windows.Forms
[void][System.Windows.Forms.MessageBox]::Show('Original DreamSkin interface restored. Your wallpaper, themes and opacity settings were kept.', 'DreamSkin Studio', 'OK', 'Information')
