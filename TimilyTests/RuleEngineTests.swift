import SwiftData
import XCTest
@testable import Timily

/// Tests for `RuleEngine`: matching per `RuleKind`, specificity/priority resolution,
/// equal-specificity conflicts, archived projects, and manual-assignment precedence.
@MainActor
final class RuleEngineTests: XCTestCase {

    // MARK: - Fixtures

    private func makeContext() throws -> ModelContext {
        let container = try PersistenceController.makeContainer(inMemory: true)
        addTeardownBlock { _ = container }
        return container.mainContext
    }

    private func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: offset)
    }

    @discardableResult
    private func makeProject(
        _ name: String,
        archived: Bool = false,
        in context: ModelContext
    ) -> Project {
        let project = Project(name: name, colorHex: "#112233", isArchived: archived)
        context.insert(project)
        return project
    }

    @discardableResult
    private func makeRule(
        _ kind: RuleKind,
        _ value: String,
        project: Project,
        createdAt: Date = .init(timeIntervalSince1970: 0),
        in context: ModelContext
    ) -> AssignmentRule {
        let rule = AssignmentRule(kind: kind, matchValue: value, project: project, createdAt: createdAt)
        context.insert(rule)
        return rule
    }

    /// A segment that simultaneously satisfies every rule kind, for priority tests.
    private func makeRichSegment(in context: ModelContext) -> ActivitySegment {
        let segment = ActivitySegment(
            appBundleId: "com.google.Chrome",
            appName: "Google Chrome",
            windowTitle: "GitHub - my repo",
            documentPath: "/Users/me/code/repo/file.swift",
            url: "https://github.com/me/repo",
            startDate: date(0),
            endDate: date(60)
        )
        context.insert(segment)
        return segment
    }

    // MARK: - Per-kind matching

    func testApplicationRuleMatchesExactBundleId() throws {
        let context = try makeContext()
        let project = makeProject("Browsing", in: context)
        let rule = makeRule(.application, "com.google.Chrome", project: project, in: context)
        let segment = makeRichSegment(in: context)

        let resolution = RuleEngine.resolve(segment, with: [rule])
        XCTAssertEqual(resolution.project?.id, project.id)
    }

    func testApplicationRuleRequiresExactMatch() throws {
        let context = try makeContext()
        let project = makeProject("Browsing", in: context)
        // A prefix is not enough — application matching is exact, not "contains".
        let rule = makeRule(.application, "com.google.Chrome.beta", project: project, in: context)
        let segment = makeRichSegment(in: context)

        let resolution = RuleEngine.resolve(segment, with: [rule])
        XCTAssertNil(resolution.project)
    }

    func testTitleContainsRuleMatchesCaseInsensitively() throws {
        let context = try makeContext()
        let project = makeProject("Repo", in: context)
        let rule = makeRule(.titleContains, "github", project: project, in: context)
        let segment = makeRichSegment(in: context)

        XCTAssertEqual(RuleEngine.resolve(segment, with: [rule]).project?.id, project.id)
    }

    func testTitleContainsRuleDoesNotMatchUnrelatedTitle() throws {
        let context = try makeContext()
        let project = makeProject("Repo", in: context)
        let rule = makeRule(.titleContains, "Figma", project: project, in: context)
        let segment = makeRichSegment(in: context)

        XCTAssertNil(RuleEngine.resolve(segment, with: [rule]).project)
    }

    func testPathContainsRuleMatchesSubstring() throws {
        let context = try makeContext()
        let project = makeProject("Code", in: context)
        let rule = makeRule(.pathContains, "code/repo", project: project, in: context)
        let segment = makeRichSegment(in: context)

        XCTAssertEqual(RuleEngine.resolve(segment, with: [rule]).project?.id, project.id)
    }

    func testPathContainsRuleDoesNotMatchUnrelatedPath() throws {
        let context = try makeContext()
        let project = makeProject("Code", in: context)
        let rule = makeRule(.pathContains, "different/repo", project: project, in: context)
        let segment = makeRichSegment(in: context)

        XCTAssertNil(RuleEngine.resolve(segment, with: [rule]).project)
    }

    func testEmptyContainsRuleDoesNotMatch() throws {
        let context = try makeContext()
        let project = makeProject("Code", in: context)
        let rule = makeRule(.titleContains, "", project: project, in: context)
        let segment = makeRichSegment(in: context)

        XCTAssertNil(RuleEngine.resolve(segment, with: [rule]).project)
    }

    func testDomainRuleMatchesHost() throws {
        let context = try makeContext()
        let project = makeProject("OSS", in: context)
        let rule = makeRule(.domain, "github.com", project: project, in: context)
        let segment = makeRichSegment(in: context)

        XCTAssertEqual(RuleEngine.resolve(segment, with: [rule]).project?.id, project.id)
    }

    func testDomainRuleMatchesSubdomain() throws {
        let context = try makeContext()
        let project = makeProject("OSS", in: context)
        let rule = makeRule(.domain, "github.com", project: project, in: context)
        let segment = ActivitySegment(
            appBundleId: "com.google.Chrome",
            appName: "Google Chrome",
            url: "https://gist.github.com/me/123",
            startDate: date(0),
            endDate: date(60)
        )
        context.insert(segment)

        XCTAssertEqual(RuleEngine.resolve(segment, with: [rule]).project?.id, project.id)
    }

    func testDomainRuleDoesNotMatchDifferentHost() throws {
        let context = try makeContext()
        let project = makeProject("OSS", in: context)
        let rule = makeRule(.domain, "gitlab.com", project: project, in: context)
        let segment = makeRichSegment(in: context)

        XCTAssertNil(RuleEngine.resolve(segment, with: [rule]).project)
    }

    func testUrlRuleMatchesFullUrlExactly() throws {
        let context = try makeContext()
        let project = makeProject("Exact", in: context)
        let rule = makeRule(.url, "https://github.com/me/repo", project: project, in: context)
        let segment = makeRichSegment(in: context)

        XCTAssertEqual(RuleEngine.resolve(segment, with: [rule]).project?.id, project.id)
    }

    func testUrlRuleDoesNotMatchDifferentPath() throws {
        let context = try makeContext()
        let project = makeProject("Exact", in: context)
        let rule = makeRule(.url, "https://github.com/me/other", project: project, in: context)
        let segment = makeRichSegment(in: context)

        XCTAssertNil(RuleEngine.resolve(segment, with: [rule]).project)
    }

    func testNoRulesYieldsUnassigned() throws {
        let context = try makeContext()
        let segment = makeRichSegment(in: context)
        XCTAssertNil(RuleEngine.resolve(segment, with: []).project)
    }

    // MARK: - Priority / specificity

    func testUrlBeatsEveryLowerSpecificity() throws {
        let context = try makeContext()
        let urlProject = makeProject("URL", in: context)
        let domainProject = makeProject("Domain", in: context)
        let titleProject = makeProject("Title", in: context)
        let appProject = makeProject("App", in: context)
        let rules = [
            makeRule(.url, "https://github.com/me/repo", project: urlProject, in: context),
            makeRule(.domain, "github.com", project: domainProject, in: context),
            makeRule(.titleContains, "GitHub", project: titleProject, in: context),
            makeRule(.application, "com.google.Chrome", project: appProject, in: context),
        ]
        let segment = makeRichSegment(in: context)

        XCTAssertEqual(RuleEngine.resolve(segment, with: rules).project?.id, urlProject.id)
    }

    func testDomainBeatsTitleAndApplication() throws {
        let context = try makeContext()
        let domainProject = makeProject("Domain", in: context)
        let titleProject = makeProject("Title", in: context)
        let appProject = makeProject("App", in: context)
        let rules = [
            makeRule(.domain, "github.com", project: domainProject, in: context),
            makeRule(.titleContains, "GitHub", project: titleProject, in: context),
            makeRule(.application, "com.google.Chrome", project: appProject, in: context),
        ]
        let segment = makeRichSegment(in: context)

        XCTAssertEqual(RuleEngine.resolve(segment, with: rules).project?.id, domainProject.id)
    }

    func testTitleBeatsApplication() throws {
        let context = try makeContext()
        let titleProject = makeProject("Title", in: context)
        let appProject = makeProject("App", in: context)
        let rules = [
            makeRule(.titleContains, "GitHub", project: titleProject, in: context),
            makeRule(.application, "com.google.Chrome", project: appProject, in: context),
        ]
        let segment = makeRichSegment(in: context)

        XCTAssertEqual(RuleEngine.resolve(segment, with: rules).project?.id, titleProject.id)
    }

    func testPathBeatsApplication() throws {
        let context = try makeContext()
        let pathProject = makeProject("Path", in: context)
        let appProject = makeProject("App", in: context)
        let rules = [
            makeRule(.pathContains, "code/repo", project: pathProject, in: context),
            makeRule(.application, "com.google.Chrome", project: appProject, in: context),
        ]
        let segment = makeRichSegment(in: context)

        XCTAssertEqual(RuleEngine.resolve(segment, with: rules).project?.id, pathProject.id)
    }

    func testApplicationMatchesWhenItIsTheOnlyKind() throws {
        let context = try makeContext()
        let appProject = makeProject("App", in: context)
        let rule = makeRule(.application, "com.google.Chrome", project: appProject, in: context)
        let segment = makeRichSegment(in: context)

        XCTAssertEqual(RuleEngine.resolve(segment, with: [rule]).project?.id, appProject.id)
    }

    // MARK: - Conflicts

    func testEqualSpecificityDifferentProjectsIsUnassigned() throws {
        let context = try makeContext()
        let a = makeProject("A", in: context)
        let b = makeProject("B", in: context)
        let rules = [
            makeRule(.url, "https://github.com/me/repo", project: a, in: context),
            makeRule(.url, "https://github.com/me/repo", project: b, in: context),
        ]
        let segment = makeRichSegment(in: context)

        XCTAssertNil(RuleEngine.resolve(segment, with: rules).project)
    }

    func testTitleVersusPathSameSpecificityConflict() throws {
        let context = try makeContext()
        let titleProject = makeProject("Title", in: context)
        let pathProject = makeProject("Path", in: context)
        // title and path share the same specificity tier → different projects conflict.
        let rules = [
            makeRule(.titleContains, "GitHub", project: titleProject, in: context),
            makeRule(.pathContains, "code/repo", project: pathProject, in: context),
        ]
        let segment = makeRichSegment(in: context)

        XCTAssertNil(RuleEngine.resolve(segment, with: rules).project)
    }

    func testMultipleRulesSameProjectIsNotConflict() throws {
        let context = try makeContext()
        let project = makeProject("Same", in: context)
        // Two equally specific rules that target the same project must still resolve.
        let rules = [
            makeRule(.titleContains, "GitHub", project: project, in: context),
            makeRule(.pathContains, "code/repo", project: project, in: context),
        ]
        let segment = makeRichSegment(in: context)

        XCTAssertEqual(RuleEngine.resolve(segment, with: rules).project?.id, project.id)
    }

    func testConflictAtTopSpecificityIgnoresLowerUniqueMatch() throws {
        let context = try makeContext()
        let a = makeProject("A", in: context)
        let b = makeProject("B", in: context)
        let appProject = makeProject("App", in: context)
        // Two conflicting URL rules outrank the unambiguous application rule:
        // the conflict at the top tier wins and the result is Unassigned.
        let rules = [
            makeRule(.url, "https://github.com/me/repo", project: a, in: context),
            makeRule(.url, "https://github.com/me/repo", project: b, in: context),
            makeRule(.application, "com.google.Chrome", project: appProject, in: context),
        ]
        let segment = makeRichSegment(in: context)

        XCTAssertNil(RuleEngine.resolve(segment, with: rules).project)
    }

    // MARK: - Archived projects

    func testArchivedProjectRuleIsIgnored() throws {
        let context = try makeContext()
        let archived = makeProject("Archived", archived: true, in: context)
        let rule = makeRule(.application, "com.google.Chrome", project: archived, in: context)
        let segment = makeRichSegment(in: context)

        XCTAssertNil(RuleEngine.resolve(segment, with: [rule]).project)
    }

    func testArchivedHighSpecificityRuleDoesNotShadowActiveRule() throws {
        let context = try makeContext()
        let archived = makeProject("Archived", archived: true, in: context)
        let active = makeProject("Active", in: context)
        // The archived URL rule is dropped before specificity is considered, so the
        // active (lower-specificity) application rule wins instead of being shadowed.
        let rules = [
            makeRule(.url, "https://github.com/me/repo", project: archived, in: context),
            makeRule(.application, "com.google.Chrome", project: active, in: context),
        ]
        let segment = makeRichSegment(in: context)

        XCTAssertEqual(RuleEngine.resolve(segment, with: rules).project?.id, active.id)
    }

    // MARK: - apply(_:to:for:) and manual assignment

    func testApplyAssignsProjectAndRuleToUnassignedEntry() throws {
        let context = try makeContext()
        let project = makeProject("Work", in: context)
        let rule = makeRule(.application, "com.google.Chrome", project: project, in: context)
        let segment = makeRichSegment(in: context)
        let entry = TimeEntry(startDate: date(0), endDate: date(60), source: .fromActivity)
        context.insert(entry)

        RuleEngine.apply([rule], to: entry, for: segment)

        XCTAssertEqual(entry.project?.id, project.id)
        XCTAssertEqual(entry.matchedRule?.id, rule.id)
    }

    func testApplyLeavesEntryUnassignedOnConflict() throws {
        let context = try makeContext()
        let a = makeProject("A", in: context)
        let b = makeProject("B", in: context)
        let rules = [
            makeRule(.url, "https://github.com/me/repo", project: a, in: context),
            makeRule(.url, "https://github.com/me/repo", project: b, in: context),
        ]
        let segment = makeRichSegment(in: context)
        let entry = TimeEntry(startDate: date(0), endDate: date(60), source: .fromActivity)
        context.insert(entry)

        RuleEngine.apply(rules, to: entry, for: segment)

        XCTAssertNil(entry.project)
        XCTAssertNil(entry.matchedRule)
    }

    func testApplyDoesNotOverrideManualAssignmentOnActivityEntry() throws {
        let context = try makeContext()
        let manualProject = makeProject("Manual", in: context)
        let ruleProject = makeProject("Rule", in: context)
        let rule = makeRule(.application, "com.google.Chrome", project: ruleProject, in: context)
        let segment = makeRichSegment(in: context)
        // Manually assigned: project set, matchedRule cleared.
        let entry = TimeEntry(
            startDate: date(0),
            endDate: date(60),
            source: .fromActivity,
            project: manualProject
        )
        context.insert(entry)

        RuleEngine.apply([rule], to: entry, for: segment)

        XCTAssertEqual(entry.project?.id, manualProject.id)
        XCTAssertNil(entry.matchedRule)
    }

    func testApplyDoesNotTouchOtherEntries() throws {
        let context = try makeContext()
        let project = makeProject("Work", in: context)
        let rule = makeRule(.application, "com.google.Chrome", project: project, in: context)
        let segment = makeRichSegment(in: context)

        let target = TimeEntry(startDate: date(0), endDate: date(60), source: .fromActivity)
        // A pre-existing historical entry that must remain untouched.
        let historical = TimeEntry(startDate: date(100), endDate: date(160), source: .fromActivity)
        context.insert(target)
        context.insert(historical)

        RuleEngine.apply([rule], to: target, for: segment)

        XCTAssertEqual(target.project?.id, project.id)
        XCTAssertNil(historical.project, "rules must not modify entries other than the one passed in")
        XCTAssertNil(historical.matchedRule)
    }
}
