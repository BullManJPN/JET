import AppKit
import Combine
import SwiftUI

// 流れ型パネル。節ごとの下書きだけを積み上げて上へ流す。Flow.swift の純ロジックを表示するだけ。
//   ./jetcli --system --panel
// 窓は上端の帯(PanelWindow.dragBar)か ⌘+ドラッグで動かす。それ以外のクリックは中身へ:
//   字幕の語をクリックで拾う(Shift+クリックでつなげる)→ 左の列の質問箱(QBoxPanel.swift)に入る

/// 1行ぶんの語(上の行 = 日本語、下の行 = もとの英語)
struct FlowTokens {
    var main: [QToken]
    var mainLang: QLang
    var en: [QToken]
}

@MainActor
final class FlowPanelModel: ObservableObject, EventDisplay {
    @Published var snap: FlowSnapshot
    @Published private(set) var browsing = false   // 読み返し中(流れを止めている)
    @Published private(set) var unseen = 0         // 読み返し中に増えた行
    @Published private(set) var jumpToken = 0      // 増えたら画面が最新へスクロールする
    @Published private(set) var box: QBox          // 質問箱
    @Published private(set) var presence = QBoxPresence()   // 質問箱の出し方(隠す / 重ねて表示 / 固定。U4)
    var boxMode: QBoxMode { presence.mode }
    var boxOpen: Bool { presence.mode == .pinned }    // 左の列として固定している(窓が左へ広がっている)
    var boxPeek: Bool { presence.mode == .peek }      // 字幕の上に重ねて表示している(窓の大きさは変えない)
    /// 帯のボタン(× / 開始・ポーズ / 質問箱)。開始・ポーズと終了の中身は経路(メニューバー / live / 再生)がつなぐ
    let controls = PanelControls()
    @Published private(set) var barHover = false               // 帯にマウスが乗っている(× と 開始・ポーズを出す)
    @Published private(set) var barSlot: BarLayout.Slot? = nil // マウスが乗っているボタン
    @Published private(set) var barDragHover = false           // マウスが帯の「窓を動かせる範囲」に乗っている(ボタンの上は含まない)
    private var pointerInside = false
    private var iconHover = false
    private var noteFocused = false
    private var windowKey = false
    /// 重ね表示を閉じない条件: 入力欄にカーソルがある(窓がキーのときだけ)/ AFM が生成中
    private var busy: Bool { (noteFocused && windowKey) || afmPending }
    private(set) var tokens: [Int: FlowTokens] = [:]   // 行 id → 語。snap を出す前に作る
    @Published private(set) var boxWidth = 250.0       // 列の幅。境目のドラッグで変わる(窓の幅は変えず、字幕の列が縮む)
    weak var scale: PanelScale?
    weak var window: PanelWindow?
    private var baseMinWidth = 320.0                   // 質問箱を閉じているときの窓の最小幅
    /// 質問箱を開く/閉じるときに窓の大きさを変える(bind で設定)
    var onBoxOpen: ((Bool) -> Void)?
    // 質問箱で作った発言
    @Published var note = ""                                 // 入力欄(言いたいこと)
    @Published private(set) var results: [QResult] = []
    @Published private(set) var afmPending = false            // AFM の案を作っている
    @Published private(set) var qError: String? = nil         // 失敗の文面(何が起きたか + 次にどうすればよいか)
    @Published private(set) var copiedId: Int? = nil          // 英語をコピーした発言(しばらく「コピーしました」)
    @Published private(set) var resultsToken = 0              // Q を押すたびに増える(列を先頭へスクロール)
    private var resultId = 0
    private var reqToken = 0
    private var composer: QComposer? = nil
    @Published private(set) var kanaHint: String? = nil       // 発音辞書が無いときの案内
    private let replyBox = QReplyBox()
    private var copiedAt = 0.0
    private var warmed = false
    private var vm: FlowViewModel
    private var br = FlowBrowse()
    private var lastDist = 0.0          // いちばん下からの距離(pt)
    private var userPhase = false       // ユーザーがスクロール中(指 / 慣性)。プログラムのスクロールでは false
    let cfg: UIConfig
    /// U5a 見た目(背景の濃さ・外観・フォント・文字サイズ)。変えたらすぐ反映し、0.5秒待って保存する(Appearance.swift)
    @Published var look: LookValues {
        didSet { if look != oldValue { lookChanged() } }
    }
    let lookBase: LookValues                                   // 「初期値に戻す」の値(同梱の jet.json)
    @Published private(set) var settingsOpen = false          // 表示の設定を開いている(帯の右端の歯車)
    private var lookSaveTimer: Timer?
    // U5b 質問箱の型。設定パネルから型ファイルを開いて直し、戻ったら(または「再読み込み」で)読み直す
    @Published private(set) var templateReport = QTemplate.Report()
    @Published private(set) var templateError: String? = nil
    private var templateStamp: Date? = nil

