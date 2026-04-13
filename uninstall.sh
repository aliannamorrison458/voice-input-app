#!/bin/bash
echo "🗑️ Uninstalling VoiceInput..."
rm -rf "/Applications/VoiceInput.app"
echo "✅ Removed /Applications/VoiceInput.app"
echo "⚠️ 配置文件 ~/.voice-input/ 保留，手动删除: rm -rf ~/.voice-input"
