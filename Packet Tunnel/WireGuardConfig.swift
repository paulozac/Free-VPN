//
//  WireGuardConfig.swift
//  Free VPN
//
//  Created by Paulo Zacchello on 4/9/26.
//

import Foundation

struct WireGuardConfig {
    var interface: InterfaceConfig
    var peers: [PeerConfig]

    struct InterfaceConfig {
        var privateKey: String
        var address: [String]
        var dns: [String]
        var mtu: Int?
        var listenPort: Int?
    }

    struct PeerConfig {
        var publicKey: String
        var presharedKey: String?
        var endpoint: String?
        var allowedIPs: [String]
        var persistentKeepalive: Int?
    }
}

// MARK: - Parsing from .conf format

extension WireGuardConfig {

    /// Parses a standard WireGuard .conf file content into a WireGuardConfig.
    static func parse(from configString: String) throws -> WireGuardConfig {
        var interfaceConfig: InterfaceConfig?
        var peers: [PeerConfig] = []

        enum Section { case none, interface, peer }
        var currentSection: Section = .none

        // Temporary storage for current peer being parsed
        var currentPeerPublicKey: String?
        var currentPeerPresharedKey: String?
        var currentPeerEndpoint: String?
        var currentPeerAllowedIPs: [String] = []
        var currentPeerPersistentKeepalive: Int?

        // Interface fields
        var privateKey: String?
        var addresses: [String] = []
        var dnsServers: [String] = []
        var mtu: Int?
        var listenPort: Int?

        func finalizePeer() -> PeerConfig? {
            guard let publicKey = currentPeerPublicKey else { return nil }
            return PeerConfig(
                publicKey: publicKey,
                presharedKey: currentPeerPresharedKey,
                endpoint: currentPeerEndpoint,
                allowedIPs: currentPeerAllowedIPs,
                persistentKeepalive: currentPeerPersistentKeepalive
            )
        }

        for line in configString.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            if trimmed.lowercased() == "[interface]" {
                // Save any in-progress peer
                if let peer = finalizePeer() {
                    peers.append(peer)
                }
                currentSection = .interface
                currentPeerPublicKey = nil
                currentPeerPresharedKey = nil
                currentPeerEndpoint = nil
                currentPeerAllowedIPs = []
                currentPeerPersistentKeepalive = nil
                continue
            }

            if trimmed.lowercased() == "[peer]" {
                // Save any in-progress peer
                if let peer = finalizePeer() {
                    peers.append(peer)
                }
                currentSection = .peer
                currentPeerPublicKey = nil
                currentPeerPresharedKey = nil
                currentPeerEndpoint = nil
                currentPeerAllowedIPs = []
                currentPeerPersistentKeepalive = nil
                continue
            }

            guard let equalsIndex = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[trimmed.startIndex..<equalsIndex].trimmingCharacters(in: .whitespaces).lowercased()
            let value = trimmed[trimmed.index(after: equalsIndex)...].trimmingCharacters(in: .whitespaces)

            switch currentSection {
            case .interface:
                switch key {
                case "privatekey":
                    privateKey = value
                case "address":
                    addresses = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                case "dns":
                    dnsServers = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                case "mtu":
                    mtu = Int(value)
                case "listenport":
                    listenPort = Int(value)
                default:
                    break
                }
            case .peer:
                switch key {
                case "publickey":
                    currentPeerPublicKey = value
                case "presharedkey":
                    currentPeerPresharedKey = value
                case "endpoint":
                    currentPeerEndpoint = value
                case "allowedips":
                    currentPeerAllowedIPs = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                case "persistentkeepalive":
                    currentPeerPersistentKeepalive = Int(value)
                default:
                    break
                }
            case .none:
                break
            }
        }

        // Finalize last peer
        if let peer = finalizePeer() {
            peers.append(peer)
        }

        guard let key = privateKey else {
            throw ConfigError.missingPrivateKey
        }

        interfaceConfig = InterfaceConfig(
            privateKey: key,
            address: addresses,
            dns: dnsServers,
            mtu: mtu,
            listenPort: listenPort
        )

        guard let iface = interfaceConfig else {
            throw ConfigError.missingInterface
        }

