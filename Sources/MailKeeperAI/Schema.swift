import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The shape of a structured answer, for both providers: JSON Schema for the OpenAI-compatible
/// endpoint (`response_format`), a dynamic generation schema for Apple's on-device model.
public indirect enum AISchema: Sendable, Equatable {
    case object(name: String, properties: [Property])
    case string(description: String? = nil)
    /// One of fixed values.
    case choice(name: String, values: [String])
    case array(of: AISchema, max: Int? = nil)
    case integer(description: String? = nil)
    case boolean(description: String? = nil)

    public struct Property: Sendable, Equatable {
        public var name: String
        public var description: String?
        public var schema: AISchema
        public var optional: Bool

        public init(_ name: String, _ schema: AISchema, description: String? = nil, optional: Bool = false) {
            self.name = name
            self.schema = schema
            self.description = description
            self.optional = optional
        }
    }

    /// JSON Schema (strict: every property required, no others — optional ones may be null).
    public func jsonSchema() -> [String: Any] {
        switch self {
        case .object(_, let properties):
            var props: [String: Any] = [:]
            for p in properties {
                var s = p.schema.jsonSchema()
                if let d = p.description { s["description"] = d }
                if p.optional, let t = s["type"] as? String { s["type"] = [t, "null"] }
                props[p.name] = s
            }
            return ["type": "object", "properties": props, "required": properties.map(\.name), "additionalProperties": false]
        case .string(let d): return ["type": "string"].merging(d.map { ["description": $0] } ?? [:]) { a, _ in a }
        case .choice(_, let values): return ["type": "string", "enum": values]
        case .array(let item, let max):
            var s: [String: Any] = ["type": "array", "items": item.jsonSchema()]
            if let max { s["maxItems"] = max }
            return s
        case .integer(let d): return ["type": "integer"].merging(d.map { ["description": $0] } ?? [:]) { a, _ in a }
        case .boolean(let d): return ["type": "boolean"].merging(d.map { ["description": $0] } ?? [:]) { a, _ in a }
        }
    }

    public var name: String {
        if case .object(let n, _) = self { return n }
        if case .choice(let n, _) = self { return n }
        return "value"
    }

    #if canImport(FoundationModels)
    func dynamic() -> DynamicGenerationSchema {
        switch self {
        case .object(let name, let properties):
            return DynamicGenerationSchema(name: name, properties: properties.map {
                DynamicGenerationSchema.Property(name: $0.name, description: $0.description, schema: $0.schema.dynamic(), isOptional: $0.optional)
            })
        case .string: return DynamicGenerationSchema(type: String.self)
        case .choice(let name, let values): return DynamicGenerationSchema(name: name, anyOf: values)
        case .array(let item, let max): return DynamicGenerationSchema(arrayOf: item.dynamic(), maximumElements: max)
        case .integer: return DynamicGenerationSchema(type: Int.self)
        case .boolean: return DynamicGenerationSchema(type: Bool.self)
        }
    }
    #endif
}
