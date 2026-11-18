import Foundation

/// Constants shared by the sender (Mac) and the receiver (iMac).
enum IMD {
    /// Bonjour service type advertised by the receiver.
    static let serviceType = "_imacdisplay._tcp"
    /// Bumped whenever the wire format changes in an incompatible way.
    static let protocolVersion = 1
    /// Upper bound for a single framed message (protects against garbage on the socket).
    static let maxMessageSize = 64 * 1024 * 1024
}

/// Every framed message starts with one of these type bytes.
/// Wire format: [type: UInt8][length: UInt32 big-endian][payload: length bytes]
enum MessageType: UInt8 {
    // Sender (Mac) -> receiver (iMac)
    case hello = 1              // JSON HelloMessage
    case pairRequest = 2        // JSON PairRequest
    case videoFormat = 10       // JSON VideoFormatMessage
    case videoFrame = 11        // binary VideoFrame
    case audioFormat = 20       // JSON AudioFormatMessage
    case audioData = 21         // raw Float32 interleaved PCM, little-endian
    case audioVolume = 22       // JSON AudioVolumeMessage, sent both ways to keep volumes in sync
    case displayControl = 30    // JSON DisplayControlMessage
    case ping = 40              // 8-byte timestamp, echoed back as pong

    // Receiver (iMac) -> sender (Mac)
    case helloReply = 101       // JSON HelloReply
    case pairResult = 102       // JSON PairResult
    case inputEvent = 110       // binary InputEvent
    case requestKeyframe = 111  // empty
    case receiverStats = 112    // JSON ReceiverStats
    case displayState = 113     // JSON DisplayState
    case pong = 140             // echo of ping payload
}

// MARK: - Handshake and pairing

struct HelloMessage: Codable {
    var protocolVersion: Int
    var senderID: String
    var senderName: String
    /// Token received during a previous pairing, if any.
    var token: String?
}

enum HelloStatus: String, Codable {
    case ok
    case pinRequired
    case incompatible
}

struct HelloReply: Codable {
    var status: HelloStatus
    var protocolVersion: Int
    var receiverID: String
    var receiverName: String
    /// Physical pixel size of the iMac screen (4096 x 2304 on the 21.5" Retina 4K).
    var screenPixelWidth: Int
    var screenPixelHeight: Int
    var hevcHardwareDecode: Bool
    var displayState: DisplayState
}

struct PairRequest: Codable {
    var senderID: String
    var senderName: String
    var pin: String
}

struct PairResult: Codable {
    var success: Bool
    var token: String?
}

// MARK: - Media

enum VideoCodec: String, Codable {
    case h264
    case hevc
}

struct VideoFormatMessage: Codable {
    var codec: VideoCodec
    var width: Int
    var height: Int
    /// SPS/PPS (and VPS for HEVC) without start codes.
    var parameterSets: [Data]
}

/// One encoded video frame in AVCC/HVCC layout (4-byte NAL unit lengths).
struct VideoFrame {
    var isKeyframe: Bool
    var ptsMicros: Int64
    var data: Data

    init(isKeyframe: Bool, ptsMicros: Int64, data: Data) {
        self.isKeyframe = isKeyframe
        self.ptsMicros = ptsMicros
        self.data = data
    }

    init?(payload: Data) {
        var reader = BinaryReader(payload)
        guard let flags = reader.read(UInt8.self), let pts = reader.read(Int64.self) else { return nil }
        isKeyframe = (flags & 1) != 0
        ptsMicros = pts
        data = reader.remaining()
    }

    func serialized() -> Data {
        var writer = BinaryWriter()
        writer.write(UInt8(isKeyframe ? 1 : 0))
        writer.write(ptsMicros)
        writer.append(data)
        return writer.data
    }
}

struct AudioFormatMessage: Codable {
    var sampleRate: Double
    var channels: Int
}

/// Volume and mute of the iMac's speakers: the iMac's system volume on one side, the
/// "iMac" audio output of the Mac on the other.
struct AudioVolumeMessage: Codable {
    /// 0...1
    var volume: Float
    var muted: Bool

    /// Equal within rounding, so a value echoed back by the other side isn't sent again.
    func matches(_ other: AudioVolumeMessage?) -> Bool {
        guard let other else { return false }
        return abs(volume - other.volume) < 0.005 && muted == other.muted
    }
}

// MARK: - Display adjustments (brightness, gamma, white point)

