import AppKit
import SwiftUI

// 質問箱の見た目。流れ型パネルの左の列(音楽プレーヤーのサイドバー風)。同じ窓・同じ背景で、細い区切り線だけで分ける。
// 上から: 見出し + 口調(ビジネス / フランク)/ 拾った語 / 型(分類ごと)/ Q ボタン(白いカプセル)
// オン = 塗りのカプセル、オフ = 枠だけ。作った発言は列の先頭(カナ = 大・太 / 英語 / 日本語 = 小・薄、クリックで英語をコピー)
// 下に入力欄(言いたいこと。Enter で Q)と Q ボタン

enum QBoxLayout {
    static func width(_ k: Double) -> Double { 250 * k }
    static func minWidth(_ k: Double) -> Double { 170 * k }
    /// 境目のつかめる幅(線は中央に1pt)
    static let dividerWidth = 9.0
    /// (U4 までの)帯の右端の開閉ボタンの幅。いまは帯の左のボタン(PanelBar.swift の BarLayout)を使う
    static let toggleWidth = 40.0
}

/// 折り返して並べる(字幕の語・カプセル)。spacing = 横の間隔、lineSpacing = 行の間隔
struct WrapLayout: Layout {
    var spacing: Double = 0
    var lineSpacing: Double = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = Double(proposal.width ?? .infinity)
        var x = 0.0, y = 0.0, rowH = 0.0, widest = 0.0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            let w = Double(sz.width), h = Double(sz.height)
            if x > 0 && x + w > maxW {
                y += rowH + lineSpacing
                x = 0
                rowH = 0
            }
            widest = max(widest, x + w)
            x += w + spacing
            rowH = max(rowH, h)
        }
        return CGSize(width: min(widest, maxW), height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxW = Double(bounds.width)
        var x = 0.0, y = 0.0, rowH = 0.0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            let w = Double(sz.width), h = Double(sz.height)
            if x > 0 && x + w > maxW {
                y += rowH + lineSpacing
                x = 0
                rowH = 0
            }
            s.place(at: CGPoint(x: Double(bounds.minX) + x, y: Double(bounds.minY) + y), proposal: ProposedViewSize(sz))
            x += w + spacing
            rowH = max(rowH, h)
        }
    }
}

/// 字幕の1語。マウスを乗せると「拾える」と分かるよう、文字色を濃く(primary)・下線を太く・薄い下地(10/30)。
/// 拾った語はもっと濃いカプセル。配置が動かないよう、下地は外側にはみ出させる
struct QTokenView: View {
    let token: QToken
    let size: Double
    let weight: Font.Weight
    let color: Color
    let picked: Bool
    let k: Double
    let family: SubtitleFont
    let onTap: () -> Void
    @State private var hover = false

    init(token: QToken, size: Double, weight: Font.Weight, color: Color, picked: Bool, k: Double,
         family: SubtitleFont = .system, onTap: @escaping () -> Void) {
        self.token = token
        self.size = size
        self.weight = weight
        self.color = color
        self.picked = picked
        self.k = k
        self.family = family
        self.onTap = onTap
    }

    var body: some View {
        let pickable = !token.pick.isEmpty
        let hot = hover && pickable && !picked   // 拾える語にマウスが乗っている
        Text(token.display)
            .font(family.font(size: size, weight: weight))
            .foregroundColor(picked || hot ? Color.primary : color)
            // 下線: Text.underline は太さを変えられないので、下端に線を重ねる
            .overlay(alignment: .bottom) {
                if hot {
                    Rectangle()
                        .fill(Color.primary)
                        .frame(height: max(1.5, 1.5 * k))
                        .offset(y: -0.5 * k)
                }
            }
            .background(
                Capsule()
                    .fill(Color.accentColor.opacity(picked ? 0.32 : (hot ? 0.14 : 0)))
                    .padding(.horizontal, -3 * k)
                    .padding(.vertical, -1 * k)
            )
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture { if pickable { onTap() } }
    }
}

