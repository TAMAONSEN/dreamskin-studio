[CmdletBinding()]
param(
  [string]$Action = 'Status',
  [ValidateSet('true', 'false')][string]$Enabled,
  [string]$MonitorId,
  [string]$Path,
  [string]$Name,
  [string]$ExpectedWorkshopId,
  [string]$ExpectedSceneFingerprint,
  [ValidateSet('true', 'false')][string]$Automatic = 'false',
  [string]$WallpaperEngineRoot = 'G:\steam\steamapps\common\wallpaper_engine'
)

# Reads saved Wallpaper Engine configuration only. No WE command, window,
# desktop capture, recording, Codex launcher, or background service is invoked.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'
$script:LinkUtf8 = New-Object Text.UTF8Encoding($false, $true)
[Console]::OutputEncoding = $script:LinkUtf8
$OutputEncoding = $script:LinkUtf8
$script:LinkState = Join-Path $env:LOCALAPPDATA 'CodexDreamSkin'
$script:LinkPrefs = Join-Path $script:LinkState 'studio-wallpaper-link.json'
$script:LinkTransparency = Join-Path $script:LinkState 'theme-preferences.json'
$script:LinkRecordings = Join-Path $script:LinkState 'studio-wallpaper-recordings.json'
$script:LinkScripts = Join-Path $script:LinkState 'engine\scripts'
$script:LinkConfig = Join-Path ([IO.Path]::GetFullPath($WallpaperEngineRoot)) 'config.json'
$script:LinkFailureData = $null

