import FluidAudio
import Foundation

/// Parakeet TDT v3 on the Neural Engine. Loaded on demand, released after use.
@MainActor
final class Engine {
    /// Talk keeps its own copy of the model files, separate from other apps that use FluidAudio.
    static var modelsDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = AsrModels.defaultCacheDirectory(for: .v3).lastPathComponent
        return base.appendingPathComponent("Talk/Models/\(folder)", isDirectory: true)
    }

    private var loading: Task<AsrManager, Error>?

    /// True once the model is in memory (not just loading).
    private(set) var isReady = false

    /// Starts loading in the background (call when recording starts so load overlaps speech).
    func prepare() {
        guard loading == nil else { return }
        loading = Task {
            let t0 = Date()
            // int8V2 on the Neural Engine: measured best of the FluidAudio options (palettized .int8 doubles
            // noisy-Spanish errors; CPU fp32 is ~2 points better there but much slower).
            let models = try await AsrModels.downloadAndLoad(
                to: Self.modelsDir, version: .v3, encoderPrecision: .int8V2)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            self.isReady = true
            log("model loaded in \(ms(since: t0)) ms from \(Self.modelsDir.path)")
            return manager
        }
    }

    /// Waits until the model is ready (returns at once when it is already loaded).
    func waitUntilLoaded() async throws {
        _ = try await loading?.value
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        prepare()
        guard let loading else { return "" }
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
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Drops every reference to the CoreML models so their memory is returned.
    func unload() async {
        guard let loading else { return }
        self.loading = nil
        isReady = false
        if let manager = try? await loading.value {
            await manager.cleanup()
        }
        log("model unloaded")
    }
}

func ms(since t: Date) -> Int { Int(Date().timeIntervalSince(t) * 1000) }

func log(_ s: String) {
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
