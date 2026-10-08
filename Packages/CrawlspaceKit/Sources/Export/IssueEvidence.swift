import Audit
import CrawlCore
import Foundation
import GRDB
import Storage

/// The specifics behind one issue on one URL: exactly what is wrong, where it is, and what to do
/// about it on this page — rather than the catalogue's general description.
///
/// Shown in the inspector, and written into ClickUp so a task says which link, which image or which
/// title, not just "this page has a broken link".
public struct IssueEvidence: Sendable, Hashable, Codable {
    public struct Item: Sendable, Hashable, Identifiable, Codable {
        public var id: String { "\(text)|\(url ?? "")" }
        /// What is wrong, in a sentence.
        public var text: String
        /// The other URL involved — a link's target, or a page linking here — to open.
        public var url: String?
        /// Where on the page, for links and images.
        public var position: LinkPosition?
        /// How many pages carry this same link. Past a handful, it is part of the theme.
        public var pagesWithSameLink: Int?
    }

    public var items: [Item] = []
    /// Items left out past the limit.
    public var more = 0
    /// What to do about it on this page, with the specifics filled in.
    public var fix: String
    /// True when one change in the theme fixes it everywhere, rather than one per page.
    public var isTemplateWide = false
}

public enum IssueEvidenceBuilder {
    /// Enough to act on without burying a ClickUp task or the inspector.
    public static let limit = 25
    /// A link on this many pages is in the theme rather than typed into each page.
    static let templatePages = 10

    public static func evidence(for code: String, urlID: Int64, store: CrawlStore) throws -> IssueEvidence {
        let fallback = IssueCatalogue.definition(for: code)?.howToFix ?? ""
        return try store.pool.read { db in
            guard let page = try Row.fetchOne(db, sql: "SELECT * FROM urls WHERE id = ?", arguments: [urlID]) else {
                return IssueEvidence(fix: fallback)
            }
            return try build(code: code, page: page, urlID: urlID, db: db, fallback: fallback)
        }
    }

    // MARK: - By issue

