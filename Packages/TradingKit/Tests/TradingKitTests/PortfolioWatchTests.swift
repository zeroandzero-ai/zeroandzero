import Foundation
import Testing
@testable import TradingKit

@Test("Portfolio Watch default selection seeds from watchlist and stays capped")
func portfolioWatchDefaultSelectionSeedsFromWatchlist() {
    let now = Date(timeIntervalSince1970: 1_763_000_000)
    let configuration = PortfolioWatchChartWallConfiguration.default(
        watchlistSymbols: ["msft", "aapl", "nvda", "meta", "amzn", "googl", "tsla"],
        now: now
    )

    #expect(configuration.selectedSymbols == ["MSFT", "AAPL", "NVDA", "META", "AMZN", "GOOGL"])
    #expect(configuration.createdAt == now)
    #expect(configuration.updateSource == .systemDefault)
}

@Test("Portfolio Watch effective selection filters removed names and enforces max 30")
func portfolioWatchEffectiveSelectionFiltersAndCaps() {
    let watchlist = (1...40).map { "SYM\($0)" }
    let selected = ["SYM3", "SYM3", "missing", "sym7"] + (8...40).map { "sym\($0)" }

    let resolved = PortfolioWatchChartWallConfiguration.effectiveSelectedSymbols(
        selectedSymbols: selected,
        watchlistSymbols: watchlist
    )

    #expect(resolved.count == PortfolioWatchChartWallConfiguration.maximumSelectedSymbols)
    #expect(resolved.first == "SYM3")
    #expect(resolved.contains("MISSING") == false)
    #expect(resolved.last == "SYM35")
}

@Test("Portfolio Watch benchmark labels map the configured ETF proxies cleanly")
func portfolioWatchBenchmarkLabelsMapKnownETFs() {
    #expect(portfolioWatchBenchmarkShortLabel(for: "xlk") == "Technology")
    #expect(portfolioWatchBenchmarkShortLabel(for: "XLF") == "Financials")
    #expect(portfolioWatchBenchmarkShortLabel(for: "EEM") == "Emerging Mkts")
    #expect(portfolioWatchBenchmarkShortLabel(for: "SPY") == nil)
}

@Test("Portfolio Watch chart wall store round-trips schema wrapper and raw object fallback")
func portfolioWatchChartWallStoreRoundTripsAndFallsBack() async throws {
    let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("portfolio-watch-wall-\(UUID().uuidString)")
        .appendingPathExtension("json")
    defer { try? FileManager.default.removeItem(at: fileURL) }

    let now = Date(timeIntervalSince1970: 1_763_000_000)
    let store = PortfolioWatchChartWallConfigurationStore(
        fileURL: fileURL,
        now: { now }
    )
    let saved = try await store.upsert(
        PortfolioWatchChartWallConfiguration(
            selectedSymbols: ["msft", "aapl", "msft"],
            updatedBy: "owner",
            updateSource: .ui,
            createdAt: now,
            updatedAt: now
        )
    )
    #expect(saved.selectedSymbols == ["MSFT", "AAPL"])

    let reloaded = try #require(await store.load())
    #expect(reloaded.selectedSymbols == ["MSFT", "AAPL"])

    let raw = """
    {
      "configurationId": "portfolio-watch-chart-wall",
      "selectedSymbols": ["nvda", "amd"],
      "updatedBy": "owner",
      "updateSource": "ui",
      "createdAt": "2026-01-01T15:30:00Z",
      "updatedAt": "2026-01-01T15:30:00Z"
    }
    """
    let rawData = try #require(raw.data(using: .utf8))
    try rawData.write(to: fileURL, options: [.atomic])

    let decoded = try PortfolioWatchChartWallConfigurationStore.decodeConfiguration(from: rawData)
    #expect(decoded.selectedSymbols == ["nvda", "amd"])
}

