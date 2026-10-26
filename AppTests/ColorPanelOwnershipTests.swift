import Testing
@testable import ProxyWoman

@MainActor @Suite(.productionChinese) struct ColorPanelOwnershipTests {
    @Test func staleOwnerCannotClearANewerOwner() {
        var clears = 0
        let ownership = ColorPanelOwnership { clears += 1 }
        let a = ownership.claim()
        let b = ownership.claim()
        #expect(!ownership.release(a))
        #expect(clears == 0)
        #expect(ownership.release(b))
        #expect(clears == 1)
        #expect(!ownership.release(b))
        #expect(clears == 1)
    }
}
