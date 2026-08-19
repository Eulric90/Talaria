import CoreLocation
import Foundation
@preconcurrency import MapKit
import os

private let sensorLog = Logger(subsystem: "io.github.eulric90.talaria", category: "SensorUpload")

struct SensorOutboxState: Codable, Hashable, Sendable {
    struct PendingLocation: Codable, Hashable, Sendable {
        let latitude: Double
        let longitude: Double
        let altitude: Double?
        let accuracy: Double
        let recordedAt: Date
    }

    struct PendingHealthSample: Codable, Hashable, Sendable {
        let metric: String
        let value: Double
        let unit: String
        let startAt: Date
        let endAt: Date?

        private static let windowedMetrics: Set<String> = [
            "steps",
            "active_calories",
            "distance_walking",
            "workout_minutes",
            "stand_hours",
            "sleep_duration",
        ]

        var dedupeKey: String {
            if Self.windowedMetrics.contains(metric) {
                return "\(metric)|\(unit)|\(startAt.timeIntervalSince1970)"
            }

            return [
                metric,
                unit,
                String(startAt.timeIntervalSince1970),
                String(endAt?.timeIntervalSince1970 ?? 0)
            ].joined(separator: "|")
        }
    }

    var pendingLocation: PendingLocation?
    var pendingHealthSamples: [PendingHealthSample] = []

    var isEmpty: Bool {
        pendingLocation == nil && pendingHealthSamples.isEmpty
    }

    mutating func enqueue(location update: LocationUpdate) {
        pendingLocation = PendingLocation(
            latitude: update.latitude,
            longitude: update.longitude,
            altitude: update.altitude,
            accuracy: update.accuracy,
            recordedAt: update.timestamp
        )
    }

    mutating func enqueue(healthSamples: [HealthSnapshot.Sample]) {
        for sample in healthSamples {
            let pending = PendingHealthSample(
                metric: sample.metric,
                value: sample.value,
                unit: sample.unit,
                startAt: sample.startAt,
                endAt: sample.endAt
            )
            if let index = pendingHealthSamples.firstIndex(where: { $0.dedupeKey == pending.dedupeKey }) {
                pendingHealthSamples[index] = pending
            } else {
                pendingHealthSamples.append(pending)
            }
        }
    }
}

/// Coordinates durable sensor uploads from the phone to the relay.
///
/// The relay only ACKs a sample once the connector has received and stored it,
/// so sensor state is persisted locally until a real delivery succeeds.
@MainActor
@Observable
final class SensorUploadService {
    private struct SensorLocationBody: Encodable {
        let latitude: Double
        let longitude: Double
        let altitude: Double?
        let accuracy: Double
        let address: String?
        let recordedAt: String
    }

    private struct SensorHealthBody: Encodable {
        struct Sample: Encodable {
            let metric: String
            let value: Double
            let unit: String
            let startAt: String
            let endAt: String?
        }

        let samples: [Sample]
    }

    private struct DeliveryResult: Decodable {
        let deliveryState: String

        var wasDelivered: Bool {
            deliveryState == "delivered"
        }
    }

    private enum HealthUploadOutcome {
        case delivered
        /// Relay accepted the payload but the connector was busy (202 "retry")
        /// — the same chunk should be re-sent after a backoff.
        case retry
        /// Permanent payload rejection (relay 400/422): identical bytes can
        /// never deliver — the chunk carries at least one poison sample that
        /// must be isolated, not retried forever (#24a follow-up).
        case rejected(String)
        /// Transient failure (network / 5xx / failed token refresh) — the same
        /// payload may succeed later; keep the backlog.
        case failed
    }

    private enum LocationUploadOutcome {
        case delivered
        /// Relay accepted the payload but the connector was busy (202 "retry")
        /// — the same fix should be re-sent after a backoff.
        case retry
        /// Permanent payload rejection — this exact fix can never deliver.
        case rejected
        case failed
    }

