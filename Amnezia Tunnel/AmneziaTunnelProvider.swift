//
//  AmneziaTunnelProvider.swift
//  Amnezia Tunnel
//
//  AmneziaWG runs in its own extension process, linking its own copy of the
//  AmneziaWG Go library. Two Go c-archives cannot coexist in one binary (the
//  cgo bridge symbols collide), and keeping them apart means an AmneziaWG
//  regression can never affect the WireGuard or OpenVPN tunnel.
//

import NetworkExtension
import os.log
import AmneziaWGKit

class AmneziaTunnelProvider: NEPacketTunnelProvider {

    private let log = Logger(subsystem: "com.zacvpn.zacvpn.AmneziaTunnel", category: "tunnel")

    private lazy var adapter: AmneziaWGKit.WireGuardAdapter = {
        return AmneziaWGKit.WireGuardAdapter(with: self) { [weak self] logLevel, message in
            self?.log.log(level: logLevel == .error ? .error : .debug, "AWG: \(message, privacy: .public)")
            self?.appendTunnelLog("AWG: \(message)")
        }
    }()

    private var tunnelLog: [String] = []
    private static let sharedDefaults = UserDefaults(suiteName: "group.com.zacvpn.zacvpn")
    private let logQueue = DispatchQueue(label: "com.zacvpn.amneziaTunnelLog")
    private let tunnelLogDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// Writes to the same shared key the app polls, so the connection log works
    /// identically whichever tunnel process is active.
    private func appendTunnelLog(_ message: String) {
        logQueue.async { [weak self] in
            guard let self else { return }
            let ts = self.tunnelLogDateFormatter.string(from: Date())
            self.tunnelLog.append("[\(ts)] \(message)")
            if self.tunnelLog.count > 500 {
                self.tunnelLog.removeFirst(self.tunnelLog.count - 500)
            }
            Self.sharedDefaults?.set(self.tunnelLog, forKey: "tunnelLog")
        }
    }

    override func startTunnel(options: [String: NSObject]? = nil) async throws {
        logQueue.sync { tunnelLog.removeAll() }
        appendTunnelLog("AmneziaWG tunnel extension starting")

        guard let protocolConfig = protocolConfiguration as? NETunnelProviderProtocol,
              let providerConfig = protocolConfig.providerConfiguration else {
            log.error("Missing provider configuration")
            appendTunnelLog("ERROR: Missing provider configuration")
            throw NEVPNError(.configurationInvalid)
        }

        guard let wgQuickConfig = providerConfig["wgQuickConfig"] as? String else {
            log.error("Missing AmneziaWG configuration")
            appendTunnelLog("ERROR: Missing AmneziaWG configuration")
            throw NEVPNError(.configurationInvalid)
        }

        log.info("AmneziaWG config received (\(wgQuickConfig.count) chars)")
        appendTunnelLog("AmneziaWG config received (\(wgQuickConfig.count) chars)")

        // Log the raw config lines (secrets redacted) for debugging
        for line in wgQuickConfig.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased()
            if lower.hasPrefix("privatekey") {
                appendTunnelLog("AWG raw: PrivateKey = [REDACTED]")
            } else if lower.hasPrefix("headerprotectionkey") {
                appendTunnelLog("AWG raw: HeaderProtectionKey = [REDACTED]")
            } else if !trimmed.isEmpty {
                appendTunnelLog("AWG raw: \(trimmed)")
            }
        }

        let tunnelConfig: AmneziaWGKit.TunnelConfiguration
        do {
            tunnelConfig = try AmneziaWGKit.TunnelConfiguration(fromWgQuickConfig: wgQuickConfig, called: "ZacVPN-AWG")
        } catch {
            log.error("Failed to parse AmneziaWG config: \(error.localizedDescription)")
            appendTunnelLog("ERROR: Failed to parse AmneziaWG config: \(error)")
            throw NEVPNError(.configurationInvalid)
        }

        logInterface(tunnelConfig)

        appendTunnelLog("AWG starting adapter...")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            adapter.start(tunnelConfiguration: tunnelConfig) { [weak self] error in
                if let error = error {
                    self?.appendTunnelLog("AWG ERROR: adapter start failed: \(error)")
                    self?.log.error("AWG adapter start failed: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                } else {
                    self?.appendTunnelLog("AWG adapter started OK")
                    continuation.resume()
                }
            }
        }

