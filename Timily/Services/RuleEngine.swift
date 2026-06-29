import Foundation
import SwiftData

/// Resolves which `Project` a piece of activity should be assigned to, based on the
/// user's `AssignmentRule`s.
///
/// Core invariants:
/// - Specificity order: `url` > `domain` > `titleContains` / `pathContains` > `application`.
/// - Only the most specific matching rules decide the outcome. If those rules target
///   more than one distinct project, the result is a conflict and the activity stays
///   Unassigned.
/// - Several matching rules pointing at the *same* project are not a conflict.
/// - Rules whose project is archived are ignored entirely.
/// - Manual assignment always wins: `apply(_:to:for:)` never overwrites an entry the
///   user assigned by hand.
/// - The engine is pure with respect to storage. It only ever inspects the rules and
///   segment it is given and mutates the single entry passed to `apply`; it never
///   fetches or rewrites historical entries.
///
/// Marked `@MainActor` because the SwiftData `@Model` objects it reads are
/// main-actor-isolated, matching the rest of the service layer.
@MainActor
enum RuleEngine {

    /// Outcome of resolving rules against a single activity context.
    enum Resolution {
        /// A single most-specific rule (or several rules for the same project) matched.
        case matched(rule: AssignmentRule, project: Project)
        /// Nothing matched, or the most specific matches conflicted across projects.
        case unassigned

        /// The resolved project, or `nil` when unassigned.
        var project: Project? {
            switch self {
            case let .matched(_, project): return project
            case .unassigned: return nil
            }
        }

        /// The rule credited with the match, or `nil` when unassigned.
        var rule: AssignmentRule? {
            switch self {
            case let .matched(rule, _): return rule
            case .unassigned: return nil
            }
        }
    }

    // MARK: - Public API

    /// Resolves the best matching project for `segment` against `rules`.
    ///
    /// This is a pure function: it reads only its arguments and returns a decision.
    static func resolve(_ segment: ActivitySegment, with rules: [AssignmentRule]) -> Resolution {
        // Archived projects never participate in matching.
        let candidates = rules.filter { !$0.project.isArchived && matches($0, segment) }
        guard let topSpecificity = candidates.map({ specificity(of: $0.kind) }).max() else {
            return .unassigned
        }

        // Keep only the most specific matches; lower-specificity rules are shadowed.
        let mostSpecific = candidates.filter { specificity(of: $0.kind) == topSpecificity }

        // Same-specificity matches pointing at different projects are a conflict.
        let distinctProjects = Set(mostSpecific.map { $0.project.id })
        guard distinctProjects.count == 1 else { return .unassigned }

        // Deterministically credit the earliest-created rule for the winning project.
        guard let winner = mostSpecific.min(by: { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }) else {
            return .unassigned
        }
        return .matched(rule: winner, project: winner.project)
    }

    /// Applies `rules` to `entry` using `segment` as the activity context.
    ///
    /// - A manually assigned entry is left untouched (manual assignment always wins).
    /// - A unique match assigns the project and records the matching rule.
    /// - No match or a conflict leaves the entry as-is (Unassigned stays Unassigned).
    ///
    /// Only `entry` is ever mutated; historical entries are never inspected or changed.
    static func apply(_ rules: [AssignmentRule], to entry: TimeEntry, for segment: ActivitySegment) {
        guard !isManuallyAssigned(entry) else { return }

        switch resolve(segment, with: rules) {
        case let .matched(rule, project):
            entry.project = project
            entry.matchedRule = rule
        case .unassigned:
            // Leave the entry Unassigned; conflicts and non-matches assign nothing.
            break
        }
    }

    // MARK: - Matching

    /// Returns whether a single rule matches the segment, ignoring specificity.
    private static func matches(_ rule: AssignmentRule, _ segment: ActivitySegment) -> Bool {
        switch rule.kind {
        case .application:
            // Exact bundle identifier match.
            return segment.appBundleId == rule.matchValue
        case .titleContains:
            return contains(segment.windowTitle, rule.matchValue)
        case .pathContains:
            return contains(segment.documentPath, rule.matchValue)
        case .domain:
            guard let host = host(from: segment.url) else { return false }
            let target = rule.matchValue.lowercased()
            // Match the exact host or any of its subdomains.
            return host == target || host.hasSuffix("." + target)
        case .url:
            // Full URL is compared verbatim.
            guard let url = segment.url else { return false }
            return url == rule.matchValue
        }
    }

    /// Case-insensitive substring test that treats an empty needle as a non-match.
    private static func contains(_ haystack: String?, _ needle: String) -> Bool {
        guard let haystack, !needle.isEmpty else { return false }
        return haystack.range(of: needle, options: [.caseInsensitive]) != nil
    }

    /// Extracts the lowercased host from a stored URL string, or `nil` if absent.
    private static func host(from urlString: String?) -> String? {
        guard let urlString, let host = URLComponents(string: urlString)?.host else { return nil }
        return host.lowercased()
    }

    // MARK: - Specificity

    /// Higher values win. Title and path share a tier, so a title/path clash is a conflict.
    private static func specificity(of kind: RuleKind) -> Int {
        switch kind {
        case .url: return 4
        case .domain: return 3
        case .titleContains, .pathContains: return 2
        case .application: return 1
        }
    }

    // MARK: - Manual assignment

    /// An entry counts as manually assigned when it has a project but no rule recorded
    /// as the matcher because manual assignment clears `matchedRule`.
    private static func isManuallyAssigned(_ entry: TimeEntry) -> Bool {
        entry.project != nil && entry.matchedRule == nil
    }
}
