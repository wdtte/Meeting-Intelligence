# Meeting Intelligence 云端转写调研与接入方案

调研日期：2026-11-15（Asia/Shanghai）。本文保留初次调研方案。后续已按确认实现 Apple / Qwen provider、Qwen-Audio 3.1 异步精校、时间戳回听与整段静音过滤；实际配置和限制见 [README.md](README.md)。

默认场景：中国大陆网络，中文为主、夹杂英文和技术名词，macOS 原生个人桌面应用，先采用用户自备 API Key（BYOK）。价格来自调研当日公开官方文档；没有登录计费控制台、调用收费 API 或上传真实会议音频。识别质量、延迟、账号可用模型及最终账单仍需样本实测。

## 1. 建议先采用什么方案

**建议保留 Apple 本地字幕，增加可选的云端精校；优先验证阿里云百炼 Qwen-Audio 3.1，重点试验蚂蚁百灵 Ling 的 ASR，架构支持多 provider，首版只做少量适配器。**

具体选择如下：

| 目的 | 建议 | 原因与条件 |
| --- | --- | --- |
| 录制中的基础字幕 | 保留 Apple SpeechTranscriber | 已实现，可离线使用，云端失败不阻塞录音 |
| 首选云端候选 | 阿里云百炼 `qwen-audio-3.1-asr-flash` | 官方当前推荐；短文件直接调用，提供时间戳、上下文、热词，适合现有磁盘分段管线；按 Token 计费，需实测每小时成本 |
| 固定时长价格的对照 | `fun-asr-flash-2026-06-15` | 同类直接文件输入，¥0.792/音频小时，便于做成本和效果对照 |
| 低成本会后整场转写对照 | `paraformer-v2` | 北京地域公开价 ¥0.288/音频小时，有时间戳；异步 URL 输入，需额外处理文件托管与作业状态 |
| 用户重点关注的 Ling | `Ming-3.0-asr-tiny` 实验适配器 | 接入简单，但公开 ASR 单价缺失，只有整段文本、最多 30 秒；先验证再决定是否正式推荐 |
| 后续第二家正式云服务 | 腾讯云大模型 2.0 | 文件 ¥0.8/音频小时、实时 ¥1/音频小时，作为国内独立供应商备选；首版不必一起实现 |

“最划算”不能只看最低单价：本项目需要**可回听的时间戳、中文术语质量、双轨成本与可靠续转**。目前能确定：在本次核实的北京地域、按音频时长计价的文件方案中，Paraformer 的公开单位价格最低；Qwen-Audio 3.1 可能更省，但必须用实际 Token 用量换算；Ling 的 ASR 价格暂时不能排位。没有同一组音频的识别结果，不能宣称任何一家精度最高。[S1][S2][S3][S4][S8]

建议首版默认提供“本地转写”和“本地 + 云端精校”，云端默认由用户主动开启。先支持会后精校，再决定是否需要录制中约 10–30 秒延迟的云端更新；真正逐字实时 WebSocket 转写放到后续。

## 2. 先把 Ling 的名称和能力确认清楚

### 2.1 Ling、百灵、百炼不是同一个产品

用户提到的 Ling，本方案按 **Ant Ling / 蚂蚁百灵**理解。其官方 FAQ 明确区分蚂蚁百灵与通义千问：这是不同团队的服务，不能共用账号、Key、价格或 API 地址。[S5]

- **Ling**：蚂蚁百灵平台及其通用语言模型系列。
- **Ming-3.0-asr-tiny**：该平台目前公开语音识别接口指定的模型。
- **阿里云百炼 / Model Studio**：另一个平台，提供 Qwen-Audio、Qwen3-ASR、Fun-ASR、Paraformer 等。

不要将 Ling 文本模型的每百万 Token 价格当成 Ming ASR 的音频价格，也不要用 Ming 全模态模型宣传页替代专用 ASR API 的规格。

### 2.2 Ling ASR 官方已确认的接口

