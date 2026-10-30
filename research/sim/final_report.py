#!/usr/bin/env python3
"""final_test.py の結果から、用語集なし/ありの比較表(Markdown)と自動判定のサマリを作る。
自動判定は目安です(下の SUSPECT = 既知の誤認識パターン、JA側に Claude 等が出たかを機械的に見る)。最終判断は目視で。
使い方(リポジトリのルートで): python3 sim/final_report.py [results/final-test-*.json]  (省略時は最新)"""
import glob, json, os, re, statistics as st, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
path = sys.argv[1] if len(sys.argv) > 1 else sorted(g for g in glob.glob(os.path.join(ROOT, "results/final-test-*.json")))[-1]
D = json.load(open(path)); R = D["recs"]
LABEL = {"none": "旧プロンプト", "robust": "新(訳だけ出す)", "robust_en": "新+英語のまま", "glossary": "用語集あり"}
CONDS = [c for c in LABEL if c in R[0]]
CLAUDE_LIKE = re.compile(r"\b(cla|claod|claoud|claed|claots?|clod|clawed?|claw|clan|quad|quads)\b", re.I)
OTHER_SUSPECT = re.compile(r"\b(odd relations|pod models|god to practice|spk|covid related|researchch|longerer|compututees)\b", re.I)
META = re.compile(r"申し訳|【訳す英語】|確認していただ|お願いします|ご確認")
HAS_JA = lambda t: bool(re.search(r"[぀-ヿ一-鿿]", t))

def q(xs, p): s = sorted(xs); return s[min(len(s) - 1, int(len(s) * p))]
def stat(xs): return "中央値 %d / p90 %d / 最大 %d ms (n=%d)" % (st.median(xs), q(xs, .9), max(xs), len(xs)) if xs else "n=0"

def flags(r, c):
    f = []
    ja = r[c]["ja"]; w = max(1, r["n_words"])
    if r[c].get("error"): f.append("エラー")
    elif not HAS_JA(ja): f.append("日本語なし")
    else:
        ratio = len(ja) / w
        if ratio > 4.5: f.append("長すぎ(文脈を訳した?)")
        if ratio < 0.8: f.append("短すぎ(訳抜け?)")
    if META.search(ja) and not META.search(r["en"]): f.append("メタ応答?")
    if "クラウド" in ja: f.append("クラウド")
    return f

L = []; p = L.append
p("# 最終訳テスト 比較表  (%s / %s)\n" % (os.path.basename(path), D.get("model")))
p("## 自動サマリ(目安)\n")
p("対象: %d 単位 (先出し %d)\n" % (len(R), sum(r["early"] for r in R)))
p("| 項目 | " + " | ".join(LABEL[c] for c in CONDS) + " |"); p("|---|" + "---|" * len(CONDS))
p("| 所要時間(全体) | " + " | ".join(stat([r[c]["total_ms"] for r in R if not r[c].get("error")]) for c in CONDS) + " |")
p("| 最初の文字まで | " + " | ".join(stat([r[c]["ttft_ms"] for r in R if not r[c].get("error")]) for c in CONDS) + " |")
p("| 入力トークン(平均) | " + " | ".join("%d" % st.mean([r[c]["in_tokens"] for r in R]) for c in CONDS) + " |")
p("| 出力の日本語文字数/英語1語(中央値) | " + " | ".join("%.1f" % st.median([len(r[c]["ja"]) / max(1, r["n_words"]) for r in R]) for c in CONDS) + " |")
for name, fn in (("メタ応答(詫び・質問など)らしい単位", lambda r, c: "メタ応答?" in flags(r, c)), ("出力に英単語を含む単位", lambda r, c: bool(re.search(r"[A-Za-z]{3,}", r[c]["ja"]))), ("異常フラグ付き単位", lambda r, c: bool(flags(r, c))), ("「クラウド」を含む", lambda r, c: "クラウド" in r[c]["ja"])):
    p("| %s | " % name + " | ".join("%d" % sum(fn(r, c) for r in R) for c in CONDS) + " |")
cn = [r for r in R if re.search(r"\bClaude", r["en"])]
p("| 英語に Claude を含む %d 単位: 訳が英語の「Claude」 / 「クロード」 | " % len(cn) + " | ".join("%d / %d" % (sum("Claude" in r[c]["ja"] for r in cn), sum("クロード" in r[c]["ja"] for r in cn)) for c in CONDS) + " |")
cl = [r for r in R if CLAUDE_LIKE.search(r["en"])]
p("| Claude系の誤認識を含む単位で、訳に Claude が出た | " + " | ".join("%d / %d" % (sum("Claude" in r[c]["ja"] for r in cl), len(cl)) for c in CONDS) + " |")
ot = [r for r in R if OTHER_SUSPECT.search(r["en"])]
p("| その他の既知の誤認識を含む単位(目視で確認) | " + " | ".join("%d" % len(ot) for c in CONDS) + " |")
p("\n※ 自動判定は目安です。下の表で、⚠印の単位を中心に目視で確認してください。\n"); SUMMARY_END = len(L)

def row(r):
    mark = "⚠ " if (CLAUDE_LIKE.search(r["en"]) or OTHER_SUSPECT.search(r["en"])) else ""
    cells = []
    for c in CONDS:
        fl = flags(r, c)
        cells.append(r[c]["ja"].replace("|", "/") + ("  **[%s]**" % ",".join(fl) if fl else ""))
    return "| %s%s u%d%s | %s | %s |" % (mark, r["file"][-12:-4], r["unit"], " 先出し" if r["early"] else "", r["en"].replace("|", "/"), " | ".join(cells))

hdr = ["| 単位 | 英語(ASR・用語補正後) | " + " | ".join(LABEL[c] for c in CONDS) + " |", "|---|---|" + "---|" * len(CONDS)]
p("## ⚠ 誤認識を含む単位\n"); L.extend(hdr)
for r in R:
    if CLAUDE_LIKE.search(r["en"]) or OTHER_SUSPECT.search(r["en"]): p(row(r))
p("\n## 異常フラグが付いた単位(⚠以外)\n"); L.extend(hdr)
for r in R:
    if not (CLAUDE_LIKE.search(r["en"]) or OTHER_SUSPECT.search(r["en"])) and any(flags(r, c) for c in CONDS): p(row(r))
p("\n## 全単位(時系列)\n"); L.extend(hdr)
for r in R: p(row(r))
out = path.replace(".json", ".md")
open(out, "w").write("\n".join(L) + "\n")
print("\n".join(L[:SUMMARY_END]))
print("\n保存:", os.path.relpath(out, ROOT))
