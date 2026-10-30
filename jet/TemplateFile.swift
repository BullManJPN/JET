import AppKit

// U5b: 質問箱の型ファイル(prompts/qbox_templates.tsv)の置き場所。
//   読む  … ユーザーの編集版(support の prompts/)があればそれ、なければ同梱の型。jet.json の ui.qbox_templates で別の場所を指していればそれ
//   編集  … 設定パネルの「ファイルを開く」。初回は同梱の型を support にコピーしてから TextEdit で開く(同梱は書き換えない)
//   Terminal 運用は support = リポジトリのルート なので、同じファイルを直接開く(git の管理下。直した型は差分に出る)
// 同梱の型に戻したいときは、support の prompts/qbox_templates.tsv を消す。

enum TemplateFile {
    static let rel = "prompts/qbox_templates.tsv"
    static var userPath: String { JetPaths.support + "/" + rel }
    static var bundledPath: String { JetPaths.resources + "/" + rel }

    /// 型を読むファイル。configured = 設定(jet.json の ui.qbox_templates。解決済み)
    static func activePath(configured: String) -> String {
        guard configured == userPath || configured == bundledPath else { return configured }   // 別の場所を指定している
        return FileManager.default.fileExists(atPath: userPath) ? userPath : bundledPath
    }

    /// 編集用のファイル。無ければ同梱の型をコピーして作る
    static func ensureUserFile() throws -> String {
        let fm = FileManager.default
        if fm.fileExists(atPath: userPath) { return userPath }
        try fm.createDirectory(atPath: (userPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try fm.copyItem(atPath: bundledPath, toPath: userPath)
        AppLog.note("質問箱の型を support にコピーした")
        return userPath
    }

    static func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// TSV はふつう表計算に関連付けられているので、TextEdit で開く(無ければ既定のアプリ)
    static func openInEditor(_ path: String) {
        let url = URL(fileURLWithPath: path)
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}
