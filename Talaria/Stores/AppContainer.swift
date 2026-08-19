import Foundation
import os

private let containerLog = Logger(subsystem: "io.github.eulric90.talaria", category: "AppContainer")

@MainActor
@Observable
final class AppContainer {
    static let apnsTokenDefaultsKey = "hermes.apns.deviceToken"
    static let hermesAPIKeyKeychainKey = "hermes.apiServerKey"
    static let modelsShimTokenKeychainKey = "talaria.modelsShimToken"
    private static let sharedDefaultContainer = AppContainer.makeDefault()

    let router = TabRouter()
    let sessionStore: AppSessionStore
    let pairingStore: PairingStore
    let hostStore: HermesHostStore
    let chatStore: ChatStore
    let inboxStore: InboxStore
    let permissionsStore: PermissionsStore
    let settingsStore: SettingsStore
    let talkStore: TalkStore
    let modelsShimClient: ModelsShimClient
    let sensorUploadService: SensorUploadService?
    private let apiClient: RelayAPIClient?
    private let notificationService: (any NotificationServiceProtocol)?
    private let secureStore: (any SecureStoreProtocol)?
    private(set) var hermesAPIKey: String = ""
    private(set) var modelsShimToken: String = ""
    private var _chatAPIKeyBox: MutableHermesAPIKeyBox?
    private var _shimTokenBox: MutableShimTokenBox?
    private var isInitialized = false
    private var lastCommandCatalogRefreshAt: Date?
    private var lastKnownHostOnline = false

    private static let commandCatalogRefreshInterval: TimeInterval = 60

    init(
        sessionStore: AppSessionStore,
        pairingStore: PairingStore,
        hostStore: HermesHostStore,
        chatStore: ChatStore,
        inboxStore: InboxStore,
        permissionsStore: PermissionsStore,
        settingsStore: SettingsStore,
        talkStore: TalkStore,
        modelsShimClient: ModelsShimClient,
        sensorUploadService: SensorUploadService? = nil,
        apiClient: RelayAPIClient? = nil,
        notificationService: (any NotificationServiceProtocol)? = nil,
        secureStore: (any SecureStoreProtocol)? = nil
    ) {
        self.sessionStore = sessionStore
        self.pairingStore = pairingStore
        self.hostStore = hostStore
        self.chatStore = chatStore
        self.inboxStore = inboxStore
        self.permissionsStore = permissionsStore
        self.settingsStore = settingsStore
        self.talkStore = talkStore
        self.modelsShimClient = modelsShimClient
        self.sensorUploadService = sensorUploadService
        self.apiClient = apiClient
        self.notificationService = notificationService
        self.secureStore = secureStore
    }

    static func sharedDefault() -> AppContainer {
        sharedDefaultContainer
    }

    var shouldShowLaunchSplash: Bool {
        sessionStore.isBootstrapping || (pairingStore.isPaired && !isInitialized)
    }