function Read-LinkObject {
  param([string]$FilePath, [int]$MaxBytes = 2097152)
  Assert-DreamSkinNoReparseComponents -Path $FilePath
  if (-not [IO.File]::Exists($FilePath)) { return $null }
  $stream = New-Object IO.FileStream($FilePath, [IO.FileMode]::Open, [IO.FileAccess]::Read,
    ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
  try {
    if ($stream.Length -gt $MaxBytes) { throw 'The local JSON file exceeds its size limit.' }
    $reader = New-Object IO.StreamReader($stream, $script:LinkUtf8, $true)
    try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
  } finally { $stream.Dispose() }
  if ($script:LinkUtf8.GetByteCount($text) -gt $MaxBytes) { throw 'The local JSON file exceeds its size limit.' }
  $object = $text | ConvertFrom-Json -ErrorAction Stop
  if ($null -eq $object -or $object -isnot [pscustomobject]) { throw 'Expected a JSON object.' }
  return $object
}

function Read-LinkPreferences {
  $prefs = Read-LinkObject -FilePath $script:LinkPrefs -MaxBytes 65536
  if ($null -eq $prefs) { return [pscustomobject]@{ schemaVersion = 1; enabled = $false; monitorId = ''; lastSync = $null } }
  if ($prefs.schemaVersion -ne 1 -or $prefs.enabled -isnot [bool] -or $prefs.monitorId -isnot [string]) {
    throw 'The saved Wallpaper Engine link preferences are invalid.'
  }
  return $prefs
}

function Write-LinkObject {
  param([string]$FilePath, [object]$Object, [AllowNull()][byte[]]$Before)
  Write-DreamSkinUtf8FileAtomically -Path $FilePath -Content (($Object | ConvertTo-Json -Depth 24) + "`n") -ExpectedBytes $Before
}

function Get-LinkKey {
  param([string]$Value)
  $hasher = [Security.Cryptography.SHA256]::Create()
  try { return [BitConverter]::ToString($hasher.ComputeHash($script:LinkUtf8.GetBytes($Value))).Replace('-', '').ToLowerInvariant() }
  finally { $hasher.Dispose() }
}

function Get-LinkAccent {
  param([object]$Project)
  $value = $Project.general.properties.schemecolor.value
  if ($null -eq $value) { $value = $Project.general.schemecolor }
  $components = @(([string]$value).Trim() -split '\s+')
  if ($components.Count -eq 3) {
    $channels = @()
    foreach ($component in $components) {
      $number = 0.0
      if (-not [double]::TryParse($component, [Globalization.NumberStyles]::Float,
          [Globalization.CultureInfo]::InvariantCulture, [ref]$number) -or
          [double]::IsNaN($number) -or [double]::IsInfinity($number) -or $number -lt 0 -or $number -gt 1) {
        return '#76C9EA'
      }
      $channels += [int][math]::Round($number * 255)
    }
    return ('#{0:X2}{1:X2}{2:X2}' -f $channels[0], $channels[1], $channels[2])
  }
  return '#76C9EA'
}

function Read-LinkRecordings {
  $mappings = Read-LinkObject -FilePath $script:LinkRecordings -MaxBytes 1048576
  if ($null -eq $mappings) { return [pscustomobject]@{ schemaVersion = 1; recordings = [pscustomobject]@{} } }
  if ($mappings.schemaVersion -ne 1 -or $mappings.recordings -isnot [pscustomobject]) {
    throw 'The recorded wallpaper mapping schema is invalid.'
  }
  return $mappings
}

function Get-LinkSceneFingerprint {
  param([string]$ScenePath)
  Assert-DreamSkinNoReparseComponents -Path $ScenePath
  $info = New-Object IO.FileInfo($ScenePath)
  if (-not $info.Exists) { throw 'The scene package is missing.' }
  return Get-LinkKey -Value ($info.FullName.ToLowerInvariant() + '|' + $info.Length + '|' + $info.LastWriteTimeUtc.Ticks)
}

function Get-LinkMappedTheme {
  param([string]$Id)
  if ($Id -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$' -or
      (Test-DreamSkinWindowsReservedPathStem -Name $Id) -or $Id.EndsWith('.')) {
    throw 'A recorded theme ID is invalid.'
  }
  $directory = Join-Path $script:LinkState ('themes\' + $Id)
  Assert-DreamSkinNoReparseComponents -Path $directory
  $recorded = Read-DreamSkinTheme -ThemeDirectory $directory -SkipImageMetadata
  if ($recorded.Theme.id -cne $Id -or $recorded.MediaType -cne 'video') { throw 'The recorded theme identity or media type is invalid.' }
  Assert-DreamSkinNoReparseComponents -Path $recorded.MediaPath
  if (-not (Test-DreamSkinThemePathWithin -Path $recorded.MediaPath -Root $directory)) {
    throw 'Recorded media must remain inside its saved theme directory.'
  }
  return $recorded
}

function Get-LinkEntries {
  $config = Read-LinkObject -FilePath $script:LinkConfig
  if ($null -eq $config) { return @() }
  $recordings = Read-LinkRecordings
  $profiles = @($config.PSObject.Properties | Where-Object {
    $null -ne $_.Value -and $null -ne $_.Value.general -and
    $null -ne $_.Value.general.wallpaperconfig.selectedwallpapers
  })
  $ownProfile = @($profiles | Where-Object { $_.Name -ieq [Environment]::UserName })
  if ($ownProfile.Count -eq 1) { $profile = $ownProfile[0] }
  elseif ($profiles.Count -eq 1) { $profile = $profiles[0] }
  elseif ($profiles.Count -eq 0) { return @() }
  else { throw 'Multiple Wallpaper Engine user profiles were found; no current profile can be selected safely.' }
  $entries = @()
  $wallpaperConfig = $profile.Value.general.wallpaperconfig
  $monitors = @($wallpaperConfig.selectedwallpapers.PSObject.Properties | Sort-Object `
    @{ Expression = { if ($_.Name -match '^Monitor(\d+)$') { [int]$Matches[1] } else { [int]::MaxValue } } }, Name)
  # Layout 0 keeps one wallpaper per display. In the shared layouts (2 is
  # "duplicate") Wallpaper Engine only updates the first display's entry and
  # leaves the others at whatever they held before the layout was switched.
  $layout = 0
  if ($wallpaperConfig.layout -is [int] -or $wallpaperConfig.layout -is [long]) { $layout = [int]$wallpaperConfig.layout }
  $layoutMode = if ($layout -eq 2) { 'clone' } elseif ($layout -ne 0) { 'shared' } else { 'individual' }
  $sharedSource = if ($layoutMode -cne 'individual' -and $monitors.Count -gt 0) { $monitors[0] } else { $null }
  foreach ($monitor in $monitors) {
    $entry = [pscustomobject]@{
      monitorId = $monitor.Name; label = $monitor.Name; title = '未知壁纸'; type = 'unknown';
      canSync = $false; mode = 'unsupported'; reason = ''; workshopId = ''; projectPath = '';
      mediaPath = ''; targetThemeId = ''; sourceKey = ''; needsRecording = $false;
      sceneFingerprint = ''; recordingFingerprint = ''; mappingKind = '';
      layout = $layoutMode; sharedFrom = ''; layoutNote = ''
    }
    if ($monitor.Name -match '^Monitor(\d+)$') { $entry.label = '屏幕 ' + ([int]$Matches[1] + 1) }
    $selectedSource = $monitor
    if ($null -ne $sharedSource) {
      $selectedSource = $sharedSource
      $entry.sharedFrom = $sharedSource.Name
      if ($layoutMode -ceq 'clone') {
        $entry.label += '（复制）'
        $entry.layoutNote = 'Wallpaper Engine 当前为复制布局，所有屏幕显示同一张壁纸。'
      } else {
        $entry.label += '（共用）'
        $entry.layoutNote = 'Wallpaper Engine 当前为多屏共用布局，所有屏幕使用同一张壁纸。'
      }
    }
    try {
      $selected = [string]$selectedSource.Value.file
      if ($selected -notmatch '^[A-Za-z]:[\\/]') { throw 'Only existing local Steam Workshop paths are supported.' }
      $selected = [IO.Path]::GetFullPath($selected)
      Assert-DreamSkinNoReparseComponents -Path $selected
      $normalized = $selected.Replace('/', '\')
      if ($normalized -notmatch '^(?<root>.+\\steamapps\\workshop\\content\\431960)\\(?<id>\d{1,20})\\[^\r\n]+$') {
        throw 'The wallpaper must remain inside a Steam Workshop 431960 item.'
      }
      $itemDirectory = Join-Path $Matches.root $Matches.id
      $entry.workshopId = $Matches.id
      $entry.projectPath = Join-Path $itemDirectory 'project.json'
      Assert-DreamSkinNoReparseComponents -Path $entry.projectPath
      $project = Read-LinkObject -FilePath $entry.projectPath -MaxBytes 262144
      if ($null -eq $project) { throw 'The Workshop project.json is missing.' }
      $entry.title = if ($project.title -is [string]) { [string]$project.title } else { $entry.workshopId }
      $reference = Read-DreamSkinWallpaperEngineProject -ProjectDirectory $itemDirectory
      $entry.type = [string]$reference.MediaType
      $entry.mediaPath = [string]$reference.MediaPath
      Assert-DreamSkinNoReparseComponents -Path $entry.mediaPath
      if (-not (Test-DreamSkinPathEqual -Left $selected -Right $entry.mediaPath) -and
          -not (Test-DreamSkinPathEqual -Left $selected -Right $entry.projectPath)) {
        throw 'The saved wallpaper path does not match its project media.'
      }
      if ($entry.type -ceq 'video') {
        # Source validates magic, extension, size and containment. Never copy it.
        $null = Assert-DreamSkinMediaFile -Path $entry.mediaPath
        $entry.mode = 'native-video'; $entry.canSync = $true
        $entry.targetThemeId = 'wallpaper-engine-' + $entry.workshopId
        $entry.reason = '直接引用本地 MP4/WebM，不复制原视频，也不控制 Wallpaper Engine。'
      } elseif ($entry.type -ceq 'scene') {
        $entry.sceneFingerprint = Get-LinkSceneFingerprint -ScenePath $entry.mediaPath
        $entry.needsRecording = $true
        $entry.reason = '该场景尚无可用录像，需先录制；当前主题保持不变。'
        $mappingProperty = $recordings.recordings.PSObject.Properties[$entry.workshopId]
        if ($null -ne $mappingProperty) {
          $mapping = $mappingProperty.Value
          if ($mapping -isnot [pscustomobject] -or $mapping.workshopId -cne $entry.workshopId -or
              $mapping.sourceFingerprint -isnot [string]) { throw 'A recorded wallpaper association is invalid.' }
          if ($mapping.sourceFingerprint -cne $entry.sceneFingerprint) {
            $entry.reason = '该场景源文件已更新，原录像关联已失效。请重新录制；旧收藏和当前主题保持不变。'
          } else {
            $recorded = Get-LinkMappedTheme -Id ([string]$mapping.themeId)
            $recordedInfo = New-Object IO.FileInfo($recorded.MediaPath)
            $entry.mode = 'recorded-scene'; $entry.canSync = $true; $entry.needsRecording = $false
            $entry.targetThemeId = [string]$recorded.Theme.id
            $entry.recordingFingerprint = [string]$mapping.recordingKey + '|' + $recordedInfo.Length + '|' + $recordedInfo.LastWriteTimeUtc.Ticks
            $entry.mappingKind = 'registered'
            $entry.reason = '复用已关联的本地录像；不实时同步鼠标互动或场景属性。'
          }
        } elseif ($entry.workshopId -ceq '3650475846' -and
            [IO.Directory]::Exists((Join-Path $script:LinkState 'themes\nijika-cloud-dynamic-3650475846'))) {
          # Compatibility seed for the recording created before this mapping
          # file existed. A newer scene than the recording must fail closed.
          $recorded = Get-LinkMappedTheme -Id 'nijika-cloud-dynamic-3650475846'
          $recordedInfo = New-Object IO.FileInfo($recorded.MediaPath)
          $sceneInfo = New-Object IO.FileInfo($entry.mediaPath)
          if ($sceneInfo.LastWriteTimeUtc -le $recordedInfo.LastWriteTimeUtc) {
            $entry.mode = 'recorded-scene'; $entry.canSync = $true; $entry.needsRecording = $false
            $entry.targetThemeId = [string]$recorded.Theme.id
            $entry.recordingFingerprint = 'legacy-' + $recordedInfo.Length + '-' + $recordedInfo.LastWriteTimeUtc.Ticks + '|' + $recordedInfo.Length + '|' + $recordedInfo.LastWriteTimeUtc.Ticks
            $entry.mappingKind = 'legacy-nijika'
            $entry.reason = '兼容已有虹夏录像；首次同步后固定源文件指纹，不实时同步场景互动。'
          } else {
            $entry.reason = '虹夏场景比已有录像更新，请重新录制后关联；旧收藏保持不变。'
          }
        }
      }
      $mediaInfo = New-Object IO.FileInfo($entry.mediaPath)
      $projectInfo = New-Object IO.FileInfo($entry.projectPath)
      $entry.sourceKey = Get-LinkKey -Value ($entry.monitorId + '|' + $entry.mediaPath + '|' +
        $mediaInfo.Length + '|' + $mediaInfo.LastWriteTimeUtc.Ticks + '|' + $projectInfo.LastWriteTimeUtc.Ticks + '|' +
        $entry.targetThemeId + '|' + $entry.recordingFingerprint)
    } catch {
      $entry.canSync = $false
      $entry.reason = [string]$_.Exception.Message
    }
    $entries += $entry
  }
  return @($entries)
}

function Get-LinkStatus {
  $prefs = Read-LinkPreferences
  [pscustomobject]@{ enabled = $prefs.enabled; monitorId = $prefs.monitorId;
    monitorEntries = @(Get-LinkEntries); source = 'saved-config'; configPath = $script:LinkConfig;
    warning = '读取已保存配置，可能稍晚于桌面当前状态。不会启动或控制 Wallpaper Engine。' }
}

function Copy-LinkFlat {
  param([string]$Source, [string]$Destination)
  Assert-DreamSkinNoReparseComponents -Path $Source
  Ensure-DreamSkinManagedDirectory -Path $Destination -Root $script:LinkState
  if (-not [IO.Directory]::Exists($Source)) { return }
  foreach ($file in [IO.Directory]::EnumerateFiles($Source)) {
    Assert-DreamSkinNoReparseComponents -Path $file
    [IO.File]::Copy($file, (Join-Path $Destination ([IO.Path]::GetFileName($file))), $true)
  }
}

function Restore-LinkFlat {
  param([string]$Backup, [string]$Destination)
  if (-not (Test-DreamSkinThemePathWithin -Path $Destination -Root $script:LinkState)) { throw 'The rollback target escaped the state directory.' }
  Assert-DreamSkinNoReparseComponents -Path $Destination
  Ensure-DreamSkinManagedDirectory -Path $Destination -Root $script:LinkState
  foreach ($file in [IO.Directory]::EnumerateFiles($Destination)) {
    Assert-DreamSkinNoReparseComponents -Path $file
    [IO.File]::Delete($file)
  }
  Copy-LinkFlat -Source $Backup -Destination $Destination
}

function Get-LinkFileHash {
  param([string]$FilePath)
  $hasher = [Security.Cryptography.SHA256]::Create()
  $stream = [IO.File]::OpenRead($FilePath)
  try { return [BitConverter]::ToString($hasher.ComputeHash($stream)).Replace('-', '').ToLowerInvariant() }
  finally { $stream.Dispose(); $hasher.Dispose() }
}

function Restore-LinkJson {
  param([string]$FilePath, [AllowNull()][byte[]]$Before, [AllowNull()][byte[]]$Applied)
  if ($null -eq $Applied) { return }
  if ($null -ne $Before) { Write-DreamSkinBytesAtomically -Path $FilePath -Bytes $Before -ExpectedBytes $Applied }
  elseif ([IO.File]::Exists($FilePath) -and
      (Test-DreamSkinBytesEqual -Left ([IO.File]::ReadAllBytes($FilePath)) -Right $Applied)) { [IO.File]::Delete($FilePath) }
}

function Invoke-LinkRegisterRecording {
  if (-not $MonitorId -or -not $Path -or $Path -notmatch '^[A-Za-z]:[\\/]') {
    throw 'RegisterRecording requires a selected monitor and an absolute local MP4 -Path.'
  }
  $videoPath = [IO.Path]::GetFullPath($Path)
  Assert-DreamSkinNoReparseComponents -Path $videoPath
  if ([IO.Path]::GetExtension($videoPath) -ine '.mp4') { throw 'Recorded scene registration accepts MP4 files only.' }
  $null = Assert-DreamSkinVideoFile -Path $videoPath
  $matches = @(Get-LinkEntries | Where-Object { $_.monitorId -ceq $MonitorId })
  if ($matches.Count -ne 1 -or $matches[0].type -cne 'scene' -or -not $matches[0].sceneFingerprint) {
    throw 'The selected saved wallpaper is not a validated local scene.'
  }
  $entry = $matches[0]
  if (($ExpectedWorkshopId -and $ExpectedWorkshopId -cne $entry.workshopId) -or
      ($ExpectedSceneFingerprint -and $ExpectedSceneFingerprint -cne $entry.sceneFingerprint)) {
    throw 'The selected scene changed after recording started; the recording was not associated.'
  }
  $recordings = Read-LinkRecordings
  Assert-DreamSkinNoReparseComponents -Path $script:LinkRecordings
  $mappingBefore = if ([IO.File]::Exists($script:LinkRecordings)) { [IO.File]::ReadAllBytes($script:LinkRecordings) } else { $null }
  $priorMapping = $recordings.recordings.PSObject.Properties[$entry.workshopId]
  $themeId = if ($null -ne $priorMapping) { [string]$priorMapping.Value.themeId } else { 'wallpaper-engine-recorded-' + $entry.workshopId }
  if ($themeId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$' -or $themeId.EndsWith('.') -or
      (Test-DreamSkinWindowsReservedPathStem -Name $themeId)) { throw 'The mapped recording theme ID is invalid.' }
  $paths = Get-DreamSkinThemePaths -StateRoot $script:LinkState
  $savedPath = Join-Path $paths.Saved $themeId
  Assert-DreamSkinNoReparseComponents -Path $savedPath
  $active = if ([IO.File]::Exists((Join-Path $paths.Active 'theme.json'))) {
    Read-DreamSkinTheme -ThemeDirectory $paths.Active -SkipImageMetadata
  } else { $null }
  $opacity = if ($null -ne $active) { Get-DreamSkinThemeMediaOpacity -Theme $active.Theme } else { 0.75 }
  Assert-DreamSkinNoReparseComponents -Path $script:LinkTransparency
  $prefBefore = if ([IO.File]::Exists($script:LinkTransparency)) { [IO.File]::ReadAllBytes($script:LinkTransparency) } else { $null }
  $preferences = Read-LinkObject -FilePath $script:LinkTransparency -MaxBytes 262144
  if ($null -eq $preferences) { $preferences = [pscustomobject]@{ schemaVersion = 1; themes = [pscustomobject]@{} } }
  if ($preferences.schemaVersion -ne 1 -or $preferences.themes -isnot [pscustomobject]) { throw 'Invalid theme transparency preferences.' }
  $surface = [double]($opacity * 100)
  if ($null -ne $active) {
    $activePreference = $preferences.themes.PSObject.Properties[[string]$active.Theme.id]
    if ($null -ne $activePreference -and $null -ne $activePreference.Value.transparency) { $surface = [double]$activePreference.Value.transparency }
  }
  if ([double]::IsNaN($surface) -or [double]::IsInfinity($surface) -or $surface -lt 0 -or $surface -gt 100) { throw 'Invalid current surface transparency.' }
  $themeName = if ($Name) { $Name.Trim() } else { [string]$entry.title }
  if (-not $Name -and $themeName.Length -gt 80) {
    $themeName = $themeName.Substring(0, 80)
    if ([char]::IsHighSurrogate($themeName[$themeName.Length - 1])) { $themeName = $themeName.Substring(0, $themeName.Length - 1) }
  }
  if (-not $themeName -or $themeName.Length -gt 80 -or $themeName -match '[\x00-\x1f]') { throw 'The recording name must contain 1 to 80 visible characters.' }
  $sourceHash = Get-LinkFileHash -FilePath $videoPath
  $transaction = Join-Path $script:LinkState ('.studio-record-' + [guid]::NewGuid().ToString('N'))
  $stage = Join-Path $transaction 'new'
  $old = Join-Path $transaction 'old'
  Ensure-DreamSkinManagedDirectory -Path $stage -Root $script:LinkState
  Ensure-DreamSkinManagedDirectory -Path $paths.Saved -Root $script:LinkState
  $published = $false; $oldMoved = $false; $committed = $false
  $prefApplied = $null; $mappingApplied = $null
  try {
    $targetMedia = Join-Path $stage 'background.mp4'
    [IO.File]::Copy($videoPath, $targetMedia, $false)
    $null = Assert-DreamSkinVideoFile -Path $targetMedia
    if ((Get-LinkFileHash -FilePath $targetMedia) -cne $sourceHash -or
        (Get-LinkFileHash -FilePath $videoPath) -cne $sourceHash) { throw 'The recording changed while being copied.' }
    if ([IO.Directory]::Exists($savedPath)) {
      $existing = Get-LinkMappedTheme -Id $themeId
      $theme = $existing.Theme | ConvertTo-Json -Depth 24 | ConvertFrom-Json
      $css = Join-Path $savedPath 'theme.css'
      if ([IO.File]::Exists($css)) {
        Assert-DreamSkinSafeCssFile -Path $css
        [IO.File]::Copy($css, (Join-Path $stage 'theme.css'), $false)
      }
    } else {
      $project = Read-LinkObject -FilePath $entry.projectPath -MaxBytes 262144
      $accent = Get-LinkAccent -Project $project
      $theme = [pscustomobject]@{ schemaVersion = 1; id = $themeId; name = $themeName; appearance = 'dark';
        art = [pscustomobject]@{ focusX = $null; focusY = $null; safeArea = 'auto'; taskMode = 'ambient' };
        palette = [pscustomobject]@{ accent = $accent };
        colors = [pscustomobject]@{ background = '#101B25'; panel = '#172B3A'; panelAlt = '#203B4B'; accent = $accent;
          accentAlt = '#B1E4F3'; secondary = '#E9C88D'; highlight = '#2E5771'; text = '#EFF8FC'; muted = '#B1C8D5'; line = 'rgba(118,201,234,.28)' } }
    }
    $theme | Add-Member -NotePropertyName image -NotePropertyValue 'background.mp4' -Force
    if (-not $Name -and [IO.Directory]::Exists($savedPath)) {
      $themeName = [string]$theme.name
    }
    $theme | Add-Member -NotePropertyName name -NotePropertyValue $themeName -Force
    $theme | Add-Member -NotePropertyName media -NotePropertyValue ([pscustomobject]@{ type = 'video'; playbackRate = 1; opacity = $opacity }) -Force
    Write-DreamSkinTheme -ThemeDirectory $stage -Theme $theme
    $null = Read-DreamSkinTheme -ThemeDirectory $stage -SkipImageMetadata
    $latest = @(Get-LinkEntries | Where-Object { $_.monitorId -ceq $MonitorId })
    if ($latest.Count -ne 1 -or $latest[0].workshopId -cne $entry.workshopId -or
        $latest[0].sceneFingerprint -cne $entry.sceneFingerprint) { throw 'The scene changed while the recording was staged.' }
    if ([IO.Directory]::Exists($savedPath)) { [IO.Directory]::Move($savedPath, $old); $oldMoved = $true }
    [IO.Directory]::Move($stage, $savedPath); $published = $true
    $prefEntry = $preferences.themes.PSObject.Properties[$themeId]
    if ($null -eq $prefEntry) {
      $preferences.themes | Add-Member -NotePropertyName $themeId -NotePropertyValue ([pscustomobject]@{})
      $prefEntry = $preferences.themes.PSObject.Properties[$themeId]
    }
    if ($prefEntry.Value -isnot [pscustomobject]) { throw 'The target theme preference entry is invalid.' }
    $prefEntry.Value | Add-Member -NotePropertyName transparency -NotePropertyValue $surface -Force
    $prefText = ($preferences | ConvertTo-Json -Depth 24) + "`n"
    Write-DreamSkinUtf8FileAtomically -Path $script:LinkTransparency -Content $prefText -ExpectedBytes $prefBefore
    $prefApplied = $script:LinkUtf8.GetBytes($prefText)
    $sceneInfo = New-Object IO.FileInfo($entry.mediaPath)
    $mapping = [pscustomobject]@{ workshopId = $entry.workshopId; themeId = $themeId;
      sourceFingerprint = $entry.sceneFingerprint;
      sourceScene = [pscustomobject]@{ path = $entry.mediaPath; bytes = $sceneInfo.Length; lastWriteTimeUtc = $sceneInfo.LastWriteTimeUtc.ToString('o') };
      recordedSha256 = $sourceHash; recordingKey = [guid]::NewGuid().ToString('N'); registeredAtUtc = [DateTime]::UtcNow.ToString('o') }
    $recordings.recordings | Add-Member -NotePropertyName $entry.workshopId -NotePropertyValue $mapping -Force
    $latest = @(Get-LinkEntries | Where-Object { $_.monitorId -ceq $MonitorId })
    if ($latest.Count -ne 1 -or $latest[0].workshopId -cne $entry.workshopId -or
        $latest[0].sceneFingerprint -cne $entry.sceneFingerprint) { throw 'The scene changed before recording registration committed.' }
    $mappingText = ($recordings | ConvertTo-Json -Depth 24) + "`n"
    if ($script:LinkUtf8.GetByteCount($mappingText) -gt 1048576) { throw 'Recorded scene mappings exceed the size limit.' }
    Write-DreamSkinUtf8FileAtomically -Path $script:LinkRecordings -Content $mappingText -ExpectedBytes $mappingBefore
    $mappingApplied = $script:LinkUtf8.GetBytes($mappingText)
    $committed = $true
    return [pscustomobject]@{ registered = $true; changed = $false; switched = $false; workshopId = $entry.workshopId;
      themeId = $themeId; savedPath = $savedPath; monitorId = $MonitorId; sourceFingerprint = $entry.sceneFingerprint;
      reveal = [math]::Round($opacity * 100); sourceTransparency = $surface; source = 'saved-config';
      message = '录像已收藏并关联，当前主题保持不变。点击“导入并应用当前壁纸”后切换。' }
  } finally {
    if (-not $committed) {
      Restore-LinkJson -FilePath $script:LinkRecordings -Before $mappingBefore -Applied $mappingApplied
      Restore-LinkJson -FilePath $script:LinkTransparency -Before $prefBefore -Applied $prefApplied
      if ($published) { Remove-DreamSkinManagedDirectoryVerified -Path $savedPath -Root $script:LinkState }
      if ($oldMoved) { [IO.Directory]::Move($old, $savedPath) }
    }
    Assert-DreamSkinNoReparseComponents -Path $transaction
    if (Test-DreamSkinThemePathWithin -Path $transaction -Root $script:LinkState) { [IO.Directory]::Delete($transaction, $true) }
  }
}

function Invoke-LinkSync {
  if (-not $MonitorId) { throw 'Select a monitor before synchronizing.' }
  # The caller holds the same operation lock as theme editing and SetFollow.
  # Read preferences and the source again here, never use a prior Status result.
  $prefs = Read-LinkPreferences
  if ($Automatic -ceq 'true' -and (-not $prefs.enabled -or $prefs.monitorId -cne $MonitorId)) {
    return [pscustomobject]@{ changed = $false; needsRecording = $false; message = '自动跟随已关闭，或已切换到其他屏幕。'; source = 'saved-config' }
  }
  $entries = @(Get-LinkEntries | Where-Object { $_.monitorId -ceq $MonitorId })
  if ($entries.Count -ne 1) { throw 'The selected monitor is no longer present in the saved Wallpaper Engine configuration.' }
  $entry = $entries[0]
  if (-not $entry.canSync) {
    return [pscustomobject]@{ changed = $false; needsRecording = $entry.needsRecording;
      message = $entry.reason; source = 'saved-config'; monitorId = $MonitorId }
  }
  $paths = Get-DreamSkinThemePaths -StateRoot $script:LinkState
  $active = if ([IO.File]::Exists((Join-Path $paths.Active 'theme.json'))) {
    Read-DreamSkinTheme -ThemeDirectory $paths.Active -SkipImageMetadata
  } else { $null }
  $savedPath = Join-Path $paths.Saved $entry.targetThemeId
  Assert-DreamSkinNoReparseComponents -Path $savedPath
  $previousSync = $prefs.lastSync
  if ($null -ne $previousSync -and $previousSync.sourceKey -ceq $entry.sourceKey -and
      ($Automatic -ceq 'true' -or ([IO.File]::Exists((Join-Path $savedPath 'theme.json')) -and
        $null -ne $active -and $active.Theme.id -ceq $entry.targetThemeId))) {
    return [pscustomobject]@{ changed = $false; needsRecording = $false; themeId = $entry.targetThemeId;
      message = '所选屏幕的壁纸没有变化。'; source = 'saved-config' }
  }
  $opacity = if ($null -ne $active) { Get-DreamSkinThemeMediaOpacity -Theme $active.Theme } else { 0.75 }
  $surface = [double]($opacity * 100)
  Assert-DreamSkinNoReparseComponents -Path $script:LinkTransparency
  $transparencyBefore = if ([IO.File]::Exists($script:LinkTransparency)) { [IO.File]::ReadAllBytes($script:LinkTransparency) } else { $null }
  $transparency = Read-LinkObject -FilePath $script:LinkTransparency -MaxBytes 262144
  if ($null -eq $transparency) { $transparency = [pscustomobject]@{ schemaVersion = 1; themes = [pscustomobject]@{} } }
  if ($transparency.schemaVersion -ne 1 -or $transparency.themes -isnot [pscustomobject]) { throw 'Theme transparency preferences are invalid.' }
  if ($null -ne $active) {
    $oldPreference = $transparency.themes.PSObject.Properties[[string]$active.Theme.id]
    if ($null -ne $oldPreference -and $null -ne $oldPreference.Value.transparency) { $surface = [double]$oldPreference.Value.transparency }
  }
  if ([double]::IsNaN($surface) -or [double]::IsInfinity($surface) -or $surface -lt 0 -or $surface -gt 100) { throw 'The current surface transparency is invalid.' }
  $prefsBefore = if ([IO.File]::Exists($script:LinkPrefs)) { [IO.File]::ReadAllBytes($script:LinkPrefs) } else { $null }
  $transaction = Join-Path $script:LinkState ('.studio-link-' + [guid]::NewGuid().ToString('N'))
  $activeBackup = Join-Path $transaction 'active'
  $savedBackup = Join-Path $transaction 'saved'
  $savedExisted = [IO.Directory]::Exists($savedPath)
  Copy-LinkFlat -Source $paths.Active -Destination $activeBackup
  Copy-LinkFlat -Source $savedPath -Destination $savedBackup
  $committed = $false
  $transparencyApplied = $null
  $recordingsBefore = $null
  $recordingsApplied = $null
  try {
    if ($entry.mode -ceq 'native-video') {
      $sourceProject = Read-LinkObject -FilePath $entry.projectPath -MaxBytes 262144
      $accent = Get-LinkAccent -Project $sourceProject
      $theme = if ($savedExisted) { (Read-DreamSkinTheme -ThemeDirectory $savedPath -SkipImageMetadata).Theme } else {
        [pscustomobject]@{ schemaVersion = 1; id = $entry.targetThemeId; name = $entry.title; appearance = 'auto';
          art = [pscustomobject]@{ focusX = $null; focusY = $null; safeArea = 'auto'; taskMode = 'auto' };
          palette = [pscustomobject]@{ accent = $accent };
          colors = [pscustomobject]@{ background = '#101B25'; panel = '#172B3A'; panelAlt = '#203B4B';
            accent = $accent; accentAlt = '#B1E4F3'; secondary = '#E9C88D'; highlight = '#2E5771';
            text = '#EFF8FC'; muted = '#B1C8D5'; line = 'rgba(118, 201, 234, 0.28)' };
          media = [pscustomobject]@{ type = 'video'; opacity = $opacity; playbackRate = 1 } }
      }
      if ($theme.id -cne $entry.targetThemeId) { throw 'The saved video theme identity does not match.' }
      $theme.media | Add-Member -NotePropertyName opacity -NotePropertyValue $opacity -Force
      $loaded = Set-DreamSkinActiveWallpaperEngineTheme -MediaPath $entry.mediaPath -Theme $theme -Name $theme.name -StateRoot $script:LinkState
      # Native videos do not inherit unrelated custom CSS from the prior theme.
      $activeCss = Join-Path $paths.Active 'theme.css'
      if ([IO.File]::Exists($activeCss)) { Assert-DreamSkinNoReparseComponents -Path $activeCss; [IO.File]::Delete($activeCss) }
      Ensure-DreamSkinManagedDirectory -Path $savedPath -Root $script:LinkState
      Write-DreamSkinTheme -ThemeDirectory $savedPath -Theme $loaded.Theme
    } else {
      $loaded = Use-DreamSkinSavedTheme -ThemeDirectory $savedPath -StateRoot $script:LinkState
      $loaded = Set-DreamSkinActiveThemeMediaOpacity -Opacity $opacity -StateRoot $script:LinkState
      # Keep the reusable recorded theme's opacity aligned with the user's setting.
      $savedTheme = (Read-DreamSkinTheme -ThemeDirectory $savedPath -SkipImageMetadata).Theme
      $savedTheme.media | Add-Member -NotePropertyName opacity -NotePropertyValue $opacity -Force
      Write-DreamSkinTheme -ThemeDirectory $savedPath -Theme $savedTheme
    }
    $targetPref = $transparency.themes.PSObject.Properties[$entry.targetThemeId]
    if ($null -eq $targetPref) {
      $transparency.themes | Add-Member -NotePropertyName $entry.targetThemeId -NotePropertyValue ([pscustomobject]@{})
      $targetPref = $transparency.themes.PSObject.Properties[$entry.targetThemeId]
    }
    if ($targetPref.Value -isnot [pscustomobject]) { throw 'The target theme transparency entry is invalid.' }
    $targetPref.Value | Add-Member -NotePropertyName transparency -NotePropertyValue $surface -Force
    $transparencyText = ($transparency | ConvertTo-Json -Depth 24) + "`n"
    Write-DreamSkinUtf8FileAtomically -Path $script:LinkTransparency -Content $transparencyText -ExpectedBytes $transparencyBefore
    $transparencyApplied = $script:LinkUtf8.GetBytes($transparencyText)
    if ($entry.mappingKind -ceq 'legacy-nijika') {
      # Migrate the compatibility seed only during an explicit successful sync;
      # Status remains read-only, and later scene updates invalidate the map.
      Assert-DreamSkinNoReparseComponents -Path $script:LinkRecordings
      $recordingsBefore = if ([IO.File]::Exists($script:LinkRecordings)) { [IO.File]::ReadAllBytes($script:LinkRecordings) } else { $null }
      $recordings = Read-LinkRecordings
      $recordedTheme = Get-LinkMappedTheme -Id $entry.targetThemeId
      $recordingInfo = New-Object IO.FileInfo($recordedTheme.MediaPath)
      $sceneInfo = New-Object IO.FileInfo($entry.mediaPath)
      $recordings.recordings | Add-Member -NotePropertyName $entry.workshopId -NotePropertyValue ([pscustomobject]@{
        workshopId = $entry.workshopId; themeId = $entry.targetThemeId; sourceFingerprint = $entry.sceneFingerprint;
        sourceScene = [pscustomobject]@{ path = $entry.mediaPath; bytes = $sceneInfo.Length; lastWriteTimeUtc = $sceneInfo.LastWriteTimeUtc.ToString('o') };
        recordedSha256 = Get-LinkFileHash -FilePath $recordedTheme.MediaPath;
        recordingKey = 'legacy-' + $recordingInfo.Length + '-' + $recordingInfo.LastWriteTimeUtc.Ticks;
        registeredAtUtc = [DateTime]::UtcNow.ToString('o')
      }) -Force
      $recordingsText = ($recordings | ConvertTo-Json -Depth 24) + "`n"
      Write-DreamSkinUtf8FileAtomically -Path $script:LinkRecordings -Content $recordingsText -ExpectedBytes $recordingsBefore
      $recordingsApplied = $script:LinkUtf8.GetBytes($recordingsText)
    }
    # An external WE config write can happen while the DreamSkin lock is held.
    $latest = @(Get-LinkEntries | Where-Object { $_.monitorId -ceq $MonitorId })
    if ($latest.Count -ne 1 -or $latest[0].sourceKey -cne $entry.sourceKey -or -not $latest[0].canSync) {
      throw 'Wallpaper Engine saved configuration changed during synchronization; the previous theme was restored.'
    }
    $prefs.monitorId = $MonitorId
    $prefs | Add-Member -NotePropertyName lastSync -NotePropertyValue ([pscustomobject]@{
      monitorId = $MonitorId; sourceKey = $entry.sourceKey; themeId = $entry.targetThemeId;
      mode = $entry.mode; time = [DateTime]::UtcNow.ToString('o') }) -Force
    Write-LinkObject -FilePath $script:LinkPrefs -Object $prefs -Before $prefsBefore
    $committed = $true
    return [pscustomobject]@{ changed = $true; needsRecording = $false; source = 'saved-config';
      monitorId = $MonitorId; mode = $entry.mode; themeId = $entry.targetThemeId; savedPath = $savedPath;
      reveal = [math]::Round($opacity * 100); sourceTransparency = $surface; requiresApply = $true;
      message = ('已同步并收藏“' + $entry.title + '”；未重启 Codex。没有背景时请手动重新应用。') }
  } finally {
    if (-not $committed) {
      Restore-LinkJson -FilePath $script:LinkRecordings -Before $recordingsBefore -Applied $recordingsApplied
      Restore-LinkFlat -Backup $activeBackup -Destination $paths.Active
      Restore-LinkFlat -Backup $savedBackup -Destination $savedPath
      if (-not $savedExisted -and [IO.Directory]::Exists($savedPath)) { [IO.Directory]::Delete($savedPath, $false) }
      if ($null -ne $transparencyApplied) {
        if ($null -ne $transparencyBefore) {
          Write-DreamSkinBytesAtomically -Path $script:LinkTransparency -Bytes $transparencyBefore -ExpectedBytes $transparencyApplied
        } elseif (Test-DreamSkinBytesEqual -Left ([IO.File]::ReadAllBytes($script:LinkTransparency)) -Right $transparencyApplied) {
          [IO.File]::Delete($script:LinkTransparency)
        }
      }
    }
    # Only this freshly generated, contained transaction tree is removed.
    Assert-DreamSkinNoReparseComponents -Path $transaction
    if (Test-DreamSkinThemePathWithin -Path $transaction -Root $script:LinkState) {
      [IO.Directory]::Delete($transaction, $true)
    }
  }
}

try {
  if ($PSVersionTable.PSEdition -ne 'Desktop') { throw 'Use Windows PowerShell 5.1.' }
  $native = Join-Path $PSHOME 'Modules'
  $env:PSModulePath = $native + ';' + (Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules')
  foreach ($module in @('Microsoft.PowerShell.Utility', 'Microsoft.PowerShell.Management', 'Microsoft.PowerShell.Security')) {
    Import-Module (Join-Path $native ($module + '\' + $module + '.psd1')) -ErrorAction Stop
  }
  . (Join-Path $script:LinkScripts 'common-windows.ps1')
  . (Join-Path $script:LinkScripts 'theme-windows.ps1')
  $result = if ($Action -ceq 'Status') { Get-LinkStatus } else {
    $lease = Enter-DreamSkinOperationLock -TimeoutMilliseconds 1000
    try {
      switch ($Action) {
        'SetFollow' {
          if (-not $PSBoundParameters.ContainsKey('Enabled')) { throw 'SetFollow requires -Enabled true or false.' }
          $prefs = Read-LinkPreferences
          if ($Enabled -ceq 'true' -and -not $MonitorId) { throw 'Select a monitor before enabling automatic following.' }
          if ($MonitorId -and @(Get-LinkEntries | Where-Object { $_.monitorId -ceq $MonitorId }).Count -ne 1) { throw 'The selected monitor is unavailable.' }
          $before = if ([IO.File]::Exists($script:LinkPrefs)) { [IO.File]::ReadAllBytes($script:LinkPrefs) } else { $null }
          Ensure-DreamSkinManagedDirectory -Path $script:LinkState -Root $script:LinkState
          $prefs.enabled = $Enabled -ceq 'true'
          if ($MonitorId) { $prefs.monitorId = $MonitorId }
          Write-LinkObject -FilePath $script:LinkPrefs -Object $prefs -Before $before
          [pscustomobject]@{ enabled = $prefs.enabled; monitorId = $prefs.monitorId; source = 'saved-config'; changed = $false }
        }
        'Sync' { Invoke-LinkSync }
        'RegisterRecording' { Invoke-LinkRegisterRecording }
        default { throw 'Unsupported Wallpaper Engine link action.' }
      }
    } finally { Exit-DreamSkinOperationLock -Mutex $lease }
  }
  [Console]::Out.WriteLine((@{ ok = $true; data = $result; error = $null } | ConvertTo-Json -Depth 24 -Compress))
  exit 0
} catch {
  [Console]::Out.WriteLine((@{ ok = $false; data = $script:LinkFailureData; error = [string]$_.Exception.Message } | ConvertTo-Json -Depth 8 -Compress))
  exit 1
}
