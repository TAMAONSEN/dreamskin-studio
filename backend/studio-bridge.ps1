[CmdletBinding()]
param(
  [string]$Action = 'Status',
  [string]$Path,
  [string]$ThemeId,
  [string]$Name,
  [string]$Percent,
  [string]$Accent,
  [string]$Background,
  [string]$Panel,
  [string]$Text,
  [ValidateSet('true', 'false')][string]$Enabled
)

# Run with Windows PowerShell 5.1. Standard output is one UTF-8 JSON envelope.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'
$script:StudioUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
[Console]::OutputEncoding = $script:StudioUtf8
$OutputEncoding = $script:StudioUtf8
$script:StudioStateRoot = Join-Path $env:LOCALAPPDATA 'CodexDreamSkin'
$script:StudioEngineRoot = Join-Path $script:StudioStateRoot 'engine'
$script:StudioScriptsRoot = Join-Path $script:StudioEngineRoot 'scripts'
$script:StudioLogRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'logs'
$script:StudioRequestLog = $null
$script:StudioFailureData = $null
$script:StudioPreferencePath = Join-Path $script:StudioStateRoot 'theme-preferences.json'
$script:StudioColorBackupPath = Join-Path $script:StudioStateRoot 'studio-theme-colors.json'
$script:StudioAutoStartPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'DreamSkin Studio.lnk'

function Read-StudioJson {
  param([Parameter(Mandatory = $true)][string]$FilePath, [int]$MaximumBytes = 262144)
  Assert-DreamSkinNoReparseComponents -Path $FilePath
  if (-not [IO.File]::Exists($FilePath)) { return $null }
  $fileInfo = New-Object IO.FileInfo($FilePath)
  if ($fileInfo.Length -gt $MaximumBytes) { throw 'The local JSON file exceeds its size limit.' }
  $bytes = [IO.File]::ReadAllBytes($FilePath)
  if ($bytes.Length -gt $MaximumBytes) { throw 'The local JSON file exceeds its size limit.' }
  $jsonText = $script:StudioUtf8.GetString($bytes).TrimStart([char]0xFEFF)
  $value = ConvertFrom-Json -InputObject $jsonText -ErrorAction Stop
  if ($null -eq $value -or $value -is [array] -or $value -is [string] -or $value -is [ValueType]) {
    throw 'The local JSON file must contain an object.'
  }
  return $value
}

function Read-StudioPreferences {
  $preferences = Read-StudioJson -FilePath $script:StudioPreferencePath
  if ($null -eq $preferences) {
    return [pscustomobject]@{ schemaVersion = 1; themes = [pscustomobject]@{} }
  }
  if ($preferences.schemaVersion -ne 1 -or $null -eq $preferences.themes -or
      $preferences.themes -isnot [pscustomobject]) {
    throw 'The theme preference schema is unsupported; no preference was changed.'
  }
  return $preferences
}

function Get-StudioTransparency {
  param([string]$Id, [AllowNull()][object]$Preferences)
  if (-not $Id -or $null -eq $Preferences) { return $null }
  $entry = $Preferences.themes.PSObject.Properties[$Id]
  if ($null -eq $entry) { return $null }
  if ($entry.Value -isnot [pscustomobject]) { throw 'The theme preference entry is invalid.' }
  $property = $entry.Value.PSObject.Properties['transparency']
  if ($null -eq $property) { return $null }
  $number = $property.Value
  if ($number -is [string] -or $number -is [bool] -or $null -eq $number -or
      [double]::IsNaN([double]$number) -or [double]::IsInfinity([double]$number) -or
      [double]$number -lt 0 -or [double]$number -gt 100) {
    throw 'The theme transparency preference is outside 0 to 100.'
  }
  return [double]$number
}

function Set-StudioPreferenceValue {
  param([Parameter(Mandatory = $true)][object]$Preferences,
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][double]$Value)
  if (-not $Id -or $Id.Length -gt 80 -or $Id -match '[\x00-\x1f]') { throw 'The theme ID is invalid.' }
  $property = $Preferences.themes.PSObject.Properties[$Id]
  if ($null -eq $property) {
    $Preferences.themes | Add-Member -NotePropertyName $Id -NotePropertyValue ([pscustomobject]@{})
    $property = $Preferences.themes.PSObject.Properties[$Id]
  }
  if ($property.Value -isnot [pscustomobject]) { throw 'The theme preference entry is invalid.' }
  $property.Value | Add-Member -NotePropertyName transparency -NotePropertyValue $Value -Force
}

function Get-StudioThemeResult {
  param([Parameter(Mandatory = $true)][object]$LoadedTheme,
        [AllowNull()][object]$Preferences)
  [pscustomobject]@{
    id = [string]$LoadedTheme.Theme.id
    name = [string]$LoadedTheme.Theme.name
    path = [string]$LoadedTheme.Directory
    mediaPath = [string]$LoadedTheme.MediaPath
    mediaType = [string]$LoadedTheme.MediaType
    reveal = Get-DreamSkinThemeMediaRevealPercent -Theme $LoadedTheme.Theme
    sourceTransparency = Get-StudioTransparency -Id ([string]$LoadedTheme.Theme.id) -Preferences $Preferences
    colors = $LoadedTheme.Theme.colors
  }
}

function Read-StudioColorBackups {
  $backups = Read-StudioJson -FilePath $script:StudioColorBackupPath -MaximumBytes 1048576
  if ($null -eq $backups) {
    return [pscustomobject]@{ schemaVersion = 1; themes = [pscustomobject]@{} }
  }
  if ($backups.schemaVersion -ne 1 -or $null -eq $backups.themes -or $backups.themes -isnot [pscustomobject]) {
    throw 'The original color backup schema is unsupported; no colors were changed.'
  }
  return $backups
}

function Get-StudioColorSnapshot {
  param([Parameter(Mandatory = $true)][object]$Theme)
  $colorsProperty = $Theme.PSObject.Properties['colors']
  $paletteProperty = $Theme.PSObject.Properties['palette']
  [pscustomobject]@{
    colorsPresent = $null -ne $colorsProperty
    colorsValue = if ($null -ne $colorsProperty) { $colorsProperty.Value } else { $null }
    palettePresent = $null -ne $paletteProperty
    paletteValue = if ($null -ne $paletteProperty) { $paletteProperty.Value } else { $null }
  }
}

function Assert-StudioColorSnapshot {
  param([Parameter(Mandatory = $true)][object]$Snapshot)
  if ($Snapshot -isnot [pscustomobject] -or
      $Snapshot.colorsPresent -isnot [bool] -or $Snapshot.palettePresent -isnot [bool]) {
    throw 'The original color snapshot is invalid.'
  }
  foreach ($value in @($Snapshot.colorsValue, $Snapshot.paletteValue)) {
    if ($null -ne $value -and $value -isnot [pscustomobject]) { throw 'A color snapshot must contain color objects.' }
  }
}

function Get-StudioColorField {
  param([AllowNull()][object]$Object, [string]$Key)
  if ($null -eq $Object) { return $null }
  if ($Object -isnot [pscustomobject]) { throw 'Theme colors and palette must be JSON objects.' }
  $property = $Object.PSObject.Properties[$Key]
  if ($null -eq $property -or $null -eq $property.Value) { return $null }
  if ($property.Value -isnot [string]) { throw 'Theme color values must be strings.' }
  return [string]$property.Value
}

function Get-StudioColors {
  param([bool]$RequiresApply = $false)
  $active = Get-StudioActive
  if ($null -eq $active) {
    return [pscustomobject]@{ themeId = $null; themeName = $null; appearance = $null;
      colors = [pscustomobject]@{ accent = $null; background = $null; panel = $null; text = $null };
      hasCustomColors = $false; canReset = $false; requiresApply = $false }
  }
  $theme = Read-StudioJson -FilePath (Join-Path $active.Directory 'theme.json') -MaximumBytes 1048576
  $backups = Read-StudioColorBackups
  $backupProperty = $backups.themes.PSObject.Properties[[string]$theme.id]
  if ($null -ne $backupProperty) { Assert-StudioColorSnapshot -Snapshot $backupProperty.Value.original }
  $currentAccent = Get-StudioColorField -Object $theme.colors -Key accent
  if ($null -eq $currentAccent) { $currentAccent = Get-StudioColorField -Object $theme.palette -Key accent }
  [pscustomobject]@{
    themeId = [string]$theme.id
    themeName = [string]$theme.name
    appearance = [string]$theme.appearance
    colors = [pscustomobject]@{
      accent = $currentAccent
      background = Get-StudioColorField -Object $theme.colors -Key background
      panel = Get-StudioColorField -Object $theme.colors -Key panel
      text = Get-StudioColorField -Object $theme.colors -Key text
    }
    hasCustomColors = $null -ne $backupProperty
    canReset = $null -ne $backupProperty
    requiresApply = $RequiresApply
  }
}