    private static func build(code: String, page: Row, urlID: Int64, db: Database,
                              fallback: String) throws -> IssueEvidence {
        let site = hostOf(page["url"])
        switch code {
        // Links on this page that point somewhere wrong.
        case "links_to_broken_internal":
            return try linksFrom(urlID, where: "t.is_internal = 1 AND t.state = 1 AND \(broken)", db: db, site: site,
                                 describe: { "links to \($0.shown) — \($0.statusText)" },
                                 fix: "Point each link at a live page or take it out. If the page moved, redirect the old address to the new one with a 301 so other links keep working.")
        case "links_to_broken_external":
            return try linksFrom(urlID, where: "t.is_internal = 0 AND t.state = 1 AND \(broken) AND NOT \(LinkCheck.sql("t"))",
                                 db: db, site: site,
                                 describe: { "links to \($0.shown) — \($0.statusText)" },
                                 fix: "Find each page's current address on the other site and update the link, or remove it. Search the other site for the article title — they often have just moved it.")
        case "links_to_unverified_external":
            return try linksFrom(urlID, where: "t.is_internal = 0 AND t.state = 1 AND \(LinkCheck.sql("t"))", db: db, site: site,
                                 describe: { "links to \($0.shown) — the site refused an automated check (\($0.statusText))" },
                                 fix: "Click each link. If it opens for you, there's nothing to do. Only replace the ones that fail in a browser too.")
        case "links_to_redirect_internal":
            return try linksFrom(urlID, where: "t.is_internal = 1 AND t.state = 1 AND t.status_code BETWEEN 300 AND 399 AND NOT \(LinkCheck.sqlRedirectByDesign("t"))",
                                 db: db, site: site,
                                 describe: { link in
                                     let target = link.redirect.map { " → \(shorten($0, site: site))" } ?? ""
                                     return "links to \(link.shown), which redirects (\(link.statusText))\(target)"
                                 },
                                 fix: "Change each link to point straight at where it ends up (shown after the arrow). Visitors skip a hop and search engines stop spending crawl time on the redirect.")
        case "links_non_descriptive_anchor":
            let generic = PageAuditor.genericAnchors.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }.joined(separator: ",")
            return try linksFrom(urlID, where: "t.is_internal = 1 AND l.type = 0 AND lower(trim(l.text)) IN (\(generic))",
                                 db: db, site: site,
                                 describe: { "“\($0.text)” links to \($0.shown)" },
                                 fix: "Rewrite the link text to say where it goes — “Our returns policy” rather than “Click here”, “How our trees are planted” rather than “Find out more”. Screen readers list links out of context, and search engines use the words to understand the page it points to.")
        case "links_internal_nofollow":
            return try linksFrom(urlID, where: "t.is_internal = 1 AND l.type = 0 AND (l.flags & 1) = 1", db: db, site: site,
                                 describe: { "rel=\"nofollow\" on the link to \($0.shown)" },
                                 fix: "Remove rel=\"nofollow\" from links to your own pages unless you deliberately don't want them crawled.")

        // This URL itself answers badly: show where it is linked from, which is where to fix it.
        case "response_internal_4xx", "response_internal_5xx", "response_internal_no_response",
             "response_external_broken", "response_external_unverified":
            var evidence = try linkedFrom(urlID, db: db, site: site)
            let status = statusText(page["status_code"], page["error"])
            evidence.fix = switch code {
            case "response_internal_4xx":
                "This page answers \(status). Either bring it back, redirect it (301) to the closest live page, or update the \(total(evidence)) linking to it, listed here."
            case "response_internal_5xx":
                "The server failed with \(status). Check its logs for this address; until it's fixed, every page linking here is sending visitors to an error."
            case "response_external_unverified":
                "The other site refused an automated check (\(status)). Open it in a browser: if it loads, nothing needs doing."
            default:
                "It answers \(status). Update or remove the \(total(evidence)) linking to it, listed here."
            }
            return evidence
        case "response_internal_3xx":
            var evidence = try linkedFrom(urlID, db: db, site: site)
            let destination = (page["redirect_url"] as String?).map { shorten($0, site: site) } ?? "its new address"
            evidence.fix = "Redirects to \(destination). Update the \(total(evidence)) listed here to link there directly."
            return evidence
        case "redirect_chain", "redirect_loop":
            let path: String? = try String.fetchOne(db, sql: "SELECT path FROM redirect_chains WHERE start_id = ?", arguments: [urlID])
            let hops = (path ?? "").split(separator: "\n").map { shorten(String($0), site: site) }
            var evidence = IssueEvidence(
                items: hops.enumerated().map { .init(text: "Step \($0.offset + 1): \($0.element)") },
                fix: code == "redirect_loop"
                    ? "These redirects go round in a circle, so the page never loads. Fix the rule that sends the last step back to the first."
                    : "Redirect the first address straight to the last one, and update links to point at the last one directly."
            )
            if hops.isEmpty { evidence.fix = fallback }
            return evidence

        // What the page says about itself.
        case "title_missing":
            return IssueEvidence(fix: "Add a <title> that says what this page is, in 30–60 characters, different from every other page's.")
        case "title_over_60_characters", "title_over_561_pixels", "title_below_30_characters", "title_same_as_h1", "title_multiple":
            let title: String = page["title"] ?? ""
            let length: Int = page["title_length"] ?? title.count
            let pixels: Double = page["title_pixels"] ?? 0
            var items = [IssueEvidence.Item(text: "Title: “\(title)” — \(length) characters, \(Int(pixels)) px wide")]
            if code == "title_same_as_h1", let h1: String = page["h1"] { items.append(.init(text: "H1: “\(h1)”")) }
            if code == "title_multiple", let count: Int = page["title_count"] { items.append(.init(text: "\(count) <title> elements on the page")) }
            let fix = switch code {
            case "title_below_30_characters": "Lengthen it to 30–60 characters: add what the page offers and, where it helps, the brand."
            case "title_same_as_h1": "Make the title the version for search results — keywords first, brand last — and keep the H1 for people on the page."
            case "title_multiple": "Keep one <title>. A second usually comes from an app or theme section adding its own."
            default: "Shorten it to under 60 characters and 561 px so Google doesn't cut it off. Put the words that matter first; drop the brand name to the end, or out."
            }
            return IssueEvidence(items: items, fix: fix)
        case "title_duplicate":
            return try sameValue(column: "title", label: "Title", page: page, urlID: urlID, db: db, site: site,
                                 fix: "Give each of these pages its own title that says how it differs — the product, colour, size or topic.")
        case "meta_description_missing":
            return IssueEvidence(fix: "Write a meta description of 70–155 characters: what's on the page and why to click. Without one, Google picks a sentence itself.")
        case "meta_description_over_155_characters", "meta_description_over_985_pixels",
             "meta_description_below_70_characters", "meta_description_multiple":
            let text: String = page["meta_description"] ?? ""
            let length: Int = page["meta_description_length"] ?? text.count
            return IssueEvidence(
                items: [.init(text: "Meta description: “\(text)” — \(length) characters")],
                fix: code == "meta_description_below_70_characters"
                    ? "Expand it to 70–155 characters: what's on the page and a reason to click."
                    : "Trim it to under 155 characters so it isn't cut off in results, keeping the reason to click near the start."
            )
        case "meta_description_duplicate":
            return try sameValue(column: "meta_description", label: "Description", page: page, urlID: urlID, db: db, site: site,
                                 fix: "Write a description for each of these pages that says what is particular to it.")
        case "h1_missing":
            return IssueEvidence(fix: "Add one <h1> that names the page's subject. On Shopify it's usually the product or collection title in the theme's template.")
        case "h1_multiple":
            let first: String = page["h1"] ?? ""
            let second: String = page["h1_second"] ?? ""
            let count: Int = page["h1_count"] ?? 2
            return IssueEvidence(
                items: [.init(text: "\(count) H1s — first “\(first)”"), .init(text: "then “\(second)”")].filter { !$0.text.hasSuffix("“”") },
                fix: "Keep one H1 for the page's subject and make the others H2s. Repeated H1s often come from a theme section such as a logo or banner."
            )
        case "h1_over_70_characters":
            let h1: String = page["h1"] ?? ""
            return IssueEvidence(items: [.init(text: "H1: “\(h1)” — \(h1.count) characters")],
                                 fix: "Shorten the H1 to the page's subject; move the detail into the text beneath it.")
        case "h1_duplicate":
            return try sameValue(column: "h1", label: "H1", page: page, urlID: urlID, db: db, site: site,
                                 fix: "Give each page an H1 that says what is particular to it.")

        // Canonicals.
        case "canonical_target_non_200", "canonical_target_non_indexable", "canonical_canonicalised":
            let target: String? = page["canonical"]
            var items: [IssueEvidence.Item] = []
            if let target {
                let status: Int? = try Int.fetchOne(db, sql: "SELECT status_code FROM urls WHERE url = ?", arguments: [target])
                items.append(.init(text: "Canonical points to \(shorten(target, site: site))\(status.map { " — \($0)" } ?? "")", url: target))
            }
            return IssueEvidence(items: items, fix: code == "canonical_canonicalised"
                ? "Fine if this page is a variant of the one it points to. If it should rank on its own, make its canonical point at itself."
                : "Point the canonical at a live, indexable page — usually this page itself.")

        // Images on this page.
        case "images_missing_alt_attribute", "images_missing_alt_text", "images_missing_dimensions", "images_alt_over_100_characters":
            let condition = switch code {
            case "images_missing_alt_attribute": "(l.flags & \(LinkFlags.altAttributeMissing.rawValue)) != 0"
            case "images_missing_dimensions": "(l.flags & \(LinkFlags.dimensionsMissing.rawValue)) != 0"
            case "images_alt_over_100_characters": "length(l.text) > 100"
            default: "(l.flags & \(LinkFlags.altAttributeMissing.rawValue)) = 0 AND l.text = ''"
            }
            let fix = switch code {
            case "images_missing_dimensions": "Add width and height attributes to each image so the page doesn't jump about as it loads."
            case "images_alt_over_100_characters": "Cut each alt text down to a short description of the image — a sentence, not a paragraph."
            default: "Describe each image in its alt text (“Blue ceramic mug on an oak table”). Purely decorative images get alt=\"\"."
            }
            return try linksFrom(urlID, where: "l.type = 1 AND \(condition)", db: db, site: site,
                                 describe: { code == "images_alt_over_100_characters" ? "\($0.shown) — alt text \($0.text.count) characters" : $0.shown },
                                 fix: fix)
        case "images_over_100kb":
            var evidence = try linkedFrom(urlID, db: db, site: site)
            let size: Int = page["size_bytes"] ?? 0
            evidence.items.insert(.init(text: "\(size / 1_024) KB"), at: 0)
            evidence.fix = "Compress it or save it at the size it's shown — under 100 KB. On Shopify, re-uploading a smaller file replaces it on every page listed."
            return evidence

        case "content_near_duplicate":
            let rows = try Row.fetchAll(db, sql: """
                SELECT u.url, n.similarity FROM near_duplicates n JOIN urls u ON u.id = n.other_id
                WHERE n.url_id = ? ORDER BY n.similarity DESC LIMIT ?
                """, arguments: [urlID, limit])
            return IssueEvidence(
                items: rows.map { row in
                    let url: String = row[0]
                    let similarity: Double = row[1]
                    return .init(text: "\(Int(similarity * 100))% the same as \(shorten(url, site: site))", url: url)
                },
                fix: "Make each page say something the others don't, or merge them into one and redirect the rest to it."
            )

        // E-commerce.
        case "ecom_product_schema_missing":
            return IssueEvidence(
                items: [.init(text: "No Product structured data was found in this page")],
                fix: "Add Product JSON-LD to the product template. On Shopify that is {{ product | structured_data }} in the product section; if the theme already has it, check whether an app or a theme edit has replaced or removed it. Check the result in Google's Rich Results Test."
            )
        case "ecom_product_no_price", "ecom_product_no_availability", "ecom_product_no_image", "ecom_product_no_identifier":
            let product = try CrawlStore.loadProduct(id: urlID, db: db) ?? ProductData()
            return productDataEvidence(code, product)
        case "ecom_product_duplicate_path":
            let own: String = page["url"]
            let path = URL(string: own).flatMap(EcommercePaths.product(in:))
            let canonical: String? = page["canonical"]
            var items: [IssueEvidence.Item] = []
            if let path {
                let clean = own.replacingOccurrences(of: #"/collections/[^/]+/products/"#, with: "/products/", options: .regularExpression)
                items.append(.init(text: "The same product as \(path.cleanPath), which is the address it should be found at", url: clean))
            }
            items.append(.init(text: canonical == nil ? "This page has no canonical tag"
                                     : "Its canonical points to itself, so search engines treat it as a page of its own"))
            return IssueEvidence(
                items: items,
                fix: "Shopify's default theme sets this page's canonical to /products/handle. Look in the theme's <head> (theme.liquid) for <link rel=\"canonical\" href=\"{{ canonical_url }}\">, which has probably been removed or overridden, and put it back."
            )
        case "ecom_links_to_duplicate_product":
            return try linksFrom(urlID, where: "t.is_internal = 1 AND l.type = 0 AND t.url LIKE '%/collections/%/products/%'",
                                 db: db, site: site,
                                 describe: { link in
                                     let clean = URL(string: link.url).flatMap(EcommercePaths.product(in:))?.cleanPath ?? "its own address"
                                     return "links to \(link.shown) — the product's own address is \(clean)"
                                 },
                                 fix: "Change the theme's product card so it links to the product's own address (/products/handle) rather than the collection path. It is one snippet, so one edit fixes every collection.")
        case "ecom_product_orphan":
            let sitemap: String? = try String.fetchOne(db, sql: "SELECT sitemap FROM sitemap_urls WHERE url = ?", arguments: [page["url"] as String])
            return IssueEvidence(
                items: [.init(text: "No page on the site links to this product" + (sitemap.map { " — the crawler found it in \(shorten($0, site: site))" } ?? ""))],
                fix: "Add the product to a collection so shoppers and search engines can reach it by browsing. If it shouldn't be for sale, unpublish it or remove it from sales channels so it leaves the sitemap."
            )
        case "ecom_product_no_collection":
            let linkers = try pagesLinkingToProduct(page["url"] as String, db: db, site: site)
            return IssueEvidence(
                items: linkers.items + (linkers.items.isEmpty ? [] : [.init(text: "None of these is a collection page")]),
                more: linkers.more,
                fix: "Add the product to the collection it belongs in (Products → the product → Collections, or a manual collection's product list). Links from other pages help, but collections are where the site's structure and the internal links that rank products come from."
            )

        case "sitemap_non_200", "sitemap_non_indexable", "sitemap_orphan":
            let sitemap: String? = try String.fetchOne(db, sql: "SELECT sitemap FROM sitemap_urls WHERE url = ?", arguments: [page["url"] as String])
            return IssueEvidence(items: sitemap.map { [.init(text: "Listed in \($0)", url: $0)] } ?? [], fix: fallback)
        case let speed where PostCrawlAnalyzer.speedCodes.contains(speed):
            return try speedEvidence(code: code, page: page, urlID: urlID, db: db, fallback: fallback)
        default:
            return IssueEvidence(fix: fallback)
        }
    }

