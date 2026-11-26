import CoreGraphics
import CryptoKit
import Darwin
import Foundation

// Wire format and value types shared with the Windows receiver.
// Kept free of AppKit so tests/mac can compile it without launching the app.

struct Input: Encodable {
    let kind: String
    var x: Int32 = 0
    var y: Int32 = 0
    var code: UInt16 = 0
    var down = false
}

let scanCodes: [Int64: UInt16] = [
    0:0x1e, 1:0x1f, 2:0x20, 3:0x21, 4:0x23, 5:0x22, 6:0x2c, 7:0x2d,
    8:0x2e, 9:0x2f, 10:0x56, 11:0x30, 12:0x10, 13:0x11, 14:0x12, 15:0x13,
    16:0x15, 17:0x14, 18:0x02, 19:0x03, 20:0x04, 21:0x05, 22:0x07, 23:0x06,
    24:0x0d, 25:0x0a, 26:0x08, 27:0x0c, 28:0x09, 29:0x0b, 30:0x1b, 31:0x18,
    32:0x16, 33:0x1a, 34:0x17, 35:0x19, 36:0x1c, 37:0x26, 38:0x24, 39:0x28,
    40:0x25, 41:0x27, 42:0x2b, 43:0x33, 44:0x35, 45:0x31, 46:0x32, 47:0x34,
    48:0x0f, 49:0x39, 50:0x29, 51:0x0e, 53:0x01, 54:0x15c, 55:0x15b,
    56:0x2a, 57:0x3a, 58:0x38, 59:0x1d, 60:0x36, 61:0x138, 62:0x11d,
    65:0x53, 67:0x37, 69:0x4e, 75:0x135, 76:0x11c, 78:0x4a, 82:0x52,
    83:0x4f, 84:0x50, 85:0x51, 86:0x4b, 87:0x4c, 88:0x4d, 89:0x47, 91:0x48, 92:0x49,
    96:0x3f, 97:0x40, 98:0x41, 99:0x3d, 100:0x42, 101:0x43, 103:0x57,
    109:0x44, 111:0x58, 115:0x147, 116:0x149, 117:0x153, 118:0x3e, 119:0x14f,
    120:0x3c, 121:0x151, 122:0x3b, 123:0x14b, 124:0x14d, 125:0x150, 126:0x148,
]

let modifierMasks: [Int64: UInt64] = [
    54:0x10, 55:0x08, 56:0x02, 57:CGEventFlags.maskAlphaShift.rawValue,
    58:0x20, 59:0x01, 60:0x04, 61:0x40, 62:0x2000,
]

struct PairingCode {
    let prefix: String
    let pin: String

    init?(_ text: String) {
        let value = text.lowercased().filter { !$0.isWhitespace && $0 != "-" }
        guard value.utf8.count == 22 else { return nil }
        let prefix = value.prefix(16)
        let pin = value.suffix(6)
        guard prefix.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              pin.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        self.prefix = String(prefix)
        self.pin = String(pin)
    }
}

struct WakeTarget {
    let address: [UInt8]
    let broadcast: String