| 项目 | 已确认信息 |
| --- | --- |
| 请求 | `POST https://api.ant-ling.com/v1/audio/transcriptions` |
| 鉴权 | `Authorization: Bearer <API_KEY>` |
| 请求编码 | `multipart/form-data`，直接上传本地文件 |
| 模型 | `Ming-3.0-asr-tiny` |
| 音频 | WAV 或 MP3，单文件 ≤10 MB、时长 ≤30 秒 |
| 语言 | 可选 `language`；不传或空值启用混合语言识别 |
| 上下文 | 可选 `prompt`，建议小于 60 字，适合放前段转录 |
| 结果格式 | 只支持 `response_format=json` |
| 结果内容 | `text`、`usage`、模型与请求标识 |
| 用量 | 输入、输出、总 Token；输入还区分 `audio_tokens` 和 `text_tokens` |
| 官方明确不支持 | `stream`、`timestamp_granularities`、`chunking_strategy`、`keywords`、已知说话人相关参数等 |
| 平台限流参考 | 公共调用限制页写 2 QPS、同步超时 90 秒；ASR 是否有额外限制需账号验证 |

这些来自专用 ASR 文档，而非由“OpenAI 兼容”推断。兼容仅能减少请求封装工作，不能推断它支持 OpenAI 全部参数。[S4][S6]

### 2.3 Ling 对本项目的实际价值与缺口

**价值：**现有约 10 秒 WAV 可以直接作为输入；不需要先建 OSS，不需要轮询异步任务；中文夹英文可从不传语言开始评测。每轨按时间顺序请求，并给同轨前一段不超过约 60 字的上下文，可以验证跨段连续性。

**主要缺口：**公开接口只返回整段文本，没有句级或词级时间戳，也没有说话人分离结果。用一个 10 秒区间承载整段文字，只能实现粗粒度回听；不能把均匀分配出来的时间当成真实对齐时间。

两种合理的产品处理方式：

1. 首版把 Ling 结果标记为“片段级定位”，点击回到这个片段起点；Apple 精细字幕仍可切换查看。
2. 后续引入音频与修订文本的 forced alignment（强制对齐），获得真实文本时间关系。它会增加本地模型、耗时与验证工作，不是首版免费附带能力。

不能直接把 Apple 各句时间戳套给被云端改写、合并或拆分后的句子。云端文本质量提升与时间定位质量必须分别评测。

如果之后合并录音文件再发给 Ling，建议上限 28 秒留余量；当前分段实际长度可能略超 10 秒，不能机械地把三个 chunk 拼成“30 秒”。跨采集间隙不能直接拼接后沿用原时间轴，必须保留间隙或记录映射。

### 2.4 Ling 价格：当前能确认什么

截至调研日，官方公开定价页列出了 Ling 文本和图像模型，**没有列出 `Ming-3.0-asr-tiny` 的输入/输出或音频单价**。ASR 返回 Token 用量不等于已确认按哪套价格扣费。[S4][S7]

免费政策也存在文档差异：FAQ 仍写“每日 50 万 Token”；计费升级说明写，新计费平台改为每月 1 日发 ¥10 Token 抵扣券，新用户或迁移用户有一次性 ¥20 券，且当月 1 日后迁移不补发当月月券。**不能把旧每日免费政策写成当前所有账户都适用，也不能未经确认将通用 Token 券折算成 ASR 小时数。**[S5][S9]

正式启用前，应在自己的控制台核实以下内容；本次没有代为开户、充值或联系供应商：

- ASR 模型是否开放、是否计费、音频与文本输入和输出分别使用什么单价。
- 是否有单请求最低计费量、失败和超时请求是否计费，券是否抵扣 ASR。
- 2 QPS 的具体作用范围、并发上限、商用资源保障和长期可用性。
- 会议音频保存时长、训练使用政策、处理地域及删除机制。

若账单可查，使用一组固定的 10 秒和 28 秒样本测出有效人民币/音频小时；如果只有临时免费而没有持续可用条款，应继续作为实验选项。**当前不建议把 Ling 作为唯一云端引擎。**

## 3. 官方价格与产品能力对比

以下金额为原币报价。人民币小时价按 `元/秒 × 3600` 计算；美元不混入人民币排序。免费额度、企业议价、资源包、对象存储、出网、额外功能和重复处理成本单独计算。

### 3.1 国内方案

