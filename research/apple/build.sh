#!/bin/bash
set -e
cd "$(dirname "$0")/.."
for f in transbench prefixbench translist; do
  swiftc -O -parse-as-library -swift-version 5 apple/$f.swift -o $f
done
echo "ビルド完了: ./transbench ./prefixbench ./translist"
