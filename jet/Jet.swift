import Foundation

struct Opts {
    var config: String? = nil   // nil = 同梱の jet.json に support の jet.json を重ねる(JetConfig.load)
    var replay: [String] = []
    var replayEvents: String? = nil
    var mic = false
    var system = false
    var excludeSelf = false
    var panel = false
    var menubar = false
    var play: String? = nil
    var file: String? = nil
    var seconds = 60.0
    var saveAudio = false
    var speed = 0.0
    var events: String? = nil
    var mock = false
    var mockDelay = 0.0
    var quiet = false
    var selftest = false
    var noDraft = false
    var K: Int? = nil
    var holdLast: Int? = nil
    var minClause: Int? = nil
    var maxClause: Int? = nil
    var earlyAfter: Double? = nil
    var coalesceMs: Double? = nil
    var holdUnknown: Double? = nil
    var noCorrect = false
    // 下書きのベンチ(--draft-bench <テストセット.jsonl>)
    var draftBench: String? = nil
    var out: String? = nil
    var name = "base"
    var draftSystem: String? = nil
    var draftFewshot: String? = nil
    var draftUser: String? = nil
    var greedy = false
    var draftMaxTokens: Int? = nil
}

func parseArgs() throws -> Opts {
    let args = Array(CommandLine.arguments.dropFirst())
    var o = Opts()
    var i = 0
    func next() -> String? {
        i += 1
        return i < args.count ? args[i] : nil
    }
    while i < args.count {
        let a = args[i]
        switch a {
        case "--config": if let v = next() { o.config = v }
        case "--replay":
            while i + 1 < args.count, !args[i + 1].hasPrefix("--") {
                i += 1
                o.replay.append(args[i])
            }
        case "--replay-events": o.replayEvents = next()
        case "--mic": o.mic = true
        case "--system": o.system = true
        case "--exclude-self": o.excludeSelf = true
        case "--panel": o.panel = true
        case "--menubar": o.menubar = true
        case _ where a.hasPrefix("-psn_"): break   // Finder から起動したときの印(無視)
        case "--play": o.play = next()
        case "--file": o.file = next()
        case "--seconds": if let v = next(), let d = Double(v) { o.seconds = d }
        case "--save-audio": o.saveAudio = true
        case "--speed": if let v = next(), let d = Double(v) { o.speed = d }
        case "--events": o.events = next()
        case "--mock-translate": o.mock = true
        case "--mock-delay":
            if let v = next() {
                let p = v.split(separator: ",").compactMap { Double($0) }
                if let d = p.first { o.mockDelay = d }
            }
        case "--quiet", "-q": o.quiet = true
        case "--selftest": o.selftest = true
        case "--no-draft": o.noDraft = true
        case "--K": if let v = next(), let n = Int(v) { o.K = n }
        case "--hold-last": if let v = next(), let n = Int(v) { o.holdLast = n }
        case "--min-clause": if let v = next(), let n = Int(v) { o.minClause = n }
        case "--max-clause": if let v = next(), let n = Int(v) { o.maxClause = n }
        case "--early-after": if let v = next(), let d = Double(v) { o.earlyAfter = d }
        case "--coalesce-ms": if let v = next(), let d = Double(v) { o.coalesceMs = d }
        case "--hold-unknown": if let v = next(), let d = Double(v) { o.holdUnknown = d }
        case "--no-correct": o.noCorrect = true
        case "--draft-bench": o.draftBench = next()
        case "--out": o.out = next()
        case "--name": if let v = next() { o.name = v }
        case "--draft-system": o.draftSystem = next()
        case "--draft-fewshot": o.draftFewshot = next()
        case "--draft-user": o.draftUser = next()
        case "--greedy": o.greedy = true
        case "--draft-max-tokens": if let v = next(), let n = Int(v) { o.draftMaxTokens = n }
        default: throw AppError("不明な引数: \(a)")
        }
        i += 1
    }
    return o
}

func makeDraft(conf: JetConfig, o: Opts) throws -> DraftTranslator {
    var d: DraftTranslator = MockDraft(delay: o.mockDelay)
    if !o.mock {
        if conf.draftEnabled { d = try AFMDraft(conf: conf) }
    }
    return d
}

@main
struct Jet {
    static func main() async {
        do { try await run() } catch {
            fputs("エラー: \(error)\n", stderr)
            exit(1)
        }
    }