| 平台 / 模型 | 类型与地域 | 公布价格 | 每音频小时 | 对本项目的意义 |
| --- | --- | --- | --- | --- |
| 蚂蚁百灵 `Ming-3.0-asr-tiny` | 短文件同步；地域待确认 | 未找到 ASR 专属公开单价 | 待实测/控制台确认 | 输入直接，只有文本，≤30 秒 |
| 百炼 `qwen-audio-3.1-asr-flash` | 短文件同步，北京 | 输入 ¥0.8/百万 Token；输出 ¥2.7/百万 Token | 随实际用量变化 | 优先评测，支持句/词时间戳、热词和上下文 |
| 百炼 `qwen-audio-3.1-asr-flash-filetrans` | 长文件异步，北京 | 同上 | 随实际用量变化 | 会后长音频、说话人分离 |
| 百炼 `qwen-audio-3.1-asr-flash-streaming` | 真正实时，北京 | 输入 ¥6/百万 Token；输出 ¥4.5/百万 Token | 随实际用量变化 | 不可套用短文件接口的 Token 单价 |
| 百炼 `fun-asr` / `fun-asr-flash-2026-06-15` | 异步长文件 / 同步短文件，北京 | ¥0.00022/秒 | **¥0.792** | 一个适合长作业，一个适合当前分段 |
| 百炼 `paraformer-v2` | 文件异步，北京 | ¥0.00008/秒 | **¥0.288** | 本次核实的北京地域按时长计费文件方案中最低 |
| 百炼 `fun-asr-realtime` | 真正实时，北京 | ¥0.00033/秒 | **¥1.188** | 与文件版分开预算 |
| 百炼 `paraformer-realtime-v2` | 真正实时，北京 | ¥0.00024/秒 | **¥0.864** | 成本对照，不代表精度结论 |
| 腾讯云录音文件识别大模型 2.0 | 文件异步，国内非跨境，后付费 | ¥0.8/小时 | **¥0.8** | 国内独立供应商备选 |
| 腾讯云实时语音识别大模型 2.0 | 真正实时，国内非跨境，后付费 | ¥1/小时 | **¥1** | 名义时长单价低于 Fun-ASR 实时；功能须对齐验证 |

来源：[S1][S2][S3][S7][S8][S10]。腾讯不同引擎/版本差价很大，表中不是旧版 1.0，也不是极速版或跨境版；其大模型版本无表中传统引擎的月度免费时长，后付费需手动开启。

需要特别区分的地域与版本：

- 百炼 Fun-ASR 文件版在新加坡为 ¥0.00026/秒，即 ¥0.936/音频小时；Fun-ASR 实时新加坡为 ¥0.00066/秒，即 ¥2.376/音频小时。
- 百炼 Qwen-Audio 3.1 短文件/异步文件新加坡单价为输入 ¥1.094、输出 ¥3.427/百万 Token，不能沿用北京价格。
- 官方价格页另列旧一代 `qwen3-asr-flash` 美国弗吉尼亚价 ¥0.000035/秒，即 ¥0.126/音频小时。它是另一个模型和地域：网络、处理地域、时间戳能力都需另审，不作为大陆默认路线；本方案的“北京最低”不涵盖该地域。
- Paraformer 北京每月 10 小时免费额度与部分模型 90 天内试用 10 小时不是同一种权益。Qwen-Audio 3.1 公开北京试用额度为 100 万 Token，不是 10 小时。长期预算以付费价为准。[S1]

火山引擎豆包语音也值得作为后续国内对照：已核实其极速版支持单次上传、同步返回，最大 100 MB / 2 小时；本次未取得可与上表同口径核对的公开价格，因此不为它填写推测单价，也不据此宣称它更贵。[S11]

### 3.2 海外方案参考

| 平台 / 型号 | 已核实公开价格 | 使用判断 |
| --- | --- | --- |
| AssemblyAI Universal-2 | 预录音 $0.15/小时 | 有多语言文件服务；中文和术语表现需要同集测试 |
| AssemblyAI Universal-3.5 Pro | 预录音 $0.21/小时；说话人分离另加 $0.02/小时，Keyterms 另加 $0.05/小时 | 不能只拿“基础价”对比包含全部功能的服务 |
| Deepgram Nova-3 Multilingual | 当前价格页 Streaming PAYG $0.0058/分钟，即 $0.348/小时 | 这是当前页面的实时显示价；不是预录音价格，也不是旧划线价；目标语种和附加功能需按具体模型核实 |
| OpenAI `gpt-live-transcribe` | 当前官方定价页 $0.017/分钟，即 $1.02/小时 | 真正实时价格参考，不能拿它推导所有文件转写模型价格 |

来源：[S12][S13][S14]。海外供应商还需验证目标地区服务可用性和真实网络表现；首版大陆中文场景没有充分理由为了接口统一优先选择它们。常见文章引用的旧模型名与旧价不能替代当前官网核实结果。Groq 旧价格地址在本次访问中已跳至首页，没有据历史报价给出排名。

