import AVFoundation
import Foundation

/// Records audio from the default input device using AVAudioEngine.
public final class AudioRecorder {
    private let sampleRate: Double
    private var engine: AVAudioEngine?
    private var audioBuffer = Data()
    private var recording = false
    private let lock = NSLock()

    /// Max buffer: 5 minutes of 16kHz mono Int16
    private let maxBufferSize: Int

    public init(sampleRate: Double = 16000) {
        self.sampleRate = sampleRate
        self.maxBufferSize = Int(sampleRate) * 2 * 300
    }

    public func start() throws {
        try ensureMicPermission()

        lock.lock()
        audioBuffer = Data()
        recording = true
        lock.unlock()

        let engine = AVAudioEngine()
        self.engine = engine

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        guard let converter = AVAudioConverter(from: format, to: AVAudioFormat(commonFormat: .pcmFormatInt16,
                                                                                sampleRate: sampleRate,
                                                                                channels: 1,
                                                                                interleaved: true)!) else {
            throw RecorderError.converterSetupFailed
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, self.recording else { return }

            let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                             sampleRate: self.sampleRate,
                                             channels: 1,
                                             interleaved: true)!
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                                         frameCapacity: AVAudioFrameCount(buffer.frameLength)) else {
                return
            }

            var error: NSError?
            converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }

            if error == nil, let channelData = convertedBuffer.int16ChannelData {
                let frameLength = Int(convertedBuffer.frameLength)
                let bytes = UnsafeBufferPointer(start: channelData[0], count: frameLength)
                self.lock.lock()
                if self.audioBuffer.count + frameLength * 2 <= self.maxBufferSize {
                    self.audioBuffer.append(Data(bytes: bytes.baseAddress!, count: frameLength * 2))
                }
                self.lock.unlock()
            }
        }

        engine.prepare()
        try engine.start()
    }

    public func stop() -> Data? {
        recording = false
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil

        lock.lock()
        let data = audioBuffer.isEmpty ? nil : audioBuffer
        let durationMs = data != nil ? Double(audioBuffer.count) / (sampleRate * 2.0) * 1000.0 : 0
        audioBuffer = Data()
        lock.unlock()

        if let data = data {
            AppLogger.info("录音停止, \(data.count) 字节, \(Int(durationMs))ms")
        }
        return data
    }

    private func ensureMicPermission() throws {
        if #available(macOS 14, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted: return
            case .denied: throw RecorderError.micPermissionDenied
            case .undetermined:
                let sem = DispatchSemaphore(value: 0)
                var granted = false
                AVAudioApplication.requestRecordPermission { ok in granted = ok; sem.signal() }
                sem.wait()
                guard granted else { throw RecorderError.micPermissionDenied }
            @unknown default: throw RecorderError.micPermissionDenied
            }
        } else {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return
            case .denied, .restricted: throw RecorderError.micPermissionDenied
            case .notDetermined:
                let sem = DispatchSemaphore(value: 0)
                var granted = false
                AVCaptureDevice.requestAccess(for: .audio) { ok in granted = ok; sem.signal() }
                sem.wait()
                guard granted else { throw RecorderError.micPermissionDenied }
            @unknown default: throw RecorderError.micPermissionDenied
            }
        }
    }
}

public enum RecorderError: LocalizedError {
    case micPermissionDenied
    case converterSetupFailed

    public var errorDescription: String? {
        switch self {
        case .micPermissionDenied:
            return "麦克风权限被拒绝，请在系统设置 → 隐私与安全 → 麦克风中授权"
        case .converterSetupFailed:
            return "音频转换器初始化失败"
        }
    }
}
