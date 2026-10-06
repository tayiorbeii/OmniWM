// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 BarutSRB — https://github.com/OmniNull/OmniWM

import Foundation

public enum IPCWindowGroupActionName: String, Codable, CaseIterable, Equatable, Sendable {
    case list
    case inspect
    case resolve
}

public enum IPCWindowGroupRequest: Equatable, Sendable {
    case list
    case inspect(name: String)
    case resolve(name: String)

    public var name: IPCWindowGroupActionName {
        switch self {
        case .list:
            .list
        case .inspect:
            .inspect
        case .resolve:
            .resolve
        }
    }
}

extension IPCWindowGroupRequest: Codable {
    private enum CodingKeys: String, CodingKey {
        case name
        case group
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let action = try container.decode(IPCWindowGroupActionName.self, forKey: .name)
        let group = try container.decodeIfPresent(String.self, forKey: .group)

        switch action {
        case .list:
            guard group == nil else {
                throw DecodingError.dataCorruptedError(
                    forKey: .group,
                    in: container,
                    debugDescription: "list does not accept a group name"
                )
            }
            self = .list
        case .inspect,
             .resolve:
            guard let group else {
                throw DecodingError.keyNotFound(
                    CodingKeys.group,
                    .init(
                        codingPath: container.codingPath,
                        debugDescription: "\(action.rawValue) requires a group name"
                    )
                )
            }
            self = action == .inspect ? .inspect(name: group) : .resolve(name: group)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        switch self {
        case .list:
            break
        case let .inspect(group),
             let .resolve(group):
            try container.encode(group, forKey: .group)
        }
    }
}

public enum IPCWindowGroupScope: String, Codable, Equatable, Sendable {
    case activeWorkspace = "active-workspace"
    case allWorkspaces = "all-workspaces"
}

public enum IPCWindowGroupClauseKind: String, Codable, Equatable, Sendable {
    case include
    case exclude
}

public struct IPCWindowGroupClauseRef: Codable, Equatable, Sendable {
    public let kind: IPCWindowGroupClauseKind
    public let index: Int

    public init(kind: IPCWindowGroupClauseKind, index: Int) {
        self.kind = kind
        self.index = index
    }
}

public enum IPCWindowGroupIssueCode: String, Codable, Equatable, Sendable {
    case invalidName = "invalid-name"
    case duplicateName = "duplicate-name"
    case duplicateId = "duplicate-id"
    case emptyInclusions = "empty-inclusions"
    case missingBundleId = "missing-bundle-id"
    case invalidTitleRegex = "invalid-title-regex"
}

public struct IPCWindowGroupIssue: Codable, Equatable, Sendable {
    public let code: IPCWindowGroupIssueCode
    public let clause: IPCWindowGroupClauseRef?
    public let message: String?

    public init(code: IPCWindowGroupIssueCode, clause: IPCWindowGroupClauseRef? = nil, message: String? = nil) {
        self.code = code
        self.clause = clause
        self.message = message
    }
}

public struct IPCWindowGroupMatcher: Codable, Equatable, Sendable {
    public let bundleId: String
    public let appNameSubstring: String?
    public let titleSubstring: String?
    public let titleRegex: String?
    public let axRole: String?
    public let axSubrole: String?

    public init(
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
}

public struct IPCWindowGroupSummary: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let scope: IPCWindowGroupScope
    public let inclusionCount: Int
    public let exclusionCount: Int
    public let isValid: Bool

    public init(
        id: String,
        name: String,
        scope: IPCWindowGroupScope,
        inclusionCount: Int,
        exclusionCount: Int,
        isValid: Bool
    ) {
        self.id = id
        self.name = name
        self.scope = scope
        self.inclusionCount = inclusionCount
        self.exclusionCount = exclusionCount
        self.isValid = isValid
    }
}

public struct IPCWindowGroupsResult: Codable, Equatable, Sendable {
    public let groups: [IPCWindowGroupSummary]

    public init(groups: [IPCWindowGroupSummary]) {
        self.groups = groups
    }
}

public struct IPCWindowGroupDefinition: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let scope: IPCWindowGroupScope
    public let include: [IPCWindowGroupMatcher]
    public let exclude: [IPCWindowGroupMatcher]
    public let issues: [IPCWindowGroupIssue]

    public init(
        id: String,
        name: String,
        scope: IPCWindowGroupScope,
        include: [IPCWindowGroupMatcher],
        exclude: [IPCWindowGroupMatcher],
        issues: [IPCWindowGroupIssue]
    ) {
        self.id = id
        self.name = name
        self.scope = scope
        self.include = include
        self.exclude = exclude
        self.issues = issues
    }
}

public enum IPCWindowGroupResolutionStatus: String, Codable, Equatable, Sendable {
    case resolved
    case noMatch = "no-match"
    case incomplete
}

public enum IPCWindowGroupFact: String, Codable, Equatable, Sendable {
    case application
    case title
    case accessibilityRole = "accessibility-role"
}

public struct IPCWindowGroupUnresolvedClause: Codable, Equatable, Sendable {
    public let clause: IPCWindowGroupClauseRef
    public let facts: [IPCWindowGroupFact]

    public init(clause: IPCWindowGroupClauseRef, facts: [IPCWindowGroupFact]) {
        self.clause = clause
        self.facts = facts
    }
}

public struct IPCWindowGroupWindow: Codable, Equatable, Sendable {
    public let id: String
    public let workspace: IPCWorkspaceRef?
    public let app: IPCAppRef?
    public let title: String?
    public let isAppHidden: Bool
    public let matchedClause: Int?
    public let unresolvedClauses: [IPCWindowGroupUnresolvedClause]

    public init(
        id: String,
        workspace: IPCWorkspaceRef?,
        app: IPCAppRef?,
        title: String?,
        isAppHidden: Bool,
        matchedClause: Int?,
        unresolvedClauses: [IPCWindowGroupUnresolvedClause]
    ) {
        self.id = id
        self.workspace = workspace
        self.app = app
        self.title = title
        self.isAppHidden = isAppHidden
        self.matchedClause = matchedClause
        self.unresolvedClauses = unresolvedClauses
    }
}

public struct IPCWindowGroupResolution: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let scope: IPCWindowGroupScope
    public let workspace: IPCWorkspaceRef?
    public let status: IPCWindowGroupResolutionStatus
    public let members: [IPCWindowGroupWindow]
    public let unresolved: [IPCWindowGroupWindow]
    public let stale: [String]

    public init(
        id: String,
        name: String,
        scope: IPCWindowGroupScope,
        workspace: IPCWorkspaceRef?,
        status: IPCWindowGroupResolutionStatus,
        members: [IPCWindowGroupWindow],
        unresolved: [IPCWindowGroupWindow],
        stale: [String]
    ) {
        self.id = id
        self.name = name
        self.scope = scope
        self.workspace = workspace
        self.status = status
        self.members = members
        self.unresolved = unresolved
        self.stale = stale
    }
}

public struct IPCWindowGroupActionDescriptor: Codable, Equatable, Sendable {
    public let path: String
    public let name: IPCWindowGroupActionName
    public let summary: String
    public let arguments: [String]

    public init(path: String, name: IPCWindowGroupActionName, summary: String, arguments: [String] = []) {
        self.path = path
        self.name = name
        self.summary = summary
        self.arguments = arguments
    }
}
