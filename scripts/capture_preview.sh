#!/bin/zsh
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
OUTPUT_PATH=${1:-"$ROOT_DIR/.tmp/semiquotabar-preview.png"}
CAPTURE_MODE=${QUOTABAR_DEBUG_CAPTURE_MODE:-offscreen}
SCREEN_TARGET=${QUOTABAR_DEBUG_SCREEN:-external}
BINARY_PATH=${QUOTABAR_BINARY_PATH:-"$ROOT_DIR/.build/debug/QuotaBar"}

if [[ ! -x "$BINARY_PATH" ]]; then
  echo "未找到可执行文件：$BINARY_PATH" >&2
  echo "请先构建可执行文件，或通过 QUOTABAR_BINARY_PATH 指定路径。" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT_PATH")"

if [[ "$CAPTURE_MODE" == "preview" ]]; then
  if pgrep -x QuotaBar >/dev/null 2>&1; then
    if [[ "${QUOTABAR_ALLOW_KILL_EXISTING:-0}" == "1" ]]; then
      pkill -x QuotaBar >/dev/null 2>&1 || true
    else
      echo "检测到 QuotaBar 已在运行；预览模式默认不终止现有实例，避免打扰当前使用。" >&2
      echo "如需强制重启并抓图，请设置 QUOTABAR_ALLOW_KILL_EXISTING=1。" >&2
      exit 1
    fi
  fi

  QUOTABAR_DEBUG_WINDOW=1 \
  QUOTABAR_DEBUG_CAPTURE_MODE=preview \
  QUOTABAR_DEBUG_SCREEN="$SCREEN_TARGET" \
  QUOTABAR_DEBUG_CAPTURE_PATH="$OUTPUT_PATH" \
  QUOTABAR_DEBUG_QUIT_AFTER_CAPTURE=1 \
  "$BINARY_PATH"
else
  QUOTABAR_DEBUG_CAPTURE_MODE=offscreen \
  QUOTABAR_DEBUG_CAPTURE_PATH="$OUTPUT_PATH" \
  QUOTABAR_DEBUG_QUIT_AFTER_CAPTURE=1 \
  "$BINARY_PATH"
fi

echo "截图已输出到：$OUTPUT_PATH"
