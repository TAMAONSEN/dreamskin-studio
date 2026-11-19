"""Isolated fake Workshop/config/state only; never invokes Wallpaper Engine."""
import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SCRIPT = ROOT / "backend" / "wallpaper-link.ps1"
ENGINE = Path(os.environ["LOCALAPPDATA"]) / "CodexDreamSkin" / "engine"
PS = Path(os.environ["WINDIR"]) / "System32/WindowsPowerShell/v1.0/powershell.exe"


def main():
    fixture = Path(tempfile.mkdtemp(prefix="wallpaper-link-fixture-", dir=ROOT))
    state = fixture / "local" / "CodexDreamSkin"
    scripts = state / "engine" / "scripts"
    scripts.mkdir(parents=True)
    for leaf in ("common-windows.ps1", "config-utf8.ps1", "theme-windows.ps1"):
        shutil.copyfile(ENGINE / "scripts" / leaf, scripts / leaf)
    # Bypass the performance transcoder in fake-header fixtures; no executable
    # is copied or launched by this suite.
    with (scripts / "theme-windows.ps1").open("a", encoding="utf-8") as stream:
        stream.write("\nfunction New-DreamSkinPerformanceProxy { param($Reference,$StateRoot) return $null }\n")
    we = fixture / "steam" / "steamapps" / "common" / "wallpaper_engine"
    workshop = fixture / "steam" / "steamapps" / "workshop" / "content" / "431960"
    we.mkdir(parents=True)
    media_bytes = b"\x00\x00\x00\x18ftypisom" + b"fixture-video-only" * 3
    projects = {}
    for project_id, kind in (("111", "video"), ("3650475846", "scene"), ("222", "scene"), ("333", "video"), ("555", "video")):
        directory = workshop / project_id
        directory.mkdir(parents=True)
        media = directory / ("background.mp4" if kind == "video" else "scene.pkg")
        media.write_bytes(media_bytes if kind == "video" else b"fixture-scene-not-rendered")
        project = {"type": kind, "file": media.name, "title": "Fixture " + project_id}
        if project_id == "333":
            project["file"] = "../escape.mp4"
        if project_id == "555":
            project["general"] = {"properties": {"schemecolor": {"value": "0.2 0.4 0.6"}}}
        (directory / "project.json").write_text(json.dumps(project), encoding="utf-8")
        projects[project_id] = media

    def make_theme(directory, theme_id):
        directory.mkdir(parents=True)
        (directory / "background.mp4").write_bytes(media_bytes)
        theme = {"schemaVersion": 1, "id": theme_id, "name": theme_id,
                 "image": "background.mp4", "appearance": "auto",
                 "colors": {"accent": "#76C9EA"}, "palette": {"accent": "#76C9EA"},
                 "media": {"type": "video", "opacity": .75, "playbackRate": 1}}
        (directory / "theme.json").write_text(json.dumps(theme), encoding="utf-8")

    active = state / "active-theme"
    recorded = state / "themes" / "nijika-cloud-dynamic-3650475846"
    make_theme(active, "fixture-current")
    make_theme(recorded, "nijika-cloud-dynamic-3650475846")
    pref_path = state / "theme-preferences.json"
    pref_path.write_text(json.dumps({"schemaVersion": 1, "themes": {
        "fixture-current": {"transparency": 75}, "unrelated": {"transparency": 37}}}), encoding="utf-8")
    config_path = we / "config.json"
    config = {"fixture": {"general": {"wallpaperconfig": {"selectedwallpapers": {
        "Monitor0": {"file": str(projects["111"])},
        "Monitor1": {"file": str(projects["3650475846"])},
        "Monitor2": {"file": str(projects["222"])},
        "Monitor3": {"file": str(projects["333"])},
        "Monitor4": {"file": str(projects["555"])}
    }}}}}
    config_path.write_text(json.dumps(config), encoding="utf-8")
    link_prefs = state / "studio-wallpaper-link.json"
    environment = dict(os.environ, LOCALAPPDATA=str(fixture / "local"))

    def run(action, *arguments, expected_ok=True):
        result = subprocess.run([str(PS), "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "RemoteSigned",
                                 "-File", str(SCRIPT), "-WallpaperEngineRoot", str(we), "-Action", action, *arguments],
                                env=environment, capture_output=True, encoding="utf-8", timeout=35)
        assert not result.stderr.strip(), (action, result.stderr)
        assert len(result.stdout.splitlines()) == 1, (action, result.stdout)
        envelope = json.loads(result.stdout)
        assert envelope["ok"] is expected_ok and (result.returncode == 0) is expected_ok, (action, envelope)
        return envelope["data"]

    status = run("Status")
    assert not status["enabled"] and status["monitorId"] == "" and status["source"] == "saved-config"
    assert len(status["monitorEntries"]) == 5
    assert status["monitorEntries"][0]["mode"] == "native-video"
    assert status["monitorEntries"][1]["mode"] == "recorded-scene"
    assert status["monitorEntries"][2]["needsRecording"]
    assert not status["monitorEntries"][3]["canSync"]
    assert not link_prefs.exists(), "Status must not write link preferences"
    assert all(entry["layout"] == "individual" and entry["sharedFrom"] == "" for entry in status["monitorEntries"])
    # Duplicate layout: only the first display's entry is current; the others
    # keep whatever was selected before the layout was switched.
    config["fixture"]["general"]["wallpaperconfig"]["layout"] = 2
    config_path.write_text(json.dumps(config), encoding="utf-8")
    cloned = run("Status")["monitorEntries"]
    assert [entry["monitorId"] for entry in cloned] == ["Monitor%d" % index for index in range(5)]
    assert all(entry["layout"] == "clone" and entry["sharedFrom"] == "Monitor0" and entry["layoutNote"] for entry in cloned)
    assert all(entry["workshopId"] == "111" and entry["mode"] == "native-video" and entry["canSync"] for entry in cloned)
    assert len({entry["sourceKey"] for entry in cloned}) == 5, "Each display keeps its own sync key"
    assert not link_prefs.exists()
    del config["fixture"]["general"]["wallpaperconfig"]["layout"]
    config_path.write_text(json.dumps(config), encoding="utf-8")
    assert run("Status")["monitorEntries"][1]["mode"] == "recorded-scene"
    run("Sync", expected_ok=False)
    before = (active / "theme.json").read_bytes()
    assert not run("Sync", "-MonitorId", "Monitor0", "-Automatic", "true")["changed"]
    assert not link_prefs.exists() and (active / "theme.json").read_bytes() == before
    run("SetFollow", "-Enabled", "true", expected_ok=False)
    run("SetFollow", "-Enabled", "true", "-MonitorId", "Monitor0")
    assert not run("Sync", "-MonitorId", "Monitor1", "-Automatic", "true")["changed"]
    native = run("Sync", "-MonitorId", "Monitor0", "-Automatic", "true")
    assert native["changed"] and native["reveal"] == native["sourceTransparency"] == 75
    native_saved = state / "themes" / "wallpaper-engine-111"
    native_theme = json.loads((active / "theme.json").read_text(encoding="utf-8"))
    assert native_theme["media"]["source"] == "wallpaper-engine-local"
    assert native_theme["media"]["opacity"] == .75
    assert native_theme["palette"]["accent"] == native_theme["colors"]["accent"] == "#76C9EA"
    assert native_theme["colors"]["text"] == "#EFF8FC"
    assert (native_saved / "theme.json").is_file()
    assert not list(native_saved.glob("*.mp4")), "Native video must remain an external reference"
    assert pref_path.read_text().find('"unrelated"') >= 0
    paired_before = [(path, path.read_bytes()) for path in (active / "theme.json", native_saved / "theme.json", pref_path, link_prefs)]
    assert not run("Sync", "-MonitorId", "Monitor0", "-Automatic", "true")["changed"]
    assert all(path.read_bytes() == value for path, value in paired_before)
    # Renamed native videos retain their display name when the workshop
    # configuration changes. Deleting the result of an unchanged source must
    # not let the next poll silently recreate that favorite.
    doc = json.loads((native_saved / "theme.json").read_text(encoding="utf-8"))
    doc["name"] = "My renamed video"
    (native_saved / "theme.json").write_text(json.dumps(doc), encoding="utf-8")
    projects["111"].write_bytes(media_bytes + b"updated")
    assert run("Sync", "-MonitorId", "Monitor0", "-Automatic", "true")["changed"]
    assert json.loads((active / "theme.json").read_text(encoding="utf-8"))["name"] == "My renamed video"
    native_saved.rename(fixture / "recycled-native")
    assert not run("Sync", "-MonitorId", "Monitor0", "-Automatic", "true")["changed"]
    assert not native_saved.exists()
    (fixture / "recycled-native").rename(native_saved)
    run("SetFollow", "-Enabled", "false", "-MonitorId", "Monitor0")
    disabled_before = [(path, path.read_bytes()) for path in (active / "theme.json", pref_path, link_prefs)]
    assert not run("Sync", "-MonitorId", "Monitor0", "-Automatic", "true")["changed"]
    assert all(path.read_bytes() == value for path, value in disabled_before)
    scheme = run("Sync", "-MonitorId", "Monitor4")
    assert scheme["changed"]
    scheme_theme = json.loads((active / "theme.json").read_text(encoding="utf-8"))
    assert scheme_theme["colors"]["accent"] == scheme_theme["palette"]["accent"] == "#336699"
    scene = run("Sync", "-MonitorId", "Monitor1")
    assert scene["changed"] and scene["mode"] == "recorded-scene"
    assert scene["themeId"] == "nijika-cloud-dynamic-3650475846" and scene["reveal"] == 75
    assert json.loads((recorded / "theme.json").read_text())["media"]["opacity"] == .75
    before_unknown = [(path, path.read_bytes()) for path in (active / "theme.json", pref_path, link_prefs)]
    unknown = run("Sync", "-MonitorId", "Monitor2")
    assert not unknown["changed"] and unknown["needsRecording"]
    assert all(path.read_bytes() == value for path, value in before_unknown)
    assert not run("Sync", "-MonitorId", "Monitor3")["changed"]
    assert not run("Sync", "-MonitorId", "Monitor1")["changed"]

    # Generic scene associations register into the library without switching
    # active media or toggling automatic following.
    mapping_path = state / "studio-wallpaper-recordings.json"
    seeded = json.loads(mapping_path.read_text(encoding="utf-8"))
    assert seeded["recordings"]["3650475846"]["themeId"] == "nijika-cloud-dynamic-3650475846"
    recording_input = fixture / "recording.mp4"
    recording_input.write_bytes(media_bytes + b"registered-222")
    scene_before = run("Status")["monitorEntries"][2]
    guarded_before = [(path, path.read_bytes()) for path in (active / "theme.json", link_prefs, mapping_path)]
    run("RegisterRecording", "-MonitorId", "Monitor0", "-Path", str(recording_input), expected_ok=False)
    run("RegisterRecording", "-MonitorId", "Monitor2", "-Path", str(recording_input),
        "-ExpectedWorkshopId", "999", expected_ok=False)
    assert all(path.read_bytes() == value for path, value in guarded_before)
    registered = run("RegisterRecording", "-MonitorId", "Monitor2", "-Path", str(recording_input),
                     "-Name", "Fixture generic scene", "-ExpectedWorkshopId", "222",
                     "-ExpectedSceneFingerprint", scene_before["sceneFingerprint"])
    assert registered["registered"] and not registered["switched"] and not registered["changed"]
    assert registered["reveal"] == registered["sourceTransparency"] == 75
    generic_saved = Path(registered["savedPath"])
    assert registered["themeId"] == "wallpaper-engine-recorded-222"
    assert (active / "theme.json").read_bytes() == guarded_before[0][1]
    assert link_prefs.read_bytes() == guarded_before[1][1]
    assert (generic_saved / "background.mp4").read_bytes() == recording_input.read_bytes()
    generic_status = run("Status")["monitorEntries"][2]
    assert generic_status["mode"] == "recorded-scene" and generic_status["canSync"]
    assert not generic_status["needsRecording"]
    mappings = json.loads(mapping_path.read_text(encoding="utf-8"))
    assert "3650475846" in mappings["recordings"] and "222" in mappings["recordings"]
    assert run("Sync", "-MonitorId", "Monitor2")["changed"]
    assert not run("Sync", "-MonitorId", "Monitor2")["changed"]
    assert json.loads((active / "theme.json").read_text())["id"] == "wallpaper-engine-recorded-222"
    # Source updates invalidate the association while retaining old favorites.
    projects["222"].write_bytes(projects["222"].read_bytes() + b"updated-scene")
    updated_status = run("Status")["monitorEntries"][2]
    assert updated_status["needsRecording"] and not updated_status["canSync"]
    invalidation_before = [(path, path.read_bytes()) for path in (active / "theme.json", pref_path, link_prefs, mapping_path)]
    assert run("Sync", "-MonitorId", "Monitor2")["needsRecording"]
    assert all(path.read_bytes() == value for path, value in invalidation_before)
    assert (generic_saved / "background.mp4").exists()
    run("RegisterRecording", "-MonitorId", "Monitor2", "-Path", str(recording_input),
        "-ExpectedSceneFingerprint", scene_before["sceneFingerprint"], expected_ok=False)
    replacement = run("RegisterRecording", "-MonitorId", "Monitor2", "-Path", str(recording_input),
                      "-ExpectedSceneFingerprint", updated_status["sceneFingerprint"])
    assert replacement["themeId"] == registered["themeId"]
    assert len(list((state / "themes").glob("wallpaper-engine-recorded-222*"))) == 1
    assert run("Sync", "-MonitorId", "Monitor2")["changed"]
    # A fresh recording of unchanged scene bytes is still a new source revision.
    recording_input.write_bytes(media_bytes + b"new-registration-same-scene")
    active_before_registration = (active / "theme.json").read_bytes()
    run("RegisterRecording", "-MonitorId", "Monitor2", "-Path", str(recording_input))
    assert (active / "theme.json").read_bytes() == active_before_registration
    assert run("Sync", "-MonitorId", "Monitor2")["changed"]
    assert not list(state.glob(".studio-record-*")), "Recording staging artifacts remain"
    assert json.loads(pref_path.read_text())["themes"]["unrelated"]["transparency"] == 37
    # A bad mapping cannot escape the saved-theme library.
    mapping_good = mapping_path.read_bytes()
    mapping_bad = json.loads(mapping_good)
    mapping_bad["recordings"]["222"]["themeId"] = "../../escape"
    mapping_path.write_text(json.dumps(mapping_bad), encoding="utf-8")
    assert not run("Status")["monitorEntries"][2]["canSync"]
    run("RegisterRecording", "-MonitorId", "Monitor2", "-Path", str(recording_input), expected_ok=False)
    mapping_path.write_bytes(mapping_good)
    # A recording cannot be linked to a different scene selected mid-register.
    with (scripts / "theme-windows.ps1").open("a", encoding="utf-8") as stream:
        stream.write(r'''
$script:LinkFixtureOriginalWriteTheme=${function:Write-DreamSkinTheme}
function Write-DreamSkinTheme {
  param([string]$ThemeDirectory,[object]$Theme)
  & $script:LinkFixtureOriginalWriteTheme -ThemeDirectory $ThemeDirectory -Theme $Theme
  if($env:LINK_TEST_REG_RACE -eq '1' -and $ThemeDirectory.Contains('.studio-record-')){
    $p=$env:LINK_TEST_CONFIG;$c=[IO.File]::ReadAllText($p)|ConvertFrom-Json
    $c.fixture.general.wallpaperconfig.selectedwallpapers.Monitor2.file=$env:LINK_TEST_OTHER_SCENE
    [IO.File]::WriteAllText($p,($c|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
  }
}
''')
    environment["LINK_TEST_REG_RACE"] = "1"
    environment["LINK_TEST_CONFIG"] = str(config_path)
    environment["LINK_TEST_OTHER_SCENE"] = str(projects["3650475846"])
    reg_race_before = [(path, path.read_bytes()) for path in (active / "theme.json", pref_path, link_prefs,
                      mapping_path, generic_saved / "theme.json", generic_saved / "background.mp4")]
    run("RegisterRecording", "-MonitorId", "Monitor2", "-Path", str(recording_input), expected_ok=False)
    assert all(path.read_bytes() == value for path, value in reg_race_before)
    assert not list(state.glob(".studio-record-*"))
    environment.pop("LINK_TEST_REG_RACE")
    config_path.write_text(json.dumps(config), encoding="utf-8")

    # Simulate an external config change while the DreamSkin operation lock is
    # held. The source backend fixture mutates only its fake WE config.
    with (scripts / "theme-windows.ps1").open("a", encoding="utf-8") as stream:
        stream.write("\nfunction New-DreamSkinPerformanceProxy { param($Reference,$StateRoot) "
                     "$p=$env:LINK_TEST_CONFIG; $c=[IO.File]::ReadAllText($p)|ConvertFrom-Json; "
                     "$c.fixture.general.wallpaperconfig.selectedwallpapers.Monitor0.file=$env:LINK_TEST_OTHER; "
                     "[IO.File]::WriteAllText($p,($c|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false)); return $null }\n")
    environment["LINK_TEST_CONFIG"] = str(config_path)
    environment["LINK_TEST_OTHER"] = str(projects["222"])
    rollback_before = [(path, path.read_bytes()) for path in (active / "theme.json", native_saved / "theme.json", pref_path, link_prefs)]
    run("Sync", "-MonitorId", "Monitor0", expected_ok=False)
    assert all(path.read_bytes() == value for path, value in rollback_before), "Source race rollback changed theme/preferences"
    assert not list(state.glob(".studio-link-*")), "Completed transaction artifacts remain"
    print(json.dumps({"ok": True, "fixture": str(fixture), "checks": [
        "read-only saved-config status", "multiple monitors and selection", "follow defaults off",
        "automatic disabled/mismatched monitor no write", "native video direct reference and library save",
        "75-percent media and preferences preserved", "no-change no writes", "recorded Nijika no recording",
        "stable default native colors", "project RGB scheme becomes matching accents", "disabled and unsupported no preference writes",
        "generic recording registers without switching active theme", "registration preserves opacity and preferences",
        "legacy Nijika seed persists on sync", "scene updates invalidate mapping and retain old favorite",
        "stale recording snapshot rejected", "reregister reuses stable theme ID",
        "fresh recording revision syncs unchanged scene", "mapped theme traversal rejected", "scene switch during registration rolls back",
        "unsupported scene preserves theme", "path escape rejected", "source race rollback", "transaction cleanup"]}))


if __name__ == "__main__":
    main()
