// UI Tests — ScreenVNC screenshot capture suite.
import XCTest

@MainActor
final class ScreenVNCScreenshots: XCTestCase {
    var app: XCUIApplication!

    override static var runsForEachTargetApplicationUIConfiguration: Bool {
        false
    }

    override func setUp() async throws {
        continueAfterFailure = false

        let newApp = XCUIApplication()
        setupSnapshot(newApp)

        newApp.launchArguments += [
            "-uitesting",
            "true",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "\"en_US\"",
            "--reset-sample-data",
            "--create-sample-data",
            "-ScreenVNCScreenshots"
        ]

        newApp.launch()
        app = newApp

        if UIDevice.current.userInterfaceIdiom == .pad ||
            ProcessInfo.processInfo.arguments.contains("-landscape") ||
            newApp.launchArguments.contains("-landscape")
        {
            XCUIDevice.shared.orientation = .landscapeLeft
            sleep(1)
        }
    }

    private var isCompact: Bool {
        if app.windows.firstMatch.exists {
            return app.windows.firstMatch.frame.width < 600
        }
        return true
    }

    private func dismissModal() {
        let dismissPredicate = NSPredicate(
            format: "label CONTAINS[c] 'cancel' OR identifier CONTAINS[c] 'cancel' " +
                "OR label CONTAINS[c] 'done' OR identifier CONTAINS[c] 'done' " +
                "OR label == 'xmark' OR identifier == 'xmark' " +
                "OR label == 'checkmark' OR identifier == 'checkmark'"
        )

        let dismissBtn = app.buttons.matching(dismissPredicate).firstMatch
        if dismissBtn.waitForExistence(timeout: 2), dismissBtn.isHittable {
            dismissBtn.tap()
            sleep(1)
            return
        }

        let anyDismiss = app.buttons.allElementsBoundByIndex.first(where: {
            ($0.label.lowercased().contains("cancel") ||
                $0.label.lowercased().contains("done") ||
                $0.label == "xmark" || $0.label == "checkmark") && $0.isHittable
        })
        anyDismiss?.tap()
        sleep(1)
    }

    @MainActor
    func testCaptureScreenshots() {
        // Allow initial view hierarchy and sample data to settle
        sleep(2)

        // 01 Connections (Root List)
        snapshot("01Connections")

        // 02 New Connection View
        let addPredicate = NSPredicate(
            format: "label CONTAINS[c] 'add' OR identifier CONTAINS[c] 'add' " +
                "OR label == '+' OR label CONTAINS[c] 'plus' OR identifier CONTAINS[c] 'plus'"
        )
        let addBtn = app.navigationBars.buttons.matching(addPredicate).firstMatch
        if addBtn.waitForExistence(timeout: 3), addBtn.isHittable {
            addBtn.tap()
            sleep(2)
            snapshot("02NewConnection")
            dismissModal()
        }

        // 03 Settings View
        let settingsPredicate = NSPredicate(
            format: "label CONTAINS[c] 'gear' OR identifier CONTAINS[c] 'gear' " +
                "OR label CONTAINS[c] 'setting' OR identifier CONTAINS[c] 'setting'"
        )
        let settingsBtn = app.navigationBars.buttons.matching(settingsPredicate).firstMatch
        if settingsBtn.waitForExistence(timeout: 3), settingsBtn.isHittable {
            settingsBtn.tap()
            sleep(2)
            snapshot("03Settings")
            dismissModal()
        }

        // 04 Profile Detail View
        let profilePredicate = NSPredicate(format: "label CONTAINS[c] 'Studio Mac Pro' OR identifier CONTAINS[c] 'Studio Mac Pro'")
        let targetProfile = app.buttons.matching(profilePredicate).firstMatch
        if targetProfile.waitForExistence(timeout: 3), targetProfile.isHittable {
            if !isCompact {
                // On iPad split view, tapping the row selects it in the detail pane
                targetProfile.tap()
                sleep(2)
                snapshot("04ProfileDetail")
            } else {
                // On phone or compact view, inspect or capture profile in view
                snapshot("04ProfileDetail")
            }
        }
    }
}
