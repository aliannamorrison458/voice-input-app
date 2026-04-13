#!/usr/bin/env python3
"""
Voice Input for macOS — 菜单栏语音输入工具
接入 STT 服务，按住热键录音 → 识别 → 自动输入到当前光标

启动: python3 app.py
打包: pyinstaller --onefile --windowed --name "VoiceInput" app.py
"""

import os
import sys
import json
import time
import threading
import tempfile
import subprocess
import wave
from pathlib import Path
from datetime import datetime

import numpy as np
import sounddevice as sd
import requests
import rumps

# ─── Config ──────────────────────────────────────────────────────────────────
CONFIG_DIR = Path.home() / ".voice-input"
CONFIG_FILE = CONFIG_DIR / "config.json"

DEFAULT_CONFIG = {
    "stt_url": "http://192.168.8.195:7700",
    "hotkey": "fn",            # 全局热键: "fn" 或 pynput key name (如 "f5", "f6")
    "language": "auto",
    "sample_rate": 16000,
    "auto_paste": True,        # 识别后自动粘贴
    "sound_effect": True,      # 录音提示音
    "max_record_seconds": 60,
}


def load_config():
    CONFIG_DIR.mkdir(exist_ok=True)
    if CONFIG_FILE.exists():
        try:
            cfg = json.loads(CONFIG_FILE.read_text())
            # Merge defaults for missing keys
            for k, v in DEFAULT_CONFIG.items():
                cfg.setdefault(k, v)
            return cfg
        except Exception:
            pass
    save_config(DEFAULT_CONFIG)
    return dict(DEFAULT_CONFIG)


def save_config(cfg):
    CONFIG_DIR.mkdir(exist_ok=True)
    CONFIG_FILE.write_text(json.dumps(cfg, indent=2, ensure_ascii=False))


# ─── Audio Recorder ──────────────────────────────────────────────────────────
class AudioRecorder:
    """按需录音，录制到内存中的 numpy 数组"""

    def __init__(self, sample_rate=16000):
        self.sample_rate = sample_rate
        self.frames = []
        self.stream = None
        self.recording = False
        self._lock = threading.Lock()

    def check_input_device(self):
        """检查是否有可用的录音设备"""
        try:
            devices = sd.query_devices()
            for i, d in enumerate(devices):
                if d['max_input_channels'] > 0:
                    return True, d['name']
            return False, "未检测到麦克风设备"
        except Exception as e:
            return False, str(e)

    def _callback(self, indata, frame_count, time_info, status):
        if self.recording:
            with self._lock:
                self.frames.append(indata.copy())

    def start(self):
        # 检查输入设备
        ok, info = self.check_input_device()
        if not ok:
            raise RuntimeError(f"录音失败: {info}\n请检查麦克风连接或系统权限（系统设置 → 隐私与安全 → 麦克风）")

        with self._lock:
            self.frames = []
            self.recording = True

        # 找到第一个可用的输入设备
        device = None
        devices = sd.query_devices()
        for i, d in enumerate(devices):
            if d['max_input_channels'] > 0:
                device = i
                break

        self.stream = sd.InputStream(
            device=device,
            samplerate=self.sample_rate,
            channels=1,
            dtype='int16',
            blocksize=1024,
            callback=self._callback,
        )
        self.stream.start()

    def stop(self):
        self.recording = False
        if self.stream:
            self.stream.stop()
            self.stream.close()
            self.stream = None
        with self._lock:
            if not self.frames:
                return None
            audio = np.concatenate(self.frames, axis=0)
            return audio

    def save_wav(self, audio_data, filepath):
        """保存为 WAV 文件"""
        with wave.open(str(filepath), 'wb') as wf:
            wf.setnchannels(1)
            wf.setsampwidth(2)  # int16
            wf.setframerate(self.sample_rate)
            wf.writeframes(audio_data.tobytes())


