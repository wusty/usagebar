import AppKit
import UserNotifications

private enum StatusIcon {
    /// The gauge glyph, filled from the bottom up to `percent`. Pass 0 for
    /// "outline only" — used for loading / signed-out states where we don't
    /// yet have a number to show.
    case gauge(Int)
    /// Refresh failed; replaces the gauge so the error is unmistakable.
    case error
}

/// User-controllable status bar text mode.
private enum DisplayMode: Int {
    case always = 0       // text always shown when there's a percent
    case smartHide = 1    // text shown only above the smartHide threshold
    case iconOnly = 2     // text never shown (settled states); icon does the talking

    var label: String {
        switch self {
        case .always:    return "Always show percent"
        case .smartHide: return "Show percent above 50% only"
        case .iconOnly:  return "Icon only"
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private var scraper: UsageScraper!
    private var refreshTimer: Timer?
    private var lastData: UsageData?
    private var lastError: String?
    private var lastRefreshAt: Date?

    private let refreshInterval: TimeInterval = 5 * 60
    private let notificationThresholds = [50, 75, 90]
    private let lastNotifiedKey = "lastNotifiedThreshold"
    private let displayModeKey = "displayMode"
    private let smartHideThreshold = 50

    private var displayMode: DisplayMode {
        let raw = UserDefaults.standard.integer(forKey: displayModeKey)
        return DisplayMode(rawValue: raw) ?? .always
    }

    // Spinner — fires while a refresh is in flight. 24 frames over a full
    // rotation, swapped at 24 FPS = 1 visible revolution per second.
    private var spinnerTimer: Timer?
    private var spinnerFrameIndex = 0
    private static let spinnerFrameCount = 24
    private static let spinnerFPS: Double = 24

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading

        scraper = UsageScraper(
            onRefreshStart: { [weak self] in self?.startSpinner() },
            onUpdate: { [weak self] result in self?.handle(result) }
        )

        setupNotifications()
        rebuildMenu()
        scraper.refresh()  // triggers onRefreshStart → spinner spins immediately

        refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.scraper.refresh()
        }
    }

    // MARK: - Scrape result

    private func handle(_ result: ScrapeResult) {
        stopSpinner()
        lastRefreshAt = Date()
        switch result {
        case .success(let data):
            lastData = data
            lastError = nil
            setStatus(
                title: titleForCurrentMode(data: data),
                icon: .gauge(data.primaryPercentage ?? 0)
            )
            scraper.hideLoginWindow()
            checkThresholds(data: data)
        case .needsLogin:
            lastData = nil
            lastError = "Not signed in"
            setStatus(title: "Sign in", icon: .gauge(0))
        case .error(let msg):
            lastError = msg
            if let data = lastData {
                // Keep showing the last good percent (respecting display mode),
                // but swap to the error icon so the user notices.
                setStatus(title: titleForCurrentMode(data: data), icon: .error)
            } else {
                setStatus(title: "", icon: .error)
            }
        }
        rebuildMenu()
    }

    // MARK: - Status bar appearance

    private func setStatus(title: String, icon: StatusIcon) {
        guard let button = statusItem.button else { return }
        button.title = title
        // Icon leads the text — the gauge serves as the app's badge in the
        // menu bar, then the number reads after it.
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading

        switch icon {
        case .gauge(let percent):
            button.image = makeGaugeIcon(percent: percent)
        case .error:
            let img = NSImage(
                systemSymbolName: "exclamationmark.triangle.fill",
                accessibilityDescription: "Error"
            )
            img?.isTemplate = true
            button.image = img
        }
    }

    /// The gauge glyph SVG, loaded once from the .app bundle.
    /// NSImage on macOS 13+ renders SVG natively; we then composite it ourselves
    /// to get the bottom-up fill-gauge effect.
    private lazy var gaugeSvg: NSImage? = {
        guard let url = Bundle.main.url(forResource: "gauge", withExtension: "svg") else {
            NSLog("Could not find Resources/gauge.svg in the app bundle")
            return nil
        }
        guard let image = NSImage(contentsOf: url) else {
            NSLog("Failed to load \(url.path) as NSImage")
            return nil
        }
        return image
    }()

    /// Status-bar title for the current display mode. The error and
    /// not-signed-in states ignore the mode and use their own strings;
    /// this only applies to the happy path (we have usage data).
    private func titleForCurrentMode(data: UsageData) -> String {
        guard let percent = data.primaryPercentage else { return "" }
        switch displayMode {
        case .always:
            return "\(percent)%"
        case .smartHide:
            return percent >= smartHideThreshold ? "\(percent)%" : ""
        case .iconOnly:
            return ""
        }
    }

