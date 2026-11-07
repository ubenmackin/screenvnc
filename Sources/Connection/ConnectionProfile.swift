// Connection — ScreenVNC host value for connection profiles.
import Foundation

public struct ConnectionProfile: Sendable, Hashable {
    public var host: String

    public init(host: String) {
        self.host = host
    }
}
