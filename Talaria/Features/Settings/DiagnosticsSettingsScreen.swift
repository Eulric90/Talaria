import SwiftUI
import Foundation
import UIKit

// MARK: - Diagnostics settings screen (Settings → DIAGNOSTICS)
//
// System-health readout. Mirrors design/Settings.dc.html screen 08, real-data-only:
//   • Status rows reflect live state — Hermes API (direct probe), Relay link
//     (relay session), Push token (registration), Location (authorization).
//   • App version + device identifier are real. HOST VERSION and UPTIME have no
//     client-reachable source yet, so they render "—" (deferred).
//   • There is no in-app log ring buffer yet, so the LOGS panel is an honest
//     placeholder pointing at the real capture path (Console.app). Tracked in
//     OPEN_ITEMS alongside an export action.
struct DiagnosticsSettingsScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(AppContainer.self) private var container
    @Environment(AppSessionStore.self) private var sessionStore
    @Environment(PermissionsStore.self) private var permissionsStore
    @Environment(SettingsStore.self) private var settingsStore

    @State private var sensorAccessToken: Bool?

    private struct RowStatus {
        let text: String
        let color: Color
        let blinks: Bool
    }

    var body: some View {
        ZStack {
            HUDScreenBackground()
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: Design.Spacing.lg) {
                    SettingsScreenHeader(title: "Diagnostics", subtitle: "System Health") { dismiss() }
                    statusPanel
                    sensorPanel
                    infoGrid
                    logsSection
                    footerLinks
                }
                .padding(.horizontal, Design.Spacing.md)
                .padding(.vertical, Design.Spacing.sm)
            }
        }
        .navigationTitle("Diagnostics")
        .toolbarVisibility(.hidden, for: .navigationBar)
        .task {
            await container.chatStore.refreshDirectHealth()
            await permissionsStore.reloadCapabilities()
            sensorAccessToken = await container.sensorUploadService?.hasValidAccessToken()
        }
    }

    // MARK: Status panel

    @State private var tokenCopied = false

    private var statusPanel: some View {
        VStack(spacing: 0) {
            statusRow("Hermes API", hermesAPIStatus)
            rowDivider
            statusRow("Relay Link", relayStatus)
            rowDivider
            statusRow("Relay Identity", identityStatus)
            rowDivider
            statusRow("Push Token", tokenCopied
                ? RowStatus(text: "COPIED", color: Design.Brand.accent, blinks: false)
                : pushStatus)
                .contentShape(Rectangle())
                .onTapGesture { copyPushToken() }
            rowDivider
            statusRow("Location", locationStatus)
        }
        .hudPanel(
            cornerRadius: Design.CornerRadius.lg,
            borderColor: Design.Colors.accentTint(0.12),
            fill: Design.Colors.background.opacity(0.5),
            innerGlow: false
        )
    }

    /// Tap the Push Token row to copy the full APNs device token to the
    /// clipboard (the row otherwise only shows the pipeline state, so there
    /// was nothing to read for host-side push testing).
    private func copyPushToken() {
        guard let token = container.cachedAPNsDeviceToken else { return }
        UIPasteboard.general.string = token
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation { tokenCopied = true }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation { tokenCopied = false }
        }
    }

    private func statusRow(_ label: String, _ status: RowStatus) -> some View {
        HStack(spacing: Design.Spacing.sm) {
            StatusPip(color: status.color, diameter: 8, blinks: status.blinks)
            Text(label)
                .font(Design.Typography.callout)
                .foregroundStyle(Design.Colors.foreground)
            Spacer()
            MonoLabel(status.text, size: 10, weight: .medium,
                      tracking: Design.Tracking.mono, color: status.color)
        }
        .padding(.horizontal, Design.Spacing.md)
        .padding(.vertical, Design.Spacing.sm)
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(Design.Colors.hairline)
            .frame(height: 1)
            .padding(.horizontal, Design.Spacing.md)
    }

    private var hermesAPIStatus: RowStatus {
        switch container.chatStore.directConnectionStatus {
        case .connected:    RowStatus(text: "REACHABLE",   color: Design.Brand.accent,        blinks: false)
        case .connecting:   RowStatus(text: "CHECKING",     color: Design.Brand.forge,         blinks: true)
        case .disconnected: RowStatus(text: "UNREACHABLE",  color: Design.Colors.danger,       blinks: false)
        case .error:        RowStatus(text: "ERROR",        color: Design.Colors.danger,       blinks: false)
        }
    }

    private var relayStatus: RowStatus {
        switch sessionStore.state.connectionStatus {
        case .connected:    RowStatus(text: "LINKED",     color: Design.Brand.accent,  blinks: false)
        case .connecting:   RowStatus(text: "CONNECTING", color: Design.Brand.forge,   blinks: true)
        case .disconnected: RowStatus(text: "STANDBY",    color: Design.Brand.forge,   blinks: true)
        case .error:        RowStatus(text: "ERROR",      color: Design.Colors.danger, blinks: false)
        }
    }

    // #3/#46: which relay user this session actually authenticates as. A
    // Keychain-resurrected identity from a previous install shows as a
    // mismatch against the user the current pairing minted — the "sensors
    // 202-forever while chat works" failure is a glance here, not a forensic
    // session. "—" when there's no session user yet.
    private var identityStatus: RowStatus {
        if container.pairingStore.identityMismatchDetected {
            return RowStatus(text: "STALE — RE-PAIR", color: Design.Colors.danger, blinks: true)
        }
        guard let userID = sessionStore.state.userID else {
            return RowStatus(text: "—", color: Design.Colors.mutedForeground, blinks: false)
        }
        let short = userID.uuidString.prefix(8).uppercased()
        if container.pairingStore.expectedRelayUserID == nil {
            // Pre-#3 pairing: identity shown but unverifiable until a re-pair
            // records the minted user.
            return RowStatus(text: "USER \(short) · UNVERIFIED", color: Design.Brand.forge, blinks: false)
        }
        return RowStatus(text: "USER \(short)", color: Design.Brand.accent, blinks: false)
    }

    // Same three-state source of truth the Notifications screen renders
    // (AppContainer.pushTokenPipelineState). A locally cached APNs token alone
    // is NOT "registered" — the relay handshake is a separate stage, and
    // claiming otherwise made this row contradict Settings → Notifications.
    private var pushStatus: RowStatus {
        switch container.pushTokenPipelineState {
        case .registered:
            return RowStatus(text: "RELAY REGISTERED", color: Design.Brand.accent, blinks: false)
        case .awaitingRelay:
            return RowStatus(text: "TOKEN HELD · AWAITING RELAY", color: Design.Brand.forge, blinks: true)
        case .notIssued:
            return RowStatus(text: "NO APNS TOKEN", color: Design.Colors.mutedForeground, blinks: false)
        }
    }

    private var locationStatus: RowStatus {
        let level = permissionsStore.locationAuthorizationLevel
        switch level {
        case .always, .whenInUse:
            return RowStatus(text: level.displayLabel.uppercased(), color: Design.Brand.accent, blinks: false)
        case .denied, .restricted:
            return RowStatus(text: level.displayLabel.uppercased(), color: Design.Colors.danger, blinks: false)
        case .notDetermined:
            return RowStatus(text: "NOT SET", color: Design.Colors.mutedForeground, blinks: false)
        }
    }

    // MARK: Sensor pipeline (#15)

    @ViewBuilder
    private var sensorPanel: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.sm) {
            MonoLabel("// Sensor Pipeline", size: 10, tracking: Design.Tracking.monoXWide,
                      color: Design.Colors.mutedForeground)

            if let s = container.sensorUploadService?.sensorDiagnostics {
                VStack(spacing: 0) {
                    sensorRow("Pipeline", s.isActive ? "ACTIVE" : "IDLE",
                              s.isActive ? Design.Brand.accent : Design.Colors.mutedForeground,
                              blinks: s.isActive)
                    rowDivider
                    sensorRow("Paired", s.isPaired ? "YES" : "NO",
                              s.isPaired ? Design.Brand.accent : Design.Colors.danger)
                    rowDivider
                    sensorRow("Access Token", tokenLabel, tokenColor)
                    rowDivider
                    sensorRow("Pending Location", pendingLocationText(s),
                              s.pendingLocation == nil ? Design.Colors.mutedForeground : Design.Brand.forge)
                    rowDivider
                    sensorRow("Pending Health", pendingHealthText(s),
                              s.pendingHealthCount == 0 ? Design.Colors.mutedForeground : Design.Brand.forge)
                    rowDivider
                    sensorRow("Last Drain", lastDrainText(s),
                              s.lastDrainSummary == nil ? Design.Colors.mutedForeground : Design.Colors.secondaryForeground)
                    rowDivider
                    sensorRow("Location", "\(s.locationAuthorization.displayLabel) · \(s.locationAccuracyLabel)",
                              locationColor(s.locationAuthorization))
                    rowDivider
                    sensorRow("Health", s.healthAuthorization.displayLabel, permissionColor(s.healthAuthorization))
                    rowDivider
                    sensorRow("Motion", s.motionAuthorization.displayLabel, permissionColor(s.motionAuthorization))
                }
                .hudPanel(
                    cornerRadius: Design.CornerRadius.lg,
                    borderColor: Design.Colors.accentTint(0.12),
                    fill: Design.Colors.background.opacity(0.5),
                    innerGlow: false
                )
            } else {
                MonoLabel("Sensor pipeline unavailable in this build.", size: 10,
                          tracking: Design.Tracking.mono, color: Design.Colors.secondaryForeground)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Design.Spacing.md)
                    .hudPanel(
                        cornerRadius: Design.CornerRadius.lg,
                        borderColor: Design.Colors.accentTint(0.12),
                        fill: Design.Colors.background.opacity(0.5),
                        innerGlow: false
                    )
            }
        }
    }

    private func sensorRow(_ label: String, _ value: String, _ color: Color, blinks: Bool = false) -> some View {
        HStack(spacing: Design.Spacing.sm) {
            StatusPip(color: color, diameter: 8, blinks: blinks)
            Text(label)
                .font(Design.Typography.callout)
                .foregroundStyle(Design.Colors.foreground)
            Spacer(minLength: Design.Spacing.sm)
            MonoLabel(value, size: 10, weight: .medium,
                      tracking: Design.Tracking.mono, color: color)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
        }
        .padding(.horizontal, Design.Spacing.md)
        .padding(.vertical, Design.Spacing.sm)
    }

    private var tokenLabel: String {
        switch sensorAccessToken {
        case .some(true): "PRESENT"
        case .some(false): "ABSENT"
        case .none: "—"
        }
    }

    private var tokenColor: Color {
        switch sensorAccessToken {
        case .some(true): Design.Brand.accent
        case .some(false): Design.Colors.danger
        case .none: Design.Colors.mutedForeground
        }
    }

    private func pendingLocationText(_ s: SensorUploadService.SensorDiagnostics) -> String {
        guard let loc = s.pendingLocation else { return "none" }
        let coord = String(format: "%.3f, %.3f", loc.latitude, loc.longitude)
        return "\(coord) · \(relativeAge(loc.recordedAt))"
    }

    private func pendingHealthText(_ s: SensorUploadService.SensorDiagnostics) -> String {
        s.pendingHealthCount == 0 ? "none" : "\(s.pendingHealthCount) sample\(s.pendingHealthCount == 1 ? "" : "s")"
    }

    private func lastDrainText(_ s: SensorUploadService.SensorDiagnostics) -> String {
        guard let summary = s.lastDrainSummary else { return "—" }
        guard let at = s.lastDrainAt else { return summary }
        return "\(summary) · \(relativeAge(at))"
    }

    private func relativeAge(_ date: Date) -> String {
        let seconds = Int(max(0, Date().timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86_400)d ago"
    }

    private func locationColor(_ level: LocationAuthorizationLevel) -> Color {
        switch level {
        case .always, .whenInUse: Design.Brand.accent
        case .denied, .restricted: Design.Colors.danger
        case .notDetermined: Design.Colors.mutedForeground
        }
    }

    private func permissionColor(_ status: PermissionStatus) -> Color {
        switch status {
        case .authorized, .authorizedWhenInUse, .authorizedAlways: Design.Brand.accent
        case .limited: Design.Brand.forge
        case .denied, .restricted, .unsupported: Design.Colors.danger
        case .notDetermined: Design.Colors.mutedForeground
        }
    }

    // MARK: Info grid

    private var infoGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: Design.Spacing.sm),
                GridItem(.flexible(), spacing: Design.Spacing.sm)
            ],
            spacing: Design.Spacing.sm
        ) {
            infoTile("App Version", appVersion)
            infoTile("Host Version", "—")
            infoTile("Uptime", "—")
            infoTile("Device", deviceIdentifier)
        }
    }

    private func infoTile(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: Design.Spacing.xs) {
            MonoLabel(label, size: 8, weight: .medium,
                      tracking: Design.Tracking.monoWide, color: Design.Colors.mutedForeground)
            Text(value)
                .font(Design.Typography.mono(13, weight: .medium))
                .foregroundStyle(Design.Colors.foreground)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Design.Spacing.md)
        .hudPanel(
            cornerRadius: Design.CornerRadius.md,
            borderColor: Design.Colors.accentTint(0.12),
            fill: Design.Colors.background.opacity(0.5),
            innerGlow: false
        )
    }

    // MARK: Logs (deferred)

    private var logsSection: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.sm) {
            MonoLabel("// Logs", size: 10, tracking: Design.Tracking.monoXWide,
                      color: Design.Colors.mutedForeground)

            VStack(alignment: .leading, spacing: Design.Spacing.xs) {
                MonoLabel("In-app log buffer not yet captured.", size: 10,
                          tracking: Design.Tracking.mono, color: Design.Colors.secondaryForeground)
                MonoLabel("Capture via Console.app · filter io.github.eulric90.talaria", size: 9,
                          tracking: Design.Tracking.mono, color: Design.Colors.mutedForeground)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Design.Spacing.md)
            .background(
                Design.Colors.background.opacity(0.6),
                in: RoundedRectangle(cornerRadius: Design.CornerRadius.md)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Design.CornerRadius.md)
                    .strokeBorder(Design.Colors.hairline, lineWidth: 1)
            }
        }
    }

    // MARK: Footer links

    private var footerLinks: some View {
        HStack(spacing: Design.Spacing.md) {
            footerLink("Terms", settingsStore.buildConfiguration.termsOfServiceURL)
            footerDot
            footerLink("Privacy", settingsStore.buildConfiguration.privacyPolicyURL)
            if settingsStore.buildConfiguration.supportURL != nil {
                footerDot
                footerLink("Support", settingsStore.buildConfiguration.supportURL)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, Design.Spacing.xs)
        .padding(.bottom, Design.Spacing.md)
    }

    private var footerDot: some View {
        Text("·")
            .font(Design.Typography.mono(9, weight: .regular))
            .foregroundStyle(Design.Colors.dimForeground)
    }

    @ViewBuilder
    private func footerLink(_ title: String, _ url: URL?) -> some View {
        Button {
            if let url { openURL(url) }
        } label: {
            MonoLabel(title, size: 9, weight: .medium, tracking: Design.Tracking.monoWide,
                      color: url == nil ? Design.Colors.mutedForeground : Design.Brand.accent)
        }
        .buttonStyle(.plain)
        .disabled(url == nil)
    }

    // MARK: Derived values

    private var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String ?? "—"
        return "\(short) (\(build))"
    }

    private var deviceIdentifier: String {
        var sysinfo = utsname()
        uname(&sysinfo)
        let machine = withUnsafeBytes(of: &sysinfo.machine) { raw -> String in
            let ptr = raw.baseAddress!.assumingMemoryBound(to: CChar.self)
            return String(cString: ptr)
        }
        return machine.isEmpty ? "—" : machine
    }
}
