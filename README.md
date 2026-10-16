# Universal Translator

A macOS menu bar app that listens while someone speaks, translates in real time, and shows the translation as a caption overlay that floats above every app, including full-screen ones. It can caption your microphone, everything your Mac is playing, or a single app such as a video call.

It works like a simultaneous interpreter:
- **While someone talks,** the captions show what's settled so far, followed by a few dimmed provisional words.
- **Text shown as final never flips back and forth.** It only becomes final once successive translations agree on it.
- **Word order is handled automatically.** When the target language waits for the verb (Japanese, Korean, German), the translation waits for it too.
- **It hears when a thought is finished.** A small end-of-turn model listens to intonation at every pause. Finished sentences are translated in full about 0.2 s after the speaker stops, and a hesitation mid-sentence doesn't cut the thought in two.
- **A second pass reviews each finished utterance.** A stronger model re-translates it from the recognizer's final transcript, with the earlier sentences as context, and the caption is quietly corrected if the meaning changed.

Everything runs on your Mac. The design follows the IWSLT 2025/2026 winning systems; see [docs/RESEARCH.md](docs/RESEARCH.md) and [docs/ROADMAP.md](docs/ROADMAP.md).

## Requirements

- macOS 26.4 or later on Apple silicon (developed on macOS 27, M3 Max)
- Xcode 27 (Swift 6.2+). The build uses `xcodebuild`, which compiles MLX's Metal shaders. On a fresh Xcode install, run `sudo xcodebuild -runFirstLaunch` and `xcodebuild -downloadComponent MetalToolchain` once.
- Disk for on-device models, all downloaded from within the app:

  | Model | Size | Use |
  | --- | --- | --- |
  | NVIDIA Nemotron speech | 611 MB (Latin-script languages) or 664 MB (all languages) | Speech recognition |
  | Hy-MT2 1.8B | 1.1 GB (llama.cpp) or 1.9 GB (MLX) | Live translation |
  | Hy-MT2 7B | 4.6 GB (llama.cpp) or 4.2 GB (MLX) | Second pass (optional) |
  | Silero VAD and Smart Turn | 18 MB | Voice and end-of-turn detection (fetched automatically) |

