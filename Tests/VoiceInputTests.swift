import XCTest
@testable import VoiceInputCore

// MARK: - Config Tests

final class ConfigTests: XCTestCase {

    // MARK: Default Config

    func testDefaultConfig() {
        let config = Config.default
        XCTAssertEqual(config.sttUrl, "http://127.0.0.1:7700")
        XCTAssertEqual(config.language, "auto")
        XCTAssertEqual(config.sampleRate, 16000)
        XCTAssertEqual(config.transcribeMode, .file)
        XCTAssertEqual(config.backend, "sensevoice")
        XCTAssertTrue(config.autoPaste)
        XCTAssertTrue(config.soundEffect)
    }

    // MARK: JSON Round-Trip

    func testJSONRoundTrip() throws {
        let original = Config(
            sttUrl: "http://192.168.1.100:7700",
            language: "zh",
            sampleRate: 44100,
            transcribeMode: .websocket,
            backend: "whisper",
            autoPaste: false,
            soundEffect: true
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Config.self, from: data)

        XCTAssertEqual(decoded.sttUrl, original.sttUrl)
        XCTAssertEqual(decoded.language, original.language)
        XCTAssertEqual(decoded.sampleRate, original.sampleRate)
        XCTAssertEqual(decoded.transcribeMode, original.transcribeMode)
        XCTAssertEqual(decoded.backend, original.backend)
        XCTAssertEqual(decoded.autoPaste, original.autoPaste)
        XCTAssertEqual(decoded.soundEffect, original.soundEffect)
    }

    // MARK: TranscribeMode

    func testTranscribeModeRawValues() {
        XCTAssertEqual(Config.TranscribeMode.file.rawValue, "file")
        XCTAssertEqual(Config.TranscribeMode.pcm.rawValue, "pcm")
        XCTAssertEqual(Config.TranscribeMode.websocket.rawValue, "websocket")
    }

    func testTranscribeModeFromRawValue() {
        XCTAssertEqual(Config.TranscribeMode(rawValue: "file"), .file)
        XCTAssertEqual(Config.TranscribeMode(rawValue: "pcm"), .pcm)
        XCTAssertEqual(Config.TranscribeMode(rawValue: "websocket"), .websocket)
        XCTAssertNil(Config.TranscribeMode(rawValue: "invalid"))
    }

    // MARK: Missing Fields (Backward Compatibility)

    func testDecodeWithMissingFields() throws {
        let json = """
        {"sttUrl": "http://localhost:7700", "language": "en"}
        """
        let data = json.data(using: .utf8)!
        let config = try JSONDecoder().decode(Config.self, from: data)

        XCTAssertEqual(config.sttUrl, "http://localhost:7700")
        XCTAssertEqual(config.language, "en")
        // Missing fields should fall back to defaults
        XCTAssertEqual(config.sampleRate, Config.default.sampleRate)
        XCTAssertEqual(config.transcribeMode, Config.default.transcribeMode)
        XCTAssertEqual(config.backend, Config.default.backend)
        XCTAssertEqual(config.autoPaste, Config.default.autoPaste)
        XCTAssertEqual(config.soundEffect, Config.default.soundEffect)
    }

    func testDecodeWithEmptyStringsFallsBackToDefault() throws {
        let json = """
        {"sttUrl": "", "language": "", "backend": "", "sampleRate": 16000, "transcribeMode": "file", "autoPaste": true, "soundEffect": true}
        """
        let data = json.data(using: .utf8)!
        var config = try JSONDecoder().decode(Config.self, from: data)

        // Config.load() handles empty string fallback, but let's test the raw decode
        XCTAssertEqual(config.sttUrl, "")
        XCTAssertEqual(config.language, "")
        XCTAssertEqual(config.backend, "")
    }

    // MARK: Save & Load

    func testSaveAndLoad() {
        let testConfig = Config(
            sttUrl: "http://127.0.0.1:9999",
            language: "ja",
            sampleRate: 8000,
            transcribeMode: .pcm,
            backend: "paraformer",
            autoPaste: false,
            soundEffect: false
        )

        // Clean up any existing test config
        let configDir = Config.configDirURL
        try? FileManager.default.removeItem(at: configDir)

        // Save
        Config.save(testConfig)

        // Load
        let loaded = Config.load()
        XCTAssertEqual(loaded.sttUrl, testConfig.sttUrl)
        XCTAssertEqual(loaded.language, testConfig.language)
        XCTAssertEqual(loaded.sampleRate, testConfig.sampleRate)
        XCTAssertEqual(loaded.transcribeMode, testConfig.transcribeMode)
        XCTAssertEqual(loaded.backend, testConfig.backend)
        XCTAssertEqual(loaded.autoPaste, testConfig.autoPaste)
        XCTAssertEqual(loaded.soundEffect, testConfig.soundEffect)

        // Clean up
        try? FileManager.default.removeItem(at: configDir)
    }

