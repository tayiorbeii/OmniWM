// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

enum SavedWindowGroupScope: String, Codable, CaseIterable, Equatable, Sendable {
    case activeWorkspace
    case allWorkspaces
}

struct SavedWindowGroupMatcher: Codable, Equatable, Sendable {
    var bundleId: String
    var appNameSubstring: String?
    var titleSubstring: String?
    var titleRegex: String?
    var axRole: String?
    var axSubrole: String?

    init(
        bundleId: String,
        appNameSubstring: String? = nil,
        titleSubstring: String? = nil,
        titleRegex: String? = nil,
        axRole: String? = nil,
        axSubrole: String? = nil
    ) {
        self.bundleId = bundleId
        self.appNameSubstring = appNameSubstring
        self.titleSubstring = titleSubstring
        self.titleRegex = titleRegex
        self.axRole = axRole
        self.axSubrole = axSubrole
    }

    var appRule: AppRule {
        AppRule(
            bundleId: bundleId,
            appNameSubstring: appNameSubstring,
            titleSubstring: titleSubstring,
            titleRegex: titleRegex,
            axRole: axRole,
            axSubrole: axSubrole
        )
    }
}

struct SavedWindowGroup: Codable, Identifiable, Equatable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case scope
        case include
        case exclude
    }

    let id: UUID
    var name: String
    var scope: SavedWindowGroupScope
    var include: [SavedWindowGroupMatcher]
    var exclude: [SavedWindowGroupMatcher]

    init(
        id: UUID = UUID(),
        name: String,
        scope: SavedWindowGroupScope,
        include: [SavedWindowGroupMatcher],
        exclude: [SavedWindowGroupMatcher] = []
    ) {
        self.id = id
        self.name = name
        self.scope = scope
        self.include = include
        self.exclude = exclude
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        scope = try container.decode(SavedWindowGroupScope.self, forKey: .scope)
        include = try container.decode([SavedWindowGroupMatcher].self, forKey: .include)
        exclude = try container.decodeIfPresent([SavedWindowGroupMatcher].self, forKey: .exclude) ?? []
    }

    static func normalizedName(_ rawName: String) -> String? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            return nil
        }
        return name
    }
}
