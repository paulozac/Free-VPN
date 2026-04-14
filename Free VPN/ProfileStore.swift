//
//  ProfileStore.swift
//  Free VPN
//
//  Created by Paulo Zacchello on 4/11/26.
//

import Foundation
import os.log

struct SavedProfile: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var configString: String
    var dateAdded: Date
    var endpoint: String?
    var address: String?
    var protocolType: VPNProtocolType?

    var vpnProtocol: VPNProtocolType {
        protocolType ?? .wireGuard
    }
}

@MainActor
@Observable
final class ProfileStore {

    private(set) var profiles: [SavedProfile] = []
    var selectedProfileID: UUID?

    private let log = Logger(subsystem: "com.zacvpn.zacvpn", category: "ProfileStore")
    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent("vpn_profiles.json")
    }()

    init() {
        load()
    }

    var selectedProfile: SavedProfile? {
        profiles.first(where: { $0.id == selectedProfileID })
    }

    /// Adds a new profile after validation. Returns an error message or nil on success.
    @discardableResult
    func addProfile(name: String, configString: String) -> String? {
        let detectedProtocol = VPNProtocolType.detect(from: configString)

        // Validate based on protocol type
        switch detectedProtocol {
        case .wireGuard:
            if let error = WireGuardConfig.validate(configString) {
                return error
            }
        case .openVPN:
            if let error = OpenVPNConfig.validate(configString) {
                return error
            }
        }

        let endpoint: String?
        let address: String?
        let displayName: String

        switch detectedProtocol {
        case .wireGuard:
            let config = try? WireGuardConfig.parse(from: configString)
            endpoint = config?.peers.first?.endpoint
            address = config?.interface.address.first
            displayName = config?.displayName() ?? "Profile \(profiles.count + 1)"
        case .openVPN:
            endpoint = OpenVPNConfig.extractEndpoint(from: configString)
            address = nil
            displayName = OpenVPNConfig.displayName(from: configString)
        }

        let profile = SavedProfile(
            id: UUID(),
            name: name.isEmpty ? displayName : name,
            configString: configString,
            dateAdded: Date(),
            endpoint: endpoint,
            address: address,
            protocolType: detectedProtocol
        )

        profiles.append(profile)

        if profiles.count == 1 {
            selectedProfileID = profile.id
        }

        save()
        log.info("Added \(detectedProtocol.displayName) profile '\(profile.name)'")
        return nil
    }

    func removeProfile(_ profile: SavedProfile) {
        profiles.removeAll(where: { $0.id == profile.id })
        if selectedProfileID == profile.id {
            selectedProfileID = profiles.first?.id
        }
        save()
    }

    func selectProfile(_ profile: SavedProfile) {
        selectedProfileID = profile.id
        save()
    }

    func renameProfile(_ profile: SavedProfile, to newName: String) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index].name = newName
        save()
    }

    // MARK: - Persistence

    private func save() {
        do {
            let data = try JSONEncoder().encode(profiles)
            try data.write(to: fileURL, options: .atomic)

            if let id = selectedProfileID {
                UserDefaults.standard.set(id.uuidString, forKey: "selectedProfileID")
            } else {
                UserDefaults.standard.removeObject(forKey: "selectedProfileID")
            }
        } catch {
            log.error("Failed to save profiles: \(error.localizedDescription)")
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

        do {
            let data = try Data(contentsOf: fileURL)
            profiles = try JSONDecoder().decode([SavedProfile].self, from: data)

            if let idString = UserDefaults.standard.string(forKey: "selectedProfileID"),
               let id = UUID(uuidString: idString),
               profiles.contains(where: { $0.id == id }) {
                selectedProfileID = id
            } else {
                selectedProfileID = profiles.first?.id
            }
        } catch {
            log.error("Failed to load profiles: \(error.localizedDescription)")
        }
    }
}