@Test("Portfolio Watch read does not persistently collapse owner wall selection when watchlist is transiently sparse")
func portfolioWatchReadDoesNotPersistFilteredFallbackSelection() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("portfolio-watch-wall-read-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let fileURL = root.appendingPathComponent("portfolio_watch_chart_wall.json")
    let now = Date(timeIntervalSince1970: 1_763_000_100)
    let chartWallStore = PortfolioWatchChartWallConfigurationStore(
        fileURL: fileURL,
        now: { now }
    )
    _ = try await chartWallStore.upsert(
        PortfolioWatchChartWallConfiguration(
            selectedSymbols: ["AAPL", "MSFT", "AMZN"],
            updatedBy: "owner",
            updateSource: .ui,
            createdAt: now,
            updatedAt: now
        )
    )

    let store = Store()
    await store.setWatchlistSymbols(["NVDA"])
    let engine = Engine(
        store: store,
        portfolioWatchChartWallConfigurationStore: chartWallStore
    )

    let loaded = try await engine.getPortfolioWatchChartWallConfiguration()
    let reloaded = try #require(await chartWallStore.load())

    #expect(loaded.selectedSymbols == ["AAPL", "MSFT", "AMZN"])
    #expect(reloaded.selectedSymbols == ["AAPL", "MSFT", "AMZN"])
    #expect(
        PortfolioWatchChartWallConfiguration.effectiveSelectedSymbols(
            selectedSymbols: loaded.selectedSymbols,
            watchlistSymbols: ["NVDA"]
        ) == ["AAPL", "MSFT", "AMZN"]
    )
}

@Test("Portfolio Watch effective selection preserves owner wall during sparse watchlist recovery")
func portfolioWatchEffectiveSelectionPreservesExplicitOwnerWallWhenWatchlistIsSparse() {
    let selected = ["NVDA", "TSM", "AVGO", "AMZN", "GOOG", "AAPL", "CRWD", "NFLX", "TSLA", "KSS", "NYCB"]
    let resolved = PortfolioWatchChartWallConfiguration.effectiveSelectedSymbols(
        selectedSymbols: selected,
        watchlistSymbols: ["NVDA"]
    )

    #expect(resolved == selected)
}

@Test("Portfolio Watch wall editor rows include selected symbols missing from sparse watchlist")
func portfolioWatchWallEditorRowsIncludeSelectedSymbolsMissingFromSparseWatchlist() {
    let selected = ["NVDA", "TSM", "AVGO", "AMZN", "GOOG", "AAPL", "CRWD", "NFLX", "TSLA", "KSS", "NYCB"]
    let rows = makePortfolioWatchChartWallSelectionEditorRows(
        selectedSymbols: selected,
        watchlistSymbols: ["NVDA"]
    )

    #expect(rows.map(\.symbol) == selected)
    #expect(rows.count == 11)
    #expect(rows.first { $0.symbol == "NVDA" }?.isWatchlisted == true)
    #expect(rows.first { $0.symbol == "TSM" }?.isWallOnly == true)
}

@Test("Portfolio Watch wall save preserves hidden selected symbols when adding one symbol")
func portfolioWatchWallSavePreservesHiddenSelectedSymbolsWhenAddingOneSymbol() {
    let selected = ["NVDA", "TSM", "AVGO", "AMZN", "GOOG", "AAPL", "CRWD", "NFLX", "TSLA", "KSS", "NYCB"]
    var drafted = Set(selected)
    drafted.insert("META")

    let orderedSelection = portfolioWatchChartWallOrderedSelectionForSave(
        draftedSelection: drafted,
        currentSelectedSymbols: selected,
        watchlistSymbols: ["NVDA", "META"]
    )

    #expect(orderedSelection == selected + ["META"])
    #expect(orderedSelection.count == 12)
}

@Test("Portfolio Watch wall save removes only explicitly removed hidden symbol")
func portfolioWatchWallSaveRemovesOnlyExplicitlyRemovedHiddenSymbol() {
    let selected = ["NVDA", "TSM", "AVGO", "AMZN", "GOOG", "AAPL", "CRWD", "NFLX", "TSLA", "KSS", "NYCB"]
    var drafted = Set(selected)
    drafted.remove("AVGO")

    let orderedSelection = portfolioWatchChartWallOrderedSelectionForSave(
        draftedSelection: drafted,
        currentSelectedSymbols: selected,
        watchlistSymbols: ["NVDA"]
    )

    #expect(orderedSelection == ["NVDA", "TSM", "AMZN", "GOOG", "AAPL", "CRWD", "NFLX", "TSLA", "KSS", "NYCB"])
}

