use async_trait::async_trait;
use meeting_summary::{provider::*, rpc::*};
use serde_json::{Value, json};
use std::{sync::Arc, time::Duration};
use tokio::io::{AsyncWriteExt, BufReader, DuplexStream};
struct FixtureProvider;
#[async_trait]
impl SummaryProvider for FixtureProvider {
    async fn summarize(
        &self,
        input: SummaryInput,
        progress: ProgressHandler,
    ) -> Result<SummaryResult, ProviderError> {
        progress(Progress {
            stage: "summarizing",
            completed: 0,
            total: 1,
        });
        if input.text == "slow" {
            tokio::time::sleep(Duration::from_millis(150)).await;
        }
        if input.text == "cancel" {
            tokio::time::sleep(Duration::from_secs(30)).await;
        }
        Ok(SummaryResult {
            text: input.text,
            model: "fixture".into(),
            meeting_id: input.meeting_id,
            input_fingerprint: input.input_fingerprint,
            usage: None,
        })
    }
}
fn params(text: &str) -> Value {
    json!({"baseURL":"http://localhost/v1","apiKey":"fixture", "text":text,"locale":"zh-CN","meetingID":"fixture","inputFingerprint":"a".repeat(64)})
}
async fn send(writer: &mut DuplexStream, id: &str, method: &str, params: Value) {
    let mut data =
        serde_json::to_vec(&json!({"jsonrpc":"2.0","id":id,"method":method,"params":params}))
            .unwrap();
    data.push(b'\n');
    writer.write_all(&data).await.unwrap();
}
async fn next(reader: &mut BufReader<DuplexStream>) -> Value {
    let bytes = tokio::time::timeout(Duration::from_secs(3), read_frame(reader))
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    serde_json::from_slice(&bytes).unwrap()
}
async fn connection() -> (
    DuplexStream,
    BufReader<DuplexStream>,
    tokio::task::JoinHandle<std::io::Result<()>>,
) {
    let (writer, input) = tokio::io::duplex(65536);
    let (output, reader) = tokio::io::duplex(65536);
    let task = tokio::spawn(serve(
        BufReader::new(input),
        output,
        Arc::new(FixtureProvider),
    ));
    (writer, BufReader::new(reader), task)
}
#[tokio::test]
async fn handshake_version_and_unknown_methods_have_structured_errors() {
    let (mut writer, mut reader, task) = connection().await;
    send(&mut writer, "before", "summary/generate", params("x")).await;
    assert_eq!(next(&mut reader).await["error"]["code"], -32002);
    send(
        &mut writer,
        "old",
        "initialize",
        json!({"protocolVersion":99}),
    )
    .await;
    assert_eq!(next(&mut reader).await["id"], "old");
    send(
        &mut writer,
        "init",
        "initialize",
        json!({"protocolVersion":1}),
    )
    .await;
    assert_eq!(next(&mut reader).await["result"]["protocolVersion"], 1);
    send(&mut writer, "unknown", "other", json!({})).await;
    assert_eq!(next(&mut reader).await["error"]["code"], -32601);
    drop(writer);
    assert!(task.await.unwrap().is_ok());
}
#[tokio::test]
async fn concurrent_results_are_matched_by_id_and_progress_carries_request_id() {
    let (mut writer, mut reader, task) = connection().await;
    send(
        &mut writer,
        "init",
        "initialize",
        json!({"protocolVersion":1}),
    )
    .await;
    next(&mut reader).await;
    send(&mut writer, "slow-id", "summary/generate", params("slow")).await;
    send(&mut writer, "fast-id", "summary/generate", params("fast")).await;
    let mut results = Vec::new();
    let mut notifications = Vec::new();
    while results.len() < 2 {
        let value = next(&mut reader).await;
        if value.get("method").is_some() {
            notifications.push(value)
        } else {
            results.push(value)
        }
    }
    assert_eq!(results[0]["id"], "fast-id");
    assert_eq!(results[1]["id"], "slow-id");
    assert_eq!(results[1]["result"]["text"], "slow");
    assert_eq!(notifications.len(), 2);
    assert!(
        notifications
            .iter()
            .all(|p| ["fast-id", "slow-id"].contains(&p["params"]["requestID"].as_str().unwrap()))
    );
    drop(writer);
    assert!(task.await.unwrap().is_ok());
}
#[tokio::test]
async fn cancellation_has_one_terminal_response_and_no_late_success() {
    let (mut writer, mut reader, task) = connection().await;
    send(
        &mut writer,
        "init",
        "initialize",
        json!({"protocolVersion":1}),
    )
    .await;
    next(&mut reader).await;
    send(&mut writer, "target", "summary/generate", params("cancel")).await;
    assert_eq!(next(&mut reader).await["method"], "summary/progress");
    send(
        &mut writer,
        "cancel",
        "summary/cancel",
        json!({"requestID":"target"}),
    )
    .await;
    assert_eq!(next(&mut reader).await["error"]["code"], -32800);
    assert_eq!(next(&mut reader).await["result"]["cancelled"], true);
    send(
        &mut writer,
        "probe",
        "initialize",
        json!({"protocolVersion":1}),
    )
    .await;
    assert_eq!(next(&mut reader).await["id"], "probe");
    drop(writer);
    assert!(task.await.unwrap().is_ok());
}
#[tokio::test]
async fn frames_preserve_split_and_coalesced_messages_and_reject_oversize() {
    let (mut writer, input) = tokio::io::duplex(32);
    let task = tokio::spawn(async move {
        writer.write_all(b"{\"id\":").await.unwrap();
        writer.write_all(b"1}\n{\"id\":2}\n").await.unwrap();
    });
    let mut reader = BufReader::new(input);
    assert_eq!(
        read_frame(&mut reader).await.unwrap().unwrap(),
        b"{\"id\":1}\n"
    );
    assert_eq!(
        read_frame(&mut reader).await.unwrap().unwrap(),
        b"{\"id\":2}\n"
    );
    task.await.unwrap();
    let oversized = vec![b'x'; MAX_MESSAGE_BYTES + 1];
    let mut reader = BufReader::new(&oversized[..]);
    assert!(read_frame(&mut reader).await.is_err());
    let mut truncated = BufReader::new(&b"{\"id\":1}"[..]);
    assert!(read_frame(&mut truncated).await.is_err());
}
#[tokio::test]
async fn disconnect_aborts_pending_work() {
    let (mut writer, mut reader, task) = connection().await;
    send(
        &mut writer,
        "init",
        "initialize",
        json!({"protocolVersion":1}),
    )
    .await;
    next(&mut reader).await;
    send(&mut writer, "pending", "summary/generate", params("cancel")).await;
    next(&mut reader).await;
    drop(writer);
    drop(reader);
    assert!(
        tokio::time::timeout(Duration::from_secs(1), task)
            .await
            .is_ok()
    );
}
