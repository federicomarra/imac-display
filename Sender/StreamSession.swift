import CoreAudio
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

/// A snapshot of the settings used for one stream.
struct StreamConfig {
    var policy: QualityPolicy
    var maxFrameRate: Int
    var maxBitrate: Int
    var codecPreference: CodecPreference
    var audio: Bool
    var input: Bool
    var receiverName: String
}

struct StreamStats: Equatable {
    var width = 0
    var height = 0
    var fps = 0
    var targetFPS = 0
    var megabitsPerSecond = 0.0
    var roundTripMilliseconds = 0
    var droppedFrames = 0
    var codec = ""
    var link: LinkKind = .unknown
    var audioActive = false
    var warning: String?
}

/// The media pipeline for one authenticated connection:
/// virtual display -> ScreenCaptureKit -> VideoToolbox -> network,
/// plus system audio and input events.
final class StreamSession {
    let connection: FramedConnection
    let reply: HelloReply
    let config: StreamConfig

    /// Called once per second on a background queue.
    var onStats: ((StreamStats) -> Void)?
    /// Called on a background queue when the stream can't continue.
    var onFatalError: ((String) -> Void)?

    private let virtualDisplay = VirtualDisplayManager()
    private let capturer = ScreenCapturer()
    private let audio = SystemAudioCapturer()
    private let injector = InputInjector()
    private let controlQueue = DispatchQueue(label: "imacdisplay.sender.session", qos: .userInteractive)

    private let lock = NSLock()
    private var encoder: VideoEncoder?
    private var lastPixelBuffer: CVPixelBuffer?
    private var lastPTS = CMTime.invalid
    private var framesSent = 0
    private var framesDropped = 0
    private var bytesSent = 0
    private var stopped = false

    private var adaptive: AdaptiveQuality
    private var codec: VideoCodec = .h264
    private var baseSize = (width: 4096, height: 2304)
    private var currentSize = (width: 4096, height: 2304)
    private var roundTrip = 0.0
    private var timer: DispatchSourceTimer?
    private var audioWarning: String?
    private let clockStart = Date()

    /// The iMac audio output of the Mac, when the audio driver is installed.
    private var outputDevice: AudioObjectID?
    private var stopObservingVolume: (() -> Void)?
    /// Last volume both sides agree on, so an echo isn't sent back (controlQueue).
    private var lastVolume: AudioVolumeMessage?

    init(connection: FramedConnection, reply: HelloReply, config: StreamConfig) {
        self.connection = connection
        self.reply = reply
        self.config = config
        adaptive = AdaptiveQuality(policy: config.policy, maxFrameRate: config.maxFrameRate, maxBitrate: config.maxBitrate)
    }

    // MARK: - Lifecycle

    func start() async throws {
        codec = chooseCodec()

        // The iMac is always a separate screen, like a monitor on HDMI: mirroring, if
        // wanted, is chosen in System Settings → Displays like for any monitor.
        let serial = UInt32(truncatingIfNeeded: reply.receiverID.hashValueStable)
        let created = await MainActorRunner.run {
            self.virtualDisplay.create(name: self.config.receiverName, serial: serial)
        }
        guard let displayID = created else {
            throw NSError(domain: "iMacDisplay", code: 1, userInfo: [
                NSLocalizedDescriptionKey: NSLocalizedString("macOS did not allow creating the virtual screen.", comment: "Stream error"),
            ])
        }
        baseSize = Self.even(width: reply.screenPixelWidth, height: reply.screenPixelHeight)

        currentSize = scaled(baseSize, by: adaptive.scale)
        try makeEncoder(size: currentSize)

        capturer.onFrame = { [weak self] pixelBuffer, pts in
            self?.captured(pixelBuffer, pts: pts)
        }
        capturer.onError = { [weak self] error in
            self?.onFatalError?(error.localizedDescription)
        }
        try await capturer.start(displayID: displayID, width: currentSize.width, height: currentSize.height, fps: adaptive.frameRate)

        // With the audio driver the iMac is an audio output of the Mac while connected
        // (SenderController removes it on disconnect, so a restart doesn't lose it).
        let device = AudioOutputDevice.publish(config.audio ? config.receiverName : nil)
        if config.audio {
            if let device {
                outputDevice = device
                stopObservingVolume = AudioOutputDevice.observe(device, queue: controlQueue) { [weak self] in
                    self?.outputVolumeChanged()
                }
            }
            audio.onFormat = { [weak self] format in self?.connection.sendJSON(.audioFormat, format) }
            audio.onSamples = { [weak self] samples in self?.connection.send(.audioData, samples) }
            do {
                try audio.start(deviceUID: device == nil ? nil : AudioOutputDevice.deviceUID)
            } catch {
                audioWarning = error.localizedDescription
            }
        }

        if config.input {
            _ = InputInjector.isTrusted(prompt: true)
        }

        startTimer()
    }

