import Foundation

extension SelfTest {
    /// `Talk --worker-test a.wav b.m4a …`: runs each file through the model worker the way a dictation does
    /// (start worker → wait for the model → transcribe → unload), one worker per file, and prints one line per
    /// file with timings, whether the worker exited, and the text. Ends with `RESULT pass=N fail=M`.
    static func workerTest(files: [URL]) {
        Task { @MainActor in
            var pass = 0, fail = 0
            for url in files {
                do {
                    let samples = try await AudioDecoder.load(url)
                    let worker = ModelWorker()
                    let t0 = Date()
                    worker.prepare()
                    try await worker.waitUntilLoaded()
                    let loadMs = ms(since: t0)
                    let t1 = Date()
                    let text = try await worker.transcribe(samples)
                    let textMs = ms(since: t1)
                    await worker.unload()
                    let exited = !worker.isRunning
                    let ok = exited && !text.isEmpty
                    if ok { pass += 1 } else { fail += 1 }
                    print("\(ok ? "PASS" : "FAIL"): \(url.lastPathComponent) start+load_ms=\(loadMs) transcribe_ms=\(textMs) "
                        + "worker_exited=\(exited ? "yes" : "no") app_footprint_mb=\(Int(footprintMB()))")
                    print("TEXT \(url.lastPathComponent)\t\(text)")
                } catch {
                    fail += 1
                    print("FAIL: \(url.lastPathComponent) \(error.localizedDescription)")
                }
            }
            print("RESULT pass=\(pass) fail=\(fail)")
            fflush(stdout)
            exit(fail == 0 ? 0 : 1)
        }
    }
}

extension ModelWorker {
    /// For self-tests: whether a worker process is alive.
    var isRunning: Bool { hasProcess }
}
