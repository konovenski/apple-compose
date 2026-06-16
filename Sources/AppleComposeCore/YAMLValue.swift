import Foundation
import Yams

public indirect enum YAMLValue: Equatable {
    case map([String: YAMLValue])
    case array([YAMLValue])
    case string(String)
    case bool(Bool)
    case int(Int, String)
    case double(Double)
    case null
    case reset(YAMLValue)
    case overrideValue(YAMLValue)

    public init(any value: Any?) throws {
        guard let value else {
            self = .null
            return
        }

        if value is NSNull {
            self = .null
        } else if let value = value as? Bool {
            self = .bool(value)
        } else if let value = value as? Int {
            self = .int(value, String(value))
        } else if let value = value as? Double {
            self = .double(value)
        } else if let value = value as? String {
            self = .string(value)
        } else if let value = value as? [Any?] {
            self = .array(try value.map { try YAMLValue(any: $0) })
        } else if let value = value as? [Any] {
            self = .array(try value.map { try YAMLValue(any: $0) })
        } else if let value = value as? [String: Any?] {
            var map: [String: YAMLValue] = [:]
            for (key, child) in value {
                map[key] = try YAMLValue(any: child)
            }
            self = .map(map)
        } else if let value = value as? [String: Any] {
            var map: [String: YAMLValue] = [:]
            for (key, child) in value {
                map[key] = try YAMLValue(any: child)
            }
            self = .map(map)
        } else if let value = value as? NSDictionary {
            var map: [String: YAMLValue] = [:]
            for (key, child) in value {
                guard let key = key as? String else {
                    throw ComposeError.invalidYAML("YAML map contains a non-string key: \(key)")
                }
                map[key] = try YAMLValue(any: child)
            }
            self = .map(map)
        } else if let value = value as? NSArray {
            self = .array(try value.map { try YAMLValue(any: $0) })
        } else if let value = value as? NSNumber {
            self = .double(value.doubleValue)
        } else {
            throw ComposeError.invalidYAML("Unsupported YAML value type: \(type(of: value))")
        }
    }

    public var map: [String: YAMLValue]? {
        switch self {
        case .map(let value): value
        case .reset(let value), .overrideValue(let value): value.map
        default: nil
        }
    }

    public var array: [YAMLValue]? {
        switch self {
        case .array(let value): value
        case .reset(let value), .overrideValue(let value): value.array
        default: nil
        }
    }

    public var string: String? {
        switch self {
        case .string(let value): value
        case .int(let value, _): String(value)
        case .double(let value): String(value)
        case .bool(let value): value ? "true" : "false"
        case .null, .map, .array: nil
        case .reset(let value), .overrideValue(let value): value.string
        }
    }

    public var bool: Bool? {
        switch self {
        case .bool(let value):
            value
        case .string(let value):
            switch value.lowercased() {
            case "true", "yes", "y", "1", "on": true
            case "false", "no", "n", "0", "off": false
            default: nil
            }
        case .int(let value, _):
            value != 0
        case .reset(let value), .overrideValue(let value):
            value.bool
        default:
            nil
        }
    }

    public var int: Int? {
        switch self {
        case .int(let value, _): value
        case .double(let value): Int(value)
        case .string(let value): Int(value)
        case .reset(let value), .overrideValue(let value): value.int
        default: nil
        }
    }

    public subscript(_ key: String) -> YAMLValue? {
        map?[key]
    }

    public func toAny() -> Any {
        switch self {
        case .map(let map):
            return Dictionary(uniqueKeysWithValues: map.map { ($0.key, $0.value.toAny()) })
        case .array(let array):
            return array.map { $0.toAny() }
        case .string(let value):
            return value
        case .bool(let value):
            return value
        case .int(let value, _):
            return value
        case .double(let value):
            return value
        case .null:
            return NSNull()
        case .reset(let value), .overrideValue(let value):
            return value.toAny()
        }
    }

    public func interpolated(with environment: [String: String]) throws -> YAMLValue {
        switch self {
        case .map(let map):
            return .map(try map.mapValues { try $0.interpolated(with: environment) })
        case .array(let array):
            return .array(try array.map { try $0.interpolated(with: environment) })
        case .string(let value):
            return .string(try Interpolator(environment: environment).interpolate(value))
        case .reset(let value):
            return .reset(try value.interpolated(with: environment))
        case .overrideValue(let value):
            return .overrideValue(try value.interpolated(with: environment))
        case .bool, .int, .double, .null:
            return self
        }
    }

    public init(node: Node) throws {
        let tag = nodeTagName(node)
        let value: YAMLValue

        switch node {
        case .mapping(let mapping):
            var result: [String: YAMLValue] = [:]
            for (keyNode, valueNode) in mapping {
                if isMergeKey(keyNode) {
                    for (key, value) in try mergedMappingValues(from: valueNode) {
                        result[key] = value
                    }
                    continue
                }
                guard let key = keyNode.string else {
                    throw ComposeError.invalidYAML("YAML map contains a non-string key")
                }
                result[key] = try YAMLValue(node: valueNode)
            }
            value = .map(result)
        case .sequence(let sequence):
            value = .array(try sequence.map { try YAMLValue(node: $0) })
        case .scalar(let scalar):
            let constructed = try YAMLValue(any: node.any)
            if case .int(let intValue, _) = constructed {
                value = .int(intValue, scalar.string)
            } else {
                value = constructed
            }
        case .alias:
            value = try YAMLValue(any: node.any)
        }

        if tag == "!reset" {
            self = .reset(value)
        } else if tag == "!override" {
            self = .overrideValue(value)
        } else {
            self = value
        }
    }
}

