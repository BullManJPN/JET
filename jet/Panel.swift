import AppKit
import Combine
import SwiftUI

// 字幕パネルの窓と、表示を窓につなぐ部分(表示の中身は FlowPanel.swift)。
//   ./jetcli --replay-events results/flow-20261029-154617.jsonl [--speed 1]
// 操作: パネルを一度クリック → ⌘+ / ⌘− で文字サイズ、⌘Q で終了。上端の帯か ⌘+ドラッグで移動、辺・角のドラッグで大きさ。Terminal の Ctrl-C でも終了。

// MARK: - 共通

/// イベントを受け取って表示を更新するもの(ReplayDriver と、U2 の live がこれに渡す)
@MainActor
protocol EventDisplay: AnyObject {
    func apply(_ e: Ev)
    func advance(to t: Double)
}

@MainActor
final class PanelScale: ObservableObject {
    @Published var k = 1.0
    func zoom(_ step: Int) {
        k = min(2.0, max(0.6, k + Double(step) * 0.1))
    }
}

/// 窓の背景。すりガラスと色の膜の2枚重ねで、濃さ(U5a 設定パネル)を変える。0.6 = すりガラスだけ(いままでの見た目)
struct PanelBackground: View {
    let k: Double
    var density = LookValues.defaultDensity
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14 * k, style: .continuous)
        ZStack {
            shape.fill(.ultraThinMaterial).opacity(LookValues.materialOpacity(density))
            shape.fill(Color(nsColor: .windowBackgroundColor)).opacity(LookValues.tintOpacity(density))
        }
    }
}

/// パネルの余白(画面とウィンドウの両方で同じ計算を使う)
enum PanelLayout {
    static func padBottom(_ k: Double) -> Double { 12 * k }
    static func padSide(_ k: Double) -> Double { 18 * k }
}

// MARK: - ウィンドウ

final class PanelWindow: NSPanel {
    var onZoom: ((Int) -> Void)?
    /// ⌘Q(メニューバーでは聞き取りを止めてから終了する)。nil ならすぐ終了
    var onQuit: (() -> Void)?
    /// 辺・角のドラッグで大きさを変えられるか
    var userResizable = false
    var minUserSize = NSSize(width: 320, height: 240)
    private let edge = 6.0
    /// 上端の帯の高さ(閉じるボタンなどが並ぶ行 + 少し)。流れ型はここをつかむと窓が動く
    static let dragBar = 28.0
    /// nil 以外(流れ型): 帯か ⌘+ドラッグでだけ窓を動かし、それ以外のクリックは中身(語のクリックなど)へ渡す
    var dragBarHeight: Double? = nil
    /// 帯の右端のこの幅はボタン(U5a の歯車)なので、窓を動かさず中身へ渡す
    var barButtonWidth = 0.0
    /// 帯の左のボタンの並び(× / 開始・ポーズ / 質問箱)の幅。この幅は窓を動かさず中身へ渡す(U4。「終了する?」で広がる)
    var barLeftWidth: (() -> Double)? = nil
    /// マウスが窓に入った・動いた(true)/ 出た(false)。座標は窓の左からの x と、窓の上からの距離。アプリが前面になくても届く
    var onPointer: ((Bool, Double, Double) -> Void)?
    private var tracker: PointerTracker? = nil

    private func inDragBar(_ p: NSPoint) -> Bool {
        guard let b = dragBarHeight else { return false }
        return Double(frame.height) - Double(p.y) < b && Double(p.x) > (barLeftWidth?() ?? 0)
            && Double(p.x) < Double(frame.width) - barButtonWidth
    }

    /// 帯のボタン(左の並び・右端の歯車)の上か。角のリサイズより優先する(外側の辺 edge pt だけはリサイズのまま)
    private func inBarButtons(_ p: NSPoint) -> Bool {
        guard let b = dragBarHeight else { return false }
        let x = Double(p.x), top = Double(frame.height) - Double(p.y), w = Double(frame.width)
        guard top < b && top > edge else { return false }
        if let lw = barLeftWidth?(), x > edge && x <= lw { return true }
        return barButtonWidth > 0 && x < w - edge && x >= w - barButtonWidth
    }

    /// マウスの出入りを追う(NSTrackingArea を .activeAlways で。中身の大きさが変わっても追従する)
    func trackPointer() {
        guard tracker == nil, let v = contentView else { return }
        let t = PointerTracker()
        t.onMove = { [weak self] e in
            guard let self = self else { return }
            let p = e.locationInWindow
            self.onPointer?(true, Double(p.x), Double(self.frame.height) - Double(p.y))
        }
        t.onExit = { [weak self] in self?.onPointer?(false, -1, -1) }
        v.addTrackingArea(NSTrackingArea(rect: .zero,
                                         options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                         owner: t, userInfo: nil))
        tracker = t
    }
    /// 背景の角丸の半径(14 × 文字サイズ倍率)。角の当たり判定をこの大きさにする(見た目のカーブ = 角)
    var cornerRadius = 14.0
    /// 直前にリサイズ用のカーソルを出していたか(離れたときだけ通常の矢印に戻す。境目のカーソルと取り合わないため)
    private var resizeCursorShown = false

