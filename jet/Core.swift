import Foundation

// sim/core.py の移植。Apple のフレームワークは使わない(Foundation のみ)。時計は持たず、呼び出し側が wall を渡す。

typealias Ev = [String: Any]

let CONJ: Set<String> = ["and", "but", "because", "which", "where", "when", "if", "or", "while", "although"]
/// 主語らしい語(look_conj の後にこれが来たら、接続詞の手前で節を閉じる)。sim/core.py SUBJ
let SUBJ: Set<String> = ["a", "all", "an", "everyone", "he", "her", "his", "i", "i'm", "it", "it's", "its", "many", "most", "my", "now", "our", "people", "she", "so", "some", "that", "that's", "the", "their", "then", "there", "there's", "these", "they", "they're", "this", "those", "we", "we're", "you", "you're", "your"]
/// 節の終わりにしたくない語(前置詞・冠詞など)。sim/core.py DANGLING
let DANGLING: Set<String> = ["a", "about", "an", "and", "are", "as", "at", "be", "been", "but", "by", "can", "could", "do", "does", "for", "from", "had", "has", "have", "her", "his", "if", "in", "into", "is", "its", "more", "most", "my", "not", "of", "on", "or", "our", "should", "so", "than", "that", "the", "their", "to", "very", "was", "were", "when", "which", "while", "who", "will", "with", "would", "your"]

func r3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }

