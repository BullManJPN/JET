# Findings

What was measured while building JET, and what each result changed. Full reports (Japanese): [`docs/research-asr.md`](../docs/research-asr.md), [`docs/research-translation.md`](../docs/research-translation.md), decision log [`docs/decisions.md`](../docs/decisions.md).

**How to read the numbers.** One Mac mini (24 GB, macOS 27.2), a few public videos plus live microphone recordings, a few hundred sentences or clauses per test. The audio, transcripts and test sets are not published. Translation quality was scored by an LLM judge (Claude Haiku 4.5) and spot-checked by hand; the same setup re-run varied by about 1 point and the judge varies per sentence, so only differences of several points are trusted.

## Summary

| Question | Finding | Decision |
|---|---|---|
| Do few-shot examples help the on-device model? | No. It copies them. 8 examples: 212 leaked-example cases, 39% bad translations. | No examples, greedy decoding |
| Does extra context or scene-setting help? | No. Giving the previous English made about half the outputs copy examples or translate the context; "this is an IT meeting" only swapped errors around. | Short prompt, no context |
| Which engine for live drafts? | The on-device model: median 0.39 s per sentence and consistent terminology. A local 8B model was 2.4× slower and made meaning-reversing errors. | On-device model only |
| When to confirm a recognized word? | Waiting for the recognizer's final result: median 3.4 s. Two matching updates: 1.3 s. | Word-level LocalAgreement (K=2) |
| Garbled intermediate words reach the translator | 14% of clauses contained a word that is not in the final text. Waiting up to 3 s for unknown words halves that. | Wait ≤ 3 s for words not in a dictionary |
| Force the recognizer to finalize at pauses? | No. It dropped words and made stale drafts worse. | Rejected |
| Keep a cloud "final translation" stage? | It was built and measured, then removed: the point of the project is on-device, no data leaving. | Removed; drafts only |
| How is the display kept stable? | Drafts only, never rewritten; older lines fade. | Flowing captions |

## 1. Translation engine

61 real microphone sentences (recognition errors included), latency per sentence:

| Engine | Median | p90 | Notes |
|---|---|---|---|
| Apple Foundation Models (on-device) | 392 ms | 610 ms | Stable terms and style; translates recognition errors as heard |
| Local 8B model (via Ollama) | 945 ms | 1756 ms | Terms mistranslated, mixed styles, some reversed meanings → rejected |
| Claude Haiku 4.5 (cloud) | 926 ms | 1267 ms | Best quality class; partly repairs recognition errors |
| Apple Translation (low-latency; 12-sentence test) | ~47 ms | – | Fast but stiff; also translates fillers |

The cloud model was kept out on purpose, not on quality: audio-derived text would leave the machine.

## 2. Prompt study for the on-device model

550 clauses from public-video sessions and microphone recordings, judged A/B/C by an LLM. "Readable" is measured on clauses whose recognized English is clean (about 410 of them); C = wrong or unclear meaning; "leaks" = a prompt example appearing in the output.