public enum ComposeError: Error, CustomStringConvertible, Equatable, Sendable {
    case invalidYAML(String)
    case invalidCompose(String)
    case invalidInterpolation(String)
    case missingComposeFile([String])
    case unsupported([CompatibilityIssue])
    case commandFailed(String, Int32)

    public var description: String {
        switch self {
        case .invalidYAML(let message):
            return "Invalid YAML: \(message)"
        case .invalidCompose(let message):
            return "Invalid Compose file: \(message)"
        case .invalidInterpolation(let message):
            return "Invalid interpolation: \(message)"
        case .missingComposeFile(let candidates):
            return "No Compose file found. Looked for: \(candidates.joined(separator: ", "))"
        case .unsupported(let issues):
            let rendered = issues.map { "- \($0.rendered)" }.joined(separator: "\n")
            return "Compose file uses features that cannot be represented exactly with Apple containers:\n\(rendered)"
        case .commandFailed(let command, let status):
            return "Command failed with exit status \(status): \(command)"
        }
    }
}

public func mergeComposeValues(base: YAMLValue, override: YAMLValue) -> YAMLValue {
    mergeComposeValues(base: base, override: override, path: [], mode: .composeFiles)
}

func mergeComposeSectionValues(section: String, base: YAMLValue, override: YAMLValue) -> YAMLValue {
    mergeComposeValues(base: base, override: override, path: [section], mode: .composeFiles)
}

func mergeComposeExtendsValues(base: YAMLValue, override: YAMLValue) -> YAMLValue {
    mergeComposeValues(base: base, override: override, path: [], mode: .extends)
}

private enum ComposeMergeMode {
    case composeFiles
    case extends
}

