import { useEffect, useMemo, useRef, useState } from "react";

type IconName =
  | "archive"
  | "back"
  | "check"
  | "chevron"
  | "clock"
  | "copy"
  | "dots"
  | "download"
  | "headphones"
  | "mic"
  | "pause"
  | "play"
  | "plus"
  | "settings"
  | "skipBack"
  | "skipForward"
  | "sparkles"
  | "stop";

const paths: Record<IconName, React.ReactNode> = {
  archive: (
    <>
      <rect x="3" y="5" width="18" height="16" rx="2" />
      <path d="M8 3h8l2 2H6l2-2ZM9 11h6" />
    </>
  ),
  back: <path d="m15 18-6-6 6-6" />,
  check: <path d="m5 12 4 4L19 6" />,
  chevron: <path d="m9 18 6-6-6-6" />,
  clock: (
    <>
      <circle cx="12" cy="12" r="9" />
      <path d="M12 7v5l3 2" />
    </>
  ),
  copy: (
    <>
      <rect x="8" y="8" width="12" height="12" rx="2" />
      <path d="M16 8V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h2" />
    </>
  ),
  dots: (
    <>
      <circle cx="5" cy="12" r="1" fill="currentColor" stroke="none" />
      <circle cx="12" cy="12" r="1" fill="currentColor" stroke="none" />
      <circle cx="19" cy="12" r="1" fill="currentColor" stroke="none" />
    </>
  ),
  download: (
    <>
      <path d="M12 3v12m0 0 4-4m-4 4-4-4M5 20h14" />
    </>
  ),
  headphones: (
    <>
      <path d="M4 14v-2a8 8 0 0 1 16 0v2" />
      <path d="M4 14h3v6H5a1 1 0 0 1-1-1v-5Zm16 0h-3v6h2a1 1 0 0 0 1-1v-5Z" />
    </>
  ),
  mic: (
    <>
      <rect x="9" y="3" width="6" height="12" rx="3" />
      <path d="M5 11a7 7 0 0 0 14 0M12 18v3M9 21h6" />
    </>
  ),
  pause: (
    <>
      <path d="M9 7v10M15 7v10" />
    </>
  ),
  play: <path d="m9 7 8 5-8 5V7Z" />,
  plus: <path d="M12 5v14M5 12h14" />,
  settings: (
    <>
      <circle cx="12" cy="12" r="3" />
      <path d="M19.4 15a1.7 1.7 0 0 0 .34 1.88l.06.06-2.83 2.83-.06-.06a1.7 1.7 0 0 0-1.88-.34 1.7 1.7 0 0 0-1.03 1.56V21h-4v-.08A1.7 1.7 0 0 0 8.97 19.4a1.7 1.7 0 0 0-1.88.34l-.06.06-2.83-2.83.06-.06A1.7 1.7 0 0 0 4.6 15a1.7 1.7 0 0 0-1.53-1H3v-4h.08A1.7 1.7 0 0 0 4.6 9a1.7 1.7 0 0 0-.34-1.88L4.2 7.06l2.83-2.83.06.06A1.7 1.7 0 0 0 8.97 4.6 1.7 1.7 0 0 0 10 3.08V3h4v.08a1.7 1.7 0 0 0 1.03 1.53 1.7 1.7 0 0 0 1.88-.34l.06-.06 2.83 2.83-.06.06A1.7 1.7 0 0 0 19.4 9c.12.37.41.7.72.83.27.11.57.17.87.17H21v4h-.08A1.7 1.7 0 0 0 19.4 15Z" />
    </>
  ),
  skipBack: (
    <>
      <path d="M6 6v12M18 7l-8 5 8 5V7Z" />
    </>
  ),
  skipForward: (
    <>
      <path d="M18 6v12M6 7l8 5-8 5V7Z" />
    </>
  ),
  sparkles: (
    <>
      <path d="m12 3 1.2 3.1L16 7.5l-2.8 1.4L12 12l-1.2-3.1L8 7.5l2.8-1.4L12 3Z" />
      <path d="m6 13 .8 2.2L9 16l-2.2.8L6 19l-.8-2.2L3 16l2.2-.8L6 13Zm12-1 .6 1.5 1.4.5-1.4.5L18 16l-.6-1.5L16 14l1.4-.5L18 12Z" />
    </>
  ),
  stop: <rect x="7" y="7" width="10" height="10" rx="2" />,
};

function Icon({ name, size = 18 }: { name: IconName; size?: number }) {
  return (
    <svg
      aria-hidden="true"
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.8"
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      {paths[name]}
    </svg>
  );
}

