// translist.swift — JSON の項目リスト(各項目に "text")を Apple Translation で訳し、"ja" と "ms" を付けて保存する
// 使い方(リポジトリのルートで): ./translist results/chunks-input.json results/chunks-output.json
import Foundation
import Translation

func now() -> Double { ProcessInfo.processInfo.systemUptime }

@main
struct TransList {
    static func main() async {
        do { try await run() } catch {
            fputs("エラー: \(error)\n", stderr)
            exit(1)
        }
    }

    static func run() async throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            fputs("使い方: ./translist <入力.json> <出力.json>\n", stderr)
            exit(2)
        }
        let inData = try Data(contentsOf: URL(fileURLWithPath: args[1]))
        guard let items = try JSONSerialization.jsonObject(with: inData) as? [[String: Any]] else {
            fputs("入力JSONの形式が違います\n", stderr)
            exit(2)
        }
        let src = Locale.Language(identifier: "en")
        let tgt = Locale.Language(identifier: "ja")
        let strategies: [(String, TranslationSession.Strategy)] = [
            ("apple-lowLatency", .lowLatency),
            ("apple-highFidelity", .highFidelity),
        ]
        var out: [[String: Any]] = []
        for (name, strategy) in strategies {
            print("=== \(name) ===")
            let session = TranslationSession(installedSource: src, target: tgt, preferredStrategy: strategy)
            do { _ = try await session.translate("Hello.") } catch {
                print("  翻訳に失敗: \(error)"); continue
            }
            var total = 0.0
            for item in items {
                guard let text = item["text"] as? String else { continue }
                let t0 = now()
                var ja = ""
                do { ja = try await session.translate(text).targetText } catch { ja = "ERROR: \(error)" }
                let ms = (now() - t0) * 1000
                total += ms
                var o = item
                o["strategy"] = name
                o["ja"] = ja.replacingOccurrences(of: "\n", with: " ")
                o["ms"] = Int(ms.rounded())
                out.append(o)
            }
            print(String(format: "  %d 項目、平均 %.0f ms", items.count, total / Double(max(items.count, 1))))
        }
        let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: URL(fileURLWithPath: args[2]))
        print("保存: \(args[2])")
    }
}
