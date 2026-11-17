根据这三个选择，我建议把第一版定义为：

MeetingAI：一款面向 macOS 26+ 的应用级音频捕获与智能会议转写工具。

它有一个很明确的产品原则：
- 用户选择一个会议应用，例如 Zoom、飞书、腾讯会议、Chrome。
- MeetingAI 捕获该应用的系统输出音频，同时独立捕获麦克风。
- Apple SpeechAnalyzer 负责实时转写。
- 云端 ASR 在后台对原始录音进行高精度转写。
- 云端结果回来后，修正本地 Transcript，而不是重新生成一份独立记录。
我建议第一版先不做 LLM 摘要、声纹识别、会议知识库，也不做自己的服务端。先把音频采集和转写闭环做扎实。

下面我会按照可以直接在 Xcode 里落地的方式设计。
1. 技术架构
首先确定技术选型。
模块	技术	职责
App UI	SwiftUI	菜单栏、设置、会议详情
系统音频	ScreenCaptureKit	捕获指定应用输出
麦克风	AVAudioEngine	捕获本地麦克风
音频处理	AVFoundation / CoreMedia	重采样、分帧、时间戳
本地 ASR	SpeechAnalyzer	实时转写
云端 ASR	URLSession + WebSocket/HTTP	后台高精度转写
本地数据库	SQLite	会议、转写、任务状态
音频存储	AVAudioFile	原始音频持久化
并发	Swift Concurrency	异步任务协调

这里有一个重要选择：第一版使用 AVAudioFile 写入音频文件，不要自己实现 WAV 编码器。

另外，指定应用捕获需要特别注意 ScreenCaptureKit 的行为：它捕获的是应用输出的音频，而不是直接获得应用内部的原始音频轨道。应用可能输出多个音频通道，最终仍然需要在自己的 Pipeline 中处理格式和声道。
2. 核心架构图
MeetingCoordinator

会议生命周期与任务编排

SystemCapture

ScreenCaptureKit

Target Application


MicrophoneCapture

AVAudioEngine

Input Device




Audio Pipeline

时间轴统一、PCM 转换、分段、音频落盘

Local ASR

SpeechAnalyzer

实时字幕


Cloud ASR

后台任务

高精度校正




TranscriptRepository

片段合并、版本修订、持久化


SwiftUI

实时字幕 / 录音控制 / 历史会议


我建议整个系统划分成五个独立的模块：
1. Capture：只管采集。
2. AudioPipeline：只管音频数据处理和持久化。
3. Transcription：只管转写。
4. Persistence：只管数据存储。
5. Application：负责生命周期和业务协调。
不要让 ScreenCaptureKit 直接依赖 SpeechAnalyzer，也不要让 UI 直接调用 ASR。
3. 一个关键技术调整：指定应用音频，优先研究 Core Audio Process Tap
这里我想修正前面 ScreenCaptureKit 的选型。

你的需求不是录制某个应用的窗口，而是：
只捕获指定进程输出的音频，不捕获其他应用的声音，也不需要屏幕画面。

Apple 实际上提供了一个更贴近这个需求的 API：Core Audio Process Tap。

首选方案
 AudioHardwareCreateProcessTap
Apple 官方有一个专门的示例工程：Capturing system audio with Core Audio taps。它可以捕获指定进程或进程组输出的音频，并将 Tap 作为输入接入 HAL Aggregate Device。

Apple Developer Documentation+1

两种方案的区别：
对比	Core Audio Tap	ScreenCaptureKit
指定进程音频	原生支持	通过内容过滤器
纯音频采集	适合	可以
需要屏幕内容	不需要	不需要注册视频输出
进程级音频	直接支持	需要验证过滤器行为
音频输入方式	Aggregate Device / Audio Unit	CMSampleBuffer

我建议：
- Core Audio Process Tap：第一选择。
- ScreenCaptureKit：保留为后续替代采集实现，或者用于应用/窗口选择交互。
3.1 Core Audio Tap 的工作原理
Target Application

