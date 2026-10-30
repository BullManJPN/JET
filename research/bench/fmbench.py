#!/usr/bin/env python3
"""fm コマンド経由で Apple Foundation Models (端末内 / PCC) の翻訳の速さと訳を測る。
使い方: python3 fmbench.py --input research/sentences.txt --model pcc
        python3 fmbench.py --input research/sentences.txt --model on-device   (fm を通したときの余分な時間の確認用)
出力: results/bench-<日時>-thinkoff-fm-<model>.json (compare.py で読める形式)
プロンプトは afmbench.swift と同じ。"""
import json, os, sys, time, subprocess, datetime, statistics as st, re

HERE = os.path.dirname(os.path.abspath(__file__))
SYSTEM = ("あなたは英語から日本語への同時通訳者です。入力された英語を、意味を変えずに自然な日本語に訳します。"
          "文が途中で終わっていても、聞こえた部分だけを訳してください。説明・注釈・前置きは一切書かず、日本語訳だけを1行で出力します。"
          "Claude, Anthropic, MCP, AGI, API, LLM, SDK, Slack, Zoom などの固有名詞・IT用語は英語のまま残します。")
FEWSHOT = [("Thanks for coming in today.", "本日はお越しいただきありがとうございます。"),
           ("We're looking for someone who can, um, own the whole", "全体を担当できる人を探しています。"),
           ("Let's connect the model to Slack using MCP.", "MCPを使ってモデルをSlackに接続しましょう。")]

def prompt(s):
    p = "".join("英語: %s\n日本語: %s\n\n" % (en, ja) for en, ja in FEWSHOT)
    return p + "英語: %s\n日本語:" % s

def has_ja(t): return bool(re.search(r"[぀-ヿ一-鿿]", t))

def run(s, model):
    cmd = ["fm", "respond", "--instructions", SYSTEM, prompt(s)]
    if model == "pcc": cmd[2:2] = ["--model", "pcc"]
    t0 = time.perf_counter(); first = None; buf = b""
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    while True:
        b = os.read(p.stdout.fileno(), 4096)
        if not b: break
        if first is None and b.strip(): first = time.perf_counter() - t0
        buf += b
    err = p.stderr.read().decode("utf-8", "replace").strip()
    p.wait()
    total = time.perf_counter() - t0
    out = buf.decode("utf-8", "replace").strip().replace("\n", " ")
    return out, (first or total) * 1000, total * 1000, (err if p.returncode else "")

def main():
    a = sys.argv[1:]
    inp = a[a.index("--input") + 1] if "--input" in a else "sentences.txt"
    model = a[a.index("--model") + 1] if "--model" in a else "pcc"
    sents = [l.strip() for l in open(os.path.join(HERE, inp), encoding="utf-8") if l.strip()]
    name = "fm-" + model
    print("入力: %s %d 文 / model=%s" % (inp, len(sents), model))
    o, f, t, e = run("Hello.", model)
    print("ウォームアップ: %.0f ms → %s %s" % (t, o, ("エラー: " + e) if e else ""))
    if e: sys.exit(1)
    rows, firsts, totals = [], [], []
    for s in sents:
        o, f, t, e = run(s, model)
        bad = (not e) and not has_ja(o)
        rows.append({"model": name, "en": s, "ttft_ms": int(f), "total_ms": int(t), "tok_s": 0, "tokens": 0,
                     "load_ms": 0, "think_chars": 0, "text": ("(エラー) " + e[:200]) if e else o,
                     "not_ja": 1 if (bad or e) else 0, **({"error": e} if e else {})})
        if not e: firsts.append(f); totals.append(t)
        print("  %5.0f / %5.0f ms | %s" % (f, t, ("(エラー) " + e[:120]) if e else o))
        if e and "quota" in e.lower(): print("利用枠に達したため中止"); break
    print("\n==== 要約 ====")
    if totals:
        ts = sorted(totals)
        print("最初の出力 中央値 %.0f ms / total 中央値 %.0f ms / p90 %.0f ms / 最大 %.0f ms" % (
            st.median(firsts), st.median(ts), ts[int(len(ts) * .9)], ts[-1]))
    print("エラー: %d / 非日本語: %d / 全 %d 件" % (sum(1 for r in rows if r.get("error")),
          sum(r["not_ja"] for r in rows if not r.get("error")), len(rows)))
    out = os.path.join(HERE, "results", "bench-%s-thinkoff-%s.json" % (datetime.datetime.now().strftime("%Y%m%d-%H%M%S"), name))
    json.dump(rows, open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print("保存:", out)

if __name__ == "__main__":
    main()
