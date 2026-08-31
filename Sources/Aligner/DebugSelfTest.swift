import AppKit
import ScreenCaptureKit

// Diagnostics that run only with ALIGNER_DEBUG=1 (see README → Debugging).
// Kept out of AppDelegate so the app's real logic stays readable.
extension AppDelegate {
    // MARK: - Debug self-test (ALIGNER_DEBUG=1)

    /// Renders the first overlay view to the PNG named by `ALIGNER_DEBUG_DUMP`.
    func dumpOverlay() {
        guard let path = ProcessInfo.processInfo.environment["ALIGNER_DEBUG_DUMP"],
              let view = overlays.first?.overlayView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
        Debug.log("selftest: dumped \(rep.pixelsWide)x\(rep.pixelsHigh) to \(path)")
    }

    /// Captures the first overlay's display via the sampler, writes the luma to
    /// the PNG named by `ALIGNER_DEBUG_CAPTURE`, and logs the edges found
    /// around the screen centre.
    func dumpCapture() {
        guard let path = ProcessInfo.processInfo.environment["ALIGNER_DEBUG_CAPTURE"],
              let window = overlays.first else { return }
        Debug.log("selftest: screen capture authorized=\(ScreenSampler.isAuthorized)")
        let excluded = overlays.map(\.windowNumber)
        let displayID = window.displayID, frame = window.frame, scale = window.backingScaleFactor
        Task {
            do {
                let map = try await sampler.capture(displayID: displayID, frame: frame, scale: scale, excluding: excluded)
                if let data = map.pngData() { try? data.write(to: URL(fileURLWithPath: path)) }
                let cx = map.width / 2, cy = map.height / 2
                var found: [DetectedEdge] = []
                for y in stride(from: 40, to: map.height - 40, by: 40) {
                    found += EdgeDetector.edges(in: map, orientation: .horizontal, near: y, along: cx, radius: 20)
                }
                for x in stride(from: 40, to: map.width - 40, by: 40) {
                    found += EdgeDetector.edges(in: map, orientation: .vertical, near: x, along: cy, radius: 20)
                }
                Debug.log("selftest: capture dumped to \(path); \(found.count) edges along the centre lines: " +
                          found.prefix(12).map { "\($0.orientation == .horizontal ? "h" : "v")\($0.position)[\($0.start)-\($0.end)] step \($0.step)" }.joined(separator: ", "))
            } catch {
                Debug.log("selftest: capture failed: \(error)")
            }
        }
    }

    /// `ALIGNER_DEBUG_SNAPTEST=1`: drives the first overlay with synthesized
    /// mouse events — a horizontal drag just below the menu bar — and checks
    /// that the committed line lands where `SnapEngine` says the nearest edge
    /// is (computed on a fresh capture, so it doesn't depend on what's under
    /// the menu bar), then repeats with ⌘ held to check the bypass.
    func runSnapTest() {
        guard ProcessInfo.processInfo.environment["ALIGNER_DEBUG_SNAPTEST"] != nil,
              let window = overlays.first else { return }
        let view = window.overlayView
        let raw = NSPoint(x: 600, y: window.frame.maxY - 29)
        let width = LineSettings.shared.style.width
        let excluded = overlays.map(\.windowNumber)
        let displayID = window.displayID, frame = window.frame, scale = window.backingScaleFactor

        func event(_ type: NSEvent.EventType, _ point: NSPoint, _ flags: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: window.convertPoint(fromScreen: point), modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )!
        }

