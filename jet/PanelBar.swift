import AppKit
import Combine
import SwiftUI

// U4: 窓の上端の帯の左に並ぶボタン(× / 開始・ポーズ / 質問箱のアイコン)と、質問箱の出し方(隠す / 重ねて表示 / 固定)。
// チャットアプリの左サイドバーのような動き(DESIGN-ui.md「窓の操作 (U4)」)
//   ×            : 完全終了。メニューの「終了」・⌘Q と同じ経路(聞き取りを止め、イベントを書き終えてから終了)。聞き取り中は2段階
//   開始・ポーズ : メニューバーのときだけ出す(メニューの「開始 / ポーズ」と同じ)
//   質問箱       : マウスを乗せる = 字幕の上に重ねて表示 / クリック = 固定(窓が左へ広がる)/ 固定中にクリック = 隠す
// × と 開始・ポーズは帯にマウスを乗せたときだけ出す。質問箱のアイコンはいつも出す(帯の外では薄く)

/// 帯のボタンの並び。窓(PanelWindow)の当たり判定と SwiftUI の見た目で同じ値を使う。帯は文字サイズで変えない
enum BarLayout {
    static let lead = 12.0        // 窓の左端からの余白
    static let slot = 26.0        // ボタン1つの幅
    static let gap = 2.0
    static let armedQuit = 80.0   // 「終了する?」に変わったときの × の幅
    static let trail = 6.0        // 並びの右の余白(ここまでは窓を動かさない)

    enum Slot: Equatable { case quit, run, box, gear }

    // 帯の右端: 歯車(U5a 表示の設定)。窓の右端からの距離で判定する
    static let rightTrail = 8.0   // 窓の右端からの余白
    /// 帯の右でボタンが占める幅(この幅は窓を動かさず、クリックを中身へ渡す)
    static var rightWidth: Double { rightTrail + slot + trail }

    /// 窓の右端からの距離 fromRight の位置が歯車か
    static func hitGear(fromRight: Double) -> Bool { fromRight >= rightTrail && fromRight <= rightTrail + slot }

    /// 各ボタンの x の範囲(窓の左からの距離)
    static func ranges(canRun: Bool, wide: Bool) -> [(slot: Slot, x: ClosedRange<Double>)] {
        var out: [(slot: Slot, x: ClosedRange<Double>)] = []
        var x = lead
        let qw = wide ? armedQuit : slot
        out.append((slot: .quit, x: x...(x + qw)))
        x += qw + gap
        if canRun {
            out.append((slot: .run, x: x...(x + slot)))
            x += slot + gap
        }
        out.append((slot: .box, x: x...(x + slot)))
        return out
    }

    /// 帯の左でボタンが占める幅(この幅は窓を動かさず、クリックを中身へ渡す)
    static func width(canRun: Bool, wide: Bool) -> Double {
        (ranges(canRun: canRun, wide: wide).last?.x.upperBound ?? 0) + trail
    }

    /// x の位置にあるボタン
    static func hit(x: Double, canRun: Bool, wide: Bool) -> Slot? {
        ranges(canRun: canRun, wide: wide).first { $0.x.contains(x) }?.slot
    }
}

/// × の2段階(純ロジック)。聞き取り中は1回目で「終了する?」に変わり、armTimeout 秒以内の2回目で終了。
/// ポーズ中・停止中は1回で終了
struct QuitGate: Equatable {
    static let armTimeout = 4.0
    private(set) var armedAt: Double? = nil
    var armed: Bool { armedAt != nil }

    /// true = 終了する
    mutating func press(listening: Bool, now: Double) -> Bool {
        if !listening {
            armedAt = nil
            return true
        }
        if let a = armedAt, now - a <= QuitGate.armTimeout {
            armedAt = nil
            return true
        }
        armedAt = now
        return false
    }

    mutating func cancel() { armedAt = nil }
}

/// 質問箱の出し方
enum QBoxMode: Equatable { case hidden, peek, pinned }

/// 質問箱の3段階(純ロジック)。隠す → アイコンに乗せる = 重ねて表示 → クリック = 固定
///   重ね表示を閉じるのは窓全体からマウスが出たとき。入力欄にカーソルがある・AFM が生成中なら閉じずに待つ
///   最初に語を拾ったときに自動で開くのは固定(重ね表示中に拾ったときはそのまま)
struct QBoxPresence: Equatable {
    private(set) var mode: QBoxMode = .hidden
    /// 重ね表示のまま窓から出たが、入力中・生成中だったので閉じずにいる
    private(set) var deferredClose = false

