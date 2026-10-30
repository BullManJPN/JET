import AppKit
import Foundation

// U3: メニューバー。アプリは起動したまま、聞き取り(Live.run 1回分 = セッション)を何度でも始めたり止めたりする。
//   ./jetcli --menubar
// 起動直後は停止中。メニュー: 開始/ポーズ・入力(マイク / システム音声)・パネルの表示・設定ファイルを開く・終了
// U4: 窓の帯の × / 開始・ポーズ(PanelBar.swift の PanelControls)もここにつなぐ。× と ⌘Q と Ctrl-C は「終了」と同じ経路
// メインスレッドはパネルのループが使い続けるので、@MainActor の Task は使わない(DESIGN-ui.md「実装上の注意」)。
// セッションは Task.detached で動かし、終わったことは SessionBox に書く → メニュー側のタイマーが読んで表示を変える

/// セッションの終わりを、メインの外(Live.run のタスク)からメニューへ渡す箱
final class SessionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var ended = false
    private var error: String? = nil
    private var evPath: String? = nil
    private var errorKind: String? = nil

    func reset() { lock.lock(); ended = false; error = nil; evPath = nil; errorKind = nil; lock.unlock() }

    func finish(error: String?, evPath: String, errorKind: String? = nil) {
        lock.lock(); ended = true; self.error = error; self.evPath = evPath; self.errorKind = errorKind; lock.unlock()
    }

    /// 終わっていたら (エラー, イベントのパス, エラーの種類) を返して空にする。errorKind は診断ログ用(本文を含まない)
    func take() -> (error: String?, evPath: String, errorKind: String?)? {
        lock.lock(); defer { lock.unlock() }
        guard ended, let p = evPath else { return nil }
        ended = false
        return (error, p, errorKind)
    }
}

@MainActor
final class JetMenu: NSObject {
    enum Phase { case idle, running, stopping }

    private let o: Opts
    private let conf: JetConfig
    private let cor: Corrector
    private let draft: DraftTranslator
    private let controller: PanelController
    private let driver: LiveDriver
    private let inbox: EventInbox
    private let item: NSStatusItem
    private let box = SessionBox()
    private var timer: Timer?

    private var phase: Phase = .idle
    private var lastError: String? = nil
    private var stopFlag: StopFlag? = nil
    private var restartAfterStop = false   // 聞き取り中に入力を切り替えた → 止まったら新しい入力で始める
    private var quitting = false
    /// 窓の帯のボタン(流れ型)。状態はここから書く
    var controls: PanelControls?
    /// Terminal の Ctrl-C(シグナルのスレッドで立てる → poll で「終了」と同じ経路へ)
    var sigint: StopFlag?

    private static let sourceKey = "JETMenuSource"
    /// "mic" / "system"。最後に使った入力を覚えておく
    private var source: String {
        didSet { UserDefaults.standard.set(source, forKey: JetMenu.sourceKey) }
    }

    init(o: Opts, conf: JetConfig, cor: Corrector, draft: DraftTranslator,
         controller: PanelController, driver: LiveDriver, inbox: EventInbox) {
        self.o = o
        self.conf = conf
        self.cor = cor
        self.draft = draft
        self.controller = controller
        self.driver = driver
        self.inbox = inbox
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let saved = UserDefaults.standard.string(forKey: JetMenu.sourceKey)
        self.source = (saved == "system") ? "system" : "mic"
        super.init()
    }

    func setup() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    // MARK: 状態

    private func poll() {
        if let s = sigint, s.get(), !quitting {
            print("\nCtrl-C: 聞き取りを止めてから終了します")
            doQuit()
        }
        guard let r = box.take() else { return }
        stopFlag = nil
        phase = .idle
        lastError = r.error
        if let e = r.error {
            print("聞き取りが止まりました(エラー): \(e)")
            AppLog.note("聞き取りが止まった(エラー): \(r.errorKind ?? "不明")")
        } else {
            AppLog.note("聞き取りを止めた")
            print("聞き取りを止めました。イベント: \(r.evPath)")
        }
        if quitting { NSApp.terminate(nil); return }
        if restartAfterStop {
            restartAfterStop = false
            if r.error == nil { start() }
        }
        refresh()
    }

    private var sourceName: String { source == "system" ? "システム音声" : "マイク" }

    /// メニューバーの文字を縦中央に寄せる補正(負の値で下げる)。上に寄って見えるときは小さく(-3 など)、下すぎるときは 0 に近づける
    private static let barBaseline: CGFloat = -2

