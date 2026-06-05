import Foundation

public enum PortfolioWatchChartWallConfigurationUpdateSource: String, Codable, Sendable, Equatable {
    case systemDefault = "system_default"
    case ui
    case pmConversation = "pm_conversation"
}

public struct PortfolioWatchChartWallConfiguration: Codable, Sendable, Equatable, Identifiable {
    public static let singletonID = "portfolio-watch-chart-wall"
    public static let maximumSelectedSymbols = 30
    public static let defaultSeedCount = 6

    public var id: String { configurationId }

    public var configurationId: String
    public var selectedSymbols: [String]
    public var updatedBy: String
    public var updateSource: PortfolioWatchChartWallConfigurationUpdateSource
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        configurationId: String = PortfolioWatchChartWallConfiguration.singletonID,
        selectedSymbols: [String],
        updatedBy: String,
        updateSource: PortfolioWatchChartWallConfigurationUpdateSource,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.configurationId = configurationId
        self.selectedSymbols = selectedSymbols
        self.updatedBy = updatedBy
        self.updateSource = updateSource
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public static func `default`(
        watchlistSymbols: [String],
        now: Date
    ) -> PortfolioWatchChartWallConfiguration {
        PortfolioWatchChartWallConfiguration(
            selectedSymbols: Array(
                normalizedOrderedSymbols(watchlistSymbols)
                    .prefix(min(defaultSeedCount, maximumSelectedSymbols))
            ),
            updatedBy: "system",
            updateSource: .systemDefault,
            createdAt: now,
            updatedAt: now
        )
    }

    public static func normalizedSelectedSymbols(
        _ symbols: [String],
        maxSelection: Int = PortfolioWatchChartWallConfiguration.maximumSelectedSymbols
    ) -> [String] {
        Array(normalizedOrderedSymbols(symbols).prefix(max(0, maxSelection)))
    }

    public static func effectiveSelectedSymbols(
        selectedSymbols: [String],
        watchlistSymbols: [String],
        maxSelection: Int = PortfolioWatchChartWallConfiguration.maximumSelectedSymbols,
        fallbackCount: Int = PortfolioWatchChartWallConfiguration.defaultSeedCount
    ) -> [String] {
        let orderedWatchlist = normalizedOrderedSymbols(watchlistSymbols)
        let watchlistSet = Set(orderedWatchlist)
        let selected = normalizedOrderedSymbols(selectedSymbols)

        if selected.isEmpty == false {
            let selectedFromWatchlist = selected.filter { watchlistSet.contains($0) }
            if selectedFromWatchlist.count == selected.count {
                return Array(selectedFromWatchlist.prefix(max(0, maxSelection)))
            }

            // During launch/recovery the Store watchlist can be temporarily sparse even
            // while the durable chart-wall preference is richer. Prefer the owner's
            // explicit wall selection over a destructive visual fallback to stale seed names.
            if orderedWatchlist.count < selected.count {
                return Array(selected.prefix(max(0, maxSelection)))
            }

            if selectedFromWatchlist.isEmpty == false {
                return Array(selectedFromWatchlist.prefix(max(0, maxSelection)))
            }

            return Array(selected.prefix(max(0, maxSelection)))
        }

        let resolvedFallbackCount = min(max(0, fallbackCount), max(0, maxSelection))
        return Array(orderedWatchlist.prefix(resolvedFallbackCount))
    }
}

public struct PortfolioWatchChartWallSelectionEditorRow: Sendable, Equatable, Identifiable {
    public var id: String { symbol }
    public let symbol: String
    public let isSelected: Bool
    public let isWatchlisted: Bool

    public init(
        symbol: String,
        isSelected: Bool,
        isWatchlisted: Bool
    ) {
        self.symbol = symbol
        self.isSelected = isSelected
        self.isWatchlisted = isWatchlisted
    }

    public var isWallOnly: Bool {
        isSelected && isWatchlisted == false
    }
}

