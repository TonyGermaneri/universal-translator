#!/usr/bin/env python3
"""Headless evaluation of live translation quality-of-experience.

Synthesizes test passages with macOS `say`, plays each through the built app in real time
(UT_AUDIO_FILE) with isolated settings (UT_DEFAULTS_SUITE), and summarizes the debug log:

  live latency        time per live translation update (p50 / p95)
  first output        time from the first stable source word of an utterance to its first caption
  finish latency      time from the end of an utterance to its final translation on screen
  after speech        time from the end of the speaker's speech to the final translation on screen
  turn                end-of-turn detection delay (end of speech → turn ended) and how it was decided
  erasure (NE)        visible characters taken back / final length (lower = steadier captions);
                      "committed" counts only text shown as final
  replaced            utterances whose final translation contradicted committed text
  revisions           second-pass revisions applied / evaluated
  WER                 word error rate of the recognized text that was translated, against the script

usage: scripts/evaluate.py [--target ja] [--live apple|appleIntelligence|lmStudio|none]
                           [--revision off|appleHighFidelity|appleIntelligence|lmStudio]
                           [--stability 0.5] [--passage NAME] [--vad silero|energy] [--turn on|off]
Build the app first (scripts/build-app.sh).
"""
import argparse
import json
import os
import plistlib
import re
import statistics
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, "build", "Universal Translator.app", "Contents", "MacOS", "UniversalTranslator")
SUITE = "ut.eval"

PASSAGES = {
    "meeting": "Good morning everyone, and thanks for joining the call. Today I want to walk through three things: "
               "the launch timeline, the budget, and the hiring plan. [[slnc 700]] First, the timeline. We were hoping "
               "to ship in March, but because the vendor delivered the hardware late, we are now looking at the end of "
               "April. [[slnc 900]] That gives us about six weeks to finish testing, which is tight but doable if we keep "
               "the scope where it is. [[slnc 1200]] Any questions so far?",
    "technical": "The new caching layer sits between the application servers and the database. [[slnc 600]] When a "
                 "request comes in, we first check whether the result is already cached, and if it is, we return it "
                 "immediately without touching the database. [[slnc 800]] Otherwise we run the query, store the result "
                 "with a five minute expiry, and then respond. [[slnc 700]] In our tests this cut the average response "
                 "time from two hundred milliseconds to about forty.",
    "questions": "Where is the nearest train station? [[slnc 1200]] How long does it take to get there on foot? "
                 "[[slnc 1200]] Could you recommend a good place for lunch nearby? [[slnc 1200]] Thank you so much, "
                 "that is really helpful.",
    "monologue": "So what I keep coming back to is that the people who actually use the product every day are not the "
                 "people who buy it and that means the feedback we get from sales is always one step removed from what "
                 "is really happening on the ground which is why I think we need to spend more time with the support "
                 "team and less time in planning meetings that only include managers.",
}


def defaults_for(args):
    settings = {
        "targetLanguage": args.target,
        "sourceLocale": "en-US",
        "hasCompletedFirstRun": True,
        "recognizer": args.recognizer,
        "translation": {"backend": args.live, "revision": args.revision, "localEngine": args.engine, "lmStudioURL": args.lmstudio_url,
                        "lmStudioModel": args.lmstudio_model, "lmStudioTemplate": args.lmstudio_template},
        "timing": {"stability": args.stability, "neuralVAD": args.vad == "silero", "smartTurn": args.turn == "on"},
    }
    return {"settings.v1": json.dumps(settings).encode()}


