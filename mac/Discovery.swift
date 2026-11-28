import Foundation
import Darwin

struct NearbyPC {
    let id: String
    let name: String
    let host: String
    let fingerprint: String
}

final class Discovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private let browser = NetServiceBrowser()
    private var services: [String: NetService] = [:]
    private var peers: [String: NearbyPC] = [:]
    var didChange: (([NearbyPC]) -> Void)?

    var computers: [NearbyPC] {
        peers.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func start() {
        browser.delegate = self
        browser.searchForServices(ofType: "_prilo._tcp.", inDomain: "local.")
    }

    func restart() {
        browser.stop()
        for service in services.values {
            service.stop()
        }
        services.removeAll()
        if !peers.isEmpty {
            peers.removeAll()
            didChange?(computers)
        }
        browser.delegate = self
        browser.searchForServices(ofType: "_prilo._tcp.", inDomain: "local.")
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services[service.name] = service
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        services.removeValue(forKey: service.name)?.stop()
        if peers.removeValue(forKey: service.name) != nil { didChange?(computers) }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        Diagnostics.shared.record("Bonjour unavailable code=\(errorDict[NetService.errorCode]?.intValue ?? -1)")
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard services[sender.name] === sender, sender.port == 43821, let data = sender.txtRecordData() else { return }
        let fields = NetService.dictionary(fromTXTRecord: data)
        guard let raw = fields["fingerprint"], let fingerprint = String(data: raw, encoding: .utf8),
              fingerprint.count == 64, fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return }

        let addresses: [in_addr] = sender.addresses?.compactMap { data in
            guard data.count >= MemoryLayout<sockaddr_in>.size else { return nil }
            let address = data.withUnsafeBytes { $0.loadUnaligned(as: sockaddr_in.self) }
            return address.sin_family == AF_INET ? address.sin_addr : nil
        } ?? []
        guard let address = addresses.first(where: { Self.onLocalSubnet($0) }) ?? addresses.first else { return }
        var hostBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var hostAddress = address
        guard inet_ntop(AF_INET, &hostAddress, &hostBuffer, socklen_t(hostBuffer.count)) != nil else { return }
        let name = fields["name"].flatMap { String(data: $0, encoding: .utf8) } ?? sender.name
        peers[sender.name] = NearbyPC(id: sender.name, name: name, host: String(cString: hostBuffer), fingerprint: fingerprint)
        didChange?(computers)
    }

    private static func onLocalSubnet(_ remote: in_addr) -> Bool {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return false }
        defer { freeifaddrs(first) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = entry.pointee
            guard let address = interface.ifa_addr, let netmask = interface.ifa_netmask,
                  address.pointee.sa_family == AF_INET,
                  interface.ifa_flags & UInt32(IFF_UP) != 0,
                  interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let local = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr
            let mask = UnsafeRawPointer(netmask).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr
            if (local & mask) == (remote.s_addr & mask) { return true }
        }
        return false
    }
}

