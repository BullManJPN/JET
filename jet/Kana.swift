import Foundation

// 英語の文 → カタカナ(英語の話し手が言ったときに実際に聞こえる音に寄せる)。
// 発音辞書 CMUdict(asr/cmudict.dict、ARPAbet)+ 規則。AFM は使わない(AFM にカナを作らせると当たり外れが大きかった、10/29)。
// 主な規則:
//   語をまたぐ連結   that again → ザッタゲン / tell us → テラス / speak a → スピーカ
//   語末の破裂音     what → ワッ / get back → ゲッ バッ(飲み込む)
//   you の前         could you → クッジュー / let you → レッチュー / thank you → サンキュー
//   it・a・of などの前の t   got it → ガリッ / 語中 little → リル / better → ベラ
//   語末の r         more → モア / there → ゼア(語中や for・or は ー)
//   語末の l         will → ウィゥ / else → エゥス / example → イグザンポォ
//   n の後の t・d    and → アン / want → ワン / sounds → サウンズ
// 辞書に無い語: 大文字の略語は文字ごとの読み(ACW → エーシーダブリュー)、数字は英語の読み、それ以外は英語のまま

final class KanaDict: @unchecked Sendable {
    static let shared = KanaDict()
    private let lock = NSLock()
    private var dict: [String: [String]]? = nil

    /// 読み込む(1回だけ。読み込み中に呼ばれたら終わるまで待つ)。メインの外で呼ぶ
    @discardableResult
    func ensure(path: String) -> [String: [String]] {
        lock.lock()
        defer { lock.unlock() }
        if let d = dict { return d }
        let d = KanaDict.parse(path: path)
        dict = d
        if d.isEmpty { fputs("カナ用の発音辞書がありません: \(path)\n", stderr) }
        return d
    }

    /// 読み込み済みなら返す(待たない)
    func loaded() -> [String: [String]]? {
        guard lock.try() else { return nil }
        defer { lock.unlock() }
        return dict
    }

    static func parse(path: String) -> [String: [String]] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var d: [String: [String]] = [:]
        d.reserveCapacity(140_000)
        for raw in text.split(separator: "\n") {
            var line = raw
            if let h = line.firstIndex(of: "#") { line = line[..<h] }
            let parts = line.split(separator: " ")
            guard parts.count >= 2 else { continue }
            let w = String(parts[0])
            if w.hasSuffix(")") { continue }   // word(2) などの別の読みは使わない(最初の読みだけ)
            d[w] = parts.dropFirst().map(String.init)
        }
        return d
    }
}

enum KanaG2P {
    struct Ph { let s: String; let stress: Int? }   // stress が nil でない = 母音

    static let stops: Set<String> = ["P", "T", "K", "B", "D", "G"]
    static let shortV: Set<String> = ["AE", "EH", "IH", "AH", "UH", "AA", "AO"]
    /// この語の前の語末 t は ら行(got it → ガリッ / a lot of → アラロヴ)
    static let flapFunc: Set<String> = ["it", "a", "an", "of", "at", "all", "up", "on", "out"]
    static let youWords: Set<String> = ["you", "your", "you're", "yours", "you'll", "you've", "you'd"]
    /// 語末の r を ー にする語(ふつうは ア)
    static let rLong: Set<String> = ["for", "or", "nor"]
    /// 辞書の最初の読みが会話の読みと違う語(機能語は弱い読みに)
    static let overrides: [String: String] = [
        "your": "Y UH1 R", "and": "AH0 N D", "to": "T UW1", "for": "F AO1 R", "a": "AH0",
        "the": "DH AH0", "of": "AH1 V", "it": "IH1 T", "can": "K AE1 N", "an": "AH0 N",
    ]

    static let letters: [Character: String] = [
        "A": "エー", "B": "ビー", "C": "シー", "D": "ディー", "E": "イー", "F": "エフ", "G": "ジー", "H": "エイチ",
        "I": "アイ", "J": "ジェイ", "K": "ケイ", "L": "エル", "M": "エム", "N": "エヌ", "O": "オー", "P": "ピー",
        "Q": "キュー", "R": "アール", "S": "エス", "T": "ティー", "U": "ユー", "V": "ヴィー", "W": "ダブリュー",
        "X": "エックス", "Y": "ワイ", "Z": "ズィー",
    ]

