import Foundation

/// 要求を1つずつ順に処理するワーカー(FIFO・直列)
final class Worker<Req: Sendable>: @unchecked Sendable {
    private let cont: AsyncStream<Req>.Continuation
    private var task: Task<Void, Never>!

    init(_ handler: @escaping @Sendable (Req) async -> Void) {
        let (stream, c) = AsyncStream.makeStream(of: Req.self)
        self.cont = c
        self.task = Task {
            for await r in stream { await handler(r) }
        }
    }

    func submit(_ r: Req) { cont.yield(r) }

    func finish() async {
        cont.finish()
        await task.value
    }
}

struct DraftReq: Sendable {
    let seg: Int
    let idx: Int
    let text: String
    let tSubmit: Double
}

/// Engine のイベントを受けて、clause → 下書き のワーカーに渡す。1ファイル(1セッション)に1つ
final class Pipeline: @unchecked Sendable {
    private let conf: JetConfig
    private let sink: EventSink
    private let file: String
    private let now: @Sendable () -> Double
    private let draftT: DraftTranslator
    private var draftW: Worker<DraftReq>!

    init(conf: JetConfig, sink: EventSink, file: String, now: @escaping @Sendable () -> Double,
         draft: DraftTranslator) {
        self.conf = conf
        self.sink = sink
        self.file = file
        self.now = now
        self.draftT = draft
        self.draftW = Worker<DraftReq> { [self] r in await self.runDraft(r) }
    }

    func handle(_ events: [Ev]) {
        for e in events {
            sink.emit(e)
            guard let kind = e["kind"] as? String, let seg = e["seg"] as? Int else { continue }
            if kind == "clause", conf.draftEnabled, let idx = e["idx"] as? Int, let text = e["text"] as? String {
                draftW.submit(DraftReq(seg: seg, idx: idx, text: text, tSubmit: ProcessInfo.processInfo.systemUptime))
            }
        }
    }

    func drain() async {
        await draftW.finish()
    }

    private func runDraft(_ r: DraftReq) async {
        let t0 = ProcessInfo.processInfo.systemUptime
        var ja = ""
        var guarded = false
        var echo = false
        var err = ""
        do {
            let res = try await draftT.translate(r.text)
            ja = res.ja
            guarded = res.guarded
            echo = res.echo
        } catch {
            guarded = true
            err = "\(error)"
        }
        let t1 = ProcessInfo.processInfo.systemUptime
        var e: Ev = ["kind": "draft", "t": r3(now()), "file": file, "seg": r.seg, "idx": r.idx,
                     "wait": r3(t0 - r.tSubmit), "lat": r3(t1 - t0), "guard": guarded]
        if !guarded { e["ja"] = ja }
        if !err.isEmpty { e["error"] = err }
        if echo { e["echo"] = true }   // 例文の混入を取り除いた(件数を数えられるように)
        sink.emit(e)
    }
}
