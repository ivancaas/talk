import Foundation

/// `~/.config/talk/config.json`. The Settings window edits the same file.
struct Config: Codable, Equatable {
    var hotkey: String = "opt+space"
    /// "bottom" or "top"
    var pill: String = "bottom"
    /// Seconds to keep the model after a dictation (0 = unload right away).
    var unloadAfterSeconds: Double = 0

    init() {}

    /// Missing keys fall back to defaults, so older config files keep working.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey) ?? hotkey
        pill = try c.decodeIfPresent(String.self, forKey: .pill) ?? pill
        unloadAfterSeconds = try c.decodeIfPresent(Double.self, forKey: .unloadAfterSeconds) ?? unloadAfterSeconds
    }

    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/talk/config.json")

    /// Why the file on disk was not used (nil when it loaded). Talk runs on defaults meanwhile and
    /// leaves the file alone; Setup and Settings show this text.
    @MainActor static var loadError: String?

    @MainActor static func load() -> Config {
        loadError = nil
        guard FileManager.default.fileExists(atPath: url.path) else {
            let c = Config()
            try? c.save()
            return c
        }
        do {
            return try decode(try Data(contentsOf: url))
        } catch {
            loadError = describe(error)
            log("config: \(loadError ?? "") (\(url.path)); using defaults")
            return Config()
        }
    }

    static func decode(_ data: Data) throws -> Config {
        try JSONDecoder().decode(Config.self, from: data)
    }

    func save() throws {
        try FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: Self.url, options: .atomic)
    }

    /// Moves an unreadable file aside (config.json.bak) and writes the defaults.
    @MainActor static func resetToDefaults() throws -> Config {
        let backup = url.appendingPathExtension("bak")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: url, to: backup)
        let c = Config()
        try c.save()
        loadError = nil
        return c
    }

    /// One short sentence a person can act on.
    static func describe(_ error: Error) -> String {
        guard let e = error as? DecodingError else { return error.localizedDescription }
        switch e {
        case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx):
            let key = ctx.codingPath.last?.stringValue
            return key.map { "“\($0)” has the wrong type" } ?? "The file must hold one JSON object"
        case .dataCorrupted(let ctx):
            let detail = (ctx.underlyingError as NSError?)?.userInfo[NSDebugDescriptionErrorKey] as? String
            let trimmed = detail?.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            return "Not valid JSON" + (trimmed.map { ": \($0)" } ?? "")
        default:
            return "Not valid JSON"
        }
    }
}
