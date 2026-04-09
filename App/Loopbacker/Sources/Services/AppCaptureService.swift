import Foundation
import ScreenCaptureKit
import CoreMedia
import AppKit
import os.log

private let logger = Logger(subsystem: "com.jacobcoffee.loopbacker", category: "AppCapture")

/// Represents a running application whose audio can be captured.
struct CaptureApp: Identifiable, Equatable {
    let id: String          // bundleIdentifier
    let name: String        // localized app name
    let icon: NSImage?      // app icon for UI
    let bundleURL: URL?

    static func == (lhs: CaptureApp, rhs: CaptureApp) -> Bool {
        lhs.id == rhs.id
    }
}

/// Manages ScreenCaptureKit-based audio capture from running applications.
/// Each active capture delivers Float32 interleaved audio into a caller-provided ring buffer writer.
class AppCaptureService: NSObject, ObservableObject {
    @Published var availableApps: [CaptureApp] = []
    @Published var permissionGranted: Bool = false

    /// Active stream delegates keyed by bundle identifier
    private var activeDelegates: [String: AppStreamDelegate] = [:]
    private var activeStreams: [String: SCStream] = [:]

    /// Tracks in-flight start operations to prevent start/stop races
    private var pendingStarts: Set<String> = []

    /// Audio callback queue — not the main thread, not the CoreAudio IO thread
    private let captureQueue = DispatchQueue(label: "com.jacobcoffee.loopbacker.appcapture", qos: .userInteractive)

    // MARK: - Permission

