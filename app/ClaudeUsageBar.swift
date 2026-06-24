//
//  AIMeter — a macOS menu-bar app that tracks Claude usage and Anthropic status.
//
//  Single-file SwiftUI + AppKit app (no Xcode project; built with `swiftc` via
//  build-local.sh). Personal fork of ClaudeUsageBar (MIT).
//
//  Architecture (top → bottom in this file):
//    • KeychainHelper   — stores the claude.ai session cookie in the login Keychain
//    • LoginItemManager — real launch-at-login via a per-user LaunchAgent
//    • Palette          — per-window identity colors (session/weekly/sonnet)
//    • AppDelegate      — status-bar item, popover, menu-bar ring icon + blink, Cmd+U hotkey
//    • UsageManager     — polls claude.ai usage API; owns all usage state + notifications
//    • StatusManager    — polls status.claude.com; tracks per-component outages
//    • UsageView        — the SwiftUI popover UI and its formatting helpers
//
//  Threading rule: all @Published mutations happen on the main thread. Network
//  work runs on URLSession's background queue and hops back to main before
//  touching published state (see parseUsageData / StatusManager.parse).
//
import SwiftUI
import AppKit
import WebKit
import Carbon
import Security

// MARK: - Verbose diagnostics
//
// Some logs would include identifiers (the org ID) or full API payloads (your
// usage data). Keep them OFF by default so a public/shared build doesn't write
// that to the unified log (Console.app, persisted). Flip `verboseLogging` to
// true only while actively debugging. The cookie itself is never logged.
private let verboseLogging = false
private func vlog(_ message: @autoclosure () -> String) {
    if verboseLogging { NSLog("%@", message()) }
}

// Menu-bar display mode for an optional extra value. Int-backed so the persisted
// rawValue stays compatible with the existing UserDefaults integers (0/1/2).
enum BarMode: Int {
    case off = 0      // never show
    case always = 1   // always show
    case when = 2     // show only when the threshold condition is met
}

// MARK: - Notifications
//
// Thin wrapper over NSUserNotification (deprecated, but works without permissions
// for ad-hoc-signed apps — see file header). Centralizes the repeated 4-line
// construction so call sites are one line.
enum Notifier {
    static func post(title: String, body: String) {
        let n = NSUserNotification()
        n.title = title
        n.informativeText = body
        n.soundName = NSUserNotificationDefaultSoundName
        NSUserNotificationCenter.default.deliver(n)
    }
}

// MARK: - Keychain helper (fork: store the claude.ai session cookie securely)
//
// The cookie carries `sessionKey`, which grants full account access. Upstream
// stored it in plaintext in UserDefaults (~/Library/Preferences/com.claude.usagebar.plist),
// readable by any process running as the user and included in unencrypted backups.
// We keep it in the login Keychain, device-only: not synced to iCloud and not
// restorable onto another device. (Local encrypted backups can still include it.)
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
    static let sessionNS = NSColor(srgbRed: 0.13, green: 0.62, blue: 0.27, alpha: 1) // #219E45 darker green
    static let weeklyNS  = NSColor(srgbRed: 0.35, green: 0.78, blue: 0.98, alpha: 1) // #5AC8FA bright sky blue
    static let sonnetNS  = NSColor(srgbRed: 1.00, green: 0.62, blue: 0.04, alpha: 1) // #FF9F0A
    static let alertNS   = NSColor(srgbRed: 1.00, green: 0.23, blue: 0.19, alpha: 1) // red
    static let warnNS    = NSColor(srgbRed: 1.00, green: 0.80, blue: 0.00, alpha: 1) // yellow

    static let session = Color(.sRGB, red: 0.13, green: 0.62, blue: 0.27)
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