@Test("Portfolio Watch persisted 11-symbol wall survives store reload")
func portfolioWatchPersistedPaperPortfolioWallSurvivesReload() async throws {
    let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("portfolio-watch-wall-reload-\(UUID().uuidString)")
        .appendingPathExtension("json")
    defer { try? FileManager.default.removeItem(at: fileURL) }

    let selected = ["NVDA", "TSM", "AVGO", "AMZN", "GOOG", "AAPL", "CRWD", "NFLX", "TSLA", "KSS", "NYCB"]
    let now = Date(timeIntervalSince1970: 1_763_000_200)
    let writer = PortfolioWatchChartWallConfigurationStore(
        fileURL: fileURL,
        now: { now }
    )
    _ = try await writer.upsert(
        PortfolioWatchChartWallConfiguration(
            selectedSymbols: selected,
            updatedBy: "pm-primary",
            updateSource: .pmConversation,
            createdAt: now,
            updatedAt: now
        )
    )

    let reader = PortfolioWatchChartWallConfigurationStore(
        fileURL: fileURL,
        now: { now.addingTimeInterval(60) }
    )
    let reloaded = try #require(await reader.load())

    #expect(reloaded.selectedSymbols == selected)
    #expect(reloaded.updateSource == .pmConversation)
}

@Test("Portfolio Watch PM-added wall state is the same state read on relaunch")
func portfolioWatchPMAddedSymbolsPersistToRelaunchReadPath() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("portfolio-watch-wall-pm-relaunch-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let fileURL = root.appendingPathComponent("portfolio_watch_chart_wall.json")
    let now = Date(timeIntervalSince1970: 1_763_000_300)
    let chartWallStore = PortfolioWatchChartWallConfigurationStore(
        fileURL: fileURL,
        now: { now }
    )
    _ = try await chartWallStore.upsert(
        PortfolioWatchChartWallConfiguration(
            selectedSymbols: ["NVDA"],
            updatedBy: "owner",
            updateSource: .ui,
            createdAt: now,
            updatedAt: now
        )
    )

    let store = Store()
    await store.setWatchlistSymbols(["NVDA", "TSM", "AVGO", "AMZN", "GOOG", "AAPL", "CRWD", "NFLX", "TSLA", "KSS", "NYCB"])
    let engine = Engine(
        store: store,
        portfolioWatchChartWallConfigurationStore: chartWallStore
    )
    let updated = try await engine.upsertPortfolioWatchChartWallConfiguration(
        PortfolioWatchChartWallConfiguration(
            selectedSymbols: ["NVDA", "TSM", "AVGO", "AMZN", "GOOG", "AAPL", "CRWD", "NFLX", "TSLA", "KSS", "NYCB"],
            updatedBy: "pm-primary",
            updateSource: .pmConversation,
            createdAt: now,
            updatedAt: now
        )
    )
    #expect(updated.selectedSymbols.count == 11)

    let relaunchReader = PortfolioWatchChartWallConfigurationStore(
        fileURL: fileURL,
        now: { now.addingTimeInterval(120) }
    )
    let reloaded = try await relaunchReader.loadOrDefault(watchlistSymbols: ["NVDA"])

    #expect(reloaded.selectedSymbols == updated.selectedSymbols)
    #expect(
        PortfolioWatchChartWallConfiguration.effectiveSelectedSymbols(
            selectedSymbols: reloaded.selectedSymbols,
            watchlistSymbols: ["NVDA"]
        ) == updated.selectedSymbols
    )
}

