#!/bin/bash
set -e

APP_PATH="/Users/ai/Developer/voice-input-app/.build/release/VoiceInput"
LOG_FILE="$HOME/.voice-input/log.txt"
TEST_PASS=0
TEST_FAIL=0

pass() { echo "  ✅ $1"; TEST_PASS=$((TEST_PASS + 1)); }
fail() { echo "  ❌ $1"; TEST_FAIL=$((TEST_FAIL + 1)); }

echo "=== VoiceInput 交互测试 ==="
echo ""

pkill -x VoiceInput 2>/dev/null || true
sleep 1
rm -f "$LOG_FILE" "$LOG_FILE.old.txt"

"$APP_PATH" &
APP_PID=$!
sleep 4

echo "1. 启动状态验证"
LOG=$(cat "$LOG_FILE" 2>/dev/null || echo "")

echo "$LOG" | grep -q "应用启动" && pass "启动日志" || fail "缺少启动日志"
echo "$LOG" | grep -q "服务健康检查" && pass "STT 健康检查" || fail "未执行健康检查"
echo "$LOG" | grep -q "辅助功能" && pass "辅助功能权限检查" || fail "未检查权限"

echo ""
echo "2. STT 离线自动重试"
INITIAL_CHECKS=$(grep -c "服务健康检查" "$LOG_FILE" || echo "0")
echo "   初始检查次数: $INITIAL_CHECKS"
sleep 12
LATER_CHECKS=$(grep -c "服务健康检查" "$LOG_FILE" || echo "0")
echo "   12秒后检查次数: $LATER_CHECKS"
if [ "$LATER_CHECKS" -gt "$INITIAL_CHECKS" ]; then
    pass "自动重试生效 ($INITIAL_CHECKS -> $LATER_CHECKS 次)"
else
    fail "未自动重试"
fi

echo ""
echo "3. 配置完整性"
CFG="$HOME/.voice-input/config.json"
python3 -c "
import json
d=json.load(open('$CFG'))
checks = [
    ('sttUrl', 'http://127.0.0.1:7700'),
    ('language', 'auto'),
    ('sampleRate', 16000),
    ('autoPaste', True),
    ('backend', 'sensevoice'),
    ('transcribeMode', 'file'),
    ('soundEffect', True),
]
for key, expected in checks:
    actual = d.get(key)
    if actual == expected:
        print(f'  ✅ {key}: {actual}')
    else:
        print(f'  ❌ {key}: 期望 {expected}, 实际 {actual}')
"

echo ""
echo "4. 进程稳定性"
if kill -0 $APP_PID 2>/dev/null; then
    pass "App 运行中"
    MEM_KB=$(ps -p $APP_PID -o rss= | tr -d ' ')
    MEM_MB=$((MEM_KB / 1024))
    echo "   内存: ${MEM_MB}MB"
    [ "$MEM_MB" -lt 100 ] && pass "内存 < 100MB" || echo "   ⚠️  内存偏高"
fi

CRASH=$(find ~/Library/Logs/DiagnosticReports -name "VoiceInput*" -mmin -5 2>/dev/null | head -1)
[ -z "$CRASH" ] && pass "无崩溃" || fail "有崩溃: $CRASH"

echo ""
echo "5. 退出"
kill $APP_PID 2>/dev/null; sleep 2
! kill -0 $APP_PID 2>/dev/null && pass "正常退出" || fail "未响应退出"

echo ""
echo "================================"
echo "结果: ✅ $TEST_PASS 通过, ❌ $TEST_FAIL 失败"
echo "================================"
exit $TEST_FAIL
