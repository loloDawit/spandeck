import Foundation

/// Why owner-only storage refused to go on (R8). The cache is then not written; nothing falls back to weaker storage.
enum StorageFailure: Error, Equatable {
    /// The cache folder is a symlink or not a folder, or a cache file is a symlink or not a regular file.
    case unsafeLocation
    /// The cache folder or file belongs to another user.
    case notOwned
    /// The folder or file couldn't be made owner-only.
    case permissions
    /// The cache or key couldn't be marked excluded from backup (audit 0007, P4). Foundation's error names the path, so
    /// it isn't kept.
    case backupExclusion
    case io(Int32)

    var text: String {
        switch self {
        case .unsafeLocation: return "the cache folder or file is a link or not a regular folder or file"
        case .notOwned: return "the cache folder or file belongs to another user"
        case .permissions: return "the cache couldn't be made readable by you only"
        case .backupExclusion: return "the cache or its key couldn't be excluded from backups"
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
    /// Marks a file excluded from backup; a test seam for a volume that can't hold the attribute.
    var markExcluded: (URL) throws -> Void = PrivateDirectory.setExcludedFromBackup

    /// Sets `isExcludedFromBackup` (audit 0007, P4), the attribute Time Machine reads, and reads it back through a new
    /// URL so a value Foundation cached for the old one can't stand in for the file's own.
    static func setExcludedFromBackup(_ file: URL) throws {
        var url = file
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        guard try URL(fileURLWithPath: file.path).resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
                == true else { throw StorageFailure.backupExclusion }
    }

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
    /// written to it, and removed if the write fails. With `excludedFromBackup`, it is marked before rename(2) moves it
    /// into place: a replacement doesn't inherit the old file's attribute, but keeps its own. If it can't be marked,
    /// nothing is moved into place.
    func write(_ data: Data, to name: String, excludedFromBackup: Bool) throws {
        try prepare()
        let temp = url.appendingPathComponent("." + name + Self.tempMarker + UUID().uuidString).path
        let fd = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw StorageFailure.io(errno) }
        var moved = false
        defer { if !moved { unlink(temp) } }
        var failure: StorageFailure?
        if fchmod(fd, 0o600) != 0 { failure = .permissions }
        // Marked while still empty, before any data is written (review of #90): a process that exits mid-write (a quit
        // that times out, #86) leaves no unmarked temporary file holding data. If it can't be marked, nothing is written.
        if failure == nil, excludedFromBackup {
            do { try markExcluded(URL(fileURLWithPath: temp)) } catch { failure = .backupExclusion }
        }
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

    /// Marks a file already in the folder excluded from backup, without changing its bytes. A missing file or folder
    /// is fine; a symlink, or anything but a regular file of the user's, is refused and never followed.
    func excludeFromBackup(_ name: String) throws {
        guard try checkExistingFolder() else { return }
        let file = url.appendingPathComponent(name)
        var st = stat()
        if lstat(file.path, &st) != 0 {
            if errno == ENOENT { return }
            throw StorageFailure.io(errno)
        }
        guard st.st_mode & S_IFMT == S_IFREG else { throw StorageFailure.unsafeLocation }
        guard st.st_uid == getuid() else { throw StorageFailure.notOwned }
        do { try markExcluded(file) } catch { throw StorageFailure.backupExclusion }
    }

    /// Removes the file; a symlink is removed itself, never its target. A missing file or folder is fine.
    func remove(_ name: String) throws {
        guard try checkExistingFolder() else { return }
        if unlink(url.appendingPathComponent(name).path) != 0, errno != ENOENT { throw StorageFailure.io(errno) }
    }

    /// Temporary files an interrupted `write` of `name` left behind. Throws if the folder can't be listed, rather than
    /// reporting none: a folder can be writable without being readable.
    func temporaryFiles(of name: String) throws -> [String] {
        guard try checkExistingFolder() else { return [] }
        guard let dir = opendir(url.path) else { throw StorageFailure.io(errno) }
        defer { closedir(dir) }
        let prefix = "." + name + Self.tempMarker
        var found: [String] = []
        errno = 0
        while let entry = readdir(dir) {
            let item = withUnsafeBytes(of: entry.pointee.d_name) { String(decoding: $0.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self) }
            if item.hasPrefix(prefix) { found.append(item) }
            errno = 0
        }
        if errno != 0 { throw StorageFailure.io(errno) }
        return found
    }

    /// Removes temporary files an interrupted `write` of `name` left behind; throws if any can't be listed or removed.
    func removeTemporaryFiles(of name: String) throws {
        for item in try temporaryFiles(of: name) { try remove(item) }
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