    // MARK: - Speed

    /// The numbers behind a Speed issue on each device, Lighthouse's biggest suggestions, and, for
    /// a page measured as a Shopify template, that one fix in the theme covers every page like it.
    private static func speedEvidence(code: String, page: Row, urlID: Int64, db: Database,
                                      fallback: String) throws -> IssueEvidence {
        func ms(_ value: Double) -> String { value >= 1_000 ? String(format: "%.1f s", value / 1_000) : "\(Int(value)) ms" }
        var items: [IssueEvidence.Item] = []
        for (label, prefix) in [("Mobile", "lh_m_"), ("Desktop", "lh_d_")] {
            let score: Double? = page["\(prefix)score"]
            let lcp: Double? = page["\(prefix)lcp_ms"]
            let cls: Double? = page["\(prefix)cls"]
            let tbt: Double? = page["\(prefix)tbt_ms"]
            let text: String? = switch code {
            case "lh_low_score", "lh_needs_improvement": score.map { "\(label): scores \(Int($0)) out of 100" }
            case "lh_poor_lcp": lcp.map { "\(label): main content appears after \(ms($0))\($0 > 4_000 ? " (over 4 s)" : "")" }
            case "lh_poor_cls": cls.map { "\(label): layout shifts by \(String(format: "%.2f", $0))\($0 > 0.25 ? " (over 0.25)" : "")" }
            case "lh_high_tbt": tbt.map { "\(label): blocked for \(ms($0))\($0 > 600 ? " (over 600 ms)" : "")" }
            default: nil
            }
            if let text { items.append(.init(text: text)) }
        }

        // The biggest suggestions across both devices, each named once.
        let rows = try Row.fetchAll(db, sql: "SELECT device, opportunities, template FROM lighthouse_reports WHERE url_id = ?",
                                    arguments: [urlID])
        var seen = Set<String>()
        let suggestions = rows
            .flatMap { row -> [(device: String, opportunity: LighthouseOpportunity)] in
                let json: String? = row["opportunities"]
                let list = json.flatMap { try? JSONDecoder().decode([LighthouseOpportunity].self, from: Data($0.utf8)) } ?? []
                return list.map { (device: row["device"] as String, opportunity: $0) }
            }
            .sorted { $0.opportunity.savingsMs > $1.opportunity.savingsMs }
            .filter { seen.insert($0.opportunity.id).inserted }
            .prefix(3)
        for suggestion in suggestions {
            let saving = suggestion.opportunity.savingsMs > 0
                ? " — saves about \(ms(suggestion.opportunity.savingsMs)) on \(suggestion.device)"
                : suggestion.opportunity.displayValue.map { " — \($0)" } ?? ""
            items.append(.init(text: "Suggested: \(suggestion.opportunity.title)\(saving)"))
        }

        var evidence = IssueEvidence(items: items, fix: fallback)
        if let template = rows.compactMap({ $0["template"] as String? }).first {
            // Templates many pages share; home, all products, cart and search are one page each.
            let shared = ["Product", "Collection", "Article", "Blog", "Page"].contains(template)
            evidence.items.insert(.init(text: "Measured as the store's \(template) page"), at: 0)
            if shared {
                evidence.isTemplateWide = true
                evidence.fix = "This page stands for every \(template.lowercased()) page: they're all built from the theme's \(template.lowercased()) template, so fix it there, once. " + fallback
            }
        }
        return evidence
    }

