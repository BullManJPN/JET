import AppKit
import SwiftUI

// U5a: 見た目の設定(背景の濃さ・外観・フォント・文字サイズ)。設定パネル(SettingsPanel.swift)で変え、すぐ画面に反映する。
// 保存は「変えた項目だけ」を jet.json の "ui" に書く(差分方式)。既定値は同梱の jet.json(Terminal 運用は <リポジトリのルート>/jet.json)
//   .app       … ~/Library/Application Support/JET/jet.json
//   Terminal   … <リポジトリのルート>/jet.user.json(git の管理外。手で整えた jet.json を書き直さないため)

/// 外観(明るい / 暗い)。自動 = システムに合わせる
enum LookMode: String, CaseIterable, Equatable {
    case system, light, dark

    var label: String {
        switch self {
        case .system: return "自動"
        case .light: return "明るい"
        case .dark: return "暗い"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// 字幕の本文のフォント(ボタンなどは変えない)。日本語と英語の両方が入るものだけ
enum SubtitleFont: String, CaseIterable, Equatable {
    case system
    case hiraginoSans = "hiragino_sans"
    case hiraginoMaru = "hiragino_maru"
    case hiraginoMincho = "hiragino_mincho"
    case rounded

    var label: String {
        switch self {
        case .system: return "システム"
        case .hiraginoSans: return "ヒラギノ角ゴ"
        case .hiraginoMaru: return "ヒラギノ丸ゴ"
        case .hiraginoMincho: return "ヒラギノ明朝"
        case .rounded: return "SF Rounded(英字が丸い)"
        }
    }

    /// 字幕で使う太さは regular(古い行)と semibold(いちばん新しい行)だけ
    func font(size: Double, weight: Font.Weight) -> Font {
        let bold = weight != .regular
        switch self {
        case .system: return .system(size: size, weight: weight)
        case .rounded: return .system(size: size, weight: weight, design: .rounded)
        case .hiraginoSans: return .custom(bold ? "HiraginoSans-W6" : "HiraginoSans-W3", size: size)
        case .hiraginoMaru: return .custom("HiraMaruProN-W4", size: size)
        case .hiraginoMincho: return .custom(bold ? "HiraMinProN-W6" : "HiraMinProN-W3", size: size)
        }
    }
}

/// 見た目の値(純ロジック。selftest で試す)
struct LookValues: Equatable {
    /// 背景の濃さ 0.1〜1.0。0.6 = いままでの見た目(すりガラスだけ)。下げるとすりガラスが薄くなり、上げると色の膜が重なる
    var density = LookValues.defaultDensity
    var mode: LookMode = .system
    var font: SubtitleFont = .system
    var flowPt = 19.0      // 日本語の文字サイズ
    var flowEnPt = 13.0    // 英語の文字サイズ(0 = 出さない)

    static let defaultDensity = 0.6
    static let densityRange = 0.1...1.0   // 下限: 窓が見えなくなってつかめなくなるのを防ぐ
    static let flowPtRange = 12.0...36.0
    static let flowEnPtRange = 9.0...24.0
    /// jet.json の "ui" のキー(この5つだけを設定パネルが書く)
    static let keys = ["bg_density", "appearance", "font", "flow_pt", "flow_en_pt"]

    init() {}

    init(ui: UIConfig) {
        density = min(max(ui.bgDensity, LookValues.densityRange.lowerBound), LookValues.densityRange.upperBound)
        mode = LookMode(rawValue: ui.appearance) ?? .system
        font = SubtitleFont(rawValue: ui.font) ?? .system
        flowPt = ui.flowPt
        flowEnPt = ui.flowEnPt
    }

    var json: [String: Any] {
        ["bg_density": (density * 100).rounded() / 100, "appearance": mode.rawValue, "font": font.rawValue,
         "flow_pt": flowPt, "flow_en_pt": flowEnPt]
    }

    // 背景の2枚重ね: すりガラス(material)と色の膜(窓の背景色)。0.6 を境に、下はすりガラスを薄く、上は膜を濃く
    static func materialOpacity(_ d: Double) -> Double {
        d >= defaultDensity ? 1.0 : max(0, d / defaultDensity)
    }

    static func tintOpacity(_ d: Double) -> Double {
        d <= defaultDensity ? 0 : min(1, (d - defaultDensity) / (1.0 - defaultDensity)) * 0.85
    }

    /// 文字の影(縁取り)の強さ 0〜1。背景を薄くしたぶんだけ強くして、下のスライドなどに重ねても読めるようにする
    static func haloStrength(_ d: Double) -> Double {
        d >= defaultDensity ? 0 : min(1, (defaultDensity - d) / (defaultDensity - densityRange.lowerBound))
    }
}

enum LookStore {
    /// パネルが保存するファイル
    static var userPath: String { JetPaths.userConfig }

    /// 既定値 = 同梱の jet.json の "ui"(パネルの「初期値に戻す」もこれ)
    static func base() -> LookValues {
        let p = JetPaths.resources + "/jet.json"
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: p)),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return LookValues() }
        return LookValues(ui: UIConfig(json: o["ui"] as? [String: Any] ?? [:]))
    }