        func drag(from a: NSPoint, to b: NSPoint, flags: NSEvent.ModifierFlags, then: @escaping (Line?) -> Void) {
            let before = LineStore.shared.lines.count
            view.mouseDown(with: event(.leftMouseDown, a, flags))
            // Give the capture time to arrive before finishing the drag.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                view.mouseDragged(with: event(.leftMouseDragged, b, flags))
                view.mouseUp(with: event(.leftMouseUp, b, flags))
                then(LineStore.shared.lines.count > before ? LineStore.shared.lines.last : nil)
            }
        }

        Task {
            guard let map = try? await sampler.capture(displayID: displayID, frame: frame, scale: scale, excluding: excluded) else {
                Debug.log("snaptest: capture failed"); return
            }
            let expected = SnapEngine.snap(map, orientation: .horizontal, value: raw.y, along: raw.x, flushWidth: width, side: raw.y)
            await MainActor.run {
                Debug.log("snaptest: snapToEdges=\(view.snapToEdges) raw y=\(raw.y) expected " +
                          (expected.map { "y=\($0.value) (boundary \($0.edge.position))" } ?? "no edge in range"))
                drag(from: raw, to: NSPoint(x: raw.x + 300, y: raw.y), flags: [.shift]) { line in
                    // With an edge in range the line must sit flush on it; with
                    // none, committing the raw position is the correct result.
                    let ok: Bool
                    if let expected {
                        ok = line != nil && line!.start.y == expected.value && line!.end.y == expected.value
                    } else {
                        ok = line != nil && line!.start.y == raw.y && line!.end.y == raw.y
                    }
                    Debug.log("snaptest snap: \(ok ? "PASS" : "FAIL") committed=\(line.map { "\($0.start)-\($0.end)" } ?? "none")")
                    // A different x range so the second drag doesn't grab the first line.
                    let raw2 = NSPoint(x: 1200, y: raw.y)
                    drag(from: raw2, to: NSPoint(x: 1500, y: raw.y), flags: [.shift, .command]) { line in
                        let ok = line != nil && line!.start.y == raw.y
                        Debug.log("snaptest bypass ⌘: \(ok ? "PASS" : "FAIL") committed=\(line.map { "\($0.start)-\($0.end)" } ?? "none")")
                    }
                }
            }
        }
    }

    /// Asks the window server which window would receive a click at the centre
    /// of each screen, first with capture on and then off, and draws a few
    /// sample lines in different styles so a dump can verify rendering.
    func runDebugSelfTest() {
        func hitTest(_ label: String) {
            for window in overlays {
                let point = NSPoint(x: window.frame.midX, y: window.frame.midY)
                let hit = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
                Debug.log("selftest \(label): window=\(window.windowNumber) hit=\(hit) ours=\(hit == window.windowNumber)")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
            overlays.forEach { $0.setCapturing(true) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                hitTest("capture")
                overlays.forEach { $0.setCapturing(false) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                    hitTest("passthrough")
                    if let frame = overlays.first?.frame {
                        let cx = frame.midX, cy = frame.midY
                        let red = LineStyle(color: LineStyle.presetColors[0].color, width: 1, dash: .solid)
                        let blue = LineStyle(color: LineStyle.presetColors[5].color, width: 2, dash: .dashed)
                        let green = LineStyle(color: LineStyle.presetColors[3].color, width: 3, dash: .dotted)
                        LineStore.shared.add(Line(start: NSPoint(x: cx - 300, y: cy), end: NSPoint(x: cx + 300, y: cy), style: red))
                        LineStore.shared.add(Line(start: NSPoint(x: cx, y: cy - 200), end: NSPoint(x: cx, y: cy + 200), style: blue))
                        LineStore.shared.add(Line(start: NSPoint(x: cx - 150, y: cy - 150), end: NSPoint(x: cx + 150, y: cy + 150), style: green))
                        Debug.log("selftest: added sample lines around (\(cx), \(cy))")
                        dumpOverlay()
                        dumpCapture()
                        runSnapTest()
                    }
                }
            }
        }
    }
}

// MARK: - Demo recording (ALIGNER_DEBUG_GIF=<frames dir>)

extension AppDelegate {
    private enum GifError: Error { case noStage, badTitle, noOverlay, noDisplay }