    // MARK: - E-commerce

    /// What the product's structured data lacks, in the variants' own terms.
    private static func productDataEvidence(_ code: String, _ product: ProductData) -> IssueEvidence {
        /// Several Product blocks on a page is a different problem from a variant missing a field:
        /// the fix is finding which app or template writes the incomplete block, not editing a variant.
        func blocks(_ count: Int, _ what: String) -> String {
            "\(count) of the \(product.entities) Product blocks on this page \(count == 1 ? "has" : "have") no \(what)"
        }
        let appHint = " This is usually a reviews or SEO app adding its own Product data beside the theme's; Google checks each block separately, so the incomplete one is reported as an error even though the other is fine."
        switch code {
        case "ecom_product_no_price":
            if product.entities > 1, product.entitiesNoPrice > 0 {
                return IssueEvidence(
                    items: [.init(text: blocks(product.entitiesNoPrice, "price"))],
                    fix: "Find where the incomplete block comes from — view the page source and search for \"application/ld+json\" — and remove it or turn off that app's structured data setting." + appHint
                )
            }
            return IssueEvidence(
                items: [.init(text: product.variants == 1 ? "The product's offer has no price"
                                                          : "\(product.variants - product.withPrice) of its \(product.variants) variants have no price")],
                fix: "Every variant's offer needs a price and a priceCurrency. If the structured data comes from a theme or an app, compare a variant that works with one that doesn't: it is usually a variant option the template doesn't handle."
            )
        case "ecom_product_no_availability":
            if product.entities > 1, product.entitiesNoAvailability > 0 {
                return IssueEvidence(
                    items: [.init(text: blocks(product.entitiesNoAvailability, "availability"))],
                    fix: "Find where the incomplete block comes from — view the page source and search for \"application/ld+json\" — and remove it or turn off that app's structured data setting." + appHint
                )
            }
            return IssueEvidence(
                items: [.init(text: product.variants == 1 ? "The product's offer doesn't say whether it is in stock"
                                                          : "\(product.variants - product.withAvailability) of its \(product.variants) variants don't say whether they are in stock")],
                fix: "Add availability to each offer (for example https://schema.org/InStock). Google shows stock status beside the price and leaves out products it can't tell are available."
            )
        case "ecom_product_no_image":
            return IssueEvidence(
                items: [.init(text: "The structured data has no image")],
                fix: "Add the product's image URL to the structured data. Google requires one for product rich results."
            )
        default:
            // "Variants" would be wrong for a page with two Product blocks and one variant.
            let scope = product.entities > 1 ? "in any of the \(product.entities) Product blocks on this page"
                : product.variants > 1 ? "on any of its \(product.variants) variants" : "in the product data"
            var items = [IssueEvidence.Item(text: "No GTIN, ISBN or MPN \(scope)")]
            if product.withSKU > 0 { items.append(.init(text: "It does have a SKU, which Google doesn't use to match products")) }
            return IssueEvidence(
                items: items,
                fix: "Enter the barcode on each variant (Products → the variant → Barcode) and make sure the structured data outputs it. Google matches products to its catalogue by GTIN, and Merchant Center expects one for branded goods. Products you make and brand yourself, with no barcode, can be left."
            )
        }
    }

