import Foundation

/// What to give up first when the link can't carry full quality.
enum QualityPolicy: String, CaseIterable, Identifiable {
    case reduceFrameRate
    case reduceResolution
    case reduceQuality
    var id: String { rawValue }
}

enum CodecPreference: String, CaseIterable, Identifiable {
    case automatic
    case h264
    case hevc
    var id: String { rawValue }
}

/// User settings of the Mac app, persisted in UserDefaults.
final class SenderSettings: ObservableObject {
    static let shared = SenderSettings()

    private let defaults = UserDefaults.standard

    @Published var qualityPolicy: QualityPolicy { didSet { defaults.set(qualityPolicy.rawValue, forKey: Keys.qualityPolicy) } }
    @Published var maxFrameRate: Int { didSet { defaults.set(maxFrameRate, forKey: Keys.maxFrameRate) } }
    @Published var maxBitrateMbps: Double { didSet { defaults.set(maxBitrateMbps, forKey: Keys.maxBitrateMbps) } }
    @Published var codec: CodecPreference { didSet { defaults.set(codec.rawValue, forKey: Keys.codec) } }
    @Published var audioEnabled: Bool { didSet { defaults.set(audioEnabled, forKey: Keys.audioEnabled) } }
    @Published var inputEnabled: Bool { didSet { defaults.set(inputEnabled, forKey: Keys.inputEnabled) } }
    @Published var autoConnect: Bool { didSet { defaults.set(autoConnect, forKey: Keys.autoConnect) } }

    var lastReceiverID: String? {
        get { defaults.string(forKey: Keys.lastReceiverID) }
        set { defaults.set(newValue, forKey: Keys.lastReceiverID) }
    }

    /// Stable identity of this Mac, used for pairing.
    let senderID: String

    private enum Keys {
        static let qualityPolicy = "qualityPolicy"
        static let maxFrameRate = "maxFrameRate"
        static let maxBitrateMbps = "maxBitrateMbps"
        static let codec = "codec"
        static let audioEnabled = "audioEnabled"
        static let inputEnabled = "inputEnabled"
        static let autoConnect = "autoConnect"
        static let lastReceiverID = "lastReceiverID"
        static let senderID = "senderID"
    }

    private init() {
        let d = UserDefaults.standard
        qualityPolicy = QualityPolicy(rawValue: d.string(forKey: Keys.qualityPolicy) ?? "") ?? .reduceFrameRate
        let storedFPS = d.integer(forKey: Keys.maxFrameRate)
        maxFrameRate = [30, 45, 60].contains(storedFPS) ? storedFPS : 60
        let storedBitrate = d.double(forKey: Keys.maxBitrateMbps)
        maxBitrateMbps = storedBitrate >= 5 ? storedBitrate : 40
        codec = CodecPreference(rawValue: d.string(forKey: Keys.codec) ?? "") ?? .automatic
        audioEnabled = d.object(forKey: Keys.audioEnabled) as? Bool ?? true
        inputEnabled = d.object(forKey: Keys.inputEnabled) as? Bool ?? true
        autoConnect = d.object(forKey: Keys.autoConnect) as? Bool ?? true
        if let stored = d.string(forKey: Keys.senderID) {
            senderID = stored
        } else {
            let created = UUID().uuidString
            d.set(created, forKey: Keys.senderID)
            senderID = created
        }
    }
}

/// Tokens received from paired iMacs, keyed by receiver ID.
enum PairingStore {
    private static let key = "pairingTokens"

    static func token(for receiverID: String) -> String? {
        tokens[receiverID]
    }

    static func set(_ token: String, for receiverID: String) {
        var all = tokens
        all[receiverID] = token
        tokens = all
    }

    static func removeAll() {
        tokens = [:]
    }

    private static var tokens: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
