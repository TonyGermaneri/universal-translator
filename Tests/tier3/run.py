#!/usr/bin/env python3
"""Tier 3: the built app, live. Each test launches build/Universal Translator.app with test hooks (isolated
settings, debug log, audio from a file or a tapped process) and checks what it did, so these are the end-to-end
checks behind the macOS 15 port and the Dock icon.

  first_run_gate   macOS 15, no models: listening refuses and names the downloads (no Apple fallback)
  dock             in the Dock by default; with "menu bar only", only while Settings or the transcript is open
  overlay_display  a position saved on a display (as a drag saves it) puts the captions there, on each display
  overlay_grip     hovering over the captions shows the move grip; it leaves with the pointer; none when locked
                   (moves the mouse pointer, and puts it back)
  model_import     hand-downloaded models (copies of the real ones) are checked and installed; a corrupt one isn't
  engine_llamacpp  Nemotron + Silero VAD + Smart Turn + Hy-MT2 1.8B (llama.cpp), scripts/evaluate.py's passages
  engine_mlx       the same with Hy-MT2 1.8B on MLX
  system_audio     a tapped process (UT_TAP_PID), launched with `open` so the app asks for its own permission
  mic              the real microphone hearing speech the Mac says aloud (only with --speaker: it plays out loud)

usage: Tests/tier3/run.py [--only NAME ...] [--speaker] [--quick] [--keep DIR]
  --quick   two passages per engine instead of four
Build first (scripts/build-app.sh). Needs the models downloaded; a test that can't run says why and counts as a skip,
listed at the end. One run at a time: it refuses to start while any copy of the app is running.
"""
import argparse
import importlib.util
import json
import os
import platform
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
APP = os.path.join(ROOT, "build", "Universal Translator.app")
BIN = os.path.join(APP, "Contents", "MacOS", "UniversalTranslator")
SUITE = "ut.tier3"
MODELS = os.path.expanduser("~/Library/Application Support/Universal Translator/Models")
# Local names from LocalModels.swift (the files or folders isDownloaded checks).
NEEDED = {
    "Nemotron (Latin)": "nemotron-asr-latin-560ms",
    "Silero VAD": "silero-vad-unified-v6.0.0.mlmodelc",
    "Smart Turn": "smart_turn.mlmodelc",
}
LIVE = {"llamaCpp": ("Hy-MT2 1.8B", "Hy-MT2-1.8B-Q4_K_M.gguf"), "mlx": ("Hy-MT2 1.8B (MLX)", "hy-mt2-1.8b-8bit-mlx")}
# The model id each engine's runner logs its generations under ("LLM <id> ...").
LIVE_ID = {"llamaCpp": "hy-mt2-1.8b-q4", "mlx": "hy-mt2-1.8b-mlx-8bit"}

spec = importlib.util.spec_from_file_location("evaluate", os.path.join(ROOT, "scripts", "evaluate.py"))
evaluate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(evaluate)


class Skip(Exception):
    pass


def macos_major():
    return int(platform.mac_ver()[0].split(".")[0])


def settings(**fields):
    """Isolated settings (UT_DEFAULTS_SUITE) on top of the app's defaults."""
    s = {"hasCompletedFirstRun": True, "targetLanguage": "ja", "sourceLocale": "en-US", "recognizer": "nemotron",
         "translation": {"backend": "localLLM", "revision": "off", "localEngine": "llamaCpp"}}
    s.update(fields)
    subprocess.run(["defaults", "delete", SUITE], capture_output=True)
    subprocess.run(["defaults", "import", SUITE, "-"], input=plistlib.dumps({"settings.v1": json.dumps(s).encode()}),
                   check=True)


def quit_app():
    subprocess.run(["pkill", "-x", "UniversalTranslator"], capture_output=True)
    for _ in range(50):
        if subprocess.run(["pgrep", "-x", "UniversalTranslator"], capture_output=True).returncode != 0:
            return
        time.sleep(0.1)


