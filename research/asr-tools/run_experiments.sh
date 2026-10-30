#!/bin/bash
# ビルドが成功したときだけ、4条件で同じ音声を測る。途中で止まらないよう、失敗は表示して次へ進む。
set -u
cd "$(dirname "$0")/.."
./asr/build.sh || { echo "ビルド失敗。実験を中止します"; exit 1; }
SAMPLE=${1:-samples/tts1.aiff}
for cfg in "base:" "fast:--fast --prepare" "preset:--preset --prepare" "chunk20:--fast --prepare --chunk-ms 20"; do
  tag=${cfg%%:*}; args=${cfg#*:}
  echo; echo "######## $tag ($args) ########"
  ./asrlog --file "$SAMPLE" $args --tag "$tag" | grep -E "^設定|^FINAL|エラー" 
done
echo; echo "================ 集計 ================"
for tag in base fast preset chunk20; do
  f=$(ls -t logs/*-$tag.jsonl 2>/dev/null | head -1)
  [ -n "$f" ] && { echo "---- $tag ($f)"; python3 asr/analyze.py "$f" | tail -7; }
done
