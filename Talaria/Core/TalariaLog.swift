import Foundation
import os

// MARK: - TalariaLog
//
// Lightweight os.Logger facade for Talaria, fronting the Developer screen's
// "Verbose Logging" flag (T3). Subsystem is the app bundle id so captures filter
// cleanly in Console.app (filter: io.github.eulric90.talaria).
//
// Truthfulness note: flipping Verbose Logging is wired to REAL os_log here —
// `setVerbose(_:)` persists the flag and emits an observable `.notice` line every
// time it changes, so the toggle has a real, visible effect today. Routing the
// existing per-service `Logger(...)` call sites through `TalariaLog.verbose(_:)`
// (so they actually fall silent when the flag is off) is the remaining wiring,
// tracked in OPEN_ITEMS (#dev-verbose-adoption).
enum TalariaLog {
    /// App bundle identifier — the Console.app subsystem filter.
    static let subsystem = Bundle.main.bundleIdentifier ?? "io.github.eulric90.talaria"

    private static let defaultsKey = "talaria.verboseLogging"

    /// Shared logger. Categories let captures be sliced further if needed.
    static let logger = Logger(subsystem: subsystem, category: "app")

    /// Current verbose state. Backed by UserDefaults so non-MainActor service
    /// code can read it cheaply without holding SettingsStore.
    static var isVerbose: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }

    /// Persist the flag and emit a real, observable os_log line on every change.
    /// Called from the Developer screen toggle (alongside the UserSettings write).
    static func setVerbose(_ on: Bool) {
        let previous = isVerbose
        UserDefaults.standard.set(on, forKey: defaultsKey)
        guard previous != on else { return }
        // Always-on notice so the state change is visible in Console.app even
        // when verbose itself is off.
        let state = on ? "ENABLED" : "DISABLED"
        logger.notice("Verbose logging \(state, privacy: .public)")
    }

    /// Verbose-only diagnostic line. No-ops (emits nothing) when the flag is off.
    static func verbose(_ message: @autoclosure () -> String) {
        guard isVerbose else { return }
        let line = message()
        logger.debug("\(line, privacy: .public)")
    }

    /// Always-on event line (state changes, lifecycle, errors).
    static func event(_ message: @autoclosure () -> String) {
        let line = message()
        logger.notice("\(line, privacy: .public)")
    }
}

// MARK: - Per-category verbose logging
//
// Lets each service keep its own Logger category (LiveSpeechService, SensorUpload,
// …) while routing diagnostic (`.info`/`.debug`-level) lines through the global
// Verbose Logging flag. Errors, warnings, and `.notice` breadcrumbs stay on the
// service's own logger (always-on, by design). The os_log emission — the costly
// part — is skipped when verbose is off; interpolation argument expressions are
// still evaluated, so wrap genuinely hot paths in `if TalariaLog.isVerbose { … }`.
extension Logger {
    func verbose(_ message: @autoclosure () -> String) {
        guard TalariaLog.isVerbose else { return }
        let line = message()
        debug("\(line, privacy: .public)")
    }
}
