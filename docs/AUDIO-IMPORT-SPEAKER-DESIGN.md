# 音频导入与云端发言人区分设计

日期：2026-11-18（Asia/Shanghai）
状态：v0.3.0 实现与本机自动化验证已完成；双架构发布验证及未执行的系统手工项目见 [v0.3.0 验收记录](RELEASE-0.3.0.md)。

## 1. 目标与范围

本次需求包含两条入口，共用云端转写、发言人展示、逐句回听和摘要链路：

1. 应用录音：录制时保留现有本地字幕；会后选择云端转写时，可开启发言人区分。
2. 音频导入：导入本地音频后直接使用云端转写，不依赖 Apple／Whisper 模型准备，也不先运行本地 ASR；支持发言人区分。

首版支持单文件 WAV、M4A、MP3，实际能否导入以系统解码和内容校验为准。提供文件选择入口，不同时增加批量队列、文件夹导入、拖放、视频提取或其他云供应商。standard 和 compatibility 版本提供相同的导入与云端能力，继续使用各自原有的本地引擎。

发言人区分指本次识别任务内的 speaker diarization：默认显示“发言人 1、发言人 2”，允许用户命名和修正字幕归属。不推断真实姓名，不创建跨会议声纹库，不承诺重叠发言的文字一定完整。

## 2. 当前代码与必须调整的约束

| 当前能力 | 代码位置 | 对本次设计的影响 |
| --- | --- | --- |
| 本地约 10 秒分片，云端按 chunk 并发处理 | `Sources/MeetingCore/ChunkWriter.swift`、`TranscriptionCoordinator.swift` | 独立任务的 speaker 编号不能直接当作整场身份；新增按音轨的长任务路径 |
| Qwen 异步任务已有上传、checkpoint、轮询与用量归属 | `Sources/MeetingCore/QwenTranscriptionProvider.swift` | 复用传输和防重复提交规则；目前请求明确关闭 diarization |
| 字幕绑定单个 chunk，提交时必须位于 chunk 时间范围内 | `Sources/MeetingCore/Transcript.swift` | 整场句子可跨存储分片，不能原样使用逐 chunk 的 commit |
| 点击字幕按 start 跳转 | `Sources/MeetingIntelligence/AppModel.swift`、`PlaybackCoordinator.swift` | 复用播放能力，统一会议相对时间即可 |
| 摘要文本使用来源标签 | `Sources/MeetingCore/SummaryProvider.swift` | 增加发言人标签；改名和归属修正必须使摘要失效 |
| 完整性检查要求本地完成和每个 chunk 的云任务完成 | `Sources/MeetingCore/MeetingReadRepository.swift` | 云端直转、按音轨任务都需要新的完成判定 |
| CLI 为严格 schema，source 只有 application／microphone | `Sources/MeetingCLI/CLISchema.swift` | 新来源和任务语义须显式版本化，不能只在 UI 补标签 |

`AudioSource` 当前表达采集来源，不能把“系统音频”直接命名为某人，也不能将整个“麦克风”音轨认定为一个发言人。历史 Apple 字幕保持原有 engine 和来源。

## 3. 核心决策

### 3.1 存储分片与云端识别单元分开

保留用于落盘、恢复和播放的 `AudioChunk`。新增独立的 `CloudTranscriptionSession`，表示一次可持久化的云端长音频任务；不创建假的存储 chunk 作为整场任务。

| 情况 | 云端识别单元 | 发言人身份范围 |
| --- | --- | --- |
| 应用录音，未开启发言人区分 | 继续现有逐 chunk 精校 | 无发言人推断 |
| 应用录音，开启发言人区分 | 每个音频来源一条连续音轨、一个云任务 | 每条音轨任务内 |
| 导入音频，默认开启发言人区分 | 整个文件的规范化单声道音轨、一个云任务 | 本文件的该次云任务内 |
| 导入音频，主动关闭发言人区分 | 同一条文件任务路径，关闭对应 API 参数 | 无发言人推断 |

系统音频与麦克风分别建任务，不混成一条后丢失来源，也不把两条任务中的 speaker 0 自动合并。同一人在两个来源中出现时，首版可能出现两个发言人条目，UI 必须说明；用户可手动修正归属。不为该行为暗中增加跨任务声纹匹配。

