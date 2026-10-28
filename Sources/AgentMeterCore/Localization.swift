import Foundation

public enum AppLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case system, simplifiedChinese = "zh-Hans", english = "en"
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .system: return "跟随系统 / System"
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        }
    }

    public func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> Self {
        guard self == .system else { return self }
        for language in preferredLanguages {
            let base = language.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first
            if base == "zh" { return .simplifiedChinese }
            if base == "en" { return .english }
        }
        return .english
    }
}

/// Localizes at presentation time so cached source messages and stable quota titles
/// never become language-dependent identifiers or require another network read.
public enum L10n {
    private static let lock = NSLock()
    private static var selected: AppLanguage = .system
    public static var language: AppLanguage {
        get { lock.lock(); defer { lock.unlock() }; return selected }
        set { lock.lock(); defer { lock.unlock() }; selected = newValue }
    }
    public static var isEnglish: Bool { language.resolved() == .english }
    public static var locale: Locale { Locale(identifier: isEnglish ? "en_US" : "zh_Hans_CN") }

    private static let english = [CommonTranslations.english, DashboardTranslations.english,
                                  HistoryTranslations.english, SettingsTranslations.english, MenuBarTranslations.english]
        .reduce(into: [String: String]()) { result, table in result.merge(table) { first, _ in first } }

    private struct Template {
        let expression: NSRegularExpression
        let translation: String
    }
    private static let templates: [Template] = english.keys.filter { $0.contains("%@") }
        .sorted {
            let left = $0.replacingOccurrences(of: "%@", with: "").replacingOccurrences(of: "%%", with: "%").count
            let right = $1.replacingOccurrences(of: "%@", with: "").replacingOccurrences(of: "%%", with: "%").count
            return left == right ? $0 < $1 : left > right
        }.compactMap { key in
            let pattern = key.components(separatedBy: "%@").map {
                NSRegularExpression.escapedPattern(for: $0.replacingOccurrences(of: "%%", with: "%"))
            }.joined(separator: "(.*?)")
            guard let expression = try? NSRegularExpression(pattern: "^" + pattern + "$", options: [.dotMatchesLineSeparators]) else { return nil }
            return Template(expression: expression, translation: english[key]!)
        }

    public static func text(_ source: String) -> String {
        guard isEnglish else { return source }
        return translated(source, depth: 0)
    }

    private static func translated(_ source: String, depth: Int) -> String {
        if let exact = english[source] { return exact }
        guard depth < 4, source.range(of: "\\p{Han}", options: .regularExpression) != nil else { return source }
        // Sources may append multiple status sentences while retaining raw cache data.
        if source.contains("。") {
            let sentences = source.split(separator: "。", omittingEmptySubsequences: false)
            if sentences.count > 2 || (sentences.count == 2 && !sentences[1].isEmpty) {
                return sentences.enumerated().compactMap { index, sentence -> String? in
                    let raw = String(sentence).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !raw.isEmpty else { return nil }
                    return translated(raw + (index < sentences.count - 1 ? "。" : ""), depth: depth + 1)
                }.joined(separator: " ")
            }
        }
        if source.contains("\n") {
            return source.components(separatedBy: "\n").map { translated($0, depth: depth + 1) }.joined(separator: "\n")
        }
        let fullRange = NSRange(source.startIndex..., in: source)
        for template in templates {
            guard let match = template.expression.firstMatch(in: source, range: fullRange) else { continue }
            let arguments: [CVarArg] = (1..<match.numberOfRanges).map { index in
                guard let range = Range(match.range(at: index), in: source) else { return "" }
                return translated(String(source[range]), depth: depth + 1)
            }
            return String(format: template.translation, locale: Locale(identifier: "en_US"), arguments: arguments)
        }
        return source
    }

    public static func format(_ key: String, _ arguments: CVarArg...) -> String {
        let template = isEnglish ? (english[key] ?? key) : key
        return String(format: template, locale: locale, arguments: arguments)
    }
}
