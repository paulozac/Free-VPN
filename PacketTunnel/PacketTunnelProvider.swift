//
//  PacketTunnelProvider.swift
//  PacketTunnel
//
//  Created by Paulo Zacchello on 4/9/26.
//

import NetworkExtension
import os.log

class PacketTunnelProvider: NEPacketTunnelProvider {

    private let log = Logger(subsystem: "com.zacvpn.zacvpn.PacketTunnel", category: "tunnel")

    override func startTunnel(options: [String: NSObject]? = nil) async throws {
        log.info("Starting WireGuard tunnel...")

        guard let protocolConfig = protocolConfiguration as? NETunnelProviderProtocol,
              let providerConfig = protocolConfig.providerConfiguration,
              let wgQuickConfig = providerConfig["wgQuickConfig"] as? String else {
            log.error("Missing WireGuard configuration")
            throw TunnelError.missingConfiguration
        }

        let config: WireGuardConfig
        do {
            config = try WireGuardConfig.parse(from: wgQuickConfig)
        } catch {
            log.error("Failed to parse WireGuard config: \(error.localizedDescription)")
            throw TunnelError.invalidConfiguration
        }

        // Configure tunnel network settings based on the WireGuard config
        let networkSettings = buildNetworkSettings(from: config)

        try await setTunnelNetworkSettings(networkSettings)

        log.info("Tunnel network settings applied successfully")

        // TODO: Integrate wireguard-go or WireGuardKit here to establish
        // the actual WireGuard tunnel. The config is parsed and ready.
        // For now, the tunnel is "established" with routing configured
        // but without the cryptographic WireGuard protocol layer.
        //
        // To complete the implementation:
        // 1. Add WireGuardKit as a dependency (SPM or framework)
        // 2. Use WireGuardAdapter to start the tunnel with the parsed config
        // 3. Handle adapter callbacks for status updates

        log.info("WireGuard tunnel started")
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        log.info("Stopping WireGuard tunnel, reason: \(String(describing: reason))")

        // TODO: Stop the WireGuardAdapter here when integrated
    }

    override func handleAppMessage(_ messageData: Data) async -> Data? {
        // Handle messages from the container app if needed
        return nil
    }

    // MARK: - Network Settings

    private func buildNetworkSettings(from config: WireGuardConfig) -> NEPacketTunnelNetworkSettings {
        let endpoint = config.peers.first?.endpoint ?? "0.0.0.0"
        let serverAddress = endpoint.components(separatedBy: ":").first ?? endpoint

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: serverAddress)

        // DNS
        if !config.interface.dns.isEmpty {
            settings.dnsSettings = NEDNSSettings(servers: config.interface.dns)
        }

        // MTU
        if let mtu = config.interface.mtu {
            settings.mtu = NSNumber(value: mtu)
        }

        // IPv4 and IPv6 settings from interface addresses
        var ipv4Addresses: [String] = []
        var ipv4Masks: [String] = []
        var ipv6Addresses: [String] = []
        var ipv6PrefixLengths: [NSNumber] = []

        for address in config.interface.address {
            let parts = address.split(separator: "/")
            let ip = String(parts[0])
            let prefixLength = parts.count > 1 ? Int(parts[1]) ?? 32 : 32

            if ip.contains(":") {
                // IPv6
                ipv6Addresses.append(ip)
                ipv6PrefixLengths.append(NSNumber(value: prefixLength))
            } else {
                // IPv4
                ipv4Addresses.append(ip)
                ipv4Masks.append(subnetMask(from: prefixLength))
            }
        }

        // IPv4 routing
        if !ipv4Addresses.isEmpty {
            let ipv4Settings = NEIPv4Settings(addresses: ipv4Addresses, subnetMasks: ipv4Masks)

            var includedRoutes: [NEIPv4Route] = []
            for peer in config.peers {
                for allowedIP in peer.allowedIPs {
                    let parts = allowedIP.split(separator: "/")
                    let ip = String(parts[0])
                    if ip.contains(":") { continue }
                    let prefix = parts.count > 1 ? Int(parts[1]) ?? 32 : 32
                    includedRoutes.append(NEIPv4Route(destinationAddress: ip, subnetMask: subnetMask(from: prefix)))
                }
            }
            ipv4Settings.includedRoutes = includedRoutes
            settings.ipv4Settings = ipv4Settings
        }

        // IPv6 routing
        if !ipv6Addresses.isEmpty {
            let ipv6Settings = NEIPv6Settings(addresses: ipv6Addresses, networkPrefixLengths: ipv6PrefixLengths)

            var includedRoutes: [NEIPv6Route] = []
            for peer in config.peers {
                for allowedIP in peer.allowedIPs {
                    let parts = allowedIP.split(separator: "/")
                    let ip = String(parts[0])
                    if !ip.contains(":") { continue }
                    let prefix = parts.count > 1 ? Int(parts[1]) ?? 128 : 128
                    includedRoutes.append(NEIPv6Route(destinationAddress: ip, networkPrefixLength: NSNumber(value: prefix)))
                }
            }
            ipv6Settings.includedRoutes = includedRoutes
            settings.ipv6Settings = ipv6Settings
        }

        return settings
    }

    /// Converts a CIDR prefix length to a dotted-decimal subnet mask.
    private func subnetMask(from prefixLength: Int) -> String {
        let clamped = max(0, min(32, prefixLength))
        let mask: UInt32 = clamped == 0 ? 0 : ~UInt32(0) << (32 - clamped)
        return "\(mask >> 24 & 0xFF).\(mask >> 16 & 0xFF).\(mask >> 8 & 0xFF).\(mask & 0xFF)"
    }
}

// MARK: - Errors

enum TunnelError: Error {
    case missingConfiguration
    case invalidConfiguration
}
