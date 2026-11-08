// App — Device mode detection, aspect-ratio classification, and foldable posture.
import SwiftUI
import UIKit

public enum DeviceMode: String, Sendable, CaseIterable {
    case mode1NormalPhone
    case mode2InnerDisplayOrPad
    case mode3DuoOuterScreen

    public var displayName: String {
        switch self {
        case .mode1NormalPhone: "Normal iPhone"
        case .mode2InnerDisplayOrPad: "iPad / Duo Inner Display"
        case .mode3DuoOuterScreen: "iPhone Duo Outer Screen"
        }
    }

    /// Single gate for compact toolbar icons; keeps Duo checks consistent.
    /// Outer-screen layout favors icons for thumb reach and narrow width.
    @MainActor
    public static func shouldUseCompactIcons(deviceMode: DeviceMode) -> Bool {
        DeviceModeDetector.isDuoDevice || deviceMode == .mode3DuoOuterScreen
    }
}

public enum HingePosture: String, Sendable {
    case closed
    case tabletop
    case flat
}

public enum DeviceModeDetector {
    /// Detects if the current running device is an iPhone Duo (foldable) hardware or simulator.
    @MainActor
    public static var isDuoDevice: Bool {
        #if targetEnvironment(simulator)
            let simName = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? ""
            let simModel = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? ""
            if simName.localizedCaseInsensitiveContains("duo") || simModel.contains("iPhone19,") {
                return true
            }
        #endif
        let deviceName = UIDevice.current.name
        if deviceName.localizedCaseInsensitiveContains("duo") {
            return true
        }
        guard let bounds = activeScreenBounds else {
            return false
        }
        let maxDim = max(bounds.width, bounds.height)
        let minDim = min(bounds.width, bounds.height)
        if minDim > 0 {
            let ratio = maxDim / minDim
            if UIDevice.current.userInterfaceIdiom == .phone, ratio < 1.65 {
                return true
            }
        }
        return false
    }

    /// Resolves foreground screen via scene context; avoids deprecated UIScreen.main.
    /// Nil in background or tests; callers treat missing bounds as non-Duo.
    @MainActor
    private static var activeScreenBounds: CGRect? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let foreground = scenes.first(where: { $0.activationState == .foregroundActive })
        return (foreground ?? scenes.first)?.screen.bounds
    }

    /// Classifies device modes from traits, geometry, and hinge posture.
    @MainActor
    public static func detectMode(
        horizontalSizeClass: UserInterfaceSizeClass?,
        verticalSizeClass: UserInterfaceSizeClass?,
        screenSize: CGSize,
        hingeAngle: Double = 180.0
    ) -> DeviceMode {
        let posture = detectPosture(hingeAngle: hingeAngle)
        // Folded Duo keeps outer screen; avoids stale inner layout when closed.
        if posture == .closed, isDuoDevice {
            return .mode3DuoOuterScreen
        }

        // Mode 2: iPad or iPhone Duo Unfolded Inner Screen (regular width + regular height)
        if horizontalSizeClass == .regular && verticalSizeClass == .regular {
            return .mode2InnerDisplayOrPad
        }

        // Half-open Duo favors inner layout for split console use.
        if posture == .tabletop, isDuoDevice {
            return .mode2InnerDisplayOrPad
        }

        // iPhone Duo hardware / simulator folded outer display maps to Mode 3
        if isDuoDevice {
            return .mode3DuoOuterScreen
        }

        let maxDim = max(screenSize.width, screenSize.height)
        let minDim = min(screenSize.width, screenSize.height)
        let aspectRatio = minDim > 0 ? (maxDim / minDim) : 1.7

        // Aspect ratio fallback for outer screen if simulated without model identifier
        if aspectRatio < 1.65, horizontalSizeClass == .compact || verticalSizeClass == .compact {
            return .mode3DuoOuterScreen
        }

        // Mode 1: Standard iPhone form factor.
        return .mode1NormalPhone
    }

    public static func detectPosture(hingeAngle: Double) -> HingePosture {
        if hingeAngle <= 15.0 {
            .closed
        } else if hingeAngle < 135.0 {
            .tabletop
        } else {
            .flat
        }
    }
}
