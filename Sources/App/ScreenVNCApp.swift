// App — ScreenVNC application entry point and root scene configuration.
import SwiftUI

@main
public struct ScreenVNCApp: App {
    public init() {
        SampleDataSeeder.seedIfRequested()
    }

    public var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