Zoom / Chrome / Feishu


CATapDescription

指定进程 PID、捕获方式、声道配置


AudioHardwareCreateProcessTap

创建 AudioObjectID


HAL Aggregate Device

将 Process Tap 注册为音频输入


Audio Input Callback

读取目标进程 PCM 数据


具体步骤：
1. 获取目标应用的 PID。
2. 构造 CATapDescription，指定需要捕获的进程。
3. 调用 AudioHardwareCreateProcessTap 创建 Tap。
4. 创建 HAL Aggregate Device，将 Tap 加入其中。
5. 通过 Audio Unit 或 Core Audio IOProc 读取音频。
6. 停止时销毁 Aggregate Device 和 Tap。
Apple 官方文档明确要求配置 NSAudioCaptureUsageDescription，第一次使用包含 Tap 的 Aggregate Device 时，系统会向用户请求系统音频录制权限。

Apple Developer Documentation+1

3.2 如何选择目标应用？
我建议在 UI 中用 NSWorkspace 获取当前运行的应用：
import AppKit

let applications = NSWorkspace.shared.runningApplications

for app in applications {
    guard let name = app.localizedName,
          let bundleId = app.bundleIdentifier else {
        continue
    }

    print(name, bundleId, app.processIdentifier)
}


用户选择应用后，保存：
struct TargetApplication: Codable {
    let bundleIdentifier: String
    let displayName: String
}


注意：不要把 PID 永久保存到数据库，因为应用退出后再次启动，PID 可能变化。

每次开始会议时重新解析 PID。

对于应用多进程架构（例如 Chromium），还要测试目标音频究竟由主进程还是子进程输出。必要时需要捕获进程组，不能假设选择主进程就一定能捕获全部声音。
3.3 一个重要的边界
Core Audio Tap 不等于无条件获取任何应用的声音。

你需要考虑：
- 目标应用退出。
- PID 改变。
- 应用使用多个音频进程。
- 音频输出设备切换。
- 用户撤销系统音频捕获权限。
- Tap 创建或 Aggregate Device 创建失败。
这些都应该体现在 CaptureState 中。

4. Swift 工程结构
建议 Xcode 创建一个 macOS App：
- Product Name：MeetingAI
- Interface：SwiftUI
- Language：Swift
- Minimum Deployment：macOS 26.0
- Architecture：Apple Silicon 优先，同时保留 Universal Binary 的可能性。
项目结构：
MeetingAI/
│
├── App/
│   ├── MeetingAIApp.swift
│   ├── AppDelegate.swift
│   └── AppContainer.swift
│
├── Domain/
│   ├── Meeting.swift
│   ├── AudioSource.swift
│   ├── AudioChunk.swift
│   ├── TranscriptSegment.swift
│   └── MeetingState.swift
│
├── Capture/
│   ├── AudioCaptureProtocol.swift
│   ├── ProcessAudioCapture.swift
│   ├── CoreAudioTap.swift
│   └── MicrophoneCapture.swift
│
├── Audio/
│   ├── AudioPipeline.swift
│   ├── AudioConverter.swift
│   ├── AudioWriter.swift
│   └── AudioClock.swift
│
├── ASR/
│   ├── TranscriptionProtocol.swift
│   ├── AppleSpeechEngine.swift
│   ├── CloudASREngine.swift
│   └── TranscriptMerger.swift
│
├── Storage/
│   ├── Database.swift
│   ├── MeetingRepository.swift
│   └── TranscriptRepository.swift
│
├── Application/
│   ├── MeetingCoordinator.swift
│   └── TranscriptionCoordinator.swift
│
└── Presentation/
    ├── MenuBarView.swift
    ├── MeetingView.swift
    ├── TranscriptView.swift
    └── SettingsView.swift


第一版不要急着使用复杂的依赖注入框架。一个 AppContainer 管理对象创建就够了。
5. Capture 模块：具体 Swift 接口
这里要特别注意：Core Audio 的 Process Tap 底层比较复杂，不能像 AVAudioEngine.installTap 一样简单地创建一个回调就结束。

