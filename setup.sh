#!/bin/bash
# Voice Input for macOS — 安装脚本
set -e

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
PLIST_NAME="com.voiceinput.agent"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_NAME}.plist"

echo "🎤 Voice Input for macOS — 安装"
echo ""

# 1. 检查 Python
PYTHON="$APP_DIR/venv/bin/python3"
if [ ! -f "$PYTHON" ]; then
    echo "📦 创建虚拟环境..."
    python3 -m venv "$APP_DIR/venv"
    source "$APP_DIR/venv/bin/activate"
    pip install -r "$APP_DIR/requirements.txt"
fi

# 2. 创建 LaunchAgent (开机自启)
echo "🚀 配置开机自启..."
cat > "$PLIST_PATH" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_NAME}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${PYTHON}</string>
        <string>${APP_DIR}/app.py</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>WorkingDirectory</key>
    <string>${APP_DIR}</string>
    <key>StandardOutPath</key>
    <string>${HOME}/.voice-input/stdout.log</string>
    <key>StandardErrorPath</key>
    <string>${HOME}/.voice-input/stderr.log</string>
</dict>
</plist>
EOF

# 3. 加载 LaunchAgent
launchctl unload "$PLIST_PATH" 2>/dev/null || true
launchctl load "$PLIST_PATH"

echo ""
echo "✅ 安装完成！"
echo ""
echo "📋 使用说明:"
echo "   • 菜单栏会出现 🎤 图标"
echo "   • 按住 F5 键录音，松开自动识别并粘贴"
echo "   • 点击菜单栏 🎤 可手动操作"
echo ""
echo "⚠️  首次使用需授权:"
echo "   1. 系统设置 → 隐私与安全 → 辅助功能 → 添加终端/Python"
echo "   2. 系统设置 → 隐私与安全 → 麦克风 → 允许"
echo ""
echo "📝 卸载: bash uninstall.sh"
echo "📝 配置: ~/.voice-input/config.json"
