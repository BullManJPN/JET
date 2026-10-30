#!/bin/bash
set -e
cd "$(dirname "$0")/.."
swiftc -O -parse-as-library -swift-version 5 asr/asrlog.swift -o asrlog
echo "ビルド完了: ./asrlog"