我建议把底层复杂度全部封装进 ProcessAudioCapture。
5.1 统一采集接口
import Foundation
import AVFoundation

enum AudioSource: String, Codable {
    case system
    case microphone
}

struct CapturedAudio {
    let source: AudioSource
    let timestamp: CMTime
    let sampleBuffer: CMSampleBuffer
}

protocol AudioCapture: AnyObject {
    func start() async throws

    func stop() async throws

    var onAudio: ((CapturedAudio) -> Void)? { get set }
}


实现两个 Adapter：
final class ProcessAudioCapture: AudioCapture {
    var onAudio: ((CapturedAudio) -> Void)?

    func start() async throws {
        // 1. Resolve target application PID
        // 2. Resolve Core Audio process object
        // 3. Create CATapDescription
        // 4. AudioHardwareCreateProcessTap
        // 5. Create HAL Aggregate Device
        // 6. Start Audio Unit / IOProc
    }

    func stop() async throws {
        // Stop IOProc
        // Destroy Aggregate Device
        // Destroy Process Tap
    }
}


final class MicrophoneCapture: AudioCapture {
    var onAudio: ((CapturedAudio) -> Void)?

    private let engine = AVAudioEngine()

    func start() async throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        input.installTap(
            onBus: 0,
            bufferSize: 4096,
            format: format
        ) { [weak self] buffer, time in
            // Convert buffer to an owned audio sample.
            // Forward to Audio Pipeline.
        }

        engine.prepare()
        try engine.start()
    }

    func stop() async throws {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}


这是接口骨架，真正实现时，Core Audio Tap 的输出需要经过 Aggregate Device 的输入端读取；麦克风则可以直接使用 AVAudioEngine。
5.2 Core Audio 实现顺序
建议你直接参考 Apple 的官方 Sample Code，而不是从零猜测 Aggregate Device 的属性配置。

官方示例中涉及的核心 API：
API	作用
CATapDescription	描述要捕获的进程
AudioHardwareCreateProcessTap	创建 Tap
kAudioTapPropertyUID	获取 Tap UID
AudioHardwareCreateAggregateDevice	创建虚拟聚合设备
kAudioAggregateDevicePropertyTapList	将 Tap 加入设备
AudioHardwareDestroyProcessTap	销毁 Tap
AudioHardwareDestroyAggregateDevice	销毁聚合设备

官方实现还演示了 Tap 的 mono/stereo mixdown 和 mute behavior 配置。

Apple Developer

这里有个细节：CATapDescription.processes 使用的是 Core Audio 的进程对象标识，而不是简单地把 NSRunningApplication.processIdentifier（PID）直接塞进去。你需要先将 PID 转换为 Core Audio process object。

我建议第一周不要同时开发所有模块。先独立写一个 CoreAudioTapDemo。

只做三件事：
1. 列出正在运行的应用。
2. 选择一个应用。
3. 捕获它的音频并写成 WAV。
当这三个步骤成功，再将它封装为 ProcessAudioCapture。
6. Audio Pipeline：两路音频的核心处理
这是我建议重点设计的部分。

不要让 Capture 模块负责写文件和 ASR。

应该是：
ProcessAudioCapture ─────┐
                         │
                         ▼
                    AudioPipeline
                         ▲
                         │
MicrophoneCapture ───────┘
                         │
               ┌─────────┴─────────┐
               ▼                   ▼
          AudioWriter          LocalASR
               │                   │
               ▼                   ▼
          Audio Files        Transcript Events


6.1 音频数据结构
建议每个音频片段都带有：
struct AudioChunk {
    let meetingId: UUID
    let source: AudioSource

    let sequence: Int64

    // 相对于 Meeting 开始时的时间
    let startTime: Double
    let duration: Double

    let sampleRate: Double
    let channelCount: Int

    let fileURL: URL?
}


这里不建议直接将 CMSampleBuffer 存在数据库中。

