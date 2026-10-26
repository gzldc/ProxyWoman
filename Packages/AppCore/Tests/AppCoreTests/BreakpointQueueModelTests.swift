import FlowStore
import Foundation
import RulesEngine
import Testing
@testable import AppCore

@MainActor @Suite(.timeLimit(.minutes(1)), .productionChinese) struct BreakpointQueueModelTests {
    @Test func queueRefreshesOnChangeAndKeepsSelection() async throws {
        let a = requestTicket(), b = requestTicket(flowID: 2)
        let client = FakeBreakpointClient(tickets: [a])
        let model = BreakpointQueueModel(client: client)
        try await awaitRefresh(model) { model.start() }
        #expect(model.tickets.map(\.id) == [a.id])
        model.select(a.id)
        model.selectedEditor?.headers[0].value = "text/html"

        try await awaitRefresh(model) { client.publish([a, b]) }
        #expect(Set(model.tickets.map(\.id)) == [a.id, b.id])
        #expect(model.pendingCount == 2)
        #expect(model.selectedID == a.id)
        // The draft survives a refresh of the same ticket.
        #expect(model.selectedEditor?.headers[0].value == "text/html")
        #expect(model.notice == nil)
    }

    @Test func onlyOneSubscriptionToChangesExists() async throws {
        let client = FakeBreakpointClient()
        let model = BreakpointQueueModel(client: client)
        try await awaitRefresh(model) { model.start() }
        model.start()
        model.start()
        try await awaitRefresh(model) { client.publish([requestTicket()]) }
        #expect(client.changesCalls == 1)
        #expect(model.pendingCount == 1)
    }

    @Test func selectedTicketDisappearsShowsNoticeOnce() async throws {
        let a = requestTicket()
        let client = FakeBreakpointClient(tickets: [a])
        let model = BreakpointQueueModel(client: client)
        await model.refresh()
        model.select(a.id)
        let editor = try #require(model.selectedEditor)
        editor.headers[0].value = "edited"
        #expect(editor.isDirty)

        client.publish([])
        await model.refresh()
        #expect(model.selectedID == nil && model.selectedEditor == nil)
        #expect(model.notice == .ended(draftDiscarded: true))
        #expect(model.budget.reservedBytes == 0)

        model.dismissNotice()
        await model.refresh()
        #expect(model.notice == nil)
    }

    @Test func untouchedSelectedTicketEndingSaysNoDraftWasLost() async throws {
        let a = requestTicket()
        let client = FakeBreakpointClient(tickets: [a])
        let model = BreakpointQueueModel(client: client)
        await model.refresh()
        model.select(a.id)
        client.publish([])
        await model.refresh()
        #expect(model.notice == .ended(draftDiscarded: false))
    }

    @Test func dirtyDraftOfAnUnselectedTicketIsNeverDroppedSilently() async throws {
        let a = requestTicket(), b = requestTicket(flowID: 2)
        let client = FakeBreakpointClient(tickets: [a, b])
        let model = BreakpointQueueModel(client: client)
        await model.refresh()
        model.select(a.id)
        model.selectedEditor?.headers[0].value = "edited"
        model.select(b.id)
        client.publish([b])
        await model.refresh()
        #expect(model.selectedID == b.id)
        #expect(model.notice == .ended(draftDiscarded: true))
    }

    @Test func requestLineOrStatusOnlyEditsAreDirtyAndNeverDroppedSilently() async throws {
        let a = requestTicket(), b = requestTicket(flowID: 2), r = responseTicket(flowID: 3, phase: .pausedHeaders)
        let client = FakeBreakpointClient(tickets: [a, b, r])
        let model = BreakpointQueueModel(client: client)
        await model.refresh()

        model.select(r.id)
        let response = try #require(model.selectedEditor)
        response.status = "404"
        #expect(response.isDirty)
        response.revert()
        #expect(!response.isDirty)
        response.reason = "Nope"
        #expect(response.isDirty)
        response.revert()

        model.select(a.id)
        let request = try #require(model.selectedEditor)
        request.method = "PUT"
        #expect(request.isDirty)
        request.revert()
        request.url = "http://origin.test:8080/changed"
        #expect(request.isDirty)

        // The URL-only draft of an unselected ticket that ends is reported, not dropped silently.
        model.select(b.id)
        client.publish([b, r])
        await model.refresh()
        #expect(model.notice == .ended(draftDiscarded: true))
        model.dismissNotice()

        // A method-only draft keeps the selection when a newer ticket arrives.
        model.selectedEditor?.method = "DELETE"
        let c = requestTicket(flowID: 4)
        client.publish([b, r, c])
        await model.refresh()
        #expect(model.selectedID == b.id)
    }

    @Test func acceptedContinueNeverReportsAnEndedDraftWhicheverOrderTheRefreshRuns() async throws {
        let a = requestTicket(), b = requestTicket(flowID: 2)
        let client = FakeBreakpointClient(tickets: [a])
        let model = BreakpointQueueModel(client: client)
        try await awaitRefresh(model) { model.start() }

        // Order 1: the change feed (ticket gone) is refreshed while Continue still awaits its reply.
        model.select(a.id)
        model.selectedEditor?.headers[0].value = "edited"
        let refreshed = OnceWaiter()
        model.refreshObserver = { refreshed.resume(true) }
        client.performHook.withLock {
            $0 = {
                client.publish([])
                let timeout = Task { try? await Task.sleep(for: .seconds(5)); refreshed.resume(false) }
                #expect(await refreshed.value(), "the change-feed refresh ran before the reply")
                timeout.cancel()
            }
        }
        await model.continueSelected()
        model.refreshObserver = nil
        client.performHook.withLock { $0 = nil }
        #expect(client.commands.count == 1)
        #expect(model.notice == nil)
        #expect(model.selectedEditor == nil && model.selectedID == nil)
        #expect(model.budget.reservedBytes == 0)

        // Order 2: the reply first, the change feed afterwards.
        try await awaitRefresh(model) { client.publish([b]) }
        model.select(b.id)
        model.selectedEditor?.headers[0].value = "edited"
        await model.continueSelected()
        #expect(model.notice == nil)
        try await awaitRefresh(model) { client.publish([]) }
        #expect(model.notice == nil)
        #expect(client.commands.count == 2)
    }

    @Test func newTicketNeverMovesTheSelection() async throws {
        let a = requestTicket(), b = requestTicket(flowID: 2), c = requestTicket(flowID: 3)
        let client = FakeBreakpointClient(tickets: [a])
        let model = BreakpointQueueModel(client: client)
        await model.refresh()
        #expect(model.selectedID == nil)

        client.publish([a, b])
        await model.refresh()
        #expect(model.selectedID == nil)

        model.select(a.id)
        client.publish([a, b, c])
        await model.refresh()
        #expect(model.selectedID == a.id)
    }

    @Test func anOlderRefreshFinishingLateNeverOverwritesANewerOne() async throws {
        let a = requestTicket(), b = requestTicket(flowID: 2)
        let client = FakeBreakpointClient(tickets: [a])
        let model = BreakpointQueueModel(client: client)
        let gate = Gate()
        client.readGate.withLock { $0 = gate }
        let older = Task { await model.refresh() }
        await gate.arrived()
        client.readGate.withLock { $0 = nil }
        client.publish([a, b])
        await model.refresh()
        #expect(model.tickets.map(\.id) == [a.id, b.id])
        await gate.open()
        await older.value
        #expect(model.tickets.map(\.id) == [a.id, b.id])
    }

    @Test func admissionToggleCancelExistingChoice() async throws {
        let client = FakeBreakpointClient(tickets: [requestTicket()])
        let model = BreakpointQueueModel(client: client)
        await model.refresh()
        #expect(model.admissionEnabled)

        await model.setAdmissionEnabled(false)
        #expect(model.isConfirmingAdmissionOff)
        #expect(client.admissions.isEmpty && model.admissionEnabled)
        model.cancelAdmissionOff()
        #expect(!model.isConfirmingAdmissionOff && client.admissions.isEmpty)

        await model.setAdmissionEnabled(false)
        await model.resolveAdmissionOff(cancelExisting: true)
        #expect(client.admissions == [AdmissionCall(enabled: false, cancelExisting: true)])
        #expect(!model.admissionEnabled && !model.isConfirmingAdmissionOff)

        await model.setAdmissionEnabled(true)
        await model.setAdmissionEnabled(false)
        await model.resolveAdmissionOff(cancelExisting: false)
        #expect(client.admissions == [
            AdmissionCall(enabled: false, cancelExisting: true), AdmissionCall(enabled: true, cancelExisting: false),
            AdmissionCall(enabled: false, cancelExisting: false),
        ])
    }

    @Test func turningAdmissionOffWithNothingPausedDoesNotAsk() async throws {
        let client = FakeBreakpointClient()
        let model = BreakpointQueueModel(client: client)
        await model.refresh()
        await model.setAdmissionEnabled(false)
        #expect(!model.isConfirmingAdmissionOff)
        #expect(client.admissions == [AdmissionCall(enabled: false, cancelExisting: false)])
    }

    @Test func cancelEndsTheTicketThroughTheClient() async throws {
        let a = requestTicket()
        let client = FakeBreakpointClient(tickets: [a])
        let model = BreakpointQueueModel(client: client)
        await model.refresh()
        model.select(a.id)
        await model.cancelSelected()
        #expect(client.commands == [.cancel(a.token)])
        #expect(model.selectedEditor == nil && model.selectedID == nil)
    }

    @Test func collectBodyUnsupportedKeepsTheTicketWithANotice() async throws {
        let a = requestTicket()
        let client = FakeBreakpointClient(tickets: [a])
        client.enqueue(.unsupported)
        let model = BreakpointQueueModel(client: client)
        await model.refresh()
        model.select(a.id)
        await model.collectBodySelected()
        #expect(client.commands == [.collectBody(a.token)])
        #expect(model.notice == .bodyUnavailable)
        #expect(model.selectedID == a.id)
    }
}

