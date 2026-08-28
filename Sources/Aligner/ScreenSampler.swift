import AppKit
import ScreenCaptureKit

/// Captures a display — minus our own overlay windows — as an `EdgeMap`.
/// Needs Screen Recording permission.
actor ScreenSampler {
    static var isAuthorized: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt if the user hasn't decided yet. Returns true
    /// only if access is already granted.
    @discardableResult
    static func requestAuthorization() -> Bool { CGRequestScreenCaptureAccess() }

    enum SamplerError: Error {
        case noDisplay
        case conversionFailed
    }

    private var cachedContent: SCShareableContent?
    private var cachedAt: TimeInterval = 0

    func invalidateCache() {
        cachedContent = nil
    }

    func capture(
        displayID: CGDirectDisplayID,
        frame: NSRect,
        scale: CGFloat,
        excluding windowNumbers: [Int]
    ) async throws -> EdgeMap {
        let content = try await shareableContent()
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw SamplerError.noDisplay
        }
        let excluded = content.windows.filter { windowNumbers.contains(Int($0.windowID)) }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)

        let configuration = SCStreamConfiguration()
        configuration.width = Int((CGFloat(display.width) * scale).rounded())
        configuration.height = Int((CGFloat(display.height) * scale).rounded())
        configuration.showsCursor = false
        configuration.captureResolution = .best
        configuration.pixelFormat = kCVPixelFormatType_32BGRA

        let started = ProcessInfo.processInfo.systemUptime
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        guard let map = EdgeMap(image: image, frame: frame) else { throw SamplerError.conversionFailed }
        let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
        Debug.log("capture display \(displayID): \(map.width)x\(map.height), excluded \(excluded.count) windows, \(elapsed) ms")
        return map
    }

    private func shareableContent() async throws -> SCShareableContent {
        let now = ProcessInfo.processInfo.systemUptime
        if let cachedContent, now - cachedAt < 5 { return cachedContent }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        cachedContent = content
        cachedAt = now
        return content
    }
}