@Test("Portfolio Watch price-recovery subscriptions do not mutate selected wall")
func portfolioWatchPriceRecoverySubscriptionsDoNotMutateChartWallSelection() async throws {
    let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("portfolio-watch-wall-subscription-\(UUID().uuidString)")
        .appendingPathExtension("json")
    defer { try? FileManager.default.removeItem(at: fileURL) }

    let now = Date(timeIntervalSince1970: 1_763_000_400)
    let chartWallStore = PortfolioWatchChartWallConfigurationStore(
        fileURL: fileURL,
        now: { now }
    )
    let selected = ["NVDA", "TSM", "AVGO", "AMZN", "GOOG", "AAPL", "CRWD", "NFLX", "TSLA", "KSS", "NYCB"]
    _ = try await chartWallStore.upsert(
        PortfolioWatchChartWallConfiguration(
            selectedSymbols: selected,
            updatedBy: "pm-primary",
            updateSource: .pmConversation,
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(portfolioWatchChartWallConfigurationStore: chartWallStore)
    await engine.subscribeQuotes(symbols: ["SPY", "QQQ"], source: "pm.paper_portfolio_price_recovery.test")
    await engine.subscribeTrades(symbols: ["SPY", "QQQ"], source: "pm.paper_portfolio_price_recovery.test")
    await engine.subscribeBars(symbols: ["SPY", "QQQ"], source: "pm.paper_portfolio_price_recovery.test")

    let reloaded = try #require(await chartWallStore.load())
    #expect(reloaded.selectedSymbols == selected)
}

@Test("Portfolio Watch chart wall store reports unsupported schema versions predictably")
func portfolioWatchChartWallStoreRejectsUnknownSchema() throws {
    let payload = """
    {
      "schemaVersion": 9,
      "configuration": {}
    }
    """
    let data = try #require(payload.data(using: .utf8))

    do {
        _ = try PortfolioWatchChartWallConfigurationStore.decodeConfiguration(from: data)
        Issue.record("Expected unsupported schema version error.")
    } catch let error as PortfolioWatchChartWallConfigurationStoreError {
        #expect(error == .unsupportedSchemaVersion(9))
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }
}

@Test("Portfolio Watch selected symbols render waiting cards without price data")
func portfolioWatchSelectedSymbolsRenderWithoutPriceData() {
    let selected = ["NVDA", "TSM", "AVGO"]
    let cards = makePortfolioWatchCardPresentations(
        selectedSymbols: selected,
        positions: [],
        quotesBySymbol: [:],
        optionQuotesBySymbol: [:],
        marketDataDesiredSubscriptions: MarketDataSubscriptionSet(quotes: Set(selected), trades: Set(selected)),
        marketDataSubscriptions: .empty,
        tracker: PortfolioWatchIntradaySeriesTracker(),
        now: Date(timeIntervalSince1970: 1_763_100_000)
    )

    #expect(cards.map(\.symbol) == selected)
    #expect(cards.allSatisfy { $0.currentPrice == nil })
    #expect(cards.allSatisfy { $0.liveState == .waitingForFirstUpdate })
    #expect(cards.allSatisfy { $0.diagnostics.subscriptionDesired })
}

@Test("Portfolio Watch intraday tracker updates within the same minute bucket")
func portfolioWatchIntradayTrackerUpdatesSameMinuteBucket() {
    var tracker = PortfolioWatchIntradaySeriesTracker()
    let firstTime = Date(timeIntervalSince1970: 1_763_100_000)
    let secondTime = firstTime.addingTimeInterval(15)

    tracker.ingest(
        symbol: "AAPL",
        quote: MarketQuote(
            symbol: "AAPL",
            lastPrice: 190.25,
            timestamp: "2026-03-17T14:30:05Z",
            lastTradeTimestamp: "2026-03-17T14:30:05Z"
        ),
        now: firstTime
    )
    tracker.ingest(
        symbol: "AAPL",
        quote: MarketQuote(
            symbol: "AAPL",
            lastPrice: 191.10,
            timestamp: "2026-03-17T14:30:20Z",
            lastTradeTimestamp: "2026-03-17T14:30:20Z"
        ),
        now: secondTime
    )

    let points = tracker.points(for: "AAPL")
    #expect(points.count == 1)
    #expect(points.first?.price == 191.10)
}

@Test("Portfolio Watch intraday tracker keeps out-of-order updates monotonic")
func portfolioWatchIntradayTrackerKeepsOutOfOrderUpdatesMonotonic() {
    var tracker = PortfolioWatchIntradaySeriesTracker()

    tracker.ingest(
        symbol: "AVGO",
        quote: MarketQuote(
            symbol: "AVGO",
            lastPrice: 389,
            timestamp: "2026-06-05T17:03:00Z",
            lastTradeTimestamp: "2026-06-05T17:03:00Z"
        ),
        now: Date(timeIntervalSince1970: 1_764_000_180)
    )
    tracker.ingest(
        symbol: "AVGO",
        quote: MarketQuote(
            symbol: "AVGO",
            lastPrice: 386,
            timestamp: "2026-06-05T17:01:00Z",
            lastTradeTimestamp: "2026-06-05T17:01:00Z"
        ),
        now: Date(timeIntervalSince1970: 1_764_000_060)
    )
    tracker.ingest(
        symbol: "AVGO",
        quote: MarketQuote(
            symbol: "AVGO",
            lastPrice: 390,
            timestamp: "2026-06-05T17:02:00Z",
            lastTradeTimestamp: "2026-06-05T17:02:00Z"
        ),
        now: Date(timeIntervalSince1970: 1_764_000_120)
    )
    tracker.ingest(
        symbol: "AVGO",
        quote: MarketQuote(
            symbol: "AVGO",
            lastPrice: 391,
            timestamp: "2026-06-05T17:02:45Z",
            lastTradeTimestamp: "2026-06-05T17:02:45Z"
        ),
        now: Date(timeIntervalSince1970: 1_764_000_165)
    )

    let points = tracker.points(for: "AVGO")
    #expect(points.map(\.price) == [386, 391, 389])
    #expect(points.map(\.timestamp) == points.map(\.timestamp).sorted())
}

@Test("Portfolio Watch live value resolver uses newest trade or bar timestamp")
func portfolioWatchLiveValueResolverUsesNewestTradeOrBarTimestamp() throws {
    let quote = MarketQuote(
        symbol: "AVGO",
        lastPrice: 389.55,
        timestamp: "2026-06-05T17:03:00Z",
        lastTradeTimestamp: "2026-06-05T16:48:00Z",
        lastBarTimestamp: "2026-06-05T17:03:00Z"
    )

    let resolved = try #require(resolvePortfolioWatchLiveValue(from: quote))

    #expect(resolved.price == 389.55)
    #expect(resolved.source == .minuteBar)
    #expect(resolved.observedAt == DateCodec.parseISO8601("2026-06-05T17:03:00Z"))
}

@Test("Portfolio Watch first usable quote seeds the first intraday point immediately")
func portfolioWatchIntradayTrackerSeedsFirstPointFromQuote() {
    var tracker = PortfolioWatchIntradaySeriesTracker()

    tracker.ingest(
        symbol: "msft",
        quote: MarketQuote(
            symbol: "MSFT",
            bidPrice: 412.10,
            askPrice: 412.30,
            timestamp: "2026-03-17T14:31:00Z",
            lastQuoteTimestamp: "2026-03-17T14:31:00Z"
        ),
        now: Date(timeIntervalSince1970: 1_763_100_060)
    )

    let points = tracker.points(for: "MSFT")
    #expect(points.count == 1)
    #expect(abs((points.first?.price ?? 0) - 412.20) < 0.0001)
}

@Test("Portfolio Watch ignores zero-valued quote snapshots for first-point seeding")
func portfolioWatchIntradayTrackerIgnoresZeroQuoteValues() {
    var tracker = PortfolioWatchIntradaySeriesTracker()

    tracker.ingest(
        symbol: "AAPL",
        quote: MarketQuote(
            symbol: "AAPL",
            bidPrice: 0,
            askPrice: 0,
            timestamp: "2026-03-17T14:31:00Z",
            lastQuoteTimestamp: "2026-03-17T14:31:00Z"
        ),
        now: Date(timeIntervalSince1970: 1_763_100_060)
    )

    #expect(tracker.points(for: "AAPL").isEmpty)
}

@Test("Portfolio Watch intraday tracker resets for a new trading day")
func portfolioWatchIntradayTrackerResetsForNewDay() {
    var tracker = PortfolioWatchIntradaySeriesTracker()

    tracker.ingest(
        symbol: "AAPL",
        quote: MarketQuote(
            symbol: "AAPL",
            lastPrice: 190.25,
            timestamp: "2026-03-17T19:59:00Z",
            lastTradeTimestamp: "2026-03-17T19:59:00Z"
        ),
        now: Date(timeIntervalSince1970: 1_763_100_000)
    )
    tracker.ingest(
        symbol: "AAPL",
        quote: MarketQuote(
            symbol: "AAPL",
            lastPrice: 188.75,
            timestamp: "2026-03-18T13:35:00Z",
            lastTradeTimestamp: "2026-03-18T13:35:00Z"
        ),
        now: Date(timeIntervalSince1970: 1_763_190_000)
    )

    let points = tracker.points(for: "AAPL")
    #expect(points.count == 1)
    #expect(points.first?.price == 188.75)
}

@Test("Portfolio Watch intraday tracker stays bounded")
func portfolioWatchIntradayTrackerStaysBounded() {
    var tracker = PortfolioWatchIntradaySeriesTracker(maxPointsPerSeries: 3)

    for minute in 0..<5 {
        tracker.ingest(
            symbol: "AAPL",
            quote: MarketQuote(
                symbol: "AAPL",
                lastPrice: 190 + Double(minute),
                timestamp: "2026-03-17T14:\(String(format: "%02d", minute)):00Z",
                lastTradeTimestamp: "2026-03-17T14:\(String(format: "%02d", minute)):00Z"
            ),
            now: Date(timeIntervalSince1970: 1_763_100_000 + Double(minute * 60))
        )
    }

    let points = tracker.points(for: "AAPL")
    #expect(points.count == 3)
    #expect(points.first?.price == 192)
    #expect(points.last?.price == 194)
}

@Test("Portfolio Watch intraday tracker exposes volatile cache counts and trims without touching configuration")
func portfolioWatchIntradayTrackerDiagnosticsAndTrimAreCountable() {
    var tracker = PortfolioWatchIntradaySeriesTracker(maxPointsPerSeries: 3)

    for minute in 0..<4 {
        tracker.ingest(
            symbol: "AAPL",
            quote: MarketQuote(
                symbol: "AAPL",
                lastPrice: 190 + Double(minute),
                timestamp: "2026-03-17T14:\(String(format: "%02d", minute)):00Z",
                lastTradeTimestamp: "2026-03-17T14:\(String(format: "%02d", minute)):00Z"
            ),
            now: Date(timeIntervalSince1970: 1_763_100_000 + Double(minute * 60))
        )
    }
    tracker.ingest(
        symbol: "MSFT",
        quote: MarketQuote(
            symbol: "MSFT",
            lastPrice: 410,
            timestamp: "2026-03-17T14:10:00Z",
            lastTradeTimestamp: "2026-03-17T14:10:00Z"
        ),
        now: Date(timeIntervalSince1970: 1_763_100_600)
    )

    #expect(tracker.trackedSymbolCount == 2)
    #expect(tracker.totalPointCount == 4)
    #expect(tracker.pointCountBySymbol()["AAPL"] == 3)
    #expect(tracker.pointCountBySymbol()["MSFT"] == 1)

    tracker.removeAll()

    #expect(tracker.trackedSymbolCount == 0)
    #expect(tracker.totalPointCount == 0)
    #expect(tracker.points(for: "AAPL").isEmpty)
}

@Test("Portfolio Watch card display points are downsampled while full point count remains diagnostic")
func portfolioWatchCardDisplayPointsAreDownsampledForUI() {
    var tracker = PortfolioWatchIntradaySeriesTracker(maxPointsPerSeries: 12)

    for minute in 0..<12 {
        tracker.ingest(
            symbol: "AAPL",
            quote: MarketQuote(
                symbol: "AAPL",
                lastPrice: 190 + Double(minute),
                timestamp: "2026-03-17T14:\(String(format: "%02d", minute)):00Z",
                lastTradeTimestamp: "2026-03-17T14:\(String(format: "%02d", minute)):00Z"
            ),
            now: Date(timeIntervalSince1970: 1_763_100_000 + Double(minute * 60))
        )
    }

    let cards = makePortfolioWatchCardPresentations(
        selectedSymbols: ["AAPL"],
        positions: [],
        quotesBySymbol: [:],
        optionQuotesBySymbol: [:],
        tracker: tracker,
        maxDisplayPointsPerCard: 4,
        now: Date(timeIntervalSince1970: 1_763_100_000)
    )

    let card = try! #require(cards.first)
    #expect(card.pointCount == 12)
    #expect(card.diagnostics.pointCount == 12)
    #expect(card.points.count == 4)
    #expect(card.points.last?.price == 201)
}

@Test("Portfolio Watch card presentations reflect current price, day change, and held symbols")
func portfolioWatchCardPresentationsReflectQuotesAndHoldings() {
    var tracker = PortfolioWatchIntradaySeriesTracker()
    tracker.ingest(
        symbol: "AAPL",
        quote: MarketQuote(
            symbol: "AAPL",
            lastPrice: 190,
            timestamp: "2026-03-17T14:30:00Z",
            lastTradeTimestamp: "2026-03-17T14:30:00Z"
        ),
        now: Date(timeIntervalSince1970: 1_763_100_000)
    )
    tracker.ingest(
        symbol: "AAPL",
        quote: MarketQuote(
            symbol: "AAPL",
            lastPrice: 194,
            timestamp: "2026-03-17T15:00:00Z",
            lastTradeTimestamp: "2026-03-17T15:00:00Z"
        ),
        now: Date(timeIntervalSince1970: 1_763_101_800)
    )

    let cards = makePortfolioWatchCardPresentations(
        selectedSymbols: ["AAPL"],
        positions: [
            PositionRow(
                id: "pos-aapl",
                symbol: "AAPL",
                side: "long",
                qty: "10",
                marketValue: "$1,940"
            )
        ],
        quotesBySymbol: [
            "AAPL": MarketQuote(
                symbol: "AAPL",
                lastPrice: 194,
                timestamp: "2026-03-17T15:00:00Z",
                lastTradeTimestamp: "2026-03-17T15:00:00Z"
            )
        ],
        optionQuotesBySymbol: [:],
        tracker: tracker,
        now: Date(timeIntervalSince1970: 1_763_101_800)
    )

    let card = try! #require(cards.first)
    #expect(card.currentPrice == 194)
    #expect(card.changeValue == 4)
    #expect(abs((card.changePercent ?? 0) - 2.1052631579) < 0.001)
    #expect(card.isHeld == true)
    #expect(card.pointCount == 2)
    #expect(card.liveState == .liveChart)
    #expect(card.priceSource == .lastTrade)
    #expect(card.diagnostics.subscriptionActive == false)
    #expect(card.benchmarkLabel == nil)
}

@Test("Portfolio Watch card presentations expose truthful waiting and building states")
func portfolioWatchCardPresentationsExposePartialDataStates() {
    var tracker = PortfolioWatchIntradaySeriesTracker()
    tracker.ingest(
        symbol: "NVDA",
        quote: MarketQuote(
            symbol: "NVDA",
            bidPrice: 902.0,
            askPrice: 902.4,
            timestamp: "2026-03-17T14:30:00Z",
            lastQuoteTimestamp: "2026-03-17T14:30:00Z"
        ),
        now: Date(timeIntervalSince1970: 1_763_100_000)
    )

    let cards = makePortfolioWatchCardPresentations(
        selectedSymbols: ["NVDA", "TSLA"],
        positions: [],
        quotesBySymbol: [
            "NVDA": MarketQuote(
                symbol: "NVDA",
                bidPrice: 902.0,
                askPrice: 902.4,
                timestamp: "2026-03-17T14:30:00Z",
                lastQuoteTimestamp: "2026-03-17T14:30:00Z"
            )
        ],
        optionQuotesBySymbol: [:],
        marketDataSubscriptions: MarketDataSubscriptionSet(quotes: ["NVDA", "TSLA"], trades: ["NVDA", "TSLA"]),
        tracker: tracker,
        now: Date(timeIntervalSince1970: 1_763_100_000)
    )

    let building = try! #require(cards.first(where: { $0.symbol == "NVDA" }))
    #expect(building.currentPrice != nil)
    #expect(building.pointCount == 1)
    #expect(building.liveState == .buildingChart)
    #expect(building.priceSource == .midQuote)
    #expect(building.diagnostics.subscriptionActive == true)

    let waiting = try! #require(cards.first(where: { $0.symbol == "TSLA" }))
    #expect(waiting.currentPrice == nil)
    #expect(waiting.pointCount == 0)
    #expect(waiting.liveState == .waitingForFirstUpdate)
    #expect(waiting.diagnostics.subscriptionActive == true)
}

@Test("Portfolio Watch distinguishes requested coverage from Alpaca-acknowledged coverage")
func portfolioWatchCardPresentationsExposeRequestedButUnacknowledgedCoverage() {
    let cards = makePortfolioWatchCardPresentations(
        selectedSymbols: ["NVDA"],
        positions: [],
        quotesBySymbol: [:],
        optionQuotesBySymbol: [:],
        marketDataDesiredSubscriptions: MarketDataSubscriptionSet(quotes: ["NVDA"], trades: ["NVDA"]),
        marketDataSubscriptions: .empty,
        tracker: PortfolioWatchIntradaySeriesTracker(),
        now: Date(timeIntervalSince1970: 1_763_100_000)
    )

    let card = try! #require(cards.first)
    #expect(card.diagnostics.subscriptionDesired == true)
    #expect(card.diagnostics.subscriptionActive == false)
    #expect(card.liveState == .waitingForFirstUpdate)

    let note = portfolioWatchLiveCoverageNote(
        cards: cards,
        sessionState: .market,
        connectionActive: true
    )
    #expect(note?.contains("not acknowledged") == true)
}

@Test("Portfolio Watch card presentations include benchmark labels for mapped ETFs")
func portfolioWatchCardPresentationsIncludeBenchmarkLabels() {
    var tracker = PortfolioWatchIntradaySeriesTracker()
    tracker.ingest(
        symbol: "XLF",
        quote: MarketQuote(
            symbol: "XLF",
            lastPrice: 48.12,
            timestamp: "2026-03-17T14:30:00Z",
            lastTradeTimestamp: "2026-03-17T14:30:00Z"
        ),
        now: Date(timeIntervalSince1970: 1_763_100_000)
    )

    let cards = makePortfolioWatchCardPresentations(
        selectedSymbols: ["XLF", "SPY"],
        positions: [],
        quotesBySymbol: [
            "XLF": MarketQuote(
                symbol: "XLF",
                lastPrice: 48.12,
                timestamp: "2026-03-17T14:30:00Z",
                lastTradeTimestamp: "2026-03-17T14:30:00Z"
            )
        ],
        optionQuotesBySymbol: [:],
        tracker: tracker,
        now: Date(timeIntervalSince1970: 1_763_100_000)
    )

    let xlf = try! #require(cards.first(where: { $0.symbol == "XLF" }))
    #expect(xlf.benchmarkLabel == "Financials")

    let spy = try! #require(cards.first(where: { $0.symbol == "SPY" }))
    #expect(spy.benchmarkLabel == nil)
}

@Test("Portfolio Watch live coverage note appears only for partial connected walls")
func portfolioWatchLiveCoverageNoteReflectsPartialCoverageTruthfully() {
    let partialCards = [
        PortfolioWatchCardPresentation(
            symbol: "XLF",
            benchmarkLabel: "Financials",
            currentPrice: 48.12,
            changeValue: 0.32,
            changePercent: 0.67,
            isHeld: false,
            pointCount: 2,
            lastUpdatedAt: Date(timeIntervalSince1970: 1_763_100_000),
            sessionState: .market,
            liveState: .liveChart,
            priceSource: .lastTrade,
            diagnostics: PortfolioWatchLiveDiagnostics(
                symbol: "XLF",
                subscriptionActive: true,
                pointCount: 2,
                priceSource: .lastTrade,
                lastQuoteAt: nil,
                lastTradeAt: Date(timeIntervalSince1970: 1_763_100_000),
                lastBarAt: nil
            ),
            points: [
                PortfolioWatchIntradayPoint(timestamp: Date(timeIntervalSince1970: 1_763_099_940), price: 47.95),
                PortfolioWatchIntradayPoint(timestamp: Date(timeIntervalSince1970: 1_763_100_000), price: 48.12)
            ]
        ),
        PortfolioWatchCardPresentation(
            symbol: "EEM",
            benchmarkLabel: "Emerging Mkts",
            currentPrice: nil,
            changeValue: nil,
            changePercent: nil,
            isHeld: false,
            pointCount: 0,
            lastUpdatedAt: nil,
            sessionState: .market,
            liveState: .waitingForFirstUpdate,
            priceSource: nil,
            diagnostics: PortfolioWatchLiveDiagnostics(
                symbol: "EEM",
                subscriptionActive: true,
                pointCount: 0,
                priceSource: nil,
                lastQuoteAt: nil,
                lastTradeAt: nil,
                lastBarAt: nil
            ),
            points: []
        )
    ]

    let note = portfolioWatchLiveCoverageNote(
        cards: partialCards,
        sessionState: .market,
        connectionActive: true
    )
    #expect(note?.contains("partial") == true)

    #expect(
        portfolioWatchLiveCoverageNote(
            cards: partialCards,
            sessionState: .closed,
            connectionActive: true
        ) == nil
    )
    #expect(
        portfolioWatchLiveCoverageNote(
            cards: partialCards,
            sessionState: .market,
            connectionActive: false
        ) == nil
    )
}

@Test("Portfolio Watch wall layout reaches five columns on wide screens")
func portfolioWatchWallLayoutUsesWideScreens() {
    #expect(PortfolioWatchWallLayout.columnCount(for: 520, selectedCount: 8) == 1)
    #expect(PortfolioWatchWallLayout.columnCount(for: 900, selectedCount: 8) == 3)
    #expect(PortfolioWatchWallLayout.columnCount(for: 1_450, selectedCount: 8) == 5)
    #expect(PortfolioWatchWallLayout.columnCount(for: 1_600, selectedCount: 30) == 6)
    #expect(PortfolioWatchWallLayout.minimumCardWidth(for: 30) == 220)
    #expect(PortfolioWatchWallLayout.rowCount(for: 1_600, selectedCount: 30) == 5)
    #expect(PortfolioWatchWallLayout.gridHeight(for: 1_600, selectedCount: 30) == 1_225)
}
