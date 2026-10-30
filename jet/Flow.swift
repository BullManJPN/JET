import Foundation

// 流れ型の純ロジック。確定訳(最終訳)は使わず、節ごとの下書き(AFM)だけを積み上げる。
// 新しいものが下、古いものは上へ流れて薄くなる。差し替えも消去もしない(読んでいる行が動かないのが狙い)。
//   ねらい: 最終訳は区間が閉じるのを待つので中央値3.8秒・p90 9.6秒かかる(10/29 実測)。
//           下書きは節が閉じた 0.32秒後に出るので、話してから約1.6秒で読める。

struct FlowLine: Equatable {
    var id: Int
    var seg: Int
    var text: String
    var en = ""         // その日本語のもとになった英語(節の英語 / かたまりの英語)。日本語の下に小さく出す
    var stale = false   // clause_stale: もとの英語が最終結果と食い違った(訳が当てにならない)
    var sep = false     // 区切りの行(聞き取りの開始。例「― 17:20 開始(マイク)―」)。text に見出しが入る
}

struct FlowSnapshot: Equatable {
    var lines: [FlowLine] = []   // 古い順。最後がいちばん新しい(画面のいちばん下)
}

struct FlowViewModel {
    let cfg: UIConfig
    private var lines: [FlowLine] = []
    private var id = 0
    private var clauseEn: [String: String] = [:]   // seg#idx → 節の英語(ガードレールで止まったとき用)
    private var staleKeys: Set<String> = []        // 下書きが来る前に古いと分かった節
    private var shownKey: [String: Int] = [:]      // seg#idx → 出した行の id
    private var fileName: String? = nil

    init(_ cfg: UIConfig = UIConfig()) {
        self.cfg = cfg
    }

    mutating func advance(to now: Double) {}   // 時間で変わるものは無い(積み上げるだけ)

    mutating func apply(_ e: Ev, now: Double? = nil) {
        guard let kind = e["kind"] as? String else { return }
        // 聞き取りの開始(session): 前の回の行は残し、区切りの行を足す。節の対応表だけ新しくする
        if kind == "session" {
            clauseEn = [:]
            staleKeys = []
            shownKey = [:]
            fileName = e["file"] as? String
            let label = e["label"] as? String ?? "―"
            id += 1
            lines.append(FlowLine(id: id, seg: -1, text: label, sep: true))
            trim()
            return
        }
        if let f = e["file"] as? String {
            if let c = fileName, c != f {
                lines = []
                clauseEn = [:]
                staleKeys = []
                shownKey = [:]
            }
            fileName = f
        }
        guard let seg = uiInt(e["seg"]), seg >= 0 else { return }

        switch kind {
        case "clause":
            guard let idx = uiInt(e["idx"]) else { break }
            clauseEn["\(seg)#\(idx)"] = e["text"] as? String ?? ""
            if clauseEn.count > 400 { clauseEn = [:] }

        case "clause_stale":
            guard let idx = uiInt(e["idx"]) else { break }
            let key = "\(seg)#\(idx)"
            if let lid = shownKey[key] {
                // すでに出した行 → 消さずに印をつける(読んでいる行が消えないように)
                if let i = lines.firstIndex(where: { $0.id == lid }) { lines[i].stale = true }
            } else {
                staleKeys.insert(key)
            }

        case "draft":
            guard let idx = uiInt(e["idx"]) else { break }
            let key = "\(seg)#\(idx)"
            if shownKey[key] != nil { break }
            // ガードレールで止まった / 中国語や英語が混ざった → 日本語の代わりに英語の節を出す(自前の安全策)
            let en = clauseEn[key] ?? ""
            let guarded = (e["guard"] as? Bool) == true
            let text = guarded ? en : uiStripPeriod(e["ja"] as? String ?? "")
            if text.isEmpty { break }
            // ガードレールのときは英語そのものを日本語の欄に出しているので、下に同じ英語は重ねない
            append(seg: seg, text: text, en: guarded ? "" : en, stale: staleKeys.contains(key), key: key)

        default:
            break
        }
    }

    private mutating func append(seg: Int, text: String, en: String, stale: Bool, key: String?) {
        id += 1
        lines.append(FlowLine(id: id, seg: seg, text: text, en: en, stale: stale))
        if let k = key { shownKey[k] = id }
        trim()
    }

    private mutating func trim() {
        let keep = max(2, cfg.flowKeep)
        if lines.count > keep {
            let drop = lines.count - keep
            let gone = Set(lines.prefix(drop).map { $0.id })
            lines.removeFirst(drop)
            shownKey = shownKey.filter { !gone.contains($0.value) }
        }
    }