struct DisplayControlMessage: Codable {
    /// 0...1
    var brightness: Float?
    /// 0.5...2.0, 1 = neutral. Higher values brighten mid-tones.
    var gamma: Float?
    /// -1...1, 0 = neutral. Positive = warmer, negative = cooler.
    var warmth: Float?
    var resetColor: Bool?
}

struct DisplayState: Codable, Equatable {
    var brightnessSupported: Bool
    var brightness: Float
    var gamma: Float
    var warmth: Float
}

struct ReceiverStats: Codable {
    var framesReceived: Int
    var framesDisplayed: Int
    var decodeFailures: Int
}

// MARK: - Input (iMac keyboard and mouse -> Mac)

enum InputEvent {
    /// Relative mouse motion in points.
    case mouseMove(dx: Float, dy: Float)
    /// button: 0 = left, 1 = right, 2+ = other.
    case mouseButton(button: UInt8, down: Bool, clickCount: UInt8)
    case scroll(dx: Float, dy: Float, continuous: Bool)
    /// flags are NSEvent.ModifierFlags raw values, which match CGEventFlags.
    case key(keyCode: UInt16, down: Bool, flags: UInt64)
    case flagsChanged(keyCode: UInt16, flags: UInt64)

    func serialized() -> Data {
        var w = BinaryWriter()
        switch self {
        case let .mouseMove(dx, dy):
            w.write(UInt8(1)); w.write(dx); w.write(dy)
        case let .mouseButton(button, down, clickCount):
            w.write(UInt8(2)); w.write(button); w.write(UInt8(down ? 1 : 0)); w.write(clickCount)
        case let .scroll(dx, dy, continuous):
            w.write(UInt8(3)); w.write(dx); w.write(dy); w.write(UInt8(continuous ? 1 : 0))
        case let .key(keyCode, down, flags):
            w.write(UInt8(4)); w.write(keyCode); w.write(UInt8(down ? 1 : 0)); w.write(flags)
        case let .flagsChanged(keyCode, flags):
            w.write(UInt8(5)); w.write(keyCode); w.write(flags)
        }
        return w.data
    }

    init?(payload: Data) {
        var r = BinaryReader(payload)
        guard let kind = r.read(UInt8.self) else { return nil }
        switch kind {
        case 1:
            guard let dx = r.readFloat(), let dy = r.readFloat() else { return nil }
            self = .mouseMove(dx: dx, dy: dy)
        case 2:
            guard let b = r.read(UInt8.self), let d = r.read(UInt8.self), let c = r.read(UInt8.self) else { return nil }
            self = .mouseButton(button: b, down: d != 0, clickCount: c)
        case 3:
            guard let dx = r.readFloat(), let dy = r.readFloat(), let c = r.read(UInt8.self) else { return nil }
            self = .scroll(dx: dx, dy: dy, continuous: c != 0)
        case 4:
            guard let k = r.read(UInt16.self), let d = r.read(UInt8.self), let f = r.read(UInt64.self) else { return nil }
            self = .key(keyCode: k, down: d != 0, flags: f)
        case 5:
            guard let k = r.read(UInt16.self), let f = r.read(UInt64.self) else { return nil }
            self = .flagsChanged(keyCode: k, flags: f)
        default:
            return nil
        }
    }
}

// MARK: - Helpers

enum JSONCoding {
    static func encode<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }
}

/// Big-endian binary writer.
struct BinaryWriter {
    private(set) var data = Data()

    mutating func write<T: FixedWidthInteger>(_ value: T) {
        var be = value.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

    mutating func write(_ value: Float) {
        write(value.bitPattern)
    }

    mutating func append(_ other: Data) {
        data.append(other)
    }
}

/// Big-endian binary reader. Works on Data slices with any start index.
struct BinaryReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    mutating func read<T: FixedWidthInteger>(_ type: T.Type) -> T? {
        let size = MemoryLayout<T>.size
        guard offset + size <= data.endIndex else { return nil }
        var value: T = 0
        for i in 0..<size {
            value = (value &<< 8) | T(truncatingIfNeeded: data[offset + i])
        }
        offset += size
        return value
    }

    mutating func readFloat() -> Float? {
        guard let bits = read(UInt32.self) else { return nil }
        return Float(bitPattern: bits)
    }

    mutating func remaining() -> Data {
        let rest = data.subdata(in: offset..<data.endIndex)
        offset = data.endIndex
        return rest
    }
}