    /// アイコンにマウスが乗った(乗ったその時だけ呼ぶ)
    mutating func iconEntered() {
        guard mode == .hidden else { return }
        mode = .peek
        deferredClose = false
    }

    /// アイコンをクリック: 隠す・重ね表示 → 固定、固定 → 隠す
    mutating func iconClicked() {
        mode = mode == .pinned ? .hidden : .pinned
        deferredClose = false
    }

    /// 字幕の語を拾った: 隠していたら固定で開く
    mutating func picked() {
        if mode == .hidden { mode = .pinned }
    }

    mutating func pointerEntered() { deferredClose = false }

    mutating func pointerExited(busy: Bool) {
        guard mode == .peek else { return }
        if busy { deferredClose = true } else { mode = .hidden }
    }

    /// 入力欄から抜けた・窓がキーでなくなった。窓の外にいて閉じるのを待っていたら閉じる
    mutating func freed(pointerInside: Bool, busy: Bool) {
        guard mode == .peek, deferredClose, !pointerInside, !busy else { return }
        mode = .hidden
        deferredClose = false
    }

    /// AFM の案ができた: 結果を読めるよう、待っていた「閉じる」は取り消す(次に窓から出たときに閉じる)
    mutating func generated() { deferredClose = false }

    mutating func close() {
        mode = .hidden
        deferredClose = false
    }
}

/// 帯のボタンと、メニューバー / live / 再生 の各経路をつなぐ。経路ごとに onToggleRun・onQuit を設定する
@MainActor
final class PanelControls: ObservableObject {
    enum Run: Equatable { case idle, running, stopping }
    /// 聞き取りの状態(メニューバー: JetMenu.refresh、live: LivePanel が書く)
    @Published var run: Run = .idle
    /// 開始・ポーズのボタンを出すか(メニューバーのときだけ true)
    @Published var canRun = false
    @Published private(set) var gate = QuitGate()
    @Published private(set) var quitting = false
    var onToggleRun: (() -> Void)?
    /// 閉じると消える内容があるか(字幕・質問箱の入力・拾った語・作った発言・AFM 生成中。FlowPanelModel が設定)
    var hasContent: @MainActor () -> Bool = { false }
    /// app モード: 内容があるまま終了するときは警告を出す(JetMenu.quit)
    var warnsOnLoss = false
    var willWarn: Bool { warnsOnLoss && hasContent() }
    /// 完全終了の経路(聞き取りを止めてイベントを書き終えてから終了)。nil ならすぐ終了
    var onQuit: (() -> Void)?
    private var disarmTimer: Timer?

    var listening: Bool { run != .idle }
    /// × が広がっている(「終了する?」/「終了中…」)
    var wide: Bool { gate.armed || quitting }

    func pressQuit() {
        if quitting { return }
        // 警告を出すときは、その警告が確認になる(× の2段階は通さない)
        if willWarn { quitNow(); return }
        if gate.press(listening: listening, now: ProcessInfo.processInfo.systemUptime) {
            disarmTimer?.invalidate()
            disarmTimer = nil
            quitNow()
            return
        }
        // 「終了する?」は armTimeout 秒で元に戻す(タイマーはメインの run loop で動く)
        disarmTimer?.invalidate()
        disarmTimer = Timer.scheduledTimer(withTimeInterval: QuitGate.armTimeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.disarm() }
        }
    }

    func disarm() {
        disarmTimer?.invalidate()
        disarmTimer = nil
        if gate.armed { gate.cancel() }
    }

    /// 2段階を通さずに終了する(⌘Q)
    func quitNow() {
        if quitting { return }
        quitting = true
        if gate.armed { gate.cancel() }
        if let q = onQuit { q() } else { NSApp.terminate(nil) }
    }

    /// 警告で「キャンセル」されたとき、× を元に戻す
    func quitCancelled() {
        quitting = false
        disarm()
    }

    /// 帯の外(⌘Q・Ctrl-C)から終了が始まったときに、× を「終了中…」にする
    func noteQuitting() {
        quitting = true
        disarm()
    }

    func toggleRun() {
        guard run != .stopping else { return }
        onToggleRun?()
    }
}

/// 窓の中のマウスの位置を、アプリが前面になくても受け取る(SwiftUI の onHover は前面でない窓では来ないことがあるため)
final class PointerTracker: NSResponder {
    var onMove: ((NSEvent) -> Void)?
    var onExit: (() -> Void)?
    override func mouseEntered(with event: NSEvent) { onMove?(event) }
    override func mouseMoved(with event: NSEvent) { onMove?(event) }
    override func mouseExited(with event: NSEvent) { onExit?() }
}