Pipeline 接收 SampleBuffer 后，将它转换成自己管理生命周期的 PCM 数据，再分发给 Writer 和 ASR。
6.2 时间轴
两路音频的时间戳可能来自不同的时钟，因此必须建立统一的会议时间轴。

我建议：
struct AudioClock {
    let meetingStartHostTime: UInt64

    func relativeTime(hostTime: UInt64) -> Double {
        let nanos = AudioConvertHostTimeToNanos(
            hostTime &- meetingStartHostTime
        )

        return Double(nanos) / 1_000_000_000
    }
}


实际工程中还需要检查 host time 的有效性和时钟换算，不能假设两个采集设备的时间戳天然完全一致。
6.3 音频格式
我建议采用两套格式：
用途	格式
原始归档	48kHz PCM，保留原始声道
本地 ASR	SpeechAnalyzer 支持的格式
云端 ASR	Provider 要求的格式

不要在采集阶段强行将所有音频转换成 16kHz。

Apple SpeechAnalyzer 提供 bestAvailableAudioFormat(compatibleWith:)，可以根据 Transcriber 获取合适的分析格式，再通过 AnalyzerInputConverter 转换输入。

Apple Developer Documentation+1

6.4 线程模型
建议采用以下模型：
执行上下文	职责
Core Audio IOProc	获取音频，写入预分配 Ring Buffer
Audio Processing Task	PCM 转换、时间戳映射
Audio Writer Task	写入磁盘
Local ASR Task	实时推送给 SpeechAnalyzer
Cloud Upload Task	后台上传
MainActor	UI 状态更新

特别强调：Core Audio IOProc 是实时音频回调，不要在里面做网络、文件 I/O、锁等待或大量内存分配。可以采用预分配的 Ring Buffer 将音频交给普通消费线程。

7. Local ASR：Apple SpeechAnalyzer 实现
这一层可以相对独立。

Apple Speech Framework 新版采用 Actor + AsyncSequence 的模式，比较适合 Swift Concurrency。

官方流程是：
1. 创建 SpeechTranscriber。
2. 检查语言和模型资源。
3. 下载尚未安装的 Asset。
4. 创建 SpeechAnalyzer。
5. 输入 AnalyzerInput。
6. 消费 Transcriber 的 Results。
7. 结束时调用 finish。
注意，SpeechTranscriber 的可用语言与设备支持情况需要在运行时检查，不能认为所有 macOS 26 设备都一定已经安装了中文模型。

Apple Developer Documentation+1

7.1 定义统一转写事件
enum TranscriptStatus {
    case provisional
    case final
}

struct TranscriptEvent {
    let meetingId: UUID
    let source: AudioSource

    let startTime: Double
    let endTime: Double

    let text: String
    let status: TranscriptStatus
    let engine: String
}


7.2 Local ASR 接口
protocol TranscriptionEngine {
    func start() async throws

    func append(_ buffer: AVAudioPCMBuffer) async throws

    func finish() async throws

    var results: AsyncStream<TranscriptEvent> { get }
}


7.3 AppleSpeechEngine
import Speech
import AVFoundation

actor AppleSpeechEngine {

    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer

    init(locale: Locale) {
        transcriber = SpeechTranscriber(
            locale: locale,
            preset: .transcription
        )

        analyzer = SpeechAnalyzer(
            modules: [transcriber]
        )
    }

    func prepare() async throws {
        guard SpeechTranscriber.isAvailable else {
            throw NSError(
                domain: "MeetingAI",
                code: 1001
            )
        }

        if let request = try await
            AssetInventory.assetInstallationRequest(
                supporting: [transcriber]
            ) {
            try await request.downloadAndInstall()
        }
    }
}


这是初始化部分的核心代码。输入流、结果消费任务和结束流程还需要单独实现。

我建议 MVP 先使用 AsyncStream 作为音频输入缓冲：
let (inputStream, inputContinuation) =
    AsyncStream<AnalyzerInput>.makeStream()


