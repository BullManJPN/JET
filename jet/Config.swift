import Foundation

struct AppError: Error, CustomStringConvertible {
    let description: String
    init(_ s: String) { description = s }
}

struct Cfg {
    var K = 2
    var holdLast = 0
    var minClause = 4
    var maxClause = 14
    var earlyAfter = 8.0
    var correct = true
    var coalesce = 0.3
    var lookConj: Set<String> = []   // 次の語が主語らしいときだけ閉じる接続詞(jet.json look_conj)
    var keepConj: Set<String> = []   // 閉じない接続詞(keep_conj)
    var smartMax = false             // 上限で切るとき前置詞・冠詞などの手前で切る(smart_max)
    var lookSubj: Set<String>? = nil // look_conj の後に来たら閉じる語(look_subj。nil なら SUBJ)
    var softMax = 0                  // maxClause を超えても、この語数までは句読点を待つ(soft_max)
    var holdUnknown = 0.0   // 辞書にない語の確定を待つ最長秒数(0 = 待たない)。sim/core.py の hold_unknown
}

struct JetConfig {
    var cfg = Cfg()
    var terms = "asr/terms.txt"
    var aliases = "asr/term_aliases.tsv"
    var vocab = "asr/vocab.txt"
    var fuzzy = 0.84
    var draftEnabled = true
    var draftSystem = "prompts/draft_system.txt"
    var draftFewshot = ""          // 空 = 例文なし(方針: 例文は使わない)
    var draftUser = "prompts/draft_user.txt"
    var guardEnRatio = 0.6
    var draftGreedy = false     // 下書きの生成を決定的に(毎回同じ入力に同じ訳)
    var draftMaxTokens = 0      // 下書きの出力の上限トークン(0 = 上限なし)
    var eventsDir = "logs"
    var keepLogs = JetPaths.keepsLogs   // false(app モード)ならイベント・認識ログをファイルに書かない
    var asrLocale = "en-US"
    var asrPrepare = true
    var ui = UIConfig()

    /// JSON ファイルを辞書で読む
    private static func readObject(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError("設定ファイルの形式が不正です: \(path)")
        }
        return o
    }

    /// base に over を重ねる。辞書は項目ごとに重ね、それ以外(数・文字・配列)は over で置き換える
    static func mergeJSON(_ base: [String: Any], _ over: [String: Any]) -> [String: Any] {
        var out = base
        for (k, v) in over {
            if let a = out[k] as? [String: Any], let b = v as? [String: Any] { out[k] = mergeJSON(a, b) } else { out[k] = v }
        }
        return out
    }

    /// path が nil なら、同梱の jet.json にユーザーの設定(JetPaths.userConfig。変えた項目だけ)を重ねる。
    /// 指定があればそのファイルだけを読む(シェルの cwd からの相対)
    static func load(_ path: String?) throws -> JetConfig {
        let o: [String: Any]
        if let p = path {
            o = try readObject(p)
        } else {
            let basePath = JetPaths.resources + "/jet.json"
            var base = try readObject(basePath)
            let user = JetPaths.userConfig
            if user != basePath, FileManager.default.fileExists(atPath: user) {
                base = mergeJSON(base, try readObject(user))
            }
            o = base
        }
        var c = JetConfig()
        func num(_ d: [String: Any], _ k: String) -> Double? { (d[k] as? NSNumber)?.doubleValue }
        func str(_ d: [String: Any], _ k: String) -> String? { d[k] as? String }
        func bool(_ d: [String: Any], _ k: String) -> Bool? { d[k] as? Bool }
        if let v = num(o, "K") { c.cfg.K = Int(v) }
        if let v = num(o, "hold_last") { c.cfg.holdLast = Int(v) }
        if let v = num(o, "min_clause") { c.cfg.minClause = Int(v) }
        if let v = num(o, "max_clause") { c.cfg.maxClause = Int(v) }
        if let v = num(o, "early_after") { c.cfg.earlyAfter = v }
        if let v = bool(o, "correct") { c.cfg.correct = v }
        if let v = num(o, "coalesce_ms") { c.cfg.coalesce = v / 1000.0 }
        if let v = num(o, "hold_unknown_s") { c.cfg.holdUnknown = v }
        if let v = o["look_conj"] as? [String] { c.cfg.lookConj = Set(v) }
        if let v = o["keep_conj"] as? [String] { c.cfg.keepConj = Set(v) }
        if let v = bool(o, "smart_max") { c.cfg.smartMax = v }
        if let v = o["look_subj"] as? [String] { c.cfg.lookSubj = Set(v) }
        if let v = num(o, "soft_max") { c.cfg.softMax = Int(v) }
        if let v = str(o, "vocab") { c.vocab = v }
        if let v = str(o, "terms") { c.terms = v }
        if let v = str(o, "aliases") { c.aliases = v }
        if let v = num(o, "fuzzy_threshold") { c.fuzzy = v }
        if let v = str(o, "events_dir") { c.eventsDir = v }
        if let d = o["ui"] as? [String: Any] { c.ui = UIConfig(json: d) }
        if let d = o["asr"] as? [String: Any] {
            if let v = str(d, "locale") { c.asrLocale = v }
            if let v = bool(d, "prepare") { c.asrPrepare = v }
        }
        if let d = o["draft"] as? [String: Any] {
            if let v = bool(d, "enabled") { c.draftEnabled = v }
            if let v = str(d, "system") { c.draftSystem = v }
            if let v = str(d, "fewshot") { c.draftFewshot = v }
            if let v = str(d, "user") { c.draftUser = v }
            if let v = num(d, "guard_en_ratio") { c.guardEnRatio = v }
            if let v = bool(d, "greedy") { c.draftGreedy = v }
            if let v = num(d, "max_tokens") { c.draftMaxTokens = Int(v) }
        }
        c.resolvePaths()
        return c
    }

    /// 設定の相対パスを実ファイルにする(JetPaths.resolve)。terms / aliases は support と同梱を合算して読むので、そのまま残す
    mutating func resolvePaths() {
        vocab = JetPaths.resolve(vocab)
        draftSystem = JetPaths.resolve(draftSystem)
        draftFewshot = JetPaths.resolve(draftFewshot)
        draftUser = JetPaths.resolve(draftUser)
        eventsDir = JetPaths.writable(eventsDir)
        ui.resolvePaths()
    }
}
