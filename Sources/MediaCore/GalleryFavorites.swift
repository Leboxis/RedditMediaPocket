import Foundation

public enum GalleryFavorites {
    public static func key(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    @discardableResult
    public static func toggle(_ favorites: inout Set<String>, _ url: URL) -> Bool {
        let key = key(for: url)
        if favorites.contains(key) {
            favorites.remove(key)
            return false
        }
        favorites.insert(key)
        return true
    }

    public static func isFavorite(_ favorites: Set<String>, _ url: URL) -> Bool {
        favorites.contains(key(for: url))
    }

    public static func filter(_ files: [URL], favorites: Set<String>, onlyFavorites: Bool) -> [URL] {
        guard onlyFavorites else { return files }
        return files.filter { favorites.contains(key(for: $0)) }
    }

    public static func encode(_ favorites: Set<String>) throws -> Data {
        try JSONEncoder().encode(Array(favorites).sorted())
    }

    public static func decode(_ data: Data) throws -> Set<String> {
        Set(try JSONDecoder().decode([String].self, from: data))
    }
}
