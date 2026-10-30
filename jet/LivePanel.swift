import AppKit
import Foundation

// U2: live(--mic / --system / --file)の結果をパネルに出す。  ./jetcli --mic --panel
// Live.run は async でメインの外の Task で動かし、EventSink が受け箱(EventInbox)に入れたイベントを
// メインの 30ms tick が取り出して表示に渡す。@MainActor の Task は使わない(DESIGN-ui.md「実装上の注意」)

/// 受け箱のイベントを30msごとに表示へ渡す。時刻は Live と同じ時計(最初の音声バッファが0秒)
@MainActor
final class LiveDriver {
    private let display: EventDisplay
    private let inbox: EventInbox
    /// 聞き取り1回ごとに新しい時計に差し替える(メニューバー)
    var clock: LiveClock
    private var timer: Timer?

    init(display: EventDisplay, inbox: EventInbox, clock: LiveClock) {
        self.display = display
        self.inbox = inbox
        self.clock = clock
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        for e in inbox.take() { display.apply(e) }
        display.advance(to: clock.now())
    }
}

extension PanelApp {
    @MainActor
    static func runLive(o: Opts, conf: JetConfig, cor: Corrector, sink: EventSink,
                        draft: DraftTranslator, evPath: String?) async throws {
        let ui = conf.ui
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)   // Dock に出さない
        let scale = PanelScale()
        let parts = makeDisplay(ui, scale: scale)
        let controller = PanelController(cfg: ui, scale: scale, root: parts.root)
        controller.attach(parts)
        let inbox = EventInbox()
        sink.setTee(inbox)
        let clock = LiveClock()
        let driver = LiveDriver(display: parts.display, inbox: inbox, clock: clock)

        // 入力を止めるフラグはここで持つ(U4: 帯の × と ⌘Q でも止めてから終了するため)。
        // 1回目の Ctrl-C は従来どおり入力を止めるだけ(パネルは残る)。Live.run は外からフラグを渡すと Ctrl-C を奪わないので、ここで受ける
        let stop = StopFlag()
        let ended = StopFlag()       // Live.run が終わった(イベントを書き終えた)
        let wantQuit = StopFlag()    // × / ⌘Q で終了を頼まれた
        signal(SIGINT, SIG_IGN)
        let sigSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        sigSrc.setEventHandler { stop.set() }
        sigSrc.resume()
        if let c = parts.controls {
            c.run = .running
            c.onQuit = { [weak c] in
                MainActor.assumeIsolated {
                    if ended.get() { NSApp.terminate(nil); return }
                    wantQuit.set()
                    stop.set()
                    c?.run = .stopping
                    // 止まらなければ5秒で終了(メニューバーの「終了」と同じ)
                    Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { _ in
                        MainActor.assumeIsolated { NSApp.terminate(nil) }
                    }
                }
            }
        }
        // ⌘Q も × と同じ経路(2段階は通さない)
        controller.window.onQuit = { [weak c = parts.controls] in
            MainActor.assumeIsolated {
                if let c = c { c.quitNow() } else { NSApp.terminate(nil) }
            }
        }
        // 終わったことは 0.2秒のタイマーで受け取る(@MainActor の Task は使わない)
        let watch = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak c = parts.controls] t in
            MainActor.assumeIsolated {
                guard ended.get() else { return }
                t.invalidate()
                c?.run = .idle
                if wantQuit.get() { NSApp.terminate(nil) }
            }
        }
        controller.show()
        driver.start()

        // Live.run はメインの外で動かす。終わってもパネルは残す(最後の文を読めるように)
        Task.detached {
            do {
                try await Live.run(file: o.file, mic: o.mic, system: o.system, excludeSelf: o.excludeSelf, play: o.play,
                                   seconds: o.seconds, saveAudio: o.saveAudio,
                                   conf: conf, cor: cor, sink: sink, draft: draft, clock: clock, stopFlag: stop)
            } catch {
                fputs("エラー: \(error)\n", stderr)
                exit(1)
            }
            signal(SIGINT, SIG_DFL)   // 入力は止まったので、次の Ctrl-C でパネルごと閉じる
            if let p = evPath {
                print("\nイベント: \(p)")
                print("照合: python3 sim/parity.py \(p)")
            }
            if !wantQuit.get() { print("入力は終了しました。パネルは残します(帯の ×・⌘Q・Ctrl-C で終了)") }
            ended.set()
        }
        print("パネルを表示しました(live)。話し始めてください。Ctrl-C で入力を止める(パネルは残る)/ パネルを一度クリックして ⌘Q で終了")
        withExtendedLifetime((controller, driver, parts.display, sigSrc, watch)) {
            app.run()
        }
    }
}
