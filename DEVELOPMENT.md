# VoiceInput 开发文档

> macOS 菜单栏语音输入工具 — Swift 原生实现

---

## 1. 架构概览

```
┌─────────────────────────────────────────────────────┐
│                   VoiceInput App                    │
│                  (macOS Menu Bar)                   │
│                                                     │
│  main.swift → AppDelegate (NSApplicationDelegate)   │
│       │                                             │
│       ├── HotkeyMonitor  ──→ Fn 键全局监听          │
│       ├── AudioRecorder  ──→ AVAudioEngine 录音     │
│       ├── STTClient      ──→ HTTP 请求 STT 服务     │
│       ├── TextInjector   ──→ 剪贴板 + Cmd+V 注入    │
│       ├── SoundEffect    ──→ 系统音效提示            │
│       └── Config         ──→ JSON 配置文件读写       │
│                                                     │
│                      ↓ HTTP                         │
│                                                     │
│  ┌───────────────────────────────────────────┐      │
│  │  STT Service (192.168.8.195:7700)        │      │
│  │  /health              → 健康检查          │      │
│  │  /v1/audio/transcriptions → 语音转文字    │      │
│  │  SenseVoice / whisper.cpp / edge-tts      │      │
│  └───────────────────────────────────────────┘      │
└─────────────────────────────────────────────────────┘
```

## 2. 项目结构

```
voice-input-app/
├── Sources/
│   ├── main.swift            # 入口，NSApplication.accessory 模式
│   ├── AppDelegate.swift     # 核心控制器，菜单栏 + 状态管理
│   ├── AudioRecorder.swift   # AVAudioEngine 录音，16kHz 单声道 PCM
│   ├── HotkeyMonitor.swift   # NSEvent.flagsChanged 监听 Fn 键
│   ├── STTClient.swift       # OpenAI 兼容 STT API 客户端
│   ├── TextInjector.swift    # 剪贴板 + CGEvent Cmd+V 文字注入
│   ├── Config.swift          # ~/.voice-input/config.json 读写
│   └── SoundEffect.swift     # NSSound 系统音效
├── Resources/                # (预留) 资源文件
├── Package.swift             # SPM 配置，Swift 5.9+，macOS 13+
├── setup.sh                  # 构建 + 安装到 /Applications
└── uninstall.sh              # 卸载
```

## 3. 核心模块详解

### 3.1 入口 (main.swift)

```swift
@main
struct VoiceInputApp {
    static func main() {
        let app = NSApplication.shared
        app.delegate = AppDelegate()
        app.setActivationPolicy(.accessory) // 菜单栏应用，不占 Dock
        app.run()
    }
}
```

关键点：
- `.accessory` 模式：无 Dock 图标，纯菜单栏应用
- `AppDelegate` 负责所有生命周期

### 3.2 热键监听 (HotkeyMonitor.swift)

使用 `NSEvent.addGlobalMonitorForEvents` + `addLocalMonitorForEvents` 监听 `.flagsChanged` 事件。

```
Fn 按下 → .function 标志位出现 → callback(true)  → 开始录音
Fn 松开 → .function 标志位消失 → callback(false) → 停止录音 + 转写
```

实现要点：
- **全局 + 本地双监听**：global monitor 不接收自己应用的事件，需要 local monitor 补充
- **状态翻转检测**：用 `fnPressed` bool 防止重复触发
- **弱引用**：`[weak self]` 防止循环引用

### 3.3 录音 (AudioRecorder.swift)

基于 AVAudioEngine 的实时录音：

```
AVAudioEngine.inputNode
    → installTap(onBus: 0, bufferSize: 4096)
    → AVAudioConverter: 原始格式 → 16kHz mono Int16 PCM
    → Data() buffer 累积
```

关键参数：
| 参数 | 值 | 说明 |
|------|-----|------|
| Sample Rate | 16000 Hz | STT 够用，节省带宽 |
| Channels | 1 (Mono) | 语音不需要立体声 |
| Format | PCM Int16 | STT 服务原始格式 |
| Buffer Size | 4096 | 平衡延迟和性能 |

录音流程：
1. 请求麦克风权限（macOS 14+ 用 `AVAudioApplication`，旧版用 `AVCaptureDevice`）
2. 创建 AVAudioEngine，安装 tap
3. 实时转换格式 → 追加到 Data buffer
4. `stop()` 移除 tap、停止引擎，返回累积的 PCM 数据

### 3.4 STT 客户端 (STTClient.swift)

OpenAI 兼容的 HTTP 客户端：

**健康检查**：`GET /health` → 检查 `status == "ok"`

**语音转写**：`POST /v1/audio/transcriptions`
- Content-Type: `multipart/form-data`
- 字段：`file`（WAV 音频）、`language`（语言代码）
- PCM 数据包装为 WAV 容器（44 字节 RIFF 头）
- 超时：30 秒
- 响应解析：`{"text": "识别结果"}`

WAV 封装细节：
```
RIFF Header: 44 bytes + PCM data
- fmt chunk: PCM format, 1 channel, 16000 Hz, 16-bit
- data chunk: raw PCM samples
```

### 3.5 文字注入 (TextInjector.swift)

通过模拟键盘操作注入文字到当前焦点应用：

```
1. 保存当前剪贴板内容
2. 设置剪贴板为识别文本
3. Thread.sleep(50ms) — 等待剪贴板生效
4. CGEvent 模拟 Cmd+V (keyDown + keyUp)
5. 0.5 秒后恢复原剪贴板内容
```

