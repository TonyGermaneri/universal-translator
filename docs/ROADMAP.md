# Roadmap: v2 "state of the art" simultaneous translation

Goal: captions that keep up with the speaker (first provisional words in about 100 ms, stable translated text in 1.5–3 s depending on the language pair). Captions should commit only text that won't change, and quietly fix recent sentences once the whole thought is known. Background and sources: [RESEARCH.md](RESEARCH.md).

## Architecture (v2)

```
mic / system audio / one app ─▶ capture ─┬─▶ Endpointer: Silero VAD ─▶ TurnDetector ◀─ Smart Turn (on pauses)
                                          │                                   │ end of turn
                                          └─▶ recognizer (Nemotron │ Apple) ◀─┘ (pad / flush with silence)
                                                     │ volatile + final text
                                                     ▼
                     TranscriptBuffer ─▶ SourceFrontier (stable words, utterance = turn)
                                                     ▼
                     SimulPolicy (target-side LocalAgreement, forced prefix, language profile, mask-k, max delay)
                        │ live: Hy-MT2 1.8B (llama.cpp │ MLX) │ Apple .lowLatency │ LM Studio raw completions
                        ▼
                     CaptionStore (committed │ provisional) ─▶ overlay (roll-up, fade-in, reading-speed hold)
                        ▲                                    └▶ transcript window (scrollback, search, export)
                     RevisionPolicy ◀─ second pass on finished utterances, using the recognizer's final transcript
                        │ Hy-MT2 7B │ Apple .highFidelity │ LM Studio │ Apple Intelligence
```

### Key decisions
1. **The commit decision moves to the target side.** Use LocalAgreement (LCP of consecutive translations) with the committed target forced as a prefix (the IWSLT 2025/2026 winning recipe). The current source-side segmenter is kept only as a cheap *hold gate* (skip a translation request while the source ends on "the/to/and…") and for sentence-end detection. The LLM chunking judge is retired as a policy.
2. **Use language profiles.** Agreement units are words, or characters trimmed to safe boundaries for ja/zh. Each profile also sets max delay (≈3 s de/fr/es, 4.5 s ja/ko), the mask-k ghost length, safe-boundary characters, and interpreter-style prompt hints.
3. **Display text in three tiers.** Locked (scrolled away or already revised) → committed (soft) → ghost (provisional, last *k* units hidden). Only the ghost tier and at most one second-pass revision per sentence may change visible text.
4. **Run the LLM in-process with llama.cpp (prebuilt `llama.xcframework`, Metal).** Use Hy-MT2-1.8B Q4_K_M for the first pass (prefix forcing, KV prefix-cache reuse, token healing, SSBD draft verification) and Hy-MT2-7B Q4_K_M for the second pass. Apple Translation remains the zero-download engine and the fallback (`.lowLatency` first pass, `.highFidelity` second pass). *MLX (`mlx-swift-lm`) was the first choice, but its Metal shaders need `xcodebuild`. After the one-time Xcode repair it was added as the alternative engine (`LocalMLX`, same `CompletionRunner` contract). llama.cpp stays the default: it measured faster in the app (see Phase 2).*
5. **End turns with our own endpointer; never force the recognizer.** Silero VAD and Smart Turn decide when a thought is over. The recognizer then catches up by itself: Nemotron gets its current chunk padded with silence, Apple gets a second of silence fed in. `finalize(through:)` was tried first and dropped: it garbles the words around the forced point. Use a stable source frontier: finals, plus agreed volatile words seen for at least 250 ms.
6. **Measure everything.** Log lag per sentence (source word end → commit), erasure per tier, revisions, and per-call latency. A headless evaluation harness (TTS audio → metrics) compares configurations.

## Phases

### Phase 1: simultaneous core (no new dependencies): done
- [x] `TranslatorCore/SimulPolicy`: target-side LCP with forced prefix, sentence-scoped state, max-delay forcing, mask-k ghost, end-of-sentence flush, history of (source, target) pairs.
- [x] `TranslatorCore/LanguageProfile`: units, safe boundaries, max delay, mask-k, prompt hints for de, ja, ko, zh, es, fr, and a default.
- [x] `TranslatorCore/RevisionPolicy`: content diff (ignoring punctuation, whitespace and width), accept/reject thresholds, ≤1 revision per sentence, visibility window.
- [x] `TranslatorCore/SourceFrontier`: stable source words (finals plus agreed volatile words older than 250 ms). *Changed after measurement:* the translation unit is the **utterance** (up to a real pause), not the punctuated sentence. Apple only punctuates when it finalizes, about 1 s late, and splitting on that boundary contradicted text already committed. Long monologues are finished at the stable edge after 40 words.
- [x] Unit tests for all of the above, including an end-to-end policy simulation driven by a fake translator.
- [x] `SentenceTranslator` protocol (with capabilities: prefix forcing, context, local/remote). Rework the Apple backend: `.lowLatency` for the first pass (no prefix, so LCP over whole outputs), `.highFidelity` for the second pass. Handle the per-pair language download.
- [x] Engine: replace the segmenter-driven commits with SimulPolicy ticks (on frontier change, at most every ~120 ms). Call `finalize(through:)` on the VAD endpoint.
- [x] Caption model and overlay: per-sentence tiers, ghost styling, fade-in, revision highlight (~600 ms), Reduce Motion, roll-up line fitting.
- [x] A "Responsive ↔ Stable" control mapped to the profile parameters, plus a lag indicator.
- [x] Metrics logging and a headless evaluation script (`scripts/evaluate.py`: TTS paragraphs in several styles → lag, erasure and revision report).
- [x] Live captions take priority: second-pass revisions run during pauses and are cancelled when a live request needs the translator.