function ConvertTo-StudioHexColor {
  param([Parameter(Mandatory = $true)][string]$Value)
  $candidate = $Value.Trim()
  if ($candidate -cmatch '^#[0-9a-fA-F]{3}$') {
    $candidate = '#' + $candidate[1] + $candidate[1] + $candidate[2] + $candidate[2] + $candidate[3] + $candidate[3]
  }
  if ($candidate -cnotmatch '^#[0-9a-fA-F]{6}$') { throw 'Choose a color in #RRGGBB or #RGB format.' }
  return $candidate.ToUpperInvariant()
}

function Set-StudioThemeColors {
  param([Parameter(Mandatory = $true)][AllowEmptyCollection()][hashtable]$Updates, [switch]$Reset)
  $active = Get-StudioActive
  if ($null -eq $active) { throw 'There is no active theme.' }
  $themePath = Join-Path $active.Directory 'theme.json'
  $themeBefore = [IO.File]::ReadAllBytes($themePath)
  $theme = Read-StudioJson -FilePath $themePath -MaximumBytes 1048576
  $currentId = [string]$theme.id
  if (-not $currentId -or $currentId.Length -gt 80 -or $currentId -match '[\x00-\x1f]') { throw 'The current theme ID is invalid.' }
  if ($ThemeId -and $ThemeId -cne $currentId) { throw 'The current theme changed. Refresh before editing its colors.' }
  Assert-DreamSkinNoReparseComponents -Path $script:StudioColorBackupPath
  $backupBefore = if ([IO.File]::Exists($script:StudioColorBackupPath)) { [IO.File]::ReadAllBytes($script:StudioColorBackupPath) } else { $null }
  $backups = Read-StudioColorBackups
  $backupProperty = $backups.themes.PSObject.Properties[$currentId]
  if ($Reset) {
    if ($null -eq $backupProperty) { throw 'There are no Studio color changes to restore for this theme.' }
    $original = $backupProperty.Value.original
    Assert-StudioColorSnapshot -Snapshot $original
    if ($original.colorsPresent) {
      $theme | Add-Member -NotePropertyName colors -NotePropertyValue $original.colorsValue -Force
    } else { $theme.PSObject.Properties.Remove('colors') }
    if ($original.palettePresent) {
      $theme | Add-Member -NotePropertyName palette -NotePropertyValue $original.paletteValue -Force
    } else { $theme.PSObject.Properties.Remove('palette') }
    $backups.themes.PSObject.Properties.Remove($currentId)
  } else {
    if ($Updates.Count -eq 0) { throw 'SetColors requires at least one of -Accent, -Background, -Panel or -Text.' }
    foreach ($key in @($Updates.Keys)) { $Updates[$key] = ConvertTo-StudioHexColor -Value ([string]$Updates[$key]) }
    # Validate both existing color objects before writing the first backup.
    $null = Get-StudioColorField -Object $theme.colors -Key accent
    $null = Get-StudioColorField -Object $theme.palette -Key accent
    if ($null -eq $backupProperty) {
      $backups.themes | Add-Member -NotePropertyName $currentId -NotePropertyValue ([pscustomobject]@{
        original = Get-StudioColorSnapshot -Theme $theme
      })
    } else { Assert-StudioColorSnapshot -Snapshot $backupProperty.Value.original }
    # Clone after snapshotting so adding fields cannot mutate the saved original.
    $theme = $theme | ConvertTo-Json -Depth 24 | ConvertFrom-Json
    if ($null -eq $theme.colors) { $theme | Add-Member -NotePropertyName colors -NotePropertyValue ([pscustomobject]@{}) -Force }
    foreach ($key in $Updates.Keys) { $theme.colors | Add-Member -NotePropertyName $key -NotePropertyValue $Updates[$key] -Force }
    $selectedAccent = Get-StudioColorField -Object $theme.colors -Key accent
    if ($null -eq $selectedAccent) { $selectedAccent = Get-StudioColorField -Object $theme.palette -Key accent }
    if ($null -ne $selectedAccent) {
      $theme.colors | Add-Member -NotePropertyName accent -NotePropertyValue $selectedAccent -Force
      if ($null -eq $theme.palette) { $theme | Add-Member -NotePropertyName palette -NotePropertyValue ([pscustomobject]@{}) -Force }
      $theme.palette | Add-Member -NotePropertyName accent -NotePropertyValue $selectedAccent -Force
    }
  }
  $colorAccent = Get-StudioColorField -Object $theme.colors -Key accent
  $paletteAccent = Get-StudioColorField -Object $theme.palette -Key accent
  if ($null -ne $colorAccent -and $null -ne $paletteAccent -and $colorAccent.Trim() -cne $paletteAccent.Trim()) {
    throw 'The original theme has conflicting accent values; no color was changed.'
  }
  $backupText = ($backups | ConvertTo-Json -Depth 24) + "`n"
  if ($script:StudioUtf8.GetByteCount($backupText) -gt 1048576) { throw 'The color backup store exceeds its size limit.' }
  $backupApplied = $script:StudioUtf8.GetBytes($backupText)
  $themeText = ($theme | ConvertTo-Json -Depth 24) + "`n"
  $themeApplied = $script:StudioUtf8.GetBytes($themeText)
  $backupWritten = $false
  $themeWritten = $false
  try {
    if ($Reset) {
      # Restore first. An interruption may leave an extra backup, but must never
      # discard the only original snapshot before the original colors are back.
      Write-DreamSkinUtf8FileAtomically -Path $themePath -Content $themeText -ExpectedBytes $themeBefore
      $themeWritten = $true
      Write-DreamSkinUtf8FileAtomically -Path $script:StudioColorBackupPath -Content $backupText -ExpectedBytes $backupBefore
    } else {
      Write-DreamSkinUtf8FileAtomically -Path $script:StudioColorBackupPath -Content $backupText -ExpectedBytes $backupBefore
      $backupWritten = $true
      Write-DreamSkinUtf8FileAtomically -Path $themePath -Content $themeText -ExpectedBytes $themeBefore
    }
  } catch {
    $colorFailure = $_
    if ($themeWritten) {
      try { Write-DreamSkinBytesAtomically -Path $themePath -Bytes $themeBefore -ExpectedBytes $themeApplied }
      catch { throw 'The reset failed and a newer theme edit prevented rollback. The original color backup was retained.' }
    }
    if ($backupWritten) {
      try {
        if ($null -ne $backupBefore) {
          Write-DreamSkinBytesAtomically -Path $script:StudioColorBackupPath -Bytes $backupBefore -ExpectedBytes $backupApplied
        } elseif (Test-DreamSkinBytesEqual -Left ([IO.File]::ReadAllBytes($script:StudioColorBackupPath)) -Right $backupApplied) {
          [IO.File]::Delete($script:StudioColorBackupPath)
        }
      } catch { throw 'The color update failed and backup rollback was blocked. Refresh before retrying.' }
    }
    throw $colorFailure
  }
  return Get-StudioColors -RequiresApply $true
}

function Get-StudioActive {
  $activeDirectory = Join-Path $script:StudioStateRoot 'active-theme'
  if (-not [IO.File]::Exists((Join-Path $activeDirectory 'theme.json'))) { return $null }
  return Read-DreamSkinTheme -ThemeDirectory $activeDirectory -SkipImageMetadata
}

function Get-StudioThemeList {
  # Get-DreamSkinSavedThemes also repairs transactions. This read path never does.
  $savedDirectory = Join-Path $script:StudioStateRoot 'themes'
  Assert-DreamSkinNoReparseComponents -Path $savedDirectory
  if (-not [IO.Directory]::Exists($savedDirectory)) { return @() }
  $active = Get-StudioActive
  $activeId = if ($null -ne $active) { [string]$active.Theme.id } else { '' }
  $items = @()
  foreach ($directory in [IO.Directory]::EnumerateDirectories($savedDirectory)) {
    if ([IO.Path]::GetFileName($directory).StartsWith('.')) { continue }
    try {
      $loaded = Read-DreamSkinTheme -ThemeDirectory $directory -SkipImageMetadata
      $items += [pscustomobject]@{
        id = [string]$loaded.Theme.id
        name = [string]$loaded.Theme.name
        path = [string]$loaded.Directory
        mediaPath = [string]$loaded.MediaPath
        mediaType = [string]$loaded.MediaType
        isActive = [string]$loaded.Theme.id -ceq $activeId
      }
    } catch {
      # Invalid saved directories are not offered for selection.
    }
  }
  return @($items | Sort-Object name, id)
}

