import Foundation
import os

private let sessionLog = Logger(subsystem: "io.github.eulric90.talaria", category: "AppSessionStore")

@MainActor
@Observable
final class AppSessionStore {
    private enum SecureKeys {
        static let accessToken = "session.accessToken"
        static let refreshToken = "session.refreshToken"
    }

    /// How an on-demand access-token refresh resolved (#15). Distinguishes
    /// "retry the request with the fresh token" from "this credential set is
    /// dead and needs recovery" — the old `Void` return collapsed both into
    /// silence, so 401 handlers retried with the same stale token that had
    /// just been rejected.
    enum TokenRefreshOutcome: Equatable {
        /// New tokens were minted and persisted.
        case refreshed
        /// No refresh token in the secure store — nothing to refresh with.
        case missingRefreshToken
        /// The relay examined the refresh token and refused it; retrying the
        /// same token can never succeed.
        case rejected
        /// Network or server failure — the refresh token may still be good.
        case transientFailure
    }

    var state: AppSessionState {
        didSet { persistence.saveSessionState(state) }
    }
    var isBootstrapping = false
    var lastErrorMessage: String?

    private var tokenRefreshTask: Task<TokenRefreshOutcome, Never>?
    private var sessionRecoveryTask: Task<Bool, Never>?
    private var lastSessionRecoveryAttemptAt: Date?
    /// Floor between silent re-registration attempts so a relay that keeps
    /// rejecting fresh credentials can't be hammered once per failed request.
    private static let sessionRecoveryRetryInterval: TimeInterval = 60

    private let bootstrapService: any SessionBootstrapServiceProtocol
    private let syncCoordinator: any SyncCoordinatorProtocol
    private let secureStore: any SecureStoreProtocol
    private let persistence: any AppPersistenceStoreProtocol
    private let notificationService: any NotificationServiceProtocol
    private let environmentProvider: @MainActor () -> AppEnvironment

    init(
        bootstrapService: any SessionBootstrapServiceProtocol,
        syncCoordinator: any SyncCoordinatorProtocol,
        secureStore: any SecureStoreProtocol,
        persistence: any AppPersistenceStoreProtocol,
        notificationService: any NotificationServiceProtocol,
        environmentProvider: @escaping @MainActor () -> AppEnvironment
    ) {
        self.bootstrapService = bootstrapService
        self.syncCoordinator = syncCoordinator
        self.secureStore = secureStore
        self.persistence = persistence
        self.notificationService = notificationService
        self.environmentProvider = environmentProvider
        self.state = persistence.loadSessionState() ?? AppSessionState()
    }

    func bootstrap(forceRegistration: Bool = false) async {
        guard !isBootstrapping else { return }

        isBootstrapping = true
        lastErrorMessage = nil
        state.connectionStatus = .connecting
        state.syncStatus = .syncing

        defer { isBootstrapping = false }

        let request = makeRegistrationRequest()
        let accessTokenBeforeBootstrap = await currentAccessToken()
        let needsRegistration =
            forceRegistration
            || !state.deviceRegistered
            || state.deviceID == nil
            || accessTokenBeforeBootstrap == nil

        do {
            if needsRegistration {
                let response = try await bootstrapService.registerDevice(request)
                await applySessionState(response.state, tokens: response.tokens)
            }

            try await loadAndApplySessionState(installationID: request.installationID)
        } catch {
            if await attemptRefreshAndReload(installationID: request.installationID) {
                return
            }
            // #15: launch-time self-heal. When the refresh path couldn't save
            // the session (refresh token gone or rejected) and this pass
            // didn't already try registering, a silent re-registration can
            // still mint fresh credentials for this known installation.
            if !needsRegistration, await recoverSessionByReRegistering() {
                return
            }

            lastErrorMessage = error.localizedDescription
            state.connectionStatus = .error
            state.syncStatus = .error
        }
    }

    func refreshSession() async {
        await syncCoordinator.sync()
        state.syncStatus = .syncing
        await bootstrap(forceRegistration: false)
    }

    func currentAccessToken() async -> String? {
        await secureStore.retrieve(key: SecureKeys.accessToken)
    }

    func currentRefreshToken() async -> String? {
        await secureStore.retrieve(key: SecureKeys.refreshToken)
    }

    /// Single-flight: concurrent 401s from talk, sensors, and the host
    /// service coalesce onto one relay round trip instead of racing the
    /// rotation (the loser's refresh would present an already-rotated token).
    @discardableResult
    func refreshAccessTokenIfNeeded() async -> TokenRefreshOutcome {
        if let tokenRefreshTask {
            return await tokenRefreshTask.value
        }
        let task = Task { await performTokenRefresh() }
        tokenRefreshTask = task
        let outcome = await task.value
        tokenRefreshTask = nil
        return outcome
    }

