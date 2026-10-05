import AppKit
import WebKit

enum ScrapeResult {
    case success(UsageData)
    case needsLogin
    case error(String)
}

final class UsageScraper: NSObject, WKNavigationDelegate, NSWindowDelegate {
    // claude.ai serves usage as a modal overlay opened by a hash fragment on the
    // chat home (`/new#settings/usage`), not as a standalone route anymore. The
    // legacy `/settings/usage` path no longer reliably renders the panel, so we
    // navigate straight to the canonical fragment URL.
    static let pageURL = URL(string: "https://claude.ai/new#settings/usage")!
    private static let blankURL = URL(string: "about:blank")!

    /// True when `url` is showing the usage panel — either the canonical
    /// `#settings/usage` fragment or the legacy `/settings/usage` path (kept so
    /// we don't loop if Anthropic ever serves the old route again).
    private static func isUsagePage(_ url: URL) -> Bool {
        if url.path == "/settings/usage" { return true }
        if let frag = url.fragment, frag.contains("settings/usage") { return true }
        return false
    }

    private let webView: WKWebView
    private let window: NSWindow
    private let onUpdate: (ScrapeResult) -> Void
    private let onRefreshStart: () -> Void

    private var pendingScrape: DispatchWorkItem?
    private var isWindowVisible = false
    // True between requesting an about:blank load (post-scrape cleanup to free
    // WebContent memory) and its didFinish/didFail. We ignore those callbacks
    // because there's nothing to scrape on a blank page.
    private var isBlankingForCleanup = false
    // True once we've auto-redirected the WebView to /settings/usage within a
    // single refresh cycle. Prevents an infinite loop in the (unlikely) case
    // that /settings/usage itself bounces us elsewhere on claude.ai.
    private var didAutoRedirectThisCycle = false

    init(
        onRefreshStart: @escaping () -> Void = {},
        onUpdate: @escaping (ScrapeResult) -> Void
    ) {
        self.onRefreshStart = onRefreshStart
        self.onUpdate = onUpdate

        let config = WKWebViewConfiguration()
        // .default() is a persistent data store; cookies survive across launches
        // when the app has a stable bundle identifier (set in Info.plist).
        config.websiteDataStore = .default()

        let frame = NSRect(x: 0, y: 0, width: 1100, height: 800)
        self.webView = WKWebView(frame: frame, configuration: config)
        self.webView.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

        // A real window — created off-screen and ordered out — so the WebView
        // always has a hosting window (required for reliable rendering / JS).
        self.window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 1100, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        self.window.title = "Usage Bar - sign in to claude.ai"
        self.window.contentView = webView
        self.window.isReleasedWhenClosed = false

        super.init()
        self.window.delegate = self
        self.webView.navigationDelegate = self
    }

    // MARK: - Public

    func refresh(force: Bool = false) {
        // Don't reload while the user is mid-login.
        if isWindowVisible && !force { return }
        isBlankingForCleanup = false
        didAutoRedirectThisCycle = false
        onRefreshStart()
        webView.load(URLRequest(url: Self.pageURL))
    }

    func showLoginWindow() {
        isWindowVisible = true
        window.setFrame(NSRect(x: 200, y: 200, width: 1100, height: 800), display: true)
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        if webView.url == nil {
            refresh(force: true)
        }
    }

