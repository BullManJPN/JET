import Foundation
import NaturalLanguage

// 質問箱の純ロジック(Selftest で試せる部分)。字幕の語をクリックで拾い、よく使う型と組み合わせて質問を作る。
// 質問を作る部分は段階 (3)(型への差し込み)と (4)(AFM の自然な案)。見た目は QBoxPanel.swift / FlowPanel.swift

enum QLang: String { case en, ja }
enum QTone: String { case business, casual }

/// 字幕の1語。display = 画面に出す文字(句読点込み)、pick = 拾ったときの語(空 = 拾えない)
struct QToken: Equatable {
    var display: String
    var pick: String
}

enum QTokenizer {
    /// 日本語(かな・漢字)を含むか
    static func hasJapanese(_ s: String) -> Bool {
        s.unicodeScalars.contains {
            (0x3040...0x30FF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value)
        }
    }

    /// 拾う語の前後から外す記号(5% / Wi-Fi / don't はそのまま残る)
    private static let enTrim = CharacterSet(charactersIn: ",.;:!?\"()[]{}“”‘’…").union(.whitespacesAndNewlines)
    private static let jaTrim = CharacterSet(charactersIn: "、。，．,.!?！？「」『』（）()…・：:;；\"“”").union(.whitespacesAndNewlines)

    /// 英語: 空白で区切る
    static func en(_ s: String) -> [QToken] {
        s.split(whereSeparator: { $0 == " " || $0 == "\n" }).map { w in
            let d = String(w)
            return QToken(display: d, pick: d.trimmingCharacters(in: enTrim))
        }
    }

    /// 日本語: NLTokenizer の語。語と語の間(句読点・記号)は前の語の表示に付ける。表示をつなげると元の文に戻る
    static func ja(_ s: String) -> [QToken] {
        let tok = NLTokenizer(unit: .word)
        tok.string = s
        var out: [QToken] = []
        var cursor = s.startIndex
        func addGap(_ g: String) {
            if g.isEmpty { return }
            if out.isEmpty { out.append(QToken(display: g, pick: "")) } else { out[out.count - 1].display += g }
        }
        tok.enumerateTokens(in: s.startIndex..<s.endIndex) { r, _ in
            if cursor < r.lowerBound { addGap(String(s[cursor..<r.lowerBound])) }
            out.append(QToken(display: String(s[r]), pick: ""))
            cursor = r.upperBound
            return true
        }
        if cursor < s.endIndex { addGap(String(s[cursor...])) }
        // 拾う語 = 表示から前後の句読点を外したもの(5 + % のように記号が後ろに付いた語も「5%」で拾える)
        for i in out.indices { out[i].pick = out[i].display.trimmingCharacters(in: jaTrim) }
        return out
    }

    static func auto(_ s: String) -> [QToken] { hasJapanese(s) ? ja(s) : en(s) }

    /// 続く語をつなげる(英語は空白、日本語は表示をそのままつなげて前後の句読点だけ外す)
    static func join(_ toks: ArraySlice<QToken>, lang: QLang) -> String {
        switch lang {
        case .en: return toks.map { $0.pick }.filter { !$0.isEmpty }.joined(separator: " ")
        case .ja: return toks.map { $0.display }.joined().trimmingCharacters(in: jaTrim)
        }
    }
}

/// 質問箱の型(prompts/qbox_templates.tsv の1行)。___ = 拾った語が入る場所
struct QTemplate: Equatable, Identifiable {
    let id: String
    let group: String
    let slot: Bool
    let ja: String
    let bizEn: String
    let bizKana: String
    let casEn: String
    let casKana: String

    /// 画面の見出し(___ を 〇〇 に)
    var label: String { ja.replacingOccurrences(of: "___", with: "〇〇") }

    static func parse(_ text: String) -> [QTemplate] { report(text).templates }

