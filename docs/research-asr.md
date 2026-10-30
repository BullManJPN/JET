# JET 調査・実測: 音声認識・システム音声 (10/28)

SpeechAnalyzer の実測、語彙対策(用語補正)、間(ま)での強制確定の実験(不採用)、システム音声(ScreenCaptureKit)の取り込み。翻訳側は `research-translation.md`。

> 測定に使った音声・書き起こし・測定結果のファイルは、プライバシーのため公開していません。

## 音声認識の実測

### 音声認識 (実マイク6本)
- 更新は約1秒ごと、ASRの確定は最後の語から約0.8秒後(合成音声と同じ傾向)
- ピリオドはポーズでの区間確定時にしか付かない。区間は最長19秒(句点なしの1文)
- **ASRの確定を待つと、各語の確定は話してから中央値3.4秒 / p90 8.6秒 / 最大20秒** → 遅すぎる
- 仮テキストの句読点で文を早期確定: 一致41%、早まるのは0.1秒 → 使えない
- **単語単位の LocalAgreement(2回連続一致)**: 90%の語を中央値1.3秒 / p90 1.9秒で確定。最終結果との食い違い4.9%(多くは "lar" "researchch" のような書きかけの語 → 最後の1語は確定しないルールで減らす)
- 固有名詞の誤認識が最大の精度問題: Claude → Claod/quad/clod/clawed/claw、MLX → 人名のような聞き違い、Macs → marks、SDK → SPK、code related → COVID related

### 調査メモ(音声認識まわり)
- SpeechTranscriber は contextualStrings(語彙ヒント)が効かない。効くのは DictationTranscriber(+ SFSpeechLanguageModel)
- LocalAgreement は whisper_streaming や CUNI の IWSLT 2025 同時通訳システムでも使われる定番。CUNIの報告: 文脈が長いと幻覚が増える、文単位で文脈を区切ると日本語で幻覚

## ASRの語彙対策 (10/28 完了)
- 同じ音声(実録音 real1, 64秒)で3通り比較。**SpeechTranscriber を採用**
  - Speech: 196語、句読点あり、確定18回(間の約0.8秒後)。用語ミス: Claud, Atropic など
  - Dictation: 116語、句読点なし、確定2回のみ。聞き取り自体の取りこぼしがある(例: 人名と会社名を含む文 → "my work task")。用語ヒント(contextualStrings)は効果なし
  - 合成音声(say)では Dictation が良く見えたが実音声では逆。合成音声は判定に使えない
- 対策: 認識後の用語補正 `research/asr-tools/correct_terms.py` + 別名表 `asr/term_aliases.tsv` + 用語集 `asr/terms.txt`
  - 実録音3箇所、実マイク61文のうち5文(MLX の聞き違い→MLX, SPK→SDK, clod/clawed code→Claude Code)を補正。誤変換なし
  - 直せない例: "odd relations", "pod models", "God to practice" → 最終訳プロンプトに用語集を渡して文脈で直す(未検証)
- (10/28 追加) 別名表に Claod / Claoud / Claed → Claude、claots → Claudes、**quad → Claude**(AI話題前提。quad core など普通の用法が要るなら外す。実録音6本では誤変換なし)
- Q&Aで他の登壇者の名前を呼ぶ場面の人名は、聞き違いではなく人名と判断 → 別名表には入れない
- 使い方: `python3 research/asr-tools/correct_terms.py <log.jsonl>` で差分表示 / `research/asr-tools/score_terms.py` でWERと用語ヒット数 / `research/asr-tools/run_term_compare.sh N VOICE`
- asrlog.swift のオプション: `--engine speech|dictation` `--terms <file>` `--save-audio`
- システム音声(Web会議の相手の声)の取り込みは後回し。実装時に ScreenCaptureKit などで追加し、同じ保存音声で再比較する(会議アプリの圧縮音声は別条件)

## 間(ま)での強制確定の実験 (10/28 不採用。コードは削除済み)
ねらい: 無音(間)を見つけたら `SpeechAnalyzer.finalize(through:)` で区間を強制確定し、LocalAgreement の待ち(約1.3秒)を飛ばして節を早く閉じる。`./jetcli --file x.wav --pause-ms N --pause-db D`(N=0 で無効)。音量は AVAudioEngine の入力と --file の両方で RMS(100ms窓)を測る
- 音量の分布: 実録音(10/28 154426)は音が小さく、静かな時 -66 〜 話している時 -52 dBFS ほどで、両者が連続していて固定の閾値でうまく分けられない。初期値 -45 dB では間が0回で、A/B は無効だった
- 再実験(同じ録音を実時間で流す。5条件。語数は強制なし189):
  - 間 300ms/-58dB: 42回、語109、語の一致率 0.533、古い下書き 28%
  - 間 300ms/-62dB: 19回、語108、一致率 0.704、古い下書き 52%
  - 間 500ms/-58dB: 26回、語135、一致率 0.640、古い下書き 38%
  - 間 500ms/-62dB: 7回、語166(一致率 0.859)、古い下書き 39%
  - 強制なし: 古い下書き 16%。強制なし同士の語の一致率は 1.000(ASR は再現する)ので、下がった分は強制確定が原因