    /// Pages that link to a product under any of its addresses — its own and its collection paths.
    private static func pagesLinkingToProduct(_ address: String, db: Database, site: String) throws -> (items: [IssueEvidence.Item], more: Int) {
        guard let handle = URL(string: address).flatMap(EcommercePaths.product(in:))?.handle else { return ([], 0) }
        let rows = try Row.fetchAll(db, sql: """
            SELECT DISTINCT s.url FROM links l
            JOIN urls t ON t.id = l.target_id JOIN urls s ON s.id = l.source_id
            WHERE l.type = \(LinkType.anchor.rawValue) AND t.is_internal = 1
              AND (t.url LIKE ? OR t.url LIKE ?) AND s.url NOT LIKE ?
            ORDER BY s.url LIMIT ?
            """, arguments: ["%/products/\(handle)", "%/products/\(handle)?%", "%/products/\(handle)%", limit + 1])
        let items = rows.prefix(limit).map { row -> IssueEvidence.Item in
            let url: String = row[0]
            return .init(text: "Linked from \(shorten(url, site: site))", url: url)
        }
        return (Array(items), max(0, rows.count - limit))
    }

    // MARK: - Links

    private static let broken = "(t.status_code >= 400 OR (t.status_code IS NULL AND t.blocked_by_robots = 0))"

