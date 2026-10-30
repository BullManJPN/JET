#!/usr/bin/env python3
"""JET 3層表示のタイミング・シミュレーター(訳は呼ばず、所要時間だけ再現)。
 英語表示: LocalAgreement + 用語補正 / 下書き訳: 節が閉じたら AFM(1本ずつ処理、待ち行列あり) / 最終訳: ASR確定時(長い区間は8秒超で先出し)、
 直前の最終訳を入力に使うので最終訳は直列。所要時間は results/ の実測値から抽選(--lat median で中央値の固定値)。
使い方(リポジトリのルートで): python3 sim/jet_sim.py [-v] [--K 2] [--hold-last 1] [--no-correct] [--early-after 8] [--lat empirical|median] [--seed 0] [--files 'logs/x*.jsonl']
出力: 標準出力にサマリ / results/sim-<日時>[-tag].md(サマリ+時系列) / .jsonl(イベント)
回帰確認: --hold-last 0 --no-correct で local_agreement.py と同じ英語表示の数字になる"""
import argparse, glob, json, os, random, statistics as st, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import core

ROOT = core.ROOT
DRAFT_POOL = "results/bench-20261028-103825-thinkoff-afm-chunk-noctx.json"
FINAL_POOL = "results/bench-20261028-095900-thinkoff.json"


def pool(path):
    d = json.load(open(os.path.join(ROOT, path)))
    return [x["total_ms"] / 1000 for x in d if x.get("total_ms")]


def q(xs, p):
    s = sorted(xs)
    return s[min(len(s) - 1, int(len(s) * p))]


def stat(xs, unit="s"):
    if not xs:
        return "n=0"
    return "中央値 %.2f / p90 %.2f / 最大 %.2f %s (n=%d)" % (st.median(xs), q(xs, .9), max(xs), unit, len(xs))


