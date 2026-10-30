import Foundation

/// イベントの受け箱(U2: Live の各タスク → パネルの 30ms tick)。EventSink が emit のたびに入れる
final class EventInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Ev] = []

    func push(_ e: Ev) {
        lock.lock()
        items.append(e)
        lock.unlock()
    }

    func take() -> [Ev] {
        lock.lock()
        let out = items
        items = []
        lock.unlock()
        return out
    }
}

/// イベントを JSONL に書き、画面(Terminal)にも1行で出す。複数のタスクから呼ばれるので排他する。
/// path が nil ならファイルには書かない(app モード。受け箱 tee へ渡すだけで、閉じると消える)
final class EventSink: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle?
    private var tee: EventInbox? = nil
    let quiet: Bool

    /// パネルに渡す受け箱をつなぐ(U2)
    func setTee(_ box: EventInbox?) {
        lock.lock()
        tee = box
        lock.unlock()
    }

    init(path: String?, quiet: Bool) throws {
        if let path = path {
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: path, contents: nil)
            self.handle = try FileHandle(forWritingTo: url)
        } else {
            self.handle = nil
        }
        self.quiet = quiet
    }

    func emit(_ e: Ev) {
        guard let d = try? JSONSerialization.data(withJSONObject: e, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        lock.lock()
        defer { lock.unlock() }
        if let h = handle {
            h.write(d)
            h.write(Data("\n".utf8))
        }
        tee?.push(e)
        if !quiet, let line = renderEvent(e) { print(line) }
    }
}

func renderEvent(_ e: Ev) -> String? {
    let kind = e["kind"] as? String ?? ""
    let t = e["t"] as? Double ?? 0
    let head = String(format: "%7.2f  ", t)
    let idx = e["idx"] as? Int ?? -1
    switch kind {
    case "seg":
        return "\n" + head + "---- seg \(e["seg"] as? Int ?? -1)  \(e["text"] as? String ?? "")"
    case "commit":
        let w = (e["words"] as? [String] ?? []).joined(separator: " ")
        return head + "EN     +" + w + ((e["flush"] as? Bool ?? false) ? "   (ASR確定で残りを確定)" : "")
    case "clause":
        return head + "CLAUSE #\(idx) \"\(e["text"] as? String ?? "")\""
    case "clause_stale":
        return head + "STALE  #\(idx) (最終結果と食い違い)"
    case "final_req":
        return head + "FINAL? 送信\((e["early"] as? Bool ?? false) ? "(先出し)" : "") 語\(e["n_words"] as? Int ?? 0): \(e["en"] as? String ?? "")"
    case "draft":
        let lat = e["lat"] as? Double ?? 0
        let body = (e["guard"] as? Bool ?? false) ? "ガードレール→英語表示" : (e["ja"] as? String ?? "")
        return head + String(format: "DRAFT  #%d %.2fs  ", idx, lat) + body
    default:
        return nil
    }
}