- Optional: [LM Studio](https://lmstudio.ai), to use any local model instead

## Build and run

```sh
scripts/build-app.sh            # builds with xcodebuild and signs build/Universal Translator.app (embeds llama.framework and MLX's shaders)
scripts/build-app.sh --run      # …and launches it
scripts/build-app.sh --install  # …copies it to /Applications and launches it
swift test                      # unit tests: policy, transcript alignment, frontier, turns, revisions, prompts, reading speed
scripts/evaluate.py --target ja # end-to-end latency, stability and accuracy report (see below)
```

The script signs with the first *Developer ID Application* or *Apple Development* identity in your keychain (override with `SIGN_IDENTITY`; change the bundle id with `BUNDLE_ID`). A stable signature means macOS keeps the microphone and system-audio permissions across rebuilds.

On first launch the Settings window opens:
1. Under **General**, download the **NVIDIA Nemotron** speech model. Apple Speech is used until it's downloaded.
2. Under **Translation**, download **Hy-MT2 1.8B** and, optionally, **Hy-MT2 7B**. Apple Translation is used until then.
3. Click **Start Listening** or press **⌃⌥⌘T**.

## How it works

```
mic / system audio / app ─▶ capture ─┬─▶ Silero VAD ─▶ turn detector ◀─ Smart Turn (on pauses)
                                      │                     │ end of turn: recognizer catches up (no forced finalize)
                                      └─▶ speech recognizer ◀┘   Nemotron (default) │ Apple SpeechAnalyzer
                                                 ▼
                    TranscriptBuffer ─▶ SourceFrontier ─▶ SimulPolicy ─▶ overlay + transcript window
                                       (stable words,     (agreement,      (committed │ provisional)
                                        utterance = turn)  forced prefix)        ▲
                                                 second pass: RevisionPolicy ◀──┘ (from the final transcript)
```

1. **Audio.** The microphone (any input device), all audio the Mac is playing, or one app and its helper processes. The last two use a Core Audio process tap; the audio keeps playing normally.
2. **Voice and end of turn.**
   - Silero VAD v6 scores every 32 ms of audio.
   - At each pause, Smart Turn v3.2 judges from intonation and pace whether the speaker has finished. When it's confident, the turn ends about 0.2 s after the last word; otherwise it waits up to 1.4 s.
   - Without the models, a level meter and a fixed 0.7 s pause are used.
3. **Speech recognition.**
   - **NVIDIA Nemotron 3.5 Streaming (default):** words every 0.56 s, never revised. At the end of a turn the current chunk is padded with silence and decoded at once.
   - **Apple SpeechAnalyzer:** in-progress text about once a second. At the end of a turn it's fed a second of silence so it catches up immediately, and its final transcript later corrects the original-language line and feeds the second pass.
   - Neither recognizer is ever forced to finalize: `finalize(through:)` garbles the words around the forced point.
4. **Stable source frontier.** Final words count immediately. In-progress words count once two consecutive hypotheses agree on them and they've existed for 250 ms. The translation unit is the **utterance**: one turn. Long monologues are finished at the stable edge after 40 words.
5. **Simultaneous policy (`SimulPolicy`).** Each time the stable source grows, the translator is asked to *continue the committed translation* (prefix forcing). Only the longest common prefix of two consecutive translations is committed (LocalAgreement). The rest shows as provisional text with its last few units hidden. A per-language profile sets the agreement unit (words, or characters trimmed to particles for Japanese and Chinese) and the maximum wait before a commit is forced. The "Responsive ↔ Stable" control scales those values.
6. **On-device translation LLM (`LocalLLM` with llama.cpp, or `LocalMLX` with MLX; both on the GPU).** Tencent's Hy-MT2 1.8B (Apache-2.0). The two engines share one contract (`CompletionRunner`) and the same decoding features:
   - **Prompt-cache reuse:** only the new tokens are processed on each update.
   - **Token healing:** a committed prefix that ends mid-token continues naturally.
   - **SSBD:** the previous translation is verified as a speculative draft and kept wherever the model nearly agrees.
   - **Valid UTF-8 only:** generated text never breaks a multi-byte character.
   - **Short live steps:** each live update generates at most 12 new tokens; finals translate in full.
   - **Context only from six words on:** earlier sentences are given as background once the utterance is long enough, since small models otherwise translate the background.
7. **Second pass (`RevisionPolicy`).**
   - Hy-MT2 7B re-translates each finished utterance from the final transcript, with recent context.
   - The caption is revised only if the content changed meaningfully, at most once, while it's still on screen, and only during pauses. A bigger change is required when the transcript didn't change, so the 7B's rewording isn't shown.
   - Candidates that add a sentence or change length a lot are rejected, and fragments cut mid-speech are skipped.
   - Changed words are highlighted briefly.

| Recognizer | Notes |
| --- | --- |
| **NVIDIA Nemotron** (default) | Most accurate in our tests (1.2% WER) and steadiest; 40 locales. 611–664 MB download. |
| Apple Speech | Built in, no download; 2.8% WER, text arrives about once a second. |

| Live translator | Notes |
| --- | --- |
| **Hy-MT2 1.8B** (default) | Steadiest captions, with context. Live update p50 70–80 ms. |
| Apple Translation | No download and fast, but it can't continue a prefix, so captions change more. |
| Apple Intelligence model | On-device LLM with context; slower. |
| LM Studio | Any OpenAI-compatible server. **Fast mode** uses raw completions with the model's chat template (detected from its name: ChatML, Qwen 3, Llama 3, Gemma, Mistral, Phi, Hy-MT2) and continues the committed translation like the built-in engine. Unknown models use the chat API. |

Second pass: Hy-MT2 7B (default), Hy-MT2 1.8B, Apple Translation high fidelity, Apple Intelligence, LM Studio, or off.

The Hy-MT2 models run on **llama.cpp** (default) or **MLX** (Settings → Translation → Engine), each with its own download. In the app llama.cpp is faster: live p50 70–84 ms vs 85–108 ms, and final captions 26–75 ms sooner. MLX's 8-bit 1.8B is closer to Tencent's full-precision model, but no steadier on screen. Details in [RESEARCH.md](docs/RESEARCH.md#3-translation-models).

### Measured (M3 Max, `scripts/evaluate.py`, 19 utterances per language, synthesized speech)

| Target | Live update p50 | Final caption after speech ends | Flicker (NE) | Committed text changed | Speech WER |
| --- | --- | --- | --- | --- | --- |
| Japanese | 78 ms | 442 ms | 0.36 | 0.00 | 1.2% |
| German | 77 ms | 425 ms | 0.05 | 0.00 | 1.2% |
| Spanish | 69 ms | 413 ms | 0.02 | 0.00 | 1.2% |

Japanese flickers more because its verb comes last, so provisional words change more often. Speed depends on what else is using the GPU.

## The overlay

A borderless, non-activating `NSPanel` that never takes focus.

- **Captions:**
  - Roll-up (last N lines, measured with TextKit), stacked, or marquee layout.
  - Marquee: one line scrolls across like a news ticker, toward where the language starts reading (left to right for Arabic and Hebrew). It moves at a steady speed (10 characters/s by default) and speeds up, to at most 30, while words wait off screen, so it keeps up with the speaker. The original speech scrolls on its own line. Auto-hide and auto-clear wait until the text has scrolled away.
  - Committed text at full strength, provisional words dimmed or italic, newly final words fade in.
  - Revised words get a brief highlight.
  - Optional original-language line, a "behind" badge when translation lags, and a "Paused" badge.
  - Respects Reduce Motion (the marquee shows rolling captions instead).
- **Readability:**
  - A reading-speed limit (17 characters/s by default; Chinese and Japanese characters count as two). A line that hasn't been on screen long enough to read stays, and the caption grows by a line instead.
  - Captions clear after 12 s of silence, but never before the last one has been read.
- **Indicators:** a listening/speaking dot and a privacy symbol beside it (a lock means nothing leaves this Mac; a network symbol means recognized text goes to another machine).
- **Placement:**
  - Main display, the display with the pointer, or a specific display.
  - A 9-point anchor grid with margins, or drag it anywhere when unlocked; adjust width with the ↔ handle.
- **Window:**
  - Stays above apps, above the menu bar, or above everything including full-screen apps.
  - Click-through when locked; all Spaces; can be hidden from screen recording; auto-hides when idle.
- **Typography and background:** any font, size, weight and colour; outline; shadow; box or no background; blur; corner radius; padding; border; opacity.
- **Presets:** Subtitles, Broadcast lower third, Teleprompter, News ticker, Minimal outline, High contrast. Settings export and import as JSON.

## Transcript, shortcuts and menu

**Transcript window** (menu bar → **Show Transcript**, ⌘T in the menu): the whole session with the original under each translation. It follows the latest line until you scroll up, then offers **Latest**. It has search, copy, text size, revision markers, and export to `.srt`, `.vtt` or `.txt`.

Global shortcuts (rebindable; no Accessibility permission needed):

| Shortcut | Action |
| --- | --- |
| **⌃⌥⌘T** | Start or stop |
| **⌃⌥⌘P** | Pause or resume (models stay loaded; the sentence in progress is finished) |
| **⌃⌥⌘O** | Show or hide the overlay |
| **⌃⌥⌘L** | Lock or unlock the overlay |
| **⌃⌥⌘K** | Clear captions |
| None by default | Show the transcript |

The menu bar menu shows whether anything leaves the Mac. It also switches what to listen to (the microphone, all system audio, or an app that's playing audio), the target language, and the Responsive/Balanced/Stable timing.

## Testing and evaluation

`scripts/evaluate.py` synthesizes four passages with `say`: meeting talk, a technical explanation, short questions, and a run-on monologue. It plays each through the real app in real time, with isolated settings, and reports:
- live update latency (p50/p95);
- time to the first caption;
- final translation latency, measured from the end of the utterance and from the end of speech;
- end-of-turn detection delay, and how many turns the model decided;
- normalized erasure (NE: visible characters taken back), overall and for committed text;
- replaced finals and accepted revisions;
- the recognizer's word error rate against the script.

```sh
scripts/evaluate.py --target de --recognizer appleSpeech --vad energy --turn off --revision off
scripts/evaluate.py --target ja --live lmStudio --lmstudio-url http://localhost:1234 --lmstudio-model qwen/qwen3-8b
```

Debug hooks (environment variables):

| Variable | Effect |
| --- | --- |
| `UT_AUDIO_FILE` | Streams a file in real time instead of the microphone |
| `UT_AUTOSTART=1` | Starts listening at launch |
| `UT_DEFAULTS_SUITE` | Keeps settings in a separate defaults domain |
| `UT_DEBUG_LOG` | Logs recognizer results, turn decisions, live/final translations, per-utterance metrics (JSON), revisions and LLM timings |
| `UT_OPEN=settings\|transcript`, `UT_SETTINGS_SECTION` | Opens a window at launch (for screenshots) |
| `UT_PAUSE_AT=9,14` | Toggles pause at these seconds after launch |
| `UT_TAP_PID` | Captures (and mutes) one process instead of the selected source |

`llm-bench` measures the on-device models outside the app. Build it with `xcodebuild build -scheme llm-bench -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode`, then run `.build/xcode/Build/Products/Release/llm-bench` with `DYLD_FRAMEWORK_PATH=.build/xcode/Build/Products/Release`:

| Command | Measures |
| --- | --- |
| `llm-bench <model.gguf or MLX folder>` | Speed, token healing and glossary handling (`LIVE_RUNS=3` adds the live-caption workload) |
| `llm-bench --compare <model.gguf> <MLX folder>` | Tokenizer agreement, then the same workload on both engines |
| `llm-bench --scaling <model>…` | Call time by number of new prompt tokens |
| `llm-bench --consistency <model>…` | Same output with and without prompt-cache reuse |
| `llm-bench --translate <model> <language> <file>` | Final translations of each line, for quality comparisons |
| `llm-bench --tokenize <tokenizer.json> <file>` | Token IDs, to check the MLX tokenizer against Hugging Face's |

## Project layout

```
Sources/TranslatorCore/        platform-independent logic (unit tested)
  SimulPolicy.swift            target-side LocalAgreement with forced prefix, forced commits, flush
  LanguageProfile.swift        per-target units, safe boundaries, max delay, mask, stability tuning
  SourceFrontier.swift         stable source words and utterance units
  TurnDetector.swift           voice activity and end-of-turn decisions (VAD + end-of-turn model)
  RevisionPolicy.swift         second-pass gating and changed-span diff
  ReadingGovernor.swift        reading-speed limit for roll-up captions
  Transcript.swift             tokens, TranscriptBuffer (agreement, word alignment, final text per utterance), TextJoiner
  HyMT2Prompt.swift            Hy-MT2 prompt formats (1.8B and 7B)
  PromptTemplate.swift         chat templates for raw completions (LM Studio fast mode)
  Prompts.swift, Glossary.swift, VoiceActivityDetector.swift, OpenAICompatibleClient.swift,
  SentenceBoundary.swift, SubtitleExporter.swift
Sources/LocalLLM/              CompletionRunner contract, and the llama.cpp runner: cache reuse, token healing, SSBD, valid UTF-8, stop strings
Sources/LocalMLX/              the same on MLX (MLXRunner), and a byte-level BPE tokenizer matching Hugging Face's
Sources/UniversalTranslator/   the app
  App/          AppController, TranslatorController (start/stop/pause/restart), menu bar
  Audio/        microphone and system-audio capture, Silero/Smart Turn endpointer, conversion (+ file playback)
  Engine/       SpeechPipeline, SpeechRecognizer (Apple), NemotronRecognizer
  Translation/  LiveTranslationController, translators (Apple, Apple Intelligence, LM Studio), LocalModels
  Overlay/      CaptionStore (sentences, effects, reading timing), OverlayController (window), OverlayView
  Transcript/   transcript window
  Settings/     settings model/persistence, privacy status, and the SwiftUI settings window
Sources/llm-bench/             developer benchmark
Tests/TranslatorCoreTests/
scripts/                       build-app.sh, evaluate.py, make-icon.swift
docs/                          RESEARCH.md, ROADMAP.md
```
