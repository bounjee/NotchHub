import Foundation
import os

/// Unix socket server that receives one JSON line per `notch-hook` invocation.
/// Each connection stays open until the hook exits, so a waiting PermissionRequest
/// notices when the hook process goes away.
final class HubServer: Sendable {
    let path: String
    private let onEvent: @Sendable (HookEvent, HubConnection) -> Void
    private let onClose: @Sendable (HubConnection) -> Void
    /// Identity of the socket file we bound, so we never delete another instance's socket.
    private let boundFile = OSAllocatedUnfairLock<(dev: dev_t, ino: ino_t)?>(initialState: nil)

    /// How long a client may take to send its line before we drop it.
    private let firstLineTimeout: Int
    static let maxLineLength = 16 * 1024 * 1024

    static var defaultPath: String {
        ProcessInfo.processInfo.environment["NOTCHHUB_SOCKET"]
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/NotchHub/hub.sock").path
    }

    init(
        path: String = HubServer.defaultPath,
        firstLineTimeout: Int = 5,
        onEvent: @escaping @Sendable (HookEvent, HubConnection) -> Void,
        onClose: @escaping @Sendable (HubConnection) -> Void
    ) {
        self.path = path
        self.firstLineTimeout = firstLineTimeout
        self.onEvent = onEvent
        self.onClose = onClose
    }

    /// True when another live process is already listening on `path`.
    static func isServing(at path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard var address = socketAddress(path) else { return false }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        } == 0
    }

    func start() throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        guard var address = Self.socketAddress(path) else { close(fd); throw POSIXError(.ENAMETOOLONG) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, SOMAXCONN) == 0 else {
            let code = errno
            close(fd)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        chmod(path, 0o600)
        var info = stat()
        if stat(path, &info) == 0 {
            let identity = (dev: info.st_dev, ino: info.st_ino)
            boundFile.withLock { $0 = identity }
        }

        let thread = Thread { [self] in acceptLoop(fd) }
        thread.name = "NotchHub.accept"
        // A full backlog makes macOS refuse connections outright, so accept promptly.
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Removes the socket file, but only if it is still the one this server created.
    func removeSocketFile() {
        guard let mine = boundFile.withLock({ $0 }) else { return }
        var info = stat()
        if stat(path, &info) == 0, info.st_dev == mine.dev, info.st_ino == mine.ino { unlink(path) }
    }

    private static func socketAddress(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }

    private func acceptLoop(_ listener: Int32) {
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 {
                switch errno {
                case EBADF, EINVAL: return
                case EINTR, ECONNABORTED: continue
                default:
                    // EMFILE and friends are temporary; never stop serving because of them.
                    log.error("accept failed: \(errno)")
                    usleep(50_000)
                    continue
                }
            }
            var noSigPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            Self.setReadTimeout(client, seconds: firstLineTimeout)
            let connection = HubConnection(fd: client)
            Thread.detachNewThread { [self] in serve(connection) }
        }
    }

    private static func setReadTimeout(_ fd: Int32, seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    private func serve(_ connection: HubConnection) {
        let fd = connection.fd
        var line = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var gotLine = false
        while !gotLine {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }  // closed, error or timed out
            if let newline = buffer[..<n].firstIndex(of: 0x0A) {
                line.append(contentsOf: buffer[..<newline])
                gotLine = true
            } else {
                line.append(contentsOf: buffer[..<n])
            }
            if line.count > Self.maxLineLength { break }
        }
        if gotLine, let event = HookEvent(json: line) {
            // A PermissionRequest may wait for the user as long as Claude Code allows.
            Self.setReadTimeout(fd, seconds: 0)
            onEvent(event, connection)
            // Block until the hook exits or we reply, whichever comes first.
            while true {
                let n = read(fd, &buffer, buffer.count)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
            }
        }
        connection.markClosed()
        close(fd)
        onClose(connection)
    }
}

final class HubConnection: PermissionReplying, @unchecked Sendable {
    let fd: Int32
    private let closed = OSAllocatedUnfairLock(initialState: false)

    init(fd: Int32) { self.fd = fd }

    func reply(_ line: Data) {
        closed.withLock { isClosed in
            guard !isClosed else { return }
            isClosed = true
            line.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let n = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                    if n < 0 && errno == EINTR { continue }
                    if n <= 0 { break }
                    offset += n
                }
            }
            // Wakes the reader thread, which then closes the descriptor.
            shutdown(fd, SHUT_RDWR)
        }
    }

    fileprivate func markClosed() {
        closed.withLock { $0 = true }
    }
}