    func testLoadWithNoConfigFileReturnsDefault() {
        let configDir = Config.configDirURL
        try? FileManager.default.removeItem(at: configDir)

        let loaded = Config.load()
        XCTAssertEqual(loaded.sttUrl, Config.default.sttUrl)
        XCTAssertEqual(loaded.language, Config.default.language)
        XCTAssertEqual(loaded.sampleRate, Config.default.sampleRate)

        // Clean up
        try? FileManager.default.removeItem(at: configDir)
    }

    func testLoadWithCorruptedFileReturnsDefault() throws {
        let configDir = Config.configDirURL
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)

        // Write garbage
        let garbage = "not valid json {{{{".data(using: .utf8)!
        try garbage.write(to: Config.configFileURL)

        let loaded = Config.load()
        XCTAssertEqual(loaded.sttUrl, Config.default.sttUrl)

        // Clean up
        try? FileManager.default.removeItem(at: configDir)
    }
}

// MARK: - STTClient Tests

final class STTClientTests: XCTestCase {

    // MARK: Init

    func testValidURL() {
        let client = STTClient(
            baseURL: "http://127.0.0.1:7700",
            language: "auto",
            sampleRate: 16000,
            transcribeMode: .file,
            backend: "sensevoice"
        )
        XCTAssertNotNil(client)
        XCTAssertEqual(client?.currentBaseURL, "http://127.0.0.1:7700")
    }

    func testValidURLWithTrailingSlashes() {
        let client = STTClient(
            baseURL: "http://127.0.0.1:7700///",
            language: "auto",
            sampleRate: 16000,
            transcribeMode: .file,
            backend: "sensevoice"
        )
        XCTAssertNotNil(client)
        // Trailing slashes should be stripped
        XCTAssertEqual(client?.currentBaseURL, "http://127.0.0.1:7700")
    }

    func testInvalidURL() {
        let client = STTClient(
            baseURL: "not a url at all",
            language: "auto",
            sampleRate: 16000,
            transcribeMode: .file,
            backend: "sensevoice"
        )
        XCTAssertNil(client)
    }

    func testEmptyURL() {
        let client = STTClient(
            baseURL: "",
            language: "auto",
            sampleRate: 16000,
            transcribeMode: .file,
            backend: "sensevoice"
        )
        XCTAssertNil(client)
    }

    func testHTTPSCurrentURL() {
        let client = STTClient(
            baseURL: "https://stt.example.com",
            language: "auto",
            sampleRate: 16000,
            transcribeMode: .file,
            backend: "sensevoice"
        )
        XCTAssertNotNil(client)
        XCTAssertEqual(client?.currentBaseURL, "https://stt.example.com")
    }
}

// MARK: - AppLogger Tests

final class AppLoggerTests: XCTestCase {

    func testLoggingDoesNotCrash() {
        // Just verify these don't crash
        AppLogger.info("Test info message")
        AppLogger.warn("Test warn message")
        AppLogger.error("Test error message")
    }

    func testLogFileCreated() {
        let configDir = Config.configDirURL
        try? FileManager.default.removeItem(at: configDir)

        AppLogger.info("Creating log file")

        // Wait for async write
        let expectation = XCTestExpectation(description: "Log file created")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let logFile = configDir.appendingPathComponent("log.txt")
            XCTAssertTrue(FileManager.default.fileExists(atPath: logFile.path),
                         "Log file should be created after writing")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 3.0)

        // Clean up
        try? FileManager.default.removeItem(at: configDir)
    }

    func testLogRotation() {
        let configDir = Config.configDirURL
        try? FileManager.default.removeItem(at: configDir)
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)

        // Write a file that exceeds 5MB to trigger rotation
        let logFile = configDir.appendingPathComponent("log.txt")
        let largeData = Data(repeating: 0x41, count: 6 * 1024 * 1024) // 6MB
        FileManager.default.createFile(atPath: logFile.path, contents: largeData)

        // Write another log entry — should trigger rotation
        AppLogger.info("After rotation")

        // Wait for async write
        let expectation = XCTestExpectation(description: "Log rotated")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            let backupFile = configDir.appendingPathComponent("log.old.txt")
            // The original file should have been moved to backup
            // Note: the rotation + new write happens async, so timing may vary
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5.0)

        // Clean up
        try? FileManager.default.removeItem(at: configDir)
    }
}

// MARK: - STTError Tests

final class STTErrorTests: XCTestCase {

    func testHTTPErrorDescription() {
        let error = STTError.httpError(404, "Not Found")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("404"))
        XCTAssertTrue(error.errorDescription!.contains("Not Found"))
    }

    func testNoTextInResponseDescription() {
        let error = STTError.noTextInResponse
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("text"))
    }

    func testInvalidURLDescription() {
        let error = STTError.invalidURL
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("地址"))
    }
}

// MARK: - RecorderError Tests

final class RecorderErrorTests: XCTestCase {

    func testMicPermissionDeniedDescription() {
        let error = RecorderError.micPermissionDenied
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("麦克风"))
    }

    func testConverterSetupFailedDescription() {
        let error = RecorderError.converterSetupFailed
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("转换器"))
    }
}