    private static let toneKey = "JETQBoxTone"
    private static let widthKey = "JETQBoxWidth"     // 列の幅(文字倍率 1 のときの値で記録)

    init(cfg: UIConfig) {
        self.cfg = cfg
        let v = FlowViewModel(cfg)
        self.vm = v
        self.snap = v.snapshot()
        self.look = LookValues(ui: cfg)
        self.lookBase = LookStore.base()
        let tone: QTone = UserDefaults.standard.string(forKey: FlowPanelModel.toneKey) == "casual" ? .casual : .business
        self.box = QBox(templates: [], tone: tone)
        reloadTemplates()
        controls.hasContent = { [weak self] in self?.hasContent ?? false }
    }

    // MARK: 表示の設定(U5a)

    func toggleSettings() {
        settingsOpen.toggle()
        if settingsOpen { refreshTemplatesIfChanged() }
    }

    // MARK: 質問箱の型(U5b)

    /// いま読んでいる型ファイル(ユーザーの編集版があればそれ)
    var templatePath: String { TemplateFile.activePath(configured: cfg.qboxTemplates) }

    /// 型ファイルを読み直す。読めない・1件も使えないときは、いまの型をそのまま使い続ける
    func reloadTemplates() {
        let path = templatePath
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            templateError = "型のファイルが読めません(\((path as NSString).abbreviatingWithTildeInPath))。いまの型をそのまま使います"
            return
        }
        templateStamp = TemplateFile.modified(path)
        let r = QTemplate.report(text)
        templateReport = r
        if r.templates.isEmpty {
            templateError = "使える型が1件もありません。いまの型をそのまま使います"
            return
        }
        templateError = nil
        var b = box
        b.replaceTemplates(r.templates)
        if b != box { box = b }
    }

    /// 直したあとにこのパネルへ戻ったとき、ファイルが変わっていれば読み直す
    func refreshTemplatesIfChanged() {
        if TemplateFile.modified(templatePath) != templateStamp { reloadTemplates() }
    }

    /// 型ファイルを TextEdit で開く(初回は同梱の型をコピーしてから)
    func openTemplateFile() {
        do {
            TemplateFile.openInEditor(try TemplateFile.ensureUserFile())
        } catch {
            templateError = "型のファイルを用意できませんでした(\(AppLog.kind(error)))"
        }
    }
    func closeSettings() { settingsOpen = false }
    func resetLook() { look = lookBase }

    /// 外観(明るい / 暗い)は窓ごと切り替える(すりガラス・文字色・ボタンの色がそろって変わる)
    func applyLook() {
        let a = look.mode.nsAppearance
        if window?.appearance != a { window?.appearance = a }
    }

    private func lookChanged() {
        applyLook()
        lookSaveTimer?.invalidate()
        lookSaveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveLook() }
        }
    }

    private func saveLook() {
        lookSaveTimer?.invalidate()
        lookSaveTimer = nil
        LookStore.save(look, base: lookBase)
    }

    /// 終了の前: 保存を待っている変更があれば書く
    func flushLook() {
        if lookSaveTimer != nil { saveLook() }
    }

    /// 閉じると消える内容があるか(終了時の警告用)
    var hasContent: Bool {
        !snap.lines.isEmpty
            || !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !box.picks.isEmpty || !results.isEmpty || afmPending
    }

    func apply(_ e: Ev) {
        vm.apply(e)
        let s = vm.snapshot()
        if s != snap {
            updateTokens(s)
            snap = s
        }
        sync()
    }

    /// 30ms ごと。読み返しの時計は実時間(聞き取りを止めていても、触らず flow_idle_s 秒で戻る)
    func advance(to t: Double) {
        if br.tick(now: now(), idle: cfg.flowIdleS) { jumpToken += 1 }
        sync()
        pollReply()
        if copiedId != nil && now() - copiedAt > 1.5 { copiedId = nil }
    }

    private func now() -> Double { ProcessInfo.processInfo.systemUptime }

    private func updateTokens(_ s: FlowSnapshot) {
        var alive = Set<Int>()
        for line in s.lines where !line.sep {
            alive.insert(line.id)
            if tokens[line.id] != nil { continue }
            let ja = QTokenizer.hasJapanese(line.text)
            tokens[line.id] = FlowTokens(main: ja ? QTokenizer.ja(line.text) : QTokenizer.en(line.text),
                                         mainLang: ja ? .ja : .en,
                                         en: QTokenizer.en(line.en))
        }
        if tokens.count > alive.count {
            tokens = tokens.filter { alive.contains($0.key) }
            var b = box
            b.forget(alive: alive)
            if b != box { box = b }
        }
    }

    // MARK: 読み返し(画面の ScrollView から呼ぶ)

    func scrollGeometry(distFromBottom d: Double) {
        lastDist = d
        if userPhase { userScrolled() }
    }

    func scrollPhase(user: Bool) {
        let wasUser = userPhase
        userPhase = user
        if user || wasUser { userScrolled() }   // 動かし始め・動かし終わりの位置でも判定する
    }

    func jumpToLatest() {
        br.jump()
        jumpToken += 1
        sync()
    }

    private func userScrolled() {
        br.userScroll(distFromBottom: lastDist, now: now(), lastId: snap.lines.last?.id ?? 0)
        sync()
    }

    private func sync() {
        if browsing != br.active { browsing = br.active }
        let u = br.unseen(snap.lines)
        if unseen != u { unseen = u }
    }

    // MARK: 質問箱

    /// 字幕の語をクリック。Shift を押していたら直前に拾った語からつなげる。読んでいる行が動かないよう流れを止める
    func click(line: FlowLine, row: Int, index: Int) {
        guard let t = tokens[line.id] else { return }
        let toks = row == 0 ? t.main : t.en
        let lang: QLang = row == 0 ? t.mainLang : .en
        let shift = NSEvent.modifierFlags.contains(.shift)
        let added = box.click(line: line.id, row: row, lang: lang, index: index, tokens: toks, shift: shift)
        br.hold(now: now(), lastId: snap.lines.last?.id ?? 0)
        sync()
        if added { setPresence { $0.picked() } }
    }

    func togglePick(_ id: Int) { box.togglePick(id) }
    func removePick(_ id: Int) { box.removePick(id) }
    func clearPicks() { box.clearPicks() }
    func toggleTemplate(_ id: String) { box.toggleTemplate(id) }

    func setTone(_ t: QTone) {
        box.tone = t
        UserDefaults.standard.set(t.rawValue, forKey: FlowPanelModel.toneKey)
    }

    /// 帯の質問箱のアイコンをクリック: 隠す・重ね表示 → 固定、固定 → 隠す
    func toggleBox() { setPresence { $0.iconClicked() } }

    func closeBox() { setPresence { $0.close() } }

    /// 窓の中のマウス(PanelWindow.onPointer)。帯に乗ったら × と 開始・ポーズを出す / アイコンに乗ったら重ねて表示 / 窓から出たら閉じる
    func pointer(inside: Bool, x: Double, fromTop: Double) {
        let inBar = inside && fromTop >= 0 && fromTop < PanelWindow.dragBar
        let fromRight = Double(window?.frame.width ?? 0) - x
        let slot: BarLayout.Slot? = !inBar ? nil
            : (BarLayout.hitGear(fromRight: fromRight) ? .gear : BarLayout.hit(x: x, canRun: controls.canRun, wide: controls.wide))
        if barHover != inBar {
            barHover = inBar
            if !inBar { controls.disarm() }   // 帯から離れたら「終了する?」は取り消す
        }
        if barSlot != slot { barSlot = slot }
        // 窓を動かせる範囲 = 帯のうち、左のボタンの並びと右端の歯車の間(PanelWindow.inDragBar と同じ)
        let drag = inBar && x > barLeftWidth && fromRight > BarLayout.rightWidth
        if barDragHover != drag { barDragHover = drag }
        let onIcon = slot == .box
        if onIcon && !iconHover { setPresence { $0.iconEntered() } }
        iconHover = onIcon
        if inside != pointerInside {
            pointerInside = inside
            let b = busy
            if inside {
                setPresence { $0.pointerEntered() }
            } else {
                setPresence { $0.pointerExited(busy: b) }
            }
        }
    }

    /// 入力欄のカーソル(QBoxView の FocusState)
    func setNoteFocused(_ f: Bool) {
        guard f != noteFocused else { return }
        noteFocused = f
        if !f { freed() }
    }

    private func setWindowKey(_ k: Bool) {
        guard k != windowKey else { return }
        windowKey = k
        if !k { freed() } else if settingsOpen { refreshTemplatesIfChanged() }
    }

    /// 閉じない条件が解けた: 窓の外で閉じるのを待っていたら閉じる
    private func freed() {
        let inside = pointerInside, b = busy
        setPresence { $0.freed(pointerInside: inside, busy: b) }
    }

    /// 帯の左のボタンの並びの幅(窓はこの幅を動かさない)
    var barLeftWidth: Double { BarLayout.width(canRun: controls.canRun, wide: controls.wide) }

    // MARK: 質問を作る(Q ボタン / 入力欄で Enter)

    /// 型への差し込みをすぐ出し、必要なら AFM の案を頼む(結果は受け箱 → advance で受け取る)。
    /// AFM の案 = 英語(AFM)→ 日本語(下書き訳と同じプロンプト)→ カナ(発音辞書 + 規則)
    func generate() {
        syncNoteFromField()
        let req = QRequest.make(box: box, note: note, context: contextLines())
        QLog.p("Q: 語 \(req.words) / 型 \(req.templates.count)(差し込み \(req.slotTemplates))/ 入力欄 \"\(req.note)\" / AFM \(req.wantsAFM ? "呼ぶ" : "呼ばない") / 生成中 \(afmPending)")
        resultsToken += 1
        if req.isEmpty {
            results = []
            afmPending = false
            qError = QCompose.emptyMessage
            return
        }
        let instant = QCompose.fill(box, startId: resultId, dict: KanaDict.shared.loaded())
        resultId += instant.count + 1
        results = instant
        QLog.p("型への差し込み \(instant.count) 件")
        qError = nil
        reqToken += 1          // 前の依頼の結果が遅れて来ても捨てる
        guard req.wantsAFM else {
            afmPending = false
            // 何も出ないまま終わらせない(語を差し込む型だけで、差し込む語が無いなど)
            if instant.isEmpty { qError = QCompose.slotOnlyMessage }
            return
        }
        if let e = ensureComposer() {
            QLog.p("AFM の準備に失敗: \(e)")
            AppLog.note("AFM の準備に失敗")
            qError = e
            afmPending = false
            return
        }
        guard let c = composer else { QLog.p("AFM の部品がありません(composer nil)"); return }
        let token = reqToken
        let inbox = replyBox
        let kanaPath = cfg.kanaDict
        afmPending = true
        QLog.p("AFM に依頼(番号 \(token))")
        Task.detached {
            QLog.p("AFM の処理を開始(番号 \(token))")
            do {
                var en = ""
                do {
                    en = try await QComposer.withTimeout(10) { try await c.english(req) }
                } catch let e where "\(e)".contains("timeout") {
                    // 時間切れは1回だけやり直す(AFM の読み込みと重なると遅いことがある)
                    QLog.p("英語: 時間切れ → やり直し")
                    en = try await QComposer.withTimeout(10) { try await c.english(req) }
                }
                QLog.p("英語: \"\(en)\"")
                guard QCompose.validEnglish(en) else {
                    inbox.put(token, .failed("invalid output"))
                    return
                }
                // 拾った語が入らなかったら、その語を「必ず入れる語」として1回だけ作り直す(greedy なので同じ材料では毎回同じ文になる)
                let miss = QCompose.missingWords(en, req.words)
                if !miss.isEmpty,
                   let en2 = try? await QComposer.withTimeout(10, { try await c.english(req, must: miss) }),
                   QCompose.validEnglish(en2), QCompose.missingWords(en2, req.words).count < miss.count {
                    en = en2
                }
                let ja = (try? await QComposer.withTimeout(8) { try await c.japanese(en) }) ?? ""
                QLog.p("日本語: \"\(ja)\"")
                let kana = KanaG2P.convert(en, dict: KanaDict.shared.ensure(path: kanaPath))
                QLog.p("カナ: \"\(kana)\" → 受け箱へ")
                inbox.put(token, .ok(QResultText(en: en, ja: ja, kana: kana)))
            } catch {
                QLog.p("AFM の失敗: \(error)")
                AppLog.note("AFM の失敗: \(AppLog.kind(error))")
                inbox.put(token, .failed("\(error)"))
            }
        }
    }

    /// 入力欄の文字を、画面に出ているとおりに取り込む(10/30)。日本語入力で変換を確定する前(下線が付いたまま)に
    /// Q を押すと、確定前の文字は入力欄の値(note)に入っていないため、AFM に何も渡らなかった。
    /// 変換中の文字があれば確定してから、入力欄の編集中の文字(field editor)を読む。パネルの文字入力欄はこの1つだけ
    private func syncNoteFromField() {
        guard let tv = window?.firstResponder as? NSTextView, tv.isFieldEditor else { return }
        if tv.hasMarkedText() {
            QLog.p("入力欄: 変換中の文字を確定")
            tv.unmarkText()
        }
        let s = tv.string
        if s != note {
            QLog.p("入力欄: 画面の文字 \"\(s)\" を取り込む(入力欄の値は \"\(note)\" だった)")
            note = s
        }
    }

    /// AFM の部品を用意する。失敗したら文面(何が起きたか + 次にどうすればよいか)を返す
    private func ensureComposer() -> String? {
        if composer != nil { return nil }
        do {
            composer = try QComposer(systemPath: cfg.qboxSystem, userPath: cfg.qboxUser,
                                     jaSystemPath: cfg.qboxJaSystem, jaUserPath: cfg.qboxJaUser)
            return nil
        } catch {
            let d = "\(error)"
            return d.contains("unavailable") ? QCompose.message(for: d)
                : "AFM の準備ができませんでした。\(cfg.qboxSystem)・\(cfg.qboxUser)・\(cfg.qboxJaSystem) があるか確かめてから、もう一度 Q を押してください"
        }
    }

    /// 質問箱を最初に開いたとき: 発音辞書の読み込みと AFM の立ち上げを裏で済ませておく(最初の Q が遅くならないように)
    private func warmUp() {
        if warmed { return }
        warmed = true
        let e = ensureComposer()
        QLog.p("準備: AFM " + (e ?? "OK"))
        let c = composer
        let path = cfg.kanaDict
        Task.detached {
            KanaDict.shared.ensure(path: path)
            QLog.p("準備: 発音辞書を読み込んだ")
            await c?.warmup()
            QLog.p("準備: AFM の立ち上げが終わった")
        }
    }

    private func pollReply() {
        let got = replyBox.take()
        for r in got where r.token != reqToken { QLog.p("古い依頼の結果を捨てた(番号 \(r.token)、いまは \(reqToken))") }
        for r in got where r.token == reqToken {
            QLog.p("結果を受け取った(番号 \(r.token))")
            afmPending = false
            setPresence { $0.generated() }
            switch r.reply {
            case .ok(let o):
                resultId += 1
                results.insert(QResult(id: resultId, kana: o.kana, en: o.en,
                                       ja: o.ja.isEmpty ? "(日本語訳を作れませんでした)" : o.ja, fromAFM: true), at: 0)
                if o.kana.isEmpty || KanaDict.shared.loaded()?.isEmpty == true {
                    kanaHint = "カナを出すには発音辞書(\(cfg.kanaDict))が要ります。入れ方は README の発音辞書の項を見てください"
                }
            case .failed(let d):
                qError = QCompose.message(for: d)
            }
        }
    }

    /// 語を拾った字幕の行(英語。なければ日本語)。最大3行
    private func contextLines() -> [String] {
        var out: [String] = []
        for p in box.picks where p.on && p.line >= 0 {
            guard let l = snap.lines.first(where: { $0.id == p.line }) else { continue }
            let s = l.en.isEmpty ? l.text : l.en
            if !out.contains(s) { out.append(s) }
            if out.count >= 3 { break }
        }
        return out
    }

    /// 発言をクリック: 英語をコピー(会議のチャットに貼れる)
    func copy(_ r: QResult) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(r.en, forType: .string)
        copiedId = r.id
        copiedAt = now()
    }

    /// 質問箱の出し方を変える。固定になる / 固定をやめるときだけ窓の大きさを変える(onBoxOpen)
    private func setPresence(_ f: (inout QBoxPresence) -> Void) {
        var p = presence
        f(&p)
        guard p != presence else { return }
        let was = presence.mode
        if was == .hidden && p.mode != .hidden {
            // 隠していた → 出す: 列の幅を記録から戻し、発音辞書と AFM を裏で用意する
            let k = scale?.k ?? 1.0
            let saved = UserDefaults.standard.double(forKey: FlowPanelModel.widthKey)
            boxWidth = saved > 0 ? saved * k : QBoxLayout.width(k)
        }
        if was != p.mode { noteFocused = false }   // 列の場所が変わると入力欄のカーソルは外れる
        presence = p
        if (was == .pinned) != (p.mode == .pinned) { onBoxOpen?(p.mode == .pinned) }
        if p.mode != .hidden { warmUp() }
    }

    /// 境目のドラッグ: 列の幅を変える。字幕の列は最低 220pt(×倍率)残す
    func dragBoxWidth(start: Double, delta: Double) {
        let k = scale?.k ?? 1.0
        let total = Double(window?.frame.width ?? 100_000)
        let lo = QBoxLayout.minWidth(k)
        let hi = max(lo, total - QBoxLayout.dividerWidth - 220 * k)
        let w = min(hi, max(lo, start + delta))
        guard w != boxWidth else { return }
        boxWidth = w
        window?.minUserSize.width = baseMinWidth + w + QBoxLayout.dividerWidth
    }

    func endBoxWidthDrag() {
        let k = scale?.k ?? 1.0
        UserDefaults.standard.set(boxWidth / k, forKey: FlowPanelModel.widthKey)
    }

    /// 窓につなぐ: 上端の帯で動かす / 質問箱の開閉で窓を左へ広げる・戻す / 終了時は閉じてから(記録する窓の大きさに列を含めない)
    static func bind(_ m: FlowPanelModel, to w: PanelWindow) {
        w.dragBarHeight = PanelWindow.dragBar
        w.barButtonWidth = BarLayout.rightWidth   // 帯の右端の歯車(U5a)
        w.barLeftWidth = { [weak m] in MainActor.assumeIsolated { m?.barLeftWidth ?? 0 } }
        w.onPointer = { [weak m] inside, x, top in
            MainActor.assumeIsolated { m?.pointer(inside: inside, x: x, fromTop: top) }
        }
        w.trackPointer()
        w.acceptsMouseMovedEvents = true
        m.window = w
        m.applyLook()
        m.windowKey = w.isKeyWindow
        // 窓がキーでなくなったら(ほかのアプリをクリックした)、入力欄のカーソルは「入力中」と見なさない。
        // queue: nil = 送られたスレッド(メイン)ですぐ呼ぶ(メインのキューは使わない。DESIGN-ui.md「実装上の注意」)
        _ = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: w, queue: nil) { [weak m] _ in
            MainActor.assumeIsolated { m?.setWindowKey(true) }
        }
        _ = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: w, queue: nil) { [weak m] _ in
            MainActor.assumeIsolated { m?.setWindowKey(false) }
        }
        m.baseMinWidth = w.minUserSize.width
        m.onBoxOpen = { [weak w, weak m] open in
            guard let w = w, let m = m else { return }
            let baseMin = m.baseMinWidth
            let sw = m.boxWidth + QBoxLayout.dividerWidth
            var f = w.frame
            if open {
                f.origin.x -= sw
                f.size.width += sw
                // 画面の左端からはみ出すなら右へずらす
                if let vf = (w.screen ?? NSScreen.main)?.visibleFrame, f.minX < vf.minX { f.origin.x = vf.minX }
                w.minUserSize.width = baseMin + sw
            } else {
                f.origin.x += sw
                f.size.width = max(baseMin, f.size.width - sw)
                w.minUserSize.width = baseMin
            }
            w.setFrame(f, display: true)
        }
        _ = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak m] _ in
            MainActor.assumeIsolated {
                m?.flushLook()
                m?.closeBox()
            }
        }
    }
}