    /// user(保存先の中身)に v を書き込んだ結果。既定値と同じ項目は消す(差分だけ残す)。ほかのキーはそのまま(純ロジック)
    static func merged(user: [String: Any], _ v: LookValues, base: LookValues) -> [String: Any] {
        var out = user
        var ui = user["ui"] as? [String: Any] ?? [:]
        let now = v.json, def = base.json
        for k in LookValues.keys {
            if let a = now[k], let b = def[k], "\(a)" == "\(b)" {
                ui.removeValue(forKey: k)
            } else {
                ui[k] = now[k]
            }
        }
        if ui.isEmpty { out.removeValue(forKey: "ui") } else { out["ui"] = ui }
        return out
    }

    /// 保存する。保存先が読めない(手で書き換えて形式が崩れている)ときは上書きしない
    @discardableResult
    static func save(_ v: LookValues, base: LookValues) -> Bool {
        let fm = FileManager.default
        var user: [String: Any] = [:]
        if fm.fileExists(atPath: userPath) {
            guard let d = try? Data(contentsOf: URL(fileURLWithPath: userPath)),
                  let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
                AppLog.note("設定を保存できない(保存先の形式が不正)")
                fputs("設定を保存できません(形式が不正): \(userPath)\n", stderr)
                return false
            }
            user = o
        }
        let out = merged(user: user, v, base: base)
        guard let data = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return false }
        try? fm.createDirectory(atPath: (userPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        do {
            try (data + Data("\n".utf8)).write(to: URL(fileURLWithPath: userPath), options: .atomic)
            return true
        } catch {
            AppLog.note("設定を保存できない: \(AppLog.kind(error))")
            return false
        }
    }
}

/// 背景を薄くしたときの文字の縁取り(背景色の影を2重に)。強さ 0 なら何もしない。
/// 1かたまり(日本語 + 英語)をまとめて描いてから影を付ける(語ごとに影を描くと重い)
struct SubtitleHalo: ViewModifier {
    let strength: Double
    let k: Double

    @ViewBuilder
    func body(content: Content) -> some View {
        if strength <= 0 {
            content
        } else {
            let c = Color(nsColor: .windowBackgroundColor)
            content
                .compositingGroup()
                .shadow(color: c.opacity(0.95 * strength), radius: (1.0 + 1.5 * strength) * k)
                .shadow(color: c.opacity(0.7 * strength), radius: (2.5 + 3.0 * strength) * k)
        }
    }
}

// MARK: - 単体テスト(./jetcli --selftest)

enum LookSelftest {
    static func run() -> Bool {
        var fails = 0, total = 0
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            total += 1
            if !ok { fails += 1; print("NG  look: \(name)  \(detail())") }
        }
        let d0 = LookValues.defaultDensity
        check("濃さ: 既定はいままでの見た目(すりガラスだけ・膜なし・縁取りなし)",
              LookValues.materialOpacity(d0) == 1 && LookValues.tintOpacity(d0) == 0 && LookValues.haloStrength(d0) == 0)
        check("濃さ: 下限ですりガラスは薄く残り、縁取りは最大",
              LookValues.materialOpacity(0.1) > 0.1 && LookValues.materialOpacity(0.1) < 0.2 && LookValues.haloStrength(0.1) == 1)
        check("濃さ: 上限で膜は 0.85", abs(LookValues.tintOpacity(1.0) - 0.85) < 1e-9 && LookValues.materialOpacity(1.0) == 1)
        check("濃さ: 薄くするほど縁取りが強い", LookValues.haloStrength(0.3) > LookValues.haloStrength(0.5))

        var v = LookValues()
        v.density = 0.35
        v.mode = .dark
        v.font = .hiraginoMaru
        v.flowPt = 24
        v.flowEnPt = 0
        let back = LookValues(ui: UIConfig(json: v.json))
        check("保存した値を読み直すと同じ", back == v, "\(back)")
        var low = UIConfig()
        low.bgDensity = 0.0
        check("読み込み: 濃さは下限で止める", LookValues(ui: low).density == LookValues.densityRange.lowerBound)
        check("読み込み: 知らない値は既定", LookValues(ui: UIConfig(json: ["appearance": "purple", "font": "x"])) == LookValues())

        let base = LookValues()
        var w = base
        w.flowPt = 22
        let m1 = LookStore.merged(user: ["K": 3, "ui": ["panel_width": 600, "font": "rounded"]], w, base: base)
        let ui1 = m1["ui"] as? [String: Any] ?? [:]
        check("差分: 変えた項目だけ書く", (ui1["flow_pt"] as? Double) == 22 && ui1["bg_density"] == nil && ui1["appearance"] == nil, "\(ui1)")
        check("差分: 既定に戻した項目は消す", ui1["font"] == nil, "\(ui1)")
        check("差分: ほかのキーは残す", (m1["K"] as? Int) == 3 && (ui1["panel_width"] as? Int) == 600, "\(m1)")
        let m2 = LookStore.merged(user: ["ui": ["flow_pt": 22]], base, base: base)
        check("差分: 全部既定なら ui ごと消す", m2["ui"] == nil, "\(m2)")

        print("look: \(total - fails) / \(total) 件OK")
        return fails == 0
    }
}
