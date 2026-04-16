import Foundation

/// HTTP client for the STT service (OpenAI-compatible /v1/audio/transcriptions).
public final class STTClient {
    public struct HealthCheckResult {
        public let isOnline: Bool
        public let reason: String
    }

    /// Rich STT response matching the API docs.
    public struct TranscribeResult {
        public let text: String
        public let originalText: String?
        public let language: String?
        public let durationSeconds: Double?
        public let processingSeconds: Double?
        public let correctionSeconds: Double?
        public let backend: String?
        public let ollamaModel: String?
        public let segments: [Segment]?

        public struct Segment {
            public let start: Double
            public let end: Double
            public let text: String
            public let confidence: Double?
        }

        /// Parse from API JSON response.
        static func from(json: [String: Any]) -> TranscribeResult? {
            guard let text = json["text"] as? String else { return nil }
            var segs: [Segment]?
            if let rawSegs = json["segments"] as? [[String: Any]] {
                segs = rawSegs.compactMap { s in
                    guard let start = s["start"] as? Double,
                          let end = s["end"] as? Double,
                          let text = s["text"] as? String else { return nil }
                    return Segment(start: start, end: end, text: text, confidence: s["confidence"] as? Double)
                }
            }
            return TranscribeResult(
                text: text,
                originalText: json["original_text"] as? String,
                language: json["language"] as? String,
                durationSeconds: json["duration_seconds"] as? Double,
                processingSeconds: json["processing_seconds"] as? Double,
                correctionSeconds: json["correction_seconds"] as? Double,
                backend: json["backend"] as? String,
                ollamaModel: json["ollama_model"] as? String,
                segments: segs
            )
        }
    }

    private let baseURL: URL
    private let language: String
    private let sampleRate: Double
    private let transcribeMode: Config.TranscribeMode
    private let backend: String

    /// Display-friendly URL string for UI
    public var currentBaseURL: String {
        baseURL.absoluteString
    }

