import Foundation
import os

/// Unix socket server that receives one JSON line per `notch-hook` invocation.
/// Each connection stays open until the hook exits, so a waiting PermissionRequest
/// notices when the hook process goes away.
final class HubServer: Sendable {
    let path: String
    private let onEvent: @Sendable (HookEvent, HubConnection) -> Void
    private let onClose: @Sendable (HubConnection) -> Void

    static var defaultPath: String {
        ProcessInfo.processInfo.environment["NOTCHHUB_SOCKET"]
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/NotchHub/hub.sock").path
    }

    init(
        path: String = HubServer.defaultPath,
        onEvent: @escaping @Sendable (HookEvent, HubConnection) -> Void,
        onClose: @escaping @Sendable (HubConnection) -> Void
    ) {
        self.path = path
        self.onEvent = onEvent
        self.onClose = onClose
    }

    func start() throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { close(fd); throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 32) == 0 else {
            let code = errno
            close(fd)
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        chmod(path, 0o600)

        let thread = Thread { [self] in acceptLoop(fd) }
        thread.name = "NotchHub.accept"
        thread.start()
    }

    private func acceptLoop(_ listener: Int32) {
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            var noSigPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            let connection = HubConnection(fd: client)
            Thread.detachNewThread { [self] in serve(connection) }
        }
    }

    private func serve(_ connection: HubConnection) {
        let fd = connection.fd
        var line = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var gotLine = false
        while !gotLine {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            if let newline = buffer[..<n].firstIndex(of: 0x0A) {
                line.append(contentsOf: buffer[..<newline])
                gotLine = true
            } else {
                line.append(contentsOf: buffer[..<n])
            }
            if line.count > 16 * 1024 * 1024 { break }
        }
        if gotLine, let event = HookEvent(json: line) {
            onEvent(event, connection)
            // Block until the hook exits or we reply, whichever comes first.
            while read(fd, &buffer, buffer.count) > 0 {}
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