采集模块将转换好的 AnalyzerInput 投递给 inputContinuation，而 Analyzer 消费 inputStream。

需要注意：
- 使用 AnalyzerInputConverter 进行格式转换。
- 为输入设置正确的音频时间信息。
- 不要无限制缓存音频。
- 停止时结束 input continuation。
- 调用 Analyzer 的 finish 流程。
- 独立消费 transcriber.results。
一个值得提前测试的问题： 系统音频和麦克风分别创建一个 SpeechAnalyzer，意味着同时运行两个分析任务。Apple 会根据设备资源限制并发分析数量，可能返回 insufficientResources。建议在目标 M 系列设备上测试，不要直接启用 ignoresResourceLimits 来绕过限制。

Apple Developer Documentation

我的建议是 MVP 先尝试双 Analyzer，如果设备资源不允许，则采用降级策略，而不是让整个录音失败。
8. Cloud ASR：后台校正，而不是实时双写
你的模式已经确定为：

Local First
 本地实时转写 + 云端后台校正。
因此云端 ASR 应该设计成独立的异步任务系统。
8.1 定义云端 Provider
struct CloudTranscriptionRequest {
    let meetingId: UUID
    let audioFiles: [URL]
    let language: String
}

struct CloudTranscriptionResult {
    let meetingId: UUID
    let segments: [TranscriptEvent]
}

protocol CloudASRProvider {
    func transcribe(
        _ request: CloudTranscriptionRequest
    ) async throws -> CloudTranscriptionResult
}


第一版先使用 HTTP 文件上传，不要急着做 WebSocket。

推荐流程：
Meeting Stopped
      |
      v
Audio Files Persisted
      |
      v
Create ASR Job
      |
      v
Upload System Audio ────┐
                        |
Upload Microphone ──────┤
                        |
                        v
                   Cloud ASR
                        |
                        v
                 Parse Transcript
                        |
                        v
                 TranscriptMerger
                        |
                        v
                Update SQLite


这里我建议一个会议对应一个 CloudASRJob，而不是每个音频片段都创建独立任务。
enum ASRJobStatus: String, Codable {
    case pending
    case uploading
    case processing
    case completed
    case failed
}

struct ASRJob {
    let id: UUID
    let meetingId: UUID
    var status: ASRJobStatus
    var retryCount: Int
    var errorMessage: String?
}


云端上传建议：
- 支持断点续传，或者按音频文件独立上传。
- 保存服务端任务 ID。
- 支持重试。
- 使用幂等请求 ID。
- 记录模型版本和转写时间。
- 上传失败不影响本地录音及 Transcript。
如果未来需要长会议，可以按 5～10 分钟切片上传，但每个切片都要带原始会议时间偏移，并且在切片边界保留少量上下文，防止句子被截断。
8.2 TranscriptMerger
这部分我建议不要过度复杂化。

定义三种数据：
数据	含义
Local Transcript	实时结果
Cloud Transcript	高精度结果
Final Transcript	最终展示结果

合并规则：
Local Partial
      |
      v
Local Final
      |
      v
Display as Provisional
      |
      v
Cloud Final
      |
      v
Match by Time + Source
      |
      v
Update / Insert / Delete
      |
      v
Final Transcript


这里需要特别注意：本地和云端 ASR 的分段方式可能完全不同。

例如：

本地：
10.0 - 11.0 我们准备使用
11.0 - 12.0 Redis 做缓存


云端：
10.0 - 12.0 我们准备使用 Redis 做缓存


所以不能简单使用：
segments[local.id] = cloudSegment


我建议第一版采用：
1. 按 AudioSource 隔离匹配。
2. 按时间区间重叠度寻找候选。
3. 使用文本相似度辅助匹配。
4. 云端结果覆盖相应时间区间的本地结果。
5. 没有匹配到的云端结果直接插入。
6. 对于边界不确定的片段，保留本地版本并标记需要复核。
另外，云端结果不要覆盖原始 ASR 记录。建议保留 revision，这样以后可以做编辑撤销和 ASR 质量评估。