@MainActor @Suite(.timeLimit(.minutes(1)), .productionChinese) struct FlowClearConfirmationTests {
    @Test func clearWithoutFlowBoundPausedTicketsClearsAtOnce() async {
        // A paused exchange that is not recorded has no flow: Clear does not end it.
        let client = FakeBreakpointClient(tickets: [requestTicket(flowID: nil)])
        var clears = 0
        let confirmation = FlowClearConfirmation(client: client) { clears += 1 }
        await confirmation.request()
        #expect(clears == 1)
        #expect(confirmation.pausedTicketCount == nil)
        #expect(client.cancelledFlows.isEmpty)
    }

    @Test func clearWithPausedTicketsWarnsWithCountThenCancelsThemOnce() async {
        let client = FakeBreakpointClient(tickets: [requestTicket(flowID: 1), responseTicket(flowID: 2), requestTicket(flowID: nil)])
        var clears = 0
        let confirmation = FlowClearConfirmation(client: client) {
            clears += 1
            #expect(client.events == ["cancel"])
        }
        await confirmation.request()
        #expect(confirmation.pausedTicketCount == 2)
        #expect(clears == 0 && client.cancelledFlows.isEmpty)

        await confirmation.confirm()
        #expect(client.cancelledFlows == [[1, 2]])
        #expect(clears == 1)
        #expect(confirmation.pausedTicketCount == nil)
        // The unrecorded pause is untouched.
        #expect(await client.tickets().map(\.flowID) == [nil])
    }

    @Test func dismissedClearChangesNothing() async {
        let client = FakeBreakpointClient(tickets: [requestTicket(flowID: 7)])
        var clears = 0
        let confirmation = FlowClearConfirmation(client: client) { clears += 1 }
        await confirmation.request()
        confirmation.dismiss()
        await confirmation.confirm()
        #expect(clears == 0 && client.cancelledFlows.isEmpty)
        #expect(confirmation.pausedTicketCount == nil)
    }

    @Test func clearWithoutBreakpointsClearsDirectly() async {
        var clears = 0
        let confirmation = FlowClearConfirmation(client: nil) { clears += 1 }
        await confirmation.request()
        #expect(clears == 1)
    }
}