/// App lifecycle owner. Builds the status-bar item and the popover, renders the
/// menu-bar ring icon (plus its low-quota / outage blink animation), and wires
/// the global Cmd+U hotkey. Holds the three ObservableObject managers and is the
/// bridge AppKit ⇄ managers (e.g. managers call back here to redraw the icon or
/// resize the popover). All work here is main-thread only.
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    // Session ring enters the green→red danger ramp above this % used; the ramp
    // spans the remaining `dangerSpan` points up to 100% (full red).
    static let dangerThreshold = 75
    static let dangerSpan = CGFloat(100 - dangerThreshold)   // = 25.0 denominator
    static let popoverWidth: CGFloat = 360

    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var usageManager: UsageManager!
    var statusManager: StatusManager!
    var eventMonitor: Any?
    var hotKeyRef: EventHotKeyRef?
    var eventHandlerRef: EventHandlerRef?   // Carbon handler; removed on unregister to avoid leak/dup
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

        // Refresh the menu-bar icon (center status dot) whenever service status changes.
        statusManager.onStatusChange = { [weak self] in self?.redrawStatusIcon() }

        // Create popover
        popover = NSPopover()
        popover.contentSize = NSSize(width: AppDelegate.popoverWidth, height: 360)
        popover.behavior = .transient
        popover.delegate = self
        let hosting = NSHostingController(rootView: UsageView(
            usageManager: usageManager,
            statusManager: statusManager
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

        // Usage + Anthropic status are time-sensitive — poll on the configured interval.
        restartUsageTimer()

        // Set up Cmd+U keyboard shortcut
        setupKeyboardShortcut()

        // Refresh the menu-bar countdown text once a minute (the icon otherwise only
        // redraws on fetch/blink, which would leave countdowns stale).
        titleRefreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            // Scheduled on the main run loop, so we're already on the main actor.
            MainActor.assumeIsolated { self?.drawIcon() }
        }
        reconfigureBlink()
    }

    /// (Re)create the usage/status poll timer using the user's configured interval.
    /// Called at launch and whenever the interval changes in Settings.
    func restartUsageTimer() {
        usageTimer?.invalidate()
        let seconds = TimeInterval(max(1, usageManager.refreshIntervalMinutes) * 60)
        usageTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.usageManager.fetchUsage()
                self?.statusManager.fetch()
            }
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

    func registerGlobalHotKey() {
        // Guard against double registration
        if hotKeyRef != nil { return }

        var hotKeyID = EventHotKeyID()
        // Legacy/internal signature; value is functional, do not change.
        hotKeyID.signature = 0x436C5542 // 'ClUB' as hex
        hotKeyID.id = 1

        // Carbon virtual keycode 32 = kVK_ANSI_U ('U' on ANSI layouts). Matched by
        // physical key position, so the actual character is keyboard-layout-dependent.
        let keyCode: UInt32 = 32
        let modifiers: UInt32 = UInt32(cmdKey)

        // Create event spec for hotkey
        var eventType = EventTypeSpec()
        eventType.eventClass = OSType(kEventClassKeyboard)
        eventType.eventKind = OSType(kEventHotKeyPressed)

        // Install event handler
        let callback: EventHandlerUPP = { (nextHandler, event, userData) -> OSStatus in
            // Get the AppDelegate instance
            let appDelegate = Unmanaged<AppDelegate>.fromOpaque(userData!).takeUnretainedValue()

            // Toggle popover (hop to the main actor — Carbon may call us off-main).
            Task { @MainActor in
                appDelegate.togglePopover()
            }

            return noErr
        }

        // Install the handler
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType, selfPtr, &eventHandlerRef)

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
        // Also remove the Carbon event handler so a later re-register installs a
        // single fresh one (otherwise handlers accumulate on every toggle).
        if let eh = eventHandlerRef {
            RemoveEventHandler(eh)
            eventHandlerRef = nil
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
            // Already on main here — refresh synchronously so it takes effect before show.
            usageManager.updatePercentages()

            // Drive the popover size EXPLICITLY from the last known content height
            // before showing. If we let NSPopover auto-grow after the SwiftUI content
            // measures itself, it expands upward (anchored at the bottom) and pushes
            // the top off the screen. Setting contentSize ourselves makes NSPopover
            // place and keep the window on-screen.
            popover.contentSize = NSSize(width: AppDelegate.popoverWidth, height: clampedPopoverHeight(lastPopoverHeight))
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

            // Tear down any stale monitor before adding a fresh one (a transient
            // auto-dismiss may not have routed through closePopover).
            removeEventMonitor()
            eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                if self?.popover.isShown == true {
                    self?.closePopover()
                }
            }
        }
    }

    func closePopover() {
        popover.performClose(nil)
        removeEventMonitor()
    }

    private func removeEventMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    /// NSPopoverDelegate: fires on EVERY dismissal, including transient auto-dismiss
    /// (clicking elsewhere), so the global monitor is always cleaned up.
    func popoverDidClose(_ notification: Notification) {
        removeEventMonitor()
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
            popover.contentSize = NSSize(width: AppDelegate.popoverWidth, height: clamped)
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
        if percent <= AppDelegate.dangerThreshold { return Palette.sessionNS }   // same green as the % text
        let t = CGFloat(min(1.0, Double(percent - AppDelegate.dangerThreshold) / Double(AppDelegate.dangerSpan)))
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
        let danger = blinkEnabled && lastSessionPercent > AppDelegate.dangerThreshold
        let outage = blinkEnabled && statusDotColor() != nil
        if danger || outage {
            if blinkTimer == nil {
                blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.blinkTickFired() }
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
        let frac = max(0.0, min(1.0, Double(lastSessionPercent - AppDelegate.dangerThreshold) / Double(AppDelegate.dangerSpan)))
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
        let dangerActive = blinkEnabled && percent > AppDelegate.dangerThreshold
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
            // Sonnet reset timer only if it differs from the weekly reset by at least
            // a minute (matches the minute-level display granularity; avoids a
            // redundant duplicate timer when they're effectively the same instant).
            if let st = um.weeklySonnetResetsAt,
               um.weeklyResetsAt.map({ abs(st.timeIntervalSince($0)) >= 60 }) ?? true,
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

/// The core model. Polls claude.ai's internal usage API (five_hour / seven_day /
/// seven_day_sonnet), parses the utilization % and reset times, and publishes
/// everything the popover and the menu-bar title render. Also owns:
///   • the session cookie (loaded from / saved to the Keychain via KeychainHelper),
///   • all persisted settings (UserDefaults: refresh interval, menu-bar display
///     modes/thresholds, notification toggles, tracked-component selection),
///   • usage notifications (per-threshold, session-reset, reset-imminent),
///   • the conditional menu-bar visibility logic (show* computed properties).
/// Network callbacks marshal back to the main thread before mutating @Published state.
@MainActor
class UsageManager: ObservableObject {
    // The API reports each window's utilization as a percent (0–100), so these
    // values ARE the percentage — no separate limit field is needed.
    @Published var sessionUsage: Int = 0
    @Published var weeklyUsage: Int = 0
    @Published var weeklySonnetUsage: Int = 0
    @Published var sessionResetsAt: Date?
    @Published var weeklyResetsAt: Date?
    @Published var weeklySonnetResetsAt: Date?
    @Published var lastUpdated: Date = Date()
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    // Informational status (e.g. "Cookie saved, fetching…"). Rendered distinctly
    // from errorMessage (secondary color, not orange). Real failures stay on errorMessage.
    @Published var statusMessage: String?
    @Published var usageNotificationsEnabled: Bool = true
    @Published var statusNotificationsEnabled: Bool = true
    @Published var openAtLogin: Bool = false
    @Published var hasWeeklySonnet: Bool = false
    @Published var hasFetchedData: Bool = false
    @Published var isAccessibilityEnabled: Bool = false
    @Published var shortcutEnabled: Bool = true

    // Notify-once persistence keys (set when notified, cleared/re-armed elsewhere):
    //   cookie_invalid_notified      set: handleAuthFailure   clear: save/clearSessionCookie
    //   last_notified_threshold      set: checkNotificationThresholds   reset: clearSessionCookie, lowered on usage drop
    //   last_effective_indicator     set: StatusManager.parse (re-fires only on effective-indicator transition)
    //   last_notified_update_version set: UpdateManager.fetch (re-fires only on a new version)

    // Fork additions
    @Published var cookieInvalid: Bool = false          // set when API returns 401/403
    @Published var lastSuccessfulUpdate: Date?          // for the stale-data check
    @Published var refreshIntervalMinutes: Int = 5      // configurable poll interval
    @Published var loginItemStatus: String = "—"        // LaunchAgent status string ("Enabled (LaunchAgent)" / "Not registered")

    // Menu-bar display modes per extra value (default: Off → only primary %).
    // % thresholds mean "show if ≥ N%"; timer thresholds mean "show if reset ≤ N min".
    @Published var sessionTimerMode: BarMode = .off
    @Published var sessionTimerThreshold: Int = 60      // minutes
    @Published var weeklyPercentMode: BarMode = .off
    @Published var weeklyPercentThreshold: Int = 80     // percent
    @Published var weeklyTimerMode: BarMode = .off
    @Published var weeklyTimerThreshold: Int = 60       // minutes
    @Published var sonnetPercentMode: BarMode = .off
    @Published var sonnetPercentThreshold: Int = 80     // percent
    @Published var blinkEnabled: Bool = true

    private func minutesUntil(_ date: Date?) -> Int? {
        guard let date = date else { return nil }
        let s = Int(date.timeIntervalSinceNow)
        return s > 0 ? s / 60 : 0
    }
    private func showPercent(mode: BarMode, value: Int, threshold: Int) -> Bool {
        switch mode {
        case .always: return true
        case .when:   return value >= threshold
        case .off:    return false
        }
    }
    private func showTimer(mode: BarMode, date: Date?, threshold: Int) -> Bool {
        switch mode {
        case .always: return true
        case .when:   if let m = minutesUntil(date) { return m <= threshold }; return false
        case .off:    return false
        }
    }
    // Effective visibility used by the menu-bar title builder.
    var showSessionTimer: Bool { showTimer(mode: sessionTimerMode, date: sessionResetsAt, threshold: sessionTimerThreshold) }
    var showWeeklyPercent: Bool { showPercent(mode: weeklyPercentMode, value: weeklyUsage, threshold: weeklyPercentThreshold) }
    var showWeeklyTimer: Bool { showTimer(mode: weeklyTimerMode, date: weeklyResetsAt, threshold: weeklyTimerThreshold) }
    var showSonnetPercent: Bool { showPercent(mode: sonnetPercentMode, value: weeklySonnetUsage, threshold: sonnetPercentThreshold) }

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
    // In-flight guard: prevents overlapping fetches from interleaving reset-detection
    // state. Set on the main thread at the top of fetchUsage(); cleared on every
    // terminal path (org-id failure, invalid URL, and the response handler).
    private var isFetching = false

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

        // Menu-bar display modes/thresholds + blink.
        let d = UserDefaults.standard
        // Int rawValue persistence keeps backward compatibility with saved 0/1/2 values.
        sessionTimerMode = BarMode(rawValue: d.integer(forKey: "session_timer_mode")) ?? .off
        weeklyPercentMode = BarMode(rawValue: d.integer(forKey: "weekly_percent_mode")) ?? .off
        weeklyTimerMode = BarMode(rawValue: d.integer(forKey: "weekly_timer_mode")) ?? .off
        sonnetPercentMode = BarMode(rawValue: d.integer(forKey: "sonnet_percent_mode")) ?? .off
        if d.object(forKey: "session_timer_thr") != nil { sessionTimerThreshold = d.integer(forKey: "session_timer_thr") }
        if d.object(forKey: "weekly_percent_thr") != nil { weeklyPercentThreshold = d.integer(forKey: "weekly_percent_thr") }
        if d.object(forKey: "weekly_timer_thr")  != nil { weeklyTimerThreshold  = d.integer(forKey: "weekly_timer_thr") }
        if d.object(forKey: "sonnet_percent_thr") != nil { sonnetPercentThreshold = d.integer(forKey: "sonnet_percent_thr") }
        blinkEnabled = d.object(forKey: "blink_enabled") == nil ? true : d.bool(forKey: "blink_enabled")
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
        let d = UserDefaults.standard
        d.set(sessionTimerMode.rawValue, forKey: "session_timer_mode")
        d.set(weeklyPercentMode.rawValue, forKey: "weekly_percent_mode")
        d.set(weeklyTimerMode.rawValue, forKey: "weekly_timer_mode")
        d.set(sonnetPercentMode.rawValue, forKey: "sonnet_percent_mode")
        d.set(sessionTimerThreshold, forKey: "session_timer_thr")
        d.set(weeklyPercentThreshold, forKey: "weekly_percent_thr")
        d.set(weeklyTimerThreshold, forKey: "weekly_timer_thr")
        d.set(sonnetPercentThreshold, forKey: "sonnet_percent_thr")
        d.set(blinkEnabled, forKey: "blink_enabled")
    }

    /// Apply menu-bar display/blink settings immediately (redraw the icon).
    func applyMenuBarSettings() {
        saveSettings()
        delegate?.redrawStatusIcon()
    }

    /// Toggle "Open at Login" and actually register/unregister with the OS.
    /// Reverts the published flag if the OS call fails, and refreshes the status string.
    func setOpenAtLogin(_ enabled: Bool) {
        // setEnabled returns false only if the plist couldn't be written; otherwise
        // reflect plist-on-disk as the real state.
        let ok = LoginItemManager.setEnabled(enabled)
        loginItemStatus = LoginItemManager.statusDescription
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
        // Trim sloppy-paste whitespace/newlines and reject control characters
        // (cheap defense-in-depth against CRLF header injection on the Cookie header).
        let clean = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.unicodeScalars.contains(where: { $0.value < 0x20 }) else {
            errorMessage = "Cookie contains invalid characters"
            return
        }
        NSLog("🔐 Saving cookie, length: \(clean.count)")
        sessionCookie = clean
        if KeychainHelper.save(clean) {
            NSLog("🔐 Cookie saved to Keychain")
        } else {
            NSLog("🔐 ⚠️ Keychain save failed")
        }
        // A freshly pasted cookie clears any prior invalid state.
        cookieInvalid = false
        UserDefaults.standard.removeObject(forKey: "cookie_invalid_notified")
    }

    func clearSessionCookie() {
        NSLog("🔐 Clearing cookie")
        sessionCookie = ""
        KeychainHelper.delete()
        // Wipe any pre-migration plaintext leftover too.
        UserDefaults.standard.removeObject(forKey: "claude_session_cookie")
        cookieInvalid = false
        UserDefaults.standard.removeObject(forKey: "cookie_invalid_notified")

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

        NSLog("🔐 Cookie cleared, data reset")
    }

    func fetchOrganizationId(cookie: String, completion: @escaping @MainActor (String?) -> Void) {
        // Get org ID from the lastActiveOrg cookie value
        let cookieParts = cookie.components(separatedBy: ";")
        for part in cookieParts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("lastActiveOrg=") {
                let orgId = trimmed.replacingOccurrences(of: "lastActiveOrg=", with: "")
                vlog("📋 Found org ID in cookie: \(orgId)")
                completion(orgId)   // already on main actor here
                return
            }
        }

        // If not in cookie, fetch from bootstrap
        guard let url = URL(string: "https://claude.ai/api/bootstrap") else {
            completion(nil)
            return
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        // Send the full cookie string as-is (same as the usage request). The user
        // pastes the entire Cookie header value, so do NOT re-wrap it in
        // "sessionKey=…" — that would duplicate the key and malform the header.
        request.setValue(cookie, forHTTPHeaderField: "Cookie")

        NSLog("📡 Fetching bootstrap to get org ID...")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if let http = response as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
                Task { @MainActor in
                    self?.handleAuthFailure()
                    completion(nil)
                }
                return
            }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let account = json["account"] as? [String: Any],
                  let lastActiveOrgId = account["lastActiveOrgId"] as? String else {
                NSLog("❌ Could not parse org ID from bootstrap")
                Task { @MainActor in completion(nil) }
                return
            }
            vlog("✅ Got org ID from bootstrap: \(lastActiveOrgId)")
            Task { @MainActor in completion(lastActiveOrgId) }
        }.resume()
    }

    func fetchUsage() {
        // Documented invariant (see file header): callers are on the main thread.
        dispatchPrecondition(condition: .onQueue(.main))

        guard !sessionCookie.isEmpty else {
            self.errorMessage = "Session cookie not set"
            self.updateStatusBar()
            return
        }

        // Reentrancy guard: only one fetch outstanding at a time.
        guard !isFetching else { return }
        isFetching = true

        // Snapshot the cookie once on main and thread it through the async paths,
        // so no self.sessionCookie read ever happens off the main thread.
        let cookie = sessionCookie

        isLoading = true
        errorMessage = nil

        // Extract org ID from cookie (completion runs on the main actor).
        fetchOrganizationId(cookie: cookie) { [weak self] orgId in
            guard let self = self, let orgId = orgId else {
                self?.errorMessage = "Could not get org ID from cookie"
                self?.isLoading = false
                self?.isFetching = false
                return
            }
            self.fetchUsageWithOrgId(orgId, cookie: cookie)
        }
    }

    func fetchUsageWithOrgId(_ orgId: String, cookie: String) {
        let urlString = "https://claude.ai/api/organizations/\(orgId)/usage"

        guard let url = URL(string: urlString) else {
            // On the main actor already.
            errorMessage = "Invalid URL"
            isLoading = false
            isFetching = false
            return
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"

        // Use the full cookie string (user provides all cookies, not just sessionKey)
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("claude.ai", forHTTPHeaderField: "authority")

        vlog("🔍 Fetching from: \(urlString)")   // contains org ID

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            // Reduce to Sendable values before hopping to the main actor.
            let status = (response as? HTTPURLResponse)?.statusCode
            let hadError = error != nil
            let errorDesc = error?.localizedDescription
            Task { @MainActor in
                guard let self = self else { return }
                self.isLoading = false
                self.isFetching = false

                if hadError {
                    NSLog("❌ Error: \(errorDesc ?? "unknown")")
                    self.errorMessage = "Network error"
                    // Icon may still reflect last-known percent, but don't re-run the
                    // notification-threshold check against stale data.
                    return
                }

                guard let status = status else {
                    self.errorMessage = "Invalid response"
                    return
                }

                NSLog("📡 Status: \(status)")

                if let data = data, let responseString = String(data: data, encoding: .utf8) {
                    vlog("📦 Response: \(responseString)")
                }

                if status == 200, let data = data {
                    self.cookieInvalid = false
                    self.parseUsageData(data)
                    // Only refresh the icon + run threshold notifications on fresh data.
                    self.updateStatusBar()
                } else if status == 401 || status == 403 {
                    self.handleAuthFailure()
                } else {
                    self.errorMessage = "HTTP \(status)"
                }
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
            Notifier.post(title: "AIMeter — cookie expired",
                          body: "AIMeter can't read your usage. Open the menu bar app and paste a fresh cookie.")
            UserDefaults.standard.set(true, forKey: "cookie_invalid_notified")
        }
    }

    /// Parse one usage window (five_hour / seven_day / seven_day_sonnet): rounded
    /// utilization percent + reset Date. Returns nil if the window key is absent.
    /// resets_at is parsed with a fractional-seconds-first ISO8601 formatter and a
    /// no-fractional fallback (mirrors StatusManager.parse), so both timestamp
    /// shapes succeed. nil resetsAt means the field was missing/unparseable — the
    /// caller keeps the previous value rather than clobbering it.
    private func parseWindow(_ key: String, in json: [String: Any]) -> (usage: Int, resetsAt: Date?)? {
        guard let dict = json[key] as? [String: Any] else { return nil }
        // Round (not floor) so display and the ≥90% / >75% thresholds stay consistent.
        let usage = (dict["utilization"] as? Double).map { Int($0.rounded()) } ?? 0
        var resetsAt: Date?
        if let s = dict["resets_at"] as? String {
            let primary = ISO8601DateFormatter()
            primary.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let fallback = ISO8601DateFormatter()
            fallback.formatOptions = [.withInternetDateTime]
            resetsAt = primary.date(from: s) ?? fallback.date(from: s)
            if resetsAt == nil { NSLog("❌ Failed to parse \(key) reset time: \(s)") }
        }
        return (usage, resetsAt)
    }

    func parseUsageData(_ data: Data) {
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                errorMessage = "Invalid JSON"
                return
            }

            NSLog("📊 Parsing usage data...")

            // Parse each usage window via the shared helper (dedups the three
            // identical blocks and centralizes the ISO8601 fractional-seconds fallback).
            if let w = parseWindow("five_hour", in: json) {
                sessionUsage = w.usage
                sessionResetsAt = w.resetsAt ?? sessionResetsAt
            }
            if let w = parseWindow("seven_day", in: json) {
                weeklyUsage = w.usage
                weeklyResetsAt = w.resetsAt ?? weeklyResetsAt
            }
            // seven_day_sonnet is a Pro-plan feature; absent for other plans.
            if let w = parseWindow("seven_day_sonnet", in: json) {
                hasWeeklySonnet = true
                weeklySonnetUsage = w.usage
                weeklySonnetResetsAt = w.resetsAt ?? weeklySonnetResetsAt
            } else {
                hasWeeklySonnet = false
            }

            // Log what we found
            NSLog("✅ Parsed: Session \(sessionUsage)%, Weekly \(weeklyUsage)%\(hasWeeklySonnet ? ", Weekly Sonnet \(weeklySonnetUsage)%" : "")")

            lastUpdated = Date()
            lastSuccessfulUpdate = Date()
            errorMessage = nil
            statusMessage = nil
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
        // sessionUsage is already a percent (0–100).
        let sessionPercent = sessionUsage

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
            }
        }

        // Re-arm: keep lastNotifiedThreshold == the highest threshold currently
        // crossed. When usage drops (e.g. a session reset toward 0%), lowering it
        // lets a later re-crossing of a threshold re-fire its alert (see the
        // `lastNotifiedThreshold < threshold` check above). Using the highest
        // threshold ≤ percentage (not 0) avoids re-firing thresholds we're still above.
        if percentage < lastNotifiedThreshold {
            let newThreshold = thresholds.filter { $0 <= percentage }.last ?? 0
            NSLog("🔄 Resetting notification threshold from \(lastNotifiedThreshold)% to \(newThreshold)%")
            lastNotifiedThreshold = newThreshold
            UserDefaults.standard.set(lastNotifiedThreshold, forKey: "last_notified_threshold")
        }
    }

    func sendNotification(percentage: Int, threshold: Int) {
        Notifier.post(title: "AIMeter — usage alert",
                      body: "You've reached \(percentage)% of your 5-hour session limit")
        NSLog("📬 Sent notification for \(threshold)% threshold")
    }

    func sendTestNotification() {
        NSLog("🔔 Test notification button clicked")
        Notifier.post(title: "AIMeter — usage alert",
                      body: "Test notification — You've reached 75% of your 5-hour session limit")
        NSLog("📬 Test notification sent successfully")
    }

    /// Session reset just happened: usage was meaningfully high and dropped to ~0.
    private func checkSessionReset(newUsage: Int) {
        guard usageNotificationsEnabled else { return }
        if previousSessionUsage >= 50 && newUsage <= 5 {
            Notifier.post(title: "AIMeter — session reset",
                          body: "Your 5-hour session limit just reset — you're back to full capacity.")
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
            Notifier.post(title: "AIMeter — session resets soon",
                          body: "About \(mins) min left before your 5-hour window resets (now at \(sessionUsage)%).")
            NSLog("📬 Reset-imminent notification sent (\(mins) min)")
            notifiedResetSoon = true
        }
        // Re-arm: once we're comfortably far from the reset, allow the next imminent alert.
        if secondsLeft > 10 * 60 { notifiedResetSoon = false }
    }

    /// Public entry for the manual "Refresh now" button.
    func refreshNow() {
        fetchUsage()
    }

    @Published var sessionPercentage: Double = 0.0
    @Published var weeklyPercentage: Double = 0.0
    @Published var weeklySonnetPercentage: Double = 0.0

    func updatePercentages() {
        // Utilization values are percents (0–100); ProgressView wants a 0–1 fraction.
        sessionPercentage = Double(sessionUsage) / 100.0
        weeklyPercentage = Double(weeklyUsage) / 100.0
        weeklySonnetPercentage = Double(weeklySonnetUsage) / 100.0
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

// Track everything except Claude for Government by default — most users don't use it.
private let defaultTrackedComponentIdSet: Set<String> = Set(
    defaultTrackedComponents.map { $0.id }.filter { $0 != "c-claude-gov" }
)

/// Polls the public Anthropic status summary (status.claude.com) and models it
/// per-component. The user picks which components to track; `effectiveIndicator`
/// and the `filtered*` views reflect only those, so an outage in an untracked
/// service neither colors the menu-bar dot nor fires a notification. Notifies
/// only on *transitions* of the effective (filtered) indicator.
@MainActor
class StatusManager: ObservableObject {
    @Published var indicator: String = "none"        // none | minor | major | critical (raw, global)
    @Published var statusDescription: String = "All systems operational"
    @Published var incidents: [StatusIncident] = []
    @Published var affectedComponents: [AffectedComponent] = []
    @Published var allComponents: [StatusComponent] = defaultTrackedComponents
    @Published var selectedComponentIds: Set<String> = defaultTrackedComponentIdSet
    @Published var lastUpdated: Date?
    @Published var hasFetched: Bool = false
    @Published var lastFetchFailed: Bool = false   // true after a network/empty-data failure

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
        let maxSeverity = trackedComponents.map { severity(for: $0.status) }.max() ?? 0
        switch maxSeverity {
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
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            // Reduce to Sendable values before hopping to the main actor.
            let errorDesc = error?.localizedDescription
            let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? -1
            Task { @MainActor in
                guard let self = self else { return }
                if let errorDesc = errorDesc {
                    NSLog("⚠️ Status fetch failed: \(errorDesc)")
                    self.lastFetchFailed = true
                    return
                }
                guard let data = data else {
                    NSLog("⚠️ Status fetch returned no data (HTTP \(httpStatus))")
                    self.lastFetchFailed = true
                    return
                }
                self.lastFetchFailed = false
                self.parse(data)
            }
        }.resume()
    }

    private func parse(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = json["status"] as? [String: Any],
              let parsedIndicator = status["indicator"] as? String,
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

        // Already on the main actor (parse is @MainActor-isolated via the class).
        let isFirstFetch = !hasFetched

        indicator = parsedIndicator
        statusDescription = desc
        incidents = parsedIncidents
        affectedComponents = parsedAffected
        if !parsedAll.isEmpty {
            allComponents = parsedAll
            // First time we see real components: track all except Claude for Government by default
            if UserDefaults.standard.array(forKey: "tracked_component_ids") == nil {
                let defaultIds = parsedAll
                    .filter { !$0.name.localizedCaseInsensitiveContains("Government") }
                    .map { $0.id }
                selectedComponentIds = Set(defaultIds)
                UserDefaults.standard.set(Array(selectedComponentIds),
                                          forKey: "tracked_component_ids")
            }
        }
        lastUpdated = Date()
        hasFetched = true

        // Notify on transitions of EFFECTIVE (filtered) indicator
        let effective = effectiveIndicator
        let previous = UserDefaults.standard.string(forKey: "last_effective_indicator")
        if !isFirstFetch, let previous = previous, previous != effective {
            notifyStatusChange(to: effective)
        }
        UserDefaults.standard.set(effective, forKey: "last_effective_indicator")

        // Refresh the menu-bar icon's center status dot.
        onStatusChange?()
    }

    /// Human-readable severity label for the EFFECTIVE (filtered) indicator. Used by
    /// both the notification body and the popover header so neither can contradict
    /// the menu-bar dot (which is also keyed off effectiveIndicator).
    func effectiveSeverityLabel(_ indicator: String) -> String {
        switch indicator {
        case "minor":    return "Minor service disruption"
        case "major":    return "Major service outage"
        case "critical": return "Critical service outage"
        default:         return "All tracked services operational"
        }
    }

    private func notifyStatusChange(to indicator: String) {
        guard UserDefaults.standard.bool(forKey: "status_notifications_enabled") else { return }

        // Derive title/body from the EFFECTIVE (filtered) state — and the actually
        // affected tracked components — so the notification can't disagree with the
        // filtered dot/header shown elsewhere.
        let title: String
        let body: String
        if indicator == "none" {
            title = "AIMeter — Claude is back online"
            body = "All tracked Claude services are operational again."
        } else {
            title = "AIMeter — \(effectiveSeverityLabel(indicator))"
            let affected = filteredAffectedComponents
            if !affected.isEmpty {
                let names = affected.prefix(3).map { $0.name }.joined(separator: ", ")
                let more = affected.count > 3 ? " +\(affected.count - 3)" : ""
                body = "Affects: \(names)\(more)"
            } else {
                body = "Visit status.claude.com for details."
            }
        }
        Notifier.post(title: title, body: body)
        NSLog("📬 Sent status-change notification: \(indicator)")
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
            // Preserve the insertion point / selection across an external binding
            // change (clamped to the new length) so it doesn't jump mid-edit.
            let ranges = textView.selectedRanges
            textView.string = text
            let len = (text as NSString).length
            textView.selectedRanges = ranges.compactMap {
                guard let r = $0 as? NSRange else { return $0 }
                let loc = min(r.location, len)
                return NSValue(range: NSRange(location: loc, length: min(r.length, len - loc)))
            }
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
    @State private var sessionCookieInput: String = ""
    @State private var showingCookieInput: Bool = false
    @State private var showingSettings: Bool = false
    @State private var showingStatusDetails: Bool = false
    // Bumped once a minute while the popover is open so countdown / relative-time
    // strings re-evaluate (they would otherwise freeze at the value shown on open).
    @State private var minuteTick: Int = 0
    private let minuteTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                content
                    // Re-render when the minute tick advances (drives live times).
                    .id(minuteTick)
                    .padding()
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
                        }
                    )
            }
            // Width is fixed; the HEIGHT is controlled by the AppDelegate via the
            // popover's contentSize (see setPopoverHeight). The ScrollView fills it.
            .frame(width: AppDelegate.popoverWidth)
            .onPreferenceChange(ContentHeightKey.self) { value in
                guard value > 0 else { return }
                // Tell AppKit the real content height so it sizes/positions the
                // popover correctly (and keeps it on-screen).
                usageManager.reportPopoverHeight(value)
            }
            .onAppear {
                usageManager.updatePercentages()
                // Re-sync the real login-item status each time the popover opens.
                usageManager.refreshLoginItemStatus()
            }
            .onReceive(minuteTimer) { _ in
                minuteTick &+= 1
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
            Text("AIMeter")
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

            if let error = usageManager.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .padding(.bottom, 8)
            } else if let status = usageManager.statusMessage {
                // Informational, not an error: neutral secondary color.
                Text(status)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 8)
            }

            // Only show usage if data has been fetched
            if !usageManager.hasFetchedData {
                Text("👋 Welcome! Set your session cookie below to get started.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            }

            // Usage rows (all share the same layout via usageRow).
            if usageManager.hasFetchedData {
                usageRow(title: "Session (5 hour)",
                         percentage: usageManager.sessionPercentage,
                         resetDate: usageManager.sessionResetsAt,
                         countdown: usageManager.sessionResetCountdown,
                         color: Palette.session)

                usageRow(title: "Weekly (7 day)",
                         percentage: usageManager.weeklyPercentage,
                         resetDate: usageManager.weeklyResetsAt,
                         countdown: usageManager.weeklyResetCountdown,
                         color: Palette.weekly,
                         includeDate: true)

                if usageManager.hasWeeklySonnet {
                    usageRow(title: "Weekly Sonnet (7 day)",
                             percentage: usageManager.weeklySonnetPercentage,
                             resetDate: usageManager.weeklySonnetResetsAt,
                             countdown: usageManager.sonnetResetCountdown,
                             color: Palette.sonnet,
                             includeDate: true)
                }
            }

            if statusManager.hasFetched {
                Divider()
            }

            // Anthropic service status (compact; expandable on issue)
            if statusManager.hasFetched {
                statusSection
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

            cookiePanel

            // Settings Section
            Button(showingSettings ? "Hide Settings" : "Settings") {
                showingSettings.toggle()
            }
            .buttonStyle(.borderless)
            .font(.caption)

            if showingSettings {
                settingsSection

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

    // MARK: - Extracted sections

    @ViewBuilder
    private var statusSection: some View {
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
                            // Use the EFFECTIVE (filtered) severity label, not the
                            // global statusManager.statusDescription, so this header
                            // can't contradict the filtered menu-bar dot.
                            Text(effective == "none"
                                 ? "All Claude services operational"
                                 : statusManager.effectiveSeverityLabel(effective))
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

    @ViewBuilder
    private var cookiePanel: some View {
        if showingCookieInput {
                VStack(alignment: .leading, spacing: 8) {
                    // Inline steps below are self-contained; no external tutorial link
                    // (the old one pointed at the upstream ClaudeUsageBar repo).
                    Text("How to get your session cookie:")
                        .font(.caption)
                        .fontWeight(.semibold)

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
                        // Read-only preview of the currently stored cookie. Shown as a
                        // label (not seeded into the editable field) so a user can't
                        // accidentally save the truncated preview over the real cookie.
                        if !usageManager.cookieHint.isEmpty {
                            Text("Current: \(usageManager.cookieHint)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        VStack(spacing: 4) {
                            PasteableTextField(text: $sessionCookieInput, placeholder: "Paste cookie here...")
                                .frame(height: 60)
                                .cornerRadius(4)

                            HStack(spacing: 8) {
                                Button("Save Cookie & Fetch") {
                                    NSLog("🔐 Save clicked, input length: \(sessionCookieInput.count)")
                                    if sessionCookieInput.isEmpty {
                                        usageManager.errorMessage = "Cookie field is empty!"
                                    } else if sessionCookieInput == usageManager.cookieHint {
                                        // The truncated preview is not a real cookie.
                                        usageManager.errorMessage = "Paste a full cookie, not the preview"
                                    } else {
                                        usageManager.saveSessionCookie(sessionCookieInput)
                                        // Informational status (secondary color), not an error,
                                        // and set BEFORE fetchUsage() so its errorMessage=nil reset
                                        // doesn't clobber it.
                                        usageManager.statusMessage = "Cookie saved, fetching…"
                                        usageManager.fetchUsage()
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)

                                if !usageManager.cookieHint.isEmpty {
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
    }

    @ViewBuilder
    private var settingsSection: some View {
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

                    // Menu-bar display (fork): each extra value can be Off / Always /
                    // When (conditional on a %-or-time threshold).
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Show in menu bar")
                            .font(.caption).fontWeight(.semibold)
                        barRow("Session reset timer", Palette.session, isPercent: false,
                               modeGet: { usageManager.sessionTimerMode }, modeSet: { usageManager.sessionTimerMode = $0 },
                               thrGet: { usageManager.sessionTimerThreshold }, thrSet: { usageManager.sessionTimerThreshold = $0 })
                        barRow("Weekly usage %", Palette.weekly, isPercent: true,
                               modeGet: { usageManager.weeklyPercentMode }, modeSet: { usageManager.weeklyPercentMode = $0 },
                               thrGet: { usageManager.weeklyPercentThreshold }, thrSet: { usageManager.weeklyPercentThreshold = $0 })
                        barRow("Weekly reset timer", Palette.weekly, isPercent: false,
                               modeGet: { usageManager.weeklyTimerMode }, modeSet: { usageManager.weeklyTimerMode = $0 },
                               thrGet: { usageManager.weeklyTimerThreshold }, thrSet: { usageManager.weeklyTimerThreshold = $0 })
                        barRow("Weekly Sonnet usage %", Palette.sonnet, isPercent: true,
                               modeGet: { usageManager.sonnetPercentMode }, modeSet: { usageManager.sonnetPercentMode = $0 },
                               thrGet: { usageManager.sonnetPercentThreshold }, thrSet: { usageManager.sonnetPercentThreshold = $0 })
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
    }

    private var appVersionString: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "v\(short) · build \(build)"
    }

    /// One usage progress row: title + reset time, the colored bar, and "% used".
    @ViewBuilder
    private func usageRow(title: String, percentage: Double, resetDate: Date?,
                          countdown: String?, color: Color, includeDate: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                if let resetTime = resetDate {
                    Text("Resets \(formatResetTime(resetTime, includeDate: includeDate))\(countdown.map { " · in \($0)" } ?? "")")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            ProgressView(value: percentage).tint(color)
            Text("\(Int(percentage * 100))% used").font(.caption).foregroundColor(color)
        }
    }

    /// One configurable menu-bar value: label + mode picker (Off/Always/When) and,
    /// when "When", a threshold stepper (% for percentages, minutes for timers).
    @ViewBuilder
    private func barRow(_ label: String, _ color: Color, isPercent: Bool,
                        modeGet: @escaping () -> BarMode, modeSet: @escaping (BarMode) -> Void,
                        thrGet: @escaping () -> Int, thrSet: @escaping (Int) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption2).foregroundColor(color)
                Spacer()
                Picker("", selection: Binding(get: modeGet, set: { modeSet($0); usageManager.applyMenuBarSettings() })) {
                    Text("Off").tag(BarMode.off)
                    Text("Always").tag(BarMode.always)
                    Text("When…").tag(BarMode.when)
                }
                .labelsHidden().pickerStyle(.menu).font(.caption2).fixedSize()
            }
            if modeGet() == .when {
                let thr = Binding(get: thrGet, set: { thrSet($0); usageManager.applyMenuBarSettings() })
                if isPercent {
                    Stepper("show if ≥ \(thrGet())%", value: thr, in: 0...100, step: 5)
                        .font(.caption2).foregroundColor(.secondary)
                } else {
                    Stepper("show if reset ≤ \(thrGet()) min", value: thr, in: 5...300, step: 5)
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
        }
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

    func statusColor(for indicator: String) -> Color {
        switch indicator {
        case "none":     return .green
        case "minor":    return .yellow
        case "major":    return .orange
        case "critical": return .red
        default:         return .gray
        }
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
