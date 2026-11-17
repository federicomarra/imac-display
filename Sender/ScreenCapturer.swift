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

/// Captures one display with ScreenCaptureKit as NV12 pixel buffers.
final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate {
    /// Called on the capture queue for every new frame.
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    var onError: ((Error) -> Void)?

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "imacdisplay.sender.capture", qos: .userInteractive)
    private var configuration = SCStreamConfiguration()

    func start(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int) async throws {
        var found: SCDisplay?
        // A new virtual display takes a moment to show up in the shareable content.
        for _ in 0..<20 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            if let display = content.displays.first(where: { $0.displayID == displayID }) {
                found = display
                break
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        guard let display = found else { throw CaptureError.displayNotFound }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        configuration = Self.makeConfiguration(width: width, height: height, fps: fps)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
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
        onError?(error)
    }
}
