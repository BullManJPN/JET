# jetcli 設計 (2026-10-28)  Swift 試作 第1段: 画面なしコマンド

> **注(10/30)**: 最終訳(Haiku)は削除済みで、アプリ本体は外部 API を呼ばない。この文書は設計時点(10/28)の記録。`results/` などの測定データは公開していない。

最初の段階として作った。マイク → 英語確定 → 節 → AFM下書き → Haiku確定訳 を、research/sim/jet_sim.py と同じ種類のイベント(JSONL)で出す。画面は後でこのイベントを表示する薄い層として載せる。

## 方針
- お手本は `research/sim/core.py`。同じ録音ログを Swift に通し、確定・節・補正の結果が一致することを毎回確かめる(`research/sim/parity.py`)
- Core は時計を持たない純ロジック(Foundation のみ)。`ingest(volatile, wall)` / `ingest(final, wall)` / `tick(now)` を受けてイベントを返す。`--replay` でも `--mic` でも同じコードが動く
- パラメータとプロンプトは `jet.json` と `prompts/` に出す
- ビルドは `./build_jet.sh`(swiftc -O -parse-as-library -swift-version 5 jet/*.swift)。実行は Terminal(当時、Haiku を呼ぶ測定スクリプトだけが環境変数のキーを使っていた)

## 構成
```
jet/Core.swift         設定、語分割、用語補正、LocalAgreement、節の閉じ判定、先出し、最終訳の入力の切り出し
jet/SeqMatcher.swift   difflib.SequenceMatcher の移植(あいまい一致 0.84、古い下書き判定)
jet/Events.swift       イベント型と JSONL 出力
jet/Translators.swift  下書き(AFM)、最終訳(Haiku)、モック、後処理(英日間の半角スペース除去)
jet/Pipeline.swift     Core → 下書きキュー → 最終訳キュー(どちらも FIFO・直列)
jet/Sources.swift      --replay / --file / --mic(SpeechAnalyzer。asrlog.swift の feedMic を移植)
jet/Jet.swift          @main と引数
jet.json  prompts/  build_jet.sh  research/sim/dump_events.py  research/sim/parity.py
```
入力: `--replay <asr-*.jsonl> [--speed 0|1|N]` / `--file x.wav`(実時間) / `--mic [--seconds N] [--save-audio]`
その他: `--config jet.json` `--no-draft` `--no-final` `--mock-translate` `--events <path>`
live 実行でも asrlog と同じ形式の認識ログを保存する(後で --replay で再現できる)

## イベント
`seg`(区間の見出し) / `commit`(確定語) / `clause`(節が閉じた) / `draft`(下書き訳) / `final_req`(最終訳の送信) / `final`(最終訳) / `clause_stale`(ASR確定時に古い下書きと分かった節)
- すべて `file`(ログ名)と `seg`(区間番号。空テキストの区間も数える)を持つ。live の file は実行日時
- `draft` / `final` は本文(ja)、待ち時間、所要時間、ガードレール停止の有無を持つ

## 照合 (S1 の合格条件)
`python3 research/sim/dump_events.py` で正解を作る(`results/golden-events.jsonl`(非公開)、hold_last 0)。
実録音6本: 68区間 / 1040語 / 144節 / 79単位(先出し12) / 古い下書き34
`python3 research/sim/parity.py <jetcli の出力>` が「完全一致」になること。時刻と訳は比べない
注: 初期のシミュレーター結果(1038語・143節・80単位・古い下書き37)は hold_last 1 かつ別名表追加前の数字。`results/golden-events-hold1.jsonl`(非公開) は hold_last 1 での現在の値(1037語・143節・80単位・34)

## 実装で気をつける所
1. ASR更新の 0.3秒まとめ: sim は後から一括で処理。live は「0.3秒静かになったら閉じる」タイマーが要り、英語表示が最大 0.3秒遅れる可能性がある(未測定)。`coalesce_ms` で調整。照合時は wall の差で判定する(タイマーなし)
2. 最終訳の英語の切り出し: 先出しの単位は確定済みの語、区間の最後の単位は ASR確定テキストの k_start 以降(規則は make_final_inputs.py にあった。dump_events.py と Core に取り込む)。位置で切るので語数がずれると位置もずれる。まず Python と同じ方式で移す
3. 用語補正のあいまい一致は difflib の ratio(0.84)。SeqMatcher.swift で忠実に移植(最長一致の同点処理も同じにする)
4. 最終訳の差し替え部品は、まず自前の `FinalTranslator` プロトコル(Haiku / AFM / モック)。Foundation Models の LanguageModel プロトコルとの統合は、型を確認してから
5. `drop_late_draft`(既定 true): 下書きが出る前に、その節を含む単位の最終訳が出ていたら下書きを捨てる。照合時は false
6. 下書きの安全策 v1: ガードレールのエラー / かなが無く漢字だけ / 英字が `guard_en_ratio` 以上 → 英語の塊を表示。基準は実測で調整
7. 最終訳: claude-haiku-4-5-20251001, temperature 0.2, max_tokens 400, ストリーミング。入力 = 訳す英語 + 直前 `ctx_units`(2) 単位の英語 + 直前の訳

## 段階
| 段階 | 内容 | 確認 |
|---|---|---|
| S0 | dump_events.py / jet.json / prompts / parity.py / build_jet.sh | 正解イベントが作れる(完了) |
| S1 | Core + --replay + --mock-translate | parity.py が完全一致 |
| S2 | AFM下書き + Haiku最終訳を接続。--replay --speed 1 | sim の見込み(下書き約0.26s / 最終訳約0.93s)と比べる |
| S3 | --mic + SpeechAnalyzer。認識ログも保存 | 実際に話して各イベントの遅れを見る |
| S4 | live と sim の比較レポート | |
その後: システム音声(ScreenCaptureKit)、画面、返答案

## 追記 (10/28 S3 以降)
- ASR更新のまとめ幅は 100ms(`coalesce_ms`)、ティッカーは 10ms。live の時計は最初の音声バッファを0秒とする(LiveClock)
- 最終訳の単位の切り出しは difflib の対応づけ(alignedNext)。位置で数えると語が落ちる不具合があった
- 間(ま)での強制確定(`--pause-ms` `--pause-db`)は実験の結果不採用で、コードは削除済み。既定は無効。詳細は docs/research-asr.md の「間(ま)での強制確定の実験」

## 追記 (10/28 システム音声 S4)
- 方針: v1 は全システム音声(自プロセス除く)。`--app <bundleID>` は後から SCContentFilter の作り方だけ変えて追加できる
- 構成: `jet/SystemAudio.swift`(SCStream → AVAudioPCMBuffer)、`Live.feedSystem`(feedMic と同じ受け口: 保存・pause.feed・変換・clock・yield)、`--system`(`--mic` と排他)。保存は `samples/sys-<日時>-live.wav`
- SCStream: capturesAudio, excludesCurrentProcessAudio, 48kHz/モノラル, 映像は 2x2・1fps、音声出力だけ登録。AVAudioConverter は最初のバッファで作る
- 権限: 画面とシステムオーディオの録音(Terminal に付与、再起動が必要)
- 今回やらない: 自分の声との分離、アプリ指定、画面
| 段階 | 内容 | 確認 |
|---|---|---|
| S4a | `research/apple/sckprobe.swift` 単体で取り込み → WAV 保存 | 権限・型・バッファ到着間隔・WAV が再生できる |
| S4b | feedSystem を接続し --system で認識まで通す | 認識ログが出る |
| S4c | afplay で実録音を流してマイク録音と比較 | 語数・WER が同等 |
| S4d | 実会議音声で比較(実施せず。docs/research-asr.md 参照) | |