    private struct Stage {
        var window: SCWindow
        var viewport: CGRect   // CG screen coords (top-left origin), points
        var cards: [CGRect]
        var icons: [CGRect]
    }

    /// Records a scripted demo over `demo/index.html#stage` (open it in a
    /// browser first; the page publishes its layout in the window title):
    /// two ⇧-drags with a drawn cursor, frames written as PNGs for ffmpeg.
    /// Quits when done.
    func runGifDemo() {
        guard let dir = ProcessInfo.processInfo.environment["ALIGNER_DEBUG_GIF"] else { return }
        Task { @MainActor in
            do {
                try await recordDemo(into: URL(fileURLWithPath: dir, isDirectory: true))
            } catch {
                Debug.log("gif: failed: \(error)")
            }
            NSApp.terminate(nil)
        }
    }

    private func findStage() async throws -> Stage {
        for _ in 0..<40 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if let window = content.windows.first(where: { ($0.title ?? "").hasPrefix("stage|") }), let title = window.title {
                Debug.log("gif: stage window frame \(window.frame) title \(title.prefix(80))")
                // stage|innerW,innerH|cardX,cardY,cardW,cardH,gap|iconX,iconY,iconSize
                let parts = title.split(separator: "|").map { $0.split(separator: ",").compactMap { Double($0) } }
                guard parts.count == 4, parts[1].count == 2, parts[2].count == 5, parts[3].count == 3 else { throw GifError.badTitle }
                let frame = window.frame
                let viewport = CGRect(x: frame.minX, y: frame.maxY - parts[1][1], width: parts[1][0], height: parts[1][1])
                let c = parts[2], i = parts[3]
                let pitch = c[2] + c[4]
                let cards = (0..<4).map { CGRect(x: viewport.minX + c[0] + Double($0) * pitch, y: viewport.minY + c[1], width: c[2], height: c[3]) }
                let icons = (0..<4).map { CGRect(x: viewport.minX + i[0] + Double($0) * pitch, y: viewport.minY + i[1], width: i[2], height: i[2]) }
                return Stage(window: window, viewport: viewport, cards: cards, icons: icons)
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw GifError.noStage
    }

    /// Captures a display region at 2× every ~100 ms until stopped. Only the
    /// given windows are composited, so whatever else is on screen — or on
    /// top — never appears in the frames.
    private final class Recorder {
        private let filter: SCContentFilter
        private let configuration: SCStreamConfiguration
        private let directory: URL
        private(set) var frames = 0
        private var running = true
        private var task: Task<Void, Never>?

        init(display: SCDisplay, windows: [SCWindow], region: CGRect, directory: URL) {
            filter = SCContentFilter(display: display, including: windows)
            configuration = SCStreamConfiguration()
            configuration.sourceRect = region
            configuration.width = Int(region.width * 2)
            configuration.height = Int(region.height * 2)
            configuration.showsCursor = false
            configuration.captureResolution = .best
            self.directory = directory
        }

        func start() {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            task = Task.detached(priority: .userInitiated) { [self] in
                while running {
                    let started = ProcessInfo.processInfo.systemUptime
                    if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) {
                        let url = directory.appendingPathComponent(String(format: "frame%04d.png", frames))
                        if let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                            CGImageDestinationAddImage(destination, image, nil)
                            CGImageDestinationFinalize(destination)
                            frames += 1
                        }
                    }
                    let remaining = 0.1 - (ProcessInfo.processInfo.systemUptime - started)
                    if remaining > 0 { try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
                }
            }
        }

        func stop() async {
            running = false
            await task?.value
        }
    }