    private func performTokenRefresh() async -> TokenRefreshOutcome {
        guard let refreshToken = await currentRefreshToken() else {
            return .missingRefreshToken
        }

        do {
            let tokens = try await bootstrapService.refreshAuth(refreshToken: refreshToken)
            try await persist(tokens: tokens)
            return .refreshed
        } catch let error as RelayAPIClient.ClientError {
            lastErrorMessage = error.localizedDescription
            switch error {
            case .unauthorized, .payloadRejected:
                sessionLog.error("token refresh rejected by relay — credential set is dead: \(error.localizedDescription, privacy: .public)")
                return .rejected
            case .invalidURL, .requestFailed:
                return .transientFailure
            }
        } catch {
            lastErrorMessage = error.localizedDescription
            return .transientFailure
        }
    }

    /// Last-resort self-heal for a dead credential set (#15): re-register
    /// this installation over the unauthenticated register route. The relay
    /// preserves the device→user binding server-side, so a previously paired
    /// device gets fresh tokens for the same user without a manual re-pair.
    /// Callers must re-validate identity afterwards
    /// (`PairingStore.validateRestoredIdentity()`).
    func recoverSessionByReRegistering() async -> Bool {
        if let sessionRecoveryTask {
            return await sessionRecoveryTask.value
        }
        // A never-registered installation has no identity to recover — it
        // must go through pairing.
        guard state.deviceRegistered else { return false }
        if let lastSessionRecoveryAttemptAt,
           Date.now.timeIntervalSince(lastSessionRecoveryAttemptAt) < Self.sessionRecoveryRetryInterval {
            return false
        }
        let task = Task { await performSessionRecovery() }
        sessionRecoveryTask = task
        let recovered = await task.value
        sessionRecoveryTask = nil
        return recovered
    }

    private func performSessionRecovery() async -> Bool {
        lastSessionRecoveryAttemptAt = .now
        let request = makeRegistrationRequest()
        sessionLog.notice("attempting silent re-registration to recover a dead relay session (#15)")
        do {
            let response = try await bootstrapService.registerDevice(request)
            await applySessionState(response.state, tokens: response.tokens)
            try await loadAndApplySessionState(installationID: request.installationID)
            sessionLog.notice("silent re-registration recovered the relay session")
            return true
        } catch {
            lastErrorMessage = error.localizedDescription
            sessionLog.error("silent re-registration failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func applyPairedSession(state: AppSessionState, tokens: AuthTokens) async {
        lastErrorMessage = nil
        await applySessionState(state, tokens: tokens)
    }

    func revokeCurrentSession() async {
        do {
            try await bootstrapService.revokeCurrentSession(accessToken: await currentAccessToken())
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func clearSession() async {
        await secureStore.delete(key: SecureKeys.accessToken)
        await secureStore.delete(key: SecureKeys.refreshToken)

        let retainedInstallationID = state.installationID
        let retainedEndpoint = state.backendEndpoint
        lastErrorMessage = nil
        isBootstrapping = false
        state = AppSessionState(
            installationID: retainedInstallationID,
            backendEndpoint: retainedEndpoint
        )
        persistence.clearSessionState()
    }

    private func persist(tokens: AuthTokens) async throws {
        await secureStore.store(key: SecureKeys.accessToken, value: tokens.accessToken)
        await secureStore.store(key: SecureKeys.refreshToken, value: tokens.refreshToken)
    }

    private func makeRegistrationRequest() -> DeviceRegistrationRequest {
        DeviceRegistrationRequest.current(
            installationID: state.installationID,
            environment: environmentProvider()
        )
    }

    private func loadAndApplySessionState(installationID: UUID) async throws {
        let accessToken = await currentAccessToken()
        var loadedState = try await bootstrapService.loadSession(accessToken: accessToken)
        loadedState = mergeInstallationID(into: loadedState, from: installationID)
        loadedState.syncStatus = .synced
        loadedState.lastSyncAt = .now
        // The relay's /session response is authoritative for whether it holds an
        // active push registration for this device; the in-memory flag only adds
        // a registration that succeeded after this load (it starts false every
        // launch, so overwriting with it hid live server registrations).
        loadedState.pushTokenRegistered =
            loadedState.pushTokenRegistered || notificationService.isPushTokenRegistered
        state = loadedState
    }

    private func applySessionState(_ remoteState: AppSessionState, tokens: AuthTokens) async {
        try? await persist(tokens: tokens)
        state = mergeInstallationID(into: remoteState, from: state.installationID)
    }

    private func attemptRefreshAndReload(installationID: UUID) async -> Bool {
        guard await refreshAccessTokenIfNeeded() == .refreshed else { return false }

        do {
            try await loadAndApplySessionState(installationID: installationID)
            return true
        } catch {
            lastErrorMessage = error.localizedDescription
            return false
        }
    }

    private func mergeInstallationID(into state: AppSessionState, from installationID: UUID) -> AppSessionState {
        var mergedState = state
        mergedState.installationID = installationID
        return mergedState
    }
}
