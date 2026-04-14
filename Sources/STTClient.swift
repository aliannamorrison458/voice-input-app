import Foundation

/// HTTP client for the STT service (OpenAI-compatible /v1/audio/transcriptions).
final class STTClient {
    struct HealthCheckResult {
        let isOnline: Bool
        let reason: String
    }

    private let baseURL: URL
    private let language: String
    private let sampleRate: Double
    private let transcribeMode: Config.TranscribeMode
    private let backend: String

    init(baseURL: String, language: String, sampleRate: Double, transcribeMode: Config.TranscribeMode, backend: String) {
        self.baseURL = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")))!
        self.language = language
        self.sampleRate = sampleRate
        self.transcribeMode = transcribeMode
        self.backend = backend
    }

    func healthCheck() async -> HealthCheckResult {
        let url = baseURL.appendingPathComponent("health")
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
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
                return HealthCheckResult(isOnline: true, reason: "status=ok")
            }

            let status = json?["status"] as? String ?? "missing"
            return HealthCheckResult(isOnline: false, reason: "status=\(status)")
        } catch let error as URLError {
            return HealthCheckResult(isOnline: false, reason: "网络错误(\(error.code.rawValue)): \(error.localizedDescription)")
        } catch {
            return HealthCheckResult(isOnline: false, reason: error.localizedDescription)
        }
    }

    func transcribe(audioData: Data, timeout: TimeInterval = 30) async throws -> String {
        switch transcribeMode {
        case .file:
            return try await transcribeByFile(audioData: audioData, timeout: timeout)
        case .pcm:
            return try await transcribeByPCM(audioData: audioData, timeout: timeout)
        case .websocket:
            return try await transcribeByWebSocket(audioData: audioData)
        }
    }

    private func transcribeByFile(audioData: Data, timeout: TimeInterval) async throws -> String {
        let wav = wavData(from: audioData)
        return try await transcribeByMultipart(
            path: "v1/audio/transcriptions",
            fileName: "audio.wav",
            mimeType: "audio/wav",
            fileData: wav,
            extraFormFields: [
                ("language", language),
                ("backend", backend),
            ],
            timeout: timeout
        )
    }

    private func transcribeByPCM(audioData: Data, timeout: TimeInterval) async throws -> String {
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

    private func transcribeByMultipart(
        path: String,
        fileName: String,
        mimeType: String,
        fileData: Data,
        extraFormFields: [(String, String)],
        timeout: TimeInterval
    ) async throws -> String {
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
        guard let text = json?["text"] as? String else {
            throw STTError.noTextInResponse
        }
        return text
    }

    private func transcribeByWebSocket(audioData: Data) async throws -> String {
        let wsURL = websocketURL().appendingPathComponent("v1/stream")
        let task = URLSession.shared.webSocketTask(with: wsURL)
        task.resume()
        defer {
            task.cancel(with: .normalClosure, reason: nil)
        }

        let config: [String: Any] = [
            "action": "config",
            "language": language,
            "sample_rate": Int(sampleRate),
            "backend": backend,
        ]
        let configData = try JSONSerialization.data(withJSONObject: config)
        try await task.send(.string(String(data: configData, encoding: .utf8) ?? "{}"))
        try await task.send(.data(audioData))
        try await task.send(.string("{\"action\":\"end\"}"))

        while true {
            let message = try await task.receive()
            switch message {
            case .string(let text):
                if let finalText = parseFinalText(from: text) {
                    return finalText
                }
            case .data(let data):
                if let text = String(data: data, encoding: .utf8),
                   let finalText = parseFinalText(from: text) {
                    return finalText
                }
            @unknown default:
                continue
            }
        }
    }

    private func parseFinalText(from message: String) -> String? {
        guard let data = message.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String,
              type == "final",
              let text = json["text"] as? String else {
            return nil
        }
        return text
    }

    private func websocketURL() -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        return components.url!
    }

    /// Wrap raw PCM data in a WAV container.
    private func wavData(from pcm: Data) -> Data {
        let sampleRate: UInt32 = 16000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = UInt32(pcm.count)

        var data = Data()
        // RIFF header
        data.append(contentsOf: "RIFF".utf8)
        data.append(littleEndian: UInt32(36 + dataSize))
        data.append(contentsOf: "WAVE".utf8)
        // fmt chunk
        data.append(contentsOf: "fmt ".utf8)
        data.append(littleEndian: UInt32(16)) // chunk size
        data.append(littleEndian: UInt16(1))  // PCM
        data.append(littleEndian: channels)
        data.append(littleEndian: sampleRate)
        data.append(littleEndian: byteRate)
        data.append(littleEndian: blockAlign)
        data.append(littleEndian: bitsPerSample)
        // data chunk
        data.append(contentsOf: "data".utf8)
        data.append(littleEndian: dataSize)
        data.append(pcm)
        return data
    }
}

enum STTError: LocalizedError {
    case httpError(Int, String)
    case noTextInResponse

    var errorDescription: String? {
        switch self {
        case .httpError(let code, let msg):
            return "STT 请求失败 (HTTP \(code)): \(msg)"
        case .noTextInResponse:
            return "STT 响应中没有 text 字段"
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