    /// What a single authorized POST attempt resolved to, separating the
    /// can-never-succeed rejections from retry-worthy failures. Previously
    /// every non-401 failure collapsed into one undifferentiated nil, so a
    /// single 422 sample wedged the entire health outbox forever (#24a).
    private enum UploadAttempt {
        case response(DeliveryResult?)
        case rejected(String)
        case transientFailure
    }

    /// The relay hard-caps SensorHealthRequest.samples at 100
    /// (relay/app/schemas.py) — larger payloads 422 before any field check,
    /// so backlog drains must be chunked (#24a).
    private static let healthUploadChunkSize = 100
    /// How many consecutive connector-busy (202 "retry") responses to absorb
    /// per drain before giving up and leaving the rest for the next trigger.
    private static let maxHealthBusyRetries = 3
    /// How many consecutive connector-busy (202 "retry") responses to absorb
    /// for location uploads before falling through to health.
    private static let maxLocationBusyRetries = 2

    private let apiClient: RelayAPIClient
    private let accessTokenProvider: @MainActor () async -> String?
    private let accessTokenRefresher: @MainActor () async -> String?
    private let persistence: AppPersistenceStoreProtocol
    private let isPairedProvider: @MainActor () -> Bool
    // In-app revoke gates (#6): when false, start() must not wire or (re)start
    // that sensor — otherwise the launch-time health re-assert / location
    // startMonitoring resurrects a collection the user revoked.
    private let isHealthCollectionEnabled: @MainActor () -> Bool
    private let isLocationCollectionEnabled: @MainActor () -> Bool
    private let locationService: LiveLocationService
    private let healthService: LiveHealthService
    private let motionService: LiveMotionService?

    private var isActive = false
    private var isDraining = false
    private var outboxState: SensorOutboxState

    /// Most recent drain attempt outcome (for the #15 sensor diagnostics panel).
    private(set) var lastDrainSummary: String?
    private(set) var lastDrainAt: Date?

    private let iso8601Formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init(
        apiClient: RelayAPIClient,
        accessTokenProvider: @escaping @MainActor () async -> String?,
        accessTokenRefresher: @escaping @MainActor () async -> String? = { nil },
        persistence: AppPersistenceStoreProtocol,
        isPairedProvider: @escaping @MainActor () -> Bool,
        isHealthCollectionEnabled: @escaping @MainActor () -> Bool = { true },
        isLocationCollectionEnabled: @escaping @MainActor () -> Bool = { true },
        locationService: LiveLocationService,
        healthService: LiveHealthService,
        motionService: LiveMotionService? = nil
    ) {
        self.apiClient = apiClient
        self.accessTokenProvider = accessTokenProvider
        self.accessTokenRefresher = accessTokenRefresher
        self.persistence = persistence
        self.isPairedProvider = isPairedProvider
        self.isHealthCollectionEnabled = isHealthCollectionEnabled
        self.isLocationCollectionEnabled = isLocationCollectionEnabled
        self.locationService = locationService
        self.healthService = healthService
        self.motionService = motionService
        self.outboxState = persistence.loadSensorOutboxState()
    }

    // MARK: - Diagnostics surface (#15)

    /// Read-only snapshot of the sensor pipeline's internal state for the in-app
    /// diagnostics panel. Computed from observable state, so a SwiftUI view that
    /// reads it updates as the pipeline changes.
    struct SensorDiagnostics {
        let isActive: Bool
        let isPaired: Bool
        let pendingLocation: PendingLocationInfo?
        let pendingHealthCount: Int
        let lastDrainSummary: String?
        let lastDrainAt: Date?
        let locationAuthorization: LocationAuthorizationLevel
        let locationAccuracyLabel: String
        let healthAuthorization: PermissionStatus
        let motionAuthorization: PermissionStatus

        struct PendingLocationInfo {
            let latitude: Double
            let longitude: Double
            let recordedAt: Date
        }
    }