    func snapshot() -> FlowSnapshot { FlowSnapshot(lines: lines) }
}

// MARK: - 読み返し(純ロジック)
// 上へスクロールしたら流れを止める(新しい行が来ても最新へ飛ばない)。「最新へ」を押すか、
// スクロールをやめて flow_idle_s 秒たったら最新へ戻る。時計は引数(Selftest で試せる)

struct FlowBrowse {
    static let threshold = 24.0   // いちばん下からこれ以上離れたら読み返し中(pt)
    private(set) var active = false
    private(set) var startId = 0  // 読み返しを始めた時点のいちばん新しい行。これより新しい行 = まだ見ていない
    private var lastUser = 0.0

    /// ユーザーがスクロールしている(指で動かしている / 慣性で流れている)ときに呼ぶ
    mutating func userScroll(distFromBottom d: Double, now: Double, lastId: Int) {
        lastUser = now
        if d > FlowBrowse.threshold {
            if !active { active = true; startId = lastId }
        } else {
            active = false
        }
    }

    /// true = 最新へ戻す
    mutating func tick(now: Double, idle: Double) -> Bool {
        guard active, idle > 0, now - lastUser >= idle else { return false }
        active = false
        return true
    }

    mutating func jump() { active = false }

    /// 語をクリックしたとき: 読んでいる行が動かないよう流れを止める(触らず idle 秒で戻る)
    mutating func hold(now: Double, lastId: Int) {
        lastUser = now
        if !active { active = true; startId = lastId }
    }

    /// 読み返し中に増えた行の数(区切りの行は数えない)
    func unseen(_ lines: [FlowLine]) -> Int {
        active ? lines.filter { $0.id > startId && !$0.sep }.count : 0
    }
}

// MARK: - 単体テスト(./jetcli --selftest)

enum FlowSelftest {
    private static func E(_ kind: String, _ seg: Int, _ extra: [String: Any] = [:]) -> Ev {
        var d: Ev = ["kind": kind, "seg": seg, "t": 0.0, "file": "t"]
        for (k, v) in extra { d[k] = v }
        return d
    }

    static func run() -> Bool {
        var fails = 0, total = 0
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            total += 1
            if !ok { fails += 1; print("NG  flow: \(name)  \(detail())") }
        }
        func texts(_ vm: FlowViewModel) -> [String] { vm.snapshot().lines.map { $0.text } }
        func ens(_ vm: FlowViewModel) -> [String] { vm.snapshot().lines.map { $0.en } }

        // 1. 下書きを古い順に積む。最終訳が来ても何も変えない
        do {
            var vm = FlowViewModel()
            vm.apply(E("clause", 0, ["idx": 0, "text": "Hey, I'm Alex."]))
            vm.apply(E("draft", 0, ["idx": 0, "ja": "こんにちは、私はAlexです。"]))
            vm.apply(E("clause", 0, ["idx": 1, "text": "I like Claude relations"]))
            vm.apply(E("draft", 0, ["idx": 1, "ja": "Claudeの関係が好きです。"]))
            check("積む: 古い順・末尾の。を除く", texts(vm) == ["こんにちは、私はAlexです", "Claudeの関係が好きです"], "\(texts(vm))")
            check("英語: もとの節の英語が対応する", ens(vm) == ["Hey, I'm Alex.", "I like Claude relations"], "\(ens(vm))")
            vm.apply(E("final", 0, ["unit": 0, "ja": "こんにちは、アレックスです。Claudeとの関係が好きです。"]))
            check("最終訳では差し替えない", texts(vm).count == 2, "\(texts(vm))")
        }

        // 2. 同じ節の下書きは1回だけ / dropped は出さない / 空は出さない
        do {
            var vm = FlowViewModel()
            vm.apply(E("draft", 1, ["idx": 0, "ja": "一度だけ。"]))
            vm.apply(E("draft", 1, ["idx": 0, "ja": "二度目は無視。"]))
            vm.apply(E("draft", 1, ["idx": 1, "dropped": true]))
            vm.apply(E("draft", 1, ["idx": 2, "ja": ""]))
            check("同じ節は1回 / dropped と空は出さない", texts(vm) == ["一度だけ"], "\(texts(vm))")
        }

        // 3. ガードレール → 英語の節を出す。節の英語が無ければ出さない
        do {
            var vm = FlowViewModel()
            vm.apply(E("clause", 2, ["idx": 0, "text": "some tricky sentence"]))
            vm.apply(E("draft", 2, ["idx": 0, "guard": true, "error": "unsafe"]))
            vm.apply(E("draft", 2, ["idx": 1, "guard": true]))
            check("ガードレール → 英語", texts(vm) == ["some tricky sentence"], "\(texts(vm))")
            check("ガードレール: 下に同じ英語を重ねない", ens(vm) == [""], "\(ens(vm))")
        }