### Phase 2: in-process LLM engine: done (llama.cpp)
- [x] `LocalLLM/LlamaRunner`: llama.cpp via the prebuilt xcframework (works with `swift build`). Greedy decoding, KV-cache trim to the longest common prefix between calls, prewarm, cancellation, explicit release before exit (avoids a Metal teardown assertion).
- [x] Prefix forcing with **token healing**: the last forced token is backed off and the first new token is constrained to extend it, which fixed "したいとおもいます" and "計画でです".
- [x] **SSBD**: the previous hypothesis is verified in one batch and kept where the model nearly agrees (β = 0.2). Japanese flicker fell 0.83 → 0.66; faster too.
- [x] Live steps generate at most 12 new tokens (look-ahead for agreement), finals translate in full.
- [x] Model manager: download, cancel or delete Hy-MT2 1.8B (1.1 GB) and 7B (4.6 GB) from Hugging Face with progress. Falls back to Apple Translation when a model isn't downloaded.
- [x] `llm-bench` developer tool for model speed outside the app.
- [x] Optional MLX engine (`LocalMLX/MLXRunner`, mlx-swift-lm 3.32.3) with the same features: prompt-cache reuse, token healing, SSBD, valid UTF-8, stop strings. Prompt tokens and draft are verified in one forward pass, only the needed positions are projected onto the vocabulary, and decoding is pipelined. Selectable in Settings → Translation (**Engine**); llama.cpp stays the default. Findings:
  - **swift-transformers tokenized Hy-MT2 wrongly** (its regex search split ":\n\n" into three tokens), so prompts differed from training, and it took 3 ms per prompt. `LocalMLX/BPETokenizer` matches Hugging Face's reference on 388/388 test strings for both models, at 0.05 ms per prompt with a per-word cache.
  - **The 4-bit MLX conversions are worse than llama.cpp's mixed Q4_K_M.** Live translations change more from word to word, so only 3.7 draft tokens per update are kept (llama.cpp 6.8) and updates are slower. The MLX engine uses the 8-bit 1.8B instead: it reproduces Tencent's full-precision model (16–18/25 identical translations vs 9–12 for Q4_K_M) and keeps 6.5 draft tokens per update.
  - **Same speed per forward pass.** At equal work the engines are within a few ms (best of 10). MLX decodes 4-bit models faster (1.8B: 197 vs 158 tok/s; 7B: 55 vs 49 tok/s), but the 8-bit 1.8B decodes at 118 tok/s.
  - **In the app llama.cpp is faster** (same runs, all three languages): live update p50 70–84 ms vs 85–108 ms, final caption 26–75 ms sooner, same flicker. The MLX 7B second pass finished fewer reviews in time (13–17 vs 18 of 19).
  - **Tencent's Q8_0 and Q6_K 1.8B GGUFs come from different weights** than the current full-precision release (19% relative difference per tensor, against ~1% for a real 8-bit copy), so they're less faithful than Q4_K_M. Don't switch to them.

### Phase 3: faster, smarter endpointing and input: done
- [x] Silero VAD v6 (Core ML, 32 ms frames, 0.08 ms each) replaces the energy VAD; the energy VAD is the fallback. Mic sensitivity maps to its thresholds.
- [x] Smart Turn v3.2 end-of-turn model (Core ML, ~3 ms), asked at 0.2 s and 0.5 s into each pause. The turn ends when it's confident, or after the longest pause setting (1.4 s). Both models (18 MB) download automatically. Turn ends are detected 230–310 ms after speech, against 743 ms before.
- [x] Turn ends no longer force `finalize(through:)`, which garbled Apple's results. Instead:
  - Apple gets one second of silence fed at the end of a turn, and its timeline is mapped back to real time.
  - The utterance finishes on the in-progress text once a result burst covering the end of speech is complete.
  - Apple's final transcript, when it arrives, corrects the original-language line and feeds the second pass.