## 4. 按会议而非单条音轨估算成本

### 4.1 双轨计费是核心变量

当前 `Recording.duration` 是会议时间轴长度，`Recording.audioDuration` 是完整 chunk 时长之和。后者更接近分轨提交时的计费量：一小时会议同时录应用与麦克风，如果两路都完整上传，通常是约两小时输入，而非一小时。

按时长计费时的预算公式：

`费用 ≈ Σ(各次实际提交的计费秒数 × 对应地域/模型单价) + 存储/出网/附加功能`

不能假设服务端 VAD 自动减少账单；应按实际上传时长和供应商计费规则预算。多声道也不能默认只计一次，多轨拼成立体声不保证更省。

| 方案 | 1 小时会议，只上传一轨 | 1 小时会议，两轨全上传 | 每月 100 小时会议，两轨全上传 |
| --- | --- | --- | --- |
| Paraformer 文件 | ¥0.288 | ¥0.576 | ¥57.6 |
| Fun-ASR / Fun-ASR-Flash 文件 | ¥0.792 | ¥1.584 | ¥158.4 |
| 腾讯大模型 2.0 文件 | ¥0.8 | ¥1.6 | ¥160 |
| 腾讯大模型 2.0 实时 | ¥1 | ¥2 | ¥200 |
| Fun-ASR 实时 | ¥1.188 | ¥2.376 | ¥237.6 |

这是未扣免费额度、未计重叠和重试的基础预算。为了对照而将一整场会同时发给三家，会产生三份输入费用，不能作为生产默认。

### 4.2 Qwen-Audio 3.1 的成本公式

北京短文件/异步文件：`费用 = input_tokens × 0.8 / 1,000,000 + output_tokens × 2.7 / 1,000,000`。

仅演示公式：假设某一小时音轨累计输入 50,000 Token、输出 20,000 Token，则为 ¥0.094；两轨若用量相同为 ¥0.188。**这组 Token 数是假设，不是官方每小时换算率或实测结果，不能作为报价承诺。**音频 Token、上下文长度、输出形式和重试都会改变结果。

对照 Paraformer 的 ¥0.288/音频小时，若输出为 20,000 Token，则输入低于 292,500 Token/小时，Qwen-Audio 3.1 的上述模型费更低；这可作为试验时的直接判断线。最终用账单验证，兼顾托管成本和准确率。

Ling 待取得 ASR 单价后，使用同一方法，并分别记录 `audio_tokens`、`text_tokens` 和输出量；不能用 Ling 文本模型单价代算。

### 4.3 首版节流与后续优化

- 首版按完整片段计费，提供预计音频时长、预估费用或“价格待确认”，用户可只选择某一路。
- 保持原始音频，上传副本统一为 16 kHz、16-bit、单声道 PCM WAV：约 32 KB/秒，10 秒约 0.32 MB，28 秒约 0.90 MB，每轨约 115.2 MB/小时（十进制）。Base64 增加约三分之一传输量；压缩字节本身不会降低按时长收费。
- 后续验证本地 VAD，跳过确认纯静音段；裁剪保留约 200–500 ms 保护区并记录时间映射，避免截掉轻声、起音与停顿中的短词。VAD 误删应计入质量验收。
- 评测后再决定是否增加重叠窗口。每 20 秒额外重复 1 秒音频约增加 5% 输入；Token 计费还需另计重复上下文。先不在首版默认叠加多个优化。
- 不默认混成单轨来省钱：会失去可靠采集来源，并增加抢话识别难度。耳机/扬声器重复收录是采集问题，跨轨“相同文本”不应直接删除。

## 5. 如何接入现有工程

### 5.1 已有基础与不能直接沿用的部分

已阅读 `README.md`、`LocalTranscriber.swift`、`TranscriptionCoordinator.swift`、`Transcript.swift`、`ChunkWriter.swift`、`Recording.swift`、`AppModel.swift` 和 `SettingsPage.swift`。

