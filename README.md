# VoiceInput — macOS 菜单栏语音输入工具

Swift 原生开发的 macOS 菜单栏应用，按住 Fn 键录音，接入 STT 服务识别后自动输入到当前光标。

## 功能

- 🎤 菜单栏常驻，不占 Dock
- ⌨️ Fn 键全局热键（按住录音，松开识别）
- 🎙️ 16kHz 单声道录音
- 🌐 接入自建 STT 服务（OpenAI 兼容 API）
- 📋 自动粘贴到当前焦点（剪贴板 + Cmd+V）
- 🔊 录音提示音

## 依赖

- macOS 13+
- Swift 5.9+
- 自建 STT 服务（默认 http://192.168.8.195:7700）

## 安装

```bash
cd voice-input-app
chmod +x setup.sh
./setup.sh
```

首次运行需授权麦克风权限（系统设置 → 隐私与安全 → 麦克风）。

## 配置

配置文件 `~/.voice-input/config.json`：

```json
{
  "sttUrl": "http://192.168.8.195:7700",
  "language": "auto",
  "sampleRate": 16000,
  "autoPaste": true,
  "soundEffect": true
}
```

菜单栏 → ⚙️ 设置... 可直接打开配置文件。

## 卸载

```bash
./uninstall.sh
```