type TranscriptLine = {
  id: number;
  time: number;
  speaker: string;
  initials: string;
  color: string;
  text: string;
};

const meetingTranscript: TranscriptLine[] = [
  {
    id: 1,
    time: 8,
    speaker: "陈曦",
    initials: "CX",
    color: "coral",
    text: "早上好，我们开始吧。今天主要确认新版本的上线范围，以及发布前还需要解决的问题。",
  },
  {
    id: 2,
    time: 22,
    speaker: "林然",
    initials: "LR",
    color: "violet",
    text: "好的。设计侧的高优先级页面已经全部交付，剩下的是空状态和少量边缘场景。",
  },
  {
    id: 3,
    time: 41,
    speaker: "陈曦",
    initials: "CX",
    color: "coral",
    text: "很棒。开发这边进度怎么样？周四之前可以完成主流程的联调吗？",
  },
  {
    id: 4,
    time: 54,
    speaker: "周行",
    initials: "ZX",
    color: "blue",
    text: "主流程今天下午就能进入测试。通知模块可能还需要一天，我会在明天中午前给出准确时间。",
  },
  {
    id: 5,
    time: 78,
    speaker: "林然",
    initials: "LR",
    color: "violet",
    text: "那我今天把通知模块的交互说明再补充一下，避免开发时有歧义。",
  },
  {
    id: 6,
    time: 94,
    speaker: "陈曦",
    initials: "CX",
    color: "coral",
    text: "可以。我们暂定周五上午灰度发布，周四下班前做最终检查。其他风险请直接发到项目群。",
  },
  {
    id: 7,
    time: 117,
    speaker: "周行",
    initials: "ZX",
    color: "blue",
    text: "没问题，我也会把测试清单同步给大家。",
  },
];

const liveScript: TranscriptLine[] = [
  {
    id: 101,
    time: 2,
    speaker: "我",
    initials: "我",
    color: "blue",
    text: "大家好，我们现在开始今天的会议。",
  },
  {
    id: 102,
    time: 7,
    speaker: "陈曦",
    initials: "CX",
    color: "coral",
    text: "先快速过一下本周的进度，然后确认接下来的负责人。",
  },
  {
    id: 103,
    time: 13,
    speaker: "我",
    initials: "我",
    color: "blue",
    text: "好的，我先分享一下目前收集到的用户反馈。",
  },
  {
    id: 104,
    time: 19,
    speaker: "陈曦",
    initials: "CX",
    color: "coral",
    text: "最集中的是哪一类问题？我们可以先从高频反馈开始。",
  },
];

const meetings = [
  { title: "产品周会", meta: "今天 · 26 分钟", active: true },
  { title: "用户访谈 · 第 12 期", meta: "昨天 · 42 分钟" },
  { title: "设计评审", meta: "6月18日 · 31 分钟" },
  { title: "增长实验复盘", meta: "6月17日 · 48 分钟" },
];

const duration = 142;

function formatTime(seconds: number) {
  const safe = Math.max(0, Math.floor(seconds));
  return `${Math.floor(safe / 60)}:${String(safe % 60).padStart(2, "0")}`;
}

function Waveform({ progress, live = false }: { progress: number; live?: boolean }) {
  const bars = useMemo(
    () => Array.from({ length: 104 }, (_, i) => 7 + ((i * 17 + i * i * 3) % 29)),
    [],
  );
  return (
    <div className={`waveform ${live ? "waveform-live" : ""}`} aria-label="录音波形">
      {bars.map((height, index) => (
        <span
          key={index}
          className={index / bars.length <= progress ? "played" : ""}
          style={{ height: `${height}px`, animationDelay: `${(index % 14) * -80}ms` }}
        />
      ))}
    </div>
  );
}