# ─── STT Client ──────────────────────────────────────────────────────────────
class STTClient:
    """调用 STT 服务"""

    def __init__(self, base_url, language="auto"):
        self.base_url = base_url.rstrip("/")
        self.language = language

    def transcribe(self, wav_path, timeout=30):
        """发送音频到 STT 服务，返回识别文字"""
        url = f"{self.base_url}/v1/audio/transcriptions"
        with open(wav_path, 'rb') as f:
            files = {'file': ('audio.wav', f, 'audio/wav')}
            data = {'language': self.language}
            resp = requests.post(url, files=files, data=data, timeout=timeout)
            resp.raise_for_status()
            result = resp.json()
            return result.get('text', '')

    def health_check(self):
        """检查 STT 服务是否在线"""
        try:
            resp = requests.get(f"{self.base_url}/health", timeout=5)
            data = resp.json()
            return data.get('status') == 'ok'
        except Exception:
            return False


# ─── Text Injection ──────────────────────────────────────────────────────────
def inject_text(text):
    """
    将文字注入到当前焦点应用。
    策略：复制到剪贴板 → 模拟 Cmd+V 粘贴
    """
    if not text:
        return

    # 用 osascript 复制到系统剪贴板
    escaped = text.replace('\\', '\\\\').replace('"', '\\"')
    subprocess.run([
        'osascript', '-e',
        f'set the clipboard to "{escaped}"'
    ], capture_output=True)

    time.sleep(0.1)  # 确保剪贴板更新

    # 模拟 Cmd+V
    subprocess.run([
        'osascript', '-e',
        '''
        tell application "System Events"
            keystroke "v" using command down
        end tell
        '''
    ], capture_output=True)


# ─── Sound Effects ───────────────────────────────────────────────────────────
def play_sound(name):
    """播放系统提示音"""
    sounds = {
        'start': '/System/Library/Sounds/Tink.aiff',
        'stop': '/System/Library/Sounds/Bottle.aiff',
        'error': '/System/Library/Sounds/Basso.aiff',
        'success': '/System/Library/Sounds/Glass.aiff',
    }
    path = sounds.get(name)
    if path and os.path.exists(path):
        subprocess.run(['afplay', path], capture_output=True)


# ─── Fn Key Listener (macOS) ─────────────────────────────────────────────────
class FnKeyListener:
    """
    macOS Fn 键监听器。
    Fn 键在 macOS 上是特殊 modifier key，pynput 无法捕获。
    使用 PyObjC NSEvent.addGlobalMonitorForEvents 监听 flagsChanged 事件。
    """

    # NSEventModifierFlagFunction = 1 << 23 = 0x800000
    NS_MODIFIER_FLAG_FUNCTION = 0x800000
    # NSEventTypeFlagsChanged = 12
    NS_EVENT_TYPE_FLAGS_CHANGED = 12

    def __init__(self, on_press, on_release):
        self.on_press = on_press
        self.on_release = on_release
        self._monitor = None
        self._fn_pressed = False

    def start(self):
        try:
            from AppKit import NSEvent, NSEventMaskFlagsChanged
            import objc

            def event_handler(event):
                modifier_flags = event.modifierFlags()
                is_fn = bool(modifier_flags & self.NS_MODIFIER_FLAG_FUNCTION)
                if is_fn and not self._fn_pressed:
                    self._fn_pressed = True
                    self.on_press()
                elif not is_fn and self._fn_pressed:
                    self._fn_pressed = False
                    self.on_release()

            self._monitor = NSEvent.addGlobalMonitorForEventsMatchingMask_handler_(
                NSEventMaskFlagsChanged,
                event_handler,
            )
            if self._monitor is not None:
                print("✅ Fn 键监听已启动 (PyObjC NSEvent)")
                return True
            else:
                print("⚠️ NSEvent.addGlobalMonitorForEvents 返回 None")
                print("   需要在 系统设置 → 隐私与安全 → 辅助功能 中授权")
                return False
        except ImportError as e:
            print(f"❌ PyObjC 不可用: {e}")
            print("   请安装: pip install pyobjc-framework-Cocoa")
            return False
        except Exception as e:
            print(f"❌ Fn 键监听启动失败: {e}")
            return False

    def stop(self):
        if self._monitor is not None:
            try:
                from AppKit import NSEvent
                NSEvent.removeMonitor_(self._monitor)
            except Exception:
                pass
            self._monitor = None