首版对开启发言人区分的每个任务采用 **120 分钟的产品上限**。这是根据官方“建议不超过 2 小时”设置的保护值，不宣称为服务端绝对硬限制。应用录音超限仍完整保存在本机；不再自动提交发言人任务，提示可关闭区分后使用原有分片精校。导入文件若开启区分且超限，在提交前拒绝该配置，允许显式关闭区分后继续；普通文件识别仍须通过独立的服务端时长／大小限制校验。不能默默拆成多个任务并宣称发言人整场一致。

### 3.2 保留完整时间轴

每个音轨任务从会议相对时间 0 开始，到该来源最后一个有效 chunk 的结尾；保留开头空白、采集间隙和重叠时刻。导入音频从文件时间 0 开始。

云端输入规范化为 16 kHz、单声道 PCM WAV，分块读取和写出，不一次加载整场。重采样和声道混合不得改变播放速度，不删中间静音、不拼接跨间隙音频。整轨无声可以作为显式 no-speech 结果跳过，不能通过裁掉局部静音节省上传而破坏时间映射。

复用 `CloudAudioPreparation` 的采样率转换、声道混合和相位抵消保护算法，以及 `PlaybackSchedule`／`MergedAudioExporter` 的时间轴原则；新增可取消的按来源离线构建器。现有 M4A 导出函数会混合来源，不能直接当作本功能输入生成器，也不经过 M4A 再解码来增加有损转换。导入文件重采样需保持转换器状态跨输出分片连续，避免每片重启转换器积累误差。

云任务的 timelineOrigin 固定为 0，返回时间只做单位转换和边界校验，不能再叠加存储 chunk.offset。以整数输出采样帧累计长度，明确末尾填充／裁剪规则；全局时间误差验收不超过 20 ms，播放所需单个 chunk 清单时长仍满足现有 1 ms 一致性检查。

### 3.3 供应商契约与实现前验证

现有模型为 `qwen-audio-3.1-asr-flash-filetrans`。官方 HTTP 文档包含：

- `diarization_enabled`：可选，默认 false，仅支持单声道。
- `speaker_id`：开启区分后用于标识说话人；身份按任务作用域处理，不假定跨任务稳定。
- `speaker_count`：可选参考人数，不能保证输出人数；首版不暴露，使用自动判断。
- 开启区分时建议音频不超过 2 小时。

本次已于 2026-11-18 读取官方 API 页面核对上述字段；没有发送收费请求。实现前还需核对目标模型、北京／新加坡地域、workspace 路由、上传文件大小和音频格式限制、结果字段类型及任务最大生命周期，并以脱敏 fixture 固化。当前可访问的文档页不能替代每个地域和账户的可用性验证，不能借用其他 ASR 型号的上限。

官方参考：