9. Persistence：本地数据库设计
第一版使用 SQLite 就足够。

建议四张表：

meeting
字段	类型	说明
id	TEXT	UUID
title	TEXT	会议名称
started_at	REAL	开始时间
ended_at	REAL	结束时间
status	TEXT	生命周期状态
target_bundle_id	TEXT	目标应用

audio_asset
字段	类型	说明
id	TEXT	UUID
meeting_id	TEXT	会议 ID
source	TEXT	system / microphone
file_path	TEXT	文件路径
duration	REAL	时长
sample_rate	INTEGER	采样率
channels	INTEGER	声道

transcript_segment
字段	类型	说明
id	TEXT	UUID
meeting_id	TEXT	会议 ID
source	TEXT	音频来源
start_time	REAL	开始时间
end_time	REAL	结束时间
text	TEXT	转写内容
engine	TEXT	ASR 来源
revision	INTEGER	版本号
status	TEXT	provisional / final

asr_job
字段	类型	说明
id	TEXT	UUID
meeting_id	TEXT	会议 ID
status	TEXT	任务状态
retry_count	INTEGER	重试次数
remote_job_id	TEXT	云端任务 ID

我还建议在 transcript_segment 上建立：
CREATE INDEX idx_transcript_meeting_time
ON transcript_segment(meeting_id, start_time);

CREATE INDEX idx_transcript_source_time
ON transcript_segment(meeting_id, source, start_time);


音频文件和数据库之间要采用明确的提交顺序：
1. 音频先写入临时文件。
2. 完成后 flush 并关闭文件。
3. 原子 rename 到正式路径。
4. 提交数据库中的 audio_asset 记录。
这样 App 意外退出时，不容易留下数据库指向一个并不存在的音频文件。

10. MeetingCoordinator：整个系统的入口
这是我认为最值得认真设计的业务类。

它不直接操作 Core Audio，也不直接操作 SpeechAnalyzer。

只负责协调各个组件。
@MainActor
final class MeetingCoordinator: ObservableObject {

    @Published private(set) var isRecording = false
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var transcript: [TranscriptEvent] = []

    private let systemCapture: ProcessAudioCapture
    private let microphoneCapture: MicrophoneCapture

    private let audioPipeline: AudioPipeline
    private let transcriptionCoordinator: TranscriptionCoordinator

    init(
        systemCapture: ProcessAudioCapture,
        microphoneCapture: MicrophoneCapture,
        audioPipeline: AudioPipeline,
        transcriptionCoordinator: TranscriptionCoordinator
    ) {
        self.systemCapture = systemCapture
        self.microphoneCapture = microphoneCapture
        self.audioPipeline = audioPipeline
        self.transcriptionCoordinator = transcriptionCoordinator
    }

    func startMeeting() async throws {
        // 1. Create meeting
        // 2. Prepare local ASR
        // 3. Prepare Audio Writer
        // 4. Start microphone capture
        // 5. Start process capture
        // 6. Start transcript consumers

        try await audioPipeline.prepare()

        try await microphoneCapture.start()
        try await systemCapture.start()

        isRecording = true
    }

    func stopMeeting() async throws {
        // 1. Stop capture
        // 2. Flush audio buffers
        // 3. Finish local ASR
        // 4. Finalize audio files
        // 5. Create cloud ASR job

        try await systemCapture.stop()
        try await microphoneCapture.stop()

        try await audioPipeline.finish()

        isRecording = false
    }
}


这是协调逻辑的示意骨架，正式实现时要加上启动失败的反向清理，以及停止过程的幂等性。

例如，如果 SystemCapture 启动失败，已经启动的 MicrophoneCapture 必须被停止，而不是让用户看到一个实际没有完整录音的 Recording 状态。
10.1 状态机
建议：
enum MeetingState {
    case idle
    case preparing
    case recording
    case stopping
    case transcribing
    case completed
    case failed(Error)
}


后面可以进一步增加 paused。

