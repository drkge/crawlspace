/// Which build this is. CI rewrites this file for each release; a local build says "dev".
public enum AppVersion {
    public static let current = "2.0.0-dev"
    public static let commit = "dev"
}
