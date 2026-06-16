import Foundation

enum ComposeEnvFileFormat: Equatable {
    case compose
    case raw
}

struct ComposeEnvFileParser {
    var environment: [String: String]
    var format: ComposeEnvFileFormat

    func parse(_ text: String) throws -> [String: String?] {
        var values: [String: String?] = [:]
        for line in logicalLines(text) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            guard let delimiter = delimiterIndex(in: line) else {
                values.updateValue(nil, forKey: trimmed)
                continue
            }

            let key = String(line[..<delimiter]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }

            let rawValueStart = line.index(after: delimiter)
            let rawValue = String(line[rawValueStart...])
            switch format {
            case .raw:
                values[key] = rawValue
            case .compose:
                values[key] = try parseComposeValue(rawValue)
            }
        }
        return values
    }

    private func logicalLines(_ text: String) -> [String] {
        let physicalLines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingSuffix("\r") }
        guard format == .compose else {
            return physicalLines
        }

        var result: [String] = []
        var pending: String?

        for line in physicalLines {
            if let current = pending {
                let combined = current + "\n" + line
                if singleQuotedValueIsClosed(in: combined) {
                    result.append(combined)
                    pending = nil
                } else {
                    pending = combined
                }
                continue
            }

            if startsUnclosedSingleQuotedValue(line) {
                pending = line
            } else {
                result.append(line)
            }
        }

        if let pending {
            result.append(pending)
        }
        return result
    }

    private func delimiterIndex(in line: String) -> String.Index? {
        let equals = line.firstIndex(of: "=")
        let colon = line.firstIndex(of: ":")
        switch (equals, colon) {
        case (.some(let equals), .some(let colon)):
            return equals < colon ? equals : colon
        case (.some(let equals), .none):
            return equals
        case (.none, .some(let colon)):
            return colon
        case (.none, .none):
            return nil
        }
    }

    private func parseComposeValue(_ rawValue: String) throws -> String {
        let value = rawValue.trimmingCharacters(in: .whitespaces)
        guard let first = value.first else { return "" }

        if first == "'" || first == "\"" {
            let quote = first
            let start = value.index(after: value.startIndex)
            var result = ""
            var index = start
            var escaped = false

            while index < value.endIndex {
                let char = value[index]
                if escaped {
                    result.append(unescaped(char, quote: quote))
                    escaped = false
                    index = value.index(after: index)
                    continue
                }
                if char == "\\" {
                    escaped = true
                    index = value.index(after: index)
                    continue
                }
                if char == quote {
                    break
                }
                result.append(char)
                index = value.index(after: index)
            }

            return quote == "\"" ? try Interpolator(environment: environment).interpolate(result) : result
        }

        let withoutComment = stripUnquotedInlineComment(value).trimmingCharacters(in: .whitespaces)
        return try Interpolator(environment: environment).interpolate(withoutComment)
    }

    private func stripUnquotedInlineComment(_ value: String) -> String {
        var previousWasWhitespace = false
        for index in value.indices {
            let char = value[index]
            if char == "#", previousWasWhitespace {
                return String(value[..<index])
            }
            previousWasWhitespace = char.isWhitespace
        }
        return value
    }

    private func unescaped(_ char: Character, quote: Character) -> Character {
        guard quote == "\"" else {
            return char
        }
        switch char {
        case "n":
            return "\n"
        case "r":
            return "\r"
        case "t":
            return "\t"
        default:
            return char
        }
    }

    private func startsUnclosedSingleQuotedValue(_ line: String) -> Bool {
        singleQuotedValueStart(in: line) != nil && !singleQuotedValueIsClosed(in: line)
    }

    private func singleQuotedValueIsClosed(in line: String) -> Bool {
        guard let quote = singleQuotedValueStart(in: line) else {
            return true
        }
        var index = line.index(after: quote)
        var escaped = false
        while index < line.endIndex {
            let char = line[index]
            if escaped {
                escaped = false
            } else if char == "\\" {
                escaped = true
            } else if char == "'" {
                return true
            }
            index = line.index(after: index)
        }
        return false
    }

    private func singleQuotedValueStart(in line: String) -> String.Index? {
        guard let delimiter = delimiterIndex(in: line) else {
            return nil
        }
        var index = line.index(after: delimiter)
        while index < line.endIndex, line[index].isWhitespace {
            index = line.index(after: index)
        }
        guard index < line.endIndex, line[index] == "'" else {
            return nil
        }
        return index
    }
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}
