import Foundation

public struct FoundationFileIO: SwitcherooFileIO {
    private let fileManager: FileManager
    private let permissionSetter: ((Int, String) throws -> Void)?

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.permissionSetter = nil
    }

    init(fileManager: FileManager = .default, permissionSetter: ((Int, String) throws -> Void)? = nil) {
        self.fileManager = fileManager
        self.permissionSetter = permissionSetter
    }

    public func fileExists(path: String) -> Bool {
        fileManager.fileExists(atPath: url(forPath: path).path)
    }

    public func itemExists(path: String) -> Bool {
        fileManager.fileExists(atPath: url(forPath: path).path)
    }

    public func readFile(path: String) throws -> Data {
        try Data(contentsOf: url(forPath: path))
    }

    public func writeFileAtomically(_ data: Data, path: String, permissions: Int?) throws {
        let url = url(forPath: path)
        let directory = url.deletingLastPathComponent()
        try ensureDirectoryChain(directory)

        let tempURL = try createExclusiveTemporaryFile(in: directory)
        defer { try? fileManager.removeItem(at: tempURL) }

        let handle = try FileHandle(forWritingTo: tempURL)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()

        if let permissions {
            try applyPermissions(permissions, to: tempURL.path)
        }

        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: tempURL, backupItemName: nil, options: [.usingNewMetadataOnly])
        } else {
            try fileManager.moveItem(at: tempURL, to: url)
        }
        try fsyncDirectory(directory)
    }

    public func removeItem(path: String) throws {
        let url = url(forPath: path)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    public func createDirectoryExclusive(path: String) throws {
        let url = url(forPath: path)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    public func createDirectory(path: String, withIntermediateDirectories: Bool) throws {
        let url = url(forPath: path)
        if withIntermediateDirectories {
            try ensureDirectoryChain(url)
        } else {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
    }

    public func modificationDate(path: String) -> Date? {
        let url = url(forPath: path)
        return (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    public func setModificationDate(path: String, date: Date) throws {
        let url = url(forPath: path)
        try fileManager.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    public func canonicalDestinationPath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL

        // realpath resolves every existing symlink (including /var -> /private/var).
        if let resolved = realPath(url.path) {
            return resolved
        }

        // The destination does not exist yet: resolve the deepest existing
        // ancestor and append the missing tail.
        var prefix = url
        var suffix: [String] = []
        while !fileManager.fileExists(atPath: prefix.path) && prefix.path != "/" {
            suffix.insert(prefix.lastPathComponent, at: 0)
            prefix = prefix.deletingLastPathComponent()
        }
        let resolvedPrefix = realPath(prefix.path) ?? prefix.path
        return suffix.reduce(resolvedPrefix) { ($0 as NSString).appendingPathComponent($1) }
    }

    public func withExclusiveLock<T>(path: String, _ body: () throws -> T) throws -> T {
        let url = url(forPath: path)
        try ensureDirectoryChain(url.deletingLastPathComponent())

        let fd = open(url.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Could not open lock file \(url.path)"])
        }
        defer { close(fd) }

        while flock(fd, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Could not lock \(url.path)"])
        }
        defer { flock(fd, LOCK_UN) }

        return try body()
    }

    // MARK: - Internals

    /// Create the destination's directory chain, giving every component Switcheroo
    /// creates mode 0700 (never loosening an existing directory).
    private func ensureDirectoryChain(_ directory: URL) throws {
        guard !fileManager.fileExists(atPath: directory.path) else { return }
        try ensureDirectoryChain(directory.deletingLastPathComponent())
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    /// Create a unique temporary file in `directory`, opened exclusively with
    /// mode 0600 before any bytes are written. Never reuses a fixed name, so
    /// concurrent writers cannot publish each other's bytes.
    private func createExclusiveTemporaryFile(in directory: URL) throws -> URL {
        for _ in 0..<16 {
            let tempURL = directory.appendingPathComponent(".switcheroo.\(UUID().uuidString).tmp")
            let fd = open(tempURL.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            if fd >= 0 {
                close(fd)
                return tempURL
            }
            let code = errno
            if code == EEXIST { continue }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSLocalizedDescriptionKey: "Could not create temporary file in \(directory.path)"])
        }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(EEXIST), userInfo: [NSLocalizedDescriptionKey: "Could not create a unique temporary file in \(directory.path)"])
    }

    private func applyPermissions(_ permissions: Int, to path: String) throws {
        if let permissionSetter {
            try permissionSetter(permissions, path)
        } else {
            try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: path)
        }
    }

    private func fsyncDirectory(_ directory: URL) throws {
        let fd = open(directory.path, O_RDONLY)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Could not open directory \(directory.path) for syncing"])
        }
        defer { close(fd) }
        guard fsync(fd) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Could not sync directory \(directory.path)"])
        }
    }

    private func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func url(forPath path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
    }
}
