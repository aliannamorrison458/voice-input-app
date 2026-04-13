#!/bin/bash
# Voice Input for macOS — 卸载脚本
PLIST_NAME="com.voiceinput.agent"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_NAME}.plist"

echo "🗑️  卸载 Voice Input..."

# 停止并卸载 LaunchAgent
launchctl unload "$PLIST_PATH" 2>/dev/null || true
rm -f "$PLIST_PATH"

# 保留配置文件（用户可能需要）
echo "📁 配置保留在 ~/.voice-input/"
echo "   如需完全删除: rm -rf ~/.voice-input"

echo "✅ 已卸载"
