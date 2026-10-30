import Foundation

// ファイルの置き場所を決める唯一の場所。
//
//   resources … 同梱の読み取り専用ファイル(prompts/ asr/ と既定の jet.json)
//   support   … ユーザーが変えるもの(jet.json の上書き・編集した型や用語)と、書き出すもの(logs/ samples/)
//
//   Terminal 運用(dev) … 2つとも jetcli の置いてあるディレクトリ(リポジトリのルート)。いままでと同じ配置で、cwd には依存しない
//   .app(app)         … resources = Contents/Resources、support = ~/Library/Application Support/JET
//   JET_MODE=app       … Terminal から app モードを試す(resources は jetcli のディレクトリのまま、support だけ Application Support)
//
// app モードはイベント・認識ログをファイルに書かない(メモリだけ。閉じると消える)。録音の保存機能も持たない。

enum JetMode { case dev, app }

enum JetPaths {
    static let mode: JetMode = {
        if ProcessInfo.processInfo.environment["JET_MODE"] == "app" { return .app }
        if Bundle.main.bundleURL.pathExtension == "app" { return .app }
        return .dev
    }()

    /// ログ(イベント・認識ログ)をファイルに残すか。dev だけ残す
    static var keepsLogs: Bool { mode == .dev }

    static let resources: String = {
        if Bundle.main.bundleURL.pathExtension == "app" {
            return Bundle.main.resourcePath ?? (Bundle.main.bundlePath + "/Contents/Resources")
        }
        let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return exe.resolvingSymlinksInPath().deletingLastPathComponent().path
    }()

    static let support: String = {
        if mode == .dev { return resources }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path
            ?? (NSHomeDirectory() + "/Library/Application Support")
        return base + "/JET"
    }()

    /// ユーザーが変えた設定(差分)を置くファイル。同梱の jet.json に重ねて読む(JetConfig.load)。
    /// .app は support の jet.json、Terminal 運用は <リポジトリのルート>/jet.user.json(git の管理外。手で整えた jet.json を書き直さないため)
    static var userConfig: String { mode == .dev ? resources + "/jet.user.json" : support + "/jet.json" }

    /// 設定ファイルの相対パス(jet.json の中身・既定値)を実ファイルにする。
    /// 絶対パスと ~ はそのまま。相対は support → resources の順に探し、どちらにも無ければ resources 側(エラー文言に出る)
    static func resolve(_ p: String) -> String {
        if p.isEmpty || p.hasPrefix("/") { return p }
        if p.hasPrefix("~") { return (p as NSString).expandingTildeInPath }
        let u = support + "/" + p
        if FileManager.default.fileExists(atPath: u) { return u }
        return resources + "/" + p
    }

    /// 書き出す先(logs/ samples/)。相対は support の下
    static func writable(_ p: String) -> String {
        if p.hasPrefix("/") { return p }
        if p.hasPrefix("~") { return (p as NSString).expandingTildeInPath }
        return support + "/" + p
    }

    /// 一覧の性質のファイル(用語・別名表)を、support(ユーザー)→ resources(同梱)の順につなげて読む。
    /// ユーザーの行が先に来る(別名表は先に当たった行が効くので、ユーザーの直しが優先)
    static func readLayered(_ p: String) throws -> String {
        if p.hasPrefix("/") || p.hasPrefix("~") {
            return try String(contentsOfFile: (p as NSString).expandingTildeInPath, encoding: .utf8)
        }
        var parts: [String] = []
        var seen = Set<String>()
        for root in [support, resources] {
            let f = root + "/" + p
            guard seen.insert(f).inserted, FileManager.default.fileExists(atPath: f) else { continue }
            parts.append(try String(contentsOfFile: f, encoding: .utf8))
        }
        if parts.isEmpty { throw AppError("ファイルが見つかりません: \(p)(探した場所: \(support) と \(resources))") }
        return parts.joined(separator: "\n")
    }

    /// 「設定ファイルを開く」で開くファイル。--config があればそれ。なければ support の jet.json(無ければ空の {} で作る)
    static func settingsFile(explicit: String?) -> String {
        if let e = explicit { return e.hasPrefix("/") ? e : FileManager.default.currentDirectoryPath + "/" + e }
        let p = support + "/jet.json"
        if !FileManager.default.fileExists(atPath: p) {
            try? FileManager.default.createDirectory(atPath: support, withIntermediateDirectories: true)
            try? "{\n}\n".write(toFile: p, atomically: true, encoding: .utf8)
        }
        return p
    }
}
