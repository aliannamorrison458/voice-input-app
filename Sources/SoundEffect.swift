import AppKit

enum SoundEffect {
    enum Sound: String {
        case start = "Tink"
        case stop = "Bottle"
        case error = "Basso"
        case success = "Glass"
    }

    static func play(_ sound: Sound) {
        NSSound(named: sound.rawValue)?.play()
    }
}
