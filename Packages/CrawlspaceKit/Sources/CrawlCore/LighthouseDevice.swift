/// The two form factors Lighthouse is run as. Every page gets both.
public enum LighthouseDevice: String, Sendable, Codable, CaseIterable {
    case mobile
    case desktop

    /// Column prefix in the `urls` table: `lh_m_score`, `lh_d_score` and so on.
    public var columnPrefix: String { self == .mobile ? "lh_m_" : "lh_d_" }

    public var label: String { self == .mobile ? "Mobile" : "Desktop" }
}
