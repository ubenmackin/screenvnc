// App — Device mode detection, aspect-ratio classification, and foldable posture.
import SwiftUI

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
}

public enum HingePosture: String, Sendable {
    case closed
    case tabletop
    case flat
}

public enum DeviceModeDetector {
    /// Detects if the current running device is an iPhone Duo (foldable) hardware or simulator.
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
        let bounds = UIScreen.main.bounds
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

    /// Classifies device modes from SwiftUI environment traits, screen geometry, and hinge angle.
    public static func detectMode(
        horizontalSizeClass: UserInterfaceSizeClass?,
        verticalSizeClass: UserInterfaceSizeClass?,
        screenSize: CGSize,
        hingeAngle _: Double = 180.0
    ) -> DeviceMode {
        // Mode 2: iPad or iPhone Duo Unfolded Inner Screen (regular width + regular height)
        if horizontalSizeClass == .regular && verticalSizeClass == .regular {
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