struct QBoxView: View {
    @ObservedObject var model: FlowPanelModel
    let k: Double
    @FocusState private var noteFocused: Bool

    init(model: FlowPanelModel, k: Double) {
        self.model = model
        self.k = k
    }

    var body: some View {
        let box = model.box
        VStack(alignment: .leading, spacing: 10 * k) {
            header
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16 * k) {
                        resultsSection.id("results")
                        picksSection(box)
                        ForEach(box.groups, id: \.self) { g in
                            section(g) {
                                WrapLayout(spacing: 6 * k, lineSpacing: 6 * k) {
                                    ForEach(box.templates.filter { $0.group == g }) { t in
                                        chip(t.label, on: box.templateOn.contains(t.id)) { model.toggleTemplate(t.id) }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2 * k)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.resultsToken) { _, _ in
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("results", anchor: .top) }
                }
            }
            noteField
            qButton
        }
        .padding(EdgeInsets(top: 0, leading: 14 * k, bottom: 12 * k, trailing: 12 * k))
        // 入力欄のカーソルを渡す(重ねて出した質問箱は、入力中なら窓から出ても閉じない。U4b)
        .onChange(of: noteFocused) { _, f in model.setNoteFocused(f) }
        .onDisappear { model.setNoteFocused(false) }
    }

    private var header: some View {
        HStack(spacing: 8 * k) {
            Text("質問箱")
                .font(.system(size: 15 * k, weight: .bold))
            Spacer(minLength: 4 * k)
            Picker("", selection: Binding(get: { model.box.tone }, set: { model.setTone($0) })) {
                Text("ビジネス").tag(QTone.business)
                Text("フランク").tag(QTone.casual)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 120 * k)
        }
    }

    // MARK: 作った発言(カナ = 大・太 / 英語 / 日本語 = 小・薄。クリックで英語をコピー)

    @ViewBuilder
    private var resultsSection: some View {
        if !model.results.isEmpty || model.afmPending || model.qError != nil {
            section("作った発言") {
                VStack(alignment: .leading, spacing: 8 * k) {
                    if model.afmPending {
                        HStack(spacing: 6 * k) {
                            ProgressView().controlSize(.small)
                            Text("AFM で作っています…")
                                .font(.system(size: 11 * k))
                                .foregroundColor(Color.secondary)
                        }
                    }
                    if let e = model.qError { notice(e, symbol: "exclamationmark.triangle.fill", tint: Color.orange) }
                    ForEach(model.results) { r in resultCard(r) }
                    if let h = model.kanaHint { notice(h, symbol: "info.circle.fill", tint: Color.accentColor) }
                }
            }
        }
    }

