# LLM 摘要接入方案

日期：2026-11-16（Asia/Shanghai）。状态：已实现 Rust 后端、Swift RPC、可配置模型、摘要持久化与导出；真实服务待用户接入体验。

## 架构决定

采用 Codex 的客户端与 Rust 执行后端分离方式：SwiftUI / MeetingCore 通过本地 JSON-RPC 调用随应用打包的 Rust 摘要后端，由 Rust provider 对接兼容 OpenAI 协议的服务。

```text
SwiftUI 设置与会议详情
        │
MeetingCore：转写协调、摘要状态、持久化与导出
        │ JSON-RPC / stdio（每行一条 JSON）
meeting-summary：Rust 本地执行后端
        │ SummaryProvider trait
OpenAICompatibleProvider
        │ HTTPS / OpenAI 兼容 API
用户配置的模型服务
```

对齐的是 Codex 的进程分层和通信方式。界面继续采用原生 SwiftUI；Rust 后端专注于摘要，无需引入 Codex Agent 的工具执行、会话或审批功能。协议由本项目定义，参考 [Codex App Server](https://developers.openai.com/codex/app-server) 的请求 ID、响应及通知机制。

Rust 使用 `reqwest`、`serde` / `serde_json` 和异步任务处理 HTTP、序列化及取消。OpenAI API 的协议适配由 Rust provider 实现；不再以使用官方 TypeScript SDK 作为依赖条件。

## 各层职责

| 层 | 职责 |
| --- | --- |
| SwiftUI | Base URL / API Key / 模型设置、生成与重试入口、摘要展示和进度反馈。 |
| MeetingCore | 判断最终转写何时就绪、构造摘要输入、计算输入指纹、调用 Rust、保存摘要及导出。 |
| Swift RPC client | 启动并管理子进程、请求 ID 与响应匹配、通知分发、任务取消和进程退出处理。 |
| Rust RPC server | 协议版本协商、请求校验、任务调度、取消与结构化错误。 |
| Rust SummaryProvider | 模型请求、提示词、长文本分段归并、响应解析及供应商错误归一化。 |

Swift 的 `SummaryProvider` 可作为现有协调器的调用门面；实际模型协议和摘要生成逻辑放在 Rust 的 provider 中。既有转写 provider 与摘要 provider 分别管理自己的任务状态。

## 本地 RPC 契约

- 使用 stdio 上的逐行 JSON-RPC 2.0 消息，协议版本在 `initialize` 握手中明确。
- `summary/generate`：输入请求 ID、会议 ID、语言、带时间及来源的转写文本、输入指纹，以及本次请求所需的 Base URL、API Key 和模型名称；返回摘要文本、实际模型和用量（接口提供时）。
- `summary/progress`：通知当前阶段和已完成分段数，用于长会议反馈。
- `summary/cancel`：按请求 ID 取消后端任务；取消不保证服务端停止计费。
- stdout 专用于 RPC；日志走 stderr，且不记录密钥、转写正文或供应商原始响应。
- 限制单条消息大小；输入过大时返回明确错误，不截断 JSON 或转写后继续生成。
- 连接断开或后端异常退出时，将尚未完成的调用标记为中断，保留已有字幕和摘要；用户可以显式重试。
- 生成超时或进程重启后不自动重放可能已经计费的模型请求。

## 配置与凭据

界面提供 Base URL、API Key 和模型名称三项配置。Base URL 和模型保存到应用配置；API Key 保存在 macOS Keychain，由 Swift 在执行请求时读取，经匿名管道传给 Rust，只在任务内存中使用。

校验 Base URL 的 scheme、host 与路径；远程服务使用 HTTPS，本机回环地址允许 HTTP。拒绝 URL 内的账号、密码、query 和 fragment。包含路径前缀的地址应正确拼接 API 路径。HTTP 重定向不能把 Bearer Key 转发至其他地址。

模型由用户显式配置（默认 `gpt-4o-mini`），所有分段与合并直接使用该模型，不依赖 `/models` 发现，也不会在报错时切换模型。DeepSeek 示例：`https://api.deepseek.com` + `deepseek-chat`。服务返回实际模型名时保存该名称。旧 RPC 调用未提供 model 字段时，Rust 保留原发现策略以兼容协议；当前应用始终传入用户配置。

Keychain 启动检查只读元数据；日常读取禁止系统授权弹窗，显式设置操作提供授权入口。

## 摘要生命周期与导出

1. 录音结束后等待最终转写就绪；启用云端精校时，等待精校完成再生成摘要。
2. 使用有序转写、语言及来源 / 时间戳构造输入指纹。同一输入已有成功摘要时复用；重新生成由用户显式触发。
3. Swift 维护独立的摘要状态：等待、生成中、完成、失败和中断。摘要失败可以独立重试。
4. 转写变化或会议删除时取消旧摘要任务。提交结果前核对会议、任务 ID 和输入指纹，防止迟到结果覆盖新版本。
5. 摘要与模型、生成时间、输入指纹及状态保存在该会议的 transcript JSON。新增字段可选，旧文件继续可读。
6. HTML 转写导出与转写＋音频导出包含会议摘要；CLI JSON / Markdown 导出也包含摘要。纯音频导出保持音频格式。
7. 导出使用同一份字幕与摘要快照；摘要尚未完成或已过期时明确显示状态。HTML 转义摘要正文，Markdown 按文本安全输出。

## 已完成的实施与打包

- 已新建独立 Rust Cargo 工程并提交 `Cargo.lock`，产出 `meeting-summary` 可执行文件。
- Swift `OpenAISummaryProvider` 现通过 RPC client 调用 Rust；沿用现有协调器的摘要入口和数据结构。
- 已用 Cargo 构建步骤替换 `scripts/build-summary-helper.sh` 中的 Bun / TypeScript 编译；构建目标架构须与应用一致。
- `.app/Contents/MacOS/` 打包 Rust 后端，先签名后端，再签名并验证应用。
- 已清理 `Helpers/summary` 的 TypeScript SDK、Bun 构建和相应依赖声明；只移除已被 Rust 替代的部分。
- 开发机需要 Rust 工具链；最终用户运行打包应用时不需要 Rust、Node 或 Bun。

## 验收

- Rust：通过本地模拟 API 验证 Base URL 路径、Bearer 鉴权、摘要响应、限流、超时、无效响应、取消和长文本归并。
- RPC：验证握手、分帧、请求 ID 匹配、并发响应、后端退出和取消后的迟到响应。
- Swift：验证本地 / 云端转写完成后的触发顺序、同输入复用、失败重试、旧 JSON 兼容及版本变化时丢弃旧结果。
- 导出：HTML、JSON 和 Markdown 均包含成功摘要；摘要含 HTML / Markdown 特殊字符时正确输出。
- 打包：在不依赖开发机 Node / Bun 的环境下启动 Rust 后端，并通过签名校验。
- 真实模型服务验证另行使用用户实际配置，不能把模拟 API 测试当作真实鉴权或摘要质量验证。

## 验证记录（2026-11-16）

- 原有录音/UI 改动已提交并推送：`d031d2b`。
- Rust/Cargo 已由 1.95.0 更新到 stable 1.100.0。
- Rust 12 项测试及 Clippy（warnings 视为错误）通过；provider/RPC 覆盖协议、模型配置、分段归并、错误、取消和并发；Swift 覆盖生命周期、旧数据兼容、取消、失败保留成功摘要以及外部修改保护。
- Swift 完整测试运行通过（MeetingCore 81 项、CLI 21 项，包含默认跳过的硬件/真实识别和按需集成测试）；另行启用真实 Swift/Rust 模拟服务集成测试通过。HTML、CLI JSON/Markdown 导出覆盖摘要内容及特殊字符。
- 本机模拟 API 运行真实 Swift → Rust → HTTP 链路，验证自定义模型、路径前缀、Bearer 鉴权、请求 ID、进度、用量及退出；不使用真实密钥，不代表实际服务鉴权或质量验收。
- Cargo 构建与原生 .app 打包、嵌套后端及应用签名验证通过；运行无需 Node/Bun。
