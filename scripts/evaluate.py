#!/usr/bin/env python3
"""Headless evaluation of live translation quality-of-experience.

Synthesizes test passages with macOS `say`, plays each through the built app in real time
(UT_AUDIO_FILE) with isolated settings (UT_DEFAULTS_SUITE), and summarizes the debug log:

  live latency        time per live translation update (p50 / p95)
  first output        time from the first stable source word of an utterance to its first caption, and from the
                      first spoken word (in Japanese and Chinese no word is stable before the utterance ends)
  finish latency      time from the end of an utterance to its final translation on screen
  after speech        time from the end of the speaker's speech to the final translation on screen
  turn                end-of-turn detection delay (end of speech → turn ended) and how it was decided
  erasure (NE)        visible characters taken back / final length (lower = steadier captions);
                      "committed" counts only text shown as final
  replaced            utterances whose final translation contradicted committed text
  revisions           second-pass revisions applied / evaluated
  memory              the app's peak resident memory, beside the estimate Settings shows (MemoryEstimate)
  WER / CER           recognition error against the script: word error rate for English and Korean, character
                      error rate for Japanese and Chinese (Korean also shows its CER: spacing varies)
  chrF                how close the captions, as finally shown (after any second-pass revision), are to the
                      passage's reference translation: character n-gram F-score, 0-100; "first pass" is the same
                      before revisions, and "revised … s later" how long after its caption a revision landed

--source picks the speech language and its macOS voice (SOURCES): en-US (Samantha), ja-JP (Kyoko), zh-CN (Tingting),
zh-TW (Meijia), ko-KR (Yuna). Every language has the same four passages; each serves as the reference translation for
the others (the English ones for ja/zh/ko → en, the Japanese ones for en → ja).

--script-only LLM_BENCH skips the app and the speech: it translates the scripts sentence by sentence and scores them,
which separates the translation model's share of chrF from recognition and streaming.

usage: scripts/evaluate.py [--source en-US|ja-JP|zh-CN|zh-TW|ko-KR] [--target ja] [--script-only LLM_BENCH]
                           [--live apple|appleIntelligence|lmStudio|none]
                           [--revision off|appleHighFidelity|appleIntelligence|lmStudio]
                           [--stability 0.5] [--passage NAME] [--vad silero|energy] [--turn on|off]
Build the app first (scripts/build-app.sh).
"""
import argparse
import collections
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