    func hideLoginWindow() {
        isWindowVisible = false
        window.orderOut(nil)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if isBlankingForCleanup {
            isBlankingForCleanup = false
            return
        }

        // After login, claude.ai usually drops the user on /new (chat home)
        // with no fragment, so the usage panel isn't open. Auto-redirect so the
        // user doesn't have to navigate there manually. Only fires once per
        // refresh cycle so we can't loop if the usage URL bounces elsewhere.
        // Crucially we test for the panel being open (fragment-aware) rather
        // than an exact path match — otherwise landing on `/new#settings/usage`
        // (panel already open) would be mistaken for "not on usage" and trigger
        // a needless reload that often lands back on bare /new.
        if !didAutoRedirectThisCycle,
           let url = webView.url,
           (url.host ?? "").hasSuffix("claude.ai"),
           !Self.isUsagePage(url) {
            didAutoRedirectThisCycle = true
            webView.load(URLRequest(url: Self.pageURL))
            return
        }

        scheduleScrape(attempt: 1)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if isBlankingForCleanup {
            isBlankingForCleanup = false
            return
        }
        onUpdate(.error("Navigation failed: \(error.localizedDescription)"))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if isBlankingForCleanup {
            isBlankingForCleanup = false
            return
        }
        onUpdate(.error("Could not reach claude.ai: \(error.localizedDescription)"))
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hideLoginWindow()
        // After closing, try to re-scrape — user may have just logged in.
        refresh(force: true)
        return false
    }

    // MARK: - Scraping

    private func scheduleScrape(attempt: Int) {
        pendingScrape?.cancel()
        // Delay grows with attempt count so an SPA has time to render.
        let delay: TimeInterval = attempt == 1 ? 2.0 : 1.5
        let work = DispatchWorkItem { [weak self] in
            self?.performScrape(attempt: attempt)
        }
        pendingScrape = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func performScrape(attempt: Int) {
        // Return a plain JS object — WebKit bridges it to [String: Any] for us.
        // The try/catch inside JS guards against transient DOM exceptions
        // (e.g. document not yet ready), surfacing them via the `error` field.
        let js = """
        (function() {
          try {
            return {
              url: window.location.href,
              title: document.title || '',
              body: document.body ? (document.body.innerText || '') : ''
            };
          } catch (e) {
            return { error: String(e) };
          }
        })();
        """
        webView.evaluateJavaScript(js) { [weak self] result, error in
            guard let self = self else { return }

            if let error = error {
                self.onUpdate(.error("JS evaluation failed: \(error.localizedDescription)"))
                return
            }
            guard let obj = result as? [String: Any] else {
                self.onUpdate(.error("Unexpected JS return type"))
                return
            }
            if let jsErr = obj["error"] as? String {
                self.onUpdate(.error("Page JS threw: \(jsErr)"))
                return
            }

            let url = (obj["url"] as? String) ?? ""
            let body = (obj["body"] as? String) ?? ""

            // Login redirect — claude.ai bounces unauthenticated requests to a login flow.
            // Note the panel-open test uses "settings/usage" (no leading slash) so
            // it matches both the legacy path and the `#settings/usage` fragment;
            // the fragment has no slash before "settings", so "/settings/usage"
            // would miss it and spuriously flag the logged-in page as login.
            let onUsagePanel = url.contains("settings/usage")
            let looksLikeLogin = url.contains("/login")
                || url.contains("/oauth")
                || url.contains("/auth/")
                || url.contains("/sso")
                || (!onUsagePanel
                    && (body.localizedCaseInsensitiveContains("Sign in")
                        || body.localizedCaseInsensitiveContains("Log in")))

            if looksLikeLogin {
                self.onUpdate(.needsLogin)
                return
            }

            // If the page hasn't rendered yet, retry — SPAs hydrate lazily.
            let hasUsageMarker = body.localizedCaseInsensitiveContains("Your usage limits")
                || body.localizedCaseInsensitiveContains("% used")
                || body.localizedCaseInsensitiveContains("Last updated")
            if !hasUsageMarker && attempt < 6 {
                self.scheduleScrape(attempt: attempt + 1)
                return
            }

            if !hasUsageMarker {
                self.onUpdate(.error("Usage page did not render in time"))
                return
            }

            let parsed = UsageParser.parse(body)
            self.onUpdate(.success(parsed))

            // Free the WebContent process's retained DOM/JS state. Without this,
            // the WebContent helper RSS grows unbounded over a multi-day session.
            self.isBlankingForCleanup = true
            self.webView.load(URLRequest(url: Self.blankURL))
        }
    }
}
