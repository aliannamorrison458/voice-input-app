import Foundation

public struct Config: Codable {
    public enum TranscribeMode: String, Codable {
        case file
        case pcm
        case websocket
    }

    public var sttUrl: String
    public var language: String
    public var sampleRate: Double
    public var transcribeMode: TranscribeMode
    public var backend: String
    public var autoPaste: Bool
    public var soundEffect: Bool

    enum CodingKeys: String, CodingKey {
        case sttUrl, language, sampleRate, transcribeMode, backend, autoPaste, soundEffect
    }

    public init(
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

    public static let configDirURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".voice-input")
    public static let configFileURL = configDirURL.appendingPathComponent("config.json")

    public static let `default` = Config(
        sttUrl: "http://127.0.0.1:7700",
        language: "auto",
        sampleRate: 16000,
        transcribeMode: .file,
        backend: "sensevoice",
        autoPaste: true,
        soundEffect: true
    )

    public static func load() -> Config {
        do {
            try FileManager.default.createDirectory(at: configDirURL, withIntermediateDirectories: true)
        } catch {
            AppLogger.error("创建配置目录失败: \(error.localizedDescription)")
            save(Config.default)
            return Config.default
        }
        guard let data = try? Data(contentsOf: configFileURL) else {
            AppLogger.info("配置文件不存在，使用默认配置")
            save(Config.default)
            return Config.default
        }
        do {
            var cfg = try JSONDecoder().decode(Config.self, from: data)
            if cfg.sttUrl.isEmpty { cfg.sttUrl = Config.default.sttUrl }
            if cfg.language.isEmpty { cfg.language = Config.default.language }
            if cfg.backend.isEmpty { cfg.backend = Config.default.backend }
            return cfg
        } catch {
            AppLogger.error("配置文件解析失败: \(error.localizedDescription)，使用默认配置")
            save(Config.default)
            return Config.default
        }
    }

    public static func save(_ config: Config) {
        do {
            try FileManager.default.createDirectory(at: configDirURL, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(config)
            try data.write(to: configFileURL, options: .atomic)
        } catch {
            AppLogger.error("保存配置失败: \(error.localizedDescription)")
        }
    }

    public init(from decoder: Decoder) throws {
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
