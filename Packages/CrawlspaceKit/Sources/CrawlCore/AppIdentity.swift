/// Who the app is, in one place. It deliberately shares nothing with Crawlspace 1.x — not its
/// bundle ID, folder, Keychain items or launchd labels — so the two never trip over each other.
public enum AppIdentity {
    public static let name = "Crawlspace"
    public static let bundleID = "io.github.drkge.crawlspace"
    /// The app bundle as installed and as published: `Crawlspace.app`.
    public static let bundleName = "\(name).app"
    /// The release asset. GitHub turns spaces in asset names into dots, so this one has none.
    public static let releaseAsset = "Crawlspace.app.tar.gz"
    /// Where releases come from.
    public static let repository = "drkge/crawlspace"
}