    static func run() async throws {
        var o = try parseArgs()
        if JetPaths.mode == .app {
            // .app(引数なしで起動)はメニューバー版。Terminal への出力は使わない
            o.quiet = true
            if o.replay.isEmpty && o.replayEvents == nil && !o.mic && !o.system && o.file == nil && !o.selftest && o.draftBench == nil {
                o.menubar = true
            }
        }
        if o.selftest {
            let okCore = Selftest.run()
            let okFlow = FlowSelftest.run()
            let okEcho = EchoSelftest.run()
            let okQBox = QBoxSelftest.run()
            let okKana = KanaSelftest.run()
            let okBar = BarSelftest.run()
            let okLook = LookSelftest.run()
            exit(okCore && okFlow && okEcho && okQBox && okKana && okBar && okLook ? 0 : 1)
        }

        if let set = o.draftBench {
            var c = try JetConfig.load(o.config)
            if let v = o.draftSystem { c.draftSystem = v }
            if let v = o.draftFewshot { c.draftFewshot = v }
            if let v = o.draftUser { c.draftUser = v }
            if o.greedy { c.draftGreedy = true }
            if let v = o.draftMaxTokens { c.draftMaxTokens = v }
            try await DraftBench.run(input: set, out: o.out, conf: c, name: o.name)
            return
        }

        if let path = o.replayEvents {
            var rconf = try JetConfig.load(o.config)
            try await PanelApp.runReplay(path: path, speed: o.speed > 0 ? o.speed : 1.0, conf: rconf)
            return
        }

        var conf = try JetConfig.load(o.config)
        if let v = o.K { conf.cfg.K = v }
        if let v = o.holdLast { conf.cfg.holdLast = v }
        if let v = o.minClause { conf.cfg.minClause = v }
        if let v = o.maxClause { conf.cfg.maxClause = v }
        if let v = o.earlyAfter { conf.cfg.earlyAfter = v }
        if let v = o.coalesceMs { conf.cfg.coalesce = v / 1000.0 }
        if let v = o.holdUnknown { conf.cfg.holdUnknown = v }
        if o.noCorrect { conf.cfg.correct = false }
        if o.noDraft { conf.draftEnabled = false }

        guard !o.replay.isEmpty || o.mic || o.system || o.file != nil || o.menubar else {
            throw AppError("--replay <認識ログ...> / --mic / --system / --file <音声> のどれかを指定してください")
        }
        if o.mic && o.system { throw AppError("--mic と --system は同時に指定できません") }

        let cor = try Corrector(termsPath: conf.terms, aliasesPath: conf.aliases, thr: conf.fuzzy,
                                vocabPath: conf.cfg.holdUnknown > 0 ? conf.vocab : nil)
        if conf.cfg.holdUnknown > 0 && !o.quiet {
            print("辞書にない語は最長 \(conf.cfg.holdUnknown) 秒待つ(辞書 \(cor.vocab.count) 語)")
        }
        if o.menubar {
            // U3: メニューバーから開始/停止・入力の切り替え(Menubar.swift)。イベントは聞き取り1回ごとに別ファイル
            if !o.replay.isEmpty || o.mic || o.system || o.file != nil {
                throw AppError("--menubar は --mic / --system / --file / --replay と一緒に使えません(入力はメニューで選びます)")
            }
            let d = try makeDraft(conf: conf, o: o)
            if !o.mock {
                if conf.draftEnabled { await d.warmup() }
            }
            try await PanelApp.runMenubar(o: o, conf: conf, cor: cor, draft: d)
            return
        }
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        let evPath: String? = o.events ?? (conf.keepLogs ? "\(conf.eventsDir)/jet-\(df.string(from: Date())).jsonl" : nil)
        let sink = try EventSink(path: evPath, quiet: o.quiet)
        let draftImpl = try makeDraft(conf: conf, o: o)
        if !o.mock {
            if conf.draftEnabled { await draftImpl.warmup() }
        }
        if o.panel && !o.replay.isEmpty { throw AppError("--panel は --mic / --system / --file と一緒に使います(保存したイベントは --replay-events)") }
        if !o.replay.isEmpty {
            try await Replay.run(paths: o.replay, speed: o.speed, conf: conf, cor: cor, sink: sink,
                                 makeDraft: { draftImpl })
        } else if o.panel {
            // パネルのループがメインスレッドを使い続けるので、Live.run はメインの外の Task で動かす(LivePanel.swift)
            try await PanelApp.runLive(o: o, conf: conf, cor: cor, sink: sink, draft: draftImpl, evPath: evPath)
            return
        } else {
            try await Live.run(file: o.file, mic: o.mic, system: o.system, excludeSelf: o.excludeSelf, play: o.play, seconds: o.seconds, saveAudio: o.saveAudio,
                               conf: conf, cor: cor, sink: sink, draft: draftImpl)
        }
        if let p = evPath {
            print("\nイベント: \(p)")
            print("照合: python3 sim/parity.py \(p)")
        }
    }
}
