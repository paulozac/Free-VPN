//
//  LocalNetworkExclusion.swift
//
//  Keeps local network and smart home traffic (Matter, Thread, HomeKit, AirPlay,
//  mDNS) outside the tunnel. An Apple TV acting as a Matter/Thread home hub talks
//  to accessories over private IPv6 addresses; a full-tunnel `::/0` route would
//  send that traffic to the VPN server instead, and the accessories go offline.
//
//  Each tunnel extension keeps its own copy of this file so the extensions stay
//  fully independent of one another.
//

import Foundation
import Network
import NetworkExtension

enum LocalNetworkExclusion {

    /// Shared app-group key; the app owns the setting. A missing value means on.
    static let settingKey = "excludeLocalNetworks"

    static var isEnabled: Bool {
        UserDefaults(suiteName: "group.com.zacvpn.zacvpn")?.object(forKey: settingKey) as? Bool ?? true
    }

    /// Private, link-local and multicast IPv4 ranges.
    private static let ipv4Ranges: [(address: String, length: Int)] = [
        ("10.0.0.0", 8),
        ("172.16.0.0", 12),
        ("192.168.0.0", 16),
        ("169.254.0.0", 16),
        ("224.0.0.0", 4),
    ]

    /// Unique-local (fc00::/7), link-local and multicast IPv6 ranges.
    private static let ipv6Ranges: [(address: String, length: Int)] = [
        ("fc00::", 7),
        ("fe80::", 10),
        ("ff00::", 8),
    ]

    /// When a local range overlaps something the VPN uses, it is split no finer
    /// than this, so the route count stays small. Home LANs are /24 and Thread or
    /// Matter networks use a /48 unique-local prefix.
    private static let finestIPv4Split = 24
    private static let finestIPv6Split = 48

    /// Adds the local ranges to `settings` as excluded routes and returns lines for
    /// the tunnel log. Parts of a range the tunnel itself depends on — a tunnel
    /// address, a DNS server, or a route the profile deliberately sends through the
    /// VPN (such as a remote office LAN) — stay in the tunnel, so turning this on
    /// can never break DNS or site-to-site profiles.
    static func apply(to settings: NEPacketTunnelNetworkSettings) -> [String] {
        var log: [String] = []
        let dnsServers = (settings.dnsSettings?.servers ?? []).compactMap(Prefix.host)

        if let ipv4 = settings.ipv4Settings {
            var tunnelPrefixes = dnsServers.filter(\.isIPv4)
            tunnelPrefixes += ipv4.addresses.compactMap(Prefix.host)
            tunnelPrefixes += (ipv4.includedRoutes ?? []).compactMap { route in
                Prefix(route.destinationAddress, length: prefixLength(ofMask: route.destinationSubnetMask))
            }

            let excluded = carveRanges(ipv4Ranges, around: tunnelPrefixes, finest: finestIPv4Split, log: &log)
            ipv4.excludedRoutes = (ipv4.excludedRoutes ?? []) + excluded.map {
                NEIPv4Route(destinationAddress: $0.address, subnetMask: subnetMask(ofLength: $0.length))
            }
        }

        // Without IPv6 settings, IPv6 never enters the tunnel, so there is nothing to exclude.
        if let ipv6 = settings.ipv6Settings {
            var tunnelPrefixes = dnsServers.filter { !$0.isIPv4 }
            tunnelPrefixes += ipv6.addresses.compactMap(Prefix.host)
            tunnelPrefixes += (ipv6.includedRoutes ?? []).compactMap { route in
                Prefix(route.destinationAddress, length: route.destinationNetworkPrefixLength.intValue)
            }

            let excluded = carveRanges(ipv6Ranges, around: tunnelPrefixes, finest: finestIPv6Split, log: &log)
            ipv6.excludedRoutes = (ipv6.excludedRoutes ?? []) + excluded.map {
                NEIPv6Route(destinationAddress: $0.address, networkPrefixLength: NSNumber(value: $0.length))
            }
        }

        return log
    }

