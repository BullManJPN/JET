import AppKit
import SwiftUI

// U5a 表示の設定。帯の右端の歯車で開き、字幕の上・帯の下に右から重ねて出す。
// 別ウィンドウ(ポップオーバー・色パネル・メニュー)を使わないので、画面共有に映らない設定(sharingType = .none)がそのまま効く。
// 変えるとすぐ反映され、0.5秒後に自動で保存する(FlowPanelModel.look → LookStore)。
// 中の文字・余白は ⌘+ / ⌘− の倍率で変えない(帯と同じ)。k は角丸を窓に合わせるためだけに使う

struct SettingsPanelView: View {
    @ObservedObject var model: FlowPanelModel
    let k: Double
    @State private var lastEnPt = 13.0   // 英語を消す前の大きさ(もう一度出すときに戻す)
    @State private var listOpen = false  // 質問箱の型の一覧を広げている

    init(model: FlowPanelModel, k: Double) {
        self.model = model
        self.k = k
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    densitySection
                    modeSection
                    fontSection
                    sizeSection
                    templateSection
                    footer
                }
                .padding(EdgeInsets(top: 4, leading: 16, bottom: 16, trailing: 16))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            ZStack {
                shape.fill(.regularMaterial)
                shape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.55))
            }
            .shadow(color: Color.black.opacity(0.22), radius: 10, x: -3)
        )
        .overlay(shape.stroke(Color.primary.opacity(0.1), lineWidth: 1))
        .contentShape(Rectangle())
    }

    /// 右上は帯に接するので角を付けない。右下は窓の角丸に合わせる
    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12,
                               bottomTrailingRadius: 14 * k, topTrailingRadius: 0, style: .continuous)
    }

    private var header: some View {
        HStack {
            Text("表示の設定")
                .font(.system(size: 14, weight: .bold))
            Spacer()
            Button { model.closeSettings() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("閉じる")
        }
        .padding(EdgeInsets(top: 10, leading: 16, bottom: 8, trailing: 10))
    }

    // MARK: 各項目

    private var densitySection: some View {
        let d = model.look.density
        return section("背景の濃さ") {
            HStack(spacing: 8) {
                Image(systemName: "circle.dotted")
                Slider(value: binding(\.density, step: 0.01), in: LookValues.densityRange)
                Image(systemName: "circle.fill")
                Text("\(Int((d * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(width: 38, alignment: .trailing)
            }
            .font(.system(size: 12))
            .foregroundColor(Color.secondary)
            note(d < LookValues.defaultDensity ? "薄くすると、字幕に縁取りが付きます(共有スライドに重ねて見る用)"
                 : (abs(d - LookValues.defaultDensity) < 0.005 ? "60% がいままでの見た目です" : "濃くすると、後ろが透けにくくなります"))
        }
    }

    private var modeSection: some View {
        section("外観") {
            Picker("", selection: Binding(get: { model.look.mode }, set: { m in update { $0.mode = m } })) {
                ForEach(LookMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var fontSection: some View {
        section("字幕のフォント") {
            VStack(spacing: 2) {
                ForEach(SubtitleFont.allCases, id: \.self) { f in fontRow(f) }
            }
        }
    }

    private func fontRow(_ f: SubtitleFont) -> some View {
        let on = model.look.font == f
        return Button { update { $0.font = f } } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .opacity(on ? 1 : 0)
                Text(f.label)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text("字幕 Aa")
                    .font(f.font(size: 14, weight: .regular))
                    .foregroundColor(Color.secondary)
            }
            .foregroundColor(Color.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(on ? 0.1 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var sizeSection: some View {
        let showEn = model.look.flowEnPt > 0
        return section("文字の大きさ") {
            sizeRow("日本語", value: binding(\.flowPt, step: 1), range: LookValues.flowPtRange)
            Toggle(isOn: Binding(get: { model.look.flowEnPt > 0 }, set: { on in
                if !on { lastEnPt = model.look.flowEnPt }
                let back = min(max(lastEnPt, LookValues.flowEnPtRange.lowerBound), LookValues.flowEnPtRange.upperBound)
                update { $0.flowEnPt = on ? back : 0 }
            })) {
                Text("もとの英語も出す").font(.system(size: 12))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            if showEn {
                sizeRow("英語", value: binding(\.flowEnPt, step: 1), range: LookValues.flowEnPtRange)
            }
            note("⌘+ / ⌘− の拡大はその場だけのもので、この大きさに掛け算されます")
        }
    }

    // MARK: 質問箱の型(U5b)

    private var templateSection: some View {
        let r = model.templateReport
        return section("質問箱の型(\(r.templates.count) 件)") {
            HStack(spacing: 8) {
                capsule("ファイルを開く", enabled: true) { model.openTemplateFile() }
                capsule("再読み込み", enabled: true) { model.reloadTemplates() }
            }
            if let e = model.templateError { warning(e) }
            ForEach(r.problems, id: \.self) { warning($0) }
            note("TextEdit で開きます。保存してからこの窓に戻ると自動で読み直します。最初に開くときは同梱の型をコピーします。同梱の型に戻すには、そのファイルを消してください\n\((model.templatePath as NSString).abbreviatingWithTildeInPath)")
            Button { listOpen.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: listOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                    Text(listOpen ? "一覧を閉じる" : "一覧を見る")
                        .font(.system(size: 12))
                }
                .foregroundColor(Color.primary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if listOpen { templateList }
        }
    }

    private var templateList: some View {
        let box = model.box
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(box.groups, id: \.self) { g in
                VStack(alignment: .leading, spacing: 6) {
                    Text(g)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color.secondary)
                    ForEach(box.templates.filter { $0.group == g }) { t in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(t.label).font(.system(size: 12, weight: .medium))
                            Text("ビジネス  " + t.bizEn)
                            Text("フランク  " + t.casEn)
                        }
                        .font(.system(size: 11))
                        .foregroundColor(Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(.top, 2)
    }

    private func warning(_ s: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(Color.orange)
            Text(s)
                .foregroundColor(Color.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack(spacing: 8) {
                capsule("初期値に戻す", enabled: model.look != model.lookBase) { model.resetLook() }
                capsule("詳細設定(jet.json)", enabled: true) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: JetPaths.settingsFile(explicit: nil)))
                }
            }
            note("変えるとすぐ反映され、自動で保存されます。認識・翻訳の調整は詳細設定で")
        }
    }

    // MARK: 部品

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color.secondary)
            content()
        }
    }

    private func note(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 11))
            .foregroundColor(Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func sizeRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .frame(width: 40, alignment: .leading)
            Slider(value: value, in: range)
            Text("\(Int(value.wrappedValue.rounded())) pt")
                .monospacedDigit()
                .foregroundColor(Color.secondary)
                .frame(width: 42, alignment: .trailing)
        }
        .font(.system(size: 12))
    }

    private func capsule(_ title: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.18), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }

    /// 見た目の値を1つ変える(同じ値なら何もしない = 保存の予約もしない)
    private func update(_ f: (inout LookValues) -> Void) {
        var l = model.look
        f(&l)
        if l != model.look { model.look = l }
    }

    /// スライダー用。step 刻みに丸めてから入れる(動かすたびの更新を減らす)
    private func binding(_ kp: WritableKeyPath<LookValues, Double>, step: Double) -> Binding<Double> {
        Binding(get: { model.look[keyPath: kp] },
                set: { v in
                    let r = (v / step).rounded() * step
                    update { $0[keyPath: kp] = r }
                })
    }
}
