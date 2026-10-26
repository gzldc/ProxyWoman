import Crypto
import Foundation
import FlowStore
import NIOHTTP1

public struct WebSocketCompressionParameters: Sendable, Equatable {
    public let windowBits: Int
    public let noContextTakeover: Bool
    public init(windowBits: Int = 15, noContextTakeover: Bool = false) {
        self.windowBits = windowBits; self.noContextTakeover = noContextTakeover
    }
}

public struct WebSocketCompression: Sendable, Equatable {
    public let client: WebSocketCompressionParameters
    public let server: WebSocketCompressionParameters
    public init(client: WebSocketCompressionParameters = .init(), server: WebSocketCompressionParameters = .init()) {
        self.client = client; self.server = server
    }
    public func parameters(for direction: WebSocketDirection) -> WebSocketCompressionParameters {
        direction == .clientToServer ? client : server
    }
}

public enum WebSocketObservationMode: Sendable, Equatable {
    case messages(WebSocketCompression?)
    case opaqueFrames
    case disabled
}

public struct WebSocketHandshakeAssessment: Sendable, Equatable {
    public let handshake: WebSocketHandshake
    public let mode: WebSocketObservationMode

    /// Pure canonicalization; the caller must reserve staging space before evaluation.
    /// Original repeated headers are preserved. Diagnostics contain only fixed bounded codes.
    public static func evaluate(request: HTTPRequestHead, response: HTTPResponseHead) -> Self {
        let offeredFields = request.headers["Sec-WebSocket-Extensions"]
        let selectedFields = response.headers["Sec-WebSocket-Extensions"]
        let protocols = tokenList(request.headers["Sec-WebSocket-Protocol"])
        let selectedProtocols = tokenList(response.headers["Sec-WebSocket-Protocol"])
        var handshake = WebSocketHandshake(
            requestMethod: request.method.rawValue,
            version: "HTTP/\(request.version.major).\(request.version.minor)",
            requestHeaders: request.headers.map { HeaderField(name: $0.name, value: $0.value) },
            responseHeaders: response.headers.map { HeaderField(name: $0.name, value: $0.value) },
            responseStatus: Int(response.status.code), offeredProtocols: protocols ?? [],
            selectedProtocol: selectedProtocols?.first, offeredExtensions: offeredFields, selectedExtensions: selectedFields, requestURI: request.uri)
        func result(_ status: WebSocketHandshakeStatus, _ mode: WebSocketObservationMode, _ code: String? = nil) -> Self {
            handshake.assessment = status
            handshake.diagnostics = code.map { [WebSocketDiagnostic(code: $0)] } ?? []
            return Self(handshake: handshake, mode: mode)
        }
        guard request.method == .GET, request.version == .http1_1, response.version == .http1_1,
              let host = single(request.headers, "Host"), !host.isEmpty,
              single(request.headers, "Sec-WebSocket-Version") == "13",
              let key = single(request.headers, "Sec-WebSocket-Key"),
              let keyBytes = Data(base64Encoded: key), keyBytes.count == 16,
              hasToken(request.headers, "Connection", "upgrade"),
              hasToken(request.headers, "Upgrade", "websocket"),
              response.status.code == 101,
              hasToken(response.headers, "Connection", "upgrade"),
              hasToken(response.headers, "Upgrade", "websocket") else {
            return result(.invalid, .disabled, "invalidHandshake")
        }
        let expected = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        guard single(response.headers, "Sec-WebSocket-Accept") == expected,
              let protocols, Set(protocols).count == protocols.count,
              let selectedProtocols, selectedProtocols.count <= 1,
              response.headers["Sec-WebSocket-Protocol"].count <= 1,
              selectedProtocols.allSatisfy(protocols.contains) else {
            return result(.invalid, .disabled, "invalidAcceptOrProtocol")
        }
        guard let offered = try? WebSocketExtensionParser.parse(offeredFields),
              let selected = try? WebSocketExtensionParser.parse(selectedFields) else {
            return result(.negotiationUnverified, .disabled, "invalidExtensionGrammar")
        }
        if selected.isEmpty { return result(.verified, .messages(nil)) }
        var compression: WebSocketCompression?
        for selection in selected {
            let candidates = offered.filter { $0.name == selection.name }
            guard !candidates.isEmpty else { return result(.negotiationUnverified, .disabled, "unofferedExtension") }
            if selection.name == "permessage-deflate" {
                guard compression == nil, let responseParameters = DeflateParameters(selection, response: true),
                      candidates.contains(where: { offer in
                          guard let requestParameters = DeflateParameters(offer, response: false) else { return false }
                          return responseParameters.matches(requestParameters)
                      }) else { return result(.negotiationUnverified, .disabled, "invalidDeflateNegotiation") }
                compression = responseParameters.compression
            }
        }
        guard selected.count == 1, selected[0].name == "permessage-deflate" else {
            return result(.opaqueExtension, .opaqueFrames, "opaqueExtension")
        }
        return result(.verified, .messages(compression))
    }

    private static func single(_ headers: HTTPHeaders, _ name: String) -> String? {
        let values = headers[name]
        return values.count == 1 ? values[0].trimmingCharacters(in: CharacterSet(charactersIn: " \t")) : nil
    }
    private static func tokenList(_ fields: [String]) -> [String]? {
        var tokens: [String] = []
        for field in fields {
            for component in field.split(separator: ",", omittingEmptySubsequences: false) {
                let token = component.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
                guard !token.isEmpty, token.utf8.allSatisfy(WebSocketExtensionParser.isTokenByte) else { return nil }
                tokens.append(token)
            }
        }
        return tokens
    }
    private static func hasToken(_ headers: HTTPHeaders, _ name: String, _ token: String) -> Bool {
        tokenList(headers[name])?.contains { $0.lowercased() == token } == true
    }

    private struct DeflateParameters {
        var serverNo = false
        var clientNo = false
        var serverWindow: Int?
        var clientWindow: Int?
        var hasClientWindow = false
        init?(_ offer: WebSocketExtensionOffer, response: Bool) {
            var names: Set<String> = []
            for parameter in offer.parameters {
                guard names.insert(parameter.name).inserted else { return nil }
                switch parameter.name {
                case "server_no_context_takeover", "client_no_context_takeover":
                    guard parameter.value == nil else { return nil }
                    if parameter.name == "server_no_context_takeover" { serverNo = true } else { clientNo = true }
                case "server_max_window_bits", "client_max_window_bits":
                    if parameter.name == "client_max_window_bits" { hasClientWindow = true }
                    if let value = parameter.value {
                        guard let bits = Int(value), (8...15).contains(bits), String(bits) == value else { return nil }
                        if parameter.name == "server_max_window_bits" { serverWindow = bits } else { clientWindow = bits }
                    } else if response || parameter.name == "server_max_window_bits" { return nil }
                default: return nil
                }
            }
        }
        func matches(_ offer: Self) -> Bool {
            if offer.serverNo && !serverNo { return false }
            if let bound = offer.serverWindow, serverWindow == nil || serverWindow! > bound { return false }
            if hasClientWindow && !offer.hasClientWindow { return false }
            // client offer values are hints, not constraints on the actual response.
            return true
        }
        var compression: WebSocketCompression {
            .init(client: .init(windowBits: clientWindow ?? 15, noContextTakeover: clientNo),
                  server: .init(windowBits: serverWindow ?? 15, noContextTakeover: serverNo))
        }
    }
}