private func mergeComposeValues(base: YAMLValue, override: YAMLValue, path: [String], mode: ComposeMergeMode) -> YAMLValue {
    if case .reset(let value) = override {
        return resetDefault(for: value)
    }
    if case .overrideValue(let value) = override {
        return value
    }

    guard case .map(let baseMap) = base, case .map(let overrideMap) = override else {
        if case .array(let baseArray) = base, case .array(let overrideArray) = override {
            if shouldOverrideSequence(path: path) {
                return override
            }
            if let resource = uniqueResourceName(path: path) {
                return .array(mergeUniqueResourceSequence(base: baseArray, override: overrideArray, resource: resource, mode: mode))
            }
            if mode == .extends && shouldDeduplicateExtendsSequence(path: path) {
                return .array(mergedUniqueSequence(base: baseArray, override: overrideArray))
            }
            return .array(baseArray + overrideArray)
        }
        return override
    }

    var merged = baseMap
    for (key, value) in overrideMap {
        if let existing = merged[key] {
            merged[key] = mergeComposeValues(base: existing, override: value, path: path + [key], mode: mode)
        } else {
            merged[key] = value
        }
    }
    return .map(merged)
}

private func resetDefault(for value: YAMLValue) -> YAMLValue {
    switch value {
    case .array:
        return .array([])
    case .map:
        return .map([:])
    default:
        return .null
    }
}

private func shouldOverrideSequence(path: [String]) -> Bool {
    guard let last = path.last else { return false }
    if last == "command" || last == "entrypoint" {
        return true
    }
    return path.count >= 4 && path[path.count - 2] == "healthcheck" && last == "test"
}

private func uniqueResourceName(path: [String]) -> String? {
    guard path.count >= 3, path[0] == "services" else {
        return nil
    }
    let last = path[path.count - 1]
    if path.count >= 4,
       path[path.count - 2] == "blkio_config",
       ["device_read_bps", "device_read_iops", "device_write_bps", "device_write_iops"].contains(last) {
        return "blkio_device"
    }
    return ["ports", "volumes", "secrets", "configs", "devices"].contains(last) ? last : nil
}

private func shouldDeduplicateExtendsSequence(path: [String]) -> Bool {
    guard path.count >= 3, path[0] == "services" else {
        return false
    }
    let servicePath = Array(path.dropFirst(2))
    switch servicePath {
    case ["cap_add"],
         ["cap_drop"],
         ["device_cgroup_rules"],
         ["expose"],
         ["external_links"],
         ["security_opt"],
         ["deploy", "placement", "constraints"],
         ["deploy", "placement", "preferences"],
         ["deploy", "reservations", "generic_resources"],
         ["deploy", "resources", "reservations", "generic_resources"]:
        return true
    default:
        return false
    }
}

private func mergedUniqueSequence(base: [YAMLValue], override: [YAMLValue]) -> [YAMLValue] {
    var result: [YAMLValue] = []
    for item in base + override where !result.contains(item) {
        result.append(item)
    }
    return result
}

private func mergeUniqueResourceSequence(base: [YAMLValue], override: [YAMLValue], resource: String, mode: ComposeMergeMode) -> [YAMLValue] {
    var merged = base
    var indexes: [String: Int] = [:]
    for (index, item) in merged.enumerated() {
        if let key = uniqueResourceKey(item, resource: resource) {
            indexes[key] = index
        }
    }
    for item in override {
        guard let key = uniqueResourceKey(item, resource: resource), let index = indexes[key] else {
            merged.append(item)
            if let key = uniqueResourceKey(item, resource: resource) {
                indexes[key] = merged.count - 1
            }
            continue
        }
        merged[index] = mergeComposeValues(base: merged[index], override: item, path: [], mode: mode)
    }
    return merged
}

private func uniqueResourceKey(_ value: YAMLValue, resource: String) -> String? {
    switch resource {
    case "blkio_device":
        return blkioDevicePath(value)
    case "devices":
        return deviceTarget(value)
    case "volumes":
        return volumeTarget(value)
    case "secrets", "configs":
        return fileGrantTarget(value, resource: resource)
    case "ports":
        return portKey(value)
    default:
        return nil
    }
}

private func blkioDevicePath(_ value: YAMLValue) -> String? {
    value["path"]?.string
}

