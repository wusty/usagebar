#!/bin/bash
# Wipe all persisted state so the app starts as if launched for the first
# time. Useful for testing the new-user experience (sign-in flow, notification
# permission prompt, etc.). Does NOT remove the built .app bundle itself —
# only its user-data sidecar files.
set -euo pipefail

BUNDLE="com.usagebar.app"
APP_NAME="UsageBar"

echo "Killing any running instance..."
pkill -x "$APP_NAME" 2>/dev/null || true
# Give the OS a moment to release file handles before we delete state.
sleep 0.3

echo "Removing WebKit data store (session cookies, localStorage, IndexedDB)..."
rm -rf "$HOME/Library/WebKit/$BUNDLE"

echo "Removing caches..."
rm -rf "$HOME/Library/Caches/$BUNDLE"

echo "Removing HTTPStorages cookies..."
rm -f "$HOME/Library/HTTPStorages/$BUNDLE.binarycookies"
rm -rf "$HOME/Library/HTTPStorages/$BUNDLE"

echo "Removing UserDefaults (notification threshold state)..."
defaults delete "$BUNDLE" 2>/dev/null || true
rm -f "$HOME/Library/Preferences/$BUNDLE.plist"

echo "Removing saved application state (if any)..."
rm -rf "$HOME/Library/Saved Application State/$BUNDLE.savedState"

echo "Resetting notification permission decision..."
# tccutil writes to the user's TCC database. Works without sudo for the
# current user. May print a benign warning on first run if no entry exists.
tccutil reset Notifications "$BUNDLE" >/dev/null 2>&1 || true

echo ""
echo "Done. Launch with ./run.sh — you should see:"
echo "  1. macOS prompt to allow notifications (first-launch state)"
echo "  2. Status bar: empty gauge + 'Sign in'"
echo "  3. Menu: 'Not signed in' with 'Sign in to claude.ai...' action"
