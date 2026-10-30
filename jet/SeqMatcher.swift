import Foundation

// Python difflib.SequenceMatcher(isjunk=None) の移植。find_longest_match と get_matching_blocks を同じ手順で行う
struct SeqMatcher<E: Hashable> {
    let a: [E]
    let b: [E]
    private var b2j: [E: [Int]] = [:]

    init(_ a: [E], _ b: [E], autojunk: Bool = true) {
        self.a = a
        self.b = b
        var d: [E: [Int]] = [:]
        for (i, e) in b.enumerated() { d[e, default: []].append(i) }
        if autojunk && b.count >= 200 {
            let ntest = b.count / 100 + 1
            for (e, idxs) in d where idxs.count > ntest { d[e] = nil }
        }
        self.b2j = d
    }

    func findLongestMatch(_ alo: Int, _ ahi: Int, _ blo: Int, _ bhi: Int) -> (Int, Int, Int) {
        var besti = alo, bestj = blo, bestsize = 0
        var j2len: [Int: Int] = [:]
        var i = alo
        while i < ahi {
            var newj2len: [Int: Int] = [:]
            if let js = b2j[a[i]] {
                for j in js {
                    if j < blo { continue }
                    if j >= bhi { break }
                    let k = (j2len[j - 1] ?? 0) + 1
                    newj2len[j] = k
                    if k > bestsize {
                        besti = i - k + 1
                        bestj = j - k + 1
                        bestsize = k
                    }
                }
            }
            j2len = newj2len
            i += 1
        }
        while besti > alo && bestj > blo && a[besti - 1] == b[bestj - 1] {
            besti -= 1; bestj -= 1; bestsize += 1
        }
        while besti + bestsize < ahi && bestj + bestsize < bhi && a[besti + bestsize] == b[bestj + bestsize] {
            bestsize += 1
        }
        return (besti, bestj, bestsize)
    }

    /// 末尾のダミー (la, lb, 0) は含めない
    func matchingBlocks() -> [(Int, Int, Int)] {
        var queue: [(Int, Int, Int, Int)] = [(0, a.count, 0, b.count)]
        var mb: [(Int, Int, Int)] = []
        while let q = queue.popLast() {
            let (alo, ahi, blo, bhi) = q
            let (i, j, k) = findLongestMatch(alo, ahi, blo, bhi)
            if k > 0 {
                mb.append((i, j, k))
                if alo < i && blo < j { queue.append((alo, i, blo, j)) }
                if i + k < ahi && j + k < bhi { queue.append((i + k, ahi, j + k, bhi)) }
            }
        }
        mb.sort { ($0.0, $0.1, $0.2) < ($1.0, $1.1, $1.2) }
        var out: [(Int, Int, Int)] = []
        var i1 = 0, j1 = 0, k1 = 0
        for (i2, j2, k2) in mb {
            if i1 + k1 == i2 && j1 + k1 == j2 {
                k1 += k2
            } else {
                if k1 > 0 { out.append((i1, j1, k1)) }
                i1 = i2; j1 = j2; k1 = k2
            }
        }
        if k1 > 0 { out.append((i1, j1, k1)) }
        return out
    }

    func ratio() -> Double {
        let total = a.count + b.count
        if total == 0 { return 1.0 }
        let m = matchingBlocks().reduce(0) { $0 + $1.2 }
        return 2.0 * Double(m) / Double(total)
    }
}