    /// 子音 + 母音の段(ア イ ウ エ オ)
    static let rows: [String: [String]] = [
        "": ["ア", "イ", "ウ", "エ", "オ"],
        "B": ["バ", "ビ", "ブ", "ベ", "ボ"], "CH": ["チャ", "チ", "チュ", "チェ", "チョ"], "D": ["ダ", "ディ", "ドゥ", "デ", "ド"],
        "DH": ["ザ", "ズィ", "ズ", "ゼ", "ゾ"], "F": ["ファ", "フィ", "フ", "フェ", "フォ"], "G": ["ガ", "ギ", "グ", "ゲ", "ゴ"],
        "HH": ["ハ", "ヒ", "フ", "ヘ", "ホ"], "JH": ["ジャ", "ジ", "ジュ", "ジェ", "ジョ"], "K": ["カ", "キ", "ク", "ケ", "コ"],
        "L": ["ラ", "リ", "ル", "レ", "ロ"], "M": ["マ", "ミ", "ム", "メ", "モ"], "N": ["ナ", "ニ", "ヌ", "ネ", "ノ"],
        "P": ["パ", "ピ", "プ", "ペ", "ポ"], "R": ["ラ", "リ", "ル", "レ", "ロ"], "S": ["サ", "シ", "ス", "セ", "ソ"],
        "SH": ["シャ", "シ", "シュ", "シェ", "ショ"], "T": ["タ", "ティ", "トゥ", "テ", "ト"], "TH": ["サ", "シ", "ス", "セ", "ソ"],
        "V": ["ヴァ", "ヴィ", "ヴ", "ヴェ", "ヴォ"], "W": ["ワ", "ウィ", "ウ", "ウェ", "ウォ"], "Y": ["ヤ", "イ", "ユ", "イェ", "ヨ"],
        "Z": ["ザ", "ズィ", "ズ", "ゼ", "ゾ"], "ZH": ["ジャ", "ジ", "ジュ", "ジェ", "ジョ"],
        "KY": ["キャ", "キ", "キュ", "キェ", "キョ"], "GY": ["ギャ", "ギ", "ギュ", "ギェ", "ギョ"],
    ]
    static let coda: [String: String] = [
        "S": "ス", "Z": "ズ", "F": "フ", "V": "ヴ", "TH": "ス", "DH": "ズ", "SH": "シュ", "ZH": "ジュ",
        "CH": "チ", "JH": "ジ", "M": "ム", "N": "ン", "NG": "ン", "HH": "", "W": "ウ", "Y": "イ", "L": "ゥ",
    ]
    static let released: [String: String] = ["P": "プ", "T": "ト", "K": "ク", "B": "ブ", "D": "ド", "G": "グ"]

    /// 母音 → (段, 後ろに付けるもの)
    static func vowelShape(_ v: String, stress: Int, beforeR: Bool, wordFinal: Bool) -> (Int, String) {
        let st = stress > 0
        switch v {
        case "AA", "AE", "AH": return (0, "")
        case "AO": return (4, st && !beforeR ? "ー" : "")
        case "AW": return (0, "ウ")
        case "AY": return (0, "イ")
        case "EH": return (3, "")
        case "ER": return (0, (st || !wordFinal) ? "ー" : "")
        case "EY": return (3, "イ")
        case "IH": return (1, "")
        case "IY": return (1, st && !beforeR ? "ー" : "")
        case "OW": return (4, "ウ")
        case "OY": return (4, "イ")
        case "UH": return (2, "")
        case "UW": return (2, st && !beforeR ? "ー" : "")
        default: return (0, "")
        }
    }

    // MARK: 語に分ける

    enum Tok {
        case phones(word: String, ph: [Ph])
        case literal(String)
    }

    static func phones(_ s: String) -> [Ph] {
        s.split(separator: " ").map { p in
            let t = String(p)
            if let last = t.last, let d = last.wholeNumberValue { return Ph(s: String(t.dropLast()), stress: d) }
            return Ph(s: t, stress: nil)
        }
    }

