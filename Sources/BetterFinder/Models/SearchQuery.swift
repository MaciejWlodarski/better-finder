import Foundation

public enum SearchScopeMode: String, CaseIterable, Identifiable, Sendable {
    case currentFolder = "Current Folder"
    case recursiveFolder = "Subfolders"
    case wholeIndex = "Whole Disk (fsearch)"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .currentFolder: return "folder"
        case .recursiveFolder: return "folder.badge.gearshape"
        case .wholeIndex: return "bolt.horizontal.circle.fill"
        }
    }
}

public struct SizeFilter: Sendable, Equatable {
    public enum Op: String, Sendable {
        case gt = ">"
        case gte = ">="
        case lt = "<"
        case lte = "<="
        case eq = "="
        case range = ".."
    }
    public let op: Op
    public let bytes: Int64
    public let upperBytes: Int64?
    public let rawText: String

    public func matches(_ fileSize: Int64) -> Bool {
        switch op {
        case .gt: return fileSize > bytes
        case .gte: return fileSize >= bytes
        case .lt: return fileSize < bytes
        case .lte: return fileSize <= bytes
        case .eq: return fileSize == bytes
        case .range:
            guard let upper = upperBytes else { return fileSize >= bytes }
            return fileSize >= bytes && fileSize <= upper
        }
    }
}

public struct MTimeFilter: Sendable, Equatable {
    public enum Op: String, Sendable {
        case within = "<"
        case olderThan = ">"
    }
    public let op: Op
    public let secondsAgo: TimeInterval
    public let rawText: String

    public func matches(_ date: Date, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(date)
        switch op {
        case .within:
            return age <= secondsAgo
        case .olderThan:
            return age > secondsAgo
        }
    }
}

public enum TermMatchKind: Sendable, Equatable {
    case fuzzyOrSubstring(String, lowerBytes: [UInt8], charMask: UInt64)
    case exact(String)
    case prefix(String)
    case suffix(String)
    case excluded(String)
}

public struct ActiveFilterPill: Identifiable, Equatable, Sendable {
    public let id: String
    public let prefix: String
    public let value: String
    public let rawToken: String
    public let icon: String
}

public struct ParsedFSearchQuery: Sendable {
    public let rawQuery: String
    public var terms: [TermMatchKind] = []
    public var extensions: Set<String> = []
    public var excludedExtensions: Set<String> = []
    public var typeFilters: Set<String> = []
    public var tagFilters: Set<FinderTagColor> = []
    public var sizeFilters: [SizeFilter] = []
    public var mtimeFilters: [MTimeFilter] = []
    public var pathSubstrings: [String] = []
    public var regexPattern: String?
    public var grepPattern: String?
    public var grepTrigramMask: UInt64 = 0
    public var symlinkOnly: Bool?
    public var gitFilter: String?
    public var limit: Int = 500
    public var fuzzyTypoTolerance: Bool = true
    public var pills: [ActiveFilterPill] = []
    public var validationError: String?

