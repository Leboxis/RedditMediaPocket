import Foundation

public struct SavedMediaCount: Codable {
    public let count: Int
    public let computedAt: Date

    public init(folder: URL, computedAt: Date = Date()) throws {
        count = try CollectionFiles.scan(folder).files.count
        self.computedAt = computedAt
    }
}