    private struct Link {
        var url: String
        var shown: String
        var status: Int?
        var error: String?
        var redirect: String?
        var text: String
        var position: LinkPosition
        var sharedBy: Int
        var statusText: String { IssueEvidenceBuilder.statusText(status, error) }
    }

    /// Links from a page that meet a condition, most widely shared first — the ones in the theme.
    private static func linksFrom(_ urlID: Int64, where condition: String, db: Database, site: String,
                                  describe: (Link) -> String, fix: String) throws -> IssueEvidence {
        let rows = try Row.fetchAll(db, sql: """
            SELECT t.url, t.status_code, t.error, t.redirect_url, l.text, l.flags,
                   (SELECT COUNT(DISTINCT l2.source_id) FROM links l2
                     WHERE l2.target_id = l.target_id AND l2.type = l.type AND l2.text = l.text) AS shared
            FROM links l JOIN urls t ON t.id = l.target_id
            WHERE l.source_id = ? AND \(condition)
            ORDER BY shared DESC, t.url LIMIT ?
            """, arguments: [urlID, limit + 1])
        let links = rows.map { row -> Link in
            let url: String = row[0]
            return Link(url: url, shown: shorten(url, site: site), status: row[1], error: row[2], redirect: row[3],
                        text: row[4], position: LinkFlags(rawValue: row[5]).position, sharedBy: row[6])
        }
        var evidence = IssueEvidence(fix: fix)
        evidence.items = links.prefix(limit).map { link in
            var text = describe(link)
            if !link.text.isEmpty, !text.contains("“") { text = "“\(link.text)” " + text }
            return .init(text: text, url: link.url,
                         position: link.position == .unknown ? nil : link.position,
                         pagesWithSameLink: link.sharedBy)
        }
        evidence.more = max(0, links.count - limit)
        if let widest = links.first, widest.sharedBy >= templatePages {
            evidence.isTemplateWide = true
            let place = widest.position.isTemplate ? "the site's \(widest.position.label.lowercased())" : "a part of the theme"
            evidence.fix = "The same link is on \(widest.sharedBy) pages, so it's in \(place): change it once in the theme and it clears from all of them. " + fix
        }
        return evidence
    }

