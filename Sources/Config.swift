import Foundation

struct Config: Codable {
    enum TranscribeMode: String, Codable {
        case file
        case pcm
        case websocket
    }

    var sttUrl: String
    var language: String
    var sampleRate: Double
    var transcribeMode: TranscribeMode
    var backend: String
    var autoPaste: Bool
    var soundEffect: Bool

    enum CodingKeys: String, CodingKey {
        case sttUrl, language, sampleRate, transcribeMode, backend, autoPaste, soundEffect
    }

    init(
        sttUrl: String,
        language: String,
        sampleRate: Double,
        transcribeMode: TranscribeMode,
        backend: String,
        autoPaste: Bool,
        soundEffect: Bool
    ) {
        self.sttUrl = sttUrl
        self.language = language
        self.sampleRate = sampleRate
        self.transcribeMode = transcribeMode
        self.backend = backend
        self.autoPaste = autoPaste
        self.soundEffect = soundEffect
    }

    static let configDirURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".voice-input")
    static let configFileURL = configDirURL.appendingPathComponent("config.json")

    static let `default` = Config(
        sttUrl: "http://192.168.8.195:7700",
        language: "auto",
        sampleRate: 16000,
        transcribeMode: .file,
        backend: "sensevoice",
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
        if cfg.backend.isEmpty { cfg.backend = Config.default.backend }
        return cfg
    }

    static func save(_ config: Config) {
        try? FileManager.default.createDirectory(at: configDirURL, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(config) {
            try? data.write(to: configFileURL, options: .atomic)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.sttUrl = try container.decodeIfPresent(String.self, forKey: .sttUrl) ?? Config.default.sttUrl
        self.language = try container.decodeIfPresent(String.self, forKey: .language) ?? Config.default.language
        self.sampleRate = try container.decodeIfPresent(Double.self, forKey: .sampleRate) ?? Config.default.sampleRate
        self.transcribeMode = try container.decodeIfPresent(TranscribeMode.self, forKey: .transcribeMode) ?? Config.default.transcribeMode
        self.backend = try container.decodeIfPresent(String.self, forKey: .backend) ?? Config.default.backend
        self.autoPaste = try container.decodeIfPresent(Bool.self, forKey: .autoPaste) ?? Config.default.autoPaste
        self.soundEffect = try container.decodeIfPresent(Bool.self, forKey: .soundEffect) ?? Config.default.soundEffect
    }
}
