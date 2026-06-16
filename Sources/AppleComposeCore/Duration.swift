import Foundation

func composeDurationSeconds(_ value: String?) -> Int? {
    guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
        return nil
    }
    if let int = Int(raw) {
        guard int >= 0 else {
            return nil
        }
        return int
    }

    var index = raw.startIndex
    var total = 0.0
    var parsedComponent = false

    while index < raw.endIndex {
        let numberStart = index
        var dotSeen = false
        while index < raw.endIndex {
            let char = raw[index]
            if char == "." && !dotSeen {
                dotSeen = true
                index = raw.index(after: index)
            } else if char.isNumber {
                index = raw.index(after: index)
            } else {
                break
            }
        }
        guard numberStart < index, let amount = Double(raw[numberStart..<index]), amount >= 0 else {
            return nil
        }

        let unitStart = index
        while index < raw.endIndex, raw[index].isLetter {
            index = raw.index(after: index)
        }
        guard unitStart < index else {
            return nil
        }

        switch raw[unitStart..<index] {
        case "h":
            total += amount * 3600
        case "m":
            total += amount * 60
        case "s":
            total += amount
        case "ms":
            total += amount / 1000
        case "us":
            total += amount / 1_000_000
        case "ns":
            total += amount / 1_000_000_000
        default:
            return nil
        }
        parsedComponent = true
    }

    guard parsedComponent else {
        return nil
    }
    return Int(ceil(total))
}

func composePullPolicyIntervalSeconds(_ policy: String?) -> Int? {
    guard let raw = policy?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else {
        return nil
    }
    switch raw {
    case "daily":
        return 24 * 60 * 60
    case "weekly":
        return 7 * 24 * 60 * 60
    default:
        guard raw.hasPrefix("every_") else {
            return nil
        }
        return composePullPolicyDurationSeconds(String(raw.dropFirst("every_".count)))
    }
}

func composePullPolicyRefreshAfterSeconds(_ value: String?) -> Int? {
    guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else {
        return nil
    }
    return composePullPolicyDurationSeconds(raw)
}

private func composePullPolicyDurationSeconds(_ raw: String) -> Int? {
    guard !raw.isEmpty else {
        return nil
    }

    var index = raw.startIndex
    var total = 0.0
    var parsedComponent = false

    while index < raw.endIndex {
        let numberStart = index
        var dotSeen = false
        while index < raw.endIndex {
            let char = raw[index]
            if char == "." && !dotSeen {
                dotSeen = true
                index = raw.index(after: index)
            } else if char.isNumber {
                index = raw.index(after: index)
            } else {
                break
            }
        }
        guard numberStart < index, let amount = Double(raw[numberStart..<index]), amount >= 0 else {
            return nil
        }

        let unitStart = index
        while index < raw.endIndex, raw[index].isLetter {
            index = raw.index(after: index)
        }
        guard unitStart < index else {
            return nil
        }

        switch raw[unitStart..<index] {
        case "w":
            total += amount * 7 * 24 * 60 * 60
        case "d":
            total += amount * 24 * 60 * 60
        case "h":
            total += amount * 60 * 60
        case "m":
            total += amount * 60
        case "s":
            total += amount
        default:
            return nil
        }
        parsedComponent = true
    }

    guard parsedComponent, total > 0 else {
        return nil
    }
    return Int(ceil(total))
}
