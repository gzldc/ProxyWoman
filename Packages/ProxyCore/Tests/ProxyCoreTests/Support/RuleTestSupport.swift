import FlowStore
import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1
@testable import ProxyCore
@testable import RulesEngine

/// Synthetic rule snapshots for the exchange tests. Rules are built in memory and published the
/// way the repository does after a durable save; no rule file is ever read or written.
enum TestRules {
    /// Rules as given (several actions, final flags, groups). The array order is the evaluation order
    /// among siblings; groups keep their own `order`.
    static func provider(
        _ rules: [Rule], groups: [RuleGroup] = [], revision: UInt64 = 1, patternCache: PatternCache = .shared
    ) -> RuleSnapshotProvider {
        RuleSnapshotProvider(
            RuleSnapshot(revision: revision, groups: groups, rules: ordered(rules)), patternCache: patternCache)
    }

    static func publish(_ rules: [Rule], groups: [RuleGroup] = [], revision: UInt64, to provider: RuleSnapshotProvider) {
        provider.publish(RuleSnapshot(revision: revision, groups: groups, rules: ordered(rules)))
    }

    private static func ordered(_ rules: [Rule]) -> [Rule] {
        rules.enumerated().map { index, rule in
            var rule = rule
            rule.order = index
            return rule
        }
    }

    static func headers(
        _ direction: HTTPMessageDirection, _ operations: [HeaderEdit], matcher: RuleMatcher = RuleMatcher()
    ) -> Rule {
        Rule(id: UUID(), name: "headers", enabled: true, order: 0, matcher: matcher,
             action: .editHeaders(direction: direction, operations: operations))
    }

    static func mapRemote(
        scheme: String = "http", host: String, port: Int, path: RemotePathPolicy = .preserve,
        preserveCredentials: Bool = false, matcher: RuleMatcher = RuleMatcher()
    ) -> Rule {
        Rule(id: UUID(), name: "remote", enabled: true, order: 0, matcher: matcher,
             action: .mapRemote(MapRemoteAction(targetScheme: scheme, targetHost: host, targetPort: port, path: path,
                                                preserveCredentials: preserveCredentials)))
    }

    static func rewriteStatus(
        _ status: Int, includeLocalResponses: Bool = false, reason: String? = nil, matcher: RuleMatcher = RuleMatcher()
    ) -> Rule {
        Rule(id: UUID(), name: "status", enabled: true, order: 0, matcher: matcher,
             action: .rewriteStatus(RewriteStatusAction(
                status: status, includeLocalResponses: includeLocalResponses, reason: reason)))
    }

    static func rewriteBody(
        _ direction: HTTPMessageDirection = .response, find: String, replacement: String, syntax: BodyFindSyntax = .text,
        matcher: RuleMatcher = RuleMatcher()
    ) -> Rule {
        Rule(id: UUID(), name: "body", enabled: true, order: 0, matcher: matcher,
             action: .rewriteBody(direction: direction, BodyRewriteAction(find: find, replacement: replacement, syntax: syntax)))
    }

    static func mapLocal(matcher: RuleMatcher = RuleMatcher()) -> Rule {
        Rule(id: UUID(), name: "local", enabled: true, order: 0, matcher: matcher,
             action: .mapLocal(MapLocalAction(assetID: UUID(), headers: [])))
    }

    static func breakpoint(_ direction: HTTPMessageDirection, matcher: RuleMatcher = RuleMatcher()) -> Rule {
        Rule(id: UUID(), name: "breakpoint", enabled: true, order: 0, matcher: matcher,
             action: .breakpoint(direction: direction, mode: .headers))
    }
}

/// Records what an exchange wrote downstream; every write is accepted at once.
final class RecordingResponseWriter: DownstreamResponseWriter {
    let channel: Channel
    let version: HTTPWireVersion
    var eventLoop: EventLoop { channel.eventLoop }
    var isWritable: Bool { channel.isWritable }
    var isActive: Bool { channel.isActive }
    var heads: [HTTPResponseHead] = []
    var body = ""
    var ends = 0
    var finishes = 0
    var aborts = 0
    var closes: [RulesEngine.CloseMode] = []
    init(channel: Channel, version: HTTPWireVersion = .http1_1) { self.channel = channel; self.version = version }
    func write(_ part: HTTPServerResponsePart) -> EventLoopFuture<Void> {
        switch part {
        case .head(let head): heads.append(head)
        case .body(.byteBuffer(let bytes)): body += String(buffer: bytes)
        case .body(.fileRegion): break
        case .end: ends += 1
        }
        return channel.eventLoop.makeSucceededVoidFuture()
    }
    func flush() { channel.flush() }
    func setRequestReading(_ enabled: Bool) {}
    func responseFinished() { finishes += 1 }
    func abort(_ error: Error) { aborts += 1 }
    func closeConnection(_ mode: RulesEngine.CloseMode) { closes.append(mode) }
}

extension ConnectionFixture {
    /// Admits an `http://example.test` request on `context` without executing it.
    func admit(
        _ path: String, method: HTTPMethod = .GET, version: HTTPVersion = .http1_1, headers: HTTPHeaders = HTTPHeaders(),
        writer: RecordingResponseWriter, context: ClientConnectionContext, policy: HTTPExecutionPolicy = .init()
    ) -> HTTPExchange {
        HTTPExchange(
            requestHead: HTTPRequestHead(version: version, method: method, uri: "http://example.test" + path, headers: headers),
            target: RequestTarget(host: "example.test", port: 80, originForm: path, defaultPort: 80),
            scheme: "http", downstream: writer, connection: context,
            transport: .init(downstreamRequest: HTTPWireVersion(version)), policy: policy)
    }

    /// Everything written to an embedded upstream so far, as text.
    func written(_ channel: EmbeddedChannel) throws -> String {
        var bytes = ""
        while let part = try channel.readOutbound(as: IOData.self) {
            if case .byteBuffer(let buffer) = part { bytes += String(buffer: buffer) }
        }
        return bytes
    }

    func flow(_ path: String) throws -> Flow {
        guard let flow = store.allFlows().first(where: { $0.path == path }) else { throw WaitTimeout(description: "no flow \(path)") }
        return flow
    }
}