| Variant | Readable | C | Leaks | Median / p90 |
|---|---|---|---|---|
| Earlier setup (3 examples, sampled) | 81.6–82.5% (all clauses) | 12–13% (all) | 5–7 | 274–279 / 370–375 ms |
| Greedy, 3 examples | 90.3–90.5% | 3.7–3.9% | 6 | 269 / 363 ms |
| Examples reordered | 89.7% | 4.7% | 37 | 279 / 375 ms |
| 8 examples incl. failure types | 56.5% | 39.3% | 212 | 394 / 887 ms |
| Extra rule (don't change negation, comparison, numbers) | 90.7% | 4.7% | 1 | 288 / 371 ms |
| Scene setting (IT meeting) | 90–91% | 3.7–4.2% | 8 | ~288 / ~375 ms |
| **No examples (adopted)** | **93.2%** | **2.7%** | **0** | **257 / 350 ms** |
| One fragment example | 90.0% | 5.3% | 0 | 272 / 351 ms |
| One proper-noun example | 93.4% | 1.9% | 0 | 272 / 352 ms |

- The model treats examples as text to copy; the more examples, the more leaks, and even after removing leaks what remains is degraded. The leaked example is always the last one.
- Without any example, product names stay in English (76 of 76).
- Greedy decoding is as good, a little faster, and returns the same translation for the same input, which also makes comparisons repeatable.
- Remaining error types: numbers ("100s of 1000s"), negation and comparison ("too large to fit"), and words that need context ("Metal" → metal). In a hand check of 238 clauses, about 16 of the 22 clearly wrong ones came from mis-recognized English, not from the translator.

## 3. Speech recognition

- **Which recognizer.** On one 64-second real recording: SpeechTranscriber gave 196 words with punctuation; DictationTranscriber gave 116 words and missed speech. Contextual-string hints had no effect on SpeechTranscriber. Synthetic (text-to-speech) audio made the dictation recognizer look better than it was on real speech, so synthetic audio was not used for decisions.
- **Term correction.** An alias table plus conservative fuzzy matching (ratio ≥ 0.84) corrected 5 of 61 real microphone sentences with no false corrections.
- **Official captions.** On a 4-minute public video (602 words), the final recognition differed from the official captions by 2.5% WER, mostly spelling variants or errors in the captions themselves.
- **System audio.** ScreenCaptureKit delivers 48 kHz mono audio in 20 ms buffers (median interval 21 ms). Recognition on captured audio matched the original microphone recording at 3.6% WER (197 words in both). One trap: excluding the app's own audio also silences anything launched from the same Terminal, so it is off by default.

## 4. When to confirm a word

| Approach | Result |
|---|---|
| Wait for the recognizer's final text | Median 3.4 s, p90 8.6 s, max 20 s per word: too slow |
| Close on punctuation in intermediate text | 41% agreement, gains 0.1 s: unusable |
| **Confirm words that match in 2 consecutive updates** | **90% of words at median 1.3 s, p90 1.9 s; 4.9% differ from the final text** (mostly half-written words) |
| Force finalization at pauses (4 settings) | Word agreement 0.53–0.86; stale drafts 28–52% vs 16% baseline; words vanished after the request. **Rejected** |

## 5. Garbled intermediate words

Intermediate text contains words like `provvider` or `dististributed` that never appear in the final text, and they can stay stable for 10–30 updates. 80 of 577 clauses (14%) contained one. Simulation of waiting for words that are not in a dictionary (a Hunspell-derived list):

| Wait for unknown words | Clauses with garbled English | Clause-close delay, median | p90 |
|---|---|---|---|
| None (before) | 16.5% | 0.99 s | 2.03 s |
| up to 1 s | 11.8% | 0.99 s | 2.34 s |
| up to 2 s | 10.1% | 1.00 s | 2.55 s |
| **up to 3 s (adopted)** | **8.2%** | **1.00 s** | **2.66 s** |
| up to 5 s | 7.8% | 1.00 s | 2.84 s |
| until the final result | 7.3% | 1.00 s | 2.92 s |

Folding repeated syllables mechanically fixed only 3% and introduced new errors, so it was rejected. Extending the wait to inflected forms reduced waiting words (212 → 140 of 10,744) but increased garbled clauses (8.2% → 9.4%), so it was rejected too. The remaining ~8% are real-word confusions ("shut up" for "setup") that a dictionary cannot catch.

## 6. Where to cut a clause

Clauses are translated one by one. Comparing cut rules on recordings (an LLM judged the drafts):

| Rule | Clauses | English clean & readable (A) | C |
|---|---|---|---|
| v0: cut at and/or/which, 14-word cap | 654 | 42.5% | 12.9% |
| v4: and/or only before a subject, no cut at *which/where*, no cut after prepositions or articles, 18-word cap | 551 | 55.7% | 10.0% |

On a second set of 6 recordings (484 segments): v4 56.8% → v5 (after *and*, pronouns only) 58.7% → **v6 (wait up to 3 more words for punctuation past 18 words) 62.2%**, with C steady at 9.4–9.6%. The on-device model's p90 time rose from ~360 ms to ~410 ms as clauses got longer.

## 7. End-to-end delay

English appears about 1.3–1.4 s after speech; the draft appears 0.26–0.32 s after the clause closes: about **1.6 s** in total. The removed cloud "final translation" stage took a median 3.8 s (p90 9.6 s) from the first confirmed word of a segment, mostly waiting for the segment to close; the model call itself took ~0.95 s.

## 8. Tried and dropped

- Glossary in the cloud translator's prompt: little effect, side effects (apologies and questions as output), ~1.7× input tokens.
- Training an adapter for the on-device model: not supported from OS 27 per Apple's reply on the developer forums; the route is closed.
- Apple's cloud-backed model (Private Cloud Compute) as a drop-in for the cloud final-translation stage: it needs an entitlement and an Apple Developer Program membership, and it is not on-device. Dropped together with that stage.
- Local translation-specific small models: considered, not measured.

## Limits of this evidence

Small samples; one machine; videos chosen for convenience (technical talks and a product demo); an LLM judge. Treat these as design evidence, not benchmarks.
