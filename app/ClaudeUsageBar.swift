//
//  AIMeter — a macOS menu-bar app that tracks Claude usage and Anthropic status.
//
//  Single-file SwiftUI + AppKit app (no Xcode project; built with `swiftc` via
//  build-local.sh). Personal fork of ClaudeUsageBar (MIT).
//
//  Architecture (top → bottom in this file):
//    • KeychainHelper   — stores the claude.ai session cookie in the login Keychain
//    • LoginItemManager — real launch-at-login via a per-user LaunchAgent
//    • Palette          — per-window identity colors (session/weekly/per-model)
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
enum BarMode: Int, Codable {
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
    static let consoleAccount = "console_session_cookie"   // platform.claude.com session (fork)

    @discardableResult
    static func save(_ value: String, account: String = account) -> Bool {
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

    static func load(from svc: String = service, account: String = account) -> String? {
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
    static func delete(account: String = account) -> Bool {
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
            // session exactly as a double-click would. Escape XML-special chars so
            // an unusual install path can't break (or inject into) the plist.
            let appPath = Bundle.main.bundlePath
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
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
// Session=green, Weekly=blue, per-model weekly (e.g. Fable)=orange. Red = alarm.
// Menu-bar colors stay bright (translucent backdrop); popover colors run darker.
enum Palette {
    // Menu-bar colors: DYNAMIC — the menu bar can be dark (dark mode / dark
    // wallpaper tint) or light (light mode). Bright variants read well on dark
    // but wash out on light, so each resolves per-appearance. The bitmap icon
    // bakes them via the status button's effectiveAppearance (see drawIcon).
    private static func dyn(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
    static let sessionNS = dyn(light: NSColor(srgbRed: 0.11, green: 0.55, blue: 0.24, alpha: 1),  // #1C8C3D
                               dark:  NSColor(srgbRed: 0.18, green: 0.82, blue: 0.35, alpha: 1))  // #30D158
    static let weeklyNS  = dyn(light: NSColor(srgbRed: 0.05, green: 0.42, blue: 0.68, alpha: 1),  // #0D6BAD
                               dark:  NSColor(srgbRed: 0.75, green: 0.91, blue: 1.00, alpha: 1))  // #BFE8FF
    static let modelNS   = dyn(light: NSColor(srgbRed: 0.72, green: 0.40, blue: 0.00, alpha: 1),  // #B86600
                               dark:  NSColor(srgbRed: 1.00, green: 0.78, blue: 0.36, alpha: 1))  // #FFC75C
    static let alertNS   = dyn(light: NSColor(srgbRed: 0.84, green: 0.00, blue: 0.08, alpha: 1),  // #D60014
                               dark:  NSColor(srgbRed: 1.00, green: 0.23, blue: 0.19, alpha: 1))  // #FF3B30
    static let warnNS    = dyn(light: NSColor(srgbRed: 0.80, green: 0.60, blue: 0.00, alpha: 1),  // #CC9900
                               dark:  NSColor(srgbRed: 1.00, green: 0.80, blue: 0.00, alpha: 1))  // #FFCC00
    static let creditsNS = dyn(light: NSColor(srgbRed: 0.43, green: 0.25, blue: 0.76, alpha: 1),  // #6E3FC2
                               dark:  NSColor(srgbRed: 0.95, green: 0.71, blue: 1.00, alpha: 1))  // #F2B5FF
    static let consoleNS = dyn(light: NSColor(srgbRed: 0.04, green: 0.56, blue: 0.43, alpha: 1),  // #0A8F6E
                               dark:  NSColor(srgbRed: 0.66, green: 0.96, blue: 0.86, alpha: 1))  // #A8F5DC
    static let agyNS     = dyn(light: NSColor(srgbRed: 0.30, green: 0.30, blue: 0.33, alpha: 1),  // #4D4D54
                               dark:  NSColor(srgbRed: 0.92, green: 0.92, blue: 0.94, alpha: 1))  // #EBEBF0
    static let codexNS   = dyn(light: NSColor(srgbRed: 0.48, green: 0.42, blue: 0.00, alpha: 1),  // #7A6B00
                               dark:  NSColor(srgbRed: 1.00, green: 0.94, blue: 0.63, alpha: 1))  // #FFF0A0

    static let session = Color(.sRGB, red: 0.13, green: 0.62, blue: 0.27)  // darker #219E45
    static let weekly  = Color(.sRGB, red: 0.10, green: 0.48, blue: 0.75)  // darker #1A7ABF
    static let model   = Color(.sRGB, red: 0.85, green: 0.50, blue: 0.02)  // darker #D98005
    static let credits = Color(.sRGB, red: 0.55, green: 0.31, blue: 0.85)  // darker #8C4FD9
    static let console = Color(.sRGB, red: 0.06, green: 0.61, blue: 0.47)  // darker #0F9B78
    static let agy     = Color(.sRGB, red: 0.42, green: 0.42, blue: 0.45)  // graphite #6B6B73
    static let codex   = Color(.sRGB, red: 0.60, green: 0.52, blue: 0.00)  // dark gold #998500
    static let alert   = Color(.sRGB, red: 1.00, green: 0.23, blue: 0.19)

    /// Identity color of a usage limit, by kind: (menu bar, popover).
    static func limitColors(_ kind: String) -> (bar: NSColor, popover: Color) {
        switch kind {
        case "session":    return (sessionNS, session)
        case "weekly_all": return (weeklyNS, weekly)
        default:           return (modelNS, model)
        }
    }

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
    // The ring now tracks the WEEKLY window: blinking from 75% would go on for days,
    // so the alarm blink starts later than the red shift.
    static let blinkThreshold = 90
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
    // Last measured SwiftUI content height; used to size the popover before each show.
    var lastPopoverHeight: CGFloat = 360
    // Opaque backdrop slipped under the popover content (see openPopover).
    var popoverOpaqueBG: NSView?
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

            // The ring icon is a baked bitmap: re-render it when the menu bar
            // flips light/dark (the title's dynamic colors update on their own).
            // No appearance observer: the ring icon draws lazily (drawingHandler), so
            // its dynamic colors resolve against the menu bar's light/dark at render
            // time. An effectiveAppearance KVO observer that redrew the icon caused an
            // infinite redraw loop (~95% CPU on macOS 27): AppKit toggles the button's
            // appearance while rendering the status item, and every redraw re-fired it.
        }

        // Initialize managers
        usageManager = UsageManager(statusItem: statusItem, delegate: self)
        statusManager = StatusManager()

        // Refresh the menu-bar icon (center status dot) whenever service status changes.
        statusManager.onStatusChange = { [weak self] in self?.redrawStatusIcon() }

        // Create popover. We size it ourselves (sizingOptions = []) and set contentSize
        // ONLY before showing (in openPopover). Two AppKit traps this avoids:
        //  • Letting the hosting controller auto-grow the popover from SwiftUI's
        //    intrinsic size makes NSPopover expand UPWARD off the top of the screen —
        //    you can't scroll to the top.
        //  • Mutating contentSize while the popover is already visible makes NSPopover
        //    drop its anchor and jump to the screen's left edge.
        // So: one fixed size per showing; taller content scrolls inside.
        popover = NSPopover()
        popover.contentSize = NSSize(width: AppDelegate.popoverWidth, height: 360)
        popover.behavior = .transient
        popover.delegate = self
        let hosting = NSHostingController(rootView: UsageView(
            usageManager: usageManager,
            statusManager: statusManager
        ))
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
            // Size the popover from the last measured content height BEFORE showing.
            // (Resizing AFTER show is what breaks NSPopover's anchoring / pushes the
            // top off-screen — so we never do it while visible.)
            popover.contentSize = NSSize(width: AppDelegate.popoverWidth,
                                         height: clampedPopoverHeight(lastPopoverHeight))
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            installOpaquePopoverBackground()

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

    /// NSPopover's default vibrant material lets whatever sits behind bleed
    /// through — over a dark/busy window the content becomes unreadable. Slip an
    /// opaque window-background view UNDER the content, inside the popover's
    /// frame view: the frame's layer mask keeps rounded corners + arrow shape.
    /// Runs after every show() because AppKit can recreate the popover window
    /// (a stale view would silently bring the transparency back); the color is
    /// re-resolved each time so a light/dark theme switch is picked up too.
    func installOpaquePopoverBackground() {
        guard let contentView = popover.contentViewController?.view,
              let frameView = contentView.superview else { return }
        let bg: NSView
        if let existing = popoverOpaqueBG, existing.superview === frameView {
            bg = existing
        } else {
            popoverOpaqueBG?.removeFromSuperview()
            bg = NSView(frame: frameView.bounds)
            bg.wantsLayer = true
            bg.autoresizingMask = [.width, .height]
            frameView.addSubview(bg, positioned: .below, relativeTo: contentView)
            popoverOpaqueBG = bg
        }
        frameView.effectiveAppearance.performAsCurrentDrawingAppearance {
            bg.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
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

    /// Clamp a desired popover height to fit below the menu bar on the screen the
    /// status item actually lives on (NOT `NSScreen.main`, which follows the active
    /// Space/key window and gives wrong results per virtual desktop). Capped well
    /// below full height so a long Settings list scrolls instead of growing the
    /// popover until AppKit mis-places it.
    func clampedPopoverHeight(_ h: CGFloat) -> CGFloat {
        let screen = statusItem?.button?.window?.screen ?? NSScreen.main
        let maxH = min((screen?.visibleFrame.height ?? 800) - 20, 600)
        return min(max(h, 120), maxH)
    }

    /// Remember the SwiftUI-measured content height to size the popover at the NEXT
    /// open. We deliberately do NOT resize while the popover is visible — mutating a
    /// shown NSPopover's contentSize makes it jump to the screen edge and pushes the
    /// top off-screen. Content taller than the popover simply scrolls (Settings
    /// auto-scrolls into view).
    func setPopoverHeight(_ h: CGFloat) {
        lastPopoverHeight = clampedPopoverHeight(h)
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
        if percent <= AppDelegate.dangerThreshold { return Palette.weeklyNS }   // same blue as the weekly % text
        let t = CGFloat(min(1.0, Double(percent - AppDelegate.dangerThreshold) / Double(AppDelegate.dangerSpan)))
        // Dynamic too: lerp the light or dark variants depending on where it's drawn.
        return NSColor(name: nil) { appearance in
            var c = Palette.weeklyNS
            appearance.performAsCurrentDrawingAppearance { c = Palette.lerp(Palette.weeklyNS, Palette.alertNS, t) }
            return c
        }
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
        let danger = blinkEnabled && lastSessionPercent > AppDelegate.blinkThreshold
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
        let dangerActive = blinkEnabled && percent > AppDelegate.blinkThreshold
        let drawRing = !(dangerActive && !ringBlinkOn)
        let dot = statusDotColor()
        let drawDot = dot != nil && !(blinkEnabled && !statusBlinkOn)

        // Icon and title both keep dynamic colors and resolve them at draw time
        // against the menu bar's actual appearance (light vs dark).
        button.image = createRingIcon(percentage: percent,
                                      color: sessionRingColor(percent),
                                      drawRing: drawRing,
                                      dotColor: drawDot ? dot : nil)
        button.attributedTitle = menuBarTitle()
    }

    /// Colored menu-bar text: session % (+optional bits), then weekly, then per-model.
    /// Differentiated by color (no letter tags). Extras are behind Settings toggles.
    func menuBarTitle() -> NSAttributedString {
        let s = NSMutableAttributedString()
        // On a dark (wallpaper-tinted) bar a soft dark halo keeps colored text legible
        // whatever shows through; on a light bar it would only smudge.
        var attrs: [NSAttributedString.Key: Any] = [:]
        if statusItem.button?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua {
            let halo = NSShadow()
            halo.shadowColor = NSColor.black.withAlphaComponent(0.55)
            halo.shadowBlurRadius = 2
            halo.shadowOffset = NSSize(width: 0, height: -0.5)
            attrs[.shadow] = halo
        }
        func seg(_ text: String, _ color: NSColor) {
            var a = attrs
            a[.foregroundColor] = color
            s.append(NSAttributedString(string: text, attributes: a))
        }
        guard let um = usageManager else { return NSAttributedString(string: " \(lastSessionPercent)%") }


        // One segment per API limit; % and timer are independent options.
        var first = true
        for l in um.limits {
            var parts: [String] = []
            if um.showLimitPercent(l) { parts.append("\(l.percent)%") }
            if um.showLimitTimer(l), let t = UsageManager.countdown(to: l.resetsAt) { parts.append(t) }
            guard !parts.isEmpty else { continue }
            seg((first ? " " : "  ") + parts.joined(separator: " "), Palette.limitColors(l.kind).bar)
            first = false
        }
        // Antigravity pools: same per-item options as the Claude limits.
        for q in um.agyQuotas {
            let o = um.barSettings(for: q.id)
            var parts: [String] = []
            if um.showPercent(mode: o.percentMode, value: q.percent, threshold: o.percentThreshold) { parts.append("\(q.percent)%") }
            if um.showTimer(mode: o.timerMode, date: q.resetsAt, threshold: o.timerThreshold),
               let t = UsageManager.countdown(to: q.resetsAt) { parts.append(t) }
            if !parts.isEmpty { seg("  " + parts.joined(separator: " "), Palette.agyNS) }
        }
        // Money balances: Max extra-usage credits, Console API credits.
        if um.showExtraCredits, let t = um.extraCreditsText { seg("  " + t, Palette.creditsNS) }
        // Console: purchased credits, then the promotional bonus marked with "+".
        var consoleParts: [String] = []
        if um.showConsolePurchased { consoleParts.append(UsageManager.formatMoney(minor: um.consolePurchasedMinor, currency: um.consoleCurrency)) }
        if um.showConsoleBonus { consoleParts.append("+" + UsageManager.formatMoney(minor: um.consolePromoMinor, currency: um.consoleCurrency)) }
        if !consoleParts.isEmpty { seg("  " + consoleParts.joined(separator: " "), Palette.consoleNS) }
        // Codex: % and timer are independent toggles, same as Weekly.
        if let w = um.codexWindows.first, um.showCodexPercent || um.showCodexTimer {
            var parts: [String] = []
            if um.showCodexPercent { parts.append("\(w.percent)%") }
            if um.showCodexTimer, let t = UsageManager.countdown(to: w.resetsAt) { parts.append(t) }
            if !parts.isEmpty { seg("  " + parts.joined(separator: " "), Palette.codexNS) }
        }
        return s
    }

    /// Progress ring: faint track + arc that fills clockwise with `percentage`.
    /// `drawRing=false` hides the ring for the alarm-blink off-phase. A center dot
    /// (if `dotColor` set) flags a service disruption.
    func createRingIcon(percentage: Int, color: NSColor, drawRing: Bool = true, dotColor: NSColor? = nil) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let center = NSPoint(x: 8, y: 8)
        let radius: CGFloat = 6
        let lineWidth: CGFloat = 2.4
        let fraction = max(0.0, min(1.0, Double(percentage) / 100.0))

        // Drawn lazily by AppKit in the current appearance, so dynamic colors pick
        // the light or dark menu-bar variant on their own (no observer needed).
        let image = NSImage(size: size, flipped: false) { _ in

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

            return true
        }
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

/// One usage window exactly as claude.ai's `limits` array reports it. Popover
/// rows, Settings rows, menu-bar values and snapshot lines are all generated from
/// the list, so a window Anthropic adds or drops shows up / disappears without a
/// code change (the 5-hour session vanished in Nov 2026; per-model ones come and go).
struct UsageLimit: Equatable, Identifiable {
    let id: String          // stable settings key: kind, plus the scope name when scoped
    let kind: String        // "weekly_all", "weekly_scoped", "session", or a future kind
    let title: String       // "Weekly", "Weekly Fable", "Session"…
    let duration: String?   // "7 d", "5 h"; nil when the API gives no hint
    let percent: Int
    let resetsAt: Date?

    static func make(kind: String, scope: String?, group: String?, percent: Int, resetsAt: Date?) -> UsageLimit {
        let title: String
        switch kind {
        case "session":       title = "Session"
        case "weekly_all":    title = "Weekly"
        case "weekly_scoped": title = "Weekly \(scope ?? "model")"
        default:
            title = kind.replacingOccurrences(of: "_", with: " ").capitalized + (scope.map { " \($0)" } ?? "")
        }
        let duration: String?
        switch group ?? kind {
        case "session", "five_hour":                     duration = "5 h"
        case "daily":                                    duration = "1 d"
        case "weekly", "weekly_all", "weekly_scoped":    duration = "7 d"
        case "monthly":                                  duration = "30 d"
        default:                                         duration = kind.hasPrefix("weekly") ? "7 d" : nil
        }
        return UsageLimit(id: scope.map { "\(kind):\($0)" } ?? kind, kind: kind, title: title,
                          duration: duration, percent: percent, resetsAt: resetsAt)
    }

    /// Popover title: "Weekly Fable (7 day)".
    var rowTitle: String {
        guard let d = duration else { return title }
        let long = d.replacingOccurrences(of: " d", with: " day").replacingOccurrences(of: " h", with: " hour")
        return "\(title) (\(long))"
    }
    /// Snapshot name, kept stable for the reading agent.
    var snapshotName: String { kind == "weekly_all" ? "Weekly, all models" : title }
}

/// Menu-bar options of one limit. New limits start Off (the bar never grows by
/// surprise); only the all-models weekly % is on by default.
struct LimitBarSettings: Codable, Equatable {
    var percentMode: BarMode = .off
    var percentThreshold: Int = 80      // show if ≥ N%
    var timerMode: BarMode = .off
    var timerThreshold: Int = 60        // show if reset ≤ N min
}

/// The core model. Polls claude.ai's internal usage API — primary source is the
/// June-2026 `limits` array (session / weekly_all / per-model weekly_scoped), with
/// the legacy five_hour / seven_day / seven_day_sonnet keys as fallback — and
/// publishes everything the popover and the menu-bar title render. Also owns:
///   • the session cookie (loaded from / saved to the Keychain via KeychainHelper),
///   • all persisted settings (UserDefaults: refresh interval, menu-bar display
///     modes/thresholds, notification toggles, tracked-component selection),
///   • usage notifications (per-threshold, session-reset, reset-imminent),
///   • the conditional menu-bar visibility logic (show* computed properties).
/// Network callbacks marshal back to the main thread before mutating @Published state.
/// One Google Antigravity quota bucket, as `agy --print /quota` reports it (one
/// shared weekly pool per model group today).
struct AgyQuota: Equatable, Identifiable {
    let id: String          // settings key: "agy:<bucket id>"
    let group: String       // "Gemini Models", "Claude and GPT models"
    let window: String      // "weekly", "5h"…
    let percent: Int        // USED percent (the CLI reports the remaining fraction)
    let resetsAt: Date?

    /// "7 d" / "5 h" like the other snapshot lines; nil when unrecognized.
    var duration: String? {
        switch window {
        case "weekly": return "7 d"
        case "daily":  return "1 d"
        case "5h":     return "5 h"
        default:       return nil
        }
    }
    var rowTitle: String { "Antigravity · \(group)" + (window.isEmpty ? "" : " (\(window))") }
}

/// One Codex rate-limit window (free plan: a single 30-day window; paid plans add
/// a 5-hour primary + weekly secondary).
struct CodexWindow: Equatable {
    let percent: Int
    let windowMinutes: Int
    let resetsAt: Date?

    /// Snapshot naming: "(5 h)", "(7 d)", "(30 d)" like the Claude lines.
    var shortDuration: String {
        windowMinutes <= 0 ? "unknown"
            : windowMinutes % 1440 == 0 ? "\(windowMinutes / 1440) d"
            : windowMinutes % 60 == 0 ? "\(windowMinutes / 60) h" : "\(windowMinutes) min"
    }
    var quotaName: String {
        switch windowMinutes {
        case 300:   return "session"
        case 10080: return "weekly"
        case 43200: return "monthly"
        default:    return "quota"
        }
    }

    /// "5 hour", "7 day", "30 day"…
    var label: String {
        windowMinutes <= 0 ? "window"
            : windowMinutes % 1440 == 0 ? "\(windowMinutes / 1440) day"
            : windowMinutes % 60 == 0 ? "\(windowMinutes / 60) hour" : "\(windowMinutes) min"
    }
}

/// One prepaid-credit tranche as the Console reports it (purchased or promotional).
/// Kept per tranche so the export can show exactly how much promo is left and when
/// it expires — a single sum would hide that.
struct CreditTranche: Equatable {
    let name: String
    let remainingMinor: Int
    let grantedMinor: Int
    let expiresAt: Date?
    let scope: String?      // nil/unscoped = any model/product
}

@MainActor
class UsageManager: ObservableObject {
    // Every window the API reports, in API order. `weeklyUsage` is the primary one
    // (all-models weekly, else the first): it drives the ring and the alerts.
    @Published var limits: [UsageLimit] = []
    @Published var weeklyUsage: Int = 0
    @Published var limitSettings: [String: LimitBarSettings] = [:]
    @Published var lastUpdated: Date = Date()
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    // Informational status (e.g. "Cookie saved, fetching…"). Rendered distinctly
    // from errorMessage (secondary color, not orange). Real failures stay on errorMessage.
    @Published var statusMessage: String?
    @Published var usageNotificationsEnabled: Bool = true
    @Published var statusNotificationsEnabled: Bool = true
    @Published var openAtLogin: Bool = false
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

    @Published var blinkEnabled: Bool = true

    // API prepaid credit balance from the Console (platform.claude.com), fork.
    // Minor units (cents); nil until the first successful fetch.
    @Published var extraCreditsMinor: Int?
    @Published var extraCreditsGrantedMinor: Int?         // sum of granted tranches (bar denominator)
    @Published var extraCreditsCurrency: String = "EUR"
    @Published var extraCreditsError: String?             // shown as a quiet line in the popover
    @Published var extraCreditsMode: BarMode = .off
    @Published var extraCreditsThreshold: Int = 20           // whole currency units: show when balance ≤

    // Console (platform.claude.com) API credit balance: purchased + promo tranches.
    @Published var extraTranches: [CreditTranche] = []      // Max extra-usage tranches (for export)
    @Published var consoleCreditsMinor: Int?                // total remaining, minor units
    @Published var consolePurchasedTranches: [CreditTranche] = []
    @Published var consolePromoTranches: [CreditTranche] = []
    @Published var consolePurchasedMinor: Int = 0
    @Published var consolePromoMinor: Int = 0
    @Published var consolePromoExpires: Date?               // earliest promo expiry
    @Published var consoleCurrency: String = "USD"
    @Published var consoleCreditsError: String?
    @Published var consoleMode: BarMode = .off
    @Published var consoleThreshold: Int = 20               // bonus: show when ≤ (whole currency units)
    @Published var consolePurchasedMode: BarMode = .off
    @Published var consolePurchasedThreshold: Int = 20      // purchased: show when ≤
    @Published var snapshotDirectory: String = ""           // "" = default (Application Support/AIMeter)

    // OpenAI Codex quota (fork), read from the local `codex` CLI. nil = not fetched.
    @Published var codexWindows: [CodexWindow] = []         // primary (+ secondary when the plan has one)
    @Published var codexPlan: String?
    @Published var codexError: String?
    @Published var codexPercentMode: BarMode = .off
    @Published var codexPercentThreshold: Int = 80
    @Published var codexTimerMode: BarMode = .off
    @Published var codexTimerThreshold: Int = 60            // minutes
    private var codexFetching = false

    // Google Antigravity quota (fork), read from the local `agy` CLI.
    @Published var agyQuotas: [AgyQuota] = []
    @Published var agyError: String?
    private var agyFetching = false
    private var agyLastFetch: Date?

    private func minutesUntil(_ date: Date?) -> Int? {
        guard let date = date else { return nil }
        let s = Int(date.timeIntervalSinceNow)
        return s > 0 ? s / 60 : 0
    }
    func showPercent(mode: BarMode, value: Int, threshold: Int) -> Bool {
        switch mode {
        case .always: return true
        case .when:   return value >= threshold
        case .off:    return false
        }
    }
    func showTimer(mode: BarMode, date: Date?, threshold: Int) -> Bool {
        switch mode {
        case .always: return true
        case .when:   if let m = minutesUntil(date) { return m <= threshold }; return false
        case .off:    return false
        }
    }
    // Per-limit menu-bar options (keyed by UsageLimit.id).
    func barSettings(for id: String) -> LimitBarSettings {
        if let s = limitSettings[id] { return s }
        var s = LimitBarSettings()
        if id == "weekly_all" { s.percentMode = .always }   // the base value
        return s
    }
    func updateBarSettings(for id: String, _ change: (inout LimitBarSettings) -> Void) {
        var s = barSettings(for: id)
        change(&s)
        limitSettings[id] = s
    }
    func showLimitPercent(_ l: UsageLimit) -> Bool {
        let s = barSettings(for: l.id)
        return showPercent(mode: s.percentMode, value: l.percent, threshold: s.percentThreshold)
    }
    func showLimitTimer(_ l: UsageLimit) -> Bool {
        let s = barSettings(for: l.id)
        return showTimer(mode: s.timerMode, date: l.resetsAt, threshold: s.timerThreshold)
    }
    var showExtraCredits: Bool {
        guard let minor = extraCreditsMinor else { return false }
        switch extraCreditsMode {
        case .always: return true
        case .when:   return minor <= extraCreditsThreshold * 100
        case .off:    return false
        }
    }
    var extraCreditsText: String? {
        extraCreditsMinor.map { UsageManager.formatMoney(minor: $0, currency: extraCreditsCurrency) }
    }
    // Console money in the menu bar: promotional bonus and purchased credits are
    // two independent values, each with its own mode/threshold.
    private func showMoney(mode: BarMode, minor: Int, threshold: Int) -> Bool {
        guard consoleCreditsMinor != nil else { return false }
        switch mode {
        case .always: return true
        case .when:   return minor <= threshold * 100
        case .off:    return false
        }
    }
    var showConsoleBonus: Bool { showMoney(mode: consoleMode, minor: consolePromoMinor, threshold: consoleThreshold) }
    var showConsolePurchased: Bool { showMoney(mode: consolePurchasedMode, minor: consolePurchasedMinor, threshold: consolePurchasedThreshold) }
    var showCodexPercent: Bool {
        guard let w = codexWindows.first else { return false }
        return showPercent(mode: codexPercentMode, value: w.percent, threshold: codexPercentThreshold)
    }
    var showCodexTimer: Bool { showTimer(mode: codexTimerMode, date: codexWindows.first?.resetsAt, threshold: codexTimerThreshold) }

    static func formatMoney(minor: Int, currency: String) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.maximumFractionDigits = 2
        let value = Double(minor) / 100.0
        return f.string(from: NSNumber(value: value)) ?? String(format: "%.2f %@", value, currency)
    }

    // Countdown to a window's reset (e.g. "1h59m", "2d17h", "<1m"); nil if unknown.
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

    private var statusItem: NSStatusItem?
    private var sessionCookie: String = ""
    private var consoleCookie: String = ""     // platform.claude.com session (fork)
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
        consoleCookie = KeychainHelper.load(account: KeychainHelper.consoleAccount) ?? ""
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
    var consoleCookieHint: String {
        guard !consoleCookie.isEmpty else { return "" }
        return String(consoleCookie.prefix(20)) + "..."
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
        // Per-limit options live in one JSON blob. First run after the dynamic-limits
        // change: seed it from the old fixed keys (the per-model ones are parked under
        // "legacy_scoped" until the first fetch tells us that model's name).
        if let data = d.data(forKey: "limit_bar_settings"),
           let saved = try? JSONDecoder().decode([String: LimitBarSettings].self, from: data) {
            limitSettings = saved
        } else {
            func legacy(_ pm: String, _ pt: String, _ tm: String, _ tt: String, percentDefault: BarMode) -> LimitBarSettings {
                var s = LimitBarSettings()
                s.percentMode = d.object(forKey: pm) == nil ? percentDefault : BarMode(rawValue: d.integer(forKey: pm)) ?? .off
                if d.object(forKey: pt) != nil { s.percentThreshold = d.integer(forKey: pt) }
                s.timerMode = BarMode(rawValue: d.integer(forKey: tm)) ?? .off
                if d.object(forKey: tt) != nil { s.timerThreshold = d.integer(forKey: tt) }
                return s
            }
            limitSettings["weekly_all"] = legacy("weekly_percent_mode", "weekly_percent_thr",
                                                 "weekly_timer_mode", "weekly_timer_thr", percentDefault: .always)
            limitSettings["legacy_scoped"] = legacy("sonnet_percent_mode", "sonnet_percent_thr",
                                                    "model_timer_mode", "model_timer_thr", percentDefault: .off)
        }
        extraCreditsMode = BarMode(rawValue: d.integer(forKey: "extra_credits_mode")) ?? .off
        if d.object(forKey: "extra_credits_thr") != nil { extraCreditsThreshold = d.integer(forKey: "extra_credits_thr") }
        consoleMode = BarMode(rawValue: d.integer(forKey: "console_mode")) ?? .off
        consolePurchasedMode = BarMode(rawValue: d.integer(forKey: "console_purchased_mode")) ?? .off
        if d.object(forKey: "console_purchased_thr") != nil { consolePurchasedThreshold = d.integer(forKey: "console_purchased_thr") }
        if d.object(forKey: "console_thr") != nil { consoleThreshold = d.integer(forKey: "console_thr") }
        snapshotDirectory = d.string(forKey: "snapshot_dir") ?? ""
        codexPercentMode = BarMode(rawValue: d.integer(forKey: "codex_percent_mode")) ?? .off
        if d.object(forKey: "codex_percent_thr") != nil { codexPercentThreshold = d.integer(forKey: "codex_percent_thr") }
        codexTimerMode = BarMode(rawValue: d.integer(forKey: "codex_timer_mode")) ?? .off
        if d.object(forKey: "codex_timer_thr") != nil { codexTimerThreshold = d.integer(forKey: "codex_timer_thr") }
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
        if let data = try? JSONEncoder().encode(limitSettings) { d.set(data, forKey: "limit_bar_settings") }
        d.set(extraCreditsMode.rawValue, forKey: "extra_credits_mode")
        d.set(extraCreditsThreshold, forKey: "extra_credits_thr")
        d.set(consoleMode.rawValue, forKey: "console_mode")
        d.set(consoleThreshold, forKey: "console_thr")
        d.set(consolePurchasedMode.rawValue, forKey: "console_purchased_mode")
        d.set(consolePurchasedThreshold, forKey: "console_purchased_thr")
        d.set(codexPercentMode.rawValue, forKey: "codex_percent_mode")
        d.set(codexPercentThreshold, forKey: "codex_percent_thr")
        d.set(codexTimerMode.rawValue, forKey: "codex_timer_mode")
        d.set(codexTimerThreshold, forKey: "codex_timer_thr")
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

    /// Forward the SwiftUI-measured content height to the AppDelegate so it can size
    /// the popover at the next open.
    func reportPopoverHeight(_ h: CGFloat) {
        delegate?.setPopoverHeight(h)
    }

    /// Credential keep-fresh, same idea as QobuzGame's `_refresh_token`: use the
    /// current credential to stay authenticated forever. claude.ai has no explicit
    /// refresh endpoint, but like any web app it can rotate/extend session cookies
    /// via Set-Cookie on ordinary API responses — browsers adopt them silently,
    /// which is why the browser session outlives our pasted snapshot. Extracts the
    /// rotated cookies from a 200 response (background thread, Sendable tuples).
    nonisolated static func extractCookieUpdates(_ response: URLResponse?) -> [(name: String, value: String)] {
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let fields = http.allHeaderFields as? [String: String],
              let url = http.url else { return [] }
        return HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
            .filter { !$0.value.isEmpty && ($0.expiresDate.map { $0 > Date() } ?? true) }
            .map { ($0.name, $0.value) }
    }

    /// Merge rotated cookies into the stored cookie string and re-persist to the
    /// Keychain. Conservative on purpose: only updates names ALREADY in the stored
    /// string (no new cookies appended, none deleted), so a server blip can never
    /// grow, churn, or wipe the credential — a dead sessionKey still surfaces
    /// through the normal 401/403 path.
    func absorbSetCookies(_ updates: [(name: String, value: String)]) {
        guard let merged = UsageManager.mergeCookies(updates, into: sessionCookie) else { return }
        sessionCookie = merged.cookie
        if KeychainHelper.save(sessionCookie) {
            // Names only — cookie VALUES must never reach the log.
            NSLog("🔐 Rotated cookies persisted: \(merged.changed.joined(separator: ", "))")
        } else {
            NSLog("🔐 ⚠️ Keychain save failed for rotated cookies")
        }
    }

    /// Same keep-fresh for the Console cookie (platform.claude.com rotates its own
    /// sessionKey), persisted under its own Keychain account.
    func absorbConsoleSetCookies(_ updates: [(name: String, value: String)]) {
        guard let merged = UsageManager.mergeCookies(updates, into: consoleCookie) else { return }
        consoleCookie = merged.cookie
        if KeychainHelper.save(consoleCookie, account: KeychainHelper.consoleAccount) {
            NSLog("🔐 Rotated Console cookies persisted: \(merged.changed.joined(separator: ", "))")
        } else {
            NSLog("🔐 ⚠️ Keychain save failed for rotated Console cookies")
        }
    }

    /// Pure merge step of the keep-fresh; nil when nothing changed.
    nonisolated static func mergeCookies(_ updates: [(name: String, value: String)],
                                         into cookie: String) -> (cookie: String, changed: [String])? {
        guard !updates.isEmpty, !cookie.isEmpty else { return nil }

        var order: [String] = []
        var values: [String: String] = [:]
        for part in cookie.components(separatedBy: ";") {
            let t = part.trimmingCharacters(in: .whitespaces)
            guard let eq = t.firstIndex(of: "="), eq != t.startIndex else { continue }
            let name = String(t[..<eq])
            guard values[name] == nil else { continue }   // keep first on dup
            order.append(name)
            values[name] = String(t[t.index(after: eq)...])
        }

        var changedNames: [String] = []
        for u in updates where values[u.name] != nil && values[u.name] != u.value {
            values[u.name] = u.value
            changedNames.append(u.name)
        }
        guard !changedNames.isEmpty else { return nil }

        let merged = order.compactMap { n in values[n].map { "\(n)=\($0)" } }
            .joined(separator: "; ")
        return (merged, changedNames)
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
        weeklyUsage = 0
        limits = []
        hasFetchedData = false
        errorMessage = nil
        lastNotifiedThreshold = 0
        UserDefaults.standard.set(0, forKey: "last_notified_threshold")

        // Update status bar to show 0%
        delegate?.updateStatusIcon(percentage: 0)

        NSLog("🔐 Cookie cleared, data reset")
    }

    func saveConsoleCookie(_ raw: String) {
        var clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Accept a browser "Copy as cURL" paste: pull the Cookie header out of it.
        if let r = clean.range(of: "Cookie: ", options: .caseInsensitive) {
            var v = String(clean[r.upperBound...])
            if let q = v.firstIndex(where: { $0 == "'" || $0 == "\"" }) { v = String(v[..<q]) }
            clean = v.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !clean.unicodeScalars.contains(where: { $0.value < 0x20 }) else {
            errorMessage = "Console cookie contains invalid characters"
            return
        }
        consoleCookie = clean
        consoleCreditsError = nil
        if KeychainHelper.save(clean, account: KeychainHelper.consoleAccount) {
            NSLog("🔐 Console cookie saved, length: \(clean.count)")
        } else {
            errorMessage = "Could not save Console cookie to Keychain"
        }
    }

    func clearConsoleCookie() {
        consoleCookie = ""
        consoleCreditsMinor = nil
        consoleCreditsError = nil
        KeychainHelper.delete(account: KeychainHelper.consoleAccount)
        updateStatusBar()
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
            let rotated = UsageManager.extractCookieUpdates(response)
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let account = json["account"] as? [String: Any],
                  let lastActiveOrgId = account["lastActiveOrgId"] as? String else {
                NSLog("❌ Could not parse org ID from bootstrap")
                Task { @MainActor in completion(nil) }
                return
            }
            vlog("✅ Got org ID from bootstrap: \(lastActiveOrgId)")
            Task { @MainActor in
                self?.absorbSetCookies(rotated)
                completion(lastActiveOrgId)
            }
        }.resume()
    }

    func fetchUsage() {
        // Documented invariant (see file header): callers are on the main thread.
        dispatchPrecondition(condition: .onQueue(.main))

        // The Console balance has its own cookie and Codex its own CLI login: fetch
        // both regardless of the claude.ai cookie.
        fetchConsoleCredits()
        fetchCodexUsage()
        fetchAntigravityUsage()

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
            self.fetchExtraCredits(orgId, cookie: cookie)
        }
    }

    // MARK: - Prepaid credits (fork)
    //
    // Money balances are distinct from the % quotas: the Max org has "extra usage"
    // credits (claude.ai Settings → Usage, EUR), the Console org has the API credit
    // balance (platform.claude.com Billing, USD). There is no public endpoint for
    // either: the Admin API only has usage/cost reports and is unavailable to
    // individual accounts. The Console UI reads them from this internal endpoint.
    // With the claude.ai `sessionKey` it answers for the Max org (the claude.ai
    // lastActiveOrg) and 403s for the Console org, so this call yields the Max
    // extra-usage balance. Only `sessionKey` is sent — no other cookie — and
    // Set-Cookie from this host is deliberately NOT absorbed, so a platform-side
    // rotation can never overwrite the claude.ai cookie in the Keychain.
    func fetchExtraCredits(_ orgId: String, cookie: String) {
        guard let sessionKey = UsageManager.cookieValue("sessionKey", in: cookie),
              let url = URL(string: "https://platform.claude.com/api/organizations/\(orgId)/prepaid/credits") else {
            extraCreditsError = "no sessionKey in cookie"
            return
        }
        let request = UsageManager.platformRequest(url: url, sessionKey: sessionKey)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode
            let errorDesc = error?.localizedDescription
            Task { @MainActor in
                guard let self = self else { return }
                if let errorDesc = errorDesc {
                    NSLog("❌ Credits error: \(errorDesc)")
                    self.extraCreditsError = "Network error"
                    return
                }
                guard let status = status else {
                    self.extraCreditsError = "Invalid response"
                    return
                }
                NSLog("📡 Credits status: \(status)")
                if status == 200, let data = data {
                    self.parseExtraCreditsData(data)
                    self.writeSnapshotFile()
                } else if status == 401 || status == 403 {
                    self.extraCreditsError = "Console session not accepted"
                } else {
                    self.extraCreditsError = "HTTP \(status)"
                }
                self.updateStatusBar()
            }
        }.resume()
    }

    func parseExtraCreditsData(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let amount = json["amount"] as? NSNumber else {
            extraCreditsError = "Invalid credits JSON"
            return
        }
        extraCreditsMinor = amount.intValue
        extraCreditsCurrency = (json["currency"] as? String) ?? extraCreditsCurrency
        // Everything ever granted (all tranches) is the denominator for the bar.
        extraTranches = UsageManager.parseTranches((json["tranches"] as? [[String: Any]]) ?? [])
        let granted = extraTranches.map(\.grantedMinor).reduce(0, +)
        extraCreditsGrantedMinor = granted > 0 ? granted : nil
        extraCreditsError = nil
        vlog("💳 Credits: \(amount.intValue) \(extraCreditsCurrency) remaining of \(granted)")
    }

    /// Request to platform.claude.com carrying ONLY `sessionKey` (what the Console
    /// UI sends that matters; verified 2026-10-23 — no extra headers needed).
    nonisolated static func platformRequest(url: URL, sessionKey: String) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("web_console", forHTTPHeaderField: "anthropic-client-platform")
        request.setValue("https://platform.claude.com/settings/billing", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        return request
    }

    // Console API credit balance. The Console has its own session: the browser never
    // sends claude.ai's cookie to platform.claude.com, and the two sessions can't read
    // each other's org (claude.ai's sessionKey gets 403 on the Console org and vice
    // versa — verified 2026-10-23). So this needs the pasted Console cookie, whose
    // lastActiveOrg is the Console org. Set-Cookie IS absorbed here, into the Console
    // cookie, to keep that snapshot fresh exactly like the claude.ai one.
    func fetchConsoleCredits() {
        guard !consoleCookie.isEmpty else { return }
        guard let sessionKey = UsageManager.cookieValue("sessionKey", in: consoleCookie),
              let orgId = UsageManager.cookieValue("lastActiveOrg", in: consoleCookie),
              let url = URL(string: "https://platform.claude.com/api/organizations/\(orgId)/prepaid/credits") else {
            consoleCreditsError = "Console cookie lacks sessionKey/lastActiveOrg"
            return
        }
        let request = UsageManager.platformRequest(url: url, sessionKey: sessionKey)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode
            let rotated = UsageManager.extractCookieUpdates(response)   // 200-only inside
            let errorDesc = error?.localizedDescription
            Task { @MainActor in
                guard let self = self else { return }
                if let errorDesc = errorDesc {
                    NSLog("❌ Console credits error: \(errorDesc)")
                    self.consoleCreditsError = "Network error"
                    return
                }
                guard let status = status else {
                    self.consoleCreditsError = "Invalid response"
                    return
                }
                NSLog("📡 Console credits status: \(status)")
                if status == 200, let data = data {
                    self.absorbConsoleSetCookies(rotated)
                    self.parseConsoleCreditsData(data)
                    self.writeSnapshotFile()
                } else if status == 401 || status == 403 {
                    self.consoleCreditsError = "Console cookie expired — paste a fresh one"
                } else {
                    self.consoleCreditsError = "HTTP \(status)"
                }
                self.updateStatusBar()
            }
        }.resume()
    }

    func parseConsoleCreditsData(_ data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let amount = json["amount"] as? NSNumber else {
            consoleCreditsError = "Invalid Console credits JSON"
            return
        }
        consoleCreditsMinor = amount.intValue
        consoleCurrency = (json["currency"] as? String) ?? consoleCurrency
        consolePurchasedTranches = UsageManager.parseTranches((json["tranches"] as? [[String: Any]]) ?? [])
        consolePromoTranches = UsageManager.parseTranches((json["promo_tranches"] as? [[String: Any]]) ?? [])
        consolePurchasedMinor = consolePurchasedTranches.map(\.remainingMinor).reduce(0, +)
        consolePromoMinor = consolePromoTranches.map(\.remainingMinor).reduce(0, +)
        consolePromoExpires = consolePromoTranches.compactMap(\.expiresAt).min()
        consoleCreditsError = nil
        statusMessage = nil   // clears "Console cookie saved, fetching…" like parseUsageData does
        vlog("💳 Console credits: \(amount.intValue) \(consoleCurrency) (purchased \(consolePurchasedMinor), promo \(consolePromoMinor))")
    }

    // MARK: - OpenAI Codex quota (fork)
    //
    // The `codex` CLI exposes its own account state over JSON-RPC on stdio
    // (`codex app-server`, method `account/rateLimits/read`), authenticating and
    // refreshing with its own login — AIMeter never reads ~/.codex/auth.json. One
    // short-lived process per refresh; killed after the reply or a 20 s timeout.

    /// The app may start at login with a minimal PATH, so look in the usual places.
    nonisolated static func codexExecutable() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                          "\(home)/.local/bin/codex", "\(home)/.npm-global/bin/codex"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func fetchCodexUsage() {
        guard !codexFetching else { return }
        guard let exe = UsageManager.codexExecutable() else {
            if codexWindows.isEmpty { codexError = nil }   // not installed: stay silent
            return
        }
        codexFetching = true
        DispatchQueue.global(qos: .utility).async {
            let result = UsageManager.runCodexRateLimits(executable: exe)
            Task { @MainActor in
                self.codexFetching = false
                switch result {
                case .success(let json):
                    self.parseCodexRateLimits(json)
                    self.writeSnapshotFile()
                case .failure(let message):
                    NSLog("❌ Codex usage: \(message)")
                    self.codexError = message
                }
                self.updateStatusBar()
            }
        }
    }

    enum CodexResult { case success([String: Any]); case failure(String) }

    /// Blocking JSON-RPC round trip; call off the main thread. Returns `result` of
    /// `account/rateLimits/read`.
    nonisolated static func runCodexRateLimits(executable: String) -> CodexResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = ["app-server"]
        let stdin = Pipe(), stdout = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return .failure("cannot start codex") }
        defer { if proc.isRunning { proc.terminate() } }

        let requests = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"aimeter","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read"}"#,
        ]
        // If codex died at startup the pipe has no reader: without these two guards
        // the write would SIGPIPE (or raise an ObjC exception) and take AIMeter down.
        let writer = stdin.fileHandleForWriting
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        do {
            try writer.write(contentsOf: Data((requests.joined(separator: "\n") + "\n").utf8))
        } catch {
            return .failure("codex exited at startup")
        }

        // Read newline-delimited JSON until our id 2 arrives (or timeout). The
        // handler runs on a background queue: `lock` guards buffer/answer against
        // the timeout path reading `answer` while a late callback is still running.
        let reader = stdout.fileHandleForReading
        let deadline = Date().addingTimeInterval(20)
        let lock = NSLock()
        var buffer = Data()
        var answer: CodexResult = .failure("codex timed out")
        let done = DispatchSemaphore(value: 0)
        reader.readabilityHandler = { h in
            lock.lock(); defer { lock.unlock() }
            let chunk = h.availableData
            if chunk.isEmpty {   // EOF: codex quit before answering
                answer = .failure("codex exited without answering")
                h.readabilityHandler = nil; done.signal(); return
            }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                guard let msg = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      (msg["id"] as? NSNumber)?.intValue == 2 else { continue }
                if let r = msg["result"] as? [String: Any] {
                    answer = .success(r)
                } else {
                    let e = (msg["error"] as? [String: Any])?["message"] as? String
                    answer = .failure(e ?? "codex error")
                }
                h.readabilityHandler = nil
                done.signal()
                return
            }
        }
        _ = done.wait(timeout: .now() + deadline.timeIntervalSinceNow)
        reader.readabilityHandler = nil
        lock.lock(); defer { lock.unlock() }
        return answer
    }

    func parseCodexRateLimits(_ r: [String: Any]) {
        guard let limits = r["rateLimits"] as? [String: Any] else {
            codexError = "Not logged in to Codex"
            return
        }
        func window(_ key: String) -> CodexWindow? {
            guard let w = limits[key] as? [String: Any],
                  let pct = w["usedPercent"] as? NSNumber else { return nil }
            let reset = (w["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return CodexWindow(percent: Int(pct.doubleValue.rounded()),
                               windowMinutes: (w["windowDurationMins"] as? NSNumber)?.intValue ?? 0,
                               resetsAt: reset)
        }
        codexWindows = [window("primary"), window("secondary")].compactMap { $0 }
        codexPlan = limits["planType"] as? String
        codexError = codexWindows.isEmpty ? "No Codex limits reported" : nil
        vlog("🤖 Codex: \(codexWindows.map { "\($0.percent)%/\($0.label)" }) plan \(codexPlan ?? "?")")
    }

    // MARK: - Google Antigravity quota (fork)
    //
    // `agy --print /quota --output-format json` runs the CLI's own /quota command
    // headless: it authenticates with its own Google login, spends no tokens and
    // exits in ~3 s. AIMeter never touches agy's credentials. (Idea from
    // greenoxz/agy-quota-bar. The CLI's localhost server needs a CSRF token as of
    // agy 1.5.x, so that route is closed.) Weekly pools move slowly and every run
    // leaves a small log file, so it is polled at most every 15 minutes.

    nonisolated static func agyExecutable() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/agy", "/opt/homebrew/bin/agy", "/usr/local/bin/agy"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func fetchAntigravityUsage(force: Bool = false) {
        guard !agyFetching, let exe = UsageManager.agyExecutable() else { return }
        if !force, let last = agyLastFetch, Date().timeIntervalSince(last) < 15 * 60 { return }
        agyFetching = true
        agyLastFetch = Date()
        DispatchQueue.global(qos: .utility).async {
            let output = UsageManager.runCLI(executable: exe, arguments: ["--print", "/quota", "--output-format", "json"], timeout: 30)
            Task { @MainActor in
                self.agyFetching = false
                self.parseAntigravityQuota(output)
                self.writeSnapshotFile()
                self.updateStatusBar()
            }
        }
    }

    /// Run a CLI to completion and return its stdout; nil on launch failure or timeout.
    nonisolated static func runCLI(executable: String, arguments: [String], timeout: TimeInterval) -> Data? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        let stdout = Pipe()
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = stdout
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }

        // Drain stdout on another queue so a chatty child can't block on a full pipe.
        let lock = NSLock()
        var collected: Data?
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); collected = data; lock.unlock()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            proc.terminate()
            return nil
        }
        lock.lock(); defer { lock.unlock() }
        return collected
    }

    func parseAntigravityQuota(_ output: Data?) {
        guard let output = output else {
            agyError = "agy did not answer"
            return
        }
        guard let json = try? JSONSerialization.jsonObject(with: output) as? [String: Any],
              let data = (json["command"] as? [String: Any])?["data"] as? [String: Any],
              let groups = data["groups"] as? [[String: Any]] else {
            // Not signed in, or a CLI version without the JSON /quota command.
            let text = String(data: output, encoding: .utf8) ?? ""
            agyError = text.lowercased().contains("sign") ? "Not signed in to Antigravity" : "Unexpected agy output"
            return
        }
        var parsed: [AgyQuota] = []
        for g in groups {
            let groupName = (g["name"] as? String) ?? "Models"
            for b in (g["buckets"] as? [[String: Any]]) ?? [] {
                // No remaining_fraction = unknown: skip rather than guess 0% or 100%.
                guard let remaining = (b["remaining_fraction"] as? NSNumber)?.doubleValue else { continue }
                let bucketId = (b["id"] as? String) ?? "\(groupName)-\(b["window"] as? String ?? "")"
                parsed.append(AgyQuota(
                    id: "agy:\(bucketId)", group: groupName,
                    window: (b["window"] as? String) ?? "",
                    percent: Int(((1 - min(max(remaining, 0), 1)) * 100).rounded()),
                    resetsAt: (b["reset_time"] as? String).flatMap(UsageManager.parseISODate)))
            }
        }
        agyQuotas = parsed
        agyError = parsed.isEmpty ? "No Antigravity quota reported" : nil
        vlog("🪐 Antigravity: \(parsed.map { "\($0.group) \($0.percent)%" })")
    }

    /// Tranche list as the Console sends it (`tranches` / `promo_tranches`).
    nonisolated static func parseTranches(_ raw: [[String: Any]]) -> [CreditTranche] {
        raw.compactMap { t in
            guard let remaining = (t["remaining_amount_minor_units"] as? NSNumber)?.intValue else { return nil }
            let scopeKind = (t["scope"] as? [String: Any])?["kind"] as? String
            return CreditTranche(
                name: (t["name"] as? String) ?? (t["program_id"] as? String) ?? "credit",
                remainingMinor: remaining,
                grantedMinor: (t["granted_amount_minor_units"] as? NSNumber)?.intValue ?? remaining,
                expiresAt: (t["expires_at"] as? String).flatMap(UsageManager.parseISODate),
                scope: (scopeKind == nil || scopeKind == "unscoped") ? nil : scopeKind)
        }
    }

    // MARK: - Export for Claude Code (fork)

    /// Plain Markdown snapshot of everything the app knows, written for an LLM
    /// reader: dot-decimal amounts with explicit currency, ISO dates, and the Console
    /// credits tranche by tranche so a session can see exactly how much promo is left.
    func exportText() -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = .current
        func money(_ minor: Int, _ cur: String) -> String { String(format: "%.2f %@", Double(minor) / 100.0, cur) }
        func when(_ d: Date?) -> String {
            guard let d = d else { return "unknown" }
            return iso.string(from: d) + (UsageManager.countdown(to: d).map { " (in \($0))" } ?? "")
        }
        func trancheLines(_ ts: [CreditTranche], _ cur: String) -> [String] {
            ts.map { t in
                var line = "  - \(t.name): \(money(t.remainingMinor, cur)) remaining of \(money(t.grantedMinor, cur))"
                line += t.expiresAt.map { ", expires \(iso.string(from: $0))" } ?? ", no expiry"
                if let s = t.scope { line += ", scope: \(s)" }
                return line
            }
        }

        var out: [String] = []
        out.append("# AIMeter export — \(iso.string(from: Date()))")
        out.append("")
        out.append("## Claude Max plan quotas (claude.ai, percent of window used)")
        // Contract with the reader (a Claude Code session): one section per vendor,
        // vendor name first in the title; every quota line has the same shape
        // "- <name> (<duration>): <N>% used, resets <ISO>"; a missing value stays on
        // its line as "unknown" instead of the line disappearing.
        if limits.isEmpty {
            out.append("- Weekly, all models (7 d): unknown% used, resets unknown")
        }
        for l in limits {
            out.append("- \(l.snapshotName) (\(l.duration ?? "unknown")): \(l.percent)% used, resets \(when(l.resetsAt))")
        }
        out.append("")
        out.append("## Claude Max extra-usage credits (claude.ai → Settings → Usage; used when the plan quota is exhausted)")
        if let m = extraCreditsMinor {
            let granted = extraCreditsGrantedMinor.map { " of \(money($0, extraCreditsCurrency)) granted" } ?? ""
            out.append("- Remaining: \(money(m, extraCreditsCurrency))\(granted)")
            out.append(contentsOf: trancheLines(extraTranches, extraCreditsCurrency))
        } else {
            out.append("- Remaining: unknown\(extraCreditsError.map { " (\($0))" } ?? "")")
        }
        out.append("")
        out.append("## Claude Console API credits (platform.claude.com → Billing; spent by API keys, Claude Code on API billing, Agent SDK, Playground)")
        if let total = consoleCreditsMinor {
            out.append("- Total remaining: \(money(total, consoleCurrency))")
            out.append("- Purchased credits remaining: \(money(consolePurchasedMinor, consoleCurrency))")
            out.append(contentsOf: trancheLines(consolePurchasedTranches, consoleCurrency))
            out.append("- Promotional credits remaining: \(money(consolePromoMinor, consoleCurrency))")
            out.append(contentsOf: trancheLines(consolePromoTranches, consoleCurrency))
            if consolePromoTranches.isEmpty { out.append("  - none") }
        } else {
            let why = consoleCreditsError.map { " (\($0))" } ?? ""
            out.append("- Total remaining: unknown\(why)")
            out.append("- Purchased credits remaining: unknown")
            out.append("- Promotional credits remaining: unknown")
        }
        out.append("")
        out.append("## OpenAI Codex (local codex CLI login, percent of window used)")
        out.append("- Plan: \(codexPlan ?? "unknown")")
        if codexWindows.isEmpty {
            let why = codexError ?? (UsageManager.codexExecutable() == nil ? "codex CLI not installed" : "not fetched yet")
            out.append("- Codex (unknown): unknown% used, resets unknown (\(why))")
        } else {
            for w in codexWindows {
                out.append("- Codex, \(w.quotaName) (\(w.shortDuration)): \(w.percent)% used, resets \(when(w.resetsAt))")
            }
        }
        out.append("")
        out.append("## Google Antigravity (local agy CLI login, percent of window used)")
        out.append("- Plan: unknown")
        if agyQuotas.isEmpty {
            let why = agyError ?? (UsageManager.agyExecutable() == nil ? "agy CLI not installed" : "not fetched yet")
            out.append("- Antigravity (unknown): unknown% used, resets unknown (\(why))")
        }
        for q in agyQuotas {
            out.append("- Antigravity, \(q.group) \(q.window) (\(q.duration ?? "unknown")): \(q.percent)% used, resets \(when(q.resetsAt))")
        }
        out.append("")
        out.append("Data last fetched: \(iso.string(from: lastUpdated)). A fresh copy of this snapshot is rewritten after every refresh at \(snapshotURL.path).")
        return out.joined(separator: "\n")
    }

    /// Snapshot file for other tools (e.g. a Claude Code session doing `cat` on it):
    /// rewritten after every successful fetch, so it is never older than the refresh
    /// interval. Atomic write. Folder is user-selectable (UserDefaults `snapshot_dir`),
    /// default Application Support/AIMeter.
    static let snapshotFileName = "aimeter-snapshot.md"
    static let defaultSnapshotDirectory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("AIMeter")
    var snapshotURL: URL {
        let dir = snapshotDirectory.isEmpty ? UsageManager.defaultSnapshotDirectory : URL(fileURLWithPath: snapshotDirectory)
        return dir.appendingPathComponent(UsageManager.snapshotFileName)
    }

    func setSnapshotDirectory(_ path: String) {
        snapshotDirectory = path
        UserDefaults.standard.set(path, forKey: "snapshot_dir")
        writeSnapshotFile()   // appear in the new place right away
    }

    /// Finder folder picker for the snapshot location.
    func chooseSnapshotDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use this folder"
        panel.message = "AIMeter will rewrite \(UsageManager.snapshotFileName) here after every refresh."
        panel.directoryURL = snapshotURL.deletingLastPathComponent()
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            setSnapshotDirectory(url.path)
        }
    }

    func writeSnapshotFile() {
        let url = snapshotURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try exportText().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSLog("📝 Snapshot write failed: \(error.localizedDescription)")
        }
    }

    /// Put the export on the general pasteboard and confirm in the popover.
    func copyExportToClipboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(exportText(), forType: .string)
        statusMessage = "Copied to clipboard — paste it into Claude Code"
    }

    /// Value of one named cookie inside a raw `Cookie:` header string.
    nonisolated static func cookieValue(_ name: String, in cookie: String) -> String? {
        for part in cookie.components(separatedBy: ";") {
            let t = part.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(name + "=") { return String(t.dropFirst(name.count + 1)) }
        }
        return nil
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
            let rotated = UsageManager.extractCookieUpdates(response)   // 200-only inside
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
                    self.absorbSetCookies(rotated)
                    self.parseUsageData(data)
                    self.writeSnapshotFile()
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

    /// Parse an ISO8601 timestamp, trying fractional seconds first with a
    /// no-fractional fallback (mirrors StatusManager.parse), so both shapes succeed.
    static func parseISODate(_ s: String) -> Date? {
        let primary = ISO8601DateFormatter()
        primary.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = primary.date(from: s) { return d }
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: s)
    }

    /// Parse one legacy usage window (five_hour / seven_day / seven_day_sonnet):
    /// rounded utilization percent + reset Date. Returns nil if the window key is
    /// absent or null. nil resetsAt means the field was missing/unparseable — the
    /// caller keeps the previous value rather than clobbering it.
    private func parseWindow(_ key: String, in json: [String: Any]) -> (usage: Int, resetsAt: Date?)? {
        guard let dict = json[key] as? [String: Any] else { return nil }
        // Round (not floor) so display and the ≥90% / >75% thresholds stay consistent.
        let usage = (dict["utilization"] as? Double).map { Int($0.rounded()) } ?? 0
        var resetsAt: Date?
        if let s = dict["resets_at"] as? String {
            resetsAt = UsageManager.parseISODate(s)
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

            // `limits` array (June 2026): the source of truth. Every entry becomes a
            // UsageLimit, unknown kinds included.
            var parsed: [UsageLimit] = []
            if let entries = json["limits"] as? [[String: Any]], !entries.isEmpty {
                for entry in entries {
                    guard let kind = entry["kind"] as? String else { continue }
                    let model = ((entry["scope"] as? [String: Any])?["model"]) as? [String: Any]
                    parsed.append(UsageLimit.make(
                        kind: kind,
                        scope: model?["display_name"] as? String,
                        group: entry["group"] as? String,
                        percent: (entry["percent"] as? NSNumber).map { Int($0.doubleValue.rounded()) } ?? 0,
                        resetsAt: (entry["resets_at"] as? String).flatMap(UsageManager.parseISODate)))
                }
            } else {
                // Pre-June-2026 schema: fixed top-level windows.
                for (key, kind, scope) in [("five_hour", "session", nil), ("seven_day", "weekly_all", nil),
                                           ("seven_day_sonnet", "weekly_scoped", "Sonnet")] as [(String, String, String?)] {
                    if let w = parseWindow(key, in: json) {
                        parsed.append(UsageLimit.make(kind: kind, scope: scope, group: nil,
                                                      percent: w.usage, resetsAt: w.resetsAt))
                    }
                }
            }
            // Ids must be unique (they key the settings and the SwiftUI lists).
            var seen = Set<String>()
            limits = parsed.filter { seen.insert($0.id).inserted }
            weeklyUsage = (limits.first { $0.kind == "weekly_all" } ?? limits.first)?.percent ?? 0

            // One-time hand-over of the old per-model options to the first scoped limit.
            if let old = limitSettings["legacy_scoped"],
               let scoped = limits.first(where: { $0.kind == "weekly_scoped" }) {
                if limitSettings[scoped.id] == nil { limitSettings[scoped.id] = old }
                limitSettings["legacy_scoped"] = nil
                saveSettings()
            }

            NSLog("✅ Parsed: \(limits.map { "\($0.title) \($0.percent)%" }.joined(separator: ", "))")

            lastUpdated = Date()
            lastSuccessfulUpdate = Date()
            errorMessage = nil
            statusMessage = nil
            hasFetchedData = true
            cookieInvalid = false

        } catch {
            NSLog("❌ Parse error: \(error.localizedDescription)")
            errorMessage = "Parse error"
        }
    }

    func updateStatusBar() {
        // The 5-hour session window is gone from the API (Nov 2026): the ring and the
        // threshold notifications follow the weekly window. Already a percent (0–100).
        let sessionPercent = weeklyUsage

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

        // Notify only the HIGHEST newly-crossed threshold, once — a jump from
        // e.g. 20%→80% fires a single 75% alert, not a 25/50/75 burst.
        if let crossed = thresholds.filter({ percentage >= $0 && lastNotifiedThreshold < $0 }).max() {
            NSLog("📬 Sending notification for \(crossed)% threshold")
            sendNotification(percentage: percentage, threshold: crossed)
            lastNotifiedThreshold = crossed
            // Persist the threshold
            UserDefaults.standard.set(lastNotifiedThreshold, forKey: "last_notified_threshold")
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
                      body: "You've reached \(percentage)% of your weekly limit")
        NSLog("📬 Sent notification for \(threshold)% threshold")
    }

    func sendTestNotification() {
        NSLog("🔔 Test notification button clicked")
        Notifier.post(title: "AIMeter — usage alert",
                      body: "Test notification — You've reached 75% of your weekly limit")
        NSLog("📬 Test notification sent successfully")
    }

    /// Public entry for the manual "Refresh now" button.
    func refreshNow() {
        fetchUsage()
        fetchAntigravityUsage(force: true)
    }

    /// Percent (0–100) → clamped 0–1 fraction for ProgressView (the API can
    /// report slightly over 100 at the cap edge; >1 trips a runtime warning).
    static func fraction(_ percent: Int) -> Double {
        min(max(Double(percent) / 100.0, 0), 1)
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
    @State private var consoleCookieInput: String = ""
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
            // Width is fixed; the height is set by the AppDelegate on the popover's
            // contentSize before each show. The ScrollView fills it and scrolls when
            // the content (e.g. the Settings panel) is taller.
            .frame(width: AppDelegate.popoverWidth)
            .onPreferenceChange(ContentHeightKey.self) { value in
                guard value > 0 else { return }
                // Remembered for the NEXT open; we don't resize while shown.
                usageManager.reportPopoverHeight(value)
            }
            .onAppear {
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
                // One row per limit the API reports (names come from the API).
                ForEach(usageManager.limits) { l in
                    usageRow(title: l.rowTitle,
                             percentage: UsageManager.fraction(l.percent),
                             resetDate: l.resetsAt,
                             countdown: UsageManager.countdown(to: l.resetsAt),
                             color: Palette.limitColors(l.kind).popover,
                             includeDate: true)
                }

                // API prepaid credit balance from the Console (fork).
                if let minor = usageManager.extraCreditsMinor {
                    extraCreditsRow(remainingMinor: minor,
                               grantedMinor: usageManager.extraCreditsGrantedMinor,
                               currency: usageManager.extraCreditsCurrency)
                } else if let err = usageManager.extraCreditsError {
                    Text("Extra usage credits: \(err)")
                        .font(.caption).foregroundColor(.secondary)
                }
            }

            // Console API credit balance (fork): separate cookie, shown even when the
            // claude.ai one is missing.
            if let total = usageManager.consoleCreditsMinor {
                consoleCreditsRow(totalMinor: total,
                                  purchasedMinor: usageManager.consolePurchasedMinor,
                                  promoMinor: usageManager.consolePromoMinor,
                                  promoExpires: usageManager.consolePromoExpires,
                                  currency: usageManager.consoleCurrency)
            } else if let err = usageManager.consoleCreditsError {
                Text("API credits (Console): \(err)")
                    .font(.caption).foregroundColor(.secondary)
            }

            // OpenAI Codex quota (fork), from the local codex CLI login.
            ForEach(Array(usageManager.codexWindows.enumerated()), id: \.offset) { _, w in
                usageRow(title: "Codex \(usageManager.codexPlan.map { "\($0) " } ?? "")(\(w.label))",
                         percentage: UsageManager.fraction(w.percent),
                         resetDate: w.resetsAt,
                         countdown: UsageManager.countdown(to: w.resetsAt),
                         color: Palette.codex,
                         includeDate: true)
            }
            if usageManager.codexWindows.isEmpty, let err = usageManager.codexError {
                Text("Codex: \(err)")
                    .font(.caption).foregroundColor(.secondary)
            }

            // Google Antigravity pools (fork), from the local agy CLI login.
            ForEach(usageManager.agyQuotas) { q in
                usageRow(title: q.rowTitle,
                         percentage: UsageManager.fraction(q.percent),
                         resetDate: q.resetsAt,
                         countdown: UsageManager.countdown(to: q.resetsAt),
                         color: Palette.agy,
                         includeDate: true)
            }
            if usageManager.agyQuotas.isEmpty, let err = usageManager.agyError {
                Text("Antigravity: \(err)")
                    .font(.caption).foregroundColor(.secondary)
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
                // Export (fork): Markdown snapshot for an LLM reader (Claude Code).
                Button("Copy for Claude Code") {
                    usageManager.copyExportToClipboard()
                }
                .buttonStyle(.borderless)
                .font(.caption)
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

                // Console cookie (fork): second, independent session for the API
                // credit balance on platform.claude.com.
                VStack(alignment: .leading, spacing: 8) {
                    Text("Console cookie (API credit balance):")
                        .font(.caption)
                        .fontWeight(.semibold)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("1. Go to platform.claude.com > Settings > Billing")
                        Text("2. Safari: Develop > Show Web Inspector > Network")
                        Text("3. Reload page, find the 'credits' request")
                        Text("4. Right-click it > Copy as cURL, paste below\n   (or copy its 'Cookie' request header)")
                    }
                    .font(.caption2)
                    .foregroundColor(.secondary)

                    if !usageManager.consoleCookieHint.isEmpty {
                        Text("Current: \(usageManager.consoleCookieHint)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    PasteableTextField(text: $consoleCookieInput, placeholder: "Paste Console cookie (or cURL) here...")
                        .frame(height: 60)
                        .cornerRadius(4)

                    HStack(spacing: 8) {
                        Button("Save Console Cookie & Fetch") {
                            if consoleCookieInput.isEmpty {
                                usageManager.errorMessage = "Console cookie field is empty!"
                            } else {
                                usageManager.saveConsoleCookie(consoleCookieInput)
                                usageManager.statusMessage = "Console cookie saved, fetching…"
                                usageManager.fetchConsoleCredits()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        if !usageManager.consoleCookieHint.isEmpty {
                            Button("Clear") {
                                consoleCookieInput = ""
                                usageManager.clearConsoleCookie()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
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
                    // Snapshot file (fork): same text as "Copy for Claude Code", rewritten
                    // after every refresh, for tools that read it on their own. Folder is
                    // user-selectable so it can live inside a project Claude Code works in.
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Snapshot file (rewritten at every refresh):")
                            .font(.caption2).foregroundColor(.secondary)
                        Text(usageManager.snapshotURL.path)
                            .font(.caption2).foregroundColor(.primary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Button("Choose folder…") { usageManager.chooseSnapshotDirectory() }
                                .buttonStyle(.bordered).controlSize(.small)
                            if !usageManager.snapshotDirectory.isEmpty {
                                Button("Default") { usageManager.setSnapshotDirectory("") }
                                    .buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                    }

                    Divider()

                    // Menu-bar display (fork): each extra value can be Off / Always /
                    // When (conditional on a %-or-time threshold).
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Show in menu bar")
                            .font(.caption).fontWeight(.semibold)
                        // Two options per limit the API reports; new limits start Off.
                        ForEach(usageManager.limits) { l in
                            let color = Palette.limitColors(l.kind).popover
                            barRow("\(l.title) usage %", color, isPercent: true,
                                   modeGet: { usageManager.barSettings(for: l.id).percentMode },
                                   modeSet: { v in usageManager.updateBarSettings(for: l.id) { $0.percentMode = v } },
                                   thrGet: { usageManager.barSettings(for: l.id).percentThreshold },
                                   thrSet: { v in usageManager.updateBarSettings(for: l.id) { $0.percentThreshold = v } })
                            barRow("\(l.title) reset timer", color, isPercent: false,
                                   modeGet: { usageManager.barSettings(for: l.id).timerMode },
                                   modeSet: { v in usageManager.updateBarSettings(for: l.id) { $0.timerMode = v } },
                                   thrGet: { usageManager.barSettings(for: l.id).timerThreshold },
                                   thrSet: { v in usageManager.updateBarSettings(for: l.id) { $0.timerThreshold = v } })
                        }
                        barRow("Extra usage credits (Max)", Palette.credits, isPercent: false, moneyCode: usageManager.extraCreditsCurrency,
                               modeGet: { usageManager.extraCreditsMode }, modeSet: { usageManager.extraCreditsMode = $0 },
                               thrGet: { usageManager.extraCreditsThreshold }, thrSet: { usageManager.extraCreditsThreshold = $0 })
                        barRow("API credits (Console)", Palette.console, isPercent: false, moneyCode: usageManager.consoleCurrency,
                               modeGet: { usageManager.consolePurchasedMode }, modeSet: { usageManager.consolePurchasedMode = $0 },
                               thrGet: { usageManager.consolePurchasedThreshold }, thrSet: { usageManager.consolePurchasedThreshold = $0 })
                        barRow("API bonus credits (Console)", Palette.console, isPercent: false, moneyCode: usageManager.consoleCurrency,
                               modeGet: { usageManager.consoleMode }, modeSet: { usageManager.consoleMode = $0 },
                               thrGet: { usageManager.consoleThreshold }, thrSet: { usageManager.consoleThreshold = $0 })
                        ForEach(usageManager.agyQuotas) { q in
                            barRow("Antigravity \(q.group) %", Palette.agy, isPercent: true,
                                   modeGet: { usageManager.barSettings(for: q.id).percentMode },
                                   modeSet: { v in usageManager.updateBarSettings(for: q.id) { $0.percentMode = v } },
                                   thrGet: { usageManager.barSettings(for: q.id).percentThreshold },
                                   thrSet: { v in usageManager.updateBarSettings(for: q.id) { $0.percentThreshold = v } })
                            barRow("Antigravity \(q.group) reset timer", Palette.agy, isPercent: false,
                                   modeGet: { usageManager.barSettings(for: q.id).timerMode },
                                   modeSet: { v in usageManager.updateBarSettings(for: q.id) { $0.timerMode = v } },
                                   thrGet: { usageManager.barSettings(for: q.id).timerThreshold },
                                   thrSet: { v in usageManager.updateBarSettings(for: q.id) { $0.timerThreshold = v } })
                        }
                        barRow("Codex usage %", Palette.codex, isPercent: true,
                               modeGet: { usageManager.codexPercentMode }, modeSet: { usageManager.codexPercentMode = $0 },
                               thrGet: { usageManager.codexPercentThreshold }, thrSet: { usageManager.codexPercentThreshold = $0 })
                        barRow("Codex reset timer", Palette.codex, isPercent: false,
                               modeGet: { usageManager.codexTimerMode }, modeSet: { usageManager.codexTimerMode = $0 },
                               thrGet: { usageManager.codexTimerThreshold }, thrSet: { usageManager.codexTimerThreshold = $0 })
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
                                Text("Get alerts at 25%, 50%, 75%,\nand 90% weekly usage")
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

    /// Prepaid API credit balance (Console): same layout as usageRow, but the bar
    /// is the share of granted credits already spent and the labels are money.
    private func extraCreditsRow(remainingMinor: Int, grantedMinor: Int?, currency: String) -> some View {
        let remaining = UsageManager.formatMoney(minor: remainingMinor, currency: currency)
        let used: Double? = grantedMinor.map { g in min(max(1 - Double(remainingMinor) / Double(g), 0), 1) }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Extra usage credits (Max)").font(.subheadline)
                Spacer()
                Text("\(remaining) left").font(.caption).foregroundColor(.secondary)
            }
            if let used = used, let g = grantedMinor {
                ProgressView(value: used).tint(Palette.credits)
                Text("\(Int(used * 100))% of \(UsageManager.formatMoney(minor: g, currency: currency)) used")
                    .font(.caption).foregroundColor(Palette.credits)
            }
        }
    }

    /// Console API credit balance: purchased + promotional tranches. No bar — the
    /// promo part expires on its own schedule, so a single "% used" would mislead.
    private func consoleCreditsRow(totalMinor: Int, purchasedMinor: Int, promoMinor: Int,
                                   promoExpires: Date?, currency: String) -> some View {
        let money = { (m: Int) in UsageManager.formatMoney(minor: m, currency: currency) }
        // Two lines, one per kind of money: purchased credits, then the promotional
        // bonus (spent first, expires). Total in the caption.
        let expiry = promoExpires.map { " · bonus expires \(formatShortDate($0))" } ?? ""
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("API credits (Console)").font(.subheadline)
                Spacer()
                Text("\(money(purchasedMinor)) left").font(.caption).foregroundColor(.secondary)
            }
            HStack {
                Text("API bonus credits (Console)").font(.subheadline)
                Spacer()
                Text("\(money(promoMinor)) left").font(.caption).foregroundColor(.secondary)
            }
            Text("Total \(money(totalMinor))\(expiry)")
                .font(.caption).foregroundColor(Palette.console)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    func formatShortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date)
    }

    /// One configurable menu-bar value: label + mode picker (Off/Always/When) and,
    /// when "When", a threshold stepper (% for percentages, minutes for timers).
    @ViewBuilder
    private func barRow(_ label: String, _ color: Color, isPercent: Bool, moneyCode: String? = nil,
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
                if let code = moneyCode {
                    Stepper("show if balance ≤ \(thrGet()) \(code)", value: thr, in: 0...1000, step: 5)
                        .font(.caption2).foregroundColor(.secondary)
                } else if isPercent {
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