export default function App() {
  const [mode, setMode] = useState<"review" | "recording">("review");
  const [playing, setPlaying] = useState(false);
  const [currentTime, setCurrentTime] = useState(54);
  const [recordedSeconds, setRecordedSeconds] = useState(0);
  const [liveLines, setLiveLines] = useState<TranscriptLine[]>([]);
  const [copied, setCopied] = useState(false);
  const transcriptRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!playing || mode !== "review") return;
    const timer = window.setInterval(() => {
      setCurrentTime((value) => {
        if (value >= duration) {
          setPlaying(false);
          return 0;
        }
        return value + 1;
      });
    }, 1000);
    return () => window.clearInterval(timer);
  }, [playing, mode]);

  useEffect(() => {
    if (mode !== "recording") return;
    const timer = window.setInterval(() => {
      setRecordedSeconds((value) => value + 1);
    }, 1000);
    return () => window.clearInterval(timer);
  }, [mode]);

  useEffect(() => {
    if (mode !== "recording") return;
    const visible = liveScript.filter((line) => line.time <= recordedSeconds);
    setLiveLines(visible);
    if (visible.length)
      transcriptRef.current?.scrollTo({
        top: transcriptRef.current.scrollHeight,
        behavior: "smooth",
      });
  }, [recordedSeconds, mode]);

  const startRecording = () => {
    setMode("recording");
    setPlaying(false);
    setRecordedSeconds(0);
    setLiveLines([]);
  };

  const stopRecording = () => {
    setMode("review");
    setCurrentTime(0);
    setPlaying(false);
  };

  const seek = (time: number) => {
    setCurrentTime(time);
    setPlaying(true);
  };

  const copyTranscript = async () => {
    await navigator.clipboard?.writeText(
      meetingTranscript
        .map((line) => `${formatTime(line.time)} ${line.speaker}：${line.text}`)
        .join("\n"),
    );
    setCopied(true);
    window.setTimeout(() => setCopied(false), 1600);
  };

  const activeLine = meetingTranscript.reduce(
    (selected, line) => (line.time <= currentTime ? line : selected),
    meetingTranscript[0],
  );

  return (
    <div className="app-shell">
      <aside className="sidebar">
        <div className="traffic-lights">
          <i />
          <i />
          <i />
        </div>
        <div className="brand">
          <div className="brand-mark">
            <span />
            <span />
            <span />
            <span />
          </div>
          <strong>Meeting Intelligence</strong>
        </div>

        <button
          className={`new-recording ${mode === "recording" ? "is-recording" : ""}`}
          onClick={mode === "recording" ? stopRecording : startRecording}
        >
          <span className="record-icon">
            {mode === "recording" ? <Icon name="stop" size={15} /> : <Icon name="plus" size={17} />}
          </span>
          {mode === "recording" ? "结束录制" : "新录制"}
          {mode === "recording" && (
            <span className="record-time">{formatTime(recordedSeconds)}</span>
          )}
        </button>

        <nav className="primary-nav" aria-label="主导航">
          <button className="nav-item active">
            <Icon name="archive" />
            <span>全部会议</span>
            <span className="nav-count">24</span>
          </button>
        </nav>

        <div className="sidebar-section">
          <div className="section-heading">
            <span>最近会议</span>
            <button aria-label="更多">
              <Icon name="dots" />
            </button>
          </div>
          <div className="meeting-list">
            {meetings.map((meeting, index) => (
              <button
                className={`meeting-item ${meeting.active && mode === "review" ? "active" : ""}`}
                key={meeting.title}
              >
                <span className="meeting-dot" />
                <span>
                  <strong>{meeting.title}</strong>
                  <small>{meeting.meta}</small>
                </span>
                {index === 0 && mode === "review" && <Icon name="chevron" size={14} />}
              </button>
            ))}
          </div>
        </div>

        <div className="sidebar-footer">
          <button className="nav-item">
            <Icon name="settings" />
            <span>设置</span>
          </button>
        </div>
      </aside>

      <main className="workspace">
        {mode === "recording" ? (
          <>
            <header className="topbar recording-topbar">
              <div>
                <div className="eyebrow">
                  <span className="live-dot" /> 正在录制
                </div>
                <h1>未命名会议</h1>
              </div>
              <button className="stop-button" onClick={stopRecording}>
                <Icon name="stop" size={16} />
                结束录制
              </button>
            </header>
            <section className="live-stage">
              <div className="recording-clock">
                <div className="pulse-ring">
                  <Icon name="mic" size={24} />
                </div>
                <strong>{formatTime(recordedSeconds)}</strong>
                <span>录音与实时转写进行中</span>
              </div>
              <Waveform progress={1} live />
            </section>
            <section className="transcript-panel live-transcript">
              <div className="panel-heading">
                <div>
                  <h2>实时转写</h2>
                  <span className="language-badge">普通话</span>
                </div>
                <span className="status-saving">
                  <i /> 自动保存中
                </span>
              </div>
              <div className="transcript-scroll" ref={transcriptRef}>
                {liveLines.length === 0 && (
                  <div className="listening-state">
                    <span className="listening-bars">
                      <i />
                      <i />
                      <i />
                    </span>
                    <p>正在聆听，开始说话即可生成文字…</p>
                  </div>
                )}
                {liveLines.map((line, index) => (
                  <TranscriptItem
                    key={line.id}
                    line={line}
                    active={index === liveLines.length - 1}
                    live
                  />
                ))}
                {liveLines.length > 0 && (
                  <div className="typing-line">
                    <span />
                    <span />
                    <span />
                  </div>
                )}
              </div>
            </section>
          </>
        ) : (
          <>
            <header className="topbar">
              <button className="icon-button back-button" aria-label="返回">
                <Icon name="back" />
              </button>
              <div className="meeting-title">
                <div className="eyebrow">今天，10:02</div>
                <h1>产品周会</h1>
              </div>
              <div className="top-actions">
                <button className="secondary-button">
                  <Icon name="download" size={16} />
                  导出
                </button>
                <button className="icon-button" aria-label="更多操作">
                  <Icon name="dots" />
                </button>
              </div>
            </header>

            <section className="summary-strip">
              <div className="summary-icon">
                <Icon name="sparkles" size={18} />
              </div>
              <div>
                <strong>会议摘要</strong>
                <p>确认周五进行灰度发布；设计补充通知模块说明，开发明日同步准确排期。</p>
              </div>
              <button>
                查看完整摘要 <Icon name="chevron" size={14} />
              </button>
            </section>

            <section className="player-card">
              <div className="player-head">
                <div className="recording-label">
                  <span className="album-art">
                    <Icon name="headphones" />
                  </span>
                  <span>
                    <strong>会议录音</strong>
                    <small>26 分钟 · 3 位发言人</small>
                  </span>
                </div>
              </div>
              <div
                className="wave-wrap"
                onClick={(event) => {
                  const rect = event.currentTarget.getBoundingClientRect();
                  setCurrentTime(Math.round(((event.clientX - rect.left) / rect.width) * duration));
                }}
              >
                <Waveform progress={currentTime / duration} />
                <div className="playhead" style={{ left: `${(currentTime / duration) * 100}%` }} />
              </div>
              <div className="player-controls">
                <span className="timecode">{formatTime(currentTime)}</span>
                <div className="play-buttons">
                  <button
                    aria-label="后退 10 秒"
                    onClick={() => setCurrentTime((time) => Math.max(0, time - 10))}
                  >
                    <Icon name="skipBack" />
                  </button>
                  <button
                    className="play-button"
                    aria-label={playing ? "暂停" : "播放"}
                    onClick={() => setPlaying(!playing)}
                  >
                    <Icon name={playing ? "pause" : "play"} size={21} />
                  </button>
                  <button
                    aria-label="前进 10 秒"
                    onClick={() => setCurrentTime((time) => Math.min(duration, time + 10))}
                  >
                    <Icon name="skipForward" />
                  </button>
                </div>
                <span className="timecode total">-{formatTime(duration - currentTime)}</span>
              </div>
            </section>

            <section className="transcript-panel">
              <div className="panel-heading">
                <div className="tab-row">
                  <button className="active">转写</button>
                  <button>笔记</button>
                </div>
                <div className="transcript-actions">
                  <button className="copy-button" onClick={copyTranscript}>
                    <Icon name={copied ? "check" : "copy"} size={16} />
                    {copied ? "已复制" : "复制"}
                  </button>
                </div>
              </div>
              <div className="transcript-scroll" ref={transcriptRef}>
                {meetingTranscript.map((line) => (
                  <TranscriptItem
                    key={line.id}
                    line={line}
                    active={line.id === activeLine.id}
                    onSeek={seek}
                  />
                ))}
              </div>
            </section>
          </>
        )}
      </main>
    </div>
  );
}

function TranscriptItem({
  line,
  active,
  live,
  onSeek,
}: {
  line: TranscriptLine;
  active?: boolean;
  live?: boolean;
  onSeek?: (time: number) => void;
}) {
  return (
    <article
      className={`transcript-item ${active ? "active" : ""} ${live ? "live-line" : ""}`}
      onClick={() => onSeek?.(line.time)}
    >
      <span className={`avatar ${line.color}`}>{line.initials}</span>
      <div className="line-content">
        <div className="speaker-row">
          <strong>{line.speaker}</strong>
          <button
            onClick={(event) => {
              event.stopPropagation();
              onSeek?.(line.time);
            }}
          >
            {formatTime(line.time)}
          </button>
        </div>
        <p>{line.text}</p>
      </div>
      {!live && (
        <button className="line-play" aria-label={`从 ${formatTime(line.time)} 播放`}>
          <Icon name="play" size={15} />
        </button>
      )}
    </article>
  );
}
