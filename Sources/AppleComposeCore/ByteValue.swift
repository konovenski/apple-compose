import Foundation

func composeByteValueBytes(_ value: String, allowUnlimitedSwap: Bool = false) -> Int64? {
    let raw = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !raw.isEmpty else {
        return nil
    }
    if allowUnlimitedSwap && raw == "-1" {
        return -1
    }

    var suffixStart = raw.endIndex
    while suffixStart > raw.startIndex {
        let previous = raw.index(before: suffixStart)
        guard raw[previous].isLetter else {
            break
        }
        suffixStart = previous
    }
    let numberPart = raw[..<suffixStart]
    let suffix = raw[suffixStart...]
    guard !numberPart.isEmpty,
          let number = Double(numberPart),
          number.isFinite,
          number >= 0 else {
        return nil
    }

    let multiplier: Double
    switch suffix {
    case "":
        multiplier = 1
    case "b":
        multiplier = 1
    case "k", "kb":
        multiplier = 1_024
    case "m", "mb":
        multiplier = 1_024 * 1_024
    case "g", "gb":
        multiplier = 1_024 * 1_024 * 1_024
    case "t", "tb":
        multiplier = 1_024 * 1_024 * 1_024 * 1_024
    case "p", "pb":
        multiplier = 1_024 * 1_024 * 1_024 * 1_024 * 1_024
    default:
        return nil
    }

    let bytes = (number * multiplier).rounded(.towardZero)
    guard bytes >= 0, bytes <= Double(Int64.max) else {
        return nil
    }
    return Int64(bytes)
}

func normalizedComposeByteValue(_ value: String, allowUnlimitedSwap: Bool = false) -> String? {
    guard let bytes = composeByteValueBytes(value, allowUnlimitedSwap: allowUnlimitedSwap) else {
        return nil
    }
    return String(bytes)
}