enum Rx {
    static let word = try! NSRegularExpression(pattern: #"[\w'’-]+[.,?!]?"#)
    static let nonWord = try! NSRegularExpression(pattern: #"[^\w']"#)
    static let alpha5 = try! NSRegularExpression(pattern: "[A-Za-z]{5,}")
    static let numeric = try! NSRegularExpression(pattern: #"^\d+(st|nd|rd|th|s)?$"#)
}

func fullRange(_ s: String) -> NSRange { NSRange(location: 0, length: (s as NSString).length) }

/// 語に分ける(句読点は語の末尾に付く)
func W(_ t: String) -> [String] {
    let ns = t as NSString
    return Rx.word.matches(in: t, options: [], range: fullRange(t)).map { ns.substring(with: $0.range) }
}

/// 比較用に正規化(小文字、英数字と ' 以外を除く)
func N(_ w: String) -> String {
    let l = w.lowercased()
    return Rx.nonWord.stringByReplacingMatches(in: l, options: [], range: fullRange(l), withTemplate: "")
}

// MARK: - 用語補正 (asr/correct_terms.py)

final class Corrector {
    let terms: [String]
    let termSet: Set<String>
    let aliasRes: [(NSRegularExpression, String)]
    let termRes: [(NSRegularExpression, String)]
    let single: [String]
    let multi: [[String]]
    let thr: Double
    /// 辞書(小文字の語)。hold_unknown が 0 なら空
    let vocab: Set<String>
    /// 用語集の語と別名表の直し先の語(待たない)。sim/core.py known_words
    let known: Set<String>

    init(termsPath: String, aliasesPath: String, thr: Double, vocabPath: String? = nil) throws {
        let tt = try JetPaths.readLayered(termsPath)
        let T = tt.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var A: [(String, String)] = []
        let at = try JetPaths.readLayered(aliasesPath)
        for l in at.components(separatedBy: "\n") {
            if l.hasPrefix("#") || l.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            let p = l.components(separatedBy: "\t")
            if p.count >= 2 { A.append((p[0], p[1])) }
        }
        var ar: [(NSRegularExpression, String)] = []
        for (a, c) in A {
            let body = a.split(separator: " ", omittingEmptySubsequences: false)
                .map { NSRegularExpression.escapedPattern(for: String($0)) }
                .joined(separator: #"[\s-]+"#)
            let re = try NSRegularExpression(pattern: #"\b"# + body + #"\b"#, options: [.caseInsensitive])
            ar.append((re, NSRegularExpression.escapedTemplate(for: c)))
        }
        var tr: [(NSRegularExpression, String)] = []
        for t in T {
            let re = try NSRegularExpression(pattern: #"\b"# + NSRegularExpression.escapedPattern(for: t) + #"\b"#,
                                             options: [.caseInsensitive])
            tr.append((re, NSRegularExpression.escapedTemplate(for: t)))
        }
        self.terms = T
        self.termSet = Set(T)
        self.aliasRes = ar
        self.termRes = tr
        self.single = T.filter { !$0.contains(" ") && $0.count >= 5 }
        self.multi = A.filter { $0.0.split(separator: " ").count > 1 }
            .map { $0.0.split(separator: " ").map { N(String($0)) } }
        self.thr = thr
        var kn = Set<String>()
        for t in T { for x in t.split(whereSeparator: { $0.isWhitespace }) { kn.insert(N(String(x))) } }
        for (_, c) in A { for x in c.split(whereSeparator: { $0.isWhitespace }) { kn.insert(N(String(x))) } }
        self.known = kn
        if let vp = vocabPath {
            let vt = try String(contentsOfFile: vp, encoding: .utf8)
            self.vocab = Set(vt.split(whereSeparator: { $0.isWhitespace }).map(String.init))
        } else {
            self.vocab = []
        }
    }

    /// 辞書にも用語集にもない語(数字・序数、辞書にある語の短縮形は除く)。sim/core.py suspicious
    func suspicious(_ w: String) -> Bool {
        let n = N(w)
        if n.isEmpty { return false }
        if Rx.numeric.firstMatch(in: n, options: [], range: fullRange(n)) != nil { return false }
        if vocab.contains(n) || known.contains(n) { return false }
        if n.contains("'"), let head = n.components(separatedBy: "'").first, vocab.contains(head) { return false }
        return true
    }

    private func fz(_ w: String) -> String {
        if termSet.contains(w) { return w }
        let wl = w.lowercased()
        for t in single {
            if String(w.first!).lowercased() == String(t.first!).lowercased()
                && abs(w.count - t.count) <= 2
                && SeqMatcher(Array(wl), Array(t.lowercased())).ratio() >= thr {
                return t
            }
        }
        return w
    }

    func correct(_ text: String) -> String {
        var out = text
        for (re, tpl) in aliasRes {
            out = re.stringByReplacingMatches(in: out, options: [], range: fullRange(out), withTemplate: tpl)
        }
        for (re, tpl) in termRes {
            out = re.stringByReplacingMatches(in: out, options: [], range: fullRange(out), withTemplate: tpl)
        }
        let ns = out as NSString
        var res = ""
        var last = 0
        for m in Rx.alpha5.matches(in: out, options: [], range: fullRange(out)) {
            res += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            res += fz(ns.substring(with: m.range))
            last = m.range.location + m.range.length
        }
        res += ns.substring(from: last)
        return res
    }
}

// MARK: - 確定・節・先出し (sim/core.py process_segment を逐次処理にしたもの)

struct ClauseRec {
    var idx: Int
    var text: String
    var n: Int
    var k0: Int
    var k1: Int
    var unit: Int? = nil
}

struct UnitRec {
    var clauses: [Int]
    var nWords: Int
    var early: Bool
}

final class Engine {
    let cfg: Cfg
    let cor: Corrector
    var file: String
    private(set) var seg = 0

    private var pend: (text: String, wall: Double)? = nil
    private var raw: [String] = []
    private var emitted: [String] = []
    private var hist: [[String]] = []
    private var clauses: [ClauseRec] = []
    private var units: [UnitRec] = []
    private var unsent: [Int] = []
    private var cur: [(w: String, k: Int)] = []
    private var unitStart: Double? = nil
    private var lastK1 = -1
    private var unstable = 0
    private var heldSince: [String: Double] = [:]   // 待っている語(位置と語)を最初に見た時刻
    private var look = false                         // 直前の語が look_conj(次の語で閉じるか決める)
    private var stamp = 0.0
    private var evs: [Ev] = []

    init(cfg: Cfg, cor: Corrector, file: String) {
        self.cfg = cfg
        self.cor = cor
        self.file = file
    }

    /// 保留中のまとめ(volatile)の時刻。tick の判断に使う
    var pendingWall: Double? { pend?.wall }

    var unstableCount: Int { unstable }

    private func ev(_ kind: String, _ extra: [String: Any]) -> Ev {
        var d = extra
        d["kind"] = kind
        d["t"] = r3(stamp)
        d["file"] = file
        d["seg"] = seg
        return d
    }

    private func take() -> [Ev] {
        let r = evs
        evs = []
        return r
    }

    private func resetSegment() {
        raw = []; emitted = []; hist = []; clauses = []; units = []
        unsent = []; cur = []; unitStart = nil; lastK1 = -1; unstable = 0; heldSince = [:]; look = false
    }

    // MARK: 入口

    /// 仮テキスト。0.3秒(coalesce)以内の更新は最後の1つにまとめる(local_agreement.py と同じ)
    func volatile(_ text: String, wall: Double) -> [Ev] {
        if let p = pend {
            if wall - p.wall < cfg.coalesce {
                pend = (text, wall)
                return []
            }
            pend = (text, wall)
            processBatch(p.text, p.wall, stamp: p.wall)
            return take()
        }
        pend = (text, wall)
        return []
    }

    /// 保留中のまとめが coalesce 秒静かだったら処理する。live で定期的に呼ぶ(照合の replay では呼ばない)
    func tick(_ now: Double) -> [Ev] {
        guard let p = pend, now - p.wall >= cfg.coalesce - 1e-9 else { return [] }
        pend = nil
        processBatch(p.text, p.wall, stamp: now)
        return take()
    }

    /// ASR の区間確定
    func finalize(_ text: String, wall: Double) -> [Ev] {
        stamp = wall
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pend = nil
            evs = []
            resetSegment()
            seg += 1
            return []
        }
        if let p = pend {
            pend = nil
            processBatch(p.text, p.wall, stamp: p.wall)
        }
        stamp = wall
        let finRaw = W(text)
        let fw = W(cfg.correct ? cor.correct(text) : text)
        let nLA = emitted.count
        if finRaw.count > raw.count { raw.append(contentsOf: finRaw[raw.count...]) }
        commit(wall, flush: true)
        if !cur.isEmpty { close() }
        if !unsent.isEmpty { send(wall, early: false, fw: fw) }

        // 古い下書き: 先に確定した語のうち、最終結果と食い違う語を含む節
        let a = emitted.prefix(nLA).map { N($0) }
        let b = fw.prefix(nLA + 3).map { N($0) }
        var ok = Set<Int>()
        for (i, _, k) in SeqMatcher(a, b, autojunk: false).matchingBlocks() {
            for x in i..<(i + k) { ok.insert(x) }
        }
        var bad = Set<Int>()
        for k in 0..<a.count where !ok.contains(k) { bad.insert(k) }
        var staleEvs: [Ev] = []
        for c in clauses {
            var isStale = false
            for k in c.k0...c.k1 where bad.contains(k) { isStale = true; break }
            if isStale { staleEvs.append(ev("clause_stale", ["idx": c.idx])) }
        }
        var res: [Ev] = [ev("seg", ["text": text.trimmingCharacters(in: .whitespacesAndNewlines)])]
        res += take()
        res += staleEvs
        seg += 1
        resetSegment()
        return res
    }

    // MARK: 内部

    private func processBatch(_ text: String, _ wall: Double, stamp s: Double) {
        stamp = s
        if unitStart == nil { unitStart = wall }
        hist.append(W(text))
        if hist.count >= cfg.K {
            let ws = Array(hist.suffix(cfg.K))
            var n = 0
            while ws.allSatisfy({ $0.count > n }) && Set(ws.map { N($0[n]) }).count == 1 { n += 1 }
            let last = ws[ws.count - 1]
            if n == last.count { n = max(n - cfg.holdLast, 0) }
            if cfg.holdUnknown > 0 { n = holdCut(last, start: raw.count, n: n, wall: wall) }
            if n > raw.count {
                raw.append(contentsOf: last[raw.count..<n])
                commit(wall, flush: false)
            }
        }
        if !unsent.isEmpty, let us = unitStart, wall - us >= cfg.earlyAfter {
            send(wall, early: true, fw: [])
        }
    }

    /// last[start..<n] の中で待つべき語の位置(辞書になく、最初に見てから holdUnknown 秒たっていない)。なければ n。sim/core.py hold_cut
    private func holdCut(_ last: [String], start: Int, n: Int, wall: Double) -> Int {
        guard start < n else { return n }
        for j in start..<n {
            let w = last[j]
            if cor.suspicious(w) {
                let key = "\(j)\t\(N(w))"
                let t0 = heldSince[key] ?? wall
                if heldSince[key] == nil { heldSince[key] = wall }
                if wall - t0 < cfg.holdUnknown { return j }
            }
        }
        return n
    }

    private func heldCount() -> Int {
        var best = 0
        for toks in cor.multi {
            var s = min(toks.count - 1, raw.count)
            while s > 0 {
                if raw.suffix(s).map({ N($0) }) == Array(toks.prefix(s)) {
                    best = max(best, s)
                    break
                }
                s -= 1
            }
        }
        return best
    }

    private func commit(_ t: Double, flush: Bool) {
        let held = (flush || !cfg.correct) ? 0 : heldCount()
        let part = Array(raw.prefix(raw.count - held))
        let c: [String] = cfg.correct ? W(cor.correct(part.joined(separator: " "))) : part
        if c.count < emitted.count {
            unstable += 1
            return
        }
        var words: [String] = []
        for w in c[emitted.count...] {
            let k = emitted.count
            emitted.append(w)
            words.append(w)
            feed(w, k)
        }
        if !words.isEmpty { evs.append(ev("commit", ["words": words, "flush": flush])) }
    }

    /// 節の区切り。sim/core.py process_segment の feed と同じ(10/29 v4: look_conj / keep_conj / smart_max)
    private func feed(_ w: String, _ k: Int) {
        let n = N(w)
        if look {
            look = false
            if (cfg.lookSubj ?? SUBJ).contains(n) && cur.count - 1 >= cfg.minClause { close(upto: cur.count - 1) }
        }
        if !cur.isEmpty && CONJ.contains(n) && !cfg.lookConj.contains(n) && !cfg.keepConj.contains(n)
            && cur.count >= cfg.minClause { close() }
        cur.append((w: w, k: k))
        let endsPunct = w.last.map { ",;.?!".contains($0) } ?? false
        if endsPunct && cur.count >= cfg.minClause { close(); return }
        if cfg.lookConj.contains(n) && !endsPunct { look = true }
        if cur.count >= cfg.maxClause + cfg.softMax {
            look = false
            if cfg.smartMax {
                var i = cur.count
                while i > cfg.minClause && DANGLING.contains(N(cur[i - 1].w)) { i -= 1 }
                if !DANGLING.contains(N(cur[i - 1].w)) { close(upto: i); return }
            }
            close()
        }
    }

    private func close(upto: Int? = nil) {
        let m = upto ?? cur.count
        let part = Array(cur.prefix(m))
        let c = ClauseRec(idx: clauses.count, text: part.map { $0.w }.joined(separator: " "), n: part.count,
                          k0: part[0].k, k1: part[part.count - 1].k)
        clauses.append(c)
        unsent.append(c.idx)
        cur.removeFirst(m)
        evs.append(ev("clause", ["idx": c.idx, "text": c.text]))
    }

    /// emitted の位置 k を、最終テキスト(fw)の「その次の語」の位置に写す(語の対応づけで。位置の数え間違いを避ける)
    private func alignedNext(_ k: Int, _ fw: [String]) -> Int {
        let a = emitted.map { N($0) }
        let b = fw.map { N($0) }
        var mp: [Int: Int] = [:]
        for (i, j, n) in SeqMatcher(a, b, autojunk: false).matchingBlocks() {
            for x in 0..<n { mp[i + x] = j + x }
        }
        var j = k
        while j >= 0 && mp[j] == nil { j -= 1 }
        return j >= 0 ? mp[j]! + 1 : 0
    }

    /// 最終訳の送信。先出しは確定済みの語、区間の最後の単位は ASR 確定テキスト(fw)の、前の単位の続きから
    private func send(_ t: Double, early: Bool, fw: [String]) {
        let k0 = clauses[unsent[0]].k0
        let k1 = clauses[unsent[unsent.count - 1]].k1
        let ks = (!early && lastK1 >= 0) ? alignedNext(lastK1, fw) : 0
        let words: [String] = early ? Array(emitted[k0...k1]) : (ks < fw.count ? Array(fw[ks...]) : [])
        var nWords = 0
        for i in unsent { nWords += clauses[i].n }
        let ui = units.count
        for i in unsent { clauses[i].unit = ui }
        units.append(UnitRec(clauses: unsent, nWords: nWords, early: early))
        evs.append(ev("final_req", [
            "unit": ui, "early": early, "n_clauses": unsent.count, "n_words": nWords,
            "en": words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines),
            "clauses": unsent,
        ]))
        unsent.removeAll()
        unitStart = t
        lastK1 = k1
    }
}