- 結果: 「節が閉じるまで」は 0.96秒 → 0.01〜0.82秒と縮んで見えるが、語が減って節が短くなっただけで本当の短縮ではない。確定を要求した直後の語が消える(数語まとめて欠落する、`Claude` → `Cla`、語尾が崩れる、など)。確定要求が戻るまでは中央値 0.16秒
- 判定: **不採用**。事前に決めた基準(一致率 1.000 未満、古い下書きの増加)を全条件で満たさない。`finalize(through:)` は話の途中で使うものではないらしい。消える原因(確定済みの時刻の渡し方か、確定後の続きの引き継ぎか)は未特定
- SpeechDetector(macOS 26 以降のVADモジュール): 音声がある部分だけを文字起こしに回す用途で、「間が来た」の通知は出ない(結果はエラーだけ)。SpeechModule への準拠問題も報告されている(27.2での状況は未確認)。今回の目的には使えない
- 残した部品: Pause.swift(音量検出)と `--pause-ms` `--pause-db`。既定は無効(pauseMs 0)。使うなら次の方式: ASR は止めず、間を見つけた時に自前で節を閉じるだけ(確定済みの語は LocalAgreement が出し続けるので語は消えない)。見込みは小さい(ASR自身の確定が話し終わりの約0.8秒後で、500msの間を待つと縮むのは0.3秒前後)ため、優先度は低い。閾値は録音の静かな音量からの相対値にすること

## システム音声の取り込み (10/28 S4a〜S4c 完了、S4dは実施せず決定済み)  `jet/SystemAudio.swift` `research/apple/sckprobe.swift` 設計は `DESIGN-swift.md` 末尾
ScreenCaptureKit(SCStream)の音声だけで、相手の声(システム音声)を SpeechAnalyzer に流す。`./jetcli --system [--play x.wav] [--exclude-self] [--seconds N] [--save-audio]`(`--mic` と排他)。保存は `samples/sys-<日時>-live.wav`、認識ログは今までと同じ形式
- **S4a(単体確認 `research/apple/sckprobe.swift`)**: macOS 27.2 で動く。48kHz モノ Float32、960フレーム(20ms)ずつ規則正しく届く(間隔 中央値21ms / 最大43ms)。startCapture から最初のバッファまで 1ms 以内。許可は「画面収録とシステムオーディオ録音」に Terminal(付与後 Terminal 再起動)
- **ハマりどころ**: `excludesCurrentProcessAudio = true` は、起動元の Terminal 配下(同じ Terminal から起動した afplay など)の音も除外し、完全な無音(-inf dBFS)になる。ブラウザなど Terminal の外のアプリの音は除外オンでも取れる。→ **既定は除外オフ**(jetcli は自分では音を出さない)。`--exclude-self` で除外オン。GUI 化して自分で音を鳴らすようになったら見直す
- 映像出力の登録は不要(音声だけの登録で取れる)。CMSampleBuffer の2通りの取り出し(CopyPCMData / GetAudioBufferList)は結果が一致
- **S4b**: --system → SpeechAnalyzer → LocalAgreement → AFM下書き → Haiku最終訳 が通った(12区間・節20・最終訳13単位)。下書き 中央値0.31s / p90 0.46s、最終訳 0.80s / p90 1.09s、ガードレール停止0、エラー0 = マイクのときと同等
- **S4c**: 実録音 real1(63.9秒)を afplay で鳴らして取り込み → 元のマイク録音を --file で認識した結果と比較(`research/asr-tools/compare_logs.py`)。語数 197 / 197、**基準とのWER 3.6%**、用語ヒット 3 → 4。差は6か所でASRの揺らぎの範囲(Claud→Claude 改善 / take→kick 悪化 / Atropic→Athropic どちらも誤り / a 脱落 / was→why is / God→quad)。**取り込みの live 認識と、保存wavの file 認識は完全に同一**(リアルタイム経路で劣化なし)
- 追加ファイル: `jet/SystemAudio.swift`(SystemAudioCapture / SysFeeder)、`jet/Live.swift`(feedSystem)、`jet/Jet.swift`(--system --exclude-self --play)、`research/apple/sckprobe.swift`、`research/asr-tools/compare_logs.py`
- **S4d の扱い(10/28 決定)**: 実施しない。普段使う会議アプリは「ブラウザの動画再生と同等」として扱う。電話(PSTN)参加は想定しない(電話回線は狭帯域 G.711 で精度が落ちる見込みだったが対象外)。マイク・相手側の機材による音質低下も、いったん置いておく。調べた事実: 会議アプリの音もシステム音声に出る(リモート参加者は1本に混ざり、話者の区別はつかない。自分のマイクの声は入らない)/ 電話系の通話は Opus(約70〜80kbps/ストリーム)の例がある / 会議のコーデックとサンプルレートは資料で確認できず / 同じアカウントで2台同時参加は挙動が一定しない(ゲスト参加なら確実)
- **未対応(残り)**: `--app <bundleID>`(特定アプリだけ取る。SCContentFilter の作り方だけ変えれば足せる)、自分の声との分離(2系統ASR)、Bluetooth出力・会議アプリ使用中の挙動、installTap の macOS 27 非推奨警告(既存のマイク側)

