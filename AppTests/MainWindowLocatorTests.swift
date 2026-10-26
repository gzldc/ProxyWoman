import Testing
@testable import ProxyWoman

@Suite(.productionChinese) struct MainWindowLocatorTests {
    @Test func identifierMatching() {
        #expect(MainWindowLocator.isMainWindowIdentifier("main"))
        #expect(MainWindowLocator.isMainWindowIdentifier("main-AppWindow-1"))
        #expect(!MainWindowLocator.isMainWindowIdentifier("mainx"))
        #expect(!MainWindowLocator.isMainWindowIdentifier("rule-editor"))
        #expect(!MainWindowLocator.isMainWindowIdentifier(nil))
    }

    @Test func onlyVisibleOrMiniaturizedWindowsAreReused() {
        #expect(MainWindowLocator.isReusable(isVisible: true, isMiniaturized: false))
        #expect(MainWindowLocator.isReusable(isVisible: false, isMiniaturized: true))
        #expect(!MainWindowLocator.isReusable(isVisible: false, isMiniaturized: false))
    }
}
