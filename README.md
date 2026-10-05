# Usage Bar

A minimalist macOS menu bar app that shows your claude.ai subscription usage. It loads the claude.ai usage settings panel in an embedded WebView, reads the rendered page, and shows your usage percent in the menu bar next to a droplet glyph that doubles as a fill gauge.

## Disclaimer

This is an independent, community-built tool. It is **not affiliated with, endorsed by, or sponsored by Anthropic**. "Claude" and "Anthropic" are trademarks of Anthropic, PBC and are used here only to identify the service the app reads from.

**Use at your own risk.** The app works by automating a browser session against claude.ai and reading the rendered usage page. Anthropic's Consumer Terms of Service restrict accessing their services "through automated or non-human means" and prohibit crawling or scraping. Running this app may therefore violate those terms and could, in principle, lead to action against your account. There is no documented API for subscription usage. Other open-source trackers call an undocumented OAuth usage endpoint with the credentials Claude Code stores locally; this app instead reads the same web page you would open yourself, so it works without Claude Code installed but is equally unofficial. Read the terms yourself and decide whether that trade-off is acceptable to you before signing in.

The app also depends on the structure of a web page it does not control. Any change to the claude.ai usage panel can break parsing without notice.

## Requirements

- macOS 14 (Sonoma) or later
- Xcode or Xcode Command Line Tools (`xcode-select --install`)
- Apple Silicon (Intel may work but is untested)

## Build

```
./build.sh
```

Produces `UsageBar.app` in the project root. The script compiles all Swift sources with `swiftc`, assembles the `.app` bundle, and ad-hoc code-signs it.

## Run

```
./run.sh
```

Rebuilds, kills any running instance, and launches the app via direct exec (not via `open`). Look for the menu bar item next to the clock.

Note: the app is ad-hoc signed (not notarized by Apple), so double-clicking the `.app` in Finder triggers Gatekeeper with "may be damaged or incomplete". Launching from the terminal goes through a different code path that only validates the ad-hoc signature via AMFI, so `./run.sh` works without any Gatekeeper override.

## First-time sign in

1. Click the menu bar item.
2. Choose **Open login window...**.
3. Sign in to claude.ai in the embedded browser. After login, the app auto-redirects to the usage panel for you (no manual navigation needed), reads it, and closes the window.

The session cookie persists via the app's WebKit data store, so you only need to sign in again when the session is invalidated server-side.

## Privacy

Everything stays on your machine. The app talks only to claude.ai, using your own browser session inside a WKWebView. Your session cookie lives in the app's WebKit data store under `~/Library` (see "Reset" below for the exact paths). No usage data, credentials or telemetry are sent anywhere else.

## Status bar at a glance

| State         | What you see                                                     |
| ------------- | ---------------------------------------------------------------- |
| Normal        | A droplet filled 30% from the bottom, then `30%`                 |
| Not signed in | An empty (ghosted) droplet, then `Sign in`                       |
| Error         | Warning triangle (keeps the last known percent if available)     |
| Loading       | A rotating droplet (1 revolution per second)                     |

The icon is a droplet SVG (`Resources/gauge.svg`) used as a gauge: a 25%-alpha render shows the full silhouette as a ghost, and a 100%-alpha render is composited on top, clipped to a bottom-up rectangle proportional to the current percent (water-level metaphor). All icons are template images, so they tint automatically with the menu bar appearance (light/dark mode).

## Menu items

Clicking the bar item opens a dropdown with:

- Current usage: bold `X% used`, indented dollar amount (`$X of $Y`), indented reset date, plus a small `Refreshed HH:MM` footer
- **Refresh now** (Cmd+R) - force a refresh
- **Open login window...** (Cmd+L) - bring up the embedded browser to sign in / re-authenticate
- **Open in browser** - open the claude.ai usage panel in your default browser
- **Display** - submenu with three modes for the status bar text:
  - *Always show percent* (default) - shows e.g. `33%` next to the icon
  - *Show percent above 50% only* - icon only below 50%, icon + percent above
  - *Icon only* - the icon gauge speaks for itself; no text