    func stop() {
        lock.lock()
        let wasStopped = stopped
        stopped = true
        let encoder = self.encoder
        self.encoder = nil
        lastPixelBuffer = nil
        lock.unlock()
        guard !wasStopped else { return }

        timer?.cancel()
        timer = nil
        stopObservingVolume?()
        stopObservingVolume = nil
        audio.stop()
        injector.releaseAll()
        encoder?.invalidate()
        let capturer = self.capturer
        let virtualDisplay = self.virtualDisplay
        Task {
            await capturer.stop()
            DispatchQueue.main.async { virtualDisplay.destroy() }
        }
    }

    /// The iMac's screen on the Mac, while it exists. Read on the main thread.
    var displayID: CGDirectDisplayID? {
        virtualDisplay.displayID
    }

    /// Messages from the receiver that belong to the stream (called on the network queue).
    func handle(_ type: MessageType, _ payload: Data) {
        switch type {
        case .inputEvent:
            guard config.input, let event = InputEvent(payload: payload) else { return }
            injector.handle(event)
        case .requestKeyframe:
            forceKeyframe()
        case .audioVolume:
            // The iMac's volume changed (or this is its value at connection): mirror it.
            guard let level = JSONCoding.decode(AudioVolumeMessage.self, from: payload) else { return }
            controlQueue.async {
                guard let device = self.outputDevice else { return }
                self.lastVolume = level
                AudioOutputDevice.setLevel(level, on: device)
            }
        case .pong:
            var reader = BinaryReader(payload)
            if let sent = reader.read(Int64.self) {
                let rtt = Double(nowMicros() - sent) / 1000
                controlQueue.async { self.roundTrip = rtt }
            }
        default:
            break
        }
    }

    /// Volume or mute of the iMac output changed on the Mac (keys, menu bar): tell the iMac.
    /// Called on controlQueue.
    private func outputVolumeChanged() {
        guard let device = outputDevice else { return }
        let level = AudioOutputDevice.level(of: device)
        guard !level.matches(lastVolume) else { return }
        lastVolume = level
        connection.sendJSON(.audioVolume, level)
    }

    // MARK: - Video

    private func chooseCodec() -> VideoCodec {
        switch config.codecPreference {
        case .h264: return .h264
        case .hevc: return .hevc
        case .automatic: return reply.hevcHardwareDecode ? .hevc : .h264
        }
    }

    private func makeEncoder(size: (width: Int, height: Int)) throws {
        let encoder = try VideoEncoder(codec: codec, width: size.width, height: size.height,
                                       fps: adaptive.frameRate, bitrate: adaptive.bitrate)
        encoder.onFormat = { [weak self] format in
            self?.connection.sendJSON(.videoFormat, format)
        }
        encoder.onFrame = { [weak self] frame in
            guard let self else { return }
            let payload = frame.serialized()
            self.connection.send(.videoFrame, payload)
            self.lock.lock()
            self.framesSent += 1
            self.bytesSent += payload.count
            self.lock.unlock()
        }
        lock.lock()
        let old = self.encoder
        self.encoder = encoder
        lock.unlock()
        old?.invalidate()
    }

