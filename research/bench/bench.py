#!/usr/bin/env python3
"""JET2 レイテンシ・ベンチマーク (標準ライブラリのみ / Python 3.8+)

使い方:
    python3 bench.py                 # config.json のモデルを全部測る
    python3 bench.py jet-8b          # 指定モデルだけ
    python3 bench.py --think on jet-8b   # 思考ON時の比較

測るもの:
    ttft_ms   : 送信 → 最初の「日本語本文」の文字が出るまで (思考トークンは除く)
    total_ms  : 送信 → 最後まで
    tok_s     : 生成速度 (Ollama の eval_count / eval_duration)
    think_chars: 思考として出た文字数 (0 なら思考オフが効いている)
"""
import json, sys, time, statistics, datetime, urllib.request, urllib.error

HERE = __import__("os").path.dirname(__import__("os").path.abspath(__file__))

SYSTEM = (
    "あなたは英語から日本語への同時通訳者です。入力された英語を、意味を変えずに自然な日本語に訳します。"
    "文が途中で終わっていても、聞こえた部分だけを訳してください。説明・注釈・前置きは一切書かず、日本語訳だけを1行で出力します。"
    "Claude, Anthropic, MCP, AGI, API, LLM, Slack, Zoom などの固有名詞・IT用語は英語のまま残します。"
)
FEWSHOT = [
    ("Thanks for coming in today.", "本日はお越しいただきありがとうございます。"),
    ("We're looking for someone who can, um, own the whole", "全体を担当できる人を探しています。"),
    ("Let's connect the model to Slack using MCP.", "MCPを使ってモデルをSlackに接続しましょう。"),
]


def build_messages(sentence):
    msgs = [{"role": "system", "content": SYSTEM}]
    for en, ja in FEWSHOT:
        msgs.append({"role": "user", "content": "英語: %s\n日本語:" % en})
        msgs.append({"role": "assistant", "content": ja})
    msgs.append({"role": "user", "content": "英語: %s\n日本語:" % sentence})
    return msgs


def post_stream(url, payload):
    req = urllib.request.Request(
        url, data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"})
    return urllib.request.urlopen(req, timeout=300)


def run_one(cfg, model, sentence, think):
    if model.startswith("claude-"):
        return run_claude(cfg, model, sentence)
    payload = {
        "model": model,
        "messages": build_messages(sentence),
        "stream": True,
        "think": think,
        "keep_alive": cfg.get("keep_alive", "30m"),
    }
    t0 = time.perf_counter()
    ttft = None
    first_think = None
    content, thinking = [], []
    final = {}
    with post_stream(cfg["ollama_url"] + "/api/chat", payload) as resp:
        for line in resp:
            if not line.strip():
                continue
            obj = json.loads(line)
            msg = obj.get("message", {})
            th = msg.get("thinking") or ""
            ct = msg.get("content") or ""
            now = time.perf_counter()
            if th:
                thinking.append(th)
                if first_think is None:
                    first_think = now - t0
            if ct:
                # 本文中に <think> が混ざる古い形式にも対応
                content.append(ct)
                if ttft is None and ct.strip():
                    ttft = now - t0
            if obj.get("done"):
                final = obj
    total = time.perf_counter() - t0
    ev_c = final.get("eval_count", 0)
    ev_d = final.get("eval_duration", 0) or 1
    text = "".join(content).strip()
    think_chars = len("".join(thinking)) + (text.count("<think>") * 1)
    has_ja = any("\u3040" <= c <= "\u30ff" or "\u4e00" <= c <= "\u9fff" for c in text)
    not_ja = (not has_ja) or text.lower().startswith(("okay", "<think", "let me", "first"))
    return {
        "not_ja": 1 if not_ja else 0,
        "ttft_ms": round((ttft or total) * 1000),
        "total_ms": round(total * 1000),
        "tok_s": round(ev_c / (ev_d / 1e9), 1) if ev_c else 0,
        "tokens": ev_c,
        "load_ms": round(final.get("load_duration", 0) / 1e6),
        "think_chars": think_chars,
        "text": text.replace("\n", " "),
    }


def run_claude(cfg, model, sentence):
    """Anthropic Messages API (ストリーミング)。キーは環境変数 ANTHROPIC_API_KEY から読む。"""
    import os
    key = os.environ.get("ANTHROPIC_API_KEY")
    if not key:
        raise RuntimeError("環境変数 ANTHROPIC_API_KEY が未設定です")
    msgs = build_messages(sentence)
    system = msgs[0]["content"]
    payload = {"model": model, "max_tokens": 200, "stream": True, "system": system,
               "messages": msgs[1:], "temperature": 0.2}
    url = cfg.get("anthropic_url", "https://api.anthropic.com") + "/v1/messages"
    headers = {"content-type": "application/json", "x-api-key": key,
               "anthropic-version": "2023-06-01"}

    def open_req(pl):
        return urllib.request.urlopen(urllib.request.Request(
            url, data=json.dumps(pl).encode("utf-8"), headers=headers), timeout=60)

    t0 = time.perf_counter()
    try:
        resp = open_req(payload)
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "ignore")
        if e.code == 400 and "temperature" in body:   # temperature 非対応モデル
            payload.pop("temperature")
            t0 = time.perf_counter()
            resp = open_req(payload)
        else:
            raise RuntimeError("API %s: %s" % (e.code, body[:300]))
    ttft, out_tokens, parts = None, 0, []
    with resp:
        for raw in resp:
            line = raw.decode("utf-8", "ignore").strip()
            if not line.startswith("data:"):
                continue
            try:
                obj = json.loads(line[5:].strip())
            except ValueError:
                continue
            t = obj.get("type")
            if t == "content_block_delta":
                txt = obj.get("delta", {}).get("text", "")
                if txt:
                    parts.append(txt)
                    if ttft is None and txt.strip():
                        ttft = time.perf_counter() - t0
            elif t == "message_delta":
                out_tokens = obj.get("usage", {}).get("output_tokens", out_tokens)
    total = time.perf_counter() - t0
    text = "".join(parts).strip()
    gen = max(total - (ttft or 0), 1e-6)
    has_ja = any("\u3040" <= c <= "\u30ff" or "\u4e00" <= c <= "\u9fff" for c in text)
    return {"not_ja": 0 if has_ja else 1, "ttft_ms": round((ttft or total) * 1000),
            "total_ms": round(total * 1000),
            "tok_s": round(out_tokens / gen, 1) if out_tokens else 0, "tokens": out_tokens,
            "load_ms": 0, "think_chars": 0, "text": text.replace("\n", " ")}


