import AVFoundation
import Foundation

/// Records audio from the default input device using AVAudioEngine.
final class AudioRecorder {
    private let sampleRate: Double
    private var engine: AVAudioEngine?
    private var audioBuffer = Data()
    private var recording = false
    private let lock = NSLock()

    init(sampleRate: Double = 16000) {
        self.sampleRate = sampleRate
    }

    func start() throws {
        // Request mic permission
        let sem = DispatchSemaphore(value: 0)
        var granted = false
        if #available(macOS 14, *) {
            AVAudioApplication.requestRecordPermission { ok in
                granted = ok
                sem.signal()
            }
        } else {
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                granted = ok
                sem.signal()
            }
        }
        sem.wait()
        guard granted else {
            throw RecorderError.micPermissionDenied
        }

        lock.lock()
        audioBuffer = Data()
        recording = true
        lock.unlock()

        let engine = AVAudioEngine()
        self.engine = engine

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        // Convert to 16kHz mono int16
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
                self.audioBuffer.append(Data(bytes: bytes.baseAddress!, count: frameLength * 2))
                self.lock.unlock()
            }
        }

        engine.prepare()
        try engine.start()
    }

    func stop() -> Data? {
        recording = false
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil

        lock.lock()
        let data = audioBuffer.isEmpty ? nil : audioBuffer
        audioBuffer = Data()
        lock.unlock()
        return data
    }
}

enum RecorderError: LocalizedError {
    case micPermissionDenied
    case converterSetupFailed

    var errorDescription: String? {
        switch self {
        case .micPermissionDenied:
            return "麦克风权限被拒绝，请在系统设置 → 隐私与安全 → 麦克风中授权"
        case .converterSetupFailed:
            return "音频转换器初始化失败"
        }
    }
}
