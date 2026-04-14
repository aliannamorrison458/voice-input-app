# VoiceInput 商业化打磨 — 迭代计划

## 迭代 Loop 结构
每个迭代 = 修复 → 编译验证 → Git commit → 下一轮

## Issue 清单

### P0 — 崩溃/数据丢失
- [x] STTClient.init `URL(string:)` force unwrap → 崩溃
- [x] STTClient `websocketURL()` force unwrap → 崩溃
- [x] TextInjector `Thread.sleep` 阻塞主线程 → UI 冻结
- [x] wavData 硬编码 16000 sampleRate → 与 Config 脱节
- [x] AudioRecorder permission `DispatchSemaphore` 阻塞主线程
- [x] audioBuffer 无大小限制 → 内存爆

### P1 — 用户体验缺陷
- [x] NSUserNotification 已弃用 → macOS 14+ 不显示通知
- [x] 无辅助功能权限检查 → 注入静默失败
- [x] 菜单栏图标无状态区分 (idle/recording/processing/error)
- [x] 无录音时长显示
- [x] 无录音中视觉反馈 (只有图标变化)
- [x] 错误提示不友好 (直接显示技术信息)
- [x] STT URL 默认内网 IP → 新用户无法使用

### P2 — 交互打磨
- [x] 设置是打开 JSON 文件 → 应有 GUI 设置窗口
- [x] 无状态栏 tooltip
- [x] 无最近识别结果预览
- [x] 服务离线时无自动重连
- [x] 录音太短 (<0.5s) 无提示直接失败

### P3 — 生产加固
- [x] 日志无轮转 → 文件无限增长
- [x] 无开机自启动选项
- [x] 无重试机制 (STT 请求失败直接报错)
- [x] Config I/O 错误被 try? 吞掉
- [x] healthCheck 无超时
- [x] 无 app 版本号显示

## 迭代节奏
每轮 ~10 分钟，按 P0 → P1 → P2 → P3 顺序推进
每轮结束编译验证 + git commit

## 深度打磨阶段 (UX 精修)

### 打磨1: UX-1 视觉与动效 (2026-04-15)
- 录音中菜单栏图标脉冲呼吸灯动画 (alphaValue 0.3-1.0, 0.5s 间隔)
- 所有 tooltip 改为多行富信息格式:
  - idle: "VoiceInput 就绪\n按住 Fn 键开始录音\n点击菜单查看更多选项"
  - recording: "正在录音中…\n松开 Fn 键停止并识别"
  - processing: "正在识别中…\n请稍候"
  - error: "出现问题\n点击菜单查看详情或重试"
- 引入 QuartzCore import 实现 NSAnimationContext 渐变效果
- 动画停止时正确清理 Timer 并恢复 alphaValue=1.0

### 打磨2: UX-2 交互流畅度 (2026-04-15)
- 热键按下后即时 UI 反馈 (<50ms): 立即更新图标、菜单项、启动计时器
- AVAudioEngine 初始化移至后台线程 (DispatchQueue.global userInteractive)，不阻塞 UI
- 录音状态设置从 startRecording() 拆分到 onHotkeyPress()，实现"按键即响应"
- toggleRecord() 菜单操作复用 onHotkeyPress() 确保一致体验
- 错误处理增加 DispatchQueue.main.async 包装，保证 UI 操作在主线程

### 打磨3: UX-3 错误与恢复 (2026-04-15)
- 磁盘空间监控: 启动时 + 每60秒检查，<100MB 时警告用户
- 辅助功能权限实时检测: 每60秒检查权限是否被撤回，变化时立即通知
- 定期健康检查定时器 (healthCheckTimer) 正确生命周期管理
- 所有定时器在 quitApp 中统一清理

### 打磨4: UX-4 可发现性 (2026-04-15)
- 首次启动引导: 2秒后发送通知 "按住 Fn 键开始说话，松开自动识别"
- 使用 UserDefaults 记录是否已展示过引导，不重复显示
- 新增菜单项「❓ 使用帮助」(Cmd+? 快捷键)
- 帮助弹窗包含: 基本操作、功能说明、快捷键列表

### 打磨5: UX-5 设置体验 (2026-04-15)
- 设置窗口标题区域: 添加 🎤 图标 + 版本号显示
- 每个分组添加 SF Symbol 图标标题 (server.rack, waveform, gearshape)
- 「恢复默认」添加确认对话框 (防止误操作)
- 识别模式和后端引擎并排布局，节省垂直空间
- 语言和采样率并排布局
- Toggle 添加详细 help 文本说明
- 窗口尺寸调整为 480x440 以适应新布局

### 打磨6: UX-1 视觉与动效 - 第二轮 (2026-04-15)
- 识别中状态添加沙漏翻转动画 (⏳↔⌛ 交替, 0.6s 间隔)
- 用户能直观感知"正在处理中"，而非静止等待

### 打磨7: UX-2 交互流畅度 - 第二轮 (2026-04-15)
- 停止录音后立即切换到处理状态（"⏳ 正在转写..."），不等音频停止完成
- 消除用户在松开 Fn 键后到看到"转写中"之间的空白等待感
- 状态文案从"识别"改为"转写"，更贴切
- 出错时统一使用 resetUI() 恢复，避免遗漏

### 打磨8: UX-3 错误与恢复 - 第二轮 (2026-04-15)
- 热键按下时预检 STT 客户端是否已配置，未配置则立即报错（不再等录音完再报）
- 菜单栏服务状态显示当前服务地址 (如 "✅ STT 服务在线 (http://127.0.0.1:7700)")
- STTClient 新增 currentBaseURL 属性，暴露连接地址给 UI 显示