    @objc private func selectDisplayMode(_ sender: NSMenuItem) {
        guard let mode = DisplayMode(rawValue: sender.tag) else { return }
        UserDefaults.standard.set(mode.rawValue, forKey: displayModeKey)
        // Re-render immediately with the new mode.
        if let data = lastData {
            setStatus(
                title: titleForCurrentMode(data: data),
                icon: .gauge(data.primaryPercentage ?? 0)
            )
        }
        rebuildMenu()
    }

    // Icon canvas geometry. The icon's actual content occupies 14×14pt in the
    // leading portion of a slightly wider canvas; the trailing transparent
    // strip acts as extra space between the icon and the percent text in the
    // status bar, since AppKit's built-in image/title gap is too tight.
    private static let iconContentSize: CGFloat = 14
    private static let iconTrailingPad: CGFloat = 4
    private static let iconCanvasSize = NSSize(
        width: iconContentSize + iconTrailingPad,
        height: iconContentSize
    )
    private static let iconContentRect = NSRect(
        x: 0, y: 0,
        width: iconContentSize,
        height: iconContentSize
    )

    /// The gauge glyph: a faint render of the silhouette with a solid
    /// render on top, clipped to the bottom `percent` of the icon's height.
    /// At 0 the icon is a ghosted outline; at 100 it's fully solid.
    /// Returned as a template image so the menu bar tints it with the system
    /// label color, respecting light/dark appearance.
    private func makeGaugeIcon(percent: Int) -> NSImage {
        let svg = gaugeSvg

        let image = NSImage(size: Self.iconCanvasSize, flipped: false) { _ in
            guard let svg = svg else { return true }
            let content = Self.iconContentRect

            // Ghosted base layer for the "empty" portion.
            svg.draw(in: content, from: .zero, operation: .sourceOver, fraction: 0.25)

            // Solid fill, clipped to a bottom-up rectangle proportional to the
            // current percent — water-level gauge metaphor.
            let clamped = min(max(percent, 0), 100)
            if clamped > 0 {
                NSGraphicsContext.saveGraphicsState()
                let fillHeight = content.height * CGFloat(clamped) / 100
                let clip = NSRect(
                    x: content.minX, y: content.minY,
                    width: content.width, height: fillHeight
                )
                NSBezierPath(rect: clip).addClip()
                svg.draw(in: content, from: .zero, operation: .sourceOver, fraction: 1.0)
                NSGraphicsContext.restoreGraphicsState()
            }

            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - Spinner

    /// Pre-rendered rotation frames for the loading spinner. Built lazily on
    /// first use; trivially cheap (24 small bitmaps, ~few KB each). The
    /// template flag is set per-frame so AppKit re-tints each one at draw
    /// time, which means dark/light appearance changes mid-spin are picked
    /// up automatically without rebuilding the cache.
    private lazy var spinnerFrames: [NSImage] = {
        (0..<Self.spinnerFrameCount).map { i in
            let angle = CGFloat(i) * 360 / CGFloat(Self.spinnerFrameCount)
            return makeSpinnerFrame(angle: angle)
        }
    }()

    private func startSpinner() {
        // Idempotent — replacing an already-running spinner just restarts it.
        stopSpinner()
        spinnerFrameIndex = 0
        statusItem.button?.image = spinnerFrames[0]
        spinnerTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0 / Self.spinnerFPS,
            repeats: true
        ) { [weak self] _ in
            guard let self = self else { return }
            self.spinnerFrameIndex = (self.spinnerFrameIndex + 1) % Self.spinnerFrameCount
            self.statusItem.button?.image = self.spinnerFrames[self.spinnerFrameIndex]
        }
    }

    private func stopSpinner() {
        spinnerTimer?.invalidate()
        spinnerTimer = nil
    }

    /// One frame of the spinner: the gauge glyph rotated by `angle` degrees
    /// around the icon's center. Template image so the menu bar tints it.
    /// Uses the same padded canvas as the gauge so the text-spacing stays
    /// consistent whether the icon is spinning or static.
    private func makeSpinnerFrame(angle: CGFloat) -> NSImage {
        let svg = gaugeSvg

        let image = NSImage(size: Self.iconCanvasSize, flipped: false) { _ in
            guard let svg = svg else { return true }
            let content = Self.iconContentRect

            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(by: content.midX, yBy: content.midY)
            transform.rotate(byDegrees: angle)
            transform.translateX(by: -content.midX, yBy: -content.midY)
            transform.concat()

            svg.draw(in: content, from: .zero, operation: .sourceOver, fraction: 1.0)

            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - Notifications

    private func setupNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                NSLog("Notification auth error: \(error.localizedDescription)")
            }
            NSLog("Notification authorization granted: \(granted)")
        }
    }

