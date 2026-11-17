import Foundation

/// When the standard Heart Rate Measurement characteristic (0x2A37) should be notifying.
///
/// Pure so the policy is testable without a strap. The BLE layer applies the answer with
/// `setNotifyValue` on the existing characteristic — no new opcodes or frame bytes.
enum LiveHRDemand {
    /// A live surface appeared. Clamped only so tests can feed a negative without wrapping.
    static func retain(_ count: Int) -> Int { count + 1 }

    /// A live surface disappeared. Never goes below zero, so an extra stop cannot wedge notify off.
    static func release(_ count: Int) -> Int { max(0, count - 1) }

    /// Subscribe iff a live surface holds a demand, Continuous HRV wants the stream, the policy
    /// flag is off (legacy always-on), or the connect handshake still needs the discovery
    /// subscription left in place.
    static func shouldSubscribe(demandCount: Int,
                                continuousHRV: Bool,
                                policyEnabled: Bool,
                                holdForHandshake: Bool = false) -> Bool {
        if holdForHandshake { return true }
        if !policyEnabled { return true }
        return demandCount > 0 || continuousHRV
    }
}
