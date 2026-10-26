import NIOCore
import RulesEngine

/// Where an exchange stands with its rule delay (D16). Confined to the exchange's event loop.
struct RuleDelayState {
    /// Set once the delay was scheduled; the delay happens at most once per exchange.
    private(set) var started = false
    private var timer: Scheduled<Void>?
    private var held: RequestRuleDecision?

    mutating func hold(_ decision: RequestRuleDecision) { started = true; held = decision }
    mutating func attach(_ timer: Scheduled<Void>) { self.timer = timer }
    /// The held decision, once; nil when the delay was cancelled or already fired.
    mutating func release() -> RequestRuleDecision? { timer = nil; defer { held = nil }; return held }
    mutating func cancel() { timer?.cancel(); timer = nil; held = nil }
}

/// Where an exchange stands with the delay of a rule judged at the response. Confined to the exchange's event loop.
struct ResponseDelayState {
    private(set) var started = false
    private var timer: Scheduled<Void>?
    private var held: (() -> Void)?

    mutating func hold(_ proceed: @escaping () -> Void) { started = true; held = proceed }
    mutating func attach(_ timer: Scheduled<Void>) { self.timer = timer }
    /// The held continuation, once; nil when the delay was cancelled or already fired.
    mutating func release() -> (() -> Void)? { timer = nil; defer { held = nil }; return held }
    mutating func cancel() { timer?.cancel(); timer = nil; held = nil }
}

/// A hook callback may run on any thread; it only hops to the exchange's loop, holding the exchange weakly.
private struct WeakExchange {
    weak var exchange: HTTPExchange?
}

extension HTTPExchange {
    /// Holds the request for the summed `delay` actions (spec 6.9) on an event-loop timer. Returns true when
    /// the exchange is now waiting: nothing else happens until the timer re-enters `execute(decided:)` with
    /// the same decision (breakpoints, local responses and the connection all come after). The client upload
    /// buffers like any request that is not forwarded yet. `cancel` / `settle` cancel the timer.
    func scheduleRuleDelay(_ decision: RequestRuleDecision) -> Bool {
        guard decision.delayMilliseconds > 0, !ruleDelay.started, !terminal else { return false }
        let loop = downstream.eventLoop
        let delay = TimeAmount.milliseconds(Int64(decision.delayMilliseconds))
        ruleDelay.hold(decision)
        let weakSelf = NIOLoopBound(WeakExchange(exchange: self), eventLoop: loop)
        if let hook = connection.environment.ruleDelayHook, hook(delay, { loop.execute { weakSelf.value.exchange?.ruleDelayFired() } }) {
            return true
        }
        ruleDelay.attach(loop.assumeIsolated().scheduleTask(in: delay) { [weak self] in self?.ruleDelayFired() })
        return true
    }

    /// Holds the staged response head for `milliseconds` (the delay actions of rules judged at the response) on an
    /// event-loop timer, then runs `proceed`. Returns true when the exchange is now waiting. At most once per
    /// exchange; `settle` cancels the timer. The origin's body queues behind the head like any staged response.
    func scheduleResponseDelay(_ milliseconds: Int, then proceed: @escaping () -> Void) -> Bool {
        guard milliseconds > 0, !responseDelay.started, !terminal else { return false }
        let loop = downstream.eventLoop
        let delay = TimeAmount.milliseconds(Int64(milliseconds))
        responseDelay.hold(proceed)
        // The origin keeps sending behind the held head; reading stops so the pending bytes stay within their cap.
        // `deliverResponse` resumes reading once the staged head is written.
        lease?.setResponseReading(false)
        let weakSelf = NIOLoopBound(WeakExchange(exchange: self), eventLoop: loop)
        if let hook = connection.environment.ruleDelayHook, hook(delay, { loop.execute { weakSelf.value.exchange?.responseDelayFired() } }) {
            return true
        }
        responseDelay.attach(loop.assumeIsolated().scheduleTask(in: delay) { [weak self] in self?.responseDelayFired() })
        return true
    }

    private func responseDelayFired() {
        guard !terminal, let proceed = responseDelay.release() else { return }
        proceed()
    }

    private func ruleDelayFired() {
        guard !terminal, let decision = ruleDelay.release() else { return }
        execute(decided: .success(decision))
    }
}
