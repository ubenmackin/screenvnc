// Settings — Application-wide preferences and defaults store.
import Foundation
import Observation

public enum TabletopConsoleMode: String, Codable, Sendable, CaseIterable {
    case auto
    case alwaysFullCanvas
    case alwaysSplitConsole

    public var displayName: String {
        switch self {
        case .auto: "Automatic (Tabletop Hinge)"
        case .alwaysFullCanvas: "Always Full Canvas (BT Keyboard)"
        case .alwaysSplitConsole: "Always Split Console"
        }
    }
}

@Observable
@MainActor
public final class SettingsStore {
    public static let shared = SettingsStore()

    public var defaultDisplayPreference: DisplayPreference {
        didSet { UserDefaults.standard.set(defaultDisplayPreference.rawValue, forKey: "defaultDisplayPreference") }
    }

    public var defaultQualityPreference: QualityPreference {
        didSet { UserDefaults.standard.set(defaultQualityPreference.rawValue, forKey: "defaultQualityPreference") }
    }

    public var defaultPointerMode: PointerMode {
        didSet { UserDefaults.standard.set(defaultPointerMode.rawValue, forKey: "defaultPointerMode") }
    }

    public var tabletopConsoleMode: TabletopConsoleMode {
        didSet { UserDefaults.standard.set(tabletopConsoleMode.rawValue, forKey: "tabletopConsoleMode") }
    }

    public var requireBiometricsGlobally: Bool {
        didSet { UserDefaults.standard.set(requireBiometricsGlobally, forKey: "requireBiometricsGlobally") }
    }

    public var autoDiscoverBonjour: Bool {
        didSet { UserDefaults.standard.set(autoDiscoverBonjour, forKey: "autoDiscoverBonjour") }
    }

    public var viewOnly: Bool {
        didSet { UserDefaults.standard.set(viewOnly, forKey: "viewOnly") }
    }

    public var hasCompletedInitialSetup: Bool {
        didSet { UserDefaults.standard.set(hasCompletedInitialSetup, forKey: "hasCompletedInitialSetup") }
    }

    public init() {
        let displayDefault = DisplayPreference.fit.rawValue
        let displayRaw = UserDefaults.standard.string(forKey: "defaultDisplayPreference") ?? displayDefault
        defaultDisplayPreference = DisplayPreference(rawValue: displayRaw) ?? .fit

        let qualityDefault = QualityPreference.adaptive.rawValue
        let qualityRaw = UserDefaults.standard.string(forKey: "defaultQualityPreference") ?? qualityDefault
        defaultQualityPreference = QualityPreference(rawValue: qualityRaw) ?? .adaptive

        let pointerDefault = PointerMode.directTouch.rawValue
        let pointerRaw = UserDefaults.standard.string(forKey: "defaultPointerMode") ?? pointerDefault
        defaultPointerMode = PointerMode(rawValue: pointerRaw) ?? .directTouch

        let tabletopDefault = TabletopConsoleMode.auto.rawValue
        let tabletopRaw = UserDefaults.standard.string(forKey: "tabletopConsoleMode") ?? tabletopDefault
        tabletopConsoleMode = TabletopConsoleMode(rawValue: tabletopRaw) ?? .auto

        requireBiometricsGlobally = UserDefaults.standard.bool(forKey: "requireBiometricsGlobally")
        autoDiscoverBonjour = UserDefaults.standard.object(forKey: "autoDiscoverBonjour") as? Bool ?? true
        viewOnly = UserDefaults.standard.bool(forKey: "viewOnly")

        if let explicit = UserDefaults.standard.object(forKey: "hasCompletedInitialSetup") as? Bool {
            hasCompletedInitialSetup = explicit
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let file = appSupport.appendingPathComponent("ScreenVNC", isDirectory: true).appendingPathComponent("profiles.json")
            hasCompletedInitialSetup = FileManager.default.fileExists(atPath: file.path)
        }
    }
}
