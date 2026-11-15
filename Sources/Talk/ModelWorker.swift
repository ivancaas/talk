import Foundation

/// Runs the speech model in a child process (`Talk --model-worker`) that exits when the model is unloaded.
///
/// Releasing a CoreML model inside a long-running process does not give its Neural Engine memory back at once:
/// macOS keeps 350-600 MB attributed to the process for seconds to minutes. A process that exits returns all of
/// it immediately, so the menu-bar app keeps the model in a worker and stays at its idle size between dictations.
///
/// Same interface as `Engine` (which the worker itself uses, as does `talk transcribe`).
@MainActor
final class ModelWorker {
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var readyWaiters: [CheckedContinuation<Void, Error>] = []
    private var replyWaiters: [CheckedContinuation<String, Error>] = []
    private var failure: String?

    var hasProcess: Bool { process?.isRunning ?? false }

    /// True once the worker has the model in memory.
    private(set) var isReady = false
    /// 0...1 while the model files are being downloaded, nil otherwise.
    private(set) var downloadFraction: Double? { didSet { onDownloadChange?() } }
    /// Why the last download or load failed (cleared by the next attempt).
    private(set) var lastError: String? { didSet { onDownloadChange?() } }
    /// Called on the main actor when `downloadFraction` or `lastError` changes.
    var onDownloadChange: (() -> Void)?

    struct WorkerError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Starts the worker, which loads the model (call when recording starts so the load overlaps speech).
    func prepare() {
        guard process == nil else { return }
        let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let p = Process()
        p.executableURL = exe
        p.arguments = ["--model-worker"]
        let toWorker = Pipe(), fromWorker = Pipe()
        p.standardInput = toWorker
        p.standardOutput = fromWorker
        p.standardError = FileHandle.standardError
        lastError = nil
        failure = nil
        buffer.removeAll()
        if !Engine.isDownloaded { downloadFraction = 0 }
        fromWorker.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            Task { @MainActor in self?.received(data) }
        }
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { @MainActor in self?.exited(proc, status: status) }
        }
        do {
            try p.run()
        } catch {
            fail("could not start the model worker: \(error.localizedDescription)")
            return
        }
        process = p
        input = toWorker.fileHandleForWriting
    }

    /// Waits until the model is ready (returns at once when it is already loaded).
    func waitUntilLoaded() async throws {
        if isReady { return }
        guard process != nil else {
            if let failure { throw WorkerError(message: failure) }
            return
        }
        try await withCheckedThrowingContinuation { readyWaiters.append($0) }
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        prepare()
        try await waitUntilLoaded()
        guard let input else { throw WorkerError(message: failure ?? "model worker is not running") }
        // Request: sample count (UInt32, little endian) then Float32 samples. Written off the main thread:
        // a long dictation is several MB and the pipe only holds 64 KB until the worker reads it.
        var request = Data()
        var count = UInt32(samples.count).littleEndian
        withUnsafeBytes(of: &count) { request.append(contentsOf: $0) }
        samples.withUnsafeBytes { request.append(contentsOf: $0) }
        return try await withCheckedThrowingContinuation { cont in
            replyWaiters.append(cont)
            DispatchQueue.global(qos: .userInitiated).async {
                do { try input.write(contentsOf: request) } catch {
                    Task { @MainActor in self.fail("could not send audio to the model worker: \(error.localizedDescription)") }
                }
            }
        }
    }

    /// Ends the worker; its exit returns all of the model's memory to macOS.
    func unload() async {
        guard let p = process else { return }
        try? input?.close()  // EOF: the worker exits by itself
        input = nil
        isReady = false
        for _ in 0..<40 where p.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        if p.isRunning { p.terminate() }
        log("model unloaded (worker exited)")
    }

    // MARK: - worker → app: one JSON object per line

    private func received(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let msg = try? JSONDecoder().decode(WorkerMessage.self, from: line) else { continue }
            handle(msg)
        }
    }

    private func handle(_ msg: WorkerMessage) {
        if let p = msg.progress, let shown = downloadFraction { downloadFraction = max(shown, min(1, p)) }
        if msg.ready == true {
            isReady = true
            if downloadFraction != nil { downloadFraction = nil }
            let waiters = readyWaiters
            readyWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
        if let text = msg.text, !replyWaiters.isEmpty {
            replyWaiters.removeFirst().resume(returning: text)
        }
        if let error = msg.error { fail(error) }
    }

    private func exited(_ p: Process, status: Int32) {
        guard p === process else { return }
        process = nil
        input = nil
        isReady = false
        if !readyWaiters.isEmpty || !replyWaiters.isEmpty {
            fail(failure ?? "model worker stopped (status \(status))")
        }
    }

    private func fail(_ message: String) {
        failure = message
        lastError = message
        if downloadFraction != nil { downloadFraction = nil }
        let ready = readyWaiters, replies = replyWaiters
        readyWaiters.removeAll()
        replyWaiters.removeAll()
        ready.forEach { $0.resume(throwing: WorkerError(message: message)) }
        replies.forEach { $0.resume(throwing: WorkerError(message: message)) }
        if let p = process, p.isRunning { p.terminate() }
    }
}

struct WorkerMessage: Codable {
    var progress: Double?
    var ready: Bool?
    var text: String?
    var error: String?
}

/// `Talk --model-worker`: loads the model, then answers transcription requests on stdin until EOF.
enum WorkerMain {
    static func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        Task { @MainActor in
            let engine = Engine()
            engine.onDownloadChange = {
                if let f = engine.downloadFraction { send(WorkerMessage(progress: f)) }
            }
            engine.prepare()
            do {
                try await engine.waitUntilLoaded()
            } catch {
                send(WorkerMessage(error: error.localizedDescription))
                exit(1)
            }
            send(WorkerMessage(ready: true))
            // Requests are read on a plain thread (blocking reads) and transcribed on the main actor, in order.
            let requests = AsyncStream<[Float]> { cont in
                Thread.detachNewThread {
                    while let samples = readRequest() { cont.yield(samples) }
                    cont.finish()
                }
            }
            for await samples in requests {
                do {
                    send(WorkerMessage(text: try await engine.transcribe(samples)))
                } catch {
                    send(WorkerMessage(error: error.localizedDescription))
                }
            }
            exit(0)  // stdin closed: the app unloaded the model or quit
        }
        RunLoop.main.run()
        exit(0)
    }

    private static func send(_ msg: WorkerMessage) {
        guard var line = try? JSONEncoder().encode(msg) else { return }
        line.append(0x0A)
        try? FileHandle.standardOutput.write(contentsOf: line)
    }

    private static func readRequest() -> [Float]? {
        guard let header = readExactly(4) else { return nil }
        let count = Int(header.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) })
        guard count > 0 else { return [] }
        guard let body = readExactly(count * MemoryLayout<Float>.size) else { return nil }
        return body.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    private static func readExactly(_ n: Int) -> Data? {
        var data = Data(count: n)
        var got = 0
        while got < n {
            let r = data.withUnsafeMutableBytes { read(0, $0.baseAddress! + got, n - got) }
            if r <= 0 { return nil }
            got += r
        }
        return data
    }
}