    private func edges(at p: NSPoint) -> (l: Bool, r: Bool, b: Bool, t: Bool) {
        let w = Double(frame.width), h = Double(frame.height)
        let x = Double(p.x), y = Double(p.y)
        // 角: 角から縦横 c 以内の四角はまるごと角(カーブしている区間をつかめば斜めに変わる)
        let c = max(12.0, cornerRadius)
        let nl = x < c, nr = x > w - c, nb = y < c, nt = y > h - c
        if (nl || nr) && (nb || nt) { return (nl, nr, nb, nt) }
        return (x < edge, x > w - edge, y < edge, y > h - edge)
    }

    private func updateResizeCursor(at p: NSPoint) {
        if inBarButtons(p) {
            if resizeCursorShown {
                NSCursor.arrow.set()
                resizeCursorShown = false
            }
            return
        }
        let e = edges(at: p)
        let cursor: NSCursor?
        switch (e.l, e.r, e.b, e.t) {
        case (true, _, _, true): cursor = .frameResize(position: .topLeft, directions: .all)
        case (_, true, _, true): cursor = .frameResize(position: .topRight, directions: .all)
        case (true, _, true, _): cursor = .frameResize(position: .bottomLeft, directions: .all)
        case (_, true, true, _): cursor = .frameResize(position: .bottomRight, directions: .all)
        case (true, _, _, _), (_, true, _, _): cursor = .resizeLeftRight
        case (_, _, true, _), (_, _, _, true): cursor = .resizeUpDown
        default: cursor = inDragBar(p) ? NSCursor.openHand : nil
        }
        if let c = cursor {
            c.set()
            resizeCursorShown = true
        } else if resizeCursorShown {
            NSCursor.arrow.set()
            resizeCursorShown = false
        }
    }

    /// 辺・角のドラッグで大きさを変える(枠なしのウィンドウなので自前で行う)
    private func resizeLoop(_ e: (l: Bool, r: Bool, b: Bool, t: Bool)) {
        let start = frame
        let m0 = NSEvent.mouseLocation
        while let ev = nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if ev.type == .leftMouseUp { break }
            let m = NSEvent.mouseLocation
            let dx = m.x - m0.x, dy = m.y - m0.y
            var f = start
            if e.r { f.size.width = max(minUserSize.width, start.width + dx) }
            if e.l {
                let w = max(minUserSize.width, start.width - dx)
                f.origin.x = start.maxX - w
                f.size.width = w
            }
            if e.t { f.size.height = max(minUserSize.height, start.height + dy) }
            if e.b {
                let h = max(minUserSize.height, start.height - dy)
                f.origin.y = start.maxY - h
                f.size.height = h
            }
            setFrame(f, display: true)
        }
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            makeKey()   // 先にキーにしておくので、クリック後の ⌘+ / ⌘− / ⌘Q も使える
            let p = event.locationInWindow
            if inBarButtons(p) {
                // 帯のボタン(× / 開始・ポーズ / 質問箱 / 右端の歯車)は SwiftUI へ
                super.sendEvent(event)
                return
            }
            let e = edges(at: p)
            if userResizable && (e.l || e.r || e.b || e.t) {
                resizeLoop(e)
                return
            }
            if dragBarHeight != nil {
                // 流れ型: 帯か ⌘+ドラッグで移動。それ以外は中身へ(語のクリック・質問箱の操作・「最新へ」)
                if inDragBar(p) || event.modifierFlags.contains(.command) {
                    performDrag(with: event)
                } else {
                    super.sendEvent(event)
                }
                return
            }
            // 中身が SwiftUI なので背景のドラッグがウィンドウに届かない → パネル自身のドラッグ移動を始める
            performDrag(with: event)
            return
        }
        if event.type == .mouseMoved && (userResizable || dragBarHeight != nil) {
            updateResizeCursor(at: event.locationInWindow)
        }
        super.sendEvent(event)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
           let c = event.charactersIgnoringModifiers {
            switch c {
            case "=", "+": onZoom?(1); return true
            case "-": onZoom?(-1); return true
            case "q":
                if let q = onQuit { q() } else { NSApp.terminate(nil) }
                return true
            // 入力欄の編集(メニューの無いアプリなので、編集のキーを自前で送る)
            case "v": if NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self) { return true }
            case "c": if NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self) { return true }
            case "x": if NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self) { return true }
            case "a": if NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self) { return true }
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class PanelController {
    let cfg: UIConfig
    let scale: PanelScale
    let window: PanelWindow
    private var bag = Set<AnyCancellable>()

    init(cfg: UIConfig, scale: PanelScale, root: AnyView) {
        self.cfg = cfg
        self.scale = scale
        let size = NSSize(width: cfg.panelWidth, height: cfg.panelHeight)
        let w = PanelWindow(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        w.isFloatingPanel = true
        w.level = .floating
        w.hidesOnDeactivate = false
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.isMovableByWindowBackground = true
        w.sharingType = .none     // 画面共有・録画に映さない
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: root)
        // 中身の大きさでウィンドウの大きさを縛らない(自由に変えられるように)。
        // そのぶん中身が自分の大きさを持たないので、窓いっぱいに広げて窓に合わせて伸び縮みさせる
        // (これが無いと中身が 0×0 になり、背景が描かれず窓全体が透明 → クリックが素通りする)
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = [.width, .height]
        host.frame = NSRect(origin: .zero, size: size)
        w.contentView = host
        // Webカメラの真下 = 画面上端の中央
        if let sf = NSScreen.main?.visibleFrame {
            w.setFrameOrigin(NSPoint(x: sf.midX - size.width / 2, y: sf.maxY - size.height - 4))
        }
        self.window = w
        w.onZoom = { [weak scale] step in scale?.zoom(step) }
        // 大きさは自由に変えられる。位置と大きさは記録して次回も同じに(文字サイズでは窓を変えない)
        w.userResizable = true
        w.acceptsMouseMovedEvents = true
        // 角の当たり判定を背景の角丸(14 × k)に合わせる。文字サイズを変えると丸みも判定も変わる
        scale.$k.sink { [weak w] k in w?.cornerRadius = 14 * k }.store(in: &bag)
        w.setFrameAutosaveName("JETFlowPanel")
    }

    /// 表示の部品(窓への結びつけ)を窓につなぐ。起動の経路(live / replay / menubar)で共通
    func attach(_ parts: PanelApp.DisplayParts) {
        parts.bindWindow?(window)
    }

    func show() {
        window.orderFrontRegardless()
        if let v = window.contentView {
            print(String(format: "パネル: 窓 %.0f×%.0f / 中身 %.0f×%.0f", window.frame.width, window.frame.height, v.frame.width, v.frame.height))
        }
    }
}

