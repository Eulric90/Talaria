import Foundation
import os

private let pairingLog = Logger(subsystem: "io.github.eulric90.talaria", category: "PairingStore")

@MainActor
@Observable
final class PairingStore {
    private static let onboardingKey = "hermes.needsPermissionsOnboarding"

    var pairedRelayConfiguration: PairedRelayConfiguration?
    var isWorking = false
    var lastErrorMessage: String?
    var needsPermissionsOnboarding = false
    var onPairingChanged: (@MainActor (Bool) async -> Void)?

    /// True when the restored session authenticates as a different relay user
    /// than the one this pairing minted — the reinstall-resurrected-identity
    /// signature (#3/#46). Surfaced in Diagnostics; cleared by a re-pair.
    private(set) var identityMismatchDetected = false

    private let pairingService: any PairingServiceProtocol
    private let sessionStore: AppSessionStore
    private let persistence: any AppPersistenceStoreProtocol
    private let environmentProvider: @MainActor () -> AppEnvironment
    private let relayBaseURLProvider: @MainActor () -> String?

    init(
        pairingService: any PairingServiceProtocol,
        sessionStore: AppSessionStore,
        persistence: any AppPersistenceStoreProtocol,
        environmentProvider: @escaping @MainActor () -> AppEnvironment,
        relayBaseURLProvider: @escaping @MainActor () -> String?
    ) {
        self.pairingService = pairingService
        self.sessionStore = sessionStore
        self.persistence = persistence
        self.environmentProvider = environmentProvider
        self.relayBaseURLProvider = relayBaseURLProvider
        self.pairedRelayConfiguration = persistence.loadPairedRelayConfiguration()
        self.needsPermissionsOnboarding = UserDefaults.standard.bool(forKey: Self.onboardingKey)
    }

    var isPaired: Bool {
        pairedRelayConfiguration != nil
    }

    func normalizePairingCode(_ rawCode: String) throws -> String {
        try pairingService.normalizePairingCode(rawCode)
    }

    @discardableResult
    func pair(using rawSetupCode: String) async -> Bool {
        isWorking = true
        lastErrorMessage = nil
        defer { isWorking = false }

        do {
            let normalizedCode = try pairingService.normalizePairingCode(rawSetupCode)
            guard let relayBaseURLString = RelayConfiguration.normalizeBaseURL(relayBaseURLProvider()) else {
                lastErrorMessage = "Enter a valid relay URL ending with /v1 before pairing."
                return false
            }
            let request = DeviceRegistrationRequest.current(
                installationID: sessionStore.state.installationID,
                environment: environmentProvider(),
                relayBaseURLString: relayBaseURLString
            )
            let result = try await pairingService.redeemPairingCode(
                normalizedCode,
                request: request
            )

            // #3/#46: adopt the new identity on a clean slate. A reinstall can
            // resurrect a previous (possibly revoked) relay identity from the
            // Keychain — no stale credential may survive a successful re-pair.
            // Scoped to the relay identity: the Hermes API key and shim token
            // are user-entered config for the independent chat path, not
            // minted credentials, and must survive a re-pair.
            await sessionStore.clearSession()
            persistence.clearPairedRelayConfiguration()
            identityMismatchDetected = false

            persistence.savePairedRelayConfiguration(result.configuration)
            pairedRelayConfiguration = result.configuration
            lastErrorMessage = nil
            setNeedsPermissionsOnboarding(true)
            await sessionStore.applyPairedSession(state: result.state, tokens: result.tokens)
            pairingLog.notice("pair: adopted relay user \(result.state.userID?.uuidString ?? "unknown", privacy: .public) on a clean slate")
            await onPairingChanged?(true)
            return true
        } catch {
            lastErrorMessage = error.localizedDescription
            return false
        }
    }

    func disconnect() async {
        isWorking = true
        lastErrorMessage = nil
        defer { isWorking = false }

        await sessionStore.revokeCurrentSession()
        await clearLocalPairing(notify: true)
    }

    func completePermissionsOnboarding() {
        setNeedsPermissionsOnboarding(false)
    }

    func clearLocalPairing(notify: Bool = true) async {
        persistence.clearPairedRelayConfiguration()
        pairedRelayConfiguration = nil
        lastErrorMessage = nil
        identityMismatchDetected = false
        setNeedsPermissionsOnboarding(false)
        await sessionStore.clearSession()
        if notify {
            await onPairingChanged?(false)
        }
    }

    // MARK: - Identity validation (#3/#46)

    /// The relay user this pairing minted, when known. Pairings saved before
    /// `relayUserID` existed report nil (validation degrades to a no-op until
    /// the next re-pair records it).
    var expectedRelayUserID: UUID? {
        pairedRelayConfiguration?.relayUserID
    }

    /// Compares the restored/bootstrapped session's user against the pairing's
    /// minted user. Call after a session bootstrap. A mismatch means the
    /// Keychain resurrected an identity from a previous install — the session
    /// is flagged (Diagnostics shows RE-PAIR) rather than destroyed, so the
    /// user decides when to re-pair.
    func validateRestoredIdentity() {
        guard let expected = expectedRelayUserID,
              let actual = sessionStore.state.userID else {
            identityMismatchDetected = false
            return
        }
        let mismatch = expected != actual
        if mismatch, !identityMismatchDetected {
            pairingLog.error("validateRestoredIdentity: session user \(actual.uuidString, privacy: .public) ≠ paired user \(expected.uuidString, privacy: .public) — stale Keychain identity (#3). Re-pair required.")
        }
        identityMismatchDetected = mismatch
    }

    private func setNeedsPermissionsOnboarding(_ value: Bool) {
        needsPermissionsOnboarding = value
        UserDefaults.standard.set(value, forKey: Self.onboardingKey)
    }
}
