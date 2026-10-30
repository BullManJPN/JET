#!/bin/bash
set -e
cd "$(dirname "$0")/.."
swiftc -O -parse-as-library -swift-version 5 apple/pccbench.swift -o pccbench
echo "ビルド完了: ./pccbench"