// MARK: - 保存したイベントを実時間で流す

@MainActor
final class ReplayDriver {
    private let events: [Ev]
    private let speed: Double
    private let display: EventDisplay
    private var index = 0
    private var startedAt = Date()
    private var timer: Timer?
    private var finished = false

    init(events: [Ev], speed: Double, display: EventDisplay) {
        self.events = events
        self.speed = speed
        self.display = display
    }

    func start() {
        startedAt = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        let now = Date().timeIntervalSince(startedAt) * speed
        while index < events.count {
            let e = events[index]
            let t = uiDouble(e["t"]) ?? 0
            if t > now { break }
            display.apply(e)
            index += 1
        }
        display.advance(to: now)
        // 流し終えても tick は続ける(質問箱の AFM の結果・読み返しの自動復帰を受け取るため)
        if index >= events.count, !finished, now > (events.last.flatMap { uiDouble($0["t"]) } ?? 0) + 2 {
            finished = true
            print("再生終了(最後の文は残します。⌘Q または Ctrl-C で終了)")
        }
    }
}

enum PanelApp {
    static func loadEvents(_ path: String) throws -> [Ev] {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var out: [Ev] = []
        for line in text.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let e = (try? JSONSerialization.jsonObject(with: d)) as? Ev else { continue }
            out.append(e)
        }
        return out
    }

    /// 表示の部品
    struct DisplayParts {
        let display: EventDisplay
        let root: AnyView
        var bindWindow: ((PanelWindow) -> Void)? = nil        // 窓ができたあとに1回呼ぶ(帯・質問箱の開閉)
        var controls: PanelControls? = nil                    // 帯のボタン。経路ごとに開始・ポーズ / 終了をつなぐ
    }

    @MainActor
    static func makeDisplay(_ ui: UIConfig, scale: PanelScale) -> DisplayParts {
        let m = FlowPanelModel(cfg: ui)
        m.scale = scale
        return DisplayParts(display: m, root: AnyView(FlowPanelView(model: m, scale: scale)),
                            bindWindow: { [weak m] w in
                                guard let m = m else { return }
                                FlowPanelModel.bind(m, to: w)
                            },
                            controls: m.controls)
    }

    /// 保存したイベントを実時間(×speed)で流してパネルに出す
    @MainActor
    static func runReplay(path: String, speed: Double, conf: JetConfig) async throws {
        let ui = conf.ui
        let events = try loadEvents(path)
        if events.isEmpty { throw AppError("イベントが読めません: \(path)") }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)   // Dock に出さない
        let scale = PanelScale()
        let parts = makeDisplay(ui, scale: scale)
        let display = parts.display
        let controller = PanelController(cfg: ui, scale: scale, root: parts.root)
        controller.attach(parts)
        controller.show()
        let driver = ReplayDriver(events: events, speed: speed, display: display)
        driver.start()
        print("パネルを表示しました(\(events.count) イベント、速度 \(speed)x)。パネルを一度クリックすると ⌘+ / ⌘− / ⌘Q が使えます")
        withExtendedLifetime((controller, driver, display)) {
            app.run()
        }
    }
}
