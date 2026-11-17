import AVFoundation

/// Plays the Mac's system audio on the iMac speakers.
final class AudioPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let lock = NSLock()
    private var format: AVAudioFormat?
    private var queuedFrames: Int = 0
    private var attached = false

    /// Maximum audio kept in the queue; older packets are dropped to keep latency low.
    private let maxQueuedSeconds = 0.25

    func configure(_ message: AudioFormatMessage) {
        stop()
        guard message.channels > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: message.sampleRate,
                                         channels: AVAudioChannelCount(message.channels)) else { return }
        if !attached {
            engine.attach(player)
            attached = true
        }
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            player.play()
            lock.lock()
            self.format = format
            queuedFrames = 0
            lock.unlock()
        } catch {
            NSLog("iMacDisplay: audio engine failed to start: \(error)")
        }
    }

    /// `data` holds interleaved little-endian Float32 samples.
    func enqueue(_ data: Data) {
        lock.lock()
        guard let format else {
            lock.unlock()
            return
        }
        let channels = Int(format.channelCount)
        let frameCount = data.count / (MemoryLayout<Float>.size * channels)
        guard frameCount > 0, Double(queuedFrames) < format.sampleRate * maxQueuedSeconds else {
            lock.unlock()
            return
        }
        queuedFrames += frameCount
        lock.unlock()

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
              let channelData = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        data.withUnsafeBytes { raw in
            for channel in 0..<channels {
                let destination = channelData[channel]
                for frame in 0..<frameCount {
                    let offset = (frame * channels + channel) * MemoryLayout<Float>.size
                    destination[frame] = raw.loadUnaligned(fromByteOffset: offset, as: Float.self)
                }
            }
        }
        player.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.queuedFrames = max(0, self.queuedFrames - frameCount)
            self.lock.unlock()
        }
    }

    func stop() {
        lock.lock()
        format = nil
        queuedFrames = 0
        lock.unlock()
        player.stop()
        engine.stop()
    }
}