    static let ones = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
                       "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
    static let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]

    static func numberWords(_ n: Int) -> [String]? {
        if n < 0 || n >= 100 { return nil }
        if n < 20 { return [ones[n]] }
        return n % 10 == 0 ? [tens[n / 10]] : [tens[n / 10], ones[n % 10]]
    }

    static func wordTokens(_ w: String, _ dict: [String: [String]]) -> [Tok] {
        func lookup(_ x: String) -> Tok? {
            let l = x.lowercased()
            if let o = overrides[l] { return .phones(word: l, ph: phones(o)) }
            if let p = dict[l] { return .phones(word: l, ph: phones(p.joined(separator: " "))) }
            return nil
        }
        if (2...6).contains(w.count) && w.allSatisfy({ $0.isASCII && $0.isLetter && $0.isUppercase }) {
            return [.literal(w.compactMap { letters[$0] }.joined())]
        }
        if w.hasSuffix("%") {
            return wordTokens(String(w.dropLast()), dict) + (lookup("percent").map { [$0] } ?? [.literal("パーセント")])
        }
        if w.allSatisfy({ $0.isASCII && $0.isNumber }) {
            if let n = Int(w), let ws = numberWords(n) {
                let ts = ws.compactMap { lookup($0) }
                if ts.count == ws.count { return ts }
            }
            return [.literal(w)]
        }
        if let t = lookup(w) { return [t] }
        return [.literal(w)]
    }

    static func tokens(_ sentence: String, dict: [String: [String]]) -> [Tok] {
        let norm = sentence.replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'")
        let keep = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'%")).inverted
        var out: [Tok] = []
        for raw in norm.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            for part in raw.split(separator: "-") {   // Wi-Fi など
                let w = String(part).trimmingCharacters(in: keep)
                if w.isEmpty { continue }
                out.append(contentsOf: wordTokens(w, dict))
            }
        }
        return out
    }

    // MARK: 変換

    static func convert(_ sentence: String, dict: [String: [String]]) -> String {
        var pieces: [String] = []
        var runWords: [(word: String, ph: [Ph])] = []
        func flush() {
            if !runWords.isEmpty { pieces.append(contentsOf: run(runWords)); runWords = [] }
        }
        for t in tokens(sentence, dict: dict) {
            switch t {
            case .phones(let w, let ph): if !ph.isEmpty { runWords.append((w, ph)) }
            case .literal(let s): flush(); pieces.append(s)
            }
        }
        flush()
        return pieces.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// 辞書の語が続くところ(語をまたいでつなげる)。戻り値は画面に出す塊(語ごと。つながった語は1つの塊)
    static func run(_ ws: [(word: String, ph: [Ph])]) -> [String] {
        var flat: [(p: Ph, w: Int)] = []
        for (i, x) in ws.enumerated() { for p in x.ph { flat.append((p, i)) } }
        var out: [String] = []
        var cur = ""
        var curWord = 0
        var nextOnsetR = false    // ER の後に母音: 次の母音は ら行(average → アヴァリッジ)

        func isV(_ k: Int) -> Bool { k >= 0 && k < flat.count && flat[k].p.stress != nil }
        func sameWord(_ a: Int, _ b: Int) -> Bool { a >= 0 && b < flat.count && flat[a].w == flat[b].w }
        func wordOf(_ k: Int) -> String { ws[flat[k].w].word }
        /// j が語末の子音 s か(同じ語の母音が後ろに続かない)
        func codaAt(_ j: Int, _ s: String, of k: Int) -> Bool {
            guard j < flat.count, flat[j].p.s == s, sameWord(k, j) else { return false }
            return !(isV(j + 1) && sameWord(j, j + 1))
        }
        /// k の母音(onset = 前の子音)。戻り値 = (カナ, 後ろで使った音素の数)
        func emitVowel(_ onset: String, _ k: Int, flapped: Bool) -> (String, Int) {
            let v = flat[k].p.s
            let st = flat[k].p.stress ?? 0
            let row = rows[onset] ?? rows[""]!
            // -ple / -ble など(語末の弱い ア + l): ポォ。ら行になった t の後は ル(little → リル)
            if v == "AH" && st == 0 && codaAt(k + 1, "L", of: k) {
                return (flapped ? "ル" : row[4] + "ォ", 1)
            }
            // ER の後に同じ語の母音が続く: ア だけ出し、次の母音を ら行に
            if v == "ER" && isV(k + 1) && sameWord(k, k + 1) {
                nextOnsetR = true
                return (row[0], 0)
            }
            let beforeR = codaAt(k + 1, "R", of: k)
            // year: イヤー
            if onset == "Y" && (v == "IH" || v == "IY") && beforeR { return ("イヤー", 1) }
            let wordFinal = !(k + 1 < flat.count && sameWord(k, k + 1))
            let (col, tail) = vowelShape(v, stress: st, beforeR: beforeR, wordFinal: wordFinal)
            return (row[col] + tail, 0)
        }

        var i = 0
        while i < flat.count {
            let w = flat[i].w
            if w != curWord {   // 語の境目(つながらなかった)
                out.append(cur)
                cur = ""
                curWord = w
            }
            let p = flat[i].p
            if p.stress != nil {
                let (k2, used) = emitVowel(nextOnsetR ? "R" : "", i, flapped: false)
                nextOnsetR = false
                cur += k2
                i += 1 + used
                continue
            }
            let c = p.s
            let n = i + 1
            let sameNext = n < flat.count && flat[n].w == w
            let prevV: Ph? = (i > 0 && flat[i - 1].w == w && isV(i - 1)) ? flat[i - 1].p : nil
            let prevShortStressed = prevV.map { shortV.contains($0.s) && ($0.stress ?? 0) > 0 } ?? false

            // could you / let you / thank you: 語末の d・t・k・g + you
            if !sameNext, ["D", "T", "K", "G"].contains(c), n < flat.count, flat[n].p.s == "Y",
               youWords.contains(wordOf(n)), isV(n + 1) {
                let onset = ["D": "JH", "T": "CH", "K": "KY", "G": "GY"][c]!
                let pre = (c == "D" || c == "T") && prevShortStressed ? "ッ" : ""
                let (k2, used) = emitVowel(onset, n + 1, flapped: false)
                cur += pre + k2
                curWord = flat[n].w
                i = n + 2 + used
                continue
            }
            // ts → ツ(what's → ワッツ)/ dz → ズ(slides → スライズ)
            if c == "T" && sameNext && flat[n].p.s == "S" && !(isV(n + 1) && sameWord(n, n + 1)) {
                cur += (prevShortStressed ? "ッ" : "") + "ツ"
                i += 2
                continue
            }
            if c == "D" && sameNext && flat[n].p.s == "Z" {
                i += 1
                continue
            }
            // 次の母音の頭になる(語をまたぐ連結を含む。r・h・w・y・ng は語をまたがない)
            if isV(n) && c != "NG" && (sameNext || !["R", "HH", "W", "Y"].contains(c)) {
                var onset = c
                var flapped = false
                if c == "T", prevV != nil {
                    if sameNext {
                        if prevShortStressed && (flat[n].p.stress ?? 1) == 0 { onset = "R"; flapped = true }
                    } else if flapFunc.contains(wordOf(n)) {
                        onset = "R"; flapped = true
                    }
                }
                let pre = (!flapped && !sameNext && stops.contains(c) && prevShortStressed && (flat[n].p.stress ?? 1) == 0) ? "ッ" : ""
                let (k2, used) = emitVowel(onset, n, flapped: flapped)
                cur += pre + k2
                if !sameNext { curWord = flat[n].w }   // 次の語を今の塊に入れる
                i = n + 1 + used
                continue
            }
            // 子音で終わる
            let prevC = i > 0 && flat[i - 1].w == w ? flat[i - 1].p.s : ""
            if stops.contains(c) {
                if sameNext {
                    let nx = flat[n].p.s
                    if (c == "T" || c == "D") && prevC == "N" && (nx == "S" || nx == "Z") {
                        // sounds / wants: n と s の間の d・t は落ちる
                    } else if stops.contains(nx) {
                        cur += "ッ"
                    } else {
                        cur += (prevShortStressed ? "ッ" : "") + released[c]!
                    }
                } else if (c == "T" || c == "D") && prevC == "N" {
                    // and / want: n の後の語末 t・d は落ちる
                } else if (c == "K" || c == "G") && prevC == "NG" {
                    cur += released[c]!     // think → シンク
                } else if (c == "P" || c == "B") && prevC == "M" {
                    cur += released[c]!
                } else {
                    cur += "ッ"             // what → ワッ(飲み込む)
                }
            } else if c == "R" {
                if let pv = prevV {
                    if pv.s == "ER" {
                        // ER で伸ばし済み
                    } else if pv.s == "AA" || rLong.contains(ws[w].word) || sameNext {
                        cur += "ー"
                    } else {
                        cur += "ア"         // more → モア / there → ゼア
                    }
                } else {
                    cur += "ル"
                }
            } else if c == "M" && sameNext && ["P", "B"].contains(flat[n].p.s) {
                cur += "ン"                 // example → イグザンポォ
            } else if (c == "CH" || c == "JH") && !sameNext && prevV.map({ shortV.contains($0.s) }) == true {
                cur += "ッ" + (c == "CH" ? "チ" : "ジ")   // average → アヴァリッジ / match → マッチ
            } else {
                cur += coda[c] ?? ""
            }
            i += 1
        }
        out.append(cur)
        return out.filter { !$0.isEmpty }
    }
}

