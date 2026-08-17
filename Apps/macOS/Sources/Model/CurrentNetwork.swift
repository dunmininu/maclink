import Darwin
import Foundation

/// Which LAN this Mac is currently on.
///
/// Deliberately *not* CoreWLAN: reading the Wi-Fi SSID needs Location Services permission on modern
/// macOS, and a second permission prompt is a poor trade for a cosmetic label. The interface address
/// tells the user the same thing — which network they are on — and is also what they would check
/// first if the phone could not find the Mac.
enum CurrentNetwork {

    struct Interface {
        var name: String
        var address: String
        var isWiFi: Bool
    }

    static func primaryInterface() -> Interface? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var candidates: [Interface] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(pointer.pointee.ifa_flags)
            guard flags & IFF_UP == IFF_UP, flags & IFF_LOOPBACK == 0 else { continue }
            guard let addr = pointer.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            let name = String(cString: pointer.pointee.ifa_name)
            // en0/en1 are the built-in Wi-Fi and Ethernet ports; utun*, bridge*, awdl* and friends
            // are VPNs and peer-to-peer links, which are not "the same network" in the sense we mean.
            guard name.hasPrefix("en") else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                addr, socklen_t(addr.pointee.sa_len),
                &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST
            )
            guard result == 0 else { continue }

            candidates.append(Interface(
                name: name,
                address: String(cString: host),
                isWiFi: name == "en0"
            ))
        }

        return candidates.first { $0.isWiFi } ?? candidates.first
    }

    static func name() -> String? {
        guard let interface = primaryInterface() else { return nil }
        return interface.address
    }
}
