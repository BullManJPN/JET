#!/usr/bin/env python3
"""最終訳テスト: results/final-inputs.json の各単位を Haiku で訳す。条件(--conds)を単位ごとに交互に実行。
入力 = 訳す英語 + 直前2単位の英語 + 直前の最終訳(その条件の自分の出力) [+ 用語集]。ファイルごと・条件ごとに直列(本番と同じ依存)。
キーは環境変数 ANTHROPIC_API_KEY(bench.py と同じ)。途中で止めても results/final-test-<日時>.json に残る。
使い方(リポジトリのルートで): python3 sim/final_test.py [--limit 10] [--dry-run] [--mock]"""
import argparse, json, os, sys, time, urllib.request, urllib.error
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

BASE = ("あなたは英語から日本語への同時通訳者です。入力は話者の音声を自動認識したテキストで、聞き間違いや途切れを含むことがあります。"
        "【訳す英語】だけを、自然な話し言葉の日本語(です・ます調)に訳してください。"
        "【直前の英語】と【直前の訳】は文脈の参考です。訳してはいけません。【直前の訳】の続きとして自然につながる訳にしてください。"
        "説明・注釈・前置きは書かず、日本語訳だけを出力します。")
GLOSS = ("音声認識は固有名詞や専門用語を聞き間違えることがあります。【用語集】の語に音が近い不自然な語があれば、文脈から判断して用語集の語として訳してください。"
         "文脈から確信できないときは聞こえたまま訳し、無理に用語集の語にはしないでください。用語集の語は英語のまま残します。")


ROBUST = ("音声認識の誤りで聞き取りにくい箇所があっても、必ず最善の推測で日本語訳だけを出力してください。"
          "質問・謝罪・注釈・訳せない旨の説明は絶対に書かないでください。")
KEEP_EN = "Claude, Anthropic, MCP, API, SDK などの固有名詞・IT用語は英語のまま残します。"
# none = 前回と同じ(用語集なし) / robust = 聞き取りにくくても訳だけ出す指示を追加 / robust_en = それに加えて固有名詞を英語のまま残す指示 / glossary = 前回の用語集あり


def build(cond, en, ctx_en, prev_ja, terms):
    system = BASE
    if cond == "glossary":
        system += GLOSS
    if cond in ("robust", "robust_en"):
        system += ROBUST
    if cond == "robust_en":
        system += KEEP_EN
    parts = []
    if cond == "glossary":
        parts.append("【用語集】\n" + ", ".join(terms))
    parts.append("【直前の英語】\n" + ("\n".join(ctx_en) if ctx_en else "(なし)"))
    parts.append("【直前の訳】\n" + (prev_ja or "(なし)"))
    parts.append("【訳す英語】\n" + en)
    return system, "\n\n".join(parts)