- `ChunkWriter` 按来源保存约 10 秒的完整 WAV，采集间隙会关闭当前片段，设备采样率/声道可能不同；可复用磁盘和统一会议时间轴。
- `TranscriptionCoordinator` 已可注入识别闭包，但默认准备流程只支持 Apple；现有暂停、续转逻辑可作为基础，不必重写采集层。
- `TranscriptDocument.processedChunks` 仅以 chunk ID 记录已处理；本地已转过的 chunk 会让新云任务直接跳过，必须扩展任务身份。
- `TranscriptDocument.commit` 要求所有结果属于同一 chunk/source，且时间在该 chunk 范围内；多 chunk 窗口不能伪装成单 chunk 结果提交。
- `engine` 是整份文档的单一字符串，`schemaVersion` 只接受 1；无法直接准确表达多模型、不同版本和粗/细时间戳。
- `AudioSource` 明确是 application / microphone，不能因增加云端而改成 speaker 角色。

### 5.2 最小架构：能力接口 + 明确适配器

建议增加概念上的 `TranscriptionProvider`，描述 provider ID、模型、地域、输入限制、是否支持时间戳/热词/说话人分离，以及文件转写操作。当前只落实文件转写接口；实时连接作为独立会话能力，等有需求再实现。

首版适配器范围：

1. `AppleLocalProvider`：包装现有实现。
2. `AliyunFileProvider`：优先 Qwen-Audio 3.1，兼容经验证的 Fun-ASR-Flash 请求与结果差异；异步 Paraformer/Filetrans 后续扩展同一平台的另一种作业类型。
3. `LingFileProvider`：一个具体的 OpenAI audio/transcriptions 子集适配器，标记实验与片段级定位；价格/账号未验证时不作为默认项。

可共享 HTTP、multipart、重试和 Keychain 基础设施；provider 参数映射和响应解析仍保持独立。不要为“支持多 provider”首版做插件市场、动态模型发现、任意脚本或万能 OpenAI 兼容配置。

### 5.3 首选阿里云请求流程

1. 用户配置北京地域 Workspace ID、API Key 与模型；Keychain 保存凭据，普通设置只保存配置与 Keychain 引用。
2. 从已关闭 WAV 读取，后台生成上传副本。首版一请求对应一个 chunk，先复用已有提交边界；不在 Core Audio 实时回调里做重采样、网络或编码。
3. 使用 `URLSession` 调原生 HTTP：`POST https://{WorkspaceId}.cn-beijing.maas.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation`，Bearer 鉴权、JSON 内容。[S10]
4. `model=qwen-audio-3.1-asr-flash`；`input.messages` 最后一条 user 消息放 `input_audio.data=data:audio/wav;base64,...`；`parameters.format=wav`、`sample_rate=16000`。需要同轨上下文和热词时按模型文档添加。
5. 首版不开 SSE，完整上传后取得结果；解析模型对应的句/词最终结果、`usage`、`request_id`。若后续启用 SSE，只提交稳定时间戳；3.1 使用词的 `fixed` 标记，开启分离时结果结构改读 `output.sentences`。[S10]
6. 时间从毫秒转换为秒，加 chunk 的真实 `offset` 后校验，再原子保存。不要仅保存 `output.text` 而丢掉定位数据；多句结构与累计文本应以实际响应夹具验证，避免漏句或重复累计。

该短文件模式无需用户部署服务器或对象存储。已有旧 `dashscope.aliyuncs.com` 接入域名，但当前官方建议业务空间专属域名；配置应显式包含地域与 Workspace ID，不把新旧域名混成一个全局 base URL。[S10]

后续整场 Filetrans/Paraformer：上传至受控临时对象存储或官方临时文件机制，传可访问 URL → 保存 task ID → 退避查询 → 按文件检查状态 → 下载结果并持久保存。URL 有效期必须覆盖排队与重试；不能使用无法访问的本机路径。结果下载链接可能仅有效 24 小时，成功后立即落盘；已取得 task ID 时优先查询而不是重新提交。[S2][S15]

### 5.4 Ling 请求流程

Swift 原生 `URLSession` multipart 即可，无需为此引入 Python、Node 或 OpenAI SDK。请求携带模型、WAV 文件及可选 language/prompt；mixed 模式省略 language，保留英文术语作为评测项目。

首版逐个完整 chunk 提交，可控制在 30 秒限制内；同轨按顺序处理才能稳定使用前文。multipart 的 boundary 由客户端生成并正确写入 Content-Type，不能只写裸 `multipart/form-data` 而不含 boundary。

结果记录区间为整个 chunk，`timestampPrecision=chunk`，UI 明示片段级定位；不生成虚假的字/句时间。保存请求 ID 与 Token 用量。按公共平台 2 QPS 做保守调度，但不要把 2 QPS 与允许两个并发请求混为一谈；与同账号其他模型共享的情况也应考虑。

