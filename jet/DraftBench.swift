import Foundation

// 下書き(AFM)のベンチ。本番と同じ AFMDraft(プロンプトの組み立て・例文の除去・安全策)でテストセットを訳す。
//   ./jetcli --draft-bench results/draft-set.jsonl --name base [--greedy] [--draft-fewshot prompts/x.tsv] [--draft-system ..] [--draft-user ..]
// 入力: 1行1件の JSON {"id": "...", "en": "..."}(sim/make_draft_set.py で作る)
// 出力: results/draft-<name>-<日時>.jsonl(1行目は条件の記録)。採点は python3 sim/draft_score.py <出力>

enum DraftBench {
    private static func median(_ a: [Double]) -> Double {
        let s = a.sorted()
        if s.isEmpty { return 0 }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    private static func pct(_ a: [Double], _ p: Double) -> Double {
        let s = a.sorted()
        if s.isEmpty { return 0 }
        return s[min(s.count - 1, Int(Double(s.count) * p))]
    }

    static func run(input: String, out: String?, conf: JetConfig, name: String) async throws {
        let text = try String(contentsOfFile: input, encoding: .utf8)
        var items: [(id: String, en: String)] = []
        for l in text.split(separator: "\n") {
            guard let d = l.data(using: .utf8),
                  let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let en = o["en"] as? String, !en.isEmpty else { continue }
            items.append((id: (o["id"] as? String) ?? "\(items.count)", en: en))
        }
        if items.isEmpty { throw AppError("テストセットが読めません: \(input)") }

        let draft = try AFMDraft(conf: conf)
        await draft.warmup()

        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        let path = out ?? "results/draft-\(name)-\(df.string(from: Date())).jsonl"
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: nil)
        let h = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        func write(_ o: [String: Any]) {
            if let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes]) {
                h.write(d)
                h.write(Data("\n".utf8))
            }
        }
        write(["kind": "meta", "name": name, "set": input, "n": items.count,
               "system": conf.draftSystem, "fewshot": conf.draftFewshot, "user": conf.draftUser,
               "greedy": conf.draftGreedy, "max_tokens": conf.draftMaxTokens])

        print("下書きベンチ: \(name)  \(items.count) 件  greedy=\(conf.draftGreedy)  fewshot=\(conf.draftFewshot)")
        var lats: [Double] = []
        var nGuard = 0, nEcho = 0, nErr = 0
        for (i, it) in items.enumerated() {
            var rec: [String: Any] = ["id": it.id, "en": it.en]
            let t0 = ProcessInfo.processInfo.systemUptime
            do {
                let r = try await draft.translate(it.en)
                rec["ja"] = r.ja
                rec["raw"] = r.raw
                rec["guard"] = r.guarded
                rec["echo"] = r.echo
                if r.guarded { nGuard += 1 }
                if r.echo { nEcho += 1 }
            } catch {
                rec["guard"] = true
                rec["error"] = "\(error)"
                nGuard += 1
                nErr += 1
            }
            let lat = ProcessInfo.processInfo.systemUptime - t0
            lats.append(lat)
            rec["lat"] = r3(lat)
            write(rec)
            if (i + 1) % 50 == 0 { print("  \(i + 1) / \(items.count)") }
        }
        try? h.close()
        print(String(format: "完了: 時間 中央値 %.0f ms / p90 %.0f ms / 最大 %.0f ms", median(lats) * 1000, pct(lats, 0.9) * 1000, (lats.max() ?? 0) * 1000))
        print("英語表示(安全策) \(nGuard) 件(うちエラー \(nErr))/ 例文の除去 \(nEcho) 件")
        print("出力: \(path)")
        print("採点: python3 sim/draft_score.py \(path)")
    }
}