    init?(mac: String, broadcast: String) {
        let trimmed = mac.trimmingCharacters(in: .whitespacesAndNewlines)
        let plain = trimmed.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "")
        let digits = Array(plain.utf8)
        guard digits.count == 12, digits.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return nil }
        let address = stride(from: 0, to: 12, by: 2).compactMap { UInt8(String(decoding: digits[$0..<$0 + 2], as: UTF8.self), radix: 16) }
        guard address.count == 6, address[0] & 1 == 0, address.contains(where: { $0 != 0 }) else { return nil }
        let destination = broadcast.trimmingCharacters(in: .whitespacesAndNewlines)
        var inAddress = in_addr()
        guard inet_pton(AF_INET, destination, &inAddress) == 1, inAddress.s_addr != 0 else { return nil }
        self.address = address
        self.broadcast = destination
    }

    var mac: String { address.map { String(format: "%02x", $0) }.joined(separator: ":") }

    var packet: Data {
        var bytes = Data(repeating: 0xff, count: 6)
        for _ in 0..<16 { bytes.append(contentsOf: address) }
        return bytes
    }

    func send() throws {
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        var allowBroadcast: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_BROADCAST, &allowBroadcast,
                         socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = UInt16(9).bigEndian
        inet_pton(AF_INET, broadcast, &destination.sin_addr)
        let message = packet
        let result = withUnsafePointer(to: &destination) { socketAddress in
            socketAddress.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                message.withUnsafeBytes { sendto(descriptor, $0.baseAddress, message.count, 0, pointer,
                                                 socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        guard result == message.count else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

/// Horizontal entry point on the Windows screen, 0...65535 across the Mac display width.
/// The receiver rejects values outside that range, which would end the stream.
func entryPosition(x: CGFloat, in bounds: CGRect) -> Int32 {
    guard bounds.width > 0, x.isFinite else { return 32768 }
    let fraction = min(1, max(0, (x - bounds.minX) / bounds.width))
    return Int32((fraction * 65535).rounded(.towardZero))
}

/// Scoped token for /power/* endpoints. Must match powerToken() in windows/power.go.
func powerCode(accessCode: String) -> String {
    let signature = HMAC<SHA256>.authenticationCode(for: Data("prilo-power-v1".utf8),
                                                     using: SymmetricKey(data: Data(accessCode.utf8)))
    return signature.map { String(format: "%02x", $0) }.joined()
}

let maxClipboardBytes = 512 * 1024
let maxClipboardImageBytes = 6 * 1024 * 1024

func normalizeClipboardText(_ text: String) -> String {
    text.replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
}

// MARK: - Updates

/// A dotted release version such as "0.9.1" or "v0.9.1"; missing parts count as zero.
struct ReleaseVersion: Comparable, CustomStringConvertible {
    let parts: [Int]

    init?(_ text: String) {
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") { trimmed.removeFirst() }
        let pieces = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard !pieces.isEmpty, pieces.count <= 4 else { return nil }
        var parsed: [Int] = []
        for piece in pieces {
            guard !piece.isEmpty, piece.allSatisfy(\.isASCII), let value = Int(piece), value >= 0 else { return nil }
            parsed.append(value)
        }
        while parsed.count > 1, parsed.last == 0 { parsed.removeLast() }
        parts = parsed
    }

    var description: String { parts.map(String.init).joined(separator: ".") }

    static func < (a: ReleaseVersion, b: ReleaseVersion) -> Bool {
        for index in 0..<max(a.parts.count, b.parts.count) {
            let left = index < a.parts.count ? a.parts[index] : 0
            let right = index < b.parts.count ? b.parts[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    static func == (a: ReleaseVersion, b: ReleaseVersion) -> Bool { !(a < b) && !(b < a) }
}

/// The parts of a GitHub "latest release" response that the updater uses.
struct ReleaseInfo: Equatable {
    let version: ReleaseVersion
    let notes: String
    let page: URL
    let download: URL

    static let macAsset = "Prilo-Mac.zip"

    /// Parses the GitHub API JSON; drafts, pre-releases and releases without the Mac archive are ignored.
    static func parse(_ data: Data) -> ReleaseInfo? {
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        struct Release: Decodable {
            let tag_name: String
            let body: String?
            let html_url: URL
            let draft: Bool?
            let prerelease: Bool?
            let assets: [Asset]
        }
        guard let release = try? JSONDecoder().decode(Release.self, from: data),
              release.draft != true, release.prerelease != true,
              let version = ReleaseVersion(release.tag_name),
              let asset = release.assets.first(where: { $0.name == macAsset }),
              asset.browser_download_url.scheme == "https",
              release.html_url.scheme == "https" else { return nil }
        return ReleaseInfo(version: version, notes: release.body ?? "", page: release.html_url,
                           download: asset.browser_download_url)
    }
}