- **Quit** (Cmd+Q)

The selected display mode is persisted in `UserDefaults` (key `displayMode`). Error and not-signed-in states ignore the mode and always show their action text.

## Notifications

macOS native banners fire at **50%**, **75%**, and **90%** usage. The first launch triggers a permission prompt (Notifications); allow it once.

State is persisted across launches in `UserDefaults`, so you won't be re-notified after restarting the app. The threshold resets automatically when usage drops back below 50% (i.e. on a new billing cycle).

## Auto-refresh

Every 5 minutes (configurable via `refreshInterval` in `AppDelegate.swift`). After each successful refresh the WebView is reset to `about:blank` to free retained DOM/JS memory.

## Tests

Notification threshold logic is unit-tested via Swift Package Manager:

```
xcrun swift test
```

The pure logic lives in `Sources/UsageBarLogic/ThresholdEvaluator.swift` as a small library target. The main app target (built via `./build.sh`) compiles the same file directly without going through the library, so there's nothing to import in `AppDelegate.swift`. SPM is used **only** for the test target; the menu bar app itself ships through `./build.sh`.

## Reset (new-user experience)

The app persists state in a handful of locations:

- `~/Library/WebKit/com.usagebar.app/` - the WKWebView data store (session cookies, localStorage, IndexedDB). This is where your claude.ai login lives.
- `~/Library/Caches/com.usagebar.app/` - WebKit HTTP cache.
- `~/Library/HTTPStorages/com.usagebar.app.binarycookies` - macOS-level cookie jar.
- `~/Library/Preferences/com.usagebar.app.plist` - `UserDefaults`: `lastNotifiedThreshold` and `displayMode`.
- System TCC database - your "Allow Notifications" decision (not in `~/Library`).

When the session cookie expires, the next refresh detects the login redirect, the status bar swaps to the sign-in state, and clicking the menu opens the embedded browser to re-authenticate. No app restart needed.

To wipe everything and test the first-launch experience:

```
./reset.sh
```

The script kills any running instance, removes all the locations above (including the notification permission decision), and tells you what to expect on the next launch.

## Debugging

To see stdout/stderr in the terminal, run the binary directly instead of via `./run.sh`:

```
./UsageBar.app/Contents/MacOS/UsageBar
```

WebKit is noisy in this mode but any Swift error is visible.

## Architecture

```
Sources/
  UsageBar/
    main.swift               - app entry point
    AppDelegate.swift        - status bar, menu, display modes,
                               notifications, gauge icon + spinner
    UsageScraper.swift       - WKWebView, login window, post-login
                               auto-redirect, JS DOM extraction,
                               about:blank cleanup
    UsageParser.swift        - regex parser for the rendered usage text;
                               drops the "Claude Design" trial section
  UsageBarLogic/
    ThresholdEvaluator.swift - pure notification-threshold logic, tested
Tests/
  UsageBarLogicTests/
    ThresholdEvaluatorTests.swift
Resources/
  Info.plist                 - LSUIElement (no Dock icon), bundle ID
  gauge.svg                  - the droplet glyph, loaded by NSImage
                               and used for both the gauge and spinner
Package.swift                - SPM manifest for the test target
build.sh                     - compile + bundle + ad-hoc sign
run.sh                       - build + restart
reset.sh                     - wipe persisted state (cookies,
                               UserDefaults, notification permission)
```

## Known limitations

- The parser is tuned for the **Enterprise** dollar-spend layout. Pro / Team layouts (which use 5-hour and 7-day percent quotas) will likely need parser tweaks - see `UsageParser.swift`. Contributions welcome.
- The "may be damaged or incomplete" Gatekeeper dialog when double-clicking the `.app` is expected for ad-hoc signed local builds. Use `./run.sh` instead, or whitelist with `sudo spctl --add ./UsageBar.app` (one-time).
- Ad-hoc signed apps occasionally have trouble with `UNUserNotificationCenter` permissions - if banners don't show, check System Settings -> Notifications -> Usage Bar.

## License

MIT. See [LICENSE](LICENSE).