    /// 読み込みの結果。使えなかった行・id の重複・差し込み用なのに ___ が無い型を、設定パネルで知らせるために数える(U5b)
    struct Report: Equatable {
        var templates: [QTemplate] = []
        var skippedLines: [Int] = []      // 列が8つに足りず使えなかった行(1 始まり)
        var duplicateIds: [String] = []   // id が重なった型(最初の行だけ使う)
        var slotMissing: [String] = []    // slot = 1 なのに ___ が日本語・英語(ビジネス・フランク)のどれかに無い型

        var hasProblem: Bool { !skippedLines.isEmpty || !duplicateIds.isEmpty || !slotMissing.isEmpty }

        /// 設定パネルに出す文面(何が起きたか + どうなるか)
        var problems: [String] {
            var out: [String] = []
            if !skippedLines.isEmpty {
                let shown = skippedLines.prefix(5).map { String($0) }.joined(separator: ", ") + (skippedLines.count > 5 ? " ほか" : "")
                out.append("\(skippedLines.count) 行は列が8つに足りないため使いません(行 \(shown))")
            }
            if !duplicateIds.isEmpty {
                out.append("id が重なっています: \(duplicateIds.prefix(3).joined(separator: ", "))(最初の行だけ使います)")
            }
            if !slotMissing.isEmpty {
                out.append("差し込み用(3列目が 1)なのに ___ が無い型: \(slotMissing.prefix(3).joined(separator: ", "))")
            }
            return out
        }
    }

    static func report(_ text: String) -> Report {
        var r = Report()
        var seen = Set<String>()
        for (i, raw) in text.components(separatedBy: "\n").enumerated() {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if line.hasPrefix("#") || line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let c = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard c.count >= 8, !c[0].trimmingCharacters(in: .whitespaces).isEmpty else { r.skippedLines.append(i + 1); continue }
            if !seen.insert(c[0]).inserted { r.duplicateIds.append(c[0]); continue }
            let t = QTemplate(id: c[0], group: c[1], slot: c[2] == "1", ja: c[3],
                              bizEn: c[4], bizKana: c[5], casEn: c[6], casKana: c[7])
            if t.slot && !(t.ja.contains("___") && t.bizEn.contains("___") && t.casEn.contains("___")) { r.slotMissing.append(t.id) }
            r.templates.append(t)
        }
        return r
    }

    static func load(_ path: String) -> [QTemplate] {
        guard let t = try? String(contentsOfFile: path, encoding: .utf8) else {
            fputs("質問箱の型が読めません: \(path)\n", stderr)
            return []
        }
        return parse(t)
    }
}

/// 拾った語。line / row / start...end は字幕のどこから拾ったか(字幕側の印に使う。行が消えたら line = -1)
struct QPick: Equatable, Identifiable {
    let id: Int
    var text: String
    var lang: QLang
    var line: Int
    var row: Int        // 0 = 上の行(日本語)、1 = 下の行(英語)
    var start: Int
    var end: Int
    var on = true
}

struct QBox: Equatable {
    var templates: [QTemplate] = []
    private(set) var templateOn: Set<String> = []
    private(set) var picks: [QPick] = []
    var tone: QTone = .business
    private var nextId = 0

    init(templates: [QTemplate] = [], tone: QTone = .business) {
        self.templates = templates
        self.tone = tone
    }

    /// 型の分類(ファイルに出てくる順)
    var groups: [String] {
        var seen: [String] = []
        for t in templates where !seen.contains(t.group) { seen.append(t.group) }
        return seen
    }

