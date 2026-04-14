//
//  VPNProtocol.swift
//  Free VPN
//
//  Created by Paulo Zacchello on 4/12/26.
//

import Foundation

enum VPNProtocolType: String, Codable, Sendable {
    case wireGuard
    case openVPN

    var displayName: String {
        switch self {
        case .wireGuard: "WireGuard"
        case .openVPN: "OpenVPN"
        }
    }

    var shortName: String {
        switch self {
        case .wireGuard: "WG"
        case .openVPN: "OVPN"
        }
    }

    /// Detects the VPN protocol type from a config string.
    static func detect(from configString: String) -> VPNProtocolType {
        let lower = configString.lowercased()

        // WireGuard: has [Interface] + [Peer] with PrivateKey
        if lower.contains("[interface]") && lower.contains("[peer]") && lower.contains("privatekey") {
            return .wireGuard
        }

        // OpenVPN: has client directive, remote server, or inline certificates
        let hasClient = lower.components(separatedBy: .newlines).contains { $0.trimmingCharacters(in: .whitespaces) == "client" }
        if lower.contains("remote ") || lower.contains("<ca>") || hasClient {
            return .openVPN
        }

        // Default to WireGuard
        return .wireGuard
    }
}

// MARK: - OpenVPN Config Validation

enum OpenVPNConfig {

    /// Validates an OpenVPN config string. Returns error message or nil if valid.
    nonisolated static func validate(_ configString: String) -> String? {
        let trimmed = configString.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "The configuration is empty."
        }

        let lower = trimmed.lowercased()

        // Must have a remote directive
        if !lower.contains("remote ") {
            return "Missing 'remote' directive. An OpenVPN config must specify at least one remote server."
        }

        // Must have a CA certificate (inline or file reference)
        let hasInlineCA = lower.contains("<ca>")
        let hasCAFile = lower.components(separatedBy: .newlines).contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("ca ") }
        if !hasInlineCA && !hasCAFile {
            return "Missing CA certificate. An OpenVPN config must include a <ca> block or 'ca' file reference."
        }

        return nil
    }

    /// Extracts the remote server endpoint from an OpenVPN config.
    static func extractEndpoint(from configString: String) -> String? {
        for line in configString.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("remote ") {
                let parts = trimmed.split(separator: " ", maxSplits: 3)
                if parts.count >= 3 {
                    return "\(parts[1]):\(parts[2])"
                } else if parts.count >= 2 {
                    return String(parts[1])
                }
            }
        }
        return nil
    }

    /// Returns a display name derived from the remote server.
    static func displayName(from configString: String) -> String {
        if let endpoint = extractEndpoint(from: configString) {
            return endpoint.components(separatedBy: ":").first ?? endpoint
        }
        return "OpenVPN"
    }
}
