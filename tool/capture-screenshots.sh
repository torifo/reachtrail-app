#!/usr/bin/env bash
#
# Play Store 用スクリーンショット撮影ツール
#
# 使い方:
#   ./tool/capture-screenshots.sh [device_serial]
#
# device_serial を省略すると、接続中の Android デバイス／エミュレータから対話的に選択。
# 各画面で Enter を押すと adb で撮影し、screenshots/<デバイス名>/NN_<画面名>.png に保存。
# 撮影前後で systemui demo mode を切り替え、ステータスバーを 09:30 / 電池満タンに固定。

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_BASE="$ROOT_DIR/screenshots"

# 撮影シナリオ: "ファイル接尾辞|案内文" の配列
SCENES=(
  "signin|サインイン画面（ログイン前のヒーロー）"
  "base_set|Base タブ：基準地点が設定済みの状態"
  "register_search|Register タブ：候補リスト＋地図＋レーダー表示中"
  "register_modal|Register タブ：記録モーダルを開いてフォーム入力中"
  "map_tab|Map タブ：マイマップ＋Place Ranking"
  "history|履歴一覧画面"
  "best|自己ベスト表示"
  "reload_button|地図リロードボタンが目立つ画角"
)

# ----- デバイス選択 -----
if [[ $# -ge 1 ]]; then
  DEVICE="$1"
else
  mapfile -t DEVICES < <(adb devices | awk 'NR>1 && $2=="device" {print $1}')
  if [[ ${#DEVICES[@]} -eq 0 ]]; then
    echo "接続中のデバイスが見つかりません。エミュレータを起動してから再実行してください。" >&2
    exit 1
  elif [[ ${#DEVICES[@]} -eq 1 ]]; then
    DEVICE="${DEVICES[0]}"
  else
    echo "接続中のデバイス:"
    for i in "${!DEVICES[@]}"; do
      MODEL=$(adb -s "${DEVICES[$i]}" shell getprop ro.product.model | tr -d '\r')
      printf "  [%d] %s (%s)\n" "$i" "${DEVICES[$i]}" "$MODEL"
    done
    read -rp "番号を選択: " IDX
    DEVICE="${DEVICES[$IDX]}"
  fi
fi

# デバイス名（出力フォルダ名に使用）。型番ベースで kebab 化
RAW_MODEL=$(adb -s "$DEVICE" shell getprop ro.product.model | tr -d '\r')
DEVICE_NAME=$(echo "$RAW_MODEL" | tr ' ' '_' | tr '[:upper:]' '[:lower:]')
OUTPUT_DIR="$OUTPUT_BASE/$DEVICE_NAME"
mkdir -p "$OUTPUT_DIR"

echo
echo "デバイス: $DEVICE ($RAW_MODEL)"
echo "保存先: $OUTPUT_DIR"
echo

# 解像度確認
RES=$(adb -s "$DEVICE" shell wm size | awk '{print $NF}' | tr -d '\r')
echo "画面サイズ: $RES"

# ----- ステータスバー demo mode (見栄え用) -----
cleanup_demo() {
  adb -s "$DEVICE" shell am broadcast -a com.android.systemui.demo -e command exit >/dev/null 2>&1 || true
}
trap cleanup_demo EXIT

adb -s "$DEVICE" shell settings put global sysui_demo_allowed 1 >/dev/null
adb -s "$DEVICE" shell am broadcast -a com.android.systemui.demo -e command enter >/dev/null
adb -s "$DEVICE" shell am broadcast -a com.android.systemui.demo -e command clock -e hhmm 0930 >/dev/null
adb -s "$DEVICE" shell am broadcast -a com.android.systemui.demo -e command battery -e level 100 -e plugged false >/dev/null
adb -s "$DEVICE" shell am broadcast -a com.android.systemui.demo -e command network -e wifi show -e level 4 >/dev/null
adb -s "$DEVICE" shell am broadcast -a com.android.systemui.demo -e command notifications -e visible false >/dev/null

# ----- 撮影ループ -----
echo
echo "各画面の準備ができたら Enter で撮影、s でスキップ、q で終了。"
echo

INDEX=1
for SCENE in "${SCENES[@]}"; do
  SUFFIX="${SCENE%%|*}"
  LABEL="${SCENE##*|}"
  FILENAME=$(printf "%02d_%s.png" "$INDEX" "$SUFFIX")
  TARGET="$OUTPUT_DIR/$FILENAME"

  echo "──────────────────────────────────────"
  echo "[$INDEX/${#SCENES[@]}] $LABEL"
  echo "→ 保存先: $FILENAME"
  read -rp "アプリで該当画面を開いた状態で Enter (s=skip, q=quit): " INPUT

  case "$INPUT" in
    q|Q) echo "中断しました。"; break ;;
    s|S) echo "スキップしました。"; INDEX=$((INDEX+1)); continue ;;
  esac

  adb -s "$DEVICE" exec-out screencap -p > "$TARGET"
  echo "✓ 保存: $TARGET ($(sips -g pixelWidth -g pixelHeight "$TARGET" 2>/dev/null | awk '/pixel/ {printf $2" "}' | xargs))"

  INDEX=$((INDEX+1))
done

echo
echo "撮影完了。$OUTPUT_DIR を確認してください。"
echo
echo "Play Store アップロード前に解像度確認:"
echo "  ls -la $OUTPUT_DIR"
echo "  sips -g pixelWidth -g pixelHeight $OUTPUT_DIR/*.png"
