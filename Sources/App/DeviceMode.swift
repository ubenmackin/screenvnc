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
    /// Classifies device modes from SwiftUI environment traits, screen geometry, and hinge angle.
    public static func detectMode(
        horizontalSizeClass: UserInterfaceSizeClass?,
        verticalSizeClass: UserInterfaceSizeClass?,
        screenSize: CGSize,
        hingeAngle _: Double = 180.0
    ) -> DeviceMode {
        // Mode 2: iPad or iPhone Duo Unfolded Inner Screen (regular width + regular height, or flat wide canvas)
        if horizontalSizeClass == .regular && verticalSizeClass == .regular {
            return .mode2InnerDisplayOrPad
        }

        let maxDim = max(screenSize.width, screenSize.height)
        let minDim = min(screenSize.width, screenSize.height)
        let aspectRatio = minDim > 0 ? (maxDim / minDim) : 1.7

        // Mode 3: iPhone Duo Outer Screen has a shorter, passport-style aspect ratio (~1.45:1).
        // Standard modern iPhones have elongated aspect ratios (~19.5:9 or > 2.0:1).
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
