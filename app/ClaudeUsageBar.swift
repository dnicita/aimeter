import SwiftUI
import AppKit
import WebKit
import Carbon
import Security

// MARK: - Keychain helper (fork: store the claude.ai session cookie securely)
//
// The cookie carries `sessionKey`, which grants full account access. Upstream
// stored it in plaintext in UserDefaults (~/Library/Preferences/com.claude.usagebar.plist),
// readable by any process running as the user and included in unencrypted backups.
// We keep it in the login Keychain, device-only (never synced to iCloud / backups).
enum KeychainHelper {
    static let service = "com.danielenicita.aimeter"
    static let legacyService = "com.claude.usagebar"   // pre-rebrand, for cookie migration
    static let account = "claude_session_cookie"

    @discardableResult
    static func save(_ value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        // Delete any existing item first, then add fresh.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)

        var attrs = query
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attrs as CFDictionary, nil)
        if status != errSecSuccess {
            NSLog("🔐 Keychain save failed: \(status)")
        }
        return status == errSecSuccess
    }

    static func load(from svc: String = service) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: svc,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

// MARK: - Login item manager (fork: actually register at login)
//
// Upstream's "Open at Login" toggle only wrote a bool to UserDefaults and never
// registered anything with the OS, so the app never launched at login.
//
// We use a per-user LaunchAgent (~/Library/LaunchAgents/com.claude.usagebar.plist)
// instead of SMAppService, because this app is ad-hoc signed (no Team ID) for
// personal use, and SMAppService.register() is unreliable / often silently fails
// or stays in "requiresApproval" without a Developer ID. A LaunchAgent works
// regardless of signing, launches the app at login via `open`, and is verifiable
// with `launchctl list | grep com.claude.usagebar`.
enum LoginItemManager {
    static let label = "com.danielenicita.aimeter"
    static let legacyLabel = "com.claude.usagebar"   // pre-rebrand

