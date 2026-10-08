import Foundation

/// A loosely-typed JSON value, used for ADF node/mark attributes.
nonisolated enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let value): return value
        case .number(let value): return value == value.rounded() ? String(Int(value)) : String(value)
        case .bool(let value): return String(value)
        default: return nil
        }
    }

    var intValue: Int? {
        switch self {
        case .number(let value): return Int(value)
        case .string(let value): return Int(value)
        default: return nil
        }
    }
}

/// Atlassian Document Format node. Descriptions and comments in the v3 API
/// are ADF trees rather than wiki markup. Encodes back to the same shape,
/// leaving out fields that are nil, so a tree can be edited and sent back.
nonisolated struct ADFNode: Codable, Hashable, Sendable {
    let type: String
    let text: String?
    let attrs: [String: JSONValue]?
    let marks: [ADFMark]?
    let content: [ADFNode]?

    init(type: String, text: String? = nil, attrs: [String: JSONValue]? = nil, marks: [ADFMark]? = nil, content: [ADFNode]? = nil) {
        self.type = type
        self.text = text
        self.attrs = attrs
        self.marks = marks
        self.content = content
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(attrs, forKey: .attrs)
        try container.encodeIfPresent(marks, forKey: .marks)
        try container.encodeIfPresent(content, forKey: .content)
    }

    func attr(_ name: String) -> String? { attrs?[name]?.stringValue }
    func intAttr(_ name: String) -> Int? { attrs?[name]?.intValue }

    var children: [ADFNode] { content ?? [] }

    /// Plain-text projection, useful for previews and fallbacks.
    var plainText: String {
        if type == "text" { return text ?? "" }
        if type == "hardBreak" { return "\n" }
        if type == "mention" || type == "emoji" { return attr("text") ?? "" }
        if type == "inlineCard" {
            // Issue cards read as their key; other cards as their address.
            guard let url = attr("url") else { return "" }
            if let match = url.firstMatch(of: /\/browse\/([A-Za-z][A-Za-z0-9_]*-[0-9]+)/) { return String(match.1).uppercased() }
            return url
        }
        let inner = children.map(\.plainText)
        switch type {
        case "paragraph", "heading", "listItem", "codeBlock", "blockquote":
            return inner.joined() + "\n"
        default:
            return inner.joined()
        }
    }
}

nonisolated struct ADFMark: Codable, Hashable, Sendable {
    let type: String
    let attrs: [String: JSONValue]?

    init(type: String, attrs: [String: JSONValue]? = nil) {
        self.type = type
        self.attrs = attrs
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(attrs, forKey: .attrs)
    }

    func attr(_ name: String) -> String? { attrs?[name]?.stringValue }
}
