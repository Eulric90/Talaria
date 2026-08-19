import Foundation
import WidgetKit

/// Timeline entry backed by the App Group shared data snapshot, plus the
/// per-widget theme choice from the configuration intent.
struct HermesWidgetEntry: TimelineEntry {
    let date: Date
    let data: HermesWidgetData
    var widgetTheme: WidgetTheme = .matchApp

    /// Palette resolved for this entry (widget theme → shared tables).
    var palette: ThemePalette { widgetTheme.resolvedPalette(data: data) }

    static let placeholder = HermesWidgetEntry(
        date: .now,
        data: HermesWidgetData(
            hostName: "Hermes",
            hostOnline: true,
            lastMessagePreview: "Good morning! How can I help?",
            lastMessageSender: "assistant",
            lastMessageAt: .now,
            lastMessageSummary: "Good morning! How can I help?",
            voiceSessionActive: false,
            steps: 4_230,
            activeCalories: 185,
            sleepHours: 7.4,
            heartRate: 68,
            updatedAt: .now
        )
    )
}

/// Reads the latest snapshot from the App Group shared container and carries
/// the widget's configured theme into each entry.
struct HermesTimelineProvider: AppIntentTimelineProvider {
    private static let appGroupID: String = {
        if let custom = Bundle.main.object(forInfoDictionaryKey: "APP_GROUP_ID") as? String, !custom.isEmpty {
            return custom
        }
        return "group.io.github.eulric90.talaria"
    }()
    private static let dataKey = "hermes.widget.data"

    func placeholder(in context: Context) -> HermesWidgetEntry {
        .placeholder
    }

    func snapshot(for configuration: HermesWidgetConfigurationIntent, in context: Context) async -> HermesWidgetEntry {
        HermesWidgetEntry(date: .now, data: readData(), widgetTheme: configuration.theme)
    }

    func timeline(for configuration: HermesWidgetConfigurationIntent, in context: Context) async -> Timeline<HermesWidgetEntry> {
        let entry = HermesWidgetEntry(date: .now, data: readData(), widgetTheme: configuration.theme)
        // Refresh every 15 minutes; immediate refreshes are triggered by
        // WidgetCenter.shared.reloadAllTimelines() in the main app.
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 15, to: .now) ?? .now
        return Timeline(entries: [entry], policy: .after(nextRefresh))
    }

    private func readData() -> HermesWidgetData {
        guard let defaults = UserDefaults(suiteName: Self.appGroupID),
              let raw = defaults.data(forKey: Self.dataKey),
              let decoded = try? JSONDecoder().decode(HermesWidgetData.self, from: raw)
        else {
            return .empty
        }
        return decoded
    }
}
