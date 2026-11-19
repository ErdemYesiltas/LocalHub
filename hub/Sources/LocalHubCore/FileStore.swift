import CryptoKit
import Foundation

public struct HubFile: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    /// Owner. Devices only ever see their own files.
    public let deviceID: String?
    public let filename: String
    public let mime: String
    public let bytes: Int
    /// `upload`, `output`, … (free text from the client, max 32 chars).
    public let purpose: String
    /// `upload` or `job`.
    public let source: String
    public let jobID: String?
    public let createdAt: Date
}

public enum FileError: Error, Equatable, LocalizedError {
    case unsupportedType(String), tooLarge(limit: Int), quotaExceeded(limit: Int), notFound
    public var errorDescription: String? {
        switch self {
        case .unsupportedType(let type): "Files of type \(type) are not supported"
        case .tooLarge(let limit): "The file exceeds the \(limit / 1_048_576) MiB limit"
        case .quotaExceeded(let limit): "The device's \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)) quota is full; delete files first"
        case .notFound: "The file is missing or belongs to another device"
        }
    }
}

/// Uploaded and generated files: content in `files/<id>.<ext>` (0600), metadata in `hub.sqlite`.
public final class FileStore: Sendable {
    public let directory: URL
    private let store: HubStore
    private let mutationLock = NSLock()
    public static let maxFileBytes = 100 * 1024 * 1024
    /// Generated videos can be large; outputs get a higher ceiling than uploads.
    public static let maxOutputBytes = 1024 * 1024 * 1024

    static let extensions: [String: String] = [
        "image/png": "png", "image/jpeg": "jpg", "image/webp": "webp", "image/gif": "gif",
        "audio/mpeg": "mp3", "audio/wav": "wav", "audio/x-wav": "wav", "audio/flac": "flac", "audio/ogg": "ogg",
        "video/mp4": "mp4", "video/webm": "webm", "video/quicktime": "mov", "image/apng": "apng",
        "application/json": "json", "text/plain": "txt",
        "model/gltf-binary": "glb", "model/gltf+json": "gltf", "model/obj": "obj", "model/stl": "stl",
    ]

    init(store: HubStore, directory: URL) throws {
        self.store = store
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }

    public static func mime(forFilename name: String) -> String? {
        let ext = (name as NSString).pathExtension.lowercased()
        return extensions.first { $0.value == ext || ($0.value == "jpg" && ext == "jpeg") }?.key
    }

    @discardableResult
    public func create(deviceID: String?, filename: String, mime: String, data: Data, purpose: String,
                       source: String, jobID: String? = nil, quota: Int, maxBytes: Int = maxFileBytes) throws -> HubFile {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        let mime = mime.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        guard let ext = Self.extensions[mime] else { throw FileError.unsupportedType(mime) }
        guard data.count <= maxBytes else { throw FileError.tooLarge(limit: maxBytes) }
        if let deviceID, try store.usage(deviceID: deviceID) + data.count > quota { throw FileError.quotaExceeded(limit: quota) }
        let id = "file-" + SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
        let name = String((filename as NSString).lastPathComponent
            .unicodeScalars.filter { $0.value >= 32 && $0.value != 127 }.map(Character.init).prefix(200))
        let file = HubFile(id: id, deviceID: deviceID, filename: name.isEmpty ? "\(id).\(ext)" : name, mime: mime,
            bytes: data.count, purpose: String(purpose.prefix(32)), source: source, jobID: jobID, createdAt: Date())
        let url = contentURL(file)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        do { try store.save(file) } catch { try? FileManager.default.removeItem(at: url); throw error }
        return file
    }

    /// `deviceID: nil` is the app's view of every file.
    public func list(deviceID: String?) throws -> [HubFile] { try store.files(deviceID: deviceID) }

    public func get(_ id: String, deviceID: String?) throws -> HubFile {
        guard let file = try store.file(id), deviceID == nil || file.deviceID == deviceID else { throw FileError.notFound }
        return file
    }

    public func contentURL(_ file: HubFile) -> URL {
        directory.appendingPathComponent("\(file.id).\(Self.extensions[file.mime] ?? "bin")")
    }

    public func data(_ file: HubFile) throws -> Data { try Data(contentsOf: contentURL(file)) }

    public func delete(_ id: String, deviceID: String?) throws {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        let file = try get(id, deviceID: deviceID)
        try store.deleteFile(file.id)
        try? FileManager.default.removeItem(at: contentURL(file))
    }

    public func usage(deviceID: String) throws -> Int { try store.usage(deviceID: deviceID) }
}