    static func makeDefault(
        defaults: UserDefaults? = nil,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AppContainer {
        let resolvedDefaults: UserDefaults
        if let defaults {
            resolvedDefaults = defaults
        } else if let suiteName = processEnvironment["UITEST_DEFAULTS_SUITE"] {
            resolvedDefaults = UserDefaults(suiteName: suiteName) ?? .standard
        } else {
            resolvedDefaults = .standard
        }

        let buildConfiguration = AppBuildConfiguration.current()
        let secureStore = KeychainSecureStore(
            serviceName: processEnvironment["UITEST_KEYCHAIN_SERVICE"] ?? "io.github.eulric90.talaria.session"
        )
        // Keychain-mirrored so the pairing config survives clean reinstalls,
        // like the session tokens already do (#41).
        let persistence = UserDefaultsAppPersistenceStore(
            defaults: resolvedDefaults,
            keychainMirror: secureStore
        )
        let settingsStore = SettingsStore(
            persistence: persistence,
            buildConfiguration: buildConfiguration
        )
        // Seed the runtime theme from the persisted appearance prefs before the
        // first frame renders, so a saved non-cyan accent never flashes cyan.
        // (Live updates are mirrored from the app root via ThemeRuntime.apply.)
        ThemeRuntime.shared.apply(settingsStore.settings)
        // Sync the verbose-logging bridge from the persisted flag at launch —
        // otherwise the Developer toggle is the only writer and the bridge can
        // drift from UserSettings across restores (#29).
        TalariaLog.setVerbose(settingsStore.settings.verboseLogging)
        let syncCoordinator = MockSyncCoordinator()
        let notificationService = LiveNotificationService()
        let allowMockFallbacks = AppEnvironmentPolicy.currentBuild.allowsEnvironmentOverrides
        let usesMockPairingService = processEnvironment["UITEST_PAIRING_MODE"] == "mock"
        let pairingService: any PairingServiceProtocol
        var activePairingStore: PairingStore?

        if processEnvironment["UITEST_PAIRING_MODE"] == "mock" {
            pairingService = MockPairingService()
        } else {
            pairingService = LivePairingService()
        }

        let apiClient = RelayAPIClient {
            activePairingStore?.pairedRelayConfiguration?.baseURLString
                ?? settingsStore.settings.relayConfiguration.activeBaseURLString
                ?? ""
        }

        let sessionBootstrapService = ResilientSessionBootstrapService(
            primary: LiveSessionBootstrapService(apiClient: apiClient),
            fallback: MockSessionBootstrapService(),
            allowsFallback: { allowMockFallbacks && (activePairingStore?.isPaired != true || usesMockPairingService) }
        )

        let inboxService = ResilientInboxService(
            primary: LiveInboxService(apiClient: apiClient),
            fallback: MockInboxService(),
            allowsFallback: { allowMockFallbacks && (activePairingStore?.isPaired != true || usesMockPairingService) }
        )

        let sessionStore = AppSessionStore(
            bootstrapService: sessionBootstrapService,
            syncCoordinator: syncCoordinator,
            secureStore: secureStore,
            persistence: persistence,
            notificationService: notificationService,
            environmentProvider: { settingsStore.settings.environment }
        )

        let runtimePairingStore = PairingStore(
            pairingService: pairingService,
            sessionStore: sessionStore,
            persistence: persistence,
            environmentProvider: { settingsStore.settings.environment },
            relayBaseURLProvider: { settingsStore.settings.relayConfiguration.activeBaseURLString }
        )
        activePairingStore = runtimePairingStore

        // #15: one 401-recovery ladder for every relay-token consumer (host,
        // sensors, talk). Refresh first; if the refresh token itself is dead,
        // silently re-register this installation (the relay preserves the
        // device→user binding) and re-validate identity before handing the
        // fresh token back. Returns nil when nothing was recovered — the
        // stored token just 401'd, so retrying with it would only burn a
        // doomed request.
        let relayAccessTokenRefresher: @MainActor () async -> String? = {
            switch await sessionStore.refreshAccessTokenIfNeeded() {
            case .refreshed:
                return await sessionStore.currentAccessToken()
            case .transientFailure:
                return nil
            case .missingRefreshToken, .rejected:
                guard await sessionStore.recoverSessionByReRegistering() else { return nil }
                runtimePairingStore.validateRestoredIdentity()
                // A recovered session that authenticates as the wrong relay
                // user is the #46 half-broken state — flag it (Diagnostics
                // shows RE-PAIR) and fail the request instead of quietly
                // acting as someone else.
                guard !runtimePairingStore.identityMismatchDetected else { return nil }
                return await sessionStore.currentAccessToken()
            }
        }

        let hostService: any HermesHostServiceProtocol
        if usesMockPairingService {
            hostService = MockHermesHostService()
        } else {
            hostService = LiveHermesHostService(
                apiClient: apiClient,
                accessTokenRefresher: relayAccessTokenRefresher
            )
        }

        let hostStore = HermesHostStore(
            hostService: hostService,
            accessTokenProvider: { await sessionStore.currentAccessToken() }
        )

        let hermesAPIKeyBox = MutableHermesAPIKeyBox()
        let sessionsClient = SessionsHermesClient(
            baseURLProvider: {
                let raw = settingsStore.settings.hermesAPIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                return raw.isEmpty ? nil : raw
            },
            apiKeyProvider: { hermesAPIKeyBox.value }
        )
        let hermesClient = ResilientHermesClient(
            primary: sessionsClient,
            fallback: MockHermesClient(),
            allowsFallback: { allowMockFallbacks && (activePairingStore?.isPaired != true || usesMockPairingService) }
        )

        // Talaria models-shim client (OJAMD tailnet). Auth priority:
        //  1. Dedicated shim token from Keychain (legacy / explicit override)
        //  2. DEBUG launch-env TALARIA_SHIM_TOKEN (simulator convenience)
        //  3. Hermes API server key (same key used for chat — zero-config)
        // Option 3 means the user never has to manually copy a second token;
        // the shim accepts both its own token AND the API server key (#14).
        let shimTokenBox = MutableShimTokenBox()
        let modelsShimClient = ModelsShimClient(
            baseURLProvider: {
                let raw = settingsStore.settings.modelsShimBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                return raw.isEmpty ? nil : raw
            },
            tokenProvider: { [hermesAPIKeyBox] in
                if !shimTokenBox.value.isEmpty { return shimTokenBox.value }
                #if DEBUG
                if let envToken = processEnvironment["TALARIA_SHIM_TOKEN"], !envToken.isEmpty {
                    return envToken
                }
                #endif
                // Fall back to the Hermes API key — the shim accepts it as an
                // alternate bearer token (see tools/models-shim/shim.py).
                if !hermesAPIKeyBox.value.isEmpty { return hermesAPIKeyBox.value }
                return nil
            }
        )

        let liveLocationService = LiveLocationService()
        liveLocationService.updateSyncPreference(settingsStore.settings.locationSyncPreference)
        let liveHealthService = LiveHealthService(persistence: persistence)
        let liveMotionService = LiveMotionService()
        let sensorUploadService: SensorUploadService? = usesMockPairingService ? nil : SensorUploadService(
            apiClient: apiClient,
            accessTokenProvider: { await sessionStore.currentAccessToken() },
            accessTokenRefresher: relayAccessTokenRefresher,
            persistence: persistence,
            isPairedProvider: { activePairingStore?.isPaired == true },
            isHealthCollectionEnabled: { settingsStore.settings.healthCollectionEnabled },
            isLocationCollectionEnabled: { settingsStore.settings.locationCollectionEnabled },
            locationService: liveLocationService,
            healthService: liveHealthService,
            motionService: liveMotionService
        )
        let voiceService: any VoiceSessionServiceProtocol = if usesMockPairingService {
            MockVoiceSessionService()
        } else {
            LiveVoiceSessionService(
                apiClient: apiClient,
                accessTokenProvider: { await sessionStore.currentAccessToken() },
                accessTokenRefresher: relayAccessTokenRefresher
            )
        }

        let container = AppContainer(
            sessionStore: sessionStore,
            pairingStore: runtimePairingStore,
            hostStore: hostStore,
            chatStore: ChatStore(hermesClient: hermesClient, persistence: persistence),
            inboxStore: InboxStore(
                inboxService: inboxService,
                persistence: persistence,
                sessionStore: sessionStore,
                allowDemoFallback: allowMockFallbacks
            ),
            permissionsStore: PermissionsStore(
                locationService: liveLocationService,
                healthService: liveHealthService,
                notificationService: notificationService,
                mediaService: processEnvironment["UITEST_PAIRING_MODE"] != nil ? MockMediaService() : LiveMediaService(),
                motionService: liveMotionService
            ),
            settingsStore: settingsStore,
            talkStore: TalkStore(voiceService: voiceService),
            modelsShimClient: modelsShimClient,
            sensorUploadService: sensorUploadService,
            apiClient: apiClient,
            notificationService: notificationService,
            secureStore: secureStore
        )

        container.chatAPIKeyBox = hermesAPIKeyBox
        container.shimTokenBox = shimTokenBox

        // Restore any persisted Hermes Sessions-API key into the in-memory box
        // so the chat client can pick it up on first send without blocking startup.
        Task { @MainActor [weak container, hermesAPIKeyBox] in
            if let stored = await secureStore.retrieve(key: AppContainer.hermesAPIKeyKeychainKey) {
                hermesAPIKeyBox.value = stored
                container?.hermesAPIKey = stored
            }
        }

        // Restore the persisted models-shim bearer token (same pattern).
        Task { @MainActor [weak container, shimTokenBox] in
            if let stored = await secureStore.retrieve(key: AppContainer.modelsShimTokenKeychainKey) {
                shimTokenBox.value = stored
                container?.modelsShimToken = stored
            }
        }

        let refreshUnpairedRelayContext: @MainActor () async -> Void = { [weak sessionStore, weak container] in
            guard container?.pairingStore.isPaired == false else { return }
            await sessionStore?.clearSession()
            guard let relayBaseURL = container?.settingsStore.settings.relayConfiguration.activeBaseURLString,
                  !relayBaseURL.isEmpty else { return }
            _ = relayBaseURL
            await sessionStore?.bootstrap(forceRegistration: true)
            await container?.inboxStore.loadInbox(force: true)
        }

        settingsStore.onEnvironmentChanged = { _ in
            await refreshUnpairedRelayContext()
        }
        settingsStore.onRelayConfigurationChanged = { _ in
            await refreshUnpairedRelayContext()
        }

        runtimePairingStore.onPairingChanged = { [weak container] isPaired in
            if isPaired {
                await container?.handlePairingActivated()
            } else {
                await container?.handlePairingRemoved()
            }
        }

        // Keep widget data fresh while app is foregrounded
        container.chatStore.onConversationChanged = { [weak container] in
            container?.updateWidgetData()
        }
        // Run-completion push watch (#38): when a stream detaches while the
        // app is leaving the foreground, ask the relay to watch the session
        // and fire APNs on completion; when the app reconciles the run on its
        // own, withdraw the watch so no stale push arrives.
        container.chatStore.onRunDetached = { [weak container] sessionId in
            Task { await container?.postPushWatch(sessionId: sessionId) }
        }
        container.chatStore.onRunResolved = { [weak container] sessionId in
            Task { await container?.cancelPushWatch(sessionId: sessionId) }
        }
        container.talkStore.onSessionStateChanged = { [weak container] in
            container?.updateWidgetData()
        }
        container.hostStore.onHostChanged = { [weak container] in
            guard let container else { return }
            let isOnline = container.hostStore.isHostOnline
            let becameOnline = isOnline && container.lastKnownHostOnline == false
            container.lastKnownHostOnline = isOnline
            container.updateWidgetData()
            Task { [weak container] in
                await container?.refreshCommandCatalog(force: becameOnline)
            }
        }

        return container
    }

    func initialize() async {
        guard pairingStore.isPaired else {
            containerLog.warning("initialize: ABORT — not paired")
            return
        }
        guard !isInitialized else {
            containerLog.verbose("initialize: SKIP — already initialized")
            return
        }
        guard await sessionStore.currentAccessToken() != nil else {
            containerLog.warning("initialize: ABORT — no access token, clearing pairing")
            await pairingStore.clearLocalPairing()
            return
        }

        await permissionsStore.reloadCapabilities()
        await sessionStore.bootstrap()
        // #3/#46: a reinstall can resurrect a previous relay identity from the
        // Keychain — verify the bootstrapped session's user matches the one
        // this pairing minted before relay-backed features run on it.
        pairingStore.validateRestoredIdentity()
        if sessionStore.state.connectionStatus != .connected {
            // Relay bootstrap failed (e.g. the relay restarted and invalidated this
            // device's tokens → 401 on register/session/refresh). Do NOT strand the
            // launch splash: the direct chat path (:8642, API-key auth) is independent
            // of the relay session, so we continue into the app in a degraded state and
            // let the user reach Settings to re-pair / retry rather than being hard
            // locked at launch. Relay-backed features (sensor upload, inbox, push) stay
            // degraded until a valid session is restored; re-pairing re-runs initialize().
            containerLog.warning("initialize: relay bootstrap not connected (is \(String(describing: self.sessionStore.state.connectionStatus), privacy: .public)) — entering degraded mode; direct chat still available")
        }
        await hostStore.refresh()
        lastKnownHostOnline = hostStore.isHostOnline
        await chatStore.loadConversationIfNeeded()
        await inboxStore.loadInbox()
        await refreshCommandCatalog(force: true)
        // Seed the model chip label from the shim if the command catalog didn't
        // provide an active model name (e.g. relay offline). Best-effort: if the
        // shim is unreachable or the token isn't set, the chip shows "HERMES".
        if chatStore.activeModelName == nil {
            await seedActiveModelFromShim()
        }
        await registerStoredPushTokenIfNeeded()
        containerLog.notice("initialize: starting sensor service + handleAppDidBecomeActive")
        sensorUploadService?.start()
        await sensorUploadService?.handleAppDidBecomeActive()
        reconcileLiveActivities()
        updateWidgetData()
        isInitialized = true
    }

    func handleAppDidBecomeActive() async {
        guard pairingStore.isPaired else {
            containerLog.warning("handleAppDidBecomeActive: BLOCKED — not paired")
            return
        }
        guard await sessionStore.currentAccessToken() != nil else {
            containerLog.warning("handleAppDidBecomeActive: BLOCKED — no access token")
            return
        }
        containerLog.verbose("handleAppDidBecomeActive: paired + token OK, proceeding")

        await permissionsStore.reloadCapabilities()
        await hostStore.refresh()
        lastKnownHostOnline = hostStore.isHostOnline
        await refreshCommandCatalog(force: true)
        // Seed the model chip from the shim if the catalog didn't provide one
        // (e.g. relay offline). This path runs even when initialize() aborts.
        if chatStore.activeModelName == nil {
            await seedActiveModelFromShim()
        }
        await registerStoredPushTokenIfNeeded()
        await sensorUploadService?.handleAppDidBecomeActive()
        talkStore.handleAppDidBecomeActive()
        await talkStore.refreshReadiness()
        await chatStore.reconcilePendingRuns()
        reconcileLiveActivities()
        await reportAppStateIfNeeded("foreground")
        updateWidgetData()
    }

    /// User tapped a completion notification — bring the app to chat and
    /// reconcile so the finished reply is fetched. `sessionID` (from the
    /// remote push payload) targets the specific conversation; local
    /// completion notifications pass nil and land on the active one.
    func handleNotificationTap(sessionID: String?) async {
        guard pairingStore.isPaired else { return }
        router.activeSheet = nil
        router.popToRoot()
        router.selectedTab = .chat
        if let sessionID, !sessionID.isEmpty {
            await chatStore.openSession(sessionID)
        }
        await chatStore.reconcilePendingRuns()
    }

    func handleRemoteNotificationWake() async {
        containerLog.notice("handleRemoteNotificationWake: entered")
        guard pairingStore.isPaired else {
            containerLog.warning("handleRemoteNotificationWake: BLOCKED — not paired")
            return
        }
        guard await sessionStore.currentAccessToken() != nil else {
            containerLog.warning("handleRemoteNotificationWake: BLOCKED — no access token")
            return
        }

        // A push that woke us almost always means a run finished server-side;
        // reconcile so the reply is fetched and the completion notification
        // can fire.
        await chatStore.reconcilePendingRuns()

        await permissionsStore.reloadCapabilities()
        await hostStore.refresh()
        lastKnownHostOnline = hostStore.isHostOnline
        await registerStoredPushTokenIfNeeded()
        await sensorUploadService?.handleAppDidBecomeActive()
        talkStore.handleAppDidBecomeActive()
        await talkStore.refreshReadiness()
        reconcileLiveActivities()
        updateWidgetData()
    }

    func handleSystemLaunch() async {
        containerLog.notice("handleSystemLaunch: entered")
        guard pairingStore.isPaired else {
            containerLog.warning("handleSystemLaunch: BLOCKED — not paired")
            return
        }
        guard await sessionStore.currentAccessToken() != nil else {
            containerLog.warning("handleSystemLaunch: BLOCKED — no access token")
            return
        }
        containerLog.notice("handleSystemLaunch: guards passed, starting sensor service")

        sensorUploadService?.start()
        await sensorUploadService?.handleSystemLaunch()
        await registerStoredPushTokenIfNeeded()
        await talkStore.refreshReadiness()
        reconcileLiveActivities()
        await reportAppStateIfNeeded("foreground")
    }

    private func handlePairingActivated() async {
        isInitialized = false
        chatStore.reset()
        inboxStore.reset()
        await initialize()

        // Start sensor data pipeline
        sensorUploadService?.start()
        await talkStore.refreshReadiness()
    }

    /// The push-token pipeline has two independent stages, and conflating them
    /// produced contradictory Settings readouts (Notifications vs Diagnostics).
    /// This is the single source of truth both screens render from:
    ///   1. iOS issues an APNs device token (requires the aps-environment
    ///      entitlement; cached under `apnsTokenDefaultsKey` when delivered).
    ///   2. The relay accepts that token via POST push/register
    ///      (`sessionStore.state.pushTokenRegistered`).
    enum PushTokenPipelineState {
        /// iOS has not delivered an APNs device token on this install.
        case notIssued
        /// A token is held locally but the relay registration is unconfirmed.
        case awaitingRelay
        /// The relay has confirmed the push registration.
        case registered
    }

    var pushTokenPipelineState: PushTokenPipelineState {
        if sessionStore.state.pushTokenRegistered { return .registered }
        return cachedAPNsDeviceToken == nil ? .notIssued : .awaitingRelay
    }

    /// The APNs device token most recently delivered by iOS, if any.
    var cachedAPNsDeviceToken: String? {
        guard let token = UserDefaults.standard.string(forKey: Self.apnsTokenDefaultsKey),
              !token.isEmpty else { return nil }
        return token
    }

    /// Registers the APNs device token with the relay so it can send silent push notifications.
    func registerPushTokenIfNeeded(_ token: String) async {
        guard pairingStore.isPaired,
              let apiClient,
              let notificationService
        else { return }

        // Respect the user's in-app notifications toggle.
        // If disabled, deactivate any existing registration on the relay
        // so the user actually stops receiving pushes.
        guard settingsStore.settings.notificationsEnabled else {
            // Always attempt deactivation — the relay may have an active
            // registration from a previous session even if the local flag is false.
            await deactivatePushRegistration()
            await notificationService.markPushTokenRegistered(false)
            sessionStore.state.pushTokenRegistered = false
            return
        }

        let normalizedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedToken.isEmpty else { return }

        await notificationService.updatePushToken(normalizedToken)

        guard let accessToken = await sessionStore.currentAccessToken() else {
            containerLog.notice("registerPushToken: no relay access token — registration deferred")
            await notificationService.markPushTokenRegistered(false)
            sessionStore.state.pushTokenRegistered = false
            return
        }

        if notificationService.isPushTokenRegistered,
           notificationService.currentPushToken == normalizedToken {
            sessionStore.state.pushTokenRegistered = true
            return
        }

        guard let deviceID = sessionStore.state.deviceID else {
            containerLog.notice("registerPushToken: no deviceID in session state — registration deferred")
            await notificationService.markPushTokenRegistered(false)
            sessionStore.state.pushTokenRegistered = false
            return
        }

        #if DEBUG
        let pushEnvironment = "development"
        #else
        let pushEnvironment = "production"
        #endif

        struct PushRegisterBody: Encodable {
            let deviceId: String
            let apnsToken: String
            let pushEnvironment: String
            let bundleId: String
        }

        let body = PushRegisterBody(
            deviceId: deviceID.uuidString.lowercased(),
            apnsToken: normalizedToken,
            pushEnvironment: pushEnvironment,
            bundleId: Bundle.main.bundleIdentifier ?? "io.github.eulric90.talaria"
        )

        struct PushRegisterResponse: Decodable {
            let data: PushData?
            struct PushData: Decodable { let registered: Bool }
        }

        do {
            let _: PushRegisterResponse = try await apiClient.post(
                path: "push/register",
                body: body,
                accessToken: accessToken
            )
            containerLog.notice("registerPushToken: relay accepted push registration")
            await notificationService.markPushTokenRegistered(true)
            sessionStore.state.pushTokenRegistered = true
        } catch {
            // Non-critical — token will be retried on next app launch
            containerLog.notice("registerPushToken: relay push/register failed: \(error.localizedDescription, privacy: .public)")
            await notificationService.markPushTokenRegistered(false)
            sessionStore.state.pushTokenRegistered = false
        }
    }

    // MARK: - In-app permission revocation (#6 / OPEN_ITEMS #23)
    //
    // The app can't rescind an iOS grant, so in-app revoke means durably
    // stopping Talaria's USE of it: collection halts immediately, and the
    // persisted UserSettings flag keeps SensorUploadService.start() from
    // resurrecting it on the next launch. Camera/Photos stay deep-link-only.

    /// Revoke (`false`) or restore (`true`) the app's HealthKit use.
    func setHealthCollectionEnabled(_ enabled: Bool) async {
        settingsStore.settings.healthCollectionEnabled = enabled
        if enabled {
            restartSensorPipelineIfPaired()
        } else {
            await sensorUploadService?.disableHealthCollection()
        }
        await permissionsStore.reloadCapabilities()
    }

    /// Revoke (`false`) or restore (`true`) the app's location use. Revoking
    /// also resets the sync preference to foreground-only so a later
    /// re-enable doesn't silently resume background sync.
    func setLocationCollectionEnabled(_ enabled: Bool) async {
        settingsStore.settings.locationCollectionEnabled = enabled
        if enabled {
            restartSensorPipelineIfPaired()
        } else {
            sensorUploadService?.disableLocationCollection()
            settingsStore.settings.locationSyncPreference = .foregroundOnly
            permissionsStore.updateLocationSyncPreference(.foregroundOnly)
        }
        await permissionsStore.reloadCapabilities()
    }

    /// Revoke (`false`) or restore (`true`) push notifications. The existing
    /// register path deactivates the relay registration when the flag is off
    /// and re-registers the cached APNs token when it's on.
    func setNotificationsEnabled(_ enabled: Bool) async {
        settingsStore.settings.notificationsEnabled = enabled
        await registerPushTokenIfNeeded(cachedAPNsDeviceToken ?? "")
        await permissionsStore.reloadCapabilities()
    }

    /// Re-enabling a sensor rides the normal start() wiring, which is gated
    /// on the collection flags — a stop/start rebuilds exactly the enabled set.
    private func restartSensorPipelineIfPaired() {
        guard pairingStore.isPaired else { return }
        sensorUploadService?.stop()
        sensorUploadService?.start()
    }

    /// Tells the relay to deactivate push registrations for this device.
    private func deactivatePushRegistration() async {
        guard let apiClient,
              let accessToken = await sessionStore.currentAccessToken() else { return }

        struct DeactivateResponse: Decodable {
            let deactivated: Bool?
        }

        _ = try? await apiClient.post(
            path: "push/deactivate",
            accessToken: accessToken
        ) as DeactivateResponse
    }

    private func registerStoredPushTokenIfNeeded() async {
        guard let storedToken = UserDefaults.standard.string(forKey: Self.apnsTokenDefaultsKey) else {
            return
        }
        await registerPushTokenIfNeeded(storedToken)
    }

    // MARK: - Run-completion push watch (#38)
    //
    // Chat rides the direct :8642 path, so the relay never sees a run happen.
    // These calls are the bridge: on detach the app names the session it
    // walked away from, the relay polls the gateway's messages endpoint, and
    // an APNs alert (payload `session_id`) fires when the reply lands. All
    // best-effort — a failed watch just means no push, and the existing
    // foreground reconcile still recovers the reply.

    /// Asks the relay to watch the currently pending run, if there is one.
    /// Called on the background transition; the stream-detach callback
    /// (`onRunDetached`) covers the lock-mid-stream case where the scene
    /// phase change has already passed.
    func watchPendingRunIfNeeded() async {
        guard let sessionId = chatStore.pendingRunSessionId else { return }
        await postPushWatch(sessionId: sessionId)
    }

    func postPushWatch(sessionId: String) async {
        guard settingsStore.settings.notificationsEnabled,
              sessionStore.state.pushTokenRegistered,
              let apiClient,
              let accessToken = await sessionStore.currentAccessToken()
        else { return }

        struct WatchBody: Encodable { let sessionId: String }
        struct WatchResponse: Decodable {}

        do {
            let _: WatchResponse = try await apiClient.post(
                path: "push/watch",
                body: WatchBody(sessionId: sessionId),
                accessToken: accessToken
            )
            containerLog.notice("postPushWatch: relay watching session for completion push")
        } catch {
            containerLog.notice("postPushWatch: failed (no completion push this run): \(error.localizedDescription, privacy: .public)")
        }
    }

    func cancelPushWatch(sessionId: String) async {
        guard let apiClient,
              let accessToken = await sessionStore.currentAccessToken() else { return }

        struct CancelBody: Encodable { let sessionId: String }
        struct CancelResponse: Decodable {}

        _ = try? await apiClient.post(
            path: "push/watch/cancel",
            body: CancelBody(sessionId: sessionId),
            accessToken: accessToken
        ) as CancelResponse
    }

    /// Fetches the dynamic slash command catalog from the connected Hermes host.
    /// Merges built-in commands, gateway commands, skills, and personality options.
    func refreshCommandCatalog(force: Bool = false) async {
        if !force,
           let lastCommandCatalogRefreshAt,
           Date().timeIntervalSince(lastCommandCatalogRefreshAt) < Self.commandCatalogRefreshInterval {
            return
        }

        guard let token = await sessionStore.currentAccessToken(),
              let client = apiClient else { return }

        struct CatalogResponse: Decodable {
            let commands: [RemoteCommand]?
            let skills: [RemoteSkill]?
            let personalities: [RemotePersonality]?
            let quickCommands: [RemoteQuickCommand]?
            let activeModel: ActiveModel?

            struct RemoteCommand: Decodable {
                let name: String
                let description: String
                let category: String?
                let args: String?
            }
            struct RemoteSkill: Decodable {
                let name: String
                let description: String
            }
            struct RemotePersonality: Decodable {
                let name: String
                let description: String
            }
            struct RemoteQuickCommand: Decodable {
                let name: String
                let description: String
            }
            struct ActiveModel: Decodable {
                let name: String
                let provider: String?
                let contextWindow: Int?
            }
        }

        do {
            let response: CatalogResponse = try await client.get(
                path: "commands",
                accessToken: token
            )

            var catalog = SlashCommand.localCommands
            var catalogIDs = Set(catalog.map(\.id))
            let remoteCommands = response.commands ?? []
            let skills = response.skills ?? []
            let personalities = response.personalities ?? []
            let quickCommands = response.quickCommands ?? []

            // Add remote built-in commands (skip any that overlap with local)
            for cmd in remoteCommands {
                let command = SlashCommand.fromRemote(
                    name: cmd.name,
                    description: cmd.description,
                    category: cmd.category ?? "Agent",
                    args: cmd.args
                )
                if catalogIDs.insert(command.id).inserted {
                    catalog.append(command)
                }
            }

            // Add skill commands
            for skill in skills {
                let command = SlashCommand.fromSkill(name: skill.name, description: skill.description)
                if catalogIDs.insert(command.id).inserted {
                    catalog.append(command)
                }
            }

            // `/personality <name>` suggestions only appear once the user starts
            // typing `/personality`, keeping the top-level dropdown manageable.
            for personality in personalities {
                let command = SlashCommand.fromPersonality(
                    name: personality.name,
                    description: personality.description
                )
                if catalogIDs.insert(command.id).inserted {
                    catalog.append(command)
                }
            }

            // Hermes docs say quick commands resolve at dispatch time and are not
            // included in built-in autocomplete tables, but we still track them so
            // typed commands can be considered part of the known catalog.
            for quickCommand in quickCommands {
                let command = SlashCommand.fromQuickCommand(
                    name: quickCommand.name,
                    description: quickCommand.description
                )
                if catalogIDs.insert(command.id).inserted {
                    catalog.append(command)
                }
            }

            if remoteCommands.isEmpty && skills.isEmpty && personalities.isEmpty && quickCommands.isEmpty {
                chatStore.resetCommandCatalog()
            } else {
                chatStore.replaceCommandCatalog(
                    catalog,
                    activeModel: response.activeModel?.name,
                    contextWindow: response.activeModel?.contextWindow
                )
                lastCommandCatalogRefreshAt = .now
            }
        } catch {
            // Fallback to built-in list — catalog is a nice-to-have. Keep the
            // active model + Hermes-reported context window: the catalog rides
            // the relay, and a transient fetch failure must not demote the CTX
            // denominator to the nominal client-side table (#4).
            chatStore.restoreBuiltInCatalog()
        }
    }

    /// Best-effort seed for the model chip label. Uses the shim's cached model
    /// list (no refresh — fast) and extracts the `model` field (the persistent
    /// default id). Only called when the command catalog didn't supply one.
    private func seedActiveModelFromShim() async {
        do {
            let options = try await modelsShimClient.fetchModels(refresh: false)
            if let currentModel = options.model, !currentModel.isEmpty {
                chatStore.replaceCommandCatalog(
                    chatStore.commandCatalog,
                    activeModel: currentModel
                )
                containerLog.verbose("seedActiveModelFromShim: seeded '\(currentModel)'")
            }
        } catch {
            // Shim unreachable / not configured — chip will show fallback ("HERMES")
            containerLog.notice("seedActiveModelFromShim: shim unavailable — \(error.localizedDescription, privacy: .public)")
        }
    }

    func reportAppStateIfNeeded(_ state: String) async {
        guard pairingStore.isPaired, let apiClient, let accessToken = await sessionStore.currentAccessToken() else {
            return
        }

        struct AppStateBody: Encodable {
            let state: String
        }

        struct AppStateResponse: Decodable {}

        _ = try? await apiClient.post(
            path: "device/app-state",
            body: AppStateBody(state: state),
            accessToken: accessToken
        ) as AppStateResponse
    }

    /// Snapshots current app state into the App Group shared container
    /// so Home Screen widgets and CarPlay widgets can display it.
    func updateWidgetData() {
        let lastMessage = chatStore.conversation?.messages.last
        var data = SharedWidgetDataStore.read()
        data.hostName = hostStore.currentHost?.resolvedDisplayName
        data.hostOnline = hostStore.isHostOnline
        data.voiceSessionActive = talkStore.isSessionActive
        data.updatedAt = .now
        // Appearance snapshot for "Match App" widget themes. Uses the effective
        // theme so automatic (seasonal) mode carries into widgets too (issue #24).
        data.appearanceTheme = settingsStore.settings.effectiveAppearanceTheme().rawValue
        data.appearanceAccent = settingsStore.settings.appearanceAccent.rawValue
        if let msg = lastMessage {
            data.lastMessagePreview = String(msg.content.prefix(120))
            data.lastMessageSummary = HermesWidgetData.summarize(msg.content)
            data.lastMessageSender = msg.sender.rawValue
            data.lastMessageAt = msg.timestamp
        }
        SharedWidgetDataStore.write(data)
    }

    private func handlePairingRemoved() async {
        isInitialized = false
        await talkStore.endSessionIfNeeded()
        talkStore.reset()
        sensorUploadService?.stop()
        sensorUploadService?.resetOutbox()
        router.selectedTab = .chat
        router.activeSheet = nil
        router.resetAll()
        chatStore.reset()
        inboxStore.reset()
        hostStore.reset()
        lastKnownHostOnline = false
        lastCommandCatalogRefreshAt = nil
        LiveActivityService.endAllActivities()
        SharedWidgetDataStore.write(.empty)
    }

    private func reconcileLiveActivities() {
        if talkStore.isSessionActive || chatStore.isStreaming {
            return
        }
        LiveActivityService.endAllActivities()
    }

    // MARK: - Hermes Sessions API key

    /// Persists the Hermes API server key in the Keychain and updates the
    /// in-memory copy that the chat client reads on each request.
    func saveHermesAPIKey(_ value: String) async {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        hermesAPIKey = trimmed
        chatAPIKeyBox?.value = trimmed
        guard let secureStore else { return }
        if trimmed.isEmpty {
            await secureStore.delete(key: Self.hermesAPIKeyKeychainKey)
        } else {
            await secureStore.store(key: Self.hermesAPIKeyKeychainKey, value: trimmed)
        }
    }

    fileprivate var chatAPIKeyBox: MutableHermesAPIKeyBox? {
        get { _chatAPIKeyBox }
        set { _chatAPIKeyBox = newValue }
    }

    // MARK: - Models shim token

    /// Persists the models-shim bearer token in the Keychain and updates the
    /// in-memory copy that `ModelsShimClient` reads on each request.
    func saveModelsShimToken(_ value: String) async {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        modelsShimToken = trimmed
        shimTokenBox?.value = trimmed
        guard let secureStore else { return }
        if trimmed.isEmpty {
            await secureStore.delete(key: Self.modelsShimTokenKeychainKey)
        } else {
            await secureStore.store(key: Self.modelsShimTokenKeychainKey, value: trimmed)
        }
    }

    fileprivate var shimTokenBox: MutableShimTokenBox? {
        get { _shimTokenBox }
        set { _shimTokenBox = newValue }
    }
}

/// Reference-typed holder so the chat client's @MainActor closure captures by
/// reference. The AppContainer rewrites `value` whenever the user updates the
/// API key in Settings, and the next request picks it up without recreating
/// the client.
@MainActor
final class MutableHermesAPIKeyBox {
    var value: String = ""
}
