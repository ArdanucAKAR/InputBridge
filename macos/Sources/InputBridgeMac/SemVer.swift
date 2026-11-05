import Foundation

/// major.minor.patch[-prerelease] with SemVer 2.0 precedence:
/// 0.2.6-beta.1 < 0.2.6-beta.2 < 0.2.6-rc.1 < 0.2.6 < 0.2.7. Build metadata (+...) is ignored.
struct SemVer: Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: [String]

    static let zero = SemVer(major: 0, minor: 0, patch: 0, prerelease: [])

    init(major: Int, minor: Int, patch: Int, prerelease: [String]) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    init?(_ raw: String) {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        if let plus = text.firstIndex(of: "+") { text = String(text[..<plus]) }

        var pre: [String] = []
        if let dash = text.firstIndex(of: "-") {
            let suffix = String(text[text.index(after: dash)...])
            text = String(text[..<dash])
            pre = suffix.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !pre.isEmpty, pre.allSatisfy({ !$0.isEmpty }) else { return nil }
        }

        // Accept 1-4 numeric parts; a 4th part is ignored.
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var numbers = [0, 0, 0]
        for (index, part) in parts.enumerated() {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(part) else { return nil }
            if index < 3 { numbers[index] = value }
        }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2], prerelease: pre)
    }

    var isPrerelease: Bool { !prerelease.isEmpty }

    var description: String {
        let core = "\(major).\(minor).\(patch)"
        return prerelease.isEmpty ? core : core + "-" + prerelease.joined(separator: ".")
    }

    /// Same major.minor.patch, ignoring any pre-release suffix.
    func hasSameCore(as other: SemVer) -> Bool {
        major == other.major && minor == other.minor && patch == other.patch
    }

    static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        switch (lhs.prerelease.isEmpty, rhs.prerelease.isEmpty) {
        case (true, _): return false          // a release is never lower than anything with the same core
        case (false, true): return true       // a pre-release is lower than the release
        case (false, false): break
        }

        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            switch (Int(left), Int(right)) {
            case let (l?, r?): return l < r
            case (.some, .none): return true   // numeric identifiers sort before alphanumeric ones
            case (.none, .some): return false
            case (.none, .none): return left < right
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}
