# Research: state of the art for live speech translation (October 2026)

This summarizes the research behind the v2 roadmap ([ROADMAP.md](ROADMAP.md)). Numbers marked **measured** were taken on the development Mac (M3 Max, 36 GB, macOS 27.0.1); everything else is from the cited sources.

## 1. This is a solved problem, and the winning recipe is simple

Simultaneous speech translation is benchmarked yearly at IWSLT. The 2025 and 2026 winners are **cascades** like this app (streaming speech recognition → off-the-shelf instruction LLM). Neither one fine-tuned the translation model.

- **The commit policy is decided on the target side.** The LLM is asked to *continue the translation already shown* (the committed target goes in the assistant turn, which forces the prefix). The app commits only the **longest common prefix (LCP)** of two consecutive translations. This is called LocalAgreement. Context resets at the end of each utterance.
- **This handles target-language word order without special rules.** German participles and Japanese predicates keep moving to the end of the sentence, so they aren't committed until they stop moving.
- **Small translators are good enough under this policy.** IWSLT 2026's winner (NVIDIA NeMo) found Qwen3-4B-Instruct within about 1.3 COMET of Qwen3.5-27B.
- **Small LLMs are poor policy-makers.** Zero-shot "should I wait?" decisions degrade sharply below 70B. That matches what we saw with the Apple Intelligence chunking judge.
- **The prompt rules from NeMo work and are worth copying:** *"The input may be incomplete; preserve incompleteness. Do not infer missing content. Do not complete or extend the text."* One in-context example stops small models from producing non-translations.

Sources: IWSLT 2025 findings (aclanthology.org/2025.iwslt-1.44), IWSLT 2026 findings (aclanthology.org/2026.iwslt-1.39), NeMo@IWSLT 2026 (aclanthology.org/2026.iwslt-1.23), CUNI SimulStreaming (arxiv.org/abs/2506.17077, github.com/ufal/SimulStreaming), MLLP 2026 (arxiv.org/abs/2606.17255).

### Readiness for each target language
- **English→German:** the verb comes second in main clauses, so the subject and finite verb can go out early. Participles, infinitives, separable particles and verbs in subordinate clauses move to the end.
- **English→Japanese/Korean:** the predicate comes last, and relative and subordinate clauses come first. These units are safe to emit early: closed topic noun phrases, fronted adverbials, and completed subordinate clauses ("When I got home," → 帰ったとき、).
- **Japanese needs more lag.** IWSLT's latency regimes are 0–3.5 s and 3.5–5 s for En→Ja, against 0–2 s and 2–4 s for En→De.
- **Agree on characters for Japanese and Chinese.** Agreement for CJK targets is computed per character, then trimmed back to a particle or punctuation boundary.
- **Interpreter-style prompting helps.** Short clauses translated in order, with repetition instead of reordering, reduce latency.

