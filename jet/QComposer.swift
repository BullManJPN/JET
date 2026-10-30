import Foundation
import FoundationModels

// 質問箱の AFM の案(段階 (4))。役割を分ける(10/29 改訂):
//   英語   AFM(材料 = 拾った語・型・入力欄・口調・字幕の行)。英語だけを1行で出させる
//   日本語 その英語を下書き訳と同じプロンプト(prompts/draft_system.txt・draft_user.txt)で訳す
//   カナ   AFM を使わず、発音辞書 + 規則(Kana.swift)
// 以前は AFM に英語・日本語・カナを一度に作らせていたが、日本語とカナが崩れ、JSON の記号が混ざった
// プロンプトは prompts/qbox_system.txt・qbox_user.txt(再ビルドなしで直せる)

final class QComposer: @unchecked Sendable {
    private let system: String
    private let userTpl: String
    private let jaSystem: String
    private let jaUserTpl: String
    private let options: GenerationOptions

    init(systemPath: String, userPath: String, jaSystemPath: String, jaUserPath: String) throws {
        switch SystemLanguageModel.default.availability {
        case .available: break
        case .unavailable(let reason): throw AppError("unavailable: \(reason)")
        }
        func read(_ p: String) throws -> String {
            try String(contentsOfFile: p, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        self.system = try read(systemPath)
        self.userTpl = try read(userPath)
        self.jaSystem = try read(jaSystemPath)
        self.jaUserTpl = try read(jaUserPath)
        self.options = GenerationOptions(sampling: .greedy, temperature: nil, maximumResponseTokens: 200)
    }

    /// 英語の発言(1行)。使えない出力なら空。must = 必ず入れる語(1回目に入らなかった語でやり直すとき)
    func english(_ req: QRequest, must: [String] = []) async throws -> String {
        let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: system)
        let r = try await session.respond(to: req.prompt(userTpl, must: must), options: options)
        return QCompose.cleanEnglish(r.content)
    }

    /// 英語 → 日本語(字幕の下書き訳と同じプロンプト・例文なし)。日本語が出なければ空
    func japanese(_ en: String) async throws -> String {
        let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: jaSystem)
        let prompt = jaUserTpl.replacingOccurrences(of: "{FEWSHOT}", with: "").replacingOccurrences(of: "{EN}", with: en)
        let r = try await session.respond(to: prompt, options: options)
        return QCompose.cleanJapanese(r.content)
    }

    /// 最初の呼び出しは AFM の読み込みで遅いので、質問箱を開いたときに軽く1回呼んでおく
    func warmup() async {
        _ = try? await japanese("Hello.")
    }

    /// 秒数を超えたら timeout を投げる
    static func withTimeout<T: Sendable>(_ seconds: Double, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { g in
            g.addTask { try await op() }
            g.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw AppError("timeout")
            }
            guard let r = try await g.next() else { throw AppError("timeout") }
            g.cancelAll()
            return r
        }
    }
}

/// 質問箱の動きを Terminal に出す(AFM の案が出ないときに、どこで止まったかを見るため。10/30)
/// 拾った語・入力欄・英語/日本語の案が混ざるので、app モードでは何も出さない(診断は AppLog に文字なしで書く)
enum QLog {
    private static let t0 = ProcessInfo.processInfo.systemUptime
    static func p(_ s: String) {
        guard JetPaths.mode == .dev else { return }
        print(String(format: "質問箱 %8.2fs  ", ProcessInfo.processInfo.systemUptime - t0) + s)
        fflush(stdout)
    }
}

struct QResultText: Sendable {
    var en: String
    var ja: String
    var kana: String
}

/// AFM の結果の受け箱(メインの外 → パネルの 30ms tick)。@MainActor の Task は使わない(DESIGN-ui.md「実装上の注意」)
final class QReplyBox: @unchecked Sendable {
    enum Reply {
        case ok(QResultText)
        case failed(String)
    }
    private let lock = NSLock()
    private var items: [(token: Int, reply: Reply)] = []

    func put(_ token: Int, _ r: Reply) {
        lock.lock(); items.append((token, r)); lock.unlock()
    }

    /// たまった結果を全部取り出す(古い依頼の結果は呼び出し側で捨てる)
    func take() -> [(token: Int, reply: Reply)] {
        lock.lock(); defer { lock.unlock() }
        let x = items
        items = []
        return x
    }
}
