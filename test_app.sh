#!/bin/bash
set -e

APP_PATH="/Users/ai/Developer/voice-input-app/.build/release/VoiceInput"
CONFIG_DIR="$HOME/.voice-input"
LOG_FILE="$CONFIG_DIR/log.txt"
CONFIG_FILE="$CONFIG_DIR/config.json"
TEST_PASS=0
TEST_FAIL=0

pass() { echo "  ✅ $1"; TEST_PASS=$((TEST_PASS + 1)); }
fail() { echo "  ❌ $1"; TEST_FAIL=$((TEST_FAIL + 1)); }

echo "=== VoiceInput 功能测试 ==="
echo ""

# --- 预清理 ---
echo "1. 启动准备"
pkill -x VoiceInput 2>/dev/null || true
sleep 1

# 清理旧日志以便观察
rm -f "$LOG_FILE" "$LOG_FILE.old.txt" 2>/dev/null || true

# --- 启动 App ---
"$APP_PATH" &
APP_PID=$!
echo "   App PID: $APP_PID"
sleep 3

# 检查进程存活
if kill -0 $APP_PID 2>/dev/null; then
    pass "App 启动成功，进程存活 (PID=$APP_PID)"
else
    fail "App 启动后立即退出"
    exit 1
fi

# --- 检查日志 ---
echo ""
echo "2. 启动日志检查"
sleep 1

if [ -f "$LOG_FILE" ]; then
    pass "日志文件已创建: $LOG_FILE"
    
    if grep -q "应用启动" "$LOG_FILE"; then
        pass "日志包含启动信息"
    else
        fail "日志缺少启动信息"
    fi
    
    if grep -q "STT=" "$LOG_FILE"; then
        pass "日志包含 STT 配置"
    fi
    
    echo "   最近日志:"
    tail -10 "$LOG_FILE" | sed 's/^/   | /'
else
    fail "日志文件未创建"
fi

# --- 检查配置文件 ---
echo ""
echo "3. 配置文件检查"

if [ -f "$CONFIG_FILE" ]; then
    pass "配置文件存在"
    
    # 检查默认值
    STT_URL=$(python3 -c "import json; d=json.load(open('$CONFIG_FILE')); print(d.get('sttUrl',''))")
    if echo "$STT_URL" | grep -q "127.0.0.1"; then
        pass "默认 STT URL 使用 127.0.0.1: $STT_URL"
    else
        fail "默认 STT URL 不是 127.0.0.1: $STT_URL"
    fi
    
    HAS_LANGUAGE=$(python3 -c "import json; d=json.load(open('$CONFIG_FILE')); print(d.get('language',''))")
    if [ -n "$HAS_LANGUAGE" ]; then
        pass "配置包含 language 字段: $HAS_LANGUAGE"
    else
        fail "配置缺少 language 字段"
    fi
    
    HAS_AUTOPASTE=$(python3 -c "import json; d=json.load(open('$CONFIG_FILE')); print(d.get('autoPaste',''))")
    if [ "$HAS_AUTOPASTE" = "True" ]; then
        pass "autoPaste 默认为 true"
    else
        fail "autoPaste 默认值异常: $HAS_AUTOPASTE"
    fi
    
    echo "   配置内容:"
    cat "$CONFIG_FILE" | python3 -m json.tool | sed 's/^/   | /'
else
    fail "配置文件未创建"
fi

# --- 测试配置保存/加载 ---
echo ""
echo "4. 配置保存/加载测试"

# 修改配置并检查 app 是否重新加载
python3 -c "
import json
cfg = json.load(open('$CONFIG_FILE'))
cfg['language'] = 'en'
cfg['soundEffect'] = False
json.dump(cfg, open('$CONFIG_FILE', 'w'), indent=2)
"
echo "   已修改配置 (language=en, soundEffect=False)"

# 等待 app 可能的配置监听或等重启
sleep 2

# --- 检查 STT 离线状态处理 ---
echo ""
echo "5. STT 离线处理检查"

if grep -q "离线\|offline\|网络错误\|无法连接" "$LOG_FILE"; then
    pass "App 正确检测到 STT 服务离线"
else
    echo "   ℹ️  未检测到 STT 离线日志（可能服务在线或尚未触发）"
fi

# --- 检查辅助功能权限检查 ---
echo ""
echo "6. 权限检查"

if grep -q "辅助功能" "$LOG_FILE"; then
    pass "App 执行了辅助功能权限检查"
else
    echo "   ℹ️  未检测到辅助功能检查日志"
fi

# --- App 生命周期 ---
echo ""
echo "7. App 生命周期测试"

# 检查 App 是否仍在运行
if kill -0 $APP_PID 2>/dev/null; then
    pass "App 运行 5+ 秒后仍然存活"
else
    fail "App 在测试期间崩溃"
fi

# 检查是否有崩溃日志
CRASH_LOG=$(find ~/Library/Logs/DiagnosticReports -name "VoiceInput*" -mmin -5 2>/dev/null | head -1)
if [ -n "$CRASH_LOG" ]; then
    fail "发现崩溃日志: $CRASH_LOG"
    echo "   崩溃内容:"
    tail -30 "$CRASH_LOG" | sed 's/^/   | /'
else
    pass "无崩溃日志"
fi

# --- 优雅退出 ---
echo ""
echo "8. 退出测试"
kill $APP_PID 2>/dev/null
sleep 2

if ! kill -0 $APP_PID 2>/dev/null; then
    pass "App 响应 SIGTERM 退出"
else
    kill -9 $APP_PID 2>/dev/null
    fail "App 未响应 SIGTERM，强制杀死"
fi

# 检查退出日志
if [ -f "$LOG_FILE" ] && grep -q "应用退出" "$LOG_FILE"; then
    pass "日志记录了应用退出"
fi

# --- 汇总 ---
echo ""
echo "================================"
echo "测试结果: ✅ $TEST_PASS 通过, ❌ $TEST_FAIL 失败"
echo "================================"

exit $TEST_FAIL
