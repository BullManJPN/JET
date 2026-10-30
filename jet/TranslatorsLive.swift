import Foundation
import FoundationModels

private func hasKana(_ s: String) -> Bool {
    s.unicodeScalars.contains { $0.value >= 0x3040 && $0.value <= 0x30FF }
}

private func hasHan(_ s: String) -> Bool {
    s.unicodeScalars.contains { $0.value >= 0x4E00 && $0.value <= 0x9FFF }
}

/// 下書き: Apple Foundation Models(端末内)。節ごとに新しいセッション、文脈なし、短いプロンプト
final class AFMDraft: DraftTranslator, @unchecked Sendable {
    private let system: String
    private let fewshot: String
    private let examples: [(en: String, ja: String)]
    private let userTpl: String
    private let enRatio: Double
    private let options: GenerationOptions

    init(conf: JetConfig) throws {
        switch SystemLanguageModel.default.availability {
        case .available: break
        case .unavailable(let reason): throw AppError("AFMが使えません: \(reason)")
        }
        let sys = try String(contentsOfFile: conf.draftSystem, encoding: .utf8)
        self.system = sys.trimmingCharacters(in: .whitespacesAndNewlines)
        self.userTpl = try String(contentsOfFile: conf.draftUser, encoding: .utf8)
        var fs = ""
        var exs: [(en: String, ja: String)] = []
        var tsv = ""
        if !conf.draftFewshot.isEmpty { tsv = try String(contentsOfFile: conf.draftFewshot, encoding: .utf8) }
        for l in tsv.components(separatedBy: "\n") {
            let p = l.components(separatedBy: "\t")
            if p.count >= 2 {
                fs += "英語: \(p[0])\n日本語: \(p[1])\n\n"
                exs.append((en: p[0], ja: p[1]))
            }
        }
        self.fewshot = fs
        self.examples = exs
        self.enRatio = conf.guardEnRatio
        self.options = GenerationOptions(sampling: conf.draftGreedy ? .greedy : nil,
                                         temperature: nil,
                                         maximumResponseTokens: conf.draftMaxTokens > 0 ? conf.draftMaxTokens : nil)
    }

    private func buildPrompt(_ en: String) -> String {
        userTpl.replacingOccurrences(of: "{FEWSHOT}", with: fewshot).replacingOccurrences(of: "{EN}", with: en)
    }

    private func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        for p in ["日本語:", "日本語："] where t.hasPrefix(p) {
            t = String(t.dropFirst(p.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return t
    }

    /// 日本語を出さず英語の塊を表示する条件(v1の簡易判定): 空 / かなが無く漢字だけ(中国語の疑い) / かなも漢字も無い / 英字が多すぎる
    private func isBad(_ ja: String) -> Bool {
        if ja.isEmpty { return true }
        let kana = hasKana(ja), han = hasHan(ja)
        if !kana && !han { return true }
        if !kana && han { return true }
        var letters = 0, total = 0
        for u in ja.unicodeScalars where !u.properties.isWhitespace {
            total += 1
            if (u.value >= 0x41 && u.value <= 0x5A) || (u.value >= 0x61 && u.value <= 0x7A) { letters += 1 }
        }
        return total > 0 && Double(letters) / Double(total) > enRatio
    }

    func translate(_ en: String) async throws -> DraftResult {
        let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: system)
        var out = ""
        let stream = session.streamResponse(to: buildPrompt(en), options: options)
        for try await snap in stream { out = snap.content }
        let raw = clean(out)
        // 例文がそのまま混ざっていたら取り除く。残りが空なら isBad で英語の表示に回る
        let ja = stripFewshotEcho(raw, input: en, examples: examples)
        return DraftResult(ja: ja, guarded: isBad(ja), echo: ja != raw, raw: raw)
    }

    func warmup() async {
        let t0 = ProcessInfo.processInfo.systemUptime
        _ = try? await translate("Hello.")
        print(String(format: "AFM ウォームアップ %.0f ms", (ProcessInfo.processInfo.systemUptime - t0) * 1000))
    }
}
