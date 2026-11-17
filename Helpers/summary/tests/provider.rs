use meeting_summary::provider::*;
use serde_json::{Value, json};
use std::{
    io::{Read, Write},
    net::{TcpListener, TcpStream},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    thread,
    time::Duration,
};

type HTTPReply = (u16, String, Vec<(&'static str, String)>);

#[derive(Clone)]
struct Request {
    path: String,
    headers: String,
    body: Value,
}
struct Server {
    base: String,
    calls: Arc<Mutex<Vec<Request>>>,
    stop: Arc<AtomicBool>,
    worker: Option<thread::JoinHandle<()>>,
}
impl Server {
    fn new(handler: impl Fn(&Request) -> HTTPReply + Send + Sync + 'static) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://{}/custom/v1", listener.local_addr().unwrap());
        let calls = Arc::new(Mutex::new(Vec::new()));
        let stop = Arc::new(AtomicBool::new(false));
        let (worker_calls, worker_stop, handler) = (calls.clone(), stop.clone(), Arc::new(handler));
        let worker = thread::spawn(move || {
            for stream in listener.incoming() {
                if worker_stop.load(Ordering::SeqCst) {
                    break;
                }
                let mut stream = stream.unwrap();
                let calls = worker_calls.clone();
                let handler = handler.clone();
                thread::spawn(move || {
                    stream
                        .set_read_timeout(Some(Duration::from_secs(2)))
                        .unwrap();
                    let mut bytes = Vec::new();
                    let mut block = [0u8; 4096];
                    let header_end = loop {
                        let count = stream.read(&mut block).unwrap();
                        if count == 0 {
                            return;
                        }
                        bytes.extend_from_slice(&block[..count]);
                        if let Some(index) = bytes.windows(4).position(|s| s == b"\r\n\r\n") {
                            break index + 4;
                        }
                    };
                    let headers = String::from_utf8(bytes[..header_end].to_vec()).unwrap();
                    let length: usize = headers
                        .lines()
                        .find_map(|l| {
                            l.to_lowercase()
                                .strip_prefix("content-length:")
                                .map(str::trim)
                                .map(str::to_owned)
                        })
                        .map(|l| l.parse().unwrap())
                        .unwrap_or(0);
                    while bytes.len() < header_end + length {
                        let count = stream.read(&mut block).unwrap();
                        if count == 0 {
                            return;
                        }
                        bytes.extend_from_slice(&block[..count]);
                    }
                    let path = headers
                        .lines()
                        .next()
                        .unwrap()
                        .split_whitespace()
                        .nth(1)
                        .unwrap()
                        .to_owned();
                    let body = serde_json::from_slice(&bytes[header_end..header_end + length])
                        .unwrap_or(Value::Null);
                    let request = Request {
                        path,
                        headers,
                        body,
                    };
                    calls.lock().unwrap().push(request.clone());
                    let (status, body, extra) = handler(&request);
                    let content_type = if extra
                        .iter()
                        .any(|(key, _)| key.eq_ignore_ascii_case("content-type"))
                    {
                        ""
                    } else {
                        "Content-Type: application/json\r\n"
                    };
                    let extra: String = extra
                        .into_iter()
                        .map(|(key, value)| format!("{key}: {value}\r\n"))
                        .collect();
                    let response = format!(
                        "HTTP/1.1 {status} Test\r\n{content_type}Content-Length: {}\r\nConnection: close\r\n{extra}\r\n{body}",
                        body.len()
                    );
                    let _ = stream.write_all(response.as_bytes());
                });
            }
        });
        Self {
            base,
            calls,
            stop,
            worker: Some(worker),
        }
    }
}
impl Drop for Server {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        let address = self
            .base
            .trim_start_matches("http://")
            .split('/')
            .next()
            .unwrap();
        let _ = TcpStream::connect(address);
        let _ = self.worker.take().unwrap().join();
    }
}
fn input(base: &str) -> SummaryInput {
    SummaryInput {
        base_url: base.into(),
        api_key: "fixture-key".into(),
        model: None,
        text: "周五发布。".into(),
        locale: "zh-CN".into(),
        meeting_id: "meeting-fixture".into(),
        input_fingerprint: "a".repeat(64),
    }
}
fn models() -> HTTPReply {
    (
        200,
        json!({"data":[{"id":"embedding-model"},{"id":"private-model"},{"id":"gpt-4o-mini"}]})
            .to_string(),
        vec![],
    )
}
fn completion(text: &str) -> HTTPReply {
    (200,json!({"choices":[{"finish_reason":"stop","message":{"content":text}}],"usage":{"prompt_tokens":10,"completion_tokens":5}}).to_string(),vec![])
}
fn progress() -> ProgressHandler {
    Arc::new(|_| {})
}

#[tokio::test]
async fn configured_deepseek_model_bypasses_discovery_for_every_chunk_and_merge() {
    let server = Server::new(|r| {
        assert!(r.path.ends_with("/chat/completions"));
        assert_eq!(r.body["model"], "deepseek-chat");
        assert_eq!(r.body["stream"], true);
        completion("配置模型生成的摘要")
    });
    let mut request = input(&server.base);
    request.model = Some("deepseek-chat".into());
    request.text = "会议内容".repeat(4000);
    let result = OpenAICompatibleProvider::new()
        .unwrap()
        .summarize(request, progress())
        .await
        .unwrap();
    assert_eq!(result.model, "deepseek-chat");
    assert_eq!(server.calls.lock().unwrap().len(), 3);
}

#[tokio::test]
async fn custom_path_auth_model_and_usage_follow_openai_protocol() {
    let server = Server::new(|r| {
        if r.path.ends_with("/models") {
            models()
        } else {
            let (status, body, headers) = completion("摘要：周五发布。");
            let mut body: Value = serde_json::from_str(&body).unwrap();
            body["model"] = json!("gpt-4o-mini-resolved-version");
            (status, body.to_string(), headers)
        }
    });
    let result = OpenAICompatibleProvider::new()
        .unwrap()
        .summarize(input(&server.base), progress())
        .await
        .unwrap();
    assert_eq!(result.model, "gpt-4o-mini-resolved-version");
    assert_eq!(result.text, "摘要：周五发布。");
    assert_eq!(result.usage.unwrap().input_tokens, 10);
    let calls = server.calls.lock().unwrap();
    assert_eq!(calls.len(), 2);
    assert_eq!(calls[1].path, "/custom/v1/chat/completions");
    assert!(
        calls[1]
            .headers
            .to_lowercase()
            .contains("authorization: bearer fixture-key")
    );
    assert_eq!(calls[1].body["model"], "gpt-4o-mini");
    assert!(
        calls[1].body["messages"][0]["content"]
            .as_str()
            .unwrap()
            .contains("简体中文")
    );
}
#[tokio::test]
async fn discovery_fallback_and_private_model_work() {
    for missing in [true, false] {
        let server = Server::new(move |r| {
            if r.path.ends_with("/models") {
                if missing {
                    (404, "{}".into(), vec![])
                } else {
                    (
                        200,
                        json!({"data":[{"id":"private-model"}]}).to_string(),
                        vec![],
                    )
                }
            } else {
                completion("结果")
            }
        });
        let result = OpenAICompatibleProvider::new()
            .unwrap()
            .summarize(input(&server.base), progress())
            .await
            .unwrap();
        assert_eq!(
            result.model,
            if missing {
                "gpt-4o-mini"
            } else {
                "private-model"
            }
        );
    }
}
#[tokio::test]
async fn long_unicode_transcripts_keep_tail_and_merge_all_summaries() {
    let server = Server::new(|r| {
        if r.path.ends_with("/models") {
            models()
        } else {
            completion("分段摘要")
        }
    });
    let mut request = input(&server.base);
    request.text = "甲😀".repeat(13000) + "最后决定周五发布";
    assert_eq!(split_text(&request.text, 12000).join(""), request.text);
    let updates = Arc::new(Mutex::new(Vec::new()));
    let saved = updates.clone();
    let result = OpenAICompatibleProvider::new()
        .unwrap()
        .summarize(request, Arc::new(move |p| saved.lock().unwrap().push(p)))
        .await
        .unwrap();
    let calls = server.calls.lock().unwrap();
    assert_eq!(calls.len(), 5);
    assert!(
        calls[3].body["messages"][1]["content"]
            .as_str()
            .unwrap()
            .contains("最后决定周五发布")
    );
    assert!(
        calls[4].body["messages"][1]["content"]
            .as_str()
            .unwrap()
            .contains("分段摘要\n\n分段摘要\n\n分段摘要")
    );
    assert_eq!(result.usage.unwrap().input_tokens, 40);
    assert!(updates.lock().unwrap().iter().any(|p| p.stage == "merging"));
}
#[tokio::test]
async fn status_errors_timeouts_and_invalid_results_never_retry_or_expose_payloads() {
    for status in [401, 429, 500, 404] {
        let server = Server::new(move |r| {
            if r.path.ends_with("/models") {
                models()
            } else {
                (status, "fixture-key confidential transcript".into(), vec![])
            }
        });
        let error = OpenAICompatibleProvider::new()
            .unwrap()
            .summarize(input(&server.base), progress())
            .await
            .unwrap_err();
        assert!(
            !serde_json::to_string(&error)
                .unwrap()
                .contains("fixture-key")
        );
        assert_eq!(server.calls.lock().unwrap().len(), 2);
    }
    for body in [
        "not json".to_owned(),
        json!({"choices":[]}).to_string(),
        json!({"choices":[{"finish_reason":"length","message":{"content":"partial"}}]}).to_string(),
        completion(&"长".repeat(4001)).1,
    ] {
        let server = Server::new(move |r| {
            if r.path.ends_with("/models") {
                models()
            } else {
                (200, body.clone(), vec![])
            }
        });
        assert!(
            OpenAICompatibleProvider::new()
                .unwrap()
                .summarize(input(&server.base), progress())
                .await
                .is_err()
        );
        assert_eq!(server.calls.lock().unwrap().len(), 2);
    }
    let server = Server::new(|r| {
        if r.path.ends_with("/models") {
            models()
        } else {
            thread::sleep(Duration::from_millis(250));
            completion("late")
        }
    });
    let error = OpenAICompatibleProvider::with_timeout(Duration::from_millis(30))
        .unwrap()
        .summarize(input(&server.base), progress())
        .await
        .unwrap_err();
    assert_eq!(error.kind, "timeout");
    assert_eq!(server.calls.lock().unwrap().len(), 2);
}
#[tokio::test]
async fn redirects_are_not_followed_and_empty_model_lists_fail() {
    let target = Server::new(|_| completion("must not be reached"));
    let location = target.base.clone();
    let source = Server::new(move |_| (307, "{}".into(), vec![("Location", location.clone())]));
    assert!(
        OpenAICompatibleProvider::new()
            .unwrap()
            .summarize(input(&source.base), progress())
            .await
            .is_err()
    );
    assert!(target.calls.lock().unwrap().is_empty());
    let empty = Server::new(|_| {
        (
            200,
            json!({"data":[{"id":"embedding-only"}]}).to_string(),
            vec![],
        )
    });
    assert_eq!(
        OpenAICompatibleProvider::new()
            .unwrap()
            .summarize(input(&empty.base), progress())
            .await
            .unwrap_err()
            .kind,
        "model_unavailable"
    );
}
#[test]
fn validation_rejects_unsafe_endpoints_and_invalid_input() {
    for base in [
        "http://remote.test/v1",
        "file:///tmp/key",
        "https://user:key@example.test/v1",
        "https://example.test/v1?key=x",
        "https://example.test/v1#x",
    ] {
        assert!(validate(&input(base)).is_err());
    }
    for base in [
        "http://localhost:1234/v1",
        "http://127.0.0.1:1234/v1",
        "http://[::1]:1234/v1",
        "https://example.test/prefix/v1",
    ] {
        assert!(validate(&input(base)).is_ok());
    }
    let mut request = input("https://example.test/v1");
    request.api_key = "bad\nkey".into();
    assert!(validate(&request).is_err());
}

#[tokio::test]
async fn sse_eof_needs_finish_and_never_resubmits_or_saves_partial_output() {
    for (tail, succeeds) in [
        ("", false),
        ("data: [DONE]\n\n", false),
        (
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n",
            true,
        ),
        (
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: incomplete",
            false,
        ),
    ] {
        let server = Server::new(move |_| {
            (
                200,
                format!("data: {{\"choices\":[{{\"delta\":{{\"content\":\"摘要\"}}}}]}}\n\n{tail}"),
                vec![("Content-Type", "text/event-stream".into())],
            )
        });
        let mut request = input(&server.base);
        request.model = Some("fixture".into());
        let result = OpenAICompatibleProvider::new()
            .unwrap()
            .summarize(request, progress())
            .await;
        assert_eq!(result.is_ok(), succeeds);
        if let Ok(result) = result {
            assert_eq!(result.text, "摘要");
            assert!(result.usage.is_none());
        }
        assert_eq!(server.calls.lock().unwrap().len(), 1);
    }
}
