import Foundation
import Darwin
import Synchronization

public enum SummaryRPCError: Error, LocalizedError, Sendable {
    case processExited(Int32), invalidResponse, messageTooLarge, timedOut
    public var errorDescription: String? {
        switch self {
        case .processExited(let code): "摘要后端连接中断（退出码 \(code)），请显式重试；请求可能已经计费。"
        case .invalidResponse: "摘要后端响应不匹配或协议无效，请重新构建应用后重试。"
        case .messageTooLarge: "转写内容超过摘要后端单条消息限制（8 MB），未提交摘要请求。"
        case .timedOut: "摘要后端长时间未响应，已中断连接。请显式重试；请求可能已经计费。"
        }
    }
}

/// One managed backend connection per summary. Separate connections may run
/// concurrently; every response and progress notification is matched by ID.
final class SummaryRPCClient: Sendable {
    static let maxMessageBytes = 8 * 1024 * 1024
    private struct State {
        var process: Process?
        var input: FileHandle?
        var requestID: String?
        var cancelled = false
        var timedOut = false
        var timerGeneration = 0
    }
    private let state = Mutex(State())
    private let executable: URL?
    init(executable: URL? = nil) { self.executable = executable }

    func generate(id: String, params: [String: Any], progress: @escaping SummaryProgressHandler) async throws -> Data {
        let input = try Self.frame(id: id, method: "summary/generate", params: params)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async { [self] in
                    do { continuation.resume(returning: try execute(id: id, input: input, progress: progress)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { self.cancel() }
    }
    private func cancel() {
        state.withLock { value in
            value.cancelled = true
            if let id = value.requestID, let input = value.input,
               let frame = try? Self.frame(id: UUID().uuidString, method: "summary/cancel", params: ["requestID": id]) {
                try? input.write(contentsOf: frame)
            }
        }
        // Allow the Rust backend to acknowledge cancellation, then enforce exit.
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(500)) { [self] in
            state.withLock { if let process = $0.process, process.isRunning { process.terminate() } }
        }
    }
    private func armWatchdog() {
        let generation = state.withLock { value in value.timerGeneration += 1; return value.timerGeneration }
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(150)) { [weak self] in
            self?.state.withLock { value in
                if value.timerGeneration == generation, let process = value.process, process.isRunning {
                    value.timedOut = true; process.terminate()
                }
            }
        }
    }
    private func execute(id: String, input: Data, progress: @escaping SummaryProgressHandler) throws -> Data {
        let process = Process(), stdin = Pipe(), stdout = Pipe()
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.executableURL = try executable ?? Self.backendURL()
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = FileHandle.nullDevice
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        try state.withLock { value in
            guard !value.cancelled else { throw CancellationError() }
            try process.run(); value.process = process; value.input = stdin.fileHandleForWriting
        }
        defer {
            state.withLock { value in
                value.input = nil; value.process = nil; value.timerGeneration += 1
                try? stdin.fileHandleForWriting.close()
                if process.isRunning { process.terminate() }
            }
            process.waitUntilExit(); try? stdout.fileHandleForReading.close()
        }
        let reader = SummaryRPCFrameReader(handle: stdout.fileHandleForReading)
        let initializeID = UUID().uuidString
        try state.withLock { _ in
            try stdin.fileHandleForWriting.write(contentsOf: Self.frame(id: initializeID, method: "initialize", params: ["protocolVersion": 1]))
        }
        armWatchdog()
        let handshake = try response(reader: reader, process: process, id: initializeID, progress: { _ in })
        guard let metadata = try JSONSerialization.jsonObject(with: handshake) as? [String: Any], metadata["protocolVersion"] as? Int == 1 else {
            throw SummaryRPCError.invalidResponse
        }
        try state.withLock { value in
            guard !value.cancelled else { throw CancellationError() }
            value.requestID = id
            try stdin.fileHandleForWriting.write(contentsOf: input)
        }
        armWatchdog()
        let result = try response(reader: reader, process: process, id: id, progress: progress)
        if state.withLock({ $0.cancelled }) { throw CancellationError() }
        return result
    }
    private func response(reader: SummaryRPCFrameReader, process: Process, id: String,
                          progress: @escaping SummaryProgressHandler) throws -> Data {
        while let bytes = try reader.next() {
            if state.withLock({ $0.cancelled }) { throw CancellationError() }
            guard let message = try JSONSerialization.jsonObject(with: bytes) as? [String: Any], message["jsonrpc"] as? String == "2.0" else {
                throw SummaryRPCError.invalidResponse
            }
            if let method = message["method"] as? String {
                guard method == "summary/progress", let params = message["params"] as? [String: Any],
                      params["requestID"] as? String == id else { throw SummaryRPCError.invalidResponse }
                let data = try JSONSerialization.data(withJSONObject: params)
                let update = try JSONDecoder().decode(SummaryProgress.self, from: data)
                guard update.completed >= 0, update.total >= update.completed else { throw SummaryRPCError.invalidResponse }
                armWatchdog()
                Task { await progress(update) }
                continue
            }
            guard message["id"] as? String == id else { throw SummaryRPCError.invalidResponse }
            if let error = message["error"] as? [String: Any] {
                if error["code"] as? Int == -32800 { throw CancellationError() }
                if (error["data"] as? [String: Any])?["kind"] as? String == "timeout" { throw SummaryRPCError.timedOut }
                // The bundled backend emits normalized errors without raw server bodies.
                throw MeetingError.message(error["message"] as? String ?? "摘要后端请求失败。")
            }
            guard let result = message["result"] as? [String: Any] else { throw SummaryRPCError.invalidResponse }
            return try JSONSerialization.data(withJSONObject: result)
        }
        if state.withLock({ $0.cancelled }) { throw CancellationError() }
        if state.withLock({ $0.timedOut }) { throw SummaryRPCError.timedOut }
        process.waitUntilExit()
        throw SummaryRPCError.processExited(process.terminationStatus)
    }
    static func frame(id: String, method: String, params: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        data.append(10)
        guard data.count <= maxMessageBytes else { throw SummaryRPCError.messageTooLarge }
        return data
    }
    private static func backendURL() throws -> URL {
        let bundled = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("meeting-summary")
        let development = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build/meeting-summary")
        guard let url = [bundled, development].compactMap({ $0 }).first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw MeetingError.message("Rust 摘要后端缺失，请运行 scripts/build-summary-helper.sh 或重新构建应用。")
        }
        return url
    }
}

/// A response may span arbitrary pipe reads or share one read with notifications.
final class SummaryRPCFrameReader {
    private let handle: FileHandle
    private var pending = Data()
    init(handle: FileHandle) { self.handle = handle }
    func next() throws -> Data? {
        while true {
            if let newline = pending.firstIndex(of: 10) {
                let frame = Data(pending[..<newline]); pending.removeSubrange(...newline)
                guard frame.count + 1 <= SummaryRPCClient.maxMessageBytes else { throw SummaryRPCError.messageTooLarge }
                return frame
            }
            guard pending.count < SummaryRPCClient.maxMessageBytes else { throw SummaryRPCError.messageTooLarge }
            // Foundation read(upToCount:) may wait to fill the requested size on
            // a pipe. POSIX read returns available bytes without waiting for EOF.
            var block = [UInt8](repeating: 0, count: 16 * 1024)
            let count = Darwin.read(handle.fileDescriptor, &block, block.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if count == 0 {
                guard pending.isEmpty else { throw SummaryRPCError.invalidResponse }
                return nil
            }
            pending.append(contentsOf: block.prefix(count))
        }
    }
}