    /// Pages linking to this URL — where anything wrong with it is actually fixed.
    private static func linkedFrom(_ urlID: Int64, db: Database, site: String) throws -> IssueEvidence {
        let count = try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT source_id) FROM links WHERE target_id = ?", arguments: [urlID]) ?? 0
        let rows = try Row.fetchAll(db, sql: """
            SELECT s.url, l.text, l.flags FROM links l JOIN urls s ON s.id = l.source_id
            WHERE l.target_id = ? GROUP BY s.id ORDER BY s.url LIMIT ?
            """, arguments: [urlID, limit])
        var evidence = IssueEvidence(fix: "")
        evidence.items = rows.map { row in
            let url: String = row[0]
            let text: String = row[1]
            let position = LinkFlags(rawValue: row[2]).position
            let anchor = text.isEmpty ? "" : " as “\(text)”"
            return .init(text: "Linked from \(shorten(url, site: site))\(anchor)", url: url,
                         position: position == .unknown ? nil : position)
        }
        evidence.more = max(0, count - rows.count)
        evidence.isTemplateWide = count >= templatePages && evidence.items.contains { $0.position?.isTemplate == true }
        return evidence
    }

    private static func total(_ evidence: IssueEvidence) -> String {
        let count = evidence.items.count + evidence.more
        return "\(count.formatted()) \(count == 1 ? "page" : "pages")"
    }

    // MARK: - Shared values

    private static func sameValue(column: String, label: String, page: Row, urlID: Int64, db: Database,
                                  site: String, fix: String) throws -> IssueEvidence {
        let value: String = page[column] ?? ""
        let others = try String.fetchAll(db, sql: """
            SELECT url FROM urls WHERE \(column) = ? AND id != ? AND is_internal = 1 AND state = 1 ORDER BY url LIMIT ?
            """, arguments: [value, urlID, limit])
        var evidence = IssueEvidence(fix: fix)
        evidence.items = [.init(text: "\(label): “\(value)”")]
            + others.map { .init(text: "Also on \(shorten($0, site: site))", url: $0) }
        return evidence
    }

    // MARK: - Formatting

    static func statusText(_ status: Int?, _ error: String?) -> String {
        if let status {
            let reason = HTTPURLResponse.localizedString(forStatusCode: status).capitalized
            return "\(status) \(reason)"
        }
        return error ?? "no response"
    }

    /// Addresses on the crawled site are shown as their path; elsewhere, in full. The scheme has to
    /// match as well as the host: shown as a path, http://site/x and https://site/x look identical,
    /// which made an http link redirecting to https read as a page redirecting to itself.
    static func shorten(_ address: String, site: String) -> String {
        guard let url = URL(string: address), let host = url.host(), let scheme = url.scheme,
              "\(scheme)://\(host)" == site else { return address }
        let path = url.path().isEmpty ? "/" : url.path()
        return path + (url.query().map { "?\($0)" } ?? "")
    }

    /// scheme://host of the page, which is what counts as "this site" when shortening.
    private static func hostOf(_ address: String?) -> String {
        guard let url = address.flatMap(URL.init(string:)), let host = url.host(), let scheme = url.scheme else { return "" }
        return "\(scheme)://\(host)"
    }
}
