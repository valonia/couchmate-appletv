import Foundation

/// A JSON object as JSONSerialization gives it.
typealias JSON = [String: Any]

/// Reading values from JSON without fuss: missing or null gives nil, numbers can be NSNumber or strings.
extension Dictionary where Key == String, Value == Any {
    func str(_ k: String) -> String? {
        switch self[k] {
        case let s as String: return s.isEmpty ? nil : s
        case let n as NSNumber where !n.isBool: return n.stringValue
        default: return nil
        }
    }
    func string(_ k: String, _ fallback: String = "") -> String { str(k) ?? fallback }
    func bool(_ k: String, _ fallback: Bool = false) -> Bool {
        switch self[k] {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        case let s as String: return s == "true" || s == "1"
        default: return fallback
        }
    }
    func double(_ k: String) -> Double? {
        switch self[k] {
        case let n as NSNumber where !n.isBool: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }
    func int(_ k: String) -> Int? { double(k).map { Int($0) } }
    func int64(_ k: String) -> Int64 { double(k).map { Int64($0) } ?? 0 }
    func obj(_ k: String) -> JSON? { self[k] as? JSON }
    func arr(_ k: String) -> [Any]? { self[k] as? [Any] }
    func objects(_ k: String) -> [JSON] { (self[k] as? [Any])?.compactMap { $0 as? JSON } ?? [] }
    func has(_ k: String) -> Bool { if let v = self[k] { return !(v is NSNull) } else { return false } }
}

extension NSNumber {
    /// JSONSerialization gives booleans as NSNumber too – this tells them apart.
    var isBool: Bool { CFGetTypeID(self) == CFBooleanGetTypeID() }
}

func parseJSON(_ data: Data) -> Any? {
    try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
}

func toJSONString(_ v: Any) -> String {
    guard JSONSerialization.isValidJSONObject(v), let d = try? JSONSerialization.data(withJSONObject: v) else { return "{}" }
    return String(data: d, encoding: .utf8) ?? "{}"
}

/// Percent-encoding for query values.
func enc(_ s: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
}