    /// 字幕の語をクリック。shift = 直前に拾った語(同じ行・同じ段)からここまでをつなげる。
    /// 拾った語をもう一度クリックすると取り消す。戻り値 true = 新しく拾った
    @discardableResult
    mutating func click(line: Int, row: Int, lang: QLang, index: Int, tokens: [QToken], shift: Bool) -> Bool {
        guard tokens.indices.contains(index), !tokens[index].pick.isEmpty else { return false }
        if shift, let li = picks.indices.last, picks[li].line == line, picks[li].row == row {
            let s = min(picks[li].start, index), e = max(picks[li].end, index)
            picks[li].start = s
            picks[li].end = e
            picks[li].text = QTokenizer.join(tokens[s...e], lang: lang)
            picks[li].on = true
            return false
        }
        if let i = picks.firstIndex(where: { $0.line == line && $0.row == row && $0.start <= index && index <= $0.end }) {
            picks.remove(at: i)
            return false
        }
        let text = tokens[index].pick
        if let i = picks.firstIndex(where: { $0.text.lowercased() == text.lowercased() }) {
            // 同じ語を別の場所から拾った → 増やさず、オンにして最後へ(続けて Shift+クリックでつなげられるように)
            var p = picks.remove(at: i)
            p.on = true
            p.line = line; p.row = row; p.lang = lang; p.start = index; p.end = index
            picks.append(p)
            return false
        }
        nextId += 1
        picks.append(QPick(id: nextId, text: text, lang: lang, line: line, row: row, start: index, end: index))
        return true
    }

    func isPicked(line: Int, row: Int, index: Int) -> Bool {
        picks.contains { $0.line == line && $0.row == row && $0.start <= index && index <= $0.end }
    }

    mutating func togglePick(_ id: Int) {
        if let i = picks.firstIndex(where: { $0.id == id }) { picks[i].on.toggle() }
    }

    mutating func removePick(_ id: Int) { picks.removeAll { $0.id == id } }

    mutating func clearPicks() { picks = [] }

    mutating func toggleTemplate(_ id: String) {
        if templateOn.contains(id) { templateOn.remove(id) } else { templateOn.insert(id) }
    }

    /// 型を入れ替える(ファイルを直して再読み込みしたとき)。オンにしていた型は、まだあるものだけ残す
    mutating func replaceTemplates(_ new: [QTemplate]) {
        templates = new
        templateOn = templateOn.intersection(Set(new.map { $0.id }))
    }

    /// 字幕の行が捨てられたら、字幕側の印だけ外す(拾った語は箱に残す)
    mutating func forget(alive: Set<Int>) {
        for i in picks.indices where picks[i].line >= 0 && !alive.contains(picks[i].line) { picks[i].line = -1 }
    }
}

// MARK: - 質問を作る(段階 (3)(4))

/// 作った発言。カナ(実際に聞こえる音)/ 英語 / 日本語。fromAFM = AFM の案(false = 型への差し込み)
struct QResult: Equatable, Identifiable {
    let id: Int
    var kana: String
    var en: String
    var ja: String
    var fromAFM: Bool
}

/// AFM に渡す材料
struct QRequest: Equatable {
    var tone: QTone
    var words: [String]       // オンの拾った語
    var templates: [String]   // オンの型(口調に合わせた英語 + 日本語)
    var note: String          // 入力欄(言いたいこと)
    var context: [String]     // 語を拾った字幕の行(英語)
    var slotTemplates = 0     // オンの型のうち ___ のあるもの(語を差し込める型)

    var isEmpty: Bool { words.isEmpty && templates.isEmpty && note.isEmpty }
    /// 型に差し込める語の数(英字の語。日本語の語は英語にしないと差し込めないので、型への差し込みでは使わない)
    var insertable: Int { words.filter { !QTokenizer.hasJapanese($0) }.count }
    /// AFM を呼ぶか: 入力欄がある / 語が2つ以上(つなぐのは AFM)/ 語はあるが差し込める型が無い / 語が日本語(英語にするのは AFM)。
    /// 英語の語1つ + 差し込める型なら、型への差し込みで足りる(AFM は同じような文を重ねて出すだけになる)
    var wantsAFM: Bool {
        !note.isEmpty || words.count >= 2 || (words.count == 1 && (slotTemplates == 0 || insertable == 0))
    }

    static func make(box: QBox, note: String, context: [String]) -> QRequest {
        let words = box.picks.filter { $0.on }.map { $0.text }
        let tpls = box.templates.filter { box.templateOn.contains($0.id) }.map { t in
            "\(box.tone == .business ? t.bizEn : t.casEn)(\(t.ja))"
        }
        let slots = box.templates.filter { box.templateOn.contains($0.id) && $0.slot }.count
        return QRequest(tone: box.tone, words: words, templates: tpls,
                        note: note.trimmingCharacters(in: .whitespacesAndNewlines), context: context, slotTemplates: slots)
    }

