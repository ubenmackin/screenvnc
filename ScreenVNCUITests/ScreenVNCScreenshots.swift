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

    private func findButton(identifier: String, predicate: NSPredicate) -> XCUIElement? {
        let identified = app.buttons[identifier]
        if identified.waitForExistence(timeout: 2), identified.isHittable {
            return identified
        }
        let navMatch = app.navigationBars.buttons.matching(predicate).firstMatch
        if navMatch.waitForExistence(timeout: 1), navMatch.isHittable {
            return navMatch
        }
        let appMatch = app.buttons.matching(predicate).firstMatch
        if appMatch.waitForExistence(timeout: 1), appMatch.isHittable {
            return appMatch
        }
        return app.buttons.allElementsBoundByIndex.first(where: {
            predicate.evaluate(with: $0) && $0.isHittable
        })
    }

    private func dismissModal() {
        let cancelBtn = app.buttons["CancelButton"]
        if cancelBtn.waitForExistence(timeout: 2), cancelBtn.isHittable {
            cancelBtn.tap()
            sleep(1)
            return
        }

        let doneBtn = app.buttons["DoneButton"]
        if doneBtn.waitForExistence(timeout: 2), doneBtn.isHittable {
            doneBtn.tap()
            sleep(1)
            return
        }

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
        if let addBtn = findButton(identifier: "AddConnectionButton", predicate: addPredicate) {
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
        if let settingsBtn = findButton(identifier: "SettingsButton", predicate: settingsPredicate) {
            settingsBtn.tap()
            sleep(2)
            snapshot("03Settings")
            dismissModal()
        }

        // 04 Profile Detail View (Active Remote Desktop Session)
        let profilePredicate = NSPredicate(
            format: "label CONTAINS[c] 'Studio Mac Pro' OR identifier CONTAINS[c] 'Studio Mac Pro'"
        )
        let targetProfile = findButton(identifier: "ProfileRow_Studio Mac Pro", predicate: profilePredicate)
        if let targetProfile {
            targetProfile.tap()
            sleep(2)
            snapshot("04ProfileDetail")
        }
    }
}
