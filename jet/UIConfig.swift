import Foundation

// 画面の設定(jet.json の "ui")と、イベントを読む小さな道具。

struct UIConfig {
    var panelWidth = 536.0     // 最初に開くときの幅(以後は窓の大きさを記録して使う)
    var panelHeight = 640.0    // 最初に開くときの高さ
    // flow(流れ型): 節ごとの下書きだけを積み上げる。最終訳では差し替えない
    var flowPt = 19.0          // 文字サイズ(全部の行で同じ。行の組み直しを避けるため変えない)
    var flowKeep = 60          // 残す行数
    var flowFade = 6           // 何行かけて flow_min_opacity まで薄くするか
    var flowMinOpacity = 0.2   // いちばん薄いときの濃さ
    var qboxTemplates = "prompts/qbox_templates.tsv"   // 質問箱の型(TSV)
    var qboxSystem = "prompts/qbox_system.txt"         // 質問箱の AFM の指示
    var qboxUser = "prompts/qbox_user.txt"             // 質問箱の AFM に渡す材料の書式
    var qboxJaSystem = "prompts/draft_system.txt"      // 質問箱の英語 → 日本語(字幕の下書き訳と同じ)
    var qboxJaUser = "prompts/draft_user.txt"
    var kanaDict = "asr/cmudict.dict"                  // カナ用の発音辞書(CMUdict)
    var flowIdleS = 10.0       // 読み返し中、何も触らずにこの秒数たったら最新へ戻る(0 = 自動では戻らない)
    var flowEnPt = 13.0        // 日本語の下に出す英語の文字サイズ(0 = 英語を出さない)
    // U5a 設定パネルで変える見た目(Appearance.swift の LookValues)
    var bgDensity = LookValues.defaultDensity   // 背景の濃さ 0.1〜1.0(0.6 = すりガラスだけ)
    var appearance = "system"  // system / light / dark
    var font = "system"        // 字幕の本文のフォント(SubtitleFont)

    init() {}

    /// 相対パスを実ファイルにする(JetPaths.resolve)
    mutating func resolvePaths() {
        qboxTemplates = JetPaths.resolve(qboxTemplates)
        qboxSystem = JetPaths.resolve(qboxSystem)
        qboxUser = JetPaths.resolve(qboxUser)
        qboxJaSystem = JetPaths.resolve(qboxJaSystem)
        qboxJaUser = JetPaths.resolve(qboxJaUser)
        kanaDict = JetPaths.resolve(kanaDict)
    }

    /// jet.json の "ui" から読む。無い項目は既定値
    init(json d: [String: Any]) {
        if let v = uiDouble(d["panel_width"]) { panelWidth = v }
        if let v = uiDouble(d["panel_height"]) { panelHeight = v }
        if let v = uiDouble(d["flow_pt"]) { flowPt = v }
        if let v = uiInt(d["flow_keep"]) { flowKeep = v }
        if let v = uiInt(d["flow_fade"]) { flowFade = v }
        if let v = uiDouble(d["flow_min_opacity"]) { flowMinOpacity = v }
        if let v = uiDouble(d["flow_idle_s"]) { flowIdleS = v }
        if let v = d["qbox_templates"] as? String { qboxTemplates = v }
        if let v = d["qbox_system"] as? String { qboxSystem = v }
        if let v = d["qbox_user"] as? String { qboxUser = v }
        if let v = d["qbox_ja_system"] as? String { qboxJaSystem = v }
        if let v = d["qbox_ja_user"] as? String { qboxJaUser = v }
        if let v = d["kana_dict"] as? String { kanaDict = v }
        if let v = uiDouble(d["flow_en_pt"]) { flowEnPt = v }
        if let v = uiDouble(d["bg_density"]) { bgDensity = v }
        if let v = d["appearance"] as? String { appearance = v }
        if let v = d["font"] as? String { font = v }
    }
}

// MARK: - 小さな道具

func uiDouble(_ v: Any?) -> Double? {
    if let d = v as? Double { return d }
    if let i = v as? Int { return Double(i) }
    if let n = v as? NSNumber { return n.doubleValue }
    return nil
}

func uiInt(_ v: Any?) -> Int? {
    if let i = v as? Int { return i }
    if let d = v as? Double { return Int(d) }
    if let n = v as? NSNumber { return n.intValue }
    return nil
}

/// 下書きの末尾の「。」「．」(と空白)を除く
func uiStripPeriod(_ s: String) -> String {
    var t = Substring(s)
    while let last = t.last, last == "。" || last == "．" || last == " " || last == "\n" || last == "\t" || last == "\u{3000}" {
        t = t.dropLast()
    }
    return String(t)
}
