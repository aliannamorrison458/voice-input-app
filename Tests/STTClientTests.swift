import XCTest
@testable import VoiceInputCore

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

    // MARK: - TranscribeResult Parsing

    func testParseMinimalResponse() {
        let json: [String: Any] = ["text": "你好世界"]
        let result = STTClient.TranscribeResult.from(json: json)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.text, "你好世界")
        XCTAssertNil(result?.originalText)
        XCTAssertNil(result?.segments)
    }

    func testParseFullResponse() {
        let json: [String: Any] = [
            "text": "你好世界",
            "original_text": "你好世界",
            "language": "zh",
            "duration_seconds": 3.5,
            "processing_seconds": 0.8,
            "correction_seconds": 0.3,
            "backend": "sensevoice",
            "ollama_model": "qwen2.5:3b",
            "segments": [
                ["start": 0.0, "end": 1.5, "text": "你好", "confidence": 0.95],
                ["start": 1.5, "end": 3.5, "text": "世界", "confidence": 0.92],
            ]
        ]
        let result = STTClient.TranscribeResult.from(json: json)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.text, "你好世界")
        XCTAssertEqual(result?.originalText, "你好世界")
        XCTAssertEqual(result?.language, "zh")
        XCTAssertEqual(result?.durationSeconds, 3.5)
        XCTAssertEqual(result?.processingSeconds, 0.8)
        XCTAssertEqual(result?.correctionSeconds, 0.3)
        XCTAssertEqual(result?.backend, "sensevoice")
        XCTAssertEqual(result?.ollamaModel, "qwen2.5:3b")
        XCTAssertEqual(result?.segments?.count, 2)
        XCTAssertEqual(result?.segments?[0].text, "你好")
        XCTAssertEqual(result?.segments?[0].start, 0.0)
        XCTAssertEqual(result?.segments?[0].end, 1.5)
        XCTAssertEqual(result?.segments?[0].confidence, 0.95)
    }

    func testParseOllamaCorrected() {
        // API docs: text = corrected, original_text = raw
        let json: [String: Any] = [
            "text": "Hello, world!",
            "original_text": "helloworld",
            "language": "en",
            "backend": "whisper_cpp",
            "ollama_model": "qwen2.5:3b",
            "correction_seconds": 0.2,
        ]
        let result = STTClient.TranscribeResult.from(json: json)
        XCTAssertEqual(result?.text, "Hello, world!")
        XCTAssertEqual(result?.originalText, "helloworld")
        XCTAssertEqual(result?.correctionSeconds, 0.2)
    }

    func testParseNoTextReturnsNil() {
        let json: [String: Any] = ["language": "zh"]
        let result = STTClient.TranscribeResult.from(json: json)
        XCTAssertNil(result)
    }

    func testParseSegmentsWithoutConfidence() {
        let json: [String: Any] = [
            "text": "测试",
            "segments": [
                ["start": 0.0, "end": 1.0, "text": "测试"]
            ]
        ]
        let result = STTClient.TranscribeResult.from(json: json)
        XCTAssertEqual(result?.segments?.count, 1)
        XCTAssertNil(result?.segments?[0].confidence)
    }

    func testParseMalformedSegmentSkipped() {
        let json: [String: Any] = [
            "text": "测试",
            "segments": [
                ["start": 0.0, "end": 1.0, "text": "ok"],
                ["start": "bad"],  // malformed
                ["text": "missing start/end"],
            ]
        ]
        let result = STTClient.TranscribeResult.from(json: json)
        XCTAssertEqual(result?.segments?.count, 1) // only the valid one
    }
}
