import Foundation

/// A parsed JSON value that keeps object keys in their original order
/// (including duplicates). Numbers keep their raw source text so no
/// precision is lost.
public indirect enum JSONNode: Sendable, Equatable {
    case object([(key: String, value: JSONNode)])
    case array([JSONNode])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    /// Iterative (explicit stack of node pairs) so deep values never overflow a small thread stack.
    public static func == (lhs: JSONNode, rhs: JSONNode) -> Bool {
        var pending = [(lhs, rhs)]
        while let (l, r) = pending.popLast() {
            switch (l, r) {
            case (.object(let lm), .object(let rm)):
                guard lm.count == rm.count else { return false }
                for (a, b) in zip(lm, rm) {
                    guard a.key == b.key else { return false }
                    pending.append((a.value, b.value))
                }
            case (.array(let la), .array(let ra)):
                guard la.count == ra.count else { return false }
                for (a, b) in zip(la, ra) { pending.append((a, b)) }
            case (.string(let a), .string(let b)): if a != b { return false }
            case (.number(let a), .number(let b)): if a != b { return false }
            case (.bool(let a), .bool(let b)): if a != b { return false }
            case (.null, .null): break
            default: return false
            }
        }
        return true
    }

    /// Multi-line, indented rendering. Empty containers print as `{}` / `[]`.
    /// Uses an explicit stack, so depth never depends on the thread's stack size.
    public func prettyPrinted(indent: Int = 2) -> String {
        let indent = max(indent, 0)
        var out = ""
        var stack: [(node: JSONNode, next: Int)] = []

        func open(_ node: JSONNode) {
            switch node {
            case .null: out += "null"
            case .bool(let b): out += b ? "true" : "false"
            case .number(let raw): out += raw
            case .string(let s): Self.writeEscaped(s, to: &out)
            case .array(let items):
                if items.isEmpty {
                    out += "[]"
                } else {
                    out += "["
                    stack.append((node, 0))
                }
            case .object(let members):
                if members.isEmpty {
                    out += "{}"
                } else {
                    out += "{"
                    stack.append((node, 0))
                }
            }
        }

        func pad(_ level: Int) -> String { String(repeating: " ", count: indent * level) }

        open(self)
        while let top = stack.last {
            let i = top.next
            switch top.node {
            case .array(let items):
                if i < items.count {
                    stack[stack.count - 1].next += 1
                    out += (i == 0 ? "\n" : ",\n") + pad(stack.count)
                    open(items[i])
                } else {
                    stack.removeLast()
                    out += "\n" + pad(stack.count) + "]"
                }
            case .object(let members):
                if i < members.count {
                    stack[stack.count - 1].next += 1
                    out += (i == 0 ? "\n" : ",\n") + pad(stack.count)
                    Self.writeEscaped(members[i].key, to: &out)
                    out += ": "
                    open(members[i].value)
                } else {
                    stack.removeLast()
                    out += "\n" + pad(stack.count) + "}"
                }
            default:
                stack.removeLast()
            }
        }
        return out
    }

    private static func writeEscaped(_ s: String, to out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case _ where scalar.value < 0x20:
                let hex = String(scalar.value, radix: 16, uppercase: false)
                out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default: out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
    }
}
