#!/bin/bash
# 日程组件纯逻辑测试。
# 用途：验证事件判定、今日筛选（含跨午夜）、筛选开关、预读窗口、导入解析、去重、导出往返。
# 特点：不启动 App、不读写用户的 schedule.json、不改用户的偏好（测试结束会清掉自己写的键）。
#
# 用法（仓库根目录）：
#   ./tests/run.sh
#
# 说明：
#  1. 本机是 Command Line Tools，SwiftPM 的 sandbox 在受限环境里起不来，
#     所以直接用 swiftc 编译整个 Sources 目录 + 测试文件，绕开 SwiftPM。
#  2. 顶层代码只允许出现在 main.swift 里，所以先把测试文件复制成临时的 main.swift。

set -uo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
OUT="$WORK/schedule-tests"
MC="$WORK/modulecache"
SDK="$(xcrun --show-sdk-path)"

# App 自己的 main.swift 要排除（否则和测试的 main.swift 撞名）
SOURCES=()
for f in Sources/DockSide/*.swift; do
    [[ "$(basename "$f")" == "main.swift" ]] && continue
    SOURCES+=("$f")
done
cp tests/ScheduleLogicTests.swift "$WORK/main.swift"

echo "编译中…"
swiftc -o "$OUT" \
    "${SOURCES[@]}" \
    "$WORK/main.swift" \
    -target "arm64-apple-macosx13.0" \
    -sdk "$SDK" \
    -module-cache-path "$MC" 2>&1 | grep -E "error:" | head -20

if [[ ! -x "$OUT" ]]; then
    echo "❌ 编译失败"
    rm -rf "$WORK"
    exit 1
fi

"$OUT"
STATUS=$?
rm -rf "$WORK"
exit $STATUS