# The same four passages in Japanese, Chinese (Simplified for zh-CN, Taiwanese wording in Traditional for zh-TW) and
# Korean, pauses in the same places. Each language's passages are the reference translation for speech in another:
# the English above for ja/zh/ko → en, and the Japanese for en → ja.
JA = {
    "meeting": "皆さん、おはようございます。会議にご参加いただきありがとうございます。今日は三つのことについてお話ししたいと思います。"
               "発売のスケジュール、予算、そして採用計画です。[[slnc 700]] まず、スケジュールです。3月の出荷を目指していましたが、"
               "ベンダーからのハードウェアの納品が遅れたため、現在は4月末を見込んでいます。[[slnc 900]] テストを終えるまで約6週間ですが、"
               "範囲を今のままに保てば、厳しいながらも可能です。[[slnc 1200]] ここまでで何か質問はありますか？",
    "technical": "新しいキャッシュ層は、アプリケーションサーバーとデータベースの間にあります。[[slnc 600]] リクエストが来ると、"
                 "まず結果がすでにキャッシュされているかを確認し、キャッシュされていれば、データベースにアクセスせずにすぐに返します。"
                 "[[slnc 800]] そうでなければ、クエリを実行し、結果を5分間の有効期限付きで保存してから応答します。[[slnc 700]] "
                 "テストでは、これにより平均応答時間が200ミリ秒から約40ミリ秒に短縮されました。",
    "questions": "一番近い駅はどこですか？[[slnc 1200]] 歩いてどのくらいかかりますか？[[slnc 1200]] "
                 "この近くでおすすめのランチの場所はありますか？[[slnc 1200]] 本当にありがとうございます、とても助かります。",
    "monologue": "結局私が何度も考えてしまうのは、毎日実際に製品を使っている人たちは、それを購入する人たちではないということで、"
                 "つまり営業から得られるフィードバックは、現場で実際に起きていることから常に一歩離れているということで、"
                 "だからこそ私たちはサポートチームともっと時間を過ごし、マネージャーだけが参加する企画会議に使う時間を減らすべきだと思うんです。",
}
ZH_CN = {
    "meeting": "大家早上好，感谢各位参加这次电话会议。今天我想讲三件事：发布时间表、预算和招聘计划。[[slnc 700]] "
               "首先是时间表。我们原本希望在三月发货，但由于供应商交付硬件延迟，现在预计要到四月底。[[slnc 900]] "
               "这样我们大约有六周时间完成测试，时间很紧，但只要保持现有范围，还是可以做到的。[[slnc 1200]] 到目前为止有什么问题吗？",
    "technical": "新的缓存层位于应用服务器和数据库之间。[[slnc 600]] 当请求进来时，我们先检查结果是否已经缓存，如果已经缓存，"
                 "就直接返回，不访问数据库。[[slnc 800]] 否则，我们执行查询，把结果以五分钟的过期时间保存起来，然后再响应。"
                 "[[slnc 700]] 在我们的测试中，这把平均响应时间从两百毫秒降到了大约四十毫秒。",
    "questions": "最近的火车站在哪里？[[slnc 1200]] 走路过去要多长时间？[[slnc 1200]] 你能推荐附近一个吃午饭的好地方吗？"
                 "[[slnc 1200]] 非常感谢，这真的很有帮助。",
    "monologue": "所以我一直在想的是，每天真正使用产品的人并不是购买产品的人，这意味着我们从销售那里得到的反馈总是和实际发生的情况"
                 "隔着一层，这就是为什么我认为我们需要花更多时间和支持团队在一起，少花时间开那些只有经理参加的规划会议。",
}
ZH_TW = {
    "meeting": "大家早安，感謝各位參加這次電話會議。今天我想談三件事：上市時程、預算和招募計畫。[[slnc 700]] "
               "首先是時程。我們原本希望在三月出貨，但因為供應商交付硬體延遲，現在預計要到四月底。[[slnc 900]] "
               "這樣我們大約有六週的時間完成測試，時間很緊，但只要維持目前的範圍，還是做得到的。[[slnc 1200]] 到目前為止有什麼問題嗎？",
    "technical": "新的快取層位於應用程式伺服器和資料庫之間。[[slnc 600]] 當請求進來時，我們會先檢查結果是否已經快取，如果已經快取，"
                 "就直接回傳，不存取資料庫。[[slnc 800]] 否則，我們會執行查詢，把結果以五分鐘的有效期限儲存起來，然後再回應。"
                 "[[slnc 700]] 在我們的測試中，這讓平均回應時間從兩百毫秒降到大約四十毫秒。",
    "questions": "最近的火車站在哪裡？[[slnc 1200]] 走路過去要多久？[[slnc 1200]] 你可以推薦附近一個吃午餐的好地方嗎？"
                 "[[slnc 1200]] 非常謝謝你，這真的很有幫助。",
    "monologue": "所以我一直在想的是，每天真正在使用產品的人並不是購買產品的人，這表示我們從業務那邊得到的回饋總是和實際發生的狀況"
                 "隔了一層，這就是為什麼我認為我們需要花更多時間跟客服團隊相處，少花時間開那些只有主管參加的規劃會議。",
}
KO = {
    "meeting": "여러분 안녕하세요, 통화에 참여해 주셔서 감사합니다. 오늘은 세 가지를 살펴보려고 합니다. 출시 일정, 예산, 그리고 "
               "채용 계획입니다. [[slnc 700]] 먼저 일정입니다. 3월에 출시하기를 바랐지만, 공급업체가 하드웨어를 늦게 납품해서 "
               "지금은 4월 말을 예상하고 있습니다. [[slnc 900]] 그러면 테스트를 마치는 데 약 6주가 남는데, 범위를 지금대로 "
               "유지한다면 빠듯하지만 가능합니다. [[slnc 1200]] 지금까지 질문 있으신가요?",
    "technical": "새 캐시 계층은 애플리케이션 서버와 데이터베이스 사이에 있습니다. [[slnc 600]] 요청이 들어오면 먼저 결과가 이미 "
                 "캐시되어 있는지 확인하고, 캐시되어 있으면 데이터베이스를 거치지 않고 바로 반환합니다. [[slnc 800]] 그렇지 "
                 "않으면 쿼리를 실행하고, 결과를 5분 만료 시간으로 저장한 다음 응답합니다. [[slnc 700]] 테스트에서 이를 통해 "
                 "평균 응답 시간이 200밀리초에서 약 40밀리초로 줄었습니다.",
    "questions": "가장 가까운 기차역이 어디예요? [[slnc 1200]] 걸어서 얼마나 걸려요? [[slnc 1200]] 근처에 점심 먹기 좋은 곳을 "
                 "추천해 주실 수 있나요? [[slnc 1200]] 정말 감사합니다, 정말 도움이 많이 됐어요.",
    "monologue": "그래서 제가 계속 생각하게 되는 건 매일 실제로 제품을 사용하는 사람들은 제품을 구매하는 사람들이 아니라는 거고 "
                 "그 말은 영업팀에서 받는 피드백이 항상 현장에서 실제로 일어나는 일과 한 단계 떨어져 있다는 뜻이고 그래서 저는 "
                 "우리가 지원팀과 더 많은 시간을 보내고 관리자들만 참여하는 기획 회의에는 시간을 덜 써야 한다고 생각합니다.",
}
# Speech locale → the macOS voice that speaks it and its passages.
SOURCES = {"en-US": ("Samantha", PASSAGES), "ja-JP": ("Kyoko", JA), "zh-CN": ("Tingting", ZH_CN),
           "zh-TW": ("Meijia", ZH_TW), "ko-KR": ("Yuna", KO)}
