#!/bin/bash
set -e
cd "$(dirname "$0")/.."
swiftc -O -parse-as-library -swift-version 5 apple/afmbench.swift -o afmbench
echo "ビルド完了: ./afmbench"