    var sensorDiagnostics: SensorDiagnostics {
        SensorDiagnostics(
            isActive: isActive,
            isPaired: isPairedProvider(),
            pendingLocation: outboxState.pendingLocation.map {
                .init(latitude: $0.latitude, longitude: $0.longitude, recordedAt: $0.recordedAt)
            },
            pendingHealthCount: outboxState.pendingHealthSamples.count,
            lastDrainSummary: lastDrainSummary,
            lastDrainAt: lastDrainAt,
            locationAuthorization: locationService.authorizationLevel,
            locationAccuracyLabel: locationService.accuracyLevel.displayLabel,
            healthAuthorization: healthService.authorizationStatus,
            motionAuthorization: motionService?.authorizationStatus ?? .unsupported
        )
    }

    /// Whether a non-empty access token is currently retrievable (async).
    func hasValidAccessToken() async -> Bool {
        let token = await accessTokenProvider()
        return token?.isEmpty == false
    }

    private func recordDrain(_ summary: String) {
        lastDrainSummary = summary
        lastDrainAt = Date()
    }

    func start() {
        guard !isActive else {
            sensorLog.notice("start() skipped — already active")
            return
        }
        isActive = true
        outboxState = persistence.loadSensorOutboxState()
        sensorLog.notice("start() — activating sensor pipeline. Outbox: loc=\(self.outboxState.pendingLocation != nil), health=\(self.outboxState.pendingHealthSamples.count)")

        if isLocationCollectionEnabled() {
            locationService.onLocationUpdate = { [weak self] update in
                guard let self else { return }
                Task { @MainActor in
                    sensorLog.notice("📍 location update: (\(update.latitude), \(update.longitude)) accuracy=\(update.accuracy)")
                    self.outboxState.enqueue(location: update)
                    self.persistOutboxState()
                    await self.drainOutboxIfPossible()
                }
            }
        } else {
            sensorLog.notice("start() — location collection disabled in-app (#6); not wiring")
        }

        if isHealthCollectionEnabled() {
            healthService.onHealthUpdate = { [weak self] changedIdentifiers in
                guard let self else { return }
                Task { @MainActor in
                    sensorLog.notice("💓 health update for: \(changedIdentifiers.joined(separator: ", "), privacy: .public)")
                    await self.captureHealthSnapshot(changedIdentifiers: changedIdentifiers)
                }
            }
        } else {
            sensorLog.notice("start() — health collection disabled in-app (#6); not wiring")
        }

        motionService?.onActivityUpdate = { [weak self] activityCode in
            guard let self else { return }
            Task { @MainActor in
                sensorLog.notice("🏃 activity update: code=\(activityCode.rawValue)")
                let now = Date()
                let sample = HealthSnapshot.Sample(
                    metric: "user_activity",
                    value: Double(activityCode.rawValue),
                    unit: "activity_code",
                    startAt: now,
                    endAt: nil
                )
                self.outboxState.enqueue(healthSamples: [sample])
                self.persistOutboxState()
                await self.drainOutboxIfPossible()
            }
        }

        if isLocationCollectionEnabled() {
            locationService.startMonitoring()
        }
        motionService?.startMonitoring()

        // Health authorization is in-memory only: LiveHealthService resets it to
        // .notDetermined on every launch, and Apple's read-privacy model means it
        // cannot be recovered via authorizationStatus(for:) (read status stays hidden).
        // collectSnapshot() hard-gates on .authorized, so without re-asserting here,
        // every snapshot returns nil after a relaunch even when the user already
        // granted access. Re-request on each start() to restore .authorized AND
        // re-enable background delivery. For read-only types iOS shows the system
        // sheet at most once per install, so repeat calls after the first decision
        // are silent — no nagging, even on denial.
        if isHealthCollectionEnabled() {
            Task { [weak self] in
                guard let self else { return }
                let status = await self.healthService.requestAuthorization()
                self.healthService.startMonitoring()
                sensorLog.notice("start() — health auth re-asserted: \(String(describing: status), privacy: .public)")
                await self.captureHealthSnapshot(forceFullRefresh: true)
            }
        }

        sensorLog.notice("start() — monitoring started (loc/motion; health pending re-auth). loc auth=\(String(describing: self.locationService.authorizationStatus), privacy: .public)")
    }