private func deviceTarget(_ value: YAMLValue) -> String? {
    if let target = value["target"]?.string {
        return target
    }
    if let source = value["source"]?.string {
        return source
    }
    guard let string = value.string else {
        return nil
    }
    let parts = string.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard parts.count >= 2 else {
        return string
    }
    return parts[1]
}

private func volumeTarget(_ value: YAMLValue) -> String? {
    if let target = value["target"]?.string {
        return target
    }
    guard let string = value.string else {
        return nil
    }
    let parts = string.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
    if parts.count == 1 {
        return parts[0]
    }
    return parts.count >= 2 ? parts[1] : nil
}

private func fileGrantTarget(_ value: YAMLValue, resource: String) -> String? {
    if let target = value["target"]?.string {
        return normalizedFileGrantTarget(target, resource: resource)
    }
    if let source = value["source"]?.string {
        return normalizedFileGrantTarget(source, resource: resource)
    }
    if let string = value.string {
        return normalizedFileGrantTarget(string, resource: resource)
    }
    return nil
}

private func normalizedFileGrantTarget(_ target: String, resource: String) -> String {
    guard !target.hasPrefix("/") else {
        return target
    }
    return resource == "secrets" ? "/run/secrets/\(target)" : "/\(target)"
}

private func portKey(_ value: YAMLValue) -> String? {
    if let raw = value.string {
        let parsed = parseComposePortString(raw)
        return [parsed.hostIP ?? "", parsed.target ?? "", parsed.published ?? "", parsed.protocolName ?? "tcp"].joined(separator: "|")
    }
    let hostIP = value["host_ip"]?.string ?? ""
    let target = value["target"]?.string ?? ""
    let published = value["published"]?.string ?? ""
    let proto = value["protocol"]?.string ?? "tcp"
    return [hostIP, target, published, proto].joined(separator: "|")
}

func parseComposePortString(_ raw: String) -> (hostIP: String?, target: String?, published: String?, protocolName: String?) {
    let pieces = raw.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
    let spec = pieces[0]
    let proto = pieces.count > 1 && !pieces[1].isEmpty ? pieces[1] : "tcp"
    let parts = spec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    switch parts.count {
    case 1:
        return (nil, parts[0], nil, proto)
    case 2:
        return (nil, parts[1], parts[0].isEmpty ? nil : parts[0], proto)
    default:
        let hostIP = parts.dropLast(2).joined(separator: ":")
        let published = parts[parts.count - 2]
        return (hostIP.isEmpty ? nil : hostIP, parts.last, published.isEmpty ? nil : published, proto)
    }
}

private func nodeTagName(_ node: Node) -> String {
    switch node {
    case .mapping(let mapping):
        return mapping.tag.description
    case .sequence(let sequence):
        return sequence.tag.description
    case .scalar(let scalar):
        return scalar.tag.description
    case .alias(let alias):
        return alias.tag.description
    }
}

private func isMergeKey(_ node: Node) -> Bool {
    node.tag.description == Tag.Name.merge.rawValue || node.string == "<<"
}

private func mergedMappingValues(from node: Node) throws -> [String: YAMLValue] {
    if case .mapping(let mapping) = node {
        return try mappingValues(mapping)
    }
    if case .sequence(let sequence) = node {
        var result: [String: YAMLValue] = [:]
        for item in sequence {
            guard case .mapping(let mapping) = item else { continue }
            for (key, value) in try mappingValues(mapping) {
                result[key] = value
            }
        }
        return result
    }
    return [:]
}

private func mappingValues(_ mapping: Node.Mapping) throws -> [String: YAMLValue] {
    var result: [String: YAMLValue] = [:]
    for (keyNode, valueNode) in mapping {
        if isMergeKey(keyNode) {
            for (key, value) in try mergedMappingValues(from: valueNode) {
                result[key] = value
            }
            continue
        }
        guard let key = keyNode.string else {
            throw ComposeError.invalidYAML("YAML map contains a non-string key")
        }
        result[key] = try YAMLValue(node: valueNode)
    }
    return result
}
