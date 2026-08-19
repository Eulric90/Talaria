import Foundation
import UIKit

struct DeviceRegistrationRequest: Codable, Hashable, Sendable {
    let installationID: UUID
    let deviceName: String
    let appVersion: String
    let buildNumber: String
    let bundleID: String
    let deviceModel: String
    let systemVersion: String
    let environment: AppEnvironment
    let relayBaseURLString: String
}

extension DeviceRegistrationRequest {
    @MainActor
    static func current(
        installationID: UUID,
        environment: AppEnvironment,
        relayBaseURLString: String? = nil
    ) -> DeviceRegistrationRequest {
        let device = UIDevice.current
        let bundle = Bundle.main

        return DeviceRegistrationRequest(
            installationID: installationID,
            deviceName: device.name,
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0",
            buildNumber: bundle.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String ?? "1",
            bundleID: bundle.bundleIdentifier ?? "io.github.eulric90.talaria",
            deviceModel: device.model,
            systemVersion: device.systemVersion,
            environment: environment,
            relayBaseURLString: relayBaseURLString ?? environment.baseURLString
        )
    }
}
