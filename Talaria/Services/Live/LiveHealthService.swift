import Foundation
import HealthKit
import os

private let healthLog = Logger(subsystem: "io.github.eulric90.talaria", category: "LiveHealth")

struct HealthSnapshot: Sendable {
    struct Sample: Sendable {
        let metric: String
        let value: Double
        let unit: String
        let startAt: Date
        let endAt: Date?
    }

    let samples: [Sample]
    let collectedAt: Date
}

@MainActor
@Observable
final class LiveHealthService: HealthServiceProtocol {
    internal struct SleepInterval: Sendable {
        let value: Int
        let startDate: Date
        let endDate: Date
    }

    private struct HealthMetricDescriptor {
        let metric: String
        let sampleType: HKSampleType
        let startDateProvider: () -> Date
        let builder: @MainActor (LiveHealthService, Date) async -> HealthSnapshot.Sample?
    }

    private struct AnchoredChangeResult {
        let didChange: Bool
        let newAnchor: HKQueryAnchor?
    }

    private(set) var authorizationStatus: PermissionStatus
    private(set) var backgroundDeliveryEnabled = false
    var onHealthUpdate: (@MainActor (Set<String>) -> Void)?

    private let store: HKHealthStore?
    private let persistence: (any AppPersistenceStoreProtocol)?
    private let metricDescriptors: [String: HealthMetricDescriptor]
    private var observerQueries: [HKObserverQuery] = []

    init(persistence: (any AppPersistenceStoreProtocol)? = nil) {
        self.persistence = persistence

        guard HKHealthStore.isHealthDataAvailable() else {
            self.store = nil
            self.metricDescriptors = [:]
            self.authorizationStatus = .unsupported
            return
        }

        let store = HKHealthStore()
        self.store = store
        self.metricDescriptors = LiveHealthService.makeMetricDescriptors()
        self.authorizationStatus = .notDetermined
    }

    func requestAuthorization() async -> PermissionStatus {
        guard let store else {
            authorizationStatus = .unsupported
            return .unsupported
        }

        do {
            try await store.requestAuthorization(
                toShare: [],
                read: Set(metricDescriptors.values.map { $0.sampleType as HKObjectType })
            )
            authorizationStatus = .authorized
            await configureBackgroundDeliveryIfNeeded()
        } catch {
            authorizationStatus = .denied
            backgroundDeliveryEnabled = false
        }

        return authorizationStatus
    }

    func refreshAuthorizationStatus() async {
        guard let store else {
            authorizationStatus = .unsupported
            return
        }

        // Apple's privacy model: authorizationStatus(for:) only works for
        // write (share) access. For read access, the system always returns
        // .notDetermined to prevent apps from learning what the user denied.
        // The correct check: attempt a sample query and see if data comes back.
        // If requestAuthorization was previously called, we trust that result.
        // See: https://developer.apple.com/documentation/healthkit/hkhealthstore/authorizationstatus(for:)
        let requestStatus = store.authorizationStatus(for: HKQuantityType(.stepCount))
        if requestStatus == .sharingDenied {
            // User explicitly denied write access — implies they saw the prompt
            // but we only care about read. Check if we got data previously.
            authorizationStatus = authorizationStatus == .authorized ? .authorized : .notDetermined
        } else {
            // If we previously got authorized via requestAuthorization, keep it.
            // Otherwise stay at current state — we can't distinguish denied from not-asked for read.
            if authorizationStatus != .authorized {
                authorizationStatus = .notDetermined
            }
        }
    }

    func startMonitoring() {
        guard let store, observerQueries.isEmpty else { return }

        for (identifier, descriptor) in metricDescriptors.sorted(by: { $0.key < $1.key }) {
            let query = HKObserverQuery(sampleType: descriptor.sampleType, predicate: nil) { [weak self] _, completionHandler, error in
                defer { completionHandler() }
                guard error == nil else { return }
                Task { @MainActor in
                    self?.onHealthUpdate?([identifier])
                }
            }
            observerQueries.append(query)
            store.execute(query)
        }

        if authorizationStatus == .authorized {
            Task { @MainActor in
                await configureBackgroundDeliveryIfNeeded()
            }
        }
    }