    /// Show banners even when the app is "frontmost" (menu bar apps are always
    /// nominally active, so without this, notifications get swallowed).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    private func checkThresholds(data: UsageData) {
        guard let percent = data.primaryPercentage else { return }
        let lastNotified = UserDefaults.standard.integer(forKey: lastNotifiedKey)

        let decision = ThresholdEvaluator.evaluate(
            percent: percent,
            lastNotified: lastNotified,
            thresholds: notificationThresholds
        )

        if decision.newLastNotified != lastNotified {
            UserDefaults.standard.set(decision.newLastNotified, forKey: lastNotifiedKey)
        }
        if let threshold = decision.notify {
            postThresholdNotification(threshold: threshold, data: data)
        }
    }

    private func postThresholdNotification(threshold: Int, data: UsageData) {
        let content = UNMutableNotificationContent()
        content.title = "Usage at \(threshold)%"

        var bodyParts: [String] = []
        if let section = data.sections.first {
            if let spent = section.dollarSpent, let limit = section.dollarLimit {
                bodyParts.append("\(spent) of \(limit)")
            } else if let spent = section.dollarSpent {
                bodyParts.append(spent)
            }
            if let resets = section.resets {
                bodyParts.append("Resets \(resets)")
            }
        }
        content.body = bodyParts.isEmpty ? "You've used \(data.primaryPercentage ?? threshold)%" : bodyParts.joined(separator: " · ")
        content.sound = .default

        // Reusing identifiers per threshold so repeated runs don't pile up
        // pending entries in Notification Center.
        let request = UNNotificationRequest(
            identifier: "usage-threshold-\(threshold)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                NSLog("Failed to post notification: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Menu

    private func rebuildMenu() {
        let menu = NSMenu()

        if let data = lastData {
            appendUsage(data, to: menu)
            if let err = lastError {
                menu.addItem(footer("Refresh failed: \(err)"))
            }
        } else if let err = lastError {
            let item = NSMenuItem(title: err, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            if err == "Not signed in" {
                let signIn = NSMenuItem(title: "Sign in to claude.ai…", action: #selector(openLogin), keyEquivalent: "")
                signIn.target = self
                menu.addItem(signIn)
            }
        } else {
            let item = NSMenuItem(title: "Loading…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let refresh = NSMenuItem(title: "Refresh now", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        let openLoginItem = NSMenuItem(title: "Open login window…", action: #selector(openLogin), keyEquivalent: "l")
        openLoginItem.target = self
        menu.addItem(openLoginItem)

        let openBrowser = NSMenuItem(title: "Open in browser", action: #selector(openInBrowser), keyEquivalent: "")
        openBrowser.target = self
        menu.addItem(openBrowser)

        menu.addItem(displaySubmenuItem())

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func displaySubmenuItem() -> NSMenuItem {
        let submenu = NSMenu()
        for mode in [DisplayMode.always, .smartHide, .iconOnly] {
            let item = NSMenuItem(
                title: mode.label,
                action: #selector(selectDisplayMode(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = mode.rawValue
            if displayMode == mode {
                item.state = .on  // checkmark beside the active option
            }
            submenu.addItem(item)
        }
        let item = NSMenuItem(title: "Display", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private func appendUsage(_ data: UsageData, to menu: NSMenu) {
        guard let section = data.sections.first else { return }

        // Primary line — bold percent, full label color (overrides the default
        // gray that disabled menu items normally get).
        if let pct = section.percentage {
            menu.addItem(primary("\(pct)% used"))
        }

        // Indented detail rows.
        if let spent = section.dollarSpent, let limit = section.dollarLimit {
            menu.addItem(detail("\(spent) of \(limit)"))
        } else if let spent = section.dollarSpent {
            menu.addItem(detail(spent))
        }
        if let resets = section.resets {
            menu.addItem(detail("Resets \(resets)"))
        }
        if let expires = section.expires {
            menu.addItem(detail("Expires \(expires)"))
        }

        // Quiet footer — only show the local refresh time, since the page's
        // own "updated just now" is always near-identical and just noise.
        if let refreshedAt = lastRefreshAt {
            menu.addItem(footer("Refreshed \(timeFormatter.string(from: refreshedAt))"))
        }
    }

    private func primary(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: NSColor.labelColor
            ]
        )
        return item
    }

    private func detail(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.indentationLevel = 1
        item.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        return item
    }

    private func footer(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.tertiaryLabelColor
            ]
        )
        return item
    }

    // MARK: - Actions

    @objc private func refreshNow() {
        scraper.refresh(force: true)
    }

    @objc private func openLogin() {
        scraper.showLoginWindow()
    }

    @objc private func openInBrowser() {
        NSWorkspace.shared.open(UsageScraper.pageURL)
    }
}