# Target language → reference translations of the passages.
REFERENCES = {"en": PASSAGES, "ja": JA, "zh": ZH_CN, "ko": KO}


def defaults_for(args):
    settings = {
        "targetLanguage": args.target,
        "sourceLocale": args.source,
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
    # The app stopped logging well before the end (seen with llama.cpp, no crash): record what it's doing. While the
    # passage is being spoken the log never rests for long, so 5 s of quiet then is a stall; caught only at the end
    # (10 s quiet), one in a passage's last 10 s would go unrecorded.
    sample = os.path.join(workdir, f"{name}.sample.txt")
    launched = time.time()
    peak_rss = 0   # the app's largest resident memory while the passage played, in bytes
    # The passage plays from when the app starts listening (ENDPOINT), not from launch. Seen 2026-10-26: a first launch
    # from a new folder took about 12 s to start, and stopping the app at launch + duration cut off the passage's last
    # 12 s, which looked like the app had stalled (likely the occasional stall seen on a first passage).
    deadline, listening_at, exited = launched + 90, None, None
    while time.time() < deadline:
        time.sleep(0.5)
        if exited is None and proc.poll() is not None:
            exited = (time.time() - launched, proc.returncode)
            print(f"{name}: the app exited on its own {exited[0]:.0f} s after launch (status {exited[1]})",
                  file=sys.stderr)
        if listening_at is None and os.path.exists(log) and \
                "ENDPOINT" in open(log, encoding="utf-8", errors="replace").read():
            listening_at = time.time()
            deadline = listening_at + duration + args.tail
            if listening_at - launched > 5:
                print(f"{name}: slow start, listening {listening_at - launched:.0f} s after launch", file=sys.stderr)
        if proc.poll() is None:
            rss = subprocess.run(["ps", "-o", "rss=", "-p", str(proc.pid)], capture_output=True, text=True).stdout.strip()
            peak_rss = max(peak_rss, int(rss) * 1024 if rss.isdigit() else 0)
        if not os.path.exists(log) or os.path.exists(sample) or proc.poll() is not None:
            continue
        speaking = listening_at is not None and time.time() < listening_at + duration - 2.5
        if speaking and time.time() - os.path.getmtime(log) > 5:
            subprocess.run(["sample", str(proc.pid), "3", "-file", sample], capture_output=True)
    if not os.path.exists(sample) and os.path.exists(log) and time.time() - os.path.getmtime(log) > 10 \
            and proc.poll() is None:
        subprocess.run(["sample", str(proc.pid), "3", "-file", sample], capture_output=True)
    proc.terminate()
    # Seen 2026-10-24 (llama.cpp, while a build ran): the app took over 10 s to quit. Record what it was doing.
    quit_sample = os.path.join(workdir, f"{name}.quit-sample.txt")
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        subprocess.run(["sample", str(proc.pid), "3", "-file", quit_sample], capture_output=True)
        proc.kill()
        proc.wait()
        print(f"{name}: the app took more than 10 s to quit (sampled, then killed)", file=sys.stderr)
    if args.keep_logs and os.path.exists(log):
        os.makedirs(args.keep_logs, exist_ok=True)
        subprocess.run(["cp", log, os.path.join(args.keep_logs, f"{name}.log")])
        for kept in (sample, quit_sample):
            if os.path.exists(kept):
                subprocess.run(["cp", kept, args.keep_logs])
    r = parse(open(log, encoding="utf-8").read() if os.path.exists(log) else "")
    heard = " ".join(x.get("source", "") for x in r["sentences"])
    r["recognition"] = recognition_error(args.source, text, heard)
    r["cer"] = None if args.source.startswith("en") else cer(args.source, text, heard)
    reference = REFERENCES.get(args.target.split("-")[0], {}).get(name)
    r["chrf"] = (strip_markup(reference), " ".join(x["final"] for x in r["sentences"])) if reference else None
    r["chrf_first"] = (strip_markup(reference), " ".join(x.get("translation", "") for x in r["sentences"])) \
        if reference else None
    r["slowQuit"] = os.path.exists(quit_sample)
    r["exited"] = exited
    r["startup"] = None if listening_at is None else listening_at - launched
    r["peakMemory"] = peak_rss
    estimate = re.search(r"\] MEMORY estimate (\d+) of (\d+)", open(log, encoding="utf-8").read() if os.path.exists(log) else "")
    r["memoryEstimate"] = int(estimate.group(1)) if estimate else None
    if args.keep_logs:
        os.makedirs(args.keep_logs, exist_ok=True)
        with open(os.path.join(args.keep_logs, f"{name}.memory.json"), "w") as f:
            json.dump({"peak": peak_rss, "estimate": r["memoryEstimate"]}, f)
    return r


def parse(log):
    live = [int(m) for m in re.findall(r"\] LIVE +(\d+)ms", log)]
    sentences = [dict(json.loads(m), at=float(t)) for t, m in re.findall(r"^\[ *([\d.]+)\] SENTENCE (\{.*\})$", log, re.M)]
    accepted = len(re.findall(r"\] REVISE .*accept\(", log))
    evaluated = len(re.findall(r"\] REVISE +\d+ms", log))
    turns = [(int(ms), reason) for ms, reason in re.findall(r"\] TURN end .*\(\+(\d+) ms\) p=\S+ (\w+)", log)]
    # A second-pass revision replaces its sentence's caption ("final": what the screen ends up showing).
    for s in sentences:
        s["final"] = s.get("translation", "")
    for t, m in re.findall(r"^\[ *([\d.]+)\] REVISED (\{.*\})$", log, re.M):
        revised = json.loads(m)
        for s in reversed(sentences):
            if s["source"] == revised["source"]:
                s["final"] = revised["translation"]
                s["revisedAfterMs"] = int((float(t) - s["at"]) * 1000)
                break
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


def edit_rate(r, h):
    d = list(range(len(h) + 1))
    for i in range(1, len(r) + 1):
        prev, d[0] = d[0], i
        for j in range(1, len(h) + 1):
            cur = min(d[j] + 1, d[j - 1] + 1, prev + (r[i - 1] != h[j - 1]))
            prev, d[j] = d[j], cur
    return d[len(h)] / max(1, len(r)), len(r)


def wer(reference, hypothesis):
    return edit_rate(normalize_words(reference), normalize_words(hypothesis))


def strip_markup(text):
    return re.sub(r"\s+", " ", re.sub(r"\[\[.*?\]\]", " ", text)).strip()


KANJI_DIGITS = "〇一二三四五六七八九"
HANGUL_DIGITS = "영일이삼사오육칠팔구"


def cjk_number(n, digits, units):
    """Numbers as they're spoken in Sino-Japanese/Chinese characters or Sino-Korean hangul: 200 → 二百 / 이백."""
    if n == 0:
        return digits[0]
    out = ""
    for unit, value in zip(units, (1000, 100, 10)):
        q, n = divmod(n, value)
        if q:
            out += (digits[q] if q > 1 else "") + unit
    return out + (digits[n] if n else "")


def normalize_chars(locale, text):
    """Characters to compare for a CJK recognition: no spaces or punctuation, digits written as spoken (the
    recognizer writes either), and 两 (two, before a measure word) as 二."""
    text = strip_markup(text).lower()
    if locale.startswith("ko"):
        text = re.sub(r"\d+", lambda m: cjk_number(int(m.group()), HANGUL_DIGITS, "천백십"), text)
    else:
        text = re.sub(r"\d+", lambda m: cjk_number(int(m.group()), KANJI_DIGITS, "千百十"), text)
        text = text.replace("两", "二").replace("兩", "二")
    return re.sub(r"[\W_]+", "", text)


def cer(locale, reference, hypothesis):
    return edit_rate(normalize_chars(locale, reference), normalize_chars(locale, hypothesis))


def korean_words(text):
    text = re.sub(r"\d+", lambda m: cjk_number(int(m.group()), HANGUL_DIGITS, "천백십"), strip_markup(text))
    return [w for w in (re.sub(r"[\W_]+", "", w) for w in text.split()) if w]


def recognition_error(locale, reference, hypothesis):
    """(error rate, reference length, measure): word error rate for languages written with spaces (English,
    Korean), character error rate for Japanese and Chinese."""
    if locale.startswith("ko"):
        return edit_rate(korean_words(reference), korean_words(hypothesis)) + ("WER",)
    if locale.split("-")[0] in ("ja", "zh"):
        return cer(locale, reference, hypothesis) + ("CER",)
    return wer(reference, hypothesis) + ("WER",)


def chrf(reference, hypothesis, order=6, beta=2):
    """chrF (Popović 2015, sacreBLEU's defaults): F-score of character 1–6-grams, spaces removed, recall weighted
    twice; 0–100. Measures how close a translation is to the reference without needing word boundaries."""
    ref, hyp = re.sub(r"\s+", "", reference), re.sub(r"\s+", "", hypothesis)
    precisions, recalls = [], []
    for n in range(1, order + 1):
        r = collections.Counter(ref[i:i + n] for i in range(len(ref) - n + 1))
        h = collections.Counter(hyp[i:i + n] for i in range(len(hyp) - n + 1))
        overlap = sum((r & h).values())
        if h:
            precisions.append(overlap / sum(h.values()))
        if r:
            recalls.append(overlap / sum(r.values()))
    p = statistics.mean(precisions) if precisions else 0.0
    rc = statistics.mean(recalls) if recalls else 0.0
    return 0.0 if p + rc == 0 else 100 * (1 + beta ** 2) * p * rc / (beta ** 2 * p + rc)


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
            f"first {mean('firstOutputMs'):5.0f} ms (from speech start {mean('firstOutputAfterSpeechStartMs'):5.0f}) | finish {mean('finishAfterCompleteMs'):5.0f} ms | "
            f"after speech {mean('finishAfterSpeechMs'):5.0f} ms | turn +{turn_ms:4.0f} ms ({by_model}/{len(turns)} model) | "
            f"NE {mean('normalizedErasure'):.2f} (committed {mean('committedErasure'):.2f}) | "
            f"replaced {replaced}/{len(s)} | revised {r['revised']}/{r['reviewed']}"
            + (f" ({mean('revisedAfterMs') / 1000:.1f} s later)" if any("revisedAfterMs" in x for x in s) else "") + " | "
            f"{r['recognition'][2]} {r['recognition'][0]:.1%}" + (f" (CER {r['cer'][0]:.1%})" if r.get("cer") and
                                                                  r["recognition"][2] != "CER" else "") +
            (f" | chrF {chrf(*r['chrf']):.1f}" if r.get("chrf") else "") +
            (f" (first pass {chrf(*r['chrf_first']):.1f})" if r.get("chrf_first") and r["chrf_first"] != r["chrf"] else "") +
            (f" | memory {r['peakMemory'] / 2 ** 30:.1f} GB (estimate {r['memoryEstimate'] / 2 ** 30:.1f})"
             if r.get("peakMemory") and r.get("memoryEstimate") else ""))