def launch(env, via_open=False):
    """The app with test hooks. `open` makes the app responsible for its own permissions; run directly, it borrows
    the terminal's (fine for the microphone, but macOS refuses system-audio recording to most terminals)."""
    env = dict(env, UT_DEFAULTS_SUITE=SUITE)
    if via_open:
        args = ["open", "-n"]
        for k, v in env.items():
            args += ["--env", f"{k}={v}"]
        subprocess.run(args + [APP], check=True)
    else:
        subprocess.Popen([BIN], env=dict(os.environ, **env), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def wait_for(path, pattern, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if os.path.exists(path) and re.search(pattern, open(path, encoding="utf-8").read()):
            return True
        time.sleep(0.3)
    return False


def say(text, out=None):
    subprocess.run(["say", "-r", "160"] + (["-o", out] if out else []) + [text], check=True)


def sentences(log):
    return [json.loads(m) for m in re.findall(r"\] SENTENCE (\{.*\})", log)]


def stalled_at(passage_text, log):
    """None if the recognized text reaches the passage's last words; otherwise the last log time, in seconds.
    Seen 2026-10-23: a llama.cpp run that stopped logging mid-passage (no crash), which otherwise only shows as a
    high word error rate."""
    words = evaluate.normalize_words(passage_text)[-3:]
    heard = evaluate.normalize_words(" ".join(s["source"] for s in sentences(log)))
    if any(heard[i:i + 3] == words for i in range(len(heard))):
        return None
    times = re.findall(r"^\[ *([\d.]+)\]", log, re.M)
    return float(times[-1]) if times else 0.0


def require_models(*names):
    missing = [n for n, local in names if not os.path.exists(os.path.join(MODELS, local))]
    if missing:
        raise Skip("not downloaded: " + ", ".join(missing))


# ------------------------------------------------------------------------------------------------------ tests

def test_first_run_gate(work, args):
    if macos_major() >= 26:
        raise Skip("macOS 26 falls back to Apple's engines; the gate is for earlier systems")
    settings()
    log, audio = os.path.join(work, "gate.log"), os.path.join(work, "hello.aiff")
    say("Good morning everyone.", audio)
    empty = tempfile.mkdtemp(dir=work)
    launch({"UT_MODELS_DIR": empty, "UT_AUDIO_FILE": audio, "UT_DEBUG_LOG": log, "UT_AUTOSTART": "1"})
    ok = wait_for(log, r"START failed", 20)
    quit_app()
    text = open(log, encoding="utf-8").read() if os.path.exists(log) else ""
    assert ok, "listening didn't fail without models (it should refuse, not fall back)"
    for part in ("Download NVIDIA Nemotron Speech", "Hy-MT2 1.8B", "Settings → General", "macOS 26"):
        assert part in text, f"the error doesn't mention {part!r}: {text.strip()[-300:]}"
    assert "RECOGNIZER" not in text, "a recognizer started anyway"
    return "refused, naming both models"


def test_dock(work, args):
    def app_type():
        time.sleep(3)
        pid = subprocess.run(["pgrep", "-nx", "UniversalTranslator"], capture_output=True, text=True).stdout.strip()
        out = subprocess.run(["lsappinfo", "info", "-only", "ApplicationType", pid], capture_output=True, text=True).stdout
        quit_app()
        return out.rsplit("=", 1)[-1].strip().strip('"')
    results = {}
    for name, extra, menu_bar_only in (("default", {}, False), ("menu bar only", {}, True),
                                       ("menu bar only + settings", {"UT_OPEN": "settings"}, True),
                                       ("menu bar only + transcript", {"UT_OPEN": "transcript"}, True)):
        settings(menuBarOnly=menu_bar_only)
        launch(extra)
        results[name] = app_type()
    expected = {"default": "Foreground", "menu bar only": "UIElement", "menu bar only + settings": "Foreground",
                "menu bar only + transcript": "Foreground"}
    assert results == expected, f"got {results}, expected {expected}"
    return "in the Dock by default; menu bar only hides it until a window opens"


def test_model_import(work, args):
    """A hand-downloaded model (copies of the real downloads) is checked and installed by the app; a corrupted copy
    is refused and leaves nothing behind."""
    require_models(("Silero VAD", NEEDED["Silero VAD"]), LIVE["llamaCpp"])
    settings()
    results = []
    for label, model_id, local, corrupt in (("Silero VAD folder", "silero-vad-v6", NEEDED["Silero VAD"], False),
                                            ("Hy-MT2 1.8B file", "hy-mt2-1.8b-q4", LIVE["llamaCpp"][1], False),
                                            ("corrupted Silero VAD", "silero-vad-v6", NEEDED["Silero VAD"], True)):
        source = os.path.join(work, f"download-{len(results)}", local)
        os.makedirs(os.path.dirname(source))
        subprocess.run(["cp", "-cR", os.path.join(MODELS, local), source], check=True)  # APFS clone: instant
        if corrupt:
            with open(os.path.join(source, "weights", "weight.bin"), "ab") as f:
                f.write(b"\0")
        models, log = tempfile.mkdtemp(dir=work), os.path.join(work, f"import-{len(results)}.log")
        launch({"UT_MODELS_DIR": models, "UT_IMPORT_MODEL": f"{model_id}={source}", "UT_DEBUG_LOG": log})
        done = wait_for(log, rf"IMPORT {model_id} (ok|failed)", 60)
        quit_app()
        text = open(log, encoding="utf-8").read() if os.path.exists(log) else ""
        assert done, f"{label}: the app didn't finish the import"
        installed = os.path.exists(os.path.join(models, local))
        if corrupt:
            assert "failed" in text and "weights/weight.bin doesn't match its checksum" in text, f"{label}: {text.strip()}"
            assert not installed, f"{label}: installed anyway"
        else:
            assert f"IMPORT {model_id} ok" in text, f"{label}: {text.strip()}"
            assert installed, f"{label}: not in the models folder"
        results.append(label)
    return "imported " + ", ".join(results[:2]) + "; refused the corrupted copy"


def geometry(pid=None):
    out = subprocess.run(["swift", os.path.join(ROOT, "Tests", "tier3", "geometry.swift")] + ([str(pid)] if pid else []),
                         capture_output=True, text=True, check=True).stdout
    return json.loads(out)


def test_overlay_display(work, args):
    """A position saved on a display (as a drop saves it) puts the overlay on that display: each attached one."""
    screens = geometry()["screens"]
    placed = []
    for screen in screens[:2]:
        # First run shows sample captions to measure (and opens Settings, a layer-0 window).
        settings(hasCompletedFirstRun=False,
                 overlay={"anchor": "custom", "customX": 0.5, "customY": 0.5, "screenMode": "specific",
                          "screenName": screen["name"]})
        launch({})
        time.sleep(3)
        pid = subprocess.run(["pgrep", "-nx", "UniversalTranslator"], capture_output=True, text=True).stdout.strip()
        windows = geometry(pid)["windows"]
        quit_app()
        # The overlay panel, at whatever level the settings give it; Settings is layer 0, the menu bar icon 25.
        panel = [w for w in windows if w["onscreen"] and w["layer"] not in (0, 25) and w["w"] > 100]
        assert panel, f"no overlay on screen for {screen['name']}: {windows}"
        w = max(panel, key=lambda w: w["w"])
        cx = w["x"] + w["w"] / 2
        slack = 24
        assert screen["x"] - slack <= w["x"] and w["x"] + w["w"] <= screen["x"] + screen["w"] + slack \
            and screen["y"] - slack <= w["y"] and w["y"] + w["h"] <= screen["y"] + screen["h"] + slack, \
            f"overlay {w} isn't on {screen['name']} {screen}"
        assert abs(cx - (screen["x"] + screen["w"] / 2)) <= 0.05 * screen["w"], \
            f"overlay isn't centered on {screen['name']}: center {cx:.0f}, display {screen}"
        placed.append(f"{screen['name']} (at {w['x']:.0f},{w['y']:.0f})")
    detail = "placed on " + " and ".join(placed)
    return detail + ("" if len(screens) > 1 else " (only one display attached: the second-display case didn't run)")


def mouse(x=None, y=None):
    """Where the pointer is (and moves it to x, y first if given), in the same coordinates as geometry()."""
    cmd = ["swift", os.path.join(ROOT, "Tests", "tier3", "mouse.swift")] + ([str(x), str(y)] if x is not None else [])
    return [float(v) for v in subprocess.run(cmd, capture_output=True, text=True, check=True).stdout.split()]


def test_overlay_grip(work, args):
    """Hovering over the captions shows the move grip on their top edge; it goes when the pointer leaves, and never
    shows with the position locked. (Moves the mouse pointer, and puts it back.)"""
    def windows_with(**fields):
        # First run shows sample captions (and opens Settings, a layer-0 window).
        settings(hasCompletedFirstRun=False, overlay=fields)
        launch({})
        time.sleep(3)
        pid = subprocess.run(["pgrep", "-nx", "UniversalTranslator"], capture_output=True, text=True).stdout.strip()
        return pid
    def overlay_and_grip(pid):
        wins = [w for w in geometry(pid)["windows"] if w["onscreen"] and w["layer"] not in (0, 25)]
        captions = max(wins, key=lambda w: w["w"], default=None)
        grips = [w for w in wins if abs(w["w"] - 92) < 3 and abs(w["h"] - 26) < 3]
        return captions, (grips[0] if grips else None)
    home = mouse()
    try:
        pid = windows_with()
        captions, _ = overlay_and_grip(pid)
        assert captions, "no sample captions on screen"
        mouse(captions["x"] + captions["w"] / 2, captions["y"] + captions["h"] / 2)
        time.sleep(0.8)
        _, grip = overlay_and_grip(pid)
        assert grip, "hovering over the captions didn't show the grip"
        assert abs((grip["x"] + grip["w"] / 2) - (captions["x"] + captions["w"] / 2)) <= 4, f"grip {grip} not centered on {captions}"
        assert abs((grip["y"] + grip["h"] / 2) - captions["y"]) <= 4 or grip["y"] >= captions["y"], \
            f"grip {grip} isn't on the captions' top edge {captions}"
        mouse(captions["x"] + 5, max(0, captions["y"] - 300))   # well away from both
        time.sleep(1.5)
        _, grip = overlay_and_grip(pid)
        assert not grip, "the grip stayed after the pointer left"
        quit_app()

        pid = windows_with(lockPosition=True)
        captions, _ = overlay_and_grip(pid)
        assert captions, "no sample captions on screen (locked run)"
        mouse(captions["x"] + captions["w"] / 2, captions["y"] + captions["h"] / 2)
        time.sleep(0.8)
        _, grip = overlay_and_grip(pid)
        assert not grip, "the grip showed with the position locked"
    finally:
        quit_app()
        mouse(*home)
    return "grip on hover, gone after leaving, none when locked"


def test_reading_aid(work, args):
    """Reading aids on the sample captions: furigana (Japanese) and pinyin (Chinese) under the characters, on the
    translation line and on the original-speech line, which get taller by about the readings' size; Traditional
    characters in place of Simplified, which changes the text but not the height."""
    def panel_height(log, **fields):
        # First run shows sample captions (and opens Settings, a layer-0 window).
        settings(hasCompletedFirstRun=False, **fields)
        launch({"UT_DEBUG_LOG": log})
        time.sleep(3)
        pid = subprocess.run(["pgrep", "-nx", "UniversalTranslator"], capture_output=True, text=True).stdout.strip()
        wins = [w for w in geometry(pid)["windows"] if w["onscreen"] and w["layer"] not in (0, 25) and w["w"] > 100]
        quit_app()
        assert wins, f"no sample captions on screen: {fields}"
        return max(wins, key=lambda w: w["w"])["h"]
    font = 34   # the default caption size; the original speech is 55 % of it
    ja_target, ja_source = {"targetLanguage": "ja", "sourceLocale": "en-US"}, {"targetLanguage": "en", "sourceLocale": "ja-JP"}
    zh_target, zh_source = {"targetLanguage": "zh", "sourceLocale": "en-US"}, {"targetLanguage": "en", "sourceLocale": "zh-CN"}
    # (layout, line, languages, aids, text the log must show, height the readings add: None = no readings)
    cases = [(layout, line, langs, {"ja": "furigana"}, "本日(ほんじつ)はご参加(さんか)", size)
             for layout in ("rolling", "marquee")
             for line, langs, size in (("ja translation", ja_target, font), ("ja original speech", ja_source, font * 0.55))]
    cases += [("rolling", "zh translation", zh_target, {"zh": "pinyin"}, "感(gǎn)谢(xiè)大(dà)家(jiā)", font),
              ("rolling", "zh original speech", zh_source, {"zh": "pinyin,traditional"}, "感(gǎn)謝(xiè)", font * 0.55),
              ("marquee", "zh translation", zh_target, {"zh": "traditional"}, "感謝大家今天的參與", None)]
    offs, results = {}, []
    for layout, line, langs, aids, expected, size in cases:
        log = os.path.join(work, f"reading-{layout}-{line.replace(' ', '-')}-{len(results)}.log")
        key = (layout, json.dumps(langs, sort_keys=True))
        if key not in offs:
            offs[key] = panel_height(log + ".off", overlay={"layout": layout}, **langs)
        off = offs[key]
        on = panel_height(log, overlay={"layout": layout, "readingAids": aids}, **langs)
        text = open(log, encoding="utf-8").read() if os.path.exists(log) else ""
        label = f"{layout}, {line}, {aids}"
        assert expected in text, f"{label}: the log doesn't show {expected}: {text.strip()[:300]}"
        if size is None:
            assert abs(on - off) <= 2, f"{label}: captions {off:.0f} pt tall as written, {on:.0f} converted"
            results.append(f"{layout} {line} converted, same height")
        else:
            assert on - off >= 0.35 * size, f"{label}: captions {off:.0f} pt tall without readings, {on:.0f} with"
            results.append(f"{layout} {line} +{on - off:.0f} pt")
    return "; ".join(results)


def test_stall_capture(work, args):
    """The engine tests' evidence for a stuck app: evaluate.py samples an app whose log has gone quiet, and one that
    doesn't quit when asked, then kills it. Checked with a stand-in app that logs once, then ignores everything."""
    fake = os.path.join(work, "stuck-app")
    with open(fake, "w") as f:
        f.write("#!/bin/bash\ntrap '' TERM\necho '[   0.50] started' >> \"$UT_DEBUG_LOG\"\nwhile true; do sleep 1; done\n")
    os.chmod(fake, 0o755)
    opts = argparse.Namespace(voice="Samantha", tail=9.0, keep_logs=os.path.join(work, "stuck"), target="ja",
                              live="localLLM", revision="off", engine="llamaCpp", stability=0.5, vad="silero", turn="on",
                              recognizer="nemotron", lmstudio_url="", lmstudio_model="", lmstudio_template="automatic")
    real = evaluate.APP
    evaluate.APP = fake
    try:
        r = evaluate.run_passage("stuck", "Hello there.", opts, work)
    finally:
        evaluate.APP = real
    kept = sorted(os.listdir(opts.keep_logs))
    assert "stuck.sample.txt" in kept, f"a quiet log wasn't sampled: {kept}"
    assert "stuck.quit-sample.txt" in kept and r["slowQuit"], f"a slow quit wasn't sampled: {kept}"
    assert subprocess.run(["pgrep", "-f", fake], capture_output=True).returncode != 0, "the stuck app was left running"
    return "a quiet log and a slow quit are both sampled; the stuck app is killed"


def test_transcript(work, args):
    """With the transcript saved automatically, a live session (a spoken passage, llama.cpp) leaves one text file
    with every finished sentence: its clock time, what was said and the translation."""
    require_models(*NEEDED.items(), LIVE["llamaCpp"])
    folder = os.path.join(work, "transcripts")
    audio = os.path.join(work, "transcript.aiff")
    log = os.path.join(work, "transcript.log")
    say(evaluate.PASSAGES["questions"] + " [[slnc 2500]]", out=audio)
    duration = float(re.search(r"estimated duration: ([\d.]+)", subprocess.run(
        ["afinfo", audio], capture_output=True, text=True).stdout).group(1))
    settings(saveTranscript=True)
    launch({"UT_AUDIO_FILE": audio, "UT_AUTOSTART": "1", "UT_DEBUG_LOG": log, "UT_TRANSCRIPTS_DIR": folder})
    # Until the passage's last sentence is in, plus the 1 s before the file is rewritten. Seen 2026-10-25: the app
    # went quiet at 11 s (the llama.cpp stall, 4 reruns fine), which a fixed wait passed off as a short transcript.
    deadline, stuck = time.time() + duration + 20, None
    while time.time() < deadline:
        time.sleep(0.5)
        content = open(log, encoding="utf-8").read() if os.path.exists(log) else ""
        if stalled_at(evaluate.PASSAGES["questions"], content) is None:
            time.sleep(2)
            break
        if os.path.exists(log) and time.time() - os.path.getmtime(log) > 8:
            pid = subprocess.run(["pgrep", "-nx", "UniversalTranslator"], capture_output=True, text=True).stdout.strip()
            stuck = os.path.join(ROOT, ".build", f"stall-transcript-{time.strftime('%Y%m%d-%H%M%S')}")
            os.makedirs(stuck, exist_ok=True)
            if pid:
                subprocess.run(["sample", pid, "3", "-file", os.path.join(stuck, "sample.txt")], capture_output=True)
            shutil.copy(log, stuck)
            break
    quit_app()
    assert stuck is None, f"the app stalled mid-passage; log and process sample in {stuck}"
    finished = sentences(open(log, encoding="utf-8").read()) if os.path.exists(log) else []
    assert finished, "no sentence finished"
    saved = sorted(os.listdir(folder)) if os.path.isdir(folder) else []
    assert len(saved) == 1 and re.fullmatch(r"Transcript \d{4}-\d\d-\d\d \d\d\.\d\d\.\d\d\.txt", saved[0]), \
        f"expected one transcript file, found {saved}"
    text = open(os.path.join(folder, saved[0]), encoding="utf-8").read()
    assert text.startswith("Universal Translator transcript, ") and "English (United States) → Japanese" in text, text[:200]
    entries = re.findall(r"^\[(\d\d:\d\d:\d\d)\] (.+)\n→ (.+)$", text, re.M)
    assert len(entries) == len(finished), f"{len(finished)} sentences finished, {len(entries)} in the file:\n{text}"
    said = [e[1] for e in entries]
    for s in finished:
        assert s["source"] in said, f"not in the file: {s['source']}"
    return f"{len(entries)} sentences in {saved[0]}"


def engine(engine_name, work, args):
    require_models(*NEEDED.items(), LIVE[engine_name])
    logs = os.path.join(work, engine_name)
    cmd = [sys.executable, "-I", os.path.join(ROOT, "scripts", "evaluate.py"), "--revision", "off",
           "--engine", engine_name, "--keep-logs", logs]
    passages = ["meeting", "questions"] if args.quick else sorted(evaluate.PASSAGES)
    for p in passages:
        cmd += ["--passage", p]
    subprocess.run(cmd, check=True, capture_output=True)
    total, errors, words, live = 0, 0, 0, []
    for p in passages:
        log = open(os.path.join(logs, f"{p}.log"), encoding="utf-8").read()
        # The neural VAD and end-of-turn model, not the energy fallback a failed download leaves behind.
        assert "ENDPOINT vad=silero turn=smart-turn" in log, f"{p}: not on Silero VAD + Smart Turn"
        assert f"LLM {LIVE_ID[engine_name]} " in log, f"{p}: {LIVE[engine_name][0]} didn't translate anything"
        r = evaluate.parse(log)
        assert r["sentences"], f"{p}: no sentence finished"
        stall = stalled_at(evaluate.PASSAGES[p], log)
        slow_quit = os.path.exists(os.path.join(logs, f"{p}.quit-sample.txt"))
        if stall is not None or slow_quit:
            # evaluate.py sampled the stuck app; keep the samples and the log past the run's temporary folder.
            kept = os.path.join(ROOT, ".build", f"stall-{engine_name}-{p}-{time.strftime('%Y%m%d-%H%M%S')}")
            os.makedirs(kept, exist_ok=True)
            for f in (f"{p}.log", f"{p}.sample.txt", f"{p}.quit-sample.txt"):
                if os.path.exists(os.path.join(logs, f)):
                    shutil.copy(os.path.join(logs, f), kept)
        assert stall is None, f"{p}: the app stopped before the end of the passage (last log line at {stall:.1f} s); " \
                              f"log and process sample in {kept}"
        assert not slow_quit, f"{p}: the app took more than 10 s to quit; log and process sample in {kept}"
        for s in r["sentences"]:
            assert not s["replacedCommitted"], f"{p}: a final caption was replaced: {s['source']}"
            assert s["committedErasure"] == 0, f"{p}: text shown as final changed: {s['source']}"
        rate, n = evaluate.wer(evaluate.PASSAGES[p], " ".join(s["source"] for s in r["sentences"]))
        errors, words, total = errors + rate * n, words + n, total + len(r["sentences"])
        live += r["live"]
    wer = errors / max(1, words)
    p50 = sorted(live)[len(live) // 2] if live else float("nan")
    assert wer <= 0.05, f"word error rate {wer:.1%} (limit 5%)"
    assert p50 <= 600, f"live translation p50 {p50} ms (limit 600 ms)"
    return f"{total} sentences, WER {wer:.1%}, live p50 {p50} ms, nothing final changed"


def test_engine_llamacpp(work, args):
    return engine("llamaCpp", work, args)


def test_engine_mlx(work, args):
    return engine("mlx", work, args)


TAP_TEXT = "Where is the nearest train station? How long does it take to get there on foot?"


def test_system_audio(work, args):
    require_models(*NEEDED.items(), LIVE["llamaCpp"])
    settings(audioSource="systemAudio")
    audio, log = os.path.join(work, "tap.aiff"), os.path.join(work, "tap.log")
    # Silence first, so the tap (which mutes the process) is in place before the speech starts.
    say("[[slnc 6000]] Where is the nearest train station? [[slnc 1200]] "
        "How long does it take to get there on foot? [[slnc 2500]]", audio)
    player = subprocess.Popen(["afplay", audio])
    time.sleep(0.3)
    launch({"UT_TAP_PID": str(player.pid), "UT_DEBUG_LOG": log, "UT_AUTOSTART": "1"}, via_open=True)
    player.wait()
    time.sleep(4)
    quit_app()
    heard = sentences(open(log, encoding="utf-8").read()) if os.path.exists(log) else []
    assert heard, ("nothing heard from the tapped process. If macOS didn't ask, allow Universal Translator under "
                   "System Settings → Privacy & Security → Screen & System Audio Recording (ad-hoc builds lose it "
                   "on every rebuild)")
    rate, _ = evaluate.wer(TAP_TEXT, " ".join(s["source"] for s in heard))
    assert rate <= 0.15, f"word error rate {rate:.0%}: {[s['source'] for s in heard]}"
    return f"{len(heard)} sentences from the tapped process, WER {rate:.0%}"


MIC_TEXT = ("Good morning everyone, and thanks for joining the call. "
            "Today I want to talk about the launch timeline and the budget.")


def test_mic(work, args):
    if not args.speaker:
        raise Skip("plays speech out loud: pass --speaker")
    require_models(*NEEDED.items(), LIVE["llamaCpp"])
    settings(audioSource="microphone")
    log = os.path.join(work, "mic.log")
    launch({"UT_DEBUG_LOG": log, "UT_AUTOSTART": "1"})
    assert wait_for(log, r"ENDPOINT vad=", 30), "the app didn't start listening"
    time.sleep(2)
    say(MIC_TEXT)
    time.sleep(5)
    quit_app()
    heard = sentences(open(log, encoding="utf-8").read())
    assert heard, ("nothing heard: check the terminal's microphone permission (System Settings → Privacy & "
                   "Security → Microphone) and the speaker volume")
    rate, _ = evaluate.wer(MIC_TEXT, " ".join(s["source"] for s in heard))
    assert rate <= 0.15, f"word error rate {rate:.0%}: {[s['source'] for s in heard]}"
    return f"{len(heard)} sentences from the microphone, WER {rate:.0%}"


TESTS = [("first_run_gate", test_first_run_gate), ("dock", test_dock), ("overlay_display", test_overlay_display),
         ("overlay_grip", test_overlay_grip), ("reading_aid", test_reading_aid), ("model_import", test_model_import),
         ("stall_capture", test_stall_capture), ("transcript", test_transcript),
         ("engine_llamacpp", test_engine_llamacpp),
         ("engine_mlx", test_engine_mlx), ("system_audio", test_system_audio), ("mic", test_mic)]


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--only", action="append", choices=[n for n, _ in TESTS])
    p.add_argument("--speaker", action="store_true", help="allow the microphone test (plays speech out loud)")
    p.add_argument("--quick", action="store_true", help="two passages per engine instead of four")
    p.add_argument("--keep", metavar="DIR", help="keep logs here")
    args = p.parse_args()
    if not os.access(BIN, os.X_OK):
        sys.exit(f"No app at {APP}: run scripts/build-app.sh")
    if subprocess.run(["pgrep", "-x", "UniversalTranslator"], capture_output=True).returncode == 0:
        sys.exit("Universal Translator is running (another tier3 run, or the app itself): quit it first")

    work = args.keep or tempfile.mkdtemp(prefix="ut-tier3-")
    os.makedirs(work, exist_ok=True)
    print(f"tier3: macOS {platform.mac_ver()[0]}, logs in {work}")
    results = []
    try:
        for name, test in TESTS:
            if args.only and name not in args.only:
                continue
            started = time.time()
            try:
                detail = test(work, args)
                results.append((name, "pass", detail))
            except Skip as e:
                results.append((name, "skip", str(e)))
            except (AssertionError, subprocess.CalledProcessError) as e:
                results.append((name, "FAIL", str(e) or type(e).__name__))
            finally:
                quit_app()
            print(f"  {results[-1][1]:4}  {name:16} {time.time() - started:5.0f} s  {results[-1][2]}", flush=True)
    finally:
        subprocess.run(["defaults", "delete", SUITE], capture_output=True)
        if not args.keep:
            shutil.rmtree(work, ignore_errors=True)
    counts = {k: sum(1 for r in results if r[1] == k) for k in ("pass", "FAIL", "skip")}
    print(f"tier3: {counts['pass']} passed, {counts['FAIL']} failed, {counts['skip']} skipped")
    for name, status, detail in results:
        if status == "skip":
            print(f"  skipped {name}: {detail}")
    sys.exit(1 if counts["FAIL"] else 0)


if __name__ == "__main__":
    main()