function Get-StudioSavedTheme {
  param([string]$Id)
  if (-not $Id) { throw '请选择一个收藏主题。' }
  $matches = @(Get-StudioThemeList | Where-Object { $_.id -ceq $Id })
  if ($matches.Count -ne 1) { throw '该收藏已不存在或无法唯一识别，请刷新列表。' }
  return $matches[0]
}

function Rename-StudioSavedTheme {
  param([string]$Id, [string]$NewName)
  $NewName = $NewName.Trim()
  if (-not $NewName -or $NewName.Length -gt 80 -or $NewName -match '[\u0000-\u001f]') {
    throw '请输入 1 到 80 个字符的主题名称。'
  }
  $item = Get-StudioSavedTheme -Id $Id
  $directories = @($item.path)
  if ($item.isActive) { $directories += Join-Path $script:StudioStateRoot 'active-theme' }
  $changes = foreach ($directory in $directories) {
    $path = Join-Path $directory 'theme.json'
    $json = Read-StudioJson -FilePath $path
    if ($null -eq $json -or [string]$json.id -cne $Id) { throw '主题已变化，请刷新列表。' }
    $before = [IO.File]::ReadAllBytes($path)
    $original = ConvertFrom-Json -InputObject $script:StudioUtf8.GetString($before).TrimStart([char]0xFEFF)
    if ([string]$original.id -cne $Id) { throw '主题已变化，请刷新列表。' }
    $original.name = $NewName
    [pscustomobject]@{
      path = $path; before = $before
      after = $script:StudioUtf8.GetBytes(($original | ConvertTo-Json -Depth 24) + "`r`n")
    }
  }
  $applied = @()
  try {
    foreach ($change in $changes) {
      Write-DreamSkinBytesAtomically -Path $change.path -Bytes $change.after -ExpectedBytes $change.before
      $applied += $change
    }
  } catch {
    $failure = $_
    foreach ($change in $applied) {
      Write-DreamSkinBytesAtomically -Path $change.path -Bytes $change.before -ExpectedBytes $change.after
    }
    throw $failure
  }
  return [pscustomobject]@{ id = $Id; name = $NewName; active = $item.isActive }
}