def render(e):
    k = e["kind"]
    if k == "seg":
        return "---- seg%d 話者区間 %.1f-%.1fs  ASR確定  %s" % (e["idx"], e["a0"], e["a1"], e["text"])
    if k == "commit":
        return "EN     +%s%s" % (" ".join(e["words"]), "   (ASR確定で残りを確定)" if e["flush"] else "")
    if k == "clause":
        return "CLAUSE #%d 閉じる \"%s\"  (話し終え推定 %.2f)" % (e["idx"], e["text"], e["spoken_end"])
    if k == "draft":
        return "DRAFT  #%d 完了  開始%.2f 待ち%.2fs 所要%.2fs%s" % (e["idx"], e["start"], e["wait"], e["lat"], "  ガードレール→英語表示" if e["guard"] else "")
    if k == "final_req":
        return "FINAL? 送信%s 節%d 語%d" % ("(先出し)" if e["early"] else "", e["n_clauses"], e["n_words"])
    if k == "final":
        return "FINAL  完了%s  開始%.2f 待ち%.2fs 所要%.2fs" % ("(先出し)" if e["early"] else "", e["start"], e["wait"], e["lat"])
    return str(e)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--files", nargs="*")
    ap.add_argument("--K", type=int, default=2)
    ap.add_argument("--hold-last", type=int, default=1)
    ap.add_argument("--max-clause", type=int, default=14)
    ap.add_argument("--early-after", type=float, default=8.0)
    ap.add_argument("--no-correct", action="store_true")
    ap.add_argument("--lat", choices=["empirical", "median"], default="empirical")
    ap.add_argument("--guard", type=float, default=0.02, help="下書きがガードレールで止まる確率")
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--tag", default="")
    ap.add_argument("-v", action="store_true", help="時系列を標準出力にも出す")
    a = ap.parse_args()

    cfg = core.Cfg(K=a.K, hold_last=a.hold_last, max_clause=a.max_clause, early_after=a.early_after, correct=not a.no_correct)
    T, A, multi = core.load_terms()
    dp, fp = pool(DRAFT_POOL), pool(FINAL_POOL)
    rng = random.Random(a.seed)
    draw = (lambda p: rng.choice(p)) if a.lat == "empirical" else (lambda p: st.median(p))
    files = []
    for pat in (a.files or ["logs/asr-20261028-*-mic.jsonl"]):
        files += sorted(glob.glob(pat if os.path.isabs(pat) else os.path.join(ROOT, pat)))
    if not files:
        sys.exit("ログが見つかりません")

    M = {k: [] for k in ["lag_la", "lag_fin", "close_lag", "draft_wait", "draft_lag", "final_wait", "final_lag",
                         "draft_lead", "first_ja", "first_draft", "short_first_ja"]}
    C = dict(files=0, segs=0, words=0, la=0, bad=0, clauses=0, stale=0, guard=0, units=0, early=0, short=0, unstable=0, final_queued=0, draft_queued=0)
    allev = []

    for path in files:
        C["files"] += 1
        name = os.path.basename(path).replace("asr-", "").replace(".jsonl", "")
        draft_free = final_free = 0.0
        fev = []
        for si, (batches, fin) in enumerate(core.load_segments(path)):
            if not fin["text"].strip():
                continue
            R = core.process_segment(batches, fin, cfg, T, A, multi)
            C["segs"] += 1; C["words"] += len(R["emitted"]); C["la"] += R["n_la"]; C["bad"] += len(R["bad"]); C["unstable"] += R["unstable"]
            for k, t in enumerate(R["etime"]):
                (M["lag_la"] if k < R["n_la"] else M["lag_fin"]).append(t - R["spoken"][k])
            ev = [dict(t=fin["wall"], kind="seg", idx=si, a0=R["a0"], a1=R["a1"], text=fin["text"].strip())] + R["events"]
            ja_times, draft_times = [], []
            for c in R["clauses"]:
                start = max(c["t_close"], draft_free)
                lat = draw(dp)
                done = start + lat
                draft_free = done
                guard = rng.random() < a.guard
                c.update(d_start=start, d_done=done, guard=guard)
                C["clauses"] += 1; C["stale"] += c["stale"]; C["guard"] += guard
                C["draft_queued"] += start - c["t_close"] > 0.01
                M["close_lag"].append(c["t_close"] - c["spoken_end"])
                M["draft_wait"].append(start - c["t_close"])
                M["draft_lag"].append(done - c["spoken_end"])
                if not guard:
                    draft_times.append(done); ja_times.append(done)
                ev.append(dict(t=done, kind="draft", idx=c["idx"], start=start, wait=start - c["t_close"], lat=lat, guard=guard))
            for ui, u in enumerate(R["units"]):
                start = max(u["t_trigger"], final_free)
                lat = draw(fp)
                done = start + lat
                final_free = done
                u["done"] = done
                C["units"] += 1; C["early"] += u["early"]; C["final_queued"] += start - u["t_trigger"] > 0.01
                M["final_wait"].append(start - u["t_trigger"])
                M["final_lag"].append(done - u["spoken_end"])
                ja_times.append(done)
                ev.append(dict(t=done, kind="final", early=u["early"], start=start, wait=start - u["t_trigger"], lat=lat))
            for c in R["clauses"]:
                if not c["guard"] and c["unit"] is not None:
                    M["draft_lead"].append(R["units"][c["unit"]]["done"] - c["d_done"])
            if ja_times:
                M["first_ja"].append(min(ja_times) - R["a0"])
                if R["a1"] - R["a0"] < 1.0:
                    C["short"] += 1; M["short_first_ja"].append(min(ja_times) - R["a0"])
            if draft_times:
                M["first_draft"].append(min(draft_times) - R["a0"])
            fev += ev
        fev.sort(key=lambda e: e["t"])
        for e in fev:
            allev.append(dict(file=name, **e))

    L = []
    p = L.append
    p("対象: %d本 / %d区間 / %d語   設定: K=%d hold_last=%d 用語補正=%s 先出し>%gs 所要時間=%s seed=%d" % (
        C["files"], C["segs"], C["words"], cfg.K, cfg.hold_last, "なし" if a.no_correct else "あり", cfg.early_after, a.lat, a.seed))
    p("")
    p("【英語表示】全 %d 語: 仮テキストで先に確定 %d 語 (%.0f%%) / ASR確定まで待った語 %d" % (
        C["words"], C["la"], 100 * C["la"] / max(1, C["words"]), C["words"] - C["la"]))
    p("  先に確定した語のうち最終結果と食い違い: %d (%.1f%%)" % (C["bad"], 100 * C["bad"] / max(1, C["la"])))
    p("  遅れ(推定・話してから) 全体      : " + stat(M["lag_la"] + M["lag_fin"]))
    p("  遅れ 先行確定の語               : " + stat(M["lag_la"]))
    p("  遅れ ASR確定待ちの語            : " + stat(M["lag_fin"]))
    p("【節】%d 節 / 平均 %.1f 語   閉じるまで(話し終えてから): %s" % (
        C["clauses"], C["words"] / max(1, C["clauses"]), stat(M["close_lag"])))
    p("【下書き】ガードレール停止(英語表示) %d 節 (%.1f%%)" % (C["guard"], 100 * C["guard"] / max(1, C["clauses"])))
    p("  待ち行列で待った節 %d / 待ち時間 : %s" % (C["draft_queued"], stat(M["draft_wait"])))
    p("  下書きが出るまで(節を話し終えてから): " + stat(M["draft_lag"]))
    p("  古い下書き(節の英語が最終結果と食い違い): %d / %d 節 (%.1f%%)" % (C["stale"], C["clauses"], 100 * C["stale"] / max(1, C["clauses"])))
    p("【最終訳】%d 回 (先出し %d) / 直列待ちが出た %d 回   待ち時間: %s" % (C["units"], C["early"], C["final_queued"], stat(M["final_wait"])))
    p("  最終訳が出るまで(単位を話し終えてから): " + stat(M["final_lag"]))
    p("  下書きが最終訳より早い時間      : " + stat(M["draft_lead"]))
    p("【最初の日本語】区間の話し始めから: " + stat(M["first_ja"]))
    p("  下書きだけで見ると               : " + stat(M["first_draft"]))
    p("  1秒未満の区間 %d 件(最初の日本語): %s" % (C["short"], stat(M["short_first_ja"])))
    if C["unstable"]:
        p("  [注意] 用語補正で確定済みの語が変わった回数: %d" % C["unstable"])
    summary = "\n".join(L)
    print(summary)

    ts = time.strftime("%Y%m%d-%H%M%S") + ("-" + a.tag if a.tag else "")
    base = os.path.join(ROOT, "results", "sim-" + ts)
    with open(base + ".jsonl", "w") as f:
        for e in allev:
            f.write(json.dumps(e, ensure_ascii=False) + "\n")
    trace, cur = [], None
    for e in allev:
        if e["file"] != cur:
            cur = e["file"]; trace.append("\n=== %s" % cur)
        trace.append("%7.2f  %s" % (e["t"], render(e)))
    with open(base + ".md", "w") as f:
        f.write("# JET シミュレーター結果 %s\n\n```\n%s\n```\n\n## 時系列\n\n```%s\n```\n" % (ts, summary, "\n".join(trace)))
    if a.v:
        print("\n".join(trace))
    print("\n保存: results/sim-%s.md / .jsonl" % ts)


if __name__ == "__main__":
    main()