    func stop() {
        isActive = false
        isDraining = false
        locationService.onLocationUpdate = nil
        healthService.onHealthUpdate = nil
        motionService?.onActivityUpdate = nil
        locationService.stopMonitoring()
        healthService.stopMonitoring()
        motionService?.stopMonitoring()
    }

    func resetOutbox() {
        outboxState = SensorOutboxState()
        persistence.clearSensorOutboxState()
    }

    // MARK: - In-app revoke (#6 / OPEN_ITEMS #23)

    /// Halts HealthKit use now: observers stopped, background delivery
    /// disabled, queued samples dropped. The caller persists the
    /// `healthCollectionEnabled` flag that keeps start() from re-asserting.
    func disableHealthCollection() async {
        healthService.onHealthUpdate = nil
        healthService.stopMonitoring()
        await healthService.disableBackgroundDelivery()
        outboxState.pendingHealthSamples.removeAll()
        persistOutboxState()
        sensorLog.notice("health collection revoked in-app — observers stopped, background delivery off, outbox cleared")
    }

    /// Halts location use now: monitoring sessions invalidated, queued fix
    /// dropped. The caller persists the `locationCollectionEnabled` flag.
    func disableLocationCollection() {
        locationService.onLocationUpdate = nil
        locationService.stopMonitoring()
        outboxState.pendingLocation = nil
        persistOutboxState()
        sensorLog.notice("location collection revoked in-app — monitoring stopped, pending fix dropped")
    }

    func handleAppDidBecomeActive() async {
        guard isActive else {
            sensorLog.warning("handleAppDidBecomeActive: service not active — skipping")
            return
        }
        sensorLog.notice("handleAppDidBecomeActive: requesting location + full health refresh")

        if isLocationCollectionEnabled() {
            locationService.requestSingleLocation()
        }
        await captureHealthSnapshot(forceFullRefresh: true)
        await drainOutboxIfPossible()
    }

    func handleSystemLaunch() async {
        guard isActive else {
            sensorLog.warning("handleSystemLaunch: service not active — skipping")
            return
        }
        sensorLog.notice("handleSystemLaunch: capturing health + draining outbox")

        await captureHealthSnapshot()
        await drainOutboxIfPossible()
    }

    private func captureHealthSnapshot(
        forceFullRefresh: Bool = false,
        changedIdentifiers: Set<String>? = nil
    ) async {
        guard isHealthCollectionEnabled() else { return }
        guard
            let snapshot = await healthService.collectSnapshot(
                forceFullRefresh: forceFullRefresh,
                changedIdentifiers: changedIdentifiers
            )
        else {
            sensorLog.notice("captureHealth: collectSnapshot returned nil (auth=\(String(describing: self.healthService.authorizationStatus), privacy: .public))")
            return
        }
        guard !snapshot.samples.isEmpty else {
            sensorLog.notice("captureHealth: snapshot empty (no changed metrics)")
            return
        }
        sensorLog.notice("captureHealth: got \(snapshot.samples.count) samples — \(snapshot.samples.map(\.metric).joined(separator: ", "))")
        outboxState.enqueue(healthSamples: snapshot.samples)
        SharedWidgetDataStore.updateHealthMetrics(from: snapshot.samples)
        persistOutboxState()
        await drainOutboxIfPossible()
    }

