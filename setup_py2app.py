"""
py2app 打包脚本
用法: python3 setup_py2app.py py2app
生成: dist/VoiceInput.app
"""

from setuptools import setup

APP = ['app.py']
DATA_FILES = []

OPTIONS = {
    'argv_emulation': False,
    'plist': {
        'CFBundleName': 'VoiceInput',
        'CFBundleDisplayName': 'Voice Input',
        'CFBundleGetInfoString': '语音输入工具 - 接入 STT 服务',
        'CFBundleIdentifier': 'com.voiceinput.app',
        'CFBundleVersion': '1.0.0',
        'CFBundleShortVersionString': '1.0.0',
        'NSMicrophoneUsageDescription': 'Voice Input 需要麦克风来录制语音',
        'LSUIElement': True,  # 不在 Dock 显示，只有菜单栏
        'NSHighResolutionCapable': True,
    },
    'packages': ['rumps', 'sounddevice', 'numpy', 'requests', 'pynput'],
    'includes': ['wave', 'tempfile', 'threading', 'subprocess'],
    'excludes': ['tkinter', 'matplotlib', 'scipy'],
    'iconfile': None,  # 可添加 .icns 图标
}

setup(
    name='VoiceInput',
    app=APP,
    data_files=DATA_FILES,
    options={'py2app': OPTIONS},
    setup_requires=['py2app'],
)
