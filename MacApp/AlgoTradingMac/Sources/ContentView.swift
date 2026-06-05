import Foundation
import Charts
import Darwin
import SwiftUI
import TradingKit
#if canImport(AppKit)
import AppKit
#endif

typealias TradingEnvironment = TradingKit.Environment
typealias TradingMarketDataFeed = TradingKit.MarketDataFeed
typealias TradingInstrumentType = TradingKit.InstrumentType

enum LiveSafetyBannerSeverity: String, Equatable {
    case hidden
    case healthy
    case degraded
    case blocked

    var color: Color {
        switch self {
        case .hidden:
            return .green
        case .healthy:
            return .green
        case .degraded:
            return .orange
        case .blocked:
            return .red
        }
    }
}

func makeLiveSafetyBannerSeverity(
    selectedEnvironment: TradingEnvironment,
    isArmedForLiveTrading: Bool,
    killSwitchEnabled: Bool,
    readinessStatus: AlwaysOnReadinessStatus
) -> LiveSafetyBannerSeverity {
    guard selectedEnvironment == .live else {
        return .hidden
    }
    if killSwitchEnabled || isArmedForLiveTrading == false {
        return .blocked
    }
    switch readinessStatus {
    case .active:
        return .healthy
    case .recoveringAfterWake, .degraded:
        return .degraded
    case .pausedByHost, .needsAttention:
        return .blocked
    }
}

func makeLiveSafetyStatusDetail(
    selectedEnvironment: TradingEnvironment,
    isArmedForLiveTrading: Bool,
    killSwitchEnabled: Bool,
    alwaysOnReadiness: AlwaysOnReadinessState
) -> String {
    guard selectedEnvironment == .live else {
        return "Paper environment is selected."
    }
    if killSwitchEnabled {
        return "Kill switch is enabled; Live NEW/REPLACE is blocked and cancel remains available."
    }
    if isArmedForLiveTrading == false {
        return "Live is disarmed; arming is required before Live NEW/REPLACE can pass normal gates."
    }
    if alwaysOnReadiness.status == .active {
        return "Live is armed and app-owned readiness is healthy. Live NEW/REPLACE still requires the governed order path and local authentication when enabled."
    }
    if let blocker = alwaysOnReadiness.blockers.first {
        return "Live is armed; green requires readiness to clear: \(blocker)"
    }
    return "Live is armed; green requires \(alwaysOnReadiness.summary)"
}

struct OwnerEnvironmentFeedPreferenceStore {
    static let environmentKey = "OwnerSelectedTradingEnvironment"
    static let marketDataFeedKey = "OwnerSelectedMarketDataFeed"

    static func loadEnvironment(
        defaults: UserDefaults = .standard
    ) -> TradingEnvironment {
        guard let rawValue = defaults.string(forKey: environmentKey),
              let environment = TradingEnvironment(rawValue: rawValue)
        else {
            return .paper
        }
        return environment
    }

    static func loadMarketDataFeed(
        defaults: UserDefaults = .standard
    ) -> TradingMarketDataFeed {
        guard let rawValue = defaults.string(forKey: marketDataFeedKey),
              let feed = TradingMarketDataFeed(rawValue: rawValue)
        else {
            return .stocksIEX
        }
        return feed
    }

    static func saveEnvironment(
        _ environment: TradingEnvironment,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(environment.rawValue, forKey: environmentKey)
    }

    static func saveMarketDataFeed(
        _ feed: TradingMarketDataFeed,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(feed.rawValue, forKey: marketDataFeedKey)
    }
}

func makePMInboxRetainedSelection(
    currentSelectionID: String?,
    availableIDs: [String]
) -> String? {
    guard let currentSelectionID else { return nil }
    return availableIDs.contains(currentSelectionID) ? currentSelectionID : nil
}

func firstNonEmptyPMInboxText(_ values: [String?]) -> String? {
    for value in values {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty == false {
            return trimmed
        }
    }
    return nil
}

func pmInboxSupportingContextSummary(_ sections: [(String, String?)]) -> String? {
    let lines = sections.compactMap { title, body -> String? in
        guard let body = firstNonEmptyPMInboxText([body]) else {
            return nil
        }
        return "\(title): \(body)"
    }
    guard lines.isEmpty == false else {
        return nil
    }
    return lines.joined(separator: "\n\n")
}

func normalizedRSSSourceIdentifier(forFeedName feedName: String) -> String {
    let lower = feedName.lowercased()
    let scalars = lower.unicodeScalars.map { scalar -> Character in
        let allowed = CharacterSet.alphanumerics.contains(scalar)
        return allowed ? Character(scalar) : "_"
    }
    let collapsed = String(scalars)
        .replacingOccurrences(of: "__", with: "_")
        .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    if collapsed.isEmpty {
        return "rss_custom"
    }
    return "rss_\(collapsed)"
}

func readableNewsSourceLabel(for event: NewsEvent, rssFeeds: [RSSFeed]) -> String {
    switch event.source {
    case "alpaca_news":
        return "Alpaca News"
    case "sec_edgar":
        return "SEC EDGAR"
    default:
        if event.source.hasPrefix("rss_") {
            if let feed = rssFeeds.first(where: { normalizedRSSSourceIdentifier(forFeedName: $0.name) == event.source }) {
                return feed.name
            }
            let trimmed = event.source.replacingOccurrences(of: "rss_", with: "")
            if trimmed.isEmpty {
                return "RSS"
            }
            return trimmed
                .split(separator: "_")
                .map { $0.capitalized }
                .joined(separator: " ")
        }
        return event.source
    }
}

func latestRuntimeSettingsValue<T>(
    current: T?,
    incoming: T,
    updatedAt: KeyPath<T, Date>
) -> T {
    guard let current else {
        return incoming
    }
    if current[keyPath: updatedAt] >= incoming[keyPath: updatedAt] {
        return current
    }
    return incoming
}

actor AsyncRefreshCoordinator<Key: Hashable> {
    private var latestGenerationByKey: [Key: Int] = [:]

    func begin(_ key: Key) -> Int {
        let nextGeneration = (latestGenerationByKey[key] ?? 0) + 1
        latestGenerationByKey[key] = nextGeneration
        return nextGeneration
    }

    func isLatest(_ generation: Int, for key: Key) -> Bool {
        latestGenerationByKey[key] == generation
    }
}

private actor StoreEventRefreshCoalescer {
    private let intervalNanoseconds: UInt64
    private var pendingMarketDataRefreshTask: Task<Void, Never>?
    private var marketDataRefreshInFlight = false
    private var marketDataRefreshPendingAfterInFlight = false
    private var lastMarketDataRefreshScheduledAt: Date?

    init(intervalNanoseconds: UInt64) {
        self.intervalNanoseconds = intervalNanoseconds
    }

    func cancelPendingMarketDataRefresh() {
        pendingMarketDataRefreshTask?.cancel()
        pendingMarketDataRefreshTask = nil
        marketDataRefreshPendingAfterInFlight = false
    }

    func handleMarketDataEvent(
        refresh: @escaping @Sendable () async -> Void
    ) {
        if marketDataRefreshInFlight {
            marketDataRefreshPendingAfterInFlight = true
            scheduleDelayedMarketDataRefreshIfNeeded(refresh: refresh)
            return
        }

        let now = Date()
        if let lastMarketDataRefreshScheduledAt,
           now.timeIntervalSince(lastMarketDataRefreshScheduledAt) < Double(intervalNanoseconds) / 1_000_000_000 {
            scheduleDelayedMarketDataRefreshIfNeeded(refresh: refresh)
            return
        }

        startMarketDataRefresh(refresh: refresh)
    }

    private func scheduleDelayedMarketDataRefreshIfNeeded(
        refresh: @escaping @Sendable () async -> Void
    ) {
        guard pendingMarketDataRefreshTask == nil else {
            return
        }

        let delayNanoseconds = intervalNanoseconds
        pendingMarketDataRefreshTask = Task { [weak self] in
            guard let self else {
                return
            }
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled else {
                return
            }
            await self.startMarketDataRefresh(refresh: refresh)
        }
    }

    private func startMarketDataRefresh(
        refresh: @escaping @Sendable () async -> Void
    ) {
        pendingMarketDataRefreshTask?.cancel()
        pendingMarketDataRefreshTask = nil
        marketDataRefreshInFlight = true
        marketDataRefreshPendingAfterInFlight = false
        lastMarketDataRefreshScheduledAt = Date()

        Task { [weak self] in
            await refresh()
            await self?.finishMarketDataRefresh(refresh: refresh)
        }
    }

    private func finishMarketDataRefresh(
        refresh: @escaping @Sendable () async -> Void
    ) {
        marketDataRefreshInFlight = false
        if marketDataRefreshPendingAfterInFlight {
            marketDataRefreshPendingAfterInFlight = false
            scheduleDelayedMarketDataRefreshIfNeeded(refresh: refresh)
        }
    }
}

private enum StoreEventSubscriptionRunner {
    static func run(
        events: AsyncStream<StoreEvent>,
        coalescer: StoreEventRefreshCoalescer,
        receiveMarketData: @escaping @Sendable () async -> Void,
        receiveControlEvent: @escaping @Sendable (StoreEvent) async -> Void
    ) async {
        for await event in events {
            if isHighFrequencyMarketDataStoreEventName(event.name) {
                await coalescer.handleMarketDataEvent(refresh: receiveMarketData)
                continue
            }

            await coalescer.cancelPendingMarketDataRefresh()
            await receiveControlEvent(event)
        }
    }
}

private func isHighFrequencyMarketDataStoreEventName(_ name: String) -> Bool {
    switch name {
    case "market_data", "market_quote", "market_trade", "market_bar":
        return true
    default:
        return false
    }
}

private enum PMInboxRefreshDomain: String {
    case signals
    case pmProfiles
    case pmCommunicationSessions
    case pmCommunicationMessages
    case pmContextPack
    case pmDecisions
    case pmApprovalRequests
    case pmDelegations
    case analystCharters
    case analystTasks
    case analystFindings
    case analystSourceAccessSuggestions
    case analystEvidenceBundles
    case analystMemos
    case analystStrategyImplications
    case analystStrategyFollowUpCandidates
    case analystStandingReports
}

private func isBackgroundStandingReviewApprovalRequest(
    _ request: PMApprovalRequest,
    decisions: [PMDecisionRecord],
    executionAssessment: PMExecutionRoutingAssessment? = nil
) -> Bool {
    let linkedDecision = decisions.first(where: { $0.decisionId == request.decisionId })
    return makePMRecommendationClosurePresentation(
        request: request,
        linkedDecision: linkedDecision,
        executionAssessment: executionAssessment
    ).status == .backgroundPMReview
}

struct PMInboxRecentAnalystActivityItem: Identifiable, Equatable {
    enum ActivityKind: String, Equatable {
        case standingReport = "Standing Report"
        case adHocAnalystMemo = "PM-requested Analyst Memo"
        case analystMemo = "Analyst Memo"
        case adHocDelegation = "PM-requested Delegation"
        case delegation = "PM Delegation"
    }

    let id: String
    let kind: ActivityKind
    let analystTitle: String
    let timestamp: Date
    let headline: String
    let summary: String
    let linkedStandingReportID: String?
    let linkedMemoID: String?
    let linkedDelegationID: String?
}

struct PMInboxRecentAnalystActivityDetailPresentation: Equatable {
    let analystTitle: String
    let activityType: String
    let headline: String
    let summary: String
    let conclusion: String
    let pmTreatment: String
    let nextStep: String?
    let supportingContext: String?
    let sourceTruth: AnalystSourceTruthPresentation?
    let linkedStandingReportID: String?
    let linkedMemoPresentation: AnalystMemoReadablePresentation?
    let executionTruth: PMInboxExecutionTruthPresentation
}

struct PMInboxRecentNewsReviewSummaryPresentation: Equatable {
    let analystSummary: String
    let analystSupportSummary: String?
    let analystRuntimeSummary: String
    let pmTreatmentSummary: String
    let affectedNames: String?
    let nextStep: String?
}

struct PMInboxRecentNewsReviewDetailPresentation: Equatable {
    let analystFindingSummary: String
    let analystMaterialDevelopments: [String]
    let analystWhyItMatters: String
    let analystCurrentView: String
    let analystMaterialSourceSummary: String?
    let analystSupplementalSourcesReviewed: [String]
    let analystRecommendedNextStep: String
    let analystUncertaintySummary: String?
    let sourceTruth: AnalystSourceTruthPresentation?
    let executionTruth: PMInboxExecutionTruthPresentation
    let affectedHoldings: [String]
    let affectedWatchlistOnly: [String]
}

private struct PMInboxReviewProjection: Equatable {
    var approvalRequestsForReview: [PMApprovalRequest] = []
    var recentNewsDecisionsForReview: [PMDecisionRecord] = []
    var recentDecisionsForReview: [PMDecisionRecord] = []
    var recentAnalystActivityScopeItems: [PMInboxRecentAnalystActivityItem] = []
    var recentAnalystActivityItems: [PMInboxRecentAnalystActivityItem] = []
    var communicationSessionsForDisplay: [PMCommunicationSession] = []
    var pmBackgroundReviewNotebookEntries: [PMNotebookEntry] = []
}

private enum PMInboxProjectionBudget {
    static let approvalRequestsForReview = 5
    static let recentAnalystActivityVisible = 5
    static let recentAnalystActivityScope = 25
    static let communicationSessionsForDisplay = 25
    static let backgroundReviewNotebookEntries = 12
    static let rowHeadlineCharacters = 180
    static let rowSummaryCharacters = 480
}

struct PMInboxExecutionTruthPresentation: Equatable {
    let requestedOrConfiguredSummary: String
    let executionUsedSummary: String
    let summary: String
}

private func boundedPMInboxPreviewText(_ text: String, maxCharacters: Int) -> String {
    let collapsed = text
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\t", with: " ")
    guard collapsed.count > maxCharacters else {
        return collapsed
    }
    return String(collapsed.prefix(max(0, maxCharacters - 3))).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
}

func makePMInboxRecentAnalystActivityItems(
    standingReportSummaries: [AnalystStandingReportReviewSummaryPresentation],
    reports: [AnalystStandingReport],
    memos: [AnalystMemo],
    charters: [AnalystCharter],
    delegations: [PMDelegationRecord],
    includeRecentNews: Bool = false,
    limit: Int? = 5
) -> [PMInboxRecentAnalystActivityItem] {
    let memosByID = Dictionary(uniqueKeysWithValues: memos.map { ($0.memoId, $0) })
    let reportsByID = Dictionary(uniqueKeysWithValues: reports.map { ($0.reportId, $0) })
    let reportActivityItems: [PMInboxRecentAnalystActivityItem] = standingReportSummaries.compactMap { report -> PMInboxRecentAnalystActivityItem? in
        let linkedReport = reportsByID[report.reportId]
        let linkedMemo = linkedReport.flatMap { memosByID[$0.memoId] }
        guard includeRecentNews || isRecentNewsAnalystContext(
            analystID: linkedReport?.analystId,
            charterID: linkedReport?.charterId,
            title: report.analystTitle
        ) == false else {
            return nil
        }
        return PMInboxRecentAnalystActivityItem(
            id: "standing:\(report.reportId)",
            kind: .standingReport,
            analystTitle: report.analystTitle,
            timestamp: recentAnalystStandingActivityTimestamp(
                deliveredAt: report.deliveredAt,
                report: linkedReport,
                linkedMemo: linkedMemo
            ),
            headline: boundedPMInboxPreviewText(
                report.title,
                maxCharacters: PMInboxProjectionBudget.rowHeadlineCharacters
            ),
            summary: boundedPMInboxPreviewText(
                report.headlineView.isEmpty == false ? report.headlineView : report.executiveSummary,
                maxCharacters: PMInboxProjectionBudget.rowSummaryCharacters
            ),
            linkedStandingReportID: report.reportId,
            linkedMemoID: linkedReport?.memoId,
            linkedDelegationID: linkedReport
                .flatMap { report in
                    memosByID[report.memoId]?.delegationId
                }
        )
    }

    let chartersByID = Dictionary(uniqueKeysWithValues: charters.map { ($0.charterId, $0) })
    let delegationsByID = Dictionary(uniqueKeysWithValues: delegations.map { ($0.delegationId, $0) })
    let memosByDelegationID = Dictionary(grouping: memos) { $0.delegationId ?? "" }
    let memoActivityItems = memos
        .filter { memo in
            memo.delegationId != nil
                && reports.contains(where: { $0.memoId == memo.memoId }) == false
        }
        .compactMap { memo -> PMInboxRecentAnalystActivityItem? in
            guard includeRecentNews || isRecentNewsAnalystContext(
                analystID: memo.analystId,
                charterID: memo.charterId,
                title: memo.title
            ) == false else {
                return nil
            }
            let analystTitle = memo.charterId.flatMap { chartersByID[$0]?.title } ?? memo.analystId
            let linkedDelegation = memo.delegationId.flatMap { delegationsByID[$0] }
            return PMInboxRecentAnalystActivityItem(
                id: "memo:\(memo.memoId)",
                kind: isPMRequestedAdHocDelegation(linkedDelegation) ? .adHocAnalystMemo : .analystMemo,
                analystTitle: analystTitle,
                timestamp: memo.updatedAt,
                headline: boundedPMInboxPreviewText(
                    memo.title,
                    maxCharacters: PMInboxProjectionBudget.rowHeadlineCharacters
                ),
                summary: boundedPMInboxPreviewText(
                    memo.executiveSummary,
                    maxCharacters: PMInboxProjectionBudget.rowSummaryCharacters
                ),
                linkedStandingReportID: nil,
                linkedMemoID: memo.memoId,
                linkedDelegationID: memo.delegationId
            )
        }

    let delegationActivityItems = delegations
        .filter { delegation in
            isExercisePMDelegation(delegation) == false
                && (memosByDelegationID[delegation.delegationId]?.isEmpty ?? true)
        }
        .compactMap { delegation -> PMInboxRecentAnalystActivityItem? in
            guard includeRecentNews || isRecentNewsAnalystContext(
                analystID: delegation.analystId,
                charterID: delegation.charterId,
                title: delegation.title
            ) == false else {
                return nil
            }
            return PMInboxRecentAnalystActivityItem(
                id: "delegation:\(delegation.delegationId)",
                kind: isPMRequestedAdHocDelegation(delegation) ? .adHocDelegation : .delegation,
                analystTitle: chartersByID[delegation.charterId]?.title ?? delegation.analystId,
                timestamp: delegation.updatedAt,
                headline: boundedPMInboxPreviewText(
                    delegation.title,
                    maxCharacters: PMInboxProjectionBudget.rowHeadlineCharacters
                ),
                summary: boundedPMInboxPreviewText(
                    delegation.rationale,
                    maxCharacters: PMInboxProjectionBudget.rowSummaryCharacters
                ),
                linkedStandingReportID: nil,
                linkedMemoID: nil,
                linkedDelegationID: delegation.delegationId
            )
        }

    let richerActivityItems = sortPMInboxRecentAnalystActivityItems(reportActivityItems + memoActivityItems)
    let fallbackActivityItems = sortPMInboxRecentAnalystActivityItems(delegationActivityItems)
    let combined = richerActivityItems + fallbackActivityItems
    guard let limit else {
        return combined
    }
    return Array(combined.prefix(limit))
}

private func isRecentNewsAnalystContext(
    analystID: String?,
    charterID: String?,
    title: String?
) -> Bool {
    if analystID == recentNewsStandingAnalystID || charterID == recentNewsStandingAnalystCharterID {
        return true
    }
    guard let title else {
        return false
    }
    return title.localizedCaseInsensitiveContains(recentNewsStandingAnalystTitle)
}

private func sortPMInboxRecentAnalystActivityItems(
    _ items: [PMInboxRecentAnalystActivityItem]
) -> [PMInboxRecentAnalystActivityItem] {
    items.sorted { lhs, rhs in
        if lhs.timestamp == rhs.timestamp {
            let lhsPriority = pmInboxRecentAnalystActivityPriority(lhs.kind)
            let rhsPriority = pmInboxRecentAnalystActivityPriority(rhs.kind)
            if lhsPriority == rhsPriority {
                return lhs.id < rhs.id
            }
            return lhsPriority > rhsPriority
        }
        return lhs.timestamp > rhs.timestamp
    }
}

private func pmInboxRecentAnalystActivityPriority(
    _ kind: PMInboxRecentAnalystActivityItem.ActivityKind
) -> Int {
    switch kind {
    case .standingReport:
        return 3
    case .adHocAnalystMemo:
        return 3
    case .analystMemo:
        return 2
    case .adHocDelegation:
        return 2
    case .delegation:
        return 1
    }
}

private func isPMRequestedAdHocDelegation(_ delegation: PMDelegationRecord?) -> Bool {
    guard let delegation else { return false }
    if delegation.sourceCommunicationMessageId != nil {
        return true
    }
    if let status = delegation.followThrough?.status {
        return status != .notRequired
    }
    return false
}

private func recentAnalystStandingActivityTimestamp(
    deliveredAt: Date,
    report: AnalystStandingReport?,
    linkedMemo: AnalystMemo?
) -> Date {
    [
        deliveredAt,
        report?.updatedAt,
        report?.createdAt,
        linkedMemo?.updatedAt,
        linkedMemo?.createdAt
    ]
    .compactMap { $0 }
    .max() ?? deliveredAt
}

func makePMInboxRecentAnalystActivityDetailPresentation(
    item: PMInboxRecentAnalystActivityItem,
    reports: [AnalystStandingReport],
    memos: [AnalystMemo],
    evidenceBundles: [AnalystEvidenceBundle],
    delegations: [PMDelegationRecord]
) -> PMInboxRecentAnalystActivityDetailPresentation {
    let linkedReport = item.linkedStandingReportID.flatMap { reportID in
        reports.first(where: { $0.reportId == reportID })
    }
    let linkedMemo = item.linkedMemoID.flatMap { memoID in
        memos.first(where: { $0.memoId == memoID })
    } ?? linkedReport.flatMap { report in
        memos.first(where: { $0.memoId == report.memoId })
    }
    let linkedDelegation = item.linkedDelegationID.flatMap { delegationID in
        delegations.first(where: { $0.delegationId == delegationID })
    } ?? linkedMemo.flatMap { memo in
        memo.delegationId.flatMap { delegationID in
            delegations.first(where: { $0.delegationId == delegationID })
        }
    }
    let linkedEvidenceBundle = linkedMemo.flatMap { memo in
        memo.evidenceBundleId.flatMap { bundleID in
            evidenceBundles.first(where: { $0.bundleId == bundleID })
        }
    }

    let conclusion = firstNonEmptyPMInboxText([
        linkedReport?.headlineView,
        linkedMemo?.currentView,
        linkedReport?.summary,
        linkedMemo?.executiveSummary,
        linkedDelegation?.rationale,
        item.summary
    ]) ?? item.summary

    let nextStep = firstNonEmptyPMInboxText([
        linkedMemo?.recommendedNextStep,
        linkedReport?.openQuestions.first,
        linkedDelegation?.taskingBrief?.taskObjective
    ])

    let supportingContext = pmInboxSupportingContextSummary([
        ("Portfolio relevance", linkedReport?.portfolioRelevanceSummary),
        ("Reporting window", linkedReport?.reportingWindowSummary),
        ("Delegation context", linkedDelegation?.rationale)
    ])

    let pmTreatment: String
    switch item.kind {
    case .standingReport:
        pmTreatment = linkedReport?.deliveryStatus.displayTitle
            ?? "Tracked as standing analyst activity for PM review."
    case .adHocAnalystMemo:
        let delivery = linkedDelegation?.followThrough?.status.rawValue.replacingOccurrences(of: "_", with: " ")
            ?? "not recorded"
        pmTreatment = "PM-requested ad hoc analyst result. Follow-through delivery: \(delivery)."
    case .analystMemo:
        pmTreatment = linkedDelegation?.status == .issued
            ? "Captured as current PM analyst follow-up context."
            : "Captured as memo-backed PM background context."
    case .adHocDelegation:
        let delivery = linkedDelegation?.followThrough?.status.rawValue.replacingOccurrences(of: "_", with: " ")
            ?? "pending"
        pmTreatment = "PM-requested ad hoc delegation. Follow-through delivery: \(delivery)."
    case .delegation:
        pmTreatment = linkedDelegation?.status == .issued
            ? "Open PM delegation context."
            : "Recorded for PM traceability without owner action."
    }

    return PMInboxRecentAnalystActivityDetailPresentation(
        analystTitle: item.analystTitle,
        activityType: item.kind.rawValue,
        headline: item.headline,
        summary: item.summary,
        conclusion: conclusion,
        pmTreatment: pmTreatment,
        nextStep: nextStep,
        supportingContext: supportingContext,
        sourceTruth: makeAnalystSourceTruthPresentation(
            memo: linkedMemo,
            linkedEvidenceBundle: linkedEvidenceBundle,
            fallbackEvidenceReferences: linkedReport?.evidenceReferenceSummary ?? []
        ),
        linkedStandingReportID: item.linkedStandingReportID,
        linkedMemoPresentation: linkedMemo.map(makeAnalystMemoReadablePresentation),
        executionTruth: makePMInboxAnalystExecutionTruthPresentation(
            item: item,
            linkedReport: linkedReport,
            linkedMemo: linkedMemo,
            linkedDelegation: linkedDelegation
        )
    )
}

func makePMInboxRecentNewsReviewDetailPresentation(
    decision: PMDecisionRecord,
    linkedTask: AnalystTask?,
    linkedMemo: AnalystMemo?,
    linkedEvidenceBundle: AnalystEvidenceBundle?,
    linkedDelegation: PMDelegationRecord?,
    positions: [PositionRow],
    watchlistSymbols: [String],
    strategyBrief: PortfolioStrategyBrief?,
    linkedStandingReport: AnalystStandingReport? = nil,
    rssFeeds: [RSSFeed] = []
) -> PMInboxRecentNewsReviewDetailPresentation {
    let wakeUp = makeRecentNewsWakeUpPresentation(
        decision: decision,
        linkedTask: linkedTask,
        linkedMemo: linkedMemo,
        positions: positions,
        watchlistSymbols: watchlistSymbols,
        strategyBrief: strategyBrief
    )
    let memoPresentation = linkedMemo.map(makeAnalystMemoReadablePresentation)
    let sourceTruth = makeAnalystSourceTruthPresentation(
        memo: linkedMemo,
        linkedEvidenceBundle: linkedEvidenceBundle
    )
    let materialDevelopments = makeRecentNewsMaterialDevelopments(
        linkedEvidenceBundle: linkedEvidenceBundle,
        wakeUp: wakeUp,
        linkedMemo: linkedMemo,
        decision: decision,
        rssFeeds: rssFeeds
    )
    let supplementalSourcesReviewed = makeRecentNewsSupplementalSourcesReviewed(
        linkedEvidenceBundle: linkedEvidenceBundle
    )
    let executionTruth = makePMInboxAnalystExecutionTruthPresentation(
        item: PMInboxRecentAnalystActivityItem(
            id: "recent-news:\(decision.decisionId)",
            kind: linkedMemo == nil ? .delegation : .analystMemo,
            analystTitle: recentNewsStandingAnalystTitle,
            timestamp: decision.updatedAt,
            headline: linkedMemo?.title ?? decision.title,
            summary: linkedMemo?.executiveSummary ?? decision.summary,
            linkedStandingReportID: linkedStandingReport?.reportId,
            linkedMemoID: linkedMemo?.memoId,
            linkedDelegationID: linkedDelegation?.delegationId
        ),
        linkedReport: linkedStandingReport,
        linkedMemo: linkedMemo,
        linkedDelegation: linkedDelegation
    )

    return PMInboxRecentNewsReviewDetailPresentation(
        analystFindingSummary: firstNonEmptyPMInboxText([
            wakeUp.whatHappened,
            memoPresentation?.executiveSummary,
            decision.summary
        ]) ?? decision.summary,
        analystMaterialDevelopments: materialDevelopments,
        analystWhyItMatters: firstNonEmptyPMInboxText([
            wakeUp.whyItMatters,
            memoPresentation?.currentView,
            decision.summary
        ]) ?? decision.summary,
        analystCurrentView: firstNonEmptyPMInboxText([
            memoPresentation?.currentView,
            wakeUp.strategyRelevance,
            wakeUp.whyItMatters
        ]) ?? wakeUp.whyItMatters,
        analystMaterialSourceSummary: firstNonEmptyPMInboxText([
            sourceTruth?.primarySources.first,
            sourceTruth?.summary
        ]),
        analystSupplementalSourcesReviewed: supplementalSourcesReviewed,
        analystRecommendedNextStep: firstNonEmptyPMInboxText([
            memoPresentation?.recommendedNextStep,
            wakeUp.recommendedNextStep
        ]) ?? wakeUp.recommendedNextStep,
        analystUncertaintySummary: firstNonEmptyPMInboxText([
            linkedMemo?.uncertaintySummary
        ]),
        sourceTruth: sourceTruth,
        executionTruth: executionTruth,
        affectedHoldings: wakeUp.affectedHoldings,
        affectedWatchlistOnly: wakeUp.affectedWatchlistOnly
    )
}

private func makeRecentNewsMaterialDevelopments(
    linkedEvidenceBundle: AnalystEvidenceBundle?,
    wakeUp: RecentNewsWakeUpPresentation,
    linkedMemo: AnalystMemo?,
    decision: PMDecisionRecord,
    rssFeeds: [RSSFeed]
) -> [String] {
    let appNewsTitles = linkedEvidenceBundle?.refs
        .filter { $0.sourceKind == .appNews }
        .map { recentNewsMaterialDevelopmentLine(for: $0, rssFeeds: rssFeeds) }
        .filter { $0.isEmpty == false } ?? []

    let fallbackSummary = firstNonEmptyPMInboxText([
        wakeUp.whatHappened,
        linkedMemo?.executiveSummary,
        decision.summary
    ])

    let combined = appNewsTitles.isEmpty ? [fallbackSummary].compactMap { $0 } : appNewsTitles
    return Array(combined.prefix(3))
}

private func makeRecentNewsSupplementalSourcesReviewed(
    linkedEvidenceBundle: AnalystEvidenceBundle?
) -> [String] {
    guard let linkedEvidenceBundle else {
        return []
    }

    var labels: [String] = []
    for ref in linkedEvidenceBundle.refs where ref.sourceKind == .web {
        let label = recentNewsReviewedSourceLabel(for: ref)
        if label.isEmpty == false && labels.contains(label) == false {
            labels.append(label)
        }
    }

    for ref in linkedEvidenceBundle.refs where ref.sourceKind == .manualNote {
        for label in recentNewsPlannedSupplementalSources(from: ref) where labels.contains(label) == false {
            labels.append(label)
        }
    }

    return Array(labels.prefix(4))
}

private func recentNewsReviewedSourceLabel(for ref: AnalystEvidenceRef) -> String {
    if let host = ref.url.flatMap(URL.init(string:))?.host?.trimmingCharacters(in: .whitespacesAndNewlines),
       host.isEmpty == false {
        return recentNewsReadableHostLabel(host)
    }

    let preferred = ref.sourceIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if preferred.isEmpty == false {
        if preferred.hasPrefix("planned-source-") || preferred.hasPrefix("research-candidate-") {
            return recentNewsReadableHostLabel(preferred)
        }
        return recentNewsReadableSourceIdentifier(preferred)
    }

    return ref.title.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func recentNewsMaterialDevelopmentLine(
    for ref: AnalystEvidenceRef,
    rssFeeds: [RSSFeed]
) -> String {
    let title = ref.title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard title.isEmpty == false else {
        return ""
    }

    let source = recentNewsReadableSourceLabel(
        sourceIdentifier: ref.sourceIdentifier,
        urlString: ref.url,
        title: ref.title,
        rssFeeds: rssFeeds
    )
    guard source.isEmpty == false else {
        return title
    }
    return "\(title) (\(source))"
}

private func recentNewsReadableSourceLabel(
    sourceIdentifier: String?,
    urlString: String?,
    title: String,
    rssFeeds: [RSSFeed]
) -> String {
    let identifier = sourceIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if identifier.isEmpty == false {
        switch identifier {
        case "alpaca_news":
            return "Alpaca News"
        case "sec_edgar":
            return "SEC EDGAR"
        default:
            if identifier.hasPrefix("rss_") {
                if let feed = rssFeeds.first(where: {
                    normalizedRSSSourceIdentifier(forFeedName: $0.name) == identifier
                }) {
                    return feed.name
                }
                return recentNewsReadableSourceIdentifier(identifier)
            }
        }
    }

    if let host = urlString.flatMap(URL.init(string:))?.host?.trimmingCharacters(in: .whitespacesAndNewlines),
       host.isEmpty == false {
        return recentNewsReadableHostLabel(host)
    }

    return recentNewsReadableSourceIdentifier(title)
}

private func recentNewsReadableSourceIdentifier(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty == false else {
        return ""
    }

    let lowered = trimmed.lowercased()
    if lowered == "axios" || lowered.contains("axios.com") {
        return "Axios"
    }
    if lowered.contains("theinformation.com") || lowered == "the information" {
        return "The Information"
    }
    if lowered.contains("marketwatch") {
        return "MarketWatch"
    }
    if lowered.contains("how_to_geek") || lowered.contains("how-to-geek") {
        return "How-To Geek"
    }
    if lowered.contains("nyse") {
        return "NYSE"
    }
    if lowered.contains("cmegroup") {
        return "CME Group"
    }
    if lowered.contains("cftc") {
        return "CFTC"
    }

    return trimmed
        .replacingOccurrences(of: "planned-source-source-", with: "")
        .replacingOccurrences(of: "rss_", with: "")
        .replacingOccurrences(of: "www.", with: "")
        .replacingOccurrences(of: "_", with: " ")
        .split(separator: " ")
        .map { $0.capitalized }
        .joined(separator: " ")
}

private func recentNewsReadableHostLabel(_ host: String) -> String {
    let normalized = host
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .replacingOccurrences(of: "www.", with: "")

    switch normalized {
    case "axios.com":
        return "Axios"
    case "theinformation.com":
        return "The Information"
    case "nyse.com":
        return "NYSE"
    case "cmegroup.com":
        return "CME Group"
    case "cftc.gov":
        return "CFTC"
    case "marketwatch.com":
        return "MarketWatch"
    case "howtogeek.com":
        return "How-To Geek"
    default:
        return normalized
    }
}

private func recentNewsPlannedSupplementalSources(from ref: AnalystEvidenceRef) -> [String] {
    guard ref.sourceIdentifier == "missing_information_research_plan",
          let summary = ref.summary,
          let range = summary.range(of: "Targeted public sources: ") else {
        return []
    }

    let trailing = String(summary[range.upperBound...])
    let targetBlock = trailing.components(separatedBy: ". Source gaps:").first ?? trailing
    let candidates = targetBlock
        .split(separator: "|")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { $0.isEmpty == false && $0 != "no public web targets selected" }

    return candidates.compactMap { candidate in
        if let host = URL(string: candidate)?.host {
            return recentNewsReadableHostLabel(host)
        }
        return recentNewsReadableSourceIdentifier(candidate)
    }
}

func makePMInboxRecentNewsReviewSummaryPresentation(
    detail: PMInboxRecentNewsReviewDetailPresentation,
    pmTreatmentSummary: String,
    affectedNames: String?,
    nextStep: String?
) -> PMInboxRecentNewsReviewSummaryPresentation {
    PMInboxRecentNewsReviewSummaryPresentation(
        analystSummary: detail.analystFindingSummary,
        analystSupportSummary: detail.analystMaterialSourceSummary,
        analystRuntimeSummary: detail.executionTruth.executionUsedSummary,
        pmTreatmentSummary: pmTreatmentSummary,
        affectedNames: affectedNames,
        nextStep: nextStep
    )
}

func makePMInboxAnalystExecutionTruthPresentation(
    item: PMInboxRecentAnalystActivityItem,
    linkedReport: AnalystStandingReport?,
    linkedMemo: AnalystMemo?,
    linkedDelegation: PMDelegationRecord?
) -> PMInboxExecutionTruthPresentation {
    if let runtimeProvenance = linkedMemo?.runtimeProvenance ?? linkedDelegation?.lastRuntimeProvenance {
        let actualRuntime = runtimeProvenance.actualRuntimeIdentifier
        let fallbackReason = analystFallbackExecutionReasonSummary(linkedDelegation?.lastLaunch?.lastIssueSummary)
        let summary: String
        if actualRuntime.hasPrefix("openai_responses[") {
            summary = "This analyst artifact used the OpenAI Responses API-backed worker path in the recorded run."
        } else if actualRuntime.hasPrefix("deterministic_local_fallback") {
            let fallbackLead = fallbackReason ?? "This analyst artifact fell back to the app's local deterministic synthesis path instead of completing through a live OpenAI API call."
            summary = "\(fallbackLead) The app is surfacing the recorded fallback truth instead of implying successful API usage."
        } else {
            summary = "This analyst artifact stayed on the app's local deterministic synthesis path. No live OpenAI API call is recorded for this run."
        }
        return PMInboxExecutionTruthPresentation(
            requestedOrConfiguredSummary: runtimeProvenance.intendedPolicy.map(analystRequestedRuntimeText) ?? "Worker fallback",
            executionUsedSummary: analystExecutionUsedRuntimeText(runtimeProvenance),
            summary: summary
        )
    }

    if let runtimeProvenance = linkedReport?.runtimeProvenance {
        let actualRuntime = runtimeProvenance.actualRuntimeIdentifier
        let summary: String
        if actualRuntime.hasPrefix("openai_responses[") {
            summary = "This standing report records worker-backed OpenAI Responses execution for the linked analyst run."
        } else if actualRuntime.hasPrefix("deterministic_local_fallback") {
            summary = "This standing report records a local synthesis fallback rather than a live OpenAI API call for the linked analyst run."
        } else {
            summary = "This standing report records bounded local synthesis rather than a live OpenAI API call for the linked analyst run."
        }
        return PMInboxExecutionTruthPresentation(
            requestedOrConfiguredSummary: runtimeProvenance.intendedPolicy.map(analystRequestedRuntimeText) ?? "Worker fallback",
            executionUsedSummary: analystExecutionUsedRuntimeText(runtimeProvenance),
            summary: summary
        )
    }

    if item.kind == .standingReport || linkedReport != nil {
        return PMInboxExecutionTruthPresentation(
            requestedOrConfiguredSummary: "No worker runtime recorded",
            executionUsedSummary: "App-owned standing report path",
            summary: "This standing report does not carry worker runtime provenance. In the covered PM Inbox path, treat it as app-owned standing-report output rather than a proven OpenAI API call."
        )
    }

    return PMInboxExecutionTruthPresentation(
        requestedOrConfiguredSummary: "No worker runtime recorded",
        executionUsedSummary: "No runtime provenance recorded",
        summary: "This analyst activity does not currently carry runtime provenance, so the app should not imply model-backed execution for it."
    )
}

func analystFallbackExecutionReasonSummary(_ issueSummary: String?) -> String? {
    guard let issueSummary = firstNonEmptyPMInboxText([issueSummary]) else {
        return nil
    }
    if issueSummary == "openai_api_key_missing" {
        return "This analyst artifact fell back because no OpenAI API key was available in the app Keychain for the recorded run."
    }
    if issueSummary == "openai_unexpected_error" {
        return "This analyst artifact fell back after the OpenAI API attempt returned an unexpected error."
    }
    return "This analyst artifact fell back after the recorded OpenAI path issue: \(issueSummary)."
}

func makePMInboxPMExecutionTruthPresentation(
    runtimeSettings: PMRuntimeSettings?,
    runtimeProvenance: PMRuntimeProvenance? = nil
) -> PMInboxExecutionTruthPresentation {
    if let runtimeProvenance {
        let summary: String
        if runtimeProvenance.usedOpenAI {
            summary = "This PM artifact records real OpenAI Responses execution for the covered reasoning path."
        } else if runtimeProvenance.synthesisStatus == "fallback_missing_openai_key" {
            summary = "This PM artifact fell back to bounded deterministic PM logic because no OpenAI API key was available in the app Keychain for the recorded run."
        } else if let issue = firstNonEmptyPMInboxText([runtimeProvenance.synthesisIssueSummary]) {
            summary = "This PM artifact fell back to bounded deterministic PM logic after the recorded OpenAI path issue: \(issue)."
        } else {
            summary = "This PM artifact used bounded deterministic PM fallback logic rather than a proven OpenAI Responses execution."
        }
        return PMInboxExecutionTruthPresentation(
            requestedOrConfiguredSummary: pmRequestedRuntimeText(runtimeProvenance),
            executionUsedSummary: pmExecutionUsedRuntimeText(runtimeProvenance),
            summary: summary
        )
    }

    let configuredSummary: String
    if let runtimeSettings {
        configuredSummary = "\(runtimeSettings.runtimeIdentifier) (\(runtimeSettings.reasoningMode?.rawValue ?? "default") reasoning)"
    } else {
        configuredSummary = "No PM runtime preference recorded"
    }

    let operabilitySummary = makeRuntimeOperabilityPresentation(pmRuntimeSettings: runtimeSettings)?
        .ownerSurfaceSummary
        ?? "No PM runtime validation record is available right now."

    return PMInboxExecutionTruthPresentation(
        requestedOrConfiguredSummary: configuredSummary,
        executionUsedSummary: "App-owned deterministic PM review logic",
        summary: "\(operabilitySummary) The covered PM review and PM Inbox decision path still uses app-owned deterministic PM logic, so this surface does not prove an OpenAI API request or any ChatGPT-account-backed runtime."
    )
}

func makeRecentPMDecisionsForReview(
    decisions: [PMDecisionRecord],
    recentAnalystActivityItems: [PMInboxRecentAnalystActivityItem],
    reports: [AnalystStandingReport],
    memos: [AnalystMemo],
    delegations: [PMDelegationRecord],
    limit: Int = 5
) -> [PMDecisionRecord] {
    let sortedDecisions = sortRecentPMDecisionsForReview(decisions)
    guard recentAnalystActivityItems.isEmpty == false else {
        return Array(sortedDecisions.prefix(limit))
    }

    let reportsByID = Dictionary(uniqueKeysWithValues: reports.map { ($0.reportId, $0) })
    let memosByID = Dictionary(uniqueKeysWithValues: memos.map { ($0.memoId, $0) })
    let delegationsByID = Dictionary(uniqueKeysWithValues: delegations.map { ($0.delegationId, $0) })
    let cutoff = recentAnalystActivityItems.map(\.timestamp).min() ?? .distantFuture

    let recentDelegationIDs = Set(recentAnalystActivityItems.compactMap(\.linkedDelegationID))
    let recentTaskIDs = Set(recentAnalystActivityItems.compactMap { item in
        item.linkedDelegationID.flatMap { delegationsByID[$0]?.taskId }
    })
    let recentStandingReportIDs = Set(recentAnalystActivityItems.compactMap(\.linkedStandingReportID))
    let recentCharterIDs = Set(recentAnalystActivityItems.compactMap { item in
        if let reportID = item.linkedStandingReportID,
           let report = reportsByID[reportID] {
            return report.charterId
        }
        if let memoID = item.linkedMemoID,
           let memo = memosByID[memoID] {
            return memo.charterId
        }
        if let delegationID = item.linkedDelegationID,
           let delegation = delegationsByID[delegationID] {
            return delegation.charterId
        }
        return nil
    })

    let hasLinkageScope = recentDelegationIDs.isEmpty == false
        || recentTaskIDs.isEmpty == false
        || recentStandingReportIDs.isEmpty == false
        || recentCharterIDs.isEmpty == false

    let timeAligned = sortedDecisions.filter { $0.updatedAt >= cutoff }
    let linkedAndTimeAligned = timeAligned.filter { decision in
        let decisionStandingReportIDs = Set(standingReportIDs(for: decision))
        if decisionStandingReportIDs.isEmpty == false,
           decisionStandingReportIDs.isDisjoint(with: recentStandingReportIDs) == false {
            return true
        }
        if recentDelegationIDs.contains(decision.delegationId ?? "") {
            return true
        }
        if recentTaskIDs.contains(decision.taskId ?? "") {
            return true
        }
        if recentCharterIDs.contains(decision.charterId ?? "") {
            return true
        }
        return false
    }

    let scopedDecisions: [PMDecisionRecord]
    if hasLinkageScope && linkedAndTimeAligned.isEmpty == false {
        let linkedDecisionIDs = Set(linkedAndTimeAligned.map(\.decisionId))
        let unlinkedTimeAligned = timeAligned.filter { decision in
            guard linkedDecisionIDs.contains(decision.decisionId) == false else {
                return false
            }
            let hasExplicitLinkage = firstNonEmptyPMInboxText([
                standingReportIDs(for: decision).isEmpty ? nil : standingReportIDs(for: decision).joined(separator: "|"),
                decision.charterId,
                decision.taskId,
                decision.delegationId
            ]) != nil
            return hasExplicitLinkage == false
        }
        scopedDecisions = linkedAndTimeAligned + unlinkedTimeAligned
    } else {
        scopedDecisions = timeAligned
    }

    return Array(sortRecentPMDecisionsForReview(scopedDecisions).prefix(limit))
}

private func sortRecentPMDecisionsForReview(
    _ decisions: [PMDecisionRecord]
) -> [PMDecisionRecord] {
    decisions.sorted { lhs, rhs in
        if lhs.updatedAt == rhs.updatedAt {
            if lhs.createdAt == rhs.createdAt {
                return lhs.decisionId < rhs.decisionId
            }
            return lhs.createdAt > rhs.createdAt
        }
        return lhs.updatedAt > rhs.updatedAt
    }
}

struct PMInboxDecisionCorrelationPresentation: Equatable {
    let decisionTimestamp: Date
    let relatedActivityDescription: String?
    let relatedActivityTimestamp: Date?
}

struct PMInboxOwnerReachThresholdPresentation: Equatable {
    let thresholdTitle: String
    let thresholdSummary: String
    let initiativeTitle: String
    let initiativeSummary: String
    let routingTitle: String
    let routingSummary: String
}

private func linkedTaskForPMInboxDecision(
    _ decision: PMDecisionRecord,
    tasks: [AnalystTask],
    delegations: [PMDelegationRecord]
) -> AnalystTask? {
    let linkedDelegation = delegations.first(where: { $0.delegationId == decision.delegationId })
    return tasks.first(where: { $0.taskId == decision.taskId || $0.taskId == linkedDelegation?.taskId })
}

private func isRecentNewsDecisionForPMInbox(
    _ decision: PMDecisionRecord,
    tasks: [AnalystTask],
    delegations: [PMDelegationRecord]
) -> Bool {
    if decision.charterId == recentNewsStandingAnalystCharterID {
        return true
    }
    if let linkedDelegation = delegations.first(where: { $0.delegationId == decision.delegationId }),
       isRecentNewsAnalystContext(
           analystID: linkedDelegation.analystId,
           charterID: linkedDelegation.charterId,
           title: linkedDelegation.title
       ) {
        return true
    }
    let linkedTask = linkedTaskForPMInboxDecision(
        decision,
        tasks: tasks,
        delegations: delegations
    )
    if linkedTask?.tags.contains("recent-news-analyst") == true {
        return true
    }
    let title = decision.title.lowercased()
    if title.contains("recent news analyst escalation") || title.contains("recent news") {
        return true
    }
    return (decision.taskId ?? "").contains("recent-news-task")
        || (decision.delegationId ?? "").contains("recent-news-delegation")
}

func makeRecentNewsReviewDecisionsForPMInbox(
    decisions: [PMDecisionRecord],
    tasks: [AnalystTask],
    delegations: [PMDelegationRecord],
    limit: Int = 3
) -> [PMDecisionRecord] {
    Array(
        sortRecentPMDecisionsForReview(
            decisions.filter {
                isRecentNewsDecisionForPMInbox(
                    $0,
                    tasks: tasks,
                    delegations: delegations
                )
            }
        )
        .prefix(limit)
    )
}

func makePMInboxDecisionCorrelationPresentation(
    decision: PMDecisionRecord,
    recentAnalystActivityItems: [PMInboxRecentAnalystActivityItem],
    reports: [AnalystStandingReport],
    memos: [AnalystMemo],
    delegations: [PMDelegationRecord]
) -> PMInboxDecisionCorrelationPresentation {
    let reportsByID = Dictionary(uniqueKeysWithValues: reports.map { ($0.reportId, $0) })
    let memosByID = Dictionary(uniqueKeysWithValues: memos.map { ($0.memoId, $0) })
    let delegationsByID = Dictionary(uniqueKeysWithValues: delegations.map { ($0.delegationId, $0) })
    let explicitlyLinkedReportIDs = Set(standingReportIDs(for: decision))

    let explicitMatches = recentAnalystActivityItems
        .filter { item in
            guard let reportID = item.linkedStandingReportID else {
                return false
            }
            return explicitlyLinkedReportIDs.contains(reportID)
        }
    let bestMatch = (explicitMatches.isEmpty ? recentAnalystActivityItems : explicitMatches)
        .filter { item in
            if explicitlyLinkedReportIDs.isEmpty == false {
                return item.linkedStandingReportID.map(explicitlyLinkedReportIDs.contains) == true
            }
            if let decisionDelegationID = decision.delegationId,
               decisionDelegationID == item.linkedDelegationID {
                return true
            }
            if let delegationID = item.linkedDelegationID,
               let taskID = delegationsByID[delegationID]?.taskId,
               let decisionTaskID = decision.taskId,
               decisionTaskID == taskID {
                return true
            }
            if let reportID = item.linkedStandingReportID,
               let charterID = reportsByID[reportID]?.charterId,
               let decisionCharterID = decision.charterId,
               decisionCharterID == charterID {
                return true
            }
            if let memoID = item.linkedMemoID,
               let charterID = memosByID[memoID]?.charterId,
               let decisionCharterID = decision.charterId,
               decisionCharterID == charterID {
                return true
            }
            if let delegationID = item.linkedDelegationID,
               let charterID = delegationsByID[delegationID]?.charterId,
               let decisionCharterID = decision.charterId,
               decisionCharterID == charterID {
                return true
            }
            return false
        }
        .max { lhs, rhs in
            if lhs.timestamp == rhs.timestamp {
                return lhs.id > rhs.id
            }
            return lhs.timestamp < rhs.timestamp
        }
    let relatedDescription: String?
    if explicitMatches.count > 1 {
        relatedDescription = "Following \(explicitMatches.count) reviewed standing reports"
    } else {
        relatedDescription = bestMatch.map { item in
            "Following \(item.analystTitle) \(item.kind.rawValue.lowercased()): \(item.headline)"
        }
    }
    let relatedTimestamp = (explicitMatches.isEmpty ? [bestMatch].compactMap { $0 } : explicitMatches)
        .map(\.timestamp)
        .max()

    return PMInboxDecisionCorrelationPresentation(
        decisionTimestamp: decision.updatedAt,
        relatedActivityDescription: relatedDescription,
        relatedActivityTimestamp: relatedTimestamp
    )
}

private func standingReportIDs(for decision: PMDecisionRecord) -> [String] {
    var ids: [String] = []
    if let primaryStandingReportID = decision.primaryStandingReportId,
       primaryStandingReportID.isEmpty == false {
        ids.append(primaryStandingReportID)
    }
    if let standingReportIDs = decision.standingReportIds {
        ids.append(contentsOf: standingReportIDs.filter { $0.isEmpty == false })
    }

    var seen: Set<String> = []
    return ids.filter { seen.insert($0).inserted }
}

func makePMInboxOwnerReachThresholdPresentation(
    memo: PMDecisionMemoPresentation
) -> PMInboxOwnerReachThresholdPresentation {
    let thresholdTitle: String
    let thresholdSummary: String

    switch memo.initiativePosture {
    case .stayQuiet:
        thresholdTitle = "Quiet / non-material"
        thresholdSummary = "PM kept this in background handling and traceability only. No independent owner reach-out is justified from this event as-is."
    case .summarizeAndInform:
        thresholdTitle = "Worth monitoring"
        thresholdSummary = "PM judged this as owner-relevant context worth surfacing, but not as a decision-ready ask."
    case .clarifyFirst, .analystBenchFirst:
        thresholdTitle = "PM follow-up warranted"
        thresholdSummary = "PM judged that more clarification or bench work should happen before escalating this as a stronger owner-facing recommendation."
    case .ownerDecisionRequired:
        thresholdTitle = "Owner-relevant strategic concern"
        thresholdSummary = "PM judged this as mature enough to justify a direct owner-facing decision or explicit owner-visible ask."
    }

    return PMInboxOwnerReachThresholdPresentation(
        thresholdTitle: thresholdTitle,
        thresholdSummary: thresholdSummary,
        initiativeTitle: pmInboxInitiativePostureLabel(memo.initiativePosture),
        initiativeSummary: memo.initiativeSummary,
        routingTitle: pmInboxActionabilityCategoryLabel(memo.coherence.actionabilityCategory),
        routingSummary: firstNonEmptyPMInboxText([
            memo.coherence.pmInboxSummary,
            memo.closure.pmInboxSummary
        ]) ?? memo.closure.pmInboxSummary
    )
}

private func pmInboxInitiativePostureLabel(
    _ posture: PMInitiativePosture
) -> String {
    switch posture {
    case .clarifyFirst:
        return "Clarify first"
    case .analystBenchFirst:
        return "Analyst bench first"
    case .summarizeAndInform:
        return "Summarize and inform"
    case .ownerDecisionRequired:
        return "Owner decision required"
    case .stayQuiet:
        return "Stay quiet"
    }
}

private func pmInboxActionabilityCategoryLabel(
    _ category: PMEventActionabilityCategory
) -> String {
    switch category {
    case .clarification:
        return "Clarification"
    case .ownerInformational:
        return "Owner informational"
    case .ownerDecisionRequired:
        return "Owner decision required"
    case .benchInternal:
        return "Background PM handling"
    case .traceabilityOnly:
        return "Traceability only"
    }
}

private struct PMInboxRecentAnalystActivityRow: View {
    let item: PMInboxRecentAnalystActivityItem
    let timestampLabel: String
    let isSelected: Bool
    let openAction: () -> Void

    var body: some View {
        Button(action: openAction) {
            rowBody
        }
        .buttonStyle(.plain)
    }

    private var rowBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.analystTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(timestampLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text("\(item.kind.rawValue) • \(item.headline)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text(item.summary)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct PMInboxRecentNewsReviewRow: View {
    let decision: PMDecisionRecord
    let timestampLabel: String
    let analystSummary: String
    let analystSupport: String?
    let analystRuntimeSummary: String
    let pmTreatment: String
    let affectedNames: String?
    let nextStep: String?
    let isSelected: Bool
    let openAction: () -> Void

    var body: some View {
        Button(action: openAction) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(recentNewsStandingAnalystTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(timestampLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    RecentNewsWakeUpBadge()
                    Text(decision.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(analystSummary)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let analystSupport, analystSupport.isEmpty == false {
                    Text("Analyst support: \(analystSupport)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text("Analyst runtime: \(analystRuntimeSummary)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("PM treatment: \(pmTreatment)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let affectedNames, affectedNames.isEmpty == false {
                    Text(affectedNames)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let nextStep, nextStep.isEmpty == false {
                    Text(nextStep)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

private func makePMInboxReviewProjection(
    approvalRequests: [PMApprovalRequest],
    decisions: [PMDecisionRecord],
    executionRoutingAssessmentsByApprovalRequestID: [String: PMExecutionRoutingAssessment],
    standingReports: [AnalystStandingReport],
    memos: [AnalystMemo],
    tasks: [AnalystTask],
    charters: [AnalystCharter],
    delegations: [PMDelegationRecord],
    communicationSessions: [PMCommunicationSession],
    contextPack: PMContextPack?
) -> PMInboxReviewProjection {
    let pendingApprovalRequests = makeOwnerActionableApprovalRequests(
        approvalRequests: approvalRequests,
        decisions: decisions
    )
    let approvalRequestsForReview = if pendingApprovalRequests.isEmpty == false {
        pendingApprovalRequests
    } else {
        Array(
            approvalRequests
                .filter { request in
                    isExercisePMApprovalRequest(request) == false
                        && isBackgroundStandingReviewApprovalRequest(
                            request,
                            decisions: decisions,
                            executionAssessment: executionRoutingAssessmentsByApprovalRequestID[request.approvalRequestId]
                        ) == false
                }
                .prefix(PMInboxProjectionBudget.approvalRequestsForReview)
        )
    }

    let standingReportSummaries = makeStandingAnalystReportReviewSummaryPresentations(
        reports: standingReports,
        memos: memos,
        charters: charters
    )
    let recentAnalystActivityScopeItems = makePMInboxRecentAnalystActivityItems(
        standingReportSummaries: standingReportSummaries,
        reports: standingReports,
        memos: memos,
        charters: charters,
        delegations: delegations,
        includeRecentNews: false,
        limit: PMInboxProjectionBudget.recentAnalystActivityScope
    )
    let recentAnalystActivityItems = Array(
        recentAnalystActivityScopeItems.prefix(PMInboxProjectionBudget.recentAnalystActivityVisible)
    )
    let visibleDecisions = Array(
        decisions.filter { decision in
            isExercisePMDecision(decision) == false
        }
    )
    let recentNewsDecisionsForReview = makeRecentNewsReviewDecisionsForPMInbox(
        decisions: visibleDecisions,
        tasks: tasks,
        delegations: delegations
    )
    let recentNewsDecisionIDs = Set(recentNewsDecisionsForReview.map(\.decisionId))
    let recentDecisionsForReview = makeRecentPMDecisionsForReview(
        decisions: visibleDecisions.filter { recentNewsDecisionIDs.contains($0.decisionId) == false },
        recentAnalystActivityItems: recentAnalystActivityScopeItems,
        reports: standingReports,
        memos: memos,
        delegations: delegations
    )
    let communicationSessionsForDisplay = communicationSessions
        .filter { isExercisePMCommunicationSession($0) == false }
        .sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.sessionId < rhs.sessionId
            }
            return lhs.updatedAt > rhs.updatedAt
        }
        .prefix(PMInboxProjectionBudget.communicationSessionsForDisplay)
    let pmBackgroundReviewNotebookEntries = contextPack?.recentNotebookEntries.filter { entry in
        entry.tags.contains("pm_background_review")
            && entry.tags.contains("standing_review_cycle")
    }.prefix(PMInboxProjectionBudget.backgroundReviewNotebookEntries) ?? []
    return PMInboxReviewProjection(
        approvalRequestsForReview: approvalRequestsForReview,
        recentNewsDecisionsForReview: recentNewsDecisionsForReview,
        recentDecisionsForReview: recentDecisionsForReview,
        recentAnalystActivityScopeItems: Array(recentAnalystActivityScopeItems),
        recentAnalystActivityItems: recentAnalystActivityItems,
        communicationSessionsForDisplay: Array(communicationSessionsForDisplay),
        pmBackgroundReviewNotebookEntries: Array(pmBackgroundReviewNotebookEntries)
    )
}

private struct AnalystSignalBadge: View {
    var body: some View {
        Text("Analyst Signal")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.blue.opacity(0.15))
            .clipShape(Capsule())
    }
}

private struct AnalystSignalLineageSection: View {
    let presentation: SignalLineageReadablePresentation

    var body: some View {
        GroupBox("Analyst Provenance") {
            VStack(alignment: .leading, spacing: 10) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow { Text("Analyst"); Text(presentation.analystLabel) }
                    GridRow { Text("Charter"); Text(presentation.charterLabel) }
                    GridRow { Text("Task"); Text(presentation.taskLabel) }
                    GridRow { Text("Finding"); Text(presentation.findingLabel) }
                    GridRow { Text("Evidence"); Text(presentation.evidenceLabel) }
                }

                if presentation.technicalRefs.isEmpty == false {
                    DisclosureGroup("Technical IDs") {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                            ForEach(presentation.technicalRefs) { ref in
                                GridRow {
                                    Text(ref.label)
                                    Text(ref.value)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AnalystProposalBadge: View {
    var body: some View {
        Text("Analyst Proposal")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.green.opacity(0.15))
            .clipShape(Capsule())
    }
}

private struct AnalystProposalLineageSection: View {
    let lineage: AnalystProposalLineage

    var body: some View {
        GroupBox("Analyst Proposal Provenance") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow { Text("Analyst"); Text(lineage.analystId ?? "-") }
                GridRow { Text("Charter"); Text(lineage.charterId ?? "-") }
                GridRow { Text("Task"); Text(lineage.taskId ?? "-") }
                GridRow { Text("Finding"); Text(lineage.originatingFindingId ?? "-") }
                GridRow { Text("Evidence Bundle"); Text(lineage.sourceEvidenceBundleId ?? "-") }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct PMDelegationStatusBadge: View {
    let label: String
    let color: Color

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.15))
            .clipShape(Capsule())
    }
}

private func pmLaunchHealthColor(_ health: PMDelegationLaunchHealth) -> Color {
    switch health {
    case .notLaunched:
        return .secondary
    case .healthy:
        return .green
    case .degradedExternalEvidence:
        return .orange
    case .failed:
        return .red
    }
}

private func pmWorkflowStateColor(_ state: PMDelegationWorkflowState) -> Color {
    switch state {
    case .noOutputsYet:
        return .secondary
    case .awaitingDownstreamReview:
        return .blue
    case .resolved:
        return .green
    case .canceled:
        return .red
    }
}

private func pmExecutionStateColor(_ state: PMDelegationExecutionState) -> Color {
    switch state {
    case .pendingLaunch:
        return .secondary
    case .running:
        return .blue
    case .progressing:
        return .green
    case .completed:
        return .green
    case .failed:
        return .red
    case .stale:
        return .orange
    case .canceled:
        return .red
    }
}

private struct TechnicalDetailsToggleButton: View {
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
            Label(
                isExpanded ? "Hide Details" : "Open Details",
                systemImage: isExpanded ? "chevron.up.circle" : "chevron.right.circle"
            )
            .font(.callout.weight(.semibold))
        }
        .buttonStyle(.bordered)
    }
}

private struct OwnerReadableFactLine: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }
}

private struct RecentNewsWakeUpBadge: View {
    var body: some View {
        Text("Recent News Analyst")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.orange.opacity(0.16))
            .clipShape(Capsule())
    }
}

private struct PortfolioRiskWakeUpBadge: View {
    var body: some View {
        Text("Portfolio Risk")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.red.opacity(0.14))
            .clipShape(Capsule())
    }
}

private struct RecentNewsAffectedNamesGroup: View {
    let affectedHoldings: [String]
    let affectedWatchlistOnly: [String]

    var body: some View {
        GroupBox("Affected Names") {
            VStack(alignment: .leading, spacing: 8) {
                if affectedHoldings.isEmpty == false {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Current Holdings")
                            .font(.subheadline.weight(.semibold))
                        Text(affectedHoldings.joined(separator: ", "))
                            .foregroundStyle(.secondary)
                    }
                }

                if affectedWatchlistOnly.isEmpty == false {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Watchlist Only")
                            .font(.subheadline.weight(.semibold))
                        Text(affectedWatchlistOnly.joined(separator: ", "))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AnalystBenchRoleBadge: View {
    let label: String
    let isOverlay: Bool

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background((isOverlay ? Color.orange : Color.blue).opacity(0.14))
            .clipShape(Capsule())
    }
}

private struct BenchRoutingSummaryCard: View {
    let presentation: PMBenchRoutingCandidatePresentation

    var body: some View {
        GroupBox("Selected Analyst Routing") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(presentation.title)
                            .font(.headline)
                        Text(presentation.analystId)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    AnalystBenchRoleBadge(
                        label: presentation.roleTitle,
                        isOverlay: presentation.roleTitle.contains("Overlay")
                    )
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Coverage")
                        .font(.subheadline.weight(.semibold))
                    Text(presentation.coverageSummary)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("When To Route Here")
                        .font(.subheadline.weight(.semibold))
                    Text(presentation.routingHint)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Shared Context Included")
                        .font(.subheadline.weight(.semibold))
                    Text(presentation.sharedContextSummary)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Prior Continuity")
                        .font(.subheadline.weight(.semibold))
                    Text(presentation.continuitySummary)
                        .foregroundStyle(.secondary)
                }

                if let followUpHint = presentation.followUpHint {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Cross-Analyst Follow-Up")
                            .font(.subheadline.weight(.semibold))
                        Text(followUpHint)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AnalystMemoSupportGroup: View {
    let memo: AnalystMemo
    let linkedFinding: AnalystFinding?
    let linkedEvidenceBundle: AnalystEvidenceBundle?
    let linkedSourceAccessSuggestions: [AnalystSourceAccessSuggestionRecord]
    let linkedStrategyImplication: AnalystStrategyImplicationRecord?
    let linkedStrategyFollowUpCandidates: [AnalystStrategyFollowUpCandidateRecord]
    let defaultStrategyImplicationPMID: String?
    let onSaveStrategyImplication: (AnalystStrategyImplicationRecord) async -> String?
    let onSaveStrategyFollowUpCandidate: (AnalystStrategyFollowUpCandidateRecord) async -> String?

    @State private var detailsExpanded = false

    private var presentation: AnalystMemoReadablePresentation {
        makeAnalystMemoReadablePresentation(memo)
    }

    private var researchTrustPresentation: AnalystResearchTrustReadablePresentation {
        makeAnalystResearchTrustReadablePresentation(
            memo: memo,
            linkedEvidenceBundle: linkedEvidenceBundle,
            relevantSourceSuggestions: linkedSourceAccessSuggestions
        )
    }

    var body: some View {
        GroupBox("Latest Analyst Memo") {
            VStack(alignment: .leading, spacing: 10) {
                Text(memo.title)
                    .font(.headline)

                if let requested = presentation.requestedModelSummary {
                    OwnerReadableFactLine(title: "Requested Model:", value: requested)
                }
                if let actual = presentation.executionUsedSummary {
                    OwnerReadableFactLine(title: "Execution Used:", value: actual)
                }

                Text(presentation.executiveSummary)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Current View")
                        .font(.subheadline.weight(.semibold))
                    Text(presentation.currentView)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Recommended Next Step")
                        .font(.subheadline.weight(.semibold))
                    Text(presentation.recommendedNextStep)
                        .foregroundStyle(.secondary)
                }

                OwnerReadableFactLine(title: "Confidence:", value: presentation.confidenceSummary)

                GroupBox("Research Coverage And Trust") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(researchTrustPresentation.postureSummary)

                        OwnerReadableFactLine(title: "Coverage:", value: researchTrustPresentation.coverageLabel)
                        OwnerReadableFactLine(title: "Outside Research:", value: researchTrustPresentation.outsideResearchLabel)
                        OwnerReadableFactLine(title: "Source Constraints:", value: researchTrustPresentation.sourceConstraintLabel)

                        if let outsideResearchSummary = researchTrustPresentation.outsideResearchSummary {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Outside Research Added")
                                    .font(.subheadline.weight(.semibold))
                                Text(outsideResearchSummary)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if let sourceConstraintSummary = researchTrustPresentation.sourceConstraintSummary {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Source Coverage Limits")
                                    .font(.subheadline.weight(.semibold))
                                Text(sourceConstraintSummary)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Text(researchTrustPresentation.boundaryNote)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                AnalystStrategyImplicationSupportGroup(
                    memo: memo,
                    linkedFinding: linkedFinding,
                    linkedEvidenceBundle: linkedEvidenceBundle,
                    linkedStrategyImplication: linkedStrategyImplication,
                    linkedStrategyFollowUpCandidates: linkedStrategyFollowUpCandidates,
                    defaultPMID: defaultStrategyImplicationPMID,
                    onSaveStrategyImplication: onSaveStrategyImplication,
                    onSaveStrategyFollowUpCandidate: onSaveStrategyFollowUpCandidate
                )

                TechnicalDetailsToggleButton(isExpanded: $detailsExpanded)

                if detailsExpanded {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(presentation.detailSections) { section in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(section.title)
                                    .font(.subheadline.weight(.semibold))
                                Text(section.body)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let linkedFinding {
                    DisclosureGroup("Linked Analyst Finding") {
                        AnalystFindingSupportGroup(
                            finding: linkedFinding,
                            linkedMemo: memo,
                            linkedEvidenceBundle: linkedEvidenceBundle
                        )
                        .padding(.top, 8)
                    }
                } else if let linkedEvidenceBundle {
                    DisclosureGroup("Linked Evidence Bundle") {
                        AnalystEvidenceBundleSupportGroup(bundle: linkedEvidenceBundle)
                            .padding(.top, 8)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AnalystStrategyImplicationSupportGroup: View {
    let memo: AnalystMemo
    let linkedFinding: AnalystFinding?
    let linkedEvidenceBundle: AnalystEvidenceBundle?
    let linkedStrategyImplication: AnalystStrategyImplicationRecord?
    let linkedStrategyFollowUpCandidates: [AnalystStrategyFollowUpCandidateRecord]
    let defaultPMID: String?
    let onSaveStrategyImplication: (AnalystStrategyImplicationRecord) async -> String?
    let onSaveStrategyFollowUpCandidate: (AnalystStrategyFollowUpCandidateRecord) async -> String?

    @State private var isEditing: Bool
    @State private var savedImplication: AnalystStrategyImplicationRecord?
    @State private var selectedKind: AnalystStrategyImplicationKind
    @State private var implicationSummaryDraft: String
    @State private var whyItMattersDraft: String
    @State private var candidateStrategyBriefRevisionDraft: String
    @State private var candidatePMFollowUpDraft: String
    @State private var saveError: String?
    @State private var isSaving = false
    @State private var followUpFeedback: String?
    @State private var followUpFeedbackIsError = false
    @State private var followUpSaveInFlight = false

    init(
        memo: AnalystMemo,
        linkedFinding: AnalystFinding?,
        linkedEvidenceBundle: AnalystEvidenceBundle?,
        linkedStrategyImplication: AnalystStrategyImplicationRecord?,
        linkedStrategyFollowUpCandidates: [AnalystStrategyFollowUpCandidateRecord],
        defaultPMID: String?,
        onSaveStrategyImplication: @escaping (AnalystStrategyImplicationRecord) async -> String?,
        onSaveStrategyFollowUpCandidate: @escaping (AnalystStrategyFollowUpCandidateRecord) async -> String?
    ) {
        self.memo = memo
        self.linkedFinding = linkedFinding
        self.linkedEvidenceBundle = linkedEvidenceBundle
        self.linkedStrategyImplication = linkedStrategyImplication
        self.linkedStrategyFollowUpCandidates = linkedStrategyFollowUpCandidates
        self.defaultPMID = defaultPMID
        self.onSaveStrategyImplication = onSaveStrategyImplication
        self.onSaveStrategyFollowUpCandidate = onSaveStrategyFollowUpCandidate

        _isEditing = State(initialValue: false)
        _savedImplication = State(initialValue: linkedStrategyImplication)
        _selectedKind = State(initialValue: linkedStrategyImplication?.implicationKind ?? .worthMonitoring)
        _implicationSummaryDraft = State(initialValue: linkedStrategyImplication?.implicationSummary ?? "")
        _whyItMattersDraft = State(initialValue: linkedStrategyImplication?.whyItMatters ?? "")
        _candidateStrategyBriefRevisionDraft = State(
            initialValue: linkedStrategyImplication?.candidateStrategyBriefRevisionNote ?? ""
        )
        _candidatePMFollowUpDraft = State(
            initialValue: linkedStrategyImplication?.candidatePMFollowUpSummary ?? ""
        )
    }

    private var currentImplication: AnalystStrategyImplicationRecord? {
        savedImplication ?? linkedStrategyImplication
    }

    private var presentation: AnalystStrategyImplicationReadablePresentation? {
        currentImplication.map(makeAnalystStrategyImplicationReadablePresentation)
    }

    private var trimmedImplicationSummaryDraft: String {
        implicationSummaryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedWhyItMattersDraft: String {
        whyItMattersDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var showCandidateStrategyBriefRevisionField: Bool {
        selectedKind == .candidateStrategyBriefRevision
    }

    private var showCandidatePMFollowUpField: Bool {
        selectedKind == .strategyFollowUpWarranted || selectedKind == .candidateInstructionOrMandateFollowUp
    }

    private var canSave: Bool {
        trimmedReadableText(defaultPMID) != nil
            && trimmedImplicationSummaryDraft.isEmpty == false
            && trimmedWhyItMattersDraft.isEmpty == false
    }

    private var activeFollowUpCandidates: [AnalystStrategyFollowUpCandidateRecord] {
        linkedStrategyFollowUpCandidates.filter { $0.status.isActive }
    }

    var body: some View {
        GroupBox("Strategy Implication") {
            VStack(alignment: .leading, spacing: 10) {
                if let presentation, isEditing == false {
                    OwnerReadableFactLine(title: "Classification:", value: presentation.implicationLabel)
                    Text(presentation.implicationSummary)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Why It Matters")
                            .font(.subheadline.weight(.semibold))
                        Text(presentation.whyItMatters)
                            .foregroundStyle(.secondary)
                    }

                    if let revisionNote = presentation.candidateStrategyBriefRevisionNote {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Candidate Strategy Brief Revision")
                                .font(.subheadline.weight(.semibold))
                            Text(revisionNote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let followUp = presentation.candidatePMFollowUpSummary {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Candidate PM Follow-Up")
                                .font(.subheadline.weight(.semibold))
                            Text(followUp)
                                .foregroundStyle(.secondary)
                        }
                    }

                    OwnerReadableFactLine(title: "Linked Artifacts:", value: presentation.linkedArtifactsSummary)
                    Text(presentation.boundaryNote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if activeFollowUpCandidates.isEmpty == false {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Open Follow-Up Candidates")
                                .font(.subheadline.weight(.semibold))
                            ForEach(activeFollowUpCandidates) { candidate in
                                Text("\(candidate.followUpKind.displayTitle) • \(candidate.status.displayTitle) • \(candidate.candidateSummary)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    GroupBox("PM Strategy Follow-Up Actions") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Turn this implication into one bounded PM follow-up candidate. These candidates stay separate from the saved Portfolio Strategy Brief until a later explicit apply or dismissal step.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)

                            HStack(spacing: 8) {
                                Button("Create Brief Revision Candidate") {
                                    Task { await createStrategyFollowUpCandidate(kind: .strategyBriefRevision) }
                                }
                                .buttonStyle(.bordered)
                                .disabled(followUpSaveInFlight)

                                Button("Create Instruction Candidate") {
                                    Task { await createStrategyFollowUpCandidate(kind: .pmInstructionFollowUp) }
                                }
                                .buttonStyle(.bordered)
                                .disabled(followUpSaveInFlight)
                            }

                            HStack(spacing: 8) {
                                Button("Create Mandate Candidate") {
                                    Task { await createStrategyFollowUpCandidate(kind: .pmMandateFollowUp) }
                                }
                                .buttonStyle(.bordered)
                                .disabled(followUpSaveInFlight)

                                Button("Mark Monitor-Only") {
                                    Task { await createStrategyFollowUpCandidate(kind: .monitorOnly) }
                                }
                                .buttonStyle(.bordered)
                                .disabled(followUpSaveInFlight)
                            }

                            if followUpSaveInFlight {
                                ProgressView()
                                    .controlSize(.small)
                            }

                            if let followUpFeedback, followUpFeedback.isEmpty == false {
                                Text(followUpFeedback)
                                    .font(.footnote)
                                    .foregroundStyle(followUpFeedbackIsError ? .red : .green)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button("Edit Strategy Implication") {
                        syncDrafts(from: currentImplication)
                        saveError = nil
                        followUpFeedback = nil
                        isEditing = true
                    }
                    .buttonStyle(.bordered)
                } else if currentImplication == nil, isEditing == false {
                    Text("No strategy implication recorded yet.")
                        .foregroundStyle(.secondary)
                    Text("Use this only to capture bounded PM strategy interpretation. The saved Portfolio Strategy Brief remains unchanged until an explicit separate update flow applies one.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Record Strategy Implication") {
                        syncDrafts(from: nil)
                        saveError = nil
                        followUpFeedback = nil
                        isEditing = true
                    }
                    .buttonStyle(.bordered)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Classification", selection: $selectedKind) {
                            ForEach(AnalystStrategyImplicationKind.allCases, id: \.self) { kind in
                                Text(kind.displayTitle).tag(kind)
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Summary")
                                .font(.subheadline.weight(.semibold))
                            TextField(
                                "Record the bounded strategic implication for this analyst output.",
                                text: $implicationSummaryDraft,
                                axis: .vertical
                            )
                            .textFieldStyle(.roundedBorder)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Why It Matters")
                                .font(.subheadline.weight(.semibold))
                            TextEditor(text: $whyItMattersDraft)
                                .frame(minHeight: 80)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.secondary.opacity(0.18))
                                )
                        }

                        if showCandidateStrategyBriefRevisionField {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Candidate Strategy Brief Revision")
                                    .font(.subheadline.weight(.semibold))
                                TextEditor(text: $candidateStrategyBriefRevisionDraft)
                                    .frame(minHeight: 70)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(Color.secondary.opacity(0.18))
                                    )
                            }
                        }

                        if showCandidatePMFollowUpField {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Candidate PM Follow-Up")
                                    .font(.subheadline.weight(.semibold))
                                TextField(
                                    "Record the bounded mandate or instruction follow-up.",
                                    text: $candidatePMFollowUpDraft,
                                    axis: .vertical
                                )
                                .textFieldStyle(.roundedBorder)
                            }
                        }

                        Text("This captures PM strategy interpretation of analyst output. It does not edit the saved Portfolio Strategy Brief by itself.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        if trimmedReadableText(defaultPMID) == nil {
                            Text("No durable PM profile is currently available for saving this implication.")
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }

                        if let saveError, saveError.isEmpty == false {
                            Text(saveError)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }

                        HStack {
                            Button(currentImplication == nil ? "Record Strategy Implication" : "Save Strategy Implication") {
                                Task {
                                    await saveStrategyImplication()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(canSave == false || isSaving)

                            Button(currentImplication == nil ? "Clear" : "Cancel") {
                                saveError = nil
                                syncDrafts(from: currentImplication)
                                isEditing = false
                            }
                            .buttonStyle(.bordered)
                            .disabled(isSaving)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func syncDrafts(from implication: AnalystStrategyImplicationRecord?) {
        selectedKind = implication?.implicationKind ?? .worthMonitoring
        implicationSummaryDraft = implication?.implicationSummary ?? ""
        whyItMattersDraft = implication?.whyItMatters ?? ""
        candidateStrategyBriefRevisionDraft = implication?.candidateStrategyBriefRevisionNote ?? ""
        candidatePMFollowUpDraft = implication?.candidatePMFollowUpSummary ?? ""
    }

    private func saveStrategyImplication() async {
        guard let pmID = trimmedReadableText(defaultPMID) else {
            saveError = "No durable PM profile is currently available for saving this implication."
            return
        }

        let now = Date()
        let existing = currentImplication
        let implication = AnalystStrategyImplicationRecord(
            implicationId: existing?.implicationId ?? defaultAnalystStrategyImplicationID(for: memo),
            pmId: pmID,
            implicationKind: selectedKind,
            implicationSummary: trimmedImplicationSummaryDraft,
            whyItMatters: trimmedWhyItMattersDraft,
            candidateStrategyBriefRevisionNote: showCandidateStrategyBriefRevisionField
                ? trimmedReadableText(candidateStrategyBriefRevisionDraft)
                : nil,
            candidatePMFollowUpSummary: showCandidatePMFollowUpField
                ? trimmedReadableText(candidatePMFollowUpDraft)
                : nil,
            memoId: memo.memoId,
            findingId: linkedFinding?.findingId ?? existing?.findingId,
            evidenceBundleId: linkedEvidenceBundle?.bundleId ?? memo.evidenceBundleId ?? existing?.evidenceBundleId,
            delegationId: memo.delegationId ?? existing?.delegationId,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )

        isSaving = true
        let error = await onSaveStrategyImplication(implication)
        isSaving = false

        if let error, error.isEmpty == false {
            saveError = error
            return
        }

        savedImplication = implication
        saveError = nil
        followUpFeedback = nil
        isEditing = false
        syncDrafts(from: implication)
    }

    private func createStrategyFollowUpCandidate(kind: AnalystStrategyFollowUpCandidateKind) async {
        guard let implication = currentImplication else {
            followUpFeedback = "Save the strategy implication before creating a follow-up candidate."
            followUpFeedbackIsError = true
            return
        }

        let now = Date()
        let existing = linkedStrategyFollowUpCandidates.first(where: { $0.followUpKind == kind })
        let candidate = AnalystStrategyFollowUpCandidateRecord(
            candidateId: existing?.candidateId ?? defaultAnalystStrategyFollowUpCandidateID(
                implicationID: implication.implicationId,
                kind: kind
            ),
            implicationId: implication.implicationId,
            pmId: implication.pmId,
            followUpKind: kind,
            status: kind == .monitorOnly ? .monitoring : .open,
            candidateSummary: strategyFollowUpCandidateSummary(for: implication, kind: kind),
            candidateDetail: strategyFollowUpCandidateDetail(for: implication, kind: kind),
            memoId: memo.memoId,
            findingId: linkedFinding?.findingId ?? implication.findingId,
            evidenceBundleId: linkedEvidenceBundle?.bundleId ?? implication.evidenceBundleId,
            delegationId: memo.delegationId ?? implication.delegationId,
            closedAt: kind == .monitorOnly ? nil : existing?.closedAt,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )

        followUpSaveInFlight = true
        let error = await onSaveStrategyFollowUpCandidate(candidate)
        followUpSaveInFlight = false

        if let error, error.isEmpty == false {
            followUpFeedback = error
            followUpFeedbackIsError = true
            return
        }

        followUpFeedback = kind == .monitorOnly
            ? "Monitor-only follow-up recorded."
            : "\(kind.displayTitle) recorded."
        followUpFeedbackIsError = false
    }
}

private struct AnalystFindingSupportGroup: View {
    let finding: AnalystFinding
    let linkedMemo: AnalystMemo?
    let linkedEvidenceBundle: AnalystEvidenceBundle?

    private var presentation: AnalystFindingReadablePresentation {
        makeAnalystFindingReadablePresentation(
            finding,
            linkedMemo: linkedMemo,
            linkedEvidenceBundle: linkedEvidenceBundle
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(presentation.title)
                .font(.headline)

            Text(presentation.summary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Thesis")
                    .font(.subheadline.weight(.semibold))
                Text(presentation.thesis)
                    .foregroundStyle(.secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow { Text("Status"); Text(presentation.statusSummary) }
                GridRow { Text("Confidence"); Text(presentation.confidenceSummary) }
                if let symbolsSummary = presentation.symbolsSummary {
                    GridRow { Text("Symbols"); Text(symbolsSummary) }
                }
                if let tagsSummary = presentation.tagsSummary {
                    GridRow { Text("Tags"); Text(tagsSummary) }
                }
                if let timeHorizonSummary = presentation.timeHorizonSummary {
                    GridRow { Text("Time Horizon"); Text(timeHorizonSummary) }
                }
                if let linkedMemoSummary = presentation.linkedMemoSummary {
                    GridRow { Text("Linked Memo"); Text(linkedMemoSummary) }
                }
                if let linkedEvidenceSummary = presentation.linkedEvidenceSummary {
                    GridRow { Text("Evidence"); Text(linkedEvidenceSummary) }
                }
            }
            .font(.caption)

            Text(presentation.boundaryNote)
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let linkedEvidenceBundle {
                DisclosureGroup("Linked Evidence Bundle") {
                    AnalystEvidenceBundleSupportGroup(bundle: linkedEvidenceBundle)
                        .padding(.top, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AnalystEvidenceBundleSupportGroup: View {
    let bundle: AnalystEvidenceBundle

    private var presentation: AnalystEvidenceBundleReadablePresentation {
        makeAnalystEvidenceBundleReadablePresentation(bundle)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Research Evidence")
                .font(.headline)
            Text(presentation.summary)

            if let notes = presentation.notes {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Coverage Notes")
                        .font(.subheadline.weight(.semibold))
                    Text(notes)
                        .foregroundStyle(.secondary)
                }
            }

            Text(presentation.coverageSummary)
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(presentation.refs.prefix(6)) { ref in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(ref.title)
                                .font(.subheadline.weight(.semibold))
                            Spacer(minLength: 0)
                            Text(ref.sourceSummary)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        if let observedAtSummary = ref.observedAtSummary {
                            Text(observedAtSummary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if let summary = ref.summary {
                            Text(summary)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if ref.id != presentation.refs.prefix(6).last?.id {
                        Divider()
                    }
                }
            }

            Text(presentation.boundaryNote)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StandingAnalystReportInboxRowCard: View {
    let report: AnalystStandingReportReviewSummaryPresentation
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(report.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Spacer(minLength: 0)
                Text(report.reportKindLabel)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.teal.opacity(0.12))
                    .clipShape(Capsule())
            }

            Text("\(report.analystTitle) • \(report.cadenceSummary)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(report.reportingWindowSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text(report.portfolioScopeSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text(report.executiveSummary)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(3)
            Text(report.deliverySummary)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct StandingAnalystReportReviewDetailView: View {
    let report: AnalystStandingReportReviewPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(report.title)
                        .font(.headline)
                    Text("\(report.analystTitle) • \(report.cadenceSummary)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text(report.reportKindLabel)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.teal.opacity(0.12))
                    .clipShape(Capsule())
            }

            Text(report.executiveSummary)
                .font(.callout)

            GroupBox("PM Triage") {
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Headline View")
                            .font(.subheadline.weight(.semibold))
                        Text(report.headlineView)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Reporting Window")
                            .font(.subheadline.weight(.semibold))
                        Text(report.reportingWindowSummary)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Portfolio Scope")
                            .font(.subheadline.weight(.semibold))
                        Text(report.portfolioScopeSummary)
                            .foregroundStyle(.secondary)
                        Text(report.coveredSymbolsSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Portfolio Relevance")
                            .font(.subheadline.weight(.semibold))
                        Text(report.portfolioRelevanceSummary)
                            .foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Next Step")
                            .font(.subheadline.weight(.semibold))
                        Text(report.recommendedNextStep)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if report.skillUsageSummary.isEmpty == false {
                GroupBox("Agent Skills Used / Considered") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(report.skillUsageSummary, id: \.self) { line in
                            Text(line)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            ForEach(report.detailSections) { section in
                GroupBox(section.title) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let summary = section.summary, !summary.isEmpty {
                            Text(summary)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        ForEach(section.items) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(item.headline)
                                        .font(.subheadline.weight(.semibold))
                                    Spacer(minLength: 0)
                                    Text(item.stanceLabel)
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(Color.secondary.opacity(0.12))
                                        .clipShape(Capsule())
                                    if let symbolSummary = item.symbolSummary {
                                        Text(symbolSummary)
                                            .font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 3)
                                            .background(Color.blue.opacity(0.12))
                                            .clipShape(Capsule())
                                    }
                                    if let scoreSummary = item.scoreSummary {
                                        Text(scoreSummary)
                                            .font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 3)
                                            .background(Color.orange.opacity(0.12))
                                            .clipShape(Capsule())
                                    }
                                }

                                Text(item.detail)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LinkedStandingAnalystReportDocumentView: View {
    let report: AnalystStandingReportReviewPresentation
    let linkedMemoPresentation: AnalystMemoReadablePresentation?
    let sourceTruth: AnalystSourceTruthPresentation?

    @ViewBuilder
    private func memoSection(_ title: String, body: String) -> some View {
        GroupBox(title) {
            Text(body)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var deepSupportSections: [AnalystStandingReportReviewSectionPresentation] {
        report.detailSections.filter { section in
            switch section.kind {
            case .materialDevelopments, .importantItems, .nonMaterialItems, .longIdeas, .shortIdeas, .macroViews, .etfIdeas, .riskIssues, .evidence:
                return true
            case .reportingWindow, .portfolioScope, .portfolioRelevance, .followUp:
                return false
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(report.title)
                        .font(.headline)
                    Text("\(report.analystTitle) • \(report.cadenceSummary)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text(report.reportKindLabel)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.teal.opacity(0.12))
                    .clipShape(Capsule())
            }

            Text(linkedMemoPresentation?.executiveSummary ?? report.executiveSummary)
                .font(.callout)

            memoSection(
                "Current thesis and posture",
                body: linkedMemoPresentation?.currentView ?? report.headlineView
            )

            if let sourceTruth {
                GroupBox("Primary Sources And Support") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(sourceTruth.summary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        ForEach(sourceTruth.primarySources, id: \.self) { line in
                            Text(line)
                                .font(.subheadline)
                        }

                        if let weakSupportSummary = sourceTruth.weakSupportSummary, weakSupportSummary.isEmpty == false {
                            Text(weakSupportSummary)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if let linkedMemoPresentation {
                ForEach(linkedMemoPresentation.detailSections.filter { $0.title != "Technical Provenance" }) { section in
                    memoSection(section.title, body: section.body)
                }
                memoSection("Recommendation / next step", body: linkedMemoPresentation.recommendedNextStep)
            } else {
                if report.skillUsageSummary.isEmpty == false {
                    memoSection("Agent Skills Used / Considered", body: report.skillUsageSummary.joined(separator: "\n"))
                }
                memoSection("Portfolio relevance", body: report.portfolioRelevanceSummary)
                memoSection("Recommendation / next step", body: report.recommendedNextStep)
            }

            if deepSupportSections.isEmpty == false {
                GroupBox("Detailed Supporting Sections") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(deepSupportSections) { section in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(section.title)
                                    .font(.subheadline.weight(.semibold))
                                if let summary = section.summary, summary.isEmpty == false {
                                    Text(summary)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                ForEach(section.items) { item in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.headline)
                                            .font(.subheadline.weight(.semibold))
                                        Text(item.detail)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

private struct DelegationContextGroup: View {
    let delegation: PMDelegationRecord
    let charterTitle: String?
    let taskTitle: String?
    let latestOutputSummary: String
    let observability: PMDelegationObservabilitySummary
    let memo: AnalystMemo?
    let linkedFinding: AnalystFinding?
    let linkedEvidenceBundle: AnalystEvidenceBundle?
    let linkedSourceAccessSuggestions: [AnalystSourceAccessSuggestionRecord]
    let linkedStrategyImplication: AnalystStrategyImplicationRecord?
    let linkedStrategyFollowUpCandidates: [AnalystStrategyFollowUpCandidateRecord]
    let defaultStrategyImplicationPMID: String?
    let onSaveStrategyImplication: (AnalystStrategyImplicationRecord) async -> String?
    let onSaveStrategyFollowUpCandidate: (AnalystStrategyFollowUpCandidateRecord) async -> String?

    @State private var detailsExpanded = false

    private var presentation: PMDelegationReadablePresentation {
        makePMDelegationReadablePresentation(
            delegation: delegation,
            charterTitle: charterTitle,
            taskTitle: taskTitle,
            observability: observability,
            latestOutputSummary: latestOutputSummary
        )
    }

    var body: some View {
        GroupBox("Linked Delegation") {
            VStack(alignment: .leading, spacing: 10) {
                Text(delegation.title)
                    .font(.headline)

                HStack(spacing: 8) {
                    PMDelegationStatusBadge(
                        label: observability.launchHealth.rawValue,
                        color: pmLaunchHealthColor(observability.launchHealth)
                    )
                    PMDelegationStatusBadge(
                        label: observability.executionState.rawValue,
                        color: pmExecutionStateColor(observability.executionState)
                    )
                    PMDelegationStatusBadge(
                        label: observability.workflowState.rawValue,
                        color: pmWorkflowStateColor(observability.workflowState)
                    )
                }

                Text(presentation.subheadline)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(presentation.outcomeSummary)

                OwnerReadableFactLine(title: "Requested Model:", value: presentation.requestedModelSummary)
                OwnerReadableFactLine(title: "Execution Used:", value: presentation.executionUsedSummary)
                OwnerReadableFactLine(title: "Execution State:", value: observability.executionState.rawValue)
                if let stage = observability.progressStage, !stage.isEmpty {
                    OwnerReadableFactLine(title: "Execution Stage:", value: stage)
                }
                OwnerReadableFactLine(title: "Latest Output:", value: presentation.latestOutputSummary)

                if let memo {
                    AnalystMemoSupportGroup(
                        memo: memo,
                        linkedFinding: linkedFinding,
                        linkedEvidenceBundle: linkedEvidenceBundle,
                        linkedSourceAccessSuggestions: linkedSourceAccessSuggestions,
                        linkedStrategyImplication: linkedStrategyImplication,
                        linkedStrategyFollowUpCandidates: linkedStrategyFollowUpCandidates,
                        defaultStrategyImplicationPMID: defaultStrategyImplicationPMID,
                        onSaveStrategyImplication: onSaveStrategyImplication,
                        onSaveStrategyFollowUpCandidate: onSaveStrategyFollowUpCandidate
                    )
                }

                TechnicalDetailsToggleButton(isExpanded: $detailsExpanded)

                if detailsExpanded {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(presentation.detailSections) { section in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(section.title)
                                    .font(.subheadline.weight(.semibold))
                                Text(section.body)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private func latestAnalystMemo(
    in memos: [AnalystMemo],
    delegationID: String?,
    taskID: String?,
    findingID: String?
) -> AnalystMemo? {
    memos.first { memo in
        if let delegationID, memo.delegationId == delegationID {
            return true
        }
        if let findingID, memo.findingId == findingID {
            return true
        }
        if let taskID, memo.taskId == taskID {
            return true
        }
        return false
    }
}

private func linkedAnalystStrategyImplication(
    in implications: [AnalystStrategyImplicationRecord],
    memo: AnalystMemo?,
    finding: AnalystFinding?,
    delegation: PMDelegationRecord?
) -> AnalystStrategyImplicationRecord? {
    implications.first { implication in
        if let memoID = memo?.memoId, implication.memoId == memoID {
            return true
        }
        if let findingID = finding?.findingId, implication.findingId == findingID {
            return true
        }
        if let delegationID = delegation?.delegationId, implication.delegationId == delegationID {
            return true
        }
        return false
    }
}

private func linkedAnalystStrategyFollowUpCandidates(
    in candidates: [AnalystStrategyFollowUpCandidateRecord],
    implication: AnalystStrategyImplicationRecord?
) -> [AnalystStrategyFollowUpCandidateRecord] {
    guard let implication else {
        return []
    }
    return candidates
        .filter { $0.implicationId == implication.implicationId }
        .sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.candidateId < rhs.candidateId
            }
            return lhs.updatedAt > rhs.updatedAt
        }
}

private func linkedAnalystSourceAccessSuggestions(
    in suggestions: [AnalystSourceAccessSuggestionRecord],
    memo: AnalystMemo?,
    finding: AnalystFinding?,
    evidenceBundle: AnalystEvidenceBundle?,
    delegation: PMDelegationRecord?
) -> [AnalystSourceAccessSuggestionRecord] {
    suggestions
        .filter { suggestion in
            if let memoID = memo?.memoId, suggestion.memoId == memoID {
                return true
            }
            if let findingID = finding?.findingId, suggestion.findingId == findingID {
                return true
            }
            if let bundleID = evidenceBundle?.bundleId, suggestion.evidenceBundleId == bundleID {
                return true
            }
            if let taskID = memo?.taskId, suggestion.taskId == taskID {
                return true
            }
            if let delegationID = memo?.delegationId, suggestion.delegationId == delegationID {
                return true
            }
            if let delegationID = delegation?.delegationId, suggestion.delegationId == delegationID {
                return true
            }
            return false
        }
        .sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.suggestionId < rhs.suggestionId
            }
            return lhs.updatedAt > rhs.updatedAt
        }
}

private func preferredStrategyImplicationPMID(
    memo: AnalystMemo?,
    delegation: PMDelegationRecord?,
    fallbackPMID: String?,
    contextPMID: String?,
    pmProfiles: [PMProfile]
) -> String? {
    let candidates = [memo?.pmId, delegation?.pmId, fallbackPMID, contextPMID]
    for candidate in candidates {
        if let trimmed = trimmedReadableText(candidate),
           isOperationalExercisePMID(trimmed) == false {
            return trimmed
        }
    }
    return pmProfiles.first(where: { isOperationalExercisePMID($0.pmId) == false })?.pmId
}

private func defaultAnalystStrategyImplicationID(for memo: AnalystMemo) -> String {
    "analyst-strategy-implication-\(memo.memoId)"
}

private func defaultAnalystStrategyFollowUpCandidateID(
    implicationID: String,
    kind: AnalystStrategyFollowUpCandidateKind
) -> String {
    "analyst-strategy-follow-up-\(implicationID)-\(kind.rawValue)"
}

private func strategyFollowUpCandidateSummary(
    for implication: AnalystStrategyImplicationRecord,
    kind: AnalystStrategyFollowUpCandidateKind
) -> String {
    switch kind {
    case .monitorOnly:
        return "Monitor only: \(implication.implicationSummary)"
    case .strategyBriefRevision:
        return implication.candidateStrategyBriefRevisionNote ?? implication.implicationSummary
    case .pmInstructionFollowUp:
        return implication.candidatePMFollowUpSummary ?? implication.implicationSummary
    case .pmMandateFollowUp:
        return implication.candidatePMFollowUpSummary ?? implication.implicationSummary
    }
}

private func strategyFollowUpCandidateDetail(
    for implication: AnalystStrategyImplicationRecord,
    kind: AnalystStrategyFollowUpCandidateKind
) -> String {
    switch kind {
    case .monitorOnly:
        return "Keep this implication in monitoring posture only. \(implication.whyItMatters)"
    case .strategyBriefRevision:
        return implication.candidateStrategyBriefRevisionNote ?? implication.whyItMatters
    case .pmInstructionFollowUp:
        return implication.candidatePMFollowUpSummary ?? implication.whyItMatters
    case .pmMandateFollowUp:
        return implication.candidatePMFollowUpSummary ?? implication.whyItMatters
    }
}

private func trimmedReadableText(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          trimmed.isEmpty == false else {
        return nil
    }
    return trimmed
}

private func latestDelegationOutputText(_ delegation: PMDelegationRecord, task: AnalystTask?) -> String {
    if let proposalID = delegation.linkedProposalIDs.last {
        return "Proposal \(proposalID)"
    }
    if let signalID = delegation.linkedSignalIDs.last {
        return "Signal \(signalID)"
    }
    if let findingID = delegation.linkedFindingIDs.last ?? task?.checkpoint?.linkedFindingIDs.last {
        return "Finding \(findingID)"
    }
    if task?.checkpoint != nil {
        return "Checkpoint updated"
    }
    return "No downstream outputs yet"
}

protocol AppMemoryFootprintSampling: Sendable {
    func sample(now: Date) -> ProcessMemoryFootprintSample
}

struct MachTaskMemoryFootprintSampler: AppMemoryFootprintSampling {
    func sample(now: Date = Date()) -> ProcessMemoryFootprintSample {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { infoPointer in
            infoPointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    reboundPointer,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else {
            return ProcessMemoryFootprintSample(
                capturedAt: now,
                physicalFootprintBytes: nil,
                residentSizeBytes: nil,
                source: "mach_task_info_task_vm_info",
                failureReason: "task_info_failed_\(result)"
            )
        }
        return ProcessMemoryFootprintSample(
            capturedAt: now,
            physicalFootprintBytes: UInt64(info.phys_footprint),
            residentSizeBytes: UInt64(info.resident_size),
            source: "mach_task_info_task_vm_info",
            failureReason: nil
        )
    }
}

protocol AppAllocatorPressureRelieving: Sendable {
    func relieve(goalBytes: UInt64) -> AllocatorPressureReliefOutcome
}

struct DarwinAllocatorPressureReliever: AppAllocatorPressureRelieving {
    func relieve(goalBytes: UInt64 = 0) -> AllocatorPressureReliefOutcome {
        let reclaimed = malloc_zone_pressure_relief(
            malloc_default_zone(),
            Int(goalBytes)
        )
        return AllocatorPressureReliefOutcome(
            attempted: true,
            reclaimedBytes: UInt64(reclaimed),
            error: nil
        )
    }
}

private func memoryPostureCounterJSON(_ counters: [String: Int]) -> JSONValue {
    .object(
        Dictionary(
            uniqueKeysWithValues: counters
                .sorted { lhs, rhs in lhs.key < rhs.key }
                .map { key, value in
                    (key, JSONValue.number(Double(value)))
                }
        )
    )
}

private func optionalMemoryPostureBytesJSON(_ bytes: UInt64?) -> JSONValue {
    bytes.map { JSONValue.number(Double($0)) } ?? .null
}

private func optionalMemoryPostureMBJSON(_ megabytes: Double?) -> JSONValue {
    megabytes.map { JSONValue.number($0) } ?? .null
}

private func memoryPostureDateJSON(_ date: Date?) -> JSONValue {
    guard let date else {
        return .null
    }
    memoryPostureISO8601FormatterLock.lock()
    defer { memoryPostureISO8601FormatterLock.unlock() }
    return .string(memoryPostureISO8601Formatter.string(from: date))
}

private let memoryPostureISO8601FormatterLock = NSLock()

private let memoryPostureISO8601Formatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

private extension ProcessMemoryFootprintSample {
    var jsonValue: JSONValue {
        .object([
            "capturedAt": memoryPostureDateJSON(capturedAt),
            "physicalFootprintBytes": optionalMemoryPostureBytesJSON(physicalFootprintBytes),
            "physicalFootprintMB": optionalMemoryPostureMBJSON(physicalFootprintMB),
            "residentSizeBytes": optionalMemoryPostureBytesJSON(residentSizeBytes),
            "residentSizeMB": optionalMemoryPostureMBJSON(residentSizeMB),
            "source": .string(source),
            "failureReason": failureReason.map(JSONValue.string) ?? .null
        ])
    }
}

private extension AllocatorPressureReliefOutcome {
    var jsonValue: JSONValue {
        .object([
            "attempted": .bool(attempted),
            "reclaimedBytes": optionalMemoryPostureBytesJSON(reclaimedBytes),
            "reclaimedMB": optionalMemoryPostureMBJSON(
                reclaimedBytes.map { Double($0) / 1_024 / 1_024 }
            ),
            "error": error.map(JSONValue.string) ?? .null
        ])
    }
}

private extension MemoryReliefActionSummary {
    var jsonValue: JSONValue {
        .object([
            "mode": .string(mode.rawValue),
            "reason": .string(reason),
            "dryRun": .bool(dryRun),
            "forced": .bool(forced),
            "startedAt": memoryPostureDateJSON(startedAt),
            "completedAt": memoryPostureDateJSON(completedAt),
            "bandBeforeAction": .string(bandBeforeAction.rawValue),
            "sample": sample.jsonValue,
            "volatileCategoryCountsBefore": memoryPostureCounterJSON(volatileCategoryCountsBefore),
            "volatileCategoryCountsAfter": memoryPostureCounterJSON(volatileCategoryCountsAfter),
            "allocatorRelief": allocatorRelief.jsonValue,
            "actionApplied": .bool(actionApplied),
            "summary": .string(summary)
        ])
    }
}

private extension MemoryPostureDiagnostics {
    var jsonValue: JSONValue {
        .object([
            "configuration": .object([
                "warmupSeconds": .number(configuration.warmupSeconds),
                "checkCadenceSeconds": .number(configuration.checkCadenceSeconds),
                "watchThresholdMB": .number(configuration.watchThresholdMB),
                "reliefThresholdMB": .number(configuration.reliefThresholdMB),
                "elevatedThresholdMB": .number(configuration.elevatedThresholdMB),
                "criticalThresholdMB": .number(configuration.criticalThresholdMB)
            ]),
            "latestSample": latestSample?.jsonValue ?? .null,
            "peakPhysicalFootprintBytes": optionalMemoryPostureBytesJSON(peakPhysicalFootprintBytes),
            "peakPhysicalFootprintMB": optionalMemoryPostureMBJSON(peakPhysicalFootprintMB),
            "currentBand": .string(currentBand.rawValue),
            "lastSampleAt": memoryPostureDateJSON(lastSampleAt),
            "nextScheduledSampleAt": memoryPostureDateJSON(nextScheduledSampleAt),
            "lastAction": lastAction?.jsonValue ?? .null,
            "automaticReliefCount": .number(Double(automaticReliefCount)),
            "manualReliefCount": .number(Double(manualReliefCount)),
            "memoryPressureReliefCount": .number(Double(memoryPressureReliefCount)),
            "allocatorReliefAttemptCount": .number(Double(allocatorReliefAttemptCount)),
            "allocatorReliefTotalReclaimedBytes": .number(Double(allocatorReliefTotalReclaimedBytes)),
            "allocatorReliefTotalReclaimedMB": .number(Double(allocatorReliefTotalReclaimedBytes) / 1_024 / 1_024),
            "actionInFlight": .bool(actionInFlight)
        ])
    }
}

@MainActor
final class AppModel: ObservableObject {
    private static let runNowRefreshPollIntervalNanoseconds: UInt64 = 500_000_000
    private static let runNowRefreshAttemptLimit = 12
    private static let standingReviewAutoConsumeDebounceNanoseconds: UInt64 = 750_000_000
    private static let marketDataUIRefreshIntervalNanoseconds: UInt64 = 1_000_000_000

    private enum StoreSnapshotRefreshScope {
        case full
        case marketData
        case connectivity
        case diagnostic
        case jobs
        case schedules
        case news
        case strategyStatuses
        case proposals
        case proposalRuns
        case signals
        case ipc

        var diagnosticName: String {
            switch self {
            case .full: return "full"
            case .marketData: return "market_data"
            case .connectivity: return "connectivity"
            case .diagnostic: return "diagnostic"
            case .jobs: return "jobs"
            case .schedules: return "schedules"
            case .news: return "news"
            case .strategyStatuses: return "strategy_statuses"
            case .proposals: return "proposals"
            case .proposalRuns: return "proposal_runs"
            case .signals: return "signals"
            case .ipc: return "ipc"
            }
        }
    }

    private struct StrategyBriefRevisionCandidateCacheKey: Equatable {
        let sessionCount: Int
        let messageCount: Int
        let newestInAppSessionId: String?
        let newestInAppSessionUpdatedAt: Date?
        let newestMessageId: String?
        let newestMessageUpdatedAt: Date?
        let strategyBriefUpdatedAt: Date?
    }

    private struct OwnerPMConversationPresentationCacheKey: Equatable {
        let sessionCount: Int
        let messageCount: Int
        let newestOwnerSessionId: String?
        let newestOwnerSessionUpdatedAt: Date?
        let newestMessageId: String?
        let newestMessageUpdatedAt: Date?
        let approvalRequestCount: Int
        let newestApprovalRequestId: String?
        let newestApprovalRequestUpdatedAt: Date?
        let decisionCount: Int
        let newestDecisionId: String?
        let newestDecisionUpdatedAt: Date?
    }

    struct CommandCenterTopBarChipPresentation: Equatable, Identifiable {
        let title: String
        let value: String

        var id: String { title }
    }

    struct SystemHealthMetricPresentation: Equatable, Identifiable {
        let title: String
        let value: String

        var id: String { title }
    }

    struct VisibleStatusPresentation: Equatable {
        let selectedEnvironmentKeysFound: Bool
        let selectedEnvironmentSummary: String
        let selectedEnvironmentName: String
        let liveSafetyStatusLabel: String
        let liveSafetyStatusDetail: String
        let liveExecutionProtectionStatusLabel: String
        let liveExecutionProtectionDetailText: String
        let alwaysOnReadinessLabel: String
        let alwaysOnReadinessDetail: String
        let tradeStreamOwnerFacingLabel: String
        let marketDataOwnerFacingLabel: String
        let workerLinkStatus: String
        let systemExceptionCategories: [OwnerSystemExceptionCategoryPresentation]
        let commandCenterTopBarChips: [CommandCenterTopBarChipPresentation]
        let systemHealthMetrics: [SystemHealthMetricPresentation]

        static let initial = VisibleStatusPresentation(
            selectedEnvironmentKeysFound: false,
            selectedEnvironmentSummary: "missing",
            selectedEnvironmentName: TradingEnvironment.paper.rawValue.capitalized,
            liveSafetyStatusLabel: "Paper",
            liveSafetyStatusDetail: "Paper environment: live arming is unavailable.",
            liveExecutionProtectionStatusLabel: "Local Auth Required",
            liveExecutionProtectionDetailText: "Live NEW/REPLACE requires Touch ID or the Mac password before submission. Paper is unaffected and cancel remains available.",
            alwaysOnReadinessLabel: AlwaysOnReadinessState.initial().status.displayName,
            alwaysOnReadinessDetail: AlwaysOnReadinessState.initial().summary,
            tradeStreamOwnerFacingLabel: "disconnected",
            marketDataOwnerFacingLabel: "idle",
            workerLinkStatus: "Unavailable",
            systemExceptionCategories: makeOwnerSystemExceptionCategoryPresentations(
                snapshot: .empty,
                tradeConnectionState: "disconnected",
                marketDataConnectionState: "idle",
                workerLinkConnected: false
            ),
            commandCenterTopBarChips: [
                CommandCenterTopBarChipPresentation(title: "Posture", value: "Paper • Paper"),
                CommandCenterTopBarChipPresentation(title: "Connectivity", value: "Trades disconnected • Market idle"),
                CommandCenterTopBarChipPresentation(title: "Readiness", value: AlwaysOnReadinessState.initial().status.displayName),
                CommandCenterTopBarChipPresentation(title: "Your Decisions", value: "0 pending"),
                CommandCenterTopBarChipPresentation(title: "Background", value: "0 analyst • 0 PM"),
                CommandCenterTopBarChipPresentation(title: "Exceptions", value: "0 degraded • 0 failed launches"),
                CommandCenterTopBarChipPresentation(title: "Safety", value: "0 positions • kill switch OFF")
            ],
            systemHealthMetrics: [
                SystemHealthMetricPresentation(title: "Trade Connectivity", value: "disconnected"),
                SystemHealthMetricPresentation(title: "Market Data", value: "idle"),
                SystemHealthMetricPresentation(title: "Always-On Readiness", value: AlwaysOnReadinessState.initial().status.displayName),
                SystemHealthMetricPresentation(title: "Worker Link", value: "Unavailable"),
                SystemHealthMetricPresentation(title: "Running Jobs", value: "0"),
                SystemHealthMetricPresentation(title: "Last Market Data", value: "None"),
                SystemHealthMetricPresentation(title: "Configured Feed", value: TradingMarketDataFeed.test.displayName),
                SystemHealthMetricPresentation(title: "Feed Verify", value: TradingMarketDataFeed.test.diagnosticWebSocketEndpoint)
            ]
        )
    }

    @Published var selectedEnvironment: TradingEnvironment = OwnerEnvironmentFeedPreferenceStore.loadEnvironment() {
        didSet {
            applySelectedEnvironment()
        }
    }
    @Published var selectedMarketDataFeed: TradingMarketDataFeed = OwnerEnvironmentFeedPreferenceStore.loadMarketDataFeed() {
        didSet {
            applySelectedMarketDataFeed()
        }
    }

    @Published private(set) var engineStatusText: String = Engine.disconnectedStatus
    @Published private(set) var buildText: String = Engine.buildInfo
    @Published private(set) var connectionState: String = TradeUpdatesConnectionState.disconnected.rawValue
    @Published private(set) var tradeUpdatesLastDiagnostic: String?
    @Published private(set) var tradeUpdatesLastError: String?
    @Published private(set) var accountSummaryText: String = "Account not loaded"
    @Published private(set) var openOrders: [OrderRow] = []
    @Published private(set) var positions: [PositionRow] = []
    @Published private(set) var auditLines: [String] = []
    @Published private(set) var lastTradeUpdateText: String = "None"
    @Published private(set) var marketDataConnectionState: String = MarketDataConnectionState.disconnected.rawValue
    @Published private(set) var marketDataLastDiagnostic: String?
    @Published private(set) var marketDataLastErrorCode: Int?
    @Published private(set) var marketDataLastErrorMessage: String?
    @Published private(set) var lastMarketDataText: String = "None"
    @Published private(set) var lastOptionsMarketDataText: String = "None"
    @Published private(set) var visibleStatusPresentation: VisibleStatusPresentation = .initial
    @Published private(set) var alwaysOnReadiness: AlwaysOnReadinessState = .initial()
    @Published var showAdvancedTabs: Bool = false {
        didSet {
            UserDefaults.standard.set(
                showAdvancedTabs,
                forKey: Self.showAdvancedTabsDefaultsKey
            )
        }
    }
    @Published private(set) var isLive: Bool = false
    @Published private(set) var isArmedForLiveTrading: Bool = false
    @Published private(set) var armingSessionID: String?
    @Published private(set) var killSwitchEnabled: Bool = false
    @Published private(set) var tradingEnabled: Bool = true
    @Published private(set) var liveExecutionProtectionSettings: LiveExecutionProtectionSettings = .default(now: Date())
    @Published private(set) var liveExecutionProtectionLastAuthResult: LocalUserPresenceAuthorizationResult?
    @Published private(set) var watchlistSymbols: [String] = []
    @Published private(set) var quotesBySymbol: [String: MarketQuote] = [:]
    @Published private(set) var optionQuotesBySymbol: [String: MarketQuote] = [:]
    @Published private(set) var marketDataDesiredSubscriptions: MarketDataSubscriptionSet = .empty
    @Published private(set) var marketDataSubscriptions: MarketDataSubscriptionSet = .empty
    @Published private(set) var lastMarketDataReceivedAt: Date?
    @Published private(set) var lastMarketDataReceivedSymbol: String?
    @Published private(set) var portfolioWatchChartWallConfiguration: PortfolioWatchChartWallConfiguration?
    @Published private(set) var portfolioWatchChartCards: [PortfolioWatchCardPresentation] = []
    @Published private(set) var portfolioIntelligenceSnapshot: PortfolioIntelligenceSnapshot = .empty()
    @Published private(set) var optionContractsBySymbol: [String: OptionContract] = [:]
    @Published private(set) var strategyStatuses: [StrategyStatusSnapshot] = []
    @Published private(set) var jobs: [JobSummary] = []
    @Published private(set) var pmCommandCenterSnapshot: PMCommandCenterSnapshot = .empty
    @Published private(set) var runningJobSnapshots: [RunningJobSnapshot] = []
    @Published private(set) var ownerDecisionDeskItems: [OwnerDecisionDeskItemPresentation] = []
    @Published private(set) var ownerBackgroundActivityCards: [OwnerBackgroundActivityPresentation] = []
    @Published private(set) var ownerRecentChangePresentations: [OwnerRecentChangePresentation] = []
    @Published private(set) var ownerPMConversationPresentation: OwnerPMConversationPresentation?
    @Published private(set) var strategyBriefRevisionCandidate: StrategyBriefConversationRevisionCandidatePresentation?
    @Published private(set) var schedules: [ScheduledJobSummary] = []
    @Published private(set) var retentionPolicy: RetentionPolicy = .default
    @Published private(set) var storageFootprint: StorageFootprintSummary = StorageFootprintSummary.empty(
        rootPath: "-",
        now: Date()
    )
    @Published private(set) var lastMaintenanceJob: JobSummary?
    @Published private(set) var lastMaintenanceSummary: String = "None"
    @Published private(set) var lastOldJobTelemetryCleanup: OldJobTelemetryCleanupPresentation?
    @Published private(set) var ipcStatus: IPCServerStatus = .stopped()
    @Published private(set) var proposals: [ProposalRow] = []
    @Published private(set) var rssFeeds: [RSSFeed] = []
    @Published private(set) var alpacaNewsIngestEnabled: Bool = true
    @Published private(set) var rssFeedSummary: RSSFeedSummary = RSSFeedSummary()
    @Published private(set) var recentNews: [NewsEvent] = []
    @Published private(set) var signals: [Signal] = []
    @Published private(set) var pmProfiles: [PMProfile] = []
    @Published private(set) var pmContextPack: PMContextPack?
    @Published private(set) var portfolioStrategyBrief: PortfolioStrategyBrief?
    @Published private(set) var llmProviderSettings: LLMProviderSettings?
    @Published private(set) var llmCredentialReadinessByProfileId: [String: LLMCredentialReadiness] = [:]
    @Published private(set) var pmRuntimeSettings: PMRuntimeSettings?
    @Published private(set) var recentNewsAnalystRuntimeSettings: RecentNewsAnalystRuntimeSettings?
    @Published private(set) var standingBenchAnalystRuntimeSettings: StandingBenchAnalystRuntimeSettings?
    @Published private(set) var pmDecisions: [PMDecisionRecord] = []
    @Published private(set) var pmApprovalRequests: [PMApprovalRequest] = []
    @Published private(set) var pmExecutionRoutingAssessmentsByApprovalRequestID: [String: PMExecutionRoutingAssessment] = [:]
    @Published private(set) var pmCommunicationSessions: [PMCommunicationSession] = []
    @Published private(set) var pmCommunicationMessages: [PMCommunicationMessage] = []
    @Published private(set) var pmMandates: [PMMandate] = []
    @Published private(set) var pmInstructions: [PMInstruction] = []
    @Published private(set) var telegramBridgeStatus: TelegramBridgeStatus = TelegramBridgeStatus(tokenConfigured: false)
    @Published private(set) var pmDelegations: [PMDelegationRecord] = []
    @Published private(set) var lastPMDelegationFollowUp: PMDelegationFollowUpResult?
    @Published private(set) var analystCharters: [AnalystCharter] = []
    @Published private(set) var agentSkills: [AgentSkillRecord] = []
    @Published private(set) var analystSourceAccessSuggestions: [AnalystSourceAccessSuggestionRecord] = []
    @Published private(set) var analystTasks: [AnalystTask] = []
    @Published private(set) var analystFindings: [AnalystFinding] = []
    @Published private(set) var analystEvidenceBundles: [AnalystEvidenceBundle] = []
    @Published private(set) var analystMemos: [AnalystMemo] = []
    @Published private(set) var analystStrategyImplications: [AnalystStrategyImplicationRecord] = []
    @Published private(set) var analystStrategyFollowUpCandidates: [AnalystStrategyFollowUpCandidateRecord] = []
    @Published private(set) var analystStandingReports: [AnalystStandingReport] = []
    @Published private(set) var lastAnalystWorkerLaunch: AnalystWorkerLaunchResult?
    @Published private(set) var newsIngestStatus: NewsIngestStatus = NewsIngestStatus()
    @Published private(set) var proposalDetailsByID: [String: StrategyProposal] = [:]
    @Published private(set) var proposalRunSummariesByProposalID: [String: [PaperRunRecordSummary]] = [:]
    @Published private(set) var runDetailsByID: [String: PaperRunRecord] = [:]
    @Published private(set) var cancelingOrderIDs: Set<String> = []
    @Published private(set) var replacingOrderIDs: Set<String> = []
    @Published private(set) var keyStatus: CredentialsStatus = CredentialsStatus(
        paperPublicFound: false,
        paperSecretFound: false,
        livePublicFound: false,
        liveSecretFound: false,
        telegramConfigured: false,
        openAIConfigured: false,
        lastChecked: nil
    )
    @Published private(set) var memoryPostureDiagnostics = MemoryPostureDiagnostics(
        configuration: .conservativeDefault,
        latestSample: nil,
        peakPhysicalFootprintBytes: nil,
        currentBand: .sampleUnavailable,
        lastSampleAt: nil,
        nextScheduledSampleAt: nil,
        lastAction: nil,
        automaticReliefCount: 0,
        manualReliefCount: 0,
        memoryPressureReliefCount: 0,
        allocatorReliefAttemptCount: 0,
        allocatorReliefTotalReclaimedBytes: 0,
        actionInFlight: false
    )

    private let engine: Engine
    private let store: Store
    private let keychainProvider: KeychainCredentialsProvider
    private let memoryFootprintSampler: AppMemoryFootprintSampling
    private let allocatorPressureReliever: AppAllocatorPressureRelieving
    private let storeEventRefreshCoalescer = StoreEventRefreshCoalescer(
        intervalNanoseconds: AppModel.marketDataUIRefreshIntervalNanoseconds
    )
    private var portfolioWatchSeriesTracker = PortfolioWatchIntradaySeriesTracker()
    private var started = false
    private var storeEventsTask: Task<Void, Never>?
    private var telegramBridgePollingTask: Task<Void, Never>?
    private var lastTelegramBridgeStatusRefreshAt: Date?
    private var standingReviewAutoConsumeTask: Task<Void, Never>?
    private var standingReviewAutoConsumeRequested = false
    private var optionContractLookupsInFlight: Set<String> = []
    private var strategyBriefRevisionCandidateCacheKey: StrategyBriefRevisionCandidateCacheKey?
    private var strategyBriefRevisionCandidateRebuildCount = 0
    private var strategyBriefRevisionCandidateCacheHitCount = 0
    private var strategyBriefRevisionCandidateScannedMessageCount = 0
    private var strategyBriefRevisionCandidateLastScannedMessageCount = 0
    private var strategyBriefRevisionCandidateLastConsideredMessageCount = 0
    private var strategyBriefRevisionCandidateLastMessageCount = 0
    private var strategyBriefRevisionCandidateLastCandidateVisible = false
    private var appModelControlEventReceivedCount = 0
    private var appModelControlEventReceivedByName: [String: Int] = [:]
    private var appModelSnapshotApplyCountByScope: [String: Int] = [:]
    private var appModelFullSnapshotApplyCount = 0
    private var appModelFullSnapshotApplyByEvent: [String: Int] = [:]
    private var appModelOwnerSurfaceRebuildCount = 0
    private var appModelOwnerSurfaceRebuildByReason: [String: Int] = [:]
    private var commandCenterProjectionRebuildCount = 0
    private var jobScopedProjectionRefreshCount = 0
    private var ownerDecisionDeskProjectionRebuildCount = 0
    private var pmConversationPresentationRebuildCount = 0
    private var pmConversationPresentationCacheHitCount = 0
    private var pmConversationRoutineFilterScannedCount = 0
    private var pmConversationLastRoutineFilterScannedCount = 0
    private var pmConversationLastMatchingMessageCount = 0
    private var pmConversationPresentationCacheKey: OwnerPMConversationPresentationCacheKey?
    private var pmConversationRoutineFilterCache = OwnerPMConversationRoutineFilterCache()
    private var volatileCacheTrimCount = 0
    private var lastVolatileCacheTrimAt: Date?
    private var lastVolatileCacheTrimReason: String?
    private var lastVolatileCacheTrimCategoryCounts: [String: Int] = [:]
    private var lastVolatileCacheTrimRebuildReason: String?
    private var selectedMainTab: MainTab = .commandCenter
    private var portfolioWatchChartWallRebuildCount = 0
    private var portfolioWatchChartWallPublishedRebuildCount = 0
    private var portfolioWatchChartWallHiddenSkipCount = 0
    private var portfolioWatchChartWallReleaseCount = 0
    private var portfolioWatchChartWallLastPublishedCardCount = 0
    private var portfolioWatchChartWallLastSkippedCardCount = 0
    private var marketDataPresentationPublishedCount = 0
    private var marketDataPresentationSuppressedCount = 0
    private var topBannerPresentationRecomputeCount = 0
    private var topBannerPresentationPublishCount = 0
    private var topBannerPresentationPublishSkipCount = 0
    private var topCardPresentationRecomputeCount = 0
    private var topCardPresentationPublishCount = 0
    private var topCardPresentationPublishSkipCount = 0
    private var systemHealthPresentationRecomputeCount = 0
    private var systemHealthPresentationPublishCount = 0
    private var systemHealthPresentationPublishSkipCount = 0
    private var statusSerializationCount = 0
    private var memoryPressureTrimCount = 0
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private let memoryPostureConfiguration = MemoryPostureMonitorConfiguration.conservativeDefault
    private let memoryPostureLaunchDate = Date()
    private var memoryPostureMonitorTask: Task<Void, Never>?
    private var latestMemoryFootprintSample: ProcessMemoryFootprintSample?
    private var peakMemoryPhysicalFootprintBytes: UInt64?
    private var memoryPostureNextScheduledSampleAt: Date?
    private var lastMemoryReliefAction: MemoryReliefActionSummary?
    private var memoryPostureAutomaticReliefCount = 0
    private var memoryPostureManualReliefCount = 0
    private var memoryPostureMemoryPressureReliefCount = 0
    private var memoryPostureAllocatorReliefAttemptCount = 0
    private var memoryPostureAllocatorReliefTotalReclaimedBytes: UInt64 = 0
    private var memoryPostureActionInFlight = false
    private let pmInboxRefreshCoordinator = AsyncRefreshCoordinator<PMInboxRefreshDomain>()
    private static let showAdvancedTabsDefaultsKey = "ShowAdvancedTabsRawViews"
    private static let telegramBridgePollIntervalNanoseconds: UInt64 = 15_000_000_000
    private static let telegramBridgePollingStatusRefreshInterval: TimeInterval = 300
    private static let strategyBriefRevisionCandidateMessageScanLimit = 160

    init(
        engine: Engine? = nil,
        keychainProvider: KeychainCredentialsProvider = KeychainCredentialsProvider(),
        memoryFootprintSampler: AppMemoryFootprintSampling = MachTaskMemoryFootprintSampler(),
        allocatorPressureReliever: AppAllocatorPressureRelieving = DarwinAllocatorPressureReliever()
    ) {
        let resolvedEngine = engine ?? Engine(keychainProvider: keychainProvider)
        self.engine = resolvedEngine
        self.store = resolvedEngine.store
        self.keychainProvider = keychainProvider
        self.memoryFootprintSampler = memoryFootprintSampler
        self.allocatorPressureReliever = allocatorPressureReliever
        self.memoryPostureNextScheduledSampleAt = MemoryPosturePolicy.nextScheduledSampleDate(
            launchDate: memoryPostureLaunchDate,
            lastSampleAt: nil,
            configuration: memoryPostureConfiguration
        )
        self.showAdvancedTabs = UserDefaults.standard.bool(
            forKey: Self.showAdvancedTabsDefaultsKey
        )
        self.memoryPostureDiagnostics = makeMemoryPostureDiagnostics()
        Task { [weak self, resolvedEngine] in
            await resolvedEngine.setOwnerSurfaceRuntimeDiagnosticsProvider { [weak self] in
                self?.ownerSurfaceRuntimeDiagnosticsJSON() ?? .object([:])
            }
            await resolvedEngine.setMemoryReliefActionProvider { [weak self] request in
                await MainActor.run {
                    guard let self else {
                        return .object([
                            "available": .bool(false),
                            "summary": .string("Memory relief is unavailable because the app model is not active.")
                        ])
                    }
                    let mode: MemoryReliefActionMode = request.dryRun ? .ipcDryRun : .ipcForcedDiagnostic
                    return self.performMemoryRelief(
                        reason: request.reason,
                        mode: mode,
                        forced: request.force,
                        dryRun: request.dryRun
                    ).jsonValue
                }
            }
        }
    }

    deinit {
        storeEventsTask?.cancel()
        telegramBridgePollingTask?.cancel()
        standingReviewAutoConsumeTask?.cancel()
        memoryPressureSource?.cancel()
        memoryPostureMonitorTask?.cancel()
        let storeEventRefreshCoalescer = self.storeEventRefreshCoalescer
        let engine = self.engine
        Task {
            await storeEventRefreshCoalescer.cancelPendingMarketDataRefresh()
            await engine.stop()
        }
    }

    private func applyScheduleSummary(_ summary: ScheduledJobSummary) {
        if let existingIndex = schedules.firstIndex(where: { $0.scheduleId == summary.scheduleId }) {
            schedules[existingIndex] = summary
        } else {
            schedules.append(summary)
        }
        schedules.sort { lhs, rhs in
            if lhs.jobType.rawValue == rhs.jobType.rawValue {
                return lhs.scheduleId < rhs.scheduleId
            }
            return lhs.jobType.rawValue < rhs.jobType.rawValue
        }
    }

    private var preferredPMIDForCommunication: String? {
        let contextPMID = pmContextPack?.pmId
        if isOperationalExercisePMID(contextPMID) == false,
           contextPMID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return contextPMID
        }
        return pmProfiles.first(where: { isOperationalExercisePMID($0.pmId) == false })?.pmId
    }

    private func runLatestPMInboxRefresh<Value>(
        domain: PMInboxRefreshDomain,
        load: @escaping @Sendable () async throws -> Value,
        apply: @escaping @MainActor (Value) -> Void
    ) async -> String? {
        let generation = await pmInboxRefreshCoordinator.begin(domain)
        do {
            let value = try await load()
            guard await pmInboxRefreshCoordinator.isLatest(generation, for: domain) else {
                return nil
            }
            await MainActor.run {
                apply(value)
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func firstNonNilString(_ values: [String?]) -> String? {
        for value in values {
            if let value {
                return value
            }
        }
        return nil
    }

    func startIfNeeded() {
        guard !started else {
            return
        }
        started = true

        subscribeToStoreEvents()
        startMemoryPressureMonitoringIfNeeded()
        startSelfFootprintMemoryPostureMonitoringIfNeeded()
        Task {
            await engine.setEnvironment(selectedEnvironment)
            await engine.setMarketDataFeed(selectedMarketDataFeed)
            await engine.start()
            await MainActor.run {
                refreshKeychainStatus()
            }
            await runStartupConversationReadyRefreshes()
            Task { @MainActor [weak self] in
                await self?.runDeferredStartupRefreshes()
            }
        }
    }

    private func startMemoryPressureMonitoringIfNeeded() {
        guard memoryPressureSource == nil else {
            return
        }
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                self.memoryPressureTrimCount += 1
                _ = self.performMemoryRelief(
                    reason: "macos_memory_pressure",
                    mode: .macOSMemoryPressure,
                    forced: true,
                    dryRun: false
                )
            }
        }
        source.resume()
        memoryPressureSource = source
    }

    private func startSelfFootprintMemoryPostureMonitoringIfNeeded() {
        guard memoryPostureMonitorTask == nil else {
            return
        }
        refreshMemoryPostureDiagnostics()
        memoryPostureMonitorTask = Task { @MainActor [weak self] in
            while Task.isCancelled == false {
                guard let self else {
                    return
                }
                let next = self.memoryPostureNextScheduledSampleAt
                    ?? MemoryPosturePolicy.nextScheduledSampleDate(
                        launchDate: self.memoryPostureLaunchDate,
                        lastSampleAt: self.latestMemoryFootprintSample?.capturedAt,
                        configuration: self.memoryPostureConfiguration
                    )
                let delay = max(1, next.timeIntervalSince(Date()))
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if Task.isCancelled {
                    return
                }
                self.runScheduledMemoryPostureSample()
            }
        }
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            Task { await engine.handleHostAvailabilityEvent(.appBecameActive) }
        case .inactive:
            Task { await engine.handleHostAvailabilityEvent(.appBecameInactive) }
        case .background:
            Task { await engine.handleHostAvailabilityEvent(.appEnteredBackground) }
        @unknown default:
            break
        }
    }

    func updateSelectedMainTab(_ tab: MainTab) {
        guard selectedMainTab != tab else {
            return
        }

        let previousTab = selectedMainTab
        selectedMainTab = tab

        if previousTab == .marketWatch && tab != .marketWatch {
            releasePortfolioWatchDerivedPresentations(reason: "tab_changed_away")
        }
        if previousTab == .commandCenter && tab != .commandCenter {
            releaseCommandCenterDerivedPresentations(reason: "tab_changed_away")
        }

        switch tab {
        case .commandCenter:
            rebuildOwnerSurfaceProjections(reason: "tab_visible_command_center")
        case .marketWatch:
            rebuildPortfolioWatchChartWall(forcePublish: true, reason: "tab_visible_portfolio_watch")
            Task { @MainActor [weak self] in
                await self?.refreshSnapshotFromStore(scope: .marketData, reason: "tab_visible_portfolio_watch")
            }
        case .orderTicket:
            Task { @MainActor [weak self] in
                await self?.refreshSnapshotFromStore(scope: .marketData, reason: "tab_visible_market_data_surface")
            }
        default:
            break
        }
    }

    private var shouldPublishMarketDataPresentation: Bool {
        switch selectedMainTab {
        case .marketWatch, .orderTicket:
            return true
        case .commandCenter, .blotter, .pmInbox, .proposals, .signals, .jobs, .news, .systemControl, .logs:
            return false
        }
    }

    func handleHostWillSleep() {
        Task { await engine.handleHostAvailabilityEvent(.hostWillSleep) }
    }

    func handleHostDidWake() {
        Task { await engine.handleHostAvailabilityEvent(.hostDidWake) }
    }

    private func runStartupConversationReadyRefreshes() async {
        _ = await refreshPortfolioWatchChartWallConfiguration()
        await refreshSnapshotFromStore()

        async let pmProfilesRefresh: String? = refreshPMProfiles()
        async let decisionRefresh: String? = refreshPMDecisions()
        async let approvalRefresh: String? = refreshPMApprovalRequests()
        async let telegramStatusRefresh: String? = refreshTelegramBridgeStatus()

        _ = await ensureInAppPMUserCommunicationSession()

        async let sessionRefresh: String? = refreshPMCommunicationSessions()
        async let messageRefresh: String? = refreshPMCommunicationMessages(refreshContextPack: false)

        _ = await pmProfilesRefresh
        _ = await decisionRefresh
        _ = await approvalRefresh
        _ = await telegramStatusRefresh
        _ = await sessionRefresh
        _ = await messageRefresh

        startTelegramBridgePollingLoopIfNeeded()
    }

    private func runDeferredStartupRefreshes() async {
        _ = await refreshRSSFeeds()
        _ = await refreshAlpacaNewsIngestEnabled()
        _ = await refreshNews(limit: 100)
        _ = await refreshSignals(limit: 200)
        _ = await refreshPMMandates()
        _ = await refreshPMInstructions()
        _ = await refreshPortfolioStrategyBrief()
        _ = await refreshAgentSkills()
        _ = await refreshPortfolioWatchChartWallConfiguration()
        _ = await refreshPMRuntimeSettings()
        _ = await refreshLLMProviderSettings()
        _ = await refreshRecentNewsAnalystRuntimeSettings()
        _ = await refreshStandingBenchAnalystRuntimeSettings()
        _ = await refreshLiveExecutionProtectionSettings()
        _ = await refreshPMDelegations()
        _ = await refreshAnalystMemos()
        _ = await refreshAnalystFindings()
        _ = await refreshAnalystEvidenceBundles()
        _ = await refreshAnalystSourceAccessSuggestions()
        _ = await refreshAnalystStrategyImplications()
        _ = await refreshAnalystStrategyFollowUpCandidates()
        _ = await refreshAnalystStandingReports()
        _ = await refreshPMContextPack()
        scheduleAutomaticStandingReviewConsumptionIfNeeded()
        _ = await refreshJobs()
        _ = await refreshSchedules()
        _ = await refreshRetentionPolicy()
        _ = await refreshStorageFootprint()
        await refreshEngineStatus()
    }

    func refreshKeychainStatus(forceRefresh: Bool = false) {
        if forceRefresh {
            keychainProvider.clearSessionCache()
            OpenAIKeychainCredentialResolver.clearSharedCache()
        }
        assignIfChanged(\.keyStatus, keychainProvider.credentialStatus())
        rebuildVisibleStatusPresentation(reason: "keychain_status")
    }

    func ensureKeychainStatusLoaded() {
        guard keyStatus.lastChecked == nil else {
            return
        }
        refreshKeychainStatus()
    }

    func refreshLLMProviderSettings() async -> String? {
        do {
            llmProviderSettings = try await engine.getLLMProviderSettings()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func upsertLLMCredentialProfile(_ profile: LLMCredentialProfile) async -> String? {
        do {
            llmProviderSettings = try await engine.upsertLLMCredentialProfile(profile, source: .ui)
            OpenAIKeychainCredentialResolver.clearSharedCache()
            refreshKeychainStatus(forceRefresh: true)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func checkLLMCredentialProfile(profileId: String) async -> String? {
        do {
            let readiness = try await engine.checkLLMCredentialProfile(profileId: profileId)
            llmCredentialReadinessByProfileId[profileId] = readiness
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func cancelOrder(orderID: String) {
        guard !cancelingOrderIDs.contains(orderID) else {
            return
        }
        cancelingOrderIDs.insert(orderID)
        Task { [weak self] in
            guard let self else {
                return
            }
            await engine.cancelOrder(orderID: orderID)
            cancelingOrderIDs.remove(orderID)
        }
    }

    func refreshJobs() async -> String? {
        do {
            assignIfChanged(\.jobs, try await engine.listJobs())
            await updateLastMaintenanceState()
            rebuildOwnerSurfaceProjections()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func refreshSchedules() async -> String? {
        do {
            schedules = try await engine.listSchedules()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func upsertSchedule(_ schedule: ScheduledJob) async -> String? {
        do {
            let summary = try await engine.upsertSchedule(schedule, source: .ui)
            applyScheduleSummary(summary)
            schedules = try await engine.listSchedules()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func setScheduleEnabled(id: String, enabled: Bool) async -> String? {
        do {
            _ = try await engine.setScheduleEnabled(id: id, enabled: enabled, source: .ui)
            schedules = try await engine.listSchedules()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func removeSchedule(id: String) async -> String? {
        do {
            try await engine.removeSchedule(id: id, source: .ui)
            schedules = try await engine.listSchedules()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func runScheduleNow(id: String) async -> (summary: ScheduledJobSummary?, error: String?) {
        do {
            let summary = try await engine.runScheduleNow(id: id, source: .ui)
            applyScheduleSummary(summary)
            schedules = try await engine.listSchedules()
            _ = await refreshJobs()
            _ = await refreshPMContextPack()
            scheduleAutomaticStandingReviewConsumptionIfNeeded()
            if summary.jobType == .standingAnalystReport,
               let runningJobID = summary.runningJobId,
               runningJobID.isEmpty == false {
                Task { @MainActor [weak self] in
                    await self?.refreshStandingRunNowStateUntilSettled(
                        scheduleID: id,
                        runningJobID: runningJobID
                    )
                }
            }
            if let latest = schedules.first(where: { $0.scheduleId == id }) {
                return (latest, nil)
            }
            return (summary, nil)
        } catch {
            if let latest = try? await engine.listSchedules() {
                schedules = latest
            }
            return (nil, error.localizedDescription)
        }
    }

    private func refreshStandingRunNowStateUntilSettled(
        scheduleID: String,
        runningJobID: String
    ) async {
        for _ in 0..<Self.runNowRefreshAttemptLimit {
            _ = await refreshJobs()
            _ = await refreshSchedules()
            _ = await refreshAnalystStandingReports()
            _ = await refreshPMContextPack()
            scheduleAutomaticStandingReviewConsumptionIfNeeded()

            let jobStillActive = runningJobSnapshots.contains { $0.jobId == runningJobID }
            let scheduleStillRunning = schedules.first(where: { $0.scheduleId == scheduleID })?.runningJobId == runningJobID
            if jobStillActive == false && scheduleStillRunning == false {
                break
            }

            try? await Task.sleep(nanoseconds: Self.runNowRefreshPollIntervalNanoseconds)
        }
    }

    func refreshRetentionPolicy() async -> String? {
        retentionPolicy = await engine.getRetentionPolicy()
        return nil
    }

    func saveRetentionPolicy(_ policy: RetentionPolicy) async -> String? {
        do {
            retentionPolicy = try await engine.updateRetentionPolicy(policy, source: .ui)
            _ = await refreshStorageFootprint()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func refreshStorageFootprint() async -> String? {
        storageFootprint = await engine.storageHealthSummary()
        return nil
    }

    func runMaintenanceRetention(
        dryRun: Bool,
        jobTelemetryCleanupBefore: Date? = nil
    ) async -> String? {
        do {
            let job = try await engine.runMaintenanceRetention(
                dryRun: dryRun,
                jobTelemetryCleanupBefore: jobTelemetryCleanupBefore,
                source: .ui
            )
            assignIfChanged(\.jobs, try await engine.listJobs())
            assignMaintenanceState(from: job)
            await refreshMaintenanceJobUntilSettled(jobID: job.jobId)
            rebuildCommandCenterProjection(reason: "maintenance_retention_ui")
            _ = await refreshStorageFootprint()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func cancelJob(jobID: String) async -> String? {
        do {
            _ = try await engine.cancelJob(jobID: jobID, source: .ui)
            assignIfChanged(\.jobs, try await engine.listJobs())
            rebuildOwnerSurfaceProjections()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func submitManualOrder(
        instrumentType: TradingInstrumentType,
        symbol: String,
        qty: Int,
        side: OrderSide,
        type: OrderType,
        limitPriceText: String,
        timeInForce: TimeInForce,
        bracketEnabled: Bool,
        takeProfitText: String,
        stopLossText: String,
        stopLossLimitText: String
    ) async -> TicketSubmissionOutcome {
        let parsedLimitPrice: Decimal?
        if type == .limit {
            let trimmed = limitPriceText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return .failure("Limit price is required for limit orders.")
            }
            guard let decimal = Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX")) else {
                return .failure("Limit price must be a valid decimal number.")
            }
            parsedLimitPrice = decimal
        } else {
            parsedLimitPrice = nil
        }

        let bracket: BracketOrderInput?
        if bracketEnabled {
            if instrumentType == .option {
                return .failure("Bracket orders are currently disabled for options.")
            }
            let takeProfitTrimmed = takeProfitText.trimmingCharacters(in: .whitespacesAndNewlines)
            let stopLossTrimmed = stopLossText.trimmingCharacters(in: .whitespacesAndNewlines)
            let stopLossLimitTrimmed = stopLossLimitText.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !takeProfitTrimmed.isEmpty else {
                return .failure("Take-profit price is required when bracket is enabled.")
            }
            guard !stopLossTrimmed.isEmpty else {
                return .failure("Stop-loss price is required when bracket is enabled.")
            }
            guard let takeProfit = Decimal(string: takeProfitTrimmed, locale: Locale(identifier: "en_US_POSIX")) else {
                return .failure("Take-profit must be a valid decimal number.")
            }
            guard let stopLoss = Decimal(string: stopLossTrimmed, locale: Locale(identifier: "en_US_POSIX")) else {
                return .failure("Stop-loss must be a valid decimal number.")
            }

            let stopLossLimit: Decimal?
            if stopLossLimitTrimmed.isEmpty {
                stopLossLimit = nil
            } else {
                guard let parsedStopLimit = Decimal(string: stopLossLimitTrimmed, locale: Locale(identifier: "en_US_POSIX")) else {
                    return .failure("Stop-loss limit must be a valid decimal number.")
                }
                stopLossLimit = parsedStopLimit
            }

            bracket = BracketOrderInput(
                takeProfitLimitPrice: takeProfit,
                stopLossStopPrice: stopLoss,
                stopLossLimitPrice: stopLossLimit
            )
        } else {
            bracket = nil
        }

        do {
            let sessionID = selectedEnvironment == .live ? armingSessionID : nil
            let orderID = try await engine.placeOrder(
                instrumentType: instrumentType,
                symbol: symbol,
                qty: qty,
                side: side,
                type: type,
                limitPrice: parsedLimitPrice,
                timeInForce: timeInForce,
                bracket: bracket,
                source: "ui.order_ticket",
                armingSessionID: sessionID
            )
            return .success("Order submitted (\(shortOrderID(orderID))). Awaiting trade updates.")
        } catch let validationError as ManualOrderValidationError {
            return .failure(validationError.localizedDescription)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    func lookupOptionContract(symbol: String) async -> OptionContract? {
        await engine.fetchOptionContract(symbolOrID: symbol)
    }

    func submitReplaceOrder(
        orderID: String,
        qtyText: String,
        limitPriceText: String
    ) async -> TicketSubmissionOutcome {
        let trimmedQty = qtyText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLimit = limitPriceText.trimmingCharacters(in: .whitespacesAndNewlines)

        let parsedQty: Int?
        if trimmedQty.isEmpty {
            parsedQty = nil
        } else {
            guard let qty = Int(trimmedQty) else {
                return .failure("Replacement quantity must be a whole number.")
            }
            parsedQty = qty
        }

        let parsedLimit: Decimal?
        if trimmedLimit.isEmpty {
            parsedLimit = nil
        } else {
            guard let limit = Decimal(string: trimmedLimit, locale: Locale(identifier: "en_US_POSIX")) else {
                return .failure("Replacement limit price must be a valid decimal number.")
            }
            parsedLimit = limit
        }

        guard parsedQty != nil || parsedLimit != nil else {
            return .failure("Provide replacement qty and/or replacement limit price.")
        }

        guard !replacingOrderIDs.contains(orderID) else {
            return .failure("Replace already in progress for this order.")
        }

        replacingOrderIDs.insert(orderID)
        defer { replacingOrderIDs.remove(orderID) }

        do {
            let sessionID = selectedEnvironment == .live ? armingSessionID : nil
            let replacementID = try await engine.replaceOrder(
                orderID: orderID,
                qty: parsedQty,
                limitPrice: parsedLimit,
                source: "ui.replace_sheet",
                armingSessionID: sessionID
            )
            return .success("Replace submitted (\(shortOrderID(replacementID))). Awaiting trade updates.")
        } catch let validationError as ManualOrderValidationError {
            return .failure(validationError.localizedDescription)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    func addWatchSymbol(_ symbol: String) async -> String? {
        let normalized = symbol
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard !normalized.isEmpty else {
            return "Symbol is required."
        }

        await engine.addWatchSymbol(normalized)
        _ = await refreshPortfolioWatchChartWallConfiguration()
        return nil
    }

    func removeWatchSymbol(_ symbol: String) async {
        let normalized = symbol
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        await engine.removeWatchSymbol(symbol)
        if let configuration = portfolioWatchChartWallConfiguration,
           configuration.selectedSymbols.contains(normalized) {
            let remaining = configuration.selectedSymbols.filter { $0 != normalized }
            _ = await upsertPortfolioWatchChartWallSelection(remaining)
        }
    }

    func refreshRSSFeeds() async -> String? {
        do {
            let feeds = try await engine.listRSSFeeds()
            rssFeeds = feeds
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func refreshAlpacaNewsIngestEnabled() async -> String? {
        alpacaNewsIngestEnabled = await engine.alpacaNewsIngestEnabled()
        return nil
    }

    func setAlpacaNewsIngestEnabled(_ enabled: Bool) async -> String? {
        let previous = alpacaNewsIngestEnabled
        alpacaNewsIngestEnabled = enabled
        do {
            alpacaNewsIngestEnabled = try await engine.setAlpacaNewsIngestEnabled(enabled, source: .ui)
            return nil
        } catch {
            alpacaNewsIngestEnabled = previous
            return error.localizedDescription
        }
    }

    func addRSSFeed(
        name: String,
        url: String,
        pollIntervalSec: Int,
        enabled: Bool,
        tags: [String]
    ) async -> String? {
        do {
            _ = try await engine.addRSSFeed(
                name: name,
                url: url,
                enabled: enabled,
                pollIntervalSec: pollIntervalSec,
                tags: tags
            )
            rssFeeds = try await engine.listRSSFeeds()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func updateRSSFeed(_ feed: RSSFeed) async -> String? {
        do {
            _ = try await engine.updateRSSFeed(feed)
            rssFeeds = try await engine.listRSSFeeds()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func removeRSSFeed(id: String) async -> String? {
        do {
            try await engine.removeRSSFeed(id: id)
            rssFeeds = try await engine.listRSSFeeds()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func refreshNews(limit: Int = 100) async -> String? {
        do {
            recentNews = try await engine.listNews(limit: limit)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func refreshSignals(
        status: SignalStatus? = nil,
        limit: Int = 200
    ) async -> String? {
        await runLatestPMInboxRefresh(domain: .signals, load: {
            try await self.engine.listSignals(status: status, limit: limit)
        }) { [weak self] loadedSignals in
            guard let self else { return }
            self.assignIfChanged(\.signals, loadedSignals)
            self.rebuildOwnerSurfaceProjections()
        }
    }

    func refreshPMInboxReviewData(signalLimit: Int = 200) async -> String? {
        let pmProfileError = await refreshPMProfiles()
        if pmCommunicationSessions.isEmpty {
            let ensureSessionError = await ensureInAppPMUserCommunicationSession()
            if let ensureSessionError {
                return ensureSessionError
            }
        }
        let communicationSessionError = await refreshPMCommunicationSessions()
        let communicationMessageError = await refreshPMCommunicationMessages()
        let decisionError = await refreshPMDecisions()
        let approvalError = await refreshPMApprovalRequests()
        let delegationError = await refreshPMDelegations()
        let charterError = await refreshAnalystCharters()
        let taskError = await refreshAnalystTasks()
        let memoError = await refreshAnalystMemos()
        let findingError = await refreshAnalystFindings()
        let evidenceBundleError = await refreshAnalystEvidenceBundles()
        let sourceSuggestionError = await refreshAnalystSourceAccessSuggestions()
        let implicationError = await refreshAnalystStrategyImplications()
        let strategyFollowUpError = await refreshAnalystStrategyFollowUpCandidates()
        let standingReportError = await refreshAnalystStandingReports()
        let signalError = await refreshSignals(status: nil, limit: signalLimit)

        return firstNonNilString([
            pmProfileError,
            communicationSessionError,
            communicationMessageError,
            decisionError,
            approvalError,
            delegationError,
            charterError,
            taskError,
            memoError,
            findingError,
            evidenceBundleError,
            sourceSuggestionError,
            implicationError,
            strategyFollowUpError,
            standingReportError,
            signalError
        ])
    }

    func refreshAnalystCharters() async -> String? {
        await runLatestPMInboxRefresh(domain: .analystCharters, load: {
            try await self.engine.listAnalystCharters()
        }) { [weak self] charters in
            guard let self else { return }
            self.assignIfChanged(\.analystCharters, charters)
            self.rebuildOwnerSurfaceProjections()
        }
    }

    func refreshAgentSkills() async -> String? {
        do {
            assignIfChanged(\.agentSkills, try await engine.listAgentSkills(includeArchived: true))
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func upsertAgentSkill(_ skill: AgentSkillRecord) async -> String? {
        do {
            _ = try await engine.upsertAgentSkill(skill, source: .ui)
            assignIfChanged(\.agentSkills, try await engine.listAgentSkills(includeArchived: true))
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func archiveAgentSkill(skillId: String) async -> String? {
        do {
            _ = try await engine.archiveAgentSkill(id: skillId, updatedBy: "human owner", source: .ui)
            assignIfChanged(\.agentSkills, try await engine.listAgentSkills(includeArchived: true))
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func refreshPMProfiles() async -> String? {
        await runLatestPMInboxRefresh(domain: .pmProfiles, load: {
            try await self.engine.listPMProfiles()
        }) { [weak self] profiles in
            self?.pmProfiles = profiles
        }
    }

    func refreshPMCommunicationSessions() async -> String? {
        await runLatestPMInboxRefresh(domain: .pmCommunicationSessions, load: {
            try await self.engine.listPMCommunicationSessions()
        }) { [weak self] sessions in
            guard let self else { return }
            if self.assignIfChanged(\.pmCommunicationSessions, sessions) {
                self.rebuildOwnerSurfaceProjections()
            }
        }
    }

    func refreshPMCommunicationMessages(
        refreshContextPack: Bool = true
    ) async -> String? {
        let result = await runLatestPMInboxRefresh(domain: .pmCommunicationMessages, load: {
            try await self.engine.listPMCommunicationMessages()
        }) { [weak self] messages in
            guard let self else { return }
            if self.assignIfChanged(\.pmCommunicationMessages, messages) {
                self.rebuildOwnerSurfaceProjections()
            }
        }
        if refreshContextPack {
            _ = await refreshPMContextPack()
        }
        return result
    }

    func refreshPMMandates() async -> String? {
        do {
            pmMandates = try await engine.listPMMandates()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func refreshPMInstructions() async -> String? {
        do {
            pmInstructions = try await engine.listPMInstructions()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func ensureInAppPMUserCommunicationSession() async -> String? {
        do {
            _ = try await engine.ensureInAppPMUserCommunicationSession(
                pmId: preferredPMIDForCommunication,
                source: .ui
            )
            assignIfChanged(\.pmCommunicationSessions, try await engine.listPMCommunicationSessions())
            rebuildOwnerSurfaceProjections()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func refreshTelegramBridgeStatus() async -> String? {
        assignIfChanged(\.telegramBridgeStatus, await engine.telegramBridgeStatus())
        lastTelegramBridgeStatusRefreshAt = Date()
        return nil
    }

    private func refreshTelegramBridgeStatusFromPollingIfNeeded(force: Bool = false) async {
        let now = Date()
        guard force
            || lastTelegramBridgeStatusRefreshAt == nil
            || now.timeIntervalSince(lastTelegramBridgeStatusRefreshAt ?? now) >= Self.telegramBridgePollingStatusRefreshInterval
        else { return }
        _ = await refreshTelegramBridgeStatus()
    }

    func pollTelegramBridgeUpdates() async -> String? {
        do {
            let result = try await engine.pollTelegramUpdates(
                pmId: preferredPMIDForCommunication,
                source: .ui
            )
            let communicationChanged = telegramPollChangedPMCommunication(result)
            if communicationChanged {
                _ = await refreshPMCommunicationSessions()
                _ = await refreshPMCommunicationMessages()
            }
            if communicationChanged || result.statusRefreshRecommended {
                await refreshTelegramBridgeStatusFromPollingIfNeeded(force: true)
            }
            return nil
        } catch TelegramBridgeError.missingBotToken {
            await refreshTelegramBridgeStatusFromPollingIfNeeded()
            return TelegramBridgeError.missingBotToken.localizedDescription
        } catch {
            _ = await refreshPMCommunicationSessions()
            _ = await refreshPMCommunicationMessages()
            await refreshTelegramBridgeStatusFromPollingIfNeeded(force: true)
            return error.localizedDescription
        }
    }

    private func telegramPollChangedPMCommunication(_ result: TelegramBridgePollResult) -> Bool {
        result.ingestedMessageCount > 0
            || result.approvalResponseCount > 0
            || result.clarificationReplyCount > 0
    }

    private func startTelegramBridgePollingLoopIfNeeded() {
        guard telegramBridgePollingTask == nil else { return }
        telegramBridgePollingTask = Task { [weak self] in
            guard let self else { return }
            while Task.isCancelled == false {
                try? await Task.sleep(nanoseconds: Self.telegramBridgePollIntervalNanoseconds)
                guard Task.isCancelled == false else { break }

                _ = await self.pollTelegramBridgeUpdates()
            }
        }
    }

    func refreshPMContextPack() async -> String? {
        await runLatestPMInboxRefresh(domain: .pmContextPack, load: {
            try await self.engine.assemblePMContextPack()
        }) { [weak self] contextPack in
            self?.pmContextPack = contextPack
            self?.scheduleAutomaticStandingReviewConsumptionIfNeeded()
        }
    }

    func completePendingStandingReviewCycle(
        source: AuditEventSource = .ui
    ) async -> (summaryRecorded: Bool, error: String?) {
        do {
            let summary = try await engine.completePendingStandingReviewCycle(source: source)
            _ = await refreshAnalystStandingReports()
            _ = await refreshPMDecisions()
            _ = await refreshPMApprovalRequests()
            _ = await refreshPMContextPack()
            scheduleAutomaticStandingReviewConsumptionIfNeeded()
            return (summary != nil, nil)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    private func scheduleAutomaticStandingReviewConsumptionIfNeeded() {
        let pendingCount = pmContextPack?.operatingContext.standingReviewQueue.pendingCount ?? 0
        guard pendingCount > 0 else {
            return
        }

        standingReviewAutoConsumeRequested = true
        guard standingReviewAutoConsumeTask == nil else {
            return
        }

        standingReviewAutoConsumeTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            while true {
                self.standingReviewAutoConsumeRequested = false
                try? await Task.sleep(nanoseconds: Self.standingReviewAutoConsumeDebounceNanoseconds)

                let pendingCount = self.pmContextPack?.operatingContext.standingReviewQueue.pendingCount ?? 0
                if pendingCount > 0 {
                    _ = await self.completePendingStandingReviewCycle(source: .engine)
                }

                let remainingPendingCount = self.pmContextPack?.operatingContext.standingReviewQueue.pendingCount ?? 0
                if remainingPendingCount > 0 {
                    self.standingReviewAutoConsumeRequested = true
                }

                if self.standingReviewAutoConsumeRequested == false {
                    self.standingReviewAutoConsumeTask = nil
                    return
                }
            }
        }
    }

    func refreshPortfolioStrategyBrief() async -> String? {
        do {
            assignIfChanged(\.portfolioStrategyBrief, try await engine.getPortfolioStrategyBrief())
            rebuildOwnerSurfaceProjections()
            _ = await refreshPMContextPack()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func refreshPortfolioWatchChartWallConfiguration() async -> String? {
        do {
            portfolioWatchChartWallConfiguration = try await engine.getPortfolioWatchChartWallConfiguration()
            rebuildPortfolioWatchChartWall()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func upsertPortfolioWatchChartWallSelection(_ selectedSymbols: [String]) async -> String? {
        let base = portfolioWatchChartWallConfiguration
            ?? PortfolioWatchChartWallConfiguration.default(
                watchlistSymbols: watchlistSymbols,
                now: Date()
            )
        let proposedSelection = selectedSymbols.isEmpty && watchlistSymbols.isEmpty == false
            ? PortfolioWatchChartWallConfiguration.effectiveSelectedSymbols(
                selectedSymbols: [],
                watchlistSymbols: watchlistSymbols
            )
            : selectedSymbols

        let candidate = PortfolioWatchChartWallConfiguration(
            configurationId: base.configurationId,
            selectedSymbols: proposedSelection,
            updatedBy: "owner",
            updateSource: .ui,
            createdAt: base.createdAt,
            updatedAt: Date()
        )

        do {
            portfolioWatchChartWallConfiguration = try await engine.upsertPortfolioWatchChartWallConfiguration(
                candidate,
                source: .ui
            )
            rebuildPortfolioWatchChartWall()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func upsertPortfolioStrategyBrief(_ brief: PortfolioStrategyBrief) async -> String? {
        do {
            assignIfChanged(
                \.portfolioStrategyBrief,
                try await engine.upsertPortfolioStrategyBrief(brief, source: .ui)
            )
            rebuildOwnerSurfaceProjections()
            _ = await refreshPMContextPack()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func revisePortfolioStrategyBriefFromConversation(
        messageId: String,
        title: String,
        documentBody: String,
        revisionSummary: String
    ) async -> String? {
        let trimmedPMID = preferredPMIDForCommunication?.trimmingCharacters(in: .whitespacesAndNewlines)
        let updatedBy = pmProfiles.first(where: { $0.pmId == trimmedPMID })?.displayName
            ?? trimmedPMID
            ?? "pm"

        do {
            assignIfChanged(
                \.portfolioStrategyBrief,
                try await engine.revisePortfolioStrategyBriefFromCommunicationMessage(
                    messageId: messageId,
                    title: title,
                    documentBody: documentBody,
                    updatedBy: updatedBy,
                    revisionSummary: revisionSummary,
                    source: .ui
                )
            )
            rebuildOwnerSurfaceProjections()
            _ = await refreshPMCommunicationMessages()
            _ = await refreshPMContextPack()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func refreshRecentNewsAnalystRuntimeSettings() async -> String? {
        do {
            let loaded = try await engine.getRecentNewsAnalystRuntimeSettings()
            recentNewsAnalystRuntimeSettings = latestRuntimeSettingsValue(
                current: recentNewsAnalystRuntimeSettings,
                incoming: loaded,
                updatedAt: \.updatedAt
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func refreshStandingBenchAnalystRuntimeSettings() async -> String? {
        do {
            let loaded = try await engine.getStandingBenchAnalystRuntimeSettings()
            standingBenchAnalystRuntimeSettings = latestRuntimeSettingsValue(
                current: standingBenchAnalystRuntimeSettings,
                incoming: loaded,
                updatedAt: \.updatedAt
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func refreshPMRuntimeSettings() async -> String? {
        do {
            pmRuntimeSettings = try await engine.getPMRuntimeSettings()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func upsertPMRuntimeSettings(
        _ settings: PMRuntimeSettings
    ) async -> String? {
        do {
            pmRuntimeSettings = try await engine.upsertPMRuntimeSettings(
                settings,
                source: .ui
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func validatePMRuntimeCandidate(
        runtimeIdentifier: String,
        reasoningMode: AnalystRuntimeReasoningMode?,
        providerKind: LLMProviderKind,
        credentialProfileId: String
    ) async -> RuntimeValidationRecord {
        await engine.validatePMRuntimeCandidate(
            runtimeIdentifier: runtimeIdentifier,
            reasoningMode: reasoningMode,
            providerKind: providerKind,
            credentialProfileId: credentialProfileId
        )
    }

    func upsertRecentNewsAnalystRuntimeSettings(
        _ settings: RecentNewsAnalystRuntimeSettings
    ) async -> String? {
        do {
            recentNewsAnalystRuntimeSettings = try await engine.upsertRecentNewsAnalystRuntimeSettings(
                settings,
                source: .ui
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func upsertStandingBenchAnalystRuntimeSettings(
        _ settings: StandingBenchAnalystRuntimeSettings
    ) async -> String? {
        do {
            standingBenchAnalystRuntimeSettings = try await engine.upsertStandingBenchAnalystRuntimeSettings(
                settings,
                source: .ui
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func validateRecentNewsAnalystRuntimeCandidate(
        runtimeIdentifier: String,
        reasoningMode: AnalystRuntimeReasoningMode?,
        providerKind: LLMProviderKind,
        credentialProfileId: String
    ) async -> RuntimeValidationRecord {
        await engine.validateRecentNewsAnalystRuntimeCandidate(
            runtimeIdentifier: runtimeIdentifier,
            reasoningMode: reasoningMode,
            providerKind: providerKind,
            credentialProfileId: credentialProfileId
        )
    }

    func validateStandingBenchAnalystRuntimeCandidate(
        runtimeIdentifier: String,
        reasoningMode: AnalystRuntimeReasoningMode?,
        providerKind: LLMProviderKind,
        credentialProfileId: String
    ) async -> RuntimeValidationRecord {
        await engine.validateStandingBenchAnalystRuntimeCandidate(
            runtimeIdentifier: runtimeIdentifier,
            reasoningMode: reasoningMode,
            providerKind: providerKind,
            credentialProfileId: credentialProfileId
        )
    }

    func refreshPMDecisions() async -> String? {
        let result = await runLatestPMInboxRefresh(domain: .pmDecisions, load: {
            try await self.engine.listPMDecisions()
        }) { [weak self] decisions in
            guard let self else { return }
            self.assignIfChanged(\.pmDecisions, decisions)
            self.rebuildOwnerSurfaceProjections()
        }
        _ = await refreshPMContextPack()
        return result
    }

    func refreshPMApprovalRequests() async -> String? {
        let result = await runLatestPMInboxRefresh(domain: .pmApprovalRequests, load: {
            try await self.engine.listPMApprovalRequests()
        }) { [weak self] approvalRequests in
            guard let self else { return }
            self.assignIfChanged(\.pmApprovalRequests, approvalRequests)
            let validIDs = Set(approvalRequests.map(\.approvalRequestId))
            self.assignIfChanged(
                \.pmExecutionRoutingAssessmentsByApprovalRequestID,
                self.pmExecutionRoutingAssessmentsByApprovalRequestID.filter {
                    validIDs.contains($0.key)
                }
            )
            self.rebuildOwnerSurfaceProjections()
        }
        _ = await refreshPMContextPack()
        await refreshPortfolioIntelligenceSnapshotFromStore()
        return result
    }

    func refreshPMDelegations() async -> String? {
        let result = await runLatestPMInboxRefresh(domain: .pmDelegations, load: {
            try await self.engine.listPMDelegations()
        }) { [weak self] delegations in
            guard let self else { return }
            self.assignIfChanged(\.pmDelegations, delegations)
            self.rebuildOwnerSurfaceProjections()
        }
        _ = await refreshPMContextPack()
        return result
    }

    func sendPMCommunicationMessage(
        sessionId: String,
        senderRole: PMCommunicationSenderRole,
        body: String,
        replyToMessageId: String? = nil
    ) async -> String? {
        do {
            _ = try await engine.createPMCommunicationMessage(
                sessionId: sessionId,
                senderRole: senderRole,
                senderId: senderRole == .pm ? preferredPMIDForCommunication : "owner",
                body: body,
                replyToMessageId: replyToMessageId,
                source: .ui
            )
            _ = await refreshPMCommunicationSessions()
            _ = await refreshPMCommunicationMessages()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func sendOwnerConversationMessage(
        body: String,
        sessionId: String? = nil
    ) async -> String? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return nil
        }
        do {
            var targetSession: PMCommunicationSession
            if let sessionId {
                if let existingSession = pmCommunicationSessions.first(where: { $0.sessionId == sessionId }) {
                    targetSession = existingSession
                } else {
                    targetSession = try await engine.getPMCommunicationSession(id: sessionId)
                }
            } else {
                targetSession = try await engine.ensureInAppPMUserCommunicationSession(
                    pmId: preferredPMIDForCommunication,
                    source: .ui
                )
                upsertLocalPMCommunicationSession(targetSession)
            }

            if targetSession.channel != .inApp {
                targetSession = try await engine.ensureInAppPMUserCommunicationSession(
                    pmId: preferredPMIDForCommunication,
                    source: .ui
                )
                upsertLocalPMCommunicationSession(targetSession)
            }

            let ownerMessage = try await engine.createPMCommunicationMessage(
                sessionId: targetSession.sessionId,
                senderRole: .owner,
                senderId: "owner",
                body: trimmed,
                source: .ui
            )
            upsertLocalPMCommunicationSession(
                PMCommunicationSession(
                    sessionId: targetSession.sessionId,
                    channel: targetSession.channel,
                    externalConversationId: targetSession.externalConversationId,
                    pmId: targetSession.pmId,
                    participantId: targetSession.participantId,
                    participantDisplayName: targetSession.participantDisplayName,
                    status: targetSession.status,
                    createdAt: targetSession.createdAt,
                    updatedAt: ownerMessage.sentAt
                )
            )
            upsertLocalPMCommunicationMessage(ownerMessage)
            _ = await refreshPMContextPack()
            Task { @MainActor in
                await finishPMConversationReply(
                    ownerMessageId: ownerMessage.messageId,
                    sessionId: targetSession.sessionId
                )
            }
            return nil
        } catch {
            _ = await refreshPMCommunicationSessions()
            _ = await refreshPMCommunicationMessages()
            return error.localizedDescription
        }
    }

    private func finishPMConversationReply(
        ownerMessageId: String,
        sessionId: String
    ) async {
        do {
            let reply = try await engine.generatePMConversationReply(
                to: ownerMessageId,
                source: .ui
            )
            upsertLocalPMCommunicationMessage(reply)
            if let existingSession = pmCommunicationSessions.first(where: { $0.sessionId == sessionId }) {
                upsertLocalPMCommunicationSession(
                    PMCommunicationSession(
                        sessionId: existingSession.sessionId,
                        channel: existingSession.channel,
                        externalConversationId: existingSession.externalConversationId,
                        pmId: existingSession.pmId,
                        participantId: existingSession.participantId,
                        participantDisplayName: existingSession.participantDisplayName,
                        status: existingSession.status,
                        createdAt: existingSession.createdAt,
                        updatedAt: reply.sentAt
                    )
                )
            }
        } catch {
            // The engine records a bounded system note when reply generation fails.
        }
        _ = await refreshPMCommunicationSessions()
        _ = await refreshPMCommunicationMessages()
        _ = await refreshPMContextPack()
    }

    private func upsertLocalPMCommunicationSession(_ session: PMCommunicationSession) {
        var sessions = pmCommunicationSessions.filter { $0.sessionId != session.sessionId }
        sessions.append(session)
        sessions.sort { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.sessionId < rhs.sessionId
            }
            return lhs.updatedAt > rhs.updatedAt
        }
        assignIfChanged(\.pmCommunicationSessions, sessions)
        rebuildOwnerSurfaceProjections()
    }

    private func upsertLocalPMCommunicationMessage(_ message: PMCommunicationMessage) {
        var messages = pmCommunicationMessages.filter { $0.messageId != message.messageId }
        messages.append(message)
        messages.sort { lhs, rhs in
            if lhs.sentAt == rhs.sentAt {
                return lhs.messageId < rhs.messageId
            }
            return lhs.sentAt < rhs.sentAt
        }
        assignIfChanged(\.pmCommunicationMessages, messages)
        rebuildOwnerSurfaceProjections()
    }

    func latestInAppOwnerConversationSessionID() -> String? {
        pmCommunicationSessions
            .filter { $0.channel == .inApp && isExercisePMCommunicationSession($0) == false }
            .sorted { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.sessionId < rhs.sessionId
                }
                return lhs.updatedAt > rhs.updatedAt
            }
            .first?.sessionId
    }

    func hasVisiblePMConversationMessage(
        body: String,
        sessionId: String? = nil
    ) -> Bool {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return false
        }
        let targetSessionID = sessionId ?? latestInAppOwnerConversationSessionID()
        return pmCommunicationMessages.contains { message in
            message.senderRole == .owner
                && message.body.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed
                && (targetSessionID == nil || message.sessionId == targetSessionID)
        }
    }

    func hasVisiblePMConversationReply(
        replyingTo messageId: String
    ) -> Bool {
        pmCommunicationMessages.contains { message in
            message.senderRole == .pm && message.replyToMessageId == messageId
        }
    }

    func promotePMCommunicationMessageToNotebook(
        messageId: String,
        title: String,
        body: String
    ) async -> String? {
        guard let pmId = preferredPMIDForCommunication else {
            return "PM profile is required before promoting communication."
        }
        do {
            _ = try await engine.promotePMCommunicationMessageToNotebookEntry(
                messageId: messageId,
                pmId: pmId,
                title: title,
                body: body,
                source: .ui
            )
            _ = await refreshPMCommunicationMessages()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func promotePMCommunicationMessageToInstruction(
        messageId: String,
        title: String,
        body: String
    ) async -> String? {
        guard let pmId = preferredPMIDForCommunication else {
            return "PM profile is required before promoting communication."
        }
        do {
            _ = try await engine.promotePMCommunicationMessageToInstruction(
                messageId: messageId,
                pmId: pmId,
                title: title,
                body: body,
                source: .ui
            )
            _ = await refreshPMCommunicationMessages()
            _ = await refreshPMContextPack()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func promotePMCommunicationMessageToDecision(
        messageId: String,
        title: String,
        summary: String
    ) async -> String? {
        guard let pmId = preferredPMIDForCommunication else {
            return "PM profile is required before promoting communication."
        }
        do {
            _ = try await engine.promotePMCommunicationMessageToDecision(
                messageId: messageId,
                pmId: pmId,
                title: title,
                summary: summary,
                source: .ui
            )
            _ = await refreshPMDecisions()
            _ = await refreshPMCommunicationMessages()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func promotePMCommunicationMessageToApprovalRequest(
        messageId: String,
        subject: String,
        rationale: String
    ) async -> String? {
        guard let pmId = preferredPMIDForCommunication else {
            return "PM profile is required before promoting communication."
        }
        do {
            _ = try await engine.promotePMCommunicationMessageToApprovalRequest(
                messageId: messageId,
                pmId: pmId,
                subject: subject,
                rationale: rationale,
                source: .ui
            )
            _ = await refreshPMApprovalRequests()
            _ = await refreshPMCommunicationMessages()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func promotePMCommunicationMessageToDelegation(
        messageId: String,
        charterId: String,
        title: String,
        rationale: String
    ) async -> String? {
        guard let pmId = preferredPMIDForCommunication else {
            return "PM profile is required before promoting communication."
        }
        do {
            _ = try await engine.promotePMCommunicationMessageToDelegation(
                messageId: messageId,
                pmId: pmId,
                charterId: charterId,
                title: title,
                rationale: rationale,
                source: .ui
            )
            _ = await refreshPMDelegations()
            _ = await refreshPMCommunicationMessages()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func resolvePMDelegationWorkerIssue(
        delegationId: String
    ) async -> String? {
        do {
            _ = try await engine.resolvePMDelegationWorkerIssue(
                delegationId: delegationId,
                resolvedBy: "owner",
                source: .ui
            )
            assignIfChanged(\.pmDelegations, try await engine.listPMDelegations())
            rebuildOwnerSurfaceProjections()
            _ = await refreshPMContextPack()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func resolveActivePMDelegationWorkerIssues() async -> String? {
        do {
            _ = try await engine.resolveActivePMDelegationWorkerIssues(
                resolvedBy: "owner",
                source: .ui
            )
            assignIfChanged(\.pmDelegations, try await engine.listPMDelegations())
            rebuildOwnerSurfaceProjections()
            _ = await refreshPMContextPack()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func respondToPMApprovalRequest(
        requestID: String,
        response: PMApprovalRequestOwnerResponse
    ) async -> String? {
        do {
            let request = try await engine.respondToPMApprovalRequest(
                requestId: requestID,
                response: response,
                source: .ui
            )
            assignIfChanged(\.pmApprovalRequests, try await engine.listPMApprovalRequests())
            assignIfChanged(
                \.analystStrategyFollowUpCandidates,
                try await engine.listAnalystStrategyFollowUpCandidates()
            )
            assignIfChanged(\.portfolioStrategyBrief, try await engine.getPortfolioStrategyBrief())
            rebuildOwnerSurfaceProjections()
            _ = await refreshPMContextPack()
            if let proposalId = request.proposalId {
                _ = await fetchProposalDetail(id: proposalId)
            }
            _ = await refreshPMExecutionRoutingAssessment(approvalRequestID: requestID)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func sendTelegramApprovalRequestPrompt(
        approvalRequestID: String,
        sessionID: String
    ) async -> String? {
        do {
            _ = try await engine.sendTelegramApprovalRequestPrompt(
                approvalRequestId: approvalRequestID,
                sessionId: sessionID,
                source: .ui
            )
            _ = await refreshPMCommunicationSessions()
            _ = await refreshPMCommunicationMessages()
            _ = await refreshTelegramBridgeStatus()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func createPMApprovalRequestFromDecision(
        decisionID: String,
        subject: String? = nil,
        rationale: String? = nil
    ) async -> String? {
        do {
            let request = try await engine.createPMApprovalRequestFromDecision(
                decisionId: decisionID,
                subject: subject,
                rationale: rationale,
                source: .ui
            )
            assignIfChanged(\.pmApprovalRequests, try await engine.listPMApprovalRequests())
            assignIfChanged(\.pmDecisions, try await engine.listPMDecisions())
            rebuildOwnerSurfaceProjections()
            _ = await refreshPMContextPack()
            if let proposalId = request.proposalId {
                _ = await fetchProposalDetail(id: proposalId)
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func refreshPMExecutionRoutingAssessment(
        approvalRequestID: String
    ) async -> String? {
        do {
            let assessment = try await engine.assessPMExecutionRouting(
                approvalRequestId: approvalRequestID
            )
            pmExecutionRoutingAssessmentsByApprovalRequestID[approvalRequestID] = assessment
            return nil
        } catch {
            pmExecutionRoutingAssessmentsByApprovalRequestID.removeValue(forKey: approvalRequestID)
            return error.localizedDescription
        }
    }

    func routePMExecutionApprovedIntent(
        approvalRequestID: String
    ) async -> String? {
        do {
            let assessment = try await engine.routePMExecutionApprovedIntent(
                approvalRequestId: approvalRequestID,
                source: .ui
            )
            pmExecutionRoutingAssessmentsByApprovalRequestID[approvalRequestID] = assessment
            _ = await refreshSnapshotFromStore()
            _ = await refreshPMApprovalRequests()
            if let proposalId = assessment.proposalId {
                _ = await fetchProposalDetail(id: proposalId)
                _ = await fetchProposalRuns(proposalID: proposalId)
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func acknowledgePMApprovalRequest(
        requestID: String
    ) async -> String? {
        do {
            _ = try await engine.acknowledgePMApprovalRequest(
                requestId: requestID,
                acknowledgedBy: "owner",
                source: .ui
            )
            assignIfChanged(\.pmApprovalRequests, try await engine.listPMApprovalRequests())
            rebuildOwnerSurfaceProjections()
            _ = await refreshPMContextPack()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func archivePMExerciseArtifacts() async throws -> PMExerciseArtifactArchiveSummary {
        let summary = try await engine.archivePMExerciseArtifacts(source: .ui)
        assignIfChanged(\.pmDecisions, try await engine.listPMDecisions())
        assignIfChanged(\.pmApprovalRequests, try await engine.listPMApprovalRequests())
        assignIfChanged(\.pmDelegations, try await engine.listPMDelegations())
        assignIfChanged(\.pmCommunicationSessions, try await engine.listPMCommunicationSessions())
        assignIfChanged(\.pmCommunicationMessages, try await engine.listPMCommunicationMessages())
        rebuildOwnerSurfaceProjections()
        _ = await refreshPMContextPack()
        return summary
    }

    func upsertAnalystCharter(_ charter: AnalystCharter) async -> String? {
        do {
            _ = try await engine.upsertAnalystCharter(charter, source: .ui)
            assignIfChanged(\.analystCharters, try await engine.listAnalystCharters())
            rebuildOwnerSurfaceProjections()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func refreshAnalystTasks() async -> String? {
        await runLatestPMInboxRefresh(domain: .analystTasks, load: {
            try await self.engine.listAnalystTasks()
        }) { [weak self] tasks in
            guard let self else { return }
            self.assignIfChanged(\.analystTasks, tasks)
            self.rebuildOwnerSurfaceProjections()
        }
    }

    func refreshAnalystFindings() async -> String? {
        await runLatestPMInboxRefresh(domain: .analystFindings, load: {
            try await self.engine.listAnalystFindings()
        }) { [weak self] findings in
            guard let self else { return }
            self.assignIfChanged(\.analystFindings, findings)
            self.rebuildOwnerSurfaceProjections()
        }
    }

    func refreshAnalystSourceAccessSuggestions() async -> String? {
        await runLatestPMInboxRefresh(domain: .analystSourceAccessSuggestions, load: {
            try await self.engine.listAnalystSourceAccessSuggestions()
        }) { [weak self] suggestions in
            guard let self else { return }
            self.assignIfChanged(\.analystSourceAccessSuggestions, suggestions)
            self.rebuildOwnerSurfaceProjections()
        }
    }

    func applyAnalystSourceAccessSuggestionAction(
        suggestionID: String,
        action: AnalystSourceAccessSuggestionAction
    ) async -> String? {
        do {
            let updatedBy = preferredPMIDForCommunication ?? "pm-control-plane"
            _ = try await engine.applyAnalystSourceAccessSuggestionAction(
                suggestionId: suggestionID,
                action: action,
                updatedBy: updatedBy,
                source: .ui
            )
            assignIfChanged(
                \.analystSourceAccessSuggestions,
                try await engine.listAnalystSourceAccessSuggestions()
            )
            assignIfChanged(\.analystCharters, try await engine.listAnalystCharters())
            rebuildOwnerSurfaceProjections()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func refreshAnalystEvidenceBundles() async -> String? {
        await runLatestPMInboxRefresh(domain: .analystEvidenceBundles, load: {
            try await self.engine.listAnalystEvidenceBundles()
        }) { [weak self] bundles in
            guard let self else { return }
            self.assignIfChanged(\.analystEvidenceBundles, bundles)
            self.rebuildOwnerSurfaceProjections()
        }
    }

    func refreshAnalystMemos() async -> String? {
        await runLatestPMInboxRefresh(domain: .analystMemos, load: {
            try await self.engine.listAnalystMemos()
        }) { [weak self] memos in
            guard let self else { return }
            self.assignIfChanged(\.analystMemos, memos)
            self.rebuildOwnerSurfaceProjections()
        }
    }

    func refreshAnalystStrategyImplications() async -> String? {
        await runLatestPMInboxRefresh(domain: .analystStrategyImplications, load: {
            try await self.engine.listAnalystStrategyImplications()
        }) { [weak self] implications in
            self?.analystStrategyImplications = implications
        }
    }

    func refreshAnalystStrategyFollowUpCandidates() async -> String? {
        await runLatestPMInboxRefresh(domain: .analystStrategyFollowUpCandidates, load: {
            try await self.engine.listAnalystStrategyFollowUpCandidates()
        }) { [weak self] candidates in
            self?.analystStrategyFollowUpCandidates = candidates
        }
    }

    func refreshAnalystStandingReports() async -> String? {
        await runLatestPMInboxRefresh(domain: .analystStandingReports, load: {
            try await self.engine.listAnalystStandingReports()
        }) { [weak self] reports in
            guard let self else { return }
            self.assignIfChanged(\.analystStandingReports, reports)
            self.rebuildOwnerSurfaceProjections()
        }
    }

    func upsertAnalystTask(_ task: AnalystTask) async -> String? {
        do {
            _ = try await engine.upsertAnalystTask(task, source: .ui)
            assignIfChanged(\.analystTasks, try await engine.listAnalystTasks())
            rebuildOwnerSurfaceProjections()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func upsertAnalystStrategyImplication(_ implication: AnalystStrategyImplicationRecord) async -> String? {
        do {
            _ = try await engine.upsertAnalystStrategyImplication(implication, source: .ui)
            analystStrategyImplications = try await engine.listAnalystStrategyImplications()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func upsertAnalystStrategyFollowUpCandidate(
        _ candidate: AnalystStrategyFollowUpCandidateRecord
    ) async -> String? {
        do {
            _ = try await engine.upsertAnalystStrategyFollowUpCandidate(candidate, source: .ui)
            analystStrategyFollowUpCandidates = try await engine.listAnalystStrategyFollowUpCandidates()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func applyAnalystStrategyFollowUpCandidateToStrategyBrief(
        candidateID: String,
        updatedBy: String
    ) async -> String? {
        do {
            _ = try await engine.applyAnalystStrategyFollowUpCandidateToStrategyBrief(
                candidateId: candidateID,
                updatedBy: updatedBy,
                source: .ui
            )
            assignIfChanged(
                \.analystStrategyFollowUpCandidates,
                try await engine.listAnalystStrategyFollowUpCandidates()
            )
            assignIfChanged(\.portfolioStrategyBrief, try await engine.getPortfolioStrategyBrief())
            rebuildOwnerSurfaceProjections()
            _ = await refreshPMContextPack()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func routeAnalystStrategyFollowUpCandidateToOwnerApproval(
        candidateID: String
    ) async -> String? {
        do {
            _ = try await engine.routeAnalystStrategyFollowUpCandidateToOwnerApproval(
                candidateId: candidateID,
                source: .ui
            )
            assignIfChanged(
                \.analystStrategyFollowUpCandidates,
                try await engine.listAnalystStrategyFollowUpCandidates()
            )
            assignIfChanged(\.pmApprovalRequests, try await engine.listPMApprovalRequests())
            rebuildOwnerSurfaceProjections()
            _ = await refreshPMContextPack()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func convertAnalystStrategyFollowUpCandidateToInstruction(
        candidateID: String
    ) async -> String? {
        do {
            _ = try await engine.convertAnalystStrategyFollowUpCandidateToInstruction(
                candidateId: candidateID,
                source: .ui
            )
            analystStrategyFollowUpCandidates = try await engine.listAnalystStrategyFollowUpCandidates()
            pmInstructions = try await engine.listPMInstructions()
            _ = await refreshPMContextPack()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func convertAnalystStrategyFollowUpCandidateToMandate(
        candidateID: String
    ) async -> String? {
        do {
            _ = try await engine.convertAnalystStrategyFollowUpCandidateToMandate(
                candidateId: candidateID,
                source: .ui
            )
            analystStrategyFollowUpCandidates = try await engine.listAnalystStrategyFollowUpCandidates()
            pmMandates = try await engine.listPMMandates()
            _ = await refreshPMContextPack()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func launchAnalystWorkerOnce(
        charterID: String,
        taskID: String?,
        draftSignal: Bool
    ) async -> String? {
        do {
            lastAnalystWorkerLaunch = try await engine.launchAnalystWorkerOnce(
                charterID: charterID,
                taskID: taskID,
                draftSignal: draftSignal,
                source: .ui
            )
            _ = await refreshAnalystTasks()
            _ = await refreshAnalystMemos()
            _ = await refreshAnalystFindings()
            _ = await refreshAnalystEvidenceBundles()
            _ = await refreshAnalystSourceAccessSuggestions()
            _ = await refreshAnalystStrategyImplications()
            _ = await refreshAnalystStrategyFollowUpCandidates()
            _ = await refreshAnalystStandingReports()
            _ = await refreshPMContextPack()
            _ = await refreshSignals(limit: 200)
            _ = await refreshPMDelegations()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func launchAnalystWorkerForDelegation(
        delegationID: String,
        draftSignal: Bool,
        draftProposal: Bool
    ) async -> String? {
        do {
            lastAnalystWorkerLaunch = try await engine.launchAnalystWorkerForPMDelegation(
                delegationID: delegationID,
                draftSignal: draftSignal,
                draftProposal: draftProposal,
                source: .ui
            )
            _ = await refreshPMDelegations()
            _ = await refreshAnalystTasks()
            _ = await refreshAnalystMemos()
            _ = await refreshAnalystFindings()
            _ = await refreshAnalystEvidenceBundles()
            _ = await refreshAnalystSourceAccessSuggestions()
            _ = await refreshAnalystStrategyImplications()
            _ = await refreshAnalystStrategyFollowUpCandidates()
            _ = await refreshAnalystStandingReports()
            _ = await refreshPMContextPack()
            _ = await refreshSignals(limit: 200)
            return nil
        } catch {
            _ = await refreshPMDelegations()
            return error.localizedDescription
        }
    }

    func submitPMDelegationFollowUp(
        _ request: PMDelegationFollowUpRequest
    ) async -> String? {
        do {
            let result = try await engine.submitPMDelegationFollowUp(request, source: .ui)
            lastPMDelegationFollowUp = result
            if let launchResult = result.launchResult {
                lastAnalystWorkerLaunch = launchResult
            }
            _ = await refreshPMDelegations()
            _ = await refreshPMDecisions()
            _ = await refreshAnalystTasks()
            _ = await refreshAnalystMemos()
            _ = await refreshAnalystFindings()
            _ = await refreshAnalystEvidenceBundles()
            _ = await refreshAnalystStrategyImplications()
            _ = await refreshAnalystStrategyFollowUpCandidates()
            _ = await refreshAnalystStandingReports()
            _ = await refreshSignals(limit: 200)
            return nil
        } catch {
            _ = await refreshPMDelegations()
            _ = await refreshPMDecisions()
            return error.localizedDescription
        }
    }

    func acknowledgeSignal(id: String) async -> String? {
        do {
            _ = try await engine.acknowledgeSignal(id: id, source: .ui)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func archiveSignal(id: String) async -> String? {
        do {
            _ = try await engine.archiveSignal(id: id, source: .ui)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func draftProposalFromSignal(id: String) async -> String? {
        do {
            let proposal = try await engine.draftProposalFromSignal(
                id: id,
                strategyID: "heartbeat",
                source: .ui
            )
            proposalDetailsByID[proposal.proposalId] = proposal
            _ = await fetchProposalRuns(proposalID: proposal.proposalId)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func marketQuote(for symbol: String) -> MarketQuote? {
        let normalized = symbol
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard !normalized.isEmpty else {
            return nil
        }
        switch MarketSymbolClassifier.instrumentType(for: normalized) {
        case .equity:
            return quotesBySymbol[normalized]
        case .option:
            return optionQuotesBySymbol[normalized]
        }
    }

    func optionContract(for symbol: String) -> OptionContract? {
        let normalized = symbol
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        return optionContractsBySymbol[normalized]
    }

    func currentPositionQuantity(for symbol: String) -> Decimal {
        let normalized = symbol
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard !normalized.isEmpty,
              let row = positions.first(where: { $0.symbol == normalized })
        else {
            return 0
        }

        let parsed = Decimal(string: row.qty, locale: Locale(identifier: "en_US_POSIX")) ?? 0
        if row.side.lowercased() == "short", parsed > 0 {
            return -parsed
        }
        return parsed
    }

    var selectedEnvironmentKeysFound: Bool {
        visibleStatusPresentation.selectedEnvironmentKeysFound
    }

    var selectedEnvironmentSummary: String {
        visibleStatusPresentation.selectedEnvironmentSummary
    }

    var selectedEnvironmentName: String {
        visibleStatusPresentation.selectedEnvironmentName
    }

    var liveSafetyStatusLabel: String {
        visibleStatusPresentation.liveSafetyStatusLabel
    }

    var liveSafetyStatusColor: Color {
        makeLiveSafetyBannerSeverity(
            selectedEnvironment: selectedEnvironment,
            isArmedForLiveTrading: isArmedForLiveTrading,
            killSwitchEnabled: killSwitchEnabled,
            readinessStatus: alwaysOnReadiness.status
        ).color
    }

    var liveSafetyStatusDetail: String {
        visibleStatusPresentation.liveSafetyStatusDetail
    }

    var liveExecutionProtectionRequired: Bool {
        liveExecutionProtectionSettings.localUserPresenceRequiredForLiveOrders
    }

    var liveExecutionProtectionStatusLabel: String {
        visibleStatusPresentation.liveExecutionProtectionStatusLabel
    }

    var liveExecutionProtectionDetailText: String {
        visibleStatusPresentation.liveExecutionProtectionDetailText
    }

    var alwaysOnReadinessLabel: String {
        visibleStatusPresentation.alwaysOnReadinessLabel
    }

    var alwaysOnReadinessDetail: String {
        visibleStatusPresentation.alwaysOnReadinessDetail
    }

    var alwaysOnReadinessStatusColor: Color {
        switch alwaysOnReadiness.status {
        case .active:
            return .green
        case .recoveringAfterWake:
            return .blue
        case .degraded:
            return .orange
        case .pausedByHost, .needsAttention:
            return .red
        }
    }

    var tradeStreamOwnerFacingLabel: String {
        visibleStatusPresentation.tradeStreamOwnerFacingLabel
    }

    var marketDataOwnerFacingLabel: String {
        visibleStatusPresentation.marketDataOwnerFacingLabel
    }

    var workerLinkStatus: String {
        visibleStatusPresentation.workerLinkStatus
    }

    var ownerSystemExceptionCategories: [OwnerSystemExceptionCategoryPresentation] {
        visibleStatusPresentation.systemExceptionCategories
    }

    var commandCenterTopBarChips: [CommandCenterTopBarChipPresentation] {
        visibleStatusPresentation.commandCenterTopBarChips
    }

    var systemHealthMetrics: [SystemHealthMetricPresentation] {
        visibleStatusPresentation.systemHealthMetrics
    }

    var tradingDisabledReason: String? {
        guard selectedEnvironment == .live else {
            return nil
        }
        if killSwitchEnabled {
            return "Trading disabled by kill switch."
        }
        if !isArmedForLiveTrading {
            return "Live trading is disarmed."
        }
        return nil
    }

    var shortArmingSessionID: String {
        guard let armingSessionID else {
            return "-"
        }
        return String(armingSessionID.prefix(8))
    }

    func armLiveTrading() async {
        _ = await engine.armLiveTrading()
    }

    func disarmLiveTrading() async {
        await engine.disarmLiveTrading()
    }

    func setKillSwitchEnabled(_ enabled: Bool) async {
        await engine.setKillSwitchEnabled(enabled)
    }

    func refreshLiveExecutionProtectionSettings() async -> String? {
        assignIfChanged(\.liveExecutionProtectionSettings, await engine.getLiveExecutionProtectionSettings())
        rebuildVisibleStatusPresentation(reason: "live_execution_protection")
        return nil
    }

    func setLiveExecutionProtectionRequired(_ required: Bool) async -> String? {
        let result = await engine.setLiveExecutionProtectionRequired(required, source: .ui)
        assignIfChanged(\.liveExecutionProtectionSettings, result.settings)
        assignIfChanged(\.liveExecutionProtectionLastAuthResult, result.authorizationResult)
        rebuildVisibleStatusPresentation(reason: "live_execution_protection")
        await refreshEngineStatus()
        return result.applied ? nil : result.summary
    }

    func testLiveExecutionLocalAuthentication() async -> String? {
        let result = await engine.testLiveExecutionLocalAuthentication(source: .ui)
        liveExecutionProtectionLastAuthResult = result
        return result.summary
    }

    func startStrategy(id: String, paramsJSON: String) async -> String? {
        let params: [String: JSONValue]
        let trimmed = paramsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            params = [:]
        } else {
            do {
                params = try JSONValue.parseObject(json: trimmed)
            } catch {
                return "Parameters must be a valid JSON object."
            }
        }

        do {
            _ = try await engine.startStrategy(id: id, params: params, source: .ui)
            return nil
        } catch let runnerError as StrategyRunnerError {
            return runnerError.message
        } catch {
            return error.localizedDescription
        }
    }

    func stopStrategy(id: String) async -> String? {
        do {
            _ = try await engine.stopStrategy(id: id, source: .ui)
            return nil
        } catch let runnerError as StrategyRunnerError {
            return runnerError.message
        } catch {
            return error.localizedDescription
        }
    }

    func setStrategyParameters(id: String, paramsJSON: String) async -> String? {
        let params: [String: JSONValue]
        do {
            params = try JSONValue.parseObject(json: paramsJSON)
        } catch {
            return "Parameters must be a valid JSON object."
        }

        do {
            _ = try await engine.setStrategyParameters(id: id, params: params, source: .ui)
            return nil
        } catch let runnerError as StrategyRunnerError {
            return runnerError.message
        } catch {
            return error.localizedDescription
        }
    }

    func fetchProposalDetail(id: String) async -> String? {
        do {
            if let proposal = try await engine.getProposal(id: id) {
                proposalDetailsByID[id] = proposal
                return nil
            }
            return "Proposal not found."
        } catch {
            return error.localizedDescription
        }
    }

    func proposalDetail(id: String) -> StrategyProposal? {
        proposalDetailsByID[id]
    }

    func approveProposalForPaper(id: String, notes: String) async -> String? {
        do {
            let proposal = try await engine.approveProposalForPaper(
                id: id,
                reviewedBy: "human",
                notes: notes,
                source: .ui
            )
            proposalDetailsByID[id] = proposal
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func denyProposalForPaper(id: String, notes: String) async -> String? {
        do {
            let proposal = try await engine.denyProposalForPaper(
                id: id,
                reviewedBy: "human",
                notes: notes,
                source: .ui
            )
            proposalDetailsByID[id] = proposal
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func submitProposal(id: String) async -> String? {
        do {
            let proposal = try await engine.submitProposal(id: id, source: .ui)
            proposalDetailsByID[id] = proposal
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func startStrategyFromProposal(id: String) async -> String? {
        do {
            _ = try await engine.startStrategyFromProposal(
                proposalID: id,
                source: .ui
            )
            _ = await fetchProposalRuns(proposalID: id)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func fetchProposalRuns(proposalID: String) async -> String? {
        do {
            let runs = try await engine.listRuns(proposalID: proposalID)
            proposalRunSummariesByProposalID[proposalID] = runs
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func proposalRuns(proposalID: String) -> [PaperRunRecordSummary] {
        proposalRunSummariesByProposalID[proposalID] ?? []
    }

    func allKnownRuns() -> [PaperRunRecordSummary] {
        proposalRunSummariesByProposalID
            .values
            .flatMap { $0 }
            .sorted { lhs, rhs in
                if lhs.startedAt == rhs.startedAt {
                    return lhs.runId < rhs.runId
                }
                return lhs.startedAt > rhs.startedAt
            }
    }

    func fetchRunDetail(runID: String) async -> String? {
        do {
            let record = try await engine.getRun(runID: runID)
            runDetailsByID[runID] = record
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func runDetail(runID: String) -> PaperRunRecord? {
        runDetailsByID[runID]
    }

    func exportRunJSON(runID: String) async -> TicketSubmissionOutcome {
        do {
            return .success(try await engine.exportRunJSON(runID: runID))
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    func prettyProposalJSON(id: String) -> String? {
        guard let proposal = proposalDetailsByID[id] else {
            return nil
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try container.encode(formatter.string(from: date))
        }
        guard let data = try? encoder.encode(proposal) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func jsonText(for params: [String: JSONValue]) -> String {
        let value = JSONValue.object(params)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
              let text = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return text
    }

    func trimVolatileCaches(reason: String = "manual") -> String {
        let clearedProposalDetails = proposalDetailsByID.count
        let clearedRunDetails = runDetailsByID.count
        let clearedRoutineFilterEntries = pmConversationRoutineFilterCache.entryCount
        let clearedPortfolioTrackerSymbols = portfolioWatchSeriesTracker.trackedSymbolCount
        let clearedPortfolioTrackerPoints = portfolioWatchSeriesTracker.totalPointCount
        let clearedPortfolioCardCount = portfolioWatchChartCards.count
        let clearedPortfolioCardDisplayPoints = portfolioWatchChartCards.reduce(0) { $0 + $1.points.count }
        let clearedPortfolioCardSourcePoints = portfolioWatchChartCards.reduce(0) { $0 + $1.pointCount }
        let clearedPMConversationMessages = ownerPMConversationPresentation?.visibleMessages.count ?? 0
        let clearedPMConversationTextBytes = ownerPMConversationPresentation?.visibleMessages.reduce(0) { partial, message in
            partial + message.body.utf8.count
        } ?? 0
        let clearedOwnerDecisionDeskItems = selectedMainTab == .commandCenter ? 0 : ownerDecisionDeskItems.count
        let clearedOwnerBackgroundCards = selectedMainTab == .commandCenter ? 0 : ownerBackgroundActivityCards.count
        let clearedOwnerRecentChanges = selectedMainTab == .commandCenter ? 0 : ownerRecentChangePresentations.count

        proposalDetailsByID = [:]
        runDetailsByID = [:]
        pmConversationRoutineFilterCache = OwnerPMConversationRoutineFilterCache()
        strategyBriefRevisionCandidateCacheKey = nil
        pmConversationPresentationCacheKey = nil
        strategyBriefRevisionCandidate = nil
        if selectedMainTab != .commandCenter {
            releaseCommandCenterDerivedPresentations(reason: "volatile_cache_trim")
        }
        portfolioWatchSeriesTracker.removeAll(keepingCapacity: false)
        portfolioWatchChartCards = []
        if selectedMainTab == .marketWatch {
            rebuildPortfolioWatchChartWall(forcePublish: true, reason: "volatile_cache_trim")
        } else if selectedMainTab == .commandCenter {
            rebuildOwnerSurfaceProjections(reason: "volatile_cache_trim_visible_command_center")
        }

        volatileCacheTrimCount += 1
        lastVolatileCacheTrimAt = Date()
        lastVolatileCacheTrimReason = reason
        lastVolatileCacheTrimRebuildReason = selectedMainTab.diagnosticName
        lastVolatileCacheTrimCategoryCounts = [
            "proposalDetails": clearedProposalDetails,
            "runDetails": clearedRunDetails,
            "pmRoutineFilterEntries": clearedRoutineFilterEntries,
            "portfolioTrackerSymbols": clearedPortfolioTrackerSymbols,
            "portfolioTrackerPoints": clearedPortfolioTrackerPoints,
            "portfolioCardPresentations": clearedPortfolioCardCount,
            "portfolioCardDisplayPoints": clearedPortfolioCardDisplayPoints,
            "portfolioCardSourcePoints": clearedPortfolioCardSourcePoints,
            "pmConversationVisibleMessages": clearedPMConversationMessages,
            "pmConversationVisibleTextBytes": clearedPMConversationTextBytes,
            "ownerDecisionDeskItems": clearedOwnerDecisionDeskItems,
            "ownerBackgroundCards": clearedOwnerBackgroundCards,
            "ownerRecentChanges": clearedOwnerRecentChanges
        ]

        let categorySummary = lastVolatileCacheTrimCategoryCounts
            .filter { $0.value > 0 }
            .sorted { lhs, rhs in lhs.key < rhs.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ")
        let trimmedSummary = categorySummary.isEmpty ? "no populated volatile categories" : categorySummary
        return "Trimmed volatile UI caches (\(trimmedSummary)). Durable history and Store truth were not deleted."
    }

    @discardableResult
    func performMemoryRelief(
        reason: String = "manual",
        mode: MemoryReliefActionMode = .systemControlManual,
        forced: Bool = true,
        dryRun: Bool = false
    ) -> MemoryReliefActionSummary {
        guard memoryPostureActionInFlight == false else {
            let sample = latestMemoryFootprintSample ?? memoryFootprintSampler.sample(now: Date())
            let summary = MemoryReliefActionSummary(
                mode: mode,
                reason: reason,
                dryRun: dryRun,
                forced: forced,
                startedAt: Date(),
                completedAt: Date(),
                bandBeforeAction: .sampleUnavailable,
                sample: sample,
                volatileCategoryCountsBefore: volatileCacheCategoryCounts(),
                volatileCategoryCountsAfter: volatileCacheCategoryCounts(),
                allocatorRelief: .notAttempted,
                actionApplied: false,
                summary: "Memory relief is already running; no overlapping action was started."
            )
            lastMemoryReliefAction = summary
            refreshMemoryPostureDiagnostics()
            return summary
        }

        memoryPostureActionInFlight = true
        refreshMemoryPostureDiagnostics()
        let startedAt = Date()
        let sample = sampleMemoryPosture(now: startedAt)
        let band = MemoryPosturePolicy.classify(
            physicalFootprintBytes: sample.physicalFootprintBytes,
            configuration: memoryPostureConfiguration
        )
        let beforeCounts = volatileCacheCategoryCounts()
        let shouldApply = MemoryPosturePolicy.shouldApplyRelief(
            band: band,
            forced: forced,
            dryRun: dryRun,
            inFlight: false
        )

        let allocatorOutcome: AllocatorPressureReliefOutcome
        let summaryText: String
        if shouldApply {
            _ = trimVolatileCaches(reason: reason)
            allocatorOutcome = allocatorPressureReliever.relieve(goalBytes: 0)
            if allocatorOutcome.attempted {
                memoryPostureAllocatorReliefAttemptCount += 1
                memoryPostureAllocatorReliefTotalReclaimedBytes += allocatorOutcome.reclaimedBytes ?? 0
            }
            switch mode {
            case .automaticSelfFootprint:
                memoryPostureAutomaticReliefCount += 1
            case .macOSMemoryPressure:
                memoryPostureMemoryPressureReliefCount += 1
            case .systemControlManual, .ipcForcedDiagnostic:
                memoryPostureManualReliefCount += 1
            case .ipcDryRun:
                break
            }
            let reclaimedMB = allocatorOutcome.reclaimedBytes
                .map { String(format: "%.1f MB", Double($0) / 1_024 / 1_024) } ?? "unknown"
            summaryText = "Memory relief ran for \(band.rawValue): volatile UI-derived caches were released and allocator pressure relief reclaimed \(reclaimedMB). Durable Store truth was not deleted."
        } else if dryRun {
            allocatorOutcome = .notAttempted
            summaryText = "Memory relief dry run: latest band is \(band.rawValue). No caches were released and durable Store truth was not touched."
        } else {
            allocatorOutcome = .notAttempted
            summaryText = "Memory relief was not needed for latest band \(band.rawValue). Durable Store truth was not touched."
        }
        let afterCounts = volatileCacheCategoryCounts()
        let completedAt = Date()
        let summary = MemoryReliefActionSummary(
            mode: mode,
            reason: reason,
            dryRun: dryRun,
            forced: forced,
            startedAt: startedAt,
            completedAt: completedAt,
            bandBeforeAction: band,
            sample: sample,
            volatileCategoryCountsBefore: beforeCounts,
            volatileCategoryCountsAfter: afterCounts,
            allocatorRelief: allocatorOutcome,
            actionApplied: shouldApply,
            summary: summaryText
        )
        lastMemoryReliefAction = summary
        memoryPostureActionInFlight = false
        refreshMemoryPostureDiagnostics()
        return summary
    }

    private func sampleMemoryPosture(now: Date = Date()) -> ProcessMemoryFootprintSample {
        let sample = memoryFootprintSampler.sample(now: now)
        latestMemoryFootprintSample = sample
        if let physicalFootprintBytes = sample.physicalFootprintBytes {
            peakMemoryPhysicalFootprintBytes = max(
                peakMemoryPhysicalFootprintBytes ?? 0,
                physicalFootprintBytes
            )
        }
        memoryPostureNextScheduledSampleAt = MemoryPosturePolicy.nextScheduledSampleDate(
            launchDate: memoryPostureLaunchDate,
            lastSampleAt: sample.capturedAt,
            configuration: memoryPostureConfiguration
        )
        refreshMemoryPostureDiagnostics()
        return sample
    }

    private func runScheduledMemoryPostureSample() {
        guard MemoryPosturePolicy.shouldRunScheduledSample(
            now: Date(),
            launchDate: memoryPostureLaunchDate,
            lastSampleAt: latestMemoryFootprintSample?.capturedAt,
            inFlight: memoryPostureActionInFlight,
            configuration: memoryPostureConfiguration
        ) else {
            memoryPostureNextScheduledSampleAt = MemoryPosturePolicy.nextScheduledSampleDate(
                launchDate: memoryPostureLaunchDate,
                lastSampleAt: latestMemoryFootprintSample?.capturedAt,
                configuration: memoryPostureConfiguration
            )
            refreshMemoryPostureDiagnostics()
            return
        }

        let sample = sampleMemoryPosture()
        let band = MemoryPosturePolicy.classify(
            physicalFootprintBytes: sample.physicalFootprintBytes,
            configuration: memoryPostureConfiguration
        )
        if band.reliefEligible {
            _ = performMemoryRelief(
                reason: "self_footprint_\(band.rawValue)",
                mode: .automaticSelfFootprint,
                forced: false,
                dryRun: false
            )
        }
    }

    private func refreshMemoryPostureDiagnostics() {
        memoryPostureDiagnostics = makeMemoryPostureDiagnostics()
    }

    private func makeMemoryPostureDiagnostics() -> MemoryPostureDiagnostics {
        let classifiedBand = MemoryPosturePolicy.classify(
            physicalFootprintBytes: latestMemoryFootprintSample?.physicalFootprintBytes,
            configuration: memoryPostureConfiguration
        )
        let displayedBand: MemoryPostureBand
        if let action = lastMemoryReliefAction,
           action.actionApplied,
           action.sample.capturedAt == latestMemoryFootprintSample?.capturedAt {
            displayedBand = .reliefApplied
        } else {
            displayedBand = classifiedBand
        }
        return MemoryPostureDiagnostics(
            configuration: memoryPostureConfiguration,
            latestSample: latestMemoryFootprintSample,
            peakPhysicalFootprintBytes: peakMemoryPhysicalFootprintBytes,
            currentBand: displayedBand,
            lastSampleAt: latestMemoryFootprintSample?.capturedAt,
            nextScheduledSampleAt: memoryPostureNextScheduledSampleAt,
            lastAction: lastMemoryReliefAction,
            automaticReliefCount: memoryPostureAutomaticReliefCount,
            manualReliefCount: memoryPostureManualReliefCount,
            memoryPressureReliefCount: memoryPostureMemoryPressureReliefCount,
            allocatorReliefAttemptCount: memoryPostureAllocatorReliefAttemptCount,
            allocatorReliefTotalReclaimedBytes: memoryPostureAllocatorReliefTotalReclaimedBytes,
            actionInFlight: memoryPostureActionInFlight
        )
    }

    var ipcStatusLine: String {
        if ipcStatus.running, let port = ipcStatus.port {
            return "\(ipcStatus.host):\(port)"
        }
        return "Not running"
    }

    var agentCtlReadyText: String {
        if ipcStatus.running, let _ = ipcStatus.port {
            return "agentctl ready"
        }
        return "agentctl unavailable"
    }

    var auditLinesNewestFirst: [String] {
        auditLines.reversed()
    }

    private func applySelectedEnvironment() {
        let targetEnvironment = selectedEnvironment
        OwnerEnvironmentFeedPreferenceStore.saveEnvironment(targetEnvironment)
        Task {
            await engine.setEnvironment(targetEnvironment)
            if started {
                await engine.stop()
                await engine.start()
            }
            await MainActor.run {
                refreshKeychainStatus()
            }
            await refreshSnapshotFromStore()
            await refreshEngineStatus()
        }
    }

    private func applySelectedMarketDataFeed() {
        let targetFeed = selectedMarketDataFeed
        OwnerEnvironmentFeedPreferenceStore.saveMarketDataFeed(targetFeed)
        Task {
            await engine.setMarketDataFeed(targetFeed)
            await refreshSnapshotFromStore()
        }
    }

    private func refreshEngineStatus() async {
        assignIfChanged(\.engineStatusText, await engine.status)
    }

    private func subscribeToStoreEvents() {
        guard storeEventsTask == nil else {
            return
        }

        let store = self.store
        let coalescer = self.storeEventRefreshCoalescer
        storeEventsTask = Task { [weak self] in
            await StoreEventSubscriptionRunner.run(
                events: store.events,
                coalescer: coalescer,
                receiveMarketData: { [weak self] in
                    await self?.performMarketDataSnapshotRefresh()
                },
                receiveControlEvent: { [weak self] event in
                    await self?.handleControlStoreEvent(event)
                }
            )
        }
    }

    private func refreshSnapshotFromStore() async {
        await refreshSnapshotFromStore(scope: .full, reason: "manual")
    }

    private func performMarketDataSnapshotRefresh() async {
        await refreshSnapshotFromStore(scope: .marketData, reason: "market_data")
        await refreshEngineStatus()
    }

    private func handleControlStoreEvent(_ event: StoreEvent) async {
        recordControlStoreEvent(event.name)
        await refreshSnapshotFromStore(scope: refreshScope(for: event), reason: event.name)
        await refreshEngineStatus()
        if event.name == "portfolio_watch_chart_wall_updated" {
            _ = await refreshPortfolioWatchChartWallConfiguration()
        }
        if event.name == "analyst_charter_updated" {
            _ = await refreshAnalystCharters()
            _ = await refreshPMContextPack()
        }
        if event.name == "agent_skill_updated" {
            _ = await refreshAgentSkills()
        }
        if event.name == "pm_communication_session_upserted" {
            _ = await refreshPMCommunicationSessions()
        }
        if event.name == "pm_communication_message_upserted" {
            _ = await refreshPMCommunicationMessages()
        }
        if event.name == "pm_decision_upserted" {
            _ = await refreshPMDecisions()
        }
        if event.name == "pm_approval_request_upserted" {
            _ = await refreshPMApprovalRequests()
        }
        if event.name == "analyst_standing_report_upserted"
            || event.name == "pm_standing_review_queue_changed" {
            _ = await refreshAnalystMemos()
            _ = await refreshAnalystStandingReports()
            _ = await refreshPMContextPack()
            scheduleAutomaticStandingReviewConsumptionIfNeeded()
        }
        if event.name == "pm_standing_review_cycle_closed" {
            _ = await refreshAnalystTasks()
            _ = await refreshAnalystMemos()
            _ = await refreshAnalystStandingReports()
            _ = await refreshPMDelegations()
            _ = await refreshPMDecisions()
            _ = await refreshPMApprovalRequests()
            _ = await refreshPMContextPack()
        }
    }

    private func refreshSnapshotFromStore(
        scope: StoreSnapshotRefreshScope,
        reason: String
    ) async {
        recordSnapshotApply(scope: scope, reason: reason)
        let snapshot = await store.snapshot()
        switch scope {
        case .full:
            await applyFullSnapshot(snapshot, reason: reason)
        case .marketData:
            applyMarketDataSnapshot(snapshot)
        case .connectivity:
            applyConnectivitySnapshot(snapshot)
        case .diagnostic:
            applyDiagnosticSnapshot(snapshot)
        case .jobs:
            await applyJobsSnapshot(snapshot, reason: reason)
        case .schedules:
            applySchedulesSnapshot(snapshot)
        case .news:
            applyNewsSnapshot(snapshot)
        case .strategyStatuses:
            applyStrategyStatusSnapshot(snapshot)
        case .proposals:
            applyProposalsSnapshot(snapshot, reason: reason)
        case .proposalRuns:
            applyProposalRunsSnapshot(snapshot)
        case .signals:
            applySignalsSnapshot(snapshot, reason: reason)
        case .ipc:
            applyIPCSnapshot(snapshot)
        }
    }

    private func applyFullSnapshot(_ snapshot: StoreSnapshot, reason: String) async {
        appModelFullSnapshotApplyCount += 1
        incrementCounter(&appModelFullSnapshotApplyByEvent, key: reason)
        assignIfChanged(\.buildText, snapshot.build)
        assignIfChanged(\.connectionState, snapshot.connectionState)
        assignIfChanged(\.tradeUpdatesLastDiagnostic, snapshot.tradeUpdatesLastDiagnostic)
        assignIfChanged(\.tradeUpdatesLastError, snapshot.tradeUpdatesLastError)
        assignIfChanged(\.openOrders, snapshot.openOrders)
        assignIfChanged(\.positions, snapshot.positions)
        assignIfChanged(\.auditLines, snapshot.auditLines)
        assignIfChanged(\.lastTradeUpdateText, snapshot.lastTradeUpdateSummary ?? "None")
        assignIfChanged(\.isLive, snapshot.isLive)
        assignIfChanged(\.isArmedForLiveTrading, snapshot.isArmedForLiveTrading)
        assignIfChanged(\.armingSessionID, snapshot.armingSessionID)
        assignIfChanged(\.killSwitchEnabled, snapshot.killSwitchEnabled)
        assignIfChanged(\.tradingEnabled, snapshot.tradingEnabled)
        let previousWatchlistSymbols = watchlistSymbols
        assignIfChanged(\.watchlistSymbols, snapshot.watchlistSymbols)
        assignIfChanged(\.marketDataDesiredSubscriptions, snapshot.marketDataDesiredSubscriptions)
        assignIfChanged(\.marketDataSubscriptions, snapshot.marketDataSubscriptions)
        assignIfChanged(\.lastMarketDataReceivedAt, snapshot.lastMarketDataReceivedAt)
        assignIfChanged(\.lastMarketDataReceivedSymbol, snapshot.lastMarketDataReceivedSymbol)
        assignIfChanged(\.quotesBySymbol, snapshot.quotesBySymbol)
        assignIfChanged(\.optionQuotesBySymbol, snapshot.optionQuotesBySymbol)
        assignIfChanged(\.marketDataConnectionState, snapshot.marketDataConnectionState)
        assignIfChanged(\.marketDataLastDiagnostic, snapshot.marketDataLastDiagnostic)
        assignIfChanged(\.marketDataLastErrorCode, snapshot.marketDataLastErrorCode)
        assignIfChanged(\.marketDataLastErrorMessage, snapshot.marketDataLastErrorMessage)
        assignIfChanged(\.lastMarketDataText, snapshot.lastMarketDataSummary ?? "None")
        assignIfChanged(\.lastOptionsMarketDataText, snapshot.lastOptionsMarketDataSummary ?? "None")
        assignIfChanged(\.alwaysOnReadiness, snapshot.alwaysOnReadiness)
        assignIfChanged(\.strategyStatuses, snapshot.strategies)
        assignIfChanged(\.jobs, snapshot.jobs)
        await updateLastMaintenanceState()
        assignIfChanged(\.schedules, snapshot.schedules)
        assignIfChanged(\.ipcStatus, snapshot.ipcStatus)
        assignIfChanged(\.proposals, snapshot.proposals)
        assignIfChanged(\.rssFeedSummary, snapshot.rssFeedSummary)
        assignIfChanged(\.recentNews, snapshot.recentNews)
        assignIfChanged(\.signals, snapshot.signals)
        assignIfChanged(\.newsIngestStatus, snapshot.newsIngestStatus)
        assignIfChanged(\.proposalRunSummariesByProposalID, snapshot.proposalRunSummariesByProposalID)
        let proposalIDs = Set(snapshot.proposals.map(\.id))
        let filteredProposalDetails = proposalDetailsByID.filter { proposalIDs.contains($0.key) }
        assignIfChanged(\.proposalDetailsByID, filteredProposalDetails)
        assignIfChanged(\.accountSummaryText, snapshot.accountSummary?.displayLine ?? "Account not loaded")
        if previousWatchlistSymbols != snapshot.watchlistSymbols {
            scheduleOptionContractMetadataLookups(for: snapshot.watchlistSymbols)
        }
        applyPortfolioIntelligenceSnapshot(from: snapshot)
        rebuildPortfolioWatchChartWall()
        rebuildOwnerSurfaceProjections(reason: reason)
    }

    private func applyMarketDataSnapshot(_ snapshot: StoreSnapshot) {
        guard shouldPublishMarketDataPresentation else {
            marketDataPresentationSuppressedCount += 1
            rebuildPortfolioWatchChartWall(
                reason: "market_data_hidden",
                quotesBySymbolOverride: snapshot.quotesBySymbol,
                optionQuotesBySymbolOverride: snapshot.optionQuotesBySymbol
            )
            return
        }

        marketDataPresentationPublishedCount += 1
        assignIfChanged(\.lastMarketDataReceivedAt, snapshot.lastMarketDataReceivedAt)
        assignIfChanged(\.lastMarketDataReceivedSymbol, snapshot.lastMarketDataReceivedSymbol)
        assignIfChanged(\.quotesBySymbol, snapshot.quotesBySymbol)
        assignIfChanged(\.optionQuotesBySymbol, snapshot.optionQuotesBySymbol)
        assignIfChanged(\.lastMarketDataText, snapshot.lastMarketDataSummary ?? "None")
        assignIfChanged(\.lastOptionsMarketDataText, snapshot.lastOptionsMarketDataSummary ?? "None")
        applyPortfolioIntelligenceSnapshot(from: snapshot)
        rebuildPortfolioWatchChartWall(reason: "market_data_visible")
        rebuildVisibleStatusPresentation(reason: "market_data_visible")
    }

    private func applyConnectivitySnapshot(_ snapshot: StoreSnapshot) {
        assignIfChanged(\.connectionState, snapshot.connectionState)
        assignIfChanged(\.tradeUpdatesLastDiagnostic, snapshot.tradeUpdatesLastDiagnostic)
        assignIfChanged(\.tradeUpdatesLastError, snapshot.tradeUpdatesLastError)
        assignIfChanged(\.marketDataDesiredSubscriptions, snapshot.marketDataDesiredSubscriptions)
        assignIfChanged(\.marketDataSubscriptions, snapshot.marketDataSubscriptions)
        assignIfChanged(\.marketDataConnectionState, snapshot.marketDataConnectionState)
        assignIfChanged(\.marketDataLastDiagnostic, snapshot.marketDataLastDiagnostic)
        assignIfChanged(\.marketDataLastErrorCode, snapshot.marketDataLastErrorCode)
        assignIfChanged(\.marketDataLastErrorMessage, snapshot.marketDataLastErrorMessage)
        assignIfChanged(\.lastMarketDataReceivedAt, snapshot.lastMarketDataReceivedAt)
        assignIfChanged(\.lastMarketDataReceivedSymbol, snapshot.lastMarketDataReceivedSymbol)
        assignIfChanged(\.lastMarketDataText, snapshot.lastMarketDataSummary ?? "None")
        assignIfChanged(\.lastOptionsMarketDataText, snapshot.lastOptionsMarketDataSummary ?? "None")
        assignIfChanged(\.alwaysOnReadiness, snapshot.alwaysOnReadiness)
        applyPortfolioIntelligenceSnapshot(from: snapshot)
        if selectedMainTab == .marketWatch {
            rebuildPortfolioWatchChartWall(forcePublish: true, reason: "connectivity_visible_portfolio_watch")
        }
        rebuildVisibleStatusPresentation(reason: "connectivity")
    }

    private func applyDiagnosticSnapshot(_ snapshot: StoreSnapshot) {
        assignIfChanged(\.auditLines, snapshot.auditLines)
    }

    private func applyJobsSnapshot(_ snapshot: StoreSnapshot, reason: String) async {
        let jobsChanged = assignIfChanged(\.jobs, snapshot.jobs)
        await updateLastMaintenanceState()
        if jobsChanged {
            rebuildJobScopedOwnerSurfaceProjections(reason: reason)
            rebuildVisibleStatusPresentation(reason: reason)
        }
    }

    private func applySchedulesSnapshot(_ snapshot: StoreSnapshot) {
        assignIfChanged(\.schedules, snapshot.schedules)
    }

    private func applyNewsSnapshot(_ snapshot: StoreSnapshot) {
        assignIfChanged(\.rssFeedSummary, snapshot.rssFeedSummary)
        assignIfChanged(\.recentNews, snapshot.recentNews)
        assignIfChanged(\.newsIngestStatus, snapshot.newsIngestStatus)
    }

    private func applyStrategyStatusSnapshot(_ snapshot: StoreSnapshot) {
        assignIfChanged(\.strategyStatuses, snapshot.strategies)
    }

    private func applyProposalsSnapshot(_ snapshot: StoreSnapshot, reason: String) {
        let proposalsChanged = assignIfChanged(\.proposals, snapshot.proposals)
        let proposalIDs = Set(snapshot.proposals.map(\.id))
        let filteredProposalDetails = proposalDetailsByID.filter { proposalIDs.contains($0.key) }
        assignIfChanged(\.proposalDetailsByID, filteredProposalDetails)
        if proposalsChanged {
            rebuildCommandCenterProjection(reason: reason)
        }
    }

    private func applyProposalRunsSnapshot(_ snapshot: StoreSnapshot) {
        assignIfChanged(\.proposalRunSummariesByProposalID, snapshot.proposalRunSummariesByProposalID)
    }

    private func applySignalsSnapshot(_ snapshot: StoreSnapshot, reason: String) {
        if assignIfChanged(\.signals, snapshot.signals) {
            rebuildCommandCenterProjection(reason: reason)
        }
    }

    private func applyIPCSnapshot(_ snapshot: StoreSnapshot) {
        assignIfChanged(\.ipcStatus, snapshot.ipcStatus)
        rebuildVisibleStatusPresentation(reason: "ipc")
    }

    @discardableResult
    private func assignIfChanged<Value: Equatable>(
        _ keyPath: ReferenceWritableKeyPath<AppModel, Value>,
        _ value: Value
    ) -> Bool {
        guard self[keyPath: keyPath] != value else {
            return false
        }
        self[keyPath: keyPath] = value
        return true
    }

    @discardableResult
    private func rebuildVisibleStatusPresentation(reason: String = "direct") -> Bool {
        _ = reason
        topBannerPresentationRecomputeCount += 1
        topCardPresentationRecomputeCount += 1
        systemHealthPresentationRecomputeCount += 1

        let selectedEnvironmentKeysFound: Bool
        switch selectedEnvironment {
        case .paper:
            selectedEnvironmentKeysFound = keyStatus.paperKeysFound
        case .live:
            selectedEnvironmentKeysFound = keyStatus.liveKeysFound
        }

        let liveSafetyStatusLabel: String
        if selectedEnvironment == .live {
            if killSwitchEnabled {
                liveSafetyStatusLabel = "LIVE • KILL SWITCH"
            } else {
                liveSafetyStatusLabel = isArmedForLiveTrading ? "LIVE • ARMED" : "LIVE • DISARMED"
            }
        } else {
            liveSafetyStatusLabel = "Paper"
        }

        let alwaysOnReadinessDetail: String
        if alwaysOnReadiness.blockers.isEmpty {
            alwaysOnReadinessDetail = alwaysOnReadiness.summary
        } else {
            alwaysOnReadinessDetail = "\(alwaysOnReadiness.summary) \(alwaysOnReadiness.blockers.joined(separator: " "))"
        }

        let tradeReadiness = makeTradeStreamReadinessPresentation(
            connectionState: connectionState,
            lastError: tradeUpdatesLastError
        )
        let marketDataReadiness = makeMarketDataStreamReadinessPresentation(
            connectionState: marketDataConnectionState,
            desiredMarketData: marketDataDesiredSubscriptions,
            activeMarketData: marketDataSubscriptions,
            lastMarketDataReceivedAt: lastMarketDataReceivedAt,
            now: Date(),
            lastErrorCode: marketDataLastErrorCode,
            lastErrorMessage: marketDataLastErrorMessage
        )
        let workerLinkStatus = ipcStatus.running ? "Connected" : "Unavailable"
        let systemExceptionCategories = makeOwnerSystemExceptionCategoryPresentations(
            snapshot: pmCommandCenterSnapshot,
            tradeConnectionState: tradeReadiness.label,
            marketDataConnectionState: marketDataReadiness.label,
            workerLinkConnected: ipcStatus.running
        )
        let ownerDecisionValue = ownerDecisionTopBarValue(pmCommandCenterSnapshot)
        let topBarChips = [
            CommandCenterTopBarChipPresentation(
                title: "Posture",
                value: "\(selectedEnvironment.rawValue.capitalized) • \(liveSafetyStatusLabel)"
            ),
            CommandCenterTopBarChipPresentation(
                title: "Connectivity",
                value: "Trades \(tradeReadiness.label) • Market \(marketDataReadiness.label)"
            ),
            CommandCenterTopBarChipPresentation(
                title: "Readiness",
                value: alwaysOnReadiness.status.displayName
            ),
            CommandCenterTopBarChipPresentation(
                title: "Your Decisions",
                value: ownerDecisionValue
            ),
            CommandCenterTopBarChipPresentation(
                title: "Background",
                value: "\(pmCommandCenterSnapshot.activeAnalystBackgroundCount) analyst • \(pmCommandCenterSnapshot.activePMBackgroundCount) PM"
            ),
            CommandCenterTopBarChipPresentation(
                title: "Exceptions",
                value: "\(pmCommandCenterSnapshot.degradedDelegationsCount) degraded • \(pmCommandCenterSnapshot.failedDelegationsCount) failed launches"
            ),
            CommandCenterTopBarChipPresentation(
                title: "Safety",
                value: "\(positions.count) positions • kill switch \(killSwitchEnabled ? "ON" : "OFF")"
            )
        ]
        let systemHealthMetrics = [
            SystemHealthMetricPresentation(title: "Trade Connectivity", value: tradeReadiness.label),
            SystemHealthMetricPresentation(title: "Market Data", value: marketDataReadiness.label),
            SystemHealthMetricPresentation(title: "Always-On Readiness", value: alwaysOnReadiness.status.displayName),
            SystemHealthMetricPresentation(title: "Worker Link", value: workerLinkStatus),
            SystemHealthMetricPresentation(title: "Running Jobs", value: "\(runningJobSnapshots.count)"),
            SystemHealthMetricPresentation(title: "Last Market Data", value: lastMarketDataReceivedSymbol ?? "None"),
            SystemHealthMetricPresentation(title: "Configured Feed", value: selectedMarketDataFeed.displayName),
            SystemHealthMetricPresentation(title: "Feed Verify", value: selectedMarketDataFeed.diagnosticWebSocketEndpoint)
        ]

        let presentation = VisibleStatusPresentation(
            selectedEnvironmentKeysFound: selectedEnvironmentKeysFound,
            selectedEnvironmentSummary: selectedEnvironmentKeysFound ? "found" : "missing",
            selectedEnvironmentName: selectedEnvironment.rawValue.capitalized,
            liveSafetyStatusLabel: liveSafetyStatusLabel,
            liveSafetyStatusDetail: makeLiveSafetyStatusDetail(
                selectedEnvironment: selectedEnvironment,
                isArmedForLiveTrading: isArmedForLiveTrading,
                killSwitchEnabled: killSwitchEnabled,
                alwaysOnReadiness: alwaysOnReadiness
            ),
            liveExecutionProtectionStatusLabel: liveExecutionProtectionRequired ? "Local Auth Required" : "Local Auth Off",
            liveExecutionProtectionDetailText: liveExecutionProtectionRequired
                ? "Live NEW/REPLACE requires Touch ID or the Mac password before submission. Paper is unaffected and cancel remains available."
                : "Live NEW/REPLACE does not currently require a final local macOS authentication prompt. Existing approval, arming, and kill-switch gates still apply.",
            alwaysOnReadinessLabel: alwaysOnReadiness.status.displayName,
            alwaysOnReadinessDetail: alwaysOnReadinessDetail,
            tradeStreamOwnerFacingLabel: tradeReadiness.label,
            marketDataOwnerFacingLabel: marketDataReadiness.label,
            workerLinkStatus: workerLinkStatus,
            systemExceptionCategories: systemExceptionCategories,
            commandCenterTopBarChips: topBarChips,
            systemHealthMetrics: systemHealthMetrics
        )

        let didPublish = assignIfChanged(\.visibleStatusPresentation, presentation)
        if didPublish {
            topBannerPresentationPublishCount += 1
            topCardPresentationPublishCount += 1
            systemHealthPresentationPublishCount += 1
        } else {
            topBannerPresentationPublishSkipCount += 1
            topCardPresentationPublishSkipCount += 1
            systemHealthPresentationPublishSkipCount += 1
        }
        return didPublish
    }

    private func ownerDecisionTopBarValue(_ snapshot: PMCommandCenterSnapshot) -> String {
        var parts = [
            "\(snapshot.ownerActionableApprovalCount) pending"
        ]
        if snapshot.newSignalsCount > 0 {
            parts.append("\(snapshot.newSignalsCount) signal review\(snapshot.newSignalsCount == 1 ? "" : "s")")
        }
        if snapshot.fyiSignalsCount > 0 {
            parts.append("\(snapshot.fyiSignalsCount) FYI alert\(snapshot.fyiSignalsCount == 1 ? "" : "s")")
        }
        return parts.joined(separator: " • ")
    }

    private func rebuildOwnerSurfaceProjections(reason: String = "direct") {
        recordOwnerSurfaceRebuild(reason: reason)
        guard selectedMainTab == .commandCenter else {
            rebuildCommandCenterProjection(reason: reason, publishesVisibleCards: false)
            return
        }
        rebuildStrategyBriefRevisionCandidateIfNeeded()
        rebuildCommandCenterProjection(reason: reason)
        rebuildOwnerDecisionDeskProjection(reason: reason)
        rebuildPMConversationPresentationIfNeeded(reason: reason)
    }

    private func rebuildCommandCenterProjection(
        reason: String,
        publishesVisibleCards: Bool = true
    ) {
        commandCenterProjectionRebuildCount += 1
        let snapshot = makePMCommandCenterSnapshot(
            delegations: pmDelegations,
            charters: analystCharters,
            tasks: analystTasks,
            approvalRequests: pmApprovalRequests,
            decisions: pmDecisions,
            standingReports: analystStandingReports,
            jobs: jobs,
            signals: signals,
            proposals: proposals
        )
        assignIfChanged(\.pmCommandCenterSnapshot, snapshot)
        assignIfChanged(\.runningJobSnapshots, makeRunningJobSnapshots(jobs: jobs))
        rebuildVisibleStatusPresentation(reason: reason)
        guard publishesVisibleCards else {
            return
        }
        assignIfChanged(
            \.ownerBackgroundActivityCards,
            makeOwnerBackgroundActivityPresentations(
                snapshot: snapshot,
                standingReports: analystStandingReports,
                jobs: jobs
            )
        )
        assignIfChanged(\.ownerRecentChangePresentations, makeOwnerRecentChangePresentations(snapshot: snapshot))
    }

    private func rebuildJobScopedOwnerSurfaceProjections(reason: String) {
        let activeStandingRunCount = activeStandingAnalystRunCount(in: jobs)
        if activeStandingRunCount != pmCommandCenterSnapshot.activeStandingRunCount {
            rebuildCommandCenterProjection(
                reason: "\(reason)_standing_run_count_changed",
                publishesVisibleCards: selectedMainTab == .commandCenter
            )
            return
        }

        _ = reason
        jobScopedProjectionRefreshCount += 1
        assignIfChanged(\.runningJobSnapshots, makeRunningJobSnapshots(jobs: jobs))
        guard selectedMainTab == .commandCenter else {
            return
        }
        assignIfChanged(
            \.ownerBackgroundActivityCards,
            makeOwnerBackgroundActivityPresentations(
                snapshot: pmCommandCenterSnapshot,
                standingReports: analystStandingReports,
                jobs: jobs
            )
        )
    }

    private func releaseCommandCenterDerivedPresentations(reason: String) {
        _ = reason
        strategyBriefRevisionCandidate = nil
        strategyBriefRevisionCandidateCacheKey = nil
        pmConversationPresentationCacheKey = nil
        ownerPMConversationPresentation = nil
        ownerDecisionDeskItems = []
        ownerBackgroundActivityCards = []
        ownerRecentChangePresentations = []
    }

    private func activeStandingAnalystRunCount(in jobs: [JobSummary]) -> Int {
        jobs.filter {
            $0.type == .standingAnalystReport && ($0.status == .queued || $0.status == .running)
        }.count
    }

    private func rebuildOwnerDecisionDeskProjection(reason: String) {
        _ = reason
        ownerDecisionDeskProjectionRebuildCount += 1
        assignIfChanged(
            \.ownerDecisionDeskItems,
            makeOwnerDecisionDeskPresentations(
                approvalRequests: pmApprovalRequests,
                decisions: pmDecisions,
                delegations: pmDelegations,
                tasks: analystTasks,
                findings: analystFindings,
                communicationMessages: pmCommunicationMessages,
                charters: analystCharters,
                memos: analystMemos,
                strategyBrief: portfolioStrategyBrief,
                evidenceBundles: analystEvidenceBundles,
                sourceAccessSuggestions: analystSourceAccessSuggestions
            )
        )
    }

    private func rebuildPMConversationPresentationIfNeeded(reason: String) {
        _ = reason
        let key = makeOwnerPMConversationPresentationCacheKey()
        guard key != pmConversationPresentationCacheKey else {
            pmConversationPresentationCacheHitCount += 1
            return
        }

        pmConversationPresentationCacheKey = key
        pmConversationPresentationRebuildCount += 1
        let computation = makeOwnerPMConversationPresentationComputation(
            sessions: pmCommunicationSessions,
            messages: pmCommunicationMessages,
            approvalRequests: pmApprovalRequests,
            decisions: pmDecisions,
            routineFilterCache: &pmConversationRoutineFilterCache
        )
        pmConversationRoutineFilterScannedCount += computation.routineFilterScannedMessageCount
        pmConversationLastRoutineFilterScannedCount = computation.routineFilterScannedMessageCount
        pmConversationLastMatchingMessageCount = computation.matchingMessageCount
        assignIfChanged(
            \.ownerPMConversationPresentation,
            computation.presentation
        )
    }

    private func rebuildStrategyBriefRevisionCandidateIfNeeded() {
        let key = makeStrategyBriefRevisionCandidateCacheKey()
        strategyBriefRevisionCandidateLastMessageCount = pmCommunicationMessages.count
        guard key != strategyBriefRevisionCandidateCacheKey else {
            strategyBriefRevisionCandidateCacheHitCount += 1
            return
        }

        let computation = makeStrategyBriefConversationRevisionCandidateComputation(
            sessions: pmCommunicationSessions,
            messages: pmCommunicationMessages,
            messageScanLimit: Self.strategyBriefRevisionCandidateMessageScanLimit
        )
        strategyBriefRevisionCandidateCacheKey = key
        strategyBriefRevisionCandidateRebuildCount += 1
        strategyBriefRevisionCandidateScannedMessageCount += computation.scannedMessageCount
        strategyBriefRevisionCandidateLastScannedMessageCount = computation.scannedMessageCount
        strategyBriefRevisionCandidateLastConsideredMessageCount = computation.consideredMessageCount
        strategyBriefRevisionCandidateLastCandidateVisible = computation.candidate != nil
        assignIfChanged(\.strategyBriefRevisionCandidate, computation.candidate)
    }

    private func makeStrategyBriefRevisionCandidateCacheKey() -> StrategyBriefRevisionCandidateCacheKey {
        var newestInAppSession: PMCommunicationSession?
        for session in pmCommunicationSessions
        where session.channel == .inApp && isExercisePMCommunicationSession(session) == false {
            guard let existing = newestInAppSession else {
                newestInAppSession = session
                continue
            }
            if session.updatedAt > existing.updatedAt
                || (session.updatedAt == existing.updatedAt && session.sessionId < existing.sessionId) {
                newestInAppSession = session
            }
        }
        let newestMessage = pmCommunicationMessages.last
        return StrategyBriefRevisionCandidateCacheKey(
            sessionCount: pmCommunicationSessions.count,
            messageCount: pmCommunicationMessages.count,
            newestInAppSessionId: newestInAppSession?.sessionId,
            newestInAppSessionUpdatedAt: newestInAppSession?.updatedAt,
            newestMessageId: newestMessage?.messageId,
            newestMessageUpdatedAt: newestMessage?.updatedAt,
            strategyBriefUpdatedAt: portfolioStrategyBrief?.updatedAt
        )
    }

    private func makeOwnerPMConversationPresentationCacheKey() -> OwnerPMConversationPresentationCacheKey {
        var newestOwnerSession: PMCommunicationSession?
        for session in pmCommunicationSessions
        where appModelOwnerFacingPMConversationChannel(session.channel)
            && isExercisePMCommunicationSession(session) == false {
            if newestOwnerSession == nil
                || session.updatedAt > newestOwnerSession!.updatedAt
                || (session.updatedAt == newestOwnerSession!.updatedAt
                    && session.sessionId < newestOwnerSession!.sessionId) {
                newestOwnerSession = session
            }
        }

        let newestMessage = newestPMCommunicationMessage(pmCommunicationMessages)
        let newestApprovalRequest = newestPMApprovalRequest(pmApprovalRequests)
        let newestDecision = newestPMDecision(pmDecisions)
        return OwnerPMConversationPresentationCacheKey(
            sessionCount: pmCommunicationSessions.count,
            messageCount: pmCommunicationMessages.count,
            newestOwnerSessionId: newestOwnerSession?.sessionId,
            newestOwnerSessionUpdatedAt: newestOwnerSession?.updatedAt,
            newestMessageId: newestMessage?.messageId,
            newestMessageUpdatedAt: newestMessage?.updatedAt,
            approvalRequestCount: pmApprovalRequests.count,
            newestApprovalRequestId: newestApprovalRequest?.approvalRequestId,
            newestApprovalRequestUpdatedAt: newestApprovalRequest?.updatedAt,
            decisionCount: pmDecisions.count,
            newestDecisionId: newestDecision?.decisionId,
            newestDecisionUpdatedAt: newestDecision?.updatedAt
        )
    }

    private func appModelOwnerFacingPMConversationChannel(
        _ channel: PMCommunicationChannel
    ) -> Bool {
        switch channel {
        case .inApp, .telegram, .mockTelegram:
            return true
        case .genericRemote:
            return false
        }
    }

    private func newestPMCommunicationMessage(
        _ messages: [PMCommunicationMessage]
    ) -> PMCommunicationMessage? {
        messages.max { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.messageId > rhs.messageId
            }
            return lhs.updatedAt < rhs.updatedAt
        }
    }

    private func newestPMApprovalRequest(
        _ approvalRequests: [PMApprovalRequest]
    ) -> PMApprovalRequest? {
        approvalRequests.max { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.approvalRequestId > rhs.approvalRequestId
            }
            return lhs.updatedAt < rhs.updatedAt
        }
    }

    private func newestPMDecision(
        _ decisions: [PMDecisionRecord]
    ) -> PMDecisionRecord? {
        decisions.max { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.decisionId > rhs.decisionId
            }
            return lhs.updatedAt < rhs.updatedAt
        }
    }

    private func recordControlStoreEvent(_ name: String) {
        appModelControlEventReceivedCount += 1
        incrementCounter(&appModelControlEventReceivedByName, key: name)
    }

    private func recordSnapshotApply(scope: StoreSnapshotRefreshScope, reason: String) {
        _ = reason
        incrementCounter(&appModelSnapshotApplyCountByScope, key: scope.diagnosticName)
    }

    private func recordOwnerSurfaceRebuild(reason: String) {
        appModelOwnerSurfaceRebuildCount += 1
        incrementCounter(&appModelOwnerSurfaceRebuildByReason, key: reason)
    }

    private func incrementCounter(_ counters: inout [String: Int], key: String) {
        counters[key, default: 0] += 1
    }

    private func counterJSON(_ counters: [String: Int]) -> JSONValue {
        .object(
            Dictionary(
                uniqueKeysWithValues: counters
                    .sorted { lhs, rhs in lhs.key < rhs.key }
                    .map { key, value in
                        (key, JSONValue.number(Double(value)))
                    }
            )
        )
    }

    private func ownerSurfaceRuntimeDiagnosticsJSON() -> JSONValue {
        statusSerializationCount += 1
        return .object([
            "appModelRefresh": .object([
                "controlEventReceivedCount": .number(Double(appModelControlEventReceivedCount)),
                "controlEventReceivedByName": counterJSON(appModelControlEventReceivedByName),
                "snapshotApplyCountByScope": counterJSON(appModelSnapshotApplyCountByScope),
                "fullSnapshotApplyCount": .number(Double(appModelFullSnapshotApplyCount)),
                "fullSnapshotApplyByEvent": counterJSON(appModelFullSnapshotApplyByEvent)
            ]),
            "ownerSurface": .object([
                "rebuildCount": .number(Double(appModelOwnerSurfaceRebuildCount)),
                "rebuildByReason": counterJSON(appModelOwnerSurfaceRebuildByReason),
                "commandCenterProjectionRebuildCount": .number(Double(commandCenterProjectionRebuildCount)),
                "jobScopedProjectionRefreshCount": .number(Double(jobScopedProjectionRefreshCount)),
                "ownerDecisionDeskProjectionRebuildCount": .number(Double(ownerDecisionDeskProjectionRebuildCount))
            ]),
            "pmConversationPresentation": .object([
                "rebuildCount": .number(Double(pmConversationPresentationRebuildCount)),
                "cacheHitCount": .number(Double(pmConversationPresentationCacheHitCount)),
                "routineFilterScannedCount": .number(Double(pmConversationRoutineFilterScannedCount)),
                "lastRoutineFilterScannedCount": .number(Double(pmConversationLastRoutineFilterScannedCount)),
                "lastMatchingMessageCount": .number(Double(pmConversationLastMatchingMessageCount))
            ]),
            "strategyBriefCandidate": .object([
                "rebuildCount": .number(Double(strategyBriefRevisionCandidateRebuildCount)),
                "cacheHitCount": .number(Double(strategyBriefRevisionCandidateCacheHitCount)),
                "scannedMessageCount": .number(Double(strategyBriefRevisionCandidateScannedMessageCount)),
                "lastScannedMessageCount": .number(Double(strategyBriefRevisionCandidateLastScannedMessageCount)),
                "lastConsideredMessageCount": .number(Double(strategyBriefRevisionCandidateLastConsideredMessageCount)),
                "lastMessageCount": .number(Double(strategyBriefRevisionCandidateLastMessageCount)),
                "messageScanLimit": .number(Double(Self.strategyBriefRevisionCandidateMessageScanLimit)),
                "candidateVisible": .bool(strategyBriefRevisionCandidateLastCandidateVisible)
            ]),
            "volatileCacheTrim": .object([
                "trimCount": .number(Double(volatileCacheTrimCount)),
                "lastTrimAt": diagnosticDateJSON(lastVolatileCacheTrimAt),
                "lastReason": lastVolatileCacheTrimReason.map(JSONValue.string) ?? .null,
                "lastVisibleTab": lastVolatileCacheTrimRebuildReason.map(JSONValue.string) ?? .null,
                "memoryPressureTrimCount": .number(Double(memoryPressureTrimCount)),
                "lastCategoryCounts": counterJSON(lastVolatileCacheTrimCategoryCounts),
                "currentCategoryCounts": volatileCacheCategoryCountsJSON()
            ]),
            "memoryPosture": memoryPostureDiagnostics.jsonValue,
            "marketDataPresentation": .object([
                "activeTab": .string(selectedMainTab.diagnosticName),
                "publishedCount": .number(Double(marketDataPresentationPublishedCount)),
                "suppressedHiddenCount": .number(Double(marketDataPresentationSuppressedCount))
            ]),
            "portfolioWatchChartWall": .object([
                "activeTab": .string(selectedMainTab.diagnosticName),
                "rebuildCount": .number(Double(portfolioWatchChartWallRebuildCount)),
                "publishedRebuildCount": .number(Double(portfolioWatchChartWallPublishedRebuildCount)),
                "hiddenSkipCount": .number(Double(portfolioWatchChartWallHiddenSkipCount)),
                "releaseCount": .number(Double(portfolioWatchChartWallReleaseCount)),
                "lastPublishedCardCount": .number(Double(portfolioWatchChartWallLastPublishedCardCount)),
                "lastSkippedCardCount": .number(Double(portfolioWatchChartWallLastSkippedCardCount)),
                "trackerSymbolCount": .number(Double(portfolioWatchSeriesTracker.trackedSymbolCount)),
                "trackerPointCount": .number(Double(portfolioWatchSeriesTracker.totalPointCount))
            ]),
            "visibleSurfaceAllocation": .object([
                "topBannerPresentationRecomputeCount": .number(Double(topBannerPresentationRecomputeCount)),
                "topBannerPresentationPublishCount": .number(Double(topBannerPresentationPublishCount)),
                "topBannerPresentationPublishSkipCount": .number(Double(topBannerPresentationPublishSkipCount)),
                "topCardPresentationRecomputeCount": .number(Double(topCardPresentationRecomputeCount)),
                "topCardPresentationPublishCount": .number(Double(topCardPresentationPublishCount)),
                "topCardPresentationPublishSkipCount": .number(Double(topCardPresentationPublishSkipCount)),
                "systemHealthPresentationRecomputeCount": .number(Double(systemHealthPresentationRecomputeCount)),
                "systemHealthPresentationPublishCount": .number(Double(systemHealthPresentationPublishCount)),
                "systemHealthPresentationPublishSkipCount": .number(Double(systemHealthPresentationPublishSkipCount)),
                "statusSerializationCount": .number(Double(statusSerializationCount)),
                "statusSnapshotRetainedCount": .number(0)
            ]),
            "portfolioWatchVisible": portfolioWatchVisibleRuntimeDiagnosticsJSON(),
            "pmConversationVisible": pmConversationVisibleRuntimeDiagnosticsJSON()
        ])
    }

    private func volatileCacheCategoryCounts() -> [String: Int] {
        [
            "proposalDetails": proposalDetailsByID.count,
            "runDetails": runDetailsByID.count,
            "pmRoutineFilterEntries": pmConversationRoutineFilterCache.entryCount,
            "portfolioTrackerSymbols": portfolioWatchSeriesTracker.trackedSymbolCount,
            "portfolioTrackerPoints": portfolioWatchSeriesTracker.totalPointCount,
            "portfolioCardPresentations": portfolioWatchChartCards.count,
            "portfolioCardDisplayPoints": portfolioWatchChartCards.reduce(0) { $0 + $1.points.count },
            "portfolioCardSourcePoints": portfolioWatchChartCards.reduce(0) { $0 + $1.pointCount },
            "pmConversationVisibleMessages": ownerPMConversationPresentation?.visibleMessages.count ?? 0,
            "pmConversationVisibleTextBytes": ownerPMConversationPresentation?.visibleMessages.reduce(0) { partial, message in
                partial + message.body.utf8.count
            } ?? 0,
            "ownerDecisionDeskItems": ownerDecisionDeskItems.count,
            "ownerBackgroundCards": ownerBackgroundActivityCards.count,
            "ownerRecentChanges": ownerRecentChangePresentations.count
        ]
    }

    private func volatileCacheCategoryCountsJSON() -> JSONValue {
        counterJSON(volatileCacheCategoryCounts())
    }

    private func portfolioWatchVisibleRuntimeDiagnosticsJSON() -> JSONValue {
        let cards = portfolioWatchChartCards
            .prefix(PortfolioWatchChartWallConfiguration.maximumSelectedSymbols)
            .map { card -> JSONValue in
                let currentPrice = card.currentPrice.map(JSONValue.number) ?? JSONValue.null
                let lastUpdatedAt = diagnosticDateJSON(card.lastUpdatedAt)
                let priceSource = card.priceSource.map { JSONValue.string($0.displayTitle) } ?? JSONValue.null
                let lastQuoteAt = diagnosticDateJSON(card.diagnostics.lastQuoteAt)
                let lastTradeAt = diagnosticDateJSON(card.diagnostics.lastTradeAt)
                let lastBarAt = diagnosticDateJSON(card.diagnostics.lastBarAt)
                return .object([
                    "symbol": .string(card.symbol),
                    "currentPrice": currentPrice,
                    "lastUpdatedAt": lastUpdatedAt,
                    "liveState": .string(card.liveState.rawValue),
                    "statusLine": .string(card.liveState.statusLine),
                    "priceSource": priceSource,
                    "subscriptionDesired": .bool(card.diagnostics.subscriptionDesired),
                    "subscriptionActive": .bool(card.diagnostics.subscriptionActive),
                    "pointCount": .number(Double(card.pointCount)),
                    "lastQuoteAt": lastQuoteAt,
                    "lastTradeAt": lastTradeAt,
                    "lastBarAt": lastBarAt
                ])
            }
        return .object([
            "effectiveSelectedSymbols": .array(effectivePortfolioWatchChartSymbols.map(JSONValue.string)),
            "cardCount": .number(Double(portfolioWatchChartCards.count)),
            "pricedCardCount": .number(Double(portfolioWatchChartCards.filter { $0.currentPrice != nil }.count)),
            "waitingCardCount": .number(Double(portfolioWatchChartCards.filter { $0.liveState == .waitingForFirstUpdate }.count)),
            "cards": .array(cards)
        ])
    }

    private func pmConversationVisibleRuntimeDiagnosticsJSON() -> JSONValue {
        let visibleMessages = ownerPMConversationPresentation?.visibleMessages ?? []
        let messagesByID = Dictionary(uniqueKeysWithValues: pmCommunicationMessages.map { ($0.messageId, $0) })
        let telegramSessionIDs = Set(
            pmCommunicationSessions
                .filter { $0.channel == .telegram || $0.channel == .mockTelegram }
                .map(\.sessionId)
        )
        let visibleBackingMessages = visibleMessages.compactMap { messagesByID[$0.messageId] }
        let telegramVisibleCount = visibleBackingMessages.filter { message in
            telegramSessionIDs.contains(message.sessionId)
        }.count
        let lastVisibleMessageAt = diagnosticDateJSON(visibleBackingMessages.last?.sentAt)
        return .object([
            "visibleMessageCount": .number(Double(visibleMessages.count)),
            "telegramVisibleMessageCount": .number(Double(telegramVisibleCount)),
            "lastMatchingMessageCount": .number(Double(pmConversationLastMatchingMessageCount)),
            "sessionSummary": ownerPMConversationPresentation.map { .string($0.sessionSummary) } ?? .null,
            "replyRoutingSummary": ownerPMConversationPresentation.map { .string($0.replyRoutingSummary) } ?? .null,
            "lastVisibleMessageAt": lastVisibleMessageAt
        ])
    }

    private func diagnosticDateJSON(_ date: Date?) -> JSONValue {
        guard let date else { return .null }
        Self.diagnosticISO8601FormatterLock.lock()
        defer { Self.diagnosticISO8601FormatterLock.unlock() }
        return .string(Self.diagnosticISO8601Formatter.string(from: date))
    }

    private static let diagnosticISO8601FormatterLock = NSLock()

    private static let diagnosticISO8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private func refreshScope(for event: StoreEvent) -> StoreSnapshotRefreshScope {
        switch event.name {
        case "jobs":
            return .jobs
        case "schedules":
            return .schedules
        case "rss_feeds", "news_events", "news_ingest_status":
            return .news
        case "strategy_statuses":
            return .strategyStatuses
        case "proposals":
            return .proposals
        case "proposal_runs":
            return .proposalRuns
        case "signals":
            return .signals
        case "ipc_status":
            return .ipc
        case "market_data_connection_state",
            "market_data_subscription",
            "market_data_desired_subscription",
            "always_on_readiness",
            "stream_runtime_diagnostics",
            "connection_state",
            "trade_updates_subscribed",
            "trade_updates_disconnected":
            return .connectivity
        case "diagnostic",
            "notification",
            "pm_communication_session_upserted",
            "pm_communication_message_upserted",
            "portfolio_watch_chart_wall_updated",
            "analyst_charter_updated",
            "agent_skill_updated",
            "pm_decision_upserted",
            "pm_approval_request_upserted",
            "analyst_standing_report_upserted",
            "pm_standing_review_queue_changed",
            "pm_standing_review_cycle_closed":
            return .diagnostic
        default:
            return .full
        }
    }

    private func refreshPortfolioIntelligenceSnapshotFromStore() async {
        let snapshot = await store.snapshot()
        applyPortfolioIntelligenceSnapshot(from: snapshot)
    }

    private func applyPortfolioIntelligenceSnapshot(from snapshot: StoreSnapshot) {
        let nextSnapshot = makePortfolioIntelligenceSnapshot(
            snapshot: snapshot,
            paperEstablishmentExecution: latestPaperEstablishmentLifecycleState(),
            generatedAt: Date()
        )
        guard !portfolioIntelligenceContentMatches(portfolioIntelligenceSnapshot, nextSnapshot) else {
            return
        }
        portfolioIntelligenceSnapshot = nextSnapshot
    }

    private func portfolioIntelligenceContentMatches(
        _ lhs: PortfolioIntelligenceSnapshot,
        _ rhs: PortfolioIntelligenceSnapshot
    ) -> Bool {
        portfolioEnvironmentContentMatches(lhs.paper, rhs.paper)
            && portfolioEnvironmentContentMatches(lhs.live, rhs.live)
    }

    private func portfolioEnvironmentContentMatches(
        _ lhs: PortfolioEnvironmentSummary,
        _ rhs: PortfolioEnvironmentSummary
    ) -> Bool {
        lhs.environment == rhs.environment
            && lhs.availability == rhs.availability
            && lhs.statusSummary == rhs.statusSummary
            && lhs.account == rhs.account
            && lhs.exposure == rhs.exposure
            && lhs.dataQuality == rhs.dataQuality
            && lhs.orderActivity == rhs.orderActivity
            && lhs.positions == rhs.positions
            && lhs.advancedMetricReadiness == rhs.advancedMetricReadiness
            && lhs.advancedMetricsNote == rhs.advancedMetricsNote
    }

    private func latestPaperEstablishmentLifecycleState() -> PMPaperPortfolioExecutionLifecycleState? {
        pmApprovalRequests
            .compactMap(\.paperPortfolioExecutionLifecycleState)
            .sorted { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.summary < rhs.summary
                }
                return lhs.updatedAt > rhs.updatedAt
            }
            .first
    }

    var effectivePortfolioWatchChartSymbols: [String] {
        PortfolioWatchChartWallConfiguration.effectiveSelectedSymbols(
            selectedSymbols: portfolioWatchChartWallConfiguration?.selectedSymbols ?? [],
            watchlistSymbols: watchlistSymbols
        )
    }

    private func releasePortfolioWatchDerivedPresentations(reason: String) {
        _ = reason
        guard portfolioWatchChartCards.isEmpty == false else {
            return
        }
        portfolioWatchChartWallReleaseCount += 1
        portfolioWatchChartWallLastSkippedCardCount = portfolioWatchChartCards.count
        portfolioWatchChartCards = []
    }

    private func rebuildPortfolioWatchChartWall(
        forcePublish: Bool = false,
        reason: String = "direct",
        quotesBySymbolOverride: [String: MarketQuote]? = nil,
        optionQuotesBySymbolOverride: [String: MarketQuote]? = nil
    ) {
        _ = reason
        portfolioWatchChartWallRebuildCount += 1
        let now = Date()
        let selectedSymbols = effectivePortfolioWatchChartSymbols
        let sourceQuotesBySymbol = quotesBySymbolOverride ?? quotesBySymbol
        let sourceOptionQuotesBySymbol = optionQuotesBySymbolOverride ?? optionQuotesBySymbol
        portfolioWatchSeriesTracker.reconcileSymbols(selectedSymbols)
        for symbol in selectedSymbols {
            portfolioWatchSeriesTracker.ingest(
                symbol: symbol,
                quote: sourceQuotesBySymbol[symbol] ?? sourceOptionQuotesBySymbol[symbol],
                now: now
            )
        }

        guard forcePublish || selectedMainTab == .marketWatch else {
            portfolioWatchChartWallHiddenSkipCount += 1
            portfolioWatchChartWallLastSkippedCardCount = portfolioWatchChartCards.count
            releasePortfolioWatchDerivedPresentations(reason: "portfolio_watch_hidden")
            return
        }

        portfolioWatchChartWallPublishedRebuildCount += 1
        assignIfChanged(
            \.portfolioWatchChartCards,
            makePortfolioWatchCardPresentations(
                selectedSymbols: selectedSymbols,
                positions: positions,
                quotesBySymbol: sourceQuotesBySymbol,
                optionQuotesBySymbol: sourceOptionQuotesBySymbol,
                marketDataDesiredSubscriptions: marketDataDesiredSubscriptions,
                marketDataSubscriptions: marketDataSubscriptions,
                tracker: portfolioWatchSeriesTracker,
                now: now
            )
        )
        portfolioWatchChartWallLastPublishedCardCount = portfolioWatchChartCards.count
    }


    private func shortOrderID(_ orderID: String) -> String {
        String(orderID.prefix(8))
    }

    private func updateLastMaintenanceState() async {
        let previous = lastMaintenanceJob
        let latest = jobs
            .filter { $0.type == .maintenanceRetention }
            .sorted { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.jobId < rhs.jobId
                }
                return lhs.updatedAt > rhs.updatedAt
            }
            .first
        assignIfChanged(\.lastMaintenanceJob, latest)

        guard let latest else {
            assignIfChanged(\.lastMaintenanceSummary, "None")
            assignIfChanged(\.lastOldJobTelemetryCleanup, nil)
            return
        }

        if let previous,
           previous.jobId == latest.jobId,
           previous.updatedAt == latest.updatedAt,
           lastMaintenanceSummary != "None" {
            return
        }

        do {
            let job = try await engine.getJob(jobID: latest.jobId)
            assignMaintenanceState(from: job)
        } catch {
            assignIfChanged(\.lastMaintenanceSummary, latest.message ?? "No summary")
        }
    }

    private func assignMaintenanceState(from job: JobRecord) {
        assignIfChanged(\.lastMaintenanceJob, job.summary)
        assignIfChanged(
            \.lastMaintenanceSummary,
            maintenanceSummaryLine(from: job) ?? job.message ?? "No summary"
        )
        assignIfChanged(
            \.lastOldJobTelemetryCleanup,
            makeOldJobTelemetryCleanupPresentation(from: job)
        )
    }

    private func refreshMaintenanceJobUntilSettled(jobID: String) async {
        for _ in 0..<12 {
            guard let job = try? await engine.getJob(jobID: jobID) else {
                try? await Task.sleep(nanoseconds: 250_000_000)
                continue
            }

            assignMaintenanceState(from: job)
            if job.status == .succeeded || job.status == .failed || job.status == .canceled {
                break
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        if let refreshedJobs = try? await engine.listJobs() {
            assignIfChanged(\.jobs, refreshedJobs)
        }
    }

    private func maintenanceSummaryLine(from job: JobRecord) -> String? {
        guard let object = job.result?.objectValue else {
            return nil
        }
        let dryRun = object["dryRun"]?.boolValue ?? false
        let totalBytes = object["totalBytesFreed"]?.intValue ?? Int((object["totalBytesFreed"]?.doubleValue ?? 0).rounded())
        let deletedCount: Int = object["areas"]?.arrayValue?.reduce(0) { partial, value in
            partial + (value.objectValue?["deletedCount"]?.intValue ?? 0)
        } ?? 0
        let mode = dryRun ? "dry-run" : "apply"
        return "Last maintenance \(mode): deleted \(deletedCount) artifacts, freed \(totalBytes) bytes."
    }

    private func scheduleOptionContractMetadataLookups(for symbols: [String]) {
        let normalized = MarketDataSubscriptionSet.normalized(symbols)
        for symbol in normalized {
            guard MarketSymbolClassifier.instrumentType(for: symbol) == .option else {
                continue
            }
            guard optionContractsBySymbol[symbol] == nil else {
                continue
            }
            guard !optionContractLookupsInFlight.contains(symbol) else {
                continue
            }

            optionContractLookupsInFlight.insert(symbol)
            Task { @MainActor in
                let contract = await engine.fetchOptionContract(symbolOrID: symbol)
                if let contract {
                    optionContractsBySymbol[symbol] = contract
                }
                optionContractLookupsInFlight.remove(symbol)
            }
        }
    }
}

private struct LazyMainTabContent<Content: View>: View {
    let tab: MainTab
    @Binding var selectedTab: MainTab
    private let content: () -> Content

    init(
        tab: MainTab,
        selectedTab: Binding<MainTab>,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.tab = tab
        self._selectedTab = selectedTab
        self.content = content
    }

    var body: some View {
        if selectedTab == tab {
            content()
        } else {
            Color.clear
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var selectedTab: MainTab = .commandCenter
    @State private var temporarilyOpenedAdvancedSurface: OwnerAdvancedSurface?

    private var visibleAdvancedSurfaces: [OwnerAdvancedSurface] {
        makeVisibleOwnerAdvancedSurfaces(
            persistentPreferenceEnabled: appModel.showAdvancedTabs,
            temporarilyOpenedSurface: temporarilyOpenedAdvancedSurface
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if appModel.selectedEnvironment == .live {
                HStack {
                    Text(appModel.liveSafetyStatusLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                    if let reason = appModel.tradingDisabledReason {
                        Text("• \(reason)")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    Text("• \(appModel.liveSafetyStatusDetail)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(appModel.liveSafetyStatusColor)
            }

            commandCenterTopBar

            TabView(selection: $selectedTab) {
                LazyMainTabContent(tab: .commandCenter, selectedTab: $selectedTab) {
                    CommandCenterHomeView(selectedTab: $selectedTab)
                }
                    .tag(MainTab.commandCenter)
                    .tabItem { Text("Command Center") }

                LazyMainTabContent(tab: .marketWatch, selectedTab: $selectedTab) {
                    MarketWatchView()
                }
                    .tag(MainTab.marketWatch)
                    .tabItem { Text("Portfolio Watch") }

                LazyMainTabContent(tab: .news, selectedTab: $selectedTab) {
                    NewsView()
                }
                    .tag(MainTab.news)
                    .tabItem { Text("News") }

                LazyMainTabContent(tab: .systemControl, selectedTab: $selectedTab) {
                    SystemControlView(selectedTab: $selectedTab)
                }
                    .tag(MainTab.systemControl)
                    .tabItem { Text("System Control") }

                if visibleAdvancedSurfaces.contains(.pmInbox) {
                    LazyMainTabContent(tab: .pmInbox, selectedTab: $selectedTab) {
                        PMInboxView(selectedTab: $selectedTab)
                    }
                        .tag(MainTab.pmInbox)
                        .tabItem { Text("PM Inbox") }
                }

                if visibleAdvancedSurfaces.contains(.manualOrders) {
                    LazyMainTabContent(tab: .orderTicket, selectedTab: $selectedTab) {
                        OrderTicketView()
                    }
                        .tag(MainTab.orderTicket)
                        .tabItem { Text("Manual Orders") }
                }

                if visibleAdvancedSurfaces.contains(.ordersBlotter) {
                    LazyMainTabContent(tab: .blotter, selectedTab: $selectedTab) {
                        BlotterView()
                    }
                        .tag(MainTab.blotter)
                        .tabItem { Text("Orders Blotter") }
                }

                if visibleAdvancedSurfaces.contains(.proposals) {
                    LazyMainTabContent(tab: .proposals, selectedTab: $selectedTab) {
                        ProposalsView()
                    }
                        .tag(MainTab.proposals)
                        .tabItem { Text("Proposals") }
                }

                if visibleAdvancedSurfaces.contains(.signals) {
                    LazyMainTabContent(tab: .signals, selectedTab: $selectedTab) {
                        SignalsView(selectedTab: $selectedTab)
                    }
                        .tag(MainTab.signals)
                        .tabItem { Text("Signals") }
                }

                if visibleAdvancedSurfaces.contains(.jobs) {
                    LazyMainTabContent(tab: .jobs, selectedTab: $selectedTab) {
                        JobsView()
                    }
                        .tag(MainTab.jobs)
                        .tabItem { Text("Jobs") }
                }

                if visibleAdvancedSurfaces.contains(.logsAudit) {
                    LazyMainTabContent(tab: .logs, selectedTab: $selectedTab) {
                        LogsAuditView()
                    }
                        .tag(MainTab.logs)
                        .tabItem { Text("Logs / Audit") }
                }
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .onAppear {
            appModel.updateSelectedMainTab(selectedTab)
        }
        .onChange(of: appModel.showAdvancedTabs) { isEnabled in
            if isEnabled {
                temporarilyOpenedAdvancedSurface = nil
            } else if let advancedSurface = selectedTab.ownerAdvancedSurface {
                temporarilyOpenedAdvancedSurface = advancedSurface
            } else if selectedTab.isAdvanced {
                selectedTab = .commandCenter
            }
        }
        .onChange(of: selectedTab) { newValue in
            if appModel.showAdvancedTabs {
                temporarilyOpenedAdvancedSurface = nil
            } else {
                temporarilyOpenedAdvancedSurface = newValue.ownerAdvancedSurface
            }
            appModel.updateSelectedMainTab(newValue)
        }
    }

    private var commandCenterTopBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(appModel.commandCenterTopBarChips) { chip in
                    commandCenterChip(title: chip.title, value: chip.value)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(Color.secondary.opacity(0.06))
    }

    private func commandCenterChip(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(NSColor.windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

}

enum MainTab: Hashable {
    case commandCenter
    case orderTicket
    case blotter
    case marketWatch
    case systemControl
    case pmInbox
    case proposals
    case signals
    case jobs
    case news
    case logs

    var isAdvanced: Bool {
        switch self {
        case .commandCenter, .marketWatch, .news, .systemControl:
            return false
        case .orderTicket, .blotter, .pmInbox, .proposals, .signals, .jobs, .logs:
            return true
        }
    }

    var diagnosticName: String {
        switch self {
        case .commandCenter:
            return "command_center"
        case .orderTicket:
            return "order_ticket"
        case .blotter:
            return "blotter"
        case .marketWatch:
            return "portfolio_watch"
        case .systemControl:
            return "system_control"
        case .pmInbox:
            return "pm_inbox"
        case .proposals:
            return "proposals"
        case .signals:
            return "signals"
        case .jobs:
            return "jobs"
        case .news:
            return "news"
        case .logs:
            return "logs"
        }
    }
}

private extension MainTab {
    var ownerAdvancedSurface: OwnerAdvancedSurface? {
        switch self {
        case .pmInbox:
            return .pmInbox
        case .orderTicket:
            return .manualOrders
        case .blotter:
            return .ordersBlotter
        case .proposals:
            return .proposals
        case .signals:
            return .signals
        case .jobs:
            return .jobs
        case .logs:
            return .logsAudit
        case .commandCenter, .marketWatch, .news, .systemControl:
            return nil
        }
    }
}

private enum TicketOrderType: String, CaseIterable, Identifiable {
    case market = "Market"
    case limit = "Limit"

    var id: String { rawValue }

    var alpacaType: OrderType {
        switch self {
        case .market:
            return .market
        case .limit:
            return .limit
        }
    }
}

private enum TicketInstrumentKind: String, CaseIterable, Identifiable {
    case equity = "Equity"
    case option = "Option"

    var id: String { rawValue }

    var tradingInstrumentType: TradingInstrumentType {
        switch self {
        case .equity:
            return .equity
        case .option:
            return .option
        }
    }
}

private enum BracketPreset: String, CaseIterable, Identifiable {
    case custom = "Custom"
    case conservative = "Conservative (0.5%)"
    case standard = "Standard (1.0%)"
    case wide = "Wide (2.0%)"

    var id: String { rawValue }

    var profitPercent: Decimal? {
        switch self {
        case .custom:
            return nil
        case .conservative:
            return Decimal(string: "0.005")
        case .standard:
            return Decimal(string: "0.01")
        case .wide:
            return Decimal(string: "0.02")
        }
    }

    var lossPercent: Decimal? {
        switch self {
        case .custom:
            return nil
        case .conservative:
            return Decimal(string: "0.005")
        case .standard:
            return Decimal(string: "0.01")
        case .wide:
            return Decimal(string: "0.01")
        }
    }
}

private enum TicketMessageLevel {
    case success
    case error
}

enum TicketSubmissionOutcome {
    case success(String)
    case failure(String)
}

struct OrderTicketView: View {
    @EnvironmentObject private var appModel: AppModel

    @State private var instrument: TicketInstrumentKind = .equity
    @State private var symbol = ""
    @State private var qty = 1
    @State private var side: OrderSide = .buy
    @State private var type: TicketOrderType = .market
    @State private var limitPrice = ""
    @State private var timeInForce: TimeInForce = .day
    @State private var bracketEnabled = false
    @State private var bracketPreset: BracketPreset = .custom
    @State private var takeProfitPrice = ""
    @State private var stopLossPrice = ""
    @State private var stopLossLimitPrice = ""
    @State private var shortRiskAcknowledged = false
    @State private var isSubmitting = false
    @State private var feedbackMessage: String?
    @State private var feedbackLevel: TicketMessageLevel = .success
    @State private var optionContractMetadata: OptionContract?
    @State private var optionMetadataLookupTask: Task<Void, Never>?

    private let supportedTIF: [TimeInForce] = [.day, .gtc]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Manual Order Ticket")
                .font(.title2)

            HStack(spacing: 12) {
                Text("Environment: \(appModel.selectedEnvironmentName)")
                    .font(.callout)
                Text(appModel.liveSafetyStatusLabel)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(appModel.liveSafetyStatusColor.opacity(0.2))
                    .clipShape(Capsule())
            }

            if let reason = appModel.tradingDisabledReason {
                Text("Order entry disabled: \(reason)")
                    .foregroundStyle(.red)
                    .font(.callout.weight(.semibold))
            }

            if isOpeningOrIncreasingShort {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Warning: This will open/increase a short position.")
                        .foregroundStyle(.orange)
                        .font(.callout.weight(.semibold))
                    Toggle("I understand", isOn: $shortRiskAcknowledged)
                }
                .padding(10)
                .background(Color.orange.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    Text("Instrument")
                    Picker("Instrument", selection: $instrument) {
                        ForEach(TicketInstrumentKind.allCases) { kind in
                            Text(kind.rawValue).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                GridRow {
                    Text("Symbol")
                    TextField(
                        instrument == .equity
                            ? "AAPL"
                            : "AAPL240119C00190000",
                        text: $symbol
                    )
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text(instrument == .equity ? "Qty" : "Contracts")
                    Stepper(value: $qty, in: 1...10_000) {
                        Text("\(qty)")
                    }
                }
                GridRow {
                    Text("Side")
                    Picker("Side", selection: $side) {
                        Text("Buy").tag(OrderSide.buy)
                        Text("Sell").tag(OrderSide.sell)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                GridRow {
                    Text("Type")
                    Picker("Type", selection: $type) {
                        ForEach(TicketOrderType.allCases) { ticketType in
                            Text(ticketType.rawValue).tag(ticketType)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                if type == .limit {
                    GridRow {
                        Text("Limit price")
                        TextField("190.50", text: $limitPrice)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                GridRow {
                    Text("Time in force")
                    Picker("Time in force", selection: $timeInForce) {
                        ForEach(supportedTIF, id: \.self) { tif in
                            Text(tif.rawValue.uppercased()).tag(tif)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
            .frame(maxWidth: 520, alignment: .leading)

            if instrument == .option {
                if let metadata = optionContractMetadata {
                    Text(
                        "Contract: underlying=\(metadata.underlyingSymbol ?? "?") exp=\(metadata.expirationDate ?? "?") strike=\(metadata.strikePrice ?? "?") type=\(metadata.type?.uppercased() ?? "?")"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                } else {
                    Text("Option contract metadata unavailable (best effort).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            GroupBox("Bracket (optional)") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Bracket", isOn: $bracketEnabled)
                        .disabled(instrument == .option)

                    if bracketEnabled {
                        Picker("Preset", selection: $bracketPreset) {
                            ForEach(BracketPreset.allCases) { preset in
                                Text(preset.rawValue).tag(preset)
                            }
                        }
                        .pickerStyle(.menu)

                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                            GridRow {
                                Text("Take Profit")
                                TextField("194.00", text: $takeProfitPrice)
                                    .textFieldStyle(.roundedBorder)
                            }
                            GridRow {
                                Text("Stop Loss")
                                TextField("188.00", text: $stopLossPrice)
                                    .textFieldStyle(.roundedBorder)
                            }
                            GridRow {
                                Text("Stop Limit")
                                TextField("(optional)", text: $stopLossLimitPrice)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }

                        if type != .limit {
                            Text("Presets auto-fill when order type is Limit and a valid limit price is provided.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: 520, alignment: .leading)
            .opacity(instrument == .option ? 0.65 : 1)

            if instrument == .option {
                Text("Bracket presets are disabled for options in this slice.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button("Submit Order") {
                    submit()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSubmitting || (isOpeningOrIncreasingShort && !shortRiskAcknowledged) || !appModel.tradingEnabled)

                if isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let feedbackMessage {
                Text(feedbackMessage)
                    .foregroundStyle(feedbackLevel == .success ? .green : .red)
                    .font(.callout)
            }

            Spacer(minLength: 0)
        }
        .padding(18)
        .onChange(of: side) { _ in
            shortRiskAcknowledged = false
            applyPresetIfPossible()
        }
        .onChange(of: bracketPreset) { _ in
            applyPresetIfPossible()
        }
        .onChange(of: limitPrice) { _ in
            applyPresetIfPossible()
        }
        .onChange(of: type) { _ in
            applyPresetIfPossible()
        }
        .onChange(of: instrument) { _ in
            if instrument == .option {
                bracketEnabled = false
            }
            shortRiskAcknowledged = false
            loadOptionMetadata()
        }
        .onChange(of: symbol) { _ in
            shortRiskAcknowledged = false
            loadOptionMetadata()
        }
    }

    private func submit() {
        feedbackMessage = nil
        isSubmitting = true
        let symbolValue = symbol
        let instrumentValue = instrument.tradingInstrumentType
        let qtyValue = qty
        let sideValue = side
        let typeValue = type.alpacaType
        let limitPriceValue = limitPrice
        let tifValue = timeInForce
        let bracketEnabledValue = bracketEnabled
        let takeProfitValue = takeProfitPrice
        let stopLossValue = stopLossPrice
        let stopLossLimitValue = stopLossLimitPrice

        Task { @MainActor in
            let result = await appModel.submitManualOrder(
                instrumentType: instrumentValue,
                symbol: symbolValue,
                qty: qtyValue,
                side: sideValue,
                type: typeValue,
                limitPriceText: limitPriceValue,
                timeInForce: tifValue,
                bracketEnabled: bracketEnabledValue,
                takeProfitText: takeProfitValue,
                stopLossText: stopLossValue,
                stopLossLimitText: stopLossLimitValue
            )
            isSubmitting = false
            switch result {
            case .success(let message):
                feedbackLevel = .success
                feedbackMessage = message
            case .failure(let error):
                feedbackLevel = .error
                feedbackMessage = error
            }
        }
    }

    private func applyPresetIfPossible() {
        guard instrument == .equity else {
            return
        }
        guard bracketEnabled, bracketPreset != .custom else {
            return
        }
        guard type == .limit,
              let profitPercent = bracketPreset.profitPercent,
              let lossPercent = bracketPreset.lossPercent,
              let entryPrice = Decimal(string: limitPrice.trimmingCharacters(in: .whitespacesAndNewlines), locale: Locale(identifier: "en_US_POSIX"))
        else {
            return
        }

        let one = Decimal(string: "1")!
        let takeProfit: Decimal
        let stopLoss: Decimal

        switch side {
        case .buy:
            takeProfit = rounded2(entryPrice * (one + profitPercent))
            stopLoss = rounded2(entryPrice * (one - lossPercent))
        case .sell:
            takeProfit = rounded2(entryPrice * (one - profitPercent))
            stopLoss = rounded2(entryPrice * (one + lossPercent))
        }

        takeProfitPrice = decimalString(takeProfit)
        stopLossPrice = decimalString(stopLoss)
    }

    private func rounded2(_ value: Decimal) -> Decimal {
        var value = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 2, .bankers)
        return rounded
    }

    private func decimalString(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }

    private var isOpeningOrIncreasingShort: Bool {
        guard instrument == .equity else {
            return false
        }
        guard side == .sell else {
            return false
        }
        let normalizedSymbol = symbol
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard !normalizedSymbol.isEmpty else {
            return false
        }
        return appModel.currentPositionQuantity(for: normalizedSymbol) <= 0
    }

    private func loadOptionMetadata() {
        optionMetadataLookupTask?.cancel()

        guard instrument == .option else {
            optionContractMetadata = nil
            return
        }

        let normalized = symbol
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard !normalized.isEmpty,
              OptionContractSymbol.parse(normalized) != nil
        else {
            optionContractMetadata = nil
            return
        }

        optionMetadataLookupTask = Task { @MainActor in
            optionContractMetadata = await appModel.lookupOptionContract(symbol: normalized)
        }
    }
}

struct BlotterView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var replaceTarget: OrderRow?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Orders Blotter")
                .font(.title2)

            HStack(spacing: 16) {
                Text("Engine: \(appModel.engineStatusText)")
                Text("Connection: \(appModel.connectionState)")
                Text("Environment: \(appModel.selectedEnvironmentName)")
                Text("Keys: \(appModel.selectedEnvironmentSummary)")
                    .foregroundStyle(appModel.selectedEnvironmentKeysFound ? .green : .red)
            }
            .font(.callout)

            Text(appModel.accountSummaryText)
                .font(.callout)
                .textSelection(.enabled)

            Text("Open Orders")
                .font(.headline)

            if appModel.openOrders.isEmpty {
                Text("No open orders.")
                    .foregroundStyle(.secondary)
            } else {
                Table(appModel.openOrders) {
                    TableColumn("Inst") { row in
                        Text(row.instrumentLabel)
                            .font(.system(.body, design: .monospaced))
                    }
                    TableColumn("Symbol") { row in
                        if let underlying = row.underlyingSymbol,
                           row.instrumentType == .option {
                            Text("\(row.displayedSymbol) (\(underlying))")
                        } else {
                            Text(row.displayedSymbol)
                        }
                    }
                    TableColumn("Side") { row in
                        Text(row.side.uppercased())
                    }
                    TableColumn("Qty") { row in
                        Text(row.qty)
                    }
                    TableColumn("Filled") { row in
                        Text(row.filledQty)
                    }
                    TableColumn("Type") { row in
                        Text((row.orderType ?? "?").uppercased())
                    }
                    TableColumn("Limit") { row in
                        Text(row.limitPrice ?? "-")
                    }
                    TableColumn("Status") { row in
                        Text(row.status)
                    }
                    TableColumn("Order ID") { row in
                        Text(row.shortID)
                            .font(.system(.body, design: .monospaced))
                    }
                    TableColumn("Action") { row in
                        HStack(spacing: 8) {
                            Button("Cancel") {
                                appModel.cancelOrder(orderID: row.id)
                            }
                            .disabled(!row.canCancel || appModel.cancelingOrderIDs.contains(row.id))

                            Button("Replace") {
                                replaceTarget = row
                            }
                            .disabled(
                                !row.canReplace ||
                                appModel.replacingOrderIDs.contains(row.id) ||
                                !appModel.tradingEnabled
                            )
                        }
                    }
                }
                .frame(minHeight: 220)
            }

            Text("Positions")
                .font(.headline)

            if appModel.positions.isEmpty {
                Text("No positions.")
                    .foregroundStyle(.secondary)
            } else {
                Table(appModel.positions) {
                    TableColumn("Symbol") { row in
                        Text(row.symbol)
                    }
                    TableColumn("Direction") { row in
                        Text(row.directionLabel)
                            .foregroundStyle(row.isShort ? .orange : .primary)
                    }
                    TableColumn("Qty") { row in
                        Text(row.qty)
                    }
                    TableColumn("Market Value") { row in
                        Text(row.marketValue)
                    }
                }
                .frame(minHeight: 140)
            }

            Spacer(minLength: 0)
        }
        .padding(18)
        .sheet(item: $replaceTarget) { row in
            ReplaceOrderSheet(order: row)
                .environmentObject(appModel)
        }
    }
}

struct ReplaceOrderSheet: View {
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appModel: AppModel

    let order: OrderRow

    @State private var qtyText: String
    @State private var limitPriceText: String
    @State private var feedbackMessage: String?
    @State private var feedbackLevel: TicketMessageLevel = .success

    init(order: OrderRow) {
        self.order = order
        _qtyText = State(initialValue: order.qty)
        _limitPriceText = State(initialValue: order.limitPrice ?? "")
        _feedbackMessage = State(initialValue: nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Replace Order \(order.shortID)")
                .font(.title3)

            Text("Symbol: \(order.symbol) • Side: \(order.side.uppercased())")
                .font(.callout)
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("New Qty")
                    TextField("Qty", text: $qtyText)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("New Limit")
                    TextField("Limit (optional)", text: $limitPriceText)
                        .textFieldStyle(.roundedBorder)
                }
            }

            if let feedbackMessage {
                Text(feedbackMessage)
                    .foregroundStyle(feedbackLevel == .success ? .green : .red)
                    .font(.callout)
            }

            if let reason = appModel.tradingDisabledReason {
                Text("Replace disabled: \(reason)")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Close") {
                    dismiss()
                }
                Button("Submit Replace") {
                    submitReplace()
                }
                .buttonStyle(.borderedProminent)
                .disabled(appModel.replacingOrderIDs.contains(order.id) || !appModel.tradingEnabled)
            }
        }
        .padding(18)
        .frame(minWidth: 420)
    }

    private func submitReplace() {
        feedbackMessage = nil
        let qtyValue = qtyText
        let limitValue = limitPriceText

        Task { @MainActor in
            let outcome = await appModel.submitReplaceOrder(
                orderID: order.id,
                qtyText: qtyValue,
                limitPriceText: limitValue
            )
            switch outcome {
            case .success(let message):
                feedbackLevel = .success
                feedbackMessage = message
                dismiss()
            case .failure(let message):
                feedbackLevel = .error
                feedbackMessage = message
            }
        }
    }
}

extension View {
    @ViewBuilder
    func ownerActionButton(prominent: Bool = false) -> some View {
        if prominent {
            buttonStyle(.borderedProminent)
                .tint(.blue)
        } else {
            buttonStyle(.bordered)
                .tint(.blue)
        }
    }

    func ownerToggleTint(isOn: Bool) -> some View {
        toggleStyle(.switch)
            .tint(isOn ? .green : .red)
    }
}

struct MarketWatchView: View {
    @EnvironmentObject private var appModel: AppModel

    @State private var newSymbol = ""
    @State private var feedbackMessage: String?
    @State private var showSelectionSheet = false
    @State private var draftedSelection: Set<String> = []
    @State private var selectedCardSymbol: String?
    @State private var paperPortfolioPanelCollapsed = false
    @State private var livePortfolioPanelCollapsed = true

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.03, green: 0.05, blue: 0.08),
                    Color(red: 0.06, green: 0.09, blue: 0.14)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    portfolioWatchHeader

                    if let feedbackMessage, feedbackMessage.isEmpty == false {
                        Text(feedbackMessage)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 2)
                    }

                    if appModel.watchlistSymbols.isEmpty {
                        emptyWatchlistState
                    } else {
                        selectedSymbolsStrip
                        chartWallSection
                    }

                    portfolioIntelligenceSection
                }
                .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .sheet(isPresented: $showSelectionSheet) {
            selectionSheet
        }
        .sheet(item: selectedCardBinding) { card in
            portfolioWatchDetailSheet(card: card)
        }
        .onAppear {
            draftedSelection = Set(appModel.effectivePortfolioWatchChartSymbols)
            livePortfolioPanelCollapsed = appModel.portfolioIntelligenceSnapshot.live.availability == .unavailable
        }
    }

    private var selectedCardBinding: Binding<PortfolioWatchCardPresentation?> {
        Binding(
            get: {
                guard let selectedCardSymbol else {
                    return nil
                }
                return appModel.portfolioWatchChartCards.first(where: { $0.symbol == selectedCardSymbol })
            },
            set: { newValue in
                selectedCardSymbol = newValue?.symbol
            }
        )
    }

    private var currentSessionState: PortfolioWatchSessionState {
        PortfolioWatchSessionState.resolve(at: Date())
    }

    private var portfolioWatchHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Portfolio Watch")
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Keep this wall open during market hours for a live visual read on the names you care about most.")
                        .font(.callout)
                        .foregroundStyle(Color.white.opacity(0.72))
                }

                Spacer(minLength: 16)

                VStack(alignment: .trailing, spacing: 10) {
                    HStack(spacing: 8) {
                        statusPill(title: "Feed", value: appModel.selectedMarketDataFeed.displayName)
                        statusPill(title: "Link", value: connectionTitle)
                        statusPill(title: "Session", value: currentSessionState.displayTitle)
                    }

                    HStack(spacing: 8) {
                        Button("Edit Wall") {
                            draftedSelection = Set(appModel.effectivePortfolioWatchChartSymbols)
                            showSelectionSheet = true
                        }
                        .ownerActionButton(prominent: true)

                        Button("Refresh Wall") {
                            Task { @MainActor in
                                _ = await appModel.refreshPortfolioWatchChartWallConfiguration()
                            }
                        }
                        .ownerActionButton()
                    }
                }
            }

            HStack(spacing: 12) {
                summaryTile(title: "Watched Names", value: "\(appModel.watchlistSymbols.count)")
                summaryTile(
                    title: "Charts On Wall",
                    value: "\(appModel.portfolioWatchChartCards.count) / \(PortfolioWatchChartWallConfiguration.maximumSelectedSymbols)"
                )
                summaryTile(title: "Live Positions", value: "\(appModel.positions.count)")
                summaryTile(title: "Stream Coverage", value: marketDataCoverageSummary)
            }
        }
        .padding(20)
        .background(portfolioWatchPanelBackground)
    }

    private var emptyWatchlistState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("No watched assets yet")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text("Add a symbol to start the intraday chart wall. Watchlist truth remains app-owned, and the wall will automatically seed from the names you choose.")
                .font(.callout)
                .foregroundStyle(Color.white.opacity(0.72))

            HStack(spacing: 8) {
                TextField("Add symbol (AAPL or AAPL240119C00190000)", text: $newSymbol)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)

                Button("Add To Watchlist") {
                    addSymbol()
                }
                .ownerActionButton(prominent: true)
            }
        }
        .padding(22)
        .background(portfolioWatchPanelBackground)
    }

    private var selectedSymbolsStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Selected Watch Wall")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("The wall is a single-day intraday view that resets each trading day and stays bounded to selected watchlist names.")
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.68))
                }
                Spacer()
                Button("Edit Selection") {
                    draftedSelection = Set(appModel.effectivePortfolioWatchChartSymbols)
                    showSelectionSheet = true
                }
                .ownerActionButton()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(appModel.effectivePortfolioWatchChartSymbols, id: \.self) { symbol in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(isHeldSymbol(symbol) ? Color.green : Color.blue)
                                .frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(symbol)
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .layoutPriority(1)
                                if let label = portfolioWatchBenchmarkShortLabel(for: symbol) {
                                    Text(label)
                                        .font(.caption2)
                                        .foregroundStyle(Color.white.opacity(0.62))
                                        .lineLimit(1)
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(0.08))
                        )
                    }
                }
            }
        }
        .padding(18)
        .background(portfolioWatchPanelBackground)
    }

    private var chartWallSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Live Intraday Wall")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                    Text("Tap any chart for a focused view. The wall is the primary live experience, so detail stays secondary.")
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.68))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(.bottom, 2)

            if let liveCoverageNote {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .foregroundStyle(Color.white.opacity(0.72))
                    Text(liveCoverageNote)
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.72))
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                )
            }

            let cards = appModel.portfolioWatchChartCards
            let cardIdentityKey = cards.map(\.symbol)
            let columns = [
                GridItem(
                    .adaptive(
                        minimum: PortfolioWatchWallLayout.minimumCardWidth(for: cards.count),
                        maximum: .infinity
                    ),
                    spacing: 18,
                    alignment: .top
                )
            ]

            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                ForEach(cards) { card in
                    Button {
                        selectedCardSymbol = card.symbol
                    } label: {
                        portfolioWatchCard(card)
                    }
                    .buttonStyle(.plain)
                }
            }
            .animation(.easeInOut(duration: 0.22), value: cardIdentityKey)
        }
        .padding(18)
        .background(portfolioWatchPanelBackground)
    }

    private var portfolioIntelligenceSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Portfolio Intelligence")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                    Text("App-owned account, position, exposure, order, and data-quality truth. Advanced return and risk metrics stay blank until enough history exists.")
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.68))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }

            portfolioEnvironmentPanel(
                appModel.portfolioIntelligenceSnapshot.paper,
                collapsed: $paperPortfolioPanelCollapsed
            )
            portfolioEnvironmentPanel(
                appModel.portfolioIntelligenceSnapshot.live,
                collapsed: $livePortfolioPanelCollapsed
            )
        }
        .padding(18)
        .background(portfolioWatchPanelBackground)
    }

    private func portfolioEnvironmentPanel(
        _ summary: PortfolioEnvironmentSummary,
        collapsed: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    collapsed.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: collapsed.wrappedValue ? "chevron.right" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.white.opacity(0.70))
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(summary.environment.displayTitle)
                                .font(.headline)
                                .foregroundStyle(.white)
                            Text(summary.availability == .active ? "Active Truth" : "Unavailable")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule()
                                        .fill(summary.availability == .active ? Color.green.opacity(0.18) : Color.white.opacity(0.10))
                                )
                                .foregroundStyle(summary.availability == .active ? Color.green : Color.white.opacity(0.62))
                        }
                        Text(summary.statusSummary)
                            .font(.footnote)
                            .foregroundStyle(Color.white.opacity(0.66))
                            .lineLimit(2)
                    }
                    Spacer()
                    Text(portfolioCurrency(summary.account?.equity) ?? "—")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !collapsed.wrappedValue {
                if summary.availability == .unavailable {
                    Text(summary.statusSummary)
                        .font(.callout)
                        .foregroundStyle(Color.white.opacity(0.70))
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.white.opacity(0.05))
                        )
                } else {
                    portfolioEnvironmentDetail(summary)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(0.045))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white.opacity(0.075), lineWidth: 1)
                )
        )
    }

    private func portfolioEnvironmentDetail(_ summary: PortfolioEnvironmentSummary) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150), spacing: 10)],
                alignment: .leading,
                spacing: 10
            ) {
                portfolioMetricTile(title: "Equity", value: portfolioCurrency(summary.account?.equity) ?? "—")
                portfolioMetricTile(title: "Cash", value: portfolioCurrency(summary.account?.cash) ?? "—")
                portfolioMetricTile(title: "Buying Power", value: portfolioCurrency(summary.account?.buyingPower) ?? "—")
                portfolioMetricTile(title: "Day P&L", value: "Unavailable")
                portfolioMetricTile(title: "Unrealized P&L", value: "Unavailable")
                portfolioMetricTile(title: "Open Orders", value: "\(summary.orderActivity.openOrderCount)")
                portfolioMetricTile(title: "Positions", value: "\(summary.positions.count)")
                portfolioMetricTile(title: "Price Quality", value: "\(summary.dataQuality.pricedPositionCount)/\(summary.dataQuality.positionCount)")
            }

            portfolioRiskVisualLayer(summary)
            portfolioHoldingsBlock(summary)
            portfolioOrderActivityBlock(summary.orderActivity)
            portfolioAdvancedMetricsReadinessBlock(summary.advancedMetricReadiness)
        }
    }

    private func portfolioMetricTile(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.48))
            Text(value)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Color.white.opacity(0.055))
        )
    }

    private func portfolioRiskVisualLayer(_ summary: PortfolioEnvironmentSummary) -> some View {
        let visual = summary.riskVisualSummary
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Risk And Exposure")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text("Based on app-owned \(summary.environment.displayTitle) truth")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.54))
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 280), spacing: 12)],
                alignment: .leading,
                spacing: 12
            ) {
                portfolioExposureCompositionCard(visual)
                portfolioConcentrationCard(visual.concentration)
            }

            portfolioDataQualityRibbon(visual.dataQualityRibbon)
        }
    }

    private func portfolioExposureCompositionCard(_ visual: PortfolioRiskVisualSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Long / Short / Cash")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.64))
            portfolioExposureCompositionBar(visual.exposureSegments)
                .padding(.vertical, 4)
            HStack(spacing: 10) {
                ForEach(visual.exposureSegments) { segment in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(portfolioRiskToneColor(segment.tone))
                                .frame(width: 7, height: 7)
                            Text(segment.kind.displayTitle)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.82))
                        }
                        Text(portfolioCurrency(segment.amount) ?? "—")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.white)
                        Text(portfolioPercent(segment.portfolioWeight) ?? "—")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.white.opacity(0.56))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Divider()
                .overlay(Color.white.opacity(0.10))
            HStack(spacing: 10) {
                portfolioMiniRiskStat(title: "Gross", value: portfolioCurrency(visual.grossExposure) ?? "—")
                portfolioMiniRiskStat(title: "Net", value: portfolioCurrency(visual.netExposure) ?? "—")
                portfolioMiniRiskStat(title: "Cash Wt", value: portfolioPercent(visual.cashWeight) ?? "—")
            }
        }
        .padding(13)
        .background(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }

    private func portfolioExposureCompositionBar(_ segments: [PortfolioExposureVisualSegment]) -> some View {
        GeometryReader { geometry in
            HStack(spacing: 3) {
                ForEach(segments) { segment in
                    let width = max(geometry.size.width * CGFloat(segment.compositionShare), segment.compositionShare > 0 ? 5 : 0)
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(portfolioRiskToneColor(segment.tone).opacity(segment.compositionShare > 0 ? 0.95 : 0.16))
                        .frame(width: width)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 14)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }

    private func portfolioConcentrationCard(_ concentration: PortfolioConcentrationVisualSummary) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Concentration")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.64))
                Spacer()
                Text(concentration.level.displayTitle)
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(portfolioConcentrationColor(concentration.level).opacity(0.16))
                    )
                    .foregroundStyle(portfolioConcentrationColor(concentration.level))
            }
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(concentration.largestPositionSymbol ?? "—")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                Text("largest")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.54))
            }
            portfolioVisualProgressBar(
                value: concentration.largestPositionWeight,
                color: portfolioConcentrationColor(concentration.level)
            )
            HStack(spacing: 10) {
                portfolioMiniRiskStat(title: "Largest", value: portfolioPercent(concentration.largestPositionWeight) ?? "—")
                portfolioMiniRiskStat(title: "Top 3", value: portfolioPercent(concentration.topThreeConcentration) ?? "—")
            }
            Text(concentration.summary)
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.58))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(13)
        .background(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }

    private func portfolioDataQualityRibbon(_ ribbon: PortfolioDataQualityRibbon) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: portfolioDataQualityIcon(ribbon.status))
                .font(.callout.weight(.semibold))
                .foregroundStyle(portfolioDataQualityColor(ribbon.status))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(ribbon.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.82))
                ForEach(Array(ribbon.messages.enumerated()), id: \.offset) { _, message in
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.60))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(portfolioDataQualityColor(ribbon.status).opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(portfolioDataQualityColor(ribbon.status).opacity(0.18), lineWidth: 1)
                )
        )
    }

    private func portfolioMiniRiskStat(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.46))
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.86))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func portfolioVisualProgressBar(value: Double?, color: Color) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.white.opacity(0.07))
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(color.opacity(0.82))
                    .frame(width: geometry.size.width * CGFloat(min(max(value ?? 0, 0), 1)))
            }
        }
        .frame(height: 8)
    }

    private func portfolioAdvancedMetricsReadinessBlock(_ readiness: PortfolioAdvancedMetricReadiness) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Advanced Metrics Readiness")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            Text(readiness.summary)
                .font(.footnote)
                .foregroundStyle(Color.white.opacity(0.66))
                .fixedSize(horizontal: false, vertical: true)
            ForEach(readiness.items.prefix(4)) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.metric.displayTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.78))
                        .frame(width: 126, alignment: .leading)
                    Text(item.status.rawValue.replacingOccurrences(of: "_", with: " "))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.orange.opacity(0.92))
                    Text(item.reason)
                        .font(.caption)
                        .foregroundStyle(Color.white.opacity(0.56))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }

    private func portfolioHoldingsBlock(_ summary: PortfolioEnvironmentSummary) -> some View {
        let visual = summary.riskVisualSummary
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Position Weight Bars")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text("Absolute weights by equity/exposure base")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.48))
            }

            if visual.positionBars.isEmpty {
                Text("No positions are recorded for this environment.")
                    .font(.footnote)
                    .foregroundStyle(Color.white.opacity(0.64))
            } else {
                ForEach(visual.positionBars) { position in
                    portfolioPositionWeightRow(position)
                }
            }
        }
    }

    private func portfolioPositionWeightRow(_ position: PortfolioPositionWeightVisual) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(position.symbol)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 64, alignment: .leading)
                Text(position.side == .short ? "SHORT" : "LONG")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(portfolioRiskToneColor(position.tone))
                    .frame(width: 52, alignment: .leading)
                Text(portfolioQuantity(position.quantity))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.86))
                    .frame(width: 80, alignment: .leading)
                Text(portfolioCurrency(position.marketValueSigned) ?? "—")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 110, alignment: .leading)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(portfolioPercent(position.absoluteWeight) ?? "—")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(position.hasUsablePrice ? position.priceSource.displayTitle : position.dataQualitySummary)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(position.hasUsablePrice ? Color.white.opacity(0.54) : Color.orange.opacity(0.92))
                }
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(portfolioRiskToneColor(position.tone).opacity(position.hasUsablePrice ? 0.78 : 0.36))
                        .frame(width: geometry.size.width * CGFloat(min(max(position.relativeBarShare, 0), 1)))
                }
            }
            .frame(height: 8)

            HStack(spacing: 10) {
                Text("Price \(portfolioPrice(position.latestPrice) ?? "—")")
                Text(position.dataQualitySummary)
                Text("Abs MV \(portfolioCurrency(position.marketValueAbsolute) ?? "—")")
                Text(position.side == .short ? "Short exposure" : "Long exposure")
            }
            .font(.caption)
            .foregroundStyle(Color.white.opacity(0.56))
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.045))
        )
    }

    private func portfolioRiskToneColor(_ tone: PortfolioRiskVisualTone) -> Color {
        switch tone {
        case .long:
            return Color.green
        case .short:
            return Color.red
        case .cash:
            return Color.blue
        case .neutral:
            return Color.white.opacity(0.72)
        case .warning:
            return Color.orange
        case .unavailable:
            return Color.white.opacity(0.48)
        }
    }

    private func portfolioConcentrationColor(_ level: PortfolioConcentrationLevel) -> Color {
        switch level {
        case .unavailable:
            return Color.white.opacity(0.48)
        case .moderate:
            return Color.green
        case .elevated:
            return Color.orange
        case .high:
            return Color.red
        }
    }

    private func portfolioDataQualityColor(_ status: PortfolioDataQualityRibbonStatus) -> Color {
        switch status {
        case .clean:
            return Color.green
        case .warning:
            return Color.orange
        case .unavailable:
            return Color.white.opacity(0.52)
        }
    }

    private func portfolioDataQualityIcon(_ status: PortfolioDataQualityRibbonStatus) -> String {
        switch status {
        case .clean:
            return "checkmark.seal.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .unavailable:
            return "pause.circle.fill"
        }
    }

    private func portfolioPositionRow(_ position: PortfolioPositionMetric) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(position.symbol)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 64, alignment: .leading)
                Text(position.side == .short ? "SHORT" : "LONG")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(position.side == .short ? Color.red : Color.green)
                    .frame(width: 48, alignment: .leading)
                Text(portfolioQuantity(position.quantity))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.86))
                    .frame(width: 80, alignment: .leading)
                Text(portfolioCurrency(position.marketValueSigned) ?? "—")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 110, alignment: .leading)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(portfolioPercent(position.absoluteWeight) ?? "—")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(position.dataQualitySummary)
                        .font(.caption2)
                        .foregroundStyle(Color.white.opacity(0.54))
                }
            }
            HStack(spacing: 10) {
                Text("Price \(portfolioPrice(position.latestPrice) ?? "—")")
                Text(position.priceSource.displayTitle)
                Text("Avg cost unavailable")
                Text("Day change unavailable")
            }
            .font(.caption)
            .foregroundStyle(Color.white.opacity(0.56))

            ProgressView(value: min(max(position.absoluteWeight ?? 0, 0), 1))
                .tint(position.side == .short ? Color.red : Color.green)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.045))
        )
    }

    private func portfolioOrderActivityBlock(_ orderActivity: PortfolioOrderActivitySummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Orders And Execution")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            Text("\(orderActivity.openOrderCount) open orders • \(orderActivity.recentFilledOrderCount) filled orders currently retained in Store.")
                .font(.footnote)
                .foregroundStyle(Color.white.opacity(0.68))
            if let latest = orderActivity.latestOpenOrderSummary {
                Text("Latest open order: \(latest)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.72))
            }
            if let lifecycleSummary = orderActivity.lifecycleSummary {
                Text(lifecycleSummary)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.76))
            }
            if let lifecycleDetail = orderActivity.lifecycleDetail {
                Text(lifecycleDetail)
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.58))
                    .lineLimit(3)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }

    private var selectionSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Portfolio Watch Wall")
                .font(.title2.weight(.semibold))

            Text("Choose up to \(PortfolioWatchChartWallConfiguration.maximumSelectedSymbols) watched assets for the live chart wall. This is a visual preference layered on top of the durable watchlist.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("Add symbol to watchlist", text: $newSymbol)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)

                Button("Add To Watchlist") {
                    addSymbol()
                }
                .ownerActionButton(prominent: true)

                Spacer()

                Text("\(draftedSelection.count) selected")
                    .font(.callout.weight(.semibold))
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(selectionEditorRows) { row in
                        let symbol = row.symbol
                        HStack(spacing: 12) {
                            Toggle(
                                isOn: Binding(
                                    get: { draftedSelection.contains(symbol) },
                                    set: { isOn in
                                        if isOn {
                                            guard draftedSelection.count < PortfolioWatchChartWallConfiguration.maximumSelectedSymbols
                                            else {
                                                return
                                            }
                                            draftedSelection.insert(symbol)
                                        } else {
                                            draftedSelection.remove(symbol)
                                        }
                                    }
                                )
                            ) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(symbol)
                                            .font(.headline)
                                            .lineLimit(1)
                                            .fixedSize(horizontal: true, vertical: false)
                                            .layoutPriority(1)
                                        if let label = portfolioWatchBenchmarkShortLabel(for: symbol) {
                                            Text(label)
                                                .font(.caption.weight(.medium))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        if isHeldSymbol(symbol) {
                                            Text("Position")
                                                .font(.caption.weight(.semibold))
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 3)
                                                .background(Color.green.opacity(0.18))
                                                .clipShape(Capsule())
                                        } else {
                                            Text("Watch")
                                                .font(.caption.weight(.semibold))
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 3)
                                                .background(Color.blue.opacity(0.18))
                                                .clipShape(Capsule())
                                        }
                                        if row.isWallOnly {
                                            Text("Wall only")
                                                .font(.caption.weight(.semibold))
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 3)
                                                .background(Color.orange.opacity(0.18))
                                                .clipShape(Capsule())
                                        }
                                    }

                                    Text(
                                        row.isWallOnly
                                            ? "\(selectionRowPriceSummary(symbol: symbol)) • Preserved from saved wall; not in current watchlist snapshot."
                                            : selectionRowPriceSummary(symbol: symbol)
                                    )
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .ownerToggleTint(isOn: draftedSelection.contains(symbol))
                            .disabled(
                                draftedSelection.contains(symbol) == false &&
                                draftedSelection.count >= PortfolioWatchChartWallConfiguration.maximumSelectedSymbols
                            )

                            Spacer()

                            Button("Remove") {
                                Task { @MainActor in
                                    draftedSelection.remove(symbol)
                                    if row.isWatchlisted {
                                        await appModel.removeWatchSymbol(symbol)
                                    }
                                }
                            }
                            .ownerActionButton()
                        }
                        .padding(.vertical, 4)

                        Divider()
                    }
                }
            }

            HStack(spacing: 8) {
                Button("Cancel") {
                    showSelectionSheet = false
                    draftedSelection = Set(appModel.effectivePortfolioWatchChartSymbols)
                }
                .ownerActionButton()

                Button("Save Wall") {
                    Task { @MainActor in
                        let orderedSelection = portfolioWatchChartWallOrderedSelectionForSave(
                            draftedSelection: draftedSelection,
                            currentSelectedSymbols: appModel.effectivePortfolioWatchChartSymbols,
                            watchlistSymbols: appModel.watchlistSymbols
                        )
                        if let message = await appModel.upsertPortfolioWatchChartWallSelection(orderedSelection) {
                            feedbackMessage = message
                        } else {
                            feedbackMessage = nil
                            showSelectionSheet = false
                        }
                    }
                }
                .ownerActionButton(prominent: true)
                .disabled(draftedSelection.isEmpty && selectionEditorRows.isEmpty == false)

                Spacer()
            }
        }
        .padding(22)
        .frame(minWidth: 720, minHeight: 560)
    }

    private var selectionEditorRows: [PortfolioWatchChartWallSelectionEditorRow] {
        makePortfolioWatchChartWallSelectionEditorRows(
            selectedSymbols: appModel.effectivePortfolioWatchChartSymbols,
            watchlistSymbols: appModel.watchlistSymbols
        )
    }

    private func portfolioWatchCard(_ card: PortfolioWatchCardPresentation) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(card.symbol)
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .layoutPriority(1)
                        Text(card.sessionState.displayTitle)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.white.opacity(0.12))
                            .clipShape(Capsule())
                    }

                    Text(card.benchmarkLabel ?? (card.isHeld ? "Current portfolio position" : "Watchlist monitor"))
                        .font(.footnote.weight(card.benchmarkLabel == nil ? .regular : .medium))
                        .foregroundStyle(Color.white.opacity(card.benchmarkLabel == nil ? 0.64 : 0.74))
                        .lineLimit(1)

                    if card.benchmarkLabel != nil {
                        Text(card.isHeld ? "Current portfolio position" : "Watchlist monitor")
                            .font(.caption)
                            .foregroundStyle(Color.white.opacity(0.56))
                            .lineLimit(1)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text(priceDisplay(card.currentPrice))
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    changeBadge(card)
                }
            }

            intradayChart(
                points: card.points,
                lineColor: lineColor(for: card),
                liveState: card.liveState,
                height: 104
            )

            HStack {
                Text(lastUpdatedLine(card))
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.62))
                Spacer()
                Text(card.liveState.statusLine)
                    .font(.caption)
                    .foregroundStyle(Color.white.opacity(0.50))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )
        )
    }

    private func portfolioWatchDetailSheet(card: PortfolioWatchCardPresentation) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(card.symbol)
                        .font(.system(size: 32, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Text(card.benchmarkLabel ?? (card.isHeld ? "Current portfolio position" : "Watchlist monitor"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if card.benchmarkLabel != nil {
                        Text(card.isHeld ? "Current portfolio position" : "Watchlist monitor")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 6) {
                    Text(priceDisplay(card.currentPrice))
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                    changeBadge(card)
                }
            }

            intradayChart(
                points: card.points,
                lineColor: lineColor(for: card),
                liveState: card.liveState,
                height: 240
            )

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    detailStat(title: "Label", value: card.benchmarkLabel ?? "—")
                    detailStat(title: "Scope", value: card.isHeld ? "Portfolio position" : "Watchlist only")
                }
                GridRow {
                    detailStat(title: "Session", value: card.sessionState.displayTitle)
                    detailStat(title: "Updated", value: lastUpdatedLine(card))
                }
                GridRow {
                    detailStat(title: "Chart Points", value: "\(card.pointCount)")
                    detailStat(title: "Live State", value: card.liveState.statusLine)
                }
                GridRow {
                    detailStat(title: "Price Source", value: card.priceSource?.displayTitle ?? "Waiting")
                    detailStat(
                        title: "Coverage",
                        value: coverageLabel(for: card)
                    )
                }
            }

            DisclosureGroup("Live Data Detail") {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                    GridRow {
                        detailStat(
                            title: "Requested",
                            value: card.diagnostics.subscriptionDesired ? "Yes" : "No"
                        )
                        detailStat(
                            title: "Acknowledged",
                            value: card.diagnostics.subscriptionActive ? "Yes" : "No"
                        )
                    }
                    GridRow {
                        detailStat(
                            title: "Last Stream Event",
                            value: lastMarketDataReceiptLine
                        )
                        detailStat(title: "Point Count", value: "\(card.diagnostics.pointCount)")
                    }
                    GridRow {
                        detailStat(
                            title: "Last Quote",
                            value: compactTimestamp(card.diagnostics.lastQuoteAt)
                        )
                        detailStat(
                            title: "Last Trade",
                            value: compactTimestamp(card.diagnostics.lastTradeAt)
                        )
                    }
                    GridRow {
                        detailStat(
                            title: "Last Bar",
                            value: compactTimestamp(card.diagnostics.lastBarAt)
                        )
                        detailStat(
                            title: "Symbol",
                            value: card.diagnostics.symbol
                        )
                    }
                }
                .padding(.top, 8)
            }

            Spacer()
        }
        .padding(24)
        .frame(minWidth: 700, minHeight: 520)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func intradayChart(
        points: [PortfolioWatchIntradayPoint],
        lineColor: Color,
        liveState: PortfolioWatchLiveState,
        height: CGFloat
    ) -> some View {
        let domain = yDomain(for: points)
        return Group {
            if points.count >= 2 {
                Chart(points) { point in
                    AreaMark(
                        x: .value("Time", point.timestamp),
                        yStart: .value("Floor", domain.lowerBound),
                        yEnd: .value("Price", point.price)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [lineColor.opacity(0.22), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    LineMark(
                        x: .value("Time", point.timestamp),
                        y: .value("Price", point.price)
                    )
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(lineColor)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartLegend(.hidden)
                .chartYScale(domain: domain)
                .chartPlotStyle { plot in
                    plot
                        .background(Color.clear)
                }
            } else if points.count == 1, let point = points.first {
                Chart {
                    PointMark(
                        x: .value("Time", point.timestamp),
                        y: .value("Price", point.price)
                    )
                    .symbolSize(80)
                    .foregroundStyle(lineColor)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartLegend(.hidden)
                .chartYScale(domain: domain)
                .chartPlotStyle { plot in
                    plot
                        .background(Color.clear)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Spacer()
                    Text(liveState.statusLine)
                        .font(.footnote)
                        .foregroundStyle(Color.white.opacity(0.62))
                    Spacer()
                }
            }
        }
        .frame(height: height)
        .animation(.easeInOut(duration: 0.18), value: liveState)
    }

    private var connectionTitle: String {
        switch appModel.marketDataConnectionState.lowercased() {
        case MarketDataConnectionState.subscribed.rawValue:
            return "Subscribed"
        case MarketDataConnectionState.authenticated.rawValue:
            return "Authenticated"
        case MarketDataConnectionState.connected.rawValue:
            return "Connected"
        case MarketDataConnectionState.connecting.rawValue:
            return "Connecting"
        default:
            return "Unavailable"
        }
    }

    private var liveCoverageNote: String? {
        portfolioWatchLiveCoverageNote(
            cards: appModel.portfolioWatchChartCards,
            sessionState: currentSessionState,
            connectionActive: marketDataConnectionCanRequestCoverage
        )
    }

    private var marketDataConnectionCanRequestCoverage: Bool {
        switch appModel.marketDataConnectionState.lowercased() {
        case MarketDataConnectionState.authenticated.rawValue,
            MarketDataConnectionState.subscribed.rawValue:
            return true
        default:
            return false
        }
    }

    private var lastMarketDataReceiptLine: String {
        guard let receivedAt = appModel.lastMarketDataReceivedAt else {
            return "No stream data received"
        }
        let symbol = appModel.lastMarketDataReceivedSymbol ?? "unknown"
        return "\(symbol) • \(compactTimestamp(receivedAt))"
    }

    private func coverageLabel(for card: PortfolioWatchCardPresentation) -> String {
        if card.diagnostics.subscriptionActive {
            return "Subscription acknowledged"
        }
        if card.diagnostics.subscriptionDesired {
            return "Requested; awaiting Alpaca ack"
        }
        return "Not requested"
    }

    private var marketDataCoverageSummary: String {
        let cards = appModel.portfolioWatchChartCards
        let requested = cards.filter(\.diagnostics.subscriptionDesired).count
        let acknowledged = cards.filter(\.diagnostics.subscriptionActive).count
        let priced = cards.filter { $0.currentPrice != nil }.count
        if requested == 0 {
            return "No requested names"
        }
        return "Ack \(acknowledged)/\(requested) • Priced \(priced)/\(cards.count)"
    }

    private func addSymbol() {
        let symbol = newSymbol
        let normalized = symbol
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        feedbackMessage = nil

        Task { @MainActor in
            if let message = await appModel.addWatchSymbol(symbol) {
                feedbackMessage = message
            } else {
                newSymbol = ""
                draftedSelection = Set(appModel.effectivePortfolioWatchChartSymbols)
                if !normalized.isEmpty,
                   draftedSelection.count < PortfolioWatchChartWallConfiguration.maximumSelectedSymbols ||
                    draftedSelection.contains(normalized) {
                    draftedSelection.insert(normalized)
                }
            }
        }
    }

    private func selectionRowPriceSummary(symbol: String) -> String {
        let quote = appModel.marketQuote(for: symbol)
        let resolved = resolvePortfolioWatchLiveValue(from: quote)
        return "Price \(priceDisplay(resolved?.price)) • updated \(compactTimestamp(resolved?.observedAt))"
    }

    private func lastUpdatedLine(_ card: PortfolioWatchCardPresentation) -> String {
        switch card.liveState {
        case .waitingForFirstUpdate:
            return "Waiting for first market update"
        case .buildingChart:
            return "Updated \(compactTimestamp(card.lastUpdatedAt)) • building chart"
        case .liveChart:
            return "Updated \(compactTimestamp(card.lastUpdatedAt))"
        }
    }

    private func priceDisplay(_ value: Double?) -> String {
        guard let value else {
            return "—"
        }
        if value >= 100 {
            return String(format: "%.2f", value)
        }
        return String(format: "%.4f", value)
    }

    private func portfolioCurrency(_ value: Double?) -> String? {
        guard let value else {
            return nil
        }
        let sign = value < 0 ? "-" : ""
        let absolute = abs(value)
        if absolute >= 1_000_000 {
            return "\(sign)$\(String(format: "%.2f", absolute / 1_000_000))M"
        }
        if absolute >= 1_000 {
            return "\(sign)$\(String(format: "%.1f", absolute / 1_000))K"
        }
        return "\(sign)$\(String(format: "%.2f", absolute))"
    }

    private func portfolioPrice(_ value: Double?) -> String? {
        guard let value else {
            return nil
        }
        if value >= 100 {
            return "$\(String(format: "%.2f", value))"
        }
        return "$\(String(format: "%.4f", value))"
    }

    private func portfolioPercent(_ value: Double?) -> String? {
        guard let value else {
            return nil
        }
        return "\(String(format: "%.1f", value * 100))%"
    }

    private func portfolioQuantity(_ value: Double?) -> String {
        guard let value else {
            return "—"
        }
        if abs(value.rounded() - value) < 0.0001 {
            return String(format: "%.0f sh", value)
        }
        return String(format: "%.4f sh", value)
    }

    private func changeBadge(_ card: PortfolioWatchCardPresentation) -> some View {
        let color = lineColor(for: card)
        let label: String
        if let value = card.changeValue, let percent = card.changePercent {
            let sign = value > 0 ? "+" : ""
            label = "\(sign)\(String(format: "%.2f", value)) • \(sign)\(String(format: "%.2f", percent))%"
        } else {
            label = card.liveState == .waitingForFirstUpdate ? "Awaiting change" : "Change building"
        }

        return Text(label)
            .font(.callout.weight(.semibold))
            .foregroundStyle(color)
    }

    private func lineColor(for card: PortfolioWatchCardPresentation) -> Color {
        let change = card.changeValue ?? 0
        if change > 0 {
            return Color(red: 0.23, green: 0.85, blue: 0.58)
        }
        if change < 0 {
            return Color(red: 0.97, green: 0.36, blue: 0.34)
        }
        return Color(red: 0.45, green: 0.74, blue: 0.98)
    }

    private func yDomain(for points: [PortfolioWatchIntradayPoint]) -> ClosedRange<Double> {
        guard var minPrice = points.first?.price,
              var maxPrice = points.first?.price else {
            return 0...1
        }
        for point in points.dropFirst() {
            minPrice = min(minPrice, point.price)
            maxPrice = max(maxPrice, point.price)
        }
        if minPrice == maxPrice {
            let padding = max(abs(minPrice) * 0.01, 0.25)
            return (minPrice - padding)...(maxPrice + padding)
        }
        let padding = max((maxPrice - minPrice) * 0.18, 0.05)
        return (minPrice - padding)...(maxPrice + padding)
    }

    private func compactTimestamp(_ date: Date?) -> String {
        guard let date else {
            return "—"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    private func parseISO8601(_ raw: String?) -> Date? {
        guard let raw else {
            return nil
        }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) {
            return date
        }

        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        return basic.date(from: raw)
    }

    private func statusPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.48))
            Text(value)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
    }

    private func summaryTile(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.48))
            Text(value)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
    }

    private func detailStat(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var portfolioWatchPanelBackground: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(Color.white.opacity(0.055))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.09), lineWidth: 1)
            )
    }

    private func isHeldSymbol(_ symbol: String) -> Bool {
        appModel.positions.contains { $0.symbol == symbol }
    }

    private func preferredPrice(from quote: MarketQuote?) -> Double? {
        guard let quote else {
            return nil
        }
        if let last = quote.lastPrice {
            return last
        }
        if let bid = quote.bidPrice, let ask = quote.askPrice {
            return (bid + ask) / 2
        }
        return quote.bidPrice ?? quote.askPrice
    }
}

struct CommandCenterHomeView: View {
    @EnvironmentObject private var appModel: AppModel
    @Binding var selectedTab: MainTab

    private let conversationBottomAnchorID = "owner-pm-conversation-bottom"

    @State private var ownerReplyBody = ""
    @State private var feedbackMessage: String?
    @State private var feedbackIsError = false
    @State private var inFlight = false

    private let attentionColumns = [
        GridItem(.adaptive(minimum: 220), spacing: 12)
    ]

    private var workerLinkStatus: String {
        appModel.ipcStatus.running ? "Connected" : "Unavailable"
    }

    var body: some View {
        let snapshot = appModel.pmCommandCenterSnapshot
        let decisionItems = appModel.ownerDecisionDeskItems
        let backgroundCards = appModel.ownerBackgroundActivityCards
        let recentChanges = appModel.ownerRecentChangePresentations
        let conversation = appModel.ownerPMConversationPresentation
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let feedbackMessage, !feedbackMessage.isEmpty {
                    Text(feedbackMessage)
                        .foregroundStyle(feedbackIsError ? .red : .green)
                        .font(.callout)
                }

                OwnerSurfaceSection(title: "Your Decisions") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Review PM asks here. This area shows active decisions and any just-approved Live order route status that still needs attention.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        if decisionItems.isEmpty {
                            Text("Nothing is waiting for your decision right now.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(decisionItems) { item in
                                ownerDecisionCard(item)
                                if item.id != decisionItems.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                researchSignalsSection(snapshot: snapshot)

                OwnerSurfaceSection(title: "Conversation With PM") {
                    VStack(alignment: .leading, spacing: 12) {
                        if let conversation {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(conversation.participantName)
                                        .font(.headline)
                                    Spacer()
                                    Text(conversation.sessionSummary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                if conversation.visibleMessages.isEmpty {
                                    Text("No PM conversation messages are visible yet. Your next in-app ask will appear here, and PM replies will stay in this thread.")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                } else {
                                    ScrollViewReader { scrollProxy in
                                        ScrollView {
                                            VStack(alignment: .leading, spacing: 8) {
                                                ForEach(conversation.visibleMessages) { message in
                                                    conversationBubble(
                                                        speaker: message.speakerLabel,
                                                        body: message.body,
                                                        emphasized: message.emphasized
                                                    )
                                                    .id(message.messageId)
                                                }
                                                Color.clear
                                                    .frame(height: 1)
                                                    .id(conversationBottomAnchorID)
                                            }
                                        }
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .onAppear {
                                            scrollConversationToLatest(
                                                scrollProxy,
                                                latestMessageID: conversation.visibleMessages.last?.messageId
                                            )
                                        }
                                        .onChange(of: conversation.visibleMessages.last?.messageId) { latestMessageID in
                                            scrollConversationToLatest(
                                                scrollProxy,
                                                latestMessageID: latestMessageID
                                            )
                                        }
                                    }
                                    .frame(minHeight: 320, maxHeight: 520)
                                }

                                if conversation.awaitingPMReply {
                                    Text("Your latest in-app ask is recorded. The PM reply will appear here when it is created.")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }

                                Text("Conversation stays separate from owner decisions. If the PM needs your decision or action, it will appear in Your Decisions.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)

                                VStack(alignment: .leading, spacing: 6) {
                                    Text(conversation.ownerComposerTitle)
                                        .font(.subheadline.weight(.semibold))
                                    Text(conversation.ownerComposerHint)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                    TextEditor(text: $ownerReplyBody)
                                        .font(.system(size: 17))
                                        .frame(minHeight: 220)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(Color.secondary.opacity(0.2))
                                        )
                                    HStack(spacing: 8) {
                                        Button(inFlight ? "Sending..." : "Send To PM") {
                                            submitOwnerConversationMessage(sessionId: conversation.sessionId)
                                        }
                                        .ownerActionButton(prominent: true)
                                        .disabled(inFlight || ownerReplyBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                    }
                                }
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Start A New Ask")
                                        .font(.subheadline.weight(.semibold))
                                    Text("Ask the PM for research, clarification, follow-up work, or a fresh review.")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                    TextEditor(text: $ownerReplyBody)
                                        .font(.system(size: 17))
                                        .frame(minHeight: 220)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(Color.secondary.opacity(0.2))
                                        )
                                    HStack(spacing: 8) {
                                        Button(inFlight ? "Sending..." : "Start Conversation") {
                                            submitOwnerConversationMessage(sessionId: nil)
                                        }
                                        .ownerActionButton(prominent: true)
                                        .disabled(inFlight || ownerReplyBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                CommandCenterStrategyBriefSection(
                    revisionCandidate: appModel.strategyBriefRevisionCandidate
                )

                CommandCenterAnalystChartersSection()

                CommandCenterAgentSkillsLibrarySection()

                CommandCenterAnalystStandingSchedulesSection()

                OwnerSurfaceSection(title: "Background Activity") {
                    LazyVGrid(columns: attentionColumns, alignment: .leading, spacing: 12) {
                        ForEach(backgroundCards) { card in
                            backgroundActivityCard(card)
                        }
                    }
                }

                OwnerSurfaceSection(title: "Portfolio Snapshot") {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                        GridRow {
                            portfolioStat(title: "Current Positions", value: "\(appModel.positions.count)")
                            portfolioStat(title: "Portfolio Watch", value: "\(appModel.watchlistSymbols.count) names")
                        }
                        GridRow {
                            portfolioStat(title: "Signal Reviews", value: "\(snapshot.newSignalsCount)")
                            portfolioStat(title: "FYI Alerts", value: "\(snapshot.fyiSignalsCount)")
                        }
                        GridRow {
                            portfolioStat(title: "Awaiting Proposal Work", value: "\(snapshot.awaitingProposalCount)")
                            portfolioStat(title: "Running Jobs", value: "\(appModel.runningJobSnapshots.count)")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 8) {
                        Button("Open Portfolio Watch") {
                            selectedTab = .marketWatch
                        }
                        .ownerActionButton(prominent: true)
                    }
                    .padding(.top, 8)
                }

                OwnerSurfaceSection(title: "System Status") {
                    VStack(alignment: .leading, spacing: 10) {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                            GridRow {
                                portfolioStat(title: "Trading Posture", value: appModel.liveSafetyStatusLabel)
                                portfolioStat(title: "Kill Switch", value: appModel.killSwitchEnabled ? "On" : "Off")
                            }
                            GridRow {
                                portfolioStat(title: "Connectivity", value: appModel.tradeStreamOwnerFacingLabel)
                                portfolioStat(title: "Market Data", value: appModel.marketDataOwnerFacingLabel)
                            }
                            GridRow {
                                portfolioStat(title: "Worker Link", value: workerLinkStatus)
                                portfolioStat(title: "Running Jobs", value: "\(appModel.runningJobSnapshots.count)")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if let reason = appModel.tradingDisabledReason,
                           !reason.isEmpty {
                            Text(reason)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        Button("Open System Control") {
                            selectedTab = .systemControl
                        }
                        .ownerActionButton()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                OwnerSurfaceSection(title: "Recent Highlights") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(recentChanges) { change in
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(change.title)
                                        .font(.headline)
                                    Text(change.summary)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(change.drillDownLabel) {
                                    openRecentChange(change)
                                }
                                .ownerActionButton()
                            }
                            if change.id != recentChanges.last?.id {
                                Divider()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(18)
        }
    }

    @ViewBuilder
    private func researchSignalsSection(snapshot: PMCommandCenterSnapshot) -> some View {
        let signals = commandCenterResearchSignals
        if signals.isEmpty == false {
            OwnerSurfaceSection(title: "Research Signals") {
                VStack(alignment: .leading, spacing: 12) {
                    Text(researchSignalsIntro(snapshot: snapshot))
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    ForEach(signals.prefix(6)) { signal in
                        researchSignalCard(signal)
                        if signal.id != signals.prefix(6).last?.id {
                            Divider()
                        }
                    }

                    HStack(spacing: 8) {
                        if snapshot.fyiSignalsCount > 0 {
                            Button("Acknowledge FYI Alerts") {
                                acknowledgeFYIResearchSignals()
                            }
                            .ownerActionButton()
                            .disabled(inFlight)
                        }

                        Button("Open Signals") {
                            selectedTab = .signals
                        }
                        .ownerActionButton(prominent: snapshot.newSignalsCount > 0)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var commandCenterResearchSignals: [Signal] {
        appModel.signals
            .filter { $0.status == .new && isSuppressedPMTestingSignal($0) == false }
            .sorted { lhs, rhs in
                if lhs.countsAsOwnerFacingSignalReview != rhs.countsAsOwnerFacingSignalReview {
                    return lhs.countsAsOwnerFacingSignalReview && rhs.countsAsOwnerFacingSignalReview == false
                }
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.signalId < rhs.signalId
                }
                return lhs.updatedAt > rhs.updatedAt
            }
    }

    private func researchSignalsIntro(snapshot: PMCommandCenterSnapshot) -> String {
        let ownerReview = snapshot.newSignalsCount
        let fyi = snapshot.fyiSignalsCount
        if ownerReview > 0 && fyi > 0 {
            return "\(ownerReview) signal\(ownerReview == 1 ? "" : "s") need owner review and \(fyi) FYI alert\(fyi == 1 ? "" : "s") can be acknowledged when read. Signals are research alerts, not trade approvals."
        }
        if ownerReview > 0 {
            return "\(ownerReview) signal\(ownerReview == 1 ? "" : "s") need owner review. Signals are research alerts, not trade approvals."
        }
        return "\(fyi) FYI research alert\(fyi == 1 ? "" : "s") can be acknowledged when read. Notify-only, neutral, or low-confidence signals do not count as owner decisions."
    }

    private func researchSignalCard(_ signal: Signal) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(signal.symbols.isEmpty ? "Research Alert" : signal.symbols.joined(separator: ", "))
                    .font(.headline)
                signalActionabilityBadge(signal.actionability)
                Spacer()
                Text("\(percent(signal.confidence)) confidence")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(signal.positionStatement)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)

            Text(signal.actionability.ownerSummary)
                .font(.caption)
                .foregroundStyle(.secondary)

            if let presentation = signalLineagePresentation(signal) {
                detailLine(title: "Task", body: presentation.taskLabel)
                detailLine(title: "Finding", body: presentation.findingLabel)
                detailLine(title: "Evidence", body: presentation.evidenceLabel)
            } else if let firstEvidence = signal.evidence.first {
                detailLine(title: "Evidence", body: firstEvidence.summary ?? firstEvidence.title)
            }

            HStack(spacing: 8) {
                Button("Acknowledge") {
                    updateResearchSignal(signalID: signal.signalId, archive: false)
                }
                .ownerActionButton(prominent: signal.countsAsOwnerFacingSignalReview)
                .disabled(inFlight)

                Button("Archive") {
                    updateResearchSignal(signalID: signal.signalId, archive: true)
                }
                .ownerActionButton()
                .disabled(inFlight)

                Button("Open Details") {
                    selectedTab = .signals
                }
                .ownerActionButton()
            }
        }
        .padding(.vertical, 4)
    }

    private func updateResearchSignal(signalID: String, archive: Bool) {
        inFlight = true
        feedbackMessage = nil
        Task { @MainActor in
            let error = archive
                ? await appModel.archiveSignal(id: signalID)
                : await appModel.acknowledgeSignal(id: signalID)
            if error == nil {
                _ = await appModel.refreshSignals(status: nil, limit: 200)
                feedbackMessage = archive ? "Archived the research signal." : "Acknowledged the research signal."
                feedbackIsError = false
            } else {
                feedbackMessage = error
                feedbackIsError = true
            }
            inFlight = false
        }
    }

    private func acknowledgeFYIResearchSignals() {
        let signalIDs = commandCenterResearchSignals
            .filter(\.countsAsFYIResearchAlert)
            .map(\.signalId)
        guard signalIDs.isEmpty == false else {
            return
        }

        inFlight = true
        feedbackMessage = nil
        Task { @MainActor in
            var firstError: String?
            for signalID in signalIDs {
                if let error = await appModel.acknowledgeSignal(id: signalID),
                   firstError == nil {
                    firstError = error
                }
            }
            _ = await appModel.refreshSignals(status: nil, limit: 200)
            if let firstError {
                feedbackMessage = firstError
                feedbackIsError = true
            } else {
                feedbackMessage = "Acknowledged \(signalIDs.count) FYI research alert\(signalIDs.count == 1 ? "" : "s")."
                feedbackIsError = false
            }
            inFlight = false
        }
    }

    private func signalLineagePresentation(_ signal: Signal) -> SignalLineageReadablePresentation? {
        makeSignalLineageReadablePresentation(
            signal: signal,
            charters: appModel.analystCharters,
            tasks: appModel.analystTasks,
            findings: appModel.analystFindings,
            evidenceBundles: appModel.analystEvidenceBundles
        )
    }

    private func signalActionabilityBadge(_ actionability: SignalActionability) -> some View {
        Text(actionability.displayTitle)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(signalActionabilityColor(actionability).opacity(0.15))
            .clipShape(Capsule())
    }

    private func signalActionabilityColor(_ actionability: SignalActionability) -> Color {
        switch actionability {
        case .ownerActionable, .proposalCandidate:
            return .orange
        case .pmReview:
            return .blue
        case .monitorOnly, .notifyOnly:
            return .secondary
        case .closed:
            return .green
        }
    }

    private func percent(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }

    private func ownerDecisionCard(_ item: OwnerDecisionDeskItemPresentation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.title)
                    .font(.headline)
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(item.requestTypeTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text(item.closure.title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(recommendationClosureColor(item.closure.status))
                }
            }

            Text(item.ownerAsk)
                .font(.callout.weight(.semibold))

            detailLine(title: "Event Meaning", body: item.coherence.ownerSummary)
            detailLine(title: "Lifecycle", body: item.closure.ownerSummary)

            detailLine(title: "Why Now", body: item.whyNow)

            if let recommendation = item.recommendation,
               !recommendation.isEmpty {
                detailLine(title: "PM Recommendation", body: recommendation)
            }

            if let strategicAlignment = item.strategicAlignment,
               !strategicAlignment.isEmpty {
                detailLine(title: "Strategy Alignment", body: strategicAlignment)
            }

            if let portfolioContextSummary = item.portfolioContextSummary,
               !portfolioContextSummary.isEmpty {
                detailLine(title: "Current Portfolio Context", body: portfolioContextSummary)
            }

            if let trustLabel = item.researchTrustLabel,
               !trustLabel.isEmpty,
               let trustSummary = item.researchTrustSummary,
               !trustSummary.isEmpty {
                detailLine(title: "Research Grounding", body: "\(trustLabel). \(trustSummary)")
            }

            if let sourceConstraintSummary = item.researchTrustSourceConstraintSummary,
               !sourceConstraintSummary.isEmpty {
                detailLine(title: "Source Constraints", body: sourceConstraintSummary)
            }

            if item.researchTrustSummary != nil {
                Text("Detailed research coverage and memo/evidence drill-down stay in PM Inbox.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let evidence = item.supportingEvidence,
               !evidence.isEmpty {
                detailLine(title: "What Supports This", body: evidence)
            }

            if let uncertaintySummary = item.uncertaintySummary,
               !uncertaintySummary.isEmpty {
                detailLine(title: "What Is Still Uncertain", body: uncertaintySummary)
            }

            if let approvedNextStep = item.approvedNextStep,
               !approvedNextStep.isEmpty {
                detailLine(title: "If You Approve", body: approvedNextStep)
            }

            if let declinedNextStep = item.declinedNextStep,
               !declinedNextStep.isEmpty {
                detailLine(title: "If You Decline", body: declinedNextStep)
            }

            if let moreWorkNextStep = item.moreWorkNextStep,
               !moreWorkNextStep.isEmpty {
                detailLine(title: "If You Ask For More Work", body: moreWorkNextStep)
            }

            if let linkedCommunication = item.linkedCommunicationSummary,
               !linkedCommunication.isEmpty {
                detailLine(title: "Latest PM Note", body: linkedCommunication)
            }

            if let routingStatus = item.routingStatusSummary,
               !routingStatus.isEmpty {
                detailLine(title: "Route / Preflight Status", body: routingStatus)
            }

            Text(item.boundaryNote)
                .font(.caption)
                .foregroundStyle(.secondary)

            if item.closure.ownerPending,
               let request = appModel.pmApprovalRequests.first(where: { $0.approvalRequestId == item.approvalRequestId }) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        ownerConversationActionButton("Approve", prominent: true) {
                            applyOwnerDecision(.approved, request: request, successMessage: "Approved the PM request.")
                        }
                        ownerConversationActionButton("Decline", prominent: false) {
                            applyOwnerDecision(.rejected, request: request, successMessage: "Declined the PM request.")
                        }
                        ownerConversationActionButton("Ask For More Work", prominent: false) {
                            applyOwnerDecision(.reviewed, request: request, successMessage: "Asked the PM for more work.")
                        }
                        ownerConversationActionButton("Open Details", prominent: false) {
                            openPMInboxDetails()
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        ownerConversationActionButton("Approve", prominent: true) {
                            applyOwnerDecision(.approved, request: request, successMessage: "Approved the PM request.")
                        }
                        ownerConversationActionButton("Decline", prominent: false) {
                            applyOwnerDecision(.rejected, request: request, successMessage: "Declined the PM request.")
                        }
                        ownerConversationActionButton("Ask For More Work", prominent: false) {
                            applyOwnerDecision(.reviewed, request: request, successMessage: "Asked the PM for more work.")
                        }
                        ownerConversationActionButton("Open Details", prominent: false) {
                            openPMInboxDetails()
                        }
                    }
                }
            } else if let request = appModel.pmApprovalRequests.first(where: { $0.approvalRequestId == item.approvalRequestId }),
                      isClearablePMApprovalRequest(request) {
                ownerConversationActionButton("Clear From Decisions", prominent: false) {
                    acknowledgeOwnerDecision(request: request)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    private func isClearablePMApprovalRequest(_ request: PMApprovalRequest) -> Bool {
        isPMApprovalRequestClearableFromActiveDecisions(request)
    }

    private func acknowledgeOwnerDecision(request: PMApprovalRequest) {
        inFlight = true
        feedbackMessage = nil
        Task { @MainActor in
            defer { inFlight = false }
            let error = await appModel.acknowledgePMApprovalRequest(
                requestID: request.approvalRequestId
            )
            feedbackMessage = error ?? "Cleared the completed review from active decisions."
            feedbackIsError = error != nil
        }
    }

    private func pmSurfaceCoordinationView(
        _ presentation: OwnerPMSurfaceCoordinationPresentation
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            detailLine(title: "Command Center", body: presentation.commandCenterSummary)
            detailLine(title: "Telegram", body: presentation.telegramSummary)
            detailLine(title: "PM Inbox", body: presentation.pmInboxSummary)
            detailLine(title: "PM Runtime", body: presentation.runtimeSummary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.05))
        )
    }

    private func backgroundActivityCard(_ card: OwnerBackgroundActivityPresentation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(card.title)
                    .font(.headline)
                Spacer()
                Text("\(card.count)")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(backgroundColor(card.kind))
            }

            Text(card.summary)
                .font(.callout.weight(.semibold))

            Text(card.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button(card.drillDownLabel) {
                switch card.kind {
                case .systemExceptions:
                    selectedTab = .systemControl
                case .pmReviewing, .analystActivity:
                    openPMInboxDetails()
                }
            }
            .ownerActionButton()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    private func portfolioStat(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detailLine(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(body)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func conversationBubble(
        speaker: String,
        body: String,
        emphasized: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(speaker)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(body)
                .font(.callout.weight(emphasized ? .semibold : .regular))
                .foregroundStyle(.primary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(emphasized ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.06))
        )
    }

    private func scrollConversationToLatest(
        _ proxy: ScrollViewProxy,
        latestMessageID: String?
    ) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(conversationBottomAnchorID, anchor: .bottom)
                if let latestMessageID {
                    proxy.scrollTo(latestMessageID, anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func ownerConversationActionButton(
        _ title: String,
        prominent: Bool,
        action: @escaping () -> Void
    ) -> some View {
        if prominent {
            Button(title, action: action)
                .ownerActionButton(prominent: true)
                .disabled(inFlight)
        } else {
            Button(title, action: action)
                .ownerActionButton()
                .disabled(inFlight)
        }
    }

    private func backgroundColor(_ kind: OwnerBackgroundActivityKind) -> Color {
        switch kind {
        case .pmReviewing:
            return .blue
        case .analystActivity:
            return .green
        case .systemExceptions:
            return .red
        }
    }

    private func applyOwnerDecision(
        _ response: PMApprovalRequestOwnerResponse,
        request: PMApprovalRequest,
        successMessage: String
    ) {
        inFlight = true
        feedbackMessage = nil
        Task { @MainActor in
            defer { inFlight = false }
            let error = await appModel.respondToPMApprovalRequest(
                requestID: request.approvalRequestId,
                response: response
            )
            feedbackMessage = error ?? successMessage
            feedbackIsError = error != nil
        }
    }

    private func submitOwnerConversationMessage(sessionId: String?) {
        let message = ownerReplyBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard message.isEmpty == false else {
            return
        }
        inFlight = true
        feedbackMessage = nil
        Task { @MainActor in
            defer { inFlight = false }
            let error = await appModel.sendOwnerConversationMessage(
                body: message,
                sessionId: sessionId
            )
            if let error {
                feedbackMessage = error
                feedbackIsError = true
            } else {
                ownerReplyBody = ""
                feedbackMessage = "Sent your message to the PM."
                feedbackIsError = false
            }
        }
    }

    private func openPMInboxDetails() {
        selectedTab = .pmInbox
    }

    private func openRecentChange(_ change: OwnerRecentChangePresentation) {
        switch change.title {
        case "Signals":
            selectedTab = .signals
        case "Proposals":
            selectedTab = .proposals
        default:
            selectedTab = .pmInbox
        }
    }
}

private func recommendationClosureColor(_ status: PMRecommendationClosureStatus) -> Color {
    switch status {
    case .awaitingOwner:
        return .orange
    case .backgroundPMReview:
        return .indigo
    case .moreWorkRequested:
        return .yellow
    case .superseded, .closedNoFurtherAction:
        return .secondary
    case .routedOrInProgress:
        return .blue
    case .completed:
        return .green
    case .declined, .blockedOrFailed:
        return .red
    }
}

private func pmInboxApprovalStatusLabel(
    request: PMApprovalRequest,
    closure: PMRecommendationClosurePresentation
) -> String {
    closure.status == .backgroundPMReview ? "Under PM Review" : pmApprovalRequestStatusDisplayTitle(request.status)
}

private func pmInboxRequestedActionSectionTitle(
    closure: PMRecommendationClosurePresentation
) -> String {
    closure.status == .backgroundPMReview ? "PM Review Scope" : "Owner Ask"
}

private func pmInboxOwnerMeaningSectionTitle(
    closure: PMRecommendationClosurePresentation
) -> String {
    closure.status == .backgroundPMReview ? "What This PM Review Means" : "What Your Review Means"
}

private enum OldJobTelemetryCleanupCutoffPreset: String, CaseIterable, Identifiable {
    case fourteenDays = "14 days"
    case thirtyDays = "30 days"
    case sixtyDays = "60 days"
    case ninetyDays = "90 days"
    case custom = "Custom date"

    var id: String { rawValue }

    var dayOffset: Int? {
        switch self {
        case .fourteenDays:
            return -14
        case .thirtyDays:
            return -30
        case .sixtyDays:
            return -60
        case .ninetyDays:
            return -90
        case .custom:
            return nil
        }
    }
}

struct SystemControlView: View {
    @EnvironmentObject private var appModel: AppModel
    @Binding var selectedTab: MainTab

    @State private var liveArmingConfirmed = false
    @State private var safetyActionInFlight = false
    @State private var selectedScheduleID: String?
    @State private var scheduleEditorID: String?
    @State private var scheduleEditorJobType: JobType = .rssPoll
    @State private var scheduleEditorEnabled = true
    @State private var scheduleEditorIntervalValue = "5"
    @State private var scheduleEditorIntervalUnit: ScheduleIntervalEditorUnit = .minutes
    @State private var scheduleEditorAlwaysOn = false
    @State private var scheduleEditorRestartOnLaunch = true
    @State private var scheduleEditorAllowOverlap = false
    @State private var scheduleEditorStartupBehavior: PeriodicScheduleStartupBehavior = .waitForInterval
    @State private var scheduleEditorMaxRuntimeSec = ""
    @State private var scheduleEditorParamsJSON = "{}"
    @State private var retentionAuditRotateMB = 25
    @State private var retentionAuditKeepDays = 30
    @State private var retentionNewsKeepDays = 30
    @State private var retentionJobsKeepDays = 14
    @State private var retentionJobsMaxCount = 500
    @State private var retentionRunsEnabled = false
    @State private var retentionRunsKeepDays = 180
    @State private var retentionBarsEnabled = false
    @State private var retentionBarsMaxDBMB = ""
    @State private var maintenanceScheduleEnabled = true
    @State private var maintenanceScheduleIntervalValue = "24"
    @State private var maintenanceScheduleIntervalUnit: ScheduleIntervalEditorUnit = .hours
    @State private var oldJobCleanupCutoffPreset: OldJobTelemetryCleanupCutoffPreset = .thirtyDays
    @State private var oldJobCleanupCustomCutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60)
    @State private var showOldJobCleanupApplyConfirmation = false
    @State private var showFullMaintenanceApplyConfirmation = false
    @State private var showAdvancedRetentionSettings = false
    @State private var fullRetentionPreviewCompleted = false
    @State private var feedbackMessage: String?
    @State private var feedbackIsError = false
    @State private var inFlight = false
    @State private var showStrategyControls = false

    private var workerLinkStatus: String {
        appModel.workerLinkStatus
    }

    private var ownerSystemExceptionCategories: [OwnerSystemExceptionCategoryPresentation] {
        appModel.ownerSystemExceptionCategories
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                OwnerSurfaceSection(
                    title: "System Control",
                    subtitle: "Use this area for safety posture, feed operations, storage cleanup, and deeper operator controls. Raw workflow queues stay in the Advanced Tabs."
                ) {
                    EmptyView()
                }

                if let feedbackMessage, !feedbackMessage.isEmpty {
                    Text(feedbackMessage)
                        .foregroundStyle(feedbackIsError ? .red : .green)
                        .font(.callout)
                }

                maintenancePanel
                safetyPanel
                systemExceptionsPanel
                systemHealthPanel
                SystemControlRSSFeedsSection()

                VStack(alignment: .leading, spacing: 10) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            showStrategyControls.toggle()
                        }
                    } label: {
                        HStack {
                            Text("Advanced Strategy Controls And Audit")
                                .font(.headline)
                            Spacer()
                            Image(systemName: showStrategyControls ? "chevron.up" : "chevron.down")
                                .font(.callout.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .ownerActionButton(prominent: true)

                    if showStrategyControls {
                        VStack(alignment: .leading, spacing: 18) {
                            operationalSchedulesPanel
                            AlgoControlCenterView()
                        }
                    }
                }
            }
            .padding(18)
        }
        .onAppear {
            Task { @MainActor in
                _ = await appModel.refreshSchedules()
                _ = await appModel.refreshJobs()
                _ = await appModel.refreshRetentionPolicy()
                _ = await appModel.refreshStorageFootprint()
                loadRetentionEditor(from: appModel.retentionPolicy)
                loadMaintenanceScheduleEditor(from: maintenanceScheduleSummary)
            }
        }
        .onChange(of: appModel.schedules) { schedules in
            if let selectedScheduleID,
               operationalSchedules.contains(where: { $0.scheduleId == selectedScheduleID }) == false {
                resetScheduleEditorForCreate()
            }
            loadMaintenanceScheduleEditor(from: schedules.first(where: { $0.jobType == .maintenanceRetention }))
        }
        .onChange(of: selectedScheduleID) { newValue in
            guard let newValue else {
                if scheduleEditorID != nil {
                    resetScheduleEditorForCreate()
                }
                return
            }
            guard let selected = operationalSchedules.first(where: { $0.scheduleId == newValue }) else {
                return
            }
            loadScheduleEditor(from: selected)
        }
        .onChange(of: appModel.retentionPolicy) { updatedPolicy in
            loadRetentionEditor(from: updatedPolicy)
        }
        .onChange(of: appModel.selectedEnvironment) { newValue in
            if newValue != .live {
                liveArmingConfirmed = false
            }
        }
        .onChange(of: appModel.isArmedForLiveTrading) { isArmed in
            if !isArmed {
                liveArmingConfirmed = false
            }
        }
    }

    private var selectedScheduleSummary: ScheduledJobSummary? {
        guard let selectedScheduleID else {
            return nil
        }
        return operationalSchedules.first(where: { $0.scheduleId == selectedScheduleID })
    }

    private var operationalSchedules: [ScheduledJobSummary] {
        AutomationScheduleSections.operationalSchedules(from: appModel.schedules)
    }

    private var maintenanceScheduleSummary: ScheduledJobSummary? {
        AutomationScheduleSections.maintenanceScheduleSummary(from: appModel.schedules)
    }

    private var safetyPanel: some View {
        OwnerSurfaceSection(title: "Safety") {
            VStack(alignment: .leading, spacing: 12) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                    GridRow {
                        systemStat(title: "Environment", value: appModel.selectedEnvironmentName)
                        systemStat(title: "Trading Posture", value: appModel.liveSafetyStatusLabel)
                    }
                    GridRow {
                        systemStat(title: "Trading Disabled Reason", value: appModel.tradingDisabledReason ?? "None")
                        systemStat(title: "Worker Link", value: workerLinkStatus)
                    }
                    GridRow {
                        systemStat(title: "Live Auth Gate", value: appModel.liveExecutionProtectionStatusLabel)
                        systemStat(title: "Cancel Path", value: "Always Allowed")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(appModel.liveExecutionProtectionDetailText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Toggle(
                    "Kill Switch",
                    isOn: Binding(
                        get: { appModel.killSwitchEnabled },
                        set: { enabled in
                            Task { @MainActor in
                                await appModel.setKillSwitchEnabled(enabled)
                            }
                        }
                    )
                )
                .ownerToggleTint(isOn: appModel.killSwitchEnabled)
                .frame(maxWidth: 220, alignment: .leading)

                if appModel.selectedEnvironment == .live {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Live execution remains fully safety-governed. Arming and kill-switch controls live here rather than in Settings.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Toggle("I understand this is LIVE trading", isOn: $liveArmingConfirmed)
                            .frame(maxWidth: 260, alignment: .leading)

                        HStack(spacing: 10) {
                            Button("Arm Live Trading") {
                                armLiveTrading()
                            }
                            .ownerActionButton(prominent: true)
                            .disabled(
                                safetyActionInFlight ||
                                appModel.isArmedForLiveTrading ||
                                !liveArmingConfirmed
                            )

                            Button("Disarm Live Trading") {
                                disarmLiveTrading()
                            }
                            .ownerActionButton()
                            .disabled(safetyActionInFlight || !appModel.isArmedForLiveTrading)

                            if safetyActionInFlight {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }

                        Text("Arming session: \(appModel.shortArmingSessionID)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Switch to Live in Settings when you intentionally want to review live arming posture here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Text("This does not approve trades or arm live execution. Human approval and the existing live-safety controls remain unchanged.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var systemExceptionsPanel: some View {
        let categories = Array(ownerSystemExceptionCategories)

        return OwnerSurfaceSection(title: "System Exceptions") {
            VStack(alignment: .leading, spacing: 12) {
                Text("When Command Center flags system issues, start here. This view groups feed health, worker or launch trouble, and any remaining system follow-up without dumping raw logs by default.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if let category = categories.first {
                    systemExceptionCategoryRow(category)
                }
                if categories.count > 1 {
                    Divider()
                    systemExceptionCategoryRow(categories[1])
                }
                if categories.count > 2 {
                    Divider()
                    systemExceptionCategoryRow(categories[2])
                }

                HStack(spacing: 8) {
                    Button("Open Jobs") {
                        selectedTab = .jobs
                    }
                    .ownerActionButton()

                    Button("Open Logs / Audit") {
                        selectedTab = .logs
                    }
                    .ownerActionButton()
                }

                if let feedbackMessage, feedbackMessage.isEmpty == false {
                    Text(feedbackMessage)
                        .font(.footnote)
                        .foregroundStyle(feedbackIsError ? .red : .green)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var systemHealthPanel: some View {
        let metrics = appModel.systemHealthMetrics
        return OwnerSurfaceSection(title: "System Health") {
            VStack(alignment: .leading, spacing: 12) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                    GridRow {
                        systemStat(metrics, 0)
                        systemStat(metrics, 1)
                    }
                    GridRow {
                        systemStat(metrics, 2)
                        systemStat(metrics, 3)
                    }
                    GridRow {
                        systemStat(metrics, 4)
                        systemStat(metrics, 5)
                    }
                    GridRow {
                        systemStat(metrics, 6)
                        systemStat(metrics, 7)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 6) {
                    if appModel.selectedEnvironment == .live {
                        Text(appModel.liveSafetyStatusDetail)
                            .font(.footnote)
                            .foregroundStyle(appModel.liveSafetyStatusColor)
                    }
                    Text(appModel.alwaysOnReadinessDetail)
                        .font(.footnote)
                        .foregroundStyle(appModel.alwaysOnReadinessStatusColor)
                    Text(AlwaysOnReadinessState.hostAvailabilityContract)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Button("Open PM Inbox") {
                        selectedTab = .pmInbox
                    }
                    .ownerActionButton()

                    Button("Open Jobs") {
                        selectedTab = .jobs
                    }
                    .ownerActionButton()

                    Button("Open Logs / Audit") {
                        selectedTab = .logs
                    }
                    .ownerActionButton()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var operationalSchedulesPanel: some View {
        OwnerSurfaceSection(
            title: "Automation",
            subtitle: "Automation stays in the advanced operator area so polling, analyst cadence, and housekeeping controls remain available without dominating the owner-facing system page."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Text("Editing Saved Schedule")
                        .font(.callout.weight(.semibold))
                    Picker(
                        "Editing Saved Schedule",
                        selection: Binding(
                            get: { selectedScheduleID },
                            set: { selectedScheduleID = $0 }
                        )
                    ) {
                        Text("New (unsaved)").tag(String?.none)
                        ForEach(operationalSchedules, id: \.scheduleId) { schedule in
                            Text("\(schedule.jobType.rawValue) • \(shortID(schedule.scheduleId))")
                                .tag(String?.some(schedule.scheduleId))
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 360, alignment: .leading)
                    Spacer()
                }

                if let selected = selectedScheduleSummary {
                    HStack {
                        Text("Schedule \(shortID(selected.scheduleId))")
                            .font(.title3.weight(.semibold))
                        Spacer()
                        Toggle(
                            "Enabled",
                            isOn: Binding(
                                get: { selected.enabled },
                                set: { newValue in
                                    Task { @MainActor in
                                        feedbackMessage = await appModel.setScheduleEnabled(
                                            id: selected.scheduleId,
                                            enabled: newValue
                                        )
                                        feedbackIsError = feedbackMessage != nil
                                    }
                                }
                            )
                        )
                        .ownerToggleTint(isOn: selected.enabled)
                        .frame(width: 140)
                    }
                } else {
                    Text("Create Schedule")
                        .font(.title3.weight(.semibold))
                }

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("Job Type")
                        Picker("Job Type", selection: $scheduleEditorJobType) {
                            ForEach(JobType.operationalScheduleControllableCases, id: \.self) { type in
                                Text(type.rawValue).tag(type)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: 220, alignment: .leading)
                    }

                    GridRow {
                        Text("Interval")
                        HStack(spacing: 8) {
                            TextField("Value", text: $scheduleEditorIntervalValue)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 90)
                            Picker("Unit", selection: $scheduleEditorIntervalUnit) {
                                ForEach(ScheduleIntervalEditorUnit.allCases) { unit in
                                    Text(unit.rawValue).tag(unit)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(maxWidth: 120, alignment: .leading)
                            Text(scheduleIntervalSummaryText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: 320, alignment: .leading)
                    }

                    GridRow {
                        Text("Run Mode")
                        Picker("Run Mode", selection: $scheduleEditorAlwaysOn) {
                            Text("periodic").tag(false)
                            Text("always_on").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 220, alignment: .leading)
                    }

                    if !scheduleEditorAlwaysOn {
                        GridRow {
                            Text("Startup")
                            Picker("Startup", selection: $scheduleEditorStartupBehavior) {
                                Text("Wait For Interval").tag(PeriodicScheduleStartupBehavior.waitForInterval)
                                Text("Run Immediately").tag(PeriodicScheduleStartupBehavior.runImmediately)
                            }
                            .pickerStyle(.menu)
                            .frame(maxWidth: 220, alignment: .leading)
                        }
                    }

                    GridRow {
                        Text("Restart On Launch")
                        Toggle("Enabled", isOn: $scheduleEditorRestartOnLaunch)
                            .ownerToggleTint(isOn: scheduleEditorRestartOnLaunch)
                    }

                    GridRow {
                        Text("Allow Overlap")
                        Toggle("Enabled", isOn: $scheduleEditorAllowOverlap)
                            .ownerToggleTint(isOn: scheduleEditorAllowOverlap)
                    }

                    GridRow {
                        Text("Max Runtime (sec)")
                        TextField("Optional", text: $scheduleEditorMaxRuntimeSec)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 200, alignment: .leading)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Params JSON")
                        .font(.callout.weight(.semibold))
                    TextEditor(text: $scheduleEditorParamsJSON)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 120)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        )
                }

                if let selected = selectedScheduleSummary {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        GridRow { Text("Running Job"); Text(selected.runningJobId.map(shortID) ?? "-") }
                        GridRow { Text("Last Run"); Text(selected.lastRunAt.map(displayDate) ?? "-") }
                        GridRow { Text("Last Status"); Text(scheduleLastRunStatusLabel(selected)) }
                        GridRow { Text("Last Summary"); Text(selected.lastRunSummary ?? "-") }
                        GridRow { Text("Next Run"); Text(selected.nextRunAt.map(displayDate) ?? "-") }
                        GridRow { Text("Last Error"); Text(scheduleDisplayError(selected) ?? "-") }
                    }
                }

                HStack(spacing: 8) {
                    Button("Save Schedule") {
                        saveSchedule()
                    }
                    .ownerActionButton(prominent: true)
                    .disabled(inFlight)

                    if let selected = selectedScheduleSummary {
                        Button("Run Now") {
                            runScheduleNow(id: selected.scheduleId)
                        }
                        .ownerActionButton()
                        .disabled(inFlight)

                        Button("Remove", role: .destructive) {
                            removeSchedule(id: selected.scheduleId)
                        }
                        .ownerActionButton()
                        .disabled(inFlight)
                    }

                    Button("New Schedule") {
                        resetScheduleEditorForCreate()
                    }
                    .ownerActionButton()
                    .disabled(inFlight)
                }

                if inFlight {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var maintenancePanel: some View {
        let schedule = maintenanceScheduleSummary
        let storageCategories = makePlainEnglishStorageCategoryPresentations(appModel.storageFootprint)

        return OwnerSurfaceSection(
            title: "Storage & Cleanup",
            subtitle: "Preview cleanup before anything is deleted. Active jobs, schedules, and linked PM or analyst records stay protected by the app-owned maintenance path."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                storageCleanupSummary
                Divider()
                volatileCacheTrimCard
                Divider()
                oldJobTelemetryCleanupCard
                Divider()
                cleanupCategoriesList(storageCategories)
                Divider()
                DisclosureGroup(isExpanded: $showAdvancedRetentionSettings) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("These settings control the existing retention policy and maintenance schedule. Keep them here for operator access, but use previews before any apply action.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        maintenanceScheduleSettings(schedule: schedule)
                        retentionPolicySettingsGrid
                        advancedRetentionActions
                        rawStorageBuckets
                        lastMaintenanceDetailGrid
                    }
                    .padding(.top, 6)
                } label: {
                    Text("Advanced Retention Settings")
                        .font(.headline)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog(
            "Delete eligible old job records?",
            isPresented: $showOldJobCleanupApplyConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Eligible Job Records", role: .destructive) {
                runOldJobCleanup(dryRun: false)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(oldJobCleanupConfirmationText)
        }
        .confirmationDialog(
            "Run full retention cleanup?",
            isPresented: $showFullMaintenanceApplyConfirmation,
            titleVisibility: .visible
        ) {
            Button("Run Full Retention Cleanup", role: .destructive) {
                runMaintenanceNow(dryRun: false)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This applies the saved retention policy through the app-owned maintenance job. It can delete eligible retained artifacts and should only be used after reviewing a full retention preview.")
        }
    }

    private var volatileCacheTrimCard: some View {
        let posture = appModel.memoryPostureDiagnostics
        let latestFootprint = posture.latestSample?.physicalFootprintBytes
            .map { byteString(Int64(clamping: $0)) } ?? "Not sampled yet"
        let peakFootprint = posture.peakPhysicalFootprintBytes
            .map { byteString(Int64(clamping: $0)) } ?? "Not sampled yet"
        let nextCheck = posture.nextScheduledSampleAt.map(displayDate) ?? "Not scheduled"
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Memory Relief")
                    .font(.headline)
                Text("Releases derived UI caches and asks the allocator to return free pages when available. Durable Store truth, PM history, jobs, reports, orders, and account data are not deleted.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Label(posture.currentBand.rawValue, systemImage: "memorychip")
                Text("Latest \(latestFootprint)")
                Text("Peak \(peakFootprint)")
                Text("Next check \(nextCheck)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("Run Memory Relief") {
                    feedbackMessage = appModel.performMemoryRelief(
                        reason: "system_control_manual",
                        mode: .systemControlManual,
                        forced: true,
                        dryRun: false
                    ).summary
                    feedbackIsError = false
                }
                .ownerActionButton()
                .disabled(inFlight)

                Text("Safe to use after long sessions if scrolling feels heavy; charts rebuild from current app truth and fresh live data.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var storageCleanupSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Storage & Cleanup Summary")
                        .font(.headline)
                    Text("Preview cleanup before anything is deleted. The app protects active jobs, schedules, and linked PM/analyst records.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(byteString(appModel.storageFootprint.totalBytes))
                        .font(.title3.weight(.semibold))
                    Text("App-managed storage")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                Text("Last refreshed: \(displayDate(appModel.storageFootprint.capturedAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Refresh Storage") {
                    Task { @MainActor in
                        feedbackMessage = await appModel.refreshStorageFootprint()
                        feedbackIsError = feedbackMessage != nil
                    }
                }
                .ownerActionButton()
                .disabled(inFlight)
            }

            Text("Last cleanup result: \(appModel.lastMaintenanceSummary)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var oldJobTelemetryCleanupCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Old Job Telemetry")
                    .font(.headline)
                Text("Background job records from prior automation, analyst runs, RSS polls, and maintenance. Old completed records can be removed after preview; active jobs and linked workflow records are protected.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Before")
                    Picker("Old Job Cleanup Cutoff", selection: $oldJobCleanupCutoffPreset) {
                        ForEach(OldJobTelemetryCleanupCutoffPreset.allCases) { preset in
                            Text(preset.rawValue).tag(preset)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 220, alignment: .leading)
                }

                if oldJobCleanupCutoffPreset == .custom {
                    GridRow {
                        Text("Custom Date")
                        DatePicker(
                            "Custom Date",
                            selection: $oldJobCleanupCustomCutoff,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                        .labelsHidden()
                        .frame(maxWidth: 260, alignment: .leading)
                    }
                }

                GridRow {
                    Text("Cutoff Used")
                    Text(iso8601String(selectedOldJobCleanupCutoff))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                Button("Preview Old Job Cleanup") {
                    runOldJobCleanup(dryRun: true)
                }
                .ownerActionButton(prominent: true)
                .disabled(inFlight)

                Button("Delete Eligible Old Jobs", role: .destructive) {
                    showOldJobCleanupApplyConfirmation = true
                }
                .ownerActionButton()
                .disabled(inFlight || oldJobCleanupCanApply == false)
            }

            if let cleanup = appModel.lastOldJobTelemetryCleanup {
                oldJobTelemetryCleanupResult(cleanup)
            } else {
                Text("Run a preview to see scanned jobs, eligible old jobs, protected jobs, estimated space, and breakdowns. No files are deleted by preview.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func oldJobTelemetryCleanupResult(
        _ cleanup: OldJobTelemetryCleanupPresentation
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(cleanup.modeLabel) result • \(cleanup.deletionStateNote)")
                .font(.callout.weight(.semibold))

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow { Text("Cutoff"); Text(cleanup.cutoffText) }
                GridRow { Text("Scanned Jobs"); Text("\(cleanup.scannedCount)") }
                GridRow { Text(cleanup.dryRun ? "Eligible Jobs" : "Applied Jobs"); Text("\(cleanup.dryRun ? cleanup.eligibleCount : cleanup.appliedCount)") }
                GridRow { Text("Protected / Skipped"); Text("\(cleanup.protectedCount)") }
                GridRow { Text(cleanup.dryRun ? "Estimated Space" : "Applied Space"); Text(byteString(cleanup.dryRun ? cleanup.estimatedBytesReclaimable : cleanup.appliedBytes)) }
                GridRow { Text("Decode Errors"); Text("\(cleanup.skippedDecodeErrorCount)") }
                GridRow { Text("Linked / Protected"); Text("\(cleanup.skippedLinkedProtectedCount)") }
                if let oldest = cleanup.oldestCandidateTimestamp {
                    GridRow { Text("Oldest Candidate"); Text(oldest) }
                }
                if let newest = cleanup.newestCandidateTimestamp {
                    GridRow { Text("Newest Candidate"); Text(newest) }
                }
            }

            cleanupBreakdownList(title: "Status Breakdown", items: cleanup.candidateCountByStatus)
            cleanupBreakdownList(title: "Type Breakdown", items: cleanup.candidateCountByType)

            if cleanup.safetyExclusions.isEmpty == false {
                DisclosureGroup("Safety exclusions applied") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(cleanup.safetyExclusions, id: \.self) { exclusion in
                            Text(exclusion)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cleanupBreakdownList(
        title: String,
        items: [OldJobTelemetryCleanupBreakdownItem]
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if items.isEmpty {
                Text("None")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items.prefix(6)) { item in
                    HStack {
                        Text(item.label.replacingOccurrences(of: "_", with: " "))
                            .font(.caption)
                        Spacer()
                        Text("\(item.count)")
                            .font(.caption.weight(.semibold))
                    }
                }
            }
        }
    }

    private func cleanupCategoriesList(
        _ storageCategories: [PlainEnglishStorageCategoryPresentation]
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cleanup Categories")
                .font(.headline)
            ForEach(storageCategories) { category in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(category.title)
                            .font(.callout.weight(.semibold))
                        Spacer()
                        Text(byteString(category.bytes))
                            .font(.callout.weight(.semibold))
                    }
                    Text(category.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if category.id != storageCategories.last?.id {
                    Divider()
                }
            }
        }
    }

    private func maintenanceScheduleSettings(
        schedule: ScheduledJobSummary?
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Maintenance Schedule")
                .font(.callout.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow { Text("Schedule"); Text(schedule.map { shortID($0.scheduleId) } ?? AutomationScheduleSections.defaultMaintenanceScheduleID) }
                GridRow { Text("Enabled"); Text(schedule.map { $0.enabled ? "Yes" : "No" } ?? (maintenanceScheduleEnabled ? "Yes" : "No")) }
                GridRow { Text("Next Run"); Text(schedule?.nextRunAt.map(displayDate) ?? "-") }
                GridRow { Text("Last Run"); Text(schedule?.lastRunAt.map(displayDate) ?? "-") }
                GridRow { Text("Last Status"); Text(schedule.map(scheduleLastRunStatusLabel) ?? "-") }
                GridRow { Text("Last Summary"); Text(schedule?.lastRunSummary ?? "-") }
            }

            HStack(spacing: 12) {
                Toggle("Schedule Enabled", isOn: $maintenanceScheduleEnabled)
                    .ownerToggleTint(isOn: maintenanceScheduleEnabled)
                    .frame(width: 170, alignment: .leading)

                TextField("Value", text: $maintenanceScheduleIntervalValue)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)

                Picker("Unit", selection: $maintenanceScheduleIntervalUnit) {
                    ForEach(ScheduleIntervalEditorUnit.allCases) { unit in
                        Text(unit.rawValue).tag(unit)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 120, alignment: .leading)

                Text(maintenanceIntervalSummaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button(schedule == nil ? "Create Maintenance Schedule" : "Save Maintenance Schedule") {
                    saveMaintenanceSchedule()
                }
                .ownerActionButton(prominent: true)
                .disabled(inFlight)

                if let schedule {
                    Button("Run Scheduled Maintenance Now") {
                        runScheduleNow(id: schedule.scheduleId)
                    }
                    .ownerActionButton()
                    .disabled(inFlight)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var retentionPolicySettingsGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                Text("Activity History Rotation MB")
                Stepper(value: $retentionAuditRotateMB, in: 1...2_000, step: 1) {
                    Text("\(retentionAuditRotateMB)")
                }
                .frame(maxWidth: 220, alignment: .leading)
            }
            GridRow {
                Text("Activity History Keep Days")
                Stepper(value: $retentionAuditKeepDays, in: 1...3_650, step: 1) {
                    Text("\(retentionAuditKeepDays)")
                }
                .frame(maxWidth: 220, alignment: .leading)
            }
            GridRow {
                Text("News Archive Keep Days")
                Stepper(value: $retentionNewsKeepDays, in: 1...3_650, step: 1) {
                    Text("\(retentionNewsKeepDays)")
                }
                .frame(maxWidth: 220, alignment: .leading)
            }
            GridRow {
                Text("Job History Keep Days")
                Stepper(value: $retentionJobsKeepDays, in: 1...365, step: 1) {
                    Text("\(retentionJobsKeepDays)")
                }
                .frame(maxWidth: 220, alignment: .leading)
            }
            GridRow {
                Text("Job History Max Completed")
                Stepper(value: $retentionJobsMaxCount, in: 1...10_000, step: 1) {
                    Text("\(retentionJobsMaxCount)")
                }
                .frame(maxWidth: 220, alignment: .leading)
            }
            GridRow {
                Text("Run History Retention")
                Toggle("Enabled", isOn: $retentionRunsEnabled)
                    .ownerToggleTint(isOn: retentionRunsEnabled)
            }
            if retentionRunsEnabled {
                GridRow {
                    Text("Run History Keep Days")
                    Stepper(value: $retentionRunsKeepDays, in: 1...10_000, step: 1) {
                        Text("\(retentionRunsKeepDays)")
                    }
                    .frame(maxWidth: 220, alignment: .leading)
                }
            }
            GridRow {
                Text("Market Data Cache Retention")
                Toggle("Enabled", isOn: $retentionBarsEnabled)
                    .ownerToggleTint(isOn: retentionBarsEnabled)
            }
            if retentionBarsEnabled {
                GridRow {
                    Text("Market Data Cache Max DB MB")
                    TextField("Optional", text: $retentionBarsMaxDBMB)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220, alignment: .leading)
                }
            }
        }
    }

    private var advancedRetentionActions: some View {
        HStack(spacing: 8) {
            Button("Save Retention Policy") {
                saveRetentionPolicy()
            }
            .ownerActionButton(prominent: true)
            .disabled(inFlight)

            Button("Run Full Retention Preview") {
                runMaintenanceNow(dryRun: true)
            }
            .ownerActionButton()
            .disabled(inFlight)

            Button("Run Full Retention Cleanup", role: .destructive) {
                showFullMaintenanceApplyConfirmation = true
            }
            .ownerActionButton()
            .disabled(inFlight || fullRetentionPreviewCompleted == false)
        }
    }

    private var rawStorageBuckets: some View {
        DisclosureGroup("Raw Storage Buckets") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow { Text("Audit Size"); Text(byteString(appModel.storageFootprint.auditBytes)) }
                GridRow { Text("News Size"); Text(byteString(appModel.storageFootprint.newsBytes)) }
                GridRow { Text("Jobs Size"); Text(byteString(appModel.storageFootprint.jobsBytes)) }
                GridRow { Text("Runs Size"); Text(byteString(appModel.storageFootprint.runsBytes)) }
                GridRow { Text("Bars Cache Size"); Text(byteString(appModel.storageFootprint.barsCacheBytes)) }
            }
            .padding(.top, 6)
        }
    }

    private var lastMaintenanceDetailGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow { Text("Last Maintenance Job"); Text(appModel.lastMaintenanceJob.map { shortID($0.jobId) } ?? "-") }
            GridRow { Text("Last Maintenance Status"); Text(appModel.lastMaintenanceJob?.status.rawValue ?? "-") }
            GridRow { Text("Last Maintenance Updated"); Text(appModel.lastMaintenanceJob.map { displayDate($0.updatedAt) } ?? "-") }
            GridRow { Text("Last Maintenance Summary"); Text(appModel.lastMaintenanceSummary) }
        }
    }

    private var selectedOldJobCleanupCutoff: Date {
        if let offset = oldJobCleanupCutoffPreset.dayOffset,
           let computed = Calendar(identifier: .gregorian).date(
            byAdding: .day,
            value: offset,
            to: Date()
           ) {
            return computed
        }
        return oldJobCleanupCustomCutoff
    }

    private var oldJobCleanupCanApply: Bool {
        guard let cleanup = appModel.lastOldJobTelemetryCleanup else {
            return false
        }
        return cleanup.canApplyAfterPreview && cleanup.cutoffSource == "explicit"
    }

    private var oldJobCleanupConfirmationText: String {
        guard let cleanup = appModel.lastOldJobTelemetryCleanup else {
            return "Run a preview first. The app will not delete anything without a preview and confirmation."
        }
        return "This deletes \(cleanup.eligibleCount) eligible old terminal job record(s) before \(cleanup.cutoffText), estimated at \(byteString(cleanup.estimatedBytesReclaimable)). Active, running, queued, schedule-running, recent visible, and linked PM/analyst/proposal/run records are preserved. Schedules are preserved. This cannot be undone from the UI."
    }

    private func systemStat(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func systemStat(
        _ metrics: [AppModel.SystemHealthMetricPresentation],
        _ index: Int
    ) -> some View {
        let metric = metrics.indices.contains(index)
            ? metrics[index]
            : AppModel.SystemHealthMetricPresentation(title: "-", value: "-")
        return systemStat(title: metric.title, value: metric.value)
    }

    @ViewBuilder
    private func ownerSystemExceptionDetail(
        for category: OwnerSystemExceptionCategoryPresentation
    ) -> some View {
        switch category.title {
        case "Feed Issues":
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow { Text("Trade Updates"); Text(appModel.tradeStreamOwnerFacingLabel) }
                GridRow { Text("Market Data"); Text(appModel.marketDataOwnerFacingLabel) }
                GridRow { Text("Configured Feed"); Text(appModel.selectedMarketDataFeed.displayName) }
                GridRow { Text("Feed Verify"); Text(appModel.selectedMarketDataFeed.diagnosticWebSocketEndpoint) }
                GridRow { Text("Readiness"); Text(appModel.alwaysOnReadiness.summary) }
            }
        case "Worker / Launch Issues":
            VStack(alignment: .leading, spacing: 8) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow { Text("Worker Link"); Text(workerLinkStatus) }
                    GridRow { Text("Failed Analyst Launches"); Text("\(appModel.pmCommandCenterSnapshot.failedDelegationsCount)") }
                    GridRow { Text("Degraded Analyst Launches"); Text("\(appModel.pmCommandCenterSnapshot.degradedDelegationsCount)") }
                }
            }
        default:
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow { Text("Running Jobs"); Text("\(appModel.runningJobSnapshots.count)") }
                GridRow { Text("Last Maintenance Status"); Text(appModel.lastMaintenanceJob?.status.rawValue ?? "None") }
                GridRow { Text("Last Maintenance Summary"); Text(appModel.lastMaintenanceSummary) }
            }
        }
    }

    private func systemExceptionCategoryRow(
        _ category: OwnerSystemExceptionCategoryPresentation
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(category.title)
                    .font(.headline)
                Spacer()
                Text("\(category.count)")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(category.count == 0 ? Color.secondary : Color.red)
            }

            Text(category.summary)
                .font(.callout)
                .foregroundStyle(.secondary)

            if category.title == "Worker / Launch Issues", category.count > 0 {
                Button("Resolve Failed Worker Issues") {
                    resolveActiveWorkerIssues()
                }
                .ownerActionButton()
                .disabled(inFlight)
                Text("This clears stale failed or degraded worker launches from active exception counts while keeping delegation history and audit traceability.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            DisclosureGroup(category.detailLabel) {
                ownerSystemExceptionDetail(for: category)
                    .padding(.top, 6)
            }
        }
    }

    private func resolveActiveWorkerIssues() {
        inFlight = true
        feedbackMessage = nil
        feedbackIsError = false
        Task { @MainActor in
            defer { inFlight = false }
            if let error = await appModel.resolveActivePMDelegationWorkerIssues() {
                feedbackMessage = error
                feedbackIsError = true
            } else {
                feedbackMessage = "Resolved active worker issues from the System Exceptions card."
                feedbackIsError = false
            }
        }
    }

    private func saveSchedule() {
        inFlight = true
        feedbackMessage = nil
        feedbackIsError = false
        Task { @MainActor in
            defer { inFlight = false }
            let params: [String: JSONValue]
            let trimmedParams = scheduleEditorParamsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedParams.isEmpty {
                params = [:]
            } else {
                do {
                    params = try JSONValue.parseObject(json: trimmedParams)
                } catch {
                    feedbackMessage = "Params must be a valid JSON object."
                    feedbackIsError = true
                    return
                }
            }

            let maxRuntime: Int?
            let trimmedRuntime = scheduleEditorMaxRuntimeSec.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedRuntime.isEmpty {
                maxRuntime = nil
            } else if let parsed = Int(trimmedRuntime), parsed > 0 {
                maxRuntime = parsed
            } else {
                feedbackMessage = "Max runtime must be a positive integer."
                feedbackIsError = true
                return
            }

            let intervalValue = scheduleEditorIntervalValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsedInterval = Int(intervalValue), parsedInterval > 0 else {
                feedbackMessage = "Interval must be a positive whole number."
                feedbackIsError = true
                return
            }
            let scheduleIntervalSec = parsedInterval * scheduleEditorIntervalUnit.multiplier
            guard (1...86_400).contains(scheduleIntervalSec) else {
                feedbackMessage = "Interval must be between 1 second and 24 hours."
                feedbackIsError = true
                return
            }

            let scheduleID = scheduleEditorID ?? UUID().uuidString
            let schedule = ScheduledJob(
                scheduleId: scheduleID,
                jobType: scheduleEditorJobType,
                enabled: scheduleEditorEnabled,
                trigger: ScheduledJobTrigger(intervalSec: scheduleIntervalSec),
                policy: ScheduledJobPolicy(
                    runMode: scheduleEditorAlwaysOn ? .alwaysOn : .periodic,
                    restartOnAppLaunch: scheduleEditorRestartOnLaunch,
                    maxRuntimeSec: maxRuntime,
                    allowOverlap: scheduleEditorAllowOverlap,
                    startupBehavior: scheduleEditorStartupBehavior
                ),
                params: params
            )

            if let error = await appModel.upsertSchedule(schedule) {
                feedbackMessage = error
                feedbackIsError = true
            } else {
                selectedScheduleID = scheduleID
                feedbackMessage = "Saved ✅ schedule \(shortID(scheduleID))"
                feedbackIsError = false
            }
        }
    }

    private func runScheduleNow(id: String) {
        inFlight = true
        feedbackMessage = nil
        feedbackIsError = false
        Task { @MainActor in
            defer { inFlight = false }
            let outcome = await appModel.runScheduleNow(id: id)
            if let error = outcome.error {
                feedbackMessage = "Run Now failed: \(error)"
                feedbackIsError = true
            } else if let summary = outcome.summary,
                      let runningJobID = summary.runningJobId,
                      !runningJobID.isEmpty {
                feedbackMessage = "Run Now dispatched ✅ job \(shortID(runningJobID))"
                feedbackIsError = false
            } else if let summary = outcome.summary,
                      let lastRunSummary = summary.lastRunSummary,
                      !lastRunSummary.isEmpty {
                let status = scheduleLastRunStatusLabel(summary)
                feedbackMessage = "Run Now \(status.lowercased()): \(lastRunSummary)"
                feedbackIsError = summary.lastRunStatus == .failed || summary.lastRunStatus == .canceled
            } else {
                feedbackMessage = "Run Now dispatched."
                feedbackIsError = false
            }
        }
    }

    private func removeSchedule(id: String) {
        inFlight = true
        feedbackMessage = nil
        feedbackIsError = false
        Task { @MainActor in
            defer { inFlight = false }
            if let error = await appModel.removeSchedule(id: id) {
                feedbackMessage = error
                feedbackIsError = true
            } else {
                resetScheduleEditorForCreate()
                feedbackMessage = "Schedule removed."
                feedbackIsError = false
            }
        }
    }

    private func resetScheduleEditorForCreate() {
        selectedScheduleID = nil
        scheduleEditorID = nil
        scheduleEditorJobType = .rssPoll
        scheduleEditorEnabled = true
        scheduleEditorIntervalValue = "5"
        scheduleEditorIntervalUnit = .minutes
        scheduleEditorAlwaysOn = false
        scheduleEditorRestartOnLaunch = true
        scheduleEditorAllowOverlap = false
        scheduleEditorStartupBehavior = .waitForInterval
        scheduleEditorMaxRuntimeSec = ""
        scheduleEditorParamsJSON = "{}"
    }

    private func loadScheduleEditor(from summary: ScheduledJobSummary) {
        scheduleEditorID = summary.scheduleId
        scheduleEditorJobType = summary.jobType
        scheduleEditorEnabled = summary.enabled
        loadScheduleIntervalEditor(intervalSec: max(1, summary.intervalSec))
        scheduleEditorAlwaysOn = summary.runMode == .alwaysOn
        scheduleEditorRestartOnLaunch = summary.restartOnAppLaunch
        scheduleEditorAllowOverlap = summary.allowOverlap
        scheduleEditorStartupBehavior = summary.startupBehavior
        scheduleEditorMaxRuntimeSec = summary.maxRuntimeSec.map(String.init) ?? ""
        scheduleEditorParamsJSON = appModel.jsonText(for: summary.params)
    }

    private func loadScheduleIntervalEditor(intervalSec: Int) {
        if intervalSec % 3_600 == 0 {
            scheduleEditorIntervalUnit = .hours
            scheduleEditorIntervalValue = String(intervalSec / 3_600)
        } else if intervalSec % 60 == 0 {
            scheduleEditorIntervalUnit = .minutes
            scheduleEditorIntervalValue = String(intervalSec / 60)
        } else {
            scheduleEditorIntervalUnit = .seconds
            scheduleEditorIntervalValue = String(intervalSec)
        }
    }

    private var scheduleIntervalSummaryText: String {
        let trimmed = scheduleEditorIntervalValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Int(trimmed), parsed > 0 else {
            return "Enter a positive number"
        }
        let totalSeconds = parsed * scheduleEditorIntervalUnit.multiplier
        return "\(totalSeconds) sec"
    }

    private var maintenanceIntervalSummaryText: String {
        let trimmed = maintenanceScheduleIntervalValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Int(trimmed), parsed > 0 else {
            return "Enter a positive number"
        }
        let totalSeconds = parsed * maintenanceScheduleIntervalUnit.multiplier
        return "\(totalSeconds) sec"
    }

    private func scheduleLastRunStatusLabel(_ summary: ScheduledJobSummary) -> String {
        switch summary.lastRunStatus {
        case .succeeded:
            return "Succeeded"
        case .failed:
            return "Failed"
        case .canceled:
            return "Canceled"
        case nil:
            return "-"
        }
    }

    private func scheduleDisplayError(_ summary: ScheduledJobSummary) -> String? {
        let message = summary.lastErrorMessage ?? summary.lastError
        guard let message, !message.isEmpty else {
            return nil
        }
        if summary.runMode == .periodic && summary.lastErrorCode == "job_not_found" {
            return nil
        }
        return message
    }

    private func loadRetentionEditor(from policy: RetentionPolicy) {
        retentionAuditRotateMB = policy.audit.rotateWhenMB
        retentionAuditKeepDays = policy.audit.keepDays
        retentionNewsKeepDays = policy.news.keepDays
        retentionJobsKeepDays = policy.jobs.keepDaysCompleted
        retentionJobsMaxCount = policy.jobs.keepMaxCompletedCount ?? 500
        retentionRunsEnabled = policy.runs.enabled
        retentionRunsKeepDays = policy.runs.keepDays
        retentionBarsEnabled = policy.barsCache.enabled
        retentionBarsMaxDBMB = policy.barsCache.maxDBMB.map(String.init) ?? ""
    }

    private func loadMaintenanceScheduleEditor(from summary: ScheduledJobSummary?) {
        guard let summary else {
            maintenanceScheduleEnabled = true
            maintenanceScheduleIntervalValue = "24"
            maintenanceScheduleIntervalUnit = .hours
            return
        }
        maintenanceScheduleEnabled = summary.enabled
        if summary.intervalSec % 3_600 == 0 {
            maintenanceScheduleIntervalUnit = .hours
            maintenanceScheduleIntervalValue = String(summary.intervalSec / 3_600)
        } else if summary.intervalSec % 60 == 0 {
            maintenanceScheduleIntervalUnit = .minutes
            maintenanceScheduleIntervalValue = String(summary.intervalSec / 60)
        } else {
            maintenanceScheduleIntervalUnit = .seconds
            maintenanceScheduleIntervalValue = String(summary.intervalSec)
        }
    }

    private func saveMaintenanceSchedule() {
        inFlight = true
        feedbackMessage = nil
        feedbackIsError = false
        Task { @MainActor in
            defer { inFlight = false }

            let trimmed = maintenanceScheduleIntervalValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsed = Int(trimmed), parsed > 0 else {
                feedbackMessage = "Maintenance interval must be a positive whole number."
                feedbackIsError = true
                return
            }

            let intervalSec = parsed * maintenanceScheduleIntervalUnit.multiplier
            guard (1...86_400).contains(intervalSec) else {
                feedbackMessage = "Maintenance interval must be between 1 second and 24 hours."
                feedbackIsError = true
                return
            }

            let schedule = AutomationScheduleSections.makeMaintenanceSchedule(
                from: maintenanceScheduleSummary,
                enabled: maintenanceScheduleEnabled,
                intervalSec: intervalSec
            )

            if let error = await appModel.upsertSchedule(schedule) {
                feedbackMessage = error
                feedbackIsError = true
            } else {
                feedbackMessage = "Saved ✅ maintenance schedule \(shortID(schedule.scheduleId))"
                feedbackIsError = false
            }
        }
    }

    private func saveRetentionPolicy() {
        inFlight = true
        feedbackMessage = nil
        feedbackIsError = false
        Task { @MainActor in
            defer { inFlight = false }

            let barsMaxDBMB: Int?
            let trimmedBars = retentionBarsMaxDBMB.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedBars.isEmpty {
                barsMaxDBMB = nil
            } else if let parsed = Int(trimmedBars), parsed > 0 {
                barsMaxDBMB = parsed
            } else {
                feedbackMessage = "Bars max DB must be a positive integer when provided."
                feedbackIsError = true
                return
            }

            let policy = RetentionPolicy(
                audit: .init(
                    rotateWhenMB: max(1, retentionAuditRotateMB),
                    keepDays: max(1, retentionAuditKeepDays)
                ),
                news: .init(keepDays: max(1, retentionNewsKeepDays)),
                jobs: .init(
                    keepDaysCompleted: max(1, retentionJobsKeepDays),
                    keepMaxCompletedCount: max(1, retentionJobsMaxCount)
                ),
                runs: .init(
                    enabled: retentionRunsEnabled,
                    keepDays: max(1, retentionRunsKeepDays)
                ),
                barsCache: .init(
                    enabled: retentionBarsEnabled,
                    maxDBMB: barsMaxDBMB
                )
            )

            feedbackMessage = await appModel.saveRetentionPolicy(policy)
            feedbackIsError = feedbackMessage != nil
            if feedbackMessage == nil {
                _ = await appModel.refreshStorageFootprint()
                loadRetentionEditor(from: appModel.retentionPolicy)
            }
        }
    }

    private func runMaintenanceNow(dryRun: Bool) {
        inFlight = true
        feedbackMessage = nil
        feedbackIsError = false
        Task { @MainActor in
            defer { inFlight = false }
            feedbackMessage = await appModel.runMaintenanceRetention(dryRun: dryRun)
            feedbackIsError = feedbackMessage?.lowercased().contains("error") == true
            if feedbackMessage == nil {
                feedbackMessage = dryRun
                    ? "Full retention preview requested. Review the latest maintenance result before applying."
                    : "Full retention cleanup requested through app-owned maintenance."
                feedbackIsError = false
                fullRetentionPreviewCompleted = dryRun && appModel.lastMaintenanceJob?.status == .succeeded
            }
            _ = await appModel.refreshStorageFootprint()
        }
    }

    private func runOldJobCleanup(dryRun: Bool) {
        let cutoff: Date
        if dryRun {
            cutoff = selectedOldJobCleanupCutoff
        } else if let previewCutoff = appModel.lastOldJobTelemetryCleanup?.cutoff {
            cutoff = previewCutoff
        } else {
            feedbackMessage = "Run Preview Old Job Cleanup before deleting eligible old jobs."
            feedbackIsError = true
            return
        }

        inFlight = true
        feedbackMessage = nil
        feedbackIsError = false
        Task { @MainActor in
            defer { inFlight = false }
            feedbackMessage = await appModel.runMaintenanceRetention(
                dryRun: dryRun,
                jobTelemetryCleanupBefore: cutoff
            )
            if feedbackMessage == nil {
                feedbackMessage = dryRun
                    ? "Old job cleanup preview requested. No files are deleted by preview."
                    : "Old job cleanup apply requested through app-owned maintenance."
                feedbackIsError = false
                if !dryRun {
                    fullRetentionPreviewCompleted = false
                }
            } else {
                feedbackIsError = true
            }
            _ = await appModel.refreshStorageFootprint()
        }
    }

    private func armLiveTrading() {
        safetyActionInFlight = true
        Task { @MainActor in
            await appModel.armLiveTrading()
            safetyActionInFlight = false
        }
    }

    private func disarmLiveTrading() {
        safetyActionInFlight = true
        Task { @MainActor in
            await appModel.disarmLiveTrading()
            liveArmingConfirmed = false
            safetyActionInFlight = false
        }
    }

    private func byteString(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: max(0, bytes))
    }

    private func shortID(_ value: String) -> String {
        String(value.prefix(8))
    }

    private func displayDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func iso8601String(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

struct AlgoControlCenterView: View {
    @EnvironmentObject private var appModel: AppModel

    @State private var paramsDraftByID: [String: String] = [:]
    @State private var feedbackByID: [String: String] = [:]
    @State private var inFlight: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Advanced Strategy Controls")
                .font(.title2)

            HStack(spacing: 16) {
                Text("Safety: \(appModel.liveSafetyStatusLabel)")
                Text("Kill switch: \(appModel.killSwitchEnabled ? "ON" : "OFF")")
                Text("IPC: \(appModel.ipcStatusLine)")
                Text(appModel.agentCtlReadyText)
                    .foregroundStyle(appModel.ipcStatus.running ? .green : .secondary)
            }
            .font(.callout)

            GroupBox("Currently Running Jobs") {
                let activeJobs = Array(appModel.runningJobSnapshots.prefix(6))
                if activeJobs.isEmpty {
                    Text("No queued or running jobs right now.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(activeJobs) { job in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text("\(job.type.rawValue) • \(shortID(job.jobId))")
                                        .font(.headline)
                                    Spacer()
                                    Text(job.status.rawValue.uppercased())
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(job.status == .running ? .green : .orange)
                                }
                                Text("updated \(displayDate(job.updatedAt))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                if let summary = job.summary, !summary.isEmpty {
                                    Text(summary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            if job.id != activeJobs.last?.id {
                                Divider()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if appModel.strategyStatuses.isEmpty {
                Text("No strategies registered.")
                    .foregroundStyle(.secondary)
            } else {
                List(appModel.strategyStatuses) { status in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("\(status.name) (\(status.id))")
                                .font(.headline)
                            Spacer()
                            Text(status.state.rawValue.uppercased())
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(stateColor(status.state).opacity(0.2))
                                .clipShape(Capsule())
                        }

                        if let lastMessage = status.lastMessage,
                           !lastMessage.isEmpty {
                            Text("Last: \(lastMessage)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }

                        TextField(
                            "Params JSON",
                            text: Binding(
                                get: {
                                    paramsDraftByID[status.id]
                                        ?? appModel.jsonText(for: status.parameters)
                                },
                                set: { newValue in
                                    paramsDraftByID[status.id] = newValue
                                }
                            ),
                            axis: .vertical
                        )
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...5)
                        .font(.system(.caption, design: .monospaced))

                        HStack(spacing: 8) {
                            Button("Set Params") {
                                applyParams(for: status.id)
                            }
                            .disabled(inFlight.contains(status.id))

                            Button("Start") {
                                startStrategy(status.id)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(inFlight.contains(status.id) || status.state == .running)

                            Button("Stop") {
                                stopStrategy(status.id)
                            }
                            .disabled(inFlight.contains(status.id) || status.state != .running)

                            if inFlight.contains(status.id) {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }

                        if let feedback = feedbackByID[status.id],
                           !feedback.isEmpty {
                            Text(feedback)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(minHeight: 260)
            }

            Text("Latest audit lines")
                .font(.headline)

            List(Array(appModel.auditLinesNewestFirst.prefix(12).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            .frame(minHeight: 180)

            Spacer(minLength: 0)
        }
        .padding(18)
    }

    private func applyParams(for strategyID: String) {
        let params = paramsDraftByID[strategyID] ?? "{}"
        inFlight.insert(strategyID)
        feedbackByID[strategyID] = nil

        Task { @MainActor in
            let error = await appModel.setStrategyParameters(id: strategyID, paramsJSON: params)
            feedbackByID[strategyID] = error
            inFlight.remove(strategyID)
        }
    }

    private func startStrategy(_ strategyID: String) {
        let params = paramsDraftByID[strategyID] ?? "{}"
        inFlight.insert(strategyID)
        feedbackByID[strategyID] = nil

        Task { @MainActor in
            let error = await appModel.startStrategy(id: strategyID, paramsJSON: params)
            feedbackByID[strategyID] = error
            inFlight.remove(strategyID)
        }
    }

    private func stopStrategy(_ strategyID: String) {
        inFlight.insert(strategyID)
        feedbackByID[strategyID] = nil

        Task { @MainActor in
            let error = await appModel.stopStrategy(id: strategyID)
            feedbackByID[strategyID] = error
            inFlight.remove(strategyID)
        }
    }

    private func stateColor(_ state: StrategyRunState) -> Color {
        switch state {
        case .running:
            return .green
        case .error:
            return .red
        case .stopped:
            return .secondary
        }
    }

    private func shortID(_ value: String) -> String {
        String(value.prefix(8))
    }

    private func displayDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

private enum PMInboxSection: String, CaseIterable, Identifiable {
    case review = "Review"
    case signals = "Signals"
    case proposals = "Proposals"
    case runs = "Runs"
    case analyst = "Analyst"

    var id: String { rawValue }
}

private enum ScheduleIntervalEditorUnit: String, CaseIterable, Identifiable {
    case seconds = "Seconds"
    case minutes = "Minutes"
    case hours = "Hours"

    var id: String { rawValue }

    var multiplier: Int {
        switch self {
        case .seconds:
            return 1
        case .minutes:
            return 60
        case .hours:
            return 3_600
        }
    }
}

private enum PMInboxSignalFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case new = "New"
    case acknowledged = "Acknowledged"
    case archived = "Archived"

    var id: String { rawValue }

    func matches(_ status: SignalStatus) -> Bool {
        switch self {
        case .all:
            return true
        case .new:
            return status == .new
        case .acknowledged:
            return status == .acknowledged
        case .archived:
            return status == .archived
        }
    }
}

private enum PMInboxProposalFilter: String, CaseIterable, Identifiable {
    case awaiting = "Awaiting Approval"
    case draft = "Draft"
    case proposed = "Proposed"
    case approvedPaper = "Approved"
    case deniedPaper = "Denied"
    case all = "All"

    var id: String { rawValue }

    func matches(_ status: StrategyProposalStatus) -> Bool {
        switch self {
        case .awaiting:
            return status == .draft || status == .proposed
        case .draft:
            return status == .draft
        case .proposed:
            return status == .proposed
        case .approvedPaper:
            return status == .approvedPaper
        case .deniedPaper:
            return status == .deniedPaper
        case .all:
            return true
        }
    }
}

struct PMInboxView: View {
    @EnvironmentObject private var appModel: AppModel
    @Binding var selectedTab: MainTab

    @State private var section: PMInboxSection = .review
    @State private var signalFilter: PMInboxSignalFilter = .all
    @State private var proposalFilter: PMInboxProposalFilter = .awaiting
    @State private var selectedSignalID: String?
    @State private var selectedProposalID: String?
    @State private var selectedRunID: String?
    @State private var selectedScheduleID: String?
    @State private var selectedAnalystTaskID: String?
    @State private var selectedApprovalRequestID: String?
    @State private var selectedDecisionID: String?
    @State private var selectedRecentAnalystActivityID: String?
    @State private var selectedRecentAnalystLinkedStandingReportID: String?
    @State private var selectedCommunicationSessionID: String?
    @State private var selectedCommunicationMessageID: String?
    @State private var approvalRequestDetailsExpanded = false
    @State private var decisionDetailsExpanded = false
    @State private var approvalRequestSupportingDetailsExpanded = false
    @State private var reviewNotes = ""
    @State private var communicationPromotionTarget: PMCommunicationPromotionTargetType = .notebookEntry
    @State private var communicationPromotionTitle = ""
    @State private var communicationPromotionBody = ""
    @State private var communicationPromotionCharterID = ""
    @State private var telegramReplyBody = ""
    @State private var feedbackMessage: String?
    @State private var feedbackIsError = false
    @State private var inFlight = false
    @State private var scheduleEditorID: String?
    @State private var scheduleEditorJobType: JobType = .rssPoll
    @State private var scheduleEditorEnabled = true
    @State private var scheduleEditorIntervalValue = "5"
    @State private var scheduleEditorIntervalUnit: ScheduleIntervalEditorUnit = .minutes
    @State private var scheduleEditorAlwaysOn = false
    @State private var scheduleEditorRestartOnLaunch = true
    @State private var scheduleEditorAllowOverlap = false
    @State private var scheduleEditorStartupBehavior: PeriodicScheduleStartupBehavior = .waitForInterval
    @State private var scheduleEditorMaxRuntimeSec = ""
    @State private var scheduleEditorParamsJSON = "{}"
    @State private var retentionAuditRotateMB = 25
    @State private var retentionAuditKeepDays = 30
    @State private var retentionNewsKeepDays = 30
    @State private var retentionJobsKeepDays = 14
    @State private var retentionJobsMaxCount = 500
    @State private var retentionRunsEnabled = false
    @State private var retentionRunsKeepDays = 180
    @State private var retentionBarsEnabled = false
    @State private var retentionBarsMaxDBMB = ""
    @State private var maintenanceScheduleEnabled = true
    @State private var maintenanceScheduleIntervalValue = "24"
    @State private var maintenanceScheduleIntervalUnit: ScheduleIntervalEditorUnit = .hours
    @State private var showPMInboxFullMaintenanceApplyConfirmation = false
    @State private var pmInboxFullRetentionPreviewCompleted = false
    @State private var reviewProjection = PMInboxReviewProjection()
    @State private var hasLoadedVisibleReviewData = false
    @State private var hasPrefetchedProposalRuns = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            summaryHeader

            sectionHeaderControls

            if let feedbackMessage, !feedbackMessage.isEmpty {
                Text(feedbackMessage)
                    .foregroundStyle(feedbackIsError ? .red : .green)
                    .font(.callout)
            }

            Group {
                if section == .review {
                    reviewDeskDetailView()
                } else {
                    NavigationSplitView {
                        listPane
                    } detail: {
                        detailPane
                    }
                    .navigationSplitViewStyle(.balanced)
                }
            }
        }
        .padding(18)
        .onAppear {
            bootstrapSelections()
            loadRetentionEditor(from: appModel.retentionPolicy)
            loadMaintenanceScheduleEditor(from: maintenanceScheduleSummary)
            refreshVisibleReviewProjection()
            beginVisibleSectionWorkIfNeeded()
        }
        .onChange(of: selectedTab) { newValue in
            guard newValue == .pmInbox else {
                reviewProjection = PMInboxReviewProjection()
                selectedRecentAnalystLinkedStandingReportID = nil
                return
            }
            bootstrapSelections()
            refreshVisibleReviewProjection()
            beginVisibleSectionWorkIfNeeded()
        }
        .onChange(of: section) { _ in
            bootstrapSelections()
            if shouldMaintainReviewProjection {
                refreshVisibleReviewProjection()
            }
            beginVisibleSectionWorkIfNeeded()
        }
        .onChange(of: appModel.signals) { _ in
            if selectedSignalID == nil || filteredSignals.contains(where: { $0.id == selectedSignalID }) == false {
                selectedSignalID = filteredSignals.first?.id
            }
        }
        .onChange(of: appModel.proposals) { _ in
            if selectedProposalID == nil || filteredProposals.contains(where: { $0.id == selectedProposalID }) == false {
                selectedProposalID = filteredProposals.first?.id
            }
        }
        .onChange(of: appModel.schedules) { schedules in
            if selectedScheduleID == nil || operationalSchedules.contains(where: { $0.scheduleId == selectedScheduleID }) == false {
                selectedScheduleID = operationalSchedules.first?.scheduleId
            }
            loadMaintenanceScheduleEditor(from: schedules.first(where: { $0.jobType == .maintenanceRetention }))
        }
        .onChange(of: appModel.analystTasks) { _ in
            if selectedAnalystTaskID == nil
                || !appModel.analystTasks.contains(where: { $0.id == selectedAnalystTaskID }) {
                selectedAnalystTaskID = appModel.analystTasks.first?.id
            }
            refreshVisibleReviewProjection()
        }
        .onChange(of: appModel.pmApprovalRequests) { _ in
            refreshVisibleReviewProjection()
        }
        .onChange(of: appModel.pmDecisions) { _ in
            refreshVisibleReviewProjection()
        }
        .onChange(of: appModel.analystStandingReports) { _ in
            refreshVisibleReviewProjection()
        }
        .onChange(of: appModel.analystMemos) { _ in
            refreshVisibleReviewProjection()
        }
        .onChange(of: appModel.pmDelegations) { _ in
            refreshVisibleReviewProjection()
        }
        .onChange(of: appModel.pmCommunicationSessions) { _ in
            refreshVisibleReviewProjection()
        }
        .onChange(of: appModel.pmCommunicationMessages) { _ in
            refreshVisibleReviewProjection()
        }
        .onChange(of: appModel.pmContextPack) { _ in
            refreshVisibleReviewProjection()
        }
        .onChange(of: appModel.analystCharters) { _ in
            refreshVisibleReviewProjection()
        }
        .onChange(of: appModel.pmExecutionRoutingAssessmentsByApprovalRequestID) { _ in
            refreshVisibleReviewProjection()
        }
        .onChange(of: selectedApprovalRequestID) { _ in
            approvalRequestDetailsExpanded = false
            approvalRequestSupportingDetailsExpanded = false
            guard let selectedApprovalRequestID else {
                return
            }
            Task { @MainActor in
                _ = await appModel.refreshPMExecutionRoutingAssessment(
                    approvalRequestID: selectedApprovalRequestID
                )
                refreshVisibleReviewProjection()
            }
        }
        .onChange(of: selectedDecisionID) { _ in
            decisionDetailsExpanded = false
        }
        .onChange(of: selectedRecentAnalystActivityID) { _ in
            syncRecentAnalystActivitySelection()
        }
        .onChange(of: selectedCommunicationSessionID) { _ in
            selectedCommunicationMessageID = nil
        }
        .onChange(of: selectedCommunicationMessageID) { _ in
            loadCommunicationPromotionDraft()
        }
        .onChange(of: selectedScheduleID) { newValue in
            guard let newValue,
                  let selected = operationalSchedules.first(where: { $0.scheduleId == newValue })
            else {
                return
            }
            loadScheduleEditor(from: selected)
        }
        .onChange(of: appModel.retentionPolicy) { updatedPolicy in
            loadRetentionEditor(from: updatedPolicy)
        }
        .onChange(of: selectedProposalID) { newValue in
            guard let proposalID = newValue else {
                selectedRunID = nil
                return
            }
            Task { @MainActor in
                feedbackMessage = await appModel.fetchProposalDetail(id: proposalID)
                if feedbackMessage == nil {
                    feedbackMessage = await appModel.fetchProposalRuns(proposalID: proposalID)
                }
                selectedRunID = appModel.proposalRuns(proposalID: proposalID).first?.runId
                if let selectedRunID {
                    _ = await appModel.fetchRunDetail(runID: selectedRunID)
                }
            }
        }
        .onChange(of: selectedRunID) { newValue in
            guard let newValue else {
                return
            }
            Task { @MainActor in
                let error = await appModel.fetchRunDetail(runID: newValue)
                if let error {
                    feedbackMessage = error
                }
            }
        }
    }

    private var isVisible: Bool {
        selectedTab == .pmInbox
    }

    private var shouldMaintainReviewProjection: Bool {
        isVisible && section == .review
    }

    private var summaryHeader: some View {
        let snapshot = appModel.pmCommandCenterSnapshot
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                summaryPill(label: "Owner Decisions", value: "\(snapshot.ownerActionableApprovalCount)", color: .red)
                summaryPill(label: "Standing Reviews", value: "\(snapshot.pendingStandingReportReviewCount)", color: .purple)
                summaryPill(label: "New Signals", value: "\(snapshot.newSignalsCount)", color: .orange)
                summaryPill(label: "Awaiting Proposals", value: "\(snapshot.awaitingProposalCount)", color: .blue)
                summaryPill(label: "Active Delegations", value: "\(snapshot.activeDelegationsCount)", color: .teal)
                summaryPill(label: "Runs (24h)", value: "\(runsLast24hCount)", color: .green)
            }
        }
    }

    private var pendingApprovalRequests: [PMApprovalRequest] {
        makeOwnerActionableApprovalRequests(
            approvalRequests: appModel.pmApprovalRequests,
            decisions: appModel.pmDecisions
        )
    }

    private var approvalRequestsForReview: [PMApprovalRequest] {
        reviewProjection.approvalRequestsForReview
    }

    private var recentNewsDecisionsForReview: [PMDecisionRecord] {
        reviewProjection.recentNewsDecisionsForReview
    }

    private var selectedApprovalRequest: PMApprovalRequest? {
        guard let selectedApprovalRequestID else {
            return nil
        }
        return approvalRequestsForReview.first(where: { $0.approvalRequestId == selectedApprovalRequestID })
            ?? appModel.pmApprovalRequests.first(where: { $0.approvalRequestId == selectedApprovalRequestID })
    }

    private var recentDecisionsForReview: [PMDecisionRecord] {
        reviewProjection.recentDecisionsForReview
    }

    private var recentAnalystActivityScopeItems: [PMInboxRecentAnalystActivityItem] {
        if reviewProjection.recentAnalystActivityScopeItems.isEmpty {
            return reviewProjection.recentAnalystActivityItems
        }
        return reviewProjection.recentAnalystActivityScopeItems
    }

    private var selectedDecision: PMDecisionRecord? {
        guard let selectedDecisionID else {
            return nil
        }
        return recentNewsDecisionsForReview.first(where: { $0.decisionId == selectedDecisionID })
            ?? recentDecisionsForReview.first(where: { $0.decisionId == selectedDecisionID })
            ?? appModel.pmDecisions.first(where: { $0.decisionId == selectedDecisionID })
    }

    private var recentAnalystActivityItems: [PMInboxRecentAnalystActivityItem] {
        reviewProjection.recentAnalystActivityItems
    }

    private var selectedRecentAnalystActivityItem: PMInboxRecentAnalystActivityItem? {
        guard let selectedRecentAnalystActivityID else {
            return nil
        }
        return recentAnalystActivityItems.first(where: { $0.id == selectedRecentAnalystActivityID })
    }

    private var selectedRecentAnalystActivityDetail: PMInboxRecentAnalystActivityDetailPresentation? {
        guard let selectedRecentAnalystActivityItem else {
            return nil
        }
        return makePMInboxRecentAnalystActivityDetailPresentation(
            item: selectedRecentAnalystActivityItem,
            reports: appModel.analystStandingReports,
            memos: appModel.analystMemos,
            evidenceBundles: appModel.analystEvidenceBundles,
            delegations: appModel.pmDelegations
        )
    }

    private var selectedRecentAnalystLinkedStandingReportPresentation: AnalystStandingReportReviewPresentation? {
        guard let linkedStandingReportID = selectedRecentAnalystLinkedStandingReportID else {
            return nil
        }
        return makeStandingAnalystReportReviewPresentation(
            reportID: linkedStandingReportID,
            reports: appModel.analystStandingReports,
            memos: appModel.analystMemos,
            charters: appModel.analystCharters
        )
    }

    private var sectionHeaderControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(PMInboxSection.allCases) { item in
                        Button {
                            section = item
                        } label: {
                            Text(item.rawValue)
                                .font(.callout.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(section == item ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    filterControls
                    Spacer(minLength: 0)
                    actionControls
                }
                VStack(alignment: .leading, spacing: 10) {
                    filterControls
                    actionControls
                }
            }
        }
    }

    @ViewBuilder
    private var filterControls: some View {
        if section == .signals {
            Picker("Signals", selection: $signalFilter) {
                ForEach(PMInboxSignalFilter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.menu)
        } else if section == .proposals {
            Picker("Proposals", selection: $proposalFilter) {
                ForEach(PMInboxProposalFilter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.menu)
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private var actionControls: some View {
        switch section {
        case .review:
            reviewActionControls
        case .analyst:
            analystActionControls
        default:
            defaultActionControls
        }
    }

    private var reviewActionControls: some View {
        EmptyView()
    }

    private var analystActionControls: some View {
        HStack(spacing: 8) {
            Button("New Task") {
                selectedAnalystTaskID = nil
            }
            .buttonStyle(.borderedProminent)

            Button("Refresh Analyst Data") {
                Task { @MainActor in await refreshAnalystOperatingSurfaces() }
            }
            .buttonStyle(.bordered)
        }
    }

    private func refreshAnalystOperatingSurfaces() async {
        let pmProfileError = await appModel.refreshPMProfiles()
        let decisionError = await appModel.refreshPMDecisions()
        let approvalError = await appModel.refreshPMApprovalRequests()
        let delegationError = await appModel.refreshPMDelegations()
        let communicationSessionError = await appModel.ensureInAppPMUserCommunicationSession()
        let communicationMessageError = await appModel.refreshPMCommunicationMessages()
        let charterError = await appModel.refreshAnalystCharters()
        let taskError = await appModel.refreshAnalystTasks()
        let memoError = await appModel.refreshAnalystMemos()
        let findingError = await appModel.refreshAnalystFindings()
        let evidenceBundleError = await appModel.refreshAnalystEvidenceBundles()
        let sourceSuggestionError = await appModel.refreshAnalystSourceAccessSuggestions()
        let implicationError = await appModel.refreshAnalystStrategyImplications()
        let strategyFollowUpError = await appModel.refreshAnalystStrategyFollowUpCandidates()
        let standingReportError = await appModel.refreshAnalystStandingReports()
        let contextError = await appModel.refreshPMContextPack()
        feedbackMessage = firstNonNilString([
            pmProfileError,
            decisionError,
            approvalError,
            delegationError,
            communicationSessionError,
            communicationMessageError,
            charterError,
            taskError,
            memoError,
            findingError,
            evidenceBundleError,
            sourceSuggestionError,
            implicationError,
            strategyFollowUpError,
            standingReportError,
            contextError
        ])
        feedbackIsError = feedbackMessage != nil
    }

    private func firstNonNilString(_ values: [String?]) -> String? {
        values.compactMap { value in
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  trimmed.isEmpty == false else {
                return nil
            }
            return trimmed
        }.first
    }

    private var defaultActionControls: some View {
        Button("Refresh Signals") {
            Task { @MainActor in
                feedbackMessage = await appModel.refreshSignals(limit: 200)
                feedbackIsError = feedbackMessage != nil
            }
        }
        .buttonStyle(.bordered)
    }

    private func summaryPill(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.weight(.semibold))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func syncCommandCenterSelections() {
        let availableApprovalIDs = Set(approvalRequestsForReview.map(\.approvalRequestId))
        self.selectedApprovalRequestID = makePMInboxRetainedSelection(
            currentSelectionID: selectedApprovalRequestID,
            availableIDs: Array(availableApprovalIDs)
        )

        let availableDecisionIDs = Set(
            recentDecisionsForReview.map(\.decisionId)
                + recentNewsDecisionsForReview.map(\.decisionId)
        )
        self.selectedDecisionID = makePMInboxRetainedSelection(
            currentSelectionID: selectedDecisionID,
            availableIDs: Array(availableDecisionIDs)
        )
    }

    private func syncRecentAnalystActivitySelection() {
        let availableActivityIDs = Array(Set(recentAnalystActivityItems.map(\.id)))
        self.selectedRecentAnalystActivityID = makePMInboxRetainedSelection(
            currentSelectionID: selectedRecentAnalystActivityID,
            availableIDs: availableActivityIDs
        )
        guard let linkedStandingReportID = selectedRecentAnalystActivityDetail?.linkedStandingReportID else {
            selectedRecentAnalystLinkedStandingReportID = nil
            return
        }
        self.selectedRecentAnalystLinkedStandingReportID = makePMInboxRetainedSelection(
            currentSelectionID: selectedRecentAnalystLinkedStandingReportID,
            availableIDs: [linkedStandingReportID]
        )
    }

    private var communicationSessionsForDisplay: [PMCommunicationSession] {
        reviewProjection.communicationSessionsForDisplay
    }

    private var selectedCommunicationSession: PMCommunicationSession? {
        guard let selectedCommunicationSessionID else {
            return nil
        }
        return communicationSessionsForDisplay.first(where: { $0.sessionId == selectedCommunicationSessionID })
    }

    private var preferredTelegramCommunicationSession: PMCommunicationSession? {
        if let selectedCommunicationSession,
           selectedCommunicationSession.channel == .telegram {
            return selectedCommunicationSession
        }
        return communicationSessionsForDisplay.first(where: { $0.channel == .telegram })
    }

    private var selectedCommunicationMessages: [PMCommunicationMessage] {
        guard let session = selectedCommunicationSession else {
            return []
        }
        return appModel.pmCommunicationMessages
            .filter {
                $0.sessionId == session.sessionId &&
                isExercisePMCommunicationMessage($0) == false
            }
            .sorted { lhs, rhs in
                if lhs.sentAt == rhs.sentAt {
                    return lhs.messageId < rhs.messageId
                }
                return lhs.sentAt < rhs.sentAt
            }
    }

    private var selectedCommunicationMessage: PMCommunicationMessage? {
        guard let selectedCommunicationMessageID else {
            return nil
        }
        return selectedCommunicationMessages.first(where: { $0.messageId == selectedCommunicationMessageID })
    }

    private var selectedCommunicationMessageSummary: String {
        guard let selectedCommunicationMessage else {
            return ""
        }
        let body = selectedCommunicationMessage.body.trimmingCharacters(in: .whitespacesAndNewlines)
        return body
    }

    private var preferredCommunicationSessionForQuickOpen: PMCommunicationSession? {
        communicationSessionsForDisplay.first(where: { $0.channel == .inApp })
            ?? communicationSessionsForDisplay.first
    }

    private func selectCommunicationSession(
        _ session: PMCommunicationSession,
        selectLatestMessage: Bool
    ) {
        selectedCommunicationSessionID = session.sessionId
        if selectLatestMessage {
            selectedCommunicationMessageID = latestCommunicationMessageID(for: session.sessionId)
        } else {
            selectedCommunicationMessageID = nil
        }
    }

    private func openLatestCommunicationLog() {
        guard let session = preferredCommunicationSessionForQuickOpen else {
            selectedTab = .commandCenter
            return
        }
        selectCommunicationSession(session, selectLatestMessage: true)
    }

    private func jumpToLatestCommunicationEntry() {
        selectedCommunicationMessageID = selectedCommunicationMessages.last?.messageId
    }

    private func latestCommunicationMessageID(for sessionId: String) -> String? {
        appModel.pmCommunicationMessages
            .filter {
                $0.sessionId == sessionId &&
                isExercisePMCommunicationMessage($0) == false
            }
            .sorted { lhs, rhs in
                if lhs.sentAt == rhs.sentAt {
                    return lhs.messageId < rhs.messageId
                }
                return lhs.sentAt < rhs.sentAt
            }
            .last?
            .messageId
    }

    private func communicationLogBottomAnchorID(for sessionId: String) -> String {
        "pm-communication-log-bottom-\(sessionId)"
    }

    private func scrollCommunicationLogToLatest(
        _ scrollProxy: ScrollViewProxy,
        sessionId: String,
        messageId: String?
    ) {
        let targetID = messageId ?? communicationLogBottomAnchorID(for: sessionId)
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.15)) {
                scrollProxy.scrollTo(targetID, anchor: .bottom)
            }
        }
    }

    private func syncCommunicationSelections() {
        let availableSessionIDs = Array(Set(communicationSessionsForDisplay.map(\.sessionId)))
        self.selectedCommunicationSessionID = makePMInboxRetainedSelection(
            currentSelectionID: selectedCommunicationSessionID,
            availableIDs: availableSessionIDs
        )

        let availableMessageIDs = Array(Set(selectedCommunicationMessages.map(\.messageId)))
        self.selectedCommunicationMessageID = makePMInboxRetainedSelection(
            currentSelectionID: selectedCommunicationMessageID,
            availableIDs: availableMessageIDs
        )
    }

    private func loadCommunicationPromotionDraft() {
        guard let message = selectedCommunicationMessage else {
            communicationPromotionTitle = ""
            communicationPromotionBody = ""
            communicationPromotionCharterID = appModel.analystCharters.first?.charterId ?? ""
            return
        }
        communicationPromotionTitle = pmCommunicationDefaultPromotionTitle(for: message)
        communicationPromotionBody = message.body
        if communicationPromotionCharterID.isEmpty {
            communicationPromotionCharterID = appModel.analystCharters.first?.charterId ?? ""
        }
    }

    private func refreshVisibleReviewProjection() {
        guard shouldMaintainReviewProjection else {
            return
        }
        reviewProjection = makePMInboxReviewProjection(
            approvalRequests: appModel.pmApprovalRequests,
            decisions: appModel.pmDecisions,
            executionRoutingAssessmentsByApprovalRequestID: appModel.pmExecutionRoutingAssessmentsByApprovalRequestID,
            standingReports: appModel.analystStandingReports,
            memos: appModel.analystMemos,
            tasks: appModel.analystTasks,
            charters: appModel.analystCharters,
            delegations: appModel.pmDelegations,
            communicationSessions: appModel.pmCommunicationSessions,
            contextPack: appModel.pmContextPack
        )
        syncCommandCenterSelections()
        syncRecentAnalystActivitySelection()
        syncCommunicationSelections()
    }

    private func beginVisibleSectionWorkIfNeeded() {
        guard isVisible else {
            return
        }
        switch section {
        case .review:
            guard hasLoadedVisibleReviewData == false else {
                refreshVisibleReviewProjection()
                return
            }
            hasLoadedVisibleReviewData = true
            Task { @MainActor in
                feedbackMessage = await appModel.refreshPMInboxReviewData()
                feedbackIsError = feedbackMessage != nil
                refreshVisibleReviewProjection()
            }
        case .proposals, .runs:
            guard hasPrefetchedProposalRuns == false else {
                return
            }
            hasPrefetchedProposalRuns = true
            Task { @MainActor in
                await prefetchProposalRuns()
            }
        default:
            break
        }
    }

    @ViewBuilder
    private var listPane: some View {
        switch section {
        case .review:
            EmptyView()
        case .signals:
            List(filteredSignals, selection: $selectedSignalID) { signal in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(signal.symbols.joined(separator: ", "))
                            .font(.headline)
                        if signal.isAnalystOriginated {
                            AnalystSignalBadge()
                        }
                    }
                    Text(signal.positionStatement)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if let lineage = signal.analystLineage {
                        Text("analyst \(lineage.analystId ?? "-") • charter \(lineage.charterId ?? "-")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text(signal.status.rawValue.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(signalStatusColor(signal.status))
                }
                .padding(.vertical, 4)
                .tag(signal.id)
            }
            .frame(minWidth: 300)

        case .proposals:
            List(filteredProposals, selection: $selectedProposalID) { proposal in
                VStack(alignment: .leading, spacing: 4) {
                    Text(proposal.title)
                        .font(.headline)
                    Text("\(proposal.strategyId) • \(proposal.createdBy)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(proposal.status.rawValue)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(proposalStatusColor(proposal.status))
                }
                .padding(.vertical, 4)
                .tag(proposal.id)
            }
            .frame(minWidth: 300)

        case .runs:
            List(filteredRuns, selection: $selectedRunID) { run in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(run.runType == .replay ? "REPLAY" : "PAPER") • \(shortID(run.runId))")
                        .font(.headline)
                    Text("Proposal \(shortID(run.proposalId)) • \(run.status.rawValue)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(displayDate(run.startedAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .tag(run.runId)
            }
            .frame(minWidth: 320)

        case .analyst:
            List(appModel.analystTasks, selection: $selectedAnalystTaskID) { task in
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title)
                        .font(.headline)
                    Text("\(task.analystId) • \(task.charterId ?? "-")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(task.status.rawValue)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if let checkpoint = task.lastCheckpointSummary, !checkpoint.isEmpty {
                        Text(checkpoint)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(.vertical, 4)
                .tag(task.id)
            }
            .frame(minWidth: 320)
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        switch section {
        case .review:
            reviewDeskDetailView()
        case .signals:
            if let signal = selectedSignal {
                signalDetail(signal)
            } else {
                placeholder("Select a signal to review and take action.")
            }

        case .proposals:
            if let proposal = selectedProposal {
                proposalDetail(proposal)
            } else {
                placeholder("Select a proposal to review.")
            }

        case .runs:
            if let run = selectedRun {
                runDetail(run)
            } else {
                placeholder("Select a run to inspect metrics and export JSON.")
            }
        case .analyst:
            AnalystOperationsDetailView(selectedTaskID: $selectedAnalystTaskID)
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func reviewDeskDetailView() -> some View {
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                OwnerSurfaceSection(title: "PM Review Desk") {
                    Text("This advanced view is for PM and analyst workflow review. It stays separate from the calmer owner-facing Command Center home.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                recentNewsReviewGroup

                OwnerSurfaceSection(
                    title: "Recent Analyst Activity",
                    subtitle: "Latest PM-directed analyst work and recent standing-bench handoffs."
                ) {
                    if recentAnalystActivityItems.isEmpty {
                        Text("No recent analyst activity summaries are available yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(recentAnalystActivityItems) { item in
                                PMInboxRecentAnalystActivityRow(
                                    item: item,
                                    timestampLabel: displayDate(item.timestamp),
                                    isSelected: selectedRecentAnalystActivityID == item.id,
                                    openAction: {
                                        selectedRecentAnalystActivityID = item.id
                                    }
                                )
                            }

                            if let detail = selectedRecentAnalystActivityDetail {
                                pmInboxSelectedDetailSection(
                                    title: "Recent Analyst Activity Detail",
                                    closeAction: { selectedRecentAnalystActivityID = nil }
                                ) {
                                    VStack(alignment: .leading, spacing: 12) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(detail.headline)
                                                .font(.title3.weight(.semibold))
                                            Text("\(detail.analystTitle) • \(detail.activityType) • \(displayDate(selectedRecentAnalystActivityItem?.timestamp ?? Date()))")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }

                                        memoSection("What the analyst concluded", body: detail.conclusion)
                                        memoSection("Why this is showing up now", body: detail.summary)
                                        memoSection("PM treatment", body: detail.pmTreatment)

                                        if let nextStep = detail.nextStep, nextStep.isEmpty == false {
                                            memoSection("Next step", body: nextStep)
                                        }

                                        if let supportingContext = detail.supportingContext, supportingContext.isEmpty == false {
                                            memoSection("Supporting context", body: supportingContext)
                                        }

                                        if let sourceTruth = detail.sourceTruth {
                                            GroupBox("Primary Sources And Support") {
                                                VStack(alignment: .leading, spacing: 8) {
                                                    Text(sourceTruth.summary)
                                                        .font(.footnote)
                                                        .foregroundStyle(.secondary)

                                                    ForEach(sourceTruth.primarySources, id: \.self) { line in
                                                        Text(line)
                                                            .font(.subheadline)
                                                    }

                                                    if let weakSupportSummary = sourceTruth.weakSupportSummary, weakSupportSummary.isEmpty == false {
                                                        Text(weakSupportSummary)
                                                            .font(.footnote)
                                                            .foregroundStyle(.secondary)
                                                    }
                                                }
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                            }
                                        }

                                        GroupBox("Execution Truth") {
                                            VStack(alignment: .leading, spacing: 8) {
                                                OwnerReadableFactLine(
                                                    title: "Requested/Configured:",
                                                    value: detail.executionTruth.requestedOrConfiguredSummary
                                                )
                                                OwnerReadableFactLine(
                                                    title: "Execution Used:",
                                                    value: detail.executionTruth.executionUsedSummary
                                                )
                                                Text(detail.executionTruth.summary)
                                                    .font(.footnote)
                                                    .foregroundStyle(.secondary)
                                            }
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        }

                                        if let memoPresentation = detail.linkedMemoPresentation {
                                            GroupBox("Linked Analyst Memo") {
                                                VStack(alignment: .leading, spacing: 8) {
                                                    Text(memoPresentation.currentView)
                                                        .font(.subheadline)
                                                    Text(memoPresentation.recommendedNextStep)
                                                        .font(.footnote)
                                                        .foregroundStyle(.secondary)
                                                    if let requestedModel = memoPresentation.requestedModelSummary {
                                                        OwnerReadableFactLine(title: "Requested Model:", value: requestedModel)
                                                    }
                                                    if let executionUsed = memoPresentation.executionUsedSummary {
                                                        OwnerReadableFactLine(title: "Execution Used:", value: executionUsed)
                                                    }
                                                }
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                            }
                                        }

                                        if let linkedStandingReportID = detail.linkedStandingReportID {
                                            Button("Open Linked Standing Report Detail") {
                                                selectedRecentAnalystLinkedStandingReportID = linkedStandingReportID
                                            }
                                            .buttonStyle(.bordered)

                                            if selectedRecentAnalystLinkedStandingReportID == linkedStandingReportID,
                                               let linkedStandingReportPresentation = selectedRecentAnalystLinkedStandingReportPresentation {
                                                GroupBox("Linked Standing Report") {
                                                    LinkedStandingAnalystReportDocumentView(
                                                        report: linkedStandingReportPresentation,
                                                        linkedMemoPresentation: detail.linkedMemoPresentation,
                                                        sourceTruth: detail.sourceTruth
                                                    )
                                                }
                                            } else if selectedRecentAnalystLinkedStandingReportID == linkedStandingReportID {
                                                Text("The linked standing report could not be loaded from the current app-owned report store.")
                                                    .font(.footnote)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            } else {
                                pmInboxOpenHint("Select a recent analyst activity row to open its readable summary and PM treatment.")
                            }
                        }
                    }
                }

                approvalRequestReviewGroup

                decisionReviewGroup

                pmWorkingContextGroup

                pmBackgroundReviewSummaryGroup

                pmUserCommunicationGroup

                OwnerSurfaceSection(
                    title: "Manual Intervention",
                    subtitle: "Fallback controls stay separated from the owner-facing desk."
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Direct controls remain available for intervention and fallback. They are intentionally kept behind advanced navigation rather than the owner-facing home.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) {
                                openManualInterventionButton
                                openPortfolioWatchButton
                                openSystemControlButton
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                openManualInterventionButton
                                openPortfolioWatchButton
                                openSystemControlButton
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private func pmInboxOpenHint(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
    }

    private func pmInboxSelectedDetailSection<Content: View>(
        title: String,
        closeAction: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.headline)
                Spacer()
                Button("Close") {
                    closeAction()
                }
                .buttonStyle(.bordered)
            }

            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.45))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
        )
    }

    private var pmWorkingContextGroup: some View {
        OwnerSurfaceSection(
            title: "PM Working Context",
            subtitle: "Broader PM memory, continuity, and workflow grounding stays available here for deeper drill-down."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text("The PM operates from assembled app-owned strategic memory, short-horizon recent-conversation continuity, retrieved interaction memory, shared portfolio truth, and open workflow artifacts. Raw communication logs stay log-only by default and remain source-linked instead of being replayed wholesale.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if let context = appModel.pmContextPack {
                    VStack(alignment: .leading, spacing: 12) {
                        if let profile = context.profile {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(profile.displayName)
                                    .font(.headline)
                                Text(profile.roleSummary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: 16) {
                                pmContextCompactColumn(
                                    title: "Durable Memory",
                                    lines: [
                                        "\(context.mandates.count) mandate\(context.mandates.count == 1 ? "" : "s")",
                                        "\(context.activeInstructions.count) active instruction\(context.activeInstructions.count == 1 ? "" : "s")",
                                        "\(context.recentNotebookEntries.count) recent notebook entr\(context.recentNotebookEntries.count == 1 ? "y" : "ies")",
                                        "\(context.retrievedInteractionMemories.count) retrieved interaction memor\(context.retrievedInteractionMemories.count == 1 ? "y" : "ies")"
                                    ] + context.mandates.prefix(2).map { $0.title }
                                )
                                pmContextCompactColumn(
                                    title: "Shared Truth",
                                    lines: [
                                        "\(context.sharedPortfolioTruth.positionCount) held position\(context.sharedPortfolioTruth.positionCount == 1 ? "" : "s")",
                                        "\(context.sharedPortfolioTruth.watchlistCount) watched symbol\(context.sharedPortfolioTruth.watchlistCount == 1 ? "" : "s")",
                                        context.sharedPortfolioTruth.strategyBrief?.currentRiskPosture.isEmpty == false
                                            ? "Risk posture: \(context.sharedPortfolioTruth.strategyBrief?.currentRiskPosture ?? "-")"
                                            : "Risk posture not set"
                                    ]
                                )
                                pmContextCompactColumn(
                                    title: "Open Workflow",
                                    lines: [
                                        "\(context.openApprovalRequests.count) open approval request\(context.openApprovalRequests.count == 1 ? "" : "s")",
                                        "\(context.recentDecisions.count) recent decision\(context.recentDecisions.count == 1 ? "" : "s")",
                                        "\(context.relevantDelegations.count) active or recent delegation\(context.relevantDelegations.count == 1 ? "" : "s")",
                                        "\(context.recentAnalystMemos.count) relevant analyst memo\(context.recentAnalystMemos.count == 1 ? "" : "s")"
                                    ]
                                )
                            }
                            VStack(alignment: .leading, spacing: 12) {
                                pmContextCompactColumn(
                                    title: "Durable Memory",
                                    lines: [
                                        "\(context.mandates.count) mandate\(context.mandates.count == 1 ? "" : "s")",
                                        "\(context.activeInstructions.count) active instruction\(context.activeInstructions.count == 1 ? "" : "s")",
                                        "\(context.recentNotebookEntries.count) recent notebook entr\(context.recentNotebookEntries.count == 1 ? "y" : "ies")",
                                        "\(context.retrievedInteractionMemories.count) retrieved interaction memor\(context.retrievedInteractionMemories.count == 1 ? "y" : "ies")"
                                    ] + context.mandates.prefix(2).map { $0.title }
                                )
                                pmContextCompactColumn(
                                    title: "Shared Truth",
                                    lines: [
                                        "\(context.sharedPortfolioTruth.positionCount) held position\(context.sharedPortfolioTruth.positionCount == 1 ? "" : "s")",
                                        "\(context.sharedPortfolioTruth.watchlistCount) watched symbol\(context.sharedPortfolioTruth.watchlistCount == 1 ? "" : "s")",
                                        context.sharedPortfolioTruth.strategyBrief?.currentRiskPosture.isEmpty == false
                                            ? "Risk posture: \(context.sharedPortfolioTruth.strategyBrief?.currentRiskPosture ?? "-")"
                                            : "Risk posture not set"
                                    ]
                                )
                                pmContextCompactColumn(
                                    title: "Open Workflow",
                                    lines: [
                                        "\(context.openApprovalRequests.count) open approval request\(context.openApprovalRequests.count == 1 ? "" : "s")",
                                        "\(context.recentDecisions.count) recent decision\(context.recentDecisions.count == 1 ? "" : "s")",
                                        "\(context.relevantDelegations.count) active or recent delegation\(context.relevantDelegations.count == 1 ? "" : "s")",
                                        "\(context.recentAnalystMemos.count) relevant analyst memo\(context.recentAnalystMemos.count == 1 ? "" : "s")"
                                    ]
                                )
                            }
                        }

                        if context.recentConversationContinuity.isEmpty == false {
                            DisclosureGroup("Recent Conversation Continuity") {
                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach(context.recentConversationContinuity) { continuity in
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(
                                                "\(continuity.participantLabel ?? "Recent thread") • \(continuity.messageCount) message\(continuity.messageCount == 1 ? "" : "s")"
                                            )
                                            .font(.subheadline.weight(.semibold))
                                            Text(continuity.continuitySummary)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(4)
                                            if continuity.topicSignals.isEmpty == false {
                                                Text(continuity.topicSignals.joined(separator: " • "))
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                            Text(continuity.continuityReason)
                                                .font(.caption2)
                                                .foregroundStyle(.tertiary)
                                            let sourceLine = pmContextRecentConversationSourceLine(continuity)
                                            if sourceLine.isEmpty == false {
                                                Text(sourceLine)
                                                    .font(.caption2)
                                                    .foregroundStyle(.tertiary)
                                            }
                                        }
                                    }
                                }
                                .padding(.top, 6)
                            }
                        }

                        if context.promotedCommunicationOutcomes.isEmpty == false {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Promoted Communication Outcomes")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                ForEach(context.promotedCommunicationOutcomes.prefix(3)) { outcome in
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("\(outcome.targetTitle) • \(pmPromotionTargetDisplayName(outcome.targetType))")
                                            .font(.subheadline.weight(.semibold))
                                        Text(outcome.targetSummary)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                        Text(outcome.originSummary)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }

                        if context.retrievedInteractionMemories.isEmpty == false {
                            DisclosureGroup("Retrieved Interaction Memory") {
                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach(context.retrievedInteractionMemories.prefix(4)) { memory in
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text("\(memory.title) • \(memory.kind.displayTitle)")
                                                .font(.subheadline.weight(.semibold))
                                            Text(memory.summary)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(3)
                                            if memory.matchedSignals.isEmpty == false {
                                                Text(memory.matchedSignals.joined(separator: " • "))
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                            let sourceLine = pmContextRetrievedMemorySourceLine(memory)
                                            if sourceLine.isEmpty == false {
                                                Text(sourceLine)
                                                    .font(.caption2)
                                                    .foregroundStyle(.tertiary)
                                            }
                                        }
                                    }
                                }
                                .padding(.top, 6)
                            }
                        }

                        DisclosureGroup("Memory Boundaries") {
                            VStack(alignment: .leading, spacing: 8) {
                                pmContextBoundaryBlock(
                                    title: "PM Durable Memory",
                                    lines: context.boundarySummary.durableMemorySources
                                )
                                pmContextBoundaryBlock(
                                    title: "Recent Conversation Continuity",
                                    lines: context.boundarySummary.recentConversationSources
                                )
                                pmContextBoundaryBlock(
                                    title: "Communication Log Only",
                                    lines: context.boundarySummary.communicationLogSources
                                )
                                pmContextBoundaryBlock(
                                    title: "Analyst-Scoped Only",
                                    lines: context.boundarySummary.analystScopedSources
                                )
                                pmContextBoundaryBlock(
                                    title: "Shared Portfolio Truth",
                                    lines: context.boundarySummary.sharedTruthSources
                                )
                                pmContextBoundaryBlock(
                                    title: "Operational Artifacts",
                                    lines: context.boundarySummary.operationalArtifactSources
                                )
                            }
                            .padding(.top, 6)
                        }
                    }
                } else {
                    Text("PM working context has not been assembled yet.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var pmBackgroundReviewNotebookEntries: [PMNotebookEntry] {
        reviewProjection.pmBackgroundReviewNotebookEntries
    }

    private var pmBackgroundReviewSummaryGroup: some View {
        OwnerSurfaceSection(
            title: "Background PM Review Summaries",
            subtitle: "Closed standing-review cycles stay compact and separate from live review work."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Closed standing-review cycles stay here as compact internal summaries. They are not direct PM/User conversation turns.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if pmBackgroundReviewNotebookEntries.isEmpty {
                    Text("No recent closed PM background-review summaries are available.")
                        .foregroundStyle(.secondary)
                } else {
                    DisclosureGroup("Recent closed PM review cycles") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(pmBackgroundReviewNotebookEntries) { entry in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.title)
                                        .font(.subheadline.weight(.semibold))
                                    if let sourceSummary = entry.sourceSummary,
                                       sourceSummary.isEmpty == false {
                                        Text(sourceSummary)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(entry.body)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(6)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                if entry.id != pmBackgroundReviewNotebookEntries.last?.id {
                                    Divider()
                                }
                            }
                        }
                        .padding(.top, 4)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var pmUserCommunicationGroup: some View {
        let reviewPresentation = makePMInboxCommunicationReviewPresentation(
            sessionCount: communicationSessionsForDisplay.count
        )
        let surfaceCoordination = makeOwnerPMSurfaceCoordinationPresentation(
            telegramStatus: appModel.telegramBridgeStatus,
            runtimeSettings: appModel.pmRuntimeSettings
        )

        return OwnerSurfaceSection(
            title: "PM / User Communication Log",
            subtitle: "Communication review stays available here without becoming the primary owner desk."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text(reviewPresentation.summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                pmSurfaceCoordinationView(surfaceCoordination)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Button("Open Latest Communication Log") {
                            openLatestCommunicationLog()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)

                        if selectedCommunicationSession != nil {
                            Button("Jump To Latest Entry") {
                                jumpToLatestCommunicationEntry()
                            }
                            .buttonStyle(.bordered)
                        }

                        Button("Open Command Center") {
                            selectedTab = .commandCenter
                        }
                        .buttonStyle(.bordered)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Button("Open Latest Communication Log") {
                            openLatestCommunicationLog()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)

                        if selectedCommunicationSession != nil {
                            Button("Jump To Latest Entry") {
                                jumpToLatestCommunicationEntry()
                            }
                            .buttonStyle(.bordered)
                        }

                        Button("Open Command Center") {
                            selectedTab = .commandCenter
                        }
                        .buttonStyle(.bordered)
                    }
                }

                telegramTransportStatusGroup

                if communicationSessionsForDisplay.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(reviewPresentation.title)
                            .foregroundStyle(.secondary)
                        Button(reviewPresentation.primaryActionLabel) {
                            selectedTab = .commandCenter
                        }
                        .buttonStyle(.bordered)
                    }
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 12) {
                            pmCommunicationSessionList
                                .frame(maxWidth: 280, alignment: .topLeading)
                            if selectedCommunicationSession != nil {
                                Divider()
                                pmCommunicationDetail
                            }
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            pmCommunicationSessionList
                            pmCommunicationDetail
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func pmSurfaceCoordinationView(
        _ presentation: OwnerPMSurfaceCoordinationPresentation
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            pmReviewDetailLine(title: "Command Center", body: presentation.commandCenterSummary)
            pmReviewDetailLine(title: "Telegram", body: presentation.telegramSummary)
            pmReviewDetailLine(title: "PM Inbox", body: presentation.pmInboxSummary)
            pmReviewDetailLine(title: "PM Runtime", body: presentation.runtimeSummary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.05))
        )
    }

    private func pmReviewDetailLine(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(body)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func pmContextCompactColumn(title: String, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(lines, id: \.self) { line in
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func pmContextBoundaryBlock(title: String, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
            ForEach(lines, id: \.self) { line in
                Text("• \(line)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var telegramTransportStatusGroup: some View {
        GroupBox("Telegram Transport") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Telegram is a remote transport into the same app-owned PM/User communication records. The bridge now accepts inbound Telegram only from the allowlisted owner route, default remote replies stay concise, richer explanation is available on demand, and explicit approval terms still resolve through app-owned PM approval records.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Remote clarification phrases: more detail, summary, what supports this, what is uncertain, how does this fit the strategy, what changed, what happens if I approve, what happens if I decline.")
                    Text("Approval replies should use exactly: Approve, Decline, or More Work.")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                let status = appModel.telegramBridgeStatus
                Text(status.tokenConfigured ? "Bot token available in Keychain." : "Bot token not found in Keychain.")
                    .font(.caption)
                    .foregroundStyle(status.tokenConfigured ? Color.secondary : Color.orange)

                if let chatId = status.allowlistedOwnerChatId {
                    let routeLabel = if let participant = status.allowlistedOwnerParticipantLabel,
                                        participant.isEmpty == false {
                        "\(participant) • chat \(chatId)"
                    } else {
                        "chat \(chatId)"
                    }
                    Text("Allowlisted owner route: \(routeLabel)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else if status.tokenConfigured {
                    Text("No Telegram owner route is allowlisted yet. Inbound Telegram is ignored until an app-owned owner route is established.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if let summary = status.lastPollSummary, summary.isEmpty == false {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Webhook: \(status.lastWebhookPresent ? "present" : "absent") · Pending updates: \(status.lastWebhookPendingUpdateCount.map(String.init) ?? "0")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text("Last requested offset: \(status.lastRequestedOffset.map(String.init) ?? "none") · Highest fetched update: \(status.lastHighestFetchedUpdateId.map(String.init) ?? "none")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if status.lastRecoveryTriggered {
                    Text("Recovery poll used offset \(status.lastRecoveryOffset.map(String.init) ?? "unknown") to recover initial Telegram binding.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if let webhookError = status.lastWebhookLastErrorMessage, webhookError.isEmpty == false {
                    Text("Webhook diagnostic: \(webhookError)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if let lastPollAt = status.lastPollAt {
                    Text("Last poll: \(displayDate(lastPollAt))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if let participant = status.lastBoundParticipantLabel,
                   let chatId = status.lastBoundChatId {
                    Text("Last bound chat: \(participant) • chat \(chatId)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else if status.tokenConfigured {
                    Text("No Telegram chat is currently bound. Send the bot a fresh message, then poll updates to learn the route.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if let outboundSummary = status.lastOutboundSummary, outboundSummary.isEmpty == false {
                    Text(outboundSummary)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if let outboundClass = status.lastOutboundWakeUpClass {
                    let silentText = status.lastOutboundSilent == true ? "silent" : "normal"
                    let reason = status.lastOutboundReason?.isEmpty == false ? " · \(status.lastOutboundReason!)" : ""
                    Text("Last outbound class: \(outboundClass.rawValue) · \(silentText)\(reason)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if status.unauthorizedInboundCount > 0 {
                    let lastUnauthorizedRoute = if let participant = status.lastUnauthorizedParticipantLabel,
                                                   let chatId = status.lastUnauthorizedChatId {
                        "\(participant) • chat \(chatId)"
                    } else if let chatId = status.lastUnauthorizedChatId {
                        "chat \(chatId)"
                    } else {
                        "unknown route"
                    }
                    Text("Unauthorized inbound ignored: \(status.unauthorizedInboundCount) · Last seen: \(lastUnauthorizedRoute)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                HStack(spacing: 8) {
                    Button("Poll Telegram Updates") {
                        Task { @MainActor in
                            if let error = await appModel.pollTelegramBridgeUpdates() {
                                feedbackMessage = error
                                feedbackIsError = true
                            } else {
                                feedbackMessage = "Telegram bridge poll completed."
                                feedbackIsError = false
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)

                    Button("Refresh Transport Status") {
                        Task { @MainActor in
                            _ = await appModel.refreshTelegramBridgeStatus()
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func pmContextRetrievedMemorySourceLine(_ memory: PMRetrievedInteractionMemory) -> String {
        var parts: [String] = []
        if let messageID = memory.sourceCommunicationMessageId {
            parts.append("Message: \(messageID)")
        }
        if let decisionID = memory.sourceDecisionId {
            parts.append("Decision: \(decisionID)")
        }
        if let approvalID = memory.sourceApprovalRequestId {
            parts.append("Approval: \(approvalID)")
        }
        if let briefID = memory.sourceStrategyBriefId {
            parts.append("Brief: \(briefID)")
        }
        if let memoID = memory.sourceAnalystMemoId {
            parts.append("Memo: \(memoID)")
        }
        return parts.joined(separator: " • ")
    }

    private func pmContextRecentConversationSourceLine(_ continuity: PMRecentConversationContinuity) -> String {
        guard continuity.sourceMessageIDs.isEmpty == false else { return "" }
        return "Messages: \(continuity.sourceMessageIDs.prefix(4).joined(separator: " • "))"
    }

    private func pmPromotionTargetDisplayName(_ targetType: PMCommunicationPromotionTargetType) -> String {
        targetType.rawValue
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    private var pmCommunicationSessionList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sessions")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(communicationSessionsForDisplay) { session in
                Button {
                    selectCommunicationSession(session, selectLatestMessage: false)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(session.participantDisplayName ?? "User")
                                .font(.headline)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(pmCommunicationChannelDisplayName(session.channel))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        Text(pmCommunicationSessionSummary(session))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(selectedCommunicationSessionID == session.sessionId ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }

            if selectedCommunicationSession == nil {
                pmInboxOpenHint("Select a communication session to open its durable log and related traceability.")
            }
        }
    }

    private var pmCommunicationDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let session = selectedCommunicationSession {
                pmInboxSelectedDetailSection(
                    title: "Communication Session Detail",
                    closeAction: {
                        selectedCommunicationSessionID = nil
                        selectedCommunicationMessageID = nil
                    }
                ) {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.participantDisplayName ?? "User")
                                .font(.headline)
                            Text("\(pmCommunicationChannelDisplayName(session.channel)) • updated \(displayDate(session.updatedAt))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if selectedCommunicationMessages.isEmpty {
                            Text("No messages recorded for this session yet.")
                                .foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text("Conversation Log")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text("\(selectedCommunicationMessages.count) entries")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }

                                ScrollViewReader { scrollProxy in
                                    ScrollView {
                                        LazyVStack(alignment: .leading, spacing: 8) {
                                            ForEach(selectedCommunicationMessages) { message in
                                                Button {
                                                    selectedCommunicationMessageID = message.messageId
                                                } label: {
                                                    VStack(alignment: .leading, spacing: 4) {
                                                        HStack(alignment: .firstTextBaseline) {
                                                            Text(pmCommunicationSenderDisplayName(message.senderRole))
                                                                .font(.subheadline.weight(.semibold))
                                                                .foregroundStyle(.primary)
                                                            Spacer(minLength: 8)
                                                            Text(displayDate(message.sentAt))
                                                                .font(.caption2)
                                                                .foregroundStyle(.secondary)
                                                        }
                                                        Text(message.body)
                                                            .font(.caption)
                                                            .foregroundStyle(.primary)
                                                            .lineLimit(2)
                                                        if let promotion = message.promotion {
                                                            Text("Promoted to \(pmPromotionTargetDisplayName(promotion.targetType))")
                                                                .font(.caption2.weight(.semibold))
                                                                .foregroundStyle(.green)
                                                        }
                                                    }
                                                    .padding(10)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                                    .background(selectedCommunicationMessageID == message.messageId ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.04))
                                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                                }
                                                .buttonStyle(.plain)
                                                .id(message.messageId)
                                            }

                                            Color.clear
                                                .frame(height: 1)
                                                .id(communicationLogBottomAnchorID(for: session.sessionId))
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .frame(minHeight: 220, maxHeight: 360)
                                    .onAppear {
                                        scrollCommunicationLogToLatest(
                                            scrollProxy,
                                            sessionId: session.sessionId,
                                            messageId: selectedCommunicationMessageID ?? selectedCommunicationMessages.last?.messageId
                                        )
                                    }
                                    .onChange(of: selectedCommunicationSessionID) { selectedSessionID in
                                        guard selectedSessionID == session.sessionId else {
                                            return
                                        }
                                        scrollCommunicationLogToLatest(
                                            scrollProxy,
                                            sessionId: session.sessionId,
                                            messageId: selectedCommunicationMessageID ?? selectedCommunicationMessages.last?.messageId
                                        )
                                    }
                                    .onChange(of: selectedCommunicationMessages.last?.messageId) { latestMessageID in
                                        scrollCommunicationLogToLatest(
                                            scrollProxy,
                                            sessionId: session.sessionId,
                                            messageId: selectedCommunicationMessageID ?? latestMessageID
                                        )
                                    }
                                    .onChange(of: selectedCommunicationMessageID) { selectedMessageID in
                                        guard selectedCommunicationSessionID == session.sessionId else {
                                            return
                                        }
                                        scrollCommunicationLogToLatest(
                                            scrollProxy,
                                            sessionId: session.sessionId,
                                            messageId: selectedMessageID ?? selectedCommunicationMessages.last?.messageId
                                        )
                                    }
                                }

                                if let message = selectedCommunicationMessage {
                                    pmInboxSelectedDetailSection(
                                        title: "Conversation Entry Detail",
                                        closeAction: { selectedCommunicationMessageID = nil }
                                    ) {
                                        VStack(alignment: .leading, spacing: 12) {
                                            VStack(alignment: .leading, spacing: 6) {
                                                Text(pmCommunicationSenderDisplayName(message.senderRole))
                                                    .font(.subheadline.weight(.semibold))
                                                Text(displayDate(message.sentAt))
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                                Text(selectedCommunicationMessageSummary)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                    .fixedSize(horizontal: false, vertical: true)
                                            }

                                            if message.senderRole == .pm {
                                                let executionTruth = makePMInboxPMExecutionTruthPresentation(
                                                    runtimeSettings: appModel.pmRuntimeSettings,
                                                    runtimeProvenance: message.runtimeProvenance
                                                )
                                                GroupBox("Execution Truth") {
                                                    VStack(alignment: .leading, spacing: 8) {
                                                        OwnerReadableFactLine(
                                                            title: "Configured Runtime:",
                                                            value: executionTruth.requestedOrConfiguredSummary
                                                        )
                                                        OwnerReadableFactLine(
                                                            title: "Execution Used:",
                                                            value: executionTruth.executionUsedSummary
                                                        )
                                                        Text(executionTruth.summary)
                                                            .font(.footnote)
                                                            .foregroundStyle(.secondary)
                                                    }
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                                }
                                            }

                                            GroupBox("Promote Communication") {
                                                VStack(alignment: .leading, spacing: 10) {
                                                    Text("Selected message")
                                                        .font(.caption.weight(.semibold))
                                                        .foregroundStyle(.secondary)
                                                    Text(pmCommunicationSenderDisplayName(message.senderRole))
                                                        .font(.subheadline.weight(.semibold))
                                                    Text(message.body)
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)

                                                    if let promotion = message.promotion {
                                                        Text("Already promoted to \(pmPromotionTargetDisplayName(promotion.targetType)).")
                                                            .font(.caption)
                                                            .foregroundStyle(.green)
                                                    } else {
                                                        Picker("Promote To", selection: $communicationPromotionTarget) {
                                                            ForEach(PMCommunicationPromotionTargetType.allCases.filter { $0 != .strategyBrief }, id: \.self) { target in
                                                                Text(pmPromotionTargetDisplayName(target)).tag(target)
                                                            }
                                                        }
                                                        .pickerStyle(.menu)

                                                        if communicationPromotionTarget == .approvalRequest {
                                                            TextField("Approval request subject", text: $communicationPromotionTitle)
                                                                .textFieldStyle(.roundedBorder)
                                                        } else {
                                                            TextField("Title", text: $communicationPromotionTitle)
                                                                .textFieldStyle(.roundedBorder)
                                                        }

                                                        if communicationPromotionTarget == .delegation {
                                                            Picker("Analyst Charter", selection: $communicationPromotionCharterID) {
                                                                ForEach(appModel.analystCharters) { charter in
                                                                    Text(charter.title).tag(charter.charterId)
                                                                }
                                                            }
                                                            .pickerStyle(.menu)
                                                        }

                                                        TextEditor(text: $communicationPromotionBody)
                                                            .frame(minHeight: 72)
                                                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))

                                                        Button("Promote") {
                                                            Task { @MainActor in
                                                                await submitCommunicationPromotion()
                                                            }
                                                        }
                                                        .buttonStyle(.borderedProminent)
                                                        .tint(.blue)
                                                    }
                                                }
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                            }
                                        }
                                    }
                                } else {
                                    pmInboxOpenHint("Select a conversation entry to open its full detail and promotion context.")
                                }
                            }
                        }

                        GroupBox("Command Center Conversation") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Use Command Center for normal owner ↔ PM conversation. PM Inbox keeps the communication log visible for auditability and promotion.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Button("Open Command Center") {
                                    selectedTab = .commandCenter
                                }
                                .buttonStyle(.bordered)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if session.channel == .telegram {
                            GroupBox("Telegram PM Reply") {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("This advanced control sends a PM reply over the bound Telegram chat while still recording the message in app-owned PM communication history.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    TextEditor(text: $telegramReplyBody)
                                        .frame(minHeight: 72)
                                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
                                    Button("Send PM Reply To Telegram") {
                                        Task { @MainActor in
                                            let trimmed = telegramReplyBody.trimmingCharacters(in: .whitespacesAndNewlines)
                                            guard trimmed.isEmpty == false else {
                                                feedbackMessage = "Enter a Telegram reply before sending."
                                                feedbackIsError = true
                                                return
                                            }

                                            if let error = await appModel.sendPMCommunicationMessage(
                                                sessionId: session.sessionId,
                                                senderRole: .pm,
                                                body: trimmed,
                                                replyToMessageId: selectedCommunicationMessage?.messageId
                                            ) {
                                                feedbackMessage = error
                                                feedbackIsError = true
                                            } else {
                                                telegramReplyBody = ""
                                                _ = await appModel.refreshTelegramBridgeStatus()
                                                feedbackMessage = "PM reply sent over Telegram."
                                                feedbackIsError = false
                                            }
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(.blue)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }
        }
    }

    private func pmCommunicationChannelDisplayName(_ channel: PMCommunicationChannel) -> String {
        switch channel {
        case .inApp:
            return "In App"
        case .telegram:
            return "Telegram"
        case .genericRemote:
            return "Remote"
        case .mockTelegram:
            return "Mock Telegram"
        }
    }

    private func pmCommunicationSenderDisplayName(_ senderRole: PMCommunicationSenderRole) -> String {
        switch senderRole {
        case .owner:
            return "User"
        case .pm:
            return "PM"
        case .system:
            return "System"
        }
    }

    private func pmCommunicationSessionSummary(_ session: PMCommunicationSession) -> String {
        let messageCount = appModel.pmCommunicationMessages.filter { $0.sessionId == session.sessionId }.count
        return "\(messageCount) message\(messageCount == 1 ? "" : "s") • \(session.status.rawValue.capitalized)"
    }

    private func pmCommunicationDefaultPromotionTitle(for message: PMCommunicationMessage) -> String {
        let prefix = message.senderRole == .owner ? "Owner" : "PM"
        let snippet = message.body
            .split(separator: "\n")
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Communication"
        return "\(prefix): \(snippet.prefix(60))"
    }

    private func submitCommunicationPromotion() async {
        guard let message = selectedCommunicationMessage else {
            feedbackMessage = "Select a communication message to promote."
            feedbackIsError = true
            return
        }

        let error: String?
        switch communicationPromotionTarget {
        case .notebookEntry:
            error = await appModel.promotePMCommunicationMessageToNotebook(
                messageId: message.messageId,
                title: communicationPromotionTitle,
                body: communicationPromotionBody
            )
        case .instruction:
            error = await appModel.promotePMCommunicationMessageToInstruction(
                messageId: message.messageId,
                title: communicationPromotionTitle,
                body: communicationPromotionBody
            )
        case .decision:
            error = await appModel.promotePMCommunicationMessageToDecision(
                messageId: message.messageId,
                title: communicationPromotionTitle,
                summary: communicationPromotionBody
            )
        case .approvalRequest:
            error = await appModel.promotePMCommunicationMessageToApprovalRequest(
                messageId: message.messageId,
                subject: communicationPromotionTitle,
                rationale: communicationPromotionBody
            )
        case .delegation:
            error = await appModel.promotePMCommunicationMessageToDelegation(
                messageId: message.messageId,
                charterId: communicationPromotionCharterID,
                title: communicationPromotionTitle,
                rationale: communicationPromotionBody
            )
        case .strategyBrief:
            error = "Use Command Center to revise the portfolio strategy brief from conversation."
        }

        feedbackMessage = error
        feedbackIsError = error != nil
        if error == nil {
            communicationPromotionTitle = ""
            communicationPromotionBody = ""
            syncCommunicationSelections()
            loadCommunicationPromotionDraft()
        }
    }

    private var approvalRequestReviewGroup: some View {
        OwnerSurfaceSection(
            title: "Approval Request Review",
            subtitle: "Approval records stay compact until you explicitly open a memo and traceability view."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Review PM-layer approval request records here. Live owner responses stay in Command Center > Your Decisions; PM Inbox remains read-only traceability.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if approvalRequestsForReview.isEmpty {
                    Text("No PM approval requests recorded yet.")
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        approvalRequestList
                        if selectedApprovalRequest != nil {
                            approvalRequestDetail
                        } else {
                            pmInboxOpenHint("Select an approval request to open the PM memo and supporting context.")
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var recentNewsReviewGroup: some View {
        OwnerSurfaceSection(
            title: "Recent News Review",
            subtitle: "High-frequency Recent News Analyst cycles stay together here with PM treatment so the broader analyst lane stays readable."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Review Recent News Analyst wake-ups here as one compact analyst-plus-PM lane. This remains traceability only and does not become an owner action desk.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if recentNewsDecisionsForReview.isEmpty {
                    Text("No recent Recent News Analyst review cycles are visible right now.")
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(recentNewsDecisionsForReview) { decision in
                                let linkedDelegation = linkedDelegation(for: decision)
                                let linkedStandingReport = linkedStandingReport(for: decision)
                                let linkedTask = linkedTask(
                                    for: decision,
                                    linkedStandingReport: linkedStandingReport
                                )
                                let linkedFinding = linkedFinding(
                                    for: decision,
                                    linkedDelegation: linkedDelegation,
                                    linkedStandingReport: linkedStandingReport
                                )
                                let linkedMemo = linkedMemo(
                                    for: decision,
                                    linkedTask: linkedTask,
                                    linkedFinding: linkedFinding,
                                    linkedDelegation: linkedDelegation,
                                    linkedStandingReport: linkedStandingReport
                                )
                                let resolvedEvidenceBundle = linkedEvidenceBundle(
                                    memo: linkedMemo,
                                    finding: linkedFinding
                                )
                                let linkedRequest = linkedApprovalRequest(for: decision)
                                let wakeUp = makeRecentNewsWakeUpPresentation(
                                    decision: decision,
                                    linkedTask: linkedTask,
                                    linkedMemo: linkedMemo,
                                    positions: appModel.positions,
                                    watchlistSymbols: appModel.watchlistSymbols,
                                    strategyBrief: appModel.portfolioStrategyBrief
                                )
                                let closure = makePMRecommendationClosurePresentation(
                                    decision: decision,
                                    linkedApprovalRequest: linkedRequest,
                                    executionAssessment: linkedRequest.flatMap {
                                        $0.lastExecutionRoutingAssessment
                                            ?? appModel.pmExecutionRoutingAssessmentsByApprovalRequestID[$0.approvalRequestId]
                                    }
                                )
                                let analystDetail = makePMInboxRecentNewsReviewDetailPresentation(
                                    decision: decision,
                                    linkedTask: linkedTask,
                                    linkedMemo: linkedMemo,
                                    linkedEvidenceBundle: resolvedEvidenceBundle,
                                    linkedDelegation: linkedDelegation,
                                    positions: appModel.positions,
                                    watchlistSymbols: appModel.watchlistSymbols,
                                    strategyBrief: appModel.portfolioStrategyBrief,
                                    linkedStandingReport: linkedStandingReport,
                                    rssFeeds: appModel.rssFeeds
                                )
                                let summary = makePMInboxRecentNewsReviewSummaryPresentation(
                                    detail: analystDetail,
                                    pmTreatmentSummary: closure.pmInboxSummary,
                                    affectedNames: wakeUp.rowAffectedNames,
                                    nextStep: wakeUp.rowNextStep
                                )
                                PMInboxRecentNewsReviewRow(
                                    decision: decision,
                                    timestampLabel: displayDate(decision.updatedAt),
                                    analystSummary: summary.analystSummary,
                                    analystSupport: summary.analystSupportSummary,
                                    analystRuntimeSummary: summary.analystRuntimeSummary,
                                    pmTreatment: summary.pmTreatmentSummary,
                                    affectedNames: summary.affectedNames,
                                    nextStep: summary.nextStep,
                                    isSelected: selectedDecisionID == decision.decisionId,
                                    openAction: {
                                        selectedDecisionID = decision.decisionId
                                    }
                                )
                            }
                        }

                        if let selectedDecision,
                           recentNewsDecisionsForReview.contains(where: { $0.decisionId == selectedDecision.decisionId }) {
                            decisionDetail
                        } else {
                            pmInboxOpenHint("Select a recent-news review row to open the PM memo and linked analyst context.")
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var decisionReviewGroup: some View {
        OwnerSurfaceSection(
            title: "Recent PM Decisions",
            subtitle: "Decision summaries stay compact until you explicitly open the PM memo and follow-through detail."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Review PM conclusions and recommendations alongside their linked context. PM decisions remain distinct from proposal approval and trading authority.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if recentDecisionsForReview.isEmpty {
                    Text(
                        recentAnalystActivityItems.isEmpty
                            ? "No PM decisions recorded yet."
                            : "No PM decision artifact was recorded for the current recent analyst cycle."
                    )
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        decisionList
                        if let selectedDecision,
                           recentNewsDecisionsForReview.contains(where: { $0.decisionId == selectedDecision.decisionId }) == false {
                            decisionDetail
                        } else {
                            pmInboxOpenHint("Select a PM decision to open its recommendation memo and traceability.")
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var approvalRequestList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(pendingApprovalRequests.isEmpty ? "Recent Requests" : "Owner-Actionable Requests")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(approvalRequestsForReview) { request in
                let linkedDecision = appModel.pmDecisions.first(where: { $0.decisionId == request.decisionId })
                let executionAssessment = request.lastExecutionRoutingAssessment
                    ?? appModel.pmExecutionRoutingAssessmentsByApprovalRequestID[request.approvalRequestId]
                let memo = makePMApprovalRequestMemoPresentation(
                    request: request,
                    linkedDecision: linkedDecision,
                    executionAssessment: executionAssessment
                )
                let closure = makePMRecommendationClosurePresentation(
                    request: request,
                    linkedDecision: linkedDecision,
                    executionAssessment: executionAssessment
                )
                Button {
                    selectedApprovalRequestID = request.approvalRequestId
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(request.subject)
                                .font(.headline)
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                            Spacer(minLength: 8)
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(pmInboxApprovalStatusLabel(request: request, closure: closure))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(
                                        closure.status == .backgroundPMReview
                                            ? recommendationClosureColor(closure.status)
                                            : approvalRequestStatusColor(request.status)
                                    )
                                Text(closure.title)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(recommendationClosureColor(closure.status))
                            }
                        }
                        Text(request.rationale)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        if !memo.requestedAction.isEmpty {
                            Text(memo.requestedAction)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        if let ownerResponse = request.ownerResponse {
                            Text("Owner response: \(ownerResponseLabel(ownerResponse))")
                                .font(.caption2)
                                .foregroundStyle(ownerResponseColor(ownerResponse))
                        }
                        Text(closure.pmInboxSummary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(selectedApprovalRequestID == request.approvalRequestId ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var approvalRequestDetail: some View {
        if let request = selectedApprovalRequest {
            let linkedDecision = appModel.pmDecisions.first(where: { $0.decisionId == request.decisionId })
            let ownerRoutingPresentation = makePMInboxApprovalRoutingPresentation(
                request: request,
                linkedDecision: linkedDecision,
                telegramParticipantDisplayName: preferredTelegramCommunicationSession?.participantDisplayName ?? "Telegram chat"
            )
            let linkedDelegation = appModel.pmDelegations.first(where: { $0.delegationId == request.delegationId })
            let linkedTask = appModel.analystTasks.first(where: { $0.taskId == linkedDelegation?.taskId })
            let linkedFinding = appModel.analystFindings.first(where: { $0.findingId == request.findingId || $0.findingId == linkedDelegation?.linkedFindingIDs.last })
            let linkedCommunicationMessage = linkedCommunicationMessage(for: request)
            let linkedMemo = appModel.analystMemos.first(where: { $0.memoId == request.sourceAnalystMemoId })
                ?? latestAnalystMemo(
                    in: appModel.analystMemos,
                    delegationID: linkedDelegation?.delegationId ?? request.delegationId,
                    taskID: linkedTask?.taskId,
                    findingID: linkedFinding?.findingId ?? request.findingId
                )
            let resolvedEvidenceBundle = linkedEvidenceBundle(
                memo: linkedMemo,
                finding: linkedFinding
            )
            let linkedStrategyImplication = appModel.analystStrategyImplications.first(where: {
                $0.implicationId == request.sourceAnalystStrategyImplicationId
            }) ?? linkedAnalystStrategyImplication(
                in: appModel.analystStrategyImplications,
                memo: linkedMemo,
                finding: linkedFinding,
                delegation: linkedDelegation
            )
            let linkedDelegationSummary = linkedDelegation.map { delegation in
                makePMDelegationObservabilitySummary(
                    delegation: delegation,
                    charterDefaultRuntimePolicy: appModel.analystCharters.first(where: { $0.charterId == delegation.charterId })?.defaultRuntimePolicy,
                    task: appModel.analystTasks.first(where: { $0.taskId == delegation.taskId })
                )
            }
            let executionAssessment = request.lastExecutionRoutingAssessment
                ?? appModel.pmExecutionRoutingAssessmentsByApprovalRequestID[request.approvalRequestId]
            let memo = makePMApprovalRequestMemoPresentation(
                request: request,
                linkedDecision: linkedDecision,
                executionAssessment: executionAssessment,
                linkedDelegation: linkedDelegation,
                linkedDelegationObservability: linkedDelegationSummary,
                linkedTask: linkedTask,
                linkedFinding: linkedFinding,
                linkedCommunicationMessage: linkedCommunicationMessage,
                linkedMemo: linkedMemo,
                strategyBrief: appModel.portfolioStrategyBrief
            )
            let executionPresentation = executionAssessment.map(makePMExecutionRoutingPresentation)

            pmInboxSelectedDetailSection(
                title: "Approval Request Detail",
                closeAction: { selectedApprovalRequestID = nil }
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(request.subject)
                        .font(.title3.weight(.semibold))

                    HStack(spacing: 8) {
                        PMDelegationStatusBadge(label: pmApprovalRequestTypeDisplayTitle(request.requestType), color: .blue)
                        PMDelegationStatusBadge(
                            label: pmInboxApprovalStatusLabel(request: request, closure: memo.closure),
                            color: memo.closure.status == .backgroundPMReview
                                ? recommendationClosureColor(memo.closure.status)
                                : approvalRequestStatusColor(request.status)
                        )
                        PMDelegationStatusBadge(
                            label: memo.closure.title,
                            color: recommendationClosureColor(memo.closure.status)
                        )
                        if let ownerResponse = request.ownerResponse {
                            PMDelegationStatusBadge(
                                label: ownerResponseLabel(ownerResponse),
                                color: ownerResponseColor(ownerResponse)
                            )
                        }
                    }

                    if isClearablePMApprovalRequest(request) {
                        Button("Clear From Decisions") {
                            acknowledgeOwnerDecision(request: request)
                        }
                        .buttonStyle(.bordered)
                        .disabled(inFlight)
                    } else if request.ownerAcknowledgedAt != nil {
                        Text("Cleared from active decisions; durable approval and order history remain available here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    memoSection("What happened", body: firstNonEmptyPMInboxText([
                        memo.coherence.pmInboxSummary,
                        request.rationale
                    ]) ?? request.rationale)

                    memoSection("Why this matters now", body: memo.whyNow)

                    memoSection("What the PM recommends", body: firstNonEmptyPMInboxText([
                        memo.recommendation,
                        memo.requestedAction,
                        memo.initiativeSummary
                    ]) ?? memo.requestedAction)

                    memoSection("What this means for you", body: firstNonEmptyPMInboxText([
                        memo.ownerActionMeaning,
                        memo.boundaryNote
                    ]) ?? memo.boundaryNote)

                    memoSection("What happens next", body: approvalRequestReadableNextStep(memo))

                    if let supportingContext = pmInboxSupportingContextSummary([
                        ("Strategy", memo.strategicAlignment),
                        ("Portfolio", memo.portfolioContextSummary),
                        ("Support", memo.evidenceSummary),
                        ("Open questions", memo.uncertaintySummary)
                    ]) {
                        memoSection("Supporting context", body: supportingContext)
                    }

                    supportingDetailsButton(isExpanded: $approvalRequestSupportingDetailsExpanded)

                    if approvalRequestSupportingDetailsExpanded {
                        if !memo.supportingSections.isEmpty {
                            GroupBox("Supporting Traceability") {
                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach(memo.supportingSections) { section in
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(section.title)
                                                .font(.subheadline.weight(.semibold))
                                            Text(section.body)
                                                .foregroundStyle(.secondary)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        if section.id != memo.supportingSections.last?.id {
                                            Divider()
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }

                        if let linkedMemo {
                            AnalystMemoSupportGroup(
                                memo: linkedMemo,
                                linkedFinding: linkedFinding,
                                linkedEvidenceBundle: resolvedEvidenceBundle,
                                linkedSourceAccessSuggestions: linkedAnalystSourceAccessSuggestions(
                                    in: appModel.analystSourceAccessSuggestions,
                                    memo: linkedMemo,
                                    finding: linkedFinding,
                                    evidenceBundle: resolvedEvidenceBundle,
                                    delegation: linkedDelegation
                                ),
                                linkedStrategyImplication: linkedStrategyImplication,
                                linkedStrategyFollowUpCandidates: linkedAnalystStrategyFollowUpCandidates(
                                    in: appModel.analystStrategyFollowUpCandidates,
                                    implication: linkedStrategyImplication
                                ),
                                defaultStrategyImplicationPMID: preferredStrategyImplicationPMID(
                                    memo: linkedMemo,
                                    delegation: linkedDelegation,
                                    fallbackPMID: request.pmId,
                                    contextPMID: appModel.pmContextPack?.pmId,
                                    pmProfiles: appModel.pmProfiles
                                ),
                                onSaveStrategyImplication: appModel.upsertAnalystStrategyImplication,
                                onSaveStrategyFollowUpCandidate: appModel.upsertAnalystStrategyFollowUpCandidate
                            )
                        }

                        GroupBox(pmInboxOwnerMeaningSectionTitle(closure: memo.closure)) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(memo.ownerActionMeaning)
                                Text(memo.boundaryNote)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if let executionAssessment,
                           let executionPresentation {
                            GroupBox("Execution Readiness") {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack(spacing: 8) {
                                        PMDelegationStatusBadge(
                                            label: executionPresentation.statusTitle,
                                            color: executionRoutingStatusColor(executionAssessment.status)
                                        )
                                        Text(executionAssessment.environment == .paper ? "Paper" : "Live")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                    }

                                    Text(executionPresentation.summary)
                                        .font(.subheadline.weight(.semibold))

                                    Text(executionPresentation.detail)
                                        .foregroundStyle(.secondary)

                                    if executionPresentation.blockedReasonLines.isEmpty == false {
                                        Divider()
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text("Current Constraints")
                                                .font(.subheadline.weight(.semibold))
                                            ForEach(executionPresentation.blockedReasonLines, id: \.self) { line in
                                                Text(line)
                                                    .font(.footnote)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    }

                                    Text(executionPresentation.boundaryNote)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)

                                    Button("Refresh Readiness") {
                                        refreshPMExecutionRoutingAssessment(requestID: request.approvalRequestId)
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(inFlight)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }

                        if let proposalID = request.proposalId {
                            GroupBox("Linked Proposal Context") {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("This PM-layer request is linked to proposal \(shortID(proposalID)). Any proposal approval or paper execution step still stays behind the existing proposal workflow.")
                                    Button("Open Proposal \(shortID(proposalID))") {
                                        selectedProposalID = proposalID
                                    }
                                    .buttonStyle(.bordered)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }

                        GroupBox("Owner Routing") {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(ownerRoutingPresentation.summary)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                if let transportSummary = ownerRoutingPresentation.transportSummary {
                                    Text(transportSummary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if request.status != .pending || request.ownerResponse != nil {
                                    Text(ownerResponseText(request))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        technicalDetailsButton(isExpanded: $approvalRequestDetailsExpanded)

                        if approvalRequestDetailsExpanded {
                            approvalRequestTechnicalDetails(
                                request: request,
                                linkedDecision: linkedDecision,
                                linkedDelegation: linkedDelegation,
                                linkedTask: linkedTask,
                                linkedFinding: linkedFinding
                            )
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .task(id: request.approvalRequestId) {
                _ = await appModel.refreshPMExecutionRoutingAssessment(
                    approvalRequestID: request.approvalRequestId
                )
            }
        } else {
            Text("Select an approval request to review the PM memo, supporting context, and owner-routing traceability.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var decisionList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent Decisions")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(recentDecisionsForReview) { decision in
                let linkedTask = linkedTask(for: decision)
                let linkedMemo = linkedMemo(for: decision, linkedTask: linkedTask)
                let linkedRequest = linkedApprovalRequest(for: decision)
                let correlation = makePMInboxDecisionCorrelationPresentation(
                    decision: decision,
                    recentAnalystActivityItems: recentAnalystActivityScopeItems,
                    reports: appModel.analystStandingReports,
                    memos: appModel.analystMemos,
                    delegations: appModel.pmDelegations
                )
                let closure = makePMRecommendationClosurePresentation(
                    decision: decision,
                    linkedApprovalRequest: linkedRequest,
                    executionAssessment: linkedRequest.flatMap {
                        $0.lastExecutionRoutingAssessment
                            ?? appModel.pmExecutionRoutingAssessmentsByApprovalRequestID[$0.approvalRequestId]
                    },
                    linkedDelegationObservability: linkedDelegationObservability(for: linkedDelegation(for: decision))
                )
                let recentNewsWakeUp = makeRecentNewsWakeUpPresentation(
                    decision: decision,
                    linkedTask: linkedTask,
                    linkedMemo: linkedMemo,
                    positions: appModel.positions,
                    watchlistSymbols: appModel.watchlistSymbols,
                    strategyBrief: appModel.portfolioStrategyBrief
                )
                let portfolioRiskWakeUp = makePortfolioRiskWakeUpPresentation(
                    decision: decision,
                    linkedTask: linkedTask,
                    linkedMemo: linkedMemo,
                    positions: appModel.positions,
                    watchlistSymbols: appModel.watchlistSymbols,
                    strategyBrief: appModel.portfolioStrategyBrief
                )
                Button {
                    selectedDecisionID = decision.decisionId
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(decision.title)
                                .font(.headline)
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                            Spacer(minLength: 8)
                            if portfolioRiskWakeUp.isPortfolioRiskWakeUp {
                                PortfolioRiskWakeUpBadge()
                            } else if recentNewsWakeUp.isRecentNewsWakeUp {
                                RecentNewsWakeUpBadge()
                            }
                            Text(pmDecisionStatusDisplayTitle(decision.status))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(decision.status == .active ? .blue : .secondary)
                            if linkedRequest != nil {
                                Text(closure.title)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(recommendationClosureColor(closure.status))
                            }
                        }
                        Text(portfolioRiskWakeUp.isPortfolioRiskWakeUp ? portfolioRiskWakeUp.rowSummary : recentNewsWakeUp.rowSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        if let recommendedAction = decision.recommendedAction {
                            Text(recommendedAction)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        if let affected = portfolioRiskWakeUp.isPortfolioRiskWakeUp ? portfolioRiskWakeUp.rowAffectedNames : recentNewsWakeUp.rowAffectedNames {
                            Text(affected)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        if let nextStep = portfolioRiskWakeUp.isPortfolioRiskWakeUp ? portfolioRiskWakeUp.rowNextStep : recentNewsWakeUp.rowNextStep {
                            Text(nextStep)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        if linkedRequest != nil {
                            Text(closure.pmInboxSummary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Text("Updated \(displayDate(correlation.decisionTimestamp))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if let relatedDescription = correlation.relatedActivityDescription,
                           let relatedTimestamp = correlation.relatedActivityTimestamp {
                            Text("\(relatedDescription) from \(displayDate(relatedTimestamp))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(selectedDecisionID == decision.decisionId ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var decisionDetail: some View {
        if let decision = selectedDecision {
            let linkedDelegation = linkedDelegation(for: decision)
            let linkedStandingReport = linkedStandingReport(for: decision)
            let linkedRequest = linkedApprovalRequest(for: decision)
            let linkedTask = linkedTask(for: decision, linkedStandingReport: linkedStandingReport)
            let linkedFinding = linkedFinding(
                for: decision,
                linkedDelegation: linkedDelegation,
                linkedStandingReport: linkedStandingReport
            )
            let linkedCommunicationMessage = linkedCommunicationMessage(for: decision)
            let linkedMemo = linkedMemo(
                for: decision,
                linkedTask: linkedTask,
                linkedFinding: linkedFinding,
                linkedDelegation: linkedDelegation,
                linkedStandingReport: linkedStandingReport
            )
            let resolvedEvidenceBundle = linkedEvidenceBundle(
                memo: linkedMemo,
                finding: linkedFinding
            )
            let linkedStrategyImplication = linkedAnalystStrategyImplication(
                in: appModel.analystStrategyImplications,
                memo: linkedMemo,
                finding: linkedFinding,
                delegation: linkedDelegation
            )
            let linkedDelegationSummary = linkedDelegationObservability(for: linkedDelegation)
            let memo = makePMDecisionMemoPresentation(
                decision: decision,
                linkedApprovalRequest: linkedRequest,
                executionAssessment: linkedRequest.flatMap {
                    $0.lastExecutionRoutingAssessment
                        ?? appModel.pmExecutionRoutingAssessmentsByApprovalRequestID[$0.approvalRequestId]
                },
                linkedDelegation: linkedDelegation,
                linkedDelegationObservability: linkedDelegationSummary,
                linkedTask: linkedTask,
                linkedFinding: linkedFinding,
                linkedCommunicationMessage: linkedCommunicationMessage,
                linkedMemo: linkedMemo,
                strategyBrief: appModel.portfolioStrategyBrief
            )
            let recentNewsWakeUp = makeRecentNewsWakeUpPresentation(
                decision: decision,
                linkedTask: linkedTask,
                linkedMemo: linkedMemo,
                positions: appModel.positions,
                watchlistSymbols: appModel.watchlistSymbols,
                strategyBrief: appModel.portfolioStrategyBrief
            )
            let portfolioRiskWakeUp = makePortfolioRiskWakeUpPresentation(
                decision: decision,
                linkedTask: linkedTask,
                linkedMemo: linkedMemo,
                positions: appModel.positions,
                watchlistSymbols: appModel.watchlistSymbols,
                strategyBrief: appModel.portfolioStrategyBrief
            )
            let recentNewsReviewDetail = makePMInboxRecentNewsReviewDetailPresentation(
                decision: decision,
                linkedTask: linkedTask,
                linkedMemo: linkedMemo,
                linkedEvidenceBundle: resolvedEvidenceBundle,
                linkedDelegation: linkedDelegation,
                positions: appModel.positions,
                watchlistSymbols: appModel.watchlistSymbols,
                strategyBrief: appModel.portfolioStrategyBrief,
                linkedStandingReport: linkedStandingReport,
                rssFeeds: appModel.rssFeeds
            )
            let correlation = makePMInboxDecisionCorrelationPresentation(
                decision: decision,
                recentAnalystActivityItems: recentAnalystActivityScopeItems,
                reports: appModel.analystStandingReports,
                memos: appModel.analystMemos,
                delegations: appModel.pmDelegations
            )
            let thresholdPresentation = makePMInboxOwnerReachThresholdPresentation(
                memo: memo
            )
            let pmExecutionTruth = makePMInboxPMExecutionTruthPresentation(
                runtimeSettings: appModel.pmRuntimeSettings,
                runtimeProvenance: decision.runtimeProvenance
            )
            let pmActionSummary = firstNonEmptyPMInboxText([
                memo.closure.pmInboxSummary,
                memo.recommendation,
                decision.recommendedAction,
                decision.summary
            ]) ?? decision.summary

            pmInboxSelectedDetailSection(
                title: recentNewsWakeUp.isRecentNewsWakeUp ? "Recent News Review Detail" : "PM Decision Detail",
                closeAction: { selectedDecisionID = nil }
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(decision.title)
                        .font(.title3.weight(.semibold))

                    HStack(spacing: 8) {
                        if portfolioRiskWakeUp.isPortfolioRiskWakeUp {
                            PortfolioRiskWakeUpBadge()
                        } else if recentNewsWakeUp.isRecentNewsWakeUp {
                            RecentNewsWakeUpBadge()
                        }
                        PMDelegationStatusBadge(label: pmDecisionTypeDisplayTitle(decision.decisionType), color: .blue)
                        PMDelegationStatusBadge(label: pmDecisionStatusDisplayTitle(decision.status), color: decision.status == .active ? .green : .secondary)
                        PMDelegationStatusBadge(label: memo.closure.title, color: recommendationClosureColor(memo.closure.status))
                    }

                    if recentNewsWakeUp.isRecentNewsWakeUp {
                        GroupBox("Brief Combined Summary") {
                            VStack(alignment: .leading, spacing: 12) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Analyst")
                                        .font(.subheadline.weight(.semibold))
                                    Text(recentNewsReviewDetail.analystFindingSummary)
                                        .font(.body)
                                    if recentNewsReviewDetail.analystMaterialDevelopments.isEmpty == false {
                                        OwnerReadableFactLine(
                                            title: "Material news:",
                                            value: recentNewsReviewDetail.analystMaterialDevelopments.joined(separator: " | ")
                                        )
                                    }
                                    if let materialSourceSummary = recentNewsReviewDetail.analystMaterialSourceSummary {
                                        OwnerReadableFactLine(
                                            title: "Support:",
                                            value: materialSourceSummary
                                        )
                                    }
                                    if recentNewsReviewDetail.analystSupplementalSourcesReviewed.isEmpty == false {
                                        OwnerReadableFactLine(
                                            title: "Supplemental sources checked:",
                                            value: recentNewsReviewDetail.analystSupplementalSourcesReviewed.joined(separator: ", ")
                                        )
                                    }
                                    OwnerReadableFactLine(
                                        title: "Analyst runtime:",
                                        value: recentNewsReviewDetail.executionTruth.executionUsedSummary
                                    )
                                }

                                Divider()

                                VStack(alignment: .leading, spacing: 8) {
                                    Text("PM")
                                        .font(.subheadline.weight(.semibold))
                                    OwnerReadableFactLine(
                                        title: "PM action:",
                                        value: pmActionSummary
                                    )
                                    OwnerReadableFactLine(
                                        title: "PM runtime:",
                                        value: pmExecutionTruth.executionUsedSummary
                                    )
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        GroupBox("Time and analyst context") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Decision recorded \(displayDate(correlation.decisionTimestamp)).")
                                if let relatedDescription = correlation.relatedActivityDescription,
                                   let relatedTimestamp = correlation.relatedActivityTimestamp {
                                    Text("\(relatedDescription) from \(displayDate(relatedTimestamp)).")
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("No directly linked recent analyst activity is available in the current bounded PM Inbox projection.")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        GroupBox("PM owner-reach threshold") {
                            VStack(alignment: .leading, spacing: 8) {
                                OwnerReadableFactLine(
                                    title: "Current threshold:",
                                    value: thresholdPresentation.thresholdTitle
                                )
                                OwnerReadableFactLine(
                                    title: "Initiative posture:",
                                    value: thresholdPresentation.initiativeTitle
                                )
                                OwnerReadableFactLine(
                                    title: "Routing:",
                                    value: thresholdPresentation.routingTitle
                                )
                                Text(thresholdPresentation.thresholdSummary)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                Text(thresholdPresentation.initiativeSummary)
                                    .font(.footnote)
                                Text(thresholdPresentation.routingSummary)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        memoSection("What the PM concluded", body: firstNonEmptyPMInboxText([
                            memo.recommendation,
                            decision.recommendedAction,
                            portfolioRiskWakeUp.isPortfolioRiskWakeUp ? portfolioRiskWakeUp.recommendedNextStep : nil,
                            recentNewsWakeUp.isRecentNewsWakeUp ? recentNewsWakeUp.recommendedNextStep : nil,
                            decision.summary
                        ]) ?? decision.summary)

                        memoSection("Why", body: decisionReadableWhy(
                            memo: memo,
                            recentNewsWakeUp: recentNewsWakeUp,
                            portfolioRiskWakeUp: portfolioRiskWakeUp
                        ))

                        memoSection("Why now", body: decisionReadableWhyNow(
                            memo: memo,
                            recentNewsWakeUp: recentNewsWakeUp,
                            portfolioRiskWakeUp: portfolioRiskWakeUp
                        ))

                        memoSection("What this means", body: decisionReadableMeaning(
                            memo: memo,
                            recentNewsWakeUp: recentNewsWakeUp,
                            portfolioRiskWakeUp: portfolioRiskWakeUp
                        ))

                        memoSection("Next step / status", body: decisionReadableNextStep(
                            memo: memo,
                            linkedRequest: linkedRequest,
                            recentNewsWakeUp: recentNewsWakeUp,
                            portfolioRiskWakeUp: portfolioRiskWakeUp
                        ))

                        if let supportingContext = pmInboxSupportingContextSummary([
                            ("Strategy", memo.strategicAlignment),
                            ("Support", memo.evidenceSummary),
                            ("Open questions", memo.uncertaintySummary),
                            ("Owner ask", memo.ownerAsk)
                        ]) {
                            memoSection("Supporting context", body: supportingContext)
                        }

                        GroupBox("Execution Truth") {
                            VStack(alignment: .leading, spacing: 8) {
                                OwnerReadableFactLine(
                                    title: "Configured Runtime:",
                                    value: pmExecutionTruth.requestedOrConfiguredSummary
                                )
                                OwnerReadableFactLine(
                                    title: "Execution Used:",
                                    value: pmExecutionTruth.executionUsedSummary
                                )
                                Text(pmExecutionTruth.summary)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                if let linkedMemo {
                                    let linkedMemoPresentation = makeAnalystMemoReadablePresentation(linkedMemo)
                                    if let requestedModel = linkedMemoPresentation.requestedModelSummary {
                                        OwnerReadableFactLine(title: "Linked Analyst Requested Model:", value: requestedModel)
                                    }
                                    if let executionUsed = linkedMemoPresentation.executionUsedSummary {
                                        OwnerReadableFactLine(title: "Linked Analyst Execution Used:", value: executionUsed)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    technicalDetailsButton(isExpanded: $decisionDetailsExpanded)

                    if decisionDetailsExpanded {
                        if recentNewsWakeUp.isRecentNewsWakeUp {
                            GroupBox("Time and analyst context") {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Decision recorded \(displayDate(correlation.decisionTimestamp)).")
                                    if let relatedDescription = correlation.relatedActivityDescription,
                                       let relatedTimestamp = correlation.relatedActivityTimestamp {
                                        Text("\(relatedDescription) from \(displayDate(relatedTimestamp)).")
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Text("No directly linked recent analyst activity is available in the current bounded PM Inbox projection.")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            GroupBox("PM owner-reach threshold") {
                                VStack(alignment: .leading, spacing: 8) {
                                    OwnerReadableFactLine(
                                        title: "Current threshold:",
                                        value: thresholdPresentation.thresholdTitle
                                    )
                                    OwnerReadableFactLine(
                                        title: "Initiative posture:",
                                        value: thresholdPresentation.initiativeTitle
                                    )
                                    OwnerReadableFactLine(
                                        title: "Routing:",
                                        value: thresholdPresentation.routingTitle
                                    )
                                    Text(thresholdPresentation.thresholdSummary)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                    Text(thresholdPresentation.initiativeSummary)
                                        .font(.footnote)
                                    Text(thresholdPresentation.routingSummary)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            GroupBox("Recent News Analyst Run") {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(recentNewsReviewDetail.analystFindingSummary)
                                        .font(.body)
                                    OwnerReadableFactLine(
                                        title: "Why it mattered:",
                                        value: recentNewsReviewDetail.analystWhyItMatters
                                    )
                                    OwnerReadableFactLine(
                                        title: "Current view:",
                                        value: recentNewsReviewDetail.analystCurrentView
                                    )
                                    OwnerReadableFactLine(
                                        title: "Recommended next step:",
                                        value: recentNewsReviewDetail.analystRecommendedNextStep
                                    )
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            GroupBox("Material Sources And Support") {
                                VStack(alignment: .leading, spacing: 8) {
                                    if recentNewsReviewDetail.analystMaterialDevelopments.isEmpty == false {
                                        OwnerReadableFactLine(
                                            title: "Material news:",
                                            value: recentNewsReviewDetail.analystMaterialDevelopments.joined(separator: " | ")
                                        )
                                    }
                                    if let sourceTruth = recentNewsReviewDetail.sourceTruth {
                                        Text(sourceTruth.summary)
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                        ForEach(sourceTruth.primarySources, id: \.self) { line in
                                            Text(line)
                                                .font(.subheadline)
                                        }
                                        if recentNewsReviewDetail.analystSupplementalSourcesReviewed.isEmpty == false {
                                            OwnerReadableFactLine(
                                                title: "Supplemental sources checked:",
                                                value: recentNewsReviewDetail.analystSupplementalSourcesReviewed.joined(separator: ", ")
                                            )
                                        }
                                        if let weakSupportSummary = sourceTruth.weakSupportSummary,
                                           weakSupportSummary.isEmpty == false {
                                            Text(weakSupportSummary)
                                                .font(.footnote)
                                                .foregroundStyle(.secondary)
                                        }
                                    } else {
                                        Text("No durable analyst source refs were attached to this recent-news cycle.")
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            memoSection("What the PM concluded", body: firstNonEmptyPMInboxText([
                                memo.recommendation,
                                decision.recommendedAction,
                                recentNewsWakeUp.recommendedNextStep,
                                decision.summary
                            ]) ?? decision.summary)

                            memoSection("Why", body: decisionReadableWhy(
                                memo: memo,
                                recentNewsWakeUp: recentNewsWakeUp,
                                portfolioRiskWakeUp: portfolioRiskWakeUp
                            ))

                            memoSection("Why now", body: decisionReadableWhyNow(
                                memo: memo,
                                recentNewsWakeUp: recentNewsWakeUp,
                                portfolioRiskWakeUp: portfolioRiskWakeUp
                            ))

                            memoSection("What this means", body: decisionReadableMeaning(
                                memo: memo,
                                recentNewsWakeUp: recentNewsWakeUp,
                                portfolioRiskWakeUp: portfolioRiskWakeUp
                            ))

                            memoSection("Next step / status", body: decisionReadableNextStep(
                                memo: memo,
                                linkedRequest: linkedRequest,
                                recentNewsWakeUp: recentNewsWakeUp,
                                portfolioRiskWakeUp: portfolioRiskWakeUp
                            ))

                            if let supportingContext = pmInboxSupportingContextSummary([
                                ("Strategy", memo.strategicAlignment),
                                ("Support", memo.evidenceSummary),
                                ("Open questions", memo.uncertaintySummary),
                                ("Owner ask", memo.ownerAsk)
                            ]) {
                                memoSection("Supporting context", body: supportingContext)
                            }

                            GroupBox("Execution Truth") {
                                VStack(alignment: .leading, spacing: 8) {
                                    OwnerReadableFactLine(
                                        title: "Configured Runtime:",
                                        value: pmExecutionTruth.requestedOrConfiguredSummary
                                    )
                                    OwnerReadableFactLine(
                                        title: "Execution Used:",
                                        value: pmExecutionTruth.executionUsedSummary
                                    )
                                    Text(pmExecutionTruth.summary)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                    if let linkedMemo {
                                        let linkedMemoPresentation = makeAnalystMemoReadablePresentation(linkedMemo)
                                        if let requestedModel = linkedMemoPresentation.requestedModelSummary {
                                            OwnerReadableFactLine(title: "Linked Analyst Requested Model:", value: requestedModel)
                                        }
                                        if let executionUsed = linkedMemoPresentation.executionUsedSummary {
                                            OwnerReadableFactLine(title: "Linked Analyst Execution Used:", value: executionUsed)
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            GroupBox("Recent News Analyst Runtime") {
                                VStack(alignment: .leading, spacing: 8) {
                                    OwnerReadableFactLine(
                                        title: "Configured Runtime:",
                                        value: recentNewsReviewDetail.executionTruth.requestedOrConfiguredSummary
                                    )
                                    OwnerReadableFactLine(
                                        title: "Execution Used:",
                                        value: recentNewsReviewDetail.executionTruth.executionUsedSummary
                                    )
                                    Text(recentNewsReviewDetail.executionTruth.summary)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                    if let uncertainty = recentNewsReviewDetail.analystUncertaintySummary {
                                        Divider()
                                        Text("Bounded uncertainty / caveats")
                                            .font(.subheadline.weight(.semibold))
                                        Text(uncertainty)
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }

                        if portfolioRiskWakeUp.isPortfolioRiskWakeUp,
                           (portfolioRiskWakeUp.affectedHoldings.isEmpty == false || portfolioRiskWakeUp.affectedWatchlistOnly.isEmpty == false) {
                            RecentNewsAffectedNamesGroup(
                                affectedHoldings: portfolioRiskWakeUp.affectedHoldings,
                                affectedWatchlistOnly: portfolioRiskWakeUp.affectedWatchlistOnly
                            )
                        } else if recentNewsWakeUp.isRecentNewsWakeUp,
                                  (recentNewsReviewDetail.affectedHoldings.isEmpty == false || recentNewsReviewDetail.affectedWatchlistOnly.isEmpty == false) {
                            RecentNewsAffectedNamesGroup(
                                affectedHoldings: recentNewsReviewDetail.affectedHoldings,
                                affectedWatchlistOnly: recentNewsReviewDetail.affectedWatchlistOnly
                            )
                        }

                        if !memo.supportingSections.isEmpty {
                            GroupBox("Supporting Traceability") {
                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach(memo.supportingSections) { section in
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(section.title)
                                                .font(.subheadline.weight(.semibold))
                                            Text(section.body)
                                                .foregroundStyle(.secondary)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        if section.id != memo.supportingSections.last?.id {
                                            Divider()
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }

                        if let linkedMemo {
                            AnalystMemoSupportGroup(
                                memo: linkedMemo,
                                linkedFinding: linkedFinding,
                                linkedEvidenceBundle: resolvedEvidenceBundle,
                                linkedSourceAccessSuggestions: linkedAnalystSourceAccessSuggestions(
                                    in: appModel.analystSourceAccessSuggestions,
                                    memo: linkedMemo,
                                    finding: linkedFinding,
                                    evidenceBundle: resolvedEvidenceBundle,
                                    delegation: linkedDelegation
                                ),
                                linkedStrategyImplication: linkedStrategyImplication,
                                linkedStrategyFollowUpCandidates: linkedAnalystStrategyFollowUpCandidates(
                                    in: appModel.analystStrategyFollowUpCandidates,
                                    implication: linkedStrategyImplication
                                ),
                                defaultStrategyImplicationPMID: preferredStrategyImplicationPMID(
                                    memo: linkedMemo,
                                    delegation: linkedDelegation,
                                    fallbackPMID: decision.pmId,
                                    contextPMID: appModel.pmContextPack?.pmId,
                                    pmProfiles: appModel.pmProfiles
                                ),
                                onSaveStrategyImplication: appModel.upsertAnalystStrategyImplication,
                                onSaveStrategyFollowUpCandidate: appModel.upsertAnalystStrategyFollowUpCandidate
                            )
                        }

                        GroupBox("Action Path") {
                            VStack(alignment: .leading, spacing: 8) {
                                if let linkedRequest {
                                    Text("This recommendation already has an approval-ready PM ask on record.")
                                    Button("Open Linked Approval Request") {
                                        selectedApprovalRequestID = linkedRequest.approvalRequestId
                                    }
                                    .buttonStyle(.bordered)
                                } else {
                                    Text("Turn this PM recommendation into an approval-ready ask for the User. This records PM-layer intent only and does not approve any proposal or trade.")
                                    Button("Create Approval-Ready Ask") {
                                        createApprovalRequest(from: decision)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(inFlight || decision.status != .active)
                                }

                                if let proposalID = decision.proposalId {
                                    Divider()
                                    Text("Linked proposal context remains behind the existing separate proposal workflow.")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                    Button("Open Proposal \(shortID(proposalID))") {
                                        selectedProposalID = proposalID
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        decisionTechnicalDetails(
                            decision: decision,
                            linkedRequest: linkedRequest,
                            linkedDelegation: linkedDelegation,
                            linkedTask: linkedTask,
                            linkedFinding: linkedFinding
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text("Select a PM decision to review the recommendation memo and supporting context.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func linkedDelegation(for decision: PMDecisionRecord) -> PMDelegationRecord? {
        appModel.pmDelegations.first(where: { $0.delegationId == decision.delegationId })
    }

    private func linkedStandingReport(for decision: PMDecisionRecord) -> AnalystStandingReport? {
        let explicitlyLinkedIDs = Set(standingReportIDs(for: decision))
        if explicitlyLinkedIDs.isEmpty == false {
            return appModel.analystStandingReports
                .filter { explicitlyLinkedIDs.contains($0.reportId) }
                .max { lhs, rhs in
                    if lhs.updatedAt == rhs.updatedAt {
                        return lhs.reportId > rhs.reportId
                    }
                    return lhs.updatedAt < rhs.updatedAt
                }
        }

        if let decisionTaskID = decision.taskId {
            let memoIDsForTask = Set(
                appModel.analystMemos
                    .filter { $0.taskId == decisionTaskID }
                    .map(\.memoId)
            )
            if memoIDsForTask.isEmpty == false {
                return appModel.analystStandingReports
                    .filter { memoIDsForTask.contains($0.memoId) }
                    .max { lhs, rhs in
                        if lhs.updatedAt == rhs.updatedAt {
                            return lhs.reportId > rhs.reportId
                        }
                        return lhs.updatedAt < rhs.updatedAt
                    }
            }
        }

        return nil
    }

    private func linkedApprovalRequest(for decision: PMDecisionRecord) -> PMApprovalRequest? {
        appModel.pmApprovalRequests.first(where: { $0.decisionId == decision.decisionId })
    }

    private func linkedCommunicationMessage(for decision: PMDecisionRecord) -> PMCommunicationMessage? {
        if let messageID = decision.sourceCommunicationMessageId {
            return appModel.pmCommunicationMessages.first(where: { $0.messageId == messageID })
        }
        return appModel.pmCommunicationMessages.first(where: {
            $0.promotion?.targetType == .decision && $0.promotion?.targetId == decision.decisionId
        })
    }

    private func linkedCommunicationMessage(for request: PMApprovalRequest) -> PMCommunicationMessage? {
        if let messageID = request.sourceCommunicationMessageId {
            return appModel.pmCommunicationMessages.first(where: { $0.messageId == messageID })
        }
        return appModel.pmCommunicationMessages.first(where: {
            $0.promotion?.targetType == .approvalRequest && $0.promotion?.targetId == request.approvalRequestId
        })
    }

    private func linkedTask(
        for decision: PMDecisionRecord,
        linkedStandingReport: AnalystStandingReport? = nil
    ) -> AnalystTask? {
        let linkedDelegation = linkedDelegation(for: decision)
        let standingReport = linkedStandingReport ?? self.linkedStandingReport(for: decision)
        let reportMemo = standingReport.flatMap { report in
            appModel.analystMemos.first(where: { $0.memoId == report.memoId })
        }
        return appModel.analystTasks.first(where: {
            $0.taskId == decision.taskId
                || $0.taskId == linkedDelegation?.taskId
                || $0.taskId == reportMemo?.taskId
        })
    }

    private func linkedFinding(
        for decision: PMDecisionRecord,
        linkedDelegation: PMDelegationRecord?,
        linkedStandingReport: AnalystStandingReport? = nil
    ) -> AnalystFinding? {
        let standingReport = linkedStandingReport ?? self.linkedStandingReport(for: decision)
        let reportMemo = standingReport.flatMap { report in
            appModel.analystMemos.first(where: { $0.memoId == report.memoId })
        }
        return appModel.analystFindings.first(where: {
            $0.findingId == decision.findingId
                || $0.findingId == linkedDelegation?.linkedFindingIDs.last
                || $0.findingId == reportMemo?.findingId
        })
    }

    private func linkedMemo(
        for decision: PMDecisionRecord,
        linkedTask: AnalystTask?,
        linkedFinding: AnalystFinding? = nil,
        linkedDelegation: PMDelegationRecord? = nil,
        linkedStandingReport: AnalystStandingReport? = nil
    ) -> AnalystMemo? {
        let standingReport = linkedStandingReport ?? self.linkedStandingReport(for: decision)
        if let standingReport,
           let reportMemo = appModel.analystMemos.first(where: { $0.memoId == standingReport.memoId }) {
            return reportMemo
        }

        return latestAnalystMemo(
            in: appModel.analystMemos,
            delegationID: linkedDelegation?.delegationId ?? decision.delegationId,
            taskID: linkedTask?.taskId ?? decision.taskId,
            findingID: linkedFinding?.findingId ?? decision.findingId
        )
    }

    private func linkedEvidenceBundle(
        memo: AnalystMemo?,
        finding: AnalystFinding?
    ) -> AnalystEvidenceBundle? {
        let bundleID = memo?.evidenceBundleId ?? finding?.evidenceBundleId
        guard let bundleID else {
            return nil
        }
        return appModel.analystEvidenceBundles.first(where: { $0.bundleId == bundleID })
    }

    private func linkedDelegationObservability(
        for delegation: PMDelegationRecord?
    ) -> PMDelegationObservabilitySummary? {
        delegation.map { delegation in
            makePMDelegationObservabilitySummary(
                delegation: delegation,
                charterDefaultRuntimePolicy: appModel.analystCharters.first(where: { $0.charterId == delegation.charterId })?.defaultRuntimePolicy,
                task: appModel.analystTasks.first(where: { $0.taskId == delegation.taskId })
            )
        }
    }

    @ViewBuilder
    private func ownerReviewButton(
        _ title: String,
        response: PMApprovalRequestOwnerResponse,
        color: Color,
        request: PMApprovalRequest
    ) -> some View {
        if response == .approved {
            Button(title) {
                applyOwnerReview(response, to: request)
            }
            .buttonStyle(.borderedProminent)
            .tint(color)
            .disabled(inFlight || request.status != .pending)
        } else {
            Button(title) {
                applyOwnerReview(response, to: request)
            }
            .buttonStyle(.bordered)
            .tint(color)
            .disabled(inFlight || request.status != .pending)
        }
    }

    @ViewBuilder
    private func delegationLinkedContextGroup(_ delegation: PMDelegationRecord) -> some View {
        let charter = appModel.analystCharters.first(where: { $0.charterId == delegation.charterId })
        let task = appModel.analystTasks.first(where: { $0.taskId == delegation.taskId })
        let memo = latestAnalystMemo(
            in: appModel.analystMemos,
            delegationID: delegation.delegationId,
            taskID: task?.taskId,
            findingID: delegation.linkedFindingIDs.last ?? task?.checkpoint?.linkedFindingIDs.last
        )
        let linkedFinding = appModel.analystFindings.first(where: {
            $0.findingId == delegation.linkedFindingIDs.last || $0.findingId == task?.checkpoint?.linkedFindingIDs.last
        })
        let resolvedEvidenceBundle = linkedEvidenceBundle(
            memo: memo,
            finding: linkedFinding
        )
        let linkedStrategyImplication = linkedAnalystStrategyImplication(
            in: appModel.analystStrategyImplications,
            memo: memo,
            finding: linkedFinding,
            delegation: delegation
        )
        let summary = makePMDelegationObservabilitySummary(
            delegation: delegation,
            charterDefaultRuntimePolicy: charter?.defaultRuntimePolicy,
            task: task
        )
        DelegationContextGroup(
            delegation: delegation,
            charterTitle: charter?.title,
            taskTitle: task?.title,
            latestOutputSummary: latestDelegationOutputText(delegation, task: task),
            observability: summary,
            memo: memo,
            linkedFinding: linkedFinding,
            linkedEvidenceBundle: resolvedEvidenceBundle,
            linkedSourceAccessSuggestions: linkedAnalystSourceAccessSuggestions(
                in: appModel.analystSourceAccessSuggestions,
                memo: memo,
                finding: linkedFinding,
                evidenceBundle: resolvedEvidenceBundle,
                delegation: delegation
            ),
            linkedStrategyImplication: linkedStrategyImplication,
            linkedStrategyFollowUpCandidates: linkedAnalystStrategyFollowUpCandidates(
                in: appModel.analystStrategyFollowUpCandidates,
                implication: linkedStrategyImplication
            ),
            defaultStrategyImplicationPMID: preferredStrategyImplicationPMID(
                memo: memo,
                delegation: delegation,
                fallbackPMID: nil,
                contextPMID: appModel.pmContextPack?.pmId,
                pmProfiles: appModel.pmProfiles
            ),
            onSaveStrategyImplication: appModel.upsertAnalystStrategyImplication,
            onSaveStrategyFollowUpCandidate: appModel.upsertAnalystStrategyFollowUpCandidate
        )
    }

    private func memoSection(_ title: String, body: String) -> some View {
        GroupBox(title) {
            Text(body)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func supportingDetailsButton(
        isExpanded: Binding<Bool>,
        label: String = "Supporting Details"
    ) -> some View {
        Button {
            isExpanded.wrappedValue.toggle()
        } label: {
            Label(
                isExpanded.wrappedValue ? "Hide \(label)" : "Open \(label)",
                systemImage: isExpanded.wrappedValue ? "chevron.up.circle" : "chevron.right.circle"
            )
            .font(.callout.weight(.semibold))
        }
        .buttonStyle(.bordered)
    }

    private func approvalRequestReadableNextStep(_ memo: PMApprovalRequestMemoPresentation) -> String {
        if memo.closure.ownerPending {
            return firstNonEmptyPMInboxText([
                memo.approvedNextStep,
                memo.reviewedNextStep,
                memo.rejectedNextStep,
                memo.closure.pmInboxSummary
            ]) ?? memo.closure.pmInboxSummary
        }
        return firstNonEmptyPMInboxText([
            memo.closure.pmInboxSummary,
            memo.approvedNextStep,
            memo.reviewedNextStep,
            memo.rejectedNextStep
        ]) ?? "No further owner action is needed right now."
    }

    private func decisionReadableWhy(
        memo: PMDecisionMemoPresentation,
        recentNewsWakeUp: RecentNewsWakeUpPresentation,
        portfolioRiskWakeUp: PortfolioRiskWakeUpPresentation
    ) -> String {
        if portfolioRiskWakeUp.isPortfolioRiskWakeUp {
            return firstNonEmptyPMInboxText([
                portfolioRiskWakeUp.whatChanged,
                portfolioRiskWakeUp.whatHappened,
                memo.coherence.pmInboxSummary
            ]) ?? memo.coherence.pmInboxSummary
        }
        if recentNewsWakeUp.isRecentNewsWakeUp {
            return firstNonEmptyPMInboxText([
                recentNewsWakeUp.whyItMatters,
                recentNewsWakeUp.whatHappened,
                memo.coherence.pmInboxSummary
            ]) ?? memo.coherence.pmInboxSummary
        }
        return firstNonEmptyPMInboxText([
            memo.coherence.pmInboxSummary,
            memo.evidenceSummary
        ]) ?? memo.coherence.pmInboxSummary
    }

    private func decisionReadableWhyNow(
        memo: PMDecisionMemoPresentation,
        recentNewsWakeUp: RecentNewsWakeUpPresentation,
        portfolioRiskWakeUp: PortfolioRiskWakeUpPresentation
    ) -> String {
        if portfolioRiskWakeUp.isPortfolioRiskWakeUp {
            return firstNonEmptyPMInboxText([
                portfolioRiskWakeUp.whyItMattersNow,
                memo.whyNow
            ]) ?? memo.whyNow
        }
        if recentNewsWakeUp.isRecentNewsWakeUp {
            return firstNonEmptyPMInboxText([
                recentNewsWakeUp.strategyRelevance,
                recentNewsWakeUp.whyItMatters,
                memo.whyNow
            ]) ?? memo.whyNow
        }
        return memo.whyNow
    }

    private func decisionReadableMeaning(
        memo: PMDecisionMemoPresentation,
        recentNewsWakeUp: RecentNewsWakeUpPresentation,
        portfolioRiskWakeUp: PortfolioRiskWakeUpPresentation
    ) -> String {
        firstNonEmptyPMInboxText([
            memo.relationshipNote,
            portfolioRiskWakeUp.isPortfolioRiskWakeUp ? portfolioRiskWakeUp.pmActionGuidance : nil,
            recentNewsWakeUp.isRecentNewsWakeUp ? recentNewsWakeUp.pmActionGuidance : nil,
            memo.boundaryNote
        ]) ?? memo.boundaryNote
    }

    private func decisionReadableNextStep(
        memo: PMDecisionMemoPresentation,
        linkedRequest: PMApprovalRequest?,
        recentNewsWakeUp: RecentNewsWakeUpPresentation,
        portfolioRiskWakeUp: PortfolioRiskWakeUpPresentation
    ) -> String {
        firstNonEmptyPMInboxText([
            linkedRequest.map { _ in "A linked approval-ready PM ask is already on record for this recommendation." },
            portfolioRiskWakeUp.isPortfolioRiskWakeUp ? portfolioRiskWakeUp.recommendedNextStep : nil,
            recentNewsWakeUp.isRecentNewsWakeUp ? recentNewsWakeUp.recommendedNextStep : nil,
            memo.ownerAsk,
            memo.approvedNextStep,
            memo.closure.pmInboxSummary
        ]) ?? memo.closure.pmInboxSummary
    }

    private func technicalDetailsButton(isExpanded: Binding<Bool>) -> some View {
        Button {
            isExpanded.wrappedValue.toggle()
        } label: {
            Label(
                isExpanded.wrappedValue ? "Hide Details" : "Open Details",
                systemImage: isExpanded.wrappedValue ? "chevron.up.circle" : "chevron.right.circle"
            )
            .font(.callout.weight(.semibold))
        }
        .buttonStyle(.bordered)
    }

    private func approvalRequestTechnicalDetails(
        request: PMApprovalRequest,
        linkedDecision: PMDecisionRecord?,
        linkedDelegation: PMDelegationRecord?,
        linkedTask: AnalystTask?,
        linkedFinding: AnalystFinding?
    ) -> some View {
        GroupBox("Technical Details") {
            VStack(alignment: .leading, spacing: 12) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow { Text("PM"); Text(request.pmId) }
                    GridRow { Text("Created"); Text(formattedDate(request.createdAt)) }
                    GridRow { Text("Updated"); Text(formattedDate(request.updatedAt)) }
                    GridRow { Text("Decision"); Text(linkedDecision?.title ?? request.decisionId ?? "-") }
                    GridRow { Text("Delegation"); Text(linkedDelegation?.title ?? request.delegationId ?? "-") }
                    GridRow { Text("Finding"); Text(linkedFinding?.title ?? request.findingId ?? "-") }
                    GridRow { Text("Signal"); Text(request.signalId ?? "-") }
                    GridRow { Text("Proposal"); Text(request.proposalId ?? "-") }
                    GridRow { Text("Strategy Candidate"); Text(request.sourceAnalystStrategyFollowUpCandidateId ?? "-") }
                    GridRow { Text("Strategy Implication"); Text(request.sourceAnalystStrategyImplicationId ?? "-") }
                    GridRow { Text("Memo"); Text(request.sourceAnalystMemoId ?? "-") }
                    GridRow { Text("Evidence Bundle"); Text(request.sourceAnalystEvidenceBundleId ?? "-") }
                    GridRow { Text("Resulting Brief"); Text(request.resultingStrategyBriefId ?? "-") }
                    GridRow { Text("Communication"); Text(linkedCommunicationMessage(for: request)?.messageId ?? request.sourceCommunicationMessageId ?? "-") }
                    GridRow { Text("Owner Response"); Text(ownerResponseText(request)) }
                }
                if let linkedDelegation {
                    delegationLinkedContextGroup(linkedDelegation)
                } else if let linkedTask {
                    GroupBox("Linked Task Details") {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                            GridRow { Text("Task"); Text(linkedTask.title) }
                            GridRow { Text("Task Status"); Text(linkedTask.status.rawValue) }
                            GridRow { Text("Task Updated"); Text(formattedDate(linkedTask.updatedAt)) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func decisionTechnicalDetails(
        decision: PMDecisionRecord,
        linkedRequest: PMApprovalRequest?,
        linkedDelegation: PMDelegationRecord?,
        linkedTask: AnalystTask?,
        linkedFinding: AnalystFinding?
    ) -> some View {
        GroupBox("Technical Details") {
            VStack(alignment: .leading, spacing: 12) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow { Text("PM"); Text(decision.pmId) }
                    GridRow { Text("Created"); Text(formattedDate(decision.createdAt)) }
                    GridRow { Text("Updated"); Text(formattedDate(decision.updatedAt)) }
                    GridRow { Text("Delegation"); Text(linkedDelegation?.title ?? decision.delegationId ?? "-") }
                    GridRow { Text("Charter"); Text(decision.charterId ?? "-") }
                    GridRow { Text("Task"); Text(linkedTask?.title ?? decision.taskId ?? "-") }
                    GridRow { Text("Finding"); Text(linkedFinding?.title ?? decision.findingId ?? "-") }
                    GridRow { Text("Signal"); Text(decision.signalId ?? "-") }
                    GridRow { Text("Proposal"); Text(decision.proposalId ?? "-") }
                    GridRow { Text("Communication"); Text(linkedCommunicationMessage(for: decision)?.messageId ?? decision.sourceCommunicationMessageId ?? "-") }
                    GridRow { Text("Related Request"); Text(linkedRequest?.subject ?? "-") }
                }
                if let linkedDelegation {
                    delegationLinkedContextGroup(linkedDelegation)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func isClearablePMApprovalRequest(_ request: PMApprovalRequest) -> Bool {
        isPMApprovalRequestClearableFromActiveDecisions(request)
    }

    private func acknowledgeOwnerDecision(request: PMApprovalRequest) {
        inFlight = true
        feedbackMessage = nil
        Task { @MainActor in
            defer { inFlight = false }
            let error = await appModel.acknowledgePMApprovalRequest(
                requestID: request.approvalRequestId
            )
            if let error {
                feedbackMessage = error
                feedbackIsError = true
            } else {
                feedbackMessage = "Cleared the completed review from active decisions."
                feedbackIsError = false
                syncCommandCenterSelections()
            }
        }
    }

    private func applyOwnerReview(_ response: PMApprovalRequestOwnerResponse, to request: PMApprovalRequest) {
        inFlight = true
        feedbackMessage = nil
        Task { @MainActor in
            defer { inFlight = false }
            let error = await appModel.respondToPMApprovalRequest(
                requestID: request.approvalRequestId,
                response: response
            )
            if let error {
                feedbackMessage = error
                feedbackIsError = true
            } else {
                feedbackMessage = "Recorded owner review: \(ownerResponseLabel(response))."
                feedbackIsError = false
                syncCommandCenterSelections()
            }
        }
    }

    private func refreshPMExecutionRoutingAssessment(requestID: String) {
        inFlight = true
        feedbackMessage = nil
        Task { @MainActor in
            defer { inFlight = false }
            let error = await appModel.refreshPMExecutionRoutingAssessment(
                approvalRequestID: requestID
            )
            if let error {
                feedbackMessage = error
                feedbackIsError = true
            } else {
                feedbackMessage = "Refreshed PM execution readiness."
                feedbackIsError = false
            }
        }
    }

    private func routePMExecutionApprovedIntent(requestID: String) {
        inFlight = true
        feedbackMessage = nil
        Task { @MainActor in
            defer { inFlight = false }
            let error = await appModel.routePMExecutionApprovedIntent(
                approvalRequestID: requestID
            )
            if let error {
                feedbackMessage = error
                feedbackIsError = true
            } else {
                if let proposalID = appModel.pmExecutionRoutingAssessmentsByApprovalRequestID[requestID]?.proposalId {
                    selectedProposalID = proposalID
                }
                feedbackMessage = "Routed the approved PM next step through the existing governed path."
                feedbackIsError = false
            }
        }
    }

    private func createApprovalRequest(from decision: PMDecisionRecord) {
        inFlight = true
        feedbackMessage = nil
        Task { @MainActor in
            defer { inFlight = false }
            let error = await appModel.createPMApprovalRequestFromDecision(decisionID: decision.decisionId)
            if let error {
                feedbackMessage = error
                feedbackIsError = true
            } else {
                selectedApprovalRequestID = appModel.pmApprovalRequests.first(where: {
                    $0.decisionId == decision.decisionId && $0.status == .pending
                })?.approvalRequestId
                feedbackMessage = "Created approval-ready PM ask from the selected recommendation."
                feedbackIsError = false
                syncCommandCenterSelections()
            }
        }
    }

    private func ownerResponseText(_ request: PMApprovalRequest) -> String {
        guard let response = request.ownerResponse else {
            return request.status == .pending ? "Pending owner review" : "No owner response recorded"
        }
        let timestamp = request.ownerRespondedAt.map(formattedDate) ?? "-"
        return "\(ownerResponseLabel(response)) at \(timestamp)"
    }

    private func executionRoutingStatusColor(_ status: PMExecutionRoutingStatus) -> Color {
        switch status {
        case .executableNowPaper, .executableNowLive, .routedSuccessfully:
            return .green
        case .blockedMissingProposalApproval,
             .blockedEnvironmentMismatch,
             .blockedExecutionPrerequisites,
             .partiallyRouted:
            return .orange
        case .blockedLiveNotArmed, .blockedKillSwitch, .launchFailed, .invalidState:
            return .red
        }
    }

    private func proposalStatusDisplayTitle(_ status: StrategyProposalStatus) -> String {
        switch status {
        case .draft:
            return "Draft"
        case .proposed:
            return "Proposed"
        case .approvedPaper:
            return "Approved for Paper"
        case .deniedPaper:
            return "Denied for Paper"
        }
    }

    private func liveExecutionPostureSummary(assessment: PMExecutionRoutingAssessment) -> String {
        guard assessment.environment == .live else {
            return "Paper mode active"
        }
        if assessment.killSwitchEnabled {
            return "Live selected • kill switch ON"
        }
        return assessment.isLiveArmed ? "Live selected • armed" : "Live selected • disarmed"
    }

    private func ownerResponseLabel(_ response: PMApprovalRequestOwnerResponse) -> String {
        switch response {
        case .approved:
            return "Approved"
        case .rejected:
            return "Rejected"
        case .reviewed:
            return "More Work Requested"
        }
    }

    private func ownerResponseColor(_ response: PMApprovalRequestOwnerResponse) -> Color {
        switch response {
        case .approved:
            return .green
        case .rejected:
            return .red
        case .reviewed:
            return .secondary
        }
    }

    private func approvalRequestStatusColor(_ status: PMApprovalRequestStatus) -> Color {
        switch status {
        case .pending:
            return .orange
        case .resolved:
            return .green
        case .withdrawn, .stale:
            return .secondary
        }
    }

    private func latestDelegationOutputText(_ delegation: PMDelegationRecord, task: AnalystTask?) -> String {
        if let proposalID = delegation.linkedProposalIDs.last {
            return "Proposal \(proposalID)"
        }
        if let signalID = delegation.linkedSignalIDs.last {
            return "Signal \(signalID)"
        }
        if let findingID = delegation.linkedFindingIDs.last ?? task?.checkpoint?.linkedFindingIDs.last {
            return "Finding \(findingID)"
        }
        if task?.checkpoint != nil {
            return "Checkpoint updated"
        }
        return "No downstream outputs yet"
    }

    private var openManualInterventionButton: some View {
        Button("Open Manual Orders") {
            selectedTab = .orderTicket
        }
        .buttonStyle(.bordered)
    }

    private var openPortfolioWatchButton: some View {
        Button("Open Portfolio Watch") {
            selectedTab = .marketWatch
        }
        .buttonStyle(.bordered)
    }

    private var openSystemControlButton: some View {
        Button("Open System Control") {
            selectedTab = .systemControl
        }
        .buttonStyle(.bordered)
    }

    private func attentionRow(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func commandCenterDelegationRow(_ delegation: PMDelegationRecord) -> some View {
        let charter = appModel.analystCharters.first(where: { $0.charterId == delegation.charterId })
        let task = appModel.analystTasks.first(where: { $0.taskId == delegation.taskId })
        let summary = makePMDelegationObservabilitySummary(
            delegation: delegation,
            charterDefaultRuntimePolicy: charter?.defaultRuntimePolicy,
            task: task
        )
        let presentation = makePMDelegationReadablePresentation(
            delegation: delegation,
            charterTitle: charter?.title,
            taskTitle: task?.title,
            observability: summary,
            latestOutputSummary: latestDelegationOutputText(delegation, task: task)
        )

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(delegation.title)
                    .font(.headline)
                Spacer()
                PMDelegationStatusBadge(label: summary.launchHealth.rawValue, color: launchHealthColor(summary.launchHealth))
                PMDelegationStatusBadge(label: summary.executionState.rawValue, color: executionStateColor(summary.executionState))
            }
            Text(presentation.subheadline)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text(presentation.outcomeSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            OwnerReadableFactLine(title: "Execution State:", value: summary.executionState.rawValue)
            OwnerReadableFactLine(title: "Execution Used:", value: presentation.executionUsedSummary)
            OwnerReadableFactLine(title: "Latest Output:", value: presentation.latestOutputSummary)
            HStack(spacing: 8) {
                Button("Open Analyst Detail") {
                    section = .analyst
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private func runtimePolicyText(_ policy: AnalystRuntimePolicy?) -> String {
        analystRequestedRuntimeText(policy)
    }

    private func actualRuntimeText(_ provenance: AnalystRuntimeProvenance?) -> String {
        analystActualRuntimeText(provenance)
    }

    private func launchHealthColor(_ health: PMDelegationLaunchHealth) -> Color {
        switch health {
        case .notLaunched:
            return .secondary
        case .healthy:
            return .green
        case .degradedExternalEvidence:
            return .orange
        case .failed:
            return .red
        }
    }

    private func executionStateColor(_ state: PMDelegationExecutionState) -> Color {
        pmExecutionStateColor(state)
    }

    private func workflowStateColor(_ state: PMDelegationWorkflowState) -> Color {
        switch state {
        case .noOutputsYet:
            return .secondary
        case .awaitingDownstreamReview:
            return .blue
        case .resolved:
            return .green
        case .canceled:
            return .red
        }
    }

    private func formattedDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    private func signalDetail(_ signal: Signal) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(signal.positionStatement)
                    .font(.title3)

                if let presentation = signalLineagePresentation(signal) {
                    AnalystSignalBadge()
                    AnalystSignalLineageSection(presentation: presentation)
                }

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow { Text("Signal"); Text(shortID(signal.signalId)).font(.system(.body, design: .monospaced)) }
                    GridRow { Text("Status"); Text(signal.status.rawValue).foregroundStyle(signalStatusColor(signal.status)) }
                    GridRow { Text("Symbols"); Text(signal.symbols.joined(separator: ", ")) }
                    GridRow { Text("Score"); Text(percent(signal.score)) }
                    GridRow { Text("Confidence"); Text(percent(signal.confidence)) }
                    GridRow { Text("Actionability"); Text(signal.actionability.displayTitle) }
                    GridRow { Text("Recommended"); Text(signal.recommendedAction.rawValue) }
                    GridRow { Text("Updated"); Text(displayDate(signal.updatedAt)) }
                    GridRow { Text("Linked Proposal"); Text(signal.proposalLinkId.map(shortID) ?? "-") }
                }

                GroupBox("Evidence") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(signal.evidence.enumerated()), id: \.offset) { _, evidence in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(evidence.title).font(.headline)
                                if let summary = evidence.summary, !summary.isEmpty {
                                    Text(summary).font(.footnote).foregroundStyle(.secondary)
                                }
                                HStack(spacing: 8) {
                                    Text(evidence.timestamp.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if let urlString = evidence.url,
                                       let url = URL(string: urlString) {
                                        Link("Open", destination: url).font(.caption)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 8) {
                    Button("Acknowledge") { updateSignalStatus(signalID: signal.signalId, archive: false) }
                        .buttonStyle(.borderedProminent)
                        .disabled(inFlight || signal.status == .acknowledged || signal.status == .archived)

                    Button("Archive") { updateSignalStatus(signalID: signal.signalId, archive: true) }
                        .buttonStyle(.bordered)
                        .disabled(inFlight || signal.status == .archived)

                    Button("Draft Proposal from Signal") { draftProposal(signalID: signal.signalId) }
                        .buttonStyle(.bordered)
                        .disabled(inFlight || signal.countsAsOwnerFacingSignalReview == false)

                    if let proposalID = signal.proposalLinkId {
                        Button("Open Proposal \(shortID(proposalID))") {
                            selectedProposalID = proposalID
                            section = .proposals
                            selectedTab = .pmInbox
                        }
                        .buttonStyle(.bordered)
                    }
                }

                if inFlight {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private func proposalDetail(_ proposal: StrategyProposal) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(proposal.title)
                    .font(.title3.weight(.semibold))
                Text(proposal.summary)
                    .font(.callout)

                if let lineage = proposal.analystLineage {
                    AnalystProposalBadge()
                    AnalystProposalLineageSection(lineage: lineage)
                }

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow { Text("Proposal"); Text(shortID(proposal.proposalId)).font(.system(.body, design: .monospaced)) }
                    GridRow { Text("Status"); Text(proposal.approval.status.rawValue).foregroundStyle(proposalStatusColor(proposal.approval.status)) }
                    GridRow { Text("Strategy"); Text(proposal.strategyId) }
                    GridRow { Text("Created By"); Text(proposal.createdBy) }
                    GridRow { Text("Originating Signal"); Text(proposal.originatingSignalId.map(shortID) ?? "-") }
                    GridRow { Text("Updated"); Text(displayDate(proposal.updatedAt)) }
                }

                if let signalID = proposal.originatingSignalId {
                    Button("Open Signal \(shortID(signalID))") {
                        selectedSignalID = signalID
                        section = .signals
                        selectedTab = .pmInbox
                    }
                    .buttonStyle(.bordered)
                }

                TextField("Review notes (required for approve/deny)", text: $reviewNotes, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)

                HStack(spacing: 8) {
                    Button("Submit Proposal") { submitProposal(proposalID: proposal.proposalId) }
                        .buttonStyle(.bordered)
                        .disabled(inFlight || proposal.approval.status != .draft)

                    Button("Approve for Paper") { approveProposal(proposalID: proposal.proposalId) }
                        .buttonStyle(.borderedProminent)
                        .disabled(inFlight || reviewNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("Deny for Paper") { denyProposal(proposalID: proposal.proposalId) }
                        .buttonStyle(.bordered)
                        .disabled(inFlight || reviewNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("Start from Proposal") { startFromProposal(proposalID: proposal.proposalId) }
                        .buttonStyle(.borderedProminent)
                        .disabled(inFlight || proposal.approval.status != .approvedPaper)
                }

                linkedRunsSection(proposalID: proposal.proposalId)

                HStack(spacing: 8) {
                    Button("Copy Proposal JSON") { copyProposalJSON(proposalID: proposal.proposalId) }
                        .buttonStyle(.bordered)
                }

                if inFlight {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private func linkedRunsSection(proposalID: String) -> some View {
        let runs = appModel.proposalRuns(proposalID: proposalID)
        return GroupBox("Linked Runs") {
            if runs.isEmpty {
                Text("No runs yet for this proposal.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(runs.prefix(10)) { run in
                        HStack {
                            Text("\(run.runType == .replay ? "REPLAY" : "PAPER") • \(shortID(run.runId))")
                                .font(.callout.weight(.semibold))
                            Text(run.status.rawValue)
                                .font(.caption)
                                .foregroundStyle(runStatusColor(run.status))
                            Spacer()
                            Button("Open") {
                                selectedRunID = run.runId
                                section = .runs
                                selectedTab = .pmInbox
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func runDetail(_ run: PaperRunRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Run \(shortID(run.runId))")
                    .font(.title3.weight(.semibold))

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow { Text("Type"); Text(run.runType == .replay ? "REPLAY" : "PAPER") }
                    GridRow { Text("Status"); Text(run.status.rawValue).foregroundStyle(runStatusColor(run.status)) }
                    GridRow { Text("Proposal"); Text(shortID(run.proposalId)) }
                    GridRow { Text("Started"); Text(displayDate(run.startedAt)) }
                    GridRow { Text("Ended"); Text(run.endedAt.map(displayDate) ?? "-") }
                    GridRow { Text("Fills"); Text("\(run.metrics.fillsCount) / partial \(run.metrics.partialFillsCount)") }
                    GridRow { Text("Orders Accepted"); Text("\(run.metrics.ordersAccepted)") }
                    GridRow { Text("Orders Rejected"); Text("\(run.metrics.ordersRejected)") }
                    GridRow { Text("Risk Blocks"); Text("\(run.metrics.riskBlocks)") }
                    GridRow { Text("Bars Processed"); Text("\(run.metrics.barsProcessed)") }
                    GridRow { Text("Net PnL"); Text(run.metrics.netPnL.map(decimalText) ?? "-") }
                    GridRow { Text("Symbols"); Text(run.metrics.symbolsTraded.isEmpty ? "-" : run.metrics.symbolsTraded.joined(separator: ", ")) }
                }

                HStack(spacing: 8) {
                    Button("Export Run JSON") { exportRunJSON(runID: run.runId) }
                        .buttonStyle(.borderedProminent)
                    Button("Open Proposal \(shortID(run.proposalId))") {
                        selectedProposalID = run.proposalId
                        section = .proposals
                        selectedTab = .pmInbox
                    }
                    .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private func automationDetailView() -> some View {
        HStack(alignment: .top, spacing: 16) {
            ScrollView {
                operationalSchedulesPanel
                    .padding(.vertical, 4)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            ScrollView {
                maintenancePanel
                    .padding(.vertical, 4)
            }
            .frame(width: 420, alignment: .topLeading)
        }
    }

    private var operationalSchedulesPanel: some View {
        GroupBox("Operational Jobs") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Configure runtime behavior for monitor, rss_poll, analyst_signals, recent_news_analyst, and other non-maintenance jobs here. Maintenance policy and storage controls are rendered separately in the Maintenance & Storage panel.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Text("Editing Saved Schedule")
                        .font(.callout.weight(.semibold))
                    Picker(
                        "Editing Saved Schedule",
                        selection: Binding(
                            get: { selectedScheduleID },
                            set: { newValue in
                                selectedScheduleID = newValue
                            }
                        )
                    ) {
                        Text("New (unsaved)").tag(String?.none)
                        ForEach(operationalSchedules, id: \.scheduleId) { schedule in
                            Text("\(schedule.jobType.rawValue) • \(shortID(schedule.scheduleId))")
                                .tag(String?.some(schedule.scheduleId))
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 360, alignment: .leading)
                    Spacer()
                }

                if let selected = selectedScheduleSummary {
                    HStack {
                        Text("Schedule \(shortID(selected.scheduleId))")
                            .font(.title3.weight(.semibold))
                        Spacer()
                        Toggle(
                            "Enabled",
                            isOn: Binding(
                                get: { selected.enabled },
                                set: { newValue in
                                    Task { @MainActor in
                                        feedbackMessage = await appModel.setScheduleEnabled(
                                            id: selected.scheduleId,
                                            enabled: newValue
                                        )
                                    }
                                }
                            )
                        )
                        .toggleStyle(.switch)
                        .frame(width: 140)
                    }
                } else {
                    Text("Create Schedule")
                        .font(.title3.weight(.semibold))
                }

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("Job Type")
                        Picker("Job Type", selection: $scheduleEditorJobType) {
                            ForEach(JobType.operationalScheduleControllableCases, id: \.self) { type in
                                Text(type.rawValue).tag(type)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: 220, alignment: .leading)
                    }

                    GridRow {
                        Text("Interval (sec)")
                        HStack(spacing: 8) {
                            TextField("Value", text: $scheduleEditorIntervalValue)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 90)
                            Picker("Unit", selection: $scheduleEditorIntervalUnit) {
                                ForEach(ScheduleIntervalEditorUnit.allCases) { unit in
                                    Text(unit.rawValue).tag(unit)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(maxWidth: 120, alignment: .leading)
                            Text(scheduleIntervalSummaryText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: 320, alignment: .leading)
                    }

                    GridRow {
                        Text("Run Mode")
                        Picker("Run Mode", selection: $scheduleEditorAlwaysOn) {
                            Text("periodic").tag(false)
                            Text("always_on").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 220, alignment: .leading)
                    }

                    if !scheduleEditorAlwaysOn {
                        GridRow {
                            Text("Startup")
                            Picker("Startup", selection: $scheduleEditorStartupBehavior) {
                                Text("Wait For Interval").tag(PeriodicScheduleStartupBehavior.waitForInterval)
                                Text("Run Immediately").tag(PeriodicScheduleStartupBehavior.runImmediately)
                            }
                            .pickerStyle(.menu)
                            .frame(maxWidth: 220, alignment: .leading)
                        }
                    }

                    GridRow {
                        Text("Restart On Launch")
                        Toggle("Enabled", isOn: $scheduleEditorRestartOnLaunch)
                            .toggleStyle(.switch)
                    }

                    GridRow {
                        Text("Allow Overlap")
                        Toggle("Enabled", isOn: $scheduleEditorAllowOverlap)
                            .toggleStyle(.switch)
                    }

                    GridRow {
                        Text("Max Runtime (sec)")
                        TextField("Optional", text: $scheduleEditorMaxRuntimeSec)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 200, alignment: .leading)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Params JSON")
                        .font(.callout.weight(.semibold))
                    TextEditor(text: $scheduleEditorParamsJSON)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 120)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        )
                }

                if let selected = selectedScheduleSummary {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        GridRow { Text("Running Job"); Text(selected.runningJobId.map(shortID) ?? "-") }
                        GridRow { Text("Last Run"); Text(selected.lastRunAt.map(displayDate) ?? "-") }
                        GridRow { Text("Last Job"); Text(selected.lastRunJobId.map(shortID) ?? "-") }
                        GridRow { Text("Last Status"); Text(scheduleLastRunStatusLabel(selected)) }
                        GridRow { Text("Last Summary"); Text(selected.lastRunSummary ?? "-") }
                        if selected.runMode == .periodic {
                            GridRow { Text("Startup"); Text(selected.startupBehavior.rawValue) }
                        }
                        GridRow { Text("Next Run"); Text(selected.nextRunAt.map(displayDate) ?? "-") }
                        GridRow { Text("Last Error"); Text(scheduleDisplayError(selected) ?? "-") }
                    }
                }

                HStack(spacing: 8) {
                    Button("Save Schedule") {
                        saveSchedule()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(inFlight)

                    if let selected = selectedScheduleSummary {
                        Button("Run Now") {
                            runScheduleNow(id: selected.scheduleId)
                        }
                        .buttonStyle(.bordered)
                        .disabled(inFlight)

                        Button("Remove", role: .destructive) {
                            removeSchedule(id: selected.scheduleId)
                        }
                        .buttonStyle(.bordered)
                        .disabled(inFlight)
                    }

                    Button("New Schedule") {
                        resetScheduleEditorForCreate()
                    }
                    .buttonStyle(.bordered)
                    .disabled(inFlight)
                }

                if inFlight {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var maintenancePanel: some View {
        let schedule = maintenanceScheduleSummary
        return GroupBox("Maintenance & Storage") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Retention and storage policy applies globally across managed areas. Operational schedules do not have separate maintenance or retention overrides.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                GroupBox("Maintenance Schedule (maintenance_retention)") {
                    VStack(alignment: .leading, spacing: 10) {
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                            GridRow { Text("Schedule"); Text(schedule.map { shortID($0.scheduleId) } ?? "default-maintenance-retention") }
                            GridRow { Text("Job Type"); Text(JobType.maintenanceRetention.rawValue) }
                            GridRow { Text("Run Mode"); Text(schedule?.runMode.rawValue ?? ScheduleRunMode.periodic.rawValue) }
                            GridRow { Text("Startup"); Text(schedule?.startupBehavior.rawValue ?? PeriodicScheduleStartupBehavior.waitForInterval.rawValue) }
                            GridRow { Text("Enabled"); Text(schedule.map { $0.enabled ? "Yes" : "No" } ?? (maintenanceScheduleEnabled ? "Yes" : "No")) }
                            GridRow { Text("Running Job"); Text(schedule?.runningJobId.map(shortID) ?? "-") }
                            GridRow { Text("Next Run"); Text(schedule?.nextRunAt.map(displayDate) ?? "-") }
                            GridRow { Text("Last Run"); Text(schedule?.lastRunAt.map(displayDate) ?? "-") }
                            GridRow { Text("Last Status"); Text(schedule.map(scheduleLastRunStatusLabel) ?? "-") }
                            GridRow { Text("Last Summary"); Text(schedule?.lastRunSummary ?? "-") }
                            GridRow { Text("Last Error"); Text(schedule.flatMap(scheduleDisplayError) ?? "-") }
                        }

                        HStack(spacing: 12) {
                            Toggle("Schedule Enabled", isOn: $maintenanceScheduleEnabled)
                                .toggleStyle(.switch)
                                .frame(width: 170, alignment: .leading)

                            TextField("Value", text: $maintenanceScheduleIntervalValue)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 90)

                            Picker("Unit", selection: $maintenanceScheduleIntervalUnit) {
                                ForEach(ScheduleIntervalEditorUnit.allCases) { unit in
                                    Text(unit.rawValue).tag(unit)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(maxWidth: 120, alignment: .leading)

                            Text(maintenanceIntervalSummaryText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 8) {
                            Button(schedule == nil ? "Create Maintenance Schedule" : "Save Maintenance Schedule") {
                                saveMaintenanceSchedule()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(inFlight)

                            if let schedule {
                                Button("Run Scheduled Maintenance Now") {
                                    runScheduleNow(id: schedule.scheduleId)
                                }
                                .buttonStyle(.bordered)
                                .disabled(inFlight)
                            }
                        }

                        if schedule == nil {
                            Text("No persisted maintenance_retention schedule exists yet. Creating one here keeps maintenance scheduling visible and centralized.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("Audit Rotate (MB)")
                        Stepper(value: $retentionAuditRotateMB, in: 1...2_000, step: 1) {
                            Text("\(retentionAuditRotateMB)")
                        }
                        .frame(maxWidth: 220, alignment: .leading)
                    }
                    GridRow {
                        Text("Audit Keep Days")
                        Stepper(value: $retentionAuditKeepDays, in: 1...3_650, step: 1) {
                            Text("\(retentionAuditKeepDays)")
                        }
                        .frame(maxWidth: 220, alignment: .leading)
                    }
                    GridRow {
                        Text("News Keep Days")
                        Stepper(value: $retentionNewsKeepDays, in: 1...3_650, step: 1) {
                            Text("\(retentionNewsKeepDays)")
                        }
                        .frame(maxWidth: 220, alignment: .leading)
                    }
                    GridRow {
                        Text("Jobs Keep Days")
                        Stepper(value: $retentionJobsKeepDays, in: 1...365, step: 1) {
                            Text("\(retentionJobsKeepDays)")
                        }
                        .frame(maxWidth: 220, alignment: .leading)
                    }
                    GridRow {
                        Text("Jobs Max Completed")
                        Stepper(value: $retentionJobsMaxCount, in: 1...10_000, step: 1) {
                            Text("\(retentionJobsMaxCount)")
                        }
                        .frame(maxWidth: 220, alignment: .leading)
                    }
                    GridRow {
                        Text("Runs Retention")
                        Toggle("Enabled", isOn: $retentionRunsEnabled)
                            .toggleStyle(.switch)
                    }
                    if retentionRunsEnabled {
                        GridRow {
                            Text("Runs Keep Days")
                            Stepper(value: $retentionRunsKeepDays, in: 1...10_000, step: 1) {
                                Text("\(retentionRunsKeepDays)")
                            }
                            .frame(maxWidth: 220, alignment: .leading)
                        }
                    }
                    GridRow {
                        Text("Bars Cache Retention")
                        Toggle("Enabled", isOn: $retentionBarsEnabled)
                            .toggleStyle(.switch)
                    }
                    if retentionBarsEnabled {
                        GridRow {
                            Text("Bars Max DB (MB)")
                            TextField("Optional", text: $retentionBarsMaxDBMB)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 220, alignment: .leading)
                        }
                    }
                }

                HStack(spacing: 8) {
                    Button("Save Retention Policy") {
                        saveRetentionPolicy()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(inFlight)

                    Button("Run Full Retention Preview") {
                        runMaintenanceNow(dryRun: true)
                    }
                    .buttonStyle(.bordered)
                    .disabled(inFlight)

                    Button("Run Full Retention Cleanup", role: .destructive) {
                        showPMInboxFullMaintenanceApplyConfirmation = true
                    }
                    .buttonStyle(.bordered)
                    .disabled(inFlight || pmInboxFullRetentionPreviewCompleted == false)
                    .confirmationDialog(
                        "Run full retention cleanup?",
                        isPresented: $showPMInboxFullMaintenanceApplyConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Run Full Retention Cleanup", role: .destructive) {
                            runMaintenanceNow(dryRun: false)
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This applies the saved retention policy through app-owned maintenance. Review a full retention preview first; active jobs, schedules, and linked records remain protected by the maintenance path.")
                    }

                    Button("Refresh Storage") {
                        Task { @MainActor in
                            feedbackMessage = await appModel.refreshStorageFootprint()
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(inFlight)
                }

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow { Text("Audit Size"); Text(byteString(appModel.storageFootprint.auditBytes)) }
                    GridRow { Text("News Size"); Text(byteString(appModel.storageFootprint.newsBytes)) }
                    GridRow { Text("Jobs Size"); Text(byteString(appModel.storageFootprint.jobsBytes)) }
                    GridRow { Text("Runs Size"); Text(byteString(appModel.storageFootprint.runsBytes)) }
                    GridRow { Text("Bars Cache Size"); Text(byteString(appModel.storageFootprint.barsCacheBytes)) }
                    GridRow { Text("Total"); Text(byteString(appModel.storageFootprint.totalBytes)).bold() }
                }

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow { Text("Last Maintenance Job"); Text(appModel.lastMaintenanceJob.map { shortID($0.jobId) } ?? "-") }
                    GridRow { Text("Last Maintenance Status"); Text(appModel.lastMaintenanceJob?.status.rawValue ?? "-") }
                    GridRow { Text("Last Maintenance Updated"); Text(appModel.lastMaintenanceJob.map { displayDate($0.updatedAt) } ?? "-") }
                    GridRow { Text("Last Maintenance Summary"); Text(appModel.lastMaintenanceSummary) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var filteredSignals: [Signal] {
        appModel.signals.filter { signal in
            isSuppressedPMTestingSignal(signal) == false && signalFilter.matches(signal.status)
        }
    }

    private var filteredProposals: [ProposalRow] {
        appModel.proposals.filter { proposalFilter.matches($0.status) }
    }

    private var filteredRuns: [PaperRunRecordSummary] {
        if let selectedProposalID, !selectedProposalID.isEmpty {
            return appModel.proposalRuns(proposalID: selectedProposalID)
        }
        return appModel.allKnownRuns()
    }

    private var selectedSignal: Signal? {
        guard let selectedSignalID else {
            return nil
        }
        return filteredSignals.first(where: { $0.id == selectedSignalID })
    }

    private var selectedProposal: StrategyProposal? {
        guard let selectedProposalID else {
            return nil
        }
        return appModel.proposalDetail(id: selectedProposalID)
    }

    private var selectedRun: PaperRunRecord? {
        guard let selectedRunID else {
            return nil
        }
        return appModel.runDetail(runID: selectedRunID)
    }

    private var selectedScheduleSummary: ScheduledJobSummary? {
        guard let selectedScheduleID else {
            return nil
        }
        return operationalSchedules.first(where: { $0.scheduleId == selectedScheduleID })
    }

    private var operationalSchedules: [ScheduledJobSummary] {
        AutomationScheduleSections.operationalSchedules(from: appModel.schedules)
    }

    private var maintenanceScheduleSummary: ScheduledJobSummary? {
        AutomationScheduleSections.maintenanceScheduleSummary(from: appModel.schedules)
    }

    private var newSignalsCount: Int {
        filteredSignals.filter { $0.status == .new }.count
    }

    private var awaitingProposalsCount: Int {
        appModel.proposals.filter { $0.status == .draft || $0.status == .proposed }.count
    }

    private var runsLast24hCount: Int {
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        return appModel.allKnownRuns().filter { $0.startedAt >= cutoff }.count
    }

    private func bootstrapSelections() {
        syncCommandCenterSelections()
        syncRecentAnalystActivitySelection()
        syncCommunicationSelections()
        if selectedSignalID == nil {
            selectedSignalID = filteredSignals.first?.id
        }
        if selectedProposalID == nil {
            selectedProposalID = filteredProposals.first?.id
        }
        if selectedRunID == nil {
            selectedRunID = filteredRuns.first?.runId
        }
        if selectedScheduleID == nil {
            selectedScheduleID = operationalSchedules.first?.scheduleId
        }
        if selectedAnalystTaskID == nil {
            selectedAnalystTaskID = appModel.analystTasks.first?.id
        }
    }

    private func prefetchProposalRuns() async {
        for row in appModel.proposals.prefix(20) {
            if appModel.proposalRuns(proposalID: row.id).isEmpty {
                _ = await appModel.fetchProposalRuns(proposalID: row.id)
            }
        }
        bootstrapSelections()
    }

    private func saveSchedule() {
        inFlight = true
        feedbackMessage = nil
        feedbackIsError = false
        Task { @MainActor in
            defer { inFlight = false }
            let params: [String: JSONValue]
            let trimmedParams = scheduleEditorParamsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedParams.isEmpty {
                params = [:]
            } else {
                do {
                    params = try JSONValue.parseObject(json: trimmedParams)
                } catch {
                    feedbackMessage = "Params must be a valid JSON object."
                    feedbackIsError = true
                    return
                }
            }

            let maxRuntime: Int?
            let trimmedRuntime = scheduleEditorMaxRuntimeSec.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedRuntime.isEmpty {
                maxRuntime = nil
            } else if let parsed = Int(trimmedRuntime), parsed > 0 {
                maxRuntime = parsed
            } else {
                feedbackMessage = "Max runtime must be a positive integer."
                feedbackIsError = true
                return
            }

            let intervalValue = scheduleEditorIntervalValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsedInterval = Int(intervalValue), parsedInterval > 0 else {
                feedbackMessage = "Interval must be a positive whole number."
                feedbackIsError = true
                return
            }
            let scheduleIntervalSec = parsedInterval * scheduleEditorIntervalUnit.multiplier
            guard (1...86_400).contains(scheduleIntervalSec) else {
                feedbackMessage = "Interval must be between 1 second and 24 hours."
                feedbackIsError = true
                return
            }

            let scheduleID = scheduleEditorID ?? UUID().uuidString
            let schedule = ScheduledJob(
                scheduleId: scheduleID,
                jobType: scheduleEditorJobType,
                enabled: scheduleEditorEnabled,
                trigger: ScheduledJobTrigger(intervalSec: scheduleIntervalSec),
                policy: ScheduledJobPolicy(
                    runMode: scheduleEditorAlwaysOn ? .alwaysOn : .periodic,
                    restartOnAppLaunch: scheduleEditorRestartOnLaunch,
                    maxRuntimeSec: maxRuntime,
                    allowOverlap: scheduleEditorAllowOverlap,
                    startupBehavior: scheduleEditorStartupBehavior
                ),
                params: params
            )

            if let error = await appModel.upsertSchedule(schedule) {
                feedbackMessage = error
                feedbackIsError = true
            } else {
                selectedScheduleID = scheduleID
                feedbackMessage = "Saved ✅ schedule \(shortID(scheduleID))"
                feedbackIsError = false
            }
        }
    }

    private func runScheduleNow(id: String) {
        inFlight = true
        feedbackMessage = nil
        feedbackIsError = false
        Task { @MainActor in
            defer { inFlight = false }
            let outcome = await appModel.runScheduleNow(id: id)
            if let error = outcome.error {
                feedbackMessage = "Run Now failed: \(error)"
                feedbackIsError = true
            } else if let summary = outcome.summary,
                      let runningJobID = summary.runningJobId,
                      !runningJobID.isEmpty {
                feedbackMessage = "Run Now dispatched ✅ job \(shortID(runningJobID))"
                feedbackIsError = false
            } else if let summary = outcome.summary,
                      let lastRunSummary = summary.lastRunSummary,
                      !lastRunSummary.isEmpty {
                let status = scheduleLastRunStatusLabel(summary)
                feedbackMessage = "Run Now \(status.lowercased()): \(lastRunSummary)"
                feedbackIsError = summary.lastRunStatus == .failed || summary.lastRunStatus == .canceled
            } else {
                feedbackMessage = "Run Now dispatched."
                feedbackIsError = false
            }
        }
    }

    private func removeSchedule(id: String) {
        inFlight = true
        feedbackMessage = nil
        feedbackIsError = false
        Task { @MainActor in
            if let error = await appModel.removeSchedule(id: id) {
                feedbackMessage = error
                feedbackIsError = true
            } else {
                selectedScheduleID = operationalSchedules.first?.scheduleId
                feedbackMessage = "Schedule removed."
                feedbackIsError = false
            }
            inFlight = false
        }
    }

    private func resetScheduleEditorForCreate() {
        selectedScheduleID = nil
        scheduleEditorID = nil
        scheduleEditorJobType = .rssPoll
        scheduleEditorEnabled = true
        scheduleEditorIntervalValue = "5"
        scheduleEditorIntervalUnit = .minutes
        scheduleEditorAlwaysOn = false
        scheduleEditorRestartOnLaunch = true
        scheduleEditorAllowOverlap = false
        scheduleEditorStartupBehavior = .waitForInterval
        scheduleEditorMaxRuntimeSec = ""
        scheduleEditorParamsJSON = "{}"
    }

    private func loadScheduleEditor(from summary: ScheduledJobSummary) {
        scheduleEditorID = summary.scheduleId
        scheduleEditorJobType = summary.jobType
        scheduleEditorEnabled = summary.enabled
        loadScheduleIntervalEditor(intervalSec: max(1, summary.intervalSec))
        scheduleEditorAlwaysOn = summary.runMode == .alwaysOn
        scheduleEditorRestartOnLaunch = summary.restartOnAppLaunch
        scheduleEditorAllowOverlap = summary.allowOverlap
        scheduleEditorStartupBehavior = summary.startupBehavior
        scheduleEditorMaxRuntimeSec = summary.maxRuntimeSec.map(String.init) ?? ""
        scheduleEditorParamsJSON = appModel.jsonText(for: summary.params)
    }

    private func loadScheduleIntervalEditor(intervalSec: Int) {
        if intervalSec % 3_600 == 0 {
            scheduleEditorIntervalUnit = .hours
            scheduleEditorIntervalValue = String(intervalSec / 3_600)
        } else if intervalSec % 60 == 0 {
            scheduleEditorIntervalUnit = .minutes
            scheduleEditorIntervalValue = String(intervalSec / 60)
        } else {
            scheduleEditorIntervalUnit = .seconds
            scheduleEditorIntervalValue = String(intervalSec)
        }
    }

    private var scheduleIntervalSummaryText: String {
        let trimmed = scheduleEditorIntervalValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Int(trimmed), parsed > 0 else {
            return "Enter a positive number"
        }
        let totalSeconds = parsed * scheduleEditorIntervalUnit.multiplier
        return "\(totalSeconds) sec"
    }

    private var maintenanceIntervalSummaryText: String {
        let trimmed = maintenanceScheduleIntervalValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Int(trimmed), parsed > 0 else {
            return "Enter a positive number"
        }
        let totalSeconds = parsed * maintenanceScheduleIntervalUnit.multiplier
        return "\(totalSeconds) sec"
    }

    private func scheduleLastRunStatusLabel(_ summary: ScheduledJobSummary) -> String {
        switch summary.lastRunStatus {
        case .succeeded:
            return "Succeeded"
        case .failed:
            return "Failed"
        case .canceled:
            return "Canceled"
        case nil:
            return "-"
        }
    }

    private func scheduleDisplayError(_ summary: ScheduledJobSummary) -> String? {
        let message = summary.lastErrorMessage ?? summary.lastError
        guard let message, !message.isEmpty else {
            return nil
        }
        if summary.runMode == .periodic && summary.lastErrorCode == "job_not_found" {
            return nil
        }
        return message
    }

    private func scheduleStatusText(_ summary: ScheduledJobSummary) -> String? {
        guard let status = summary.lastRunStatus else {
            return nil
        }
        let timestamp = summary.lastRunAt.map(displayDate) ?? "-"
        return "last run: \(status.rawValue) @ \(timestamp)"
    }

    private func loadRetentionEditor(from policy: RetentionPolicy) {
        retentionAuditRotateMB = policy.audit.rotateWhenMB
        retentionAuditKeepDays = policy.audit.keepDays
        retentionNewsKeepDays = policy.news.keepDays
        retentionJobsKeepDays = policy.jobs.keepDaysCompleted
        retentionJobsMaxCount = policy.jobs.keepMaxCompletedCount ?? 500
        retentionRunsEnabled = policy.runs.enabled
        retentionRunsKeepDays = policy.runs.keepDays
        retentionBarsEnabled = policy.barsCache.enabled
        retentionBarsMaxDBMB = policy.barsCache.maxDBMB.map(String.init) ?? ""
    }

    private func loadMaintenanceScheduleEditor(from summary: ScheduledJobSummary?) {
        guard let summary else {
            maintenanceScheduleEnabled = true
            maintenanceScheduleIntervalValue = "24"
            maintenanceScheduleIntervalUnit = .hours
            return
        }
        maintenanceScheduleEnabled = summary.enabled
        if summary.intervalSec % 3_600 == 0 {
            maintenanceScheduleIntervalUnit = .hours
            maintenanceScheduleIntervalValue = String(summary.intervalSec / 3_600)
        } else if summary.intervalSec % 60 == 0 {
            maintenanceScheduleIntervalUnit = .minutes
            maintenanceScheduleIntervalValue = String(summary.intervalSec / 60)
        } else {
            maintenanceScheduleIntervalUnit = .seconds
            maintenanceScheduleIntervalValue = String(summary.intervalSec)
        }
    }

    private func saveMaintenanceSchedule() {
        inFlight = true
        feedbackMessage = nil
        feedbackIsError = false
        Task { @MainActor in
            defer { inFlight = false }

            let trimmed = maintenanceScheduleIntervalValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsed = Int(trimmed), parsed > 0 else {
                feedbackMessage = "Maintenance interval must be a positive whole number."
                feedbackIsError = true
                return
            }

            let intervalSec = parsed * maintenanceScheduleIntervalUnit.multiplier
            guard (1...86_400).contains(intervalSec) else {
                feedbackMessage = "Maintenance interval must be between 1 second and 24 hours."
                feedbackIsError = true
                return
            }

            let schedule = AutomationScheduleSections.makeMaintenanceSchedule(
                from: maintenanceScheduleSummary,
                enabled: maintenanceScheduleEnabled,
                intervalSec: intervalSec
            )

            if let error = await appModel.upsertSchedule(schedule) {
                feedbackMessage = error
                feedbackIsError = true
            } else {
                feedbackMessage = "Saved ✅ maintenance schedule \(shortID(schedule.scheduleId))"
                feedbackIsError = false
            }
        }
    }

    private func saveRetentionPolicy() {
        inFlight = true
        feedbackMessage = nil
        Task { @MainActor in
            defer { inFlight = false }

            let barsMaxDBMB: Int?
            let trimmedBars = retentionBarsMaxDBMB.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedBars.isEmpty {
                barsMaxDBMB = nil
            } else if let parsed = Int(trimmedBars), parsed > 0 {
                barsMaxDBMB = parsed
            } else {
                feedbackMessage = "Bars max DB must be a positive integer when provided."
                return
            }

            let policy = RetentionPolicy(
                audit: .init(
                    rotateWhenMB: max(1, retentionAuditRotateMB),
                    keepDays: max(1, retentionAuditKeepDays)
                ),
                news: .init(keepDays: max(1, retentionNewsKeepDays)),
                jobs: .init(
                    keepDaysCompleted: max(1, retentionJobsKeepDays),
                    keepMaxCompletedCount: max(1, retentionJobsMaxCount)
                ),
                runs: .init(
                    enabled: retentionRunsEnabled,
                    keepDays: max(1, retentionRunsKeepDays)
                ),
                barsCache: .init(
                    enabled: retentionBarsEnabled,
                    maxDBMB: barsMaxDBMB
                )
            )

            feedbackMessage = await appModel.saveRetentionPolicy(policy)
            if feedbackMessage == nil {
                _ = await appModel.refreshStorageFootprint()
                loadRetentionEditor(from: appModel.retentionPolicy)
            }
        }
    }

    private func runMaintenanceNow(dryRun: Bool) {
        inFlight = true
        feedbackMessage = nil
        Task { @MainActor in
            feedbackMessage = await appModel.runMaintenanceRetention(dryRun: dryRun)
            if feedbackMessage == nil {
                feedbackMessage = dryRun
                    ? "Full retention preview requested. Review the latest maintenance result before applying."
                    : "Full retention cleanup requested through app-owned maintenance."
                pmInboxFullRetentionPreviewCompleted = dryRun && appModel.lastMaintenanceJob?.status == .succeeded
            }
            _ = await appModel.refreshStorageFootprint()
            inFlight = false
        }
    }

    private func byteString(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: max(0, bytes))
    }

    private func updateSignalStatus(signalID: String, archive: Bool) {
        inFlight = true
        feedbackMessage = nil
        Task { @MainActor in
            let error = archive
                ? await appModel.archiveSignal(id: signalID)
                : await appModel.acknowledgeSignal(id: signalID)
            if error == nil {
                _ = await appModel.refreshSignals(limit: 200)
            }
            feedbackMessage = error
            inFlight = false
        }
    }

    private func signalLineagePresentation(_ signal: Signal) -> SignalLineageReadablePresentation? {
        makeSignalLineageReadablePresentation(
            signal: signal,
            charters: appModel.analystCharters,
            tasks: appModel.analystTasks,
            findings: appModel.analystFindings,
            evidenceBundles: appModel.analystEvidenceBundles
        )
    }

    private func draftProposal(signalID: String) {
        inFlight = true
        feedbackMessage = nil
        Task { @MainActor in
            let error = await appModel.draftProposalFromSignal(id: signalID)
            if error == nil {
                _ = await appModel.refreshSignals(limit: 200)
                if let signal = appModel.signals.first(where: { $0.signalId == signalID }),
                   let proposalID = signal.proposalLinkId {
                    selectedProposalID = proposalID
                    section = .proposals
                    _ = await appModel.fetchProposalDetail(id: proposalID)
                    _ = await appModel.fetchProposalRuns(proposalID: proposalID)
                }
            }
            feedbackMessage = error
            inFlight = false
        }
    }

    private func submitProposal(proposalID: String) {
        inFlight = true
        feedbackMessage = nil
        Task { @MainActor in
            let error = await appModel.submitProposal(id: proposalID)
            if error == nil {
                _ = await appModel.fetchProposalDetail(id: proposalID)
            }
            feedbackMessage = error
            inFlight = false
        }
    }

    private func approveProposal(proposalID: String) {
        let notes = reviewNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !notes.isEmpty else {
            feedbackMessage = "Review notes are required."
            return
        }
        inFlight = true
        feedbackMessage = nil
        Task { @MainActor in
            let error = await appModel.approveProposalForPaper(id: proposalID, notes: notes)
            if error == nil {
                _ = await appModel.fetchProposalDetail(id: proposalID)
            }
            feedbackMessage = error
            inFlight = false
        }
    }

    private func denyProposal(proposalID: String) {
        let notes = reviewNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !notes.isEmpty else {
            feedbackMessage = "Review notes are required."
            return
        }
        inFlight = true
        feedbackMessage = nil
        Task { @MainActor in
            let error = await appModel.denyProposalForPaper(id: proposalID, notes: notes)
            if error == nil {
                _ = await appModel.fetchProposalDetail(id: proposalID)
            }
            feedbackMessage = error
            inFlight = false
        }
    }

    private func startFromProposal(proposalID: String) {
        inFlight = true
        feedbackMessage = nil
        Task { @MainActor in
            let error = await appModel.startStrategyFromProposal(id: proposalID)
            if error == nil {
                _ = await appModel.fetchProposalRuns(proposalID: proposalID)
                selectedRunID = appModel.proposalRuns(proposalID: proposalID).first?.runId
            }
            feedbackMessage = error
            inFlight = false
        }
    }

    private func copyProposalJSON(proposalID: String) {
        guard let json = appModel.prettyProposalJSON(id: proposalID) else {
            feedbackMessage = "Unable to format proposal JSON."
            return
        }
        #if canImport(AppKit)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(json, forType: .string)
        feedbackMessage = "Proposal JSON copied."
        #else
        feedbackMessage = json
        #endif
    }

    private func exportRunJSON(runID: String) {
        Task { @MainActor in
            switch await appModel.exportRunJSON(runID: runID) {
            case .success(let json):
                #if canImport(AppKit)
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(json, forType: .string)
                feedbackMessage = "Run JSON copied."
                #else
                feedbackMessage = json
                #endif
            case .failure(let message):
                feedbackMessage = message
            }
        }
    }

    private func shortID(_ value: String) -> String {
        String(value.prefix(8))
    }

    private func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }

    private func decimalText(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }

    private func displayDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }

    private func signalStatusColor(_ status: SignalStatus) -> Color {
        switch status {
        case .new:
            return .orange
        case .acknowledged:
            return .green
        case .archived:
            return .secondary
        }
    }

    private func proposalStatusColor(_ status: StrategyProposalStatus) -> Color {
        switch status {
        case .draft:
            return .secondary
        case .proposed:
            return .orange
        case .approvedPaper:
            return .green
        case .deniedPaper:
            return .red
        }
    }

    private func runStatusColor(_ status: PaperRunStatus) -> Color {
        switch status {
        case .running:
            return .orange
        case .stopped:
            return .green
        case .error:
            return .red
        case .aborted:
            return .secondary
        }
    }
}

enum AutomationScheduleSections {
    static let defaultMaintenanceScheduleID = "default-maintenance-retention"

    static func operationalSchedules(from schedules: [ScheduledJobSummary]) -> [ScheduledJobSummary] {
        schedules.filter { $0.jobType != .maintenanceRetention }
    }

    static func maintenanceScheduleSummary(from schedules: [ScheduledJobSummary]) -> ScheduledJobSummary? {
        schedules.first(where: { $0.jobType == .maintenanceRetention })
    }

    static func makeMaintenanceSchedule(
        from summary: ScheduledJobSummary?,
        enabled: Bool,
        intervalSec: Int
    ) -> ScheduledJob {
        if let summary {
            return ScheduledJob(
                scheduleId: summary.scheduleId,
                jobType: summary.jobType,
                enabled: enabled,
                trigger: ScheduledJobTrigger(intervalSec: intervalSec),
                policy: ScheduledJobPolicy(
                    runMode: summary.runMode,
                    restartOnAppLaunch: summary.restartOnAppLaunch,
                    maxRuntimeSec: summary.maxRuntimeSec,
                    allowOverlap: summary.allowOverlap,
                    startupBehavior: summary.startupBehavior
                ),
                params: summary.params,
                lastRunAt: summary.lastRunAt,
                lastRunJobId: summary.lastRunJobId,
                lastRunStatus: summary.lastRunStatus,
                lastRunSummary: summary.lastRunSummary,
                lastSuccessAt: summary.lastSuccessAt,
                lastError: summary.lastError,
                lastErrorCode: summary.lastErrorCode,
                lastErrorMessage: summary.lastErrorMessage,
                nextRunAt: summary.nextRunAt,
                runningJobId: summary.runningJobId
            )
        }

        return ScheduledJob(
            scheduleId: defaultMaintenanceScheduleID,
            jobType: .maintenanceRetention,
            enabled: enabled,
            trigger: ScheduledJobTrigger(intervalSec: intervalSec),
            policy: ScheduledJobPolicy(
                runMode: .periodic,
                restartOnAppLaunch: true,
                maxRuntimeSec: nil,
                allowOverlap: false,
                startupBehavior: .waitForInterval
            ),
            params: [
                "dryRun": .bool(true)
            ]
        )
    }
}

private enum ProposalStatusFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case draft = "Draft"
    case proposed = "Proposed"
    case approvedPaper = "Approved"
    case deniedPaper = "Denied"

    var id: String { rawValue }

    func matches(_ status: StrategyProposalStatus) -> Bool {
        switch self {
        case .all:
            return true
        case .draft:
            return status == .draft
        case .proposed:
            return status == .proposed
        case .approvedPaper:
            return status == .approvedPaper
        case .deniedPaper:
            return status == .deniedPaper
        }
    }
}

private enum ProposalAction {
    case approve
    case deny
}

struct ProposalsView: View {
    @EnvironmentObject private var appModel: AppModel

    @State private var selectedProposalID: String?
    @State private var statusFilter: ProposalStatusFilter = .all
    @State private var reviewNotes = ""
    @State private var feedbackMessage: String?
    @State private var inFlight = false
    @State private var pendingAction: ProposalAction?
    @State private var confirmationPresented = false
    @State private var selectedRunID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Proposals")
                    .font(.title2)
                Spacer()
                Picker("Status", selection: $statusFilter) {
                    ForEach(ProposalStatusFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 160)
            }

            NavigationSplitView {
                List(selection: $selectedProposalID) {
                    ForEach(filteredRows) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.title)
                                .font(.headline)
                            Text("\(row.strategyId) • \(row.createdBy)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(row.status.rawValue)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(statusColor(row.status))
                        }
                        .padding(.vertical, 4)
                        .tag(row.id)
                    }
                }
                .frame(minWidth: 260)
            } detail: {
                Group {
                    if let selectedProposalID,
                       let proposal = appModel.proposalDetail(id: selectedProposalID) {
                        proposalDetailView(proposal: proposal)
                    } else {
                        Text("Select a proposal to review details.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    }
                }
            }
            .navigationSplitViewStyle(.balanced)
        }
        .padding(18)
        .onAppear {
            if selectedProposalID == nil {
                selectedProposalID = filteredRows.first?.id
            }
        }
        .onChange(of: selectedProposalID) { newValue in
            guard let newValue else {
                selectedRunID = nil
                return
            }
            Task { @MainActor in
                feedbackMessage = await appModel.fetchProposalDetail(id: newValue)
                if feedbackMessage == nil {
                    let runError = await appModel.fetchProposalRuns(proposalID: newValue)
                    if let runError {
                        feedbackMessage = runError
                    }
                }
                selectedRunID = appModel.proposalRuns(proposalID: newValue).first?.runId
                if let selectedRunID {
                    _ = await appModel.fetchRunDetail(runID: selectedRunID)
                }
            }
        }
        .onChange(of: appModel.proposals) { rows in
            if let selectedProposalID,
               !rows.contains(where: { $0.id == selectedProposalID }) {
                self.selectedProposalID = rows.first?.id
                self.selectedRunID = nil
            } else if self.selectedProposalID == nil {
                self.selectedProposalID = rows.first?.id
            }
        }
        .onChange(of: selectedRunID) { newValue in
            guard let newValue else {
                return
            }
            Task { @MainActor in
                let error = await appModel.fetchRunDetail(runID: newValue)
                if let error {
                    feedbackMessage = error
                }
            }
        }
        .alert(
            pendingAction == .approve ? "Approve for Paper" : "Deny for Paper",
            isPresented: $confirmationPresented,
            actions: {
                Button("Cancel", role: .cancel) {
                    pendingAction = nil
                }
                Button(pendingAction == .approve ? "Approve" : "Deny", role: pendingAction == .approve ? .none : .destructive) {
                    performPendingAction()
                }
            },
            message: {
                Text("This action updates proposal status and audit logs.")
            }
        )
    }

    private var filteredRows: [ProposalRow] {
        appModel.proposals.filter { row in
            statusFilter.matches(row.status)
        }
    }

    @ViewBuilder
    private func proposalDetailView(proposal: StrategyProposal) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(proposal.title)
                    .font(.title3.weight(.semibold))
                Text(proposal.summary)
                    .font(.callout)

                if let lineage = proposal.analystLineage {
                    AnalystProposalBadge()
                    AnalystProposalLineageSection(lineage: lineage)
                }

                Text("Strategy: \(proposal.strategyId)")
                    .font(.callout)
                Text("Created by: \(proposal.createdBy)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if proposal.intendedEnvironmentPaperOnly {
                    Text("Paper-only proposal")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.blue.opacity(0.15))
                        .clipShape(Capsule())
                }

                GroupBox("Scope") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Symbols: \(proposal.scope.symbols?.joined(separator: ", ") ?? "-")")
                        Text("Watchlist Ref: \(proposal.scope.watchlistReference ?? "-")")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Constraints") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("maxOrdersPerMinute: \(proposal.constraints.maxOrdersPerMinute)")
                        Text("maxNotionalPerOrder: \(decimalText(proposal.constraints.maxNotionalPerOrder))")
                        Text("maxDailyNotional: \(proposal.constraints.maxDailyNotional.map(decimalText) ?? "-")")
                        Text("allowShort: \(proposal.constraints.allowShort.map(boolText) ?? "-")")
                        Text("allowOptions: \(proposal.constraints.allowOptions.map(boolText) ?? "-")")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Test Plan") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("durationMinutes: \(proposal.testPlan.durationMinutes)")
                        Text("successMetrics: \(proposal.testPlan.successMetrics.joined(separator: ", "))")
                        Text("stopConditions: \(proposal.testPlan.stopConditions.joined(separator: ", "))")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Parameters JSON") {
                    ScrollView(.horizontal) {
                        Text(appModel.jsonText(for: proposal.parameters))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                GroupBox("Approval") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("status: \(proposal.approval.status.rawValue)")
                            .foregroundStyle(statusColor(proposal.approval.status))
                        Text("reviewedBy: \(proposal.approval.reviewedBy ?? "-")")
                        Text("reviewedAt: \(proposal.approval.reviewedAt.map(displayDate) ?? "-")")
                        Text("notes: \(proposal.approval.reviewNotes ?? "-")")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 8) {
                    TextField("Review notes (required for approve/deny)", text: $reviewNotes, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)

                    Button("Approve for Paper") {
                        pendingAction = .approve
                        confirmationPresented = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(inFlight || reviewNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("Deny for Paper") {
                        pendingAction = .deny
                        confirmationPresented = true
                    }
                    .buttonStyle(.bordered)
                    .disabled(inFlight || reviewNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("Submit Proposal") {
                        submitSelectedProposal()
                    }
                    .buttonStyle(.bordered)
                    .disabled(inFlight)
                }

                HStack(spacing: 8) {
                    Button("Start Paper Run") {
                        startPaperRun(proposalID: proposal.proposalId)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(inFlight || proposal.approval.status != .approvedPaper)

                    Button("Copy Proposal JSON") {
                        copyProposalJSON(proposalID: proposal.proposalId)
                    }
                    .buttonStyle(.bordered)
                }

                runsSection(proposal: proposal)

                if inFlight {
                    ProgressView()
                        .controlSize(.small)
                }

                if let feedbackMessage, !feedbackMessage.isEmpty {
                    Text(feedbackMessage)
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func runsSection(proposal: StrategyProposal) -> some View {
        let runs = appModel.proposalRuns(proposalID: proposal.proposalId)
        GroupBox("Runs") {
            if runs.isEmpty {
                Text("No runs recorded yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Run", selection: $selectedRunID) {
                        ForEach(runs) { run in
                            Text(
                                "\(run.runType == .replay ? "REPLAY" : "PAPER") • \(shortID(run.runId)) • \(run.status.rawValue) • \(displayDate(run.startedAt))"
                            )
                            .tag(Optional(run.runId))
                        }
                    }
                    .pickerStyle(.menu)

                    if let selectedRunID,
                       let run = appModel.runDetail(runID: selectedRunID) {
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                            GridRow {
                                Text("Run Type")
                                Text(run.runType == .replay ? "REPLAY" : "PAPER")
                                    .foregroundStyle(run.runType == .replay ? .blue : .secondary)
                            }
                            GridRow {
                                Text("Status")
                                Text(run.status.rawValue.uppercased())
                                    .foregroundStyle(runStatusColor(run.status))
                            }
                            GridRow {
                                Text("Started")
                                Text(displayDate(run.startedAt))
                            }
                            GridRow {
                                Text("Ended")
                                Text(run.endedAt.map(displayDate) ?? "-")
                            }
                            GridRow {
                                Text("Stop Reason")
                                Text(run.stopReason ?? "-")
                            }
                            GridRow {
                                Text("Orders Accepted")
                                Text("\(run.metrics.ordersAccepted)")
                            }
                            GridRow {
                                Text("Orders Rejected")
                                Text("\(run.metrics.ordersRejected)")
                            }
                            GridRow {
                                Text("Fills / Partial")
                                Text("\(run.metrics.fillsCount) / \(run.metrics.partialFillsCount)")
                            }
                            GridRow {
                                Text("Bars Processed")
                                Text("\(run.metrics.barsProcessed)")
                            }
                            GridRow {
                                Text("Total Filled Qty")
                                Text(decimalText(run.metrics.totalFilledQty))
                            }
                            GridRow {
                                Text("Risk Blocks")
                                Text("\(run.metrics.riskBlocks)")
                            }
                            GridRow {
                                Text("Symbols")
                                Text(run.metrics.symbolsTraded.isEmpty ? "-" : run.metrics.symbolsTraded.joined(separator: ", "))
                            }
                            GridRow {
                                Text("PnL")
                                Text(run.metrics.netPnL.map(decimalText) ?? "-")
                            }
                            GridRow {
                                Text("Realized PnL")
                                Text(run.metrics.realizedPnL.map(decimalText) ?? "-")
                            }
                            GridRow {
                                Text("Unrealized PnL")
                                Text(run.metrics.unrealizedPnL.map(decimalText) ?? "-")
                            }
                            GridRow {
                                Text("Starting Cash")
                                Text(run.metrics.startingCash.map(decimalText) ?? "-")
                            }
                            GridRow {
                                Text("Ending Cash")
                                Text(run.metrics.endingCash.map(decimalText) ?? "-")
                            }
                            GridRow {
                                Text("Starting Equity")
                                Text(run.metrics.startingEquity.map(decimalText) ?? "-")
                            }
                            GridRow {
                                Text("Ending Equity")
                                Text(run.metrics.endingEquity.map(decimalText) ?? "-")
                            }
                        }
                        .font(.callout)

                        if run.runType == .replay, let source = run.dataSource {
                            GroupBox("Replay Data Source") {
                                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                                    GridRow {
                                        Text("Provider")
                                        Text(source.provider)
                                    }
                                    GridRow {
                                        Text("Cache")
                                        Text(source.cache)
                                    }
                                    GridRow {
                                        Text("Symbols")
                                        Text(source.symbols.joined(separator: ", "))
                                    }
                                    GridRow {
                                        Text("Timeframe")
                                        Text(source.timeframe.rawValue)
                                    }
                                    GridRow {
                                        Text("Window")
                                        Text("\(displayDate(source.start)) → \(displayDate(source.end))")
                                    }
                                    GridRow {
                                        Text("Feed")
                                        Text(source.feed.rawValue.uppercased())
                                    }
                                }
                            }
                        }

                        if run.runType == .replay, let simulation = run.replaySimulation {
                            GroupBox("Replay Simulation") {
                                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                                    GridRow {
                                        Text("Simulated Trades")
                                        Text(simulation.simulateTrades ? "Enabled" : "Disabled")
                                    }
                                    GridRow {
                                        Text("Replay Trading Gate")
                                        Text(simulation.allowTradingInReplay ? "Allowed" : "Blocked")
                                    }
                                    GridRow {
                                        Text("Fill Policy")
                                        Text(simulation.fillPolicy.rawValue)
                                    }
                                    GridRow {
                                        Text("Slippage (Market Bps)")
                                        Text("\(simulation.slippageBps.market)")
                                    }
                                    GridRow {
                                        Text("Slippage (Limit Bps)")
                                        Text("\(simulation.slippageBps.limit)")
                                    }
                                }
                            }
                        }

                        HStack(spacing: 8) {
                            Button("Export Run JSON") {
                                exportSelectedRunJSON(runID: selectedRunID)
                            }
                            .buttonStyle(.borderedProminent)

                            Button("Copy Run Summary") {
                                copyRunSummary(run: run)
                            }
                            .buttonStyle(.bordered)
                        }
                    } else {
                        Text("Select a run to view details.")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func performPendingAction() {
        guard let proposalID = selectedProposalID,
              let action = pendingAction
        else {
            return
        }
        let notes = reviewNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !notes.isEmpty else {
            feedbackMessage = "Review notes are required."
            return
        }

        inFlight = true
        feedbackMessage = nil
        Task { @MainActor in
            let error: String?
            switch action {
            case .approve:
                error = await appModel.approveProposalForPaper(id: proposalID, notes: notes)
            case .deny:
                error = await appModel.denyProposalForPaper(id: proposalID, notes: notes)
            }
            if error == nil {
                _ = await appModel.fetchProposalDetail(id: proposalID)
            }
            feedbackMessage = error
            inFlight = false
            pendingAction = nil
        }
    }

    private func submitSelectedProposal() {
        guard let proposalID = selectedProposalID else {
            return
        }
        inFlight = true
        feedbackMessage = nil
        Task { @MainActor in
            let error = await appModel.submitProposal(id: proposalID)
            if error == nil {
                _ = await appModel.fetchProposalDetail(id: proposalID)
            }
            feedbackMessage = error
            inFlight = false
        }
    }

    private func startPaperRun(proposalID: String) {
        inFlight = true
        feedbackMessage = nil
        Task { @MainActor in
            let error = await appModel.startStrategyFromProposal(id: proposalID)
            feedbackMessage = error
            if error == nil {
                _ = await appModel.fetchProposalRuns(proposalID: proposalID)
                selectedRunID = appModel.proposalRuns(proposalID: proposalID).first?.runId
                if let selectedRunID {
                    _ = await appModel.fetchRunDetail(runID: selectedRunID)
                }
            }
            inFlight = false
        }
    }

    private func copyProposalJSON(proposalID: String) {
        guard let json = appModel.prettyProposalJSON(id: proposalID) else {
            feedbackMessage = "Unable to format proposal JSON."
            return
        }
        #if canImport(AppKit)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(json, forType: .string)
        feedbackMessage = "Proposal JSON copied."
        #else
        feedbackMessage = json
        #endif
    }

    private func exportSelectedRunJSON(runID: String) {
        Task { @MainActor in
            switch await appModel.exportRunJSON(runID: runID) {
            case .success(let json):
                #if canImport(AppKit)
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(json, forType: .string)
                feedbackMessage = "Run JSON copied."
                #else
                feedbackMessage = json
                #endif
            case .failure(let message):
                feedbackMessage = message
            }
        }
    }

    private func copyRunSummary(run: PaperRunRecord) {
        let summary = """
        run_id=\(shortID(run.runId)) strategy=\(run.strategyId) status=\(run.status.rawValue) fills=\(run.metrics.fillsCount) partial_fills=\(run.metrics.partialFillsCount) orders_accepted=\(run.metrics.ordersAccepted) orders_rejected=\(run.metrics.ordersRejected) risk_blocks=\(run.metrics.riskBlocks)
        """
        #if canImport(AppKit)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(summary, forType: .string)
        feedbackMessage = "Run summary copied."
        #else
        feedbackMessage = summary
        #endif
    }

    private func shortID(_ id: String) -> String {
        String(id.prefix(8))
    }

    private func runStatusColor(_ status: PaperRunStatus) -> Color {
        switch status {
        case .running:
            return .orange
        case .stopped:
            return .green
        case .error:
            return .red
        case .aborted:
            return .secondary
        }
    }

    private func statusColor(_ status: StrategyProposalStatus) -> Color {
        switch status {
        case .draft:
            return .secondary
        case .proposed:
            return .orange
        case .approvedPaper:
            return .green
        case .deniedPaper:
            return .red
        }
    }

    private func decimalText(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }

    private func boolText(_ value: Bool) -> String {
        value ? "true" : "false"
    }

    private func displayDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }
}

struct JobsView: View {
    @EnvironmentObject private var appModel: AppModel

    @State private var feedbackMessage: String?
    @State private var cancelingIDs: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Jobs")
                    .font(.title2)
                Spacer()
                Button("Refresh") {
                    Task { @MainActor in
                        feedbackMessage = await appModel.refreshJobs()
                    }
                }
                .buttonStyle(.bordered)
            }

            if let feedbackMessage, !feedbackMessage.isEmpty {
                Text(feedbackMessage)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            if appModel.jobs.isEmpty {
                Text("No jobs found.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(appModel.jobs) { job in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(job.type.rawValue) • \(shortID(job.jobId))")
                                .font(.headline)
                            Text("Status: \(job.status.rawValue)")
                                .font(.caption)
                                .foregroundStyle(statusColor(job.status))
                            Text(job.updatedAt.formatted(date: .abbreviated, time: .standard))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if let message = job.message, !message.isEmpty {
                                Text(message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if job.status == .queued || job.status == .running {
                            Button("Cancel") {
                                cancel(jobID: job.jobId)
                            }
                            .buttonStyle(.bordered)
                            .disabled(cancelingIDs.contains(job.jobId))
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(18)
        .task {
            feedbackMessage = await appModel.refreshJobs()
        }
    }

    private func cancel(jobID: String) {
        cancelingIDs.insert(jobID)
        Task { @MainActor in
            feedbackMessage = await appModel.cancelJob(jobID: jobID)
            cancelingIDs.remove(jobID)
        }
    }

    private func shortID(_ value: String) -> String {
        String(value.prefix(8))
    }

    private func statusColor(_ status: JobStatus) -> Color {
        switch status {
        case .queued:
            return .secondary
        case .running:
            return .orange
        case .succeeded:
            return .green
        case .failed:
            return .red
        case .canceled:
            return .secondary
        }
    }
}

private struct AnalystOperationsDetailView: View {
    @EnvironmentObject private var appModel: AppModel
    @Binding var selectedTaskID: String?

    @State private var selectedDelegationID: String?
    @State private var selectedStrategyFollowUpCandidateID: String?
    @State private var selectedSourceAccessSuggestionID: String?
    @State private var taskTitle = ""
    @State private var taskDescription = ""
    @State private var taskCharterID = ""
    @State private var taskObjective = ""
    @State private var taskWhyNow = ""
    @State private var taskReviewLens = ""
    @State private var taskExpectedAnswerShape: PMAnalystExpectedAnswerShape?
    @State private var taskChallengeInstruction = ""
    @State private var taskEvidenceExpectation = ""
    @State private var taskDisconfirmingEvidence = ""
    @State private var taskExpectedOutputs = ""
    @State private var taskRevisionReason = ""
    @State private var taskStatus: AnalystTaskStatus = .queued
    @State private var taskSymbols = ""
    @State private var taskTags = ""
    @State private var taskDueEnabled = false
    @State private var taskDueAt = Date()
    @State private var taskFeedback: String?
    @State private var taskFeedbackIsError = false
    @State private var taskSaveInFlight = false
    @State private var launchCharterID = ""
    @State private var launchTaskID: String?
    @State private var launchDraftSignal = true
    @State private var launchFeedback: String?
    @State private var launchFeedbackIsError = false
    @State private var launchInFlight = false
    @State private var followUpActionType: PMAnalystFollowUpActionType = .requestRevision
    @State private var followUpSummary = ""
    @State private var followUpTaskObjective = ""
    @State private var followUpWhyNow = ""
    @State private var followUpReviewLens = ""
    @State private var followUpExpectedAnswerShape: PMAnalystExpectedAnswerShape?
    @State private var followUpChallengeInstruction = ""
    @State private var followUpEvidenceExpectation = ""
    @State private var followUpDisconfirmingEvidence = ""
    @State private var followUpExpectedOutputs = ""
    @State private var followUpRevisionReason = ""
    @State private var followUpRequestedCharterID = ""
    @State private var followUpRuntimeIdentifier = ""
    @State private var followUpReasoningMode: AnalystRuntimeReasoningMode = .standard
    @State private var followUpFeedback: String?
    @State private var followUpFeedbackIsError = false
    @State private var followUpInFlight = false
    @State private var strategyCandidateFeedback: String?
    @State private var strategyCandidateFeedbackIsError = false
    @State private var strategyCandidateInFlight = false

    private var selectedTask: AnalystTask? {
        guard let selectedTaskID else {
            return nil
        }
        return appModel.analystTasks.first(where: { $0.id == selectedTaskID })
    }

    private var recentDelegations: [PMDelegationRecord] {
        Array(appModel.pmDelegations.prefix(8))
    }

    private var selectedDelegation: PMDelegationRecord? {
        guard let selectedDelegationID else {
            return nil
        }
        return appModel.pmDelegations.first(where: { $0.delegationId == selectedDelegationID })
    }

    private var launchableTasks: [AnalystTask] {
        appModel.analystTasks.filter { task in
            guard !launchCharterID.isEmpty else {
                return true
            }
            return task.charterId == launchCharterID
        }
    }

    private var benchRoutingSections: [PMBenchRoutingSectionPresentation] {
        makePMBenchRoutingSections(
            charters: appModel.analystCharters,
            tasks: appModel.analystTasks,
            findings: appModel.analystFindings,
            memos: appModel.analystMemos
        )
    }

    private var selectedTaskRoutingCandidate: PMBenchRoutingCandidatePresentation? {
        benchRoutingSections
            .flatMap(\.candidates)
            .first(where: { $0.charterId == taskCharterID })
    }

    private var selectedTaskRoutingSection: PMBenchRoutingSectionPresentation? {
        benchRoutingSections.first { section in
            section.candidates.contains(where: { $0.charterId == taskCharterID })
        }
    }

    private var selectedLaunchRoutingCandidate: PMBenchRoutingCandidatePresentation? {
        benchRoutingSections
            .flatMap(\.candidates)
            .first(where: { $0.charterId == launchCharterID })
    }

    private var selectedLaunchRoutingSection: PMBenchRoutingSectionPresentation? {
        benchRoutingSections.first { section in
            section.candidates.contains(where: { $0.charterId == launchCharterID })
        }
    }

    private var selectedFollowUpRoutingCandidate: PMBenchRoutingCandidatePresentation? {
        benchRoutingSections
            .flatMap(\.candidates)
            .first(where: { $0.charterId == followUpRequestedCharterID })
    }

    private var selectedFollowUpRoutingSection: PMBenchRoutingSectionPresentation? {
        benchRoutingSections.first { section in
            section.candidates.contains(where: { $0.charterId == followUpRequestedCharterID })
        }
    }

    private var followUpGuidance: PMAnalystFollowUpGuidance {
        makePMAnalystFollowUpGuidance(followUpActionType)
    }

    private var strategyFollowUpCandidates: [AnalystStrategyFollowUpCandidateRecord] {
        appModel.analystStrategyFollowUpCandidates
    }

    private var sourceAccessSuggestions: [AnalystSourceAccessSuggestionRecord] {
        appModel.analystSourceAccessSuggestions
    }

    private var openSourceAccessSuggestions: [AnalystSourceAccessSuggestionRecord] {
        sourceAccessSuggestions
            .filter { $0.status.isActive }
            .sorted(by: sourceAccessSuggestionsNewestFirst)
    }

    private var closedSourceAccessSuggestions: [AnalystSourceAccessSuggestionRecord] {
        sourceAccessSuggestions
            .filter { $0.status.isActive == false }
            .sorted(by: sourceAccessSuggestionsNewestFirst)
    }

    private var selectedSourceAccessSuggestion: AnalystSourceAccessSuggestionRecord? {
        guard let selectedSourceAccessSuggestionID else {
            return openSourceAccessSuggestions.first ?? sourceAccessSuggestions.first
        }
        return sourceAccessSuggestions.first(where: { $0.suggestionId == selectedSourceAccessSuggestionID })
            ?? openSourceAccessSuggestions.first
            ?? sourceAccessSuggestions.first
    }

    private var openStrategyFollowUpCandidates: [AnalystStrategyFollowUpCandidateRecord] {
        strategyFollowUpCandidates
            .filter { $0.status.isActive }
            .sorted(by: strategyFollowUpCandidatesNewestFirst)
    }

    private var closedStrategyFollowUpCandidates: [AnalystStrategyFollowUpCandidateRecord] {
        strategyFollowUpCandidates
            .filter { $0.status.isActive == false }
            .sorted(by: strategyFollowUpCandidatesNewestFirst)
    }

    private var recentStrategicChangeCandidates: [AnalystStrategyFollowUpCandidateRecord] {
        Array(closedStrategyFollowUpCandidates.prefix(4))
    }

    private var selectedStrategyFollowUpCandidate: AnalystStrategyFollowUpCandidateRecord? {
        guard let selectedStrategyFollowUpCandidateID else {
            return openStrategyFollowUpCandidates.first ?? strategyFollowUpCandidates.first
        }
        return strategyFollowUpCandidates.first(where: { $0.candidateId == selectedStrategyFollowUpCandidateID })
            ?? openStrategyFollowUpCandidates.first
            ?? strategyFollowUpCandidates.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if appModel.analystCharters.isEmpty {
                    Text("Create or edit analyst charters in Command Center before creating tasks or launching the worker.")
                        .foregroundStyle(.secondary)
                } else {
                    GroupBox("Delegation Detail") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Inspect recent PM delegations, runtime intent vs actual runtime, and downstream artifact progress from the analyst operations surface.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)

                            if recentDelegations.isEmpty {
                                Text("No PM delegations yet. Create them through the PM control plane or CLI, then review them here.")
                                    .foregroundStyle(.secondary)
                            } else {
                                HStack(alignment: .top, spacing: 12) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        ForEach(recentDelegations) { delegation in
                                            delegationRow(delegation)
                                        }
                                    }
                                    .frame(maxWidth: 320, alignment: .leading)

                                    Divider()

                                    if let selectedDelegation {
                                        delegationDetail(selectedDelegation)
                                    } else {
                                        Text("Select a delegation to inspect launch health, runtime provenance, and downstream outputs.")
                                            .foregroundStyle(.secondary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("Worker Run Once") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Select a charter and optional task, then launch one explicit worker run.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)

                            Picker("Charter", selection: $launchCharterID) {
                                ForEach(benchRoutingSections) { section in
                                    Section(section.title) {
                                        ForEach(section.candidates) { candidate in
                                            Text("\(candidate.title) • \(candidate.roleTitle)")
                                                .tag(candidate.charterId)
                                        }
                                    }
                                }
                            }
                            .pickerStyle(.menu)

                            if let selectedLaunchRoutingSection {
                                Text(selectedLaunchRoutingSection.helperText)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            if let selectedLaunchRoutingCandidate {
                                BenchRoutingSummaryCard(presentation: selectedLaunchRoutingCandidate)
                            }

                            Picker("Task", selection: $launchTaskID) {
                                Text("None").tag(String?.none)
                                ForEach(launchableTasks) { task in
                                    Text(task.title).tag(Optional(task.taskId))
                                }
                            }
                            .pickerStyle(.menu)

                            Toggle("Draft Signal From Finding", isOn: $launchDraftSignal)

                            HStack(spacing: 8) {
                                Button("Run Once") {
                                    runWorkerOnce()
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(launchInFlight || launchCharterID.isEmpty)

                                if launchInFlight {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            }

                            if let launchFeedback, !launchFeedback.isEmpty {
                                Text(launchFeedback)
                                    .font(.footnote)
                                    .foregroundStyle(launchFeedbackIsError ? .red : .green)
                            }

                            if let result = appModel.lastAnalystWorkerLaunch {
                                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                                    GridRow { Text("Last Charter"); Text(result.charterId) }
                                    GridRow { Text("Last Task"); Text(result.taskId ?? "-") }
                                    GridRow { Text("Last Finding"); Text(result.findingId ?? "-") }
                                    GridRow { Text("Last Signal"); Text(result.draftedSignalId ?? "-") }
                                    GridRow { Text("Summary"); Text(result.summary) }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("Strategy Follow-Up Candidates") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Open PM strategy follow-up candidates stay here as compact advanced review items. They remain separate from the actual Portfolio Strategy Brief, PM decisions, approvals, signals, proposals, and standing reports.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)

                            if strategyFollowUpCandidates.isEmpty {
                                Text("No strategy follow-up candidates are currently open or recorded.")
                                    .foregroundStyle(.secondary)
                            } else {
                                if recentStrategicChangeCandidates.isEmpty == false {
                                    GroupBox("Recent Strategic Changes") {
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text("Recently closed candidates summarize what changed, what durable PM or strategy artifact resulted, and whether the current Strategy Brief changed only through the explicit user-driven path.")
                                                .font(.footnote)
                                                .foregroundStyle(.secondary)

                                            ForEach(recentStrategicChangeCandidates) { candidate in
                                                recentStrategicChangeRow(candidate)
                                            }
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }

                                HStack(alignment: .top, spacing: 12) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        if openStrategyFollowUpCandidates.isEmpty == false {
                                            Text("Open Strategy Follow-Up Candidates")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.secondary)
                                            ForEach(openStrategyFollowUpCandidates) { candidate in
                                                strategyFollowUpCandidateRow(candidate)
                                            }
                                        }

                                        if closedStrategyFollowUpCandidates.isEmpty == false {
                                            Text("Recently Closed Strategy Follow-Up Candidates")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.secondary)
                                                .padding(.top, openStrategyFollowUpCandidates.isEmpty ? 0 : 4)
                                            ForEach(closedStrategyFollowUpCandidates.prefix(4)) { candidate in
                                                strategyFollowUpCandidateRow(candidate)
                                            }
                                        }
                                    }
                                    .frame(maxWidth: 320, alignment: .leading)

                                    Divider()

                                    if let selectedStrategyFollowUpCandidate {
                                        strategyFollowUpCandidateDetail(selectedStrategyFollowUpCandidate)
                                    } else {
                                        Text("Select a strategy follow-up candidate to inspect the implication linkage, current status, and next-step meaning.")
                                            .foregroundStyle(.secondary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("Source Access Suggestions") {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Analyst source-access suggestions stay here as compact research-governance review items. They remain distinct from memos, findings, evidence bundles, PM decisions, approvals, strategy-change requests, and standing reports.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)

                            if sourceAccessSuggestions.isEmpty {
                                Text("No source access suggestions are currently recorded.")
                                    .foregroundStyle(.secondary)
                            } else {
                                HStack(alignment: .top, spacing: 12) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        if openSourceAccessSuggestions.isEmpty == false {
                                            Text("Open Source Suggestions")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.secondary)
                                            ForEach(openSourceAccessSuggestions.prefix(4)) { suggestion in
                                                sourceAccessSuggestionRow(suggestion)
                                            }
                                        }

                                        if closedSourceAccessSuggestions.isEmpty == false {
                                            Text("Recently Closed Source Suggestions")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.secondary)
                                                .padding(.top, openSourceAccessSuggestions.isEmpty ? 0 : 4)
                                            ForEach(closedSourceAccessSuggestions.prefix(4)) { suggestion in
                                                sourceAccessSuggestionRow(suggestion)
                                            }
                                        }
                                    }
                                    .frame(maxWidth: 320, alignment: .leading)

                                    Divider()

                                    if let selectedSourceAccessSuggestion {
                                        sourceAccessSuggestionDetail(selectedSourceAccessSuggestion)
                                    } else {
                                        Text("Select a source access suggestion to inspect the requested source, current limitation, and analyst linkage.")
                                            .foregroundStyle(.secondary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("Task Editor") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(selectedTask == nil ? "Create a task under a charter." : "Edit the selected task.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)

                            Picker("Charter", selection: $taskCharterID) {
                                ForEach(benchRoutingSections) { section in
                                    Section(section.title) {
                                        ForEach(section.candidates) { candidate in
                                            Text("\(candidate.title) • \(candidate.roleTitle)")
                                                .tag(candidate.charterId)
                                        }
                                    }
                                }
                            }
                            .pickerStyle(.menu)

                            if let selectedTaskRoutingSection {
                                Text(selectedTaskRoutingSection.helperText)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            if let selectedTaskRoutingCandidate {
                                BenchRoutingSummaryCard(presentation: selectedTaskRoutingCandidate)
                            }

                            TextField("Task Title", text: $taskTitle)
                            TextField("Description", text: $taskDescription, axis: .vertical)
                                .lineLimit(3...5)

                            GroupBox("PM Tasking Brief") {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Use a durable PM brief to tell the analyst why this matters now, what answer shape is needed, and what would count as confirming or disconfirming evidence.")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                    TextField("Task Objective", text: $taskObjective)
                                    TextField("Why Now", text: $taskWhyNow)
                                    TextField("Review Lens", text: $taskReviewLens)
                                    Picker("Expected Answer Shape", selection: $taskExpectedAnswerShape) {
                                        Text("Not specified").tag(PMAnalystExpectedAnswerShape?.none)
                                        ForEach(PMAnalystExpectedAnswerShape.allCases, id: \.self) { shape in
                                            Text(pmAnalystExpectedAnswerShapeTitle(shape)).tag(Optional(shape))
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    TextField("Challenge Instruction", text: $taskChallengeInstruction)
                                    TextField("Evidence Expectation", text: $taskEvidenceExpectation)
                                    TextField("Disconfirming Evidence", text: $taskDisconfirmingEvidence)
                                    TextField("Expected Outputs (comma-separated)", text: $taskExpectedOutputs)
                                    TextField("Revision Reason", text: $taskRevisionReason)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            Picker("Status", selection: $taskStatus) {
                                ForEach(AnalystTaskStatus.allCases, id: \.self) { status in
                                    Text(status.rawValue).tag(status)
                                }
                            }
                            .pickerStyle(.segmented)

                            HStack(spacing: 8) {
                                TextField("Symbols (comma-separated)", text: $taskSymbols)
                                TextField("Tags (comma-separated)", text: $taskTags)
                            }

                            Toggle("Due Date", isOn: $taskDueEnabled)
                            if taskDueEnabled {
                                DatePicker("Due At", selection: $taskDueAt)
                            }

                            if let checkpoint = selectedTask?.checkpoint {
                                GroupBox("Current Checkpoint") {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(checkpoint.summary)
                                        if let nextAction = checkpoint.nextPlannedAction, !nextAction.isEmpty {
                                            Text("Next: \(nextAction)")
                                                .font(.footnote)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }

                            HStack(spacing: 8) {
                                Button(selectedTask == nil ? "Create Task" : "Save Task") {
                                    saveTask()
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(taskSaveInFlight || taskCharterID.isEmpty)

                                Button("New Task") {
                                    selectedTaskID = nil
                                    loadTaskEditor(from: nil)
                                }
                                .buttonStyle(.bordered)

                                if taskSaveInFlight {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            }

                            if let taskFeedback, !taskFeedback.isEmpty {
                                Text(taskFeedback)
                                    .font(.footnote)
                                    .foregroundStyle(taskFeedbackIsError ? .red : .green)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
        .onAppear {
            syncSelections()
        }
        .onChange(of: selectedTaskID) { _ in
            syncSelections()
        }
        .onChange(of: selectedDelegationID) { _ in
            loadFollowUpComposer(from: selectedDelegation, task: selectedTask)
        }
        .onChange(of: appModel.analystCharters) { _ in
            syncSelections()
        }
        .onChange(of: appModel.analystTasks) { _ in
            if let launchTaskID,
               !launchableTasks.contains(where: { $0.taskId == launchTaskID }) {
                self.launchTaskID = nil
            }
            if let selectedTaskID,
               !appModel.analystTasks.contains(where: { $0.taskId == selectedTaskID }) {
                self.selectedTaskID = nil
                loadTaskEditor(from: nil)
            }
        }
        .onChange(of: appModel.pmDelegations) { _ in
            syncSelections()
        }
        .onChange(of: appModel.analystStrategyFollowUpCandidates) { _ in
            syncSelections()
        }
        .onChange(of: appModel.analystSourceAccessSuggestions) { _ in
            syncSelections()
        }
        .onChange(of: launchCharterID) { newValue in
            if let launchTaskID,
               let task = appModel.analystTasks.first(where: { $0.taskId == launchTaskID }),
               task.charterId != newValue {
                self.launchTaskID = nil
            }
            if selectedTask == nil, taskCharterID != newValue, !newValue.isEmpty {
                taskCharterID = newValue
            }
        }
    }

    private func syncSelections() {
        if selectedDelegationID == nil {
            selectedDelegationID = recentDelegations.first?.delegationId
        }
        if let selectedDelegationID,
           !appModel.pmDelegations.contains(where: { $0.delegationId == selectedDelegationID }) {
            self.selectedDelegationID = recentDelegations.first?.delegationId
        }
        if launchCharterID.isEmpty {
            launchCharterID = selectedDelegation?.charterId
                ?? selectedTask?.charterId
                ?? appModel.analystCharters.first?.charterId
                ?? ""
        }
        loadTaskEditor(from: selectedTask)
        loadFollowUpComposer(from: selectedDelegation, task: selectedTask)
        if selectedTask == nil, let selectedDelegation {
            launchCharterID = selectedDelegation.charterId
            launchTaskID = selectedDelegation.taskId
        }
        if let selectedTask {
            launchTaskID = selectedTask.taskId
            if let charterId = selectedTask.charterId {
                launchCharterID = charterId
            }
        }
        if let selectedStrategyFollowUpCandidateID,
           !strategyFollowUpCandidates.contains(where: { $0.candidateId == selectedStrategyFollowUpCandidateID }) {
            self.selectedStrategyFollowUpCandidateID = openStrategyFollowUpCandidates.first?.candidateId
                ?? strategyFollowUpCandidates.first?.candidateId
        } else if self.selectedStrategyFollowUpCandidateID == nil {
            self.selectedStrategyFollowUpCandidateID = openStrategyFollowUpCandidates.first?.candidateId
                ?? strategyFollowUpCandidates.first?.candidateId
        }
        if let selectedSourceAccessSuggestionID,
           !sourceAccessSuggestions.contains(where: { $0.suggestionId == selectedSourceAccessSuggestionID }) {
            self.selectedSourceAccessSuggestionID = sourceAccessSuggestions.first?.suggestionId
        } else if self.selectedSourceAccessSuggestionID == nil {
            self.selectedSourceAccessSuggestionID = sourceAccessSuggestions.first?.suggestionId
        }
    }

    @ViewBuilder
    private func strategyFollowUpCandidateRow(_ candidate: AnalystStrategyFollowUpCandidateRecord) -> some View {
        let presentation = makeAnalystStrategyFollowUpCandidateReadablePresentation(candidate)
        Button {
            selectedStrategyFollowUpCandidateID = candidate.candidateId
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(candidate.followUpKind.displayTitle)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(candidate.candidateSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if candidate.status.isActive == false {
                    Text(presentation.resultSummary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    PMDelegationStatusBadge(
                        label: candidate.followUpKind.displayTitle,
                        color: .indigo
                    )
                    PMDelegationStatusBadge(
                        label: candidate.status.displayTitle,
                        color: candidate.status.isActive ? .orange : .secondary
                    )
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selectedStrategyFollowUpCandidateID == candidate.candidateId ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func recentStrategicChangeRow(_ candidate: AnalystStrategyFollowUpCandidateRecord) -> some View {
        let presentation = makeAnalystStrategyFollowUpCandidateReadablePresentation(candidate)

        Button {
            selectedStrategyFollowUpCandidateID = candidate.candidateId
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 8) {
                    Text(candidate.candidateSummary)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    PMDelegationStatusBadge(label: presentation.statusLabel, color: .secondary)
                }
                Text(presentation.resultSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selectedStrategyFollowUpCandidateID == candidate.candidateId ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func sourceAccessSuggestionRow(_ suggestion: AnalystSourceAccessSuggestionRecord) -> some View {
        let presentation = makeAnalystSourceAccessSuggestionReadablePresentation(suggestion)
        Button {
            selectedSourceAccessSuggestionID = suggestion.suggestionId
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(suggestion.requestedSource)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(suggestion.whyItMatters)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if suggestion.status.isActive == false {
                    Text(presentation.resultSummary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    PMDelegationStatusBadge(
                        label: presentation.statusLabel,
                        color: suggestion.status.isActive ? .orange : .secondary
                    )
                    if suggestion.status.isActive {
                        PMDelegationStatusBadge(label: presentation.nextStepLabel, color: .indigo)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selectedSourceAccessSuggestionID == suggestion.suggestionId ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func sourceAccessSuggestionDetail(_ suggestion: AnalystSourceAccessSuggestionRecord) -> some View {
        let presentation = makeAnalystSourceAccessSuggestionReadablePresentation(suggestion)
        let resolvedCharter = appModel.analystCharters.first(where: { $0.charterId == suggestion.resolvedCharterId })
        VStack(alignment: .leading, spacing: 12) {
            Text(suggestion.requestedSource)
                .font(.title3.weight(.semibold))

            HStack(spacing: 8) {
                PMDelegationStatusBadge(
                    label: presentation.statusLabel,
                    color: suggestion.status.isActive ? .orange : .secondary
                )
                PMDelegationStatusBadge(label: presentation.limitationLabel, color: .orange)
            }

            GroupBox("Suggestion Summary") {
                VStack(alignment: .leading, spacing: 6) {
                    OwnerReadableFactLine(title: "Requested Source:", value: suggestion.requestedSource)
                    if let requestedDomain = suggestion.requestedDomain, requestedDomain.isEmpty == false {
                        OwnerReadableFactLine(title: "Requested Domain:", value: requestedDomain)
                    }
                    OwnerReadableFactLine(title: "Current Limitation:", value: presentation.limitationLabel)
                    OwnerReadableFactLine(title: "Recommended Next Step:", value: presentation.nextStepLabel)
                    if let affectedTaskSummary = suggestion.affectedTaskSummary, affectedTaskSummary.isEmpty == false {
                        OwnerReadableFactLine(title: "Affected Task:", value: affectedTaskSummary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Why It Matters") {
                Text(suggestion.whyItMatters)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Linked Analyst Context") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(presentation.linkedArtifactsSummary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(presentation.boundaryNote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if suggestion.status.isActive {
                GroupBox("PM Source-Policy Actions") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Use explicit PM action to update bounded charter source policy. This does not grant instruction authority to external content and does not affect approvals, execution, or trading posture.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 8) {
                            Button("Add To Preferred Sources") {
                                Task {
                                    _ = await appModel.applyAnalystSourceAccessSuggestionAction(
                                        suggestionID: suggestion.suggestionId,
                                        action: .addToPreferredSources
                                    )
                                }
                            }
                            .buttonStyle(.borderedProminent)

                            Button("Add To Restricted Sources") {
                                Task {
                                    _ = await appModel.applyAnalystSourceAccessSuggestionAction(
                                        suggestionID: suggestion.suggestionId,
                                        action: .addToRestrictedSources
                                    )
                                }
                            }
                            .buttonStyle(.bordered)

                            Button("Dismiss") {
                                Task {
                                    _ = await appModel.applyAnalystSourceAccessSuggestionAction(
                                        suggestionID: suggestion.suggestionId,
                                        action: .dismiss
                                    )
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                GroupBox("Resolution") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(presentation.resultSummary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(presentation.closureSummary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if let resolvedCharter {
                            OwnerReadableFactLine(title: "Resolved Charter:", value: "\(resolvedCharter.title) (\(resolvedCharter.charterId))")
                        } else if let resolvedCharterId = suggestion.resolvedCharterId {
                            OwnerReadableFactLine(title: "Resolved Charter:", value: resolvedCharterId)
                        }
                        if let appliedPolicyEntry = suggestion.appliedPolicyEntry, appliedPolicyEntry.isEmpty == false {
                            OwnerReadableFactLine(title: "Applied Policy Entry:", value: appliedPolicyEntry)
                        }
                        if let resolvedBy = suggestion.resolvedBy, resolvedBy.isEmpty == false {
                            OwnerReadableFactLine(title: "Resolved By:", value: resolvedBy)
                        }
                        OwnerReadableFactLine(title: "Closed At:", value: suggestion.closedAt.map(sourceSuggestionDisplayDate) ?? "-")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private func strategyFollowUpCandidateDetail(_ candidate: AnalystStrategyFollowUpCandidateRecord) -> some View {
        let implication = appModel.analystStrategyImplications.first(where: { $0.implicationId == candidate.implicationId })
        let convertedInstruction = appModel.pmInstructions.first(where: { $0.instructionId == candidate.convertedInstructionId })
        let convertedMandate = appModel.pmMandates.first(where: { $0.mandateId == candidate.convertedMandateId })
        let appliedStrategyBrief = appModel.portfolioStrategyBrief?.briefId == candidate.appliedStrategyBriefId
            ? appModel.portfolioStrategyBrief
            : nil
        let presentation = makeAnalystStrategyFollowUpCandidateReadablePresentation(candidate)

        VStack(alignment: .leading, spacing: 12) {
            Text(candidate.followUpKind.displayTitle)
                .font(.title3.weight(.semibold))

            HStack(spacing: 8) {
                PMDelegationStatusBadge(label: presentation.kindLabel, color: .indigo)
                PMDelegationStatusBadge(
                    label: presentation.statusLabel,
                    color: candidate.status.isActive ? .orange : .secondary
                )
            }

            GroupBox("Candidate Summary") {
                Text(presentation.candidateSummary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("Follow-Up Detail") {
                Text(presentation.candidateDetail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let implication {
                GroupBox("Source Strategy Implication") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(implication.implicationKind.displayTitle)
                            .font(.subheadline.weight(.semibold))
                        Text(implication.implicationSummary)
                        Text(implication.whyItMatters)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

                GroupBox("Linked Analyst Context") {
                    VStack(alignment: .leading, spacing: 6) {
                        OwnerReadableFactLine(title: "Source Linkage:", value: presentation.linkedArtifactsSummary)
                        if candidate.followUpKind == .strategyBriefRevision {
                            Text("The saved Portfolio Strategy Brief remains unchanged until the user edits it directly or explicitly approves a routed strategy-change request through the app-owned owner-review path.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                        Text(presentation.boundaryNote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox(candidate.status.isActive ? "Current Outcome" : "Closure Result") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(presentation.resultSummary)
                    Text(presentation.closureSummary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if candidate.appliedStrategyBriefId != nil || candidate.convertedInstructionId != nil || candidate.convertedMandateId != nil {
                GroupBox("Resulting PM Artifact") {
                    VStack(alignment: .leading, spacing: 6) {
                        if let appliedStrategyBrief {
                            OwnerReadableFactLine(title: "Strategy Brief:", value: appliedStrategyBrief.title)
                            OwnerReadableFactLine(title: "Brief ID:", value: appliedStrategyBrief.briefId)
                            if let revisionSummary = appliedStrategyBrief.revisionSummary, revisionSummary.isEmpty == false {
                                OwnerReadableFactLine(title: "Revision Summary:", value: revisionSummary)
                            }
                        }
                        if let convertedInstruction {
                            OwnerReadableFactLine(title: "PM Instruction:", value: convertedInstruction.title)
                            OwnerReadableFactLine(title: "Instruction ID:", value: convertedInstruction.instructionId)
                        }
                        if let convertedMandate {
                            OwnerReadableFactLine(title: "PM Mandate:", value: convertedMandate.title)
                            OwnerReadableFactLine(title: "Mandate ID:", value: convertedMandate.mandateId)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            GroupBox("Candidate Status") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Use these bounded routing, convert, and lifecycle controls to keep PM follow-up traceability explicit without making the candidate itself become strategy truth. A Strategy Brief change only happens when the user edits the brief directly or explicitly approves a routed strategy-change request.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        if candidate.status.isActive, candidate.followUpKind == .strategyBriefRevision {
                            if let pendingRequest = linkedStrategyChangeApprovalRequest(for: candidate) {
                                Button("Open Pending User Strategy Review") {
                                    strategyCandidateFeedback = "A pending user strategy review already exists in PM Inbox for request \(pendingRequest.approvalRequestId)."
                                    strategyCandidateFeedbackIsError = false
                                }
                                .buttonStyle(.bordered)
                                .disabled(strategyCandidateInFlight)
                            } else {
                                Button("Route To User Strategy Review") {
                                    routeStrategyFollowUpCandidateToOwnerApproval(candidate)
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(strategyCandidateInFlight)
                            }
                        }

                        if candidate.status.isActive, candidate.followUpKind == .pmInstructionFollowUp {
                            Button("Convert To PM Instruction") {
                                convertStrategyFollowUpCandidateToInstruction(candidate)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(strategyCandidateInFlight)
                        }

                        if candidate.status.isActive, candidate.followUpKind == .pmMandateFollowUp {
                            Button("Convert To PM Mandate") {
                                convertStrategyFollowUpCandidateToMandate(candidate)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(strategyCandidateInFlight)
                        }

                        if candidate.status.isActive {
                            Button("Dismiss Candidate") {
                                updateStrategyFollowUpCandidateStatus(candidate, status: .dismissed)
                            }
                            .buttonStyle(.bordered)
                            .disabled(strategyCandidateInFlight)
                        }

                        if candidate.status == .dismissed {
                            Button("Reopen Candidate") {
                                let reopenedStatus: AnalystStrategyFollowUpCandidateStatus =
                                    candidate.followUpKind == .monitorOnly ? .monitoring : .open
                                updateStrategyFollowUpCandidateStatus(candidate, status: reopenedStatus)
                            }
                            .buttonStyle(.bordered)
                            .disabled(strategyCandidateInFlight)
                        }
                    }

                    if strategyCandidateInFlight {
                        ProgressView()
                            .controlSize(.small)
                    }

                    if let strategyCandidateFeedback, strategyCandidateFeedback.isEmpty == false {
                        Text(strategyCandidateFeedback)
                            .font(.footnote)
                            .foregroundStyle(strategyCandidateFeedbackIsError ? .red : .green)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func delegationRow(_ delegation: PMDelegationRecord) -> some View {
        let charter = appModel.analystCharters.first(where: { $0.charterId == delegation.charterId })
        let task = appModel.analystTasks.first(where: { $0.taskId == delegation.taskId })
        let summary = makePMDelegationObservabilitySummary(
            delegation: delegation,
            charterDefaultRuntimePolicy: charter?.defaultRuntimePolicy,
            task: task
        )
        let presentation = makePMDelegationReadablePresentation(
            delegation: delegation,
            charterTitle: charter?.title,
            taskTitle: task?.title,
            observability: summary,
            latestOutputSummary: latestDelegationOutputText(delegation, task: task)
        )
        Button {
            selectedDelegationID = delegation.delegationId
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(delegation.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(presentation.subheadline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(presentation.outcomeSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    PMDelegationStatusBadge(
                        label: summary.launchHealth.rawValue,
                        color: launchHealthColor(summary.launchHealth)
                    )
                    PMDelegationStatusBadge(
                        label: summary.executionState.rawValue,
                        color: executionStateColor(summary.executionState)
                    )
                    PMDelegationStatusBadge(
                        label: summary.workflowState.rawValue,
                        color: workflowStateColor(summary.workflowState)
                    )
                }
                OwnerReadableFactLine(title: "Execution Used:", value: presentation.executionUsedSummary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selectedDelegationID == delegation.delegationId ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func delegationDetail(_ delegation: PMDelegationRecord) -> some View {
        let charter = appModel.analystCharters.first(where: { $0.charterId == delegation.charterId })
        let task = appModel.analystTasks.first(where: { $0.taskId == delegation.taskId })
        let pmProfile = appModel.pmProfiles.first(where: { $0.pmId == delegation.pmId })
        let memo = latestAnalystMemo(
            in: appModel.analystMemos,
            delegationID: delegation.delegationId,
            taskID: task?.taskId,
            findingID: delegation.linkedFindingIDs.last ?? task?.checkpoint?.linkedFindingIDs.last
        )
        let linkedFinding = appModel.analystFindings.first(where: {
            $0.findingId == delegation.linkedFindingIDs.last || $0.findingId == task?.checkpoint?.linkedFindingIDs.last
        })
        let resolvedEvidenceBundle = linkedEvidenceBundle(
            memo: memo,
            finding: linkedFinding
        )
        let summary = makePMDelegationObservabilitySummary(
            delegation: delegation,
            charterDefaultRuntimePolicy: charter?.defaultRuntimePolicy,
            task: task
        )
        let producedOutputs = summary.producedOutputs.map(\.rawValue).joined(separator: ", ")
        let requestedOutputs = delegation.requestedOutputs.map(\.rawValue).joined(separator: ", ")

        VStack(alignment: .leading, spacing: 12) {
            Text(delegation.title)
                .font(.title3.weight(.semibold))

            HStack(spacing: 8) {
                PMDelegationStatusBadge(
                    label: summary.launchHealth.rawValue,
                    color: launchHealthColor(summary.launchHealth)
                )
                PMDelegationStatusBadge(
                    label: summary.executionState.rawValue,
                    color: executionStateColor(summary.executionState)
                )
                PMDelegationStatusBadge(
                    label: summary.workflowState.rawValue,
                    color: workflowStateColor(summary.workflowState)
                )
                Text(delegation.status.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            GroupBox("Delegation Summary") {
                VStack(alignment: .leading, spacing: 8) {
                    OwnerReadableFactLine(title: "PM:", value: pmProfile.map { "\($0.displayName) (\($0.pmId))" } ?? delegation.pmId)
                    OwnerReadableFactLine(title: "Requested Outputs:", value: requestedOutputs.isEmpty ? "-" : requestedOutputs)
                    OwnerReadableFactLine(title: "Produced Outputs:", value: producedOutputs.isEmpty ? "-" : producedOutputs)
                    OwnerReadableFactLine(title: "Execution State:", value: summary.executionState.rawValue)
                    if let stage = summary.progressStage, !stage.isEmpty {
                        OwnerReadableFactLine(title: "Execution Stage:", value: stage)
                    }
                    if let lastProgressAt = summary.lastProgressAt {
                        OwnerReadableFactLine(title: "Last Progress:", value: formattedDate(lastProgressAt))
                    }
                    OwnerReadableFactLine(title: "Last Updated:", value: formattedDate(delegation.updatedAt))
                    if let currentSessionResult = appModel.lastAnalystWorkerLaunch,
                       currentSessionResult.delegationId == delegation.delegationId,
                       !currentSessionResult.outputExcerpt.isEmpty {
                        Text(currentSessionResult.outputExcerpt)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            DelegationContextGroup(
                delegation: delegation,
                charterTitle: charter?.title,
                taskTitle: task?.title,
                latestOutputSummary: latestDelegationOutputText(delegation, task: task),
                observability: summary,
                memo: memo,
                linkedFinding: linkedFinding,
                linkedEvidenceBundle: resolvedEvidenceBundle,
                linkedSourceAccessSuggestions: linkedAnalystSourceAccessSuggestions(
                    in: appModel.analystSourceAccessSuggestions,
                    memo: memo,
                    finding: linkedFinding,
                    evidenceBundle: resolvedEvidenceBundle,
                    delegation: delegation
                ),
                linkedStrategyImplication: linkedAnalystStrategyImplication(
                    in: appModel.analystStrategyImplications,
                    memo: memo,
                    finding: linkedFinding,
                    delegation: delegation
                ),
                linkedStrategyFollowUpCandidates: linkedAnalystStrategyFollowUpCandidates(
                    in: appModel.analystStrategyFollowUpCandidates,
                    implication: linkedAnalystStrategyImplication(
                        in: appModel.analystStrategyImplications,
                        memo: memo,
                        finding: linkedFinding,
                        delegation: delegation
                    )
                ),
                defaultStrategyImplicationPMID: preferredStrategyImplicationPMID(
                    memo: memo,
                    delegation: delegation,
                    fallbackPMID: nil,
                    contextPMID: appModel.pmContextPack?.pmId,
                    pmProfiles: appModel.pmProfiles
                ),
                onSaveStrategyImplication: appModel.upsertAnalystStrategyImplication,
                onSaveStrategyFollowUpCandidate: appModel.upsertAnalystStrategyFollowUpCandidate
            )

            if let checkpoint = task?.checkpoint {
                GroupBox("Task Checkpoint") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(checkpoint.summary)
                        if let nextAction = checkpoint.nextPlannedAction, !nextAction.isEmpty {
                            Text("Next: \(nextAction)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            GroupBox("PM Follow-Up") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Choose the one bounded PM management action that best explains what the bench needs next. This keeps lineage and runtime provenance intact without turning follow-up into generic workflow churn.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Picker("Action", selection: $followUpActionType) {
                        ForEach(PMAnalystFollowUpActionType.allCases, id: \.self) { action in
                            Text(pmAnalystFollowUpActionTitle(action)).tag(action)
                        }
                    }
                    .pickerStyle(.menu)

                    GroupBox("PM Management Intent") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(followUpGuidance.managerialIntent)
                                .font(.subheadline.weight(.semibold))
                            Text("Use when: \(followUpGuidance.useCase)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Text("Next step meaning: \(followUpGuidance.nextStepMeaning)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    TextField("PM Follow-Up Note", text: $followUpSummary, axis: .vertical)
                        .lineLimit(2...4)

                    GroupBox("Tasking Brief") {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Task Objective", text: $followUpTaskObjective)
                            TextField("Why Now", text: $followUpWhyNow)
                            TextField("Review Lens", text: $followUpReviewLens)
                            Picker("Expected Answer Shape", selection: $followUpExpectedAnswerShape) {
                                Text("Not specified").tag(PMAnalystExpectedAnswerShape?.none)
                                ForEach(PMAnalystExpectedAnswerShape.allCases, id: \.self) { shape in
                                    Text(pmAnalystExpectedAnswerShapeTitle(shape)).tag(Optional(shape))
                                }
                            }
                            .pickerStyle(.menu)
                            TextField("Challenge Instruction", text: $followUpChallengeInstruction)
                            TextField("Evidence Expectation", text: $followUpEvidenceExpectation)
                            TextField("Disconfirming Evidence", text: $followUpDisconfirmingEvidence)
                            TextField("Expected Outputs (comma-separated)", text: $followUpExpectedOutputs)
                            TextField("Revision Reason", text: $followUpRevisionReason)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if followUpActionType == .rerouteToAnalyst {
                        Picker("Reroute To", selection: $followUpRequestedCharterID) {
                            ForEach(benchRoutingSections) { section in
                                Section(section.title) {
                                    ForEach(section.candidates) { candidate in
                                        Text("\(candidate.title) • \(candidate.roleTitle)")
                                            .tag(candidate.charterId)
                                    }
                                }
                            }
                        }
                        .pickerStyle(.menu)

                        if let selectedFollowUpRoutingSection {
                            Text(selectedFollowUpRoutingSection.helperText)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        if let selectedFollowUpRoutingCandidate {
                            BenchRoutingSummaryCard(presentation: selectedFollowUpRoutingCandidate)
                        }
                    }

                    if followUpActionType == .rerunWithRuntime {
                        TextField("Requested Runtime Identifier", text: $followUpRuntimeIdentifier)
                        Picker("Reasoning", selection: $followUpReasoningMode) {
                            ForEach(AnalystRuntimeReasoningMode.allCases, id: \.self) { mode in
                                Text(mode.rawValue.capitalized).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    HStack(spacing: 8) {
                        Button(followUpActionType == .accept ? "Record Acceptance" : "Run Follow-Up") {
                            submitDelegationFollowUp(delegation)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(followUpInFlight)

                        if followUpInFlight {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }

                    if let followUpFeedback, !followUpFeedback.isEmpty {
                        Text(followUpFeedback)
                            .font(.footnote)
                            .foregroundStyle(followUpFeedbackIsError ? .red : .green)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                Button("Run Delegation") {
                    runDelegation(delegation)
                }
                .buttonStyle(.borderedProminent)
                .disabled(launchInFlight)

                if isActivePMDelegationWorkerIssue(delegation: delegation, summary: summary) {
                    Button("Mark Worker Issue Resolved") {
                        resolveDelegationWorkerIssue(delegation)
                    }
                    .buttonStyle(.bordered)
                    .disabled(launchInFlight)
                }
            }

            if launchInFlight {
                ProgressView()
                    .controlSize(.small)
            }
            if let launchFeedback, !launchFeedback.isEmpty {
                Text(launchFeedback)
                    .font(.footnote)
                    .foregroundStyle(launchFeedbackIsError ? .red : .green)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func loadTaskEditor(from task: AnalystTask?) {
        if let task {
            taskTitle = task.title
            taskDescription = task.description
            taskCharterID = task.charterId ?? appModel.analystCharters.first?.charterId ?? ""
            taskObjective = task.pmTaskingBrief?.taskObjective ?? ""
            taskWhyNow = task.pmTaskingBrief?.whyNow ?? ""
            taskReviewLens = task.pmTaskingBrief?.reviewLens ?? ""
            taskExpectedAnswerShape = task.pmTaskingBrief?.expectedAnswerShape
            taskChallengeInstruction = task.pmTaskingBrief?.challengeInstruction ?? ""
            taskEvidenceExpectation = task.pmTaskingBrief?.evidenceExpectation ?? ""
            taskDisconfirmingEvidence = task.pmTaskingBrief?.disconfirmingEvidenceExpectation ?? ""
            taskExpectedOutputs = task.pmTaskingBrief?.expectedOutputs.joined(separator: ", ") ?? ""
            taskRevisionReason = task.pmTaskingBrief?.revisionReason ?? ""
            taskStatus = task.status
            taskSymbols = task.symbols.joined(separator: ", ")
            taskTags = task.tags.joined(separator: ", ")
            if let dueAt = task.dueAt {
                taskDueEnabled = true
                taskDueAt = dueAt
            } else {
                taskDueEnabled = false
                taskDueAt = Date()
            }
        } else {
            taskTitle = ""
            taskDescription = ""
            taskCharterID = launchCharterID.isEmpty ? (appModel.analystCharters.first?.charterId ?? "") : launchCharterID
            taskObjective = ""
            taskWhyNow = ""
            taskReviewLens = ""
            taskExpectedAnswerShape = nil
            taskChallengeInstruction = ""
            taskEvidenceExpectation = ""
            taskDisconfirmingEvidence = ""
            taskExpectedOutputs = ""
            taskRevisionReason = ""
            taskStatus = .queued
            taskSymbols = ""
            taskTags = ""
            taskDueEnabled = false
            taskDueAt = Date()
        }
    }

    private func updateStrategyFollowUpCandidateStatus(
        _ candidate: AnalystStrategyFollowUpCandidateRecord,
        status: AnalystStrategyFollowUpCandidateStatus
    ) {
        strategyCandidateFeedback = nil
        strategyCandidateFeedbackIsError = false
        strategyCandidateInFlight = true

        Task { @MainActor in
            let updated = AnalystStrategyFollowUpCandidateRecord(
                candidateId: candidate.candidateId,
                implicationId: candidate.implicationId,
                pmId: candidate.pmId,
                followUpKind: candidate.followUpKind,
                status: status,
                candidateSummary: candidate.candidateSummary,
                candidateDetail: candidate.candidateDetail,
                memoId: candidate.memoId,
                findingId: candidate.findingId,
                evidenceBundleId: candidate.evidenceBundleId,
                delegationId: candidate.delegationId,
                appliedStrategyBriefId: status.isActive ? nil : candidate.appliedStrategyBriefId,
                convertedInstructionId: status.isActive ? nil : candidate.convertedInstructionId,
                convertedMandateId: status.isActive ? nil : candidate.convertedMandateId,
                closedAt: status.isActive ? nil : Date(),
                createdAt: candidate.createdAt,
                updatedAt: Date()
            )
            let error = await appModel.upsertAnalystStrategyFollowUpCandidate(updated)
            strategyCandidateInFlight = false
            if let error, error.isEmpty == false {
                strategyCandidateFeedback = error
                strategyCandidateFeedbackIsError = true
                return
            }
            strategyCandidateFeedback = "Candidate marked \(status.displayTitle.lowercased())."
            strategyCandidateFeedbackIsError = false
        }
    }

    private func routeStrategyFollowUpCandidateToOwnerApproval(_ candidate: AnalystStrategyFollowUpCandidateRecord) {
        strategyCandidateFeedback = nil
        strategyCandidateFeedbackIsError = false
        strategyCandidateInFlight = true

        Task { @MainActor in
            let error = await appModel.routeAnalystStrategyFollowUpCandidateToOwnerApproval(
                candidateID: candidate.candidateId
            )
            strategyCandidateInFlight = false
            if let error, error.isEmpty == false {
                strategyCandidateFeedback = error
                strategyCandidateFeedbackIsError = true
                return
            }
            strategyCandidateFeedback = "Routed the candidate into explicit user strategy review with current portfolio context. Review it in PM Inbox."
            strategyCandidateFeedbackIsError = false
        }
    }

    private func applyStrategyFollowUpCandidateToStrategyBrief(_ candidate: AnalystStrategyFollowUpCandidateRecord) {
        strategyCandidateFeedback = nil
        strategyCandidateFeedbackIsError = false
        strategyCandidateInFlight = true

        Task { @MainActor in
            let updatedBy = appModel.pmProfiles.first(where: { $0.pmId == candidate.pmId })?.displayName
                ?? candidate.pmId
            let error = await appModel.applyAnalystStrategyFollowUpCandidateToStrategyBrief(
                candidateID: candidate.candidateId,
                updatedBy: updatedBy
            )
            strategyCandidateInFlight = false
            if let error, error.isEmpty == false {
                strategyCandidateFeedback = error
                strategyCandidateFeedbackIsError = true
                return
            }
            strategyCandidateFeedback = "Candidate applied to the Portfolio Strategy Brief."
            strategyCandidateFeedbackIsError = false
        }
    }

    private func linkedStrategyChangeApprovalRequest(
        for candidate: AnalystStrategyFollowUpCandidateRecord
    ) -> PMApprovalRequest? {
        appModel.pmApprovalRequests
            .filter {
                $0.requestType == .strategyChange
                    && $0.status == .pending
                    && $0.sourceAnalystStrategyFollowUpCandidateId == candidate.candidateId
            }
            .sorted { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.approvalRequestId < rhs.approvalRequestId
                }
                return lhs.updatedAt > rhs.updatedAt
            }
            .first
    }

    private func convertStrategyFollowUpCandidateToInstruction(_ candidate: AnalystStrategyFollowUpCandidateRecord) {
        strategyCandidateFeedback = nil
        strategyCandidateFeedbackIsError = false
        strategyCandidateInFlight = true

        Task { @MainActor in
            let error = await appModel.convertAnalystStrategyFollowUpCandidateToInstruction(
                candidateID: candidate.candidateId
            )
            strategyCandidateInFlight = false
            if let error, error.isEmpty == false {
                strategyCandidateFeedback = error
                strategyCandidateFeedbackIsError = true
                return
            }
            strategyCandidateFeedback = "Candidate converted to a durable PM instruction."
            strategyCandidateFeedbackIsError = false
        }
    }

    private func convertStrategyFollowUpCandidateToMandate(_ candidate: AnalystStrategyFollowUpCandidateRecord) {
        strategyCandidateFeedback = nil
        strategyCandidateFeedbackIsError = false
        strategyCandidateInFlight = true

        Task { @MainActor in
            let error = await appModel.convertAnalystStrategyFollowUpCandidateToMandate(
                candidateID: candidate.candidateId
            )
            strategyCandidateInFlight = false
            if let error, error.isEmpty == false {
                strategyCandidateFeedback = error
                strategyCandidateFeedbackIsError = true
                return
            }
            strategyCandidateFeedback = "Candidate converted to a durable PM mandate."
            strategyCandidateFeedbackIsError = false
        }
    }

    private func strategyFollowUpCandidatesNewestFirst(
        lhs: AnalystStrategyFollowUpCandidateRecord,
        rhs: AnalystStrategyFollowUpCandidateRecord
    ) -> Bool {
        let lhsDate = lhs.closedAt ?? lhs.updatedAt
        let rhsDate = rhs.closedAt ?? rhs.updatedAt
        if lhsDate == rhsDate {
            return lhs.candidateId < rhs.candidateId
        }
        return lhsDate > rhsDate
    }

    private func sourceAccessSuggestionsNewestFirst(
        lhs: AnalystSourceAccessSuggestionRecord,
        rhs: AnalystSourceAccessSuggestionRecord
    ) -> Bool {
        let lhsDate = lhs.closedAt ?? lhs.updatedAt
        let rhsDate = rhs.closedAt ?? rhs.updatedAt
        if lhsDate == rhsDate {
            return lhs.suggestionId < rhs.suggestionId
        }
        return lhsDate > rhsDate
    }

    private func sourceSuggestionDisplayDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func saveTask() {
        let trimmedTitle = taskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = taskDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, !trimmedDescription.isEmpty else {
            taskFeedback = "Task title and description are required."
            taskFeedbackIsError = true
            return
        }
        guard let charter = appModel.analystCharters.first(where: { $0.charterId == taskCharterID }) else {
            taskFeedback = "Select a valid charter."
            taskFeedbackIsError = true
            return
        }

        let now = Date()
        let existing = selectedTask
        let task = AnalystTask(
            taskId: existing?.taskId ?? "task-\(UUID().uuidString.lowercased())",
            analystId: charter.analystId,
            charterId: charter.charterId,
            parentTaskId: existing?.parentTaskId,
            title: trimmedTitle,
            description: trimmedDescription,
            pmTaskingBrief: makeTaskingBrief(
                taskObjective: taskObjective,
                whyNow: taskWhyNow,
                reviewLens: taskReviewLens,
                expectedAnswerShape: taskExpectedAnswerShape,
                challengeInstruction: taskChallengeInstruction,
                evidenceExpectation: taskEvidenceExpectation,
                disconfirmingEvidenceExpectation: taskDisconfirmingEvidence,
                expectedOutputsText: taskExpectedOutputs,
                revisionReason: taskRevisionReason
            ),
            status: taskStatus,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now,
            dueAt: taskDueEnabled ? taskDueAt : nil,
            symbols: csvList(from: taskSymbols),
            tags: csvList(from: taskTags),
            lastCheckpointSummary: existing?.lastCheckpointSummary,
            checkpoint: existing?.checkpoint,
            linkedFindingIDs: existing?.linkedFindingIDs ?? [],
            linkedProposalIDs: existing?.linkedProposalIDs ?? []
        )

        taskSaveInFlight = true
        taskFeedback = nil
        Task { @MainActor in
            defer { taskSaveInFlight = false }
            taskFeedback = await appModel.upsertAnalystTask(task)
            taskFeedbackIsError = taskFeedback != nil
            if taskFeedback == nil {
                taskFeedback = existing == nil ? "Created task." : "Saved task changes."
                taskFeedbackIsError = false
                selectedTaskID = task.taskId
                launchCharterID = task.charterId ?? launchCharterID
                launchTaskID = task.taskId
            }
        }
    }

    private func loadFollowUpComposer(from delegation: PMDelegationRecord?, task: AnalystTask?) {
        let existingBrief = delegation?.taskingBrief ?? task?.pmTaskingBrief
        followUpTaskObjective = existingBrief?.taskObjective ?? ""
        followUpWhyNow = existingBrief?.whyNow ?? ""
        followUpReviewLens = existingBrief?.reviewLens ?? ""
        followUpExpectedAnswerShape = existingBrief?.expectedAnswerShape
        followUpChallengeInstruction = existingBrief?.challengeInstruction ?? ""
        followUpEvidenceExpectation = existingBrief?.evidenceExpectation ?? ""
        followUpDisconfirmingEvidence = existingBrief?.disconfirmingEvidenceExpectation ?? ""
        followUpExpectedOutputs = existingBrief?.expectedOutputs.joined(separator: ", ") ?? ""
        followUpRevisionReason = existingBrief?.revisionReason ?? ""
        followUpRequestedCharterID = delegation?.charterId ?? task?.charterId ?? appModel.analystCharters.first?.charterId ?? ""
        followUpRuntimeIdentifier = delegation?.runtimePolicyOverride?.runtimeIdentifier ?? ""
        followUpReasoningMode = delegation?.runtimePolicyOverride?.reasoningMode ?? .standard
        let latestAction = delegation?.followUpActions.last
        followUpSummary = latestAction?.summary ?? ""
    }

    private func makeTaskingBrief(
        taskObjective: String,
        whyNow: String,
        reviewLens: String,
        expectedAnswerShape: PMAnalystExpectedAnswerShape?,
        challengeInstruction: String,
        evidenceExpectation: String,
        disconfirmingEvidenceExpectation: String,
        expectedOutputsText: String,
        revisionReason: String
    ) -> PMTaskingBrief? {
        let brief = PMTaskingBrief(
            taskObjective: taskObjective,
            whyNow: whyNow,
            reviewLens: reviewLens,
            expectedAnswerShape: expectedAnswerShape,
            challengeInstruction: challengeInstruction,
            evidenceExpectation: evidenceExpectation,
            disconfirmingEvidenceExpectation: disconfirmingEvidenceExpectation,
            expectedOutputs: csvList(from: expectedOutputsText),
            revisionReason: revisionReason
        )
        return pmTaskingBriefHasContent(brief) ? brief : nil
    }

    private func submitDelegationFollowUp(_ delegation: PMDelegationRecord) {
        let requestedRuntimePolicy: AnalystRuntimePolicy?
        if followUpActionType == .rerunWithRuntime {
            requestedRuntimePolicy = AnalystRuntimePolicy(
                runtimeIdentifier: followUpRuntimeIdentifier,
                reasoningMode: followUpReasoningMode,
                policySource: .pmDelegationOverride,
                createdAt: Date(),
                updatedAt: Date()
            )
        } else {
            requestedRuntimePolicy = nil
        }

        let request = PMDelegationFollowUpRequest(
            sourceDelegationId: delegation.delegationId,
            actionType: followUpActionType,
            summary: followUpSummary,
            requestedCharterId: followUpActionType == .rerouteToAnalyst ? followUpRequestedCharterID : nil,
            requestedRuntimePolicy: requestedRuntimePolicy,
            taskingBrief: makeTaskingBrief(
                taskObjective: followUpTaskObjective,
                whyNow: followUpWhyNow,
                reviewLens: followUpReviewLens,
                expectedAnswerShape: followUpExpectedAnswerShape,
                challengeInstruction: followUpChallengeInstruction,
                evidenceExpectation: followUpEvidenceExpectation,
                disconfirmingEvidenceExpectation: followUpDisconfirmingEvidence,
                expectedOutputsText: followUpExpectedOutputs,
                revisionReason: followUpRevisionReason
            )
        )

        followUpInFlight = true
        followUpFeedback = nil
        Task { @MainActor in
            defer { followUpInFlight = false }
            let error = await appModel.submitPMDelegationFollowUp(request)
            followUpFeedbackIsError = error != nil
            if let error {
                followUpFeedback = error
                return
            }

            if let result = appModel.lastPMDelegationFollowUp {
                if let createdDelegationId = result.createdDelegationId {
                    selectedDelegationID = createdDelegationId
                }
                followUpFeedback = pmFollowUpWorkflowSummary(
                    sourceDelegation: delegation,
                    result: result
                )
            } else {
                followUpFeedback = "PM follow-up recorded."
            }
            followUpFeedbackIsError = false
        }
    }

    private func runWorkerOnce() {
        launchInFlight = true
        launchFeedback = nil
        Task { @MainActor in
            defer { launchInFlight = false }
            let error = await appModel.launchAnalystWorkerOnce(
                charterID: launchCharterID,
                taskID: launchTaskID,
                draftSignal: launchDraftSignal
            )
            launchFeedbackIsError = error != nil
            if let error {
                launchFeedback = error
            } else {
                launchFeedback = appModel.lastAnalystWorkerLaunch?.summary ?? "Worker completed."
                if let taskId = appModel.lastAnalystWorkerLaunch?.taskId {
                    selectedTaskID = taskId
                    launchTaskID = taskId
                }
            }
        }
    }

    private func runDelegation(_ delegation: PMDelegationRecord) {
        launchInFlight = true
        launchFeedback = nil
        let wantsProposal = delegation.requestedOutputs.contains(.proposalDraft)
        let wantsSignal = wantsProposal || delegation.requestedOutputs.contains(.signal)
        Task { @MainActor in
            defer { launchInFlight = false }
            let error = await appModel.launchAnalystWorkerForDelegation(
                delegationID: delegation.delegationId,
                draftSignal: wantsSignal,
                draftProposal: wantsProposal
            )
            launchFeedbackIsError = error != nil
            if let error {
                launchFeedback = error
            } else {
                launchFeedback = appModel.lastAnalystWorkerLaunch?.summary ?? "Delegation launched."
                if let taskID = delegation.taskId {
                    selectedTaskID = taskID
                    launchTaskID = taskID
                }
            }
        }
    }

    private func resolveDelegationWorkerIssue(_ delegation: PMDelegationRecord) {
        launchInFlight = true
        launchFeedback = nil
        Task { @MainActor in
            defer { launchInFlight = false }
            let error = await appModel.resolvePMDelegationWorkerIssue(
                delegationId: delegation.delegationId
            )
            launchFeedbackIsError = error != nil
            if let error {
                launchFeedback = error
            } else {
                launchFeedback = "Worker issue resolved from active surfaces. Delegation history remains traceable."
            }
        }
    }

    private func csvList(from text: String) -> [String] {
        text
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func runtimePolicyText(_ policy: AnalystRuntimePolicy?) -> String {
        analystRequestedRuntimeText(policy)
    }

    private func actualRuntimeText(_ provenance: AnalystRuntimeProvenance?) -> String {
        analystActualRuntimeText(provenance)
    }

    private func launchHealthColor(_ health: PMDelegationLaunchHealth) -> Color {
        switch health {
        case .notLaunched:
            return .secondary
        case .healthy:
            return .green
        case .degradedExternalEvidence:
            return .orange
        case .failed:
            return .red
        }
    }

    private func executionStateColor(_ state: PMDelegationExecutionState) -> Color {
        pmExecutionStateColor(state)
    }

    private func workflowStateColor(_ state: PMDelegationWorkflowState) -> Color {
        switch state {
        case .noOutputsYet:
            return .secondary
        case .awaitingDownstreamReview:
            return .blue
        case .resolved:
            return .green
        case .canceled:
            return .red
        }
    }

    private func formattedDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    private func linkedEvidenceBundle(
        memo: AnalystMemo?,
        finding: AnalystFinding?
    ) -> AnalystEvidenceBundle? {
        let bundleID = memo?.evidenceBundleId ?? finding?.evidenceBundleId
        guard let bundleID else {
            return nil
        }
        return appModel.analystEvidenceBundles.first(where: { $0.bundleId == bundleID })
    }
}

struct SignalsView: View {
    @EnvironmentObject private var appModel: AppModel
    @Binding var selectedTab: MainTab

    @State private var selectedSignalID: String?
    @State private var statusFilter: SignalStatus? = nil
    @State private var feedbackMessage: String?
    @State private var inFlight = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Signals")
                    .font(.title2)
                Spacer()
                Picker(
                    "Status",
                    selection: statusFilterBinding
                ) {
                    Text("All").tag("all")
                    ForEach(SignalStatus.allCases, id: \.rawValue) { status in
                        Text(status.rawValue.capitalized).tag(status.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 140)
                Button("Refresh") {
                    Task { @MainActor in
                        feedbackMessage = await appModel.refreshSignals(status: statusFilter, limit: 200)
                    }
                }
                .buttonStyle(.bordered)
            }

            if let feedbackMessage, !feedbackMessage.isEmpty {
                Text(feedbackMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            NavigationSplitView {
                List(filteredSignals, selection: $selectedSignalID) { signal in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(signal.symbols.joined(separator: ", "))
                                    .font(.headline)
                                if signal.isAnalystOriginated {
                                    AnalystSignalBadge()
                                }
                            }
                            Spacer()
                            Text(signal.status.rawValue.uppercased())
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(statusColor(signal.status))
                        }
                        Text(signal.positionStatement)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        if let presentation = signalLineagePresentation(signal) {
                            Text("\(presentation.analystLabel) • \(presentation.taskLabel)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Text("\(signal.actionability.displayTitle) • confidence \(percent(signal.confidence)) • score \(percent(signal.score))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    .tag(signal.id)
                }
                .frame(minWidth: 280)
            } detail: {
                Group {
                    if let selectedSignal = selectedSignal {
                        detailView(signal: selectedSignal)
                    } else {
                        Text("Select a signal to review details.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    }
                }
            }
            .navigationSplitViewStyle(.balanced)
        }
        .padding(18)
        .onAppear {
            if selectedSignalID == nil {
                selectedSignalID = filteredSignals.first?.id
            }
        }
        .onChange(of: appModel.signals) { _ in
            if let selectedSignalID,
               !filteredSignals.contains(where: { $0.id == selectedSignalID }) {
                self.selectedSignalID = filteredSignals.first?.id
            } else if self.selectedSignalID == nil {
                self.selectedSignalID = filteredSignals.first?.id
            }
        }
    }

    private var statusFilterBinding: Binding<String> {
        Binding(
            get: { statusFilter?.rawValue ?? "all" },
            set: { newValue in
                statusFilter = (newValue == "all") ? nil : SignalStatus(rawValue: newValue)
            }
        )
    }

    private var filteredSignals: [Signal] {
        appModel.signals.filter { signal in
            guard isSuppressedPMTestingSignal(signal) == false else {
                return false
            }
            guard let statusFilter else {
                return true
            }
            return signal.status == statusFilter
        }
    }

    private var selectedSignal: Signal? {
        guard let selectedSignalID else {
            return nil
        }
        return filteredSignals.first(where: { $0.id == selectedSignalID })
    }

    private func signalLineagePresentation(_ signal: Signal) -> SignalLineageReadablePresentation? {
        makeSignalLineageReadablePresentation(
            signal: signal,
            charters: appModel.analystCharters,
            tasks: appModel.analystTasks,
            findings: appModel.analystFindings,
            evidenceBundles: appModel.analystEvidenceBundles
        )
    }

    @ViewBuilder
    private func detailView(signal: Signal) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(signal.positionStatement)
                    .font(.title3)

                if let presentation = signalLineagePresentation(signal) {
                    AnalystSignalBadge()
                    AnalystSignalLineageSection(presentation: presentation)
                }

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        Text("Signal ID")
                        Text(shortID(signal.signalId))
                            .font(.system(.body, design: .monospaced))
                    }
                    GridRow {
                        Text("Status")
                        Text(signal.status.rawValue.uppercased())
                            .foregroundStyle(statusColor(signal.status))
                    }
                    GridRow {
                        Text("Symbols")
                        Text(signal.symbols.joined(separator: ", "))
                    }
                    GridRow {
                        Text("Direction")
                        Text(signal.direction.rawValue)
                    }
                    GridRow {
                        Text("Horizon")
                        Text(signal.horizon.rawValue)
                    }
                    GridRow {
                        Text("Confidence")
                        Text(percent(signal.confidence))
                    }
                    GridRow {
                        Text("Score")
                        Text(percent(signal.score))
                    }
                    GridRow {
                        Text("Action")
                        Text(signal.recommendedAction.rawValue)
                    }
                    GridRow {
                        Text("Actionability")
                        Text(signal.actionability.displayTitle)
                    }
                    GridRow {
                        Text("Scoring Version")
                        Text(signal.provenance.scoringVersion)
                    }
                    GridRow {
                        Text("Source Job")
                        Text(signal.provenance.sourceJobId ?? "-")
                    }
                    GridRow {
                        Text("Updated")
                        Text(signal.updatedAt.formatted(date: .abbreviated, time: .standard))
                    }
                }

                GroupBox("Evidence") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(signal.evidence.enumerated()), id: \.offset) { _, evidence in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(evidence.type.rawValue.uppercased()): \(evidence.title)")
                                    .font(.headline)
                                if let summary = evidence.summary, !summary.isEmpty {
                                    Text(summary)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                HStack(spacing: 10) {
                                    Text(evidence.timestamp.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if let urlString = evidence.url,
                                       let url = URL(string: urlString) {
                                        Link("Open", destination: url)
                                            .font(.caption)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 8) {
                    Button("Acknowledge") {
                        updateSignalStatus(signalID: signal.signalId, archive: false)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(inFlight || signal.status == .acknowledged || signal.status == .archived)

                    Button("Archive") {
                        updateSignalStatus(signalID: signal.signalId, archive: true)
                    }
                    .buttonStyle(.bordered)
                    .disabled(inFlight || signal.status == .archived)

                    if let proposalID = signal.proposalLinkId {
                        Button("Open Proposal \(shortID(proposalID))") {
                            selectedTab = .proposals
                        }
                        .buttonStyle(.bordered)
                    }
                }

                if inFlight {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private func updateSignalStatus(signalID: String, archive: Bool) {
        inFlight = true
        feedbackMessage = nil
        Task { @MainActor in
            let error: String?
            if archive {
                error = await appModel.archiveSignal(id: signalID)
            } else {
                error = await appModel.acknowledgeSignal(id: signalID)
            }
            if error == nil {
                _ = await appModel.refreshSignals(status: statusFilter, limit: 200)
            }
            feedbackMessage = error
            inFlight = false
        }
    }

    private func statusColor(_ status: SignalStatus) -> Color {
        switch status {
        case .new:
            return .orange
        case .acknowledged:
            return .green
        case .archived:
            return .secondary
        }
    }

    private func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }

    private func shortID(_ id: String) -> String {
        String(id.prefix(8))
    }
}

struct NewsView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var feedbackMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("News")
                    .font(.title2)
                Spacer()
                Text("RSS: \(appModel.newsIngestStatus.rssStatus)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("SEC: \(appModel.newsIngestStatus.secStatus)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Alpaca: \(appModel.newsIngestStatus.alpacaStatus)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Refresh") {
                    Task { @MainActor in
                        feedbackMessage = await appModel.refreshNews(limit: 100)
                    }
                }
                .buttonStyle(.bordered)
            }

            if let feedbackMessage, !feedbackMessage.isEmpty {
                Text(feedbackMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            if appModel.recentNews.isEmpty {
                Text("No news events yet.")
                    .foregroundStyle(.secondary)
            } else {
                List(appModel.recentNews) { event in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top) {
                            Text(event.title)
                                .font(.headline)
                            Spacer()
                            Text(readableNewsSourceLabel(for: event, rssFeeds: appModel.rssFeeds))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }

                        if let summary = event.summary, !summary.isEmpty {
                            Text(summary)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }

                        HStack(spacing: 12) {
                            Text(event.publishedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            if let urlString = event.url,
                               let url = URL(string: urlString) {
                                Link("Open Link", destination: url)
                                    .font(.caption)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(minHeight: 380)
            }
        }
        .padding(18)
    }

}

struct LogsAuditView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Logs / Audit")
                .font(.title2)

            Text("Connection: \(appModel.connectionState)")
                .font(.callout)

            Text("Last trade update: \(appModel.lastTradeUpdateText)")
                .font(.callout)
                .textSelection(.enabled)

            Text("Market data: \(appModel.marketDataConnectionState)")
                .font(.callout)

            Text("Last market data: \(appModel.lastMarketDataText)")
                .font(.callout)
                .textSelection(.enabled)

            Text("Build: \(appModel.buildText)")
                .font(.footnote)
                .foregroundStyle(.secondary)

            List(Array(appModel.auditLinesNewestFirst.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
            .frame(minHeight: 360)
        }
        .padding(18)
    }
}

#Preview {
    ContentView()
        .environmentObject(AppModel())
}
