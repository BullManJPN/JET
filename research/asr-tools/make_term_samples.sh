#!/bin/bash
# 用語を多く含む英語の合成音声サンプルを作る。asr/term_scripts/termN.txt が正解の文章。
# 声は Samantha(米) と、あれば Daniel(英) / Karen(豪)。無い声は飛ばす。速度は標準と少し速め。
set -e
cd "$(dirname "$0")/.."
mkdir -p samples
for v in Samantha Daniel Karen; do
  if ! say -v '?' | grep -q "^$v "; then echo "声 $v はないので飛ばします"; continue; fi
  for n in 1 2 3; do
    r=175; [ "$v" != "Samantha" ] && r=195
    say -v "$v" -r $r -o "samples/term${n}_${v}.aiff" -f "asr/term_scripts/term${n}.txt"
    echo "作成: samples/term${n}_${v}.aiff"
  done
done
ls -la samples | grep term
