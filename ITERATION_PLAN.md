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