    /// 失敗・案内の文面。色の付いた薄い面の上に、本文はふつうの文字色(オレンジの文字だけでは背景と差が出にくいため)
    private func notice(_ text: String, symbol: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 7 * k) {
            Image(systemName: symbol)
                .foregroundColor(tint)
                .font(.system(size: 12 * k, weight: .semibold))
            Text(text)
                .foregroundColor(Color.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12 * k, weight: .medium))
        .padding(.horizontal, 10 * k)
        .padding(.vertical, 8 * k)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9 * k, style: .continuous).fill(tint.opacity(0.16)))
        .overlay(RoundedRectangle(cornerRadius: 9 * k, style: .continuous).strokeBorder(tint.opacity(0.55), lineWidth: 1))
    }

    private func resultCard(_ r: QResult) -> some View {
        let copied = model.copiedId == r.id
        return Button { model.copy(r) } label: {
            VStack(alignment: .leading, spacing: 3 * k) {
                if !r.kana.isEmpty {
                    Text(r.kana)
                        .font(.system(size: 16 * k, weight: .bold))
                        .foregroundColor(Color.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(r.en)
                    .font(.system(size: 13 * k))
                    .foregroundColor(Color.primary.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .firstTextBaseline, spacing: 6 * k) {
                    Text(r.ja)
                        .font(.system(size: 11 * k))
                        .foregroundColor(Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4 * k)
                    Text(copied ? "コピーしました" : (r.fromAFM ? "AFM" : "型"))
                        .font(.system(size: 10 * k, weight: copied ? .semibold : .regular))
                        .foregroundColor(copied ? Color.accentColor : Color.secondary.opacity(0.8))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10 * k)
            .background(RoundedRectangle(cornerRadius: 10 * k, style: .continuous)
                .fill(Color.primary.opacity(copied ? 0.1 : 0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("クリックで英語をコピー")
    }

    @ViewBuilder
    private func picksSection(_ box: QBox) -> some View {
        section("拾った語", trailing: box.picks.isEmpty ? nil : AnyView(
            Button("すべて消す") { model.clearPicks() }
                .buttonStyle(.plain)
                .font(.system(size: 11 * k))
                .foregroundColor(Color.secondary)
        )) {
            if box.picks.isEmpty {
                Text("字幕の語をクリックすると、ここに入ります(Shift+クリックでつなげる)")
                    .font(.system(size: 12 * k))
                    .foregroundColor(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                WrapLayout(spacing: 6 * k, lineSpacing: 6 * k) {
                    ForEach(box.picks) { p in
                        chip(p.text, on: p.on) { model.togglePick(p.id) }
                            .contextMenu { Button("削除") { model.removePick(p.id) } }
                    }
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, trailing: AnyView? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7 * k) {
            HStack {
                Text(title)
                    .font(.system(size: 11 * k, weight: .semibold))
                    .foregroundColor(Color.secondary)
                Spacer()
                if let t = trailing { t }
            }
            content()
        }
    }

    /// カプセル: オン = 塗り、オフ = 枠だけ
    private func chip(_ text: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 12 * k, weight: on ? .semibold : .regular))
                .foregroundColor(on ? Color(nsColor: .windowBackgroundColor) : Color.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 10 * k)
                .padding(.vertical, 5 * k)
                .background(Capsule().fill(on ? Color.primary.opacity(0.88) : Color.clear))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(on ? 0 : 0.28), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: 入力欄(言いたいこと)と Q ボタン

    /// Enter で Q と同じ。Esc で入力欄から抜ける(キーボードを手放す)。内容は作ったあとも残す(× で消す)
    private var noteField: some View {
        HStack(spacing: 6 * k) {
            TextField("言いたいこと(例: 今年度の平均は？)", text: $model.note)
                .textFieldStyle(.plain)
                .font(.system(size: 13 * k))
                .focused($noteFocused)
                .onSubmit { model.generate() }
                .onExitCommand { noteFocused = false }
            if !model.note.isEmpty {
                Button { model.note = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12 * k))
                        .foregroundColor(Color.secondary)
                }
                .buttonStyle(.plain)
                .help("入力欄を消す")
            }
        }
        .padding(.horizontal, 12 * k)
        .padding(.vertical, 7 * k)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(noteFocused ? 0.35 : 0.15), lineWidth: 1))
    }

    /// Q ボタン(再生ボタンのような白いカプセル)
    private var qButton: some View {
        Button { model.generate() } label: {
            HStack(spacing: 6 * k) {
                Image(systemName: "questionmark.bubble.fill")
                Text(model.afmPending ? "作っています…" : "質問を作る")
            }
            .font(.system(size: 13 * k, weight: .semibold))
            .foregroundColor(Color.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8 * k)
            .background(Capsule().fill(Color.white))
            .overlay(Capsule().strokeBorder(Color.black.opacity(0.08), lineWidth: 1))
            .shadow(color: Color.black.opacity(0.12), radius: 4 * k, y: 1 * k)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(model.afmPending)
        .opacity(model.afmPending ? 0.6 : 1)
        .help("オンの語・型・入力欄から発言を作る(Enter でも可)")
    }
}
