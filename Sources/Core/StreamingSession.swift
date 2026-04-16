import Foundation

/// Real-time WebSocket streaming session for STT.
///
/// Protocol (matching voice-test H5):
///   1. Connect to ws://host:port/v1/stream
///   2. Send JSON config: {"action":"config","language":"...","sample_rate":N,"backend":"..."}
///   3. Receive {"type":"config_ok"}
///   4. Stream binary PCM Int16 chunks via sendAudioChunk(_:)
///   5. Receive {"type":"final","text":"..."} transcription results (may arrive at any time)
///   6. Send {"action":"end"} when recording stops
///   7. Final {"type":"final","text":"..."} arrives with remaining audio
///
/// Usage:
///   let session = sttClient.createStreamingSession()
///   session.onResult = { text in print(text) }
///   try await session.connect()
///   // During recording:
///   recorder.onPCMChunk = { chunk in session.sendAudioChunk(chunk) }
///   // After recording:
///   let finalText = try await session.finalize()
public final class StreamingSession: NSObject, URLSessionWebSocketDelegate {
    private let wsURL: URL
    private let configMsg: String

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var isConnected = false
    private var isConfigured = false

    /// Accumulated transcription text from all "final" messages.
    private var transcriptBuffer = ""
    /// Continuation for finalize() awaiting connection close.
    private var finalizeContinuation: CheckedContinuation<String, Error>?
    /// Continuation for connect() awaiting config_ok.
    private var connectContinuation: CheckedContinuation<Void, Error>?

    /// Called on every "final" transcription result as it arrives (real-time).
    public var onResult: ((String) -> Void)?
    /// Called on connection state changes.
    public var onConnectionChange: ((Bool) -> Void)?
    /// Called on error.
    public var onError: ((String) -> Void)?

    init(wsURL: URL?, language: String, sampleRate: Int, backend: String) {
        self.wsURL = wsURL ?? URL(string: "ws://127.0.0.1:7701/v1/stream")!
        let config: [String: Any] = [
            "action": "config",
            "language": language,
            "sample_rate": sampleRate,
            "backend": backend,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: config),
           let str = String(data: data, encoding: .utf8) {
            self.configMsg = str
        } else {
            self.configMsg = "{\"action\":\"config\",\"language\":\"auto\",\"sample_rate\":16000}"
        }
        super.init()
    }

    // MARK: - Connection

    /// Connect and send config. Suspends until config_ok is received.
    public func connect() async throws {
        guard !isConnected else { return }
        transcriptBuffer = ""

        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        task = session?.webSocketTask(with: wsURL)
        task?.resume()

        // Wait for config_ok via delegate
        return try await withCheckedThrowingContinuation { cont in
            self.connectContinuation = cont
        }
    }

    /// Send a raw PCM chunk over the WebSocket.
    public func sendAudioChunk(_ data: Data) {
        guard isConnected, isConfigured, let task else { return }
        task.send(.data(data)) { [weak self] error in
            if let error {
                AppLogger.warn("WebSocket send chunk failed: \(error.localizedDescription)")
            }
        }
    }

    /// Send end signal and wait for final transcription result.
    /// Suspends until the server sends the final result and closes the connection.
    public func finalize() async throws -> String {
        guard isConnected, let task else {
            return transcriptBuffer
        }

        // Send end signal
        try? await task.send(.string("{\"action\":\"end\"}"))

        // Wait for connection close (which means server is done sending)
        return try await withCheckedThrowingContinuation { cont in
            self.finalizeContinuation = cont
            // Send a ping to keep the connection alive while we wait
            task.sendPing { _ in }
        }
    }

    /// Force disconnect without waiting.
    public func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        task = nil
        session = nil
        if isConnected {
            isConnected = false
            isConfigured = false
            onConnectionChange?(false)
        }
        // Resume any pending continuations
        connectContinuation?.resume(throwing: STTError.httpError(0, "WebSocket disconnected"))
        connectContinuation = nil
        finalizeContinuation?.resume(returning: transcriptBuffer)
        finalizeContinuation = nil
    }

    // MARK: - URLSessionWebSocketDelegate

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didOpenWithProtocol protocol: String?) {
        AppLogger.info("WebSocket streaming session opened")
        isConnected = true
        onConnectionChange?(true)

        // Send config immediately
        webSocketTask.send(.string(configMsg)) { [weak self] error in
            if let error {
                self?.handleError("发送配置失败: \(error.localizedDescription)")
            }
        }

        // Start receiving messages
        receiveMessage()
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        AppLogger.info("WebSocket streaming session closed: \(closeCode)")
        isConnected = false
        isConfigured = false
        onConnectionChange?(false)

        // Resume finalize continuation with accumulated text
        finalizeContinuation?.resume(returning: transcriptBuffer)
        finalizeContinuation = nil
    }

    // Note: must use URLSessionTask (not URLSessionWebSocketTask) to match protocol signature
    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           didCompleteWithError error: Error?) {
        if let error {
            AppLogger.error("WebSocket streaming error: \(error.localizedDescription)")
            handleError("连接错误: \(error.localizedDescription)")
        }
    }

    // MARK: - Receive Loop

    private func receiveMessage() {
        guard let task, isConnected else { return }

        task.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                self.handleMessage(message)
                self.receiveMessage() // Continue loop

            case .failure(let error):
                if self.isConnected { // Only log if unexpected
                    AppLogger.error("WebSocket receive failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        var text: String?
        switch message {
        case .string(let str): text = str
        case .data(let data): text = String(data: data, encoding: .utf8)
        @unknown default: break
        }

        guard let text, !text.isEmpty else { return }

        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }

        switch type {
        case "config_ok":
            AppLogger.info("WebSocket streaming config accepted")
            isConfigured = true
            connectContinuation?.resume(returning: ())
            connectContinuation = nil

        case "final":
            let transcription = json["text"] as? String ?? ""
            if !transcription.isEmpty {
                transcriptBuffer += transcription
                AppLogger.info("Streaming transcription: \(transcription.prefix(50))")
                onResult?(transcription)
            }

        case "error":
            let msg = json["message"] as? String ?? "unknown"
            AppLogger.error("WebSocket server error: \(msg)")
            connectContinuation?.resume(throwing: STTError.httpError(0, "WebSocket error: \(msg)"))
            connectContinuation = nil
            onError?(msg)

        default:
            // chunk_ok, reset_ok, etc. — ignore
            break
        }
    }

    // MARK: - Helpers

    private func handleError(_ message: String) {
        isConnected = false
        isConfigured = false
        onConnectionChange?(false)
        onError?(message)
        connectContinuation?.resume(throwing: STTError.httpError(0, message))
        connectContinuation = nil
    }
}