    /// Check Screen Recording permission. The first call triggers the system prompt.
    func checkPermission() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            await MainActor.run { permissionGranted = true }
            return true
        } catch {
            logger.warning("Screen Recording permission not granted: \(error.localizedDescription)")
            await MainActor.run { permissionGranted = false }
            return false
        }
    }

    /// Open System Settings to the Screen Recording privacy pane.
    func openPermissionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - App enumeration

    /// Refresh the list of running apps that could produce audio.
    func refreshApps() async {
        guard await checkPermission() else { return }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            let apps = content.applications
                .filter { app in
                    // Exclude ourselves and system processes
                    let bid = app.bundleIdentifier
                    return bid != Bundle.main.bundleIdentifier
                        && !bid.hasPrefix("com.apple.SystemUIServer")
                        && !bid.hasPrefix("com.apple.controlcenter")
                        && !bid.hasPrefix("com.apple.dock")
                        && !bid.hasPrefix("com.apple.finder")
                        && !bid.hasPrefix("com.apple.WindowManager")
                        && !bid.hasPrefix("com.apple.notificationcenterui")
                }
                .compactMap { app -> CaptureApp? in
                    let bid = app.bundleIdentifier
                    guard !bid.isEmpty else { return nil }
                    let icon = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
                        .first?.icon
                    let bundleURL = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
                        .first?.bundleURL
                    return CaptureApp(
                        id: bid,
                        name: app.applicationName.isEmpty ? bid : app.applicationName,
                        icon: icon,
                        bundleURL: bundleURL
                    )
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            await MainActor.run {
                self.availableApps = apps
            }
        } catch {
            logger.error("Failed to enumerate apps: \(error.localizedDescription)")
        }
    }

    /// Check if a specific app is currently running.
    func isAppRunning(bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    // MARK: - Capture

    /// Start audio-only capture for a specific app.
    /// The `ringBufferWriter` closure receives (pointer, frameCount, channelCount) and must be safe
    /// to call from a non-main, non-RT queue.
    func startCapture(
        bundleID: String,
        ringBufferWriter: @escaping (UnsafePointer<Float>, UInt32, UInt32) -> Void,
        sampleRate: Float64,
        channelCount: UInt32
    ) async throws {
        // Stop existing capture for this bundle if any
        await stopCapture(bundleID: bundleID)

        // Mark as pending to prevent stop racing with start
        pendingStarts.insert(bundleID)
        defer { pendingStarts.remove(bundleID) }

        // Find the target app in SCShareableContent
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let targetApp = content.applications.first(where: { $0.bundleIdentifier == bundleID }) else {
            throw AppCaptureError.appNotFound(bundleID)
        }

        // Find the main display for the content filter
        guard let display = content.displays.first else {
            throw AppCaptureError.noDisplay
        }

        // Create a filter that captures ONLY the target app's audio.
        let filter = SCContentFilter(display: display, including: [targetApp], exceptingWindows: [])

        // Configure for audio-only capture
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = Int(sampleRate)
        config.channelCount = Int(channelCount)
        config.excludesCurrentProcessAudio = true

        // Minimize video overhead — we only want audio.
        // SCStream requires video config even for audio-only capture.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 1 FPS minimum
        config.queueDepth = 1        // minimal video buffer queue
        config.showsCursor = false    // don't composite cursor
        config.pixelFormat = kCVPixelFormatType_32BGRA

        let streamDelegate = AppCaptureStreamDelegate(bundleID: bundleID, service: self)
        let stream = SCStream(filter: filter, configuration: config, delegate: streamDelegate)

        let outputDelegate = AppStreamDelegate(
            bundleID: bundleID,
            ringBufferWriter: ringBufferWriter,
            expectedChannelCount: channelCount
        )

        try stream.addStreamOutput(outputDelegate, type: .audio, sampleHandlerQueue: captureQueue)

        try await stream.startCapture()

        activeDelegates[bundleID] = outputDelegate
        activeStreams[bundleID] = stream
        // Hold a strong ref to the stream delegate so it doesn't get deallocated
        streamDelegates[bundleID] = streamDelegate

        logger.info("Started app audio capture for \(bundleID)")
    }

    /// Stop capture for a specific app.
    func stopCapture(bundleID: String) async {
        // If a start is in-flight, wait briefly for it to complete
        if pendingStarts.contains(bundleID) {
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
        }

        guard let stream = activeStreams.removeValue(forKey: bundleID) else { return }
        activeDelegates.removeValue(forKey: bundleID)
        streamDelegates.removeValue(forKey: bundleID)

        do {
            try await stream.stopCapture()
        } catch {
            logger.warning("Error stopping capture for \(bundleID): \(error.localizedDescription)")
        }

        logger.info("Stopped app audio capture for \(bundleID)")
    }

    /// Strong references to stream delegates (SCStream holds them weakly)
    private var streamDelegates: [String: AppCaptureStreamDelegate] = [:]

    /// Called by the stream delegate when the stream encounters an error or stops
    fileprivate func handleStreamError(bundleID: String, error: Error) {
        logger.error("SCStream error for \(bundleID): \(error.localizedDescription)")
        activeStreams.removeValue(forKey: bundleID)
        activeDelegates.removeValue(forKey: bundleID)
        streamDelegates.removeValue(forKey: bundleID)
    }

    /// Stop all active captures.
    func stopAll() async {
        let bundleIDs = Array(activeStreams.keys)
        for bid in bundleIDs {
            await stopCapture(bundleID: bid)
        }
    }
}

// MARK: - SCStreamDelegate (handles stream errors/stops)

private class AppCaptureStreamDelegate: NSObject, SCStreamDelegate {
    let bundleID: String
    weak var service: AppCaptureService?

    init(bundleID: String, service: AppCaptureService) {
        self.bundleID = bundleID
        self.service = service
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        service?.handleStreamError(bundleID: bundleID, error: error)
    }
}

// MARK: - Stream output delegate

/// Receives audio sample buffers from SCStream and forwards them to the ring buffer.
private class AppStreamDelegate: NSObject, SCStreamOutput {
    let bundleID: String
    let ringBufferWriter: (UnsafePointer<Float>, UInt32, UInt32) -> Void
    let expectedChannelCount: UInt32

