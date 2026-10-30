// prefixbench.swift — 文を単語ごとに伸ばした断片を訳し、速度・断片での訳・書き換わりを記録する
// 使い方(リポジトリのルートで): ./prefixbench     出力: results/prefix-日時.json  集計: python3 apple/analyze_prefix.py <json>
import Foundation
import Translation

func now() -> Double { ProcessInfo.processInfo.systemUptime }

@main
struct PrefixBench {
    static func main() async {
        do { try await run() } catch {
            fputs("エラー: \(error)\n", stderr)
            exit(1)
        }
    }

    static func run() async throws {
        let text = try String(contentsOfFile: "sentences.txt", encoding: .utf8)
        let sentences = text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !sentences.isEmpty else {
            fputs("sentences.txt が空、または リポジトリのルートで実行していません\n", stderr)
            exit(1)
        }

        let src = Locale.Language(identifier: "en")
        let tgt = Locale.Language(identifier: "ja")
        let strategies: [(String, TranslationSession.Strategy)] = [
            ("apple-lowLatency", .lowLatency),
            ("apple-highFidelity", .highFidelity),
        ]

        var raw: [[String: Any]] = []
        for (name, strategy) in strategies {
            print("\n=== \(name) ===")
            let session = TranslationSession(installedSource: src, target: tgt, preferredStrategy: strategy)
            do { _ = try await session.translate("Hello.") } catch {
                print("  翻訳に失敗: \(error)")
                continue
            }
            var calls = 0
            var totalMs = 0.0
            for (si, s) in sentences.enumerated() {
                let words = s.split(separator: " ").map(String.init)
                for k in 1...words.count {
                    let prefix = words[0..<k].joined(separator: " ")
                    let t0 = now()
                    var out = ""
                    do { out = try await session.translate(prefix).targetText } catch { out = "ERROR: \(error)" }
                    let ms = (now() - t0) * 1000
                    calls += 1
                    totalMs += ms
                    raw.append(["strategy": name, "si": si, "k": k, "n": words.count,
                                "en": prefix, "ja": out.replacingOccurrences(of: "\n", with: " "),
                                "ms": Int(ms.rounded())])
                }
                print(String(format: "  文 %2d/%d 完了 (%d語)", si + 1, sentences.count, words.count))
            }
            print(String(format: "  %@: %d 回の呼び出し、平均 %.0f ms", name, calls, totalMs / Double(max(calls, 1))))
        }

        let df = DateFormatter(); df.dateFormat = "yyyyMMdd-HHmmss"
        let path = "results/prefix-\(df.string(from: Date())).json"
        let data = try JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: URL(fileURLWithPath: path))
        print("\n保存: \(path)")
        print("集計: python3 apple/analyze_prefix.py \(path)")
    }
}
