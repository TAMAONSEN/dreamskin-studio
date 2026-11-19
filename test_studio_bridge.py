"""Work fixtures only; app-facing actions use explicitly inert backend stubs."""
from __future__ import annotations

import base64
import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
BRIDGE = ROOT / "backend" / "studio-bridge.ps1"
ENGINE = Path(os.environ["LOCALAPPDATA"]) / "CodexDreamSkin" / "engine"
POWERSHELL = Path(os.environ["WINDIR"]) / "System32/WindowsPowerShell/v1.0/powershell.exe"


def main() -> None:
    fixture = Path(tempfile.mkdtemp(prefix="bridge-fixture-", dir=ROOT))
    state = fixture / "CodexDreamSkin"
    scripts = state / "engine" / "scripts"
    scripts.mkdir(parents=True)
    for leaf in ("common-windows.ps1", "config-utf8.ps1", "theme-windows.ps1"):
        shutil.copyfile(ENGINE / "scripts" / leaf, scripts / leaf)
    shutil.copyfile(ENGINE / "scripts" / "image-metadata.mjs", scripts / "image-metadata.mjs")
    (state / "engine" / "VERSION").write_text("1.7.3\n", encoding="utf-8")
    active = state / "active-theme"
    active.mkdir()
    png = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jhDoAAAAASUVORK5CYII=")
    (active / "background.png").write_bytes(png)
    theme = {"schemaVersion": 1, "id": "fixture-current", "name": "Fixture current",
             "image": "background.png", "appearance": "auto",
             "media": {"type": "image", "opacity": .75, "playbackRate": 1},
             "colors": {"accent": "#D9364B"}, "customPreserved": "keep"}
    theme_path = active / "theme.json"
    theme_path.write_text(json.dumps(theme), encoding="utf-8")
    preferences = {"schemaVersion": 1, "themes": {
        "fixture-current": {"transparency": 75, "preserved": True},
        "unrelated": {"transparency": 37}}, "unrelatedTopLevel": "preserve"}
    pref_path = state / "theme-preferences.json"
    pref_path.write_text(json.dumps(preferences), encoding="utf-8")
    saved = state / "themes" / "fixture-current 'quoted'"
    saved.mkdir(parents=True)
    shutil.copyfile(theme_path, saved / "theme.json")
    shutil.copyfile(active / "background.png", saved / "background.png")
    environment = dict(os.environ, LOCALAPPDATA=str(fixture))

    def run(action: str, *arguments: str, expected_ok: bool = True) -> dict:
        result = subprocess.run([str(POWERSHELL), "-NoProfile", "-NonInteractive",
                                 "-ExecutionPolicy", "RemoteSigned", "-File", str(BRIDGE),
                                 "-Action", action, *arguments],
                                env=environment, capture_output=True, encoding="utf-8", timeout=30)
        assert not result.stderr.strip(), (action, result.stderr)
        lines = result.stdout.splitlines()
        assert len(lines) == 1, (action, result.stdout)
        envelope = json.loads(lines[0])
        assert set(envelope) == {"ok", "data", "error"}, envelope
        assert envelope["ok"] is expected_ok, envelope
        assert (result.returncode == 0) is expected_ok, (result.returncode, envelope)
        return envelope

    before = (theme_path.read_bytes(), pref_path.read_bytes())
    status = run("Status")["data"]
    assert status["active"]["reveal"] == status["active"]["sourceTransparency"] == 75
    assert status["savedCount"] == 1
    assert status["running"]["approximate"] is True
    assert run("ListThemes")["data"]["themes"][0]["isActive"] is True
    assert before == (theme_path.read_bytes(), pref_path.read_bytes()), "Read actions wrote state"

    # Color changes only touch color fields and a per-theme original snapshot.
    # Media, transparency preferences and unrelated backup entries must survive.
    color_backup = state / "studio-theme-colors.json"
    original_colors = json.loads(theme_path.read_text())["colors"]
    read_colors = run("GetColors")["data"]
    assert read_colors["colors"]["accent"] == "#D9364B"
    assert read_colors["canReset"] is False and not color_backup.exists()
    run("SetColors", "-Accent", "#123456", "-ThemeId", "stale-theme", expected_ok=False)
    run("SetColors", "-Accent", "#fff; color:red", expected_ok=False)
    run("SetColors", expected_ok=False)
    assert before == (theme_path.read_bytes(), pref_path.read_bytes())
    assert not color_backup.exists()
    color_result = run("SetColors", "-Accent", "#abc", "-Background", "#101010",
                       "-Panel", "#202020", "-Text", "#eeeeee",
                       "-ThemeId", "fixture-current")["data"]
    assert color_result["requiresApply"] is True and color_result["canReset"] is True
    color_theme = json.loads(theme_path.read_text())
    assert color_theme["colors"]["accent"] == color_theme["palette"]["accent"] == "#AABBCC"
    assert color_theme["colors"]["background"] == "#101010"
    assert color_theme["colors"]["panel"] == "#202020" and color_theme["colors"]["text"] == "#EEEEEE"
    assert color_theme["media"] == theme["media"] and color_theme["customPreserved"] == "keep"
    assert pref_path.read_bytes() == before[1]
    backups = json.loads(color_backup.read_text())
    backups["themes"]["unrelated-theme"] = {"original": {
        "colorsPresent": False, "colorsValue": None, "palettePresent": False, "paletteValue": None}}
    color_backup.write_text(json.dumps(backups), encoding="utf-8")
    run("SetColors", "-Accent", "#123456")
    assert json.loads(color_backup.read_text())["themes"]["fixture-current"]["original"]["colorsValue"] == original_colors
    reset_colors = run("ResetColors", "-ThemeId", "fixture-current")["data"]
    assert reset_colors["canReset"] is False and reset_colors["requiresApply"] is True
    reset_theme = json.loads(theme_path.read_text())
    assert reset_theme["colors"] == original_colors and "palette" not in reset_theme
    assert reset_theme["media"] == theme["media"] and pref_path.read_bytes() == before[1]
    assert "unrelated-theme" in json.loads(color_backup.read_text())["themes"]
    run("ResetColors", expected_ok=False)
    # Automatic themes must regain the absence of both color objects on reset.
    auto_theme = dict(reset_theme)
    del auto_theme["colors"]
    theme_path.write_text(json.dumps(auto_theme), encoding="utf-8")
    run("SetColors", "-Accent", "#f00")
    run("ResetColors")
    auto_reset = json.loads(theme_path.read_text())
    assert "colors" not in auto_reset and "palette" not in auto_reset
    assert auto_reset["media"]["opacity"] == .75
    theme_path.write_text(json.dumps(theme), encoding="utf-8")

    # Fault injection stays in this fixture's copied backend. Verify neither
    # second-file failure can lose originals or leave the paired state half set.
    with (scripts / "theme-windows.ps1").open("a", encoding="utf-8") as stream:
        stream.write(r'''
function Write-DreamSkinUtf8FileAtomically {
  [CmdletBinding()]
  param([string]$Path,[AllowEmptyString()][string]$Content,[AllowNull()][byte[]]$ExpectedBytes)
  $faultRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
  if(([IO.Path]::GetFileName($Path) -eq 'theme.json') -and
     [IO.File]::Exists((Join-Path $faultRoot 'stub-color-fail-theme-write'))){throw 'fixture theme write failure'}
  if(([IO.Path]::GetFileName($Path) -eq 'studio-theme-colors.json') -and
     [IO.File]::Exists((Join-Path $faultRoot 'stub-color-fail-backup-write'))){throw 'fixture backup write failure'}
  $faultBytes=[Text.UTF8Encoding]::new($false,$true).GetBytes($Content)
  if($PSBoundParameters.ContainsKey('ExpectedBytes')){
    Write-DreamSkinBytesAtomically -Path $Path -Bytes $faultBytes -ExpectedBytes $ExpectedBytes
  }else{Write-DreamSkinBytesAtomically -Path $Path -Bytes $faultBytes}
}
''')
    paired_before = (theme_path.read_bytes(), color_backup.read_bytes())
    fail_theme = state / "stub-color-fail-theme-write"
    fail_theme.touch()
    run("SetColors", "-Accent", "#112233", expected_ok=False)
    assert paired_before == (theme_path.read_bytes(), color_backup.read_bytes())
    fail_theme.unlink()
    run("SetColors", "-Accent", "#112233")
    paired_custom = (theme_path.read_bytes(), color_backup.read_bytes())
    fail_backup = state / "stub-color-fail-backup-write"
    fail_backup.touch()
    run("ResetColors", expected_ok=False)
    assert paired_custom == (theme_path.read_bytes(), color_backup.read_bytes())
    fail_backup.unlink()
    run("ResetColors")
    assert json.loads(theme_path.read_text())["colors"] == original_colors

    changed = run("SetReveal", "-Percent", "42")["data"]
    assert changed["status"]["active"]["reveal"] == 42
    assert changed["status"]["active"]["sourceTransparency"] == 42
    after_theme = json.loads(theme_path.read_text(encoding="utf-8"))
    after_pref = json.loads(pref_path.read_text(encoding="utf-8"))
    assert after_theme["media"]["opacity"] == .42
    assert after_theme["customPreserved"] == "keep" and after_theme["colors"]["accent"] == "#D9364B"
    assert after_pref["themes"]["unrelated"]["transparency"] == 37
    assert after_pref["themes"]["fixture-current"]["preserved"] is True
    assert after_pref["unrelatedTopLevel"] == "preserve"
    before_invalid = (theme_path.read_bytes(), pref_path.read_bytes())
    run("SetReveal", "-Percent", "101", expected_ok=False)
    assert before_invalid == (theme_path.read_bytes(), pref_path.read_bytes())
    run("ApplyTheme", expected_ok=False)  # Missing ID must fail before starting anything.
    run("UnsupportedAction", expected_ok=False)

    # Test real file-copy/validation code only against this isolated theme store.
    replacement = fixture / "replacement.png"
    replacement.write_bytes(png)
    wallpaper_result = run("SetWallpaper", "-Path", str(replacement))["data"]
    assert wallpaper_result["requiresApply"] is True
    assert wallpaper_result["active"]["id"] == "fixture-current"
    assert wallpaper_result["active"]["reveal"] == 42
    assert Path(wallpaper_result["active"]["mediaPath"]).is_file()
    assert json.loads(theme_path.read_text(encoding="utf-8"))["colors"]["accent"] == "#D9364B"

    # No upstream launcher is copied into the fixture. This inert script only
    # records received arguments and creates a bounded start-result file.
    (scripts / "start-dream-skin.ps1").write_text(r'''
param([switch]$PromptRestart,[string]$ResultToken,[string]$SavedThemeDirectory)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'common-windows.ps1')
$testStateRoot=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
[IO.File]::WriteAllText((Join-Path $testStateRoot 'stub-start-arguments.json'),
  (@{promptRestart=[bool]$PromptRestart;savedThemeDirectory=$SavedThemeDirectory}|ConvertTo-Json))
$testOutcomePath=Join-Path $testStateRoot 'stub-outcome.txt'
$testOutcome=if([IO.File]::Exists($testOutcomePath)){[IO.File]::ReadAllText($testOutcomePath)}else{'success'}
Write-Output 'stub raw stdout must stay in operation log'
Write-Host 'stub host output must stay in operation log'
# Use Unicode escapes so this PS5.1 fixture remains ASCII source without a BOM.
$testChinese=([string][char]0x4e2d)+[char]0x6587+[char]0x9519+[char]0x8bef
[Console]::Out.WriteLine($testChinese+' stdout')
[Console]::Error.WriteLine($testChinese+' stderr')
# A native program can bypass Console.OutputEncoding and emit raw CP936 bytes.
$testLegacy=[Text.Encoding]::GetEncoding(936).GetBytes($testChinese)
$testRawError=[Console]::OpenStandardError()
$testRawError.Write($testLegacy,0,$testLegacy.Length)
$testRawError.Flush()
if($testOutcome -eq 'cancel'){exit 0}
if($testOutcome -eq 'failure'){
  Write-DreamSkinStartResult -StateRoot $testStateRoot -Token $ResultToken -Outcome failure -Category cdp-endpoint-unavailable -AppearanceRecovery not-needed
  exit 7
}
Write-DreamSkinStartResult -StateRoot $testStateRoot -Token $ResultToken -Outcome success -Category none -AppearanceRecovery not-needed
if($testOutcome -eq 'exit-code-only'){exit 7}
exit 0
''', encoding="utf-8")
    applied = run("Apply")["data"]
    assert applied["verified"] is True
    child_log = Path(applied["logPath"]).read_text(encoding="utf-8")
    assert "stub raw stdout" in child_log
    assert "中文错误 stdout" in child_log and "中文错误 stderr" in child_log
    assert "DecoderFallback" not in child_log
    arguments = json.loads((state / "stub-start-arguments.json").read_text())
    assert arguments["promptRestart"] is True
    assert not arguments["savedThemeDirectory"]
    run("ApplyTheme", "-ThemeId", "fixture-current")
    arguments = json.loads((state / "stub-start-arguments.json").read_text())
    assert Path(arguments["savedThemeDirectory"]) == saved
    run("Resume")
    (state / "stub-outcome.txt").write_text("failure")
    run("Apply", expected_ok=False)
    (state / "stub-outcome.txt").write_text("exit-code-only")
    run("Apply", expected_ok=False)  # A success token cannot mask exit code 7.
    (state / "stub-outcome.txt").write_text("cancel")
    run("Apply", expected_ok=False)

    # Pause is intercepted before any Node/CDP code can run. Its partial-failure
    # result must explicitly tell the frontend that the marker was written.
    with (scripts / "theme-windows.ps1").open("a", encoding="utf-8") as stream:
        stream.write("\nfunction Invoke-DreamSkinLiveRemove { param([string]$StateRoot) "
                     "[pscustomobject]@{Attempted=$false;Removed=$false;Message='fixture no session'} }\n")
    pause_error = run("Pause", expected_ok=False)
    assert pause_error["data"]["paused"] is True
    assert pause_error["data"]["liveRemoved"] is False
    assert pause_error["data"]["requiresRefresh"] is True
    assert "Pause was recorded" in pause_error["error"]

    # Empty first-run stores and a library containing zero valid entries must
    # remain usable; read calls never seed themes or change the active scope.
    saved.rename(state / "saved-temporarily-hidden")
    assert run("ListThemes")["data"]["themes"] == []
    theme_path.rename(active / "theme.temporarily-hidden.json")
    empty_status = run("Status")["data"]
    assert empty_status["active"] is None and empty_status["savedCount"] == 0
    run("ApplyTheme", "-ThemeId", "missing", expected_ok=False)
    print(json.dumps({"ok": True, "fixture": str(fixture), "checks": [
        "single-envelope UTF-8", "read-only status/list", "42-percent paired update",
        "unrelated preferences preserved", "theme contract preserved",
        "out-of-range no-write", "missing theme ID no-launch", "unknown action envelope",
        "wallpaper-copy preserves contract and requires explicit apply",
        "custom colors and palette accent synchronized", "repeated edits preserve original colors",
        "color reset preserves media and 75-percent preferences", "automatic colors restore absent fields",
        "invalid colors and stale theme reject without writes", "unrelated color backups preserved",
        "color backup rollback on theme write failure", "color reset rollback on backup write failure",
        "inert apply child arguments/token/log isolation", "nonzero child fails",
        "success result token cannot mask nonzero process exit",
        "PS5.1 Chinese stdout and stderr preserved", "raw CP936 stderr never masks result token",
        "quoted saved-theme path passed literally",
        "zero-exit cancellation fails", "pause partial state reported",
        "empty library and no-active first-run status"]}))


if __name__ == "__main__":
    main()