    /// prompts/qbox_user.txt の {TONE} {WORDS} {TEMPLATES} {NOTE} {CONTEXT} を埋める。
    /// must = 1回目の英語に入らなかった語。最後の行(「英語の発言:」)の前に「必ず入れる語」の行を足す
    func prompt(_ tpl: String, must: [String] = []) -> String {
        var t = tpl
        if !must.isEmpty {
            var lines = t.components(separatedBy: "\n")
            while let l = lines.last, l.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
            let add = "必ず英語の文に入れる語: \(must.joined(separator: " / "))"
            if lines.isEmpty { lines = [add] } else { lines.insert(add, at: lines.count - 1) }
            t = lines.joined(separator: "\n")
        }
        return fill(t)
    }

    private func fill(_ tpl: String) -> String {
        func or(_ s: String) -> String { s.isEmpty ? "(なし)" : s }
        return tpl
            .replacingOccurrences(of: "{TONE}", with: tone == .business ? "ビジネス" : "フランク")
            .replacingOccurrences(of: "{WORDS}", with: or(words.joined(separator: " / ")))
            .replacingOccurrences(of: "{TEMPLATES}", with: or(templates.joined(separator: " / ")))
            .replacingOccurrences(of: "{NOTE}", with: or(note))
            .replacingOccurrences(of: "{CONTEXT}", with: or(context.joined(separator: " / ")))
    }
}

enum QCompose {
    /// 拾った語のカナ: 発音辞書 + 規則(Kana.swift)。略語(大文字2〜6字)は文字ごとの読み。
    /// 辞書が無い・辞書に無い語は英語のまま(話し手が言った語なので耳で分かる)
    static func kana(_ word: String, dict: [String: [String]]? = nil) -> String {
        KanaG2P.convert(word, dict: dict ?? [:])
    }

    /// 型への差し込み(AFM なし・すぐ出る)。英語の語だけ入れる(日本語の語は AFM の案に任せる)
    static func fill(_ box: QBox, startId: Int, limit: Int = 8, dict: [String: [String]]? = nil) -> [QResult] {
        let words = box.picks.filter { $0.on && !QTokenizer.hasJapanese($0.text) }.map { $0.text }
        var out: [QResult] = []
        var id = startId
        for t in box.templates where box.templateOn.contains(t.id) {
            let en = box.tone == .business ? t.bizEn : t.casEn
            let kn = box.tone == .business ? t.bizKana : t.casKana
            if t.slot {
                for w in words {
                    id += 1
                    out.append(QResult(id: id, kana: kn.replacingOccurrences(of: "___", with: kana(w, dict: dict)),
                                       en: en.replacingOccurrences(of: "___", with: w),
                                       ja: t.ja.replacingOccurrences(of: "___", with: w), fromAFM: false))
                }
            } else {
                id += 1
                out.append(QResult(id: id, kana: kn, en: en, ja: t.ja, fromAFM: false))
            }
            if out.count >= limit { break }
        }
        return Array(out.prefix(limit))
    }

    /// AFM の出力が使えるか: 英語は日本語を含まず空でない、日本語訳は日本語を含む
    static func valid(en: String, ja: String) -> Bool {
        validEnglish(en) && QTokenizer.hasJapanese(ja)
    }

    /// 英語に入っていない拾った語(英字の語だけ調べる。日本語の語は訳されて形が変わるので調べない)
    static func missingWords(_ en: String, _ words: [String]) -> [String] {
        let low = en.lowercased()
        return words.filter { !QTokenizer.hasJapanese($0) && !low.contains($0.lowercased()) }
    }

    static func validEnglish(_ en: String) -> Bool {
        !en.isEmpty && !QTokenizer.hasJapanese(en) && en.contains(where: { $0.isASCII && $0.isLetter })
    }

