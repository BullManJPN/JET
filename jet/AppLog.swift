import Foundation

// 診断ログ(app モードだけ)。~/Library/Application Support/JET/logs/app.log に追記する。
// 書くのは「何が起きたか」だけ: 開始・停止、入力の種類、エラーの種類。
// 書き起こし・訳・拾った語・入力欄の文字・エラーの本文は**書かない**(閉じたら何も残らない、という方針)。
// Terminal 運用(dev)では書かない(Terminal に出る)。

enum AppLog {
    private static let lock = NSLock()
    private static let maxBytes = 256 * 1024

    static var path: String { JetPaths.support + "/logs/app.log" }

    static func note(_ s: String) {
        guard JetPaths.mode == .app else { return }
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int, size > maxBytes {
            try? fm.removeItem(atPath: path + ".1")
            try? fm.moveItem(atPath: path, toPath: path + ".1")
        }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = f.string(from: Date()) + "  " + s + "\n"
        if !fm.fileExists(atPath: path) { fm.createFile(atPath: path, contents: nil) }
        guard let h = FileHandle(forWritingAtPath: path), let d = line.data(using: .utf8) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        h.write(d)
    }

    /// エラーを「種類」だけにする。AppError は自分で書いた文面(パスや状態。書き起こしは入らない)、それ以外は型の名前だけ
    static func kind(_ e: Error) -> String {
        if e is AppError { return "\(e)" }
        return String(describing: type(of: e))
    }

    /// ファイルを開く用(無ければ空で作る)
    static func ensureFile() -> String {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: path) { fm.createFile(atPath: path, contents: nil) }
        return path
    }
}
