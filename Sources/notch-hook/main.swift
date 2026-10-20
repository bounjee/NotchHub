// notch-hook: Claude Code command hook. Forwards the hook's stdin JSON to NotchHub
// over a Unix socket and, for PermissionRequest, waits for the user's decision.
// Always exits 0. Writes nothing to stdout except the PermissionRequest decision.
import Foundation

signal(SIGPIPE, SIG_IGN)

let socketPath = ProcessInfo.processInfo.environment["NOTCHHUB_SOCKET"]
    ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/NotchHub/hub.sock").path

let input = FileHandle.standardInput.readDataToEndOfFile()
guard let event = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else { exit(0) }
let isPermissionRequest = (event["hook_event_name"] as? String) == "PermissionRequest"

// Raw newlines can only be JSON whitespace (inside strings they are escaped),
// so replacing them keeps the payload unchanged while making it a single line.
var line = Data(input.map { $0 == 0x0A || $0 == 0x0D ? 0x20 : $0 })
line.append(0x0A)

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { exit(0) }

var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
let pathBytes = Array(socketPath.utf8)
guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { exit(0) }
withUnsafeMutableBytes(of: &address.sun_path) { buffer in
    buffer.copyBytes(from: pathBytes)
}
// macOS refuses (rather than queues) connections while the backlog is full, which happens
// when many parallel tool calls fire hooks at once. Retry briefly; a socket file left by a
// crashed app refuses too, so keep the total wait short.
var connected = false
for attempt in 0..<6 {
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    if result == 0 { connected = true; break }
    guard errno == ECONNREFUSED || errno == EAGAIN || errno == EINTR, attempt < 5 else { break }
    usleep(20_000)
}
guard connected else { exit(0) }

let written = line.withUnsafeBytes { buffer -> Bool in
    var offset = 0
    while offset < buffer.count {
        let n = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
        if n < 0 && errno == EINTR { continue }
        if n <= 0 { return false }
        offset += n
    }
    return true
}
guard written, isPermissionRequest else { exit(0) }

var reply = Data()
var byte: UInt8 = 0
while true {
    let n = read(fd, &byte, 1)
    if n < 0 && errno == EINTR { continue }
    guard n == 1, byte != 0x0A else { break }
    reply.append(byte)
}
close(fd)

guard let answer = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else { exit(0) }

var decision: [String: Any]
switch answer["decision"] as? String {
case "allow":
    decision = ["behavior": "allow"]
    if let updates = answer["updatedPermissions"] as? [Any], !updates.isEmpty {
        decision["updatedPermissions"] = updates
    }
case "deny":
    decision = ["behavior": "deny", "message": "Kullanıcı çentikten reddetti"]
default:
    exit(0)
}

let output: [String: Any] = [
    "hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]
]
if var data = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]) {
    data.append(0x0A)
    // The throwing variant, so a closed stdout cannot raise an exception and change the exit code.
    try? FileHandle.standardOutput.write(contentsOf: data)
}
exit(0)