public func makePortfolioWatchChartWallSelectionEditorRows(
    selectedSymbols: [String],
    watchlistSymbols: [String],
    maxSelection: Int = PortfolioWatchChartWallConfiguration.maximumSelectedSymbols
) -> [PortfolioWatchChartWallSelectionEditorRow] {
    let selected = PortfolioWatchChartWallConfiguration.normalizedSelectedSymbols(
        selectedSymbols,
        maxSelection: maxSelection
    )
    let watchlist = normalizedOrderedSymbols(watchlistSymbols)
    let selectedSet = Set(selected)
    let watchlistSet = Set(watchlist)
    let orderedSymbols = normalizedOrderedSymbols(
        selected + watchlist.filter { selectedSet.contains($0) == false }
    )
    return orderedSymbols.map { symbol in
        PortfolioWatchChartWallSelectionEditorRow(
            symbol: symbol,
            isSelected: selectedSet.contains(symbol),
            isWatchlisted: watchlistSet.contains(symbol)
        )
    }
}

public func portfolioWatchChartWallOrderedSelectionForSave(
    draftedSelection: Set<String>,
    currentSelectedSymbols: [String],
    watchlistSymbols: [String],
    maxSelection: Int = PortfolioWatchChartWallConfiguration.maximumSelectedSymbols
) -> [String] {
    let draftedSet = Set(normalizedOrderedSymbols(Array(draftedSelection)))
    guard draftedSet.isEmpty == false else {
        return []
    }
    let orderedUniverse = normalizedOrderedSymbols(
        currentSelectedSymbols + watchlistSymbols + Array(draftedSet).sorted()
    )
    return Array(
        orderedUniverse
            .filter { draftedSet.contains($0) }
            .prefix(max(0, maxSelection))
    )
}

public func portfolioWatchBenchmarkShortLabel(for symbol: String) -> String? {
    switch normalizedOrderedSymbols([symbol]).first ?? "" {
    case "XLK":
        return "Technology"
    case "XLV":
        return "Healthcare"
    case "XLY":
        return "Consumer Disc."
    case "XLP":
        return "Consumer Staples"
    case "XLI":
        return "Industrials"
    case "XLF":
        return "Financials"
    case "XLE":
        return "Energy"
    case "XLB":
        return "Materials"
    case "TLT":
        return "Long Treasuries"
    case "TIP":
        return "Inflation / TIPS"
    case "UUP":
        return "US Dollar"
    case "DBC":
        return "Commodities"
    case "GLD":
        return "Gold"
    case "EFA":
        return "Developed Intl"
    case "EEM":
        return "Emerging Mkts"
    default:
        return nil
    }
}

public enum PortfolioWatchChartWallConfigurationStoreError: Error, Sendable, Equatable {
    case unsupportedSchemaVersion(Int)
    case invalidDocument
}

