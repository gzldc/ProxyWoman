import Testing

@testable import AppCore

@Suite(.productionChinese) struct AppBundlePathTests {
    @Test func outermostAppOfAnAppExecutable() {
        #expect(
            AppBundlePath.outermostApp(ofExecutable: "/Applications/Safari.app/Contents/MacOS/Safari")
                == "/Applications/Safari.app")
    }

    @Test func helpersNestedInAnAppBelongToTheOuterApp() {
        let helper =
            "/Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper"
        #expect(AppBundlePath.outermostApp(ofExecutable: helper) == "/Applications/Claude.app")
    }

    @Test func plainExecutablesHaveNoApp() {
        #expect(AppBundlePath.outermostApp(ofExecutable: "/usr/bin/curl") == nil)
        #expect(AppBundlePath.outermostApp(ofExecutable: "/opt/tools/my.application/bin/run") == nil)
        #expect(AppBundlePath.outermostApp(ofExecutable: "") == nil)
    }
}
