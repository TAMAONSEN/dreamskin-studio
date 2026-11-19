param([string]$Output = (Join-Path $PSScriptRoot 'dist'))
$ErrorActionPreference = 'Stop'
$framework = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
$output = [IO.Path]::GetFullPath($Output)
[void][System.IO.Directory]::CreateDirectory($output)
$refs = @('System.Drawing.dll','System.Windows.Forms.dll','System.dll','System.Core.dll','System.Xaml.dll','System.Web.Extensions.dll','WPF\WindowsBase.dll','WPF\PresentationCore.dll','WPF\PresentationFramework.dll') | ForEach-Object { '/reference:' + (Join-Path $framework $_) }
$icon = Join-Path $PSScriptRoot 'assets\dreamskin-aurora.ico'
$buildArgs = @('/nologo','/target:winexe','/platform:x64','/langversion:5','/optimize+','/codepage:65001',('/out:' + (Join-Path $output 'DreamSkinStudio.exe')),('/resource:' + (Join-Path $PSScriptRoot 'MainWindow.xaml') + ',DreamSkinStudio.MainWindow.xaml')) + $refs
$buildArgs += '/win32icon:' + $icon
$buildArgs += '/resource:' + (Join-Path $PSScriptRoot 'assets\dreamskin-aurora.png') + ',DreamSkinStudio.Mark.png'
$buildArgs += Join-Path $PSScriptRoot 'Studio.cs'
$buildArgs += Join-Path $PSScriptRoot 'UiPalette.cs'
$buildArgs += Join-Path $PSScriptRoot 'Ambience.cs'
$buildArgs += Join-Path $PSScriptRoot 'ThemeColorDialog.cs'
$buildArgs += Join-Path $PSScriptRoot 'WallpaperLinkPanel.cs'
& (Join-Path $framework 'csc.exe') @buildArgs
if ($LASTEXITCODE -ne 0) { throw 'C# build failed.' }
Copy-Item -LiteralPath $icon -Destination (Join-Path $output 'dreamskin-aurora.ico') -Force
if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'backend\studio-bridge.ps1')) {
  [void][System.IO.Directory]::CreateDirectory((Join-Path $output 'backend'))
  Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'backend\studio-bridge.ps1') -Destination (Join-Path $output 'backend\studio-bridge.ps1') -Force
}
Write-Output (Join-Path $output 'DreamSkinStudio.exe')

if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'backend\wallpaper-link.ps1')) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'backend\wallpaper-link.ps1') -Destination (Join-Path $output 'backend\wallpaper-link.ps1') -Force }

if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'backend\record-wallpaper.ps1')) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'backend\record-wallpaper.ps1') -Destination (Join-Path $output 'backend\record-wallpaper.ps1') -Force }

# The installer and its rollback script run from the build folder, next to the EXE.
$install = Join-Path $PSScriptRoot 'install'
if (Test-Path -LiteralPath $install) { Copy-Item -Path (Join-Path $install '*') -Destination $output -Force }