        guard !peers.isEmpty else {
            throw ConfigError.missingPeer
        }

        return WireGuardConfig(interface: iface, peers: peers)
    }
}

// MARK: - Serialization to wg-quick format

extension WireGuardConfig {

    /// Serializes the config back to standard WireGuard .conf format.
    func toWgQuickConfig() -> String {
        var lines: [String] = []

        lines.append("[Interface]")
        lines.append("PrivateKey = \(interface.privateKey)")
        if !interface.address.isEmpty {
            lines.append("Address = \(interface.address.joined(separator: ", "))")
        }
        if !interface.dns.isEmpty {
            lines.append("DNS = \(interface.dns.joined(separator: ", "))")
        }
        if let mtu = interface.mtu {
            lines.append("MTU = \(mtu)")
        }
        if let port = interface.listenPort {
            lines.append("ListenPort = \(port)")
        }

        for peer in peers {
            lines.append("")
            lines.append("[Peer]")
            lines.append("PublicKey = \(peer.publicKey)")
            if let psk = peer.presharedKey {
                lines.append("PresharedKey = \(psk)")
            }
            if !peer.allowedIPs.isEmpty {
                lines.append("AllowedIPs = \(peer.allowedIPs.joined(separator: ", "))")
            }
            if let endpoint = peer.endpoint {
                lines.append("Endpoint = \(endpoint)")
            }
            if let keepalive = peer.persistentKeepalive {
                lines.append("PersistentKeepalive = \(keepalive)")
            }
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - Errors

extension WireGuardConfig {
    enum ConfigError: LocalizedError {
        case missingPrivateKey
        case missingInterface
        case missingPeer
        case invalidFormat
        case missingAddress
        case missingPublicKey
        case emptyConfig

        var errorDescription: String? {
            switch self {
            case .missingPrivateKey: return "Missing PrivateKey in [Interface] section"
            case .missingInterface: return "Missing [Interface] section"
            case .missingPeer: return "Missing [Peer] section"
            case .invalidFormat: return "Invalid configuration format"
            case .missingAddress: return "Missing Address in [Interface] section"
            case .missingPublicKey: return "A [Peer] section is missing a PublicKey"
            case .emptyConfig: return "The configuration is empty"
            }
        }

        var userFriendlyMessage: String {
            switch self {
            case .missingPrivateKey:
                return "Your profile is missing a PrivateKey in the [Interface] section. This is required to establish a WireGuard connection."
            case .missingInterface:
                return "This doesn't look like a valid WireGuard profile. It must contain an [Interface] section."
            case .missingPeer:
                return "Your profile is missing a [Peer] section. At least one peer (server) is required."
            case .invalidFormat:
                return "This file doesn't appear to be a valid WireGuard configuration. Please check the format and try again."
            case .missingAddress:
                return "Your profile is missing an Address in the [Interface] section. This is the VPN IP address assigned to your device."
            case .missingPublicKey:
                return "One of the [Peer] sections is missing a PublicKey. Each peer must have a PublicKey."
            case .emptyConfig:
                return "The uploaded file appears to be empty. Please select a valid WireGuard .conf file."
            }
        }
    }

    /// Validates a config string and returns a user-friendly error message, or nil if valid.
    static func validate(_ configString: String) -> String? {
        let trimmed = configString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return ConfigError.emptyConfig.userFriendlyMessage
        }

        do {
            let config = try parse(from: trimmed)

            // Additional validation beyond basic parsing
            if config.interface.address.isEmpty {
                return ConfigError.missingAddress.userFriendlyMessage
            }

            for (i, peer) in config.peers.enumerated() {
                if peer.publicKey.trimmingCharacters(in: .whitespaces).isEmpty {
                    return "Peer #\(i + 1) is missing a PublicKey."
                }
            }

            return nil // Valid
        } catch let error as ConfigError {
            return error.userFriendlyMessage
        } catch {
            return "Invalid WireGuard configuration: \(error.localizedDescription)"
        }
    }

    /// Returns a short display name derived from the config (endpoint or address).
    func displayName() -> String {
        if let endpoint = peers.first?.endpoint {
            return endpoint.components(separatedBy: ":").first ?? endpoint
        }
        return interface.address.first ?? "Unknown"
    }
}
