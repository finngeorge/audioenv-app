import Foundation

/// Generic wrapper for paginated API responses.
/// API returns: `{ "items": [...], "total": N, "page": N, "per_page": N, "pages": N }`
struct PaginatedResponse<T: Decodable>: Decodable {
    let items: [T]
    let total: Int
    let page: Int
    let perPage: Int
    let pages: Int

    enum CodingKeys: String, CodingKey {
        case items, total, page, pages
        case perPage = "per_page"
    }
}
