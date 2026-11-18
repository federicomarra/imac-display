import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case displayNotFound

    var errorDescription: String? {
        NSLocalizedString("The screen to capture was not found. Check the Screen Recording permission in System Settings → Privacy & Security.", comment: "Capture error")
    }
}

/// Captures the iMac's screen with ScreenCaptureKit as NV12 pixel buffers.
///
/// Like a monitor on HDMI, the iMac shows whatever System Settings → Displays makes of
/// its screen: its own desktop when extended, or the screen it mirrors when set to
/// Mirror. A mirrored screen isn't capturable on its own, so the capture follows the
/// screen it mirrors, and switches live when the arrangement changes.
final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate {
    /// Called on the capture queue for every new frame.
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    var onError: ((Error) -> Void)?

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "imacdisplay.sender.capture", qos: .userInteractive)
    private var configuration = SCStreamConfiguration()
    /// The iMac's (virtual) screen, and the screen actually captured for it.
    private var targetDisplayID = CGDirectDisplayID(0)
    private var capturedDisplayID = CGDirectDisplayID(0)
    private var switching = false

    func start(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int) async throws {
        targetDisplayID = displayID
        configuration = Self.makeConfiguration(width: width, height: height, fps: fps)
        try await capture()
        CGDisplayRegisterReconfigurationCallback(Self.reconfigured, Unmanaged.passUnretained(self).toOpaque())
    }

    deinit {
        CGDisplayRemoveReconfigurationCallback(Self.reconfigured, Unmanaged.passUnretained(self).toOpaque())
    }

    /// The screen whose picture the iMac shows: its own, or the one it mirrors.
    private static func source(for displayID: CGDirectDisplayID) -> CGDirectDisplayID {
        CGDisplayIsInMirrorSet(displayID) != 0 ? CGDisplayPrimaryDisplay(displayID) : displayID
    }

    /// Starts capturing the current source, or switches the running capture to it.
    private func capture() async throws {
        var found: SCDisplay?
        // A new virtual display takes a moment to show up in the shareable content.
        for _ in 0..<20 {
            let source = Self.source(for: targetDisplayID)
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            if let display = content.displays.first(where: { $0.displayID == source }) {
                found = display
                break
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        guard let display = found else { throw CaptureError.displayNotFound }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        if let stream {
            try await stream.updateContentFilter(filter)
        } else {
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
            self.stream = stream
        }
        capturedDisplayID = display.displayID
    }

    /// Display arrangement changed (System Settings → Displays): follow Mirror/Extend.
    private static let reconfigured: CGDisplayReconfigurationCallBack = { _, flags, info in
        guard !flags.contains(.beginConfigurationFlag), let info else { return }
        Unmanaged<ScreenCapturer>.fromOpaque(info).takeUnretainedValue().followArrangement()
    }

    private func followArrangement() {
        guard targetDisplayID != 0, !switching,
              Self.source(for: targetDisplayID) != capturedDisplayID else { return }
        switching = true
        Task {
            do {
                try await capture()
            } catch {
                onError?(error)
            }
            switching = false
        }
    }

    func update(width: Int, height: Int, fps: Int) async {
        guard let stream else { return }
        configuration = Self.makeConfiguration(width: width, height: height, fps: fps)
        do {
            try await stream.updateConfiguration(configuration)
        } catch {
            NSLog("iMacDisplay: could not update the capture: \(error)")
        }
    }

    func stop() async {
        CGDisplayRemoveReconfigurationCallback(Self.reconfigured, Unmanaged.passUnretained(self).toOpaque())
        targetDisplayID = 0
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    private static func makeConfiguration(width: Int, height: Int, fps: Int) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.queueDepth = 5
        configuration.showsCursor = true
        // When mirroring the MacBook (16:10) onto the iMac (16:9): bars, not stretching.
        configuration.preservesAspectRatio = true
        configuration.capturesAudio = false
        configuration.colorSpaceName = CGColorSpace.sRGB
        return configuration
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus),
              status == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        onFrame?(pixelBuffer, sampleBuffer.presentationTimeStamp)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard stream === self.stream, targetDisplayID != 0 else { return }
        // Switching between Mirror and Extend can stop the capture of the old screen:
        // start again on the current one, and give up only if that fails too.
        self.stream = nil
        Task {
            do {
                try await capture()
            } catch {
                onError?(error)
            }
        }
    }
}
