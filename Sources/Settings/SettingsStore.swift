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

public enum TwoFingerTrackpadAction: String, Codable, Sendable, CaseIterable {
    case scrollRemote
    case panViewport

    public var displayName: String {
        switch self {
        case .scrollRemote: "Scroll Remote Mac"
        case .panViewport: "Pan Zoomed Screen"
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

    public var trackpadSensitivity: Double {
        didSet {
            let clamped = min(max(trackpadSensitivity, 0.5), 2.5)
            if clamped != trackpadSensitivity {
                trackpadSensitivity = clamped
                return
            }
            UserDefaults.standard.set(clamped, forKey: "trackpadSensitivity")
        }
    }

    public var naturalScrolling: Bool {
        didSet { UserDefaults.standard.set(naturalScrolling, forKey: "naturalScrolling") }
    }

    public var invertPanDirection: Bool {
        didSet { UserDefaults.standard.set(invertPanDirection, forKey: "invertPanDirection") }
    }

    public var twoFingerTrackpadAction: TwoFingerTrackpadAction {
        didSet { UserDefaults.standard.set(twoFingerTrackpadAction.rawValue, forKey: "twoFingerTrackpadAction") }
    }

    public var tapToClickInTrackpad: Bool {
        didSet { UserDefaults.standard.set(tapToClickInTrackpad, forKey: "tapToClickInTrackpad") }
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

        let storedSensitivity = UserDefaults.standard.object(forKey: "trackpadSensitivity") as? Double ?? 1.0
        trackpadSensitivity = min(max(storedSensitivity, 0.5), 2.5)
        naturalScrolling = UserDefaults.standard.object(forKey: "naturalScrolling") as? Bool ?? true
        invertPanDirection = UserDefaults.standard.bool(forKey: "invertPanDirection")
        let twoFingerRaw = UserDefaults.standard.string(forKey: "twoFingerTrackpadAction") ?? TwoFingerTrackpadAction.scrollRemote.rawValue
        twoFingerTrackpadAction = TwoFingerTrackpadAction(rawValue: twoFingerRaw) ?? .scrollRemote
        tapToClickInTrackpad = UserDefaults.standard.object(forKey: "tapToClickInTrackpad") as? Bool ?? true

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
