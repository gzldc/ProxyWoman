import FlowStore
import NIOCore
import NIOHTTP1

/// Event-loop-confined, consuming ownership of original parsed heads. It never owns a channel.
struct WebSocketPendingHandshake: ~Copyable {
    private let request: HTTPRequestHead
    private var response: HTTPResponseHead?
    private let requestCharge: WebSocketReservation
    private var responseCharge: WebSocketReservation?
    private let budget: WebSocketMemoryBudget
    init?(request: HTTPRequestHead, budget: WebSocketMemoryBudget) {
        guard request.headers.contains(name: "upgrade"),
              let charge = Self.reserve(request: request, response: nil, budget: budget, staging: false) else { return nil }
        self.init(request: request, budget: budget, charge: charge)
    }
    /// Initializes every stored property in one non-failable step. Swift 6.2.4's release
    /// optimizer (EarlyRedundantLoadElimination) crashes on the equivalent direct assignment
    /// inside the failable initializer of this noncopyable struct.
    private init(request: HTTPRequestHead, budget: WebSocketMemoryBudget, charge: consuming WebSocketReservation) {
        self.request = request; self.response = nil; self.requestCharge = charge
        self.responseCharge = nil; self.budget = budget
    }
    mutating func captureResponse(_ response: HTTPResponseHead) {
        guard self.response == nil, response.status == .switchingProtocols,
              let charge = Self.reserve(request: nil, response: response, budget: budget, staging: false) else { return }
        responseCharge = consume charge; self.response = response
    }
    consuming func begin(flowID: Int, coordinator: WebSocketCaptureCoordinator, eventLoop: EventLoop) -> ObservationHandle? {
        guard let response else { return nil }
        return coordinator.begin(flowID: flowID, request: request, response: response, eventLoop: eventLoop)
    }
    consuming func discard() {}
    static func reserve(request: HTTPRequestHead?, response: HTTPResponseHead?, budget: WebSocketMemoryBudget,
                        staging: Bool) -> WebSocketReservation? {
        var bytes = 0, fields = 0, negotiation = 0
        func add(_ value: Int, to total: inout Int) -> Bool {
            let sum = total.addingReportingOverflow(value); if sum.overflow { return false }; total = sum.partialValue; return true
        }
        func headers(_ headers: HTTPHeaders) -> Bool {
            for (name, value) in headers {
                guard add(1, to: &fields), add(name.utf8.count, to: &bytes), add(value.utf8.count, to: &bytes) else { return false }
                func equalsASCII(_ literal: String) -> Bool {
                    name.utf8.elementsEqual(literal.utf8) { byte, expected in
                        (byte >= 65 && byte <= 90 ? byte + 32 : byte) == expected
                    }
                }
                if equalsASCII("sec-websocket-extensions") || equalsASCII("sec-websocket-protocol") {
                    guard add(value.utf8.count, to: &negotiation) else { return false }
                }
            }
            return true
        }
        if let request {
            guard add(request.uri.utf8.count, to: &bytes), add(request.method.rawValue.utf8.count, to: &bytes),
                  add(32, to: &bytes), headers(request.headers) else { return nil }
        }
        if let response { guard add(32, to: &bytes), headers(response.headers) else { return nil } }
        if staging {
            let scalar = negotiation.multipliedReportingOverflow(by: 8)
            let container = negotiation.multipliedReportingOverflow(by: 4)
            let utf8 = bytes.multipliedReportingOverflow(by: 4)
            guard !scalar.overflow, !container.overflow, !utf8.overflow else { return nil }
            var scalars = scalar.partialValue, containers = container.partialValue, total = utf8.partialValue
            guard add(16, to: &scalars), add(8, to: &containers), add(4096, to: &total) else { return nil }
            return budget.reserveHandshakeMetadata(headCount: 2, headerFieldCount: fields,
                scalarStringCount: scalars, containerCount: containers, utf8Bytes: total)
        }
        return budget.reserveHandshakeMetadata(headCount: 1, headerFieldCount: fields, scalarStringCount: 4,
            containerCount: 2, utf8Bytes: bytes)
    }
}