为什么用剪贴板 + Cmd+V？
- macOS 没有通用的 "insert text at cursor" API
- `NSTextInputContext` 只在自己的 App 内有效
- 剪贴板方案跨应用兼容性最好

### 3.6 配置 (Config.swift)

存储在 `~/.voice-input/config.json`：

```json
{
  "sttUrl": "http://192.168.8.195:7700",
  "language": "auto",
  "sampleRate": 16000,
  "autoPaste": true,
  "soundEffect": true
}
```

- 自动创建配置目录
- 缺失字段用默认值填充
- 原子写入（`.atomic` option）

### 3.7 音效 (SoundEffect.swift)

使用 macOS 系统内置音效：

| 音效 | 触发 | 系统名称 |
|------|------|----------|
| 开始录音 | Fn 按下 | Tink |
| 停止录音 | Fn 松开 | Bottle |
| 错误 | 异常 | Basso |
| 成功 | 识别完成 | Glass |

## 4. 完整工作流

```
用户按住 Fn
    │
    ├── HotkeyMonitor 检测到 .function 标志
    │   └── callback(true) → AppDelegate.onHotkeyPress()
    │       ├── 检查 isRecording / isProcessing
    │       ├── startRecording()
    │       │   ├── AudioRecorder.start()
    │       │   │   ├── 检查麦克风权限
    │       │   │   ├── 创建 AVAudioEngine
    │       │   │   └── installTap 开始累积 PCM
    │       │   ├── 菜单栏显示 🔴
    │       │   └── SoundEffect.play(.start)
    │       │
    ├── 用户松开 Fn
    │   └── callback(false) → AppDelegate.onHotkeyRelease()
    │       ├── stopRecordingAndTranscribe()
    │       │   ├── AudioRecorder.stop() → 获取 PCM Data
    │       │   ├── 菜单栏显示 ⏳
    │       │   ├── SoundEffect.play(.stop)
    │       │   ├── Task { sttClient.transcribe(audioData:) }
    │       │   │   ├── WAV 封装
    │       │   │   ├── HTTP POST 到 STT 服务
    │       │   │   └── 解析 {"text": "..."}
    │       │   │
    │       │   ├── 识别成功:
    │       │   │   ├── 保存 lastText
    │       │   │   ├── if config.autoPaste:
    │       │   │   │   └── TextInjector.inject(text)
    │       │   │   │       ├── 剪贴板写入
    │       │   │   │       └── CGEvent Cmd+V
    │       │   │   └── 通知: "✅ 识别完成"
    │       │   │
    │       │   └── 识别失败:
    │       │       └── 通知: "❌ 错误: ..."
    │       │
    │       └── resetUI() → 菜单栏恢复 🎤
```

## 5. 依赖关系

| 依赖 | 类型 | 版本 | 说明 |
|------|------|------|------|
| macOS | 运行时 | 13+ (Ventura) | 最低支持版本 |
| Swift | 编译时 | 5.9+ | SPM 配置 |
| STT Service | 运行时 | - | 192.168.8.195:7700 |

无第三方依赖 — 纯 Apple 原生框架：
- `AppKit` — 菜单栏、通知
- `AVFoundation` — 录音
- `Carbon` — CGEvent 键盘模拟
- `Foundation` — HTTP、JSON、文件操作

## 6. 构建和安装

```bash
# 构建 + 安装
cd voice-input-app
./setup.sh

# 手动构建
swift build -c release

# 卸载
./uninstall.sh

# 配置文件位置
~/.voice-input/config.json
```

安装后首次运行：
1. 系统会弹出麦克风权限请求 → 点击「允许」
2. 菜单栏出现 🎤 图标
3. 按住 Fn 键测试录音

## 7. 菜单栏功能

| 菜单项 | 功能 |
|--------|------|
| 🎤 状态 | 显示 STT 服务连接状态 |
| 🎙️ 开始录音 (Fn) | 手动触发录音（同 Fn 键） |
| 📋 粘贴上次结果 | 重新注入上次识别文本 |
| ⚙️ 设置... | 打开 config.json |
| 📝 查看日志 | 打开 log.txt |
| ❌ 退出 | 退出应用 |

## 8. 配置说明

| 字段 | 默认值 | 说明 |
|------|--------|------|
| `sttUrl` | `http://192.168.8.195:7700` | STT 服务地址 |
| `language` | `auto` | 语言检测，支持 `zh`, `en`, `ja` 等 |
| `sampleRate` | `16000` | 录音采样率 |
| `autoPaste` | `true` | 识别后自动粘贴到当前光标 |
| `soundEffect` | `true` | 录音提示音 |

## 9. 已知限制

1. **剪贴板污染**：注入文字时会短暂覆盖剪贴板，0.5 秒后恢复。极少数情况下恢复可能失败。
2. **Fn 键冲突**：某些键盘 Fn 键行为不一致（外接键盘 vs 内置键盘）。
3. **权限要求**：需要麦克风权限 + 辅助功能权限（用于 CGEvent）。
4. **无离线模式**：必须连接 STT 服务才能工作。

## 10. 扩展方向

- [ ] iOS 版本（共享 STTClient，键盘扩展）
- [ ] 本地 Whisper 模型（无需网络）
- [ ] 历史记录存储
- [ ] 多语言快捷切换
- [ ] 自动检测系统语言
- [ ] Apple Silicon 优化的本地推理

---

**仓库**: https://github.com/aliannamorrison458/voice-input-app
**语言**: Swift 5.9+
**平台**: macOS 13+
**协议**: MIT
