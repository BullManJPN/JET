#!/usr/bin/env python3
"""下書きベンチ(jetcli --draft-bench)の出力を Haiku で採点し、条件を比べる。
判定(英語に書かれている内容が基準。英語自体の聞き間違いは減点しない):
  A 趣旨が正しく伝わる / B 一部ずれるが筋は追える / C 意味が違う・意味不明・英語にない内容 / E 安全策で英語を表示(採点しない)
同じ(英語, 日本語)の組は results/draft-judge-cache.json に記録して使い回す(条件の間で同じ訳は同じ判定になる)。
使い方(リポジトリのルートで、ANTHROPIC_API_KEY のある Terminal):
  python3 sim/draft_score.py results/draft-base-*.jsonl                 1つの条件の採点
  python3 sim/draft_score.py results/draft-base-*.jsonl results/draft-greedy-*.jsonl   比べる(先頭が基準)
  --limit N(先頭N件だけ) --dry-run(プロンプトを表示して終了) --model(採点のモデル)"""
import argparse, json, os, sys, time, urllib.request, urllib.error
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE = os.path.join(ROOT, "results", "draft-judge-cache-v2.json")   # v2: 英語の聞き間違いの印(asr)つき

SYSTEM = (
    "あなたは英日翻訳の評価者です。各項目は、英語の音声認識テキスト(聞き間違いや文の途中での切れを含む)と、"
    "それを同時通訳の下書きとして訳した日本語です。英語に書かれている内容を基準に、日本語訳を次の3段階で判定します。\n"
    "A: 趣旨が正しく伝わる。多少不自然・直訳調でもよい\n"
    "B: 一部の語句がずれる・抜けるが、話の筋は追える\n"
    "C: 意味が違う(否定・比較・数量・主語と目的語の逆転など)、意味が通らない、英語にない内容が混ざる、別の文が出ている\n"
    "asr: 英語自体が音声認識の聞き間違いで、英語として意味が通らない(またはありえない語を含む)なら true、普通の英語なら false。"
    "文の途中で切れているだけなら false です。\n"
    "重要: label は、英語に書かれている字面を基準に判定します。asr が true でも、その字面に忠実に訳していれば A または B です。"
    "話者が本当に言いたかった語を推測できていないことは減点しません。文の途中で切れた英語は、その断片の範囲で判定します。"
    "Claude, MLX, API などの固有名詞・IT用語が英語のまま残っているのは正しい扱いです。です・ます調かどうかは問いません。\n"
    "出力は JSON 配列だけ: [{\"i\": 番号, \"asr\": true か false, \"label\": \"A\" か \"B\" か \"C\", \"note\": \"B・C のときだけ 10〜30字で理由\"}]"
)


def call(model, system, user, key):
    payload = {"model": model, "max_tokens": 4000, "temperature": 0, "system": system,
               "messages": [{"role": "user", "content": user}]}
    headers = {"content-type": "application/json", "x-api-key": key, "anthropic-version": "2023-06-01"}
    for attempt in range(4):
        try:
            req = urllib.request.Request("https://api.anthropic.com/v1/messages", data=json.dumps(payload).encode(), headers=headers)
            with urllib.request.urlopen(req, timeout=120) as r:
                o = json.loads(r.read().decode())
            return "".join(b.get("text", "") for b in o.get("content", []))
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8", "ignore")
            if e.code in (429, 500, 502, 503, 529) and attempt < 3:
                time.sleep(3 * (attempt + 1)); continue
            raise RuntimeError("API %s: %s" % (e.code, body[:300]))
        except (urllib.error.URLError, TimeoutError) as e:
            if attempt == 3:
                raise RuntimeError("接続エラー: %s" % e)
            time.sleep(3)
    raise RuntimeError("リトライ上限")


def parse(text):
    a, b = text.find("["), text.rfind("]")
    if a < 0 or b < 0:
        return {}
    try:
        arr = json.loads(text[a:b + 1])
    except ValueError:
        return {}
    out = {}
    for x in arr:
        try:
            lab = str(x.get("label", "")).strip().upper()[:1]
            if lab and lab in "ABC":
                out[int(x["i"])] = (lab, str(x.get("note", "")), bool(x.get("asr", False)))
        except (KeyError, ValueError, TypeError):
            pass
    return out


