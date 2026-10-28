import Darwin
import Foundation

/// Receives datagrams on a fixed local UDP port and hands each one to `onPacket`
/// on a high-priority queue. Plain BSD sockets keep per-packet overhead low at ~40 Mbps.
final class UDPReceiver {
    private let source: DispatchSourceRead

    init(port: UInt16, receiveBufferBytes: Int32, label: String,
         onPacket: @escaping (UnsafeRawBufferPointer) -> Void) throws {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var size = receiveBufferBytes
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let err = errno
            close(fd)
            throw POSIXError(.init(rawValue: err) ?? .EADDRINUSE)
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let queue = DispatchQueue(label: label, qos: .userInteractive)
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 65536, alignment: 8)
        source.setEventHandler {
            // Drain everything that's queued so a burst never sits in the socket buffer.
            while true {
                let n = recv(fd, buffer.baseAddress, buffer.count, 0)
                if n <= 0 { break }
                onPacket(UnsafeRawBufferPointer(rebasing: buffer[0..<n]))
            }
        }
        source.setCancelHandler {
            close(fd)
            buffer.deallocate()
        }
        source.resume()
    }

    func stop() {
        source.cancel()
    }
}