    /// AFM の英語の出力から、発言の1行だけを取り出す(見出し・引用符・コードの囲みを外す)
    static func cleanEnglish(_ raw: String) -> String {
        let t = raw.replacingOccurrences(of: "```json", with: "\n").replacingOccurrences(of: "```", with: "\n")
        let strip = CharacterSet(charactersIn: "\"“”`{}[] ").union(.whitespaces)
        for line in t.components(separatedBy: .newlines) {
            var l = line.trimmingCharacters(in: .whitespaces)
            for p in ["英語の発言:", "英語の発言：", "英語:", "英語：", "English:", "english:", "\"english\":"] where l.hasPrefix(p) {
                l = String(l.dropFirst(p.count))
            }
            l = l.trimmingCharacters(in: strip)
            if validEnglish(l) { return l }
        }
        return ""
    }

    /// 下書き訳の出力から日本語の1行だけ(「日本語:」を外す)。日本語が無ければ空
    static func cleanJapanese(_ raw: String) -> String {
        for line in raw.components(separatedBy: .newlines) {
            var l = line.trimmingCharacters(in: .whitespaces)
            for p in ["日本語:", "日本語："] where l.hasPrefix(p) {
                l = String(l.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
            }
            if QTokenizer.hasJapanese(l) { return l }
        }
        return ""
    }

    static let emptyMessage = "語・型・入力欄のどれかを選ぶか入力してから、Q を押してください"
    /// 語を差し込む型(___ のある型)だけで、差し込む語が無いとき
    static let slotOnlyMessage = "選んだ型は語を差し込む型です。字幕の語を拾うか、入力欄に言いたいことを書いてから、もう一度 Q を押してください"
    static let invalidMessage = "うまく作れませんでした。語・型・入力欄を少し変えて、もう一度 Q を押してください"

    /// 失敗の文面: 何が起きたか + 次にどうすればよいか(エラーの説明文から判定。API の型の違いに左右されないように)
    static func message(for error: String) -> String {
        let e = error.lowercased()
        if e.contains("guardrail") || e.contains("refusal") || e.contains("unsafe") {
            return "安全フィルターで止まりました。入力欄の言い方を変えるか、語・型を減らして、もう一度 Q を押してください"
        }
        if e.contains("unavailable") || e.contains("notenabled") || e.contains("notready") || e.contains("eligible") {
            return "Apple Intelligence が使えません。システム設定で Apple Intelligence がオンか確かめてから、もう一度 Q を押してください"
        }
        if e.contains("contextwindow") || e.contains("context window") {
            return "材料が多すぎました。語や型を減らすか、入力欄を短くして、もう一度 Q を押してください"
        }
        if e.contains("ratelimit") || e.contains("concurrent") {
            return "AFM が混み合っています。数秒おいて、もう一度 Q を押してください"
        }
        if e.contains("timeout") {
            return "時間がかかりすぎたので止めました。もう一度 Q を押してください"
        }
        if e.contains("unsupportedlanguage") || e.contains("locale") {
            return "この言語の組み合わせは AFM が扱えませんでした。入力欄を日本語か英語で書き直して、もう一度 Q を押してください"
        }
        return invalidMessage
    }
}

// MARK: - 単体テスト(./jetcli --selftest)

enum QBoxSelftest {
    static func run() -> Bool {
        var fails = 0, total = 0
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            total += 1
            if !ok { fails += 1; print("NG  qbox: \(name)  \(detail())") }
        }

        // 1. 英語の区切り: 表示は句読点込み、拾う語は句読点なし。5% はそのまま
        do {
            let t = QTokenizer.en("Next year, we will focus on reducing ACW.")
            check("en: 拾う語", t.map { $0.pick } == ["Next", "year", "we", "will", "focus", "on", "reducing", "ACW"], "\(t.map { $0.pick })")
            check("en: 表示", t[1].display == "year," && t.last?.display == "ACW.", "\(t.map { $0.display })")
            let u = QTokenizer.en("Our goal is a 5% reduction.")
            check("en: 5% は1語", u.map { $0.pick }.contains("5%"), "\(u.map { $0.pick })")
        }

