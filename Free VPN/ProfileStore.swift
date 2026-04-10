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
        if let error = WireGuardConfig.validate(configString) {
            return error
        }

        let config = try? WireGuardConfig.parse(from: configString)

        let profile = SavedProfile(
            id: UUID(),
            name: name.isEmpty ? (config?.displayName() ?? "Profile \(profiles.count + 1)") : name,
            configString: configString,
            dateAdded: Date(),
            endpoint: config?.peers.first?.endpoint,
            address: config?.interface.address.first
        )

        profiles.append(profile)

        // Auto-select if it's the first profile
        if profiles.count == 1 {
            selectedProfileID = profile.id
        }

        save()
        log.info("Added profile '\(profile.name)'")
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

    // MARK: - Persistence

    private func save() {
        do {
            let data = try JSONEncoder().encode(profiles)
            try data.write(to: fileURL, options: .atomic)

            // Persist selected ID separately
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
