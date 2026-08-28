import AppKit
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var helpItems: [NSMenuItem] = []
    private var enabledItem: NSMenuItem!
    private var modifierItems: [DrawModifier: NSMenuItem] = [:]
    private var colorItems: [NSMenuItem] = []
    private var customColorItem: NSMenuItem!
    private var widthItems: [NSMenuItem] = []
    private var dashItems: [DashStyle: NSMenuItem] = [:]

    private var overlays: [OverlayWindow] = []
    private let watcher = ModifierWatcher(required: DrawModifier.default.flags)
    private let hotKeys = HotKeyCenter()

    private enum Keys {
        static let enabled = "enabled"
        static let modifier = "modifier"
    }

    private var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Keys.enabled) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Keys.enabled) }
    }

    private var modifier: DrawModifier {
        get {
            UserDefaults.standard.string(forKey: Keys.modifier)
                .flatMap(DrawModifier.init(rawValue:)) ?? .default
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Keys.modifier) }
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        watcher.required = modifier.flags
        watcher.onChange = { [weak self] _ in self?.updateCapture() }
        watcher.onTap = { count in
            // Fires on every tap, so a triple-tap undoes on the second tap and
            // clears on the third — same end state, no waiting for a timeout.
            switch count {
            case 2: LineStore.shared.undo()
            case 3: LineStore.shared.clear()
            default: break
            }
        }

        buildStatusItem()
        rebuildOverlays()
        watcher.start()
        registerHotKeys()

        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(refreshMenuState),
            name: LineSettings.didChange,
            object: nil
        )

        if Debug.enabled { runDebugSelfTest() }
    }

    // MARK: - Overlays

    private func rebuildOverlays() {
        for window in overlays {
            window.orderOut(nil)
            window.close()
        }
        overlays = NSScreen.screens.map(OverlayWindow.init(screen:))
        for window in overlays {
            window.orderFrontRegardless()
        }
        Debug.log("overlays: \(overlays.map { "\($0.windowNumber)@\($0.frame)" })")
        updateCapture()
    }

    @objc private func screensChanged() {
        rebuildOverlays()
    }

    private func updateCapture() {
        let capture = isEnabled && watcher.isHeld
        for window in overlays {
            window.setCapturing(capture)
        }
    }

    // MARK: - Status item & menu

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "line.diagonal", accessibilityDescription: "Aligner") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "╱"
            }
            button.toolTip = "Aligner"
        }

        let menu = NSMenu()

        enabledItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        enabledItem.target = self
        menu.addItem(enabledItem)
        menu.addItem(.separator())

        let undo = NSMenuItem(title: "Undo Last Line", action: #selector(undoLine), keyEquivalent: "z")
        undo.keyEquivalentModifierMask = [.control, .option, .command]
        undo.target = self
        menu.addItem(undo)

        let clear = NSMenuItem(title: "Clear All Lines", action: #selector(clearLines), keyEquivalent: "c")
        clear.keyEquivalentModifierMask = [.control, .option, .command]
        clear.target = self
        menu.addItem(clear)
        menu.addItem(.separator())

        menu.addItem(submenuItem("Color", colorMenu()))
        menu.addItem(submenuItem("Thickness", widthMenu()))
        menu.addItem(submenuItem("Style", dashMenu()))
        menu.addItem(submenuItem("Draw While Holding", modifierMenu()))
        menu.addItem(.separator())

        menu.addItem(submenuItem("Help", helpMenu()))
        let quit = NSMenuItem(title: "Quit Aligner", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
        refreshMenuState()
    }

    private func submenuItem(_ title: String, _ submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private func colorMenu() -> NSMenu {
        let menu = NSMenu()
        for (index, preset) in LineStyle.presetColors.enumerated() {
            let item = NSMenuItem(title: preset.name, action: #selector(selectPresetColor(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.image = Self.swatch(preset.color)
            menu.addItem(item)
            colorItems.append(item)
        }
        menu.addItem(.separator())
        customColorItem = NSMenuItem(title: "Custom…", action: #selector(showColorPanel), keyEquivalent: "")
        customColorItem.target = self
        menu.addItem(customColorItem)
        return menu
    }

    private func widthMenu() -> NSMenu {
        let menu = NSMenu()
        for (index, width) in LineStyle.widths.enumerated() {
            let item = NSMenuItem(title: LineStyle.title(forWidth: width), action: #selector(selectWidth(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            menu.addItem(item)
            widthItems.append(item)
        }
        return menu
    }

    private func dashMenu() -> NSMenu {
        let menu = NSMenu()
        for dash in DashStyle.allCases {
            let item = NSMenuItem(title: dash.title, action: #selector(selectDash(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = dash.rawValue
            menu.addItem(item)
            dashItems[dash] = item
        }
        return menu
    }

    /// Gesture and shortcut reference. `{m}` is replaced with the current
    /// draw modifier's symbol. Entries are plain items with a no-op action so
    /// they render in full contrast rather than greyed out.
    private static let helpEntries: [String?] = [
        "Draw a line:  hold {m} and drag",
        "Move a line:  hold {m} and drag it",
        "Reshape a line:  hold {m} and drag an endpoint handle (the other end stays put)",
        "Stretch a line across the screen:  hold {m} and double-click it",
        nil,
        "Undo the last line:  double-tap {m}, or ⌃⌥⌘Z",
        "Clear all lines:  triple-tap {m}, or ⌃⌥⌘C",
        nil,
        "Pause Aligner:  uncheck Enabled ({m}-clicks reach other apps again)",
    ]

    private func helpMenu() -> NSMenu {
        let menu = NSMenu()
        for entry in Self.helpEntries {
            guard entry != nil else {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: "", action: #selector(helpItemClicked), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            helpItems.append(item)
        }
        return menu
    }

    @objc private func helpItemClicked() {}

    private func modifierMenu() -> NSMenu {
        let menu = NSMenu()
        for candidate in DrawModifier.allCases {
            let item = NSMenuItem(title: candidate.title, action: #selector(selectModifier(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = candidate.rawValue
            menu.addItem(item)
            modifierItems[candidate] = item
        }
        return menu
    }

    @objc private func refreshMenuState() {
        let current = modifier
        let entries = Self.helpEntries.compactMap { $0 }
        for (item, entry) in zip(helpItems, entries) {
            item.title = entry.replacingOccurrences(of: "{m}", with: current.symbol)
        }
        enabledItem.state = isEnabled ? .on : .off
        for (candidate, item) in modifierItems {
            item.state = candidate == current ? .on : .off
        }

        let style = LineSettings.shared.style
        let presetIndex = LineStyle.presetColors.firstIndex { LineStyle.sameColor($0.color, style.color) }
        for (index, item) in colorItems.enumerated() {
            item.state = index == presetIndex ? .on : .off
        }
        customColorItem.state = presetIndex == nil ? .on : .off
        customColorItem.image = presetIndex == nil ? Self.swatch(style.color) : nil
        for (index, item) in widthItems.enumerated() {
            item.state = LineStyle.widths[index] == style.width ? .on : .off
        }
        for (dash, item) in dashItems {
            item.state = dash == style.dash ? .on : .off
        }
    }

    private static func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
            color.setFill()
            path.fill()
            NSColor.labelColor.withAlphaComponent(0.35).setStroke()
            path.lineWidth = 1
            path.stroke()
            return true
        }
    }

    // MARK: - Actions

    @objc private func toggleEnabled() {
        isEnabled.toggle()
        refreshMenuState()
        updateCapture()
    }

    @objc private func undoLine() {
        LineStore.shared.undo()
    }

    @objc private func clearLines() {
        LineStore.shared.clear()
    }

    @objc private func selectModifier(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let selected = DrawModifier(rawValue: raw) else { return }
        modifier = selected
        watcher.required = selected.flags
        refreshMenuState()
        updateCapture()
    }

    @objc private func selectPresetColor(_ sender: NSMenuItem) {
        guard LineStyle.presetColors.indices.contains(sender.tag) else { return }
        LineSettings.shared.style.color = LineStyle.presetColors[sender.tag].color
    }

    @objc private func selectWidth(_ sender: NSMenuItem) {
        guard LineStyle.widths.indices.contains(sender.tag) else { return }
        LineSettings.shared.style.width = LineStyle.widths[sender.tag]
    }

    @objc private func selectDash(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let dash = DashStyle(rawValue: raw) else { return }
        LineSettings.shared.style.dash = dash
    }

    @objc private func showColorPanel() {
        let panel = NSColorPanel.shared
        panel.showsAlpha = true
        panel.isContinuous = true
        panel.color = LineSettings.shared.style.color
        panel.setTarget(self)
        panel.setAction(#selector(colorPanelChanged(_:)))
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func colorPanelChanged(_ sender: NSColorPanel) {
        LineSettings.shared.style.color = sender.color
    }

    // MARK: - Hotkeys

    private func registerHotKeys() {
        let mods = controlKey | optionKey | cmdKey
        hotKeys.register(keyCode: kVK_ANSI_Z, modifiers: mods) { LineStore.shared.undo() }
        hotKeys.register(keyCode: kVK_ANSI_C, modifiers: mods) { LineStore.shared.clear() }
    }

    // MARK: - Debug self-test (ALIGNER_DEBUG=1)

    /// Renders the first overlay view to the PNG named by `ALIGNER_DEBUG_DUMP`.
    private func dumpOverlay() {
        guard let path = ProcessInfo.processInfo.environment["ALIGNER_DEBUG_DUMP"],
              let view = overlays.first?.overlayView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
        Debug.log("selftest: dumped \(rep.pixelsWide)x\(rep.pixelsHigh) to \(path)")
    }

    /// Asks the window server which window would receive a click at the centre
    /// of each screen, first with capture on and then off, and draws a few
    /// sample lines in different styles so a dump can verify rendering.
    private func runDebugSelfTest() {
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
                    }
                }
            }
        }
    }
}
