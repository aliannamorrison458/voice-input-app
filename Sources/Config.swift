import Foundation

struct Config: Codable {
    var sttUrl: String
    var language: String
    var sampleRate: Double
    var autoPaste: Bool
    var soundEffect: Bool

    static let configDirURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".voice-input")
    static let configFileURL = configDirURL.appendingPathComponent("config.json")

    static let `default` = Config(
        sttUrl: "http://192.168.8.195:7700",
        language: "auto",
        sampleRate: 16000,
        autoPaste: true,
        soundEffect: true
    )

    static func load() -> Config {
        try? FileManager.default.createDirectory(at: configDirURL, withIntermediateDirectories: true)
        guard let data = try? Data(contentsOf: configFileURL),
              var cfg = try? JSONDecoder().decode(Config.self, from: data) else {
            save(Config.default)
            return Config.default
        }
        // Fill defaults for missing keys
        if cfg.sttUrl.isEmpty { cfg.sttUrl = Config.default.sttUrl }
        if cfg.language.isEmpty { cfg.language = Config.default.language }
        return cfg
    }

    static func save(_ config: Config) {
        try? FileManager.default.createDirectory(at: configDirURL, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(config) {
            try? data.write(to: configFileURL, options: .atomic)
        }
    }
}