        // 2. 日本語の区切り: 表示をつなげると元の文。「削減」が1語で拾える
        do {
            let s = "我々が来年フォーカスするのはACWの削減についてです。"
            let t = QTokenizer.ja(s)
            check("ja: 表示をつなげると元の文", t.map { $0.display }.joined() == s, "\(t.map { $0.display })")
            check("ja: 削減を拾える", t.map { $0.pick }.contains("削減"), "\(t.map { $0.pick })")
            check("ja: ACW を拾える", t.map { $0.pick }.contains("ACW"), "\(t.map { $0.pick })")
            check("ja: 句読点は拾う語に入らない", !t.map { $0.pick }.contains { $0.hasSuffix("。") }, "\(t.map { $0.pick })")
            check("auto: 日本語/英語の判定", QTokenizer.hasJapanese(s) && !QTokenizer.hasJapanese("reducing ACW"))
        }

        // 3. クリックで拾う / Shift+クリックでつなげる / もう一度で取り消す
        do {
            let t = QTokenizer.en("we will focus on reducing ACW.")
            var b = QBox()
            check("click: 新しく拾う", b.click(line: 1, row: 1, lang: .en, index: 4, tokens: t, shift: false))
            b.click(line: 1, row: 1, lang: .en, index: 5, tokens: t, shift: true)
            check("shift: つなげる", b.picks.map { $0.text } == ["reducing ACW"], "\(b.picks.map { $0.text })")
            check("shift: 字幕側の印", b.isPicked(line: 1, row: 1, index: 4) && b.isPicked(line: 1, row: 1, index: 5) && !b.isPicked(line: 1, row: 1, index: 3))
            check("shift: 別の段の印は付かない", !b.isPicked(line: 1, row: 0, index: 4))
            b.click(line: 1, row: 1, lang: .en, index: 5, tokens: t, shift: false)
            check("click: もう一度で取り消す", b.picks.isEmpty, "\(b.picks)")
        }

        // 4. 同じ語は増やさない / オンオフ / 削除 / 行が消えたら印だけ外す
        do {
            let t1 = QTokenizer.en("reducing ACW")
            let t2 = QTokenizer.en("the ACW target")
            var b = QBox()
            b.click(line: 1, row: 1, lang: .en, index: 1, tokens: t1, shift: false)
            b.togglePick(b.picks[0].id)
            check("toggle: オフ", b.picks[0].on == false)
            check("同じ語: 増やさない", !b.click(line: 2, row: 1, lang: .en, index: 1, tokens: t2, shift: false) && b.picks.count == 1 && b.picks[0].on && b.picks[0].line == 2)
            b.forget(alive: [5])
            check("forget: 印だけ外す", b.picks.count == 1 && b.picks[0].line == -1)
            b.removePick(b.picks[0].id)
            check("remove", b.picks.isEmpty)
            check("拾えない語は無視", !b.click(line: 3, row: 0, lang: .ja, index: 0, tokens: [QToken(display: "。", pick: "")], shift: false))
        }

        // 5. 型の読み込み(# の行は飛ばす)・分類・オンオフ
        do {
            let tsv = "# id\tgroup\tslot\tja\tbiz_en\tbiz_kana\tcasual_en\tcasual_kana\n" +
                "what\t質問\t1\t___とは何ですか\tCould you explain what ___ is?\tクッジュー\tWhat's ___?\tワッツ\n" +
                "again\t確認\t0\tもう一度\tCould you say that again?\tクッジュー\tSay that again?\tセイ\n" +
                "bad\tだめ\n"
            var b = QBox(templates: QTemplate.parse(tsv))
            check("parse: 2件(壊れた行は飛ばす)", b.templates.map { $0.id } == ["what", "again"], "\(b.templates.map { $0.id })")
            check("parse: slot", b.templates[0].slot && !b.templates[1].slot)
            check("label: 〇〇", b.templates[0].label == "〇〇とは何ですか", b.templates[0].label)
            check("groups: 出てくる順", b.groups == ["質問", "確認"], "\(b.groups)")
            b.toggleTemplate("what")
            check("template: オン", b.templateOn == ["what"])
            b.toggleTemplate("what")
            check("template: オフ", b.templateOn.isEmpty)
        }

