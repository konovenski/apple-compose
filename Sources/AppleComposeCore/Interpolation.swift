import Foundation

struct Interpolator {
    let environment: [String: String]

    func interpolate(_ input: String) throws -> String {
        var result = ""
        var index = input.startIndex

        while index < input.endIndex {
            let char = input[index]
            guard char == "$" else {
                result.append(char)
                index = input.index(after: index)
                continue
            }

            let next = input.index(after: index)
            guard next < input.endIndex else {
                result.append(char)
                index = next
                continue
            }

            if input[next] == "$" {
                result.append("$")
                index = input.index(after: next)
                continue
            }

            if input[next] == "{" {
                let start = input.index(after: next)
                guard let close = closingBraceIndex(in: input, expressionStart: start) else {
                    throw ComposeError.invalidInterpolation("Missing closing brace in '\(input)'")
                }
                let expression = String(input[start..<close])
                result += try expand(expression)
                index = input.index(after: close)
                continue
            }

            if isVariableStart(input[next]) {
                var end = input.index(after: next)
                while end < input.endIndex, isVariableBody(input[end]) {
                    end = input.index(after: end)
                }
                let name = String(input[next..<end])
                result += environment[name] ?? ""
                index = end
                continue
            }

            result.append(char)
            index = next
        }

        return result
    }

    private func closingBraceIndex(in input: String, expressionStart: String.Index) -> String.Index? {
        var depth = 1
        var index = expressionStart
        while index < input.endIndex {
            let char = input[index]
            if char == "$" {
                let next = input.index(after: index)
                guard next < input.endIndex else {
                    index = next
                    continue
                }
                if input[next] == "$" {
                    index = input.index(after: next)
                    continue
                }
                if input[next] == "{" {
                    depth += 1
                    index = input.index(after: next)
                    continue
                }
            }
            if char == "}" {
                depth -= 1
                if depth == 0 {
                    return index
                }
            }
            index = input.index(after: index)
        }
        return nil
    }

    private func expand(_ expression: String) throws -> String {
        guard let first = expression.first, isVariableStart(first) else {
            throw ComposeError.invalidInterpolation("Invalid variable expression '\(expression)'")
        }

        var nameEnd = expression.index(after: expression.startIndex)
        while nameEnd < expression.endIndex, isVariableBody(expression[nameEnd]) {
            nameEnd = expression.index(after: nameEnd)
        }
        let name = String(expression[..<nameEnd])
        guard nameEnd < expression.endIndex else {
            return environment[name] ?? ""
        }

        let remainder = expression[nameEnd...]
        let operators = [":-", "-", ":?", "?", ":+", "+"]
        for op in operators {
            if remainder.hasPrefix(op) {
                let wordStart = expression.index(nameEnd, offsetBy: op.count)
                let word = String(expression[wordStart...])
                let value = environment[name]
                let isSet = value != nil
                let isNonEmpty = !(value ?? "").isEmpty

                switch op {
                case ":-":
                    return isNonEmpty ? value! : try interpolate(word)
                case "-":
                    return isSet ? value! : try interpolate(word)
                case ":?":
                    if isNonEmpty { return value! }
                    let message = try interpolate(word)
                    throw ComposeError.invalidInterpolation(message.isEmpty ? "\(name) is required" : message)
                case "?":
                    if isSet { return value! }
                    let message = try interpolate(word)
                    throw ComposeError.invalidInterpolation(message.isEmpty ? "\(name) is required" : message)
                case ":+":
                    return isNonEmpty ? try interpolate(word) : ""
                case "+":
                    return isSet ? try interpolate(word) : ""
                default:
                    break
                }
            }
        }

        throw ComposeError.invalidInterpolation("Invalid variable expression '\(expression)'")
    }

    private func isVariableStart(_ char: Character) -> Bool {
        char == "_" || char.isLetter
    }

    private func isVariableBody(_ char: Character) -> Bool {
        char == "_" || char.isLetter || char.isNumber
    }
}

public struct DotEnv {
    public static func load(paths: [URL], environment baseEnvironment: [String: String] = [:]) throws -> [String: String] {
        var values: [String: String] = [:]
        for path in paths where FileManager.default.fileExists(atPath: path.path) {
            let data = try String(contentsOf: path, encoding: .utf8)
            let parserEnvironment = baseEnvironment.merging(values) { _, local in local }
            let parsed = try ComposeEnvFileParser(environment: parserEnvironment, format: .compose).parse(data)
            for (key, value) in parsed {
                values[key] = value ?? ""
            }
        }
        return values
    }

    public static func processEnvironment() -> [String: String] {
        ProcessInfo.processInfo.environment
    }
}
