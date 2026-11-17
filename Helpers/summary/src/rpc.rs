use crate::provider::{OpenAICompatibleProvider, ProgressHandler, SummaryInput, SummaryProvider};
use serde_json::{Value, json};
use std::{collections::HashMap, sync::Arc};
use tokio::{
    io::{AsyncBufRead, AsyncBufReadExt, AsyncWrite, AsyncWriteExt},
    sync::{Mutex, mpsc},
    task::JoinHandle,
};

type ActiveTasks = Arc<Mutex<HashMap<String, (Value, JoinHandle<()>)>>>;

pub const PROTOCOL_VERSION: u64 = 1;
pub const MAX_MESSAGE_BYTES: usize = 8 * 1024 * 1024;

fn success(id: Value, result: Value) -> Value {
    json!({"jsonrpc":"2.0","id":id,"result":result})
}
fn error(id: Value, code: i32, message: &str) -> Value {
    json!({"jsonrpc":"2.0","id":id,"error":{"code":code,"message":message}})
}
fn key(id: &Value) -> Option<String> {
    match id {
        Value::String(s) if !s.is_empty() && s.len() <= 128 => Some(format!("s:{s}")),
        Value::Number(n) if n.is_i64() || n.is_u64() => Some(format!("n:{n}")),
        _ => None,
    }
}

/// Bounded newline framing. Oversized input terminates the connection without
/// parsing a truncated request or starting a model call.
pub async fn read_frame<R: AsyncBufRead + Unpin>(
    reader: &mut R,
) -> std::io::Result<Option<Vec<u8>>> {
    let mut bytes = Vec::new();
    loop {
        let buffer = reader.fill_buf().await?;
        if buffer.is_empty() {
            return if bytes.is_empty() {
                Ok(None)
            } else {
                Err(std::io::ErrorKind::UnexpectedEof.into())
            };
        }
        let end = buffer.iter().position(|b| *b == b'\n').map(|i| i + 1);
        let count = end.unwrap_or(buffer.len());
        if bytes.len() + count > MAX_MESSAGE_BYTES {
            return Err(std::io::ErrorKind::InvalidData.into());
        }
        bytes.extend_from_slice(&buffer[..count]);
        reader.consume(count);
        if end.is_some() {
            return Ok(Some(bytes));
        }
    }
}

pub async fn serve<R, W>(
    mut input: R,
    mut output: W,
    provider: Arc<dyn SummaryProvider>,
) -> std::io::Result<()>
where
    R: AsyncBufRead + Unpin,
    W: AsyncWrite + Unpin + Send + 'static,
{
    let (tx, mut rx) = mpsc::unbounded_channel::<Value>();
    let writer = tokio::spawn(async move {
        while let Some(message) = rx.recv().await {
            let mut bytes = serde_json::to_vec(&message).map_err(std::io::Error::other)?;
            bytes.push(b'\n');
            output.write_all(&bytes).await?;
            output.flush().await?;
        }
        Ok::<_, std::io::Error>(())
    });
    let tasks: ActiveTasks = Arc::new(Mutex::new(HashMap::new()));
    let mut initialized = false;
    loop {
        let frame = tokio::select! {
            frame = read_frame(&mut input) => frame,
            _ = tx.closed() => break,
        };
        let frame = match frame {
            Ok(Some(frame)) => frame,
            Ok(None) => break,
            Err(_) => {
                let _ = tx.send(error(Value::Null, -32010, "RPC 消息过大或分帧不完整。"));
                break;
            }
        };
        let request: Value = match serde_json::from_slice(&frame) {
            Ok(value) => value,
            Err(_) => {
                let _ = tx.send(error(Value::Null, -32700, "JSON 解析失败。"));
                continue;
            }
        };
        let id = request.get("id").cloned().unwrap_or(Value::Null);
        let method = request.get("method").and_then(Value::as_str).unwrap_or("");
        if request.get("jsonrpc").and_then(Value::as_str) != Some("2.0") || key(&id).is_none() {
            let _ = tx.send(error(id, -32600, "RPC 请求格式或 ID 无效。"));
            continue;
        }
        match method {
            "initialize" => {
                if request["params"]["protocolVersion"].as_u64() != Some(PROTOCOL_VERSION) {
                    let _ = tx.send(error(id, -32602, "RPC 协议版本不兼容。"));
                    continue;
                }
                initialized = true;
                let _ = tx.send(success(id, json!({"protocolVersion": PROTOCOL_VERSION,"maxMessageBytes":MAX_MESSAGE_BYTES})));
            }
            "summary/generate" if initialized => {
                let params: SummaryInput = match serde_json::from_value(request["params"].clone()) {
                    Ok(params) => params,
                    Err(_) => {
                        let _ = tx.send(error(id, -32602, "摘要请求参数无效。"));
                        continue;
                    }
                };
                let request_key = key(&id).unwrap();
                let mut active = tasks.lock().await;
                if active.contains_key(&request_key) || active.len() >= 4 {
                    let _ = tx.send(error(id, -32600, "摘要请求重复或并发任务过多。"));
                    continue;
                }
                let (task_tx, task_provider, task_map, task_key, task_id) = (
                    tx.clone(),
                    provider.clone(),
                    tasks.clone(),
                    request_key.clone(),
                    id.clone(),
                );
                let handle = tokio::spawn(async move {
                    let progress_tx = task_tx.clone();
                    let progress_id = task_id.clone();
                    let progress: ProgressHandler = Arc::new(move |progress| {
                        let _ = progress_tx.send(json!({"jsonrpc":"2.0","method":"summary/progress", "params":{
                            "requestID":progress_id,"stage":progress.stage,"completed":progress.completed,"total":progress.total,"draft":progress.draft}}));
                    });
                    let result = task_provider.summarize(params, progress).await;
                    // Hold the lock across publication so cancellation cannot also publish a terminal response.
                    let mut active = task_map.lock().await;
                    if active.remove(&task_key).is_some() {
                        let message = match result {
                            Ok(value) => success(task_id, serde_json::to_value(value).unwrap()),
                            Err(problem) => {
                                json!({"jsonrpc":"2.0","id":task_id,"error":{"code":-32001,
                                "message":problem.message,"data":problem}})
                            }
                        };
                        let _ = task_tx.send(message);
                    }
                });
                active.insert(request_key, (id, handle));
            }
            "summary/cancel" if initialized => {
                let Some(target_key) = key(&request["params"]["requestID"]) else {
                    let _ = tx.send(error(id, -32602, "取消请求 ID 无效。"));
                    continue;
                };
                let task = tasks.lock().await.remove(&target_key);
                let cancelled = task.is_some();
                if let Some((target_id, handle)) = task {
                    handle.abort();
                    let _ = tx.send(error(target_id, -32800, "摘要已取消；服务端可能仍会计费。"));
                }
                let _ = tx.send(success(id, json!({"cancelled":cancelled})));
            }
            "summary/generate" | "summary/cancel" => {
                let _ = tx.send(error(id, -32002, "请先完成 initialize 握手。"));
            }
            _ => {
                let _ = tx.send(error(id, -32601, "RPC 方法不存在。"));
            }
        }
    }
    for (_, (_, handle)) in tasks.lock().await.drain() {
        handle.abort();
    }
    drop(tx);
    writer.await.map_err(std::io::Error::other)?
}

pub async fn run() -> std::io::Result<()> {
    let provider = OpenAICompatibleProvider::new()
        .map_err(|_| std::io::Error::other("provider initialization failed"))?;
    serve(
        tokio::io::BufReader::new(tokio::io::stdin()),
        tokio::io::stdout(),
        Arc::new(provider),
    )
    .await
}
