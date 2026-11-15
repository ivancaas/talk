import FluidAudio
import Foundation

/// Parakeet TDT v3 on the Neural Engine. Loaded on demand, released after use.
@MainActor
final class Engine {
    /// Talk keeps its own copy of the model, apart from FluidAudio's shared cache.
    static var modelsDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = AsrModels.defaultCacheDirectory(for: .v3).lastPathComponent
        return base.appendingPathComponent("Talk/Models/\(folder)", isDirectory: true)
    }

    // int8V2 on the Neural Engine: measured best of the FluidAudio options (palettized .int8 doubles
    // noisy-Spanish errors; CPU fp32 is ~2 points better there but much slower).
    private static let precision = ParakeetEncoderPrecision.int8V2

    /// True when every model file is on disk (nothing left to download).
    static var isDownloaded: Bool {
        if seenOnDisk { return true }
        seenOnDisk = AsrModels.modelsExist(at: modelsDir, version: .v3, encoderPrecision: precision)
        return seenOnDisk
    }
    private static var seenOnDisk = false

    private var loading: Task<AsrManager, Error>?
    private var generation = 0

    /// True once the model is in memory (not just loading).
    private(set) var isReady = false

    /// 0...1 while the model files are being downloaded, nil otherwise.
    private(set) var downloadFraction: Double? { didSet { onDownloadChange?() } }
    /// Why the last download or load failed (cleared by the next attempt).
    private(set) var lastError: String? { didSet { onDownloadChange?() } }
    /// Called on the main actor when `downloadFraction` or `lastError` changes.
    var onDownloadChange: (() -> Void)?

    /// Starts loading in the background (call when recording starts so load overlaps speech).
    /// Downloads the model first when it is not on disk yet, reporting `downloadFraction`.
    func prepare() {
        guard loading == nil else { return }
        generation += 1
        let generation = generation
        let downloading = !Self.isDownloaded
        lastError = nil
        if downloading { downloadFraction = 0 }
        let report: ProgressHandler = { [weak self] p in
            let fraction = p.fractionCompleted
            Task { @MainActor in self?.downloadProgress(fraction, generation) }
        }
        let progress = downloading ? report : nil
        loading = Task {
            let t0 = Date()
            do {
                let models = try await AsrModels.downloadAndLoad(
                    to: Self.modelsDir, version: .v3, encoderPrecision: Self.precision, progressHandler: progress)
                let manager = AsrManager(config: .default)
                try await manager.loadModels(models)
                if self.generation == generation {
                    self.isReady = true
                    if downloading { self.downloadFraction = nil }
                }
                log("model loaded in \(ms(since: t0)) ms from \(Self.modelsDir.path)")
                return manager
            } catch {
                if self.generation == generation {
                    // Forget the failed attempt so the next prepare() tries again.
                    self.loading = nil
                    if downloading { self.downloadFraction = nil }
                    self.lastError = error.localizedDescription
                }
                throw error
            }
        }
    }

    /// Progress arrives on any queue and may trail the end of the download: ignore stale reports.
    private func downloadProgress(_ fraction: Double, _ generation: Int) {
        guard self.generation == generation, let shown = downloadFraction else { return }
        downloadFraction = max(shown, min(1, fraction))
    }

    /// Waits until the model is ready (returns at once when it is already loaded).
    func waitUntilLoaded() async throws {
        _ = try await loading?.value
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        guard let result = try await transcribeDetailed(samples) else { return "" }
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Full result with token timings (used by the `talk transcribe` CLI for subtitles/JSON).
    func transcribeDetailed(_ samples: [Float]) async throws -> ASRResult? {
        prepare()
        guard let loading else { return nil }
        let manager: AsrManager
        do { manager = try await loading.value } catch {
            self.loading = nil
            isReady = false
            throw error
        }
        var state = TdtDecoderState.make()
        let t0 = Date()
        let (leveled, gainDB) = Level.normalize(samples)
        let result = try await manager.transcribe(leveled, decoderState: &state)
        log("transcribed \(String(format: "%.1f", Double(samples.count) / 16000)) s audio in \(ms(since: t0)) ms, gain \(String(format: "%+.1f", gainDB)) dB")
        return result
    }

    /// Drops every reference to the CoreML models so their memory is returned.
    func unload() async {
        guard let loading else { return }
        self.loading = nil
        generation += 1
        isReady = false
        if downloadFraction != nil { downloadFraction = nil }
        if let manager = try? await loading.value {
            await manager.cleanup()
        }
        log("model unloaded")
    }
}

func ms(since t: Date) -> Int { Int(Date().timeIntervalSince(t) * 1000) }

/// Set by `talk transcribe --quiet`.
nonisolated(unsafe) var quietLog = false

func log(_ s: String) {
    guard !quietLog else { return }
    FileHandle.standardError.write("[talk] \(s)\n".data(using: .utf8)!)
}

func residentMB() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
}

/// Physical footprint (what Activity Monitor shows as "Memory").
func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}