struct FlowPanelView: View {
    @ObservedObject var model: FlowPanelModel
    @ObservedObject var scale: PanelScale
    @State private var dividerStart: Double? = nil   // 境目をドラッグし始めたときの列の幅
    @State private var dividerHover = false
    @State private var panelWidth = 0.0

    init(model: FlowPanelModel, scale: PanelScale) {
        self.model = model
        self.scale = scale
    }

    var body: some View {
        let k = scale.k
        HStack(spacing: 0) {
            if model.boxOpen {
                QBoxView(model: model, k: k)
                    .frame(width: model.boxWidth)
                    .background(boxColumnBackground(k: k))
                boxDivider(k: k)
            }
            flowColumn(k: k)
        }
        .padding(.top, PanelWindow.dragBar)
        // 重ね表示(U4b): 字幕の上、帯の下に左から。窓の大きさは変えない
        .overlay(alignment: .topLeading) {
            if model.boxPeek {
                peekBox(k: k)
                    .padding(.top, PanelWindow.dragBar)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.boxPeek)
        // 表示の設定(U5a): 字幕の上、帯の下に右から重ねる。別ウィンドウにしないので画面共有に映らない設定がそのまま効く
        .overlay(alignment: .topTrailing) {
            if model.settingsOpen {
                SettingsPanelView(model: model, k: k)
                    .frame(width: min(300, max(240, panelWidth - 40)))
                    .padding(.top, PanelWindow.dragBar)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.settingsOpen)
        // 窓を動かせる範囲にマウスを乗せたら、うっすら色を付ける(つかめる場所だと分かるように)
        .overlay(alignment: .topLeading) { dragBarHighlight(k: k) }
        // 帯の左: × / 開始・ポーズ / 質問箱のアイコン(U4a)。右端: 歯車(U5a)
        .overlay(alignment: .topLeading) { PanelBarView(model: model, controls: model.controls) }
        .overlay(alignment: .topTrailing) { PanelGearView(model: model) }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PanelBackground(k: k, density: model.look.density))
        .onGeometryChange(for: Double.self) { Double($0.size.width) } action: { panelWidth = $0 }
    }

    /// 重ねて出す質問箱。字幕が少し見えるよう窓の幅より狭くし、字幕より濃い背景と影で浮かせる(下の角は窓の角丸に合わせる)
    private func peekBox(k: Double) -> some View {
        let w = max(QBoxLayout.minWidth(k), min(model.boxWidth, panelWidth - 48 * k))
        let shape = UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 14 * k,
                                           bottomTrailingRadius: 12 * k, topTrailingRadius: 12 * k, style: .continuous)
        return QBoxView(model: model, k: k)
            .padding(.top, 4 * k)
            .frame(width: w)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(
                ZStack {
                    shape.fill(.regularMaterial)
                    shape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.55))
                }
                .shadow(color: Color.black.opacity(0.22), radius: 10 * k, x: 3 * k)
            )
            .overlay(shape.stroke(Color.primary.opacity(0.1), lineWidth: 1))
            .contentShape(Rectangle())
    }

    /// 帯の「窓を動かせる範囲」(左のボタンの並びと右端の歯車の間)のハイライト。窓の当たり判定(PanelWindow.inDragBar)と同じ範囲
    private func dragBarHighlight(k: Double) -> some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color.primary.opacity(model.barDragHover ? 0.10 : 0))
            .padding(.vertical, 3)
            .padding(.leading, model.barLeftWidth)
            .padding(.trailing, BarLayout.rightWidth)
            .frame(height: PanelWindow.dragBar)
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.15), value: model.barDragHover)
    }

    /// 固定した質問箱の列の下地。背景を薄くしても質問箱はいままでの濃さで読めるよう、薄くしたぶんだけすりガラスを足す
    @ViewBuilder
    private func boxColumnBackground(k: Double) -> some View {
        let add = 1 - LookValues.materialOpacity(model.look.density)
        if add > 0 {
            UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 14 * k,
                                   bottomTrailingRadius: 0, topTrailingRadius: 0, style: .continuous)
                .fill(.ultraThinMaterial)
                .opacity(add)
        }
    }

    /// 質問箱と字幕の境目。見た目は細い線、つかめる幅は少し広め。左右にドラッグで列の幅を変える
    private func boxDivider(k: Double) -> some View {
        let active = dividerHover || dividerStart != nil
        return Rectangle()
            .fill(Color.primary.opacity(active ? 0.32 : 0.12))
            .frame(width: active ? 2 : 1)
            .frame(width: QBoxLayout.dividerWidth)
            .frame(maxHeight: .infinity)
            .padding(.vertical, 6 * k)
            .contentShape(Rectangle())
            .onHover { inside in
                dividerHover = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { v in
                        if dividerStart == nil { dividerStart = model.boxWidth }
                        model.dragBoxWidth(start: dividerStart ?? model.boxWidth, delta: Double(v.translation.width))
                    }
                    .onEnded { _ in
                        dividerStart = nil
                        model.endBoxWidthDrag()
                    }
            )
    }

    private func flowColumn(k: Double) -> some View {
        let lines = model.snap.lines
        let lastId = lines.last?.id ?? -1

        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14 * k) {
                    ForEach(Array(lines.enumerated()), id: \.element.id) { i, line in
                        let dist = lines.count - 1 - i     // 0 = いちばん新しい(下)
                        block(line, isNewest: dist == 0, k: k)
                            .opacity(opacity(dist))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .id(line.id)
                    }
                }
                .padding(.vertical, 4 * k)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)
            // 読み返し: いちばん下からの距離と、ユーザーが動かしているか(指 / 慣性)を渡す
            .onScrollGeometryChange(for: Double.self) { g in
                Double(g.contentSize.height - g.contentOffset.y - g.containerSize.height)
            } action: { _, d in
                model.scrollGeometry(distFromBottom: d)
            }
            .onScrollPhaseChange { _, phase in
                model.scrollPhase(user: phase == .interacting || phase == .decelerating)
            }
            .onAppear { proxy.scrollTo(lastId, anchor: .bottom) }
            .onChange(of: lastId) { _, id in
                // 読み返し中は新しい行が来ても飛ばない
                guard !model.browsing else { return }
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .bottom) }
            }
            .onChange(of: model.jumpToken) { _, _ in
                withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(lastId, anchor: .bottom) }
            }
        }
        .padding(EdgeInsets(top: 0, leading: PanelLayout.padSide(k),
                            bottom: PanelLayout.padBottom(k), trailing: PanelLayout.padSide(k)))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if model.browsing { latestButton(k: k).transition(.opacity) }
        }
        .animation(.easeOut(duration: 0.2), value: model.browsing)
    }

    /// 読み返し中だけ出す「↓ 最新へ」。音楽プレーヤーの再生バーのような小さなカプセル
    private func latestButton(k: Double) -> some View {
        Button { model.jumpToLatest() } label: {
            HStack(spacing: 5 * k) {
                Image(systemName: "arrow.down")
                Text(model.unseen > 0 ? "最新へ  \(model.unseen)" : "最新へ")
            }
            .font(.system(size: 12 * k, weight: .semibold))
            .foregroundColor(Color.primary)
            .padding(.horizontal, 14 * k)
            .padding(.vertical, 7 * k)
            .background(Capsule().fill(.regularMaterial))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
            .shadow(color: Color.black.opacity(0.18), radius: 6 * k, y: 2 * k)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.bottom, FlowLayout.latestBottom(k))
    }

    /// 上へ行くほど薄く。flow_fade 行で flow_min_opacity まで下がる
    private func opacity(_ dist: Int) -> Double {
        if dist <= 0 { return 1.0 }
        let cfg = model.cfg
        let lo = min(max(cfg.flowMinOpacity, 0.05), 1.0)
        let fade = max(1, cfg.flowFade)
        let step = (1.0 - lo) / Double(fade)
        return max(lo, 0.85 - Double(dist - 1) * step)
    }

    @ViewBuilder
    private func block(_ line: FlowLine, isNewest: Bool, k: Double) -> some View {
        if line.sep {
            // 区切りの行(聞き取りの開始): 小さく中央に
            Text(line.text)
                .font(.system(size: max(11, model.look.flowEnPt) * k))
                .foregroundColor(Color.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .modifier(SubtitleHalo(strength: LookValues.haloStrength(model.look.density), k: k))
        } else {
            textBlock(line, isNewest: isNewest, k: k)
        }
    }

    /// 1かたまり: 上が日本語(大)、下がもとの英語(小)。歌詞の対訳表示と上下の大きさを入れ替えた形。
    /// 語ごとにクリックで拾える(マウスを乗せると下線、拾った語はカプセル)
    private func textBlock(_ line: FlowLine, isNewest: Bool, k: Double) -> some View {
        let look = model.look
        let t = model.tokens[line.id]
        // 文字の大きさは行によって変えない(新しい行が来るたびに折り返しが組み直されて読みにくくなるのを避ける)
        let mainSize = look.flowPt * k
        let enSize = look.flowEnPt * k
        return VStack(alignment: .leading, spacing: 3 * k) {
            tokenRow(line: line, row: 0, lang: t?.mainLang ?? .ja,
                     toks: t?.main ?? [QToken(display: line.text, pick: "")],
                     size: mainSize, weight: isNewest ? .semibold : .regular,
                     color: isNewest ? Color.primary : Color.secondary, k: k, stale: line.stale, family: look.font)
            if look.flowEnPt > 0 && !line.en.isEmpty {
                tokenRow(line: line, row: 1, lang: .en,
                         toks: t?.en ?? [QToken(display: line.en, pick: "")],
                         size: enSize, weight: .regular, color: Color.secondary, k: k, stale: false, family: look.font)
                    .opacity(isNewest ? 0.85 : 0.7)
            }
        }
        // 背景を薄くしたときの縁取り(背景色の影)
        .modifier(SubtitleHalo(strength: LookValues.haloStrength(look.density), k: k))
    }

    private func tokenRow(line: FlowLine, row: Int, lang: QLang, toks: [QToken], size: Double,
                          weight: Font.Weight, color: Color, k: Double, stale: Bool, family: SubtitleFont) -> some View {
        WrapLayout(spacing: lang == .en ? size * 0.28 : 0, lineSpacing: size * 0.2) {
            ForEach(Array(toks.enumerated()), id: \.offset) { i, tk in
                QTokenView(token: tk, size: size, weight: weight, color: color,
                           picked: model.box.isPicked(line: line.id, row: row, index: i), k: k, family: family) {
                    model.click(line: line, row: row, index: i)
                }
            }
            if stale {
                Text("⚠").font(.system(size: size * 0.8)).foregroundColor(Color.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 「最新へ」の位置
enum FlowLayout {
    static func latestBottom(_ k: Double) -> Double { 10 * k }
}