    func stopMonitoring() {
        guard let store else { return }
        for query in observerQueries {
            store.stop(query)
        }
        observerQueries.removeAll()
    }

    func collectSnapshot(
        forceFullRefresh: Bool = false,
        changedIdentifiers: Set<String>? = nil
    ) async -> HealthSnapshot? {
        guard store != nil else { return nil }
        guard authorizationStatus == .authorized else { return nil }

        let changedMetrics = await resolveChangedMetrics(
            forceFullRefresh: forceFullRefresh,
            requestedIdentifiers: changedIdentifiers
        )
        guard !changedMetrics.isEmpty else { return nil }

        let now = Date()
        var samples: [HealthSnapshot.Sample] = []
        var emptyMetrics: [String] = []

        for identifier in changedMetrics.sorted() {
            guard let descriptor = metricDescriptors[identifier] else { continue }
            let startDate = descriptor.startDateProvider()
            if let sample = await descriptor.builder(self, startDate) {
                samples.append(sample)
            } else {
                emptyMetrics.append(identifier)
            }
        }

        if !emptyMetrics.isEmpty {
            // The missing complement of SensorUpload's "got N samples" line:
            // which queried metrics had no HealthKit data in their window. #46
            // burned days on an observer-registration hypothesis because
            // nothing distinguished "never queried" from "queried, no data".
            healthLog.notice("collectSnapshot: no data for \(emptyMetrics.joined(separator: ", "), privacy: .public)")
        }

        guard !samples.isEmpty else { return nil }
        return HealthSnapshot(samples: samples, collectedAt: now)
    }

    // MARK: - Background Delivery

    /// In-app revoke support (#6): iOS can't rescind a HealthKit read grant,
    /// but the app can stop waking for new samples.
    func disableBackgroundDelivery() async {
        guard let store else { return }
        do {
            try await store.disableAllBackgroundDelivery()
            backgroundDeliveryEnabled = false
        } catch {
            // Leave the flag truthful — delivery may still be active.
        }
    }

    private func configureBackgroundDeliveryIfNeeded() async {
        guard let store, authorizationStatus == .authorized else { return }

        var allSucceeded = true
        for descriptor in metricDescriptors.values {
            do {
                try await store.enableBackgroundDelivery(
                    for: descriptor.sampleType,
                    frequency: .immediate
                )
            } catch {
                allSucceeded = false
            }
        }
        backgroundDeliveryEnabled = allSucceeded
    }

    // MARK: - Incremental Anchors

    private func resolveChangedMetrics(
        forceFullRefresh: Bool,
        requestedIdentifiers: Set<String>?
    ) async -> Set<String> {
        let identifiersToCheck: Set<String>
        if forceFullRefresh {
            identifiersToCheck = Set(metricDescriptors.keys)
        } else if let requestedIdentifiers, !requestedIdentifiers.isEmpty {
            identifiersToCheck = requestedIdentifiers.intersection(metricDescriptors.keys)
        } else {
            identifiersToCheck = Set(metricDescriptors.keys)
        }

        var changed: Set<String> = []
        for identifier in identifiersToCheck {
            guard let descriptor = metricDescriptors[identifier] else { continue }
            let startDate = descriptor.startDateProvider()
            let result = await fetchAnchoredChanges(
                for: identifier,
                sampleType: descriptor.sampleType,
                startDate: startDate
            )
            if forceFullRefresh || result.didChange {
                changed.insert(identifier)
            }
        }
        return changed
    }

    private func fetchAnchoredChanges(
        for identifier: String,
        sampleType: HKSampleType,
        startDate: Date
    ) async -> AnchoredChangeResult {
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: nil)
        let anchor = loadAnchor(for: identifier)