    static var plistURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    private static var legacyPlistURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/LaunchAgents/\(legacyLabel).plist")
    }

    /// One-shot: if a pre-rebrand login item exists, carry the "launch at login"
    /// preference over to the new label, then remove the old agent + app.
    static func migrateFromLegacy() {
        guard FileManager.default.fileExists(atPath: legacyPlistURL.path) else { return }
        NSLog("🚀 Migrating legacy login item → AIMeter")
        setEnabled(true)                                       // register new agent for this app
        let uid = getuid()
        runLaunchctl(["bootout", "gui/\(uid)/\(legacyLabel)"]) // stop old
        try? FileManager.default.removeItem(at: legacyPlistURL)
        // Remove the old renamed app so it can't launch at boot anymore.
        try? FileManager.default.removeItem(atPath: "/Applications/ClaudeUsageBar.app")
    }

    static var isAvailable: Bool { true }

    /// We treat "plist present" as enabled — it's what determines launch-at-login.
    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static var statusDescription: String {
        isEnabled ? "Enabled (LaunchAgent)" : "Not registered"
    }

    @discardableResult
    private static func runLaunchctl(_ args: [String]) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = args
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus
        } catch {
            NSLog("❌ launchctl \(args.joined(separator: " ")) failed: \(error.localizedDescription)")
            return -1
        }
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        let uid = getuid()
        let domain = "gui/\(uid)"
        if enabled {
            // Launch the .app bundle (not the raw binary) so it starts in the GUI
            // session exactly as a double-click would.
            let appPath = Bundle.main.bundlePath
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>\(label)</string>
                <key>ProgramArguments</key>
                <array>
                    <string>/usr/bin/open</string>
                    <string>\(appPath)</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
                <key>ProcessType</key>
                <string>Interactive</string>
            </dict>
            </plist>
            """
            do {
                let dir = plistURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try plist.write(to: plistURL, atomically: true, encoding: .utf8)
            } catch {
                NSLog("❌ Could not write LaunchAgent plist: \(error.localizedDescription)")
                return false
            }
            // Reload so it's active immediately (ignore bootout errors if not loaded).
            runLaunchctl(["bootout", "\(domain)/\(label)"])
            let status = runLaunchctl(["bootstrap", domain, plistURL.path])
            NSLog("🚀 LaunchAgent installed at \(plistURL.path), bootstrap status: \(status)")
            // Even if bootstrap is non-zero (e.g. already loaded), the plist will
            // run at next login, so treat plist-on-disk as success.
            return true
        } else {
            runLaunchctl(["bootout", "\(domain)/\(label)"])
            try? FileManager.default.removeItem(at: plistURL)
            NSLog("🚀 LaunchAgent removed")
            return true
        }
    }
}

// MARK: - Per-window identity palette
// Session=green, Weekly=blue, Sonnet=orange. Red = "limit reached" alarm.
enum Palette {
    static let sessionNS = NSColor(srgbRed: 0.18, green: 0.82, blue: 0.35, alpha: 1) // #30D158
    static let weeklyNS  = NSColor(srgbRed: 0.35, green: 0.78, blue: 0.98, alpha: 1) // #5AC8FA bright sky blue
    static let sonnetNS  = NSColor(srgbRed: 1.00, green: 0.62, blue: 0.04, alpha: 1) // #FF9F0A
    static let alertNS   = NSColor(srgbRed: 1.00, green: 0.23, blue: 0.19, alpha: 1) // red
    static let warnNS    = NSColor(srgbRed: 1.00, green: 0.80, blue: 0.00, alpha: 1) // yellow

    static let session = Color(.sRGB, red: 0.18, green: 0.82, blue: 0.35)
    static let weekly  = Color(.sRGB, red: 0.35, green: 0.78, blue: 0.98)
    static let sonnet  = Color(.sRGB, red: 1.00, green: 0.62, blue: 0.04)
    static let alert   = Color(.sRGB, red: 1.00, green: 0.23, blue: 0.19)

    /// Linear sRGB interpolation between two NSColors.
    static func lerp(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
        let ca = a.usingColorSpace(.sRGB) ?? a
        let cb = b.usingColorSpace(.sRGB) ?? b
        let k = max(0, min(1, t))
        return NSColor(srgbRed: ca.redComponent   + (cb.redComponent   - ca.redComponent)   * k,
                       green:   ca.greenComponent + (cb.greenComponent - ca.greenComponent) * k,
                       blue:    ca.blueComponent  + (cb.blueComponent  - ca.blueComponent)  * k,
                       alpha: 1)
    }
}

// Main entry point
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var usageManager: UsageManager!
    var statusManager: StatusManager!
    var updateManager: UpdateManager!
    var eventMonitor: Any?
    var hotKeyRef: EventHotKeyRef?
    var usageTimer: Timer?
    // Last measured SwiftUI content height; used to size the popover before showing.
    var lastPopoverHeight: CGFloat = 360
    // Menu-bar icon / blink state
    var lastSessionPercent: Int = 0
    var blinkTimer: Timer?           // 0.1s master tick, runs only while blinking
    var titleRefreshTimer: Timer?    // refreshes menu-bar countdown text
    var blinkTick: Int = 0
    var ringBlinkOn: Bool = true     // blink phase of the session ring (low-quota alarm)
    var statusBlinkOn: Bool = true   // blink phase of the center status dot (outage)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // NSUserNotification (deprecated but works without permissions for unsigned apps)
        NSLog("✅ App launched, notifications ready")

        // One-shot rebrand migration: carry the old login item over to AIMeter.
        LoginItemManager.migrateFromLegacy()

        // Create status bar item with variable length for compact display
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            // Create Claude logo as initial icon
            updateStatusIcon(percentage: 0)
            button.action = #selector(handleClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.target = self

            // Force the button to be visible
            button.appearsDisabled = false
            button.isEnabled = true
        }

        // Initialize managers
        usageManager = UsageManager(statusItem: statusItem, delegate: self)
        statusManager = StatusManager()
        updateManager = UpdateManager()

        // Refresh the menu-bar icon (center status dot) whenever service status changes.
        statusManager.onStatusChange = { [weak self] in self?.redrawStatusIcon() }

        // Create popover
        popover = NSPopover()
        popover.contentSize = NSSize(width: 360, height: 360)
        popover.behavior = .transient
        let hosting = NSHostingController(rootView: UsageView(
            usageManager: usageManager,
            statusManager: statusManager,
            updateManager: updateManager
        ))
        // Don't let the hosting controller auto-grow the popover from SwiftUI's
        // intrinsic size — that growth happens AFTER positioning and pushes the
        // top off-screen. We size the popover ourselves via setPopoverHeight().
        if #available(macOS 13.0, *) {
            hosting.sizingOptions = []
        }
        popover.contentViewController = hosting

        // Fetch initial data
        usageManager.fetchUsage()
        statusManager.fetch()
        // Update check disabled in this fork (it pointed at the upstream repo and
        // would advertise "ClaudeUsageBar" releases).

        // Usage + Anthropic status are time-sensitive — poll on the configured interval.
        restartUsageTimer()

        // Set up Cmd+U keyboard shortcut
        setupKeyboardShortcut()

        // Refresh the menu-bar countdown text once a minute (the icon otherwise only
        // redraws on fetch/blink, which would leave countdowns stale).
        titleRefreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.drawIcon()
        }
        reconfigureBlink()
    }

    /// (Re)create the usage/status poll timer using the user's configured interval.
    /// Called at launch and whenever the interval changes in Settings.
    func restartUsageTimer() {
        usageTimer?.invalidate()
        let seconds = TimeInterval(max(1, usageManager.refreshIntervalMinutes) * 60)
        usageTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            self?.usageManager.fetchUsage()
            self?.statusManager.fetch()
        }
        NSLog("⏱️ Usage poll timer set to every \(usageManager.refreshIntervalMinutes) min")
    }

    func setupKeyboardShortcut() {
        // Don't nag with a modal at every launch. Just record the current status
        // (used by the in-popover Settings UI) and register the hotkey only if the
        // user has explicitly enabled it. If Accessibility is missing, the Settings
        // panel shows a "Grant Accessibility Permission" button instead.
        usageManager.checkAccessibilityStatus()

        if usageManager.shortcutEnabled {
            registerGlobalHotKey()
        }
    }

    func setShortcutEnabled(_ enabled: Bool) {
        if enabled {
            registerGlobalHotKey()
        } else {
            unregisterGlobalHotKey()
        }
    }

    func checkAccessibilityPermissions() {
        // Check if app has Accessibility permissions
        let trusted = AXIsProcessTrusted()

        if !trusted {
            NSLog("⚠️ Accessibility permissions not granted")
            // Show alert to guide user
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let alert = NSAlert()
                alert.messageText = "Accessibility Permission Required"
                alert.informativeText = "AIMeter needs Accessibility permission to use the Cmd+U keyboard shortcut.\n\nPlease enable it in:\nSystem Settings → Privacy & Security → Accessibility"
                alert.alertStyle = .informational
                alert.addButton(withTitle: "Open System Settings")
                alert.addButton(withTitle: "Skip for Now")

                let response = alert.runModal()
                if response == .alertFirstButtonReturn {
                    // Open System Settings
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
            }
        } else {
            NSLog("✅ Accessibility permissions granted")
        }
    }

    func registerGlobalHotKey() {
        // Guard against double registration
        if hotKeyRef != nil { return }

        var hotKeyID = EventHotKeyID()
        // Use simple numeric ID instead of FourCharCode
        hotKeyID.signature = 0x436C5542 // 'ClUB' as hex
        hotKeyID.id = 1

        // Cmd+U key code
        let keyCode: UInt32 = 32 // 'U' key
        let modifiers: UInt32 = UInt32(cmdKey)

        // Create event spec for hotkey
        var eventType = EventTypeSpec()
        eventType.eventClass = OSType(kEventClassKeyboard)
        eventType.eventKind = OSType(kEventHotKeyPressed)

        // Install event handler
        var handler: EventHandlerRef?
        let callback: EventHandlerUPP = { (nextHandler, event, userData) -> OSStatus in
            // Get the AppDelegate instance
            let appDelegate = Unmanaged<AppDelegate>.fromOpaque(userData!).takeUnretainedValue()

            // Toggle popover
            DispatchQueue.main.async {
                appDelegate.togglePopover()
            }

            return noErr
        }

        // Install the handler
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType, selfPtr, &handler)

        // Register the hotkey
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)

        if status == noErr {
            NSLog("✅ Registered Cmd+U hotkey successfully")
        } else {
            NSLog("❌ Failed to register hotkey, status: \(status)")
        }
    }

    func unregisterGlobalHotKey() {
        if let hotKey = hotKeyRef {
            UnregisterEventHotKey(hotKey)
            hotKeyRef = nil
            NSLog("🗑️ Unregistered Cmd+U hotkey")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        unregisterGlobalHotKey()
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    @objc func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            openPopover()
        }
    }

    @objc func handleClick() {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            // Right click - show menu
            let menu = NSMenu()
            let toggleItem = NSMenuItem(title: "Toggle Usage (⌘U)", action: #selector(togglePopover), keyEquivalent: "u")
            toggleItem.keyEquivalentModifierMask = .command
            menu.addItem(toggleItem)
            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem(title: "Quit AIMeter", action: #selector(quitApp), keyEquivalent: "q"))
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            // Left click - toggle popover
            togglePopover()
        }
    }

    func openPopover() {
        if let button = statusItem.button {
            // Force UI refresh by updating percentages
            DispatchQueue.main.async {
                self.usageManager.updatePercentages()
            }

            // Drive the popover size EXPLICITLY from the last known content height
            // before showing. If we let NSPopover auto-grow after the SwiftUI content
            // measures itself, it expands upward (anchored at the bottom) and pushes
            // the top off the screen. Setting contentSize ourselves makes NSPopover
            // place and keep the window on-screen.
            popover.contentSize = NSSize(width: 360, height: clampedPopoverHeight(lastPopoverHeight))
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

            // Add event monitor to detect clicks outside the popover
            eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                if self?.popover.isShown == true {
                    self?.closePopover()
                }
            }
        }
    }

    func closePopover() {
        popover.performClose(nil)

        // Remove event monitor
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    /// Clamp a desired popover height to what fits below the menu bar on screen.
    func clampedPopoverHeight(_ h: CGFloat) -> CGFloat {
        let maxH = (NSScreen.main?.visibleFrame.height ?? 800) - 20
        return min(max(h, 120), maxH)
    }

    /// Called by the SwiftUI view when its content height changes. Keeps the
    /// popover sized to the content and repositions it on-screen (NSPopover keeps
    /// the window visible when you set contentSize explicitly).
    func setPopoverHeight(_ h: CGFloat) {
        let clamped = clampedPopoverHeight(h)
        lastPopoverHeight = clamped
        if popover.isShown {
            popover.contentSize = NSSize(width: 360, height: clamped)
        }
    }

    var blinkEnabled: Bool { usageManager?.blinkEnabled ?? true }

    /// Entry point used on each usage fetch.
    func updateStatusIcon(percentage: Int) {
        lastSessionPercent = percentage
        reconfigureBlink()
        drawIcon()
    }

    /// Redraw without changing the percentage (status change, settings toggle).
    func redrawStatusIcon() {
        reconfigureBlink()
        drawIcon()
    }

    /// Session ring color: exactly the primary-% green, ramping to red only in the
    /// final danger zone (>75% used → green→red, full red at 100%).
    func sessionRingColor(_ percent: Int) -> NSColor {
        if percent <= 75 { return Palette.sessionNS }   // same green as the % text
        let t = CGFloat(min(1.0, Double(percent - 75) / 25.0))
        return Palette.lerp(Palette.sessionNS, Palette.alertNS, t)
    }

    /// Center status-dot color from the (filtered) service indicator. nil = no dot.
    func statusDotColor() -> NSColor? {
        switch statusManager?.effectiveIndicator {
        case "minor":            return Palette.warnNS    // yellow
        case "major", "critical": return Palette.alertNS  // red
        default:                 return nil
        }
    }

    /// Start/stop the 0.1s master blink timer based on whether the session ring is
    /// in the low-quota alarm zone (>75%) or a tracked service is down. Idle otherwise.
    func reconfigureBlink() {
        let danger = blinkEnabled && lastSessionPercent > 75
        let outage = blinkEnabled && statusDotColor() != nil
        if danger || outage {
            if blinkTimer == nil {
                blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                    self?.blinkTickFired()
                }
            }
        } else {
            blinkTimer?.invalidate(); blinkTimer = nil
            ringBlinkOn = true
            statusBlinkOn = true
        }
    }

    private func blinkTickFired() {
        blinkTick &+= 1
        // Ring alarm: full cycle 1.0s at 75% → ~0.4s near 100% (accelerates).
        let frac = max(0.0, min(1.0, Double(lastSessionPercent - 75) / 25.0))
        let ringHalf = max(2, Int((0.5 - 0.3 * frac) / 0.1 + 0.5))  // ticks per half-cycle
        let newRing = (blinkTick / ringHalf) % 2 == 0
        // Status dot: fixed slow 0.6s half-cycle (1.2s) → a rhythm clearly distinct
        // from the faster, accelerating ring alarm.
        let newStatus = (blinkTick / 6) % 2 == 0
        if newRing != ringBlinkOn || newStatus != statusBlinkOn {
            ringBlinkOn = newRing
            statusBlinkOn = newStatus
            drawIcon()
        }
    }

    /// Pure render of the menu-bar icon + colored title from current state.
    func drawIcon() {
        guard let button = statusItem.button else { return }
        let percent = lastSessionPercent
        let dangerActive = blinkEnabled && percent > 75
        let drawRing = !(dangerActive && !ringBlinkOn)
        let dot = statusDotColor()
        let drawDot = dot != nil && !(blinkEnabled && !statusBlinkOn)

        button.image = createRingIcon(percentage: percent,
                                      color: sessionRingColor(percent),
                                      drawRing: drawRing,
                                      dotColor: drawDot ? dot : nil)
        button.attributedTitle = menuBarTitle()
    }

    /// Colored menu-bar text: session % (+optional bits), then weekly, then sonnet.
    /// Differentiated by color (no letter tags). Extras are behind Settings toggles.
    func menuBarTitle() -> NSAttributedString {
        let s = NSMutableAttributedString()
        func seg(_ text: String, _ color: NSColor) {
            s.append(NSAttributedString(string: text, attributes: [.foregroundColor: color]))
        }
        guard let um = usageManager else { return NSAttributedString(string: " \(lastSessionPercent)%") }

        seg(" \(lastSessionPercent)%", Palette.sessionNS)
        if um.showSessionTimer, let t = um.sessionResetCountdown { seg(" \(t)", Palette.sessionNS) }

        // Weekly: % and timer are independent toggles.
        if um.showWeeklyPercent || um.showWeeklyTimer {
            var parts: [String] = []
            if um.showWeeklyPercent { parts.append("\(um.weeklyUsage)%") }
            if um.showWeeklyTimer, let t = um.weeklyResetCountdown { parts.append(t) }
            if !parts.isEmpty { seg("  " + parts.joined(separator: " "), Palette.weeklyNS) }
        }
        if um.showSonnetPercent, um.hasWeeklySonnet {
            seg("  \(um.weeklySonnetUsage)%", Palette.sonnetNS)
            // Sonnet reset timer only if it differs from the weekly reset.
            if let st = um.weeklySonnetResetsAt, st != um.weeklyResetsAt,
               let t = um.sonnetResetCountdown {
                seg(" \(t)", Palette.sonnetNS)
            }
        }
        return s
    }

    /// Progress ring: faint track + arc that fills clockwise with `percentage`.
    /// `drawRing=false` hides the ring for the alarm-blink off-phase. A center dot
    /// (if `dotColor` set) flags a service disruption.
    func createRingIcon(percentage: Int, color: NSColor, drawRing: Bool = true, dotColor: NSColor? = nil) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size)
        let center = NSPoint(x: 8, y: 8)
        let radius: CGFloat = 6
        let lineWidth: CGFloat = 2.4
        let fraction = max(0.0, min(1.0, Double(percentage) / 100.0))

        image.lockFocus()

        if drawRing {
            // Faint full track so an empty/low ring is still visible.
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = lineWidth
            color.withAlphaComponent(0.22).setStroke()
            track.stroke()

            // Progress arc: from the top (90°), clockwise, filling with usage.
            if fraction > 0 {
                let endAngle = 90 - CGFloat(fraction * 360.0)
                let progress = NSBezierPath()
                progress.appendArc(withCenter: center, radius: radius,
                                   startAngle: 90, endAngle: endAngle, clockwise: true)
                progress.lineWidth = lineWidth
                progress.lineCapStyle = .round
                color.setStroke()
                progress.stroke()
            }

            // Punch 4 small gaps at 12/3/6/9 o'clock by erasing short arcs.
            if let ctx = NSGraphicsContext.current {
                ctx.compositingOperation = .clear
                let halfGap: CGFloat = 8   // degrees on each side of the tick
                for c in [90, 0, 270, 180] as [CGFloat] {
                    let gap = NSBezierPath()
                    gap.appendArc(withCenter: center, radius: radius,
                                  startAngle: c - halfGap, endAngle: c + halfGap)
                    gap.lineWidth = lineWidth + 2
                    NSColor.black.setStroke()
                    gap.stroke()
                }
                ctx.compositingOperation = .sourceOver
            }
        }

        // Center status dot (only the primary/session ring carries it).
        if let dotColor = dotColor {
            let dotRadius: CGFloat = 3.6
            let dot = NSBezierPath(ovalIn: NSRect(x: center.x - dotRadius, y: center.y - dotRadius,
                                                  width: dotRadius * 2, height: dotRadius * 2))
            dotColor.setFill()
            dot.fill()
        }

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    func createSparkIcon(color: NSColor) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size)

        image.lockFocus()

        // SVG path: M8 1L9 6L13 3L10 7L15 8L10 9L13 13L9 10L8 15L7 10L3 13L6 9L1 8L6 7L3 3L7 6L8 1Z
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 8, y: 1))
        path.line(to: NSPoint(x: 9, y: 6))
        path.line(to: NSPoint(x: 13, y: 3))
        path.line(to: NSPoint(x: 10, y: 7))
        path.line(to: NSPoint(x: 15, y: 8))
        path.line(to: NSPoint(x: 10, y: 9))
        path.line(to: NSPoint(x: 13, y: 13))
        path.line(to: NSPoint(x: 9, y: 10))
        path.line(to: NSPoint(x: 8, y: 15))
        path.line(to: NSPoint(x: 7, y: 10))
        path.line(to: NSPoint(x: 3, y: 13))
        path.line(to: NSPoint(x: 6, y: 9))
        path.line(to: NSPoint(x: 1, y: 8))
        path.line(to: NSPoint(x: 6, y: 7))
        path.line(to: NSPoint(x: 3, y: 3))
        path.line(to: NSPoint(x: 7, y: 6))
        path.close()

        color.setFill()
        path.fill()

        image.unlockFocus()
        image.isTemplate = false

        return image
    }
}

// NSColor extension for hex conversion
extension NSColor {
    var hexString: String {
        guard let rgbColor = self.usingColorSpace(.deviceRGB) else {
            return "#000000"
        }
        let r = Int(rgbColor.redComponent * 255)
        let g = Int(rgbColor.greenComponent * 255)
        let b = Int(rgbColor.blueComponent * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

// Main entry point
@main
struct Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

class UsageManager: ObservableObject {
    @Published var sessionUsage: Int = 0
    @Published var sessionLimit: Int = 100
    @Published var weeklyUsage: Int = 0
    @Published var weeklyLimit: Int = 100
    @Published var weeklySonnetUsage: Int = 0
    @Published var weeklySonnetLimit: Int = 100
    @Published var sessionResetsAt: Date?
    @Published var weeklyResetsAt: Date?
    @Published var weeklySonnetResetsAt: Date?
    @Published var lastUpdated: Date = Date()
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var usageNotificationsEnabled: Bool = true
    @Published var statusNotificationsEnabled: Bool = true
    @Published var openAtLogin: Bool = false
    @Published var hasWeeklySonnet: Bool = false
    @Published var hasFetchedData: Bool = false
    @Published var isAccessibilityEnabled: Bool = false
    @Published var shortcutEnabled: Bool = true

    // Fork additions
    @Published var cookieInvalid: Bool = false          // set when API returns 401/403
    @Published var lastSuccessfulUpdate: Date?          // for the stale-data check
    @Published var refreshIntervalMinutes: Int = 5      // configurable poll interval
    @Published var loginItemStatus: String = "—"        // real SMAppService status string

    // Menu-bar display toggles (default: only the primary session %)
    @Published var showSessionTimer: Bool = false
    @Published var showWeeklyPercent: Bool = false
    @Published var showWeeklyTimer: Bool = false
    @Published var showSonnetPercent: Bool = false
    @Published var blinkEnabled: Bool = true

    // Countdown to each window's reset (e.g. "1h59m", "2d17h", "<1m"); nil if unknown.
    var sessionResetCountdown: String? { UsageManager.countdown(to: sessionResetsAt) }
    var weeklyResetCountdown: String?  { UsageManager.countdown(to: weeklyResetsAt) }
    var sonnetResetCountdown: String?  { UsageManager.countdown(to: weeklySonnetResetsAt) }

    static func countdown(to date: Date?) -> String? {
        guard let date = date else { return nil }
        let s = Int(date.timeIntervalSinceNow)
        if s <= 0 { return "now" }
        if s < 60 { return "<1m" }
        let d = s / 86_400, h = (s % 86_400) / 3_600, m = (s % 3_600) / 60
        if d > 0 { return "\(d)d\(h)h" }
        if h > 0 { return "\(h)h\(m)m" }
        return "\(m)m"
    }

    // Stale if no successful fetch for longer than this (seconds).
    let staleThresholdSeconds: TimeInterval = 15 * 60
    var isDataStale: Bool {
        guard let last = lastSuccessfulUpdate else { return false }
        return Date().timeIntervalSince(last) > staleThresholdSeconds
    }
    // Tracks the last session % we saw, to detect a reset (high -> ~0).
    private var previousSessionUsage: Int = 0
    private var notifiedResetSoon: Bool = false

    private var statusItem: NSStatusItem?
    private var sessionCookie: String = ""
    private weak var delegate: AppDelegate?
    private var lastNotifiedThreshold: Int = 0

    init(statusItem: NSStatusItem?, delegate: AppDelegate? = nil) {
        self.statusItem = statusItem
        self.delegate = delegate
        loadSessionCookie()
        loadSettings()
        checkAccessibilityStatus()
    }

    func checkAccessibilityStatus() {
        isAccessibilityEnabled = AXIsProcessTrusted()
    }

    func loadSessionCookie() {
        // 1) New Keychain (post-rebrand). 2) Old Keychain service (pre-rebrand
        // "com.claude.usagebar") → migrate. 3) Legacy plaintext UserDefaults.
        if let kc = KeychainHelper.load() {
            sessionCookie = kc
        } else if let old = KeychainHelper.load(from: KeychainHelper.legacyService) {
            sessionCookie = old
            KeychainHelper.save(old)
            NSLog("🔐 Migrated session cookie from old Keychain service to AIMeter")
        } else if let legacy = UserDefaults.standard.string(forKey: "claude_session_cookie") {
            sessionCookie = legacy
            if KeychainHelper.save(legacy) {
                UserDefaults.standard.removeObject(forKey: "claude_session_cookie")
                UserDefaults.standard.synchronize()
                NSLog("🔐 Migrated session cookie from UserDefaults to Keychain")
            }
        }
    }

    /// Short, non-sensitive hint shown in the UI (first chars only).
    var cookieHint: String {
        guard !sessionCookie.isEmpty else { return "" }
        return String(sessionCookie.prefix(20)) + "..."
    }

    func loadSettings() {
        // Migrate from legacy single notifications_enabled flag (pre-v1.1) to split flags
        let hasUsageKey  = UserDefaults.standard.object(forKey: "usage_notifications_enabled")  != nil
        let hasStatusKey = UserDefaults.standard.object(forKey: "status_notifications_enabled") != nil

        if !hasUsageKey || !hasStatusKey {
            let legacyHasKey = UserDefaults.standard.object(forKey: "notifications_enabled") != nil
            let legacyValue  = legacyHasKey ? UserDefaults.standard.bool(forKey: "notifications_enabled") : true
            if !hasUsageKey {
                usageNotificationsEnabled = legacyValue
                UserDefaults.standard.set(legacyValue, forKey: "usage_notifications_enabled")
            }
            if !hasStatusKey {
                statusNotificationsEnabled = legacyValue
                UserDefaults.standard.set(legacyValue, forKey: "status_notifications_enabled")
            }
        }
        if hasUsageKey {
            usageNotificationsEnabled = UserDefaults.standard.bool(forKey: "usage_notifications_enabled")
        }
        if hasStatusKey {
            statusNotificationsEnabled = UserDefaults.standard.bool(forKey: "status_notifications_enabled")
        }

        // Reflect the REAL login-item state from the OS, not just a stored bool.
        openAtLogin = LoginItemManager.isEnabled
        loginItemStatus = LoginItemManager.statusDescription
        lastNotifiedThreshold = UserDefaults.standard.integer(forKey: "last_notified_threshold")

        // Refresh interval (minutes); default 5, clamp to a sane range.
        let savedInterval = UserDefaults.standard.integer(forKey: "refresh_interval_minutes")
        refreshIntervalMinutes = savedInterval > 0 ? min(max(savedInterval, 1), 60) : 5

        // Menu-bar display toggles + blink (defaults: off / on).
        showSessionTimer  = UserDefaults.standard.bool(forKey: "show_session_timer")
        showWeeklyPercent = UserDefaults.standard.bool(forKey: "show_weekly_percent")
        showWeeklyTimer   = UserDefaults.standard.bool(forKey: "show_weekly_timer")
        showSonnetPercent = UserDefaults.standard.bool(forKey: "show_sonnet_percent")
        blinkEnabled = UserDefaults.standard.object(forKey: "blink_enabled") == nil
            ? true : UserDefaults.standard.bool(forKey: "blink_enabled")
        // Default shortcut to enabled if not previously set
        if UserDefaults.standard.object(forKey: "shortcut_enabled") == nil {
            shortcutEnabled = true
        } else {
            shortcutEnabled = UserDefaults.standard.bool(forKey: "shortcut_enabled")
        }
    }

    func saveSettings() {
        UserDefaults.standard.set(usageNotificationsEnabled,  forKey: "usage_notifications_enabled")
        UserDefaults.standard.set(statusNotificationsEnabled, forKey: "status_notifications_enabled")
        UserDefaults.standard.set(shortcutEnabled, forKey: "shortcut_enabled")
        UserDefaults.standard.set(refreshIntervalMinutes, forKey: "refresh_interval_minutes")
        UserDefaults.standard.set(showSessionTimer,  forKey: "show_session_timer")
        UserDefaults.standard.set(showWeeklyPercent, forKey: "show_weekly_percent")
        UserDefaults.standard.set(showWeeklyTimer,   forKey: "show_weekly_timer")
        UserDefaults.standard.set(showSonnetPercent, forKey: "show_sonnet_percent")
        UserDefaults.standard.set(blinkEnabled,      forKey: "blink_enabled")
        UserDefaults.standard.synchronize()
    }

    /// Apply menu-bar display/blink settings immediately (redraw the icon).
    func applyMenuBarSettings() {
        saveSettings()
        delegate?.redrawStatusIcon()
    }

    /// Toggle "Open at Login" and actually register/unregister with the OS.
    /// Reverts the published flag if the OS call fails, and refreshes the status string.
    func setOpenAtLogin(_ enabled: Bool) {
        let ok = LoginItemManager.setEnabled(enabled)
        loginItemStatus = LoginItemManager.statusDescription
        // Reflect the real state (e.g. "requiresApproval" leaves it not-yet-enabled).
        openAtLogin = ok ? LoginItemManager.isEnabled : openAtLogin
    }

    func refreshLoginItemStatus() {
        openAtLogin = LoginItemManager.isEnabled
        loginItemStatus = LoginItemManager.statusDescription
    }

    func setRefreshInterval(_ minutes: Int) {
        refreshIntervalMinutes = min(max(minutes, 1), 60)
        saveSettings()
        delegate?.restartUsageTimer()
    }

    /// Forward the SwiftUI-measured content height to the AppDelegate so it can
    /// size the popover correctly (and keep it on-screen).
    func reportPopoverHeight(_ h: CGFloat) {
        delegate?.setPopoverHeight(h)
    }

    func saveSessionCookie(_ cookie: String) {
        NSLog("ClaudeUsage: Saving cookie, length: \(cookie.count)")
        sessionCookie = cookie
        if KeychainHelper.save(cookie) {
            NSLog("ClaudeUsage: Cookie saved to Keychain")
        } else {
            NSLog("ClaudeUsage: ⚠️ Keychain save failed")
        }
        // A freshly pasted cookie clears any prior invalid state.
        cookieInvalid = false
        UserDefaults.standard.removeObject(forKey: "cookie_invalid_notified")
        UserDefaults.standard.synchronize()
    }

    func clearSessionCookie() {
        NSLog("ClaudeUsage: Clearing cookie")
        sessionCookie = ""
        KeychainHelper.delete()
        // Wipe any pre-migration plaintext leftover too.
        UserDefaults.standard.removeObject(forKey: "claude_session_cookie")
        cookieInvalid = false
        UserDefaults.standard.removeObject(forKey: "cookie_invalid_notified")
        UserDefaults.standard.synchronize()

        // Reset all data
        sessionUsage = 0
        weeklyUsage = 0
        weeklySonnetUsage = 0
        sessionResetsAt = nil
        weeklyResetsAt = nil
        weeklySonnetResetsAt = nil
        hasFetchedData = false
        hasWeeklySonnet = false
        errorMessage = nil
        lastNotifiedThreshold = 0
        UserDefaults.standard.set(0, forKey: "last_notified_threshold")

        // Update status bar to show 0%
        delegate?.updateStatusIcon(percentage: 0)

        NSLog("ClaudeUsage: Cookie cleared, data reset")
    }

    func fetchOrganizationId(completion: @escaping (String?) -> Void) {
        // Get org ID from the lastActiveOrg cookie value
        let cookieParts = sessionCookie.components(separatedBy: ";")
        for part in cookieParts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("lastActiveOrg=") {
                let orgId = trimmed.replacingOccurrences(of: "lastActiveOrg=", with: "")
                NSLog("📋 Found org ID in cookie: \(orgId)")
                completion(orgId)
                return
            }
        }

        // If not in cookie, fetch from bootstrap
        guard let url = URL(string: "https://claude.ai/api/bootstrap") else {
            completion(nil)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("sessionKey=\(sessionCookie)", forHTTPHeaderField: "Cookie")

        NSLog("📡 Fetching bootstrap to get org ID...")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if let http = response as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
                DispatchQueue.main.async { self?.handleAuthFailure() }
                completion(nil)
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let account = json["account"] as? [String: Any],
                  let lastActiveOrgId = account["lastActiveOrgId"] as? String else {
                NSLog("❌ Could not parse org ID from bootstrap")
                completion(nil)
                return
            }
            NSLog("✅ Got org ID from bootstrap: \(lastActiveOrgId)")
            completion(lastActiveOrgId)
        }.resume()
    }

    func fetchUsage() {
        guard !sessionCookie.isEmpty else {
            DispatchQueue.main.async {
                self.errorMessage = "Session cookie not set"
                self.updateStatusBar()
            }
            return
        }

        isLoading = true
        errorMessage = nil

        // Extract org ID from cookie
        fetchOrganizationId { [weak self] orgId in
            guard let self = self, let orgId = orgId else {
                DispatchQueue.main.async {
                    self?.errorMessage = "Could not get org ID from cookie"
                    self?.isLoading = false
                }
                return
            }

            self.fetchUsageWithOrgId(orgId)
        }
    }

    func fetchUsageWithOrgId(_ orgId: String) {
        let urlString = "https://claude.ai/api/organizations/\(orgId)/usage"

        guard let url = URL(string: urlString) else {
            DispatchQueue.main.async {
                self.errorMessage = "Invalid URL"
                self.isLoading = false
            }
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        // Use the full cookie string (user provides all cookies, not just sessionKey)
        request.setValue(sessionCookie, forHTTPHeaderField: "Cookie")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("claude.ai", forHTTPHeaderField: "authority")

        NSLog("🔍 Fetching from: \(urlString)")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.isLoading = false

                if let error = error {
                    NSLog("❌ Error: \(error.localizedDescription)")
                    self?.errorMessage = "Network error"
                    self?.updateStatusBar()
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    self?.errorMessage = "Invalid response"
                    self?.updateStatusBar()
                    return
                }

                NSLog("📡 Status: \(httpResponse.statusCode)")

                if let data = data, let responseString = String(data: data, encoding: .utf8) {
                    NSLog("📦 Response: \(responseString)")
                }

                if httpResponse.statusCode == 200, let data = data {
                    self?.cookieInvalid = false
                    self?.parseUsageData(data)
                } else if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                    self?.handleAuthFailure()
                } else {
                    self?.errorMessage = "HTTP \(httpResponse.statusCode)"
                }

                self?.updateStatusBar()
            }
        }.resume()
    }

    /// Cookie expired/invalid: surface a clear state and notify once until re-pasted.
    func handleAuthFailure() {
        cookieInvalid = true
        errorMessage = "Cookie expired — paste a fresh one"
        NSLog("🔒 Auth failed (401/403): cookie likely expired")

        let alreadyNotified = UserDefaults.standard.bool(forKey: "cookie_invalid_notified")
        if !alreadyNotified {
            let notification = NSUserNotification()
            notification.title = "Claude cookie expired"
            notification.informativeText = "AIMeter can't read your usage. Open the menu bar app and paste a fresh cookie."
            notification.soundName = NSUserNotificationDefaultSoundName
            NSUserNotificationCenter.default.deliver(notification)
            UserDefaults.standard.set(true, forKey: "cookie_invalid_notified")
            UserDefaults.standard.synchronize()
        }
    }

    func parseUsageData(_ data: Data) {
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                errorMessage = "Invalid JSON"
                return
            }

            NSLog("📊 Parsing usage data...")

            let iso8601Formatter = ISO8601DateFormatter()
            iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            // Parse the actual claude.ai response format
            if let fiveHour = json["five_hour"] as? [String: Any] {
                if let sessionUtil = fiveHour["utilization"] as? Double {
                    sessionUsage = Int(sessionUtil)
                    sessionLimit = 100
                }
                if let resetsAtString = fiveHour["resets_at"] as? String {
                    NSLog("🕐 Session resets_at string: \(resetsAtString)")
                    if let resetsAt = iso8601Formatter.date(from: resetsAtString) {
                        sessionResetsAt = resetsAt
                        NSLog("✅ Parsed session reset time: \(resetsAt)")
                    } else {
                        NSLog("❌ Failed to parse session reset time")
                    }
                }
            }

            if let sevenDay = json["seven_day"] as? [String: Any] {
                if let weeklyUtil = sevenDay["utilization"] as? Double {
                    weeklyUsage = Int(weeklyUtil)
                    weeklyLimit = 100
                }
                if let resetsAtString = sevenDay["resets_at"] as? String {
                    NSLog("🕐 Weekly resets_at string: \(resetsAtString)")
                    if let resetsAt = iso8601Formatter.date(from: resetsAtString) {
                        weeklyResetsAt = resetsAt
                        NSLog("✅ Parsed weekly reset time: \(resetsAt)")
                    } else {
                        NSLog("❌ Failed to parse weekly reset time")
                    }
                }
            }

            // Check for seven_day_sonnet (Pro plan feature)
            if let sevenDaySonnet = json["seven_day_sonnet"] as? [String: Any] {
                hasWeeklySonnet = true
                if let sonnetUtil = sevenDaySonnet["utilization"] as? Double {
                    weeklySonnetUsage = Int(sonnetUtil)
                    weeklySonnetLimit = 100
                }
                if let resetsAtString = sevenDaySonnet["resets_at"] as? String {
                    NSLog("🕐 Weekly Sonnet resets_at string: \(resetsAtString)")
                    if let resetsAt = iso8601Formatter.date(from: resetsAtString) {
                        weeklySonnetResetsAt = resetsAt
                        NSLog("✅ Parsed weekly Sonnet reset time: \(resetsAt)")
                    } else {
                        NSLog("❌ Failed to parse weekly Sonnet reset time")
                    }
                }
            } else {
                hasWeeklySonnet = false
            }

            // Log what we found
            NSLog("✅ Parsed: Session \(sessionUsage)%, Weekly \(weeklyUsage)%\(hasWeeklySonnet ? ", Weekly Sonnet \(weeklySonnetUsage)%" : "")")

            lastUpdated = Date()
            lastSuccessfulUpdate = Date()
            errorMessage = nil
            hasFetchedData = true
            cookieInvalid = false

            // Detect a session reset (usage was high, now dropped near zero) and
            // notify once so you know you're back to a full 5-hour window.
            checkSessionReset(newUsage: sessionUsage)
            // Notify when the reset is imminent (so you can wrap up before the cap).
            checkResetImminent()
            previousSessionUsage = sessionUsage

            // Update percentage values for progress bars
            updatePercentages()
        } catch {
            NSLog("❌ Parse error: \(error.localizedDescription)")
            errorMessage = "Parse error"
        }
    }

    func updateStatusBar() {
        let sessionPercent = Int((Double(sessionUsage) / Double(sessionLimit)) * 100)

        // Update the icon color
        delegate?.updateStatusIcon(percentage: sessionPercent)

        // Check for notification thresholds
        checkNotificationThresholds(percentage: sessionPercent)
    }

    func checkNotificationThresholds(percentage: Int) {
        NSLog("🔔 Checking notifications: percentage=\(percentage)%, enabled=\(usageNotificationsEnabled), lastNotified=\(lastNotifiedThreshold)%")

        guard usageNotificationsEnabled else {
            NSLog("⚠️ Usage notifications disabled")
            return
        }

        let thresholds = [25, 50, 75, 90]

        for threshold in thresholds {
            if percentage >= threshold && lastNotifiedThreshold < threshold {
                NSLog("📬 Sending notification for \(threshold)% threshold")
                sendNotification(percentage: percentage, threshold: threshold)
                lastNotifiedThreshold = threshold
                // Persist the threshold
                UserDefaults.standard.set(lastNotifiedThreshold, forKey: "last_notified_threshold")
                UserDefaults.standard.synchronize()
            }
        }

        // Reset if usage drops below current threshold
        if percentage < lastNotifiedThreshold {
            let newThreshold = thresholds.filter { $0 <= percentage }.last ?? 0
            NSLog("🔄 Resetting notification threshold from \(lastNotifiedThreshold)% to \(newThreshold)%")
            lastNotifiedThreshold = newThreshold
            UserDefaults.standard.set(lastNotifiedThreshold, forKey: "last_notified_threshold")
            UserDefaults.standard.synchronize()
        }
    }

    func sendNotification(percentage: Int, threshold: Int) {
        let notification = NSUserNotification()
        notification.title = "Claude Usage Alert"
        notification.informativeText = "You've reached \(percentage)% of your 5-hour session limit"
        notification.soundName = NSUserNotificationDefaultSoundName

        NSUserNotificationCenter.default.deliver(notification)
        NSLog("📬 Sent notification for \(threshold)% threshold")
    }

    func sendTestNotification() {
        NSLog("🔔 Test notification button clicked")

        let notification = NSUserNotification()
        notification.title = "Claude Usage Alert"
        notification.informativeText = "Test notification - You've reached 75% of your 5-hour session limit"
        notification.soundName = NSUserNotificationDefaultSoundName

        NSUserNotificationCenter.default.deliver(notification)
        NSLog("📬 Test notification sent successfully")
    }

    /// Session reset just happened: usage was meaningfully high and dropped to ~0.
    private func checkSessionReset(newUsage: Int) {
        guard usageNotificationsEnabled else { return }
        if previousSessionUsage >= 50 && newUsage <= 5 {
            let notification = NSUserNotification()
            notification.title = "Claude session reset"
            notification.informativeText = "Your 5-hour session limit just reset — you're back to full capacity."
            notification.soundName = NSUserNotificationDefaultSoundName
            NSUserNotificationCenter.default.deliver(notification)
            NSLog("📬 Session reset notification sent")
            notifiedResetSoon = false   // allow a fresh "imminent" alert next cycle
        }
    }

    /// Reset is imminent (within 10 min) while usage is high: notify once per window.
    private func checkResetImminent() {
        guard usageNotificationsEnabled, let resetsAt = sessionResetsAt else { return }
        let secondsLeft = resetsAt.timeIntervalSinceNow
        if secondsLeft > 0 && secondsLeft <= 10 * 60 && sessionUsage >= 50 && !notifiedResetSoon {
            let mins = max(1, Int(secondsLeft / 60))
            let notification = NSUserNotification()
            notification.title = "Claude session resets soon"
            notification.informativeText = "About \(mins) min left before your 5-hour window resets (now at \(sessionUsage)%)."
            notification.soundName = NSUserNotificationDefaultSoundName
            NSUserNotificationCenter.default.deliver(notification)
            NSLog("📬 Reset-imminent notification sent (\(mins) min)")
            notifiedResetSoon = true
        }
        if secondsLeft > 10 * 60 { notifiedResetSoon = false }  // re-arm once we're far from reset
    }

    /// Public entry for the manual "Refresh now" button.
    func refreshNow() {
        fetchUsage()
    }

    @Published var sessionPercentage: Double = 0.0
    @Published var weeklyPercentage: Double = 0.0
    @Published var weeklySonnetPercentage: Double = 0.0

    func updatePercentages() {
        sessionPercentage = Double(sessionUsage) / Double(sessionLimit)
        weeklyPercentage = Double(weeklyUsage) / Double(weeklyLimit)
        weeklySonnetPercentage = Double(weeklySonnetUsage) / Double(weeklySonnetLimit)
    }
}

// MARK: - Anthropic Service Status

struct StatusIncident: Identifiable, Equatable {
    let id: String
    let name: String
    let status: String           // investigating | identified | monitoring | resolved
    let latestUpdate: String
    let updatedAt: Date?
    let componentIds: [String]
}

struct AffectedComponent: Identifiable, Equatable {
    let id: String
    let name: String
    let status: String           // degraded_performance | partial_outage | major_outage
}

struct StatusComponent: Identifiable, Equatable {
    let id: String
    let name: String
    let status: String           // operational | degraded_performance | ...
}

private let defaultTrackedComponents: [StatusComponent] = [
    StatusComponent(id: "c-claude-ai",      name: "claude.ai",                          status: "operational"),
    StatusComponent(id: "c-claude-console", name: "Claude Console (platform.claude.com)", status: "operational"),
    StatusComponent(id: "c-claude-api",     name: "Claude API (api.anthropic.com)",     status: "operational"),
    StatusComponent(id: "c-claude-code",    name: "Claude Code",                         status: "operational"),
    StatusComponent(id: "c-claude-cowork",  name: "Claude Cowork",                       status: "operational"),
    StatusComponent(id: "c-claude-gov",     name: "Claude for Government",              status: "operational"),
]

private let defaultTrackedComponentIdSet: Set<String> = Set(
    defaultTrackedComponents.map { $0.id }.filter { $0 != "c-claude-gov" }
)

class StatusManager: ObservableObject {
    @Published var indicator: String = "none"        // none | minor | major | critical (raw, global)
    @Published var statusDescription: String = "All systems operational"
    @Published var incidents: [StatusIncident] = []
    @Published var affectedComponents: [AffectedComponent] = []
    @Published var allComponents: [StatusComponent] = defaultTrackedComponents
    @Published var selectedComponentIds: Set<String> = defaultTrackedComponentIdSet
    @Published var lastUpdated: Date?
    @Published var hasFetched: Bool = false

    // Called on the main thread after each successful parse, so the menu-bar
    // icon can refresh its center status dot.
    var onStatusChange: (() -> Void)?

    // Canonical URL (status.anthropic.com 302-redirects here)
    private let endpoint = URL(string: "https://status.claude.com/api/v2/summary.json")!

    init() {
        if let saved = UserDefaults.standard.array(forKey: "tracked_component_ids") as? [String] {
            selectedComponentIds = Set(saved)
        }
        // Clean up legacy debug pref if present
        UserDefaults.standard.removeObject(forKey: "status_preview_mode")
    }

    func toggleComponent(_ id: String) {
        if selectedComponentIds.contains(id) {
            selectedComponentIds.remove(id)
        } else {
            selectedComponentIds.insert(id)
        }
        UserDefaults.standard.set(Array(selectedComponentIds), forKey: "tracked_component_ids")
    }

    func isTracked(_ id: String) -> Bool {
        selectedComponentIds.contains(id)
    }

    // MARK: - Filtered/effective views (respect tracked components)

    var filteredAffectedComponents: [AffectedComponent] {
        affectedComponents.filter { selectedComponentIds.contains($0.id) }
    }

    var filteredIncidents: [StatusIncident] {
        incidents.filter { incident in
            guard !incident.componentIds.isEmpty else { return true }
            return incident.componentIds.contains(where: { selectedComponentIds.contains($0) })
        }
    }

    var effectiveIndicator: String {
        let trackedComponents = allComponents.filter { selectedComponentIds.contains($0.id) }
        let max = trackedComponents.map { severity(for: $0.status) }.max() ?? 0
        switch max {
        case 0:  return "none"
        case 1:  return "minor"
        case 2:  return "major"
        default: return "critical"
        }
    }

    private func severity(for componentStatus: String) -> Int {
        switch componentStatus {
        case "operational":          return 0
        case "under_maintenance":    return 1
        case "degraded_performance": return 1
        case "partial_outage":       return 2
        case "major_outage":         return 3
        default:                     return 0
        }
    }

    func fetch() {
        let request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self = self, let data = data else { return }
            self.parse(data)
        }.resume()
    }

    private func parse(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = json["status"] as? [String: Any],
              let indicator = status["indicator"] as? String,
              let desc = status["description"] as? String else {
            return
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFrac = ISO8601DateFormatter()
        isoNoFrac.formatOptions = [.withInternetDateTime]

        var parsedIncidents: [StatusIncident] = []
        if let raw = json["incidents"] as? [[String: Any]] {
            for inc in raw {
                guard let id = inc["id"] as? String,
                      let name = inc["name"] as? String,
                      let st = inc["status"] as? String else { continue }
                if st == "resolved" || st == "postmortem" { continue }
                let updates = inc["incident_updates"] as? [[String: Any]] ?? []
                let latest = (updates.first?["body"] as? String) ?? ""
                let dateStr = (updates.first?["created_at"] as? String) ?? (inc["updated_at"] as? String)
                let updatedAt = dateStr.flatMap { iso.date(from: $0) ?? isoNoFrac.date(from: $0) }
                let compIds = (inc["components"] as? [[String: Any]] ?? [])
                    .compactMap { $0["id"] as? String }
                parsedIncidents.append(StatusIncident(
                    id: id, name: name, status: st, latestUpdate: latest,
                    updatedAt: updatedAt,
                    componentIds: compIds
                ))
            }
        }

        var parsedAffected: [AffectedComponent] = []
        var parsedAll: [StatusComponent] = []
        if let raw = json["components"] as? [[String: Any]] {
            for c in raw {
                guard let id = c["id"] as? String,
                      let name = c["name"] as? String,
                      let st = c["status"] as? String else { continue }
                parsedAll.append(StatusComponent(id: id, name: name, status: st))
                if st != "operational" {
                    parsedAffected.append(AffectedComponent(id: id, name: name, status: st))
                }
            }
        }

        DispatchQueue.main.async {
            let isFirstFetch = !self.hasFetched

            self.indicator = indicator
            self.statusDescription = desc
            self.incidents = parsedIncidents
            self.affectedComponents = parsedAffected
            if !parsedAll.isEmpty {
                self.allComponents = parsedAll
                // First time we see real components: track all except Claude for Government by default
                if UserDefaults.standard.array(forKey: "tracked_component_ids") == nil {
                    let defaultIds = parsedAll
                        .filter { !$0.name.localizedCaseInsensitiveContains("Government") }
                        .map { $0.id }
                    self.selectedComponentIds = Set(defaultIds)
                    UserDefaults.standard.set(Array(self.selectedComponentIds),
                                              forKey: "tracked_component_ids")
                }
            }
            self.lastUpdated = Date()
            self.hasFetched = true

            // Notify on transitions of EFFECTIVE (filtered) indicator
            let effective = self.effectiveIndicator
            let previous = UserDefaults.standard.string(forKey: "last_effective_indicator")
            if !isFirstFetch, let previous = previous, previous != effective {
                self.notifyStatusChange(to: effective, description: desc)
            }
            UserDefaults.standard.set(effective, forKey: "last_effective_indicator")

            // Refresh the menu-bar icon's center status dot.
            self.onStatusChange?()
        }
    }

    private func notifyStatusChange(to indicator: String, description: String) {
        guard UserDefaults.standard.bool(forKey: "status_notifications_enabled") else { return }

        let notification = NSUserNotification()
        if indicator == "none" {
            notification.title = "Claude is back online"
            notification.informativeText = "All systems operational"
        } else {
            notification.title = "Claude status: \(description)"
            notification.informativeText = "Visit status.anthropic.com for details"
        }
        notification.soundName = NSUserNotificationDefaultSoundName
        NSUserNotificationCenter.default.deliver(notification)
        NSLog("📬 Sent status-change notification: \(indicator)")
    }
}

// MARK: - App Updates

struct BannerButton: Equatable {
    let label: String
    let url: URL?         // optional — opens this URL (validated)
    let action: String?   // "dismiss" closes the banner; nil = no extra side effect
    let style: String?    // "primary" | "secondary" | nil
}

struct AvailableUpdate: Equatable {
    let version: String
    let title: String
    let body: String
    let buttons: [BannerButton]
}

class UpdateManager: ObservableObject {
    @Published var available: AvailableUpdate?

    // Served directly from the repo via GitHub — free, unlimited, no Vercel meter.
    // Same file as website/latest.json so existing v1.1 users on Vercel see the same JSON.
    private let endpoint = URL(string: "https://raw.githubusercontent.com/Artzainnn/ClaudeUsageBar/main/website/latest.json")!

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private static let allowedHostSuffixes = [
        "github.com",
        "claudeusagebar.com"
    ]

    static func isSafeURL(_ url: URL) -> Bool {
        guard url.scheme == "https" else { return false }
        guard let host = url.host?.lowercased() else { return false }
        return allowedHostSuffixes.contains(where: { host == $0 || host.hasSuffix("." + $0) })
    }

    private static func parseButtons(from json: [String: Any]) -> [BannerButton] {
        // Explicit `buttons` array (new schema, supports any combination)
        if let raw = json["buttons"] as? [[String: Any]] {
            return raw.compactMap { dict -> BannerButton? in
                guard let label = dict["label"] as? String, !label.isEmpty else { return nil }
                let urlStr = dict["url"] as? String
                let url = urlStr.flatMap { URL(string: $0) }
                if let url = url, !isSafeURL(url) { return nil }   // reject unsafe URLs
                return BannerButton(
                    label: label,
                    url: url,
                    action: dict["action"] as? String,
                    style: dict["style"] as? String
                )
            }
        }
        // Back-compat: legacy `download_url` builds the default 2-button layout
        if let urlStr = json["download_url"] as? String,
           let url = URL(string: urlStr),
           isSafeURL(url) {
            return [
                BannerButton(label: "Download", url: url, action: nil, style: "primary"),
                BannerButton(label: "Later",    url: nil, action: "dismiss", style: nil)
            ]
        }
        return []
    }

    func fetch() {
        let request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self = self,
                  let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let version = json["version"] as? String,
                  let title = json["title"] as? String,
                  let body = json["description"] as? String else {
                NSLog("⚠️ Update fetch failed or invalid payload")
                return
            }

            let buttons = Self.parseButtons(from: json)

            DispatchQueue.main.async {
                guard self.isNewer(remote: version, than: self.currentVersion) else {
                    self.available = nil
                    return
                }

                let update = AvailableUpdate(version: version, title: title, body: body, buttons: buttons)

                if self.available != update {
                    self.available = update
                    NSLog("⬆️ Update available: \(version)")
                }

                let lastNotified = UserDefaults.standard.string(forKey: "last_notified_update_version")
                // Update notifications fire regardless of usage/status toggles — they're
                // version-once and tied to user-initiated upgrade flow, not noise.
                if lastNotified != version {
                    let n = NSUserNotification()
                    n.title = "ClaudeUsageBar \(version) is available"
                    n.informativeText = title
                    n.soundName = NSUserNotificationDefaultSoundName
                    NSUserNotificationCenter.default.deliver(n)
                    UserDefaults.standard.set(version, forKey: "last_notified_update_version")
                    NSLog("📬 Sent update notification for \(version)")
                }
            }
        }.resume()
    }

    func dismissCurrent() {
        if let v = available?.version {
            UserDefaults.standard.set(v, forKey: "dismissed_update_version")
        }
        available = nil
    }

    var isCurrentDismissed: Bool {
        guard let v = available?.version else { return false }
        return UserDefaults.standard.string(forKey: "dismissed_update_version") == v
    }

    private func isNewer(remote: String, than current: String) -> Bool {
        let r = remote.split(separator: ".").map { Int($0) ?? 0 }
        let c = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(r.count, c.count) {
            let a = i < r.count ? r[i] : 0
            let b = i < c.count ? c[i] : 0
            if a != b { return a > b }
        }
        return false
    }
}

// Custom NSTextField that properly handles paste
class CustomTextField: NSTextField {
    var onTextChange: ((String) -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown {
            if (event.modifierFlags.contains(.command)) {
                switch event.charactersIgnoringModifiers {
                case "v":
                    if let string = NSPasteboard.general.string(forType: .string) {
                        self.stringValue = string
                        onTextChange?(string)
                        NSLog("ClaudeUsage: Pasted text length: \(string.count)")
                        return true
                    }
                case "a":
                    self.currentEditor()?.selectAll(nil)
                    return true
                case "c":
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(self.stringValue, forType: .string)
                    return true
                case "x":
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(self.stringValue, forType: .string)
                    self.stringValue = ""
                    onTextChange?("")
                    return true
                default:
                    break
                }
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        onTextChange?(self.stringValue)
    }
}

// Custom TextView that ensures keyboard commands work
class PasteableNSTextView: NSTextView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "v": // Paste
                paste(nil)
                return true
            case "c": // Copy
                copy(nil)
                return true
            case "x": // Cut
                cut(nil)
                return true
            case "a": // Select All
                selectAll(nil)
                return true
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

// Multi-line text field with proper paste support
struct PasteableTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = PasteableNSTextView()

        textView.isEditable = true
        textView.isSelectable = true
        textView.font = NSFont.systemFont(ofSize: 11)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.drawsBackground = true
        textView.isRichText = false
        textView.delegate = context.coordinator
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.usesFindBar = false
        textView.isGrammarCheckingEnabled = false
        textView.allowsUndo = true

        // Enable wrapping
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? PasteableNSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PasteableTextField

        init(_ parent: PasteableTextField) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct UsageView: View {
    @ObservedObject var usageManager: UsageManager
    @ObservedObject var statusManager: StatusManager
    @ObservedObject var updateManager: UpdateManager
    @State private var sessionCookieInput: String = ""
    @State private var showingCookieInput: Bool = false
    @State private var showingSettings: Bool = false
    @State private var showingStatusDetails: Bool = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                content
                    .padding()
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
                        }
                    )
            }
            // Width is fixed; the HEIGHT is controlled by the AppDelegate via the
            // popover's contentSize (see setPopoverHeight). The ScrollView fills it.
            .frame(width: 360)
            .onPreferenceChange(ContentHeightKey.self) { value in
                guard value > 0 else { return }
                // Tell AppKit the real content height so it sizes/positions the
                // popover correctly (and keeps it on-screen).
                usageManager.reportPopoverHeight(value)
            }
            .onAppear {
                if !usageManager.cookieHint.isEmpty {
                    sessionCookieInput = usageManager.cookieHint
                }
                usageManager.updatePercentages()
                // Re-sync the real login-item status each time the popover opens.
                usageManager.refreshLoginItemStatus()
            }
            // When the (tall) settings panel opens, reveal it by scrolling down.
            .onChange(of: showingSettings) { isOpen in
                if isOpen {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        withAnimation(.easeInOut(duration: 0.35)) {
                            proxy.scrollTo("settings-anchor", anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Claude Usage")
                .font(.headline)
                .padding(.bottom, 4)
                .id("top")

            // Cookie expired / invalid banner (fork): the most important alert —
            // without a valid cookie nothing updates, so make it loud and actionable.
            if usageManager.cookieInvalid {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Cookie expired")
                            .font(.caption).fontWeight(.semibold)
                        Text("Paste a fresh cookie below to resume tracking.")
                            .font(.caption2).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
                .padding(8)
                .background(Color.red.opacity(0.12))
                .cornerRadius(8)
            } else if usageManager.isDataStale, let last = usageManager.lastSuccessfulUpdate {
                // Stale-data banner (fork): data hasn't refreshed in a while.
                HStack(spacing: 8) {
                    Image(systemName: "clock.badge.exclamationmark")
                        .foregroundColor(.orange)
                    Text("Data may be stale — last updated \(relativeTime(last)).")
                        .font(.caption2).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .padding(8)
                .background(Color.orange.opacity(0.12))
                .cornerRadius(8)
            }

            // App update / announcement banner
            if let update = updateManager.available, !updateManager.isCurrentDismissed {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("⬆️")
                        Text("Version \(update.version) available")
                            .font(.caption)
                            .fontWeight(.semibold)
                        Spacer()
                        Button(action: { updateManager.dismissCurrent() }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                    Text(update.title)
                        .font(.caption)
                    Text(update.body)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !update.buttons.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(update.buttons.indices, id: \.self) { i in
                                bannerButton(update.buttons[i])
                            }
                        }
                    }
                }
                .padding(8)
                .background(Color.accentColor.opacity(0.12))
                .cornerRadius(6)
            }

            if let error = usageManager.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .padding(.bottom, 8)
            }

            // Only show usage if data has been fetched
            if !usageManager.hasFetchedData {
                Text("👋 Welcome! Set your session cookie below to get started.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            }

            // Session Usage
            if usageManager.hasFetchedData {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Session (5 hour)")
                        .font(.subheadline)
                    Spacer()
                    if let resetTime = usageManager.sessionResetsAt {
                        Text("Resets \(formatResetTime(resetTime))\(usageManager.sessionResetCountdown.map { " · in \($0)" } ?? "")")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                ProgressView(value: usageManager.sessionPercentage)
                    .tint(Palette.session)

                Text("\(Int(usageManager.sessionPercentage * 100))% used")
                    .font(.caption)
                    .foregroundColor(Palette.session)
            }

            // Weekly Usage
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Weekly (7 day)")
                        .font(.subheadline)
                    Spacer()
                    if let resetTime = usageManager.weeklyResetsAt {
                        Text("Resets \(formatResetTime(resetTime, includeDate: true))\(usageManager.weeklyResetCountdown.map { " · in \($0)" } ?? "")")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                ProgressView(value: usageManager.weeklyPercentage)
                    .tint(Palette.weekly)

                Text("\(Int(usageManager.weeklyPercentage * 100))% used")
                    .font(.caption)
                    .foregroundColor(Palette.weekly)
            }

            // Weekly Sonnet Usage (only show if available)
            if usageManager.hasWeeklySonnet && usageManager.hasFetchedData {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Weekly Sonnet (7 day)")
                            .font(.subheadline)
                        Spacer()
                        if let resetTime = usageManager.weeklySonnetResetsAt {
                            Text("Resets \(formatResetTime(resetTime, includeDate: true))\(usageManager.sonnetResetCountdown.map { " · in \($0)" } ?? "")")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    ProgressView(value: usageManager.weeklySonnetPercentage)
                        .tint(Palette.sonnet)

                    Text("\(Int(usageManager.weeklySonnetPercentage * 100))% used")
                        .font(.caption)
                        .foregroundColor(Palette.sonnet)
                }
            }
            }

            if statusManager.hasFetched {
                Divider()
            }

            // Anthropic service status (compact; expandable on issue)
            if statusManager.hasFetched {
                let effective = statusManager.effectiveIndicator
                let filteredIncidents = statusManager.filteredIncidents
                let filteredAffected = statusManager.filteredAffectedComponents
                let hasIssue = effective != "none"
                    && (!filteredIncidents.isEmpty || !filteredAffected.isEmpty)

                VStack(alignment: .leading, spacing: 8) {
                    // Compact header row
                    HStack(alignment: .top, spacing: 6) {
                        Circle()
                            .fill(statusColor(for: effective))
                            .frame(width: 8, height: 8)
                            .padding(.top, 4)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(effective == "none"
                                 ? "All Claude services operational"
                                 : statusManager.statusDescription)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(statusContextLine(for: statusManager))
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        if hasIssue {
                            Button(action: { showingStatusDetails.toggle() }) {
                                HStack(spacing: 2) {
                                    Text(showingStatusDetails ? "Hide" : "Details")
                                    Image(systemName: showingStatusDetails ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 8))
                                }
                                .font(.caption2)
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    // Expanded panel
                    if hasIssue && showingStatusDetails {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(filteredIncidents) { incident in
                                VStack(alignment: .leading, spacing: 6) {
                                    // Title
                                    Text(incident.name)
                                        .font(.system(size: 12, weight: .semibold))
                                        .fixedSize(horizontal: false, vertical: true)

                                    // Status badge + updated time
                                    HStack(spacing: 8) {
                                        Text(incident.status.uppercased())
                                            .font(.system(size: 9, weight: .bold))
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(badgeColor(for: incident.status))
                                            .cornerRadius(3)
                                        if let updated = incident.updatedAt {
                                            Text("Updated \(relativeTime(updated))")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                    }

                                    // Body
                                    if !incident.latestUpdate.isEmpty {
                                        Text(incident.latestUpdate)
                                            .font(.caption)
                                            .foregroundColor(.primary)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .padding(.top, 2)
                                    }
                                }
                            }

                            // Affected components (when no formal incident)
                            if filteredIncidents.isEmpty && !filteredAffected.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Affected services")
                                        .font(.caption2)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.secondary)
                                    ForEach(filteredAffected) { c in
                                        HStack(spacing: 6) {
                                            Circle()
                                                .fill(Color.orange)
                                                .frame(width: 5, height: 5)
                                            Text(c.name).font(.caption2)
                                            Spacer()
                                            Text(componentLabel(c.status))
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }
                            }

                            Divider()

                            HStack {
                                if let lastCheck = statusManager.lastUpdated {
                                    Text("Checked \(relativeTime(lastCheck))")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Button(action: {
                                    NSWorkspace.shared.open(URL(string: "https://status.claude.com")!)
                                }) {
                                    Text("Open status page →")
                                        .font(.caption2)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        .padding(10)
                        .background(Color.orange.opacity(0.10))
                        .cornerRadius(6)
                    }
                }
            }

            if usageManager.hasFetchedData {
            Divider()

            HStack {
                Text("Last updated: \(formatTime(usageManager.lastUpdated))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Refresh") {
                    usageManager.fetchUsage()
                    statusManager.fetch()
                    updateManager.fetch()
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            }

            Button(showingCookieInput ? "Hide Cookie" : "Set Session Cookie") {
                showingCookieInput.toggle()
            }
            .buttonStyle(.borderless)
            .font(.caption)

            if showingCookieInput {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("How to get your session cookie:")
                            .font(.caption)
                            .fontWeight(.semibold)
                        Spacer()
                        Button(action: {
                            NSWorkspace.shared.open(URL(string: "https://github.com/Artzainnn/ClaudeUsageBar/blob/main/setup-guide.png")!)
                        }) {
                            Text("View tutorial →")
                                .font(.caption2)
                                .foregroundColor(.blue)
                        }
                        .buttonStyle(.borderless)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("1. Go to Settings > Usage on claude.ai")
                        Text("2. Press F12 (or Cmd+Option+I)")
                        Text("3. Go to Network tab")
                        Text("4. Refresh page, click 'usage' request")
                        Text("5. Find 'Cookie' in Request Headers")
                        Text("6. Copy full cookie value\n   (starts with anthropic-device-id=...)")
                    }
                    .font(.caption2)
                    .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Paste full cookie string:")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        VStack(spacing: 4) {
                            PasteableTextField(text: $sessionCookieInput, placeholder: "Paste cookie here...")
                                .frame(height: 60)
                                .cornerRadius(4)

                            HStack(spacing: 8) {
                                Button("Save Cookie & Fetch") {
                                    NSLog("ClaudeUsage: Save clicked, input length: \(sessionCookieInput.count)")
                                    if sessionCookieInput.isEmpty {
                                        usageManager.errorMessage = "Cookie field is empty!"
                                    } else {
                                        usageManager.saveSessionCookie(sessionCookieInput)
                                        usageManager.fetchUsage()
                                        usageManager.errorMessage = "Cookie saved, fetching..."
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)

                                if usageManager.hasFetchedData {
                                    Button("Clear Cookie") {
                                        sessionCookieInput = ""
                                        usageManager.clearSessionCookie()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                }
                .padding(8)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(6)
            }

            // Settings Section
            Button(showingSettings ? "Hide Settings" : "Settings") {
                showingSettings.toggle()
            }
            .buttonStyle(.borderless)
            .font(.caption)

            if showingSettings {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(isOn: Binding(
                        get: { usageManager.openAtLogin },
                        set: { newValue in
                            // Actually register/unregister the login item with the OS.
                            usageManager.setOpenAtLogin(newValue)
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Open at Login")
                                .font(.caption)
                            Text("Launch app automatically when you log in")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            // Real system status (diagnostics): shows whether the OS
                            // actually has the login item enabled, not just our toggle.
                            Text("Status: \(usageManager.loginItemStatus)")
                                .font(.caption2)
                                .foregroundColor(usageManager.openAtLogin ? .green : .secondary)
                        }
                    }
                    .toggleStyle(.checkbox)

                    Divider()

                    // Refresh interval (fork): configurable poll cadence + manual refresh.
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Refresh interval")
                            .font(.caption)
                        Picker("", selection: Binding(
                            get: { usageManager.refreshIntervalMinutes },
                            set: { usageManager.setRefreshInterval($0) }
                        )) {
                            Text("1 min").tag(1)
                            Text("5 min").tag(5)
                            Text("10 min").tag(10)
                            Text("15 min").tag(15)
                            Text("30 min").tag(30)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .font(.caption2)

                        Button(action: { usageManager.refreshNow() }) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.clockwise")
                                Text(usageManager.isLoading ? "Refreshing…" : "Refresh now")
                            }
                            .font(.caption2)
                        }
                        .buttonStyle(.borderless)
                        .disabled(usageManager.isLoading)
                    }

                    Divider()

                    // Menu-bar display (fork): which values appear in the bar.
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Show in menu bar")
                            .font(.caption).fontWeight(.semibold)
                        menuBarToggle("Session reset timer", Palette.session,
                                      get: { usageManager.showSessionTimer },
                                      set: { usageManager.showSessionTimer = $0 })
                        menuBarToggle("Weekly usage %", Palette.weekly,
                                      get: { usageManager.showWeeklyPercent },
                                      set: { usageManager.showWeeklyPercent = $0 })
                        menuBarToggle("Weekly reset timer", Palette.weekly,
                                      get: { usageManager.showWeeklyTimer },
                                      set: { usageManager.showWeeklyTimer = $0 })
                        menuBarToggle("Weekly Sonnet usage %", Palette.sonnet,
                                      get: { usageManager.showSonnetPercent },
                                      set: { usageManager.showSonnetPercent = $0 })
                        Toggle(isOn: Binding(
                            get: { usageManager.blinkEnabled },
                            set: { usageManager.blinkEnabled = $0; usageManager.applyMenuBarSettings() }
                        )) {
                            Text("Blink on low quota / outage").font(.caption2)
                        }
                        .toggleStyle(.checkbox)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: Binding(
                            get: { usageManager.usageNotificationsEnabled },
                            set: { newValue in
                                usageManager.usageNotificationsEnabled = newValue
                                usageManager.saveSettings()
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Enable Usage Notifications")
                                    .font(.caption)
                                Text("Get alerts at 25%, 50%, 75%,\nand 90% session usage")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.checkbox)

                        Toggle(isOn: Binding(
                            get: { usageManager.statusNotificationsEnabled },
                            set: { newValue in
                                usageManager.statusNotificationsEnabled = newValue
                                usageManager.saveSettings()
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Enable Status Notifications")
                                    .font(.caption)
                                Text("Get alerts when tracked Claude services have an outage")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.checkbox)

                        Button("Test Notification") {
                            usageManager.sendTestNotification()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: Binding(
                            get: { usageManager.shortcutEnabled },
                            set: { newValue in
                                usageManager.shortcutEnabled = newValue
                                usageManager.saveSettings()
                                if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
                                    appDelegate.setShortcutEnabled(newValue)
                                }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Keyboard Shortcut (⌘U)")
                                    .font(.caption)
                                Text("Toggle popup from anywhere.\nDisable if it conflicts with other apps.")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.switch)

                        if usageManager.shortcutEnabled && !usageManager.isAccessibilityEnabled {
                            Button("Grant Accessibility Permission") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)

                            Text("Accessibility permission may be needed\nfor the shortcut to work in all apps")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Status alerts: services to track")
                            .font(.caption)
                            .fontWeight(.semibold)
                        Text("Only tick the Claude services you use. Status issues with unticked services won't be shown or trigger alerts.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(statusManager.allComponents) { component in
                            Toggle(isOn: Binding(
                                get: { statusManager.isTracked(component.id) },
                                set: { _ in statusManager.toggleComponent(component.id) }
                            )) {
                                Text(component.name)
                                    .font(.caption2)
                            }
                            .toggleStyle(.checkbox)
                        }
                    }

                }
                .padding(8)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(6)

                // Anchor for scroll-to-bottom when Settings opens
                Color.clear
                    .frame(height: 1)
                    .id("settings-anchor")
            }

            // Version footer (fork): always-visible running version + build number.
            HStack {
                Spacer()
                Text(appVersionString)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.top, 2)
        }
    }

    private var appVersionString: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "v\(short) · build \(build)"
    }

    /// A checkbox toggle (label tinted in its window color) that persists and
    /// refreshes the menu-bar icon immediately.
    @ViewBuilder
    private func menuBarToggle(_ label: String, _ color: Color,
                               get: @escaping () -> Bool,
                               set: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: get, set: { v in set(v); usageManager.applyMenuBarSettings() })) {
            Text(label).font(.caption2).foregroundColor(color)
        }
        .toggleStyle(.checkbox)
    }

    func formatNumber(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
    }

    func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    func formatResetTime(_ date: Date, includeDate: Bool = false) -> String {
        let formatter = DateFormatter()

        if includeDate {
            // Format: "on 31 Jan 2026 at 7:59 AM"
            formatter.dateFormat = "d MMM yyyy 'at' h:mm a"
            return "on \(formatter.string(from: date))"
        } else {
            formatter.timeStyle = .short
            formatter.dateStyle = .none
            return "at \(formatter.string(from: date))"
        }
    }

    func colorForPercentage(_ percentage: Double) -> Color {
        if percentage < 0.7 {
            return .green
        } else if percentage < 0.9 {
            return .orange
        } else {
            return .red
        }
    }

    func statusColor(for indicator: String) -> Color {
        switch indicator {
        case "none":     return .green
        case "minor":    return .yellow
        case "major":    return .orange
        case "critical": return .red
        default:         return .gray
        }
    }

    func statusLabel(for indicator: String, description: String) -> String {
        if indicator == "none" {
            return "Claude: all systems operational"
        }
        return "Claude: \(description)"
    }

    func relativeTime(_ date: Date) -> String {
        let elapsed = Int(Date().timeIntervalSince(date))
        if elapsed < 60 { return "just now" }
        if elapsed < 3600 {
            let m = elapsed / 60
            return "\(m) min\(m == 1 ? "" : "s") ago"
        }
        if elapsed < 86_400 {
            let h = elapsed / 3600
            return "\(h) hour\(h == 1 ? "" : "s") ago"
        }
        let d = elapsed / 86_400
        return "\(d) day\(d == 1 ? "" : "s") ago"
    }

    func statusContextLine(for sm: StatusManager) -> String {
        let tracked = sm.allComponents.filter { sm.selectedComponentIds.contains($0.id) }
        let trackedNames = tracked.prefix(4).map { shortName($0.name) }.joined(separator: ", ")
        let extra = tracked.count > 4 ? " +\(tracked.count - 4)" : ""
        let trackedSummary = tracked.isEmpty ? "No services tracked" : "Tracks \(trackedNames)\(extra)"

        if sm.effectiveIndicator == "none" {
            if let lastCheck = sm.lastUpdated {
                return "\(trackedSummary) · checked \(relativeTime(lastCheck))"
            }
            return trackedSummary
        }
        let affected = sm.filteredAffectedComponents
        if !affected.isEmpty {
            let names = affected.prefix(3).map { shortName($0.name) }.joined(separator: ", ")
            let more = affected.count > 3 ? " +\(affected.count - 3)" : ""
            return "Affects: \(names)\(more)"
        }
        if let lastCheck = sm.lastUpdated {
            return "Checked \(relativeTime(lastCheck))"
        }
        return ""
    }

    func shortName(_ raw: String) -> String {
        if let paren = raw.range(of: " (") {
            return String(raw[..<paren.lowerBound])
        }
        return raw
    }

    @ViewBuilder
    func bannerButton(_ btn: BannerButton) -> some View {
        let tap = {
            if let url = btn.url {
                NSWorkspace.shared.open(url)
            }
            if btn.action == "dismiss" {
                updateManager.dismissCurrent()
            }
        }
        if btn.style == "primary" {
            Button(btn.label, action: tap)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        } else {
            Button(btn.label, action: tap)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    func badgeColor(for status: String) -> Color {
        switch status {
        case "investigating": return Color.red.opacity(0.8)
        case "identified":    return Color.orange
        case "monitoring":    return Color.blue
        case "resolved":      return Color.green
        default:              return Color.gray
        }
    }

    func componentLabel(_ status: String) -> String {
        switch status {
        case "degraded_performance": return "degraded"
        case "partial_outage":       return "partial outage"
        case "major_outage":         return "major outage"
        case "under_maintenance":    return "maintenance"
        default:                     return status
        }
    }

}