/// 帯の左のボタンの並び。位置と幅は BarLayout と同じ(窓の当たり判定と合わせる)
struct PanelBarView: View {
    @ObservedObject var model: FlowPanelModel
    @ObservedObject var controls: PanelControls

    var body: some View {
        let show = model.barHover || controls.wide
        HStack(spacing: BarLayout.gap) {
            quitButton.opacity(show ? 1 : 0)
            if controls.canRun { runButton.opacity(show ? 1 : 0) }
            boxButton
        }
        .padding(.leading, BarLayout.lead)
        .frame(height: PanelWindow.dragBar)
        .animation(.easeOut(duration: 0.15), value: show)
        .animation(.easeOut(duration: 0.15), value: controls.wide)
    }

    private func hoverFill(_ s: BarLayout.Slot) -> Color {
        Color.primary.opacity(model.barSlot == s ? 0.12 : 0)
    }

    private var quitButton: some View {
        let wide = controls.wide
        return Button { controls.pressQuit() } label: {
            ZStack {
                if controls.quitting {
                    Text("終了中…")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color.secondary)
                } else if controls.gate.armed {
                    Text("終了する?")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color.white)
                        .frame(width: BarLayout.armedQuit - 4, height: 20)
                        .background(Capsule().fill(Color.red.opacity(0.85)))
                } else {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color.secondary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(hoverFill(.quit)))
                }
            }
            .frame(width: wide ? BarLayout.armedQuit : BarLayout.slot, height: PanelWindow.dragBar)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(controls.listening ? "終了(聞き取り中はもう一度押して終了)" : "終了")
    }

    private var runButton: some View {
        Button { controls.toggleRun() } label: {
            ZStack {
                switch controls.run {
                case .idle:
                    Image(systemName: "play.fill")
                case .running:
                    Image(systemName: "pause.fill")
                case .stopping:
                    ProgressView().controlSize(.mini)
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(controls.run == .running ? Color.primary : Color.secondary)
            .frame(width: 22, height: 22)
            .background(Circle().fill(hoverFill(.run)))
            .frame(width: BarLayout.slot, height: PanelWindow.dragBar)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(controls.run == .stopping)
        .help(controls.run == .idle ? "開始" : (controls.run == .running ? "ポーズ" : "止めています…"))
    }

    private var boxButton: some View {
        let mode = model.boxMode
        return Button { model.toggleBox() } label: {
            Image(systemName: mode == .pinned ? "bubble.left.and.text.bubble.right.fill" : "bubble.left.and.text.bubble.right")
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(mode == .hidden ? Color.secondary : Color.primary)
                .opacity(mode == .hidden && !model.barHover ? 0.6 : 1)
                .frame(width: 22, height: 22)
                .background(Circle().fill(hoverFill(.box)))
                .frame(width: BarLayout.slot, height: PanelWindow.dragBar)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(mode == .pinned ? "質問箱を隠す" : "質問箱(クリックで固定)")
    }
}

/// 帯の右端の歯車(U5a)。帯にマウスを乗せたとき・設定を開いているときだけ出す
struct PanelGearView: View {
    @ObservedObject var model: FlowPanelModel

    var body: some View {
        let open = model.settingsOpen
        let show = model.barHover || open
        Button { model.toggleSettings() } label: {
            Image(systemName: open ? "gearshape.fill" : "gearshape")
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(open ? Color.primary : Color.secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.primary.opacity(model.barSlot == .gear || open ? 0.12 : 0)))
                .frame(width: BarLayout.slot, height: PanelWindow.dragBar)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(show ? 1 : 0)
        .padding(.trailing, BarLayout.rightTrail)
        .frame(height: PanelWindow.dragBar)
        .animation(.easeOut(duration: 0.15), value: show)
        .help(open ? "設定を閉じる" : "表示の設定")
    }
}

// MARK: - 単体テスト(./jetcli --selftest)

enum BarSelftest {
    static func run() -> Bool {
        var fails = 0, total = 0
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            total += 1
            if !ok { fails += 1; print("NG  bar: \(name)  \(detail())") }
        }

        // 1. × の2段階
        do {
            var g = QuitGate()
            check("quit: 停止中は1回で終了", g.press(listening: false, now: 0) && !g.armed)
            check("quit: 聞き取り中の1回目は終了しない", !g.press(listening: true, now: 10) && g.armed)
            check("quit: 時間内の2回目で終了", g.press(listening: true, now: 12) && !g.armed)
            _ = g.press(listening: true, now: 20)
            check("quit: 時間切れなら2回目も「終了する?」に戻る", !g.press(listening: true, now: 20 + QuitGate.armTimeout + 0.1) && g.armed)
            g.cancel()
            check("quit: 取り消し", !g.armed)
            _ = g.press(listening: true, now: 30)
            check("quit: 「終了する?」の間にポーズしたら1回で終了", g.press(listening: false, now: 31))
        }

        // 2. 帯のボタンの並び
        do {
            let r = BarLayout.ranges(canRun: true, wide: false)
            check("bar: 並び × / 開始 / 質問箱", r.map { $0.slot } == [.quit, .run, .box], "\(r.map { $0.slot })")
            check("bar: × は左端から", r[0].x.lowerBound == BarLayout.lead)
            check("bar: 位置で判定", BarLayout.hit(x: BarLayout.lead + 1, canRun: true, wide: false) == .quit
                  && BarLayout.hit(x: r[2].x.lowerBound + 2, canRun: true, wide: false) == .box
                  && BarLayout.hit(x: 300, canRun: true, wide: false) == nil)
            let rw = BarLayout.ranges(canRun: true, wide: true)
            check("bar: 「終了する?」で右のボタンがずれる", rw[2].x.lowerBound - r[2].x.lowerBound == BarLayout.armedQuit - BarLayout.slot)
            check("bar: 開始のボタンなし(live・再生)", BarLayout.ranges(canRun: false, wide: false).map { $0.slot } == [.quit, .box])
            check("bar: 幅", BarLayout.width(canRun: false, wide: false) == BarLayout.lead + 2 * BarLayout.slot + BarLayout.gap + BarLayout.trail)
            check("bar: 右端の歯車", BarLayout.hitGear(fromRight: BarLayout.rightTrail + 1) && !BarLayout.hitGear(fromRight: 2)
                  && !BarLayout.hitGear(fromRight: BarLayout.rightTrail + BarLayout.slot + 1))
            check("bar: 歯車は右の当たり判定の幅に収まる", BarLayout.rightTrail + BarLayout.slot < BarLayout.rightWidth)
        }

        // 3. 質問箱の3段階
        do {
            var p = QBoxPresence()
            p.iconEntered()
            check("box: アイコンに乗せる → 重ね表示", p.mode == .peek)
            p.pointerExited(busy: false)
            check("box: 窓から出る → 隠す", p.mode == .hidden)
            p.iconEntered()
            p.iconClicked()
            check("box: 重ね表示でクリック → 固定", p.mode == .pinned)
            p.pointerExited(busy: false)
            p.iconEntered()
            check("box: 固定は窓から出ても・乗せても変わらない", p.mode == .pinned)
            p.iconClicked()
            check("box: 固定でクリック → 隠す", p.mode == .hidden)
            p.iconClicked()
            check("box: 隠しているときクリック → 固定", p.mode == .pinned)
            p.close()
            p.picked()
            check("box: 語を拾う(隠している)→ 固定", p.mode == .pinned)
            p.close()
            p.iconEntered()
            p.picked()
            check("box: 重ね表示中に拾っても重ね表示のまま", p.mode == .peek)
        }

        // 4. 入力中・生成中は閉じない
        do {
            var p = QBoxPresence()
            p.iconEntered()
            p.pointerExited(busy: true)
            check("busy: 入力中に窓から出ても閉じない", p.mode == .peek && p.deferredClose)
            p.freed(pointerInside: true, busy: false)
            check("busy: 窓の中で抜けたら閉じない", p.mode == .peek)
            p.freed(pointerInside: false, busy: false)
            check("busy: 窓の外で入力欄から抜けたら閉じる", p.mode == .hidden)
            p.iconEntered()
            p.pointerExited(busy: true)
            p.pointerEntered()
            p.freed(pointerInside: false, busy: false)
            check("busy: 一度戻ってきたら待ちは取り消し", p.mode == .peek && !p.deferredClose)
            p.pointerExited(busy: true)
            p.generated()
            p.freed(pointerInside: false, busy: false)
            check("busy: 案ができたら結果を読めるよう開いたまま", p.mode == .peek)
            p.pointerExited(busy: false)
            check("busy: 次に窓から出たら閉じる", p.mode == .hidden)
            p.iconEntered()
            p.pointerExited(busy: true)
            p.freed(pointerInside: false, busy: true)
            check("busy: まだ生成中なら閉じない", p.mode == .peek)
        }

        print("bar: \(total - fails) / \(total) 件OK")
        return fails == 0
    }
}
