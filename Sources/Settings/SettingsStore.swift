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

    public init() {
        let displayDefault = DisplayPreference.fit.rawValue
        let displayRaw = UserDefaults.standard.string(forKey: "defaultDisplayPreference") ?? displayDefault
        defaultDisplayPreference = DisplayPreference(rawValue: displayRaw) ?? .fit

        let qualityDefault = QualityPreference.adaptive.rawValue
        let qualityRaw = UserDefaults.standard.string(forKey: "defaultQualityPreference") ?? qualityDefault
        defaultQualityPreference = QualityPreference(rawValue: qualityRaw) ?? .adaptive

        let tabletopDefault = TabletopConsoleMode.auto.rawValue
        let tabletopRaw = UserDefaults.standard.string(forKey: "tabletopConsoleMode") ?? tabletopDefault
        tabletopConsoleMode = TabletopConsoleMode(rawValue: tabletopRaw) ?? .auto

        requireBiometricsGlobally = UserDefaults.standard.bool(forKey: "requireBiometricsGlobally")
        autoDiscoverBonjour = UserDefaults.standard.object(forKey: "autoDiscoverBonjour") as? Bool ?? true
        viewOnly = UserDefaults.standard.bool(forKey: "viewOnly")
    }
}
