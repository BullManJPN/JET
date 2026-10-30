#!/bin/bash
# 推奨設定(--preset --prepare)で全サンプルを測る
set -u
cd "$(dirname "$0")/.."
./asr/build.sh || { echo "ビルド失敗。中止します"; exit 1; }
./asr/make_samples.sh > /dev/null
for f in samples/*.aiff; do
  name=$(basename "$f" .aiff)
  echo; echo "######## $name ########"
  ./asrlog --file "$f" --preset --prepare --tag "s-$name" | grep -E "^FINAL|エラー"
done
echo; echo "================ 集計 ================"
for f in samples/*.aiff; do
  name=$(basename "$f" .aiff)
  lf=$(ls -t logs/*-s-$name.jsonl 2>/dev/null | head -1)
  [ -n "$lf" ] && { echo "---- $name"; python3 asr/analyze.py "$lf" | tail -8; }
done
