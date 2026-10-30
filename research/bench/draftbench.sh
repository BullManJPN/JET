#!/bin/bash
# 下書き(AFM)ベンチの基準を測る: 今のプロンプトを2回(ばらつきの確認)+ greedy 1回 → Haiku で採点して比べる
# ANTHROPIC_API_KEY のある Terminal で:  ./draftbench.sh
cd "$(dirname "$0")"
./build_jet.sh || exit 1
./jetcli --selftest || exit 1
SET=results/draft-set.jsonl
TS=$(date +%Y%m%d-%H%M%S)
./jetcli --draft-bench $SET --name base1 --out results/draft-base1-$TS.jsonl || exit 1
./jetcli --draft-bench $SET --name base2 --out results/draft-base2-$TS.jsonl || exit 1
./jetcli --draft-bench $SET --name greedy --greedy --out results/draft-greedy-$TS.jsonl || exit 1
python3 sim/draft_score.py results/draft-base1-$TS.jsonl results/draft-base2-$TS.jsonl results/draft-greedy-$TS.jsonl