    private func drainOutboxIfPossible() async {
        guard !isDraining else {
            sensorLog.verbose("drain: skipped — already draining")
            return
        }
        guard isActive else {
            sensorLog.warning("drain: BLOCKED — service not active (start() never called or stop()'d)")
            recordDrain("Blocked: pipeline inactive")
            return
        }
        guard isPairedProvider() else {
            sensorLog.warning("drain: BLOCKED — isPairedProvider() returned false")
            recordDrain("Blocked: not paired")
            return
        }

        guard let accessToken = await accessTokenProvider(), !accessToken.isEmpty else {
            sensorLog.warning("drain: BLOCKED — accessTokenProvider() returned nil/empty")
            recordDrain("Blocked: no access token")
            return
        }
        _ = accessToken

        sensorLog.notice("drain: starting. Outbox: loc=\(self.outboxState.pendingLocation != nil), health=\(self.outboxState.pendingHealthSamples.count)")

        isDraining = true
        defer { isDraining = false }

        var healthBusyRetries = 0
        var locationBusyRetries = 0

        // ── Location phase ──────────────────────────────────────────
        // Drained independently of health — a location failure (transient
        // or retry-exhausted) falls through to health instead of wedging
        // the entire outbox drain (#27).
        while isActive && isPairedProvider(), let pendingLocation = outboxState.pendingLocation {
            let outcome = await uploadLocation(pendingLocation)
            sensorLog.notice("drain: location upload → \(String(describing: outcome), privacy: .public)")
            switch outcome {
            case .delivered:
                locationBusyRetries = 0
                clearPendingLocationIfUnchanged(pendingLocation)
            case .rejected:
                locationBusyRetries = 0
                // Permanent rejection: identical bytes can never deliver,
                // and a fresh fix supersedes this one — drop, don't wedge
                // the drain (health waits behind location).
                sensorLog.error("drain: location fix permanently rejected — dropped")
                clearPendingLocationIfUnchanged(pendingLocation)
            case .retry:
                guard locationBusyRetries < Self.maxLocationBusyRetries else {
                    sensorLog.notice("drain: location retries exhausted — deferring to next trigger")
                    recordDrain("Location upload busy — retries exhausted")
                    break
                }
                locationBusyRetries += 1
                let delay = Double(1 << locationBusyRetries)
                sensorLog.notice("drain: location connector busy — retrying in \(delay, privacy: .public)s (attempt \(locationBusyRetries)/\(Self.maxLocationBusyRetries))")
                try? await Task.sleep(for: .seconds(delay))
                continue
            case .failed:
                recordDrain("Location upload failed")
                break
            }
            break  // delivered, rejected, retry-exhausted, or failed — exit location phase
        }

        // ── Health phase ────────────────────────────────────────────
        // Independent of location — runs even when location failed above
        // (#27: location failure no longer starves health).
        while isActive && isPairedProvider(), !outboxState.pendingHealthSamples.isEmpty {
            // Chunk to the relay's 100-sample cap and send sequentially —
            // the connector handles one payload at a time (#24a).
            let chunk = Array(outboxState.pendingHealthSamples.prefix(Self.healthUploadChunkSize))
            let outcome = await uploadHealth(chunk)
            sensorLog.notice("drain: health chunk (\(chunk.count) of \(self.outboxState.pendingHealthSamples.count) pending) → \(String(describing: outcome), privacy: .public)")
            switch outcome {
            case .delivered:
                healthBusyRetries = 0
                outboxState.pendingHealthSamples.removeFirst(chunk.count)
                persistOutboxState()
                continue
            case .retry:
                // Connector busy — back off, then re-send the same chunk.
                guard healthBusyRetries < Self.maxHealthBusyRetries else { break }
                healthBusyRetries += 1
                let delay = Double(1 << healthBusyRetries)
                sensorLog.notice("drain: connector busy — retrying chunk in \(delay, privacy: .public)s (attempt \(healthBusyRetries)/\(Self.maxHealthBusyRetries))")
                try? await Task.sleep(for: .seconds(delay))
                continue
            case .rejected(let message):
                // Permanent 400/422: at least one sample in this chunk can
                // NEVER deliver. Binary-split to deliver the good samples
                // and drop the poison instead of retaining the whole
                // backlog while motion samples pile up behind it (#24a).
                sensorLog.error("drain: health chunk permanently rejected — \(message, privacy: .public); isolating poison sample(s)")
                recordDrain("Isolating rejected health sample(s)")
                guard await resolveRejectedChunk(size: chunk.count) else { break }
                continue
            case .failed:
                break
            }
        }
        sensorLog.notice("drain: finished. Outbox remaining: loc=\(self.outboxState.pendingLocation != nil), health=\(self.outboxState.pendingHealthSamples.count)")
        recordDrain(outboxState.isEmpty ? "Delivered · outbox clear" : "Partial · loc=\(outboxState.pendingLocation != nil ? 1 : 0), health=\(outboxState.pendingHealthSamples.count)")
    }

