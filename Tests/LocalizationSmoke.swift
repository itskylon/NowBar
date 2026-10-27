import Foundation

@main
struct LocalizationSmoke {
    static func main() throws {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            guard value() else { fatalError(message) }
        }
        expect(MeterPreferences().language == .system, "New preferences follow the system")
        let old = try JSONDecoder().decode(MeterPreferences.self, from: Data("{}".utf8))
        expect(old.language == .system, "Existing preferences follow the system")
        let unknown = try JSONDecoder().decode(MeterPreferences.self, from: Data("{\"language\":\"future\"}".utf8))
        expect(unknown.language == .system, "Unsupported preference uses system default")
        for choice in AppLanguage.allCases {
            var preferences = MeterPreferences()
            preferences.language = choice
            let encoded = try JSONEncoder().encode(preferences)
            let decoded = try JSONDecoder().decode(MeterPreferences.self, from: encoded)
            expect(decoded.language == choice, "Language persists")
        }
        expect(AppLanguage.system.resolved(preferredLanguages: ["en-GB", "zh-Hans"]) == .english, "English system language")
        expect(AppLanguage.system.resolved(preferredLanguages: ["zh-Hans-CN", "en"]) == .simplifiedChinese, "Chinese system language")
        expect(AppLanguage.system.resolved(preferredLanguages: ["zh-Hant-TW"]) == .simplifiedChinese, "Chinese family uses supported Chinese")
        expect(AppLanguage.system.resolved(preferredLanguages: ["fr-FR", "en-US", "zh"]) == .english, "First supported language")
        expect(AppLanguage.system.resolved(preferredLanguages: ["ja-JP", "zh-Hans"]) == .simplifiedChinese, "Second supported language")
        expect(AppLanguage.system.resolved(preferredLanguages: ["fr"]) == .english, "Unsupported languages fall back to English")
        expect(AppLanguage.system.resolved(preferredLanguages: []) == .english, "Missing system languages fall back to English")
        expect(AppLanguage.english.resolved(preferredLanguages: ["zh"]) == .english, "Manual English overrides system")
        expect(AppLanguage.simplifiedChinese.resolved(preferredLanguages: ["en"]) == .simplifiedChinese, "Manual Chinese overrides system")
        defer { L10n.language = .system }
        L10n.language = .english
        expect(L10n.isEnglish, "English takes effect immediately")
        expect(L10n.locale.identifier == "en_US", "English formatting locale")
        expect(L10n.text("每周") == "Weekly", "Internal quota title is presented in English")
        expect(L10n.text("等待更新") == "Awaiting update", "Cached status is translated on presentation")
        expect(L10n.text("claude-opus-4") == "claude-opus-4", "Unknown model identifier stays untouched")
        expect(L10n.format("%@ 小时", "5") == "5 hours", "Dynamic format")
        expect(L10n.text("5 小时") == "5 hours", "Cached dynamic duration")
        expect(L10n.text("剩余 17%") == "17% remaining", "Cached dynamic percentage")
        expect(L10n.format("剩余 %@%%", "17") == "17% remaining", "Percent escaping and English word order")
        L10n.language = .simplifiedChinese
        expect(!L10n.isEnglish, "Chinese takes effect immediately")
        expect(L10n.text("每周") == "每周", "Chinese display remains unchanged")
        expect(L10n.format("剩余 %@%%", "17") == "剩余 17%", "Chinese formatting")
        expect(L10n.locale.language.languageCode?.identifier == "zh" && L10n.locale.language.script?.identifier == "Hans", "Chinese formatting locale")
        print("Localization: \(checks) checks passed")
    }
}