# ─── Hotkey Listener ─────────────────────────────────────────────────────────
class HotkeyListener:
    """全局热键监听（需要辅助功能权限）"""

    def __init__(self, hotkey_name, on_press, on_release):
        self.hotkey_name = hotkey_name
        self.on_press = on_press
        self.on_release = on_release
        self._listener = None
        self._thread = None

    def start(self):
        try:
            from pynput import keyboard

            def on_key_press(key):
                try:
                    if key == keyboard.Key[self.hotkey_name]:
                        self.on_press()
                except (AttributeError, KeyError):
                    pass

            def on_key_release(key):
                try:
                    if key == keyboard.Key[self.hotkey_name]:
                        self.on_release()
                except (AttributeError, KeyError):
                    pass

            self._listener = keyboard.Listener(
                on_press=on_key_press,
                on_release=on_key_release,
            )
            self._listener.daemon = True
            self._listener.start()
            return True
        except Exception as e:
            print(f"热键监听启动失败: {e}")
            print("需要在 系统设置 → 隐私与安全 → 辅助功能 中授权")
            return False

    def stop(self):
        if self._listener:
            self._listener.stop()


# ─── Main App ────────────────────────────────────────────────────────────────
class VoiceInputApp(rumps.App):
    """macOS 菜单栏语音输入"""

    def __init__(self):
        self.config = load_config()
        super().__init__(
            name="🎤",
            title="🎤",
            quit_button=None,
        )

        self.recorder = AudioRecorder(self.config['sample_rate'])
        self.stt = STTClient(self.config['stt_url'], self.config['language'])
        self.is_recording = False
        self.is_processing = False
        self._hotkey_listener = None

        # 菜单项
        self.status_item = rumps.MenuItem("✅ STT 服务在线")
        self.record_item = rumps.MenuItem("🎙️ 开始录音 (F5)", callback=self.toggle_record)
        self.menu = [
            self.status_item,
            None,  # separator
            self.record_item,
            rumps.MenuItem("📋 粘贴上次结果", callback=self.paste_last),
            None,
            rumps.MenuItem("⚙️ 设置...", callback=self.open_settings),
            rumps.MenuItem("📝 查看日志", callback=self.open_log),
            None,
            rumps.MenuItem("❌ 退出", callback=self.quit_app),
        ]

        self.last_text = ""
        self.log_file = CONFIG_DIR / "log.txt"

        # 启动时检查服务
        threading.Thread(target=self._check_service, daemon=True).start()

        # 启动热键
        self._setup_hotkey()

    def _check_service(self):
        """后台检查 STT 服务状态"""
        if self.stt.health_check():
            self.status_item.title = "✅ STT 服务在线"
        else:
            self.status_item.title = "❌ STT 服务离线"

    def _setup_hotkey(self):
        """设置全局热键"""
        hotkey = self.config.get('hotkey', 'fn')

        if hotkey == 'fn':
            # Fn 键：使用 PyObjC NSEvent 监听
            self._hotkey_listener = FnKeyListener(
                on_press=self._hotkey_press,
                on_release=self._hotkey_release,
            )
            if self._hotkey_listener.start():
                self.record_item.title = "🎙️ 开始录音 (Fn)"
            else:
                self.record_item.title = "🎙️ 开始录音 (Fn 不可用)"
        else:
            # 其他键：使用 pynput
            self._hotkey_listener = HotkeyListener(
                hotkey,
                on_press=self._hotkey_press,
                on_release=self._hotkey_release,
            )
            if self._hotkey_listener.start():
                self.record_item.title = f"🎙️ 开始录音 ({hotkey.upper()})"
            else:
                self.record_item.title = "🎙️ 开始录音 (热键不可用)"

    def _hotkey_press(self):
        """热键按下 — 开始录音"""
        if not self.is_recording and not self.is_processing:
            rumps.notification(
                "Voice Input", "",
                "🎙️ 录音中... 松开键结束",
                sound=False,
            )
            self._start_record()

    def _hotkey_release(self):
        """热键松开 — 停止录音并识别"""
        if self.is_recording:
            self._stop_record_and_transcribe()

    # ─── Menu Callbacks ──────────────────────────────────────────────────
    def toggle_record(self, _=None):
        """菜单点击切换录音"""
        if self.is_recording:
            self._stop_record_and_transcribe()
        elif not self.is_processing:
            self._start_record()

    def paste_last(self, _=None):
        """粘贴上次识别结果"""
        if self.last_text:
            inject_text(self.last_text)

    def open_settings(self, _=None):
        """打开设置文件"""
        subprocess.run(['open', str(CONFIG_FILE)])

    def open_log(self, _=None):
        """打开日志"""
        if self.log_file.exists():
            subprocess.run(['open', '-a', 'Console', str(self.log_file)])

    def quit_app(self, _=None):
        """退出"""
        if self._hotkey_listener:
            self._hotkey_listener.stop()
        rumps.quit_application(self)

    # ─── Core Logic ──────────────────────────────────────────────────────
    def _start_record(self):
        """开始录音"""
        self.is_recording = True
        self.title = "🔴"
        self.record_item.title = "⏹️ 停止录音"
        try:
            self.recorder.start()
            if self.config.get('sound_effect'):
                play_sound('start')
        except Exception as e:
            self.is_recording = False
            self.title = "🎤"
            self.record_item.title = "🎙️ 开始录音"
            rumps.notification("Voice Input", "错误", f"录音启动失败: {e}", sound=True)

    def _stop_record_and_transcribe(self):
        """停止录音并异步识别"""
        audio = self.recorder.stop()
        self.is_recording = False
        self.is_processing = True
        self.title = "⏳"
        self.record_item.title = "⏳ 识别中..."

        if self.config.get('sound_effect'):
            play_sound('stop')

        if audio is None or len(audio) == 0:
            self._reset_ui()
            rumps.notification("Voice Input", "", "没有录到音频", sound=False)
            return

        # 异步识别
        threading.Thread(
            target=self._transcribe_worker,
            args=(audio,),
            daemon=True,
        ).start()

    def _transcribe_worker(self, audio):
        """后台线程：保存音频 → 调用 STT → 注入文字"""
        try:
            # 保存临时 WAV
            tmp = tempfile.NamedTemporaryFile(suffix='.wav', delete=False)
            tmp.close()
            self.recorder.save_wav(audio, tmp.name)

            # 调用 STT
            text = self.stt.transcribe(tmp.name)

            # 清理临时文件
            try:
                os.unlink(tmp.name)
            except Exception:
                pass

            if text:
                self.last_text = text
                self._log(f"识别结果: {text}")

                # 自动粘贴
                if self.config.get('auto_paste', True):
                    inject_text(text)
                    rumps.notification(
                        "Voice Input", "✅ 识别完成",
                        text[:80] + ("..." if len(text) > 80 else ""),
                        sound=False,
                    )
                else:
                    rumps.notification(
                        "Voice Input", "✅ 识别完成",
                        f"按 F5+空格 粘贴: {text[:60]}",
                        sound=False,
                    )

                if self.config.get('sound_effect'):
                    play_sound('success')
            else:
                rumps.notification("Voice Input", "", "识别结果为空", sound=False)
                if self.config.get('sound_effect'):
                    play_sound('error')

        except requests.exceptions.ConnectionError:
            self._log("错误: 无法连接 STT 服务")
            rumps.notification("Voice Input", "❌ 错误", "无法连接 STT 服务", sound=True)
            self.status_item.title = "❌ STT 服务离线"

        except Exception as e:
            self._log(f"错误: {e}")
            rumps.notification("Voice Input", "❌ 错误", str(e), sound=True)

        finally:
            self._reset_ui()

    def _reset_ui(self):
        """恢复 UI 状态"""
        self.is_processing = False
        self.is_recording = False
        self.title = "🎤"
        hotkey = self.config.get('hotkey', 'f5')
        self.record_item.title = f"🎙️ 开始录音 ({hotkey.upper()})"

    def _log(self, msg):
        """写日志"""
        try:
            ts = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            with open(self.log_file, 'a') as f:
                f.write(f"[{ts}] {msg}\n")
        except Exception:
            pass


# ─── Entry Point ─────────────────────────────────────────────────────────────
if __name__ == "__main__":
    print("🎤 Voice Input for macOS")
    print(f"   配置: {CONFIG_FILE}")
    print(f"   热键: F5 (按住录音，松开识别)")
    print(f"   菜单栏点击 🎤 图标操作")
    print()
    app = VoiceInputApp()
    app.run()
