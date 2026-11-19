[CmdletBinding()]
param(
  [ValidateSet('Record')][string]$Action = 'Record',
  [Parameter(Mandatory = $true)][string]$ProjectPath,
  # MACHINE-SPECIFIC: the author's recording folder. Change this default on another computer.
  [string]$OutputDirectory = 'G:\CodexMediaWork\SceneRecordings',
  [ValidateRange(4, 60)][int]$Seconds = 26
)

# Explicit user-triggered recording only. Never invoke this script from a poll.
# The source scene, Wallpaper Engine configuration, desktop and AppData are not
# edited. Only a uniquely named WPE preview window is captured and closed.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$utf8 = New-Object Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8
$recordLog = New-Object Text.StringBuilder
$logPath = $null
$previewRequested = $false
$previewTitle = 'DreamSkin-Scene-' + [guid]::NewGuid().ToString('N')
$recordMutex = $null
$recordLease = $false
$wpeExe = $null
$response = $null
$exitStatus = 1
$cleanupWarning = $null
# MACHINE-SPECIFIC: where ffmpeg, ffprobe and Wallpaper Engine are installed on
# the author's computer. Change all three paths on another computer.
$ffmpeg = 'G:\CodexMediaWork\Nijika-Cloud\tools\ffmpeg.exe'
$ffprobe = 'G:\CodexMediaWork\Nijika-Cloud\tools\ffprobe.exe'
$wpeRoot = 'G:\steam\steamapps\common\wallpaper_engine'
$invariant = [Globalization.CultureInfo]::InvariantCulture