        appendTunnelLog("AmneziaWG tunnel started successfully")
        log.info("AmneziaWG tunnel started successfully")
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        appendTunnelLog("Stopping AmneziaWG tunnel, reason: \(reason)")
        log.info("Stopping AmneziaWG tunnel, reason: \(String(describing: reason))")

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            adapter.stop { _ in
                continuation.resume()
            }
        }
    }

    override func handleAppMessage(_ messageData: Data) async -> Data? {
        return logQueue.sync { try? JSONEncoder().encode(tunnelLog) }
    }

    // MARK: - Diagnostics

    private func logInterface(_ tunnelConfig: AmneziaWGKit.TunnelConfiguration) {
        let iface = tunnelConfig.interface
        appendTunnelLog("AWG interface: addresses=\(iface.addresses.map { $0.stringRepresentation })")
        appendTunnelLog("AWG interface: dns=\(iface.dns.map { $0.stringRepresentation })")
        appendTunnelLog("AWG interface: mtu=\(iface.mtu.map { String($0) } ?? "auto")")

        let hasAnyAWGParam = iface.junkPacketCount != nil || iface.initPacketMagicHeader != nil
        appendTunnelLog("AWG obfuscation params present: \(hasAnyAWGParam)")
        if let jc = iface.junkPacketCount { appendTunnelLog("AWG Jc=\(jc)") }
        if let jmin = iface.junkPacketMinSize { appendTunnelLog("AWG Jmin=\(jmin)") }
        if let jmax = iface.junkPacketMaxSize { appendTunnelLog("AWG Jmax=\(jmax)") }
        if let s1 = iface.initPacketJunkSize { appendTunnelLog("AWG S1=\(s1)") }
        if let s2 = iface.responsePacketJunkSize { appendTunnelLog("AWG S2=\(s2)") }
        if let s3 = iface.cookiePacketJunkSize { appendTunnelLog("AWG S3=\(s3)") }
        if let s4 = iface.transportPacketJunkSize { appendTunnelLog("AWG S4=\(s4)") }
        if let h1 = iface.initPacketMagicHeader { appendTunnelLog("AWG H1=\(h1)") }
        if let h2 = iface.responsePacketMagicHeader { appendTunnelLog("AWG H2=\(h2)") }
        if let h3 = iface.underloadPacketMagicHeader { appendTunnelLog("AWG H3=\(h3)") }
        if let h4 = iface.transportPacketMagicHeader { appendTunnelLog("AWG H4=\(h4)") }
        if let i1 = iface.initPacketData1 { appendTunnelLog("AWG I1=\(i1)") }
        if let i2 = iface.initPacketData2 { appendTunnelLog("AWG I2=\(i2)") }
        if let i3 = iface.initPacketData3 { appendTunnelLog("AWG I3=\(i3)") }
        if let i4 = iface.initPacketData4 { appendTunnelLog("AWG I4=\(i4)") }
        if let i5 = iface.initPacketData5 { appendTunnelLog("AWG I5=\(i5)") }

        // AWG 3.1 parameters. The bundled amneziawg-go must understand these or it
        // rejects the whole UAPI config, so log them explicitly to make a version
        // mismatch obvious in the diagnostics.
        var awg31Params: [String] = []
        if iface.headerProtectionKey != nil { awg31Params.append("HeaderProtectionKey") }
        if let val = iface.contentPaddingAddition { awg31Params.append("ContentPaddingAddition=\(val)") }
        if let val = iface.rekeyAfterTime { awg31Params.append("RekeyAfterTime=\(val)") }
        if let val = iface.rekeyTimeout { awg31Params.append("RekeyTimeout=\(val)") }
        if let val = iface.rejectAfterTime { awg31Params.append("RejectAfterTime=\(val)") }
        if let val = iface.keepaliveTimeout { awg31Params.append("KeepaliveTimeout=\(val)") }
        if let val = iface.maxHandshakeAttempts { awg31Params.append("MaxHandshakeAttempts=\(val)") }
        if let val = iface.randomTrailers { awg31Params.append("RandomTrailers=\(val)") }
        if let val = iface.disableCookies { awg31Params.append("DisableCookies=\(val)") }
        if !awg31Params.isEmpty {
            appendTunnelLog("AWG 3.1 params: \(awg31Params.joined(separator: ", "))")
            log.info("AWG 3.1 params present: \(awg31Params.count, privacy: .public)")
        }

        for (idx, peer) in tunnelConfig.peers.enumerated() {
            appendTunnelLog("AWG peer[\(idx)]: endpoint=\(peer.endpoint?.stringRepresentation ?? "none")")
            appendTunnelLog("AWG peer[\(idx)]: allowedIPs=\(peer.allowedIPs.map { $0.stringRepresentation })")
            appendTunnelLog("AWG peer[\(idx)]: keepalive=\(peer.persistentKeepAlive.map { String($0) } ?? "none")")
        }
    }
}
