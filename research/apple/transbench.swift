// transbench.swift — Apple Translation フレームワークの速度と訳を、bench.py と同じ12文で測る
// 使い方(リポジトリのルートで): ./transbench [--runs 2]
// 事前に: システム設定 > 一般 > 言語と地域 > 翻訳言語 で「英語」「日本語」をダウンロード済みであること
import Foundation
import Translation

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

@main
struct TransBench {
    static func main() async {
        do { try await run() } catch {
            fputs("エラー: \(error)\n", stderr)
            exit(1)
        }
    }

    static func run() async throws {
        let args = CommandLine.arguments
        var runs = 2
        if let i = args.firstIndex(of: "--runs"), i + 1 < args.count, let n = Int(args[i + 1]) { runs = n }

        let text = try String(contentsOfFile: "sentences.txt", encoding: .utf8)
        let sentences = text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !sentences.isEmpty else { throw AppError("sentences.txt が空、または リポジトリのルートで実行していません") }

        let src = Locale.Language(identifier: "en")
        let tgt = Locale.Language(identifier: "ja")
        let strategies: [(String, TranslationSession.Strategy)] = [
            ("apple-lowLatency", .lowLatency),
            ("apple-highFidelity", .highFidelity),
        ]

        var raw: [[String: Any]] = []
        var outputsByModel: [String: [String]] = [:]
        var summary: [(String, Double, Double, Double, Int)] = []

        for (name, strategy) in strategies {
            print("\n=== \(name) ===")
            let session = TranslationSession(installedSource: src, target: tgt, preferredStrategy: strategy)
            // ウォームアップ(モデル読込)
            let w0 = ProcessInfo.processInfo.systemUptime
            do {
                _ = try await session.translate("Hello.")
            } catch {
                print("  翻訳に失敗しました: \(error)")
                print("  → 翻訳言語(英語/日本語)がダウンロード済みか確認してください")
                continue
            }
            print(String(format: "  warm-up: %.0f ms", (ProcessInfo.processInfo.systemUptime - w0) * 1000))

            var times: [Double] = []
            var notJa = 0
            var firstRunOutputs: [String] = []
            for r in 0..<runs {
                for s in sentences {
                    let t0 = ProcessInfo.processInfo.systemUptime
                    var out = ""
                    do {
                        out = try await session.translate(s).targetText
                    } catch {
                        out = "ERROR: \(error)"
                    }
                    let ms = (ProcessInfo.processInfo.systemUptime - t0) * 1000
                    times.append(ms)
                    let bad = !hasJapanese(out)
                    if bad { notJa += 1 }
                    if r == 0 { firstRunOutputs.append(out) }
                    raw.append(["model": name, "en": s, "ttft_ms": Int(ms.rounded()), "total_ms": Int(ms.rounded()),
                                "tok_s": 0, "tokens": 0, "load_ms": 0, "think_chars": 0,
                                "text": out.replacingOccurrences(of: "\n", with: " "), "not_ja": bad ? 1 : 0])
                    print(String(format: "  %5.0f ms | %@", ms, out.replacingOccurrences(of: "\n", with: " ")))
                }
            }
            outputsByModel[name] = firstRunOutputs
            summary.append((name, median(times), times.max() ?? 0, times.min() ?? 0, notJa))
        }

        print("\n==== 要約 (1文あたり。ストリーミングなしなので TTFT=total) ====")
        print(String(format: "%-22@ %10@ %10@ %10@ %8@", "model" as NSString, "中央値ms" as NSString, "最大ms" as NSString, "最小ms" as NSString, "非日本語" as NSString))
        for (n, med, mx, mn, nj) in summary {
            print(String(format: "%-22@ %10.0f %10.0f %10.0f %8d", n as NSString, med, mx, mn, nj))
        }
        if let a = outputsByModel["apple-lowLatency"], let b = outputsByModel["apple-highFidelity"], a.count == b.count {
            let same = zip(a, b).filter { $0 == $1 }.count
            print("lowLatency と highFidelity の訳が同一: \(same) / \(a.count) 文" + (same == a.count ? "  (同じモデルが使われている可能性)" : ""))
        }

        let df = DateFormatter(); df.dateFormat = "yyyyMMdd-HHmmss"
        let base = "results/bench-\(df.string(from: Date()))-thinkoff-apple"
        let data = try JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: URL(fileURLWithPath: base + ".json"))
        print("\n保存: \(base).json")
    }
}
