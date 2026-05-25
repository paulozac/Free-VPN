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
    var username: String?
    var password: String?

    var vpnProtocol: VPNProtocolType {
        protocolType ?? .wireGuard
    }

    var requiresAuth: Bool {
        vpnProtocol == .openVPN && OpenVPNConfig.requiresAuth(configString)
    }
}

@MainActor
@Observable
final class ProfileStore {

    private(set) var profiles: [SavedProfile] = []
    var selectedProfileID: UUID?

    private let log = Logger(subsystem: "com.zacvpn.zacvpn", category: "ProfileStore")
    private let profilesKey = "savedProfiles"
    private let selectedKey = "selectedProfileID"

    init() {
        load()
    }

    var selectedProfile: SavedProfile? {
        profiles.first(where: { $0.id == selectedProfileID })
    }

    /// Adds a new profile after validation. Returns an error message or nil on success.
    @discardableResult
    func addProfile(name: String, configString: String, username: String? = nil, password: String? = nil) -> String? {
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
            protocolType: detectedProtocol,
            username: username,
            password: password
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

    func updateCredentials(_ profile: SavedProfile, username: String, password: String) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index].username = username.isEmpty ? nil : username
        profiles[index].password = password.isEmpty ? nil : password
        save()
    }

    // MARK: - Persistence (UserDefaults — reliable on tvOS unlike Documents directory)

    private func save() {
        do {
            let data = try JSONEncoder().encode(profiles)
            UserDefaults.standard.set(data, forKey: profilesKey)

            if let id = selectedProfileID {
                UserDefaults.standard.set(id.uuidString, forKey: selectedKey)
            } else {
                UserDefaults.standard.removeObject(forKey: selectedKey)
            }
        } catch {
            log.error("Failed to save profiles: \(error.localizedDescription)")
        }
    }

    private func load() {
        // Migrate from old file-based storage if needed
        migrateFromFileIfNeeded()

        guard let data = UserDefaults.standard.data(forKey: profilesKey) else { return }

        do {
            profiles = try JSONDecoder().decode([SavedProfile].self, from: data)

            if let idString = UserDefaults.standard.string(forKey: selectedKey),
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

    /// One-time migration from the old Documents-directory JSON file to UserDefaults.
    private func migrateFromFileIfNeeded() {
        guard UserDefaults.standard.data(forKey: profilesKey) == nil else { return }

        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let fileURL = dir.appendingPathComponent("vpn_profiles.json")
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }

        do {
            let data = try Data(contentsOf: fileURL)
            // Verify it decodes before storing
            _ = try JSONDecoder().decode([SavedProfile].self, from: data)
            UserDefaults.standard.set(data, forKey: profilesKey)
            try? FileManager.default.removeItem(at: fileURL)
            log.info("Migrated profiles from file to UserDefaults")
        } catch {
            log.error("Failed to migrate profiles from file: \(error.localizedDescription)")
        }
    }
}