function Move-StudioSavedThemeToRecycleBin {
  param([string]$Id)
  $item = Get-StudioSavedTheme -Id $Id
  if ($item.isActive) { throw '请先切换到其他主题，再删除正在使用的主题。' }
  $saved = Join-Path $script:StudioStateRoot 'themes'
  if (-not (Test-DreamSkinPathEqual -Left ([IO.Path]::GetDirectoryName($item.path)) -Right $saved)) {
    throw '只能删除收藏目录中的主题。'
  }
  # Check the full directory tree without descending into junctions or links.
  $remaining = New-Object 'System.Collections.Generic.Stack[string]'
  $remaining.Push($item.path)
  while ($remaining.Count -gt 0) {
    $path = $remaining.Pop()
    Assert-DreamSkinNoReparseComponents -Path $path
    $attributes = [IO.File]::GetAttributes($path)
    if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) {
      foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($path)) { $remaining.Push($entry) }
    }
  }
  if (-not ('DreamSkinStudio.ThemeRecycle' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace DreamSkinStudio {
  public static class ThemeRecycle {
    [ComImport, Guid("947AAB5F-0A5C-4C13-B4D6-4BF7836FC9F8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IFileOperation {
      void Advise();
      void Unadvise();
      void SetOperationFlags(uint flags);
      void SetProgressMessage();
      void SetProgressDialog();
      void SetProperties();
      void SetOwnerWindow();
      void ApplyPropertiesToItem();
      void ApplyPropertiesToItems();
      void RenameItem();
      void RenameItems();
      void MoveItem();
      void MoveItems();
      void CopyItem();
      void CopyItems();
      void DeleteItem(IntPtr item, IntPtr progress);
      void DeleteItems();
      void NewItem();
      void PerformOperations();
      void GetAnyOperationsAborted([MarshalAs(UnmanagedType.Bool)] out bool aborted);
    }
    [DllImport("shell32.dll", CharSet=CharSet.Unicode, ExactSpelling=true, PreserveSig=false)]
    private static extern void SHCreateItemFromParsingName(string path, IntPtr context, ref Guid iid, out IntPtr item);

    public static void Move(string path) {
      var item = IntPtr.Zero;
      IFileOperation op = null;
      try {
        var shellItem = new Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE");
        SHCreateItemFromParsingName(path, IntPtr.Zero, ref shellItem, out item);
        var fileOperation = new Guid("3AD05575-8857-4850-9277-11B85BDB8E09");
        op = (IFileOperation)Activator.CreateInstance(Type.GetTypeFromCLSID(fileOperation));
        const uint RecycleOnDelete = 0x80000, NoConfirmation = 0x10, NoErrorUi = 0x400, Silent = 4, EarlyFailure = 0x100000;
        op.SetOperationFlags(RecycleOnDelete | NoConfirmation | NoErrorUi | Silent | EarlyFailure);
        op.DeleteItem(item, IntPtr.Zero);
        op.PerformOperations();
        bool aborted;
        op.GetAnyOperationsAborted(out aborted);
        if (aborted || System.IO.Directory.Exists(path)) throw new InvalidOperationException("Windows did not recycle the theme.");
      } finally {
        if (op != null) Marshal.FinalReleaseComObject(op);
        if (item != IntPtr.Zero) Marshal.Release(item);
      }
    }
  }
}
'@
  }
  try { [DreamSkinStudio.ThemeRecycle]::Move($item.path) }
  catch { throw ('无法将主题移到回收站。请关闭占用主题文件的窗口后重试。' + [Environment]::NewLine + $_.Exception.Message) }
  return [pscustomobject]@{ id = $Id; name = $item.name; recycled = $true }
}

function Get-StudioRunning {
  $portNumber = 9335
  $state = Read-StudioJson -FilePath (Join-Path $script:StudioStateRoot 'state.json') -MaximumBytes 131072
  if ($null -ne $state -and $state.port) {
    $candidatePort = 0
    if ([int]::TryParse([string]$state.port, [ref]$candidatePort) -and
        $candidatePort -ge 1024 -and $candidatePort -le 65535) { $portNumber = $candidatePort }
  }
  $portListening = $false
  try {
    $portListening = @([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() |
      Where-Object { $_.Port -eq $portNumber -and [Net.IPAddress]::IsLoopback($_.Address) }).Count -gt 0
  } catch { }
  $injectorAlive = $false
  if ($null -ne $state -and $state.injectorPid) {
    $injectorId = 0
    if ([int]::TryParse([string]$state.injectorPid, [ref]$injectorId) -and $injectorId -gt 0) {
      $injectorProcess = $null
      try {
        $injectorProcess = [Diagnostics.Process]::GetProcessById($injectorId)
        $injectorAlive = -not $injectorProcess.HasExited
        if ($injectorAlive -and $state.nodePath) {
          $injectorAlive = [string]::Equals($injectorProcess.MainModule.FileName,
            [string]$state.nodePath, [StringComparison]::OrdinalIgnoreCase)
        }
        if ($injectorAlive -and $state.injectorStartedAt) {
          $recordedStart = [DateTime]::Parse([string]$state.injectorStartedAt).ToUniversalTime()
          $injectorAlive = [math]::Abs(($injectorProcess.StartTime.ToUniversalTime() - $recordedStart).TotalSeconds) -lt 2
        }
      } catch { $injectorAlive = $false }
      finally { if ($null -ne $injectorProcess) { $injectorProcess.Dispose() } }
    }
  }
  return [pscustomobject]@{ port = $portNumber; portListening = [bool]$portListening;
    injectorAlive = [bool]$injectorAlive; approximate = $true }
}

function Get-StudioStatus {
  $active = Get-StudioActive
  $preferences = Read-StudioPreferences
  $versionFile = Join-Path $script:StudioEngineRoot 'VERSION'
  [pscustomobject]@{
    active = if ($null -ne $active) { Get-StudioThemeResult -LoadedTheme $active -Preferences $preferences } else { $null }
    savedCount = @(Get-StudioThemeList).Count
    paused = [bool](Test-DreamSkinPaused -StateRoot $script:StudioStateRoot)
    running = Get-StudioRunning
    autoStart = [IO.File]::Exists($script:StudioAutoStartPath)
    autoStartScope = 'DreamSkin Studio only; starts the manager at sign-in, without automatically restarting Codex.'
    stateRoot = $script:StudioStateRoot
    engineVersion = if ([IO.File]::Exists($versionFile)) { [IO.File]::ReadAllText($versionFile).Trim() } else { $null }
  }
}

function Initialize-StudioOperationLog {
  if ($null -ne $script:StudioRequestLog) { return }
  $null = [IO.Directory]::CreateDirectory($script:StudioLogRoot)
  $safeAction = $Action -replace '[^A-Za-z]', ''
  $script:StudioRequestLog = Join-Path $script:StudioLogRoot (
    (Get-Date).ToString('yyyyMMdd-HHmmss-fff') + '-' + $safeAction + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.log')
}

function Invoke-StudioLocked {
  param([Parameter(Mandatory = $true)][scriptblock]$Operation)
  Initialize-StudioOperationLog
  $operationLease = Enter-DreamSkinOperationLock -TimeoutMilliseconds 1000
  try {
    $records = @(& $Operation *>&1)
    foreach ($record in $records) {
      if ($record -is [Management.Automation.ErrorRecord]) { throw $record }
      if ($record -is [Management.Automation.WarningRecord] -or
          $record -is [Management.Automation.VerboseRecord] -or
          $record -is [Management.Automation.DebugRecord] -or
          $record -is [Management.Automation.InformationRecord] -or $record -is [string]) {
        [IO.File]::AppendAllText($script:StudioRequestLog, [string]$record + "`r`n", $script:StudioUtf8)
      } else { Write-Output $record }
    }
  }
  finally { Exit-DreamSkinOperationLock -Mutex $operationLease }
}

function Initialize-StudioChildLauncher {
  if ('DreamSkinStudio.NativeChildLauncher' -as [type]) { return }
  # A child that starts a background watcher can leak ordinary redirected pipe
  # handles into that grandchild. Use native file handles with an explicit
  # inheritance allow-list, so neither Studio nor its caller's pipes can escape.
  $launcherSource = @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
namespace DreamSkinStudio {
  public static class NativeChildLauncher {
    [StructLayout(LayoutKind.Sequential)] private struct SecurityAttributes {
      public int Length; public IntPtr Descriptor;
      [MarshalAs(UnmanagedType.Bool)] public bool Inherit;
    }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] private struct StartupInfo {
      public int Size; public string Reserved, Desktop, Title;
      public int X,Y,XSize,YSize,XChars,YChars,Fill,Flags;
      public short Show,ReservedBytes; public IntPtr ReservedPointer,Input,Output,Error;
    }
    [StructLayout(LayoutKind.Sequential)] private struct StartupInfoEx {
      public StartupInfo Info; public IntPtr Attributes;
    }
    [StructLayout(LayoutKind.Sequential)] private struct ProcessInfo {
      public IntPtr Process,Thread; public uint ProcessId,ThreadId;
    }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern IntPtr CreateFile(string name,uint access,uint share,ref SecurityAttributes security,uint creation,uint flags,IntPtr template);
    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern bool InitializeProcThreadAttributeList(IntPtr list,int count,int flags,ref IntPtr bytes);
    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern bool UpdateProcThreadAttribute(IntPtr list,uint flags,IntPtr attribute,IntPtr value,IntPtr bytes,IntPtr previous,IntPtr returnedBytes);
    [DllImport("kernel32.dll")] private static extern void DeleteProcThreadAttributeList(IntPtr list);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    [return:MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateProcess(string app,StringBuilder command,IntPtr processSecurity,IntPtr threadSecurity,bool inherit,uint flags,IntPtr environment,string directory,ref StartupInfoEx startup,out ProcessInfo process);
    [DllImport("kernel32.dll", SetLastError=true)] private static extern uint WaitForSingleObject(IntPtr handle,uint milliseconds);
    [DllImport("kernel32.dll", SetLastError=true)] private static extern bool GetExitCodeProcess(IntPtr process,out uint code);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
    private static readonly IntPtr Invalid = new IntPtr(-1);
    private static IntPtr Open(string path,uint access,uint creation) {
      var security = new SecurityAttributes { Length=Marshal.SizeOf(typeof(SecurityAttributes)), Inherit=true };
      IntPtr handle=CreateFile(path,access,3,ref security,creation,0x80,IntPtr.Zero);
      if(handle==Invalid) throw new Win32Exception(Marshal.GetLastWin32Error(),"Unable to open child log/input handle.");
      return handle;
    }
    private static void Close(IntPtr handle) { if(handle!=IntPtr.Zero && handle!=Invalid) CloseHandle(handle); }
    public static int Run(string executable,string arguments,string directory,string stdoutPath,string stderrPath) {
      IntPtr input=IntPtr.Zero,output=IntPtr.Zero,error=IntPtr.Zero,attributes=IntPtr.Zero,handles=IntPtr.Zero;
      bool initialized=false; var process=new ProcessInfo();
      try {
        input=Open("NUL",0x80000000,3);
        output=Open(stdoutPath,0x40000000,1); // CREATE_NEW: never follow/overwrite an existing log.
        error=Open(stderrPath,0x40000000,1);
        IntPtr bytes=IntPtr.Zero;
        InitializeProcThreadAttributeList(IntPtr.Zero,1,0,ref bytes);
        if(bytes==IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        attributes=Marshal.AllocHGlobal(bytes);
        if(!InitializeProcThreadAttributeList(attributes,1,0,ref bytes)) throw new Win32Exception(Marshal.GetLastWin32Error());
        initialized=true;
        handles=Marshal.AllocHGlobal(IntPtr.Size*3);
        Marshal.WriteIntPtr(handles,0,input); Marshal.WriteIntPtr(handles,IntPtr.Size,output); Marshal.WriteIntPtr(handles,IntPtr.Size*2,error);
        if(!UpdateProcThreadAttribute(attributes,0,new IntPtr(0x20002),handles,new IntPtr(IntPtr.Size*3),IntPtr.Zero,IntPtr.Zero))
          throw new Win32Exception(Marshal.GetLastWin32Error());
        var startup=new StartupInfoEx(); startup.Info.Size=Marshal.SizeOf(typeof(StartupInfoEx));
        startup.Info.Flags=0x100; startup.Info.Input=input; startup.Info.Output=output; startup.Info.Error=error;
        startup.Attributes=attributes;
        if(!CreateProcess(executable,new StringBuilder("\""+executable+"\" "+arguments),IntPtr.Zero,IntPtr.Zero,true,
            0x00080000|0x08000000,IntPtr.Zero,directory,ref startup,out process))
          throw new Win32Exception(Marshal.GetLastWin32Error(),"Unable to launch the installed backend.");
        // Native wait concerns this process handle only, never descendants or pipe EOF.
        if(WaitForSingleObject(process.Process,0xffffffff)!=0) throw new Win32Exception(Marshal.GetLastWin32Error());
        uint exitCode;
        if(!GetExitCodeProcess(process.Process,out exitCode)) throw new Win32Exception(Marshal.GetLastWin32Error());
        return unchecked((int)exitCode);
      } finally {
        Close(process.Thread); Close(process.Process);
        if(initialized) DeleteProcThreadAttributeList(attributes);
        if(attributes!=IntPtr.Zero) Marshal.FreeHGlobal(attributes);
        if(handles!=IntPtr.Zero) Marshal.FreeHGlobal(handles);
        Close(error); Close(output); Close(input);
      }
    }
  }
}
'@
  Add-Type -TypeDefinition $launcherSource -Language CSharp -ErrorAction Stop | Out-Null
}

function Read-StudioChildLog {
  param([Parameter(Mandatory = $true)][string]$FilePath)
  # A grandchild may still hold an inherited *file* handle. Reading its current
  # length is finite and does not require all writers to close the file.
  $stream = New-Object IO.FileStream($FilePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
  try {
    $snapshotLength = $stream.Length
    $maximumBytes = 16 * 1024 * 1024
    $readLength = [int][Math]::Min($snapshotLength, $maximumBytes)
    $bytes = New-Object byte[] $readLength
    $totalRead = 0
    while ($totalRead -lt $readLength) {
      $count = $stream.Read($bytes, $totalRead, $readLength - $totalRead)
      if ($count -eq 0) { break }
      $totalRead += $count
    }
    $decoded = (New-Object Text.UTF8Encoding($false, $false)).GetString($bytes, 0, $totalRead).TrimStart([char]0xFEFF)
    if ($snapshotLength -gt $maximumBytes) {
      $decoded += "`r`n[Studio: startup diagnostic snapshot truncated at 16 MiB; complete original log: $FilePath]`r`n"
    }
    return $decoded
  } finally { $stream.Dispose() }
}

function Invoke-StudioChild {
  param([Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Arguments)
  Initialize-StudioOperationLog
  Assert-DreamSkinNoReparseComponents -Path $ScriptPath
  if (-not [IO.File]::Exists($ScriptPath)) { throw 'The required installed backend is missing.' }
  $childExecutable = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
  # Windows PowerShell -File inherits the console's legacy code page. Establish
  # UTF-8 before invoking the installed script, including its error formatter.
  # Splat named parameters: quoted '-Switch' strings are positional in PS code.
  $parameterEntries = @()
  for ($argumentIndex = 0; $argumentIndex -lt $Arguments.Count; $argumentIndex++) {
    $argumentName = $Arguments[$argumentIndex]
    if ($argumentName -cin @('-PromptRestart', '-RestoreBaseTheme', '-LaunchTray')) {
      $parameterEntries += ("'" + $argumentName.Substring(1) + "' = `$true")
    } elseif ($argumentName -cin @('-ResultToken', '-SavedThemeDirectory')) {
      $argumentIndex++
      if ($argumentIndex -ge $Arguments.Count) { throw 'An internal backend parameter value is missing.' }
      $literalValue = "'" + $Arguments[$argumentIndex].Replace("'", "''") + "'"
      $parameterEntries += ("'" + $argumentName.Substring(1) + "' = " + $literalValue)
    } else { throw 'An unsupported internal backend parameter was rejected.' }
  }
  $scriptLiteral = "'" + $ScriptPath.Replace("'", "''") + "'"
  $childWrapper = '$ErrorActionPreference = ''Stop''; ' +
    '$studioChildEncoding = New-Object System.Text.UTF8Encoding($false); ' +
    '[Console]::OutputEncoding = $studioChildEncoding; $OutputEncoding = $studioChildEncoding; ' +
    '$global:LASTEXITCODE = 0; $studioChildParameters = @{' + ($parameterEntries -join '; ') + '}; ' +
    'try { & ' + $scriptLiteral + ' @studioChildParameters; ' +
    'if (-not $?) { if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }; exit 1 }; exit 0 } ' +
    'catch { [Console]::Error.WriteLine($_.Exception.ToString()); exit 1 }'
  $encodedWrapper = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childWrapper))
  $childArguments = @('-NoProfile', '-STA', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'RemoteSigned', '-EncodedCommand', $encodedWrapper)
  $childLogRoot = Join-Path $script:StudioStateRoot 'studio-child-logs'
  if (-not (Test-DreamSkinPathWithin -Path $childLogRoot -Root $script:StudioStateRoot)) { throw 'The child log directory is outside the local state root.' }
  Assert-DreamSkinNoReparseComponents -Path $childLogRoot
  $null = [IO.Directory]::CreateDirectory($childLogRoot)
  $childLogId = [guid]::NewGuid().ToString('N')
  $childStdoutPath = Join-Path $childLogRoot ($childLogId + '.stdout.log')
  $childStderrPath = Join-Path $childLogRoot ($childLogId + '.stderr.log')
  foreach ($logFile in @($childStdoutPath, $childStderrPath)) {
    if (-not (Test-DreamSkinPathWithin -Path $logFile -Root $script:StudioStateRoot)) { throw 'The child log path is outside the local state root.' }
    Assert-DreamSkinNoReparseComponents -Path $logFile
  }
  Initialize-StudioChildLauncher
  $childExitCode = [DreamSkinStudio.NativeChildLauncher]::Run($childExecutable,
    (ConvertTo-DreamSkinArgumentLine -Arguments $childArguments), $script:StudioScriptsRoot,
    $childStdoutPath, $childStderrPath)
  $childStdout = Read-StudioChildLog -FilePath $childStdoutPath
  $childStderr = Read-StudioChildLog -FilePath $childStderrPath
  [IO.File]::AppendAllText($script:StudioRequestLog,
    $childStdout + "`r`n" + $childStderr + "`r`n", $script:StudioUtf8)
  return [pscustomobject]@{ exitCode = [int]$childExitCode; logPath = $script:StudioRequestLog;
    stdoutPath = $childStdoutPath; stderrPath = $childStderrPath }
}

function Get-StudioRendererVisibility {
  param([AllowEmptyCollection()][object[]]$Output)
  try {
    $payload = ($Output -join "`n") | ConvertFrom-Json -ErrorAction Stop
    $targets = @($payload.targets)
    if ($targets.Count -eq 0) { return 'unknown' }
    $visibleCount = 0
    $hiddenCount = 0
    foreach ($target in $targets) {
      $result = $target.result
      if ($result.documentVisibility -ceq 'visible' -and
          $result.documentHidden -is [bool] -and -not $result.documentHidden -and
          $result.readiness.documentPass -is [bool] -and $result.readiness.documentPass -and
          $result.readiness.viewportPass -is [bool] -and $result.readiness.viewportPass) {
        $visibleCount++
      } elseif ($result.documentVisibility -ceq 'hidden' -and
          $result.documentHidden -is [bool] -and $result.documentHidden -and
          $result.readiness.documentPass -is [bool] -and -not $result.readiness.documentPass) {
        $hiddenCount++
      }
    }
    if ($visibleCount -eq $targets.Count) { return 'visible' }
    if ($hiddenCount -eq $targets.Count) { return 'hidden' }
    if ($visibleCount -gt 0 -and $hiddenCount -gt 0) { return 'mixed' }
  } catch { }
  return 'unknown'
}

function Stop-StudioApplyDeferred {
  param([string]$Category, [string]$Message, [int]$Port)
  $script:StudioFailureData = [pscustomobject]@{
    category = $Category; deferred = $true; verified = $false
    existingSessionPreserved = $true; preflight = $true; port = $Port
    logPath = $script:StudioRequestLog
  }
  throw $Message
}

function Show-StudioCodexWindow {
  param([int]$Port, [Parameter(Mandatory=$true)]$Codex)
  $owners = @(Get-DreamSkinPortListeners -Port $Port | Select-Object -ExpandProperty OwningProcess -Unique)
  if ($owners.Count -ne 1) { throw '未找到唯一的壁纸窗口连接，请刷新后重试。' }
  $process = Get-Process -Id $owners[0] -ErrorAction Stop
  try {
    if (-not (Test-DreamSkinPathEqual -Left $process.Path -Right $Codex.Executable)) { throw '壁纸连接所属程序已变化，请重试。' }
    if (-not ('DreamSkinStudio.WindowFocus' -as [type])) {
      Add-Type -Namespace DreamSkinStudio -Name WindowFocus -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool IsIconic(IntPtr window);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr window, int command);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint owner);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
private delegate bool WindowCallback(IntPtr window, IntPtr data);
[System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool EnumWindows(WindowCallback visit, IntPtr data);
[System.Runtime.InteropServices.DllImport("user32.dll")] private static extern IntPtr GetWindow(IntPtr window, uint command);
[System.Runtime.InteropServices.DllImport("user32.dll",CharSet=System.Runtime.InteropServices.CharSet.Unicode)] private static extern int GetClassName(IntPtr window,System.Text.StringBuilder text,int size);
[System.Runtime.InteropServices.DllImport("user32.dll",CharSet=System.Runtime.InteropServices.CharSet.Unicode)] private static extern int GetWindowText(IntPtr window,System.Text.StringBuilder text,int size);
[System.Runtime.InteropServices.DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(IntPtr window,int attribute,out int value,int size);

public static bool IsMainFrame(IntPtr window, uint pid) {
    uint owner; int cloaked;
    if (window == IntPtr.Zero || GetWindowThreadProcessId(window, out owner) == 0 || owner != pid ||
        GetWindow(window, 4) != IntPtr.Zero ||
        DwmGetWindowAttribute(window, 14, out cloaked, 4) != 0 || cloaked != 0) return false;
    var cls = new System.Text.StringBuilder(64);
    GetClassName(window, cls, cls.Capacity);
    if (cls.ToString() != "Chrome_WidgetWin_1") return false;
    var title = new System.Text.StringBuilder(256);
    return GetWindowText(window, title, title.Capacity) > 0;
}

public static IntPtr FindFrame(uint pid, IntPtr preferred) {
    IntPtr foreground = GetForegroundWindow();
    if (IsMainFrame(foreground, pid)) return foreground;
    if (IsMainFrame(preferred, pid)) return preferred;
    // MainWindowHandle omits windows hidden by closing to the tray.
    // Exclude helpers with an empty title, and avoid guessing between hidden windows.
    var matches = new System.Collections.Generic.List<IntPtr>();
    EnumWindows(delegate(IntPtr h, IntPtr unused) {
        if (IsMainFrame(h, pid)) matches.Add(h);
        return true;
    }, IntPtr.Zero);
    return matches.Count == 1 ? matches[0] : IntPtr.Zero;
}
'@
    }
    $window = [DreamSkinStudio.WindowFocus]::FindFrame($process.Id, $process.MainWindowHandle)
    if (-not [DreamSkinStudio.WindowFocus]::IsMainFrame($window, $process.Id)) { return $false }
    if ([DreamSkinStudio.WindowFocus]::IsIconic($window)) {
      [void][DreamSkinStudio.WindowFocus]::ShowWindowAsync($window, 9) # SW_RESTORE
    } elseif (-not [DreamSkinStudio.WindowFocus]::IsWindowVisible($window)) {
      [void][DreamSkinStudio.WindowFocus]::ShowWindowAsync($window, 5) # SW_SHOW keeps its current size
    }
    for ($i = 0; $i -lt 15; $i++) {
      if ([DreamSkinStudio.WindowFocus]::IsWindowVisible($window) -and -not [DreamSkinStudio.WindowFocus]::IsIconic($window)) { break }
      Start-Sleep -Milliseconds 80
    }
    if (-not [DreamSkinStudio.WindowFocus]::IsMainFrame($window, $process.Id)) { return $false }
    [void][DreamSkinStudio.WindowFocus]::SetForegroundWindow($window)
    for ($i = 0; $i -lt 8; $i++) {
      if ([DreamSkinStudio.WindowFocus]::GetForegroundWindow() -eq $window -and [DreamSkinStudio.WindowFocus]::IsWindowVisible($window) -and -not [DreamSkinStudio.WindowFocus]::IsIconic($window)) { return $true }
      Start-Sleep -Milliseconds 70
    }
    return $false
  } finally { $process.Dispose() }
}

function Request-StudioSessionWindow {
  param([int]$Port, $Codex, [string]$BrowserId, $State)
  if ($null -eq $State -or $State.browserId -cne $BrowserId) { return $false }
  $profile = Join-Path $script:StudioStateRoot 'cdp-profile'
  if (-not (Test-DreamSkinPathEqual -Left $State.profilePath -Right $profile) -or
      -not (Test-DreamSkinPathEqual -Left $State.codexExe -Right $Codex.Executable)) { return $false }
  Assert-DreamSkinNoReparseComponents -Path $profile
  if (-not [IO.Directory]::Exists($profile)) { return $false }
  $current = Get-DreamSkinCodexInstall
  if (-not (Test-DreamSkinPathEqual -Left $current.Executable -Right $Codex.Executable)) { return $false }
  $owners = @(Get-DreamSkinPortListeners -Port $Port | Select-Object -ExpandProperty OwningProcess -Unique)
  if ($owners.Count -ne 1) { return $false }
  $owner = Get-CimInstance Win32_Process -Filter ("ProcessId = " + [int]$owners[0])
  $ownerPath = if ($owner) { Get-DreamSkinProcessExecutablePath -ProcessInfo $owner }
  $profileFlag = '--user-data-dir=' + $profile
  if (-not $ownerPath -or -not (Test-DreamSkinPathEqual -Left $ownerPath -Right $Codex.Executable) -or
      -not (Test-DreamSkinCommandLineToken -CommandLine $owner.CommandLine -Token $profileFlag)) { return $false }
  $identity = Get-DreamSkinVerifiedCdpIdentity -Port $Port -Codex $Codex
  if ($null -eq $identity -or $identity.BrowserId -cne $BrowserId) { return $false }
  # Let Codex's own single-instance handler restore its hidden renderer.
  [void](Start-DreamSkinCodex -Codex $Codex -Arguments @($profileFlag))
  return $true
}

function Open-StudioCodex {
  $running = Get-StudioRunning
  if ($running.portListening -and $running.injectorAlive -and -not (Test-DreamSkinPaused -StateRoot $script:StudioStateRoot)) {
    $ready = Assert-StudioApplyForeground -RequireFocus
    return [pscustomobject]@{ reused = $true; focused = $true; port = $ready.port; windowRecovery = $ready.windowRecovery }
  }
  return Invoke-StudioApply
}

function Assert-StudioApplyForeground {
  param([switch]$RequireFocus)
  # start-dream-skin replaces the recorded watcher before final verification.
  # Inspect a validated existing renderer first, while the old watcher is intact.
  # No --once/--reload, CDP evaluate string, pause flag or theme/state write here.
  Initialize-StudioOperationLog
  $portNumber = 9335
  $state = Read-StudioJson -FilePath (Join-Path $script:StudioStateRoot 'state.json') -MaximumBytes 131072
  if ($null -ne $state -and $state.port) {
    if (-not [int]::TryParse([string]$state.port, [ref]$portNumber)) {
      throw '当前连接端口记录无效，未开始应用，也未停止现有背景。'
    }
  }
  Assert-DreamSkinPort -Port $portNumber
  $codex = Get-DreamSkinCodexInstall
  $identity = Get-DreamSkinVerifiedCdpIdentity -Port $portNumber -Codex $codex
  if ($null -eq $identity) {
    $registered = Get-DreamSkinVerifiedCdpIdentityForAnyRegistered -Port $portNumber
    if ($null -ne $registered) { $codex = $registered.Codex; $identity = $registered.Identity }
  }
  if ($null -eq $identity) {
    if ($RequireFocus -or -not (Test-DreamSkinPortAvailable -Port $portNumber)) {
      Stop-StudioApplyDeferred -Category 'unverified-cdp-endpoint' -Port $portNumber -Message `
        '无法安全确认当前 Codex 连接，已暂缓应用并保留原会话。请先检查连接状态；没有停止现有背景。'
    }
    # No existing debug listener: let the original engine perform its normal
    # first launch / explicit restart confirmation and full renderer verification.
    return [pscustomobject]@{ visibility = 'no-existing-cdp'; port = $portNumber }
  }
  $node = Get-DreamSkinNodeRuntime
  $injector = Join-Path $script:StudioScriptsRoot 'injector.mjs'
  Assert-DreamSkinNoReparseComponents -Path $injector
  if (-not [IO.File]::Exists($injector)) { throw '找不到原引擎的只读显示验证器，未开始应用。' }
  $verifyThemeDirectory = Join-Path $script:StudioStateRoot 'active-theme'
  if (-not [IO.File]::Exists((Join-Path $verifyThemeDirectory 'theme.json'))) {
    $verifyThemeDirectory = Join-Path $script:StudioEngineRoot 'assets'
  }
  if ($null -ne $state -and $state.browserId -and $state.browserId -cne $identity.BrowserId) {
    Stop-StudioApplyDeferred -Category 'cdp-session-changed' -Port $portNumber -Message 'Codex 会话已变化。请刷新管理器后重试。'
  }
  $focused = Show-StudioCodexWindow -Port $portNumber -Codex $codex
  $visibility = 'unknown'
  $recoveryAttempted = $false
  $recoveryRequested = $false
  for ($attempt = 0; $attempt -lt 3; $attempt++) {
    $currentIdentity = Get-DreamSkinVerifiedCdpIdentity -Port $portNumber -Codex $codex
    if ($null -eq $currentIdentity -or $currentIdentity.BrowserId -cne $identity.BrowserId) {
      Stop-StudioApplyDeferred -Category 'cdp-session-changed' -Port $portNumber -Message `
        'Codex 连接已变化，已暂缓应用并保留原会话。请刷新状态后重试。'
    }
    $probe = Invoke-DreamSkinNative -FilePath $node.Path -ArgumentList @(
      $injector, '--verify', '--port', [string]$portNumber,
      '--browser-id', $identity.BrowserId, '--theme-dir', $verifyThemeDirectory,
      '--timeout-ms', '1500') -DiscardStderr
    # ExitCode may be nonzero when the skin is absent/stale. This preflight
    # requires visible-renderer evidence only, not a falsely successful Apply.
    $visibility = Get-StudioRendererVisibility -Output $probe.Output
    if ($visibility -ceq 'visible' -and (-not $RequireFocus -or $focused)) {
      return [pscustomobject]@{ visibility = 'visible'; port = $portNumber; browserId = $identity.BrowserId; windowRecovery = $recoveryRequested }
    }
    if ($attempt -lt 2 -and -not $recoveryAttempted -and ($visibility -in @('hidden','mixed') -or -not $focused)) {
      $recoveryAttempted = $true
      try { $recoveryRequested = Request-StudioSessionWindow -Port $portNumber -Codex $codex -BrowserId $identity.BrowserId -State $state }
      catch { [IO.File]::AppendAllText($script:StudioRequestLog, "Window activation: " + $_.Exception.Message + [Environment]::NewLine, $script:StudioUtf8) }
      if ($recoveryRequested) { Start-Sleep -Milliseconds 600 }
    }
    if ($attempt -lt 2) { $focused = Show-StudioCodexWindow -Port $portNumber -Codex $codex }
    if ($attempt -lt 2) { Start-Sleep -Milliseconds 250 }
  }
  if ($visibility -ceq 'hidden') {
    Stop-StudioApplyDeferred -Category 'renderer-verification-deferred-hidden' -Port $portNumber -Message `
      '未能唤回壁纸版 Codex 的主窗口。请从系统托盘打开壁纸版窗口，再试一次。'
  }
  if ($visibility -ceq 'mixed') {
    Stop-StudioApplyDeferred -Category 'renderer-windows-mixed' -Port $portNumber -Message '壁纸版 Codex 还有另一个未显示的窗口。请先回到主窗口，再关闭单独打开的聊天窗口后重试。'
  }
  Stop-StudioApplyDeferred -Category 'renderer-visibility-unconfirmed' -Port $portNumber -Message `
    '暂时无法确认 Codex 的前台画面，已暂缓应用并保留原会话。请切到 Codex、确认窗口可见后重试。'
}

function Invoke-StudioApply {
  param([AllowNull()][string]$SavedThemeDirectory)
  $foregroundPreflight = Assert-StudioApplyForeground
  $resultToken = [guid]::NewGuid().ToString('N')
  $arguments = @('-PromptRestart', '-ResultToken', $resultToken)
  if ($SavedThemeDirectory) { $arguments += @('-SavedThemeDirectory', $SavedThemeDirectory) }
  $childResult = Invoke-StudioChild -ScriptPath (Join-Path $script:StudioScriptsRoot 'start-dream-skin.ps1') -Arguments $arguments
  $startResult = $null
  try { $startResult = Read-DreamSkinStartResult -StateRoot $script:StudioStateRoot -Token $resultToken }
  catch { } # Missing/invalid results remain failures; keep exit code and log visible.
  if ($childResult.exitCode -ne 0 -or $null -eq $startResult -or
      $startResult.outcome -cne 'success' -or $startResult.category -cne 'none') {
    $category = if ($null -ne $startResult -and $startResult.category -cne 'none') {
      [string]$startResult.category
    } elseif ($childResult.exitCode -ne 0) { 'process-exit-' + $childResult.exitCode }
    else { 'cancelled-or-unverified' }
    $script:StudioFailureData = [pscustomobject]@{ exitCode = $childResult.exitCode;
      category = $category; logPath = $childResult.logPath }
    throw ('The theme was not verified (' + $category + '). See ' + $childResult.logPath)
  }
  return [pscustomobject]@{ verified = $true; result = $startResult; status = Get-StudioStatus;
    preflight = $foregroundPreflight; logPath = $childResult.logPath }
}

function Set-StudioReveal {
  param([Parameter(Mandatory = $true)][double]$Value)
  if ([double]::IsNaN($Value) -or [double]::IsInfinity($Value) -or $Value -lt 0 -or $Value -gt 100) {
    throw 'Percent must be between 0 and 100.'
  }
  $active = Get-StudioActive
  if ($null -eq $active) { throw 'There is no active theme.' }
  $themePath = Join-Path $active.Directory 'theme.json'
  $themeBefore = [IO.File]::ReadAllBytes($themePath)
  $preferenceBefore = if ([IO.File]::Exists($script:StudioPreferencePath)) { [IO.File]::ReadAllBytes($script:StudioPreferencePath) } else { $null }
  $preferences = Read-StudioPreferences
  Set-StudioPreferenceValue -Preferences $preferences -Id ([string]$active.Theme.id) -Value $Value
  $theme = $active.Theme | ConvertTo-Json -Depth 24 | ConvertFrom-Json
  if ($null -eq $theme.media) {
    $theme | Add-Member -NotePropertyName media -NotePropertyValue ([pscustomobject]@{ type = $active.MediaType; playbackRate = 1 })
  }
  $theme.media | Add-Member -NotePropertyName opacity -NotePropertyValue ([double]($Value / 100)) -Force
  $preferenceText = ($preferences | ConvertTo-Json -Depth 24) + "`n"
  $themeText = ($theme | ConvertTo-Json -Depth 24) + "`n"
  $preferenceAppliedBytes = $script:StudioUtf8.GetBytes($preferenceText)
  $preferenceWritten = $false
  try {
    Write-DreamSkinUtf8FileAtomically -Path $script:StudioPreferencePath -Content $preferenceText -ExpectedBytes $preferenceBefore
    $preferenceWritten = $true
    Write-DreamSkinUtf8FileAtomically -Path $themePath -Content $themeText -ExpectedBytes $themeBefore
  } catch {
    $writeFailure = $_
    if ($preferenceWritten) {
      try {
        if ($null -ne $preferenceBefore) {
          Write-DreamSkinBytesAtomically -Path $script:StudioPreferencePath -Bytes $preferenceBefore -ExpectedBytes $preferenceAppliedBytes
        } elseif (Test-DreamSkinBytesEqual -Left ([IO.File]::ReadAllBytes($script:StudioPreferencePath)) -Right $preferenceAppliedBytes) {
          [IO.File]::Delete($script:StudioPreferencePath)
        }
      } catch { throw 'The reveal update failed and preference rollback was blocked by a newer edit. Refresh before retrying.' }
    }
    throw $writeFailure
  }
  return [pscustomobject]@{ percent = $Value; status = Get-StudioStatus; appliesLiveWhenWatcherRunning = $true }
}

try {
  if ($PSVersionTable.PSEdition -ne 'Desktop') { throw 'Use Windows PowerShell 5.1 for this bridge.' }
  # Repair PowerShell 7-inherited module search paths for this process and children.
  $nativeModuleRoot = Join-Path $PSHOME 'Modules'
  $env:PSModulePath = $nativeModuleRoot + ';' + (Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules')
  foreach ($moduleName in @('Microsoft.PowerShell.Utility', 'Microsoft.PowerShell.Management', 'Microsoft.PowerShell.Security')) {
    Import-Module (Join-Path $nativeModuleRoot ($moduleName + '\' + $moduleName + '.psd1')) -ErrorAction Stop
  }
  $commonFile = Join-Path $script:StudioScriptsRoot 'common-windows.ps1'
  $themeFile = Join-Path $script:StudioScriptsRoot 'theme-windows.ps1'
  if (-not [IO.File]::Exists($commonFile) -or -not [IO.File]::Exists($themeFile)) {
    throw 'The installed Codex Dynamic Skin backend was not found.'
  }
  . $commonFile
  . $themeFile
  $data = switch ($Action) {
    'Status' { Get-StudioStatus; break }
    'OpenCodex' {
      $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
      $guard = New-Object Threading.Mutex($false, ("Local\CodexDreamSkin." + $sid + ".OpenCodex"))
      $held = $false
      try {
        try { $held = $guard.WaitOne(0) } catch [Threading.AbandonedMutexException] { $held = $true }
        if ($held) { Open-StudioCodex }
        else { [pscustomobject]@{ opening = $true } }
      } finally {
        if ($held) { $guard.ReleaseMutex() }
        $guard.Dispose()
      }
      break
    }
    'GetColors' { Get-StudioColors; break }
    'SetColors' {
      $colorUpdates = @{}
      foreach ($binding in @(@('Accent', 'accent'), @('Background', 'background'), @('Panel', 'panel'), @('Text', 'text'))) {
        if ($PSBoundParameters.ContainsKey($binding[0])) { $colorUpdates[$binding[1]] = $PSBoundParameters[$binding[0]] }
      }
      Invoke-StudioLocked { Set-StudioThemeColors -Updates $colorUpdates }
      break
    }
    'ResetColors' {
      Invoke-StudioLocked { Set-StudioThemeColors -Updates @{} -Reset }
      break
    }
    'ListThemes' { [pscustomobject]@{ themes = @(Get-StudioThemeList) }; break }
    'RenameTheme' {
      Invoke-StudioLocked { Rename-StudioSavedTheme -Id $ThemeId -NewName $Name }
      break
    }
    'RecycleTheme' {
      Invoke-StudioLocked { Move-StudioSavedThemeToRecycleBin -Id $ThemeId }
      break
    }
    'SetWallpaper' {
      if (-not $Path -or -not [IO.Path]::IsPathRooted($Path)) { throw 'SetWallpaper requires an absolute local -Path.' }
      Invoke-StudioLocked {
        $loaded = Set-DreamSkinActiveThemeImage -ImagePath ([IO.Path]::GetFullPath($Path)) -StateRoot $script:StudioStateRoot
        [pscustomobject]@{ active = Get-StudioThemeResult -LoadedTheme $loaded -Preferences (Read-StudioPreferences); requiresApply = $true }
      }
      break
    }
    'SetReveal' {
      $numericPercent = 0.0
      if (-not [double]::TryParse($Percent, [Globalization.NumberStyles]::Float,
          [Globalization.CultureInfo]::InvariantCulture, [ref]$numericPercent)) { throw 'SetReveal requires a numeric -Percent.' }
      Invoke-StudioLocked { Set-StudioReveal -Value $numericPercent }
      break
    }
    'ApplyTheme' {
      if (-not $ThemeId) { throw 'ApplyTheme requires -ThemeId.' }
      $item = Get-StudioSavedTheme -Id $ThemeId
      $saved = Read-DreamSkinTheme -ThemeDirectory $item.path -SkipImageMetadata
      if ([string]$saved.Theme.id -cne $ThemeId) { throw 'The saved theme identity changed. Refresh the library.' }
      Invoke-StudioApply -SavedThemeDirectory $item.path
      break
    }
    'Apply' { Invoke-StudioApply; break }
    'Resume' { Invoke-StudioApply; break }
    'Pause' {
      Invoke-StudioLocked {
        $null = Set-DreamSkinPaused -Paused $true -StateRoot $script:StudioStateRoot
        try {
          $removal = Invoke-DreamSkinLiveRemove -StateRoot $script:StudioStateRoot
          if (-not $removal.Removed) { throw ('Live removal was not verified. ' + $removal.Message) }
        } catch {
          $script:StudioFailureData = [pscustomobject]@{
            paused = [bool](Test-DreamSkinPaused -StateRoot $script:StudioStateRoot)
            liveRemoved = $false
            requiresRefresh = $true
            logPath = $script:StudioRequestLog
          }
          throw ('Pause was recorded, but the current window was not confirmed cleared. ' + $_.Exception.Message)
        }
        [pscustomobject]@{ paused = $true; liveRemoved = $true; status = Get-StudioStatus }
      }
      break
    }
    'ImportTheme' {
      if (-not $Path -or -not [IO.Path]::IsPathRooted($Path)) { throw 'ImportTheme requires an absolute ZIP -Path.' }
      Invoke-StudioLocked {
        $imported = Import-DreamSkinThemeZip -ArchivePath $Path -StateRoot $script:StudioStateRoot
        [pscustomobject]@{ id = [string]$imported.Id; name = [string]$imported.Name;
          path = [string]$imported.Path; safeCssStatus = [string]$imported.SafeCssStatus; switched = $false }
      }
      break
    }
    'SaveTheme' {
      if (-not $Name) { throw 'SaveTheme requires -Name.' }
      Invoke-StudioLocked {
        $active = Get-StudioActive
        if ($null -eq $active) { throw 'There is no active theme.' }
        $preferences = Read-StudioPreferences
        $sourceValue = Get-StudioTransparency -Id ([string]$active.Theme.id) -Preferences $preferences
        $saved = Save-DreamSkinCurrentTheme -Name $Name -StateRoot $script:StudioStateRoot
        if ($null -ne $sourceValue) {
          $before = if ([IO.File]::Exists($script:StudioPreferencePath)) { [IO.File]::ReadAllBytes($script:StudioPreferencePath) } else { $null }
          Set-StudioPreferenceValue -Preferences $preferences -Id ([string]$saved.Theme.id) -Value $sourceValue
          Write-DreamSkinUtf8FileAtomically -Path $script:StudioPreferencePath `
            -Content (($preferences | ConvertTo-Json -Depth 24) + "`n") -ExpectedBytes $before
        }
        Get-StudioThemeResult -LoadedTheme $saved -Preferences $preferences
      }
      break
    }
    'Restore' {
      $restoreBackupPath = Join-Path $script:StudioStateRoot 'config.before-dream-skin.toml'
      $hadRestoreBackup = [IO.File]::Exists($restoreBackupPath)
      $priorRunning = Get-StudioRunning
      $restoration = Invoke-StudioChild -ScriptPath (Join-Path $script:StudioScriptsRoot 'restore-dream-skin.ps1') `
        -Arguments @('-RestoreBaseTheme', '-PromptRestart')
      if ($restoration.exitCode -ne 0) { throw ('Restore failed. See ' + $restoration.logPath) }
      # The original script returns 0 on user cancellation, too. Confirm the
      # managed state and its listener have actually gone before reporting success.
      $running = Get-StudioRunning
      $priorPortStillListening = @([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() |
        Where-Object { $_.Port -eq $priorRunning.port -and [Net.IPAddress]::IsLoopback($_.Address) }).Count -gt 0
      if ([IO.File]::Exists((Join-Path $script:StudioStateRoot 'state.json')) -or $running.portListening -or
          $priorPortStillListening -or ($hadRestoreBackup -and [IO.File]::Exists($restoreBackupPath))) {
        throw 'Restore was cancelled or remains incomplete; the managed session is still present.'
      }
      [pscustomobject]@{ restored = $true; status = Get-StudioStatus; logPath = $restoration.logPath }
      break
    }
    'StartTray' {
      $bootstrapPath = Join-Path $env:LOCALAPPDATA 'Programs\CodexDreamSkin\setup-bootstrap.ps1'
      $trayResult = Invoke-StudioChild -ScriptPath $bootstrapPath -Arguments @('-LaunchTray')
      if ($trayResult.exitCode -ne 0) { throw ('The installed tray could not be started. See ' + $trayResult.logPath) }
      [pscustomobject]@{ requested = $true; logPath = $trayResult.logPath;
        note = 'Only the installed tray was requested; no Codex restart or skin application was requested.' }
      break
    }
    'SetAutoStart' {
      $enableValue = switch ($Enabled.ToLowerInvariant()) {
        'true' { $true } 'false' { $false }
        default { throw 'SetAutoStart requires -Enabled true or false.' }
      }
      Invoke-StudioLocked {
        Assert-DreamSkinNoReparseComponents -Path $script:StudioAutoStartPath
        if ($enableValue) {
          if (-not $Path -or -not [IO.Path]::IsPathRooted($Path) -or
              [IO.Path]::GetExtension($Path) -ine '.exe' -or -not [IO.File]::Exists($Path)) {
            throw 'An existing absolute GUI executable -Path is required.'
          }
          $guiPath = [IO.Path]::GetFullPath($Path)
          Assert-DreamSkinNoReparseComponents -Path $guiPath
          $shellObject = New-Object -ComObject WScript.Shell
          $shortcut = $null
          try {
            $shortcut = $shellObject.CreateShortcut($script:StudioAutoStartPath)
            $shortcut.TargetPath = $guiPath
            $shortcut.WorkingDirectory = [IO.Path]::GetDirectoryName($guiPath)
            $shortcut.Description = 'Start DreamSkin Studio at sign-in; does not automatically restart Codex.'
            $shortcut.Save()
          } finally {
            if ($null -ne $shortcut) { $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shortcut) }
            $null = [Runtime.InteropServices.Marshal]::FinalReleaseComObject($shellObject)
          }
        } elseif ([IO.File]::Exists($script:StudioAutoStartPath)) {
          [IO.File]::Delete($script:StudioAutoStartPath)
        }
        [pscustomobject]@{ autoStart = [bool]$enableValue; scope = 'Starts only DreamSkin Studio at sign-in; no automatic Codex restart.' }
      }
      break
    }
    'Diagnostics' {
      $diagnosticLogs = @()
      foreach ($leaf in @('injector-error.log', 'injector.log', 'verify.log')) {
        $logFile = Join-Path $script:StudioStateRoot $leaf
        Assert-DreamSkinNoReparseComponents -Path $logFile
        $diagnosticLogs += [pscustomobject]@{ name = $leaf; path = $logFile;
          tail = if ([IO.File]::Exists($logFile)) { (Get-Content -LiteralPath $logFile -Tail 30 -Encoding UTF8) -join "`n" } else { '' } }
      }
      [pscustomobject]@{ status = Get-StudioStatus; logs = $diagnosticLogs;
        note = 'Listener and injector checks are approximate; use Apply for upstream visible-renderer verification.' }
      break
    }
    default { throw 'Unsupported bridge action.' }
  }
  [Console]::Out.WriteLine((([ordered]@{ ok = $true; data = $data; error = $null }) | ConvertTo-Json -Depth 24 -Compress))
  exit 0
} catch {
  $failureText = [string]$_.Exception.Message
  if ($null -ne $script:StudioRequestLog) {
    try { [IO.File]::AppendAllText($script:StudioRequestLog, $failureText + "`r`n" + $_.ScriptStackTrace + "`r`n", $script:StudioUtf8) } catch { }
  }
  [Console]::Out.WriteLine((([ordered]@{ ok = $false; data = $script:StudioFailureData; error = $failureText }) | ConvertTo-Json -Depth 8 -Compress))
  exit 1
}