    public init?(baseURL: String, language: String, sampleRate: Double, transcribeMode: Config.TranscribeMode, backend: String) {
        let cleaned = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: cleaned), url.scheme != nil else {
            AppLogger.error("无效的 STT URL: \(baseURL)")
            return nil
        }
        self.baseURL = url
        self.language = language
        self.sampleRate = sampleRate
        self.transcribeMode = transcribeMode
        self.backend = backend
    }

    // MARK: - Health Check

    public func healthCheck() async -> HealthCheckResult {
        let url = baseURL.appendingPathComponent("health")
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return HealthCheckResult(isOnline: false, reason: "响应不是 HTTP")
            }

            guard (200...299).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let suffix = body.isEmpty ? "" : " body=\(body.prefix(120))"
                return HealthCheckResult(isOnline: false, reason: "HTTP \(http.statusCode)\(suffix)")
            }

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if json?["status"] as? String == "ok" {
                let activeBackend = json?["active_backend"] as? String ?? "unknown"
                return HealthCheckResult(isOnline: true, reason: "status=ok, backend=\(activeBackend)")
            }

            let status = json?["status"] as? String ?? "missing"
            return HealthCheckResult(isOnline: false, reason: "status=\(status)")
        } catch let error as URLError where error.code == .timedOut {
            return HealthCheckResult(isOnline: false, reason: "健康检查超时 (>5s)")
        } catch let error as URLError {
            return HealthCheckResult(isOnline: false, reason: "网络错误(\(error.code.rawValue)): \(error.localizedDescription)")
        } catch {
            return HealthCheckResult(isOnline: false, reason: error.localizedDescription)
        }
    }

    // MARK: - Transcribe (returns text only)

    public func transcribe(audioData: Data, timeout: TimeInterval = 30, retries: Int = 2) async throws -> String {
        let result = try await transcribeWithDetails(audioData: audioData, timeout: timeout, retries: retries)
        return result.text
    }

    // MARK: - Transcribe (returns full result)

    public func transcribeWithDetails(audioData: Data, timeout: TimeInterval = 30, retries: Int = 2) async throws -> TranscribeResult {
        var lastError: Error?
        for attempt in 0...retries {
            if attempt > 0 {
                AppLogger.info("STT 重试第 \(attempt) 次")
                try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
            }
            do {
                let result: TranscribeResult
                switch transcribeMode {
                case .file:
                    result = try await transcribeByFile(audioData: audioData, timeout: timeout)
                case .pcm:
                    result = try await transcribeByPCM(audioData: audioData, timeout: timeout)
                case .websocket:
                    result = try await transcribeByWebSocket(audioData: audioData)
                }

                // Log processing details
                if let proc = result.processingSeconds {
                    AppLogger.info("STT 完成: backend=\(result.backend ?? "?"), 耗时=\(String(format: "%.2f", proc))s")
                }
                if let original = result.originalText, original != result.text {
                    AppLogger.info("Ollama 校正: \"\(original.prefix(50))\" → \"\(result.text.prefix(50))\"")
                }
                return result
            } catch {
                lastError = error
                let isRetryable = error is URLError
                if !isRetryable { throw error }
                AppLogger.warn("STT 请求失败 (尝试 \(attempt + 1)/\(retries + 1)): \(error.localizedDescription)")
            }
        }
        throw lastError ?? STTError.noTextInResponse
    }

    // MARK: - File Upload Mode

    private func transcribeByFile(audioData: Data, timeout: TimeInterval) async throws -> TranscribeResult {
        let wav = wavData(from: audioData)
        return try await transcribeByMultipart(
            path: "v1/audio/transcriptions",
            fileName: "audio.wav",
            mimeType: "audio/wav",
            fileData: wav,
            extraFormFields: [
                ("model", "whisper-1"),
                ("language", language),
                ("response_format", "json"),
                ("backend", backend),
            ],
            timeout: timeout
        )
    }

    // MARK: - PCM Mode

    private func transcribeByPCM(audioData: Data, timeout: TimeInterval) async throws -> TranscribeResult {
        return try await transcribeByMultipart(
            path: "v1/transcribe/pcm",
            fileName: "audio.pcm",
            mimeType: "application/octet-stream",
            fileData: audioData,
            extraFormFields: [
                ("sample_rate", String(Int(sampleRate))),
                ("language", language),
                ("backend", backend),
            ],
            timeout: timeout
        )
    }

    // MARK: - Multipart Request

    private func transcribeByMultipart(
        path: String,
        fileName: String,
        mimeType: String,
        fileData: Data,
        extraFormFields: [(String, String)],
        timeout: TimeInterval
    ) async throws -> TranscribeResult {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)

        for (key, value) in extraFormFields {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".data(using: .utf8)!)
            body.append(value.data(using: .utf8)!)
            body.append("\r\n".data(using: .utf8)!)
        }

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw STTError.httpError(code, String(data: data, encoding: .utf8) ?? "")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let result = TranscribeResult.from(json: json ?? [:]) else {
            throw STTError.noTextInResponse
        }
        return result
    }

    // MARK: - WebSocket Mode

    private func transcribeByWebSocket(audioData: Data) async throws -> TranscribeResult {
        guard let wsBase = websocketURL() else {
            throw STTError.invalidURL
        }
        let wsURL = wsBase.appendingPathComponent("v1/stream")
        let task = URLSession.shared.webSocketTask(with: wsURL)
        task.resume()
        defer {
            task.cancel(with: .normalClosure, reason: nil)
        }

        // Send config
        let config: [String: Any] = [
            "action": "config",
            "language": language,
            "sample_rate": Int(sampleRate),
            "backend": backend,
        ]
        let configData = try JSONSerialization.data(withJSONObject: config)
        try await task.send(.string(String(data: configData, encoding: .utf8) ?? "{}"))

        // Wait for config_ok
        let configAck = try await task.receive()
        if case .string(let ackText) = configAck {
            if let ackData = ackText.data(using: .utf8),
               let ackJson = try? JSONSerialization.jsonObject(with: ackData) as? [String: Any],
               let type = ackJson["type"] as? String {
                if type == "error" {
                    let msg = ackJson["message"] as? String ?? "unknown"
                    throw STTError.httpError(0, "WebSocket config error: \(msg)")
                }
                if type != "config_ok" {
                    AppLogger.warn("WebSocket unexpected ack: \(type)")
                }
            }
        }

        // Send audio and end
        try await task.send(.data(audioData))
        try await task.send(.string("{\"action\":\"end\"}"))

        // Receive results
        while true {
            let message = try await task.receive()
            switch message {
            case .string(let text):
                if let result = parseWebSocketMessage(text) { return result }
            case .data(let data):
                if let text = String(data: data, encoding: .utf8),
                   let result = parseWebSocketMessage(text) { return result }
            @unknown default:
                continue
            }
        }
    }

    private func parseWebSocketMessage(_ message: String) -> TranscribeResult? {
        guard let data = message.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return nil
        }

        if type == "final" {
            return TranscribeResult.from(json: json)
        }
        if type == "error" {
            // Will be handled as throw in the caller
            return nil
        }
        // chunk_ok, config_ok, reset_ok — ignore
        return nil
    }

    // MARK: - Helpers

    private func websocketURL() -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        return components.url
    }

    /// Wrap raw PCM data in a WAV container.
    private func wavData(from pcm: Data) -> Data {
        let sr: UInt32 = UInt32(sampleRate)
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = sr * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = UInt32(pcm.count)

        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        data.append(littleEndian: UInt32(36 + dataSize))
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        data.append(littleEndian: UInt32(16))
        data.append(littleEndian: UInt16(1))
        data.append(littleEndian: channels)
        data.append(littleEndian: sr)
        data.append(littleEndian: byteRate)
        data.append(littleEndian: blockAlign)
        data.append(littleEndian: bitsPerSample)
        data.append(contentsOf: "data".utf8)
        data.append(littleEndian: dataSize)
        data.append(pcm)
        return data
    }
}

public enum STTError: LocalizedError {
    case httpError(Int, String)
    case noTextInResponse
    case invalidURL

    public var errorDescription: String? {
        switch self {
        case .httpError(let code, let msg):
            return "STT 请求失败 (HTTP \(code)): \(msg)"
        case .noTextInResponse:
            return "STT 响应中没有 text 字段"
        case .invalidURL:
            return "STT 服务地址无效"
        }
    }
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        var v = value.littleEndian
        withUnsafePointer(to: &v) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout<T>.size) { bytes in
                append(bytes, count: MemoryLayout<T>.size)
            }
        }
    }
}
