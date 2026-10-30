#!/bin/bash
set -e
cd "$(dirname "$0")"
swiftc -O -parse-as-library -swift-version 5 jet/*.swift -o jetcli
echo "ビルド完了: ./jetcli"