def load(path):
    meta, recs = {}, []
    for l in open(path, encoding="utf-8"):
        if not l.strip():
            continue
        o = json.loads(l)
        if o.get("kind") == "meta":
            meta = o
        else:
            recs.append(o)
    return meta, recs


def key_of(r):
    return r["en"] + "\t" + (r.get("ja") or "")


def judge_all(files, model, apikey, batch, cache):
    todo, seen = [], set()
    for _, recs in files:
        for r in recs:
            if r.get("guard"):
                continue
            k = key_of(r)
            if k not in cache and k not in seen:
                seen.add(k); todo.append(r)
    if not todo:
        return
    print("採点: %d 組(新しいもの)を %d 件ずつ %s で" % (len(todo), batch, model))
    for s in range(0, len(todo), batch):
        chunk = todo[s:s + batch]
        items = [{"i": i + 1, "en": r["en"], "ja": r.get("ja", "")} for i, r in enumerate(chunk)]
        user = "次の各項目を判定してください。\n" + json.dumps(items, ensure_ascii=False, indent=0)
        got = {}
        for attempt in range(2):
            got = parse(call(model, SYSTEM, user, apikey))
            if len(got) >= len(chunk):
                break
        for i, r in enumerate(chunk):
            lab = got.get(i + 1)
            if lab:
                cache[key_of(r)] = lab
        json.dump(cache, open(CACHE, "w"), ensure_ascii=False)
        print("  %d / %d" % (min(s + batch, len(todo)), len(todo)))


def label(r, cache):
    if r.get("guard"):
        return ("E", "", None)
    v = tuple(cache.get(key_of(r), ("?", "", None)))
    return v if len(v) == 3 else (v[0], v[1], None)


def asr_bad(r, cache):
    """英語が聞き間違いで崩れているか。どの条件でも同じ英語なので、その英語のどれかの判定で true があれば true"""
    return ASR_BAD.get(r["en"], False)


ASR_BAD = {}


def shown(r):
    return "(英語表示)" if r.get("guard") else (r.get("ja") or "")


def pctl(a, p):
    a = sorted(a)
    return a[min(len(a) - 1, int(len(a) * p))] if a else 0