### Flicker and revision
- **Re-translation with masking matches dedicated streaming systems.** Hiding the last *k* tokens of the unstable tail (mask-k), plus biasing toward the previous output, cut normalized erasure from 2.11 to 0.12 with unchanged BLEU and lag (Arivazhagan et al. 2020; Google's stabilization work).
- **SSBD (Zoom, 2025) reuses the previous translation as a speculative draft.** With llama.cpp on an M2 Pro, re-translation was 1.3–1.7× faster with the same COMET score.
- **Every serious system splits text into two layers:** an append-only committed layer and a provisional tail. Rewrites belong only in the provisional tail of the last line. Users prefer stability over accuracy (Google CHI 2023), so second-pass revisions must be rare, gated by how much they change, and limited to text still on screen.

## 2. Speech recognition
- **Two engines.** NVIDIA Nemotron 3.5 ASR Streaming 0.6B is the default. It runs through FluidAudio on Core ML and the Neural Engine, covers 40 locales with punctuation, and its output is monotonic: words are never revised. Apple `SpeechTranscriber` is the zero-download alternative and is about as accurate as Parakeet on English. Both run on the Neural Engine, so neither competes with the GPU-bound translation LLM.
- **Hold back the newest words.** Volatile words newer than about 250 ms are unreliable (AlignAtt4LLM analysis).

**Measured here (October 2026):**
- **Apple's `finalize(through:)` damages recognition.** The planned "finalize at our endpoint" fix made the final results much worse, for `SpeechTranscriber` and `DictationTranscriber` alike. "When a request comes in" came back as "in." or ".....", and the first words after the forced point were lost. Natural finals are clean. WER on the test passages was 2.8–3.1% with natural finals.
- **Apple's in-progress text arrives in ~0.93 s bursts.** `SpeechTranscriber` with `.fastResults` emits volatile results about once per 0.93 s of audio (3.8 s without `.fastResults`). Each burst reveals a few words within milliseconds ("the d", "the data", "the database"). An utterance must not be finished on the first result of a burst.
- **Flushing with silence gives fast finals without forcing.** At the end of a turn, feed the analyzer a second of digital silence and map its timeline back to real time. The analyzer processes its pending audio at once and finalizes the way it would at a natural pause. Final captions arrived 556 ms after speech instead of 1,042 ms, with better accuracy (WER 2.8%).
- **`DictationTranscriber` updates faster but is worse here.** With frequent finalization it updates every ~0.24 s, but it rarely finalizes on its own. It was also less accurate (4.7% WER) and emitted stray "." results.
- **Nemotron loses the first word after a reset.** Resetting the stream at every turn cost the model its context and the next turn's first word ("Any questions" → "Questions"). Padding the current 560 ms chunk with silence at the end of a turn, and resetting only during 3 s pauses, gave 1.2% WER.
- **Nemotron punctuates late.** It adds a sentence's punctuation once it hears what follows, so a turn's text can start with the previous turn's "," or "?".

**Endpointing (implemented):**
- **Silero VAD v6:** the 32 ms Core ML model, 0.08 ms per frame on the CPU.
- **Smart Turn v3.2:** a 17 MB Core ML model, 2.3–5 ms on the Neural Engine. It runs at 0.2 s and 0.5 s into each pause.
- **Results:** the end of a turn is detected 230–310 ms after speech stops, against 743 ms with the old fixed 0.7 s pause. Hesitations mid-sentence ("supposed to be … really nice") no longer split the thought.
- **Error rate:** on 1,000 test clips, Smart Turn cuts off about 8% of unfinished turns too early (upstream evaluation). Synthetic speech sometimes sounds finished mid-sentence.

Sources: developer.apple.com/documentation/speech, github.com/FluidInference/FluidAudio, huggingface.co/nvidia/nemotron-3.5-asr-streaming-0.6b, github.com/pipecat-ai/smart-turn, huggingface.co/aufklarer/Smart-Turn-v3.2-CoreML.

## 3. Translation models

| Option | Quality | Speed (**measured** on this Mac) | Notes |
| --- | --- | --- | --- |
| Apple Translation `.lowLatency` | Good, no context | **26–44 ms** per clause warm (first calls 117–175 ms) | Separate download for each language pair |
| Apple Translation `.highFidelity` | Better | **335–800 ms** per clause | Single model; requests queue behind each other |
| **Hy-MT2-1.8B** (Tencent, May 2026, Apache-2.0, 1 GB at 4-bit) | FLORES XCOMET 90.0, above Microsoft Translator | **205 tok/s, first token 15–18 ms with prompt cache; 10-word clause 64–163 ms** | Default first-pass LLM |
| **Hy-MT2-7B** (4.2 GB at 4-bit) | FLORES 93.5; beats TranslateGemma-27B on WMT25 XCOMET | **52–62 tok/s; one sentence 0.3–1.1 s** | Second-pass reviser. Uses the original Hunyuan tokenizer and markers (`<\|startoftext\|>…<\|extra_0\|>`), not the 1.8B's `<｜hy_User｜>`. With the wrong markers it rambles, answers questions and writes its end marker as text. |
| Qwen3-4B-Instruct-2507 (2.3 GB at 4-bit) | Used by the IWSLT 2026 winner | **107 tok/s; full loop step 170 ms with prompt-cache reuse vs 287 ms without** | General-purpose alternative |
| TranslateGemma 4B / 12B | Good (MetricX 4.4 / 3.8 for En→Ja) | 104 / 38 tok/s | Strict template; needs an extra stop token |
| Apple Foundation Models / Private Cloud Compute | Unbenchmarked for translation | First token 0.4–0.5 s | PCC (macOS 27) is an option for the second pass |

**Measured here: the incremental loop works on Japanese.** I ran target-side LCP with a forced prefix, Qwen3-4B, and two words added per step. Committed Japanese grew in order, and the verb-final material waited until it settled. The result was *その結果、約6週間のテスト期間が残りました。これはタイトですが、スコープを現在の状態に維持すれば実現可能です。*

**Engines:**
- **llama.cpp is the default; MLX (`mlx-swift-lm` 3.32.3) is the alternative.** Both run in-process with the same decoding features. MLX's Metal shaders need `xcodebuild` (after a one-time `sudo xcodebuild -runFirstLaunch` and `xcodebuild -downloadComponent MetalToolchain`).
- **Measured (M3 Max, Hy-MT2):**

  | | llama.cpp | MLX |
  | --- | --- | --- |
  | Decode, 1.8B | 158 tok/s (Q4_K_M) | 197 tok/s (4-bit), 118 tok/s (8-bit) |
  | Decode, 7B 4-bit | 49 tok/s | 55 tok/s |
  | Call with N new prompt tokens + 1 generated (1.8B, best of 10) | 12 / 16 / 32 / 41 ms (N = 1 / 8 / 16 / 64) | 12 / 18 / 25 / 37 ms |
  | Identical to Tencent's full-precision 1.8B (25 sentences × ja/de/es) | 9–12 (Q4_K_M) | 16–18 (8-bit), 6–12 (4-bit) |
  | chrF against the 7B's translations (ja / de / es) | 60.0 / 78.5 / 80.6 | 62.8 / 79.9 / 82.6 (8-bit), 59.6 / 75.9 / 79.4 (4-bit) |
  | In the app: live p50, final caption after speech (ja / de / es) | 84, 452 / 73, 423 / 70, 413 ms | 108, 517 / 93, 498 / 85, 439 ms (8-bit live, 4-bit 7B) |

- **Why MLX is slower in the app despite faster decoding.** The 4-bit MLX conversions (plain affine 4-bit, including the vocabulary) translate less steadily than llama.cpp's mixed 4/6-bit Q4_K_M. Each update then keeps fewer draft tokens (3.7 vs 6.8) and generates more. The 8-bit model is steady but decodes 25% slower. On Apple GPUs MLX also runs batches under ~13 tokens row by row, so verifying a draft costs about 1 ms per token.
- **swift-transformers is not a faithful tokenizer for Hy-MT2.** Swift's `String.range(of:options: .regularExpression)` splits differently from the reference, so ":\n\n" became three tokens. `LocalMLX/BPETokenizer` uses `NSRegularExpression` and drops characters missing from the vocabulary before merging, as the reference does (Hy-MT2 1.8B has no "\r"). It matches on 388/388 test strings.
- **Tencent's Q8_0 and Q6_K 1.8B GGUFs don't match the current weights** (19% relative difference per tensor; Q4_K_M is within normal quantization error), which is why they translated no better than Q4_K_M. The llama.cpp graph itself matches the reference (RoPE base 11,158,840 and RoPE before the Q/K norm).
- **LM Studio stays as an optional external engine.** Its raw `/v1/completions` endpoint allows prefix forcing. **Measured with Hy-MT2 1.8B served over the OpenAI API:** live p50 108 ms, NE 0.79, 0/19 replaced, against 126 ms, NE 1.12 and 8/19 replaced through the chat API.
- **Small models leak context.** With two words of source and a long "background" of earlier sentences, Hy-MT2 1.8B translates the background instead ("Think we" → the previous sentence), and prefix forcing keeps it. Context is now given only from six words on, and never to the continuation of a sentence cut at the length cap.

Sources: huggingface.co/tencent/Hy-MT2-1.8B, arxiv.org/abs/2605.22064, arxiv.org/abs/2601.09012, aclanthology.org/2025.wmt-1.22, github.com/ml-explore/mlx-swift-lm, huggingface.co/sahilchachra/hy-mt2-1.8b-8bit-mlx, huggingface.co/sahilchachra/hy-mt2-7b-4bit-mlx, lmstudio.ai/docs/developer.

## 4. Product and caption UX
- **Roll-up captions, 2–3 lines.** Rewrites only touch the provisional tail of the last line, and committed lines never reflow.
- **Show the tiers visually.** Provisional text is dimmed or italic, new words fade in, and Reduce Motion is respected.
- **Expect 2–4 s for stable translated text.** That's the realistic figure across the industry (KUDO 4.1 s, Interprefy 3–9 s). Vendors claiming under 1 s are quoting first-token or transport latency.
- **Professional baseline features:**
  - one "Responsive ↔ Stable" control;
  - a lag indicator;
  - a glossary, with speech-recognition biasing plus forced and do-not-translate terms;
  - TXT/SRT/VTT export;
  - bilingual display;
  - a pause hotkey;
  - system-audio capture.

Sources: research.google/blog/stabilizing-live-speech-translation-in-google-translate, research.google/blog/modeling-and-improving-text-stability-in-live-captions, arxiv.org/abs/2009.09016, w3.org/WAI/WCAG22/Understanding/captions-live.
