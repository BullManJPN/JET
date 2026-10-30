#!/bin/bash
# 同じ音声を3通りで認識して点数を出す。使い方: ./asr/run_term_compare.sh N 声   (例: ./asr/run_term_compare.sh 1 Samantha)
# 条件: speech = SpeechTranscriber / dict = DictationTranscriber(ヒントなし) / dict-terms = DictationTranscriber(語彙ヒントあり)
# 実時間で流すので、1条件あたり音声の長さぶんかかる
set -e
cd "$(dirname "$0")/.."
N=${1:-1}; V=${2:-Samantha}
F="samples/term${N}_${V}.aiff"; REF="asr/term_scripts/term${N}.txt"
[ -f "$F" ] || { echo "$F がありません"; exit 1; }
./asrlog --file "$F" --preset --prepare --tag "term${N}-${V}-speech" > /dev/null
./asrlog --file "$F" --engine dictation --prepare --tag "term${N}-${V}-dict" > /dev/null
./asrlog --file "$F" --engine dictation --terms asr/terms.txt --prepare --tag "term${N}-${V}-dict-terms" > /dev/null
for t in speech dict dict-terms; do
  L=$(ls -t logs/asr-*-term${N}-${V}-${t}.jsonl | head -1)
  echo "=== $t ==="
  python3 asr/score_terms.py "$L" "$REF" | sed -n '1,2p;$p'
  python3 asr/analyze.py "$L" | grep -E "確定の遅れ|途中表示|NE\\(|結果の到着"
done