    @MainActor
    private func recordDemo(into directory: URL) async throws {
        let stage = try await findStage()
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        func appKit(_ cg: CGPoint) -> NSPoint { NSPoint(x: cg.x, y: primaryHeight - cg.y) }

        let centre = appKit(CGPoint(x: stage.viewport.midX, y: stage.viewport.midY))
        guard let overlay = overlays.first(where: { $0.frame.contains(centre) }) else { throw GifError.noOverlay }
        let view = overlay.overlayView
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == overlay.displayID }) else { throw GifError.noDisplay }
        guard let overlayWindow = content.windows.first(where: { Int($0.windowID) == overlay.windowNumber }) else { throw GifError.noOverlay }

        // Record from the top of the viewport to just below the cards.
        let bottom = stage.cards.map(\.maxY).max()! + 28
        let displayOrigin = CGDisplayBounds(overlay.displayID).origin
        let region = CGRect(x: stage.viewport.minX - displayOrigin.x, y: stage.viewport.minY - displayOrigin.y,
                            width: stage.viewport.width, height: bottom - stage.viewport.minY)
        Debug.log("gif: recording region \(region) on display \(overlay.displayID)")

        func local(_ cg: CGPoint) -> NSPoint { view.convert(overlay.convertPoint(fromScreen: appKit(cg)), from: nil) }
        func event(_ type: NSEvent.EventType, _ point: NSPoint, _ flags: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: view.convert(point, to: nil), modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: overlay.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )!
        }
        func settle(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        func glide(from a: NSPoint, to b: NSPoint, duration: Double, dragging: Bool) async {
            let steps = max(1, Int(duration * 60))
            for i in 1...steps {
                let t = Double(i) / Double(steps)
                let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
                let p = NSPoint(x: a.x + (b.x - a.x) * eased, y: a.y + (b.y - a.y) * eased)
                view.virtualCursor = p
                if dragging {
                    view.mouseDragged(with: event(.leftMouseDragged, p, [.shift]))
                } else {
                    view.mouseMoved(with: event(.mouseMoved, p, [.shift]))
                }
                await settle(1.0 / 60)
            }
        }
        func drag(from a: NSPoint, to b: NSPoint, duration: Double) async {
            view.virtualCursor = a
            view.mouseDown(with: event(.leftMouseDown, a, [.shift]))
            await settle(0.4)   // the anchor snaps once the capture lands
            await glide(from: a, to: b, duration: duration, dragging: true)
            await settle(0.5)
            view.mouseUp(with: event(.leftMouseUp, b, [.shift]))
        }

        let cards = stage.cards, icons = stage.icons
        // 1: along the bottom edge of the cards — the 4th card is 6 px taller.
        let bottomY = cards[0].maxY + 3
        let d1a = local(CGPoint(x: cards[0].minX + 24, y: bottomY)), d1b = local(CGPoint(x: cards[3].maxX - 24, y: bottomY))
        // 2: along the top edge of the icons — the 2nd icon is 4 px high.
        // Start and end at the icons' centres, clear of their rounded corners.
        let iconY = icons[0].minY - 3
        let d2a = local(CGPoint(x: icons[0].midX, y: iconY)), d2b = local(CGPoint(x: icons[3].midX, y: iconY))
        let rest = local(CGPoint(x: cards[1].midX, y: cards[0].maxY + 70))

        // Keep the real modifier keys and pointer out of it: the demo feeds its
        // own events, and the overlay stays click-through for the user.
        watcher.onChange = nil
        watcher.onFlagsChange = nil
        view.scripted = true
        view.virtualCursor = rest
        let recorder = Recorder(display: display, windows: [stage.window, overlayWindow], region: region, directory: directory)
        recorder.start()
        await settle(0.9)
        await glide(from: rest, to: d1a, duration: 0.7, dragging: false)
        await settle(0.3)
        await drag(from: d1a, to: d1b, duration: 1.8)
        await settle(0.7)
        await glide(from: d1b, to: d2a, duration: 0.9, dragging: false)
        await settle(0.3)
        await drag(from: d2a, to: d2b, duration: 1.8)
        await settle(2.0)
        await recorder.stop()
        view.scripted = false
        view.virtualCursor = nil
        Debug.log("gif: wrote \(recorder.frames) frames to \(directory.path)")
    }
}
