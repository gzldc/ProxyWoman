import FlowStore
import Foundation
import Localization
import NIOCore
import NIOHTTP1
import NIOSSL
import RulesEngine

/// HTTP/1 connection adapter: pipelining, local CONNECT/status responses and socket handoff.
/// Request-specific forwarding, recording and retries live in HTTPExchange.
final class ProxyHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    typealias ConnectionFactory = UpstreamConnectionFactory
    enum Mode { case forwardProxy, mitm(host: String, port: Int) }
    static var upgradeNote: String { L10n.string("proxyFailure.webSocketUpgradeNote") }
    static let connectEstablished = "HTTP/1.1 200 Connection Established\r\n\r\n"
    static var upstreamHandshakeTimeout: String { L10n.string("proxyFailure.upstreamTLSTimeout") }
    static let clientLookupGrace: TimeAmount = .milliseconds(50)
    static let discardUploadTimeout: TimeAmount = .seconds(2)
    private let mode: Mode
    let environment: ProxyEnvironment
    private let connector: UpstreamConnector
    private let connectionFactory: ConnectionFactory?
    private let inheritedClientLookup: EventLoopFuture<ClientApp?>?
    private(set) var connection: ClientConnectionContext?
    private(set) var context: ChannelHandlerContext?
    private var exchange: HTTPExchange?
    var localExchange: LocalExchange?
    private var queuedParts = CircularBuffer<(part: HTTPServerRequestPart, bytes: Int)>()
    private var queuedBytes = 0
    private var clientReading = true
    private var exchangeReading = true
    private var closing = false
    private var discardingInput = false
    private var requestReadBatch = false

    init(mode: Mode, environment: ProxyEnvironment, inheritedClientLookup: EventLoopFuture<ClientApp?>? = nil,
         connectionFactory: ConnectionFactory? = nil, inheritedConnection: ClientConnectionContext? = nil) {
        self.mode = mode
        self.environment = environment
        self.connector = UpstreamConnector(configuration: environment.configuration, traffic: environment.traffic)
        self.inheritedClientLookup = inheritedClientLookup
        self.connectionFactory = connectionFactory
        self.connection = inheritedConnection
    }
    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        if context.channel.isActive { startConnection(context) }
    }
    func handlerRemoved(context: ChannelHandlerContext) { clearQueuedParts(); self.context = nil }
    func channelActive(context: ChannelHandlerContext) { startConnection(context); context.fireChannelActive() }
    private func startConnection(_ context: ChannelHandlerContext) {
        guard connection == nil else { return }
        let lookup: EventLoopFuture<ClientApp?>
        if let inheritedClientLookup { lookup = inheritedClientLookup }
        else if let clientPort = context.channel.remoteAddress?.port, let proxyPort = context.channel.localAddress?.port {
            lookup = environment.clientLookup.lookup(clientPort: clientPort, proxyPort: proxyPort, on: context.eventLoop)
        } else { lookup = context.eventLoop.makeSucceededFuture(nil) }
        connection = ClientConnectionContext(channel: context.channel, environment: environment, clientLookup: lookup,
                                               connectionFactory: connectionFactory)
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !closing else { return }
        requestReadBatch = true
        let part = unwrapInboundIn(data)
        if exchange?.requestComplete == true || localExchange?.requestComplete == true {
            appendQueuedPart(part)
            updateClientReading()
        } else { process(part) }
    }
    func channelReadComplete(context: ChannelHandlerContext) {
        requestReadBatch = false
        exchange?.requestReadComplete()
        context.fireChannelReadComplete()
    }
    func channelWritabilityChanged(context: ChannelHandlerContext) {
        exchange?.downstreamWritabilityChanged(context.channel.isWritable)
        context.fireChannelWritabilityChanged()
    }
    func channelInactive(context: ChannelHandlerContext) {
        closing = true
        connection?.close(error: nil)
        exchange = nil
        localExchange = nil
        clearQueuedParts()
        context.fireChannelInactive()
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }

    private func process(_ part: HTTPServerRequestPart) {
        if let exchange {
            if requestReadBatch { exchange.requestReadStarted() }
            exchange.receiveRequest(part)
        }
        else if let localExchange {
            if case .end = part {
                localExchange.requestComplete = true
                if localExchange.isConnect { beginConnect(localExchange) }
                else { finishLocal(localExchange) }
            }
        } else if case .head(let head) = part { startExchange(head) }
    }
    private func startExchange(_ head: HTTPRequestHead) {
        guard connection?.permitsExchange == true else { closeClient(); return }
        switch mode {
        case .forwardProxy:
            if head.method == .CONNECT { startConnect(head); return }
            if let pem = environment.configuration.rootCertificatePEM, CertificateDownload.matches(head.uri) {
                respondWithCertificate(to: head, pem: pem)
                return
            }
            guard let target = RequestTarget(absoluteForm: head.uri) else {
                if head.uri.hasPrefix("/") {
                    respondLocally(to: head, status: .ok, body: L10n.format("proxyFailure.proxyRunning", environment.configuration.productName))
                } else { respondLocally(to: head, status: .badRequest, body: L10n.format("proxyFailure.unsupportedRequest", head.method.rawValue, head.uri)) }
                return
            }
            startProxiedExchange(head, target: target, scheme: "http")
        case .mitm(let host, let port):
            guard head.uri.hasPrefix("/") else {
                respondLocally(to: head, status: .badRequest, body: L10n.format("proxyFailure.unsupportedRequest", head.method.rawValue, head.uri))
                return
            }
            startProxiedExchange(head, target: RequestTarget(host: host, port: port, originForm: head.uri, defaultPort: 443),
                                 scheme: "https")
        }
    }
    private func startProxiedExchange(_ head: HTTPRequestHead, target: RequestTarget, scheme: String) {
        guard let context, let connection else { return }
        let writer = Writer(owner: self, channel: context.channel)
        exchange = HTTPExchange(requestHead: head, target: target, scheme: scheme, downstream: writer,
            connection: connection, transport: .init(downstreamRequest: HTTPWireVersion(head.version)), requestReadBatch: requestReadBatch)
        exchange?.execute()
        updateClientReading()
    }
    private func respondLocally(to head: HTTPRequestHead, status: HTTPResponseStatus, body: String) {
        guard connection?.admitLocalOperation() == true else { closeClient(); return }
        let exchange = LocalExchange(requestHead: head, target: nil)
        localExchange = exchange
        writeLocalResponse(status: status, body: body, for: exchange)
        updateClientReading()
    }
    private func respondWithCertificate(to head: HTTPRequestHead, pem: String) {
        guard connection?.admitLocalOperation() == true else { closeClient(); return }
        let exchange = LocalExchange(requestHead: head, target: nil)
        localExchange = exchange
        writeLocalResponse(
            status: .ok, body: pem, for: exchange, contentType: CertificateDownload.contentType,
            extraHeaders: [("Content-Disposition", "attachment; filename=\"\(CertificateDownload.fileName)\"")])
        updateClientReading()
    }
    private func writeLocalResponse(status: HTTPResponseStatus, body: String, for exchange: LocalExchange,
                                    contentType: String = "text/plain; charset=utf-8",
                                    extraHeaders: [(String, String)] = []) {
        guard let context else { return }
        let bytes = ByteBuffer(string: body)
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: contentType)
        headers.add(contentsOf: extraHeaders)
        headers.add(name: "Content-Length", value: String(bytes.readableBytes))
        if !exchange.keepAlive { headers.add(name: "Connection", value: "close") }
        else if exchange.requestHead.version == .http1_0 { headers.add(name: "Connection", value: "keep-alive") }
        let version: HTTPVersion = exchange.requestHead.version == .http1_0 ? .http1_0 : .http1_1
        context.write(wrapOutboundOut(.head(.init(version: version, status: status, headers: headers))), promise: nil)
        if exchange.requestHead.method != .HEAD { context.write(wrapOutboundOut(.body(.byteBuffer(bytes))), promise: nil) }
        exchange.lastClientWrite = context.writeAndFlush(wrapOutboundOut(.end(nil)))
        exchange.responseComplete = true
        finishLocal(exchange)
    }
    private func targetDescription(_ exchange: LocalExchange) -> String { exchange.target?.authority ?? "" }
    private func localFailure(_ exchange: LocalExchange, message: String) {
        writeLocalResponse(status: .badGateway, body: HTTPLocalFailureText.page(productName: environment.configuration.productName,
                                                                               message: message), for: exchange)
    }
    private func finishLocal(_ exchange: LocalExchange) {
        guard localExchange === exchange, exchange.requestComplete, exchange.responseComplete else { return }
        localExchange = nil
        let connection = self.connection
        exchange.lastClientWrite?.assumeIsolated().whenComplete { _ in connection?.finishLocalOperation() }
        finish(keepAlive: exchange.keepAlive, after: exchange.lastClientWrite, discardUpload: false)
    }
    private func finish(keepAlive: Bool, after write: EventLoopFuture<Void>?, discardUpload: Bool) {
        exchange = nil
        exchangeReading = true
        if discardUpload { closeAfterDiscardingUpload(after: write); return }
        guard keepAlive else { closeClient(after: write); return }
        while !closing, exchange?.requestComplete != true, localExchange?.requestComplete != true,
              let entry = queuedParts.popFirst() {
            queuedBytes -= entry.bytes
            connection?.releasePendingBytes(entry.bytes)
            process(entry.part)
        }
        updateClientReading()
    }
    func closeAfterDiscardingUpload(after write: EventLoopFuture<Void>?) {
        guard let context else { return }
        closing = true
        discardingInput = true
        clearQueuedParts()
        updateClientReading()
        (write ?? context.eventLoop.makeSucceededVoidFuture()).assumeIsolated().whenComplete { _ in
            context.close(mode: .output, promise: nil)
            context.eventLoop.assumeIsolated().scheduleTask(in: Self.discardUploadTimeout) { context.close(promise: nil) }
        }
    }
    func closeClient(after write: EventLoopFuture<Void>? = nil, reset: Bool = false) {
        guard let context else { return }
        closing = true
        clearQueuedParts()
        updateClientReading()
        if reset { RuleConnectionClose.reset(context.channel) }
        else if let write { write.assumeIsolated().whenComplete { _ in context.close(promise: nil) } }
        else { context.close(promise: nil) }
    }
    /// The whole h1 successor queue uses one exchange cap plus the shared context budget.
    /// Each retained control part costs at least one byte, so empty parts cannot grow it for free.
    private func appendQueuedPart(_ part: HTTPServerRequestPart) {
        guard let connection else { return }
        var count = 1
        func charge(_ value: Int) {
            let sum = count.addingReportingOverflow(value)
            count = sum.overflow ? Int.max : sum.partialValue
        }
        switch part {
        case .head(let head):
            charge(head.uri.utf8.count); charge(head.method.rawValue.utf8.count)
            for field in head.headers { charge(32); charge(field.name.utf8.count); charge(field.value.utf8.count) }
        case .body(let bytes):
            guard bytes.readableBytes > 0 else { return }
            count = bytes.readableBytes
        case .end(let fields):
            for field in fields ?? HTTPHeaders() { charge(32); charge(field.name.utf8.count); charge(field.value.utf8.count) }
        }
        guard count <= connection.limits.pendingBytesPerExchange - queuedBytes,
              connection.reservePendingBytes(count) else {
            closing = true
            clearQueuedParts()
            connection.close(error: HTTPTransportError.pendingBytesExceeded)
            context?.close(promise: nil)
            return
        }
        queuedBytes += count
        let owned: HTTPServerRequestPart
        if case .body(let bytes) = part { owned = .body(ByteBuffer(bytes: bytes.readableBytesView)) }
        else { owned = part }
        queuedParts.append((owned, count))
    }
    private func clearQueuedParts() {
        queuedParts.removeAll()
        connection?.releasePendingBytes(queuedBytes)
        queuedBytes = 0
    }

    private func updateClientReading() {
        guard let context else { return }
        let shouldRead = discardingInput || (!closing && queuedParts.isEmpty && exchangeReading)
        guard shouldRead != clientReading else { return }
        clientReading = shouldRead
        context.channel.setAutoRead(shouldRead)
    }
    static func isRetryableTransportFailure(_ error: Error?) -> Bool { HTTPExchange.isRetryableTransportFailure(error) }

    // MARK: CONNECT

    private func startConnect(_ head: HTTPRequestHead) {
        guard let target = RequestTarget(authorityForm: head.uri) else {
            respondLocally(to: head, status: .badRequest, body: L10n.format("proxyFailure.unsupportedRequest", "CONNECT", head.uri))
            return
        }
        guard connection?.admitLocalOperation() == true else { closeClient(); return }
        connection?.bindShaping(host: target.host, port: target.port)
        let exchange = LocalExchange(requestHead: head, target: target)
        exchange.isConnect = true
        self.localExchange = exchange
        updateClientReading()
    }

    /// The CONNECT request is complete: tunnel it untouched (excluded from decryption, or in the
    /// passthrough list), or intercept it (`InterceptedConnect`). No more HTTP is read meanwhile.
    private func beginConnect(_ exchange: LocalExchange) {
        guard let context, let target = exchange.target else { return }
        closing = true
        updateClientReading()
        let host = target.host.lowercased()
        // Only host/port Block entries can stop a tunnel; with no active list this is `.unchanged`
        // and the CONNECT runs exactly as before.
        let admission = environment.traffic.flatMap { $0.current() }
            .flatMap { $0.affectsExchanges ? $0.admission(connectHost: host, port: target.port) : nil } ?? .unchanged
        if case .block(let entryID) = admission.action {
            blockConnect(exchange, target: target, entryID: entryID, records: admission.records)
            return
        }
        // An Allow miss is relayed untouched: not decrypted and not recorded.
        let toolDecrypts = admission.appliesRules && environment.configuration.decryption.shouldDecrypt(host)
            && !environment.passthrough.contains(host)
        // The CONNECT point (R4 D11) only when an active rule runs there; otherwise nothing more happens here.
        if admission.appliesRules, let rules = environment.rules, let snapshot = rules.activeAtConnect() {
            evaluateConnectRules(exchange, target: target, rules: rules, snapshot: snapshot, toolDecrypts: toolDecrypts,
                                 records: admission.records)
        } else if toolDecrypts {
            intercept(exchange, host: host, port: target.port, context: context)
        } else {
            openTunnel(exchange, target: target, context: context, records: admission.records)
        }
    }

    /// A Block entry matched the CONNECT target: answer a local 403 and never open the tunnel.
    /// The failed CONNECT flow (display mode) is recorded before the response is written.
    private func blockConnect(_ exchange: LocalExchange, target: RequestTarget, entryID: UUID, records: Bool) {
        let message = HTTPLocalFailureText.blocked(authority: target.authority)
        if records, let store = environment.recording.activeStore {
            let id = TunnelRecorder.recordFailure(
                store: store, host: target.host, port: target.port, client: connection?.knownClient,
                reason: message, note: nil, provenance: FlowProvenance(tools: .init(blockedByEntry: entryID)))
            connection?.onClient { app in store.update(id) { $0.client = app } }
        }
        writeLocalResponse(
            status: .forbidden,
            body: HTTPLocalFailureText.page(productName: environment.configuration.productName, message: message),
            for: exchange)
    }

    func intercept(_ exchange: LocalExchange, host: String, port: Int, context: ChannelHandlerContext) {
        let channel = context.channel
        let tlsContext: NIOSSLContext
        do {
            tlsContext = try environment.tls.serverContext(for: host)
        } catch {
            localFailure(exchange, message: L10n.format("proxyFailure.certIssueFailed", host, "\(error)"))
            return
        }
        self.localExchange = nil
        let session = InterceptedConnect(
            host: host, port: port, environment: environment, connector: connector, tlsContext: tlsContext,
            clientLookup: connection!.clientLookup, inheritedConnection: connection, connectionFactory: connectionFactory)
        do {
            try replaceHTTPHandlers(context) { try $0.addHandler(session.firstHandler) }
        } catch {
            channel.close(promise: nil)
            return
        }
        session.start(on: channel)
        connection?.finishLocalOperation()
        channel.setAutoRead(true)
    }

    /// `rules` is what the CONNECT point's rules did, written on the tunnel row before anyone sees it.
    func openTunnel(
        _ exchange: LocalExchange, target: RequestTarget, context: ChannelHandlerContext, records: Bool = true,
        rules: ConnectRuleRecord? = nil
    ) {
        let recorder = (records ? environment.recording.activeStore : nil).map { store in
            TunnelRecorder(
                store: store, host: target.host, port: target.port, client: connection?.knownClient,
                eventLoop: context.eventLoop, holdPublication: rules != nil)
        }
        if let rules { recorder?.apply(annotations: rules.annotations, provenance: rules.provenance) }
        if let recorder { connection?.onClient(recorder.setClient) }
        // The injectable factory (nil in production) is the same seam exchanges and interception use.
        let connecting = connectionFactory?(target.host, target.port, context.eventLoop)
            ?? connector.connect(host: target.host, port: target.port, on: context.eventLoop)
        (connection?.retainTransportWork(connecting) ?? connecting)
            .assumeIsolated()
            .whenComplete { result in
                self.tunnelConnectCompleted(result, for: exchange, recorder: recorder)
            }
    }

    private func tunnelConnectCompleted(
        _ result: Result<Channel, Error>, for exchange: LocalExchange, recorder: TunnelRecorder?
    ) {
        let upstreamChannel: Channel
        switch result {
        case .success(let connected):
            upstreamChannel = connected
        case .failure(let error):
            let reason = UpstreamConnector.describe(error)
            recorder?.fail(reason)
            if self.localExchange === exchange { localFailure(exchange, message: HTTPLocalFailureText.unreachable(authority: targetDescription(exchange), reason: reason)) }
            return
        }
        guard self.localExchange === exchange, let context else {
            upstreamChannel.close(promise: nil)
            recorder?.fail(L10n.string("proxyFailure.clientDisconnected"))
            return
        }
        self.localExchange = nil
        let clientChannel = context.channel
        do {
            try GlueHandler.joinTunnel(client: clientChannel, upstream: upstreamChannel, recorder: recorder) { glue in
                try replaceHTTPHandlers(context) { try $0.addHandler(glue) }
            }
        } catch {
            recorder?.fail(UpstreamConnector.describe(error))
            upstreamChannel.close(promise: nil)
            clientChannel.close(promise: nil)
        }
    }

    /// Answers the CONNECT with 200 and swaps this connection's HTTP handlers (and this handler)
    /// for the ones `install` appends. The 200 is written raw with no message framing fields
    /// while the HTTP codecs are removed. The decoder is removed last,
    /// so bytes it already buffered (a ClientHello sent early) go on to the new handlers.
    private func replaceHTTPHandlers(
        _ context: ChannelHandlerContext, install: (ChannelPipeline.SynchronousOperations) throws -> Void
    ) throws {
        let pipeline = context.pipeline.syncOperations
        let encoder = try pipeline.handler(type: HTTPResponseEncoder.self)
        let decoder = try pipeline.handler(type: ByteToMessageHandler<HTTPRequestDecoder>.self)
        if let framer = try? pipeline.handler(type: HTTP1TransferCodingFramer<HTTPResponseHead>.self) {
            pipeline.removeHandler(framer, promise: nil)
        }
        pipeline.removeHandler(encoder, promise: nil)
        context.writeAndFlush(NIOAny(ByteBuffer(string: Self.connectEstablished)), promise: nil)
        try install(pipeline)
        pipeline.removeHandler(context: context, promise: nil)
        // Early tunnel bytes still in the decoder must survive a client EOF in the same batch.
        try DeferredInactiveHandler.removeDecoder(decoder, from: pipeline, on: context.eventLoop)
    }

    private func switchToRawRelay(lease: UpstreamLease, observation: ObservationHandle?) {
        guard let context, let upstreamChannel = (lease as? HTTP1UpstreamLease)?.detachForUpgrade() else {
            observation?.relayFailed()
            lease.cancel(error: nil)
            closeClient()
            return
        }
        connection?.retainTransport(upstreamChannel)
        exchange = nil
        closing = true
        let clientChannel = context.channel
        let (clientGlue, upstreamGlue) = GlueHandler.makePair()
        if let observation {
            clientGlue.onObservedRead = { observation.offer($0, direction: .clientToServer) }
            upstreamGlue.onObservedRead = { observation.offer($0, direction: .serverToClient) }
            clientGlue.onClose = { observation.transportEnded(direction: .clientToServer) }
            upstreamGlue.onClose = { observation.transportEnded(direction: .serverToClient) }
        }
        do {
            let client = context.pipeline.syncOperations
            let origin = upstreamChannel.pipeline.syncOperations
            try client.addHandler(clientGlue)
            try origin.addHandler(upstreamGlue)
            let clientDecoder = try client.handler(type: ByteToMessageHandler<HTTPRequestDecoder>.self)
            let clientEncoder = try client.handler(type: HTTPResponseEncoder.self)
            let originDecoder = try origin.handler(type: ByteToMessageHandler<HTTPResponseDecoder>.self)
            let originEncoder = try origin.handler(type: HTTPRequestEncoder.self)
            let handler = try origin.handler(type: UpstreamResponseHandler.self)
            client.removeHandler(context: context, promise: nil)
            if let framer = try? client.handler(type: HTTP1TransferCodingFramer<HTTPResponseHead>.self) {
                client.removeHandler(framer, promise: nil)
            }
            client.removeHandler(clientEncoder, promise: nil)
            origin.removeHandler(handler, promise: nil)
            if let framer = try? origin.handler(type: HTTP1TransferCodingFramer<HTTPRequestHead>.self) {
                origin.removeHandler(framer, promise: nil)
            }
            origin.removeHandler(originEncoder, promise: nil)
            // Decoder removals run as queued tasks in this order. The origin response decoder
            // also observes outbound writes, so it must be gone before client bytes pipelined
            // behind the Upgrade request are forwarded to the origin.
            // An EOF from the same read batch must not make either decoder drop leftovers.
            try DeferredInactiveHandler.removeDecoder(originDecoder, from: origin, on: upstreamChannel.eventLoop)
            try DeferredInactiveHandler.removeDecoder(clientDecoder, from: client, on: context.eventLoop)
        } catch {
            observation?.relayFailed()
            clientChannel.close(promise: nil)
            upstreamChannel.close(promise: nil)
            return
        }
        clientChannel.setAutoRead(upstreamChannel.isWritable)
        upstreamChannel.setAutoRead(clientChannel.isWritable)
    }

    final class Writer: HTTP1DownstreamResponseWriter {
        private weak var owner: ProxyHandler?
        private let channel: Channel
        let version: HTTPWireVersion = .http1_1
        var eventLoop: EventLoop { channel.eventLoop }
        var isWritable: Bool { channel.isWritable }
        var isActive: Bool { channel.isActive }
        var isAttached: Bool { owner?.context != nil }
        init(owner: ProxyHandler, channel: Channel) { self.owner = owner; self.channel = channel }
        func write(_ part: HTTPServerResponsePart) -> EventLoopFuture<Void> {
            guard let context = owner?.context else { return channel.eventLoop.makeFailedFuture(ChannelError.ioOnClosedChannel) }
            return context.write(NIOAny(part))
        }
        func flush() { owner?.context?.flush() }
        func setRequestReading(_ enabled: Bool) { owner?.exchangeReading = enabled; owner?.updateClientReading() }
        func responseFinished() { owner?.finish(keepAlive: true, after: nil, discardUpload: false) }
        func finish(keepAlive: Bool, after: EventLoopFuture<Void>?, discardUpload: Bool) {
            owner?.finish(keepAlive: keepAlive, after: after, discardUpload: discardUpload)
        }
        func upgrade(lease: UpstreamLease, observation: ObservationHandle?) {
            guard let owner else { observation?.relayFailed(); lease.cancel(error: nil); return }
            owner.switchToRawRelay(lease: lease, observation: observation)
        }
        func abort(_ error: Error) { owner?.closeClient() }
        /// Queued pipelined requests are dropped with the connection. Graceful half-closes (FIN) and drains the rest
        /// of the upload for a bounded time: a full close with unread bytes would go out as a reset.
        func closeConnection(_ mode: RulesEngine.CloseMode) {
            if mode == .reset { owner?.closeClient(reset: true) } else { owner?.closeAfterDiscardingUpload(after: nil) }
        }
    }
}

final class LocalExchange {
    let requestHead: HTTPRequestHead
    let target: RequestTarget?
    let keepAlive: Bool
    var requestComplete = false
    var responseComplete = false
    var isConnect = false
    var lastClientWrite: EventLoopFuture<Void>?
    init(requestHead: HTTPRequestHead, target: RequestTarget?) {
        self.requestHead = requestHead
        self.target = target
        // The request decoder stops after Upgrade even when the proxy answers locally.
        let upgradeRequested = requestHead.headers.contains(name: "upgrade")
            && requestHead.headers[canonicalForm: "connection"].contains { $0.lowercased() == "upgrade" }
        self.keepAlive = requestHead.isKeepAlive && !upgradeRequested && requestHead.method != .CONNECT
    }
}
