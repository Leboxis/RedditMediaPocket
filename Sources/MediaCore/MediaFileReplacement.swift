import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Publish prepared metadata without deleting the original first. Staging in
/// the same directory keeps rename atomic and avoids cross-volume moves.
public enum MediaFileReplacement {
    public static func replace(_ original: URL, with prepared: URL) throws {
        guard original.isFileURL, prepared.isFileURL,
              original.standardizedFileURL != prepared.standardizedFileURL,
              original.standardizedFileURL.deletingLastPathComponent()
                == prepared.standardizedFileURL.deletingLastPathComponent() else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        guard rename(prepared.path, original.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}