        // 4. clause_stale: 出す前なら出さない / 出した後なら印だけ(消さない)
        do {
            var vm = FlowViewModel()
            vm.apply(E("clause_stale", 3, ["idx": 0]))
            vm.apply(E("draft", 3, ["idx": 0, "ja": "食い違った節。"]))
            check("stale: 先に来たら出す(印つき)", vm.snapshot().lines.count == 1 && vm.snapshot().lines[0].stale, "\(vm.snapshot().lines)")
            vm.apply(E("draft", 3, ["idx": 1, "ja": "あとで古いと分かる節。"]))
            vm.apply(E("clause_stale", 3, ["idx": 1]))
            let ls = vm.snapshot().lines
            check("stale: あとから来たら消さずに印", ls.count == 2 && ls[1].stale, "\(ls)")
        }

        // 5. 上限 flow_keep を超えたら古いものから捨てる
        do {
            var c = UIConfig()
            c.flowKeep = 3
            var vm = FlowViewModel(c)
            for i in 0..<5 { vm.apply(E("draft", 4, ["idx": i, "ja": "文\(i)。"])) }
            check("上限で古いものを捨てる", texts(vm) == ["文2", "文3", "文4"], "\(texts(vm))")
        }

        // 6. file が変わったら作り直す
        do {
            var vm = FlowViewModel()
            vm.apply(E("draft", 0, ["idx": 0, "ja": "前のファイル。"]))
            var e = E("draft", 0, ["idx": 0, "ja": "次のファイル。"])
            e["file"] = "u"
            vm.apply(e)
            check("file が変わったら作り直す", texts(vm) == ["次のファイル"], "\(texts(vm))")
        }

        // 8. session: 前の回の行を残して区切りを足す。同じ seg#idx でも新しい回なら出す
        do {
            var vm = FlowViewModel()
            vm.apply(["kind": "session", "t": 0.0, "file": "a", "label": "― 1回目 ―"])
            vm.apply(["kind": "draft", "seg": 0, "idx": 0, "t": 0.0, "file": "a", "ja": "前の回。"])
            vm.apply(["kind": "session", "t": 0.0, "file": "b", "label": "― 2回目 ―"])
            vm.apply(["kind": "draft", "seg": 0, "idx": 0, "t": 0.0, "file": "b", "ja": "次の回。"])
            check("session: 行を残して区切り", texts(vm) == ["― 1回目 ―", "前の回", "― 2回目 ―", "次の回"], "\(texts(vm))")
            check("session: 区切りの印", vm.snapshot().lines.map { $0.sep } == [true, false, true, false], "\(vm.snapshot().lines)")
        }

        // 9. 読み返し: 上へ離れたら止める / 新しい行を数える / 下へ戻れば解除 / 触らず idle 秒で戻る
        do {
            var b = FlowBrowse()
            b.userScroll(distFromBottom: 5, now: 0, lastId: 3)
            check("browse: 下にいるうちは読み返しでない", !b.active)
            b.userScroll(distFromBottom: 200, now: 1, lastId: 3)
            check("browse: 上へ離れたら読み返し", b.active && b.startId == 3)
            let ls = [FlowLine(id: 3, seg: 0, text: "a"), FlowLine(id: 4, seg: 0, text: "b"),
                      FlowLine(id: 5, seg: -1, text: "―", sep: true), FlowLine(id: 6, seg: 0, text: "c")]
            check("browse: 増えた行を数える(区切りは除く)", b.unseen(ls) == 2, "\(b.unseen(ls))")
            check("browse: idle 前は戻らない", !b.tick(now: 5, idle: 10) && b.active)
            check("browse: idle 秒で戻る", b.tick(now: 11, idle: 10) && !b.active)
            b.userScroll(distFromBottom: 200, now: 20, lastId: 6)
            check("browse: idle 0 なら自動では戻らない", !b.tick(now: 999, idle: 0) && b.active)
            b.userScroll(distFromBottom: 0, now: 21, lastId: 6)
            check("browse: 下まで戻したら解除", !b.active)
            b.userScroll(distFromBottom: 200, now: 22, lastId: 6)
            b.jump()
            check("browse: 最新へ で解除", !b.active && b.unseen(ls) == 0)
            b.hold(now: 30, lastId: 6)
            check("browse: 語のクリックで止める", b.active && b.startId == 6 && !b.tick(now: 35, idle: 10) && b.tick(now: 41, idle: 10))
        }

        print("flow: \(total - fails) / \(total) 件OK")
        return fails == 0
    }
}
