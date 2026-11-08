import Foundation

/// A property-list value from UserDefaults in a form that encodes to JSON deterministically
/// (keeps Bool vs Int vs Double apart, which `NSNumber` bridging would blur).
indirect enum DefaultsValue: Codable, Hashable, Sendable {
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case data(Data)
    case date(Date)
    case array([DefaultsValue])
    case dictionary([String: DefaultsValue])

    init?(plist: Any) {
        switch plist {
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(number as CFNumber) {
                self = .double(number.doubleValue)
            } else {
                self = .int(number.int64Value)
            }
        case let data as Data:
            self = .data(data)
        case let date as Date:
            self = .date(date)
        case let array as [Any]:
            var values: [DefaultsValue] = []
            for element in array {
                guard let value = DefaultsValue(plist: element) else { return nil }
                values.append(value)
            }
            self = .array(values)
        case let dictionary as [String: Any]:
            var values: [String: DefaultsValue] = [:]
            for (key, element) in dictionary {
                guard let value = DefaultsValue(plist: element) else { return nil }
                values[key] = value
            }
            self = .dictionary(values)
        default:
            return nil
        }
    }

    var plistValue: Any {
        switch self {
        case .bool(let value): return NSNumber(value: value)
        case .int(let value): return NSNumber(value: value)
        case .double(let value): return NSNumber(value: value)
        case .string(let value): return value
        case .data(let value): return value
        case .date(let value): return value
        case .array(let values): return values.map(\.plistValue)
        case .dictionary(let values): return values.mapValues(\.plistValue)
        }
    }

    private enum Key: String, CodingKey { case b, i, f, s, data, date, a, o }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        switch self {
        case .bool(let value): try container.encode(value, forKey: .b)
        case .int(let value): try container.encode(value, forKey: .i)
        case .double(let value): try container.encode(value, forKey: .f)
        case .string(let value): try container.encode(value, forKey: .s)
        case .data(let value): try container.encode(value, forKey: .data)
        case .date(let value): try container.encode(value, forKey: .date)
        case .array(let values): try container.encode(values, forKey: .a)
        case .dictionary(let values): try container.encode(values, forKey: .o)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        if let value = try container.decodeIfPresent(Bool.self, forKey: .b) { self = .bool(value) }
        else if let value = try container.decodeIfPresent(Int64.self, forKey: .i) { self = .int(value) }
        else if let value = try container.decodeIfPresent(Double.self, forKey: .f) { self = .double(value) }
        else if let value = try container.decodeIfPresent(String.self, forKey: .s) { self = .string(value) }
        else if let value = try container.decodeIfPresent(Data.self, forKey: .data) { self = .data(value) }
        else if let value = try container.decodeIfPresent(Date.self, forKey: .date) { self = .date(value) }
        else if let value = try container.decodeIfPresent([DefaultsValue].self, forKey: .a) { self = .array(value) }
        else if let value = try container.decodeIfPresent([String: DefaultsValue].self, forKey: .o) { self = .dictionary(value) }
        else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown defaults value"))
        }
    }
}
