import FlowStore
import Foundation
import os
import Testing
@testable import AppCore

/// A clock the test moves by hand.
private final class TestClock: Sendable {
    private let current = OSAllocatedUnfairLock(initialState: Date(timeIntervalSinceReferenceDate: 1_000_000))
    var now: Date { current.withLock { $0 } }
    func set(_ date: Date) { current.withLock { $0 = date } }
    var source: @Sendable () -> Date { { [self] in now } }
}

@MainActor @Suite(.timeLimit(.minutes(1)), .productionChinese) struct BreakpointQueueFlowTests {
    private let clock = TestClock()

    private func ticket(flow: Int?, offset: TimeInterval = 0) -> BreakpointTicketSnapshot {
        requestTicket(flowID: flow, deadline: clock.now.addingTimeInterval(120 + offset))
    }

    private func model(_ client: FakeBreakpointClient) -> BreakpointQueueModel {
        BreakpointQueueModel(client: client, now: clock.source)
    }

    @Test func pausedFlowIDsFollowTicketOrderAndSkipUnrecorded() async {
        let late = ticket(flow: 3, offset: 2), unrecorded = ticket(flow: nil, offset: 1), early = ticket(flow: 7)
        let client = FakeBreakpointClient(tickets: [late, unrecorded, early])
        let model = model(client)
        await model.refresh()
        #expect(model.pausedFlowIDs == [7, 3])
        #expect(model.ticket(forFlow: 3)?.id == late.id)
        #expect(model.ticket(forFlow: 99) == nil)
    }

    @Test func selectFlowSelectsItsTicket() async {
        let a = ticket(flow: 1), b = ticket(flow: 2, offset: 1)
        let model = model(FakeBreakpointClient(tickets: [a, b]))
        await model.refresh()
        model.selectFlow(2)
        #expect(model.selectedID == b.id)
        #expect(model.selectedEditor?.id == b.id)
    }

    @Test func selectFlowWithoutTicketClearsSelection() async {
        let a = ticket(flow: 1)
        let model = model(FakeBreakpointClient(tickets: [a]))
        await model.refresh()
        model.selectFlow(1)
        model.selectFlow(5)
        #expect(model.selectedID == nil)
        model.selectFlow(1)
        model.selectFlow(nil)
        #expect(model.selectedID == nil)
    }

    @Test func draftSurvivesSelectingAnotherFlow() async throws {
        let a = ticket(flow: 1), b = ticket(flow: 2, offset: 1)
        let client = FakeBreakpointClient(tickets: [a, b])
        let model = model(client)
        await model.refresh()
        model.selectFlow(1)
        let editor = try #require(model.selectedEditor)
        editor.headers[0].value = "edited"
        model.selectFlow(2)
        client.publish([a, b])
        await model.refresh()
        model.selectFlow(1)
        #expect(model.selectedEditor === editor)
        #expect(model.selectedEditor?.isDirty == true)
        #expect(model.selectedEditor?.headers[0].value == "edited")
    }

    @Test func ticketExpiringWhileOpenRecordsTimedOut() async {
        let a = ticket(flow: 4)
        let client = FakeBreakpointClient(tickets: [a])
        let model = model(client)
        await model.refresh()
        model.selectFlow(4)
        clock.set(a.deadline.addingTimeInterval(1))
        client.publish([])
        await model.refresh()
        #expect(model.ended(forFlow: 4) == .timedOut)
        #expect(model.selectedID == nil)
    }

    @Test func ticketEndedEarlyRecordsAborted() async {
        let a = ticket(flow: 4), b = ticket(flow: 5, offset: 1)
        let client = FakeBreakpointClient(tickets: [a, b])
        let model = model(client)
        await model.refresh()
        model.selectFlow(4)
        model.selectFlow(5)
        client.publish([])
        await model.refresh()
        #expect(model.ended(forFlow: 4) == .aborted)
        #expect(model.ended(forFlow: 5) == .aborted)
    }

    @Test func responseTicketOfTheViewedFlowIsSelectedAfterItsRequestEnds() async {
        let request = ticket(flow: 4)
        let client = FakeBreakpointClient(tickets: [request])
        let model = model(client)
        await model.refresh()
        model.selectFlow(4)
        #expect(model.selectedID == request.id)
        let response = responseTicket(flowID: 4, phase: .pausedHeaders)
        client.publish([response])
        await model.refresh()
        #expect(model.pausedFlowIDs == [4])
        #expect(model.selectedID == response.id)
        #expect(model.selectedEditor?.id == response.id)
        #expect(model.ended(forFlow: 4) == nil)
    }

    @Test func viewingAFlowWithoutTicketFollowsItsFirstTicket() async {
        let client = FakeBreakpointClient(tickets: [])
        let model = model(client)
        await model.refresh()
        model.selectFlow(6)
        let arriving = ticket(flow: 6)
        client.publish([arriving])
        await model.refresh()
        #expect(model.selectedID == arriving.id)
    }

    @Test func ownContinueRecordsNothing() async {
        let a = ticket(flow: 4)
        let client = FakeBreakpointClient(tickets: [a])
        let model = model(client)
        await model.refresh()
        model.selectFlow(4)
        // A refresh while the command is in flight finds the ticket gone.
        client.performHook.withLock { hook in hook = { @MainActor in
            client.publish([])
            await model.refresh()
        } }
        await model.continueSelected()
        #expect(model.ended(forFlow: 4) == nil)
        #expect(model.notice == nil)
    }

    @Test func ownCancelRecordsNothing() async {
        let a = ticket(flow: 4)
        let client = FakeBreakpointClient(tickets: [a])
        let model = model(client)
        await model.refresh()
        model.selectFlow(4)
        client.performHook.withLock { hook in hook = { client.publish([]) } }
        await model.cancelSelected()
        #expect(model.ended(forFlow: 4) == nil)
    }

    @Test func continueAnsweredExpiredRecordsTimedOut() async {
        let a = ticket(flow: 4)
        let client = FakeBreakpointClient(tickets: [a])
        let model = model(client)
        await model.refresh()
        model.selectFlow(4)
        client.enqueue(.expired)
        client.performHook.withLock { hook in hook = { client.publish([]) } }
        await model.continueSelected()
        #expect(model.ended(forFlow: 4) == .timedOut)
        #expect(model.notice == .expired)
    }

    @Test func ticketVanishingDuringRejectedContinueRecordsAborted() async {
        let a = ticket(flow: 4)
        let client = FakeBreakpointClient(tickets: [a])
        let model = model(client)
        await model.refresh()
        model.selectFlow(4)
        client.enqueue(.invalid)
        client.performHook.withLock { hook in hook = { @MainActor in
            client.publish([])
            await model.refresh()
        } }
        await model.continueSelected()
        #expect(model.ended(forFlow: 4) == .aborted)
        #expect(model.selectedEditor == nil)
    }

    @Test func ticketVanishingDuringRejectedContinuePastDeadlineRecordsTimedOut() async {
        let a = ticket(flow: 4)
        let client = FakeBreakpointClient(tickets: [a])
        let model = model(client)
        let clock = clock
        await model.refresh()
        model.selectFlow(4)
        client.enqueue(.unsupported)
        client.performHook.withLock { hook in hook = { @MainActor in
            clock.set(a.deadline.addingTimeInterval(1))
            client.publish([])
            await model.refresh()
        } }
        await model.continueSelected()
        #expect(model.ended(forFlow: 4) == .timedOut)
    }

    @Test func acknowledgeClears() async {
        let a = ticket(flow: 4)
        let client = FakeBreakpointClient(tickets: [a])
        let model = model(client)
        await model.refresh()
        model.selectFlow(4)
        client.publish([])
        await model.refresh()
        #expect(model.ended(forFlow: 4) == .aborted)
        model.acknowledgeEnded(forFlow: 4)
        #expect(model.ended(forFlow: 4) == nil)
    }

    @Test func newTicketForAnEndedFlowClearsItsRecord() async {
        let a = ticket(flow: 4)
        let client = FakeBreakpointClient(tickets: [a])
        let model = model(client)
        await model.refresh()
        model.selectFlow(4)
        client.publish([])
        await model.refresh()
        #expect(model.ended(forFlow: 4) == .aborted)
        client.publish([ticket(flow: 4, offset: 5)])
        await model.refresh()
        #expect(model.ended(forFlow: 4) == nil)
    }

    @Test func endedMapIsBounded() async {
        let all = (1...70).map { ticket(flow: $0, offset: TimeInterval($0)) }
        let client = FakeBreakpointClient(tickets: all)
        let model = model(client)
        await model.refresh()
        for flow in 1...70 { model.selectFlow(flow) }
        client.publish([])
        await model.refresh()
        #expect((1...6).allSatisfy { model.ended(forFlow: $0) == nil })
        #expect((7...70).allSatisfy { model.ended(forFlow: $0) == .aborted })
    }

    @Test func unopenedTicketEndingRecordsNothing() async {
        let a = ticket(flow: 4), unrecorded = ticket(flow: nil, offset: 1)
        let client = FakeBreakpointClient(tickets: [a, unrecorded])
        let model = model(client)
        await model.refresh()
        model.select(unrecorded.id)
        client.publish([])
        await model.refresh()
        #expect(model.ended(forFlow: 4) == nil)
        #expect(model.pausedFlowIDs.isEmpty)
    }
}