### 5.5 字幕版本和任务持久化

建议引入独立 `TranscriptionRun`，保留原本地稿，再生成云端稿，并记录当前展示版本。用户编辑稿不要被后台云结果覆盖。

| 数据 | 建议新增的信息 |
| --- | --- |
| Run | run ID、录音 ID、provider、model、region、配置快照/哈希、创建时间、状态 |
| Job | job ID、源轨、chunk ID、输入校验值、状态、attempt、task/request ID、用量、错误类别 |
| Segment | 原有 source/time/text；附加 run ID、时间精度、可选 speaker ID 和 provider 原始关联信息 |
| 使用量 | 实际上传秒数、输入/输出 Token、调用次数、重试量、币种与价格快照、估算/实账区分 |

完成标记必须与 run/config 绑定，而非全局 `processedChunks`。同一 chunk 的 Apple、Ling 和阿里云结果可以并存；切换 provider 后创建新 run，不把旧任务“已完成”标记误用到新模型。

落盘策略：原 schema v1 兼容加载为 Apple 历史稿；新 run 使用独立带版本的文件/清单，先写完成再原子切换展示引用。若升级公共 schema，则实现明确的 v1→v2 解码与迁移，不能只改版本常量。损坏文件保留并报告。

后续合并窗口时引入 `sourceChunkIDs + 输入时间映射 + 输出范围`，用新的窗口提交逻辑替换范围结果，并对跨 chunk 句子明确定义归属；不绕过原有 `commit` 的一致性验证。

### 5.6 时间、来源与说话人

始终保留 `source=application|microphone`；远端应用轨内可能有多位参会人，speaker ID 应是独立字段。MVP 仍按采集来源显示两路。

时间计算以保存音频的真实偏移为准：`会议时间 = 输入窗口映射(服务端局部时间)`。无裁剪时就是加 offset；若 VAD 移除了间隙，就必须分段映射，不能继续只加一个 offset。

短文件各自的 `speaker_0` 不代表同一个人，跨轨、跨任务也不稳定。如需整场说话人一致性，优先会后用长文件分离能力，或设计独立的跨窗聚类；不要仅按相同编号合并。Ling 专用接口目前没有这项结果。

## 6. 可靠性、设置与数据边界

队列默认每轨串行、两轨总并发可从 2 开始，另设 provider 的 QPS 限制；全局任务调度避免历史补转占满录制中任务。每个作业可取消、可恢复，磁盘音频是恢复来源，网络变慢不能导致无界内存缓存。

| 情况 | 处理 |
| --- | --- |
| 401/403、余额/配额不足 | 停止该云任务，提示修正配置或充值；本地录音字幕继续 |
| 文件或参数错误 | 不盲目重试，显示具体失败片段与原因 |
| 429、临时 5xx | 遵循 Retry-After，指数退避加抖动，限制次数及总等待时长 |
| 提交后断网、结果未知 | 标记 outcome unknown；有 task ID 先查状态；同步接口重新调用可能重复计费，不能承诺 exactly-once |
| 暂停/退出 | 保存任务状态与已确认结果；恢复时只处理同 run 未完成作业 |
| 云端失败 | 显示失败/待续转，仍可查看 Apple 稿；不静默切到另一家上传 |

本地幂等键建议由录音、source、输入区间/校验值、provider/model/config 组成。它可以防止客户端重复落盘，**不能保证服务商不重复收费**。初始超时可从请求总时限约 90 秒开始，再以实测调整；不要直接继承 Apple 60 秒超时用于所有网络任务。

设置首版提供：模式、provider、模型、地域/Workspace ID、Keychain 凭据、混合语言、热词、连接测试，以及单次/每月预算。连接测试可分为本地配置检查和明确提示的小音频真实调用；不假设存在统一“余额查询”接口。

用户首次启用时说明发送的音轨、目标服务/地域、按量计费，并可选“本次会议使用”。Key、Authorization、签名 URL 和 Base64 音频不进日志或字幕文件；常规诊断只记录请求 ID、模型、时长、用量与错误码。会议内容与原始响应是否留档应可配置。

BYOK 个人版可直连云端；如果未来产品统一代付，改由服务端保存平台凭据，增加用户认证、配额与用量结算，不能把公司 Key 内置到可分发 app。临时 OSS 文件设置最小访问权限和清理策略；云服务端的数据留存与训练条款以具体服务协议验证，不能把“本地文件删除”说成“供应商已删除”。