    /// Called on the capture queue.
    private func captured(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        lock.lock()
        guard !stopped, let encoder else {
            lock.unlock()
            return
        }
        lastPixelBuffer = pixelBuffer
        lastPTS = pts
        // Don't pile frames up behind a slow link: skip encoding instead.
        // Skipping (rather than dropping encoded frames) keeps the H.264 stream decodable.
        let bytesPerFrame = adaptive.bitrate / 8 / max(1, adaptive.frameRate)
        let backlogLimit = max(1_500_000, bytesPerFrame * 3)
        if connection.inflightBytes > backlogLimit {
            framesDropped += 1
            lock.unlock()
            return
        }
        lock.unlock()
        encoder.encode(pixelBuffer, pts: pts)
    }

    private func forceKeyframe() {
        lock.lock()
        let encoder = self.encoder
        let pixelBuffer = lastPixelBuffer
        let pts = lastPTS
        lock.unlock()
        encoder?.requestKeyframe()
        // The screen may be static: re-encode the last frame so a keyframe goes out now.
        if let encoder, let pixelBuffer {
            let next = pts.isValid ? CMTimeAdd(pts, CMTime(value: 1, timescale: 1000)) : CMTime(value: nowMicros(), timescale: 1_000_000)
            encoder.encode(pixelBuffer, pts: next)
        }
    }

    // MARK: - Timer: ping, stats, adaptation

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: controlQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        var ping = BinaryWriter()
        ping.write(nowMicros())
        connection.send(.ping, ping.data)

        lock.lock()
        let sent = framesSent
        let dropped = framesDropped
        let bytes = bytesSent
        framesSent = 0
        framesDropped = 0
        bytesSent = 0
        lock.unlock()

        let congested = dropped > 1 || roundTrip > 120
        // `captured` reads `adaptive` on the capture queue, so mutate it under the lock.
        lock.lock()
        let change = adaptive.update(congested: congested)
        lock.unlock()
        if change.any {
            apply(change)
        }

        var stats = StreamStats()
        stats.width = currentSize.width
        stats.height = currentSize.height
        stats.fps = sent
        stats.targetFPS = adaptive.frameRate
        stats.megabitsPerSecond = Double(bytes) * 8 / 1_000_000
        stats.roundTripMilliseconds = Int(roundTrip.rounded())
        stats.droppedFrames = dropped
        stats.codec = codec == .h264 ? "H.264" : "HEVC"
        stats.link = connection.linkKind
        stats.audioActive = config.audio && audioWarning == nil
        stats.warning = audioWarning
        onStats?(stats)
    }

    /// Called on the control queue.
    private func apply(_ change: AdaptiveQuality.Change) {
        let fps = adaptive.frameRate
        if change.resolution {
            let size = scaled(baseSize, by: adaptive.scale)
            currentSize = size
            do {
                try makeEncoder(size: size)
            } catch {
                onFatalError?(error.localizedDescription)
                return
            }
            let capturer = self.capturer
            Task { await capturer.update(width: size.width, height: size.height, fps: fps) }
        }
        lock.lock()
        let encoder = self.encoder
        lock.unlock()
        if change.frameRate {
            encoder?.setFrameRate(fps)
            if !change.resolution {
                let size = currentSize
                let capturer = self.capturer
                Task { await capturer.update(width: size.width, height: size.height, fps: fps) }
            }
        }
        if change.bitrate {
            encoder?.setBitrate(adaptive.bitrate)
        }
    }

    // MARK: - Helpers

    private func nowMicros() -> Int64 {
        Int64(Date().timeIntervalSince(clockStart) * 1_000_000)
    }

    private func scaled(_ size: (width: Int, height: Int), by factor: Double) -> (width: Int, height: Int) {
        Self.even(width: Int(Double(size.width) * factor), height: Int(Double(size.height) * factor))
    }

    private static func even(width: Int, height: Int) -> (width: Int, height: Int) {
        (max(2, width & ~1), max(2, height & ~1))
    }
}

/// Runs a closure on the main thread and returns its result to async code.
enum MainActorRunner {
    static func run<T>(_ body: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume(returning: body())
            }
        }
    }
}

extension String {
    /// FNV-1a hash: unlike `hashValue`, it is the same on every launch.
    var hashValueStable: Int {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return Int(truncatingIfNeeded: hash)
    }
}