        // 5b. 型の読み込みレポート・入れ替え(U5b)
        do {
            let tsv = "# コメント\n" +
                "what\t質問\t1\t___とは何ですか\tCould you explain what ___ is?\tクッジュー\tWhat's ___?\tワッツ\n" +
                "\n" +
                "bad\tだめ\n" +
                "what\t質問\t1\t重複\tDup ___\tダップ\tDup ___\tダップ\n" +
                "noslot\t質問\t1\t差し込み先が無い\tNo slot here\tノー\tNo slot\tノー\n" +
                "again\t確認\t0\tもう一度\tSay that again?\tセイ\tAgain?\tアゲイン\r\n"
            let r = QTemplate.report(tsv)
            check("report: 使える型", r.templates.map { $0.id } == ["what", "noslot", "again"], "\(r.templates.map { $0.id })")
            check("report: 足りない行は行番号で", r.skippedLines == [4], "\(r.skippedLines)")
            check("report: id の重複は最初の行だけ", r.duplicateIds == ["what"] && r.templates[0].ja == "___とは何ですか", "\(r.duplicateIds)")
            check("report: ___ が無い差し込み用", r.slotMissing == ["noslot"], "\(r.slotMissing)")
            check("report: 改行コード CRLF でも読める", r.templates.last?.casKana == "アゲイン", "\(r.templates.last?.casKana ?? "")")
            check("report: 問題あり", r.hasProblem && !QTemplate.report("a\tg\t0\tj\te\tk\tc\tk\n").hasProblem)
            check("report: 文面は3つ", r.problems.count == 3 && r.problems[0].contains("行 4"), "\(r.problems)")
            check("parse は report と同じ型", QTemplate.parse(tsv) == r.templates)
            var b = QBox(templates: r.templates)
            b.toggleTemplate("what")
            b.toggleTemplate("again")
            b.replaceTemplates(Array(r.templates.filter { $0.id != "again" }))
            check("入れ替え: 残った型のオンは保つ・消えた型のオンは外す", b.templateOn == ["what"] && b.templates.count == 2, "\(b.templateOn)")
        }