## 7. 如何证明高精度且划算

建议先做 60–120 分钟固定样本，使用自行录制或取得授权的素材；涵盖：中文技术会议、中英夹杂/缩写、人名产品名与数字、口音/噪声、应用与麦克风抢话、长静音、分段切词、短尾段和扬声器回声。

先评测 Apple、Ling、Qwen-Audio 3.1、Fun-ASR-Flash，Paraformer 作为会后成本基线。腾讯/海外选项在前几家不能满足需求时再加入，控制实际试验费用。

| 维度 | 方法 |
| --- | --- |
| 中文文本准确率 | 人工校准参考稿，报告统一归一化后的 CER；保留重复、否定词和自我修正的规则一致 |
| 英文与关键字段 | 英文 WER；另报人名、技术词、金额、日期、数字准确率 |
| 幻觉与漏识别 | 统计静音误出字、整句漏识别、重复字幕、把前文 prompt 复制出来 |
| 回听时间 | 人工标注部分句界，统计定位误差；Ling 片段定位单列，不能与词级时间戳混排 |
| 延迟 | 区分采集等待、排队、上传和识别；记录 P50/P95 与会后清空积压时间 |
| 费用 | 对相同完整样本记录输入秒数、Token、重试和实账，换算人民币/音频小时与人民币/会议小时 |
| 恢复能力 | 模拟断网、429、提交后超时、退出重启；检查不丢音频、不覆盖稿、不重复提交已确认作业 |

建议首轮产品门槛（待样本结果校准，不是供应商承诺）：

- 云端在主要中文会议集的 CER 相对 Apple 降低至少约 20%，且关键数字/否定词不明显退化；分场景报告，不能只看总平均。
- 录制中云端若启用，10 秒片段关闭后的 P95 返回目标 ≤10 秒，明确它仍是约 10–20 秒级体验；达不到时保留会后精校路线。
- 提供句级回听的引擎，抽样句界 P95 误差目标 ≤1 秒；Ling 若只有片段级定位，单独告知并接受降级，不宣称达标。
- 大陆默认云端全双轨预算目标 ≤¥2/会议小时。Qwen-Audio 3.1 以实账判断，不能用假设 Token 数证明达标。
- 连续 1–2 小时双轨测试及重启续转通过；历史 v1 文档、尾段、采集间隙、不同采样率都能正确展示。

若两家质量接近，再以包含网络失败和人工修订成本的总成本选型；若 Ling 质量有优势且实际价格低，但缺少时间戳，则可保留为“文字精校”模式，而将完整时间定位交给其他引擎。

## 8. 实施顺序与涉及文件

| 阶段 | 交付物 | 完成条件 |
| --- | --- | --- |
| P0：选型验证 | 固定样本、模型/地域/价格记录、CER/延迟/费用报告；确认 Ling ASR 计费和权限 | 能基于真实样本做默认模型决定；无需先改采集链路 |
| P1：会后云端精校 MVP | provider 能力接口、Keychain、独立 run、阿里云短文件适配器、可选 Ling 实验适配器、稿件切换与失败续转 | Apple 原稿可保留；时间定位真实；历史兼容；预算和用量可见 |
| P2：录制中精校与成本优化 | 云作业增量调度、可配置窗口、经验证的 VAD、选择单轨、必要时 Paraformer/Filetrans | 长会议不过量积压；间隙和跨窗映射正确 |
| P3：有需求再扩展 | 真正实时 WebSocket、整场说话人、第二云供应商、统一代付后端 | 用明确体验目标与用户量证明收益 |

未来代码变更点（本文只规划）：

- `Sources/MeetingCore/TranscriptionCoordinator.swift`：run 和 provider 调度、网络任务恢复，避免本地 completed 标记影响云端。
- `Sources/MeetingCore/Transcript.swift`：版本/来源/时间精度元数据与旧格式兼容；或新增独立 run 文件类型。
- `Sources/MeetingCore/` 新模块：provider、上传副本准备、凭据存储、HTTP、云作业清单和用量记录。
- `Sources/MeetingIntelligence/AppModel.swift`：新会议配置快照、主动云端精校和重转入口。
- `Sources/MeetingIntelligence/SettingsPage.swift`：云 provider/模型/地域/Key/预算设置。
- `Sources/MeetingIntelligence/TranscriptPanel.swift`：本地与云稿切换、云状态、粗粒度定位提示。
- 后续实现时在 `Tests/MeetingCoreTests/TranscriptionTests.swift` 等处验证请求映射、响应归一化、多 run 幂等、旧数据、间隙映射和异常恢复；使用录制的脱敏响应，不让常规测试访问收费 API。

