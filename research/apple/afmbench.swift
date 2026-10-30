// afmbench.swift — Apple Foundation Models (オンデバイス) の翻訳の速さと訳を測る
// 使い方(リポジトリのルートで): ./afmbench [--input research/sentences.txt] [--runs 1] [--no-fewshot] [--name apple-afm] [--no-context]
// 入力の行に TAB があれば「直前の英語<TAB>訳す英語」として扱い、直前の英語を文脈として渡す(--no-context で無視)
// 出力: results/bench-<日時>-thinkoff-afm.json (compare.py がそのまま読める形式、model名は apple-afm)
import Foundation
import FoundationModels

struct AppError: Error, CustomStringConvertible {
    let description: String
    init(_ s: String) { description = s }
}

func hasJapanese(_ s: String) -> Bool {
    s.unicodeScalars.contains { ($0.value >= 0x3040 && $0.value <= 0x30FF) || ($0.value >= 0x4E00 && $0.value <= 0x9FFF) }
}

func median(_ a: [Double]) -> Double {
    let s = a.sorted()
    if s.isEmpty { return 0 }
    return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
}

let system = """
あなたは英語から日本語への同時通訳者です。入力された英語を、意味を変えずに自然な日本語に訳します。\
文が途中で終わっていても、聞こえた部分だけを訳してください。説明・注釈・前置きは一切書かず、日本語訳だけを1行で出力します。\
Claude, Anthropic, MCP, AGI, API, LLM, SDK, Slack, Zoom などの固有名詞・IT用語は英語のまま残します。
"""

let fewshot: [(String, String)] = [
    ("Thanks for coming in today.", "本日はお越しいただきありがとうございます。"),
    ("We're looking for someone who can, um, own the whole", "全体を担当できる人を探しています。"),
    ("Let's connect the model to Slack using MCP.", "MCPを使ってモデルをSlackに接続しましょう。"),
]

let contextNote = "「直前の英語」は話の流れを知るための参考です。訳すのは「英語:」の行だけで、直前の英語は訳に含めません。"

func buildPrompt(_ sentence: String, useFewshot: Bool, context: String = "") -> String {
    var p = ""
    if useFewshot {
        for (en, ja) in fewshot { p += "英語: \(en)\n日本語: \(ja)\n\n" }
        if !context.isEmpty {
            p += "直前の英語: We give it open-ended problems,\n英語: where it can take many steps\n日本語: そこでは多くのステップを踏むことができ\n\n"
        }
    }
    if !context.isEmpty { p += "直前の英語: \(context)\n" }
    p += "英語: \(sentence)\n日本語:"
    return p
}

@main
struct AFMBench {
    static func main() async {
        do { try await run() } catch {
            fputs("エラー: \(error)\n", stderr)
            exit(1)
        }
    }

    static func run() async throws {
        let args = CommandLine.arguments
        var runs = 1
        var input = "sentences.txt"
        let useFewshot = !args.contains("--no-fewshot")
        let useContext = !args.contains("--no-context")
        var name = "apple-afm"
        if let i = args.firstIndex(of: "--name"), i + 1 < args.count { name = args[i + 1] }
        if let i = args.firstIndex(of: "--runs"), i + 1 < args.count, let n = Int(args[i + 1]) { runs = n }
        if let i = args.firstIndex(of: "--input"), i + 1 < args.count { input = args[i + 1] }

        let model = SystemLanguageModel.default
        switch model.availability {
        case .available: break
        case .unavailable(let reason): throw AppError("AFMが使えません: \(reason)")
        }
        if !model.supportsLocale(Locale(identifier: "ja_JP")) {
            print("注意: supportsLocale(ja_JP) が false です。結果が不安定かもしれません")
        }

        let text = try String(contentsOfFile: input, encoding: .utf8)
        let sentences = text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !sentences.isEmpty else { throw AppError("\(input) が空、または リポジトリのルートで実行していません") }
        print("入力: \(input) \(sentences.count) 文 / few-shot: \(useFewshot ? "あり" : "なし")")

        // ウォームアップ(初回のモデル読み込みを測定に含めない)
        let warm = LanguageModelSession(model: model, instructions: system)
        let w0 = Date()
        _ = try? await warm.respond(to: buildPrompt("Hello.", useFewshot: useFewshot))
        print(String(format: "ウォームアップ: %.0f ms", Date().timeIntervalSince(w0) * 1000))

        var raw: [[String: Any]] = []
        var ttfts: [Double] = [], totals: [Double] = []
        var notJa = 0, refused = 0

        for line in sentences {
            var ctx = ""
            var s = line
            if let tab = line.firstIndex(of: "\t") {
                ctx = useContext ? String(line[..<tab]).trimmingCharacters(in: .whitespaces) : ""
                s = String(line[line.index(after: tab)...]).trimmingCharacters(in: .whitespaces)
            }
            for r in 0..<runs {
                // 文ごとに新しいセッション(前の文の影響を受けない)
                let session = LanguageModelSession(model: model, instructions: ctx.isEmpty ? system : system + contextNote)
                let t0 = Date()
                var ttft: Double? = nil
                var out = ""
                var err = ""
                do {
                    let stream = session.streamResponse(to: buildPrompt(s, useFewshot: useFewshot, context: ctx))
                    for try await snap in stream {
                        let cur = snap.content
                        if ttft == nil, !cur.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            ttft = Date().timeIntervalSince(t0) * 1000
                        }
                        out = cur
                    }
                } catch {
                    err = "\(error)"
                    refused += 1
                }
                let total = Date().timeIntervalSince(t0) * 1000
                let text1 = out.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                let bad = err.isEmpty && !hasJapanese(text1)
                if bad { notJa += 1 }
                if err.isEmpty { ttfts.append(ttft ?? total); totals.append(total) }
                var row: [String: Any] = ["model": name, "en": s, "ctx": ctx, "ttft_ms": Int((ttft ?? total).rounded()),
                                          "total_ms": Int(total.rounded()), "tok_s": 0, "tokens": 0, "load_ms": 0,
                                          "think_chars": 0, "text": err.isEmpty ? text1 : "(エラー) \(err)",
                                          "not_ja": bad || !err.isEmpty ? 1 : 0]
                if !err.isEmpty { row["error"] = err }
                if r == 0 { raw.append(row) }
                print(String(format: "  TTFT %4.0f / total %4.0f ms | %@", ttft ?? total, total, err.isEmpty ? text1 : "(エラー) \(err)"))
            }
        }

        print("\n==== 要約 ====")
        print(String(format: "TTFT 中央値 %.0f ms / total 中央値 %.0f ms / total 最大 %.0f ms", median(ttfts), median(totals), totals.max() ?? 0))
        print("非日本語: \(notJa) / エラー(ガードレール等): \(refused) / 全 \(sentences.count * runs) 件")

        let df = DateFormatter(); df.dateFormat = "yyyyMMdd-HHmmss"
        let base = "results/bench-\(df.string(from: Date()))-thinkoff-\(name)"
        let data = try JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: URL(fileURLWithPath: base + ".json"))
        print("保存: \(base).json")
    }
}