MODELS = os.path.expanduser("~/Library/Application Support/Universal Translator/Models")
LANGUAGE_NAMES = {"en": "English", "ja": "Japanese", "zh": "Chinese", "ko": "Korean"}


def script_only(args):
    """chrF of the scripts themselves translated by Hy-MT2 (1.8B, or --script-model) through llm-bench, one sentence at a time, without
    speech or context: how much of the score is the translation model's own."""
    model = args.script_model or os.path.join(MODELS, "Hy-MT2-1.8B-Q4_K_M.gguf" if args.engine == "llamaCpp"
                                              else "hy-mt2-1.8b-8bit-mlx")
    target = args.target.split("-")[0]
    references, translations = [], []
    with tempfile.TemporaryDirectory() as workdir:
        for name in args.passage or list(PASSAGES):
            text = strip_markup(SOURCES[args.source][1][name])
            path = os.path.join(workdir, f"{name}.txt")
            with open(path, "w", encoding="utf-8") as f:
                f.write("\n".join(l for l in re.split(r"(?<=[。？！?!.])\s*", text) if l.strip()) + "\n")
            out = subprocess.run([args.script_only, "--translate", model, LANGUAGE_NAMES[target], path],
                                 capture_output=True, text=True, check=True).stdout
            translation = " ".join(l for l in out.splitlines() if not re.match(r"(llama\.cpp|MLX): load", l))
            reference = strip_markup(REFERENCES[target][name])
            references.append(reference)
            translations.append(translation)
            print(f"{name:10s} chrF {chrf(reference, translation):5.1f} | {translation}", flush=True)
    print(f"{'overall':10s} chrF {chrf(' '.join(references), ' '.join(translations)):5.1f}")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--source", choices=sorted(SOURCES), default="en-US", help="speech language (and its voice)")
    p.add_argument("--target", help="caption language (default: ja for English speech, otherwise en)")
    p.add_argument("--live", default="localLLM")
    p.add_argument("--revision", default="localLLMLarge")
    p.add_argument("--stability", type=float, default=0.5)
    p.add_argument("--voice", help="default: the source language's voice in SOURCES")
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
    p.add_argument("--script-only", metavar="LLM_BENCH", help="no app, no speech: translate the scripts with this "
                   "llm-bench binary (swift build --product llm-bench) and score them")
    p.add_argument("--script-model", metavar="PATH", help="with --script-only: this model instead of Hy-MT2 1.8B "
                   "(e.g. the 7B second-pass model's .gguf)")
    args = p.parse_args()
    args.target = args.target or ("ja" if args.source.startswith("en") else "en")
    args.voice = args.voice or SOURCES[args.source][0]
    if args.script_only:
        return script_only(args)
    if not os.path.exists(APP):
        sys.exit("Build the app first: scripts/build-app.sh")
    subprocess.run(["pkill", "-x", "UniversalTranslator"], capture_output=True)
    names = args.passage or list(PASSAGES)
    print(f"source={args.source} voice={args.voice} target={args.target} live={args.live} revision={args.revision} engine={args.engine} stability={args.stability} "
          f"vad={args.vad} turn={args.turn} recognizer={args.recognizer}")
    all_live, all_sentences, all_turns, revised, reviewed = [], [], [], 0, 0
    errors, ref_units, char_errors, ref_chars, references, translations, first = 0.0, 0, 0.0, 0, [], [], []
    with tempfile.TemporaryDirectory() as workdir:
        for name in names:
            r = run_passage(name, SOURCES[args.source][1][name], args, workdir)
            print(summarize(name, r), flush=True)
            all_live += r["live"][1:]
            all_sentences += r["sentences"]
            all_turns += r["turns"]
            errors += r["recognition"][0] * r["recognition"][1]
            ref_units += r["recognition"][1]
            if r["cer"]:
                char_errors += r["cer"][0] * r["cer"][1]
                ref_chars += r["cer"][1]
            if r["chrf"]:
                references.append(r["chrf"][0])
                translations.append(r["chrf"][1])
                first.append(r["chrf_first"][1])
            revised += r["revised"]
            reviewed += r["reviewed"]
    print(summarize("overall", {"live": [0] + all_live, "sentences": all_sentences, "revised": revised,
                                "reviewed": reviewed, "turns": all_turns,
                                "recognition": (errors / max(1, ref_units), ref_units, r["recognition"][2]),
                                "cer": (char_errors / max(1, ref_chars), ref_chars) if ref_chars else None,
                                "chrf": (" ".join(references), " ".join(translations)) if references else None,
                                "chrf_first": (" ".join(references), " ".join(first)) if references else None}))
    subprocess.run(["defaults", "delete", SUITE], capture_output=True)


if __name__ == "__main__":
    main()