首版不需要改 `RealtimeAudio.c` 或重新设计 Core Audio 采集。若以后新增低延迟音频流出口，应独立评审，保持网络与实时回调隔离。

**当前可执行决策：用 Qwen-Audio 3.1 作为第一优先试验，Fun-ASR-Flash 作固定价对照，Ling 专项验证价格与无时间戳体验；通过同集测试后再确定默认 provider。首版保持 Apple + 一个正式云 provider，并预留 Ling 实验入口，不一次性实现所有厂商。**

## 9. 官方资料与查证范围

全部链接于 2026-11-15 查阅。下列为官方页面；搜索结果仅用于发现链接，没有把第三方测评或搜索摘要当成实际精度结论。

- [S1：阿里云百炼模型价格](https://help.aliyun.com/zh/model-studio/model-pricing)：Qwen-Audio 3.1 Token 单价、旧版 Qwen3/Fun-ASR/Paraformer 秒价、地域与试用权益。
- [S2：非实时语音识别](https://help.aliyun.com/zh/model-studio/non-realtime-speech-recognition-user-guide)：模型输入限制、时间戳、说话人分离、异步结果流程。
- [S3：语音识别概述](https://help.aliyun.com/zh/model-studio/asr-model)：当前 Qwen-Audio 3.1 选型与语种能力。
- [S4：蚂蚁百灵创建语音识别](https://developer.ant-ling.com/zh-CN/docs/api-reference/audio/asr/)：Ming ASR 模型、30 秒/10 MB、请求与不支持参数。
- [S5：蚂蚁百灵 FAQ](https://developer.ant-ling.com/zh-CN/docs/faq/)：品牌区别、2 QPS、仍展示旧免费额度，需与升级说明交叉核对。
- [S6：蚂蚁百灵调用限制](https://developer.ant-ling.com/zh-CN/docs/api-reference/api-guide/queries-per-second/)：公共限流与同步超时。
- [S7：蚂蚁百灵定价](https://developer.ant-ling.com/zh-CN/docs/models/price/)：未列 Ming 专用 ASR 单价，不能用 Ling 文本价格代算。
- [S8：腾讯云语音识别计费概述](https://cloud.tencent.com/document/product/1093/35686)：大模型 2.0 文件/实时价格，传统/大模型、跨境与免费权益区别。
- [S9：百灵计量计费服务升级说明](https://developer.ant-ling.com/zh-CN/docs/getting-started/changelog/billing-upgrade/)：新旧钱包、月度券、一次性券与原日额度变化。
- [S10：Qwen-Audio-ASR HTTP API](https://help.aliyun.com/zh/model-studio/qwen-audio-asr-http-api)：专属域名、Base64、上下文、热词、最终时间戳与 Token 用量结构。
- [S11：豆包语音录音文件识别极速版](https://docs.volcengine.com/docs/6561/2608628?lang=zh)：同步文件接口和限制；本次未取得可比价格。
- [S12：AssemblyAI Pricing](https://www.assemblyai.com/pricing)：文件型号与各项附加功能价。
- [S13：Deepgram Pricing](https://deepgram.com/pricing)：Streaming PAYG 与附加项，不混用历史划线价。
- [S14：OpenAI API Pricing](https://developers.openai.com/api/docs/pricing)：本次核实的 `gpt-live-transcribe` 实时价格。
- [S15：阿里云语音识别最佳实践](https://help.aliyun.com/zh/model-studio/speech-recognition-best-practices)：输入副本、异步作业、限流、结果持久化与不确定提交重试。
- [S16：Fun-ASR-Flash HTTP API](https://help.aliyun.com/zh/model-studio/fun-asr-flash-recorded-speech-recognition-http-api)：短文件 Base64/URL 与上下文方式，区别于异步 Fun-ASR。
- [S17：阿里云实时语音识别](https://help.aliyun.com/zh/model-studio/real-time-speech-recognition-user-guide)：实时流与短文件 SSE 的区别。

尚未取得的证据：Ling ASR 实际单价及账单、各家同集 CER、真实大陆 P95 延迟、账号配额/商用条款和音频留存政策。以上事项列为 P0 验证内容，没有用未经验证的数字补齐。
