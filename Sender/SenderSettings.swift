import Foundation

enum DisplayMode: String, CaseIterable, Identifiable {
    case extend
    case mirror
    var id: String { rawValue }
}

/// What to give up first when the link can't carry full quality.
enum QualityPolicy: String, CaseIterable, Identifiable {
    case reduceFrameRate
    case reduceResolution
    case reduceQuality
    var id: String { rawValue }
}

/// Resolution of the virtual display in extend mode.
enum ResolutionPreset: String, CaseIterable, Identifiable {
    /// Looks like 2048 x 1152, rendered at 4096 x 2304 (same as the iMac's default).
    case retina2048
    /// Looks like 2304 x 1296, rendered at 4608 x 2592 and scaled to the iMac.
    case retina2304
    /// 4096 x 2304 at 1:1.
    case native4096

    var id: String { rawValue }

    var pointSize: (width: Int, height: Int) {
        switch self {
        case .retina2048: return (2048, 1152)
        case .retina2304: return (2304, 1296)
        case .native4096: return (4096, 2304)
        }
    }

    var pixelSize: (width: Int, height: Int) {
        switch self {
        case .retina2048: return (4096, 2304)
        case .retina2304: return (4608, 2592)
        case .native4096: return (4096, 2304)
        }
    }
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

    @Published var displayMode: DisplayMode { didSet { defaults.set(displayMode.rawValue, forKey: Keys.displayMode) } }
    @Published var resolutionPreset: ResolutionPreset { didSet { defaults.set(resolutionPreset.rawValue, forKey: Keys.resolutionPreset) } }
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
        static let displayMode = "displayMode"
        static let resolutionPreset = "resolutionPreset"
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
        displayMode = DisplayMode(rawValue: d.string(forKey: Keys.displayMode) ?? "") ?? .extend
        resolutionPreset = ResolutionPreset(rawValue: d.string(forKey: Keys.resolutionPreset) ?? "") ?? .retina2048
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