// MARK: - 単体テスト(./jetcli --selftest)。辞書は小さな手書き(CMUdict と同じ表記)

enum KanaSelftest {
    static let mini: [String: [String]] = {
        let src = """
        could K UH1 D
        you Y UW1
        say S EY1
        that DH AE1 T
        again AH0 G EH1 N
        please P L IY1 Z
        what W AH1 T
        what's W AH1 T S
        is IH1 Z
        tell T EH1 L
        us AH1 S
        more M AO1 R
        about AH0 B AW1 T
        got G AA1 T
        check CH EH1 K
        get G EH1 T
        back B AE1 K
        let L EH1 T
        me M IY1
        know N OW1
        example IH0 G Z AE1 M P AH0 L
        little L IH1 T AH0 L
        handling HH AE1 N D L IH0 NG
        explain IH0 K S P L EY1 N
        thanks TH AE1 NG K S
        thank TH AE1 NG K
        there DH EH1 R
        clear K L IH1 R
        meeting M IY1 T IH0 NG
        deadline D EH1 D L AY2 N
        when W EH1 N
        sounds S AW1 N D Z
        good G UH1 D
        performance P ER0 F AO1 R M AH0 N S
        year Y IH1 R
        five F AY1 V
        percent P ER0 S EH1 N T
        speak S P IY1 K
        will W IH1 L
        else EH1 L S
        average AE1 V ER0 IH0 JH
        slides S L AY1 D Z
        """
        var d: [String: [String]] = [:]
        for l in src.split(separator: "\n") {
            let p = l.split(separator: " ").map(String.init)
            if p.count >= 2 { d[p[0]] = Array(p.dropFirst()) }
        }
        return d
    }()

