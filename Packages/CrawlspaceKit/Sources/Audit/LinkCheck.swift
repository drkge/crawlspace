import Foundation

/// Tells a link that is broken from one the far end simply wouldn't let a crawler check.
///
/// Many "broken" external links are research publishers, video sites and the like answering 403
/// behind a Cloudflare challenge, 406 to an unfamiliar client, or newspapers answering 402 at
/// their paywall. Every one of them loads in a browser.
/// Reporting them as broken buried the handful that really were, and a crawler can't tell them
/// apart without pretending to be a browser, which Crawlspace won't do. So they get their own,
/// milder finding: "couldn't check this — look at it yourself".
public enum LinkCheck {
    /// Statuses sites send when they won't serve an automated request, not because the page has
    /// gone: sign-in (401, 407), paywalls (402), bot blocking (403, and LinkedIn's 999), content
    /// negotiation that rejects crawlers (406), and rate limiting (429).
    public static let refusalStatuses: Set<Int> = [401, 402, 403, 406, 407, 429, 999]

    /// Headers that bot-protection services add when they challenge a request. Only trusted on an
    /// error response: some of them appear on every response those services serve.
    static let challengeHeaders = ["cf-mitigated", "x-datadome", "x-amzn-waf-action", "x-px-block"]

    public static func refusedAutomatedCheck(status: Int?, headers: [String: String]) -> Bool {
        guard let status, status >= 400 else { return false }
        if refusalStatuses.contains(status) { return true }
        let names = Set(headers.keys.map { $0.lowercased() })
        return challengeHeaders.contains { names.contains($0) }
    }

    /// Paths that redirect by design: sign-in, account, basket and checkout. A Shopify store's
    /// account icon sits in the header of every page and bounces to shopify.com to sign in, which
    /// would make every page "link to a redirect" — over a link the store can't change. Matched on the link's target and on where it redirects to.
    static let redirectsByDesign = [
        "/customer_authentication/", "/account", "/login", "/log-in", "/signin", "/sign-in",
        "/cart", "/basket", "/checkout", "/wp-login.php", "/my-account", "/auth/",
    ]

    /// SQL for "this internal redirect is a sign-in, account or checkout bounce".
    public static func sqlRedirectByDesign(_ alias: String) -> String {
        let patterns = redirectsByDesign.flatMap { path in
            ["\(alias).url LIKE '%\(path)%'", "\(alias).redirect_url LIKE '%\(path)%'"]
        }
        return "(" + patterns.joined(separator: " OR ") + ")"
    }

    /// The same test as SQL over a `urls` row, for re-checking crawls saved before it existed.
    /// Stored headers are a JSON object with lower-cased names.
    public static func sql(_ alias: String) -> String {
        let statuses = refusalStatuses.sorted().map(String.init).joined(separator: ",")
        let headers = challengeHeaders.map { "\(alias).headers LIKE '%\"\($0)\"%'" }.joined(separator: " OR ")
        return "(\(alias).status_code IN (\(statuses)) OR (\(alias).status_code >= 400 AND (\(headers))))"
    }
}
