import AppKit
import AVFoundation
import CoreMedia
import VideoToolbox

/// Shows the decoded stream. AVSampleBufferDisplayLayer decodes H.264/HEVC in hardware
/// and displays each frame as soon as it is enqueued.
final class VideoView: NSView {
    private let displayLayer = AVSampleBufferDisplayLayer()
    private let lock = NSLock()
    private var formatDescription: CMFormatDescription?
    private var waitingForKeyframe = true

    private(set) var framesDisplayed = 0
    private(set) var decodeFailures = 0

    /// Called (on the caller's queue) when decoding cannot continue without a new keyframe.
    var onNeedsKeyframe: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer = CALayer()
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        displayLayer.frame = bounds
        displayLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(displayLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    static var supportsHEVCHardwareDecode: Bool {
        VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
    }

    /// New SPS/PPS (sent before every keyframe).
    func setFormat(_ format: VideoFormatMessage) {
        guard let description = Self.makeFormatDescription(format) else {
            onNeedsKeyframe?()
            return
        }
        lock.lock()
        let changed: Bool
        if let current = formatDescription {
            changed = !CMFormatDescriptionEqual(current, otherFormatDescription: description)
        } else {
            changed = true
        }
        formatDescription = description
        if changed {
            // The keyframe that follows this message starts the new stream.
            waitingForKeyframe = true
        }
        lock.unlock()
        if changed {
            displayLayer.flush()
        }
    }

    func enqueue(_ frame: VideoFrame) {
        lock.lock()
        guard let description = formatDescription else {
            lock.unlock()
            return
        }
        if waitingForKeyframe {
            guard frame.isKeyframe else {
                lock.unlock()
                return
            }
            waitingForKeyframe = false
        }
        lock.unlock()

        if displayLayer.status == .failed || displayLayer.requiresFlushToResumeDecoding {
            displayLayer.flush()
            lock.lock()
            waitingForKeyframe = true
            decodeFailures += 1
            lock.unlock()
            onNeedsKeyframe?()
            return
        }

        guard let sampleBuffer = Self.makeSampleBuffer(frame, description: description) else { return }
        displayLayer.enqueue(sampleBuffer)
        lock.lock()
        framesDisplayed += 1
        lock.unlock()
    }

    /// Back to black, e.g. after a disconnect.
    func reset() {
        lock.lock()
        formatDescription = nil
        waitingForKeyframe = true
        lock.unlock()
        displayLayer.flushAndRemoveImage()
    }

    // MARK: - CoreMedia helpers

    private static func makeFormatDescription(_ format: VideoFormatMessage) -> CMFormatDescription? {
        guard !format.parameterSets.isEmpty else { return nil }
        let sets = format.parameterSets.map { $0 as NSData }
        let pointers = sets.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }
        let sizes = sets.map { $0.length }
        var description: CMFormatDescription?
        let status: OSStatus
        switch format.codec {
        case .h264:
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: pointers.count,
                parameterSetPointers: pointers,
                parameterSetSizes: sizes,
                nalUnitHeaderLength: 4,
                formatDescriptionOut: &description)
        case .hevc:
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: pointers.count,
                parameterSetPointers: pointers,
                parameterSetSizes: sizes,
                nalUnitHeaderLength: 4,
                extensions: nil,
                formatDescriptionOut: &description)
        }
        withExtendedLifetime(sets) {}
        return status == noErr ? description : nil
    }

    private static func makeSampleBuffer(_ frame: VideoFrame, description: CMFormatDescription) -> CMSampleBuffer? {
        let length = frame.data.count
        guard length > 0 else { return nil }

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: length,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: length,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer)
        guard status == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        status = frame.data.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: length)
        }
        guard status == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: frame.ptsMicros, timescale: 1_000_000),
            decodeTimeStamp: .invalid)
        var sampleSize = length
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: description,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sampleBuffer else { return nil }

        // Show each frame immediately instead of scheduling it on a timebase.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            let trueValue: CFBoolean = kCFBooleanTrue
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(trueValue).toOpaque())
        }
        return sampleBuffer
    }
}
