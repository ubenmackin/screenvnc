// VNC — Protocol version, security types, encodings, and message identifiers.
import Foundation

public enum RFBConstants {
    public static let version33 = "RFB 003.003\n"
    public static let version37 = "RFB 003.007\n"
    public static let version38 = "RFB 003.008\n"
    public static let version3889 = "RFB 003.889\n"

    public enum SecurityType: UInt8, Sendable {
        case invalid = 0
        case none = 1
        case vncAuth = 2
        case appleDH = 30
        case appleRSA = 33
    }

    public enum Encoding: Int32, Sendable {
        case raw = 0
        case copyRect = 1
        case rre = 2
        case corre = 4
        case hextile = 5
        case zlib = 6
        case tight = 7
        case zrle = 16
        case cursor = -239 // 0xFFFFFF11
        case desktopSize = -223 // 0xFFFFFF21
        case extendedDesktopSize = -224 // 0xFFFFFF20
        case lastRect = -225 // 0xFFFFFF1F
    }

    public enum ClientMessage: UInt8, Sendable {
        case setPixelFormat = 0
        case fixColourMapEntries = 1
        case setEncodings = 2
        case framebufferUpdateRequest = 3
        case keyEvent = 4
        case pointerEvent = 5
        case clientCutText = 6
    }

    public enum ServerMessage: UInt8, Sendable {
        case framebufferUpdate = 0
        case setColourMapEntries = 1
        case bell = 2
        case serverCutText = 3
    }
}
