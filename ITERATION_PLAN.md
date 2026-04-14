# VoiceInput 商业化打磨 — 迭代计划

## 迭代 Loop 结构
每个迭代 = 修复 → 编译验证 → Git commit → 下一轮

## Issue 清单

### P0 — 崩溃/数据丢失
- [ ] STTClient.init `URL(string:)` force unwrap → 崩溃
- [ ] STTClient `websocketURL()` force unwrap → 崩溃
- [ ] TextInjector `Thread.sleep` 阻塞主线程 → UI 冻结
- [ ] wavData 硬编码 16000 sampleRate → 与 Config 脱节
- [ ] AudioRecorder permission `DispatchSemaphore` 阻塞主线程
- [ ] audioBuffer 无大小限制 → 内存爆

### P1 — 用户体验缺陷
- [ ] NSUserNotification 已弃用 → macOS 14+ 不显示通知
- [ ] 无辅助功能权限检查 → 注入静默失败
- [ ] 菜单栏图标无状态区分 (idle/recording/processing/error)
- [ ] 无录音时长显示
- [ ] 无录音中视觉反馈 (只有图标变化)
- [ ] 错误提示不友好 (直接显示技术信息)
- [ ] STT URL 默认内网 IP → 新用户无法使用

### P2 — 交互打磨
- [ ] 设置是打开 JSON 文件 → 应有 GUI 设置窗口
- [ ] 无状态栏 tooltip
- [ ] 无最近识别结果预览
- [ ] 服务离线时无自动重连
- [ ] 录音太短 (<0.5s) 无提示直接失败

### P3 — 生产加固
- [ ] 日志无轮转 → 文件无限增长
- [ ] 无开机自启动选项
- [ ] 无重试机制 (STT 请求失败直接报错)
- [ ] Config I/O 错误被 try? 吞掉
- [ ] healthCheck 无超时
- [ ] 无 app 版本号显示

## 迭代节奏
每轮 ~10 分钟，按 P0 → P1 → P2 → P3 顺序推进
每轮结束编译验证 + git commit