    /// Returns the parts of `ranges` that can safely bypass the tunnel.
    private static func carveRanges(_ ranges: [(address: String, length: Int)], around tunnelPrefixes: [Prefix],
                                    finest: Int, log: inout [String]) -> [Prefix] {
        // The default route overlaps everything and is what these exclusions refine.
        let tunnelPrefixes = tunnelPrefixes.filter { $0.length > 0 }
        var result: [Prefix] = []
        for range in ranges {
            guard let prefix = Prefix(range.address, length: range.length) else { continue }
            let pieces = carve(prefix, around: tunnelPrefixes, finest: finest)
            let label = "\(range.address)/\(range.length)"
            if pieces.count == 1 && pieces[0].length == prefix.length {
                log.append("Local network: \(label) excluded")
            } else if pieces.isEmpty {
                log.append("Local network: \(label) kept in tunnel (used by the VPN)")
            } else {
                log.append("Local network: \(label) excluded except parts used by the VPN (\(pieces.count) routes)")
            }
            result += pieces
        }
        return result
    }

    /// Splits `range` into the largest sub-prefixes that don't overlap any tunnel
    /// prefix. Pieces finer than `finest` that still overlap stay in the tunnel.
    private static func carve(_ range: Prefix, around tunnelPrefixes: [Prefix], finest: Int) -> [Prefix] {
        let conflicts = tunnelPrefixes.filter(range.overlaps)
        if conflicts.isEmpty { return [range] }
        // Fully covered by a tunnel route, or as fine as we're willing to split.
        if range.length >= finest || conflicts.contains(where: { $0.length <= range.length }) { return [] }
        return range.halves.flatMap { carve($0, around: conflicts, finest: finest) }
    }

    // MARK: - Address arithmetic

    /// An IPv4 or IPv6 network prefix in raw bytes.
    private struct Prefix {
        let bytes: [UInt8]
        let length: Int

        init?(_ address: String, length: Int) {
            if let v4 = IPv4Address(address) {
                self.init(bytes: [UInt8](v4.rawValue), length: length)
            } else if let v6 = IPv6Address(address) {
                self.init(bytes: [UInt8](v6.rawValue), length: length)
            } else {
                return nil
            }
        }

        private init(bytes: [UInt8], length: Int) {
            self.bytes = bytes
            self.length = min(max(length, 0), bytes.count * 8)
        }

        /// A single address (/32 or /128).
        static func host(_ address: String) -> Prefix? {
            Prefix(address, length: 128)
        }

        var isIPv4: Bool { bytes.count == 4 }

        var address: String {
            isIPv4
                ? bytes.map(String.init).joined(separator: ".")
                : IPv6Address(Data(bytes)).map { "\($0)" } ?? "::"
        }

        /// The two prefixes one bit longer that together make up this one.
        var halves: [Prefix] {
            var upper = bytes
            upper[length / 8] |= UInt8(0x80) >> UInt8(length % 8)
            return [Prefix(bytes: bytes, length: length + 1), Prefix(bytes: upper, length: length + 1)]
        }

        /// Two prefixes overlap when they agree on every bit of the shorter one.
        func overlaps(_ other: Prefix) -> Bool {
            guard bytes.count == other.bytes.count else { return false }
            for bit in 0..<min(length, other.length) {
                let mask = UInt8(0x80) >> UInt8(bit % 8)
                if bytes[bit / 8] & mask != other.bytes[bit / 8] & mask { return false }
            }
            return true
        }
    }

    private static func prefixLength(ofMask mask: String) -> Int {
        guard let address = IPv4Address(mask) else { return 32 }
        return address.rawValue.reduce(0) { $0 + $1.nonzeroBitCount }
    }

    private static func subnetMask(ofLength length: Int) -> String {
        let bits: UInt32 = length == 0 ? 0 : ~UInt32(0) << UInt32(32 - length)
        return [24, 16, 8, 0].map { String((bits >> UInt32($0)) & 0xFF) }.joined(separator: ".")
    }
}
