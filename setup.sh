#!/bin/bash
set -e

APP_NAME="VoiceInput"
INSTALL_DIR="/Applications"
BUILD_DIR=".build/release"

echo "🔧 Building $APP_NAME (Swift native)..."
swift build -c release

echo "📦 Creating app bundle..."
APP_BUNDLE="$INSTALL_DIR/$APP_NAME.app"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/"

cat > "$APP_BUNDLE/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>VoiceInput</string>
    <key>CFBundleIdentifier</key>
    <string>com.openclaw.voiceinput</string>
    <key>CFBundleName</key>
    <string>VoiceInput</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>VoiceInput 需要麦克风权限来进行语音识别</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <!-- STT 服务默认使用内网 HTTP 地址，允许明文连接 -->
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
</dict>
</plist>
EOF

echo "✅ Installed to $APP_BUNDLE"
echo ""
echo "启动: open $APP_BUNDLE"
echo "首次运行需要在 系统设置 → 隐私与安全 → 麦克风 中授权"
