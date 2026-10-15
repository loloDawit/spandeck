import Foundation

/// Why owner-only storage refused to go on (R8). The cache is then not written; nothing falls back to weaker storage.
enum StorageFailure: Error, Equatable {
    /// The cache folder is a symlink or not a folder, or a cache file is a symlink or not a regular file.
    case unsafeLocation
    /// The cache folder or file belongs to another user.
    case notOwned
    /// The folder or file couldn't be made owner-only.
    case permissions
    case io(Int32)

    var text: String {
        switch self {
        case .unsafeLocation: return "the cache folder or file is a link or not a regular folder or file"
        case .notOwned: return "the cache folder or file belongs to another user"
        case .permissions: return "the cache couldn't be made readable by you only"
        case .io(let code): return String(cString: strerror(code))
        }
    }
}

/// One application-owned folder whose files only the current user can read (R8): the folder must be a real folder
/// (not a symlink) owned by the user and is kept at 0700; its parent folders are never changed. Files are created 0600
/// before any data is written and moved into place with rename(2), and are opened without following symlinks, so a
/// planted link can't redirect a write, a read or a delete.
struct PrivateDirectory {
    let url: URL
    /// chmod(2); a test seam for a folder whose mode can't be changed.
    var setMode: (String, mode_t) -> Int32 = { chmod($0, $1) }

    private static let tempMarker = ".tmp-"

    /// Creates the folder (0700) if missing, otherwise checks it and tightens its mode to 0700. Throws rather than
    /// continuing with weaker protection.
    func prepare() throws {
        let path = url.path
        var st = stat()
        if lstat(path, &st) != 0 {
            guard errno == ENOENT else { throw StorageFailure.io(errno) }
            // Only missing parents are created; existing ones are left as they are.
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if mkdir(path, 0o700) != 0, errno != EEXIST { throw StorageFailure.io(errno) }
            guard lstat(path, &st) == 0 else { throw StorageFailure.io(errno) }
        }
        try Self.checkFolder(st)
        if st.st_mode & 0o777 != 0o700 {
            guard setMode(path, 0o700) == 0, lstat(path, &st) == 0, st.st_mode & 0o777 == 0o700 else {
                throw StorageFailure.permissions
            }
        }
    }

    /// The file's bytes, or nil if there is none. Never follows a symlink; a file readable by others is made 0600.
    func read(_ name: String) throws -> Data? {
        try checkExistingFolder()
        let fd = open(url.appendingPathComponent(name).path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw errno == ELOOP ? StorageFailure.unsafeLocation : StorageFailure.io(errno)
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw StorageFailure.io(errno) }
        guard st.st_mode & S_IFMT == S_IFREG else { throw StorageFailure.unsafeLocation }
        guard st.st_uid == getuid() else { throw StorageFailure.notOwned }
        if st.st_mode & 0o777 != 0o600, fchmod(fd, 0o600) != 0 { throw StorageFailure.permissions }
        return try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data()
    }

    /// Replaces the file atomically. The temporary file is created 0600 (O_EXCL, O_NOFOLLOW) before anything is
    /// written to it, and removed if the write fails.
    func write(_ data: Data, to name: String) throws {
        try prepare()
        let temp = url.appendingPathComponent("." + name + Self.tempMarker + UUID().uuidString).path
        let fd = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw StorageFailure.io(errno) }
        var moved = false
        defer { if !moved { unlink(temp) } }
        var failure: StorageFailure?
        if fchmod(fd, 0o600) != 0 { failure = .permissions }
        if failure == nil {
            failure = data.withUnsafeBytes { buf -> StorageFailure? in
                var offset = 0
                while offset < buf.count {
                    let n = Darwin.write(fd, buf.baseAddress! + offset, buf.count - offset)
                    if n < 0 {
                        if errno == EINTR { continue }
                        return .io(errno)
                    }
                    offset += n
                }
                return nil
            }
        }
        if failure == nil, fsync(fd) != 0 { failure = .io(errno) }
        close(fd)
        if let failure { throw failure }
        guard rename(temp, url.appendingPathComponent(name).path) == 0 else { throw StorageFailure.io(errno) }
        moved = true
    }

    /// Removes the file; a symlink is removed itself, never its target. A missing file or folder is fine.
    func remove(_ name: String) throws {
        guard try checkExistingFolder() else { return }
        if unlink(url.appendingPathComponent(name).path) != 0, errno != ENOENT { throw StorageFailure.io(errno) }
    }

    /// Removes temporary files an interrupted `write` of `name` left behind.
    func removeTemporaryFiles(of name: String) throws {
        guard try checkExistingFolder() else { return }
        let prefix = "." + name + Self.tempMarker
        for item in (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [] where item.hasPrefix(prefix) {
            if unlink(url.appendingPathComponent(item).path) != 0, errno != ENOENT { throw StorageFailure.io(errno) }
        }
    }

    /// Checks the folder without creating or changing it; false if it doesn't exist.
    @discardableResult
    private func checkExistingFolder() throws -> Bool {
        var st = stat()
        if lstat(url.path, &st) != 0 {
            if errno == ENOENT { return false }
            throw StorageFailure.io(errno)
        }
        try Self.checkFolder(st)
        return true
    }

    private static func checkFolder(_ st: stat) throws {
        guard st.st_mode & S_IFMT == S_IFDIR else { throw StorageFailure.unsafeLocation }
        guard st.st_uid == getuid() else { throw StorageFailure.notOwned }
    }
}