    init(bundleID: String,
         ringBufferWriter: @escaping (UnsafePointer<Float>, UInt32, UInt32) -> Void,
         expectedChannelCount: UInt32) {
        self.bundleID = bundleID
        self.ringBufferWriter = ringBufferWriter
        self.expectedChannelCount = expectedChannelCount
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        guard let blockBuffer = sampleBuffer.dataBuffer else { return }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
        guard status == kCMBlockBufferNoErr, let rawPtr = dataPointer else { return }

        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return }

        let asbd = asbdPtr.pointee
        let frameCount = UInt32(CMSampleBufferGetNumSamples(sampleBuffer))
        let channelCount = UInt32(asbd.mChannelsPerFrame)

        guard frameCount > 0 && channelCount > 0 else { return }

        // SCStream delivers Float32 audio. Check if it's interleaved.
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0

        guard isFloat else { return }

        let floatPtr = UnsafeRawPointer(rawPtr).assumingMemoryBound(to: Float.self)

        // Get interleaved audio first
        let interleavedPtr: UnsafePointer<Float>
        var interleavedAlloc: UnsafeMutablePointer<Float>?

        if isInterleaved {
            interleavedPtr = floatPtr
        } else {
            // Non-interleaved: channels are in separate planes. Interleave them.
            let totalSamples = Int(frameCount * channelCount)
            let buf = UnsafeMutablePointer<Float>.allocate(capacity: totalSamples)
            let framesInt = Int(frameCount)
            let chCount = Int(channelCount)
            for ch in 0..<chCount {
                let planePtr = floatPtr.advanced(by: ch * framesInt)
                for frame in 0..<framesInt {
                    buf[frame * chCount + ch] = planePtr[frame]
                }
            }
            interleavedPtr = UnsafePointer(buf)
            interleavedAlloc = buf
        }
        defer { interleavedAlloc?.deallocate() }

        // Remap channels if needed (mono->stereo upmix, or trim to expected count)
        if channelCount == expectedChannelCount {
            ringBufferWriter(interleavedPtr, frameCount, channelCount)
        } else if channelCount == 1 && expectedChannelCount == 2 {
            // Mono to stereo: duplicate the channel
            let stereoSamples = Int(frameCount) * 2
            let stereo = UnsafeMutablePointer<Float>.allocate(capacity: stereoSamples)
            defer { stereo.deallocate() }
            for i in 0..<Int(frameCount) {
                stereo[i * 2] = interleavedPtr[i]
                stereo[i * 2 + 1] = interleavedPtr[i]
            }
            ringBufferWriter(stereo, frameCount, expectedChannelCount)
        } else if channelCount > expectedChannelCount {
            // Trim extra channels
            let outSamples = Int(frameCount * expectedChannelCount)
            let trimmed = UnsafeMutablePointer<Float>.allocate(capacity: outSamples)
            defer { trimmed.deallocate() }
            let srcCh = Int(channelCount)
            let dstCh = Int(expectedChannelCount)
            for frame in 0..<Int(frameCount) {
                for ch in 0..<dstCh {
                    trimmed[frame * dstCh + ch] = interleavedPtr[frame * srcCh + ch]
                }
            }
            ringBufferWriter(trimmed, frameCount, expectedChannelCount)
        } else {
            // Fewer channels than expected but not mono — pad with silence
            let outSamples = Int(frameCount * expectedChannelCount)
            let padded = UnsafeMutablePointer<Float>.allocate(capacity: outSamples)
            defer { padded.deallocate() }
            padded.initialize(repeating: 0.0, count: outSamples)
            let srcCh = Int(channelCount)
            let dstCh = Int(expectedChannelCount)
            for frame in 0..<Int(frameCount) {
                for ch in 0..<srcCh {
                    padded[frame * dstCh + ch] = interleavedPtr[frame * srcCh + ch]
                }
            }
            ringBufferWriter(padded, frameCount, expectedChannelCount)
        }
    }
}

// MARK: - Errors

enum AppCaptureError: LocalizedError {
    case appNotFound(String)
    case noDisplay
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .appNotFound(let bid): return "Application not found: \(bid)"
        case .noDisplay: return "No display available for content filter"
        case .permissionDenied: return "Screen Recording permission not granted"
        }
    }
}
