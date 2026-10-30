#!/bin/bash
# メニューバー版(U3)。起動直後は停止中。メニューの「開始」で聞き取り、入力はメニューで選ぶ
# Terminal を閉じると終了する(Terminal から起動しているので、マイク・画面収録の許可は Terminal のものを使う)
cd "$(dirname "$0")"
./build_jet.sh || exit 1
./jetcli --selftest > /dev/null || { echo "selftest に失敗あり(./jetcli --selftest で NG を確認)"; exit 1; }
./jetcli --menubar --quiet "$@"