def vram_info(cfg, model):
    if model.startswith("claude-"):
        return "API"
    try:
        with urllib.request.urlopen(cfg["ollama_url"] + "/api/ps", timeout=10) as r:
            for m in json.load(r).get("models", []):
                if m.get("name", "").startswith(model.split(":")[0]) or m.get("model") == model:
                    return "%.1fGB (VRAM %.1fGB)" % (m["size"] / 1e9, m.get("size_vram", 0) / 1e9)
    except Exception:
        pass
    return "-"


def main():
    args = sys.argv[1:]
    think = None
    cfg = json.load(open(HERE + "/config.json", encoding="utf-8"))
    think = bool(cfg.get("think", False))
    if "--think" in args:
        i = args.index("--think")
        think = args[i + 1] == "on"
        del args[i:i + 2]
    infile = "sentences.txt"
    if "--input" in args:
        i = args.index("--input")
        infile = args[i + 1]
        del args[i:i + 2]
    models = args or cfg["models"]
    sentences = [s.strip() for s in open(HERE + "/" + infile, encoding="utf-8") if s.strip()]
    runs = int(cfg.get("runs_per_sentence", 1))

    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    out_md = ["# JET2 bench %s  (think=%s)\n" % (stamp, "ON" if think else "OFF")]
    summary = []
    raw = []

    for model in models:
        print("\n=== %s ===" % model)
        try:
            w = run_one(cfg, model, "Hello.", think)  # ウォームアップ(モデル読込)
            print("  warm-up: load %d ms, total %d ms" % (w["load_ms"], w["total_ms"]))
        except urllib.error.URLError as e:
            print("  接続できません: %s  (ollama serve が動いているか確認)" % e)
            return 1
        except urllib.error.HTTPError as e:
            print("  エラー: %s %s" % (e.code, e.read().decode("utf-8", "ignore")[:200]))
            continue
        except RuntimeError as e:
            print("  エラー: %s" % e)
            continue
        rows = []
        for s in sentences:
            for _ in range(runs):
                r = run_one(cfg, model, s, think)
                rows.append(r)
                raw.append(dict(model=model, en=s, **r))
                print("  ttft %5d ms | total %5d ms | %5.1f tok/s | think %4d | %s"
                      % (r["ttft_ms"], r["total_ms"], r["tok_s"], r["think_chars"], r["text"][:60]))
        mem = vram_info(cfg, model)
        ttfts = [r["ttft_ms"] for r in rows]
        totals = [r["total_ms"] for r in rows]
        summary.append((model, statistics.median(ttfts), max(ttfts), statistics.median(totals),
                        statistics.median([r["tok_s"] for r in rows]),
                        sum(r["think_chars"] for r in rows), mem, sum(r["not_ja"] for r in rows), len(rows)))
        out_md.append("\n## %s\n\n| # | EN | JA | TTFT ms | total ms | tok/s |\n|---|---|---|---|---|---|" % model)
        for i, (s, r) in enumerate(zip([x for x in sentences for _ in range(runs)], rows), 1):
            out_md.append("| %d | %s | %s | %d | %d | %s |" % (i, s, r["text"], r["ttft_ms"], r["total_ms"], r["tok_s"]))

    print("\n==== 要約 (think=%s) ====" % ("ON" if think else "OFF"))
    head = "%-34s %9s %9s %10s %7s %9s %9s  %s" % ("model", "TTFT中央", "TTFT最大", "total中央", "tok/s", "think字数", "非日本語", "メモリ")
    print(head)
    out_md.insert(1, "\n## 要約\n\n| model | TTFT中央 ms | TTFT最大 ms | total中央 ms | tok/s | think字数 | 非日本語出力 | メモリ |\n|---|---|---|---|---|---|---|---|")
    for i, (m, a, b, c, d, e, mem, nj, n) in enumerate(summary):
        print("%-34s %9d %9d %10d %7.1f %9d %6d/%-2d  %s" % (m, a, b, c, d, e, nj, n, mem))
        out_md.insert(2 + i, "| %s | %d | %d | %d | %.1f | %d | %d/%d | %s |" % (m, a, b, c, d, e, nj, n, mem))

    base = "%s/results/bench-%s-think%s" % (HERE, stamp, "on" if think else "off")
    open(base + ".md", "w", encoding="utf-8").write("\n".join(out_md) + "\n")
    json.dump(raw, open(base + ".json", "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print("\n保存: %s.md / .json" % base)
    return 0


if __name__ == "__main__":
    sys.exit(main())
