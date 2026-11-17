import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

enum EncoderError: LocalizedError {
    case creationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .creationFailed(let status):
            return String(format: NSLocalizedString("The hardware video encoder could not be started (error %d).", comment: "Encoder error"), Int(status))
        }
    }
}

/// Hardware H.264/HEVC encoder tuned for screen content and low latency.
final class VideoEncoder {
    let codec: VideoCodec
    let width: Int
    let height: Int

    /// Sent before every keyframe so the receiver can always (re)start decoding.
    var onFormat: ((VideoFormatMessage) -> Void)?
    var onFrame: ((VideoFrame) -> Void)?

    private var session: VTCompressionSession?
    private let lock = NSLock()
    private var forceKeyframe = true

    init(codec: VideoCodec, width: Int, height: Int, fps: Int, bitrate: Int) throws {
        self.codec = codec
        self.width = width
        self.height = height

        var status: OSStatus = noErr
        // Low-latency rate control first, plain real-time mode as a fallback.
        var created = Self.makeSession(codec: codec, width: width, height: height, lowLatency: codec == .h264, status: &status)
        if created == nil {
            created = Self.makeSession(codec: codec, width: width, height: height, lowLatency: false, status: &status)
        }
        guard let session = created else { throw EncoderError.creationFailed(status) }
        self.session = session

        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        let profile = codec == .h264 ? kVTProfileLevel_H264_ConstrainedHigh_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel
        set(kVTCompressionPropertyKey_ProfileLevel, profile)
        // Keyframes are sent on demand (start, decoder errors, resolution changes).
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: 36_000))
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 600))
        setFrameRate(fps)
        setBitrate(bitrate)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    deinit {
        invalidate()
    }

    private static func makeSession(codec: VideoCodec, width: Int, height: Int, lowLatency: Bool, status: inout OSStatus) -> VTCompressionSession? {
        var specification: [String: Any] = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true,
        ]
        if lowLatency {
            specification[kVTVideoEncoderSpecification_EnableLowLatencyRateControl as String] = true
        }
        var session: VTCompressionSession?
        status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: codec == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC,
            encoderSpecification: specification as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session)
        return status == noErr ? session : nil
    }

    private func set(_ key: CFString, _ value: CFTypeRef) {
        guard let session else { return }
        let status = VTSessionSetProperty(session, key: key, value: value)
        if status != noErr {
            NSLog("iMacDisplay: encoder property \(key) not applied (\(status))")
        }
    }

    func setBitrate(_ bitsPerSecond: Int) {
        set(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitsPerSecond))
        // Hard cap at 1.5x the average over one second.
        let bytesPerSecond = bitsPerSecond / 8 * 3 / 2
        set(kVTCompressionPropertyKey_DataRateLimits, [NSNumber(value: bytesPerSecond), NSNumber(value: 1)] as CFArray)
    }

    func setFrameRate(_ fps: Int) {
        set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: fps))
    }

    func requestKeyframe() {
        lock.lock()
        forceKeyframe = true
        lock.unlock()
    }

    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard let session else { return }
        lock.lock()
        let force = forceKeyframe
        forceKeyframe = false
        lock.unlock()

        let properties: CFDictionary? = force
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary
            : nil
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: properties,
            infoFlagsOut: nil) { [weak self] status, _, sampleBuffer in
                guard status == noErr, let sampleBuffer, let self else { return }
                self.handle(sampleBuffer)
            }
        if status != noErr, force {
            requestKeyframe()
        }
    }

    func invalidate() {
        guard let session else { return }
        self.session = nil
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
    }

    // MARK: - Output

    private func handle(_ sampleBuffer: CMSampleBuffer) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[String: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool ?? false
        let isKeyframe = !notSync

        if isKeyframe, let description = CMSampleBufferGetFormatDescription(sampleBuffer) {
            let sets = Self.parameterSets(of: description, codec: codec)
            onFormat?(VideoFormatMessage(codec: codec, width: width, height: height, parameterSets: sets))
        }

        let length = CMBlockBufferGetDataLength(dataBuffer)
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(dataBuffer, atOffset: 0, dataLength: length, destination: base)
        }
        guard status == kCMBlockBufferNoErr else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let micros = pts.isValid ? Int64(CMTimeGetSeconds(pts) * 1_000_000) : 0
        onFrame?(VideoFrame(isKeyframe: isKeyframe, ptsMicros: micros, data: data))
    }

    static func parameterSets(of description: CMFormatDescription, codec: VideoCodec) -> [Data] {
        var count = 0
        var sets: [Data] = []
        switch codec {
        case .h264:
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                description, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil) == noErr else { return [] }
            for index in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    description, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
                   let pointer {
                    sets.append(Data(bytes: pointer, count: size))
                }
            }
        case .hevc:
            guard CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                description, parameterSetIndex: 0, parameterSetPointerOut: nil,
                parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil) == noErr else { return [] }
            for index in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    description, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
                   let pointer {
                    sets.append(Data(bytes: pointer, count: size))
                }
            }
        }
        return sets
    }
}