function Add-RecordLog([string]$Message) {
  [void]$recordLog.AppendLine((Get-Date).ToUniversalTime().ToString('o') + ' ' + $Message)
}
function Flush-RecordLog {
  if ($logPath) {
    try { [IO.File]::WriteAllText($logPath, $recordLog.ToString(), $utf8) } catch { }
  }
}
function Get-LocalFullPath([string]$Value) {
  if (-not $Value -or $Value -cnotmatch '^[A-Za-z]:[\\/]') { throw 'Use an absolute local drive path.' }
  $full = [IO.Path]::GetFullPath($Value)
  for ($part = $full; $part; $part = [IO.Path]::GetDirectoryName($part)) {
    if (([IO.File]::Exists($part) -or [IO.Directory]::Exists($part)) -and
        (([IO.File]::GetAttributes($part) -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
      throw 'Redirected recording paths are not supported.'
    }
  }
  return $full
}
function Quote-NativeArgument([string]$Value) {
  if ($null -eq $Value) { return '""' }
  # CommandLineToArgvW quoting, including quotes and trailing backslashes.
  $quoted = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
  $quoted = [regex]::Replace($quoted, '(\\+)$', '$1$1')
  return '"' + $quoted + '"'
}
function Invoke-RecorderTool {
  param([string]$Executable, [string[]]$Arguments, [string]$Step,
        [ValidateRange(1, 75)][int]$TimeoutSeconds = 75)
  Add-RecordLog ('BEGIN ' + $Step)
  $info = New-Object Diagnostics.ProcessStartInfo
  $info.FileName = $Executable
  $info.Arguments = (($Arguments | ForEach-Object { Quote-NativeArgument $_ }) -join ' ')
  $info.WorkingDirectory = $script:jobDirectory
  $info.UseShellExecute = $false
  $info.CreateNoWindow = $true
  $info.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
  $info.RedirectStandardOutput = $true
  $info.RedirectStandardError = $true
  $info.StandardOutputEncoding = $utf8
  $info.StandardErrorEncoding = $utf8
  $process = New-Object Diagnostics.Process
  $process.StartInfo = $info
  try {
    [void]$process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
      # Kill only this owned ffmpeg/ffprobe process, never WPE or a process name.
      try { $process.Kill() } catch { }
      [void]$process.WaitForExit(3000)
      Add-RecordLog ($Step + ' timed out after ' + $TimeoutSeconds + ' seconds.')
      Flush-RecordLog
      throw ($Step + ' timed out; the desktop and Wallpaper Engine were not stopped.')
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    Add-RecordLog ($Step + ' exit=' + $process.ExitCode)
    if ($stderr) { Add-RecordLog $stderr }
    Flush-RecordLog
    if ($process.ExitCode -ne 0) { throw ($Step + ' failed. See the recording log.') }
    return [pscustomobject]@{ stdout = $stdout; stderr = $stderr; exitCode = $process.ExitCode }
  } finally { $process.Dispose() }
}
function Invoke-WpePreviewCommand([string[]]$Arguments) {
  $info = New-Object Diagnostics.ProcessStartInfo
  $info.FileName = $wpeExe
  $info.Arguments = (($Arguments | ForEach-Object { Quote-NativeArgument $_ }) -join ' ')
  $info.WorkingDirectory = $wpeRoot
  $info.UseShellExecute = $false
  $info.CreateNoWindow = $true
  $info.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
  $process = New-Object Diagnostics.Process
  $process.StartInfo = $info
  try {
    [void]$process.Start()
    $finished = $process.WaitForExit(3000)
    if ($finished) {
      Add-RecordLog ('WPE command exit=' + $process.ExitCode)
      if ($process.ExitCode -ne 0) { throw 'Wallpaper Engine rejected the preview command.' }
    } else {
      # A forwarding/daemon process is not an owned capture process. Never kill it.
      Add-RecordLog 'WPE command dispatch did not exit within 3 seconds; no process was terminated.'
    }
  } finally { $process.Dispose() }
}
function Get-SourceSnapshot([string]$Project, [string]$Package) {
  $projectHash = (Get-FileHash -LiteralPath $Project -Algorithm SHA256).Hash.ToLowerInvariant()
  $packageHash = (Get-FileHash -LiteralPath $Package -Algorithm SHA256).Hash.ToLowerInvariant()
  $algorithm = [Security.Cryptography.SHA256]::Create()
  try {
    $fingerprint = [BitConverter]::ToString($algorithm.ComputeHash($utf8.GetBytes($projectHash + ':' + $packageHash))).Replace('-', '').ToLowerInvariant()
  } finally { $algorithm.Dispose() }
  return [pscustomobject]@{
    fingerprint = $fingerprint; projectSha256 = $projectHash; packageSha256 = $packageHash
  }
}
function Get-RecordingMetadata([string]$Video, [string]$Step) {
  $result = Invoke-RecorderTool -Executable $ffprobe -Arguments @(
    '-v', 'error', '-count_frames', '-show_streams', '-show_format', '-of', 'json', $Video
  ) -Step $Step -TimeoutSeconds 35
  $json = $result.stdout | ConvertFrom-Json
  $videos = @($json.streams | Where-Object { $_.codec_type -ceq 'video' })
  if ($videos.Count -ne 1) { throw 'The recording must contain exactly one video stream.' }
  $stream = $videos[0]
  $rate = [string]$stream.avg_frame_rate
  $parts = $rate.Split('/')
  $fps = if ($parts.Count -eq 2 -and [double]::Parse($parts[1], $invariant) -gt 0) {
    [double]::Parse($parts[0], $invariant) / [double]::Parse($parts[1], $invariant)
  } else { 0.0 }
  $durationText = if ($stream.duration -and $stream.duration -ne 'N/A') { [string]$stream.duration } else { [string]$json.format.duration }
  $framesText = if ($stream.nb_read_frames -and $stream.nb_read_frames -ne 'N/A') { [string]$stream.nb_read_frames } else { [string]$stream.nb_frames }
  $frames = 0L
  if (-not [long]::TryParse($framesText, [ref]$frames)) { throw 'The recording frame count could not be verified.' }
  return [pscustomobject]@{
    width = [int]$stream.width; height = [int]$stream.height; fps = $fps
    duration = [double]::Parse($durationText, $invariant); frames = $frames
    codec = [string]$stream.codec_name; pixelFormat = [string]$stream.pix_fmt
    audioStreams = @($json.streams | Where-Object { $_.codec_type -ceq 'audio' }).Count
  }
}
function Assert-VideoMetadata($Metadata, [double]$ExpectedSeconds, [bool]$FullHd) {
  if ($Metadata.audioStreams -ne 0 -or [Math]::Abs($Metadata.fps - 30.0) -gt 0.01) { throw 'The recording is not silent 30 fps video.' }
  if ([Math]::Abs($Metadata.duration - $ExpectedSeconds) -gt 0.12 -or
      [Math]::Abs($Metadata.frames - ($ExpectedSeconds * 30)) -gt 3) { throw 'The recording duration or decoded frame count is incomplete.' }
  if ($FullHd -and ($Metadata.width -ne 1920 -or $Metadata.height -ne 1080)) { throw 'The final recording is not 1920 x 1080.' }
}

function Find-RecordingEdgeBars {
  param([string]$Video, [int]$Width, [int]$Height, [double]$Duration, [string]$Crop)
  if (-not ('DreamSkinSceneRecorder.EdgeBars' -as [type])) {
    Add-Type -Namespace DreamSkinSceneRecorder -Name EdgeBars -MemberDefinition @'
public static int[] Scan(string path, int width, int height) {
    int size = checked(width * height);
    var frame = new byte[size];
    var trim = new[] { width, height, width, height };
    using (var input = System.IO.File.OpenRead(path)) {
        if (input.Length != size * 5L) throw new System.IO.InvalidDataException("Five edge samples were expected.");
        for (int sample = 0; sample < 5; sample++) {
            for (int pos = 0; pos < size;) {
                int count = input.Read(frame, pos, size - pos);
                if (count == 0) throw new System.IO.EndOfStreamException();
                pos += count;
            }
            for (int side = 0; side < 4; side++) {
                bool vertical = side % 2 == 0;
                int depth = vertical ? width : height;
                int span = vertical ? height : width;
                int count = 0;
                // Ignore corners and require an almost uniform dark band.
                // Take the shortest run across the sample frames.
                for (; count <= depth / 4; count++) {
                    int near = side < 2 ? count : depth - 1 - count;
                    int dark = 0, start = span / 10, end = span - start;
                    for (int along = start; along < end; along++) {
                        int offset = vertical ? along * width + near : near * width + along;
                        if (frame[offset] <= 24) dark++;
                    }
                    if (dark * 100 < (end - start) * 98) break;
                }
                trim[side] = Math.Min(trim[side], count);
            }
        }
    }
    return trim;
}
'@
  }
  $samples = Join-Path $script:jobDirectory ('edges-' + [guid]::NewGuid().ToString('N') + '.gray')
  $fps = (5.0 / $Duration).ToString('0.########', $invariant)
  $filter = ('fps=' + $fps + ',format=gray')
  if ($Crop) { $filter = $Crop + ',' + $filter }
  try {
    $null = Invoke-RecorderTool -Executable $ffmpeg -Arguments @(
      '-hide_banner', '-nostdin', '-v', 'error', '-n', '-i', $Video, '-an',
      '-vf', $filter, '-frames:v', '5', '-c:v', 'rawvideo', '-threads:v', '1', '-f', 'rawvideo', $samples
    ) -Step 'sample-video-edges' -TimeoutSeconds 25
    [int[]]$bars = [DreamSkinSceneRecorder.EdgeBars]::Scan($samples, $Width, $Height)
    if ($bars[0] -gt $Width / 4 -or $bars[2] -gt $Width / 4 -or
        $bars[1] -gt $Height / 4 -or $bars[3] -gt $Height / 4) {
      throw '视频边缘大面积发黑，无法可靠确定裁切范围。请确认壁纸预览正常后重新录制。'
    }
    return $bars
  } finally { if ([IO.File]::Exists($samples)) { [IO.File]::Delete($samples) } }
}

function Get-RecordingFillFilter {
  param([int]$Width, [int]$Height, [int]$X, [int]$Y, [int[]]$Bars)
  $w = $Width - $Bars[0] - $Bars[2]
  $h = $Height - $Bars[1] - $Bars[3]
  if ($w -lt 320 -or $h -lt 180) { throw 'The usable recording rectangle is too small.' }
  $crop = 'crop={0}:{1}:{2}:{3}:exact=1' -f $w,$h,($X + $Bars[0]),($Y + $Bars[1])
  return ($crop + ',fps=30,scale=1920:1080:force_original_aspect_ratio=increase:force_divisible_by=2:flags=lanczos,crop=1920:1080,setsar=1,format=yuv420p')
}

try {
  $ProjectPath = Get-LocalFullPath $ProjectPath
  $OutputDirectory = Get-LocalFullPath $OutputDirectory
  if ([IO.Path]::GetFileName($ProjectPath) -ine 'project.json' -or -not [IO.File]::Exists($ProjectPath)) { throw 'Select a local Wallpaper Engine scene project.json.' }
  if ((Get-Item -LiteralPath $ProjectPath).Length -gt 4194304) { throw 'The scene project metadata is too large.' }
  $project = [IO.File]::ReadAllText($ProjectPath) | ConvertFrom-Json
  if ([string]$project.type -ine 'scene') { throw 'This recorder accepts scene wallpapers only.' }
  $projectFolder = Split-Path -Parent $ProjectPath
  $packagePath = Get-LocalFullPath (Join-Path $projectFolder 'scene.pkg')
  if (-not [IO.File]::Exists($packagePath)) { throw 'The scene.pkg beside project.json is missing.' }
  if ($OutputDirectory -ieq $projectFolder -or $OutputDirectory.StartsWith($projectFolder.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Recordings must be saved outside the original Wallpaper Engine project.'
  }
  foreach ($tool in @($ffmpeg, $ffprobe)) {
    [void](Get-LocalFullPath $tool)
    if (-not [IO.File]::Exists($tool)) { throw 'The prepared graphics-capture FFmpeg tools are missing.' }
  }
  $allowedWpe = @((Join-Path $wpeRoot 'wallpaper64.exe'), (Join-Path $wpeRoot 'wallpaper32.exe'))
  foreach ($candidate in $allowedWpe) {
    foreach ($running in [Diagnostics.Process]::GetProcessesByName([IO.Path]::GetFileNameWithoutExtension($candidate))) {
      try { if ($running.MainModule.FileName -ieq $candidate) { $wpeExe = $candidate; break } } catch { }
      finally { $running.Dispose() }
    }
    if ($wpeExe) { break }
  }
  if (-not $wpeExe) { throw 'Open Wallpaper Engine normally before starting a scene recording.' }
  $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $recordMutex = New-Object Threading.Mutex($false, ('Local\DreamSkinStudio.' + $sid + '.SceneRecording'))
  try { $recordLease = $recordMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $recordLease = $true }
  if (-not $recordLease) { throw 'Another scene recording is already running.' }
  $workshopId = [string]$project.workshopid
  if ($workshopId -cnotmatch '^\d{1,24}$') { $workshopId = 'local-scene' }
  $jobName = $workshopId + '-' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
  $script:jobDirectory = Join-Path $OutputDirectory $jobName
  [void][IO.Directory]::CreateDirectory($script:jobDirectory)
  $logPath = Join-Path $script:jobDirectory 'recording.log'
  Add-RecordLog ('Project: ' + $ProjectPath)
  Add-RecordLog ('Window: ' + $previewTitle + '; capture is HWND-only, with no monitor capture.')
  $initialSource = Get-SourceSnapshot $ProjectPath $packagePath
  $toolHelp = Invoke-RecorderTool -Executable $ffmpeg -Arguments @('-hide_banner', '-h', 'filter=gfxcapture') -Step 'capture-capability' -TimeoutSeconds 10
  if (($toolHelp.stdout + $toolHelp.stderr) -notmatch '\bhwnd\b') { throw 'This FFmpeg build does not support HWND graphics capture.' }

  if (-not ('DreamSkinSceneRecorder.NativeWindow' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
namespace DreamSkinSceneRecorder {
  public sealed class WindowGeometry {
    public ulong Hwnd; public uint ProcessId; public string Title, ProcessPath;
    public int WindowLeft, WindowTop, WindowWidth, WindowHeight;
    public int FrameLeft, FrameTop, FrameWidth, FrameHeight;
    public int ClientLeft, ClientTop, ClientWidth, ClientHeight;
    public bool HasDwmFrame;
  }
  public static class NativeWindow {
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr FindWindow(string cls, string title);
    [DllImport("user32.dll", SetLastError=true)] static extern bool IsWindow(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr hwnd);
    [DllImport("user32.dll", SetLastError=true)] static extern bool GetClientRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll", SetLastError=true)] static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll", SetLastError=true)] static extern bool ClientToScreen(IntPtr hwnd, ref POINT point);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int count);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr hwnd, int attribute, out RECT rect, int size);
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool QueryFullProcessImageName(IntPtr process, uint flags, StringBuilder path, ref int size);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    public static ulong Find(string title) { return unchecked((ulong)FindWindow(null, title).ToInt64()); }
    public static WindowGeometry Describe(ulong value) {
      IntPtr hwnd = new IntPtr(unchecked((long)value));
      if (!IsWindow(hwnd) || IsIconic(hwnd)) throw new InvalidOperationException("The dedicated wallpaper preview is missing or minimized.");
      IntPtr oldDpi = SetThreadDpiAwarenessContext(new IntPtr(-4));
      try {
        RECT client, window, frame;
        if (!GetClientRect(hwnd, out client) || !GetWindowRect(hwnd, out window)) throw new Win32Exception();
        POINT origin = new POINT { X=client.Left, Y=client.Top };
        if (!ClientToScreen(hwnd, ref origin)) throw new Win32Exception();
        bool hasFrame = DwmGetWindowAttribute(hwnd, 9, out frame, Marshal.SizeOf(typeof(RECT))) == 0;
        uint pid; GetWindowThreadProcessId(hwnd, out pid);
        IntPtr process = OpenProcess(0x1000, false, pid);
        if (process == IntPtr.Zero) throw new Win32Exception();
        string executable;
        try { int size=32768; var path=new StringBuilder(size); if (!QueryFullProcessImageName(process, 0, path, ref size)) throw new Win32Exception(); executable=path.ToString(); }
        finally { CloseHandle(process); }
        var title=new StringBuilder(512); GetWindowText(hwnd,title,title.Capacity);
        return new WindowGeometry { Hwnd=value, ProcessId=pid, Title=title.ToString(), ProcessPath=executable,
          WindowLeft=window.Left,WindowTop=window.Top,WindowWidth=window.Right-window.Left,WindowHeight=window.Bottom-window.Top,
          FrameLeft=frame.Left,FrameTop=frame.Top,FrameWidth=frame.Right-frame.Left,FrameHeight=frame.Bottom-frame.Top,HasDwmFrame=hasFrame,
          ClientLeft=origin.X,ClientTop=origin.Y,ClientWidth=client.Right-client.Left,ClientHeight=client.Bottom-client.Top };
      } finally { if(oldDpi!=IntPtr.Zero) SetThreadDpiAwarenessContext(oldDpi); }
    }
  }
}
'@ -ErrorAction Stop
  }
  function Read-VerifiedPreview([uint64]$Handle) {
    $geometry = [DreamSkinSceneRecorder.NativeWindow]::Describe($Handle)
    if ($geometry.Title -cne $previewTitle -or $allowedWpe -inotcontains $geometry.ProcessPath) { throw 'The capture HWND does not belong to the dedicated Wallpaper Engine preview.' }
    if ($geometry.ClientWidth -lt 320 -or $geometry.ClientHeight -lt 180) { throw 'The dedicated preview client area is too small.' }
    return $geometry
  }
  $previewRequested = $true
  Invoke-WpePreviewCommand -Arguments @('-control', 'openWallpaper', '-file', $packagePath, '-playInWindow', $previewTitle, '-width', '1920', '-height', '1080')
  $windowDeadline = [DateTime]::UtcNow.AddSeconds(20)
  $hwnd = [uint64]0
  while ($hwnd -eq 0 -and [DateTime]::UtcNow -lt $windowDeadline) {
    $hwnd = [DreamSkinSceneRecorder.NativeWindow]::Find($previewTitle)
    if ($hwnd -eq 0) { Start-Sleep -Milliseconds 200 }
  }
  if ($hwnd -eq 0) { throw 'The dedicated Wallpaper Engine preview did not appear.' }
  $geometry = Read-VerifiedPreview $hwnd
  Start-Sleep -Milliseconds 900
  $probePath = Join-Path $script:jobDirectory 'capture-probe.mp4'
  $rawGraph = 'gfxcapture=hwnd=' + $hwnd.ToString($invariant) + ':capture_cursor=0:capture_border=1:display_border=0:max_framerate=30,hwdownload,format=bgra'
  $null = Invoke-RecorderTool -Executable $ffmpeg -Arguments @(
    '-hide_banner', '-nostdin', '-y', '-f', 'lavfi', '-i', $rawGraph,
    '-t', '3', '-an', '-vf', 'fps=30,format=yuv444p', '-c:v', 'libx264', '-preset', 'ultrafast', '-crf', '20', '-pix_fmt', 'yuv444p', '-movflags', '+faststart', $probePath
  ) -Step 'three-second-window-probe' -TimeoutSeconds 25
  $probeMetadata = Get-RecordingMetadata $probePath 'probe-metadata'
  Assert-VideoMetadata $probeMetadata 3.0 $false
  $afterProbe = Read-VerifiedPreview $hwnd
  if ($geometry.ClientWidth -ne $afterProbe.ClientWidth -or $geometry.ClientHeight -ne $afterProbe.ClientHeight -or $geometry.ProcessId -ne $afterProbe.ProcessId) { throw 'The dedicated preview was resized or replaced during the probe.' }
  $geometry = $afterProbe
  # WGC may use DWM extended bounds rather than GetWindowRect. Select the
  # coordinate origin from the actual raw probe dimensions before cropping.
  if ($geometry.HasDwmFrame -and $probeMetadata.width -eq $geometry.FrameWidth -and $probeMetadata.height -eq $geometry.FrameHeight) {
    $baseLeft = $geometry.FrameLeft; $baseTop = $geometry.FrameTop; $boundsKind = 'dwm-extended-frame'
  } elseif ($probeMetadata.width -eq $geometry.WindowWidth -and $probeMetadata.height -eq $geometry.WindowHeight) {
    $baseLeft = $geometry.WindowLeft; $baseTop = $geometry.WindowTop; $boundsKind = 'window-rect'
  } else { throw 'The graphics-capture dimensions do not match the verified preview window geometry.' }
  $cropLeft = $geometry.ClientLeft - $baseLeft
  $cropTop = $geometry.ClientTop - $baseTop
  $cropRight = $probeMetadata.width - $cropLeft - $geometry.ClientWidth
  $cropBottom = $probeMetadata.height - $cropTop - $geometry.ClientHeight
  if ($cropLeft -lt 0 -or $cropTop -lt 0 -or $cropRight -lt 0 -or $cropBottom -lt 0) { throw 'The client-area crop extends outside the dedicated preview.' }
  $clientCrop = 'crop=' + $geometry.ClientWidth + ':' + $geometry.ClientHeight + ':' + $cropLeft + ':' + $cropTop + ':exact=1'
  $blackProbe = Invoke-RecorderTool -Executable $ffmpeg -Arguments @(
    '-hide_banner', '-nostdin', '-i', $probePath, '-an', '-vf', ($clientCrop + ',blackdetect=d=0.5:pic_th=0.98:pix_th=0.05'), '-f', 'null', '-'
  ) -Step 'client-area-black-screen-check' -TimeoutSeconds 25
  $blackSeconds = 0.0
  foreach ($match in [regex]::Matches($blackProbe.stderr, 'black_duration:([0-9]+(?:\.[0-9]+)?)')) { $blackSeconds += [double]::Parse($match.Groups[1].Value, $invariant) }
  if ($blackSeconds -ge 2.5) { throw 'The dedicated preview probe is almost entirely black; no final recording was made.' }
  Add-RecordLog ('Client crop (' + $boundsKind + '): ' + $cropLeft + ',' + $cropTop + ',' + $geometry.ClientWidth + ',' + $geometry.ClientHeight)
  $null = Read-VerifiedPreview $hwnd
  $edgeBars = @(Find-RecordingEdgeBars -Video $probePath -Width $geometry.ClientWidth -Height $geometry.ClientHeight -Duration $probeMetadata.duration -Crop $clientCrop)
  Add-RecordLog ('Persistent edge bars (left,top,right,bottom): ' + ($edgeBars -join ','))
  $sourcePath = Join-Path $script:jobDirectory ($workshopId + '-1080p-source.mp4')
  $loopPath = Join-Path $script:jobDirectory ($workshopId + '-1080p-loop.mp4')
  $normalize = Get-RecordingFillFilter -Width $geometry.ClientWidth -Height $geometry.ClientHeight -X $cropLeft -Y $cropTop -Bars $edgeBars
  $null = Invoke-RecorderTool -Executable $ffmpeg -Arguments @(
    '-hide_banner', '-nostdin', '-y', '-f', 'lavfi', '-i', $rawGraph,
    '-t', $Seconds.ToString($invariant), '-an', '-vf', $normalize, '-c:v', 'libx264', '-preset', 'medium', '-crf', '18', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', $sourcePath
  ) -Step 'full-scene-recording' -TimeoutSeconds ([Math]::Min(75, $Seconds + 30))
  $finalGeometry = Read-VerifiedPreview $hwnd
  Add-RecordLog ('Final client: {0},{1},{2}x{3}; PID {4}' -f $finalGeometry.ClientLeft,$finalGeometry.ClientTop,$finalGeometry.ClientWidth,$finalGeometry.ClientHeight,$finalGeometry.ProcessId)
  if ($finalGeometry.ProcessId -ne $geometry.ProcessId -or $finalGeometry.ClientWidth -ne $geometry.ClientWidth -or $finalGeometry.ClientHeight -ne $geometry.ClientHeight) { throw 'The dedicated preview changed during recording; the clip will not be registered.' }
  $sourceMetadata = Get-RecordingMetadata $sourcePath 'source-metadata'
  Assert-VideoMetadata $sourceMetadata $Seconds $true
  $loopSeconds = $Seconds - 1
  $offset = $Seconds - 2
  $loopGraph = '[0:v]split=2[bodyin][headin];[bodyin]trim=start=1:end=' + $Seconds + ',setpts=PTS-STARTPTS[body];' +
    '[headin]trim=start=0:end=1,setpts=PTS-STARTPTS[head];[body][head]xfade=transition=fade:duration=1:offset=' + $offset + ',fps=30,format=yuv420p[loop]'
  $null = Invoke-RecorderTool -Executable $ffmpeg -Arguments @(
    '-hide_banner', '-nostdin', '-y', '-i', $sourcePath, '-filter_complex', $loopGraph, '-map', '[loop]', '-t', $loopSeconds.ToString($invariant),
    '-an', '-c:v', 'libx264', '-preset', 'medium', '-crf', '18', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', $loopPath
  ) -Step 'one-second-loop-transition' -TimeoutSeconds 75
  $metadata = Get-RecordingMetadata $loopPath 'loop-metadata'
  Assert-VideoMetadata $metadata $loopSeconds $true
  $finalBars = @(Find-RecordingEdgeBars -Video $loopPath -Width 1920 -Height 1080 -Duration $metadata.duration)
  if (@($finalBars | Where-Object { $_ -ge 3 }).Count -gt 0) {
    throw '成片仍检测到连续黑边，未保存为主题。请检查壁纸预览大小后重新录制。'
  }
  $finalSource = Get-SourceSnapshot $ProjectPath $packagePath
  $sourceChanged = $initialSource.fingerprint -cne $finalSource.fingerprint
  if ($sourceChanged) { throw 'The source project or package changed during recording; the clip will not be registered.' }
  $data = [ordered]@{
    path = $loopPath; width = $metadata.width; height = $metadata.height; fps = $metadata.fps
    duration = $metadata.duration; frames = $metadata.frames; codec = $metadata.codec; pixelFormat = $metadata.pixelFormat
    projectPath = $ProjectPath; workshopId = $workshopId; title = [string]$project.title
    sceneFingerprint = $initialSource.fingerprint; sourceProjectSha256 = $initialSource.projectSha256; sourcePackageSha256 = $initialSource.packageSha256
    sourceChanged = $false; sourcePath = $sourcePath; probePath = $probePath; logPath = $logPath
    capturedWindowTitle = $previewTitle; captureClientWidth = $geometry.ClientWidth; captureClientHeight = $geometry.ClientHeight
    crop = [ordered]@{ left = $cropLeft; top = $cropTop; right = $cropRight; bottom = $cropBottom; bounds = $boundsKind }
    edgeTrim = [ordered]@{ left = $edgeBars[0]; top = $edgeBars[1]; right = $edgeBars[2]; bottom = $edgeBars[3] }
    transitionSeconds = 1; sourceDuration = $sourceMetadata.duration; registrationRequested = $false
  }
  $response = [ordered]@{ ok = $true; data = $data }
  $exitStatus = 0
} catch {
  Add-RecordLog ('ERROR: ' + $_.Exception.Message)
  Add-RecordLog ([string]$_.ScriptStackTrace)
  $response = [ordered]@{ ok = $false; error = $_.Exception.Message; data = [ordered]@{ logPath = $logPath; projectPath = $ProjectPath; registrationRequested = $false } }
} finally {
  if ($previewRequested -and $wpeExe) {
    try {
      # The unique location is mandatory: an unqualified closeWallpaper would
      # close desktop wallpapers, which this recorder must never do.
      Invoke-WpePreviewCommand -Arguments @('-control', 'closeWallpaper', '-location', $previewTitle)
    } catch { $cleanupWarning = 'The dedicated preview could not be closed automatically: ' + $_.Exception.Message; Add-RecordLog $cleanupWarning }
  }
  if ($recordLease -and $recordMutex) {
    try { $recordMutex.ReleaseMutex() } finally { $recordMutex.Dispose() }
  } elseif ($recordMutex) { $recordMutex.Dispose() }
  if ($cleanupWarning -and $response) { $response.data['cleanupWarning'] = $cleanupWarning }
  Flush-RecordLog
}
$response | ConvertTo-Json -Depth 8 -Compress
exit $exitStatus
