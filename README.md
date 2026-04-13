# 🎤 Voice Input for macOS

macOS 菜单栏语音输入工具，接入 STT 服务。

## 功能

- **按住 F5 录音**，松开自动识别并粘贴到当前光标
- **菜单栏操作**：点击 🎤 手动开始/停止录音
- **自动粘贴**：识别结果直接输入到当前应用
- **系统提示音**：录音开始/结束/成功/失败有声音反馈
- **开机自启**：安装后自动随系统启动

## 快速开始

```bash
# 1. 安装依赖
cd ~/voice-input-app
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt

# 2. 测试管道（验证录音+STT）
python3 test_pipeline.py

# 3. 启动 App
python3 app.py
```

## 安装为开机自启

```bash
bash setup.sh
```

## 配置

配置文件：`~/.voice-input/config.json`

```json
{
  "stt_url": "http://192.168.8.195:7700",
  "hotkey": "f5",
  "language": "auto",
  "sample_rate": 16000,
  "auto_paste": true,
  "sound_effect": true,
  "max_record_seconds": 60
}
```

## 权限要求

首次运行需要授权：
1. **系统设置 → 隐私与安全 → 辅助功能** → 添加 Python/Terminal
2. **系统设置 → 隐私与安全 → 麦克风** → 允许

## 打包为 .app

```bash
source venv/bin/activate
pip install py2app
python3 setup_py2app.py py2app
# 生成: dist/VoiceInput.app
```

## 卸载

```bash
bash uninstall.sh
```

## 文件结构

```
~/voice-input-app/
├── app.py              # 主程序
├── test_pipeline.py    # 管道测试脚本
├── requirements.txt    # Python 依赖
├── setup.sh            # 安装脚本（开机自启）
├── uninstall.sh        # 卸载脚本
├── setup_py2app.py     # 打包脚本
└── venv/               # Python 虚拟环境
```