    private func persistOutboxState() {
        if outboxState.isEmpty {
            persistence.clearSensorOutboxState()
        } else {
            persistence.saveSensorOutboxState(outboxState)
        }
    }

    /// Clears the pending location ONLY when it is still the exact fix that
    /// was just uploaded/resolved. A fresh fix can arrive during the upload's
    /// await and land in `pendingLocation`; blindly nil-ing it afterwards
    /// silently discarded that newer fix (#24a follow-up, item 4). When a
    /// newer fix replaced it, it stays queued and the drain loop sends it next.
    private func clearPendingLocationIfUnchanged(_ uploaded: SensorOutboxState.PendingLocation) {
        if outboxState.pendingLocation == uploaded {
            outboxState.pendingLocation = nil
        }
        persistOutboxState()
    }

    /// Resolves a permanently rejected chunk from the FRONT of the health
    /// outbox by binary split: halves that deliver are removed, the rejection
    /// narrows to single samples, and each poison sample is dropped with its
    /// fields logged (#24a follow-up, items 2+3). Progress persists after
    /// every step, so an interruption never loses resolved work. Returns
    /// false on a transient failure — the drain stops and the remaining
    /// backlog re-attempts on the next trigger.
    private func resolveRejectedChunk(size: Int) async -> Bool {
        guard size > 0, !outboxState.pendingHealthSamples.isEmpty else { return true }

        if size == 1 {
            let poison = outboxState.pendingHealthSamples.removeFirst()
            sensorLog.error("drain: dropping poison health sample — metric=\(poison.metric, privacy: .public) value=\(poison.value, privacy: .public) unit=\(poison.unit, privacy: .public) startAt=\(poison.startAt.description, privacy: .public) endAt=\(poison.endAt?.description ?? "nil", privacy: .public)")
            persistOutboxState()
            return true
        }

        let firstHalf = size / 2
        for partSize in [firstHalf, size - firstHalf] {
            let part = Array(outboxState.pendingHealthSamples.prefix(partSize))
            guard !part.isEmpty else { continue }
            switch await uploadHealth(part) {
            case .delivered:
                outboxState.pendingHealthSamples.removeFirst(part.count)
                persistOutboxState()
            case .rejected:
                guard await resolveRejectedChunk(size: part.count) else { return false }
            case .retry, .failed:
                return false
            }
        }
        return true
    }

    private func uploadLocation(_ pending: SensorOutboxState.PendingLocation) async -> LocationUploadOutcome {
        // Reverse geocode to get a human-readable address
        let address = await reverseGeocode(latitude: pending.latitude, longitude: pending.longitude)

        let body = SensorLocationBody(
            latitude: pending.latitude,
            longitude: pending.longitude,
            altitude: pending.altitude,
            accuracy: pending.accuracy,
            address: address,
            recordedAt: iso8601Formatter.string(from: pending.recordedAt)
        )

        switch await performAuthorizedUpload(path: "device/sensor/location", body: body) {
        case .response(let result):
            guard let result else { return .failed }
            if result.wasDelivered { return .delivered }
            return result.deliveryState == "retry" ? .retry : .failed
        case .rejected:
            return .rejected
        case .transientFailure:
            return .failed
        }
    }

