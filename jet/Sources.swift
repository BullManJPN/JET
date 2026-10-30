import Foundation

/// replay 用の時計。speed > 0 なら実時間 × speed(ログ上の時刻)、speed == 0 ならログの時刻をそのまま使う
final class VClock: @unchecked Sendable {
    private let lock = NSLock()
    private var virtual = 0.0
    private var origin: Double? = nil
    let speed: Double

    init(speed: Double) { self.speed = speed }

    func start(at firstWall: Double) {
        lock.lock(); defer { lock.unlock() }
        origin = ProcessInfo.processInfo.systemUptime - firstWall / speed
    }

    func set(_ v: Double) {
        lock.lock(); defer { lock.unlock() }
        virtual = v
    }

    func now() -> Double {
        lock.lock(); defer { lock.unlock() }
        if speed > 0, let o = origin { return (ProcessInfo.processInfo.systemUptime - o) * speed }
        return virtual
    }
}

enum Replay {
    static func sleepUntil(_ vc: VClock, _ logTime: Double) async {
        let d = (logTime - vc.now()) / vc.speed
        if d > 0 { try? await Task.sleep(nanoseconds: UInt64(d * 1e9)) }
    }

    /// 保存済みの認識ログ(asr-*.jsonl)を流す。ファイルごとに Pipeline を作り直す
    static func run(paths: [String], speed: Double, conf: JetConfig, cor: Corrector, sink: EventSink,
                    makeDraft: () throws -> DraftTranslator) async throws {
        for path in paths {
            let name = URL(fileURLWithPath: path).lastPathComponent
                .replacingOccurrences(of: "asr-", with: "")
                .replacingOccurrences(of: ".jsonl", with: "")
            let text = try String(contentsOfFile: path, encoding: .utf8)
            var items: [(kind: String, text: String, wall: Double)] = []
            for line in text.split(separator: "\n") {
                guard let d = line.data(using: .utf8),
                      let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                      let kind = o["kind"] as? String, kind == "volatile" || kind == "final" else { continue }
                items.append((kind: kind, text: o["text"] as? String ?? "", wall: (o["wall"] as? NSNumber)?.doubleValue ?? 0))
            }
            let engine = Engine(cfg: conf.cfg, cor: cor, file: name)
            let vc = VClock(speed: speed)
            let nowF: @Sendable () -> Double = { vc.now() }
            let pipe = Pipeline(conf: conf, sink: sink, file: name, now: nowF,
                                draft: try makeDraft())
            if speed > 0, let f = items.first { vc.start(at: f.wall) }
            for it in items {
                if speed > 0 {
                    if let pw = engine.pendingWall, it.wall - pw >= conf.cfg.coalesce {
                        await sleepUntil(vc, pw + conf.cfg.coalesce)
                        pipe.handle(engine.tick(pw + conf.cfg.coalesce))
                    }
                    await sleepUntil(vc, it.wall)
                }
                vc.set(it.wall)
                if it.kind == "volatile" {
                    pipe.handle(engine.volatile(it.text, wall: it.wall))
                } else {
                    pipe.handle(engine.finalize(it.text, wall: it.wall))
                }
            }
            await pipe.drain()
            if engine.unstableCount > 0 { print("[注意] \(name): 用語補正で確定済みの語が変わった回数 \(engine.unstableCount)") }
        }
    }
}