public actor PortfolioWatchChartWallConfigurationStore {
    private struct PersistedConfigurationV1: Codable {
        let schemaVersion: Int
        let configuration: PortfolioWatchChartWallConfiguration
    }

    private struct PersistedSchemaProbe: Decodable {
        let schemaVersion: Int?
    }

    private let fileManager: FileManager
    private let fileURL: URL
    private let now: @Sendable () -> Date

    private var loaded = false
    private var cachedConfiguration: PortfolioWatchChartWallConfiguration?
    private var loadDiagnostics: [String] = []

    public init(
        fileURL: URL? = nil,
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileURL = fileURL
            ?? AppSupportPaths.rootDirectory()
            .appendingPathComponent("portfolio_watch_chart_wall.json", isDirectory: false)
        self.fileManager = fileManager
        self.now = now
    }

    public func load() -> PortfolioWatchChartWallConfiguration? {
        loadIfNeeded()
        return cachedConfiguration
    }

    @discardableResult
    public func loadOrDefault(
        watchlistSymbols: [String]
    ) throws -> PortfolioWatchChartWallConfiguration {
        loadIfNeeded()
        if let cachedConfiguration {
            return cachedConfiguration
        }

        let seeded = PortfolioWatchChartWallConfiguration.default(
            watchlistSymbols: watchlistSymbols,
            now: now()
        )
        cachedConfiguration = seeded
        try persist(seeded)
        return seeded
    }

    @discardableResult
    public func upsert(
        _ configuration: PortfolioWatchChartWallConfiguration
    ) throws -> PortfolioWatchChartWallConfiguration {
        loadIfNeeded()
        let existing = cachedConfiguration
        var updated = configuration
        updated.configurationId = PortfolioWatchChartWallConfiguration.singletonID
        updated.selectedSymbols = PortfolioWatchChartWallConfiguration.normalizedSelectedSymbols(
            configuration.selectedSymbols
        )
        updated.createdAt = existing?.createdAt ?? configuration.createdAt
        updated.updatedAt = now()
        cachedConfiguration = updated
        try persist(updated)
        return updated
    }

    public func drainLoadDiagnostics() -> [String] {
        let diagnostics = loadDiagnostics
        loadDiagnostics.removeAll()
        return diagnostics
    }

    private func loadIfNeeded() {
        guard !loaded else {
            return
        }
        loaded = true

        guard fileManager.fileExists(atPath: fileURL.path) else {
            cachedConfiguration = nil
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            cachedConfiguration = try Self.decodeConfiguration(from: data)
        } catch let error as PortfolioWatchChartWallConfigurationStoreError {
            switch error {
            case .unsupportedSchemaVersion(let version):
                loadDiagnostics.append(
                    "portfolio watch chart wall skipped file=\(fileURL.lastPathComponent) code=unsupported_schema_version version=\(version)"
                )
            case .invalidDocument:
                loadDiagnostics.append(
                    "portfolio watch chart wall skipped file=\(fileURL.lastPathComponent) code=invalid_document"
                )
            }
            cachedConfiguration = nil
        } catch {
            loadDiagnostics.append(
                "portfolio watch chart wall skipped file=\(fileURL.lastPathComponent) code=io_failure"
            )
            cachedConfiguration = nil
        }
    }

    private func persist(_ configuration: PortfolioWatchChartWallConfiguration) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = DateCodec.iso8601EncodingStrategy
        let data = try encoder.encode(
            PersistedConfigurationV1(schemaVersion: 1, configuration: configuration)
        )
        try data.write(to: fileURL, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    static func decodeConfiguration(
        from data: Data
    ) throws -> PortfolioWatchChartWallConfiguration {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = DateCodec.iso8601DecodingStrategy

        if let probe = try? decoder.decode(PersistedSchemaProbe.self, from: data),
           let schemaVersion = probe.schemaVersion {
            guard schemaVersion == 1 else {
                throw PortfolioWatchChartWallConfigurationStoreError.unsupportedSchemaVersion(schemaVersion)
            }
            do {
                return try decoder.decode(PersistedConfigurationV1.self, from: data).configuration
            } catch {
                throw PortfolioWatchChartWallConfigurationStoreError.invalidDocument
            }
        }

        do {
            return try decoder.decode(PortfolioWatchChartWallConfiguration.self, from: data)
        } catch {
            throw PortfolioWatchChartWallConfigurationStoreError.invalidDocument
        }
    }
}

public enum PortfolioWatchSessionState: String, Sendable, Equatable {
    case market
    case extendedHours = "extended_hours"
    case closed

    public var displayTitle: String {
        switch self {
        case .market:
            return "Market"
        case .extendedHours:
            return "Extended"
        case .closed:
            return "Closed"
        }
    }

    public static func resolve(
        at date: Date,
        timeZoneIdentifier: String = "America/New_York"
    ) -> PortfolioWatchSessionState {
        let timeZone = TimeZone(identifier: timeZoneIdentifier) ?? TimeZone(secondsFromGMT: 0) ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let minuteOfDay = (components.hour ?? 0) * 60 + (components.minute ?? 0)

        let marketOpen = (9 * 60) + 30
        let marketClose = 16 * 60
        let extendedOpen = 4 * 60
        let extendedClose = 20 * 60

        if minuteOfDay >= marketOpen, minuteOfDay < marketClose {
            return .market
        }
        if minuteOfDay >= extendedOpen, minuteOfDay < extendedClose {
            return .extendedHours
        }
        return .closed
    }
}

public struct PortfolioWatchIntradayPoint: Sendable, Equatable, Identifiable {
    public var id: Date { timestamp }

    public let timestamp: Date
    public let price: Double

    public init(timestamp: Date, price: Double) {
        self.timestamp = timestamp
        self.price = price
    }
}

public enum PortfolioWatchLiveValueSource: String, Sendable, Equatable {
    case lastTrade = "last_trade"
    case minuteBar = "minute_bar"
    case midQuote = "mid_quote"
    case bid = "bid"
    case ask = "ask"
    case trackerCarryForward = "tracker_carry_forward"

    public var displayTitle: String {
        switch self {
        case .lastTrade:
            return "Last Trade"
        case .minuteBar:
            return "Minute Bar"
        case .midQuote:
            return "Mid Quote"
        case .bid:
            return "Bid"
        case .ask:
            return "Ask"
        case .trackerCarryForward:
            return "Prior Intraday Point"
        }
    }
}

public enum PortfolioWatchLiveState: String, Sendable, Equatable {
    case waitingForFirstUpdate = "waiting_for_first_update"
    case buildingChart = "building_chart"
    case liveChart = "live_chart"

    public var statusLine: String {
        switch self {
        case .waitingForFirstUpdate:
            return "Waiting for first market update"
        case .buildingChart:
            return "Building intraday chart"
        case .liveChart:
            return "Live intraday chart"
        }
    }
}

public struct PortfolioWatchLiveDiagnostics: Sendable, Equatable {
    public let symbol: String
    public let subscriptionDesired: Bool
    public let subscriptionActive: Bool
    public let pointCount: Int
    public let priceSource: PortfolioWatchLiveValueSource?
    public let lastQuoteAt: Date?
    public let lastTradeAt: Date?
    public let lastBarAt: Date?

    public init(
        symbol: String,
        subscriptionDesired: Bool = false,
        subscriptionActive: Bool,
        pointCount: Int,
        priceSource: PortfolioWatchLiveValueSource?,
        lastQuoteAt: Date?,
        lastTradeAt: Date?,
        lastBarAt: Date?
    ) {
        self.symbol = symbol
        self.subscriptionDesired = subscriptionDesired
        self.subscriptionActive = subscriptionActive
        self.pointCount = pointCount
        self.priceSource = priceSource
        self.lastQuoteAt = lastQuoteAt
        self.lastTradeAt = lastTradeAt
        self.lastBarAt = lastBarAt
    }
}

public struct PortfolioWatchResolvedLiveValue: Sendable, Equatable {
    public let price: Double
    public let source: PortfolioWatchLiveValueSource
    public let observedAt: Date?

    public init(price: Double, source: PortfolioWatchLiveValueSource, observedAt: Date?) {
        self.price = price
        self.source = source
        self.observedAt = observedAt
    }
}

public struct PortfolioWatchIntradaySeriesTracker: Sendable, Equatable {
    public static let defaultMaxPointsPerSeries = 720
    public static let defaultMaxDisplayPointsPerCard = 240

    private struct StoredPoint: Sendable, Equatable {
        let bucketStart: Date
        let timestamp: Date
        let price: Double
    }

    private struct StoredSeries: Sendable, Equatable {
        var dayKey: String
        var points: [StoredPoint]
    }

    public let maxPointsPerSeries: Int
    public let sessionTimeZoneIdentifier: String

    private var seriesBySymbol: [String: StoredSeries]

    public init(
        maxPointsPerSeries: Int = Self.defaultMaxPointsPerSeries,
        sessionTimeZoneIdentifier: String = "America/New_York"
    ) {
        self.maxPointsPerSeries = max(1, maxPointsPerSeries)
        self.sessionTimeZoneIdentifier = sessionTimeZoneIdentifier
        self.seriesBySymbol = [:]
    }

    public var trackedSymbolCount: Int {
        seriesBySymbol.count
    }

    public var totalPointCount: Int {
        seriesBySymbol.values.reduce(0) { partial, series in
            partial + series.points.count
        }
    }

    public func pointCountBySymbol() -> [String: Int] {
        Dictionary(
            uniqueKeysWithValues: seriesBySymbol
                .map { symbol, series in
                    (symbol, series.points.count)
                }
        )
    }

    public mutating func reconcileSymbols(_ symbols: [String]) {
        let active = Set(normalizedOrderedSymbols(symbols))
        seriesBySymbol = seriesBySymbol.filter { active.contains($0.key) }
    }

    public mutating func ingest(
        symbol: String,
        quote: MarketQuote?,
        now: Date
    ) {
        let normalizedSymbol = normalizedOrderedSymbols([symbol]).first ?? ""
        guard !normalizedSymbol.isEmpty,
              let resolvedValue = resolvePortfolioWatchLiveValue(from: quote)
        else {
            return
        }

        let eventDate = resolvedValue.observedAt ?? now
        let dayKey = Self.sessionDayKey(
            for: eventDate,
            timeZoneIdentifier: sessionTimeZoneIdentifier
        )
        let bucketStart = Self.minuteBucketStart(
            for: eventDate,
            timeZoneIdentifier: sessionTimeZoneIdentifier
        )

        var series = seriesBySymbol[normalizedSymbol]
            ?? StoredSeries(dayKey: dayKey, points: [])
        if series.dayKey != dayKey {
            series = StoredSeries(dayKey: dayKey, points: [])
        }

        let storedPoint = StoredPoint(
            bucketStart: bucketStart,
            timestamp: eventDate,
            price: resolvedValue.price
        )
        if let existingIndex = series.points.firstIndex(where: { $0.bucketStart == bucketStart }) {
            series.points[existingIndex] = storedPoint
        } else {
            series.points.append(storedPoint)
        }
        series.points.sort {
            if $0.bucketStart == $1.bucketStart {
                return $0.timestamp < $1.timestamp
            }
            return $0.bucketStart < $1.bucketStart
        }
        if series.points.count > maxPointsPerSeries {
            series.points.removeFirst(series.points.count - maxPointsPerSeries)
        }

        seriesBySymbol[normalizedSymbol] = series
    }

    public func points(for symbol: String) -> [PortfolioWatchIntradayPoint] {
        let normalizedSymbol = normalizedOrderedSymbols([symbol]).first ?? ""
        guard let series = seriesBySymbol[normalizedSymbol] else {
            return []
        }
        return series.points
            .filter { point in
                point.price.isFinite && point.price > 0
            }
            .sorted {
                if $0.bucketStart == $1.bucketStart {
                    return $0.timestamp < $1.timestamp
                }
                return $0.bucketStart < $1.bucketStart
            }
            .map { point in
                PortfolioWatchIntradayPoint(timestamp: point.timestamp, price: point.price)
            }
    }

    public mutating func removeAll(keepingCapacity: Bool = true) {
        seriesBySymbol.removeAll(keepingCapacity: keepingCapacity)
    }

    private static func sessionDayKey(
        for date: Date,
        timeZoneIdentifier: String
    ) -> String {
        let timeZone = TimeZone(identifier: timeZoneIdentifier) ?? TimeZone(secondsFromGMT: 0) ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private static func minuteBucketStart(
        for date: Date,
        timeZoneIdentifier: String
    ) -> Date {
        let timeZone = TimeZone(identifier: timeZoneIdentifier) ?? TimeZone(secondsFromGMT: 0) ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return calendar.date(from: components) ?? date
    }
}

public func downsamplePortfolioWatchIntradayPoints(
    _ points: [PortfolioWatchIntradayPoint],
    maxCount: Int = PortfolioWatchIntradaySeriesTracker.defaultMaxDisplayPointsPerCard
) -> [PortfolioWatchIntradayPoint] {
    let resolvedMaxCount = max(1, maxCount)
    guard points.count > resolvedMaxCount else {
        return points
    }

    if resolvedMaxCount == 1 {
        return Array(points.suffix(1))
    }

    let lastIndex = points.count - 1
    let step = Double(lastIndex) / Double(resolvedMaxCount - 1)
    var sampled: [PortfolioWatchIntradayPoint] = []
    sampled.reserveCapacity(resolvedMaxCount)
    var previousIndex = -1
    for sampleIndex in 0..<resolvedMaxCount {
        let rawIndex = Int((Double(sampleIndex) * step).rounded())
        let index = min(max(rawIndex, 0), lastIndex)
        if index != previousIndex {
            sampled.append(points[index])
            previousIndex = index
        }
    }
    if sampled.last != points.last {
        sampled.append(points[lastIndex])
    }
    if sampled.count > resolvedMaxCount {
        sampled.removeFirst(sampled.count - resolvedMaxCount)
    }
    return sampled
}

public struct PortfolioWatchCardPresentation: Sendable, Equatable, Identifiable {
    public var id: String { symbol }

    public let symbol: String
    public let benchmarkLabel: String?
    public let currentPrice: Double?
    public let changeValue: Double?
    public let changePercent: Double?
    public let isHeld: Bool
    public let pointCount: Int
    public let lastUpdatedAt: Date?
    public let sessionState: PortfolioWatchSessionState
    public let liveState: PortfolioWatchLiveState
    public let priceSource: PortfolioWatchLiveValueSource?
    public let diagnostics: PortfolioWatchLiveDiagnostics
    public let points: [PortfolioWatchIntradayPoint]

    public init(
        symbol: String,
        benchmarkLabel: String?,
        currentPrice: Double?,
        changeValue: Double?,
        changePercent: Double?,
        isHeld: Bool,
        pointCount: Int,
        lastUpdatedAt: Date?,
        sessionState: PortfolioWatchSessionState,
        liveState: PortfolioWatchLiveState,
        priceSource: PortfolioWatchLiveValueSource?,
        diagnostics: PortfolioWatchLiveDiagnostics,
        points: [PortfolioWatchIntradayPoint]
    ) {
        self.symbol = symbol
        self.benchmarkLabel = benchmarkLabel
        self.currentPrice = currentPrice
        self.changeValue = changeValue
        self.changePercent = changePercent
        self.isHeld = isHeld
        self.pointCount = pointCount
        self.lastUpdatedAt = lastUpdatedAt
        self.sessionState = sessionState
        self.liveState = liveState
        self.priceSource = priceSource
        self.diagnostics = diagnostics
        self.points = points
    }
}

public func makePortfolioWatchCardPresentations(
    selectedSymbols: [String],
    positions: [PositionRow],
    quotesBySymbol: [String: MarketQuote],
    optionQuotesBySymbol: [String: MarketQuote],
    marketDataDesiredSubscriptions: MarketDataSubscriptionSet = .empty,
    marketDataSubscriptions: MarketDataSubscriptionSet = .empty,
    tracker: PortfolioWatchIntradaySeriesTracker,
    maxDisplayPointsPerCard: Int = PortfolioWatchIntradaySeriesTracker.defaultMaxDisplayPointsPerCard,
    now: Date
) -> [PortfolioWatchCardPresentation] {
    let heldSymbols = Set(
        positions
            .filter { position in
                if let quantity = Decimal(
                    string: position.qty,
                    locale: Locale(identifier: "en_US_POSIX")
                ) {
                    return quantity != 0
                }
                return true
            }
            .map { $0.symbol.uppercased() }
    )

    return normalizedOrderedSymbols(selectedSymbols).map { symbol in
        let quote = quotesBySymbol[symbol] ?? optionQuotesBySymbol[symbol]
        let points = tracker.points(for: symbol)
        let displayPoints = downsamplePortfolioWatchIntradayPoints(points, maxCount: maxDisplayPointsPerCard)
        let resolvedLiveValue = resolvePortfolioWatchLiveValue(from: quote)
        let currentPrice = resolvedLiveValue?.price ?? points.last?.price
        let baseline = points.first?.price
        let changeValue: Double? = {
            guard let currentPrice, let baseline else {
                return nil
            }
            return currentPrice - baseline
        }()
        let changePercent: Double? = {
            guard let currentPrice, let baseline, baseline != 0 else {
                return nil
            }
            return ((currentPrice - baseline) / baseline) * 100
        }()
        let lastUpdatedAt = resolvedLiveValue?.observedAt ?? points.last?.timestamp
        let subscriptionDesired = marketDataDesiredSubscriptions.quotes.contains(symbol)
            || marketDataDesiredSubscriptions.trades.contains(symbol)
            || marketDataDesiredSubscriptions.optionQuotes.contains(symbol)
            || marketDataDesiredSubscriptions.optionTrades.contains(symbol)
        let subscriptionActive = marketDataSubscriptions.quotes.contains(symbol)
            || marketDataSubscriptions.trades.contains(symbol)
            || marketDataSubscriptions.optionQuotes.contains(symbol)
            || marketDataSubscriptions.optionTrades.contains(symbol)
        let liveState: PortfolioWatchLiveState = {
            if currentPrice == nil {
                return .waitingForFirstUpdate
            }
            if points.count >= 2 {
                return .liveChart
            }
            return .buildingChart
        }()
        let diagnostics = PortfolioWatchLiveDiagnostics(
            symbol: symbol,
            subscriptionDesired: subscriptionDesired,
            subscriptionActive: subscriptionActive,
            pointCount: points.count,
            priceSource: resolvedLiveValue?.source ?? (points.isEmpty ? nil : .trackerCarryForward),
            lastQuoteAt: quote?.lastQuoteTimestamp.flatMap(DateCodec.parseISO8601),
            lastTradeAt: quote?.lastTradeTimestamp.flatMap(DateCodec.parseISO8601),
            lastBarAt: quote?.lastBarTimestamp.flatMap(DateCodec.parseISO8601)
        )

        return PortfolioWatchCardPresentation(
            symbol: symbol,
            benchmarkLabel: portfolioWatchBenchmarkShortLabel(for: symbol),
            currentPrice: currentPrice,
            changeValue: changeValue,
            changePercent: changePercent,
            isHeld: heldSymbols.contains(symbol),
            pointCount: points.count,
            lastUpdatedAt: lastUpdatedAt,
            sessionState: PortfolioWatchSessionState.resolve(at: lastUpdatedAt ?? now),
            liveState: liveState,
            priceSource: diagnostics.priceSource,
            diagnostics: diagnostics,
            points: displayPoints
        )
    }
}

public enum PortfolioWatchWallLayout {
    public static func minimumCardWidth(for selectedCount: Int) -> Double {
        switch selectedCount {
        case 25...:
            return 220
        case 16...24:
            return 236
        default:
            return 260
        }
    }

    public static func columnCount(
        for availableWidth: Double,
        selectedCount: Int,
        minimumCardWidth: Double? = nil,
        spacing: Double = 18
    ) -> Int {
        guard selectedCount > 0 else {
            return 1
        }
        let resolvedMinimumCardWidth = minimumCardWidth ?? Self.minimumCardWidth(for: selectedCount)
        let rawCount = Int(((availableWidth + spacing) / (resolvedMinimumCardWidth + spacing)).rounded(.down))
        return max(1, min(selectedCount, rawCount))
    }

    public static func rowCount(
        for availableWidth: Double,
        selectedCount: Int,
        minimumCardWidth: Double? = nil,
        spacing: Double = 18
    ) -> Int {
        let columns = columnCount(
            for: availableWidth,
            selectedCount: selectedCount,
            minimumCardWidth: minimumCardWidth,
            spacing: spacing
        )
        return max(1, Int(ceil(Double(max(selectedCount, 1)) / Double(max(columns, 1)))))
    }

    public static func gridHeight(
        for availableWidth: Double,
        selectedCount: Int,
        minimumCardWidth: Double? = nil,
        spacing: Double = 18,
        rowHeight: Double = 245
    ) -> Double {
        Double(
            rowCount(
                for: availableWidth,
                selectedCount: selectedCount,
                minimumCardWidth: minimumCardWidth,
                spacing: spacing
            )
        ) * rowHeight
    }
}

public func portfolioWatchLiveCoverageNote(
    cards: [PortfolioWatchCardPresentation],
    sessionState: PortfolioWatchSessionState,
    connectionActive: Bool
) -> String? {
    guard connectionActive, sessionState != .closed else {
        return nil
    }

    let waitingCount = cards.filter { $0.liveState == .waitingForFirstUpdate }.count
    let waitingSubscribedCount = cards.filter {
        $0.liveState == .waitingForFirstUpdate && $0.diagnostics.subscriptionActive
    }.count
    let waitingRequestedCount = cards.filter {
        $0.liveState == .waitingForFirstUpdate &&
            $0.diagnostics.subscriptionDesired &&
            !$0.diagnostics.subscriptionActive
    }.count
    let activeCount = cards.filter { $0.liveState != .waitingForFirstUpdate }.count

    guard waitingCount > 0 else {
        return nil
    }

    if waitingRequestedCount > 0 {
        return "Market data has requested live coverage for \(waitingRequestedCount) selected name\(waitingRequestedCount == 1 ? "" : "s"), but Alpaca has not acknowledged those subscriptions yet."
    }

    if waitingSubscribedCount > 0 && activeCount > 0 {
        return "Live coverage is partial for \(waitingCount) selected name\(waitingCount == 1 ? "" : "s"). Alpaca feed coverage and plan limits can leave larger walls uneven."
    }

    if cards.count >= 16 && waitingSubscribedCount > 0 {
        return "Some selected names are still waiting for live updates. Alpaca feed coverage and symbol limits can delay or reduce simultaneous updates on larger walls."
    }

    return nil
}

private func normalizedOrderedSymbols(_ values: [String]) -> [String] {
    var seen: Set<String> = []
    var ordered: [String] = []

    for value in values {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard normalized.isEmpty == false, seen.insert(normalized).inserted else {
            continue
        }
        ordered.append(normalized)
    }

    return ordered
}

private func preferredPortfolioWatchPrice(from quote: MarketQuote?) -> Double? {
    resolvePortfolioWatchLiveValue(from: quote)?.price
}

public func resolvePortfolioWatchLiveValue(
    from quote: MarketQuote?
) -> PortfolioWatchResolvedLiveValue? {
    guard let quote else {
        return nil
    }

    if let lastPrice = positivePortfolioWatchPrice(quote.lastPrice) {
        let lastTradeAt = quote.lastTradeTimestamp.flatMap(DateCodec.parseISO8601)
        let lastBarAt = quote.lastBarTimestamp.flatMap(DateCodec.parseISO8601)
        if let lastTradeAt, let lastBarAt {
            if lastBarAt > lastTradeAt {
                return PortfolioWatchResolvedLiveValue(
                    price: lastPrice,
                    source: .minuteBar,
                    observedAt: lastBarAt
                )
            }
            return PortfolioWatchResolvedLiveValue(
                price: lastPrice,
                source: .lastTrade,
                observedAt: lastTradeAt
            )
        }
        if let lastTradeAt {
            return PortfolioWatchResolvedLiveValue(
                price: lastPrice,
                source: .lastTrade,
                observedAt: lastTradeAt
            )
        }
        if let lastBarAt {
            return PortfolioWatchResolvedLiveValue(
                price: lastPrice,
                source: .minuteBar,
                observedAt: lastBarAt
            )
        }
        return PortfolioWatchResolvedLiveValue(
            price: lastPrice,
            source: .lastTrade,
            observedAt: quote.timestamp.flatMap(DateCodec.parseISO8601)
        )
    }

    let quoteObservedAt = quote.lastQuoteTimestamp.flatMap(DateCodec.parseISO8601)
        ?? quote.timestamp.flatMap(DateCodec.parseISO8601)
    if let bid = positivePortfolioWatchPrice(quote.bidPrice),
       let ask = positivePortfolioWatchPrice(quote.askPrice) {
        return PortfolioWatchResolvedLiveValue(
            price: (bid + ask) / 2.0,
            source: .midQuote,
            observedAt: quoteObservedAt
        )
    }
    if let bid = positivePortfolioWatchPrice(quote.bidPrice) {
        return PortfolioWatchResolvedLiveValue(
            price: bid,
            source: .bid,
            observedAt: quoteObservedAt
        )
    }
    if let ask = positivePortfolioWatchPrice(quote.askPrice) {
        return PortfolioWatchResolvedLiveValue(
            price: ask,
            source: .ask,
            observedAt: quoteObservedAt
        )
    }

    return nil
}

private func positivePortfolioWatchPrice(_ value: Double?) -> Double? {
    guard let value, value > 0 else {
        return nil
    }
    return value
}
