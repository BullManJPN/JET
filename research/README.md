# research/

Scripts and prompts used for the measurements described in `docs/research-asr.md` and `docs/research-translation.md`.
測定に使ったスクリプトとプロンプトです(参考用)。

- These were written for the original working layout and need audio, transcripts and result files that are **not published** (privacy). They are kept to show how the measurements were done, not to be re-run as is.
  音声・書き起こし・測定結果のファイルは公開していないため、そのままでは動きません。
- `bench.py`, `sim/draft_score.py`, `sim/final_test.py` call the Anthropic API (your own `ANTHROPIC_API_KEY` is required). **The app itself makes no network calls.**
  この3つだけが Anthropic の API を使う測定用スクリプトです。アプリ本体は外部と通信しません。
- `sentences.txt`: a small, hand-written English script (no real speakers) usable as a demo/bench input.