def run_passage(name, text, args, workdir):
    audio = os.path.join(workdir, f"{name}.aiff")
    log = os.path.join(workdir, f"{name}.log")
    subprocess.run(["say", "-v", args.voice, "-r", "175", "-o", audio, text + " [[slnc 2500]]"], check=True)
    duration = float(re.search(r"estimated duration: ([\d.]+)", subprocess.run(
        ["afinfo", audio], capture_output=True, text=True).stdout).group(1))
    subprocess.run(["defaults", "delete", SUITE], capture_output=True)
    subprocess.run(["defaults", "import", SUITE, "-"], input=plistlib.dumps(defaults_for(args)), check=True)
    env = dict(os.environ, UT_DEFAULTS_SUITE=SUITE, UT_AUDIO_FILE=audio, UT_DEBUG_LOG=log, UT_AUTOSTART="1")
    proc = subprocess.Popen([APP], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(duration + args.tail)
    proc.terminate()
    proc.wait(timeout=10)
    if args.keep_logs and os.path.exists(log):
        os.makedirs(args.keep_logs, exist_ok=True)
        subprocess.run(["cp", log, os.path.join(args.keep_logs, f"{name}.log")])
    r = parse(open(log, encoding="utf-8").read() if os.path.exists(log) else "")
    r["wer"] = wer(text, " ".join(x.get("source", "") for x in r["sentences"]))
    return r


def parse(log):
    live = [int(m) for m in re.findall(r"\] LIVE +(\d+)ms", log)]
    sentences = [json.loads(m) for m in re.findall(r"\] SENTENCE (\{.*\})", log)]
    accepted = len(re.findall(r"\] REVISE .*accept\(", log))
    evaluated = len(re.findall(r"\] REVISE +\d+ms", log))
    turns = [(int(ms), reason) for ms, reason in re.findall(r"\] TURN end .*\(\+(\d+) ms\) p=\S+ (\w+)", log)]
    return {"live": live, "sentences": sentences, "revised": accepted, "reviewed": evaluated, "turns": turns}


ONES = "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen " \
       "seventeen eighteen nineteen".split()
TENS = "_ _ twenty thirty forty fifty sixty seventy eighty ninety".split()


def number_words(n):
    if n < 20:
        return ONES[n]
    if n < 100:
        return TENS[n // 10] + ("" if n % 10 == 0 else " " + ONES[n % 10])
    if n < 1000:
        return ONES[n // 100] + " hundred" + ("" if n % 100 == 0 else " " + number_words(n % 100))
    return str(n)


def normalize_words(text):
    text = re.sub(r"\[\[.*?\]\]", " ", text.lower())
    text = re.sub(r"\d+", lambda m: " " + number_words(int(m.group())) + " ", text)
    return re.sub(r"[^a-z' ]+", " ", text).replace("'", "").split()


def wer(reference, hypothesis):
    r, h = normalize_words(reference), normalize_words(hypothesis)
    d = list(range(len(h) + 1))
    for i in range(1, len(r) + 1):
        prev, d[0] = d[0], i
        for j in range(1, len(h) + 1):
            cur = min(d[j] + 1, d[j - 1] + 1, prev + (r[i - 1] != h[j - 1]))
            prev, d[j] = d[j], cur
    return d[len(h)] / max(1, len(r)), len(r)


def pct(values, q):
    if not values:
        return float("nan")
    values = sorted(values)
    return values[min(len(values) - 1, int(round(q * (len(values) - 1))))]


def summarize(name, r):
    s = r["sentences"]
    live = r["live"][1:] or r["live"]  # first call includes model warm-up
    def mean(key):
        values = [x[key] for x in s if x.get(key, -1) >= 0]
        return statistics.mean(values) if values else float("nan")
    replaced = sum(1 for x in s if x["replacedCommitted"])
    turns = r.get("turns", [])
    turn_ms = statistics.mean([t for t, _ in turns]) if turns else float("nan")
    by_model = sum(1 for _, reason in turns if reason == "model")
    return (f"{name:10s} utt {len(s):2d} | live p50 {pct(live, .5):4.0f} p95 {pct(live, .95):5.0f} ms | "
            f"first {mean('firstOutputMs'):5.0f} ms | finish {mean('finishAfterCompleteMs'):5.0f} ms | "
            f"after speech {mean('finishAfterSpeechMs'):5.0f} ms | turn +{turn_ms:4.0f} ms ({by_model}/{len(turns)} model) | "
            f"NE {mean('normalizedErasure'):.2f} (committed {mean('committedErasure'):.2f}) | "
            f"replaced {replaced}/{len(s)} | revised {r['revised']}/{r['reviewed']} | WER {r['wer'][0]:.1%}")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--target", default="ja")
    p.add_argument("--live", default="localLLM")
    p.add_argument("--revision", default="localLLMLarge")
    p.add_argument("--stability", type=float, default=0.5)
    p.add_argument("--voice", default="Samantha")
    p.add_argument("--recognizer", choices=["nemotron", "appleSpeech"], default="nemotron")
    p.add_argument("--engine", choices=["llamaCpp", "mlx"], default="llamaCpp", help="runtime for the Hy-MT2 models")
    p.add_argument("--vad", choices=["silero", "energy"], default="silero")
    p.add_argument("--lmstudio-url", default="http://localhost:1234")
    p.add_argument("--lmstudio-model", default="")
    p.add_argument("--lmstudio-template", default="automatic")
    p.add_argument("--turn", choices=["on", "off"], default="on")
    p.add_argument("--passage", choices=sorted(PASSAGES), action="append")
    p.add_argument("--tail", type=float, default=5.0, help="seconds to keep running after the audio ends")
    p.add_argument("--keep-logs", metavar="DIR", help="copy each passage's debug log here")
    args = p.parse_args()
    if not os.path.exists(APP):
        sys.exit("Build the app first: scripts/build-app.sh")
    subprocess.run(["pkill", "-x", "UniversalTranslator"], capture_output=True)
    names = args.passage or list(PASSAGES)
    print(f"target={args.target} live={args.live} revision={args.revision} engine={args.engine} stability={args.stability} "
          f"vad={args.vad} turn={args.turn} recognizer={args.recognizer}")
    all_live, all_sentences, all_turns, revised, reviewed = [], [], [], 0, 0
    errors, ref_words = 0.0, 0
    with tempfile.TemporaryDirectory() as workdir:
        for name in names:
            r = run_passage(name, PASSAGES[name], args, workdir)
            print(summarize(name, r), flush=True)
            all_live += r["live"][1:]
            all_sentences += r["sentences"]
            all_turns += r["turns"]
            errors += r["wer"][0] * r["wer"][1]
            ref_words += r["wer"][1]
            revised += r["revised"]
            reviewed += r["reviewed"]
    print(summarize("overall", {"live": [0] + all_live, "sentences": all_sentences, "revised": revised,
                                "reviewed": reviewed, "turns": all_turns, "wer": (errors / max(1, ref_words), ref_words)}))
    subprocess.run(["defaults", "delete", SUITE], capture_output=True)


if __name__ == "__main__":
    main()