- [Qwen 录音文件识别 HTTP API](https://help.aliyun.com/zh/model-studio/qwen-audio-asr-filetrans-http-api)
- [录音文件识别使用说明](https://help.aliyun.com/zh/model-studio/non-realtime-speech-recognition-user-guide)
- 现有接入背景：[CLOUD-TRANSCRIPTION-PLAN.md](CLOUD-TRANSCRIPTION-PLAN.md)

## 4. 数据结构与版本策略

下列为拟新增／调整的契约，不是可以直接粘贴运行的完整 Swift 定义。

### 4.1 Recording

- 新增可选 `origin`：recorded 或 imported；旧记录缺省为 recorded。
- 导入记录的 `applicationName` 显示“导入音频”，`bundleIdentifier` 为空；文件名去扩展名作为可编辑标题。
- `AudioSource` 增加 imported，仅用于新导入数据；历史 application／microphone 不重标。
- 可选 `importMetadata`：原始文件名、导入时间、解码格式和实际音频时长；不持久化用户原文件绝对路径。
- 导入记录 `startedAt` 表示导入时间，`endedAt` 表示导入完成时间，不能伪造原会议日期；界面明确显示“导入于”，音频长度仍来自 chunks。
- 新建记录保存 `transcriptionPlan`，区分 localThenCloud 与 cloudOnly，不能靠当前 UI 开关推断历史记录执行策略。

### 4.2 云端配置和任务

`CloudTranscriptionConfiguration` 新增 `diarizationEnabled` 和任务策略快照。旧记录缺少字段时按 false 和 legacyChunks 解码；不能因为新版默认设置开启就重传旧会议。新录制的云端区分开关默认开启，导入默认开启，两者均可在提交前关闭。

新任务包含以下信息：

| 字段 | 含义 |
| --- | --- |
| id、runID | 本地任务 UUID 与本轮识别 UUID；创建后落盘，重启不能重建随机身份 |
| source、chunkIDs | 来源与此次任务覆盖的已关闭存储分片 |
| timelineOrigin、duration | 输入在会议时间轴的位置和长度 |
| inputFingerprint | 有序 chunk 信息、音频内容摘要和转换参数的确定性摘要 |
| configuration、model | 地域、workspace、区分开关和模型的任务快照 |
| checkpoint | 沿用 submitting／submitted／rejected 与服务端 taskID、keyID |
| submittedAt、lastPolledAt | 轮询超时、恢复和任务生命周期判断依据 |
| status、error、noSpeechRecognized | 独立可恢复状态，不与本地 ASR 状态混用 |
| usage | 每次完成任务只记录一次用量，不按覆盖的 chunks 复制计费 |

保留读取旧 `cloud.jobs[chunkID]` 的路径，新任务使用独立 sessions 容器和策略字段；不把旧逐 chunk checkpoint 解释成整轨任务。用户对已完成旧会议主动选择“重新转写并区分发言人”时，新建 runID，并明确会重新上传和计费。

### 4.3 TranscriptSegment 与 Speaker

- `TranscriptSegment` 保留 id、source、start、end、text、engine。
- v2 将 `chunkID` 改为可选；旧字幕保留原值，整轨句子通过 `sessionID` 关联任务，不强行绑定句子起点所在 chunk。
- 增加可选 `speakerID`，指向文档中的本地 Speaker UUID，不直接保存一个全局整数作为身份。
- Speaker 包含 id、sessionID、providerSpeakerID、displayName、createdOrder；编号按首次发言时间确定并持久化，重绘 UI 不重新编号。displayName 为空时使用固定默认名。
- 全文内说话人 UUID 唯一；两个来源的相同 providerSpeakerID 对应不同条目，显示来源帮助区分。
- 未返回 speaker 或无法归属时保留 null，显示“未区分发言人”；绝不为缺失结果伪造 speaker 0。
- 用户命名和逐句归属纠正只修改本地文档，不调用 ASR；自动结果与人工覆盖分开保存，便于审计及重新识别后的处理。

新增 `commitSessionResult`：检查任务来源、有限且有序的合法起止时间、整轨时间范围及 speaker 引用；允许一句跨越多个存储分片和采集间隙。一次替换该来源本轮任务覆盖范围内的字幕，替换前保持现有本地结果可用；其他来源结果不受影响。重试已完成任务不重复追加字幕。返回值只有文本而缺时间戳时按失败处理，不能平均分配假时间。

### 4.4 磁盘与 CLI 兼容

新 imported 来源、可空 chunkID 和整轨完成语义超出现有 v1 契约，因此使用磁盘 schemaVersion 2；新应用同时读取 v1／v2。新建记录写 v2；需要本功能的旧记录在首次修改时升级，浏览不触发迁移。不能仅增加枚举值后仍声称旧版可以无损读取。

迁移前保留原始 v1 manifest／transcript 的不可覆盖备份；双文件修改使用迁移 journal 和同目录临时文件，重启可完成或回滚，禁止覆盖损坏原件。备份放专门迁移子目录，避免被 CLI 当成第二份转写扫描。旧版本会拒绝 v2，不承诺跨版本写回；降级恢复只通过显式恢复备份，提醒会丢失备份之后的修改。

CLI 的公开输出 schema 同步升为 2，并更新 `meeting schema`、JSON／Markdown 导出、文档和 fixtures。source 增加 imported、chunk_id 可空，并提供 speaker_id、speaker_name、session_id、转写计划与任务进度。继续读取 v1 磁盘数据，但由新版 CLI 输出 v2 DTO；这是明确的输出契约变更，发布说明需要标注。CLI 继续只读，不新增导入或提交云任务命令。

`local_status` 在 cloudOnly 下为 not_requested，local_completion_ratio 为 null。`content_state` 根据记录保存的执行计划判断：cloudOnly 只要求所需 sessions 全部终态成功且音频完整；localThenCloud 继续要求本地和所需云任务完成。无语音为成功的空结果，不能为了满足检查把未运行的本地任务或所有 chunks 伪标 completed。

## 5. 音频导入流程

1. 侧栏增加“导入音频…”按钮；录制、删除或另一次导入进行中禁用。单文件面板过滤 WAV／M4A／MP3，但解码时重新验证内容。
2. 展示文件名、时长、云服务地域、“区分发言人”和“转写后生成摘要”；后者默认沿用现有已配置摘要服务的自动摘要行为。明确点击开始后上传音频，未配置 Key 时引导设置，不创建自动上传任务。
3. 验证文件可读、时长有限且大于 0、存在音频、服务时长／大小限制和可用存储空间。失败显示具体原因，不截断音频凑上限。若模型／账号／地域已知不支持区分，在提交前阻止该配置。
4. 获得所需文件访问权限后，在专门 staging 目录流式解码为应用自有的 PCM 分片，记录真实采样帧 offset 和 duration；不调用现有带采集增益调整的 ChunkWriter 原样改动用户音量。源文件始终不改动、不移动。
5. 按字节／采样帧显示“导入中”进度，支持取消；成功后关闭文件、校验分片，再通过可恢复的发布步骤写入记录和转写文档。导入未成功前不让 UUID 录音目录被正常库扫描为有效会议。
6. 发布完成后选择该会议，立即允许回放；创建 cloudOnly 的持久化待处理记录，再调度云端 session。原文件被改名或删除不影响已导入内容。
7. 云端完成后显示带发言人的字幕；摘要服务已配置且自动摘要开启时生成 summary，未配置时保留“生成摘要”入口。上传或摘要失败均保留已导入音频。

staging 不使用正常录音 UUID 目录格式；取消或导入失败只清理本次未发布的文件。跨音频和 transcript 根目录的发布通过 journal 恢复，禁止假设跨卷 rename 原子。重启后的孤立 staging 提示重新导入，首版不做字节级续传。临时文件采用用户独占权限，扫描与删除严格限制在应用生成的目录内。

## 6. 云任务状态、重试与结果提交

任务状态：pending → preparing → submitting → submitted → polling → completed。任何阶段可进入 failed／interrupted；应用停止等待不等于服务端已取消，也不保证停止计费。

- 任务计划和输入摘要先落盘，再生成／上传输入；仅在已完成音频可读、通过限额校验后上传。每场最多同时处理两条来源音轨，不把整轨任务放入原来的三路短片段窗口。
- `submitting` checkpoint 在非幂等提交前持久化。提交超时但不知道服务端是否接受时沿用现有规则：停止自动重发，要求用户核对后显式重新提交。
- 一旦有 taskID，重启／网络失败后只继续查询，不重建音频、不重新上传。更换当前设置不会改变该任务模型、地域或 workspace；凭证使用规则与当前 checkpoint keyID 归属机制保持一致。
- 当前轮询约 180 次、传输资源超时约 120 秒的设置针对短任务，不能机械复用。改为可恢复的退避轮询和有界请求超时，尊重 Retry-After；单次等待预算结束保存 interrupted 状态，允许继续同 taskID。任务过期或确定失败后才提供显式新提交，不用无上限 while 持有应用进程。
- 音频变化导致 inputFingerprint 不符时，不把旧结果提交到新音频；提示需要新任务。结果和任务终态在同一个 transcript 文件内原子写入，持久化失败不能在内存标记完成。
- 一条来源失败不取消另一条已经接受的远程任务；保留成功字幕，并将整体标记 partial。恢复只查询／重试未完成 session。
- 全部必需 session 结束后，才触发本轮自动摘要；普通摘要失败只重试摘要，不重跑 ASR。
- 用户“取消”停止本机准备／等待并保存 checkpoint。删除会议先停止本机任务，防止回调重新创建目录；若供应商无已验证的取消接口，明确远程任务可能继续，不虚构远程取消成功。

成功但无语音时保留终态和用量，导入会议显示“未识别到语音”，不生成空摘要。应用录音若存在可用本地字幕，则可保留 fallback，并明确该来源没有云端识别结果、没有发言人归属；不得以“全部完成”的措辞隐藏 fallback。

## 7. 发言人、回听、摘要与导出

### 7.1 展示与修正

字幕行显示时间、发言人、来源和引擎。默认发言人名在文档内唯一，标签颜色仅用于辅助，无障碍名称包含发言人和来源。保留原有点击字幕的逐句跳转和全局播放条。未完成云端替换时继续显示现有本地字幕和处理状态。

增加轻量发言人管理入口：修改名字、将一条字幕改归已存在发言人或“未区分”。已完成云结果的人工修正不会因重新加载而丢失；正在重转写的覆盖范围内禁用修改，避免提交结果与编辑竞态。成功替换后为新 run 创建新身份，不按 provider 编号继承旧真实姓名；保留上一轮结果供显式恢复，不能错误地把上轮张三自动赋给新 speaker 0。

### 7.2 摘要

`SummaryRequest` 同时接受有效字幕和已解析的发言人信息，输入示例：

```text
[00:12 · 发言人 1 · 导入音频] 我们周五发布。
[00:18 · 李明 · 导入音频] 我负责回归测试。
```

提示词要求仅按明确的发言／承诺归属总结，不把提出任务的人推断为负责人，不根据内容猜姓名。摘要包含结论、行动项及可确定的责任人；没有足够依据时写“待确认”。

摘要指纹必须包括最终文本、时间、来源、speakerID、人工归属覆盖和实际显示名称；名字若仅存 Speaker 表而不进入指纹，当前仅编码 segments 的方法将漏掉改名。只编辑 speaker 表也必须使已有摘要过期。升级旧数据时，对没有发言人或新语义变化的 v1 摘要保留旧指纹验证路径，直到实际修改内容，不能因新增 null 字段或新版编码顺序让全部旧摘要无故失效。

正在生成时保存输入快照；任务结束只有指纹仍一致才提交结果。未配置摘要 Key、转写部分失败、没有文字时，不自动启动摘要。

### 7.3 导出和用量

- HTML 字幕和摘要展示发言人，所有用户命名经现有 escape 路径转义，回听继续使用原始会议时间轴。
- CLI JSON／Markdown 使用同一解析后的发言人视图，避免 UI、导出和摘要显示不同名字；`--source` 仍过滤来源，不替代发言人。首版不增加新的 CLI 过滤语法。
- 更新 `APIUsageReport`，同时读取 legacy jobs 和新 sessions；一次任务用量只汇总一次，不因多个 chunk 或多个 speaker 重复计数。已有被替换结果的实际用量保留在独立 run 历史中，不作为零消失；仍不宣称本地统计等于供应商账单。
- 任务ID、上传签名、API Key、私有下载 URL 不进入公开 DTO 或诊断日志；诊断仅记录本地 recording／session/run 关联、阶段、脱敏错误码和时长。

## 8. 组件与变更清单

| 组件 | 计划变更 |
| --- | --- |
| `AudioImporter`（新增） | 可取消解码、文件验证、PCM 分片、staging／发布和进度 |
| `CloudSessionAudioBuilder`（新增） | 按来源构建完整单声道输入，保留时间轴、限制内存和临时磁盘占用 |
| `TranscriptionProvider`／Qwen adapter | 把输入音频描述与存储 chunk 解耦，支持 session 请求和 speaker 解析，复用已审计 HTTP 传输 |
| `TranscriptionCoordinator` | 显式执行计划、legacy／session 双路径、恢复与原子结果替换 |
| Recording／Transcript 模型及迁移器 | v1／v2 解码、导入来源、Speaker、session、journal 与备份 |
| `AppModel`／`ContentView`／`TranscriptPanel` | 导入入口、区分开关、阶段进度、命名与归属纠正 |
| `SummaryProvider`／`MeetingExporter` | 名称解析、指纹和安全导出；Rust 摘要协议若仍传最终文本则无需新增模型字段 |
| `MeetingReadRepository`／CLI schema／usage | 新完成语义、v2 DTO 和不重复计费的汇总 |
| 文档 | 同步 README 英文／简体中文、CLI-DESIGN、CLI-USAGE 和 schema 迁移说明 |

不引入额外 Python 推理进程、声纹依赖或 Whisper 模型；standard 仍不得下载／打包 Whisper。Bundle ID 和两版本共享数据契约保持一致。

## 9. 实施顺序

1. **契约与迁移**：先实现 v1 fixture 兼容、v2 模型、执行计划、session 结果提交和完成判定；锁定供应商字段 fixture。
2. **云端区分**：按来源构建任务，接通 speaker 解析、持久化、恢复和普通录音会后精校，保留关闭区分时的 legacy 路径。
3. **音频导入**：实现 staging 发布和 cloudOnly 调度，确认不触发任何本地模型准备；导入完成即可回放。
4. **消费链路**：发言人命名／修正、摘要、HTML、CLI schema v2 和用量汇总同步完成。
5. **验证与文档**：两版本回归和合成音频验收后更新 README。用户已明确要求本次验证通过后发布下一版本，按 AGENTS.md 的 main → CI → 新 annotated tag 流程发布 v0.3.0。

每阶段先完成可独立验证的最小链路，不能只启用 API 参数就宣称整场发言人支持完成。本文不承诺未经实现验证的准确开发工期。

## 10. 验证与验收

常规测试只使用临时目录、合成音频和 mocked HTTP；不上传真实会议、不调用付费服务。

| 范围 | 必须覆盖的用例 |
| --- | --- |
| 导入 | 三种声明格式的短合成样本；伪扩展名、空文件、损坏／不可读、超限、空间不足、取消；源文件不变；删除源文件后仍可回放 |
| 云端直转 | 未安装本地模型仍能提交；不请求录音／麦克风权限；不执行 local prepare；未配置 Key 不上传 |
| 音频构建 | 单／双声道、相反相位、不同采样率、开头空白、来源间隙、同源片段小重叠、双轨重叠；分片时长与文件帧数一致 |
| 身份与时间 | 同一个 task 多次轮询不改 speaker 身份；两个 task 相同编号不合并；speaker 字段缺失；跨 chunk 句子、合法重叠句、乱序／无效时间戳、片尾误差 |
| 重试恢复 | 提交不确定、429／5xx、断网、长任务超过旧轮询窗口、重启复用 taskID、单来源失败、保存失败、删除后回调；不重复追加或静默重新计费 |
| 结果替换 | 本地 fallback 保留至成功提交；重新识别不继承错误姓名；人工修正不丢失；没有语音不触发空摘要 |
| 摘要与导出 | 以发言人组织输入；改名使摘要过期；生成期间编辑导致旧结果不提交；HTML 注入字符；JSON／Markdown 名称、时间、状态一致 |
| 兼容与完整性 | 真实 v1 fixture 的读取和旧摘要；v2 round trip；缺失新增字段；迁移各崩溃点；CLI require-complete 在 cloudOnly、partial 和 legacy 下正确 |
| 用量 | 多 chunk、多个 speaker 仍只计一次 session；重启不重复；旧任务与新任务并存、重转写历史不遗漏 |

回听自动测试用已知采样帧位置的合成脉冲验证第一／中间／最后一句跳转，误差不超过 20 ms；人工验收同时检查播放条和导出 HTML。合成音频和 mocked speaker fixture 能验证工程正确性，不能证明真人说话人区分准确率；如需质量评测，另用授权样本并显式决定是否进行付费调用。

按仓库约定运行：

```sh
./scripts/test.sh
MEETING_BUILD_EDITION=compatibility ./scripts/test.sh
cargo test --locked --manifest-path Helpers/summary/Cargo.toml
./scripts/build-app.sh release
```

如改动影响 compatibility 打包，另按 [MACOS-15.md](MACOS-15.md) 完成对应构建与运行检查；只有打包相关变更才运行 DMG 工具与挂载验收。实现完成后的验收标准为：两条入口均能使用云端区分、按句回听和生成带发言人的摘要；云端直转不依赖本地 ASR；旧数据可读且无静默迁移或重传；错误和取消可恢复；文档与真实界面一致。