    private func refresh() {
        switch phase {
        case .idle: controls?.run = .idle
        case .running: controls?.run = .running
        case .stopping: controls?.run = .stopping
        }
        // メニューバー: 文字で「JET」。停止中 = JET / 聞き取り中 = JET ● / エラー = JET !
        if let b = item.button {
            let mark: String
            switch phase {
            case .running, .stopping: mark = " ●"
            case .idle: mark = lastError == nil ? "" : " !"
            }
            b.image = nil
            b.attributedTitle = NSAttributedString(
                string: "JET" + mark,
                attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .heavy),
                             .baselineOffset: Self.barBaseline])
            b.setAccessibilityLabel("JET")
        }

        let m = NSMenu()
        m.autoenablesItems = false
        let status: String
        switch phase {
        case .idle: status = lastError.map { "エラー: " + String($0.prefix(60)) } ?? "停止中"
        case .running: status = "聞き取り中(\(sourceName))"
        case .stopping: status = "止めています…"
        }
        let st = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        st.isEnabled = false
        m.addItem(st)

        let toggle = NSMenuItem(title: phase == .idle ? "開始" : "ポーズ", action: #selector(toggleRun), keyEquivalent: "")
        toggle.target = self
        toggle.isEnabled = phase != .stopping
        m.addItem(toggle)
        m.addItem(.separator())

        let head = NSMenuItem(title: "入力", action: nil, keyEquivalent: "")
        head.isEnabled = false
        m.addItem(head)
        for (key, title) in [("mic", "マイク"), ("system", "システム音声")] {
            let it = NSMenuItem(title: title, action: #selector(pickSource(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = key
            it.state = source == key ? .on : .off
            it.indentationLevel = 1
            it.isEnabled = phase != .stopping
            m.addItem(it)
        }
        m.addItem(.separator())

        let panel = NSMenuItem(title: controller.window.isVisible ? "パネルを隠す" : "パネルを表示",
                               action: #selector(togglePanel), keyEquivalent: "")
        panel.target = self
        m.addItem(panel)
        let settings = NSMenuItem(title: "設定ファイルを開く", action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        m.addItem(settings)
        if JetPaths.mode == .app {
            let log = NSMenuItem(title: "ログを開く", action: #selector(openLog), keyEquivalent: "")
            log.target = self
            m.addItem(log)
        }
        m.addItem(.separator())

        let quitItem = NSMenuItem(title: "終了", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        m.addItem(quitItem)
        item.menu = m
    }

    // MARK: 操作

    /// 開始 / ポーズ(メニューと窓の帯のボタンから)。ポーズ = 流しきって止まる(字幕の行は残り、再開すると区切りの行が入る)
    @objc func toggleRun() {
        switch phase {
        case .idle: start()
        case .running: stop()
        case .stopping: break
        }
    }

    @objc private func pickSource(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String, key != source else { return }
        source = key
        if phase == .running {
            restartAfterStop = true
            stop()
        } else {
            refresh()
        }
    }

    @objc private func togglePanel() {
        if controller.window.isVisible { controller.window.orderOut(nil) } else { controller.window.orderFrontRegardless() }
        refresh()
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: AppLog.ensureFile()))
    }

    @objc private func openSettings() {
        NSWorkspace.shared.open(URL(fileURLWithPath: JetPaths.settingsFile(explicit: o.config)))
    }

    /// メニューの「終了」・⌘Q・帯の ×。app モードで閉じると消える内容があるときは、先に警告を出す
    @objc func quit() {
        if !quitting, controls?.willWarn == true, !confirmLoss() {
            controls?.quitCancelled()
            return
        }
        doQuit()
    }

    /// 「閉じると、この画面の内容は消えます」。閉じてよければ true。キャンセルを既定(Return・Esc)にして、入力途中の誤操作を防ぐ
    private func confirmLoss() -> Bool {
        let a = NSAlert()
        a.messageText = "閉じると、この画面の内容は消えます"
        a.informativeText = "字幕と、質問箱で作った発言・入力中の文章は、どこにも保存されていません。"
        a.alertStyle = .warning
        a.addButton(withTitle: "キャンセル")
        let close = a.addButton(withTitle: "閉じる")
        close.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        a.window.level = max(a.window.level, controller.window.level)
        return a.runModal() == .alertSecondButtonReturn
    }

    /// 聞き取り中なら止めて(残りの節を流しきって)から終了する。止まらなければ5秒で終了
    private func doQuit() {
        if phase == .idle { NSApp.terminate(nil); return }
        if quitting { return }
        quitting = true
        controls?.noteQuitting()   // 帯の × を「終了中…」に(⌘Q・Ctrl-C から来たときも)
        if phase == .running { stop() }
        Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { _ in
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
    }

    private func start() {
        guard phase == .idle else { return }
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        // app モードはファイルに書かない(メモリだけ。閉じると消える)。evPath は表示用
        let evFile: String? = conf.keepLogs ? "\(conf.eventsDir)/jet-\(df.string(from: Date())).jsonl" : nil
        let evPath = evFile ?? "(保存しない)"
        let sink: EventSink
        do {
            sink = try EventSink(path: evFile, quiet: o.quiet)
        } catch {
            lastError = "\(error)"
            refresh()
            return
        }
        sink.setTee(inbox)
        let clock = LiveClock()
        driver.clock = clock
        let flag = StopFlag()
        stopFlag = flag
        box.reset()
        lastError = nil
        phase = .running
        if !controller.window.isVisible { controller.window.orderFrontRegardless() }
        refresh()
        print("聞き取りを開始(\(sourceName))。イベント: \(evPath)")
        AppLog.note("聞き取りを開始(\(sourceName))")

        let mic = source == "mic", system = source == "system"
        let excludeSelf = o.excludeSelf, saveAudio = o.saveAudio
        let conf = self.conf, cor = self.cor, draft = self.draft
        let box = self.box
        Task.detached {
            do {
                try await Live.run(file: nil, mic: mic, system: system, excludeSelf: excludeSelf, play: nil,
                                   seconds: 0, saveAudio: saveAudio,
                                   conf: conf, cor: cor, sink: sink, draft: draft,
                                   clock: clock, stopFlag: flag)
                sink.setTee(nil)   // 終わった回のイベントがこれ以上パネルに来ないように
                box.finish(error: nil, evPath: evPath)
            } catch {
                sink.setTee(nil)
                box.finish(error: "\(error)", evPath: evPath, errorKind: AppLog.kind(error))
            }
        }
    }

    private func stop() {
        guard phase == .running, let f = stopFlag else { return }
        f.set()
        phase = .stopping
        refresh()
    }
}

extension PanelApp {
    @MainActor
    static func runMenubar(o: Opts, conf: JetConfig, cor: Corrector,
                           draft: DraftTranslator) async throws {
        let ui = conf.ui
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)   // Dock に出さない(メニューバーだけ)
        let scale = PanelScale()
        let parts = makeDisplay(ui, scale: scale)
        let controller = PanelController(cfg: ui, scale: scale, root: parts.root)
        controller.attach(parts)
        let inbox = EventInbox()
        let driver = LiveDriver(display: parts.display, inbox: inbox, clock: LiveClock())
        let menu = JetMenu(o: o, conf: conf, cor: cor, draft: draft,
                           controller: controller, driver: driver, inbox: inbox)
        // ⌘Q はメインスレッドの performKeyEquivalent から呼ばれる
        controller.window.onQuit = { [weak menu] in MainActor.assumeIsolated { menu?.quit() } }
        // 窓の帯(流れ型): 開始・ポーズ / × をメニューと同じ経路へ
        if let c = parts.controls {
            c.canRun = true
            c.onToggleRun = { [weak menu] in MainActor.assumeIsolated { menu?.toggleRun() } }
            c.onQuit = { [weak menu] in MainActor.assumeIsolated { menu?.quit() } }
            c.warnsOnLoss = JetPaths.mode == .app   // 閉じると消える内容があるときの警告(終了時)
            menu.controls = c
        }
        // Ctrl-C も「終了」と同じ(聞き取りを止め、イベントを書き終えてから。止まらなければ5秒で終了)
        let sigFlag = StopFlag()
        signal(SIGINT, SIG_IGN)
        let sigSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        sigSrc.setEventHandler { sigFlag.set() }
        sigSrc.resume()
        menu.sigint = sigFlag
        controller.show()
        driver.start()
        menu.setup()
        print("メニューバーに JET を出しました。メニューの「開始」で聞き取りを始めます。終了はメニューの「終了」・パネルの帯の ×・パネルをクリックして ⌘Q・Ctrl-C")
        withExtendedLifetime((controller, driver, parts.display, menu, sigSrc)) {
            app.run()
        }
    }
}
