import Foundation
import Testing
import FlowStore
import NIOCore
@testable import ProxyCore

@Suite(.productionChinese) struct ObservationMailboxTests {
    @Test func zeroReadDoesNotAllocateAndOversizeRefusesBeforeCopy() {
        var limits = WebSocketLimits(); limits.sessionMailboxBytes = 4
        let budget = WebSocketMemoryBudget(limits: limits)
        let mailbox = ObservationMailbox(limits: limits)
        let empty = mailbox.tryReserveRead(byteCount: 0, chunkCount: 0) == nil
        #expect(empty)
        let oversized = mailbox.tryReserveRead(byteCount: 5, chunkCount: 1) == nil
        #expect(oversized)
        #expect(budget.usedBytes(category: .mailbox) == 0)
        #expect(mailbox.isCancelled)
    }
}

extension ObservationMailboxTests {
    private func publish(_ mailbox: ObservationMailbox, budget: WebSocketMemoryBudget, bytes: [UInt8], direction: WebSocketDirection) throws {
        guard let permit = mailbox.tryReserveRead(byteCount: bytes.count, chunkCount: 1),
              let payload = budget.reserve(category: .mailbox, bytes: bytes.count),
              let metadata = budget.reserve(category: .metadata, bytes: 512) else { Issue.record("fixture admission refused"); return }
        let owner = ObservationChunkStorage(bytes: Data(bytes), payload: payload, metadata: metadata,
            stamp: .init(epoch: 0, enabled: true, ingressSequence: 1), direction: direction, observedAt: Date(), monotonic: 0, baseOffset: 0)
        let accepted = mailbox.publishRead(.init(permit: permit, chunks: [owner])); #expect(accepted)
    }
    @Test func firstEOFWinsOverLaterOppositeTrafficAndInFlightRetainsCharge() throws {
        let budget = WebSocketMemoryBudget(), mailbox = ObservationMailbox(limits: .init())
        try publish(mailbox, budget: budget, bytes: [1, 2], direction: .clientToServer)
        mailbox.markTransportEnded(.init(direction: .clientToServer, at: Date(), monotonic: 1))
        mailbox.markTransportEnded(.init(direction: .clientToServer, at: Date(), monotonic: 2))
        try publish(mailbox, budget: budget, bytes: [3], direction: .serverToClient)
        var sequence: UInt64 = 0
        if let input = mailbox.take() { switch consume input { case .chunk(let chunk):
            sequence = chunk.sequence
            #expect(chunk.storage.bytes == Data([1, 2]))
            #expect(mailbox.heldBytes == 3)
            #expect(budget.usedBytes(category: .mailbox) == 3)
        case .eof: Issue.record("unexpected EOF"); return
        }} else { Issue.record("missing first chunk"); return }
        #expect(budget.usedBytes(category: .mailbox) == 1)
        mailbox.finishChunk(sequence: sequence)
        if let input = mailbox.take() { switch consume input { case .eof(let end):
            #expect(end.direction == .clientToServer && end.monotonic == 1)
        case .chunk: Issue.record("later chunk overtook EOF")
        }} else { Issue.record("EOF was overtaken by later opposite input") }
        if let input = mailbox.take() { switch consume input { case .chunk(let chunk):
            #expect(chunk.storage.bytes == Data([3]))
            mailbox.cancel()
            #expect(budget.usedBytes(category: .mailbox) == 1)
            #expect(budget.usedBytes(category: .metadata) == 512)
        case .eof: Issue.record("unexpected EOF")
        }} else { Issue.record("healthy opposite input discarded") }
        mailbox.finishChunk(sequence: 2)
        #expect(budget.usedBytes(category: .mailbox) == 0)
        #expect(budget.usedBytes(category: .metadata) == 0)
        #expect(mailbox.heldBytes == 0)
    }
    @Test func preparationAndInFlightBothCountAgainstSessionCapacity() throws {
        var limits = WebSocketLimits(); limits.sessionMailboxBytes = 4
        let mailbox = ObservationMailbox(limits: limits), budget = WebSocketMemoryBudget(limits: limits)
        try publish(mailbox, budget: budget, bytes: [1, 2, 3], direction: .clientToServer)
        if let input = mailbox.take() { switch consume input { case .chunk(let chunk):
            let refused = mailbox.tryReserveRead(byteCount: 2, chunkCount: 1) == nil
            #expect(refused && mailbox.isCancelled)
            #expect(chunk.storage.bytes == Data([1, 2, 3]))
            #expect(budget.usedBytes(category: .mailbox) == 3)
        case .eof: Issue.record("unexpected EOF")
        }}
        mailbox.finishChunk(sequence: 1)
        #expect(mailbox.heldBytes == 0)
    }
}

extension ObservationMailboxTests {
    @Test func extractedMailboxKeepsActualControlEnvelopeUntilItsLastOwner() {
        let budget = WebSocketMemoryBudget()
        guard let envelope = budget.reserve(category: .metadata, bytes: 2048) else { Issue.record("fixture refused"); return }
        var owner: ObservationMailbox? = ObservationMailbox(limits: .init(), envelope: envelope)
        var producer = owner
        owner = nil
        #expect(budget.usedBytes(category: .metadata) == 2048)
        producer?.cancel(); producer?.finishWakeStream()
        producer = nil
        #expect(budget.usedBytes(category: .metadata) == 0)
    }
}
