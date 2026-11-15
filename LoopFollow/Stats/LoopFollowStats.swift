// LoopFollow
// LoopFollowStats.swift

import AIDReportKit
import AIDReportNightscout
import Foundation

enum LoopFollowStatsError: LocalizedError {
    case nightscoutNotConfigured

    var errorDescription: String? {
        "Statistics reports read from Nightscout. Add your Nightscout URL in Settings first."
    }
}

/// AIDReportKit entry points. Reports read Nightscout: the full history, with the site's basal
/// profile filling the time no temp basal covers.
enum LoopFollowStats {
    static var displayUnit: GlucoseUnit {
        UnitSettingsStore.shared.glucoseUnit == .mmolL ? .mmolL : .mgdL
    }

    static var info: DataSourceInfo {
        DataSourceInfo(
            app: .loopFollow,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            displayUnit: displayUnit
        )
    }

    /// Full-history source backed by the Nightscout site LoopFollow follows; `nil` when
    /// only Dexcom Share is configured (no treatments are available then).
    static func nightscoutSource() -> NightscoutTherapyDataSource? {
        let urlString = Storage.shared.url.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlString.isEmpty, let url = URL(string: urlString) else { return nil }
        let token = Storage.shared.token.value
        return NightscoutTherapyDataSource(
            configuration: NightscoutConfiguration(baseURL: url, token: token.isEmpty ? nil : token),
            info: info
        )
    }

    /// The clock a report keeps. Days, times of day and midnight have to be those of the person
    /// followed, and a follower is often somewhere else:
    /// - LoopFollow's Time Zone Override when it is on, as everywhere else in the app;
    /// - otherwise the looping phone's time zone from the Nightscout profile, when that is a
    ///   different clock from this device's right now;
    /// - otherwise this device's. It is preferred over an equal profile zone because Loop uploads
    ///   a fixed offset ("ETC/GMT-1") that knows nothing of daylight saving time.
    static func reportTimeZone(profile: TimeZone?) -> TimeZone {
        let display = dateTimeUtils.displayTimeZone()
        guard !Storage.shared.graphTimeZoneEnabled.value,
              let profile,
              profile.secondsFromGMT() != display.secondsFromGMT()
        else { return display }
        return profile
    }

    /// Report from Nightscout, in the looper's time zone, with the site's basal profile filling
    /// gaps between temp basals and its carb ratios, ISF and targets on the Insulin and Settings pages.
    static func report(_ definition: ReportDefinition = .standard) async throws -> TherapyReport? {
        guard let site = nightscoutSource() else { return nil }
        // The report is still worth having without the profile: it then keeps this device's
        // clock and counts recorded basal only.
        var profile: NightscoutProfile?
        do {
            profile = try await site.profile()
        } catch {
            LogManager.shared.log(category: .nightscout, message: "Statistics report, error fetching profile data: \(error.localizedDescription)")
        }
        let source = site.usingTimeZone(reportTimeZone(profile: profile?.timeZone))
        let options = ReportOptions(
            basalSchedule: profile?.basalSchedule,
            therapySettings: profile?.therapySettings,
            metadata: ReportMetadata(appName: "LoopFollow", appVersion: info.appVersion)
        )
        return try await AIDReport.generate(definition, from: source, options: options)
    }

    /// Like `report(_:)`, but throws a readable error when no Nightscout site is configured.
    static func makeReport(_ definition: ReportDefinition) async throws -> TherapyReport {
        guard let report = try await report(definition) else {
            throw LoopFollowStatsError.nightscoutNotConfigured
        }
        return report
    }
}