    static func run() -> Bool {
        var fails = 0, total = 0
        func check(_ en: String, _ want: String) {
            total += 1
            let got = KanaG2P.convert(en, dict: mini)
            if got != want { fails += 1; print("NG  kana: \(en)  → \(got)(期待 \(want))") }
        }
        check("Could you say that again, please?", "クッジュー セイ ザッタゲン プリーズ")
        check("Could you tell us more about ACW?", "クッジュー テラス モア アバウッ エーシーダブリュー")
        check("Got it, thanks!", "ガリッ サンクス")
        check("Let me check and let you know.", "レッ ミー チェッカン レッチュー ノウ")
        check("What is", "ワティズ")
        check("When is", "ウェニズ")
        check("what's", "ワッツ")
        check("thank you", "サンキュー")
        check("Sounds good!", "サウンズ グッ")
        check("get back", "ゲッ バッ")
        check("little", "リル")
        check("example", "イグザンポォ")
        check("handling", "ハンドリン")
        check("explain", "イクスプレイン")
        check("deadline", "デッドライン")
        check("meeting", "ミーティン")
        check("there", "ゼア")
        check("clear", "クリア")
        check("for", "フォー")
        check("performance", "パーフォーマンス")
        check("year", "イヤー")
        check("speak a little", "スピーカ リル")
        check("will", "ウィゥ")
        check("else", "エゥス")
        check("average", "アヴァリッジ")
        check("slides", "スライズ")
        check("5%", "ファイヴ パーセン")
        check("Wi-Fi zzqx", "Wi Fi zzqx")
        print("kana: \(total - fails) / \(total) 件OK")
        return fails == 0
    }
}
