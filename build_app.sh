#!/bin/bash
# JET.app を組み立てる。  ./build_app.sh  →  ./JET.app
#   起動: open JET.app   終了: メニューバーの「終了」・窓の ×・⌘Q
#   selftest はアプリの中の実行ファイルから:  JET.app/Contents/MacOS/JET --selftest
#
# 署名(許可を毎回聞き直されないために、ビルドのたびに同じ署名で署名する):
#   1. 「キーチェーンアクセス」→ メニュー「証明書アシスタント」→「証明書を作成…」
#      名前 = JET Local Signing / 固有名のタイプ = 自己署名ルート / 証明書のタイプ = コード署名
#   2. 以後 ./build_app.sh は自動でその証明書を使う(別の名前なら JET_SIGN_ID="名前" ./build_app.sh)
#   証明書が無ければ ad hoc 署名(-)で作る。動くが、ビルドのたびに署名が変わるので
#   マイク・画面収録の許可を聞き直されることがある。
set -e
cd "$(dirname "$0")"

APP=JET.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/prompts" "$APP/Contents/Resources/asr"

swiftc -O -parse-as-library -swift-version 5 jet/*.swift -o "$APP/Contents/MacOS/JET"
cp app/Info.plist "$APP/Contents/Info.plist"

# アイコン: app/JET-icon-1024.png(透明な余白つきの 1024px)から JET.icns を作る
ICONSET="$(mktemp -d)/JET.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s app/JET-icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) app/JET-icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/JET.icns"

# 同梱するもの(ユーザーが変えないもの + 初期値)。比較用のプロンプトの別案・例文・実験用の物は入れない
cp jet.json "$APP/Contents/Resources/"
for f in draft_system.txt draft_user.txt qbox_system.txt qbox_user.txt qbox_templates.tsv; do
  cp "prompts/$f" "$APP/Contents/Resources/prompts/"
done
for f in cmudict.dict cmudict.LICENSE terms.txt term_aliases.tsv vocab.txt; do
  cp "asr/$f" "$APP/Contents/Resources/asr/"
done

ID="${JET_SIGN_ID:-JET Local Signing}"
if ! security find-identity -p codesigning 2>/dev/null | grep -q "\"$ID\""; then
  echo "注意: 署名用の証明書「$ID」が見つかりません。ad hoc 署名にします(許可を聞き直されることがあります)"
  ID="-"
fi
codesign --force --deep --sign "$ID" "$APP"
codesign --verify --deep --strict "$APP" && echo "署名OK(\"$ID\")"
echo "ビルド完了: ./$APP   起動: open $APP"