    public var isEmpty: Bool {
        rawQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var hasFiltersOrTerms: Bool {
        !terms.isEmpty ||
        !extensions.isEmpty ||
        !excludedExtensions.isEmpty ||
        !typeFilters.isEmpty ||
        !tagFilters.isEmpty ||
        !sizeFilters.isEmpty ||
        !mtimeFilters.isEmpty ||
        !pathSubstrings.isEmpty ||
        regexPattern != nil ||
        grepPattern != nil ||
        symlinkOnly != nil ||
        gitFilter != nil
    }

    public static func parse(_ input: String, fuzzyEnabled: Bool = true) -> ParsedFSearchQuery {
        var result = ParsedFSearchQuery(rawQuery: input)
        result.fuzzyTypoTolerance = fuzzyEnabled
        let tokens = tokenize(input)
        if tokens.unterminatedQuote {
            result.validationError = "Unclosed quotation mark in search query."
            return result
        }

        for (idx, token) in tokens.values.enumerated() {
            if token.isEmpty { continue }

            if let colonIndex = token.firstIndex(of: ":"), colonIndex != token.startIndex {
                let rawKey = String(token[..<colonIndex]).lowercased()
                let val = decodeQuotedValue(String(token[token.index(after: colonIndex)...]))
                if !val.isEmpty {
                    let isNegated = rawKey.hasPrefix("!") || rawKey.hasPrefix("-")
                    let key = isNegated ? String(rawKey.dropFirst()) : rawKey

                    switch key {
                    case "ext", "e":
                        let exts = val.lowercased().split(separator: ",").map {
                            $0.hasPrefix(".") ? String($0.dropFirst()) : String($0)
                        }
                        if isNegated {
                            result.excludedExtensions.formUnion(exts)
                        } else {
                            result.extensions.formUnion(exts)
                        }
                        result.pills.append(ActiveFilterPill(
                            id: "\(idx)-\(token)",
                            prefix: isNegated ? "!ext" : "ext",
                            value: exts.joined(separator: ", "),
                            rawToken: token,
                            icon: "doc.badge.gearshape"
                        ))
                        continue

                    case "type", "kind", "t":
                        let types = val.lowercased().split(separator: ",").map(String.init)
                        result.typeFilters.formUnion(types)
                        result.pills.append(ActiveFilterPill(
                            id: "\(idx)-\(token)",
                            prefix: "type",
                            value: types.joined(separator: ", "),
                            rawToken: token,
                            icon: "square.grid.2x2"
                        ))
                        continue

                    case "tag", "tags", "color", "kolor":
                        let rawColors = val.lowercased().split(separator: ",").map(String.init)
                        let matchedColors = rawColors.compactMap { FinderTagColor.from(rawTagName: $0) }
                        if !matchedColors.isEmpty {
                            result.tagFilters.formUnion(matchedColors)
                            result.pills.append(ActiveFilterPill(
                                id: "\(idx)-\(token)",
                                prefix: "tag",
                                value: matchedColors.map(\.displayName).joined(separator: ", "),
                                rawToken: token,
                                icon: "tag.fill"
                            ))
                            continue
                        }

                    case "size", "s":
                        if let sf = parseSizeFilter(val) {
                            result.sizeFilters.append(sf)
                            result.pills.append(ActiveFilterPill(
                                id: "\(idx)-\(token)",
                                prefix: "size",
                                value: val,
                                rawToken: token,
                                icon: "internaldrive"
                            ))
                            continue
                        }
                        result.validationError = "Invalid or out-of-range size: \(val)"
                        return result

                    case "mtime", "modified", "age", "dm":
                        if let mf = parseMTimeFilter(val) {
                            result.mtimeFilters.append(mf)
                            result.pills.append(ActiveFilterPill(
                                id: "\(idx)-\(token)",
                                prefix: "mtime",
                                value: val,
                                rawToken: token,
                                icon: "clock.arrow.circlepath"
                            ))
                            continue
                        }
                        result.validationError = "Invalid or out-of-range modification age: \(val)"
                        return result

                    case "in", "path", "dir", "folder":
                        result.pathSubstrings.append(val.lowercased())
                        result.pills.append(ActiveFilterPill(
                            id: "\(idx)-\(token)",
                            prefix: "in",
                            value: val,
                            rawToken: token,
                            icon: "folder"
                        ))
                        continue

                    case "grep", "content", "g":
                        result.grepPattern = val
                        result.grepTrigramMask = computeTrigramBloomMask(Array(val.lowercased().utf8))
                        result.pills.append(ActiveFilterPill(
                            id: "\(idx)-\(token)",
                            prefix: "grep",
                            value: val,
                            rawToken: token,
                            icon: "text.magnifyingglass"
                        ))
                        continue

                    case "regex", "re":
                        do { _ = try NSRegularExpression(pattern: val, options: [.caseInsensitive]) }
                        catch {
                            result.validationError = "Invalid regular expression: \(error.localizedDescription)"
                            return result
                        }
                        result.regexPattern = val
                        result.pills.append(ActiveFilterPill(
                            id: "\(idx)-\(token)",
                            prefix: "regex",
                            value: val,
                            rawToken: token,
                            icon: "asterisk.circle"
                        ))
                        continue

                    case "sym", "symlink":
                        let b = (val == "true" || val == "1" || val == "yes")
                        result.symlinkOnly = b
                        result.pills.append(ActiveFilterPill(
                            id: "\(idx)-\(token)",
                            prefix: "sym",
                            value: b ? "yes" : "no",
                            rawToken: token,
                            icon: "arrow.turn.up.right"
                        ))
                        continue

                    case "git":
                        result.gitFilter = val.lowercased()
                        result.pills.append(ActiveFilterPill(
                            id: "\(idx)-\(token)",
                            prefix: "git",
                            value: val.lowercased(),
                            rawToken: token,
                            icon: "point.3.connected.trianglepath.dotted"
                        ))
                        continue

                    case "limit", "max":
                        if let n = Int(val), n > 0 {
                            result.limit = min(n, 10_000)
                            continue
                        }

                    default:
                        break
                    }
                }
            }

            if (token.hasPrefix("!") || token.hasPrefix("-")) && token.count > 1 {
                let term = String(token.dropFirst()).lowercased()
                result.terms.append(.excluded(term))
                result.pills.append(ActiveFilterPill(
                    id: "\(idx)-\(token)",
                    prefix: "not",
                    value: term,
                    rawToken: token,
                    icon: "minus.circle"
                ))
            } else if token.hasPrefix("^") && token.count > 1 {
                let term = String(token.dropFirst()).lowercased()
                result.terms.append(.prefix(term))
            } else if token.hasSuffix("$") && token.count > 1 {
                let term = String(token.dropLast()).lowercased()
                result.terms.append(.suffix(term))
            } else if (token.hasPrefix("\"") && token.hasSuffix("\"") && token.count > 2) ||
                      (token.hasPrefix("'") && token.hasSuffix("'") && token.count > 2) {
                let inner = decodeQuotedValue(token).lowercased()
                result.terms.append(.exact(inner))
            } else {
                let lower = token.lowercased()
                let bytes = Array(lower.utf8)
                let mask = Self.computeAsciiBitmask(bytes)
                result.terms.append(.fuzzyOrSubstring(lower, lowerBytes: bytes, charMask: mask))
            }
        }

        return result
    }

    /// Computes a 64-bit ASCII presence bitmask for O(1) Bloom-style rejection
    @inline(__always)
    public static func computeAsciiBitmask(_ utf8Bytes: [UInt8]) -> UInt64 {
        var mask: UInt64 = 0
        for b in utf8Bytes {
            let lower = (b >= 65 && b <= 90) ? (b + 32) : b
            let bit: UInt64
            if lower >= 97 && lower <= 122 {
                bit = UInt64(lower - 97)
            } else if lower >= 48 && lower <= 57 {
                bit = UInt64(26 + (lower - 48))
            } else if lower == 46 {
                bit = 36
            } else if lower == 95 {
                bit = 37
            } else if lower == 45 {
                bit = 38
            } else {
                bit = UInt64(39 + (lower & 0x17))
            }
            mask |= (1 << (bit & 63))
        }
        return mask
    }

    /// Computes a 64-bit Trigram Bloom Filter mask over 3-byte sliding windows (for ultra-fast grep pre-rejection)
    @inline(__always)
    public static func computeTrigramBloomMask(_ bytes: [UInt8]) -> UInt64 {
        guard bytes.count >= 3 else { return 0 }
        var mask: UInt64 = 0
        let limit = bytes.count - 2
        for i in 0..<limit {
            let b0 = (bytes[i] >= 65 && bytes[i] <= 90) ? (bytes[i] + 32) : bytes[i]
            let b1 = (bytes[i + 1] >= 65 && bytes[i + 1] <= 90) ? (bytes[i + 1] + 32) : bytes[i + 1]
            let b2 = (bytes[i + 2] >= 65 && bytes[i + 2] <= 90) ? (bytes[i + 2] + 32) : bytes[i + 2]
            let hash = (UInt32(b0) &* 31 &+ UInt32(b1)) &* 31 &+ UInt32(b2)
            let bit1 = UInt64(hash & 63)
            let bit2 = UInt64((hash >> 6) & 63)
            mask |= (1 << bit1) | (1 << bit2)
        }
        return mask
    }

    // Keep the original spelling for removable filter pills. Decode only syntax
    // quotes and escaped quotes/backslashes, preserving regex escapes such as \d.
    private static func tokenize(_ input: String) -> (values: [String], unterminatedQuote: Bool) {
        var tokens: [String] = []
        var current = ""
        var inQuote: Character?
        var escaped = false
        for ch in input {
            if escaped {
                current.append(ch)
                escaped = false
            } else if ch == "\\" {
                current.append(ch)
                escaped = true
            } else if let quote = inQuote {
                current.append(ch)
                if ch == quote { inQuote = nil }
            } else if (ch == "\"" || ch == "'"), current.isEmpty || current.hasSuffix(":") {
                inQuote = ch
                current.append(ch)
            } else if ch.isWhitespace {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return (tokens, inQuote != nil)
    }

    private static func decodeQuotedValue(_ raw: String) -> String {
        let quoted = raw.count >= 2 && ((raw.first == "\"" && raw.last == "\"") ||
            (raw.first == "'" && raw.last == "'"))
        let chars = Array(quoted ? String(raw.dropFirst().dropLast()) : raw)
        var output = ""
        var index = 0
        while index < chars.count {
            let ch = chars[index]
            if ch == "\\", index + 1 < chars.count,
               chars[index + 1] == "\\" || chars[index + 1] == "\"" || chars[index + 1] == "'" {
                output.append(chars[index + 1])
                index += 2
            } else {
                output.append(ch)
                index += 1
            }
        }
        return output
    }

    private static func parseSizeFilter(_ raw: String) -> SizeFilter? {
        let lower = raw.lowercased()
        if lower.contains("..") {
            let parts = lower.components(separatedBy: "..")
            guard parts.count == 2,
                  let low = parseByteQuantity(parts[0]),
                  let high = parseByteQuantity(parts[1]), low <= high else { return nil }
            return SizeFilter(op: .range, bytes: low, upperBytes: high, rawText: raw)
        }

        let op: SizeFilter.Op
        let numPart: String
        if lower.hasPrefix(">=") {
            op = .gte
            numPart = String(lower.dropFirst(2))
        } else if lower.hasPrefix("<=") {
            op = .lte
            numPart = String(lower.dropFirst(2))
        } else if lower.hasPrefix(">") {
            op = .gt
            numPart = String(lower.dropFirst(1))
        } else if lower.hasPrefix("<") {
            op = .lt
            numPart = String(lower.dropFirst(1))
        } else if lower.hasPrefix("=") {
            op = .eq
            numPart = String(lower.dropFirst(1))
        } else {
            op = .gte
            numPart = lower
        }

        guard let bytes = parseByteQuantity(numPart) else { return nil }
        return SizeFilter(op: op, bytes: bytes, upperBytes: nil, rawText: raw)
    }

    private static func parseByteQuantity(_ str: String) -> Int64? {
        let s = str.trimmingCharacters(in: .whitespaces)
        var numStr = ""
        var unitStr = ""
        for ch in s {
            if ch.isASCII && (ch.isNumber || ch == ".") {
                guard unitStr.isEmpty else { return nil }
                numStr.append(ch)
            } else {
                unitStr.append(ch)
            }
        }
        guard let val = Double(numStr) else { return nil }
        let mult: Double
        switch unitStr.lowercased() {
        case "g", "gb", "gib": mult = 1024 * 1024 * 1024
        case "m", "mb", "mib": mult = 1024 * 1024
        case "k", "kb", "kib": mult = 1024
        case "b", "": mult = 1
        default: return nil
        }
        if let integer = Int64(numStr) {
            let (bytes, overflow) = integer.multipliedReportingOverflow(by: Int64(mult))
            return !overflow && bytes >= 0 ? bytes : nil
        }
        let scaled = val * mult
        guard scaled.isFinite, scaled >= 0 else { return nil }
        // Int64.max rounds up to 2^63 as Double; a <= max check is unsafe.
        return Int64(exactly: scaled.rounded(.towardZero))
    }

    private static func parseMTimeFilter(_ raw: String) -> MTimeFilter? {
        let lower = raw.lowercased()
        let op: MTimeFilter.Op
        let rest: String
        if lower.hasPrefix("<") || lower.hasPrefix("-") {
            op = .within
            rest = String(lower.dropFirst())
        } else if lower.hasPrefix(">") || lower.hasPrefix("+") {
            op = .olderThan
            rest = String(lower.dropFirst())
        } else if lower == "today" {
            return MTimeFilter(op: .within, secondsAgo: 86_400, rawText: raw)
        } else if lower == "week" {
            return MTimeFilter(op: .within, secondsAgo: 7 * 86_400, rawText: raw)
        } else {
            op = .within
            rest = lower
        }

        var numStr = ""
        var unitStr = ""
        for ch in rest {
            if ch.isASCII && (ch.isNumber || ch == ".") {
                guard unitStr.isEmpty else { return nil }
                numStr.append(ch)
            } else {
                unitStr.append(ch)
            }
        }
        guard let val = Double(numStr) else { return nil }
        let mult: Double
        switch unitStr {
        case "s", "sec": mult = 1
        case "m", "min": mult = 60
        case "h", "hr", "hour", "hours": mult = 3600
        case "d", "day", "days", "": mult = 86_400
        case "w", "wk", "week", "weeks": mult = 7 * 86_400
        case "mo", "month", "months": mult = 30 * 86_400
        case "y", "yr", "year", "years": mult = 365 * 86_400
        default: return nil
        }
        let seconds = val * mult
        guard seconds.isFinite, seconds >= 0 else { return nil }
        return MTimeFilter(op: op, secondsAgo: seconds, rawText: raw)
    }
}