- [x] NVIDIA Nemotron 3.5 streaming speech engine (FluidAudio 0.17.7, 560 ms chunks) behind a `SpeechRecognizer` protocol. It is now the default; Apple Speech is used until it's downloaded. At the end of a turn the chunk is padded and decoded, and the stream is reset only after 3 s pauses (resetting every turn lost the next first word). WER 1.2% vs 2.8% for Apple on the test passages.
- [x] System audio and per-app capture (Core Audio process tap and private aggregate device): "Listen to" the microphone, all system audio, or one app and its helpers, from Settings or the menu bar.

### Phase 4: professional features: done (except PCC)
- [x] Glossary: forced translations and keep-as-is terms (Hy-MT2 terminology template, LLM instructions) plus speech-recognition contextual strings (Apple) and vocabulary boosting (Nemotron). Style instructions use Hy-MT2's style template.
- [x] LM Studio fast mode: raw `/v1/completions` with the model's chat template (automatic from the model name, or ChatML, Qwen 3, Llama 3, Gemma, Mistral, Phi, Hy-MT2), the committed translation prefilled, and 16-token live steps. The chat API remains as a fallback.
- [ ] Private Cloud Compute option for the second pass.
- [x] VTT export (alongside SRT and TXT).
- [x] Transcript window: the whole session with originals, follows the latest line until you scroll up, search, copy, export, text size, and revision markers.
- [x] Pause/resume hotkey (⌃⌥⌘P) and menu item: audio is ignored while paused (models stay loaded), and the sentence in progress is finished.
- [x] Privacy indicator: a lock (everything on this Mac) or network symbol (text sent to another host) in the overlay, the menu bar, and Settings.
- [x] Marquee layout: a news-ticker line that scrolls toward where the target language starts reading. It runs at a steady speed and catches up when words are waiting (within about 1.5 s, at most 30 characters/s), with the original speech on its own line and a News ticker preset. Each frame only moves a pre-rendered strip of text: two lines at 120 Hz cost about 4% of a core.
- [x] Reading-speed governor: rolling captions keep a line until it has been readable for its length at 17 characters/s (Chinese and Japanese characters count as two). The caption grows by up to one line instead; new words are never delayed. Auto-clear after 12 s of silence, never before the last caption has been read; auto-hide respects reading time too.

### Quality fixes found along the way
- [x] **Hy-MT2 7B was prompted with the 1.8B's chat markers.** It read them as plain text, then rambled, answered questions instead of translating them, and wrote end markers as text. Each model now has its own prompt format.
- [x] **Generated text is kept valid UTF-8.** A model can start a multi-byte character with a byte token and never finish it.
- [x] **Second-pass gating:**
  - a bigger change is required unless the final transcript corrected the source;
  - candidates that add a sentence or change length a lot are rejected;
  - fragments cut at the length cap are skipped.
- [x] **Context withheld from short utterances and fragment continuations,** because small models translate the background instead.
- [x] **Turn ends are handled from events,** so a turn that ends and resumes within one tick isn't missed.
- [x] **The privacy check no longer resolves the host name on the main thread** (it blocked).

### Still open
- [ ] Private Cloud Compute second pass.
- [ ] Better continuation of sentences cut at the 40-word cap, for example a hidden forced prefix of the previous translation.
- [ ] Real-speech evaluation. All numbers come from synthesized speech, whose pauses sometimes sound finished to Smart Turn mid-sentence.

## Results (October 2026, M3 Max with other GPU-heavy apps running)

Measured with `scripts/evaluate.py`: 4 passages, 19 utterances per language, defaults (Nemotron speech, Silero + Smart Turn, Hy-MT2 1.8B live, Hy-MT2 7B second pass).

| Target | Live update p50 / p95 | Final caption after speech ends | Turn detected after | Erasure (NE) | Committed erasure | Replaced | Revised | Source WER |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| ja | 78 / 136 ms | 442 ms | 313 ms | 0.36 | 0.00 | 0/19 | 8/18 | 1.2% |
| de | 77 / 122 ms | 425 ms | 313 ms | 0.05 | 0.00 | 0/19 | 9/18 | 1.2% |
| es | 69 / 105 ms | 413 ms | 313 ms | 0.02 | 0.00 | 0/19 | 1/18 | 1.2% |

**Before this round** (Apple speech with a forced `finalize`, energy VAD, fixed 0.7 s pause), en→ja:
- the final caption came 1,042 ms after speech ended;
- the turn was detected after 743 ms;
- NE was 0.53–0.57;
- finals were garbled by the forced finalization.

**With Apple Speech instead of Nemotron** (en→ja): 518 ms after speech, NE 0.50, WER 2.8%.

## Acceptance targets (measured by the evaluation harness)
- First provisional words: ≤ 300 ms after the stable source frontier moves (Apple `.lowLatency` or Hy-MT2-1.8B).
- Committed-text erasure: 0, apart from second-pass revisions. Revisions: ≤ 1 per sentence, applied to under 30% of sentences.
- Average lag from a source word to its committed translation: ≤ 2.5 s for en→de/es/fr and ≤ 3.5 s for en→ja/ko.
- No dropped or duplicated source words (existing alignment tests stay green).
