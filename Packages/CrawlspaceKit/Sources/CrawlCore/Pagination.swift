import Foundation

/// The pages of a list split across several addresses: a collection's `?page=2`, a blog's
/// `/page/2/`.
///
/// Google treats each page of a series as a page in its own right, with its own address and its
/// own canonical. Page 2 sharing page 1's heading, description and most of its text is how a list
/// is built, not duplication, so the later pages are left out when looking for duplicates.
public enum Pagination {
    /// Query parameters that number a list's pages: `page`, and WordPress's `paged`. Not `p`,
    /// which is a WordPress post's number.
    static let parameters: Set<String> = ["page", "paged"]

    /// Which page of a list an address is, when it's a later one: 2 and on. Nil for the first page
    /// — including `?page=1`, which is a copy of it and a duplicate as Google sees it — and for
    /// anything that isn't a page of a list.
    public static func laterPage(of address: String) -> Int? {
        guard let components = URLComponents(string: address) else { return nil }
        for item in components.queryItems ?? [] where parameters.contains(item.name.lowercased()) {
            if let number = item.value.flatMap(Int.init), number >= 2 { return number }
        }
        // WordPress: /blog/page/3/.
        let segments = components.path.split(separator: "/")
        if segments.count >= 2, segments[segments.count - 2].lowercased() == "page",
           let number = Int(segments[segments.count - 1]), number >= 2 {
            return number
        }
        return nil
    }
}
