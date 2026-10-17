import Foundation

public enum HubError: Error, CustomStringConvertible {
    case connect(String)
    case closed
    case daemon(String)
    case badResponse

    public var description: String {
        switch self {
        case .connect(let why): return "cannot reach the Hub Daemon: \(why)"
        case .closed: return "the Hub Daemon closed the connection"
        case .daemon(let why): return why
        case .badResponse: return "the Hub Daemon sent something unreadable"
        }
    }
}

/// One blocking connection to the daemon's Unix socket. Use it off the main thread.
public final class HubSocket: @unchecked Sendable {
    private let fd: Int32
    private var buffer = Data()
    private let lock = NSLock()

    public init(path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HubError.connect("socket() failed") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else {
            close(fd)
            throw HubError.connect("socket path too long: \(path)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let why = String(cString: strerror(errno))
            close(fd)
            throw HubError.connect(why)
        }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit { close(fd) }

    public func write(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n <= 0 { throw HubError.closed }
                offset += n
            }
        }
    }

    public func writeLine(_ object: Any) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try write(data)
    }

    /// The next newline-terminated line, without the newline.
    public func readLine() throws -> Data {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                return Data(line)
            }
            guard let chunk = try readChunk() else { throw HubError.closed }
            buffer.append(chunk)
        }
    }

    /// Raw bytes: first whatever is buffered after the last line, then the socket. Nil at the end.
    public func readChunk() throws -> Data? {
        if !buffer.isEmpty {
            defer { buffer.removeAll() }
            return buffer
        }
        var bytes = [UInt8](repeating: 0, count: 16 * 1024)
        let n = Darwin.read(fd, &bytes, bytes.count)
        if n <= 0 { return nil }
        return Data(bytes[0..<n])
    }

    /// Ends the connection in both directions, waking a blocked reader.
    public func shutdown() {
        Darwin.shutdown(fd, SHUT_RDWR)
    }
}
