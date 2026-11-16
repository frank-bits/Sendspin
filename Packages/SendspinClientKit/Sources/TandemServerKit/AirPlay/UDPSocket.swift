import Foundation

/// A UDP socket on a port of the system's choosing: packets from anyone are handed to
/// `onReceive` on `queue`, and packets go out to any address. On a machine with several
/// network addresses, `localAddress` is the one its packets come from: a speaker ignores
/// answers from another address than the one that connected to it.
final class UDPSocket: @unchecked Sendable {
    struct Failure: Error, CustomStringConvertible {
        var description: String
    }

    let port: UInt16
    private let descriptor: Int32
    private let source: any DispatchSourceRead

    /// `port` 0 leaves the choice to the system; a given port may be shared with a socket
    /// that was just closed.
    init(queue: DispatchQueue, localAddress: String? = nil, port: UInt16 = 0,
         onReceive: @escaping @Sendable (Data, sockaddr_in) -> Void) throws {
        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { throw Failure(description: "no UDP socket (\(errno))") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        if port != 0 {
            var yes: Int32 = 1
            setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        }
        if let localAddress, inet_pton(AF_INET, localAddress, &address.sin_addr) != 1 {
            Darwin.close(descriptor)
            throw Failure(description: "\(localAddress) isn't an address")
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                bind(descriptor, generic, length) == 0 && getsockname(descriptor, generic, &length) == 0
            }
        }
        guard bound, fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else {
            Darwin.close(descriptor)
            throw Failure(description: "the UDP socket can't be set up (\(errno))")
        }
        self.descriptor = descriptor
        self.port = UInt16(bigEndian: address.sin_port)
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 2_048)
            while true {
                var sender = sockaddr_in()
                var senderLength = socklen_t(MemoryLayout<sockaddr_in>.size)
                let count = withUnsafeMutablePointer(to: &sender) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                        recvfrom(descriptor, &buffer, buffer.count, 0, generic, &senderLength)
                    }
                }
                guard count > 0 else { return }
                onReceive(Data(buffer[0..<count]), sender)
            }
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
    }

    /// Send, or drop the packet when the system can't take it now: audio doesn't wait.
    @discardableResult
    func send(_ data: Data, to address: sockaddr_in) -> Int {
        var address = address
        return data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                    sendto(descriptor, bytes.baseAddress, bytes.count, 0, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    func close() {
        source.cancel()
    }

    /// The address of ours a packet to `host` leaves from, when the socket isn't tied to one.
    static func sourceAddress(toward host: String) -> String? {
        guard var remote = address(host, port: 9) else { return nil }
        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let found = withUnsafeMutablePointer(to: &remote) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, length) == 0 }
        } && withUnsafeMutablePointer(to: &local) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) == 0 }
        }
        guard found else { return nil }
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &local.sin_addr, &text, socklen_t(text.count)) != nil else { return nil }
        return String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// An IPv4 address in numbers, with a port.
    static func address(_ host: String, port: UInt16) -> sockaddr_in? {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return nil }
        return address
    }
}
