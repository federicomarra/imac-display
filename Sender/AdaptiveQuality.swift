import Foundation

/// Steps quality down when the link is congested and back up when it recovers,
/// in the order chosen in the settings.
struct AdaptiveQuality {
    enum Dimension {
        case frameRate
        case resolution
        case bitrate
    }

    struct Change {
        var frameRate = false
        var resolution = false
        var bitrate = false
        var any: Bool { frameRate || resolution || bitrate }
    }

    private let order: [Dimension]
    private let frameRates: [Int]
    private let scales: [Double] = [1.0, 0.75, 0.5]
    private let bitrates: [Int]

    private var frameRateIndex = 0
    private var scaleIndex = 0
    private var bitrateIndex = 0
    private var calmSeconds = 0

    /// Seconds without congestion before trying one step up again.
    private let recoveryDelay = 6

    init(policy: QualityPolicy, maxFrameRate: Int, maxBitrate: Int) {
        switch policy {
        case .reduceFrameRate:
            order = [.frameRate, .bitrate, .resolution]
        case .reduceResolution:
            order = [.resolution, .frameRate, .bitrate]
        case .reduceQuality:
            order = [.bitrate, .frameRate, .resolution]
        }
        frameRates = [maxFrameRate, 45, 30, 24, 15].filter { $0 <= maxFrameRate }.reduce(into: [Int]()) { list, value in
            if !list.contains(value) { list.append(value) }
        }
        let minimumBitrate = 4_000_000
        var steps: [Int] = []
        var value = maxBitrate
        while value > minimumBitrate {
            steps.append(value)
            value = value * 3 / 4
        }
        steps.append(minimumBitrate)
        bitrates = steps
    }

    var frameRate: Int { frameRates[frameRateIndex] }
    var scale: Double { scales[scaleIndex] }
    var bitrate: Int { bitrates[bitrateIndex] }

    mutating func update(congested: Bool) -> Change {
        if congested {
            calmSeconds = 0
            for dimension in order where canDegrade(dimension) {
                return step(dimension, by: 1)
            }
            return Change()
        }
        calmSeconds += 1
        guard calmSeconds >= recoveryDelay else { return Change() }
        calmSeconds = 0
        // Restore in reverse order: the first thing given up comes back last.
        for dimension in order.reversed() where canImprove(dimension) {
            return step(dimension, by: -1)
        }
        return Change()
    }

    private func canDegrade(_ dimension: Dimension) -> Bool {
        switch dimension {
        case .frameRate: return frameRateIndex < frameRates.count - 1
        case .resolution: return scaleIndex < scales.count - 1
        case .bitrate: return bitrateIndex < bitrates.count - 1
        }
    }

    private func canImprove(_ dimension: Dimension) -> Bool {
        switch dimension {
        case .frameRate: return frameRateIndex > 0
        case .resolution: return scaleIndex > 0
        case .bitrate: return bitrateIndex > 0
        }
    }

    private mutating func step(_ dimension: Dimension, by delta: Int) -> Change {
        var change = Change()
        switch dimension {
        case .frameRate:
            frameRateIndex += delta
            change.frameRate = true
        case .resolution:
            scaleIndex += delta
            change.resolution = true
        case .bitrate:
            bitrateIndex += delta
            change.bitrate = true
        }
        return change
    }
}
