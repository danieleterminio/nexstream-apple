import Foundation

/// Regular expressions with the handful of operations the Kotlin code uses (`find`, `containsMatchIn`, `matches`, `replace`,
/// `split`), on top of NSRegularExpression (ICU, same dialect as java.util.regex for everything used here).
final class Rx {
    let re: NSRegularExpression
    /// The same pattern anchored at both ends, for `matches`.
    private let full: NSRegularExpression

    init(_ pattern: String, _ options: NSRegularExpression.Options = []) {
        do {
            re = try NSRegularExpression(pattern: pattern, options: options)
            full = try NSRegularExpression(pattern: #"\A(?:"# + pattern + #")\z"#, options: options)
        } catch { fatalError("bad regex \(pattern): \(error)") }
    }
    /// Case-insensitive.
    static func i(_ pattern: String) -> Rx { Rx(pattern, [.caseInsensitive]) }

    struct Match {
        let groups: [String?]
        let range: Range<String.Index>
        /// Group text, "" when the group did not take part.
        subscript(_ i: Int) -> String { i < groups.count ? (groups[i] ?? "") : "" }
        func opt(_ i: Int) -> String? { i < groups.count ? groups[i] : nil }
        var value: String { self[0] }
    }

    private func make(_ r: NSTextCheckingResult, _ s: String) -> Match? {
        guard let whole = Range(r.range, in: s) else { return nil }
        var g = [String?]()
        g.reserveCapacity(r.numberOfRanges)
        for k in 0..<r.numberOfRanges {
            let nr = r.range(at: k)
            if nr.location == NSNotFound { g.append(nil) } else if let rr = Range(nr, in: s) { g.append(String(s[rr])) } else { g.append(nil) }
        }
        return Match(groups: g, range: whole)
    }

    func find(_ s: String) -> Match? {
        guard let r = re.firstMatch(in: s, options: [], range: NSRange(s.startIndex..., in: s)) else { return nil }
        return make(r, s)
    }
    func findAll(_ s: String) -> [Match] {
        re.matches(in: s, options: [], range: NSRange(s.startIndex..., in: s)).compactMap { make($0, s) }
    }
    /// A match anywhere in the string.
    func contains(_ s: String) -> Bool {
        re.firstMatch(in: s, options: [], range: NSRange(s.startIndex..., in: s)) != nil
    }
    /// The whole string matches.
    func matches(_ s: String) -> Bool {
        full.firstMatch(in: s, options: [], range: NSRange(s.startIndex..., in: s)) != nil
    }
    /// Replaces every match; `template` may use `$1`.
    func replace(_ s: String, _ template: String = "") -> String {
        re.stringByReplacingMatches(in: s, options: [], range: NSRange(s.startIndex..., in: s), withTemplate: template)
    }
    func split(_ s: String) -> [String] {
        var out = [String](); var last = s.startIndex
        for m in findAll(s) { out.append(String(s[last..<m.range.lowerBound])); last = m.range.upperBound }
        out.append(String(s[last...]))
        return out
    }
}

extension String {
    /// First match of `pattern` with its groups, or nil.
    func firstMatch(_ pattern: String, caseInsensitive: Bool = false) -> Rx.Match? {
        (caseInsensitive ? Rx.i(pattern) : Rx(pattern)).find(self)
    }
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nilIfBlank: String? { trimmed.isEmpty ? nil : self }
    var isBlank: Bool { trimmed.isEmpty }

    func trimmingEnd(_ chars: String) -> String {
        var s = Substring(self)
        while let l = s.last, chars.contains(l) { s = s.dropLast() }
        return String(s)
    }
    func trimming(_ chars: String) -> String {
        var s = Substring(self)
        while let l = s.last, chars.contains(l) { s = s.dropLast() }
        while let f = s.first, chars.contains(f) { s = s.dropFirst() }
        return String(s)
    }
    func removingPrefix(_ p: String) -> String { hasPrefix(p) ? String(dropFirst(p.count)) : self }
    func removingSuffix(_ p: String) -> String { hasSuffix(p) ? String(dropLast(p.count)) : self }
    func substringBefore(_ sep: String) -> String { range(of: sep).map { String(self[..<$0.lowerBound]) } ?? self }
    func substringAfter(_ sep: String, orElse: String? = nil) -> String { range(of: sep).map { String(self[$0.upperBound...]) } ?? (orElse ?? self) }
    func containsIgnoringCase(_ other: String) -> Bool { range(of: other, options: [.caseInsensitive]) != nil }
    func equalsIgnoringCase(_ other: String) -> Bool { caseInsensitiveCompare(other) == .orderedSame }
    func hasPrefixIgnoringCase(_ p: String) -> Bool { lowercased().hasPrefix(p.lowercased()) }
    /// First letter upper-cased, the rest untouched.
    var capitalizedFirst: String { guard let f = first else { return self }; return String(f).uppercased() + dropFirst() }
    var urlQueryEncoded: String {
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
    /// Words separated by single spaces.
    var words: [String] { split(separator: " ", omittingEmptySubsequences: true).map(String.init) }
    func take(_ n: Int) -> String { String(prefix(n)) }
}

extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
    var isNilOrBlank: Bool { self?.isBlank ?? true }
}

/// Text normalisation shared by the guide and the metadata matcher: no accents, lower case, letters / digits / single spaces.
enum MetaText {
    private static let nonAlnum = Rx("[^a-z0-9 ]")
    private static let spaces = Rx(#"\s+"#)
    static func norm(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        return spaces.replace(nonAlnum.replace(folded.replacingOccurrences(of: "&", with: " and "), " "), " ").trimmed
    }
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
    subscript(safe i: Int) -> Element? { i >= 0 && i < count ? self[i] : nil }
    /// Keeps the first element for each key, in order.
    func distinct<K: Hashable>(by key: (Element) -> K) -> [Element] {
        var seen = Set<K>(); var out = [Element]()
        for e in self where seen.insert(key(e)).inserted { out.append(e) }
        return out
    }
    func grouped<K: Hashable>(by key: (Element) -> K) -> [K: [Element]] { Dictionary(grouping: self, by: key) }
}

extension Array where Element: Hashable {
    var distinct: [Element] { var seen = Set<Element>(); return filter { seen.insert($0).inserted } }
}

extension Sequence {
    /// Stable sort by a comparable key.
    func sortedBy<K: Comparable>(_ key: (Element) -> K) -> [Element] {
        enumerated().sorted { a, b in let ka = key(a.element), kb = key(b.element); return ka == kb ? a.offset < b.offset : ka < kb }.map { $0.element }
    }
    func sortedByDescending<K: Comparable>(_ key: (Element) -> K) -> [Element] {
        enumerated().sorted { a, b in let ka = key(a.element), kb = key(b.element); return ka == kb ? a.offset < b.offset : ka > kb }.map { $0.element }
    }
}

/// Epoch milliseconds, as the Android app stores every instant.
typealias Millis = Int64
enum Clock {
    static var now: Millis { Millis(Date().timeIntervalSince1970 * 1000) }
    static let minute: Millis = 60_000
    static let hour: Millis = 3_600_000
    static let day: Millis = 86_400_000
}
extension Date {
    init(ms: Millis) { self.init(timeIntervalSince1970: Double(ms) / 1000) }
    var ms: Millis { Millis(timeIntervalSince1970 * 1000) }
}
