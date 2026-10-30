import Foundation

struct DraftResult {
    var ja: String
    var guarded: Bool
    var echo = false   // 例文(few-shot)の日本語が混ざっていたので取り除いた
    var raw = ""       // AFM の出力そのもの(例文の除去などの前。ベンチの分析用)
}

/// AFM が few-shot の例文の日本語をそのまま出すことがある(10/29 実測 343件中5件。必ず最後の例文)。
/// 出力から例文の日本語を取り除いた残りを返す。入力が例文の英語そのものなら、正しい訳なので取り除かない。
/// 残りが空なら空を返す(呼び出し側で英語の表示に回る)
func stripFewshotEcho(_ ja: String, input en: String, examples: [(en: String, ja: String)]) -> String {
    let norm: (String) -> String = { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    var t = ja
    for ex in examples {
        if norm(ex.en) == norm(en) { continue }
        let full = ex.ja.trimmingCharacters(in: .whitespacesAndNewlines)
        if full.isEmpty { continue }
        var bare = full
        while let last = bare.last, "。.！？!?".contains(last) { bare.removeLast() }
        // 句点つきを先に(残りに「。」だけが残らないように)
        for pat in [full, bare] where !pat.isEmpty {
            t = t.replacingOccurrences(of: pat, with: " ")
        }
    }
    if t == ja { return ja }
    // 取り除いた跡を整える: 先頭に残った空白・句読点は除く。末尾は空白だけ除く(訳の「。」は残す)
    while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
    let lead: Set<Character> = [" ", "　", "\n", "\t", "、", "。", ",", "."]
    while let f = t.first, lead.contains(f) { t.removeFirst() }
    return t.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// stripFewshotEcho の単体テスト(./jetcli --selftest)
enum EchoSelftest {
    static func run() -> Bool {
        var fails = 0, total = 0
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            total += 1
            if !ok { fails += 1; print("NG  echo: \(name)  \(detail())") }
        }
        let ex: [(en: String, ja: String)] = [
            (en: "Thanks for coming in today.", ja: "本日はお越しいただきありがとうございます。"),
            (en: "Let's connect the model to Slack using MCP.", ja: "MCPを使ってモデルをSlackに接続しましょう。"),
        ]
        func s(_ ja: String, _ en: String) -> String { stripFewshotEcho(ja, input: en, examples: ex) }
        // 10/29 の実例
        check("例文だけ → 空", s("MCPを使ってモデルをSlackに接続しましょう。", "Let's start with a stack.") == "")
        check("例文 + 正しい訳 → 正しい訳だけ",
              s("MCPを使ってモデルをSlackに接続しましょう。 そして、そのコアエージェントループを完成させる。", "and perfecting that core agent loop.")
                == "そして、そのコアエージェントループを完成させる。", s("MCPを使ってモデルをSlackに接続しましょう。 そして、そのコアエージェントループを完成させる。", "x"))
        check("句点なしの例文も取る", s("MCPを使ってモデルをSlackに接続しましょう オープンエンドの問題を与える", "x") == "オープンエンドの問題を与える")
        check("後ろに付いた例文も取る", s("問題を与えます。MCPを使ってモデルをSlackに接続しましょう。", "x") == "問題を与えます。")
        // 取り除かないもの
        check("入力が例文の英語そのもの → そのまま", s("MCPを使ってモデルをSlackに接続しましょう。", "Let's connect the model to Slack using MCP.") == "MCPを使ってモデルをSlackに接続しましょう。")
        check("大文字小文字・前後の空白は同じとみなす", s("本日はお越しいただきありがとうございます。", "  thanks for coming in today. ") == "本日はお越しいただきありがとうございます。")
        check("例文を含まない訳はそのまま", s("Slackに接続します。", "connect to Slack") == "Slackに接続します。")
        check("一部だけ似ている訳はそのまま", s("MCPを使って接続しましょう。", "x") == "MCPを使って接続しましょう。")
        check("2つの例文が両方混ざる", s("本日はお越しいただきありがとうございます。MCPを使ってモデルをSlackに接続しましょう。", "x") == "")
        print("echo: \(total - fails) / \(total) 件OK")
        return fails == 0
    }
}

protocol DraftTranslator: Sendable {
    func translate(_ en: String) async throws -> DraftResult
    func warmup() async
}

extension DraftTranslator { func warmup() async {} }

/// 動作確認用。待ち時間は delay 秒(0なら即時)
struct MockDraft: DraftTranslator {
    var delay: Double
    func translate(_ en: String) async throws -> DraftResult {
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
        return DraftResult(ja: "【下書き】" + en, guarded: false)
    }
}