    private func reverseGeocode(latitude: Double, longitude: Double) async -> String? {
        let location = CLLocation(latitude: latitude, longitude: longitude)
        do {
            if #available(iOS 26.0, *) {
                guard let request = MKReverseGeocodingRequest(location: location) else {
                    return nil
                }
                let mapItems = try await request.mapItems
                guard let item = mapItems.first else { return nil }
                if let shortAddress = item.address?.shortAddress, !shortAddress.isEmpty {
                    return shortAddress
                }
                if let fullAddress = item.address?.fullAddress, !fullAddress.isEmpty {
                    return fullAddress
                }
                if let singleLine = item.addressRepresentations?.fullAddress(includingRegion: false, singleLine: true),
                   !singleLine.isEmpty {
                    return singleLine
                }
                return item.name
            } else {
                let placemarks = try await CLGeocoder().reverseGeocodeLocation(location)
                guard let place = placemarks.first else { return nil }
                let parts = [place.name, place.thoroughfare, place.locality, place.administrativeArea]
                    .compactMap { $0 }
                return parts.isEmpty ? nil : parts.joined(separator: ", ")
            }
        } catch {
            return nil
        }
    }

    private func uploadHealth(_ samples: [SensorOutboxState.PendingHealthSample]) async -> HealthUploadOutcome {
        let body = SensorHealthBody(
            samples: samples.map { sample in
                SensorHealthBody.Sample(
                    metric: sample.metric,
                    value: sample.value,
                    unit: sample.unit,
                    startAt: iso8601Formatter.string(from: sample.startAt),
                    endAt: sample.endAt.map { iso8601Formatter.string(from: $0) }
                )
            }
        )

        switch await performAuthorizedUpload(path: "device/sensor/health", body: body) {
        case .response(let result):
            guard let result else { return .failed }
            if result.wasDelivered { return .delivered }
            return result.deliveryState == "retry" ? .retry : .failed
        case .rejected(let message):
            return .rejected(message)
        case .transientFailure:
            return .failed
        }
    }

    /// One authorized POST, classified: a 401 gets one token-refresh retry; a
    /// relay 400/422 is a PERMANENT payload rejection (retrying identical
    /// bytes can never succeed); everything else — network, 5xx, failed
    /// refresh — is transient and keeps the backlog for the next drain (#24a).
    private func performAuthorizedUpload<Body: Encodable>(path: String, body: Body) async -> UploadAttempt {
        do {
            return .response(try await executeUpload(path: path, body: body, accessToken: await accessTokenProvider()))
        } catch RelayAPIClient.ClientError.unauthorized {
            sensorLog.warning("upload \(path): 401 unauthorized, attempting token refresh…")
            guard let refreshedToken = await accessTokenRefresher(), !refreshedToken.isEmpty else {
                sensorLog.error("upload \(path): token refresh failed/empty")
                return .transientFailure
            }
            do {
                return .response(try await executeUpload(path: path, body: body, accessToken: refreshedToken))
            } catch RelayAPIClient.ClientError.payloadRejected(let statusCode, let message) {
                sensorLog.error("upload \(path): permanent \(statusCode) rejection — \(message, privacy: .public)")
                return .rejected(message)
            } catch {
                sensorLog.error("upload \(path): error after refresh — \(error.localizedDescription)")
                return .transientFailure
            }
        } catch RelayAPIClient.ClientError.payloadRejected(let statusCode, let message) {
            sensorLog.error("upload \(path): permanent \(statusCode) rejection — \(message, privacy: .public)")
            return .rejected(message)
        } catch {
            sensorLog.error("upload \(path): error — \(error.localizedDescription)")
            return .transientFailure
        }
    }

    private func executeUpload<Body: Encodable>(path: String, body: Body, accessToken: String?) async throws -> DeliveryResult? {
        guard let accessToken, !accessToken.isEmpty else {
            sensorLog.warning("executeUpload \(path): no access token")
            return nil
        }
        let result: DeliveryResult = try await apiClient.post(
            path: path,
            body: body,
            accessToken: accessToken
        )
        sensorLog.notice("executeUpload \(path, privacy: .public): deliveryState=\(result.deliveryState, privacy: .public) wasDelivered=\(result.wasDelivered, privacy: .public)")
        return result
    }
}