def summary(name, meta, recs, cache):
    labs = [label(r, cache)[0] for r in recs]
    n = len(recs) or 1
    c = {k: labs.count(k) for k in "ABCE?"}
    clean = [label(r, cache)[0] for r in recs if not asr_bad(r, cache)]
    nc = len(clean) or 1
    lat = [r.get("lat", 0) for r in recs]
    echo = sum(1 for r in recs if r.get("echo"))
    return dict(name=name, n=len(recs), A=c["A"], B=c["B"], C=c["C"], E=c["E"], Q=c["?"],
                nclean=len(clean), cread=(clean.count("A") + clean.count("B")) / nc * 100,
                cA=clean.count("A") / nc * 100, cC=clean.count("C") / nc * 100,
                read=(c["A"] + c["B"]) / n * 100, cpct=c["C"] / n * 100,
                med=sorted(lat)[len(lat) // 2] * 1000 if lat else 0, p90=pctl(lat, 0.9) * 1000, echo=echo,
                greedy=meta.get("greedy"), fewshot=meta.get("fewshot"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="+")
    ap.add_argument("--model", default="claude-haiku-4-5-20251001")
    ap.add_argument("--batch", type=int, default=25)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    files = []
    for p in a.files:
        meta, recs = load(p)
        if a.limit:
            recs = recs[:a.limit]
        files.append((meta, recs))
    if a.dry_run:
        r = files[0][1][:3]
        print("[system]\n" + SYSTEM + "\n\n[user]\n" + json.dumps([{"i": i + 1, "en": x["en"], "ja": x.get("ja", "")} for i, x in enumerate(r)], ensure_ascii=False, indent=0))
        return
    key = os.environ.get("ANTHROPIC_API_KEY")
    if not key:
        sys.exit("環境変数 ANTHROPIC_API_KEY が未設定です(キーのある Terminal で実行してください)")
    cache = json.load(open(CACHE)) if os.path.exists(CACHE) else {}
    cache = {k: tuple(v) for k, v in cache.items()}
    judge_all(files, a.model, key, a.batch, cache)
    for k, v in cache.items():
        if len(v) == 3 and v[2]:
            ASR_BAD[k.split("\t", 1)[0]] = True

    rows = [summary(m.get("name") or os.path.basename(p), m, recs, cache) for p, (m, recs) in zip(a.files, files)]
    L = ["# 下書きベンチの採点 (%s)" % time.strftime("%Y-%m-%d %H:%M"), "",
         "採点: %s。A 趣旨が伝わる / B 一部ずれる / C 意味が違う・不明 / E 安全策で英語表示" % a.model,
         "英語がまとも = 採点で「英語自体が聞き間違いで崩れている」とされなかった項目(AFM の実力を見る欄)", "",
         "| 条件 | 件数 | A | B | C | E | 読める(A+B) | C | 英語がまとも: 件数 | A | 読める | C | 時間 中央値 | p90 | 例文除去 | greedy | 例文 |",
         "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for r in rows:
        L.append("| %s | %d | %d | %d | %d | %d | %.1f%% | %.1f%% | %d | %.1f%% | %.1f%% | %.1f%% | %.0f ms | %.0f ms | %d | %s | %s |" % (
            r["name"], r["n"], r["A"], r["B"], r["C"], r["E"], r["read"], r["cpct"],
            r["nclean"], r["cA"], r["cread"], r["cC"], r["med"], r["p90"], r["echo"],
            r["greedy"], os.path.basename(str(r["fewshot"]))))
    if any(r["Q"] for r in rows):
        L.append("\n未採点(?) あり: " + ", ".join("%s %d" % (r["name"], r["Q"]) for r in rows if r["Q"]))
    # 比べる: 先頭を基準に、判定が変わった項目
    if len(files) > 1:
        base = {r["id"]: r for r in files[0][1]}
        rank = {"A": 0, "B": 1, "E": 2, "C": 3, "?": 4}
        for (m, recs), r0 in zip(files[1:], rows[1:]):
            better, worse = [], []
            for r in recs:
                b = base.get(r["id"])
                if not b:
                    continue
                lb, lv = label(b, cache)[0], label(r, cache)[0]
                if lb == lv:
                    continue
                (better if rank[lv] < rank[lb] else worse).append((b, r, lb, lv))
            L += ["", "## %s と基準(%s)の差: 良くなった %d / 悪くなった %d" % (r0["name"], rows[0]["name"], len(better), len(worse))]
            for title, lst in (("悪くなった", worse), ("良くなった", better)):
                if not lst:
                    continue
                L.append("\n### %s(先頭20件)" % title)
                for b, r, lb, lv in lst[:20]:
                    L.append("- `%s` %s\n  - 基準 %s: %s\n  - %s %s: %s %s" % (
                        b["id"], b["en"], lb, shown(b), r0["name"], lv, shown(r),
                        ("— " + label(r, cache)[1]) if label(r, cache)[1] else ""))
    # C の一覧(先頭の条件)
    for title, bad in (("英語がまとも", False), ("英語が聞き間違い", True)):
        cs = [r for r in files[0][1] if label(r, cache)[0] == "C" and asr_bad(r, cache) == bad]
        L += ["", "## %s の C: %s(%d 件、先頭40件)" % (rows[0]["name"], title, len(cs))]
        for r in cs[:40]:
            L.append("- `%s` %s → %s — %s" % (r["id"], r["en"], r.get("ja", ""), label(r, cache)[1]))
    out = os.path.join(ROOT, "results", "draft-report-%s.md" % time.strftime("%Y%m%d-%H%M%S"))
    open(out, "w", encoding="utf-8").write("\n".join(L) + "\n")
    print("\n".join(L[:8 + len(rows)]))
    print("\nレポート: %s" % os.path.relpath(out, ROOT))


if __name__ == "__main__":
    main()