        // 6. 型への差し込み・カナ・依頼文・文面
        do {
            let tsv = "what\t質問\t1\t___とは何ですか\tCould you explain what ___ is?\tクッジュー イクスプレイン ワッ ___ イズ\tWhat's ___?\tワッツ ___\n" +
                "again\t確認\t0\tもう一度\tCould you say that again?\tクッジュー セイ ザッタゲン\tSay that again?\tセイ ザッタゲン\n"
            var b = QBox(templates: QTemplate.parse(tsv))
            check("kana: 略語は文字読み", QCompose.kana("ACW") == "エーシーダブリュー", QCompose.kana("ACW"))
            check("kana: 辞書が無ければ英語のまま", QCompose.kana("reducing ACW") == "reducing エーシーダブリュー", QCompose.kana("reducing ACW"))
            check("kana: 辞書があれば読み", QCompose.kana("little", dict: KanaSelftest.mini) == "リル", QCompose.kana("little", dict: KanaSelftest.mini))
            let t = QTokenizer.en("reducing ACW")
            b.click(line: 1, row: 1, lang: .en, index: 1, tokens: t, shift: false)
            b.toggleTemplate("what")
            b.toggleTemplate("again")
            let r = QCompose.fill(b, startId: 0)
            check("fill: 語を差し込む + 語なしの型", r.map { $0.en } == ["Could you explain what ACW is?", "Could you say that again?"], "\(r.map { $0.en })")
            check("fill: カナにも差し込む", r.first?.kana == "クッジュー イクスプレイン ワッ エーシーダブリュー イズ", r.first?.kana ?? "")
            check("fill: 日本語", r.first?.ja == "ACWとは何ですか", r.first?.ja ?? "")
            b.tone = .casual
            check("fill: 口調", QCompose.fill(b, startId: 0).first?.en == "What's ACW?")
            let jaTok = QTokenizer.ja("削減の目標")
            if let i = jaTok.firstIndex(where: { $0.pick == "削減" }) {
                b.click(line: 2, row: 0, lang: .ja, index: i, tokens: jaTok, shift: false)
            }
            check("fill: 日本語の語は差し込まない", QCompose.fill(b, startId: 0).filter { $0.en.contains("削減") }.isEmpty)
            let q = QRequest.make(box: b, note: " 今年度の平均は？ ", context: ["Next year, we will focus on reducing ACW."])
            check("request: 材料", q.words.contains("ACW") && q.note == "今年度の平均は？" && q.templates.count == 2 && q.wantsAFM, "\(q)")
            let pr = q.prompt("口調: {TONE}\n使う語: {WORDS}\n言いたいこと: {NOTE}\n流れ: {CONTEXT}")
            check("request: 埋める", pr.contains("口調: フランク") && pr.contains("今年度の平均は？") && pr.contains("reducing ACW"), pr)
            let empty = QRequest(tone: .business, words: [], templates: [], note: "", context: [])
            check("request: 空", empty.isEmpty && !empty.wantsAFM && empty.prompt("{NOTE}") == "(なし)")
            var one = QRequest(tone: .business, words: ["ACW"], templates: ["x"], note: "", context: [], slotTemplates: 1)
            check("request: 語1つ + 差し込める型 → AFM なし", !one.wantsAFM)
            one.slotTemplates = 0
            check("request: 語1つ + 差し込める型なし → AFM", one.wantsAFM)
            one.slotTemplates = 1
            one.words = ["ACW", "reduction"]
            check("request: 語2つ → AFM", one.wantsAFM)
            one.words = ["ワークフロー"]
            check("request: 日本語の語1つ + 差し込める型 → AFM(型には差し込めない)", one.wantsAFM && one.insertable == 0)
            one.words = ["workflow"]
            check("request: 英語の語1つ + 差し込める型 → AFM なし", !one.wantsAFM && one.insertable == 1)
            check("missing: 入っていない語", QCompose.missingWords("Please tell me the results for this year.", ["ACW"]) == ["ACW"])
            check("missing: 入っている語・日本語の語は調べない", QCompose.missingWords("Show me the acw for this year.", ["ACW", "今年"]).isEmpty)
            let mp = q.prompt("口調: {TONE}\n使う語: {WORDS}\n英語の発言:", must: ["ACW"])
            check("must: 最後の行の前に足す", mp.hasSuffix("必ず英語の文に入れる語: ACW\n英語の発言:"), mp)
            check("clean: 見出しと引用符", QCompose.cleanEnglish("英語の発言: \"Could you tell us more about ACW?\"") == "Could you tell us more about ACW?")
            check("clean: 日本語の行は飛ばす", QCompose.cleanEnglish("ACWについて\nWhat's ACW?") == "What's ACW?")
            check("clean: コードの囲み", QCompose.cleanEnglish("```\nWhat's ACW?\n```") == "What's ACW?")
            check("clean: 日本語訳", QCompose.cleanJapanese("日本語: ACWとは何ですか") == "ACWとは何ですか" && QCompose.cleanJapanese("What") == "")
            check("valid", QCompose.valid(en: "What's the average ACW?", ja: "ACWの平均は？") && !QCompose.valid(en: "ACWの平均", ja: "平均") && !QCompose.valid(en: "", ja: "あ"))
            check("message: 安全フィルター", QCompose.message(for: "GenerationError.guardrailViolation(...)").contains("言い方を変える"))
            check("message: 使えない", QCompose.message(for: "AFMが使えません: appleIntelligenceNotEnabled").contains("Apple Intelligence"))
            check("message: 時間切れ", QCompose.message(for: "timeout").contains("もう一度 Q"))
            check("message: その他", QCompose.message(for: "something odd") == QCompose.invalidMessage)
        }

        print("qbox: \(total - fails) / \(total) 件OK")
        return fails == 0
    }
}