def call(model, system, user, key):
    payload = {"model": model, "max_tokens": 400, "stream": True, "system": system,
               "messages": [{"role": "user", "content": user}], "temperature": 0.2}
    headers = {"content-type": "application/json", "x-api-key": key, "anthropic-version": "2023-06-01"}

    def open_req(pl):
        return urllib.request.urlopen(urllib.request.Request(
            "https://api.anthropic.com/v1/messages", data=json.dumps(pl).encode(), headers=headers), timeout=60)
    for attempt in range(3):
        t0 = time.perf_counter()
        try:
            try:
                resp = open_req(payload)
            except urllib.error.HTTPError as e:
                body = e.read().decode("utf-8", "ignore")
                if e.code == 400 and "temperature" in body and "temperature" in payload:
                    payload.pop("temperature"); t0 = time.perf_counter(); resp = open_req(payload)
                elif e.code in (429, 500, 502, 503, 529):
                    time.sleep(2 * (attempt + 1)); continue
                else:
                    raise RuntimeError("API %s: %s" % (e.code, body[:300]))
            ttft, parts, in_tok, out_tok = None, [], 0, 0
            with resp:
                for raw in resp:
                    line = raw.decode("utf-8", "ignore").strip()
                    if not line.startswith("data:"):
                        continue
                    try:
                        o = json.loads(line[5:].strip())
                    except ValueError:
                        continue
                    t = o.get("type")
                    if t == "message_start":
                        in_tok = o.get("message", {}).get("usage", {}).get("input_tokens", 0)
                    elif t == "content_block_delta":
                        txt = o.get("delta", {}).get("text", "")
                        if txt:
                            parts.append(txt)
                            if ttft is None and txt.strip():
                                ttft = time.perf_counter() - t0
                    elif t == "message_delta":
                        out_tok = o.get("usage", {}).get("output_tokens", out_tok)
            total = time.perf_counter() - t0
            return dict(ja="".join(parts).strip().replace("\n", " "), total_ms=round(total * 1000),
                        ttft_ms=round((ttft or total) * 1000), in_tokens=in_tok, out_tokens=out_tok)
        except (urllib.error.URLError, TimeoutError) as e:
            if attempt == 2:
                raise RuntimeError("接続エラー: %s" % e)
            time.sleep(2)
    raise RuntimeError("リトライ上限")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--inputs", default="results/final-inputs.json")
    ap.add_argument("--model", default="claude-haiku-4-5-20251001")
    ap.add_argument("--conds", default="none,robust,robust_en", help="none,robust,robust_en,glossary のカンマ区切り")
    ap.add_argument("--limit", type=int, default=0, help="先頭からN単位だけ(試走用)")
    ap.add_argument("--dry-run", action="store_true", help="最初のプロンプトを表示して終了(API呼び出しなし)")
    ap.add_argument("--mock", action="store_true", help="API を呼ばず仮の出力を作る(レポートのテスト用)")
    a = ap.parse_args()
    units = json.load(open(os.path.join(ROOT, a.inputs)))
    if a.limit:
        units = units[:a.limit]
    terms = [l.strip() for l in open(os.path.join(ROOT, "asr/terms.txt")) if l.strip()]
    key = os.environ.get("ANTHROPIC_API_KEY")
    if not key and not (a.dry_run or a.mock):
        sys.exit("環境変数 ANTHROPIC_API_KEY が未設定です(bench.py と同じ)")
    conds = a.conds.split(",")
    if a.dry_run:
        for c in conds:
            s, u = build(c, units[1]["en"], [units[0]["en"]], "(前の訳の例)", terms)
            print("=== %s\n[system]\n%s\n[user]\n%s\n" % (c, s, u))
        return
    ts = time.strftime("%Y%m%d-%H%M%S")
    outp = os.path.join(ROOT, "results", "final-test-%s%s.json" % (ts, "-mock" if a.mock else ""))
    recs, hist, prev = [], {}, {}
    cur_file = None
    for u in units:
        if u["file"] != cur_file:
            cur_file = u["file"]; hist[cur_file] = []; prev = {c: "" for c in conds}
        ctx = hist[cur_file][-2:]
        row = dict(u)
        line = "[%s u%d]" % (u["file"][-12:], u["unit"])
        for c in conds:
            s, um = build(c, u["en"], ctx, prev[c], terms)
            if a.mock:
                r = dict(ja="【モック】" + u["en"], total_ms=900, ttft_ms=500, in_tokens=0, out_tokens=0)
            else:
                try:
                    r = call(a.model, s, um, key)
                except RuntimeError as e:
                    r = dict(ja="", total_ms=0, ttft_ms=0, in_tokens=0, out_tokens=0, error=str(e))
                    print("  エラー:", e)
            row[c] = r
            prev[c] = r["ja"]
            line += "  %s %dms" % (c, r["total_ms"])
        hist[cur_file].append(u["en"])
        recs.append(row)
        json.dump(dict(model=a.model, recs=recs), open(outp, "w"), ensure_ascii=False, indent=1)
        print(line, flush=True)
    print("\n保存:", os.path.relpath(outp, ROOT))


if __name__ == "__main__":
    main()
