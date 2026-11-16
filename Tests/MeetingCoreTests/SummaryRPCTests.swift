import Foundation
import Testing
@testable import MeetingCore

private func rpcFixture(_ body: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("SummaryRPC-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("backend")
    let script = """
    #!/bin/sh
    IFS= read -r initialize
    initialize_id=$(printf '%s' "$initialize" | /usr/bin/sed -E 's/.*"id"[ ]*:[ ]*"([^"]+)".*/\\1/')
    \(body)
    """
    try Data(script.utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
    return file
}
private let handshake = """
printf '{"jsonrpc":"2.0","id":"%s","result":{"protocolVersion":1}}\\n' "$initialize_id"
IFS= read -r generate
"""

@Test func rpcClientMatchesHandshakeResponseAndProgressIDs() async throws {
    let fixture = try rpcFixture(handshake + """

    printf '{"jsonrpc":"2.0","method":"summary/progress","params":{"requestID":"target","stage":"summarizing","completed":0,"total":1}}\\n'
    printf '{"jsonrpc":"2.0","id":"target","result":{"text":"摘要","model":"fixture"}}\\n'
    """)
    defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
    let client = SummaryRPCClient(executable: fixture)
    let data = try await client.generate(id: "target", params: [:], progress: { _ in })
    let value = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(value["text"] as? String == "摘要")
}

@Test func rpcClientRejectsMismatchedResponseAndReportsUnexpectedExit() async throws {
    for body in [
        handshake + "\nprintf '{\"jsonrpc\":\"2.0\",\"id\":\"wrong-id\",\"result\":{}}\\n'\n",
        "exit 23\n"
    ] {
        let fixture = try rpcFixture(body)
        defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
        await #expect(throws: SummaryRPCError.self) {
            try await SummaryRPCClient(executable: fixture).generate(id: "target", params: [:], progress: { _ in })
        }
    }
}

private actor RPCProgressFlag {
    var seen = false
    func mark() { seen = true }
}
@Test func rpcClientSendsCancellationAndDiscardsLateSuccess() async throws {
    let fixture = try rpcFixture(handshake + """

    printf '{"jsonrpc":"2.0","method":"summary/progress","params":{"requestID":"target","stage":"summarizing","completed":0,"total":1}}\\n'
    IFS= read -r cancellation
    case "$cancellation" in
      *summary/cancel*) printf '{"jsonrpc":"2.0","id":"target","result":{"text":"late result"}}\\n' ;;
      *) exit 24 ;;
    esac
    """)
    defer { try? FileManager.default.removeItem(at: fixture.deletingLastPathComponent()) }
    let flag = RPCProgressFlag(), client = SummaryRPCClient(executable: fixture)
    let task = Task { try await client.generate(id: "target", params: [:]) { _ in await flag.mark() } }
    while await !flag.seen { await Task.yield() }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test func rpcFramesAreBoundedAndPreserveCoalescedPipeMessages() throws {
    let pipe = Pipe()
    try pipe.fileHandleForWriting.write(contentsOf: Data("{\"id\":1}\n{\"id\":2}\n".utf8))
    try pipe.fileHandleForWriting.close()
    defer { try? pipe.fileHandleForReading.close() }
    let reader = SummaryRPCFrameReader(handle: pipe.fileHandleForReading)
    #expect(try reader.next() == Data("{\"id\":1}".utf8))
    #expect(try reader.next() == Data("{\"id\":2}".utf8))
    #expect(try reader.next() == nil)
    #expect(throws: SummaryRPCError.self) {
        try SummaryRPCClient.frame(id: "oversized", method: "summary/generate", params: ["text": String(repeating: "x", count: SummaryRPCClient.maxMessageBytes)])
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["MEETING_TEST_SUMMARY_BASE_URL"] != nil))
func rustSummaryProviderIntegration() async throws {
    let baseURL = try #require(ProcessInfo.processInfo.environment["MEETING_TEST_SUMMARY_BASE_URL"])
    let request = SummaryRequest(recordingID: UUID(), locale: "zh-CN", segments: [
        TranscriptSegment(chunkID: UUID(), source: .application, start: 0, end: 1, text: "周五发布。")
    ])
    let provider = OpenAISummaryProvider(configuration: SummaryConfiguration(baseURL: baseURL, model: "deepseek-chat"), apiKey: "fixture-only-key")
    let result = try await provider.summarize(request)
    #expect(result.text == "结论：周五发布。")
    #expect(result.model == "fixture-chat")
    #expect(result.usage?.inputTokens == 21)
    #expect(result.usage?.modelName == "fixture-chat")
    #expect(result.usage?.keyID == APIUsageIdentity.keyID(for: "fixture-only-key"))
    #expect(result.usage?.recordedAt != nil)
}