## 途中経過の崩れた語 (10/29 調査)  `research/sim/hold/hold_sim.py`
- 下書きに渡る英語に、音節が重なった・崩れた語が多い(neurural, provvider, dististributed, machineine, stepep, Theent, Aent, agetic, haging, erors)。**最終結果には1つもなく、途中経過(volatile)には10〜30回続けて同じ形で出る**。最終結果が出るまで途中では直らない(崩れた語が出てから最終結果まで多くは約1〜2秒)
- LocalAgreement(2回一致で確定)は、崩れたまま安定した語を確定してしまう。最終結果にない語を含む節は 577節中80(14%)。最終結果と食い違う節(clause_stale)は 1人で技術を話す動画で 24〜29%、対談では約7%
- 重なった音節を機械的に畳む案: 直るのは3%だけで、Ollama → olama、aan → an のような誤変換が出る → 不採用
- **辞書にない語の確定を待つ案(シミュレーション、未実装)**: 辞書は Hunspell en_US を語形変化まで展開した約16万語 + 用語集(本番なら NSSpellChecker)。4録音577節、本番と同じ設定(K=2、hold_last 0、coalesce 100ms)

| 案 | 英語が崩れた節 | 節が閉じる遅れ 中央値 | p90 |
|---|---|---|---|
| 今(待たない) | 16.5% | 0.99秒 | 2.03秒 |
| 辞書にない語は待つ 最長1秒 | 11.8% | 0.99秒 | 2.34秒 |
| 最長2秒 | 10.1% | 1.00秒 | 2.55秒 |
| **最長3秒** | **8.2%** | **1.00秒** | **2.66秒** |
| 最長5秒 | 7.8% | 1.00秒 | 2.84秒 |
| 最終結果まで | 7.3% | 1.00秒 | 2.92秒 |
| 小文字の語だけ待つ 最長2秒 / 3秒 | 12.0% / 10.9% | 0.99秒 | 2.27 / 2.31秒 |
- **(10/29 15:30) 最長3秒で実装**(`jet.json` の `hold_unknown_s`)。辞書は `asr/vocab.txt`(上の Hunspell 展開)を Python・Swift で共有。待たない語: 数字・序数、辞書の語、用語集の語と別名表の直し先の語、辞書の語の短縮形(I'm 等)
- シミュレーションの「今」の節数(577)は実際の live と一致。残る約8%は辞書にある語との取り違え(shut up←setup、readily←rarely、incomes←end caps、batting←batching)で、この方法では直らない
- (10/29) 別名表に14件追加: molelex / malexalan / mlxlm / mxlm / alexlm → MLX・MLX LM、haging phase / hugging phase → Hugging Face、agetic / aentic → agentic、aent → agent、deep sick(k) → DeepSeek、scrats / scrout → scratch。用語集に DeepSeek と MLX LM。「agentic」を用語集に入れると文頭の Agentic が小文字になるので入れない。過去の認識ログ48本で確認し、10/27〜28 の録音には変化なし(parity に影響なし)

## 公開動画の公式字幕との比較 (10/29、約4分・602語)
- SpeechAnalyzer の最終結果と公式字幕の違いは WER 2.5%。多くは表記ゆれ(数字・序数・複合語の綴り)か字幕側の誤りで、認識の方が正しい箇所もあった。両方とも誤りの箇所もあった
- AFM に渡した節は最終結果と完全に同じ(clause_stale 0 / 78節)。途中経過には崩れた語が出ていたが、待ち(3秒)で確定されなかった
- 待ちの対象を語形変化(-s / -ed / -ing など)とハイフン語まで広げる案: 最終結果の語のうち待つ語 212 → 140 / 10744、節が閉じる遅れ p90 2.66 → 2.37秒だが、崩れた節 8.2% → 9.4%(haging などを通す)。遅れは気にならないとのことなので不採用(今の判定のまま)
- 残る問題は訳の側で、主に節の切れ目: 接続詞で閉じた短い節が文末のように訳される、14語上限で語が分かれて意味が逆になる、前置詞の直後で節が分断される、など