不要让 isRecording 成为唯一状态字段，因为它无法表达音频已经停止、云端仍然转写的情况。

11. UI：第一版只需要一个 Menu Bar App
我建议不做复杂的桌面窗口，先让它像一个轻量系统工具。
MeetingAI

Recording

TARGET APPLICATION
Zoom

Connected

MICROPHONE
MacBook Pro Microphone

Active


MEETING DURATION
00:32:18

实时转写

远端音频 · 10:32:15

我们现在的 Agent 配置管理，应该考虑声明式的方式。

麦克风 · 10:32:22

对，我倾向于使用 etcd 存储配置。

暂停

结束录音



本地转写
运行中

云端校正
等待会议结束


设置页面只需要：
- 目标应用选择。
- 麦克风选择。
- 转写语言。
- 本地模型资源状态。
- 云端 ASR API 配置。
- 音频保存位置。
- 云端上传确认选项。

12. 真正的 MVP 开发计划
我建议不要一次性实现上面所有模块。

按照技术风险排序：
MVP 迭代计划
可执行

1. 第 1 阶段：Core Audio Tap Demo
   - 应用列表
   - 选择目标 PID
   - 创建 Process Tap
   - Aggregate Device
   - 保存 WAV
   验收：只录制指定应用，不录制其他应用。
2. 第 2 阶段：双路采集
   - 接入 AVAudioEngine
   - 两路独立音频文件
   - 时间戳对齐
   - 录音生命周期
   验收：播放会议音频的同时讲话，能够获得两条独立音轨。
3. 第 3 阶段：Apple Speech
   - 下载中文 Speech Asset
   - 两路实时转写
   - 实时字幕 UI
   - 结束时 flush
   验收：持续录制 30 分钟，Transcript 完整。
4. 第 4 阶段：Cloud ASR
   - 文件上传
   - 任务管理
   - 云端结果解析
   - Transcript 合并
   验收：云端结果能够修正本地文本。
5. 第 5 阶段：产品化
   - Menu Bar
   - 历史会议
   - 错误恢复
   - 隐私控制
   验收：可以日常使用。

13. 几个容易踩坑的地方
最后整理一下，我认为开发过程中最需要验证的五个问题。
风险	验证方式
Chromium 多进程	Zoom/Chrome 分别测试主进程与子进程
双路 ASR 资源竞争	测试两个 SpeechAnalyzer 并发
音频时钟偏移	连续录制 30 分钟检查两轨偏移
App 异常退出	强制结束 App，检查音频文件恢复
云端转写失败	断网、超时、重复上传测试

还有两个产品细节：
- macOS 26 的 Core Audio Tap 官方示例值得直接作为底层实现参考，避免自己重新发明 Aggregate Device 管理。

  Apple Developer
- SpeechTranscriber 支持的语言和已安装语言是两个概念。第一次使用中文时，应该先检查资源并处理下载过程。

  Apple Developer Documentation+1
14. 我建议现在就开始写的三个文件
不要先搭完整工程。第一步先创建：
MeetingAI/
├── TargetApplication.swift
├── CoreAudioTap.swift
└── WAVWriter.swift


第一个负责应用发现和选择，第二个负责进程级音频捕获，第三个负责验证音频是否正确写入。

这三个文件跑通，就解决了整个产品最大的技术不确定性。

我建议我们先攻克 Core Audio Tap，而不是先写 SwiftUI。 因为如果指定应用的音频捕获不稳定，后面的 ASR、云端校正和 UI 都没有意义。

官方资料：
1. Apple：Capturing system audio with Core Audio taps（包含完整 Sample Code）
2. AudioHardwareCreateProcessTap
3. SpeechAnalyzer
4. SpeechTranscriber
如果你愿意，我可以下一步直接给你实现一套可在 Xcode 26 中运行的 Core Audio Tap MVP，包括应用枚举、PID 转换、Process Tap、Aggregate Device、音频回调和 WAV 写入。
继续实现 Core Audio Tap MVP