        return await withCheckedContinuation { continuation in
            let query = HKAnchoredObjectQuery(
                type: sampleType,
                predicate: predicate,
                anchor: anchor,
                limit: HKObjectQueryNoLimit
            ) { [weak self] _, sampleObjects, deletedObjects, newAnchor, _ in
                if let newAnchor {
                    Task { @MainActor in
                        self?.saveAnchor(newAnchor, for: identifier)
                    }
                }
                continuation.resume(
                    returning: AnchoredChangeResult(
                        didChange: !(sampleObjects ?? []).isEmpty || !(deletedObjects ?? []).isEmpty,
                        newAnchor: newAnchor
                    )
                )
            }
            store?.execute(query)
        }
    }

    private func loadAnchor(for identifier: String) -> HKQueryAnchor? {
        guard
            let data = persistence?.loadHealthQueryAnchorData(for: identifier),
            let anchor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
        else {
            return nil
        }
        return anchor
    }

    private func saveAnchor(_ anchor: HKQueryAnchor, for identifier: String) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true) else {
            return
        }
        persistence?.saveHealthQueryAnchorData(data, for: identifier)
    }

    // MARK: - Metric Queries

    private func queryCumulativeSum(
        _ identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        from startDate: Date,
        to endDate: Date
    ) async -> Double? {
        guard let quantityType = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate)

        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: quantityType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, result, _ in
                continuation.resume(returning: result?.sumQuantity()?.doubleValue(for: unit))
            }
            store?.execute(query)
        }
    }

    private func queryLatestSample(
        _ identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        from startDate: Date? = nil
    ) async -> (Double, Date)? {
        guard let quantityType = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let predicate = startDate.map { HKQuery.predicateForSamples(withStart: $0, end: nil) }

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: quantityType,
                predicate: predicate,
                limit: 1,
                sortDescriptors: [sort]
            ) { _, results, _ in
                guard let sample = results?.first as? HKQuantitySample else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(
                    returning: (
                        sample.quantity.doubleValue(for: unit),
                        sample.startDate
                    )
                )
            }
            store?.execute(query)
        }
    }

    nonisolated internal static func sleepBucketDay(
        for referenceDate: Date = Date(),
        calendar: Calendar = .current
    ) -> Date {
        calendar.startOfDay(for: referenceDate)
    }

    nonisolated internal static func aggregateSleepDuration(
        intervals: [SleepInterval],
        attributedTo bucketDay: Date,
        calendar: Calendar = .current
    ) -> Double? {
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: bucketDay) else {
            return nil
        }

        let asleepValues: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue,
        ]

        let totalSeconds = intervals
            .filter { asleepValues.contains($0.value) }
            .filter { $0.endDate >= bucketDay && $0.endDate < nextDay }
            .reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }

        let hours = totalSeconds / 3600.0
        return hours > 0 ? hours : nil
    }

    private static func makeMetricDescriptors() -> [String: HealthMetricDescriptor] {
        var descriptors: [String: HealthMetricDescriptor] = [:]

        if let steps = HKQuantityType.quantityType(forIdentifier: .stepCount) {
            descriptors["steps"] = HealthMetricDescriptor(
                metric: "steps",
                sampleType: steps,
                startDateProvider: { Calendar.current.startOfDay(for: Date()) },
                builder: { service, startDate in
                    guard
                        let value = await service.queryCumulativeSum(
                            .stepCount,
                            unit: .count(),
                            from: startDate,
                            to: Date()
                        )
                    else {
                        return nil
                    }
                    return .init(
                        metric: "steps",
                        value: value,
                        unit: "count",
                        startAt: startDate,
                        endAt: Date()
                    )
                }
            )
        }

        if let calories = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) {
            descriptors["active_calories"] = HealthMetricDescriptor(
                metric: "active_calories",
                sampleType: calories,
                startDateProvider: { Calendar.current.startOfDay(for: Date()) },
                builder: { service, startDate in
                    guard
                        let value = await service.queryCumulativeSum(
                            .activeEnergyBurned,
                            unit: .kilocalorie(),
                            from: startDate,
                            to: Date()
                        )
                    else {
                        return nil
                    }
                    return .init(
                        metric: "active_calories",
                        value: value,
                        unit: "kcal",
                        startAt: startDate,
                        endAt: Date()
                    )
                }
            )
        }

        if let distance = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning) {
            descriptors["distance_walking"] = HealthMetricDescriptor(
                metric: "distance_walking",
                sampleType: distance,
                startDateProvider: { Calendar.current.startOfDay(for: Date()) },
                builder: { service, startDate in
                    guard
                        let value = await service.queryCumulativeSum(
                            .distanceWalkingRunning,
                            unit: .meter(),
                            from: startDate,
                            to: Date()
                        )
                    else {
                        return nil
                    }
                    return .init(
                        metric: "distance_walking",
                        value: value,
                        unit: "meters",
                        startAt: startDate,
                        endAt: Date()
                    )
                }
            )
        }

        if let heartRate = HKQuantityType.quantityType(forIdentifier: .heartRate) {
            descriptors["heart_rate"] = HealthMetricDescriptor(
                metric: "heart_rate",
                sampleType: heartRate,
                startDateProvider: { Date().addingTimeInterval(-86_400) },
                builder: { service, startDate in
                    guard
                        let (value, date) = await service.queryLatestSample(
                            .heartRate,
                            unit: .count().unitDivided(by: .minute()),
                            from: startDate
                        )
                    else {
                        return nil
                    }
                    return .init(
                        metric: "heart_rate",
                        value: value,
                        unit: "bpm",
                        startAt: date,
                        endAt: nil
                    )
                }
            )
        }

        // Resting heart rate — latest sample in last 24h
        if let restingHR = HKQuantityType.quantityType(forIdentifier: .restingHeartRate) {
            descriptors["resting_heart_rate"] = HealthMetricDescriptor(
                metric: "resting_heart_rate",
                sampleType: restingHR,
                startDateProvider: { Date().addingTimeInterval(-86_400) },
                builder: { service, startDate in
                    guard let (value, date) = await service.queryLatestSample(
                        .restingHeartRate, unit: .count().unitDivided(by: .minute()), from: startDate
                    ) else { return nil }
                    return .init(metric: "resting_heart_rate", value: value, unit: "bpm", startAt: date, endAt: nil)
                }
            )
        }

        // Blood oxygen — latest sample in last 24h
        if let spo2 = HKQuantityType.quantityType(forIdentifier: .oxygenSaturation) {
            descriptors["blood_oxygen"] = HealthMetricDescriptor(
                metric: "blood_oxygen",
                sampleType: spo2,
                startDateProvider: { Date().addingTimeInterval(-86_400) },
                builder: { service, startDate in
                    guard let (value, date) = await service.queryLatestSample(
                        .oxygenSaturation, unit: .percent(), from: startDate
                    ) else { return nil }
                    return .init(metric: "blood_oxygen", value: value * 100, unit: "%", startAt: date, endAt: nil)
                }
            )
        }

        // Respiratory rate — latest sample in last 7 days. The watch measures
        // respiratory rate ONLY during tracked sleep, so the newest sample is
        // routinely a night (or several) old; the previous 24h floor made the
        // metric vanish whenever a capture ran more than a day after the last
        // tracked sleep (#46). Same window as body_mass — queryLatestSample
        // sorts descending with limit 1, so this still surfaces the freshest.
        if let respRate = HKQuantityType.quantityType(forIdentifier: .respiratoryRate) {
            descriptors["respiratory_rate"] = HealthMetricDescriptor(
                metric: "respiratory_rate",
                sampleType: respRate,
                startDateProvider: { Date().addingTimeInterval(-7 * 86_400) },
                builder: { service, startDate in
                    guard let (value, date) = await service.queryLatestSample(
                        .respiratoryRate, unit: .count().unitDivided(by: .minute()), from: startDate
                    ) else { return nil }
                    return .init(metric: "respiratory_rate", value: value, unit: "breaths/min", startAt: date, endAt: nil)
                }
            )
        }

        // Body mass — latest sample in last 7 days
        if let bodyMass = HKQuantityType.quantityType(forIdentifier: .bodyMass) {
            descriptors["body_mass"] = HealthMetricDescriptor(
                metric: "body_mass",
                sampleType: bodyMass,
                startDateProvider: { Date().addingTimeInterval(-7 * 86_400) },
                builder: { service, startDate in
                    guard let (value, date) = await service.queryLatestSample(
                        .bodyMass, unit: .gramUnit(with: .kilo), from: startDate
                    ) else { return nil }
                    return .init(metric: "body_mass", value: value, unit: "kg", startAt: date, endAt: nil)
                }
            )
        }

        // Exercise time — cumulative sum today
        if let exercise = HKQuantityType.quantityType(forIdentifier: .appleExerciseTime) {
            descriptors["workout_minutes"] = HealthMetricDescriptor(
                metric: "workout_minutes",
                sampleType: exercise,
                startDateProvider: { Calendar.current.startOfDay(for: Date()) },
                builder: { service, startDate in
                    guard let value = await service.queryCumulativeSum(
                        .appleExerciseTime, unit: .minute(), from: startDate, to: Date()
                    ) else { return nil }
                    return .init(metric: "workout_minutes", value: value, unit: "minutes", startAt: startDate, endAt: Date())
                }
            )
        }

        // Stand hours — cumulative sum today
        if let stand = HKQuantityType.quantityType(forIdentifier: .appleStandTime) {
            descriptors["stand_hours"] = HealthMetricDescriptor(
                metric: "stand_hours",
                sampleType: stand,
                startDateProvider: { Calendar.current.startOfDay(for: Date()) },
                builder: { service, startDate in
                    guard let value = await service.queryCumulativeSum(
                        .appleStandTime, unit: .minute(), from: startDate, to: Date()
                    ) else { return nil }
                    return .init(metric: "stand_hours", value: value / 60.0, unit: "hours", startAt: startDate, endAt: Date())
                }
            )
        }

        // Sleep duration — stable day bucket keyed by the day the sleep ends.
        // This keeps the sample startAt fixed for the current day so the
        // connector-side dedupe and daily rollup remain correct.
        let sleepType = HKCategoryType(.sleepAnalysis)
        descriptors["sleep_duration"] = HealthMetricDescriptor(
            metric: "sleep_duration",
            sampleType: sleepType,
            startDateProvider: { sleepBucketDay() },
            builder: { service, bucketDay in
                guard let hours = await service.querySleepDuration(attributedTo: bucketDay) else { return nil }
                return .init(metric: "sleep_duration", value: hours, unit: "hours", startAt: bucketDay, endAt: Date())
            }
        )

        return descriptors
    }

    // MARK: - Sleep Query

    private func querySleepDuration(attributedTo bucketDay: Date) async -> Double? {
        let sleepType = HKCategoryType(.sleepAnalysis)
        let calendar = Calendar.current
        guard
            let queryStart = calendar.date(byAdding: .hour, value: -18, to: bucketDay),
            let queryEnd = calendar.date(byAdding: .day, value: 1, to: bucketDay)
        else {
            return nil
        }
        let predicate = HKQuery.predicateForSamples(withStart: queryStart, end: queryEnd)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: sleepType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, results, _ in
                guard let samples = results as? [HKCategorySample] else {
                    continuation.resume(returning: nil)
                    return
                }
                let intervals = samples.map {
                    SleepInterval(value: $0.value, startDate: $0.startDate, endDate: $0.endDate)
                }
                continuation.resume(
                    returning: Self.aggregateSleepDuration(
                        intervals: intervals,
                        attributedTo: bucketDay,
                        calendar: calendar
                    )
                )
            }
            store?.execute(query)
        }
    }
}
