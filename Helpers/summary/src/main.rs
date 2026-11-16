#[tokio::main]
async fn main() {
    if meeting_summary::rpc::run().await.is_err() {
        eprintln!("meeting-summary: RPC connection closed unexpectedly");
        std::process::exit(1);
    }
}
