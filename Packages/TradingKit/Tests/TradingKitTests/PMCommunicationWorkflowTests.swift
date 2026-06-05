import Foundation
import Testing
@testable import TradingKit

@Test("Engine creates a bounded in-app PM/User communication loop")
func engineCreatesInAppPMUserCommunicationLoop() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-loop")
    let now = Date(timeIntervalSince1970: 1_742_000_000)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Runs PM/User communication.",
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let pmMessage = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .pm,
        senderId: "pm-1",
        body: "Please review the current PM recommendation before the next open."
    )
    let ownerReply = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Understood. Keep the risk posture moderate for now.",
        replyToMessageId: pmMessage.messageId
    )

    let sessions = try await engine.listPMCommunicationSessions()
    let messages = try await engine.listPMCommunicationMessages()

    #expect(session.channel == .inApp)
    #expect(session.participantDisplayName == "Owner")
    #expect(sessions.map(\.sessionId) == [session.sessionId])
    #expect(messages.count == 2)
    #expect(messages.first(where: { $0.messageId == pmMessage.messageId })?.direction == .outgoing)
    #expect(messages.first(where: { $0.messageId == ownerReply.messageId })?.direction == .incoming)
    #expect(messages.first(where: { $0.messageId == ownerReply.messageId })?.replyToMessageId == pmMessage.messageId)
}

@Test("PM communication writes publish material Store events for bounded Command Center refresh")
func pmCommunicationWritesPublishMaterialStoreEvents() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-store-events")
    let now = Date(timeIntervalSince1970: 1_742_000_010)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Runs PM/User communication.",
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore
    )
    let observedEvents = Task {
        var seen: Set<String> = []
        for await event in engine.store.events {
            if event.name == "pm_communication_session_upserted"
                || event.name == "pm_communication_message_upserted" {
                seen.insert(event.name)
            }
            if seen == ["pm_communication_session_upserted", "pm_communication_message_upserted"] {
                return seen
            }
        }
        return seen
    }
    await Task.yield()

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    _ = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Please make this material communication write visible in Command Center."
    )

    try? await Task.sleep(nanoseconds: 50_000_000)
    observedEvents.cancel()
    let seen = await observedEvents.value

    #expect(seen.contains("pm_communication_session_upserted"))
    #expect(seen.contains("pm_communication_message_upserted"))
}

@Test("PM decision and approval writes publish material Store events for Your Decisions refresh")
func pmDecisionAndApprovalWritesPublishMaterialStoreEvents() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-decision-approval-store-events")
    let now = Date(timeIntervalSince1970: 1_742_000_020)
    let decisionStore = PMDecisionStore(decisionsDirectory: root.appendingPathComponent("decisions", isDirectory: true))
    let approvalStore = PMApprovalRequestStore(approvalRequestsDirectory: root.appendingPathComponent("approval_requests", isDirectory: true))
    let engine = Engine(
        pmDecisionStore: decisionStore,
        pmApprovalRequestStore: approvalStore
    )
    let observedEvents = Task {
        var seen: Set<String> = []
        for await event in engine.store.events {
            if event.name == "pm_decision_upserted"
                || event.name == "pm_approval_request_upserted" {
                seen.insert(event.name)
            }
            if seen == ["pm_decision_upserted", "pm_approval_request_upserted"] {
                return seen
            }
        }
        return seen
    }
    await Task.yield()

    let decision = try await engine.upsertPMDecision(
        PMDecisionRecord(
            decisionId: "decision-owner-refresh-1",
            pmId: "pm-1",
            title: "Live order review: buy META",
            summary: "Review a Live order instruction without submitting anything.",
            recommendedAction: "Surface the review in Command Center > Your Decisions.",
            ownerAsk: "Approve whether this Live order instruction should advance.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await engine.createPMApprovalRequestFromDecision(
        decisionId: decision.decisionId,
        subject: "Approve Live META buy review",
        rationale: "Review-only Live order artifact. No order has been submitted.",
        requestedActionSummary: "Review buy META market Day order before any governed route.",
        requestType: .liveOrderReview
    )

    try? await Task.sleep(nanoseconds: 50_000_000)
    observedEvents.cancel()
    let seen = await observedEvents.value

    #expect(seen.contains("pm_decision_upserted"))
    #expect(seen.contains("pm_approval_request_upserted"))
}

@Test("Owner asks generate a persisted PM conversation reply in the same in-app session")
func ownerAskGeneratesPersistedPMConversationReply() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-auto-reply")
    let now = Date(timeIntervalSince1970: 1_742_000_025)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let strategyBriefStore = PortfolioStrategyBriefStore(fileURL: root.appendingPathComponent("strategy_brief.json", isDirectory: false))

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Runs PM/User communication.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await strategyBriefStore.upsert(
        PortfolioStrategyBrief(
            title: "Current Portfolio Strategy Brief",
            documentBody: """
            ## Objective
            Keep the portfolio concentrated in high-conviction names while tightening downside review.

            ## Key Themes
            - concentration discipline
            - catalyst-aware sizing

            ## Current Risk Posture
            Constructive, but less tolerant of thesis drift.

            ## Material Developments
            - Earnings dispersion is widening.

            ## Review Posture
            Escalate meaningful posture changes quickly.
            """,
            objectiveSummary: "Keep the portfolio concentrated in high-conviction names while tightening downside review.",
            keyThemes: ["concentration discipline", "catalyst-aware sizing"],
            currentRiskPosture: "Constructive, but less tolerant of thesis drift.",
            materialDevelopments: ["Earnings dispersion is widening."],
            reviewEscalationPosture: "Escalate meaningful posture changes quickly.",
            updatedBy: "owner",
            updateSource: .userEdited,
            createdAt: now,
            updatedAt: now
        )
    )
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "I reviewed the Portfolio Strategy Brief. Before I would revise it, I would tighten these points: make the review thresholds more explicit, define what elevates to an owner-facing decision, and clarify how concentration discipline should be documented.",
            resolution: PMConversationResolutionState(
                intentClass: .general,
                disposition: .conversationOnly
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        portfolioStrategyBriefStore: strategyBriefStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Please read the Portfolio Strategy Brief and give me your questions and comments on it.",
        source: .ui
    )
    let reply = try await engine.generatePMConversationReply(
        to: ownerAsk.messageId,
        source: .ui
    )

    let messages = try await engine.listPMCommunicationMessages()
        .filter { $0.sessionId == session.sessionId }
        .sorted { lhs, rhs in
            if lhs.sentAt == rhs.sentAt {
                return lhs.messageId < rhs.messageId
            }
            return lhs.sentAt < rhs.sentAt
        }

    #expect(reply.senderRole == .pm)
    #expect(reply.direction == .outgoing)
    #expect(reply.replyToMessageId == ownerAsk.messageId)
    #expect(reply.sessionId == session.sessionId)
    #expect(reply.body.contains("Portfolio Strategy Brief"))
    #expect(reply.body.contains("Before I would revise it, I would tighten these points:"))
    #expect(reply.body.contains("I recorded your latest ask") == false)
    #expect(messages.count == 2)
    #expect(messages.last?.messageId == reply.messageId)
}

@Test("Substantive PM conversation replies use model-backed synthesis when provider and key are available")
func substantivePMConversationRepliesUseModelBackedSynthesisWhenAvailable() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-openai-backed")
    let now = Date(timeIntervalSince1970: 1_742_000_026)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let strategyBriefStore = PortfolioStrategyBriefStore(fileURL: root.appendingPathComponent("portfolio_strategy_brief.json", isDirectory: false))
    let runtimeSettingsStore = PMRuntimeSettingsStore(fileURL: root.appendingPathComponent("pm-runtime-settings.json", isDirectory: false))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "I reviewed the current strategy and would keep the posture constructive while tightening earnings-risk monitoring."
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Runs PM/User communication.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await strategyBriefStore.upsert(
        PortfolioStrategyBrief(
            title: "Current Portfolio Strategy Brief",
            documentBody: "Brief body",
            objectiveSummary: "Stay constructive while keeping earnings risk visible.",
            keyThemes: ["AI infrastructure", "earnings discipline"],
            currentRiskPosture: "Constructive with tighter earnings review.",
            reviewEscalationPosture: "Escalate only material posture changes.",
            updatedBy: "owner",
            updateSource: .userEdited,
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await runtimeSettingsStore.upsert(
        PMRuntimeSettings(
            runtimeIdentifier: "gpt-5.4",
            reasoningMode: .deliberate,
            updatedBy: "pm-primary",
            updateSource: .pmControlPlane,
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmRuntimeSettingsStore: runtimeSettingsStore,
        portfolioStrategyBriefStore: strategyBriefStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "How should I think about the current strategy and earnings risk?",
        source: .ui
    )
    let reply = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)
    let request = try #require(await synthesisProvider.lastConversationRequest)

    #expect(reply.body.contains("tightening earnings-risk monitoring"))
    #expect(reply.runtimeProvenance?.actualRuntimeIdentifier == "openai_responses[gpt-5.4]")
    #expect(reply.runtimeProvenance?.usedOpenAI == true)
    #expect(reply.runtimeProvenance?.conversationTrace?.pathKind == .modelBacked)
    #expect(reply.runtimeProvenance?.conversationTrace?.visibleReplySource == .modelReply)
    #expect(reply.runtimeProvenance?.conversationTrace?.actionPlanSource == .modelResolution)
    #expect(reply.runtimeProvenance?.conversationTrace?.modelSynthesisAttempted == true)
    #expect(reply.runtimeProvenance?.conversationTrace?.modelProducedUsableReply == true)
    #expect(reply.runtimeProvenance?.conversationTrace?.visibleReplyModifiedAfterSynthesis == false)
    #expect(request.runtimeIdentifier == "gpt-5.4")
    #expect(request.plannerMode == "owner_conversation_action_planning")
}

@Test("PM runtime provider Anthropic routes conversation synthesis through Anthropic adapter")
func pmRuntimeProviderAnthropicRoutesConversationSynthesisThroughAnthropicAdapter() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-anthropic-backed")
    let now = Date(timeIntervalSince1970: 1_742_000_026.5)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let runtimeSettingsStore = PMRuntimeSettingsStore(fileURL: root.appendingPathComponent("pm-runtime-settings.json", isDirectory: false))
    let anthropicProvider = StubPMAnthropicSynthesisProvider(
        output: PMConversationOpenAISynthesisOutput(
            replyBody: "Anthropic-backed PM reply from the same bounded PM context.",
            resolution: PMConversationResolutionState(
                intentClass: .general,
                disposition: .conversationOnly
            )
        )
    )
    let openAIProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(replyBody: "OpenAI should not be used."),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Runs provider-aware PM conversation.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await runtimeSettingsStore.upsert(
        PMRuntimeSettings(
            providerKind: .anthropic,
            credentialProfileId: LLMCredentialProfile.anthropicDefaultProfileID,
            runtimeIdentifier: "claude-sonnet-4-20250514",
            reasoningMode: .standard,
            updatedBy: "owner",
            updateSource: .userEdited,
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmRuntimeSettingsStore: runtimeSettingsStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        llmCredentialResolver: StubPMCommunicationLLMCredentialResolver(
            resolution: LLMCredentialResolution(
                status: .ready,
                apiKey: "test-anthropic-key",
                profileId: LLMCredentialProfile.anthropicDefaultProfileID,
                providerKind: .anthropic,
                matchedServiceOrLabel: "anthropic_api_key",
                account: "algo-trading",
                summary: "Test Anthropic key resolved."
            )
        ),
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: openAIProvider,
        pmAnthropicSynthesisProvider: anthropicProvider
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Give me your current PM read.",
        source: .ui
    )
    let reply = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)

    #expect(reply.body == "Anthropic-backed PM reply from the same bounded PM context.")
    #expect(reply.runtimeProvenance?.actualProviderKind == .anthropic)
    #expect(reply.runtimeProvenance?.actualCredentialProfileId == LLMCredentialProfile.anthropicDefaultProfileID)
    #expect(reply.runtimeProvenance?.actualRuntimeIdentifier == "anthropic_messages[claude-sonnet-4-20250514]")
    #expect(reply.runtimeProvenance?.usedOpenAI == false)
    #expect(reply.runtimeProvenance?.synthesisStatus == "anthropic_messages")
    #expect(reply.runtimeProvenance?.conversationTrace?.pathKind == .modelBacked)
    #expect(await anthropicProvider.lastAPIKey == "test-anthropic-key")
    #expect(await anthropicProvider.lastConversationRequest?.runtimeIdentifier == "claude-sonnet-4-20250514")
    #expect(await openAIProvider.lastConversationRequest == nil)
}

@Test("Missing Anthropic PM credential produces precise fallback without OpenAI fallback")
func missingAnthropicPMCredentialDoesNotFallBackToOpenAI() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-anthropic-missing-key")
    let now = Date(timeIntervalSince1970: 1_742_000_026.75)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let runtimeSettingsStore = PMRuntimeSettingsStore(fileURL: root.appendingPathComponent("pm-runtime-settings.json", isDirectory: false))
    let anthropicProvider = StubPMAnthropicSynthesisProvider(
        output: PMConversationOpenAISynthesisOutput(replyBody: "Anthropic should not be called.")
    )
    let openAIProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(replyBody: "OpenAI should not be used."),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Runs provider-aware PM conversation.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await runtimeSettingsStore.upsert(
        PMRuntimeSettings(
            providerKind: .anthropic,
            credentialProfileId: LLMCredentialProfile.anthropicDefaultProfileID,
            runtimeIdentifier: "claude-sonnet-4-20250514",
            reasoningMode: .standard,
            lastKnownGoodRuntime: LastKnownGoodRuntimeRecord(
                providerKind: .openAI,
                credentialProfileId: LLMCredentialProfile.openAIDefaultProfileID,
                runtimeIdentifier: "gpt-5.4",
                reasoningMode: .standard,
                verifiedAt: now.addingTimeInterval(-60),
                summary: "Prior OpenAI runtime should not be cross-provider fallback when Anthropic is selected."
            ),
            updatedBy: "owner",
            updateSource: .userEdited,
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmRuntimeSettingsStore: runtimeSettingsStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        llmCredentialResolver: StubPMCommunicationLLMCredentialResolver(
            resolution: LLMCredentialResolution(
                status: .missingKey,
                profileId: LLMCredentialProfile.anthropicDefaultProfileID,
                providerKind: .anthropic,
                account: "algo-trading",
                summary: "No Anthropic API key was found in Keychain for service anthropic_api_key account algo-trading."
            )
        ),
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: openAIProvider,
        pmAnthropicSynthesisProvider: anthropicProvider
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Can you answer through Anthropic?",
        source: .ui
    )
    let reply = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)

    #expect(reply.body.contains("Anthropic credentials are unavailable") == true)
    #expect(reply.runtimeProvenance?.actualProviderKind == .anthropic)
    #expect(reply.runtimeProvenance?.actualRuntimeIdentifier == "deterministic_local_fallback[claude-sonnet-4-20250514]")
    #expect(reply.runtimeProvenance?.usedOpenAI == false)
    #expect(reply.runtimeProvenance?.synthesisStatus == "fallback_missing_anthropic_key")
    #expect(await anthropicProvider.lastConversationRequest == nil)
    #expect(await openAIProvider.lastConversationRequest == nil)
}

@Test("Working-portfolio structure questions use model-backed synthesis when provider and key are available")
func workingPortfolioStructureQuestionsUseModelBackedSynthesisWhenAvailable() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-working-portfolio-openai")
    let now = Date(timeIntervalSince1970: 1_742_000_027)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let instructionStore = PMInstructionStore(instructionsDirectory: root.appendingPathComponent("instructions", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "The latest conversation-defined initial paper portfolio is long MSFT and NVDA with NYCB on the short side plus a cash buffer. I’m treating that as the current working portfolio definition, not confirmed holdings."
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Answers from the latest working portfolio definition.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await instructionStore.upsert(
        PMInstruction(
            instructionId: "instruction-working-portfolio",
            pmId: "pm-1",
            title: "Working paper portfolio definition",
            body: "Initial paper portfolio: long MSFT, long NVDA, short NYCB, and hold a cash buffer until confirmed holdings are rebuilt from app truth.",
            category: "conversation_working_portfolio_definition",
            status: .active,
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmInstructionStore: instructionStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Please list the latest structure for the initial paper portfolio.",
        source: .ui
    )
    let reply = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)
    let request = try #require(await synthesisProvider.lastConversationRequest)

    #expect(reply.body.contains("latest conversation-defined initial paper portfolio"))
    #expect(request.plannerMode == "owner_conversation_action_planning")
    #expect(request.workingPortfolioDefinitionSummary.contains(where: { $0.contains("long MSFT") && $0.contains("short NYCB") }))
    #expect(reply.body.contains("Your latest ask is") == false)
}

@Test("In-app follow-ups inherit Telegram working truth and same-owner continuity")
func inAppFollowUpsInheritTelegramWorkingTruthAndContinuity() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-cross-channel-continuity")
    let now = Date()
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "I’m carrying forward the proposed short sleeve from our recent conversation and I’ll answer from that same working context here."
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Keeps Telegram and in-app owner continuity aligned.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await sessionStore.upsert(
        PMCommunicationSession(
            sessionId: "pm-user-telegram-chat-testchatownersenda",
            channel: .telegram,
            externalConversationId: "667788",
            pmId: "pm-1",
            participantId: "8899",
            participantDisplayName: "@owneruser",
            status: .active,
            createdAt: now.addingTimeInterval(-120),
            updatedAt: now.addingTimeInterval(-60)
        )
    )
    _ = try await messageStore.upsert(
        PMCommunicationMessage(
            messageId: "telegram-owner-1",
            sessionId: "pm-user-telegram-chat-testchatownersenda",
            direction: .incoming,
            senderRole: .owner,
            senderId: "owner",
            body: "Here is my current proposed paper portfolio. Long positions: NVDA, TSM, AVGO. Short positions: NYCB, KSS.",
            sentAt: now.addingTimeInterval(-120),
            createdAt: now.addingTimeInterval(-120),
            updatedAt: now.addingTimeInterval(-120)
        )
    )
    _ = try await messageStore.upsert(
        PMCommunicationMessage(
            messageId: "telegram-pm-1",
            sessionId: "pm-user-telegram-chat-testchatownersenda",
            direction: .outgoing,
            senderRole: .pm,
            senderId: "pm-1",
            body: "Understood. I’m carrying that forward as the current working paper portfolio for this same PM relationship.",
            sentAt: now.addingTimeInterval(-110),
            createdAt: now.addingTimeInterval(-110),
            updatedAt: now.addingTimeInterval(-110)
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let inAppSession = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: inAppSession.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Regarding the proposed short positions, what are the analyst conviction levels and reasoning?",
        source: .ui
    )
    _ = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)
    let request = try #require(await synthesisProvider.lastConversationRequest)

    #expect(request.sessionChannel == PMCommunicationChannel.inApp.rawValue)
    #expect(request.workingPortfolioDefinitionSummary.contains(where: {
        $0.contains("Long positions: NVDA, TSM, AVGO") && $0.contains("Short positions: NYCB, KSS")
    }))
    #expect(request.conversationFragmentSummary.contains(where: {
        $0.contains("Telegram") || $0.contains("carried from Telegram")
    }))
}

@Test("Earlier-conversation questions route through the dedicated conversation-history intent without requiring explicit log-review wording")
func earlierConversationQuestionsRouteThroughConversationHistoryIntent() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-history-intent-routing")
    let now = Date(timeIntervalSince1970: 1_742_000_027)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "From our earlier discussion, the standing guidance was to keep more cash around the earnings cluster and revisit sizing after the prints."
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Routes earlier-conversation asks through history-aware PM synthesis.",
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    _ = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Before the next earnings cluster, keep more cash buffering and wait for the prints before resizing.",
        source: .ui
    )
    _ = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .pm,
        senderId: "pm-1",
        body: "Understood. I will keep the earnings cash-buffering guidance in mind.",
        source: .ui
    )

    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "What did we decide earlier about earnings cash buffering?",
        source: .ui
    )
    _ = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)
    let request = try #require(await synthesisProvider.lastConversationRequest)

    #expect(request.plannerMode == "owner_conversation_action_planning")
    #expect(request.recentConversationSummary.contains(where: { $0.contains("earnings cash buffering") }))
}

@Test("Earlier-conversation portfolio questions automatically escalate from active memory to detailed communication-log retrieval when needed")
func earlierConversationPortfolioQuestionsEscalateToDetailedCommunicationLogRetrieval() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-history-escalation")
    let now = Date(timeIntervalSince1970: 1_742_000_028)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "From our recent communications, the latest proposed paper portfolio was long MSFT and AMD with NYCB on the short side."
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Escalates to bounded detailed communication-log retrieval when active conversation is not enough.",
            createdAt: now,
            updatedAt: now
        )
    )

    let earlierSession = PMCommunicationSession(
        sessionId: "session-earlier-paper-portfolio",
        channel: .inApp,
        pmId: "pm-1",
        participantId: "owner",
        participantDisplayName: "Owner",
        status: .closed,
        createdAt: now.addingTimeInterval(-(7 * 24 * 60 * 60)),
        updatedAt: now.addingTimeInterval(-(7 * 24 * 60 * 60))
    )
    _ = try await sessionStore.upsert(earlierSession)
    _ = try await messageStore.upsert(
        PMCommunicationMessage(
            messageId: "earlier-owner-portfolio",
            sessionId: earlierSession.sessionId,
            direction: .incoming,
            senderRole: .owner,
            senderId: "owner",
            body: "For the initial paper portfolio, keep MSFT and AMD in the long sleeve and use NYCB on the short side.",
            sentAt: now.addingTimeInterval(-(7 * 24 * 60 * 60) + 60),
            createdAt: now.addingTimeInterval(-(7 * 24 * 60 * 60) + 60),
            updatedAt: now.addingTimeInterval(-(7 * 24 * 60 * 60) + 60)
        )
    )
    _ = try await messageStore.upsert(
        PMCommunicationMessage(
            messageId: "earlier-pm-portfolio",
            sessionId: earlierSession.sessionId,
            direction: .outgoing,
            senderRole: .pm,
            senderId: "pm-1",
            body: "Understood. I will treat MSFT and AMD as the proposed long sleeve with NYCB on the short side for the paper portfolio.",
            sentAt: now.addingTimeInterval(-(7 * 24 * 60 * 60) + 120),
            createdAt: now.addingTimeInterval(-(7 * 24 * 60 * 60) + 120),
            updatedAt: now.addingTimeInterval(-(7 * 24 * 60 * 60) + 120)
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let currentSession = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: currentSession.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "From our recent communications, what was the latest long and short structure for the paper portfolio?",
        source: .ui
    )
    let reply = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)
    let request = try #require(await synthesisProvider.lastConversationRequest)

    #expect(reply.body.contains("latest proposed paper portfolio"))
    #expect(request.plannerMode == "owner_conversation_action_planning")
    #expect(request.recentConversationSummary.contains(where: { $0.contains("From our recent communications") }))
    #expect(request.detailedCommunicationHistorySummary.isEmpty == false)
    #expect(request.detailedCommunicationHistorySummary.contains(where: { summary in
        summary.contains("owner: For the initial paper portfolio")
            && summary.contains("pm: Understood. I will treat MSFT and AMD")
            && summary.contains("NYCB")
    }))
}

@Test("Detailed communication-history retrieval prefers the clean earlier portfolio body over later renderer-style PM dumps")
func detailedCommunicationHistoryPrefersCleanEarlierPortfolioBody() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-clean-history-body")
    let now = Date(timeIntervalSince1970: 1_744_922_800)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "Earlier this week the latest proposed paper portfolio was long ACN, MSFT, NVDA, ISRG, CME, ICE, GS, JPM, SOFI, and ETN with NYCB on the short side."
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Uses detailed communication bodies instead of synthetic history dumps when reconstructing portfolio context.",
            createdAt: now,
            updatedAt: now
        )
    )

    let earlierSession = PMCommunicationSession(
        sessionId: "session-earlier-detailed-portfolio",
        channel: .inApp,
        pmId: "pm-1",
        participantId: "owner",
        participantDisplayName: "Owner",
        status: .closed,
        createdAt: now.addingTimeInterval(-(6 * 24 * 60 * 60)),
        updatedAt: now.addingTimeInterval(-(6 * 24 * 60 * 60))
    )
    _ = try await sessionStore.upsert(earlierSession)
    _ = try await messageStore.upsert(
        PMCommunicationMessage(
            messageId: "earlier-owner-detailed-portfolio",
            sessionId: earlierSession.sessionId,
            direction: .incoming,
            senderRole: .owner,
            senderId: "owner",
            body: "For the paper portfolio, use ACN, MSFT, NVDA, ISRG, CME, ICE, GS, JPM, SOFI, and ETN on the long side with NYCB as the single short.",
            sentAt: now.addingTimeInterval(-(6 * 24 * 60 * 60) + 60),
            createdAt: now.addingTimeInterval(-(6 * 24 * 60 * 60) + 60),
            updatedAt: now.addingTimeInterval(-(6 * 24 * 60 * 60) + 60)
        )
    )
    _ = try await messageStore.upsert(
        PMCommunicationMessage(
            messageId: "earlier-pm-detailed-portfolio",
            sessionId: earlierSession.sessionId,
            direction: .outgoing,
            senderRole: .pm,
            senderId: "pm-1",
            body: "The proposed paper portfolio earlier this week was long ACN, MSFT, NVDA, ISRG, CME, ICE, GS, JPM, SOFI, and ETN with NYCB on the short side.",
            sentAt: now.addingTimeInterval(-(6 * 24 * 60 * 60) + 120),
            createdAt: now.addingTimeInterval(-(6 * 24 * 60 * 60) + 120),
            updatedAt: now.addingTimeInterval(-(6 * 24 * 60 * 60) + 120)
        )
    )

    let currentSession = try await sessionStore.upsert(
        PMCommunicationSession(
            sessionId: "session-current-history-dump",
            channel: .inApp,
            pmId: "pm-1",
            participantId: "owner",
            participantDisplayName: "Owner",
            status: .active,
            createdAt: now.addingTimeInterval(-(2 * 60 * 60)),
            updatedAt: now.addingTimeInterval(-(2 * 60 * 60))
        )
    )
    _ = try await messageStore.upsert(
        PMCommunicationMessage(
            messageId: "current-pm-history-dump",
            sessionId: currentSession.sessionId,
            direction: .outgoing,
            senderRole: .pm,
            senderId: "pm-1",
            body: """
            I’m grounding this on the current objective of ## Example Technology Research Portfolio.

            The most relevant prior context I found is Earlier same-day thread: owner: List the proposed initial paper portfolio. || pm: From our recent communications, the latest proposed initial paper portfolio was long ACN, MSFT, NVDA, ISRG, CME, ICE, GS, JPM, SOFI, and ETN with NYCB on the short side.

            The app does not currently show confirmed holdings, so any names from our conversation or standing review remain working ideas rather than validated holdings.

            If you want, I can go one layer deeper on the active thread from here.
            """,
            sentAt: now.addingTimeInterval(-(60 * 60)),
            createdAt: now.addingTimeInterval(-(60 * 60)),
            updatedAt: now.addingTimeInterval(-(60 * 60))
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: currentSession.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "The actual list is in your earlier response this week. Can you pull that proposed paper portfolio list of long and short positions?",
        source: .ui
    )
    _ = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)
    let request = try #require(await synthesisProvider.lastConversationRequest)

    #expect(request.plannerMode == "owner_conversation_action_planning")
    #expect(request.detailedCommunicationHistorySummary.contains(where: { summary in
        summary.contains("ACN")
            && summary.contains("MSFT")
            && summary.contains("NVDA")
            && summary.contains("NYCB")
    }))
    #expect(request.detailedCommunicationHistorySummary.contains(where: { summary in
        summary.contains("I’m grounding this on the current objective")
            || summary.contains("If you want, I can go one layer deeper")
    }) == false)
}

@Test("Specific earlier-response references retrieve the exact PM and owner bodies instead of mixed recap context")
func specificEarlierResponseReferencesRetrieveExactBodies() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-specific-entry-exact-body")
    let calendar = Calendar(identifier: .gregorian)
    let timeZone = TimeZone.current
    let now = try #require(calendar.date(from: DateComponents(
        timeZone: timeZone,
        year: 2026,
        month: 4,
        day: 18,
        hour: 21,
        minute: 10,
        second: 0
    )))
    let earlierOwnerSentAt = try #require(calendar.date(from: DateComponents(
        timeZone: timeZone,
        year: 2026,
        month: 4,
        day: 12,
        hour: 11,
        minute: 35,
        second: 0
    )))
    let earlierPMSentAt = try #require(calendar.date(from: DateComponents(
        timeZone: timeZone,
        year: 2026,
        month: 4,
        day: 12,
        hour: 11,
        minute: 35,
        second: 44
    )))
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "Yes — in that earlier response, the proposed paper portfolio list was long ACN, MSFT, NVDA, ISRG, CME, ICE, GS, JPM, SOFI, and ETN with NYCB on the short side."
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Retrieves exact earlier PM communication bodies when the owner points to a specific response.",
            createdAt: now,
            updatedAt: now
        )
    )

    let earlierSession = PMCommunicationSession(
        sessionId: "session-specific-entry-earlier",
        channel: .inApp,
        pmId: "pm-1",
        participantId: "owner",
        participantDisplayName: "Owner",
        status: .closed,
        createdAt: earlierOwnerSentAt,
        updatedAt: earlierPMSentAt
    )
    _ = try await sessionStore.upsert(earlierSession)
    _ = try await messageStore.upsert(
        PMCommunicationMessage(
            messageId: "specific-entry-owner",
            sessionId: earlierSession.sessionId,
            direction: .incoming,
            senderRole: .owner,
            senderId: "owner",
            body: "Please formalize the proposed paper portfolio exactly as discussed: longs ACN, MSFT, NVDA, ISRG, CME, ICE, GS, JPM, SOFI, and ETN, with NYCB as the single short.",
            sentAt: earlierOwnerSentAt,
            createdAt: earlierOwnerSentAt,
            updatedAt: earlierOwnerSentAt
        )
    )
    _ = try await messageStore.upsert(
        PMCommunicationMessage(
            messageId: "specific-entry-pm",
            sessionId: earlierSession.sessionId,
            direction: .outgoing,
            senderRole: .pm,
            senderId: "pm-1",
            body: """
            Understood. Based on your latest direction, I would formalize the portfolio as follows.

            Formal risk posture: Example Technology Research Portfolio.

            Capital deployment: Paper account size $100,000. Initial deployed capital target $80,000.

            Long sleeve: ACN, MSFT, NVDA, ISRG, CME, ICE, GS, JPM, SOFI, and ETN.
            Short side: NYCB.
            """,
            sentAt: earlierPMSentAt,
            replyToMessageId: "specific-entry-owner",
            createdAt: earlierPMSentAt,
            updatedAt: earlierPMSentAt
        )
    )

    let currentSession = try await sessionStore.upsert(
        PMCommunicationSession(
            sessionId: "session-specific-entry-current",
            channel: .inApp,
            pmId: "pm-1",
            participantId: "owner",
            participantDisplayName: "Owner",
            status: .active,
            createdAt: now.addingTimeInterval(-(90 * 60)),
            updatedAt: now.addingTimeInterval(-(90 * 60))
        )
    )
    _ = try await messageStore.upsert(
        PMCommunicationMessage(
            messageId: "specific-entry-later-recap",
            sessionId: currentSession.sessionId,
            direction: .outgoing,
            senderRole: .pm,
            senderId: "pm-1",
            body: "From our recent conversation, the latest proposed initial paper portfolio is a structure centered on NYCB, NVDA, TSM, AVGO, AMZN, CRWD, NFLX, and GOOG.",
            sentAt: now.addingTimeInterval(-(60 * 60)),
            createdAt: now.addingTimeInterval(-(60 * 60)),
            updatedAt: now.addingTimeInterval(-(60 * 60))
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: currentSession.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "I think the actual list is in your response to me on April 12, 11:35:44. Can you see that detailed log file? If so, pull that proposed paper portfolio list of long / short positions.",
        source: .ui
    )
    _ = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)
    let request = try #require(await synthesisProvider.lastConversationRequest)
    let exactSummary = try #require(request.detailedCommunicationHistorySummary.first)

    #expect(request.plannerMode == "owner_conversation_action_planning")
    #expect(request.detailedCommunicationHistorySummary.count == 1)
    #expect(exactSummary.hasPrefix("Specific communication entry body window: "))
    #expect(exactSummary.contains("owner ["))
    #expect(exactSummary.contains("pm ["))
    #expect(exactSummary.contains("Please formalize the proposed paper portfolio exactly as discussed"))
    #expect(exactSummary.contains("Capital deployment: Paper account size $100,000"))
    #expect(exactSummary.contains("Long sleeve: ACN, MSFT, NVDA, ISRG, CME, ICE, GS, JPM, SOFI, and ETN."))
    #expect(exactSummary.contains("Short side: NYCB."))
    #expect(exactSummary.contains("TSM") == false)
    #expect(request.workingPortfolioDefinitionSummary.isEmpty)
    #expect(request.proposedTruthUpdateSummary.isEmpty)
    #expect(request.conversationFragmentSummary.isEmpty)
    #expect(request.recoveredContextSummary.isEmpty)
}

@Test("Runtime-failure fallback does not reconstruct exact earlier responses procedurally")
func fallbackSpecificEntryRecallAnswersNaturallyFromExactEarlierResponse() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-specific-entry-fallback")
    let calendar = Calendar(identifier: .gregorian)
    let timeZone = TimeZone.current
    let now = try #require(calendar.date(from: DateComponents(
        timeZone: timeZone,
        year: 2026,
        month: 4,
        day: 18,
        hour: 21,
        minute: 20,
        second: 0
    )))
    let earlierOwnerSentAt = try #require(calendar.date(from: DateComponents(
        timeZone: timeZone,
        year: 2026,
        month: 4,
        day: 12,
        hour: 11,
        minute: 35,
        second: 0
    )))
    let earlierPMSentAt = try #require(calendar.date(from: DateComponents(
        timeZone: timeZone,
        year: 2026,
        month: 4,
        day: 12,
        hour: 11,
        minute: 35,
        second: 44
    )))
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Falls back to the exact earlier PM response naturally when model synthesis is unavailable.",
            createdAt: now,
            updatedAt: now
        )
    )

    let earlierSession = PMCommunicationSession(
        sessionId: "session-specific-entry-fallback-earlier",
        channel: .inApp,
        pmId: "pm-1",
        participantId: "owner",
        participantDisplayName: "Owner",
        status: .closed,
        createdAt: earlierOwnerSentAt,
        updatedAt: earlierPMSentAt
    )
    _ = try await sessionStore.upsert(earlierSession)
    _ = try await messageStore.upsert(
        PMCommunicationMessage(
            messageId: "specific-entry-fallback-owner",
            sessionId: earlierSession.sessionId,
            direction: .incoming,
            senderRole: .owner,
            senderId: "owner",
            body: "Please lock the paper portfolio list as long ACN, MSFT, NVDA, ISRG, CME, ICE, GS, JPM, SOFI, and ETN with NYCB on the short side.",
            sentAt: earlierOwnerSentAt,
            createdAt: earlierOwnerSentAt,
            updatedAt: earlierOwnerSentAt
        )
    )
    _ = try await messageStore.upsert(
        PMCommunicationMessage(
            messageId: "specific-entry-fallback-pm",
            sessionId: earlierSession.sessionId,
            direction: .outgoing,
            senderRole: .pm,
            senderId: "pm-1",
            body: "Yes — in that earlier response, the proposed paper portfolio list was long ACN, MSFT, NVDA, ISRG, CME, ICE, GS, JPM, SOFI, and ETN with NYCB on the short side.",
            sentAt: earlierPMSentAt,
            replyToMessageId: "specific-entry-fallback-owner",
            createdAt: earlierPMSentAt,
            updatedAt: earlierPMSentAt
        )
    )

    let currentSession = try await sessionStore.upsert(
        PMCommunicationSession(
            sessionId: "session-specific-entry-fallback-current",
            channel: .inApp,
            pmId: "pm-1",
            participantId: "owner",
            participantDisplayName: "Owner",
            status: .active,
            createdAt: now.addingTimeInterval(-(30 * 60)),
            updatedAt: now.addingTimeInterval(-(30 * 60))
        )
    )
    _ = try await messageStore.upsert(
        PMCommunicationMessage(
            messageId: "specific-entry-fallback-recap",
            sessionId: currentSession.sessionId,
            direction: .outgoing,
            senderRole: .pm,
            senderId: "pm-1",
            body: "From our recent conversation, the latest proposed initial paper portfolio is a structure centered on NYCB, NVDA, TSM, AVGO, AMZN, CRWD, NFLX, and GOOG.",
            sentAt: now.addingTimeInterval(-(10 * 60)),
            createdAt: now.addingTimeInterval(-(10 * 60)),
            updatedAt: now.addingTimeInterval(-(10 * 60))
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: false, value: nil)
    )

    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: currentSession.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "The actual list is in your response to me on April 12, 11:35:44. Can you pull that proposed paper portfolio list of long / short positions?",
        source: .ui
    )
    let reply = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)

    #expect(reply.body.contains("I couldn't complete a PM answer because the PM runtime failed:"))
    #expect(reply.body.contains("OpenAI credentials are unavailable for the PM runtime"))
    #expect(reply.body.contains("ACN") == false)
    #expect(reply.body.contains("MSFT") == false)
    #expect(reply.body.contains("NYCB") == false)
    #expect(reply.body.contains("TSM") == false)
    #expect(reply.body.contains("Specific communication entry") == false)
    #expect(reply.conversationResolution == nil)
    #expect(reply.conversationActionPlan == nil)
    #expect(reply.runtimeProvenance?.conversationTrace?.fallbackTrigger == .credentialUnavailable)
    #expect(reply.runtimeProvenance?.conversationTrace?.fallbackTriggerWasAllowedRuntimeFailure == true)
    #expect(reply.runtimeProvenance?.conversationTrace?.modelSynthesisAttempted == false)
    #expect(reply.runtimeProvenance?.conversationTrace?.modelProducedUsableReply == false)
}

@Test("Exact specific-entry recall suppresses stale recap messages from the recent-conversation model context")
func exactSpecificEntryRecallSuppressesStaleRecapMessagesFromRecentConversationContext() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-specific-entry-suppresses-recaps")
    let calendar = Calendar(identifier: .gregorian)
    let timeZone = TimeZone.current
    let now = try #require(calendar.date(from: DateComponents(
        timeZone: timeZone,
        year: 2026,
        month: 4,
        day: 19,
        hour: 10,
        minute: 25,
        second: 0
    )))
    let earlierOwnerSentAt = try #require(calendar.date(from: DateComponents(
        timeZone: timeZone,
        year: 2026,
        month: 4,
        day: 12,
        hour: 11,
        minute: 35,
        second: 0
    )))
    let earlierPMSentAt = try #require(calendar.date(from: DateComponents(
        timeZone: timeZone,
        year: 2026,
        month: 4,
        day: 12,
        hour: 11,
        minute: 35,
        second: 44
    )))
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "Yes — that earlier response listed the longs and short exactly as requested.",
            resolution: PMConversationResolutionState(
                intentClass: .general,
                disposition: .conversationOnly
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Suppresses stale recap messages when an exact earlier PM response is requested.",
            createdAt: now,
            updatedAt: now
        )
    )

    let earlierSession = PMCommunicationSession(
        sessionId: "session-specific-entry-suppress-earlier",
        channel: .inApp,
        pmId: "pm-1",
        participantId: "owner",
        participantDisplayName: "Owner",
        status: .closed,
        createdAt: earlierOwnerSentAt,
        updatedAt: earlierPMSentAt
    )
    _ = try await sessionStore.upsert(earlierSession)
    _ = try await messageStore.upsert(
        PMCommunicationMessage(
            messageId: "specific-entry-suppress-owner",
            sessionId: earlierSession.sessionId,
            direction: .incoming,
            senderRole: .owner,
            senderId: "owner",
            body: "Please formalize the proposed paper portfolio exactly as discussed.",
            sentAt: earlierOwnerSentAt,
            createdAt: earlierOwnerSentAt,
            updatedAt: earlierOwnerSentAt
        )
    )
    _ = try await messageStore.upsert(
        PMCommunicationMessage(
            messageId: "specific-entry-suppress-pm",
            sessionId: earlierSession.sessionId,
            direction: .outgoing,
            senderRole: .pm,
            senderId: "pm-1",
            body: "Long sleeve: NVDA, TSM, AVGO, AMZN, CRWD, NFLX, GOOG, AAPL, and TSLA. Short side: NYCB.",
            sentAt: earlierPMSentAt,
            replyToMessageId: "specific-entry-suppress-owner",
            createdAt: earlierPMSentAt,
            updatedAt: earlierPMSentAt
        )
    )

    let currentSession = try await sessionStore.upsert(
        PMCommunicationSession(
            sessionId: "session-specific-entry-suppress-current",
            channel: .inApp,
            pmId: "pm-1",
            participantId: "owner",
            participantDisplayName: "Owner",
            status: .active,
            createdAt: now.addingTimeInterval(-(20 * 60)),
            updatedAt: now.addingTimeInterval(-(20 * 60))
        )
    )
    _ = try await messageStore.upsert(
        PMCommunicationMessage(
            messageId: "specific-entry-suppress-recap",
            sessionId: currentSession.sessionId,
            direction: .outgoing,
            senderRole: .pm,
            senderId: "pm-1",
            body: "From our recent conversation, the latest proposed initial paper portfolio is a structure centered on NYCB, NVDA, TSM, AVGO, AMZN, CRWD, NFLX, and GOOG.",
            sentAt: now.addingTimeInterval(-(5 * 60)),
            createdAt: now.addingTimeInterval(-(5 * 60)),
            updatedAt: now.addingTimeInterval(-(5 * 60))
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: currentSession.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "I think the actual list is in your response to me on April 12, 11:35:44. Can you pull that proposed paper portfolio list of long / short positions?",
        source: .ui
    )
    _ = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)
    let request = try #require(await synthesisProvider.lastConversationRequest)

    #expect(request.detailedCommunicationHistorySummary.first?.hasPrefix("Specific communication entry body window: ") == true)
    #expect(request.recentConversationSummary.contains(where: { $0.contains("specific-entry-suppress-recap") }) == false)
    #expect(request.recentConversationSummary.contains(where: {
        $0.contains("structure centered on NYCB, NVDA, TSM, AVGO, AMZN, CRWD, NFLX, and GOOG")
    }) == false)
}

@Test("Runtime-failure fallback replies are minimal and do not reconstruct working portfolios")
func fallbackWorkingPortfolioRepliesStayNaturalAndDoNotLeakInternalScaffolding() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-working-portfolio-fallback")
    let now = Date(timeIntervalSince1970: 1_742_000_028)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let instructionStore = PMInstructionStore(instructionsDirectory: root.appendingPathComponent("instructions", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Answers naturally from the bounded working-definition path.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await instructionStore.upsert(
        PMInstruction(
            instructionId: "instruction-working-portfolio",
            pmId: "pm-1",
            title: "Working paper portfolio definition",
            body: "Initial paper portfolio: long MSFT, long NVDA, short NYCB, and keep a cash buffer until confirmed holdings are rebuilt from app truth.",
            category: "conversation_working_portfolio_definition",
            status: .active,
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmInstructionStore: instructionStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: false, value: nil)
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "I am hoping that we have fixed the ability for you to have the full conversation context and be able to reason through what to do based on our conversation. Please list the latest structure for the initial paper portfolio.",
        source: .ui
    )
    let reply = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)

    #expect(reply.body.contains("I couldn't complete a PM answer because the PM runtime failed:"))
    #expect(reply.body.contains("OpenAI credentials are unavailable for the PM runtime"))
    #expect(reply.body.contains("long MSFT") == false)
    #expect(reply.body.contains("short NYCB") == false)
    #expect(reply.body.contains("paper-portfolio working definition") == false)
    #expect(reply.body.contains("confirmed holdings") == false)
    #expect(reply.runtimeProvenance?.conversationTrace?.pathKind == .degradedFallback)
    #expect(reply.runtimeProvenance?.conversationTrace?.visibleReplySource == .deterministicFallback)
    #expect(reply.runtimeProvenance?.conversationTrace?.fallbackTrigger == .credentialUnavailable)
    #expect(reply.runtimeProvenance?.conversationTrace?.fallbackTriggerWasAllowedRuntimeFailure == true)
    #expect(reply.runtimeProvenance?.conversationTrace?.visibleReplyModifiedAfterSynthesis == false)
    #expect(reply.body.contains("Relevant prior PM context I recovered") == false)
    #expect(reply.body.contains("Standing-review memory") == false)
    #expect(reply.body.contains("Supporting detail:") == false)
    #expect(reply.conversationResolution == nil)
    #expect(reply.conversationActionPlan == nil)
}

@Test("Recent user working-portfolio corrections become the latest conversation truth without a separate apply step")
func recentWorkingPortfolioCorrectionsBecomeLatestConversationTruthWithoutApply() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-working-portfolio-conversation-truth")
    let now = Date(timeIntervalSince1970: 1_742_000_028.5)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Carries forward the latest conversation-defined paper portfolio naturally.",
            createdAt: now,
            updatedAt: now
        )
    )
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutputs: [
            PMConversationOpenAISynthesisOutput(
                replyBody: "Understood. I’m carrying forward the latest conversation-defined paper portfolio with ACN and MSFT as the core longs and a cash buffer as working context.",
                actionPlan: PMConversationActionPlan(
                    summary: "Carry the owner's initial paper portfolio definition as working conversation truth.",
                    actions: [
                        PMConversationActionIntent(
                            actionType: .updateConversationWorkingTruth,
                            summary: "Current paper portfolio is ACN and MSFT long with a cash buffer.",
                            body: "Long positions: ACN, MSFT. Keep a cash buffer.",
                            operatingTruthKind: .workingPortfolioDefinition,
                            sourceMessageIds: []
                        )
                    ]
                ),
                resolution: PMConversationResolutionState(
                    intentClass: .general,
                    disposition: .workingUnderstandingOnly,
                    operatingTruthKind: .workingPortfolioDefinition,
                    operatingTruthSummary: "Current paper portfolio is ACN and MSFT long with a cash buffer.",
                    operatingTruthBody: "Long positions: ACN, MSFT. Keep a cash buffer."
                )
            ),
            PMConversationOpenAISynthesisOutput(
                replyBody: "Understood. I’m carrying forward the latest conversation-defined paper portfolio with NYCB replacing ACN while keeping MSFT in place.",
                actionPlan: PMConversationActionPlan(
                    summary: "Update the conversation-owned working paper portfolio to reflect the owner's correction.",
                    actions: [
                        PMConversationActionIntent(
                            actionType: .updateConversationWorkingTruth,
                            summary: "Current paper portfolio is NYCB and MSFT with a cash buffer.",
                            body: "Long positions: NYCB, MSFT. Keep a cash buffer.",
                            operatingTruthKind: .workingPortfolioDefinition,
                            sourceMessageIds: []
                        )
                    ]
                ),
                resolution: PMConversationResolutionState(
                    intentClass: .correction,
                    disposition: .workingUnderstandingOnly,
                    operatingTruthKind: .workingPortfolioDefinition,
                    operatingTruthSummary: "Current paper portfolio is NYCB and MSFT with a cash buffer.",
                    operatingTruthBody: "Long positions: NYCB, MSFT. Keep a cash buffer."
                )
            ),
            PMConversationOpenAISynthesisOutput(
                replyBody: "The latest proposed paper portfolio is NYCB and MSFT with a cash buffer.",
                resolution: PMConversationResolutionState(
                    intentClass: .followUpQuestion,
                    disposition: .conversationOnly
                )
            )
        ],
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let initialAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "For the initial paper portfolio, keep ACN and MSFT as the core longs and keep a cash buffer.",
        source: .ui
    )
    _ = try await engine.generatePMConversationReply(to: initialAsk.messageId, source: .ui)

    let correctionAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Correction: replace ACN with NYCB in that working paper portfolio and keep MSFT.",
        source: .ui
    )
    let correctionReply = try await engine.generatePMConversationReply(to: correctionAsk.messageId, source: .ui)

    let recapAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Please list the latest structure for the initial paper portfolio.",
        source: .ui
    )
    let recapReply = try await engine.generatePMConversationReply(to: recapAsk.messageId, source: .ui)

    #expect(correctionReply.body.contains("carrying forward the latest conversation-defined paper portfolio"))
    #expect(correctionReply.body.contains("NYCB"))
    #expect(correctionReply.conversationResolution?.operatingTruthKind == .workingPortfolioDefinition)
    #expect(correctionReply.conversationResolution?.operatingTruthBody?.contains("NYCB") == true)
    #expect(correctionReply.conversationResolution?.operatingTruthBody?.contains("MSFT") == true)
    #expect(recapReply.body.contains("latest proposed paper portfolio"))
    #expect(recapReply.body.contains("NYCB"))
    #expect(recapReply.body.contains("MSFT"))
    #expect(recapReply.body.contains("bounded working-definition path") == false)
}

@Test("Latest owner-supplied paper portfolio update reaches model as raw owner message without deterministic grounding")
func latestOwnerSuppliedPaperPortfolioUpdateReachesModelWithoutDeterministicGrounding() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-last-turn-dominates-model-context")
    let now = Date(timeIntervalSince1970: 1_744_000_100)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "Given your latest proposed paper portfolio, I would keep NYCB as the defined short and focus new discussion on additions rather than rewriting the list you just supplied.",
            resolution: PMConversationResolutionState(
                intentClass: .followUpQuestion,
                disposition: .workingUnderstandingOnly
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Uses the latest owner-supplied portfolio list as the active working truth for the next reply.",
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    _ = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .pm,
        senderId: "pm-1",
        body: "From our recent conversation, the latest proposed initial paper portfolio is a structure centered on the names referenced most directly being NYCB, NVDA, TSM, AVGO, AMZN, CRWD, NFLX, and GOOG, the previously discussed short leg dropped from the latest version.",
        source: .ui
    )

    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: """
        Here is the current proposed paper portfolio.

        Long positions: NVDA, TSM, AVGO, AMZN, CRWD, NFLX, GOOG, AAPL, TSLA
        Short positions: NYCB

        There was a big recovery in the market this week, and so from your review of the recent analysts reports were there any high conviction suggestions for long and short positions that we should be discussing?
        """,
        source: .ui
    )
    _ = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)
    let request = try #require(await synthesisProvider.lastConversationRequest)

    #expect(request.plannerMode == "owner_conversation_action_planning")
    #expect(request.latestOwnerWorkingPortfolioUpdateSummary.isEmpty)
    #expect(request.ownerMessageBody.contains("NVDA"))
    #expect(request.ownerMessageBody.contains("AAPL"))
    #expect(request.ownerMessageBody.contains("TSLA"))
    #expect(request.ownerMessageBody.contains("NYCB"))
    #expect(request.proposedTruthUpdateSummary.isEmpty)
    #expect(request.recoveredContextSummary.contains(where: {
        $0.contains("the previously discussed short leg dropped from the latest version")
    }) == false)
    #expect(request.recentConversationSummary.contains(where: {
        $0.contains("the previously discussed short leg dropped from the latest version")
    }) == false)
}

@Test("Model-backed PM conversation replies are not rewritten by deterministic working-portfolio routing")
func modelBackedConversationRepliesAreNotRewrittenByDeterministicWorkingPortfolioRouting() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-model-interpretation-preserved")
    let now = Date(timeIntervalSince1970: 1_744_000_150)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "For the short side, I would keep NYCB as the active short in your proposed list and frame ETSY and KSS as candidate hedges worth pressure-testing rather than rewriting the portfolio you just supplied.",
            resolution: PMConversationResolutionState(
                intentClass: .followUpQuestion,
                disposition: .conversationOnly
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Keeps model-backed PM interpretation intact instead of re-routing it through deterministic portfolio inference.",
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: """
        Here is the current proposed paper portfolio.

        Long positions: NVDA, TSM, AVGO, AMZN, CRWD, NFLX, GOOG, AAPL, TSLA
        Short positions: NYCB

        On the short position side what is the analyst conviction level and reasoning for NYCB, ETSY, and KSS?
        """,
        source: .ui
    )
    let reply = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)
    let request = try #require(await synthesisProvider.lastConversationRequest)
    let actionPlan = try #require(reply.conversationActionPlan)

    #expect(request.latestOwnerWorkingPortfolioUpdateSummary.isEmpty)
    #expect(request.ownerMessageBody.contains("AAPL"))
    #expect(request.ownerMessageBody.contains("TSLA"))
    #expect(request.ownerMessageBody.contains("NYCB"))
    #expect(reply.body.contains("ETSY"))
    #expect(reply.body.contains("KSS"))
    #expect(reply.conversationResolution?.disposition == .conversationOnly)
    #expect(reply.conversationResolution?.operatingTruthBody == nil)
    #expect(actionPlan.actions.count == 1)
    #expect(actionPlan.actions.first?.actionType == .answerOnly)
}

@Test("Compound-turn working truth carries into the next model-backed follow-up without a separate apply step")
func compoundTurnWorkingTruthCarriesIntoNextModelBackedFollowUpWithoutSeparateApplyStep() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-compound-turn-carry-through")
    let now = Date(timeIntervalSince1970: 1_744_000_175)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutputs: [
            PMConversationOpenAISynthesisOutput(
                replyBody: "Under your latest update, I’m treating NVDA, TSM, AVGO, AMZN, CRWD, NFLX, GOOG, AAPL, and TSLA long with NYCB short as the current working paper portfolio. From the recent analyst work, COST and BKNG are the cleaner long discussion names while ETSY and KSS are still the more relevant short-side candidates.",
                actionPlan: PMConversationActionPlan(
                    summary: "Carry the owner's proposed paper portfolio forward as the current conversation-owned working definition.",
                    actions: [
                        PMConversationActionIntent(
                            actionType: .updateConversationWorkingTruth,
                            summary: "Current proposed paper portfolio is long NVDA, TSM, AVGO, AMZN, CRWD, NFLX, GOOG, AAPL, and TSLA with NYCB as the short.",
                            body: "Long positions: NVDA, TSM, AVGO, AMZN, CRWD, NFLX, GOOG, AAPL, and TSLA. Short positions: NYCB.",
                            operatingTruthKind: .workingPortfolioDefinition,
                            sourceMessageIds: []
                        )
                    ]
                ),
                resolution: PMConversationResolutionState(
                    intentClass: .followUpQuestion,
                    disposition: .workingUnderstandingOnly,
                    workingUnderstandingSummary: "Use the owner's proposed long and short list as the current working paper portfolio for this thread.",
                    operatingTruthKind: .workingPortfolioDefinition,
                    operatingTruthSummary: "Current proposed paper portfolio is long NVDA, TSM, AVGO, AMZN, CRWD, NFLX, GOOG, AAPL, and TSLA with NYCB as the short.",
                    operatingTruthBody: "Long positions: NVDA, TSM, AVGO, AMZN, CRWD, NFLX, GOOG, AAPL, and TSLA. Short positions: NYCB."
                )
            ),
            PMConversationOpenAISynthesisOutput(
                replyBody: "On the short side, NYCB remains the active short in your proposed portfolio. ETSY is the cleaner consumer-demand hedge candidate from the recent analyst work, while KSS reads as lower-conviction and more balance-sheet sensitive.",
                resolution: PMConversationResolutionState(
                    intentClass: .followUpQuestion,
                    disposition: .conversationOnly
                )
            )
        ],
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Carries forward conversation-owned working portfolio truth across adjacent model-backed PM turns.",
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let compoundTurn = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: """
        Here is my current proposed paper portfolio.

        Long positions: NVDA, TSM, AVGO, AMZN, CRWD, NFLX, GOOG, AAPL, TSLA
        Short positions: NYCB

        There was a big recovery in the market this week, and so from your review of the recent analyst reports were there any high-conviction suggestions for long and short positions that we should be discussing?
        """,
        source: .ui
    )
    let firstReply = try await engine.generatePMConversationReply(to: compoundTurn.messageId, source: .ui)

    let followUp = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "On the short position side what is the analyst conviction level and reasoning for each of NYCB, ETSY and KSS?",
        source: .ui
    )
    let secondReply = try await engine.generatePMConversationReply(to: followUp.messageId, source: .ui)
    let requests = await synthesisProvider.conversationRequests
    let secondRequest = try #require(requests.last)

    #expect(firstReply.body.contains("COST"))
    #expect(firstReply.body.contains("ETSY"))
    #expect(firstReply.body.contains("actionPlan") == false)
    #expect(secondReply.body.contains("NYCB"))
    #expect(secondReply.body.contains("ETSY"))
    #expect(secondReply.body.contains("KSS"))
    #expect(secondReply.body.contains("latest proposed initial paper portfolio") == false)
    #expect(secondReply.body.contains("structure centered on") == false)
    #expect(secondRequest.latestOwnerWorkingPortfolioUpdateSummary.isEmpty)
    #expect(secondRequest.workingPortfolioDefinitionSummary.contains(where: {
        $0.contains("AAPL") && $0.contains("TSLA") && $0.contains("NYCB")
    }))
    #expect(secondRequest.ownerMessageBody.contains("analyst conviction level"))
}

@Test("LLM-selected grounding receives recent analyst artifacts for a working-truth follow-up even when the owner says these positions")
func llmSelectedGroundingReceivesRecentAnalystArtifactsForWorkingTruthFollowUp() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-llm-selected-analyst-grounding")
    let now = Date(timeIntervalSince1970: 1_744_000_190)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let standingReportStore = AnalystStandingReportStore(reportsDirectory: root.appendingPathComponent("standing_reports", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutputs: [
            PMConversationOpenAISynthesisOutput(
                replyBody: "Under your latest update, I’m carrying the proposed paper portfolio forward as the current working definition. From the recent analyst work, the clearer short-side follow-up names remain NYCB and KSS.",
                actionPlan: PMConversationActionPlan(
                    summary: "Carry the latest owner-defined paper portfolio forward as conversation-owned working truth.",
                    actions: [
                        PMConversationActionIntent(
                            actionType: .updateConversationWorkingTruth,
                            summary: "Current proposed paper portfolio is long NVDA, TSM, AVGO, AMZN, CRWD, NFLX, GOOG, AAPL, and TSLA with NYCB and KSS short.",
                            body: "Long positions: NVDA, TSM, AVGO, AMZN, CRWD, NFLX, GOOG, AAPL, TSLA. Short positions: NYCB, KSS.",
                            operatingTruthKind: .workingPortfolioDefinition,
                            sourceMessageIds: []
                        )
                    ]
                ),
                resolution: PMConversationResolutionState(
                    intentClass: .followUpQuestion,
                    disposition: .workingUnderstandingOnly,
                    workingUnderstandingSummary: "Use the owner-defined paper portfolio as the current working portfolio for this thread.",
                    operatingTruthKind: .workingPortfolioDefinition,
                    operatingTruthSummary: "Current proposed paper portfolio is long NVDA, TSM, AVGO, AMZN, CRWD, NFLX, GOOG, AAPL, and TSLA with NYCB and KSS short.",
                    operatingTruthBody: "Long positions: NVDA, TSM, AVGO, AMZN, CRWD, NFLX, GOOG, AAPL, TSLA. Short positions: NYCB, KSS."
                )
            ),
            PMConversationOpenAISynthesisOutput(
                replyBody: "For the current short sleeve, NYCB has the stronger direct analyst short case, while KSS reads as a lower-conviction pressure test. I do not have a cleaner fresh analyst read beyond that for this turn.",
                resolution: PMConversationResolutionState(
                    intentClass: .followUpQuestion,
                    disposition: .conversationOnly
                )
            )
        ],
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Chooses grounding from the latest follow-up and current working truth rather than from a detector carve-out.",
            createdAt: now,
            updatedAt: now
        )
    )

    let financialsReport = AnalystStandingReport(
        reportId: "standing-report-nycb-short",
        analystId: "bench-sector-financials-analyst",
        charterId: "bench-sector-financials",
        scheduleId: "standing-report-bench-sector-financials",
        memoId: "memo-standing-report-nycb-short",
        title: "Financials Analyst Standing Report",
        summary: "Regional-bank stress still supports the short book pressure test.",
        cadenceIntervalSec: 12 * 3_600,
        reportingWindowSummary: "Past 12 hours",
        portfolioScopeSummary: "Financials coverage",
        headlineView: "Regional-bank stress still matters for current shorts.",
        portfolioRelevanceSummary: "Short candidates remain more relevant than new longs in the current bank setup.",
        sections: [
            AnalystStandingReportSection(
                sectionId: "financials-short-ideas",
                kind: .shortIdeas,
                items: [
                    AnalystStandingReportItem(
                        itemId: "nycb-short",
                        headline: "NYCB remains the cleaner direct short expression.",
                        detail: "Funding pressure and lingering balance-sheet skepticism still make NYCB the clearer downside case after the bounce.",
                        symbol: "NYCB",
                        stance: .short,
                        conviction: 8
                    )
                ]
            )
        ],
        deliveredToPMInboxAt: now,
        createdAt: now,
        updatedAt: now
    )
    let consumerReport = AnalystStandingReport(
        reportId: "standing-report-kss-short",
        analystId: "bench-sector-consumer-analyst",
        charterId: "bench-sector-consumer",
        scheduleId: "standing-report-bench-sector-consumer",
        memoId: "memo-standing-report-kss-short",
        title: "Consumer Analyst Standing Report",
        summary: "Department-store pressure remains a secondary short sleeve topic.",
        cadenceIntervalSec: 12 * 3_600,
        reportingWindowSummary: "Past 12 hours",
        portfolioScopeSummary: "Consumer coverage",
        headlineView: "Department-store softness is still a lower-conviction short theme.",
        portfolioRelevanceSummary: "The cleaner consumer short remains selective rather than broad-based.",
        sections: [
            AnalystStandingReportSection(
                sectionId: "consumer-short-ideas",
                kind: .shortIdeas,
                items: [
                    AnalystStandingReportItem(
                        itemId: "kss-short",
                        headline: "KSS remains a lower-conviction short pressure test.",
                        detail: "Traffic and margin pressure keep KSS on the board, but the case is less direct and less urgent than NYCB.",
                        symbol: "KSS",
                        stance: .short,
                        conviction: 5
                    )
                ]
            )
        ],
        deliveredToPMInboxAt: now.addingTimeInterval(-60),
        createdAt: now.addingTimeInterval(-60),
        updatedAt: now.addingTimeInterval(-60)
    )
    _ = try await standingReportStore.upsert(financialsReport)
    _ = try await standingReportStore.upsert(consumerReport)

    let engine = Engine(
        pmProfileStore: profileStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        analystStandingReportStore: standingReportStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let compoundTurn = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: """
        Here is my current proposed paper portfolio.

        Long positions: NVDA, TSM, AVGO, AMZN, CRWD, NFLX, GOOG, AAPL, TSLA
        Short positions: NYCB, KSS

        Based on the recent analyst work, are there any follow-up names we should still be discussing?
        """,
        source: .ui
    )
    _ = try await engine.generatePMConversationReply(to: compoundTurn.messageId, source: .ui)

    let followUp = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Re the proposed short positions for the paper portfolio. For the analyst covering these positions what are their conviction levels and reasoning?",
        source: .ui
    )
    let reply = try await engine.generatePMConversationReply(to: followUp.messageId, source: .ui)
    let request = try #require(await synthesisProvider.lastConversationRequest)

    #expect(request.ownerMessageBody.contains("these positions"))
    #expect(request.workingPortfolioDefinitionSummary.contains(where: {
        $0.contains("NYCB") && $0.contains("KSS")
    }))
    #expect(request.analystArtifactSummary.contains(where: {
        $0.contains("Financials Analyst") && $0.contains("NYCB") && $0.contains("conviction 8/10")
    }))
    #expect(request.analystArtifactSummary.contains(where: {
        $0.contains("Consumer Analyst") && $0.contains("KSS") && $0.contains("conviction 5/10")
    }))
    #expect(reply.body.contains("NYCB"))
    #expect(reply.body.contains("KSS"))
    #expect(reply.body.contains("latest proposed initial paper portfolio") == false)
}

@Test("PM conversation retrieves PM Inbox standing report detail sections when owner references them")
func pmConversationRetrievesPMInboxStandingReportDetailSectionsWhenOwnerReferencesThem() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-report-detail-retrieval")
    let now = Date(timeIntervalSince1970: 1_746_000_195)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let standingReportStore = AnalystStandingReportStore(reportsDirectory: root.appendingPathComponent("standing_reports", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "Yes. The summary view is not the whole report; the detailed Technology Analyst section includes short candidates.",
            resolution: PMConversationResolutionState(
                intentClass: .followUpQuestion,
                disposition: .conversationOnly
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Run the owner-facing PM desk.",
            createdAt: now,
            updatedAt: now
        )
    )
    let technologyReport = AnalystStandingReport(
        reportId: "standing-report-technology-latest",
        analystId: "bench-sector-technology-analyst",
        charterId: "bench-sector-technology",
        scheduleId: "standing-report-bench-sector-technology",
        memoId: "memo-technology-latest",
        title: "Technology Analyst Standing Report",
        summary: "The visible summary emphasizes long-side refreshes and does not enumerate detailed short candidates.",
        cadenceIntervalSec: 86_400,
        reportingWindowSummary: "Latest Technology Analyst daily report.",
        portfolioScopeSummary: "Technology sector standing coverage.",
        coveredSymbols: ["AAPL", "AMZN", "AVGO", "CRWD"],
        headlineView: "Long-oriented technology refresh.",
        portfolioRelevanceSummary: "The report includes detailed support sections beneath the summary.",
        sections: [
            AnalystStandingReportSection(
                sectionId: "technology-long-ideas",
                kind: .longIdeas,
                items: [
                    AnalystStandingReportItem(
                        itemId: "aapl-long",
                        headline: "AAPL remains a long-side quality candidate.",
                        detail: "The long-side summary is visible in the compact report view.",
                        symbol: "AAPL",
                        stance: .long,
                        conviction: 6
                    )
                ]
            ),
            AnalystStandingReportSection(
                sectionId: "technology-short-ideas",
                kind: .shortIdeas,
                summary: "Best current short-side pressure-test candidates in technology.",
                items: [
                    AnalystStandingReportItem(
                        itemId: "snow-short",
                        headline: "SNOW is a premium-valuation short candidate.",
                        detail: "SNOW belongs on the short side when premium valuation and execution sensitivity look mismatched to current construction.",
                        symbol: "SNOW",
                        stance: .short,
                        conviction: 7
                    ),
                    AnalystStandingReportItem(
                        itemId: "unity-short",
                        headline: "Unity is a short-side pressure test.",
                        detail: "Unity is a useful short-side pressure test because the report details operational uncertainty and weak execution visibility.",
                        symbol: "U",
                        stance: .short,
                        conviction: 6
                    ),
                    AnalystStandingReportItem(
                        itemId: "intc-short",
                        headline: "INTC remains a bounded short candidate.",
                        detail: "INTC is a bounded short-side pressure test while turnaround timing and capital intensity remain contested.",
                        symbol: "INTC",
                        stance: .short,
                        conviction: 5
                    )
                ]
            )
        ],
        deliveredToPMInboxAt: now,
        createdAt: now,
        updatedAt: now
    )
    _ = try await standingReportStore.upsert(technologyReport)

    let engine = Engine(
        pmProfileStore: profileStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        analystStandingReportStore: standingReportStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerMessage = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "I see short positions when I open the detailed supporting section. For example the latest Technology Analyst report lists Best Short Candidates as SNOW, Unity and INTC. Can you see that?",
        source: .ui
    )

    let reply = try await engine.generatePMConversationReply(to: ownerMessage.messageId, source: .ui)
    let request = try #require(await synthesisProvider.lastConversationRequest)

    #expect(reply.runtimeProvenance?.conversationTrace?.pathKind == .modelBacked)
    #expect(reply.runtimeProvenance?.conversationTrace?.usedAnalystArtifactGrounding == true)
    #expect(request.analystArtifactSummary.contains(where: {
        $0.contains("FULL_ANALYST_REPORT_DOCUMENTS") && $0.contains("Best Short Candidates")
    }))
    #expect(request.analystArtifactSummary.contains(where: {
        $0.contains("SNOW") && $0.contains("Unity") && $0.contains("INTC")
    }))
    #expect(request.analystArtifactSummary.contains(where: {
        $0.contains("AnalystStandingReport.sections[].items[].detail")
    }))
    #expect(reply.body.contains("detailed Technology Analyst section"))
}

@Test("PM conversation retrieves bounded full detail across every sector analyst lane for broad short-candidate asks")
func pmConversationRetrievesBoundedFullDetailAcrossSectorAnalystLanes() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-sector-full-detail")
    let now = Date(timeIntervalSince1970: 1_746_000_198)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let standingReportStore = AnalystStandingReportStore(reportsDirectory: root.appendingPathComponent("standing_reports", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "Yes. The detailed report sections include bounded short-candidate sections across the sector analyst lanes.",
            resolution: PMConversationResolutionState(
                intentClass: .followUpQuestion,
                disposition: .conversationOnly
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Run the owner-facing PM desk.",
            createdAt: now,
            updatedAt: now
        )
    )
    let sectorDefinitions = StandingAnalystBenchSeed.definitions.filter { $0.benchRole == .sector }
    for (index, definition) in sectorDefinitions.enumerated() {
        _ = try await standingReportStore.upsert(
            AnalystStandingReport(
                reportId: "standing-report-\(definition.charterId)-short-detail",
                deliveryStatus: .reviewedByPM,
                analystId: definition.analystId,
                charterId: definition.charterId,
                scheduleId: "standing-report-\(definition.charterId)",
                memoId: "memo-\(definition.charterId)-short-detail",
                title: "\(definition.title) Standing Report",
                summary: "\(definition.title) compact summary.",
                cadenceIntervalSec: standingAnalystReportDefaultIntervalSec,
                reportingWindowSummary: "\(definition.title) latest window.",
                portfolioScopeSummary: definition.coverageScope,
                coveredSymbols: ["SHORT\(index)"],
                headlineView: "\(definition.title) latest reviewed signal.",
                portfolioRelevanceSummary: "The detail section, not the compact summary, carries the short-candidate evidence.",
                sections: [
                    AnalystStandingReportSection(
                        sectionId: "\(definition.charterId)-shorts",
                        kind: .shortIdeas,
                        summary: "\(definition.title) best short candidates.",
                        items: [
                            AnalystStandingReportItem(
                                itemId: "\(definition.charterId)-short-candidate",
                                headline: "\(definition.title) short candidate SHORT\(index).",
                                detail: "\(definition.title) includes a bounded short-side pressure-test candidate in the analyst-created report source.",
                                symbol: "SHORT\(index)",
                                stance: .short,
                                conviction: 6
                            )
                        ]
                    )
                ],
                deliveredToPMInboxAt: now.addingTimeInterval(Double(index)),
                createdAt: now.addingTimeInterval(Double(index)),
                updatedAt: now.addingTimeInterval(Double(index))
            )
        )
    }

    let engine = Engine(
        pmProfileStore: profileStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        analystStandingReportStore: standingReportStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerMessage = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Are each of the sector analysts including potential short positions in their reports?",
        source: .ui
    )

    _ = try await engine.generatePMConversationReply(to: ownerMessage.messageId, source: .ui)
    let request = try #require(await synthesisProvider.lastConversationRequest)
    let artifactGrounding = request.analystArtifactSummary.joined(separator: "\n")
    let renderedPrompt = makePMConversationPromptText(from: request)

    #expect(artifactGrounding.contains("Cross-sector analyst full-report retrieval"))
    #expect(request.analystArtifactSummary.count <= 28)
    for definition in sectorDefinitions {
        #expect(artifactGrounding.contains(definition.title))
    }
    #expect(request.analystArtifactSummary.filter { $0.contains("FULL_ANALYST_REPORT_DOCUMENTS") }.count >= sectorDefinitions.count)
    #expect(renderedPrompt.contains("Best Short Candidates"))
    #expect(renderedPrompt.contains("full analyst report") || renderedPrompt.contains("analyst-created report source"))
    #expect(renderedPrompt.contains("SHORT0"))
    #expect(renderedPrompt.contains("SHORT5"))
}

@Test("PM conversation provides open analyst lane index for model-backed lane reasoning")
func pmConversationProvidesOpenAnalystLaneIndexForModelBackedLaneReasoning() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-analyst-lane-index")
    let now = Date(timeIntervalSince1970: 1_746_000_205)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let standingReportStore = AnalystStandingReportStore(reportsDirectory: root.appendingPathComponent("standing_reports", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "The last reviewed Recent News Analyst report was the May 1 material-news review.",
            resolution: PMConversationResolutionState(
                intentClass: .followUpQuestion,
                disposition: .conversationOnly
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Run the owner-facing PM desk.",
            createdAt: now,
            updatedAt: now
        )
    )
    let recentNewsReport = AnalystStandingReport(
        reportId: "standing-report-recent-news-reviewed",
        deliveryStatus: .reviewedByPM,
        analystId: "recent-news-material-impact-analyst",
        charterId: recentNewsStandingAnalystCharterID,
        scheduleId: "standing-report-recent-news-material-impact-analyst",
        memoId: "memo-recent-news-reviewed",
        title: "Recent News Analyst Standing Report",
        summary: "PM reviewed the latest Recent News Analyst report and kept the findings monitor-only.",
        cadenceIntervalSec: standingAnalystReportDefaultIntervalSec,
        reportingWindowSummary: "Recent news review through May 1.",
        portfolioScopeSummary: "Current holdings and watchlist recent-news coverage.",
        coveredSymbols: ["NVDA", "AAPL"],
        headlineView: "No material portfolio-impact headline displaced current monitoring.",
        portfolioRelevanceSummary: "Recent-news scan found no immediate owner-actionable change.",
        sections: [
            AnalystStandingReportSection(
                sectionId: "recent-news-material-developments",
                kind: .materialDevelopments,
                summary: "No material headline required an owner-facing action.",
                items: [
                    AnalystStandingReportItem(
                        itemId: "recent-news-nvda",
                        headline: "NVDA news remained monitor-only after PM review.",
                        detail: "The app-owned Recent News Analyst treated the NVDA item as watchlist context rather than a proposal trigger.",
                        symbol: "NVDA"
                    )
                ]
            )
        ],
        deliveredToPMInboxAt: now.addingTimeInterval(-2_000),
        createdAt: now.addingTimeInterval(-2_000),
        updatedAt: now.addingTimeInterval(-1_900)
    )
    let newerConsumerReport = AnalystStandingReport(
        reportId: "standing-report-consumer-newer",
        deliveryStatus: .reviewedByPM,
        analystId: "bench-sector-consumer-analyst",
        charterId: "bench-sector-consumer",
        scheduleId: "standing-report-bench-sector-consumer",
        memoId: "memo-consumer-newer",
        title: "Consumer Analyst Standing Report",
        summary: "A newer Consumer Analyst report that must not answer a Recent News Analyst query.",
        cadenceIntervalSec: standingAnalystReportDefaultIntervalSec,
        reportingWindowSummary: "Consumer weekly review.",
        portfolioScopeSummary: "Consumer sector coverage.",
        coveredSymbols: ["AMZN"],
        headlineView: "Consumer report is newer but unrelated to Recent News Analyst.",
        portfolioRelevanceSummary: "Consumer-sector context only.",
        sections: [
            AnalystStandingReportSection(
                sectionId: "consumer-items",
                kind: .importantItems,
                summary: "Consumer items were reviewed by PM.",
                items: [
                    AnalystStandingReportItem(
                        itemId: "consumer-amzn",
                        headline: "AMZN consumer demand read-through.",
                        detail: "This belongs to the Consumer Analyst lane, not Recent News Analyst.",
                        symbol: "AMZN"
                    )
                ]
            )
        ],
        deliveredToPMInboxAt: now.addingTimeInterval(-900),
        createdAt: now.addingTimeInterval(-900),
        updatedAt: now.addingTimeInterval(-800)
    )
    let portfolioRiskReport = AnalystStandingReport(
        reportId: "standing-report-portfolio-risk-reviewed",
        deliveryStatus: .reviewedByPM,
        analystId: "bench-overlay-portfolio-risk-analyst",
        charterId: "bench-overlay-portfolio-risk",
        scheduleId: "standing-report-bench-overlay-portfolio-risk",
        memoId: "memo-portfolio-risk-reviewed",
        title: "Portfolio Risk Analyst Standing Report",
        summary: "Portfolio Risk Analyst report is available as its own lane.",
        cadenceIntervalSec: standingAnalystReportDefaultIntervalSec,
        reportingWindowSummary: "Risk weekly review.",
        portfolioScopeSummary: "Portfolio-wide risk coverage.",
        coveredSymbols: ["NVDA", "AAPL"],
        headlineView: "Risk lane remains available but is not the answer to Recent News.",
        portfolioRelevanceSummary: "Portfolio risk context only.",
        deliveredToPMInboxAt: now.addingTimeInterval(-1_200),
        createdAt: now.addingTimeInterval(-1_200),
        updatedAt: now.addingTimeInterval(-1_100)
    )
    _ = try await standingReportStore.upsert(recentNewsReport)
    _ = try await standingReportStore.upsert(newerConsumerReport)
    _ = try await standingReportStore.upsert(portfolioRiskReport)

    let engine = Engine(
        pmProfileStore: profileStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        analystStandingReportStore: standingReportStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerMessage = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "What was the last Recent News Analyst report you reviewed?",
        source: .ui
    )

    _ = try await engine.generatePMConversationReply(to: ownerMessage.messageId, source: .ui)
    let request = try #require(await synthesisProvider.lastConversationRequest)

    let laneIndex = request.analystArtifactSummary.joined(separator: "\n")
    #expect(laneIndex.contains("PM model must choose the relevant analyst lane"))
    #expect(laneIndex.contains("deterministic app code is not choosing"))
    #expect(laneIndex.contains("Recent News Analyst: latest reviewed"))
    #expect(laneIndex.contains(recentNewsReport.reportId))
    #expect(laneIndex.contains("Consumer Analyst: latest reviewed"))
    #expect(laneIndex.contains(newerConsumerReport.reportId))
    #expect(laneIndex.contains("Portfolio Risk Analyst: latest reviewed"))
    #expect(laneIndex.contains(portfolioRiskReport.reportId))
    let renderedPrompt = makePMConversationPromptText(from: request)
    #expect(renderedPrompt.contains("Recent News Analyst: latest reviewed"))
    #expect(renderedPrompt.contains("Portfolio Risk Analyst: latest reviewed"))
}

@Test("PM conversation first-turn latest-from Recent News prompts include full current report context")
func pmConversationLatestFromRecentNewsPromptsIncludeFullCurrentReportContext() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-recent-news-latest-from")
    let now = Date(timeIntervalSince1970: 1_777_980_000)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let standingReportStore = AnalystStandingReportStore(reportsDirectory: root.appendingPathComponent("standing_reports", isDirectory: true))
    let decisionStore = PMDecisionStore(decisionsDirectory: root.appendingPathComponent("decisions", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "The latest Recent News Analyst report is the current monitor-only AI/legal headline review.",
            resolution: PMConversationResolutionState(
                intentClass: .followUpQuestion,
                disposition: .conversationOnly
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Run the owner-facing PM desk.",
            createdAt: now,
            updatedAt: now
        )
    )
    let recentNewsReport = AnalystStandingReport(
        reportId: "standing-report-recent-news-latest-ai-legal",
        deliveryStatus: .reviewedByPM,
        analystId: recentNewsStandingAnalystID,
        charterId: recentNewsStandingAnalystCharterID,
        scheduleId: "standing-report-\(recentNewsStandingAnalystID)",
        memoId: "memo-recent-news-latest-ai-legal",
        title: "Recent News Analyst: AI/legal headlines confirmed, materiality limited",
        summary: "AI/legal headlines are confirmed, but the analyst kept the read monitor-only.",
        cadenceIntervalSec: standingAnalystReportDefaultIntervalSec,
        reportingWindowSummary: "One-hour recent-news window.",
        portfolioScopeSummary: "Current watchlist and paper-portfolio news sensitivity.",
        coveredSymbols: ["NVDA", "META"],
        headlineView: "OpenAI, Meta, Anthropic, NYT, and EEOC headlines remained monitor-only.",
        portfolioRelevanceSummary: "Materiality remains limited without source-level detail.",
        sections: [
            AnalystStandingReportSection(
                sectionId: "recent-news-material-support",
                kind: .materialDevelopments,
                summary: "AI/legal headline support.",
                items: [
                    AnalystStandingReportItem(
                        itemId: "recent-news-ai-legal",
                        headline: "AI/legal headlines were confirmed but not actionable.",
                        detail: "The latest Recent News Analyst report cites OpenAI, Meta, Anthropic, NYT, and EEOC legal/news items as monitoring context rather than a portfolio-changing signal.",
                        stance: .neutral
                    )
                ]
            )
        ],
        deliveredToPMInboxAt: now.addingTimeInterval(-60),
        createdAt: now.addingTimeInterval(-60),
        updatedAt: now
    )
    let newerConsumerReport = AnalystStandingReport(
        reportId: "standing-report-consumer-newer-than-latest-from",
        deliveryStatus: .reviewedByPM,
        analystId: "bench-sector-consumer-analyst",
        charterId: "bench-sector-consumer",
        scheduleId: "standing-report-bench-sector-consumer",
        memoId: "memo-consumer-newer-than-latest-from",
        title: "Consumer Analyst Standing Report",
        summary: "Newer Consumer report that must not answer Recent News.",
        cadenceIntervalSec: standingAnalystReportDefaultIntervalSec,
        reportingWindowSummary: "Consumer review.",
        portfolioScopeSummary: "Consumer sector coverage.",
        headlineView: "Consumer report is newer but unrelated to Recent News.",
        portfolioRelevanceSummary: "Consumer sector only.",
        deliveredToPMInboxAt: now.addingTimeInterval(30),
        createdAt: now.addingTimeInterval(30),
        updatedAt: now.addingTimeInterval(30)
    )
    _ = try await standingReportStore.upsert(recentNewsReport)
    _ = try await standingReportStore.upsert(newerConsumerReport)
    _ = try await decisionStore.upsert(
        PMDecisionRecord(
            decisionId: "pm-decision-recent-news-latest-ai-legal",
            pmId: "pm-1",
            title: "Standing review conclusion: Recent News Analyst",
            summary: "PM reviewed the latest Recent News Analyst report.",
            recommendedAction: "Keep the latest Recent News report monitor-only.",
            charterId: recentNewsStandingAnalystCharterID,
            primaryStandingReportId: recentNewsReport.reportId,
            standingReportIds: [recentNewsReport.reportId],
            standingReviewAnalystTitles: [recentNewsStandingAnalystTitle],
            standingReviewAttentionItems: ["AI/legal headlines confirmed but not actionable."],
            createdAt: now.addingTimeInterval(90),
            updatedAt: now.addingTimeInterval(90)
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmDecisionStore: decisionStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        analystStandingReportStore: standingReportStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )
    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let prompts = [
        "For provider-evaluation purposes, answer this as a standalone question from current app-owned truth. What is the latest from our Recent News Analyst?",
        "What is the latest from our recent news analyst?",
        "What did the recent news analyst say?"
    ]

    for prompt in prompts {
        let ownerMessage = try await engine.createPMCommunicationMessage(
            sessionId: session.sessionId,
            senderRole: .owner,
            senderId: "owner",
            body: prompt,
            source: .ui
        )
        _ = try await engine.generatePMConversationReply(to: ownerMessage.messageId, source: .ui)
        let request = try #require(await synthesisProvider.lastConversationRequest)
        let artifactGrounding = request.analystArtifactSummary.joined(separator: "\n")
        let renderedPrompt = makePMConversationPromptText(from: request)

        #expect(artifactGrounding.contains("Named analyst full-report retrieval"))
        #expect(artifactGrounding.contains("FULL_ANALYST_REPORT_DOCUMENT"))
        #expect(artifactGrounding.contains("Recent News Analyst"))
        #expect(artifactGrounding.contains(recentNewsReport.reportId))
        #expect(artifactGrounding.contains("AI/legal headlines were confirmed but not actionable"))
        #expect(artifactGrounding.contains("Analyst lane: Consumer Analyst") == false)
        #expect(renderedPrompt.contains("Recent News Analyst"))
        #expect(renderedPrompt.contains("AI/legal headlines were confirmed but not actionable"))
        #expect(request.recentConversationSummary.contains(where: {
            $0.contains("older Recent News Analyst report")
        }) == false)
    }
}

@Test("PM conversation open bench context includes Portfolio Risk full report before portfolio snapshot fallback")
func pmConversationOpenBenchContextIncludesPortfolioRiskFullReport() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-risk-analyst-latest-take")
    let now = Date(timeIntervalSince1970: 1_777_900_000)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let standingReportStore = AnalystStandingReportStore(reportsDirectory: root.appendingPathComponent("standing_reports", isDirectory: true))
    let decisionStore = PMDecisionStore(decisionsDirectory: root.appendingPathComponent("decisions", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "The latest Portfolio Risk Analyst report says concentration and AI-linked clustering remain the main paper-portfolio risks.",
            resolution: PMConversationResolutionState(
                intentClass: .followUpQuestion,
                disposition: .conversationOnly
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Run the owner-facing PM desk.",
            createdAt: now,
            updatedAt: now
        )
    )
    let report = AnalystStandingReport(
        reportId: "standing-report-portfolio-risk-latest-take",
        deliveryStatus: .reviewedByPM,
        analystId: "bench-overlay-portfolio-risk-analyst",
        charterId: "bench-overlay-portfolio-risk",
        scheduleId: "standing-report-bench-overlay-portfolio-risk",
        memoId: "memo-portfolio-risk-latest-take",
        title: "Portfolio Risk Analyst Standing Refresh",
        summary: "AI-linked earnings strength exists, but portfolio materiality remains unresolved.",
        cadenceIntervalSec: standingAnalystReportDefaultIntervalSec,
        reportingWindowSummary: "Paper-portfolio risk review.",
        portfolioScopeSummary: "Paper portfolio, current holdings, and watchlist risk posture.",
        coveredSymbols: ["NVDA", "AAPL", "MSFT"],
        headlineView: "Concentration and AI-linked clustering remain the main paper-portfolio risks.",
        portfolioRelevanceSummary: "The paper portfolio is still net-long and concentrated, with only a modest short hedge.",
        sections: [
            AnalystStandingReportSection(
                sectionId: "risk-posture",
                kind: .riskIssues,
                summary: "Paper portfolio risk posture.",
                items: [
                    AnalystStandingReportItem(
                        itemId: "risk-concentration",
                        headline: "Paper portfolio remains concentrated in AI-linked longs.",
                        detail: "The Portfolio Risk Analyst report identifies single-name and theme concentration as the dominant risk, with the short side too small to offset AI-linked long exposure.",
                        stance: .risk
                    ),
                    AnalystStandingReportItem(
                        itemId: "risk-fragility",
                        headline: "Portfolio materiality remains unresolved.",
                        detail: "The report says AI-linked earnings strength is visible, but the evidence does not yet resolve whether concentration risk should be reduced or only monitored.",
                        stance: .neutral
                    )
                ]
            )
        ],
        deliveredToPMInboxAt: now.addingTimeInterval(-60),
        createdAt: now.addingTimeInterval(-60),
        updatedAt: now
    )
    _ = try await standingReportStore.upsert(report)
    _ = try await decisionStore.upsert(
        PMDecisionRecord(
            decisionId: "pm-decision-portfolio-risk-latest-take",
            pmId: "pm-1",
            title: "Standing review conclusion: Portfolio Risk Analyst",
            summary: "PM reviewed the latest Portfolio Risk Analyst report.",
            recommendedAction: "Keep portfolio-risk treatment monitor-only unless concentration worsens.",
            charterId: "bench-overlay-portfolio-risk",
            primaryStandingReportId: report.reportId,
            standingReportIds: [report.reportId],
            standingReviewAnalystTitles: ["Portfolio Risk Analyst"],
            standingReviewAttentionItems: ["Concentration and AI-linked clustering remain the main paper-portfolio risks."],
            createdAt: now.addingTimeInterval(30),
            updatedAt: now.addingTimeInterval(30)
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmDecisionStore: decisionStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        analystStandingReportStore: standingReportStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerMessage = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "What is the latest take from our risk analyst regarding the paper portfolio?",
        source: .ui
    )

    _ = try await engine.generatePMConversationReply(to: ownerMessage.messageId, source: .ui)
    let request = try #require(await synthesisProvider.lastConversationRequest)
    let artifactGrounding = request.analystArtifactSummary.joined(separator: "\n")
    let renderedPrompt = makePMConversationPromptText(from: request)

    #expect(artifactGrounding.contains("Open standing analyst bench full-report context for PM reasoning"))
    #expect(artifactGrounding.contains("not deterministic app interpretation of the owner message"))
    let portfolioRiskContext = try #require(request.analystArtifactSummary.first(where: {
        $0.contains("FULL_ANALYST_REPORT_DOCUMENT") && $0.contains("Portfolio Risk Analyst")
    }))
    #expect(portfolioRiskContext.contains(report.reportId))
    #expect(portfolioRiskContext.contains("Paper portfolio remains concentrated in AI-linked longs"))
    #expect(portfolioRiskContext.contains("single-name and theme concentration"))
    #expect(portfolioRiskContext.contains("FULL_REPORT_PM_REVIEW_TREATMENT_METADATA"))
    #expect(renderedPrompt.contains("Portfolio Risk Analyst"))
    #expect(renderedPrompt.contains("Concentration and AI-linked clustering remain the main paper-portfolio risks"))
    #expect(renderedPrompt.contains("Open standing analyst bench full-report context for PM reasoning"))
}

@Test("PM conversation open bench context exposes full reports for every non-Recent-News standing analyst lane")
func pmConversationOpenBenchContextExposesFullReportsForEveryNonRecentNewsLane() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-all-lane-open-bench-context")
    let base = Date(timeIntervalSince1970: 1_777_901_000)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let standingReportStore = AnalystStandingReportStore(reportsDirectory: root.appendingPathComponent("standing_reports", isDirectory: true))
    let decisionStore = PMDecisionStore(decisionsDirectory: root.appendingPathComponent("decisions", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "The named analyst lane report is available in the app-owned full-report context.",
            resolution: PMConversationResolutionState(
                intentClass: .followUpQuestion,
                disposition: .conversationOnly
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Run the owner-facing PM desk.",
            createdAt: base,
            updatedAt: base
        )
    )

    let nonRecentNewsDefinitions = StandingAnalystBenchSeed.definitions
        .filter { $0.charterId != recentNewsStandingAnalystCharterID }
    for (index, definition) in nonRecentNewsDefinitions.enumerated() {
        let now = base.addingTimeInterval(Double(index * 100))
        let report = AnalystStandingReport(
            reportId: "standing-report-\(definition.charterId)-latest-take",
            deliveryStatus: .reviewedByPM,
            analystId: definition.analystId,
            charterId: definition.charterId,
            scheduleId: "standing-report-\(definition.charterId)",
            memoId: "memo-\(definition.charterId)-latest-take",
            title: "\(definition.title) Standing Refresh",
            summary: "\(definition.title) latest report summary.",
            cadenceIntervalSec: standingAnalystReportDefaultIntervalSec,
            reportingWindowSummary: "\(definition.title) latest review window.",
            portfolioScopeSummary: "\(definition.title) portfolio scope.",
            headlineView: "\(definition.title) latest material lane signal.",
            portfolioRelevanceSummary: "\(definition.title) relevance to paper portfolio.",
            sections: [
                AnalystStandingReportSection(
                    sectionId: "\(definition.charterId)-details",
                    kind: .materialDevelopments,
                    summary: "\(definition.title) detailed support.",
                    items: [
                        AnalystStandingReportItem(
                            itemId: "\(definition.charterId)-detail",
                            headline: "\(definition.title) full detail headline.",
                            detail: "\(definition.title) full report detail survives open bench retrieval for this lane.",
                            stance: .neutral
                        )
                    ]
                )
            ],
            deliveredToPMInboxAt: now.addingTimeInterval(-60),
            createdAt: now.addingTimeInterval(-60),
            updatedAt: now
        )
        _ = try await standingReportStore.upsert(report)
        _ = try await decisionStore.upsert(
            PMDecisionRecord(
                decisionId: "pm-decision-\(definition.charterId)-latest-take",
                pmId: "pm-1",
                title: "Standing review conclusion: \(definition.title)",
                summary: "PM reviewed \(definition.title).",
                recommendedAction: "\(definition.title) remains a background review item.",
                charterId: definition.charterId,
                primaryStandingReportId: report.reportId,
                standingReportIds: [report.reportId],
                standingReviewAnalystTitles: [definition.title],
                createdAt: now.addingTimeInterval(30),
                updatedAt: now.addingTimeInterval(30)
            )
        )
    }

    let engine = Engine(
        pmProfileStore: profileStore,
        pmDecisionStore: decisionStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        analystStandingReportStore: standingReportStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )
    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerPrompts: [(charterId: String, prompt: String)] = [
        ("bench-sector-technology", "What is the latest take from our tech analyst?"),
        ("bench-sector-healthcare-biotech", "What is the latest take from our healthcare analyst?"),
        ("bench-sector-consumer", "What is the latest take from our consumer analyst?"),
        ("bench-sector-industrials", "What is the latest take from our industrial analyst?"),
        ("bench-sector-financials", "What is the latest take from our financial analyst?"),
        ("bench-sector-energy-materials", "What is the latest take from our energy analyst?"),
        ("bench-overlay-macro-international", "What is the latest take from our macro analyst?"),
        ("bench-overlay-portfolio-risk", "What is the latest take from our risk analyst regarding the paper portfolio?")
    ]

    for ownerPrompt in ownerPrompts {
        let definition = try #require(nonRecentNewsDefinitions.first(where: { $0.charterId == ownerPrompt.charterId }))
        let ownerMessage = try await engine.createPMCommunicationMessage(
            sessionId: session.sessionId,
            senderRole: .owner,
            senderId: "owner",
            body: ownerPrompt.prompt,
            source: .ui
        )

        _ = try await engine.generatePMConversationReply(to: ownerMessage.messageId, source: .ui)
        let request = try #require(await synthesisProvider.lastConversationRequest)
        let artifactGrounding = request.analystArtifactSummary.joined(separator: "\n")
        let renderedPrompt = makePMConversationPromptText(from: request)
        let laneContext = try #require(request.analystArtifactSummary.first(where: {
            $0.contains("FULL_ANALYST_REPORT_DOCUMENT") && $0.contains(definition.title)
        }))

        #expect(artifactGrounding.contains("Open standing analyst bench full-report context for PM reasoning"))
        #expect(artifactGrounding.contains("not deterministic app interpretation of the owner message"))
        #expect(laneContext.contains("standing-report-\(definition.charterId)-latest-take"))
        #expect(laneContext.contains("\(definition.title) full report detail survives open bench retrieval"))
        #expect(renderedPrompt.contains(definition.title))
        #expect(renderedPrompt.contains("\(definition.title) full report detail survives open bench retrieval"))
    }
}

@Test("PM conversation lane index leaves no-match analyst choice to model reasoning without substitution")
func pmConversationAnalystLaneIndexLeavesNoMatchChoiceToModelReasoningWithoutSubstitution() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-recent-news-no-match")
    let now = Date(timeIntervalSince1970: 1_746_000_208)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let standingReportStore = AnalystStandingReportStore(reportsDirectory: root.appendingPathComponent("standing_reports", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "I do not find a reviewed Recent News Analyst report in app-owned storage.",
            resolution: PMConversationResolutionState(
                intentClass: .followUpQuestion,
                disposition: .conversationOnly
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Run the owner-facing PM desk.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await standingReportStore.upsert(
        AnalystStandingReport(
            reportId: "standing-report-consumer-only",
            deliveryStatus: .reviewedByPM,
            analystId: "bench-sector-consumer-analyst",
            charterId: "bench-sector-consumer",
            scheduleId: "standing-report-bench-sector-consumer",
            memoId: "memo-consumer-only",
            title: "Consumer Analyst Standing Report",
            summary: "A Consumer Analyst report exists, but it is not Recent News Analyst.",
            cadenceIntervalSec: standingAnalystReportDefaultIntervalSec,
            reportingWindowSummary: "Consumer weekly review.",
            portfolioScopeSummary: "Consumer sector coverage.",
            headlineView: "Consumer report should not be substituted.",
            portfolioRelevanceSummary: "Consumer-sector context only.",
            deliveredToPMInboxAt: now.addingTimeInterval(-400),
            createdAt: now.addingTimeInterval(-400),
            updatedAt: now.addingTimeInterval(-300)
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        analystStandingReportStore: standingReportStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerMessage = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "What was the last Recent News Analyst report you reviewed?",
        source: .ui
    )

    _ = try await engine.generatePMConversationReply(to: ownerMessage.messageId, source: .ui)
    let request = try #require(await synthesisProvider.lastConversationRequest)

    let laneIndex = request.analystArtifactSummary.joined(separator: "\n")
    #expect(laneIndex.contains("Recent News Analyst: no standing report found"))
    #expect(laneIndex.contains("Consumer Analyst: latest reviewed"))
    #expect(laneIndex.contains("standing-report-consumer-only"))
    #expect(laneIndex.contains("PM model must choose the relevant analyst lane"))
    #expect(laneIndex.contains("Do not substitute another analyst"))
}

@Test("PM conversation latest-reviewed lane index uses the latest Recent News report and suppresses older generic matches")
func pmConversationLatestReviewedLaneIndexUsesLatestRecentNewsReportAndSuppressesOlderGenericMatches() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-latest-reviewed-recent-news")
    let base = Date(timeIntervalSince1970: 1_777_820_000)
    let olderRecentNewsReviewAt = base.addingTimeInterval(-2_000)
    let latestRecentNewsReviewAt = base.addingTimeInterval(-200)
    let newerConsumerReviewAt = base.addingTimeInterval(-50)
    let clock = PMCommunicationLockedDateSequence([
        olderRecentNewsReviewAt,
        latestRecentNewsReviewAt,
        newerConsumerReviewAt
    ])
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let standingReportStore = AnalystStandingReportStore(
        reportsDirectory: root.appendingPathComponent("standing_reports", isDirectory: true),
        now: { clock.next() }
    )
    let decisionStore = PMDecisionStore(decisionsDirectory: root.appendingPathComponent("decisions", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "The latest reviewed Recent News Analyst report's only material signal is SpaceX capital markets.",
            resolution: PMConversationResolutionState(
                intentClass: .followUpQuestion,
                disposition: .conversationOnly
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Run the owner-facing PM desk.",
            createdAt: base,
            updatedAt: base
        )
    )
    _ = try await standingReportStore.upsert(
        AnalystStandingReport(
            reportId: "standing-report-recent-news-aaa-older-ai-capex",
            deliveryStatus: .reviewedByPM,
            analystId: recentNewsStandingAnalystID,
            charterId: recentNewsStandingAnalystCharterID,
            scheduleId: "standing-report-\(recentNewsStandingAnalystID)",
            memoId: "memo-recent-news-older-ai-capex",
            title: "Recent News Analyst: AI capex remains the main PM-relevant signal; Blue Owl and retirement-order items are secondary",
            summary: "Older Recent News report that must not answer the latest-report follow-up.",
            cadenceIntervalSec: standingAnalystReportDefaultIntervalSec,
            reportingWindowSummary: "Older Recent News review.",
            portfolioScopeSummary: "Recent-news overlay coverage.",
            headlineView: "AI capex was the older material signal.",
            portfolioRelevanceSummary: "Older recent-news context.",
            sections: [
                AnalystStandingReportSection(
                    sectionId: "older-material",
                    kind: .materialDevelopments,
                    summary: "Older material signal.",
                    items: [
                        AnalystStandingReportItem(
                            itemId: "older-ai-capex",
                            headline: "AI capex was the only older material signal.",
                            detail: "This older AI capex detail should not be offered as the latest Recent News Analyst report.",
                            stance: .neutral
                        )
                    ]
                )
            ],
            deliveredToPMInboxAt: olderRecentNewsReviewAt.addingTimeInterval(-60),
            createdAt: olderRecentNewsReviewAt.addingTimeInterval(-60),
            updatedAt: olderRecentNewsReviewAt
        )
    )
    _ = try await standingReportStore.upsert(
        AnalystStandingReport(
            reportId: "standing-report-recent-news-latest-spacex",
            deliveryStatus: .reviewedByPM,
            analystId: recentNewsStandingAnalystID,
            charterId: "",
            scheduleId: "standing-report-\(recentNewsStandingAnalystID)",
            memoId: "memo-recent-news-latest-spacex",
            title: "Recent News: SpaceX capital-markets headline is the only material signal, but it remains unconfirmed",
            summary: "Latest Recent News report selected through canonical analyst identity.",
            cadenceIntervalSec: standingAnalystReportDefaultIntervalSec,
            reportingWindowSummary: "Latest Recent News review.",
            portfolioScopeSummary: "Recent-news overlay coverage.",
            headlineView: "SpaceX capital-markets headline is the only material signal.",
            portfolioRelevanceSummary: "Latest recent-news context.",
            sections: [
                AnalystStandingReportSection(
                    sectionId: "latest-material",
                    kind: .materialDevelopments,
                    summary: "Only one material signal was present.",
                    items: [
                        AnalystStandingReportItem(
                            itemId: "latest-spacex-capital-markets",
                            headline: "SpaceX capital-markets headline is the only material signal.",
                            detail: "The latest Recent News Analyst report treats the SpaceX capital-markets headline as the only material signal, with confirmation still unresolved.",
                            stance: .neutral
                        )
                    ]
                )
            ],
            deliveredToPMInboxAt: latestRecentNewsReviewAt.addingTimeInterval(-60),
            createdAt: latestRecentNewsReviewAt.addingTimeInterval(-60),
            updatedAt: latestRecentNewsReviewAt
        )
    )
    _ = try await standingReportStore.upsert(
        AnalystStandingReport(
            reportId: "standing-report-consumer-newer-than-recent-news",
            deliveryStatus: .reviewedByPM,
            analystId: "bench-sector-consumer-analyst",
            charterId: "bench-sector-consumer",
            scheduleId: "standing-report-bench-sector-consumer",
            memoId: "memo-consumer-newer-than-recent-news",
            title: "Consumer Analyst standing report refresh",
            summary: "Newer Consumer report that must not satisfy a Recent News follow-up.",
            cadenceIntervalSec: standingAnalystReportDefaultIntervalSec,
            reportingWindowSummary: "Consumer review.",
            portfolioScopeSummary: "Consumer sector coverage.",
            headlineView: "Consumer report is newer but unrelated.",
            portfolioRelevanceSummary: "Consumer context only.",
            deliveredToPMInboxAt: newerConsumerReviewAt.addingTimeInterval(-60),
            createdAt: newerConsumerReviewAt.addingTimeInterval(-60),
            updatedAt: newerConsumerReviewAt
        )
    )
    _ = try await decisionStore.upsert(
        PMDecisionRecord(
            decisionId: "pm-decision-latest-recent-news-spacex",
            pmId: "pm-1",
            title: "Standing review conclusion: Recent News SpaceX capital-markets headline",
            summary: "PM reviewed the latest Recent News Analyst report.",
            recommendedAction: "Keep the latest Recent News report in monitor-only state.",
            charterId: recentNewsStandingAnalystCharterID,
            primaryStandingReportId: "standing-report-recent-news-latest-spacex",
            standingReportIds: ["standing-report-recent-news-latest-spacex"],
            standingReviewAnalystTitles: [recentNewsStandingAnalystTitle],
            standingReviewAttentionItems: ["SpaceX capital-markets headline is the only material signal."],
            createdAt: latestRecentNewsReviewAt.addingTimeInterval(120),
            updatedAt: latestRecentNewsReviewAt.addingTimeInterval(120)
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmDecisionStore: decisionStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        analystStandingReportStore: standingReportStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerMessage = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "For that latest Recent News Analyst report, what was the only material signal?",
        source: .ui
    )

    _ = try await engine.generatePMConversationReply(to: ownerMessage.messageId, source: .ui)
    let request = try #require(await synthesisProvider.lastConversationRequest)
    let laneIndex = request.analystArtifactSummary.joined(separator: "\n")

    #expect(request.analystArtifactSummary.count >= 2)
    #expect(laneIndex.contains("Recent News Analyst: latest reviewed"))
    #expect(laneIndex.contains("standing-report-recent-news-latest-spacex"))
    #expect(laneIndex.contains("SpaceX capital-markets headline is the only material signal"))
    #expect(laneIndex.contains("FULL_REPORT_SECTION"))
    #expect(laneIndex.contains("Consumer Analyst: latest reviewed"))
    #expect(!laneIndex.contains("standing-report-recent-news-aaa-older-ai-capex"))
    #expect(!laneIndex.contains("AI capex was the only older material signal"))
    let renderedPrompt = makePMConversationPromptText(from: request)
    #expect(renderedPrompt.contains("Recent News Analyst: latest reviewed"))
    #expect(renderedPrompt.contains("SpaceX capital-markets headline is the only material signal"))
    #expect(!renderedPrompt.contains("AI capex was the only older material signal"))
}

@Test("PM conversation retrieves Recent News full detail from report memo evidence and PM treatment")
func pmConversationRetrievesRecentNewsFullDetailFromReportMemoEvidenceAndPMTreatment() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-recent-news-full-detail")
    let now = Date(timeIntervalSince1970: 1_777_840_000)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let standingReportStore = AnalystStandingReportStore(reportsDirectory: root.appendingPathComponent("standing_reports", isDirectory: true))
    let memoStore = AnalystMemoStore(memosDirectory: root.appendingPathComponent("memos", isDirectory: true))
    let evidenceStore = AnalystEvidenceBundleStore(evidenceDirectory: root.appendingPathComponent("evidence", isDirectory: true))
    let decisionStore = PMDecisionStore(decisionsDirectory: root.appendingPathComponent("decisions", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "The latest Recent News Analyst detail used the shipping-risk and GameStop/eBay article set and PM closed it monitor-only.",
            resolution: PMConversationResolutionState(
                intentClass: .followUpQuestion,
                disposition: .conversationOnly
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Run the owner-facing PM desk.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await evidenceStore.upsert(
        AnalystEvidenceBundle(
            bundleId: "evidence-recent-news-full-detail",
            analystId: recentNewsStandingAnalystID,
            charterId: recentNewsStandingAnalystCharterID,
            taskId: "standing-report-\(recentNewsStandingAnalystID)",
            refs: [
                AnalystEvidenceRef(
                    refId: "app-news-whatsapp",
                    sourceKind: .appNews,
                    sourceIdentifier: "rss_digital_trends",
                    title: "What is WhatsApp? How to use the app, tips, tricks, and more",
                    summary: "App-owned article in the noisy recent-news window."
                ),
                AnalystEvidenceRef(
                    refId: "app-news-gamestop-ebay",
                    sourceKind: .appNews,
                    sourceIdentifier: "rss_cnbc",
                    title: "eBay pops as Ryan Cohen says GameStop could issue stock to pay for takeover of much bigger retailer",
                    summary: "Low-confidence GameStop/eBay headline risk."
                ),
                AnalystEvidenceRef(
                    refId: "app-news-hormuz",
                    sourceKind: .appNews,
                    sourceIdentifier: "rss_cnbc",
                    title: "Oil prices rise as U.S. launches operation to restore freedom of navigation in Strait of Hormuz",
                    summary: "Shipping-risk headline confirmed as material to monitor."
                ),
                AnalystEvidenceRef(
                    refId: "web-axios",
                    sourceKind: .web,
                    sourceIdentifier: "axios",
                    url: "https://www.axios.com/",
                    title: "Axios",
                    summary: "Adds incremental timing, background, or strategic/risk context."
                )
            ],
            summary: "Recent News evidence bundle preserved material app-news titles and supplemental source checks.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await memoStore.upsert(
        AnalystMemo(
            memoId: "memo-recent-news-full-detail",
            analystId: recentNewsStandingAnalystID,
            charterId: recentNewsStandingAnalystCharterID,
            evidenceBundleId: "evidence-recent-news-full-detail",
            title: "Recent News Watch: No New Material Development Beyond Existing Broad-Market Headline Risk",
            executiveSummary: "The recent-news window is noisy but not obviously portfolio-changing.",
            currentView: "Shipping-risk headline is worth monitoring; GameStop-eBay remains low-confidence.",
            evidenceSummary: "Material news list includes WhatsApp, GameStop/eBay, and Hormuz shipping-risk items.",
            uncertaintySummary: "Wait for official maritime or issuer-level confirmation before escalation.",
            recommendedNextStep: "Continue monitoring and keep the recommendation episode closed unless new evidence appears.",
            confidence: 0.68,
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await standingReportStore.upsert(
        AnalystStandingReport(
            reportId: "standing-report-recent-news-full-detail",
            deliveryStatus: .reviewedByPM,
            analystId: recentNewsStandingAnalystID,
            charterId: recentNewsStandingAnalystCharterID,
            scheduleId: "standing-report-\(recentNewsStandingAnalystID)",
            memoId: "memo-recent-news-full-detail",
            title: "Recent News Analyst Standing Report",
            summary: "No new material development beyond existing broad-market headline risk.",
            cadenceIntervalSec: standingAnalystReportDefaultIntervalSec,
            reportingWindowSummary: "Recent news review through this morning.",
            portfolioScopeSummary: "Current portfolio and watchlist recent-news coverage.",
            headlineView: "Shipping-risk headline confirmed as material; GameStop-eBay remains low-confidence.",
            portfolioRelevanceSummary: "Monitor shipping risk and issuer-level evidence before elevating.",
            sections: [
                AnalystStandingReportSection(
                    sectionId: "recent-news-material-placeholder",
                    kind: .materialDevelopments,
                    summary: "Legacy schema placeholder; linked memo/evidence carries the concrete recent-news articles.",
                    items: [
                        AnalystStandingReportItem(
                            itemId: "structured-materiality-placeholder",
                            headline: "Structured materiality section is now in place",
                            detail: "This placeholder must not crowd out linked analyst memo/evidence when the PM reads the full report.",
                            stance: .neutral
                        )
                    ]
                ),
                AnalystStandingReportSection(
                    sectionId: "recent-news-material",
                    kind: .materialDevelopments,
                    summary: "Shipping-risk headline confirmed as material; GameStop-eBay remains low-confidence.",
                    items: [
                        AnalystStandingReportItem(
                            itemId: "hormuz-shipping-risk",
                            headline: "Hormuz shipping-risk headline is the material monitoring signal.",
                            detail: "The latest Recent News Analyst report treats the shipping-risk headline around Hormuz as material to monitor, while requiring official maritime or insurer follow-up before escalation.",
                            stance: .risk
                        ),
                        AnalystStandingReportItem(
                            itemId: "gamestop-ebay-low-confidence",
                            headline: "GameStop-eBay bid remains low-confidence.",
                            detail: "The report keeps the GameStop/eBay item as headline risk rather than a confirmed portfolio-changing signal.",
                            stance: .neutral
                        )
                    ]
                )
            ],
            deliveredToPMInboxAt: now.addingTimeInterval(-60),
            createdAt: now.addingTimeInterval(-60),
            updatedAt: now
        )
    )
    _ = try await decisionStore.upsert(
        PMDecisionRecord(
            decisionId: "pm-decision-recent-news-full-detail",
            pmId: "pm-1",
            title: "Recent News Analyst review closed monitor-only",
            summary: "PM judged this as owner-relevant context worth surfacing, but not decision-ready.",
            recommendedAction: "This recommendation episode is closed with no further owner action pending.",
            evidenceSummary: "Shipping-risk headline confirmed as material; GameStop-eBay remains low-confidence.",
            decisionType: .recommendation,
            status: .active,
            primaryStandingReportId: "standing-report-recent-news-full-detail",
            standingReviewAnalystTitles: [recentNewsStandingAnalystTitle],
            standingReviewAttentionItems: ["Shipping-risk headline confirmed as material."],
            standingReviewFollowUpItems: ["Continue monitoring for official maritime-security or insurer follow-up."],
            createdAt: now,
            updatedAt: now.addingTimeInterval(120)
        )
    )
    _ = try await decisionStore.upsert(
        PMDecisionRecord(
            decisionId: "pm-decision-recent-news-stale-amazon-uae",
            pmId: "pm-1",
            title: "Standing review conclusion: Recent News Analyst Refresh — Limited Incremental Signal, Highest Attention on Amazon and UAE",
            summary: "Older PM review text that should not be appended as a generic ranked snippet when the owner asks for the latest Recent News full report.",
            recommendedAction: "Keep Amazon/UAE follow-up in background review only.",
            evidenceSummary: "Standing review cycle covered 1 older report from Recent News Analyst Refresh — Limited Incremental Signal, Highest Attention on Amazon and UAE.",
            decisionType: .recommendation,
            status: .active,
            primaryStandingReportId: "standing-report-recent-news-stale-amazon-uae",
            standingReviewAnalystTitles: [recentNewsStandingAnalystTitle],
            standingReviewAttentionItems: ["Limited Incremental Signal, Highest Attention on Amazon and UAE."],
            createdAt: now.addingTimeInterval(-3_600),
            updatedAt: now.addingTimeInterval(-3_600)
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmDecisionStore: decisionStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        analystEvidenceBundleStore: evidenceStore,
        analystMemoStore: memoStore,
        analystStandingReportStore: standingReportStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let staleOwnerMessage = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "What was the latest Recent News Analyst report you reviewed?",
        source: .ui
    )
    _ = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .pm,
        senderId: "pm-1",
        body: "The older Recent News Analyst report's material signal was AI capex.",
        replyToMessageId: staleOwnerMessage.messageId,
        source: .system
    )
    let ownerMessage = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "What was the latest Recent News Analyst report you reviewed, and what material articles or signals did it contain?",
        source: .ui
    )

    _ = try await engine.generatePMConversationReply(to: ownerMessage.messageId, source: .ui)
    let request = try #require(await synthesisProvider.lastConversationRequest)
    let artifactGrounding = request.analystArtifactSummary.joined(separator: "\n")
    let renderedPrompt = makePMConversationPromptText(from: request)

    #expect(artifactGrounding.contains("Linked app-owned news/article refs"))
    #expect(artifactGrounding.contains("Named analyst full-report retrieval"))
    #expect(artifactGrounding.contains("FULL_ANALYST_REPORT_DOCUMENT"))
    #expect(artifactGrounding.contains("FULL_REPORT_LINKED_MEMO_AND_EVIDENCE"))
    #expect(artifactGrounding.contains("FULL_REPORT_SECTION"))
    #expect(artifactGrounding.contains("Recent News Analyst"))
    let firstReportContext = try #require(request.analystArtifactSummary.dropFirst().first)
    #expect(firstReportContext.hasPrefix("FULL_ANALYST_REPORT_DOCUMENT"))
    #expect(artifactGrounding.contains("Oil prices rise as U.S. launches operation"))
    #expect(artifactGrounding.contains("eBay pops as Ryan Cohen"))
    #expect(artifactGrounding.contains("Supplemental/support sources checked"))
    #expect(artifactGrounding.contains("PM reviewed/treatment record"))
    #expect(artifactGrounding.contains("no further owner action pending"))
    #expect(renderedPrompt.contains("Hormuz shipping-risk headline is the material monitoring signal"))
    #expect(renderedPrompt.contains("PM reviewed/treatment record"))
    let memoRange = try #require(firstReportContext.range(of: "FULL_LINKED_ANALYST_MEMO_BODY"))
    let evidenceRange = try #require(firstReportContext.range(of: "Linked app-owned news/article refs"))
    let scaffoldOmissionRange = try #require(firstReportContext.range(of: "REPORT_SCHEMA_SCAFFOLD_OMITTED"))
    let treatmentRange = try #require(firstReportContext.range(of: "FULL_REPORT_PM_REVIEW_TREATMENT_METADATA"))
    #expect(memoRange.lowerBound < evidenceRange.lowerBound)
    #expect(evidenceRange.lowerBound < treatmentRange.lowerBound)
    #expect(scaffoldOmissionRange.lowerBound < treatmentRange.lowerBound)
    #expect(firstReportContext.contains("Structured materiality section is now in place") == false)
    #expect(renderedPrompt.contains("Structured materiality section is now in place") == false)
    #expect(artifactGrounding.contains("older Recent News Analyst report") == false)
    #expect(artifactGrounding.contains("AI capex") == false)
    #expect(artifactGrounding.contains("Amazon and UAE") == false)
    #expect(artifactGrounding.contains("Limited Incremental Signal") == false)
    #expect(renderedPrompt.contains("Amazon and UAE") == false)
    #expect(renderedPrompt.contains("Limited Incremental Signal") == false)
    #expect(request.recentConversationSummary.contains(where: {
        $0.contains("older Recent News Analyst report") || $0.contains("AI capex")
    }) == false)
    #expect(renderedPrompt.contains("Prior PM replies may be stale"))
    #expect(renderedPrompt.contains("Treat FULL_REPORT_LINKED_MEMO_AND_EVIDENCE as the full analyst-created report body"))
    #expect(renderedPrompt.contains("treat that as full analyst report body available to you"))
    #expect(renderedPrompt.contains("Do not describe the report as missing, merely skeletal, not deep, summary-only, or unavailable"))
    #expect(renderedPrompt.contains("Use analyst report dates exactly as provided"))
    #expect(renderedPrompt.contains("Do not invent reporting windows, date ranges, review times, or report titles"))
    #expect(artifactGrounding.contains("Report title to use"))
    #expect(artifactGrounding.contains("Reporting window to use when relevant"))
    #expect(request.recentConversationSummary.count == 1)
    #expect(request.detailedCommunicationHistorySummary.isEmpty)
    #expect(request.conversationFragmentSummary.isEmpty)
    #expect(request.recoveredContextSummary.isEmpty)
    let artifactLaneRange = try #require(renderedPrompt.range(of: "Available analyst report artifacts and full analyst report document context for this ask"))
    let recentConversationRange = try #require(renderedPrompt.range(of: "Exact recent conversation text"))
    #expect(artifactLaneRange.lowerBound < recentConversationRange.lowerBound)
}

@Test("PM conversation latest-reviewed lane index preserves Technology Analyst latest reviewed behavior")
func pmConversationLatestReviewedLaneIndexPreservesTechnologyAnalystLatestReviewedBehavior() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-latest-reviewed-technology")
    let base = Date(timeIntervalSince1970: 1_777_830_000)
    let recentNewsReviewAt = base.addingTimeInterval(-300)
    let technologyReviewAt = base.addingTimeInterval(-40)
    let clock = PMCommunicationLockedDateSequence([
        recentNewsReviewAt,
        technologyReviewAt
    ])
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let standingReportStore = AnalystStandingReportStore(
        reportsDirectory: root.appendingPathComponent("standing_reports", isDirectory: true),
        now: { clock.next() }
    )
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "The latest reviewed Technology Analyst report was reviewed at the expected timestamp.",
            resolution: PMConversationResolutionState(
                intentClass: .followUpQuestion,
                disposition: .conversationOnly
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Run the owner-facing PM desk.",
            createdAt: base,
            updatedAt: base
        )
    )
    _ = try await standingReportStore.upsert(
        AnalystStandingReport(
            reportId: "standing-report-recent-news-present",
            deliveryStatus: .reviewedByPM,
            analystId: recentNewsStandingAnalystID,
            charterId: recentNewsStandingAnalystCharterID,
            scheduleId: "standing-report-\(recentNewsStandingAnalystID)",
            memoId: "memo-recent-news-present",
            title: "Recent News Analyst Standing Report",
            summary: "Recent News lane is present but not the Technology answer.",
            cadenceIntervalSec: standingAnalystReportDefaultIntervalSec,
            reportingWindowSummary: "Recent News review.",
            portfolioScopeSummary: "Recent-news overlay coverage.",
            headlineView: "Recent News context.",
            portfolioRelevanceSummary: "Recent News context.",
            deliveredToPMInboxAt: recentNewsReviewAt.addingTimeInterval(-60),
            createdAt: recentNewsReviewAt.addingTimeInterval(-60),
            updatedAt: recentNewsReviewAt
        )
    )
    _ = try await standingReportStore.upsert(
        AnalystStandingReport(
            reportId: "standing-report-technology-latest-reviewed",
            deliveryStatus: .reviewedByPM,
            analystId: "",
            charterId: "",
            scheduleId: "standing-report-bench-sector-technology",
            memoId: "memo-technology-latest-reviewed",
            title: "Technology Analyst Standing Report",
            summary: "Latest Technology report selected through schedule identity.",
            cadenceIntervalSec: standingAnalystReportDefaultIntervalSec,
            reportingWindowSummary: "Technology review.",
            portfolioScopeSummary: "Technology sector coverage.",
            headlineView: "Narrow AI-positive tone, limited new fundamental confirmation.",
            portfolioRelevanceSummary: "Technology context.",
            deliveredToPMInboxAt: technologyReviewAt.addingTimeInterval(-60),
            createdAt: technologyReviewAt.addingTimeInterval(-60),
            updatedAt: technologyReviewAt
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        analystStandingReportStore: standingReportStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerMessage = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "What was the last Technology Analyst report (day and time) that you reviewed.",
        source: .ui
    )

    _ = try await engine.generatePMConversationReply(to: ownerMessage.messageId, source: .ui)
    let request = try #require(await synthesisProvider.lastConversationRequest)
    let laneIndex = request.analystArtifactSummary.joined(separator: "\n")

    #expect(request.analystArtifactSummary.count >= 2)
    #expect(laneIndex.contains("Technology Analyst: latest reviewed"))
    #expect(laneIndex.contains("standing-report-technology-latest-reviewed"))
    #expect(laneIndex.contains(DateCodec.formatISO8601(technologyReviewAt)))
    #expect(laneIndex.contains("reviewed_by_pm report updatedAt"))
}

@Test("PM conversation skill-usage readback promotes persisted Agent Skill names")
func pmConversationSkillUsageReadbackPromotesPersistedAgentSkillNames() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-agent-skill-usage-readback")
    let now = Date(timeIntervalSince1970: 1_800_002_520)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let standingReportStore = AnalystStandingReportStore(
        reportsDirectory: root.appendingPathComponent("standing_reports", isDirectory: true),
        now: { now }
    )
    let memoStore = AnalystMemoStore(
        memosDirectory: root.appendingPathComponent("memos", isDirectory: true),
        now: { now }
    )
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "The latest Technology Analyst report used the persisted Agent Skills.",
            resolution: PMConversationResolutionState(
                intentClass: .followUpQuestion,
                disposition: .conversationOnly
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Run the owner-facing PM desk.",
            createdAt: now,
            updatedAt: now
        )
    )
    let skillUsage = makePMConversationAllSeededSkillUsageSummaries()
    _ = try await memoStore.upsert(
        AnalystMemo(
            memoId: "memo-technology-skill-usage",
            analystId: "bench-sector-technology-analyst",
            charterId: "bench-sector-technology",
            taskId: "standing-report-task-standing-report-bench-sector-technology",
            findingId: nil,
            evidenceBundleId: nil,
            title: "Technology Analyst Standing Report",
            executiveSummary: "Technology memo with explicit Agent Skills.",
            currentView: "AI infrastructure remains constructive but confirmation is incomplete.",
            evidenceSummary: "Evidence was bounded to app-owned and policy-governed support.",
            uncertaintySummary: "Confirmation breadth is still the core uncertainty.",
            recommendedNextStep: "Monitor evidence confirmation before broadening conclusions.",
            confidence: 0.66,
            skillUsageSummaries: skillUsage,
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await standingReportStore.upsert(
        AnalystStandingReport(
            reportId: "standing-report-technology-skill-usage",
            deliveryStatus: .reviewedByPM,
            analystId: "bench-sector-technology-analyst",
            charterId: "bench-sector-technology",
            scheduleId: "standing-report-bench-sector-technology",
            memoId: "memo-technology-skill-usage",
            title: "Technology standing refresh: skill usage",
            summary: "Technology standing report with persisted Agent Skill usage.",
            cadenceIntervalSec: standingAnalystReportDefaultIntervalSec,
            reportingWindowSummary: "Technology skill usage review.",
            portfolioScopeSummary: "Technology sector coverage.",
            headlineView: "AI infrastructure signal with breadth confirmation still missing.",
            portfolioRelevanceSummary: "Relevant to technology watchlist and candidate review.",
            skillUsageSummaries: skillUsage,
            deliveredToPMInboxAt: now.addingTimeInterval(-60),
            createdAt: now.addingTimeInterval(-60),
            updatedAt: now
        )
    )
    let portfolioFitUsage = [
        AgentSkillUsageSummary(
            skillId: AgentSkillSeed.portfolioFitRiskLensID,
            skillTitle: "Portfolio Fit & Risk Lens",
            requirement: .required,
            usage: .applied,
            usageSummary: "Connected the risk takeaway to current portfolio exposure and data-quality caveats."
        )
    ]
    _ = try await memoStore.upsert(
        AnalystMemo(
            memoId: "memo-portfolio-risk-skill-usage",
            analystId: "bench-overlay-portfolio-risk-analyst",
            charterId: "bench-overlay-portfolio-risk",
            taskId: "standing-report-task-standing-report-bench-overlay-portfolio-risk",
            findingId: nil,
            evidenceBundleId: nil,
            title: "Portfolio Risk Analyst Standing Report",
            executiveSummary: "Portfolio risk memo with explicit skill usage.",
            currentView: "Risk posture depends on exposure quality and live-data readiness.",
            evidenceSummary: "Portfolio Watch and Portfolio Intelligence were the app-owned source.",
            uncertaintySummary: "No advanced metrics were asserted without history.",
            recommendedNextStep: "Keep exposure caveats visible.",
            confidence: 0.7,
            skillUsageSummaries: portfolioFitUsage,
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await standingReportStore.upsert(
        AnalystStandingReport(
            reportId: "standing-report-portfolio-risk-skill-usage",
            deliveryStatus: .reviewedByPM,
            analystId: "bench-overlay-portfolio-risk-analyst",
            charterId: "bench-overlay-portfolio-risk",
            scheduleId: "standing-report-bench-overlay-portfolio-risk",
            memoId: "memo-portfolio-risk-skill-usage",
            title: "Portfolio Risk standing refresh: skill usage",
            summary: "Portfolio Risk standing report with persisted Agent Skill usage.",
            cadenceIntervalSec: standingAnalystReportDefaultIntervalSec,
            reportingWindowSummary: "Portfolio Risk skill usage review.",
            portfolioScopeSummary: "Paper portfolio risk coverage.",
            headlineView: "Risk posture depends on exposure quality and live-data readiness.",
            portfolioRelevanceSummary: "Relevant to current paper portfolio caveats.",
            skillUsageSummaries: portfolioFitUsage,
            deliveredToPMInboxAt: now.addingTimeInterval(-30),
            createdAt: now.addingTimeInterval(-30),
            updatedAt: now.addingTimeInterval(1)
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        analystMemoStore: memoStore,
        analystStandingReportStore: standingReportStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )
    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerMessage = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "What skills did the Technology Analyst use in its latest report?",
        source: .ui
    )

    _ = try await engine.generatePMConversationReply(to: ownerMessage.messageId, source: .ui)
    let request = try #require(await synthesisProvider.lastConversationRequest)
    let artifactContext = request.analystArtifactSummary.joined(separator: "\n")
    let renderedPrompt = makePMConversationPromptText(from: request)

    #expect(artifactContext.contains("AGENT_SKILL_USAGE_FOR_LATEST_ANALYST_REPORT"))
    #expect(artifactContext.contains("Role: app-owned persisted Agent Skill usage"))
    #expect(artifactContext.contains("skillId=\(AgentSkillSeed.disconfirmingEvidenceChecklistID)"))
    #expect(artifactContext.contains("Disconfirming Evidence Checklist"))
    #expect(artifactContext.contains("Portfolio Fit & Risk Lens"))
    #expect(artifactContext.contains("Source Quality And Corroboration"))
    #expect(artifactContext.contains("Long / Short Candidate Pressure Test"))
    #expect(renderedPrompt.contains("do not invent generic method labels"))

    let portfolioOwnerMessage = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Did the latest Portfolio Risk report apply the Portfolio Fit & Risk Lens?",
        source: .ui
    )
    _ = try await engine.generatePMConversationReply(to: portfolioOwnerMessage.messageId, source: .ui)
    let portfolioRequest = try #require(await synthesisProvider.lastConversationRequest)
    let portfolioContext = portfolioRequest.analystArtifactSummary.joined(separator: "\n")
    #expect(portfolioContext.contains("AGENT_SKILL_USAGE_FOR_LATEST_ANALYST_REPORT"))
    #expect(portfolioContext.contains("Portfolio Risk Analyst"))
    #expect(portfolioContext.contains("skillId=\(AgentSkillSeed.portfolioFitRiskLensID)"))
    #expect(portfolioContext.contains("Portfolio Fit & Risk Lens"))
    #expect(portfolioContext.contains("usage=Applied"))
}

@Test("PM conversation library asks include compact active Agent Skills index")
func pmConversationLibraryAskIncludesCompactActiveAgentSkillsIndex() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-agent-skills-library-index")
    let now = Date(timeIntervalSince1970: 1_800_002_540)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let skillStore = AgentSkillStore(
        skillsDirectory: root.appendingPathComponent("agent_skills", isDirectory: true),
        now: { now }
    )
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "The Agent Skills Library currently has four active seeded skills.",
            resolution: PMConversationResolutionState(
                intentClass: .followUpQuestion,
                disposition: .conversationOnly
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Run the owner-facing PM desk.",
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        agentSkillStore: skillStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )
    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerMessage = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "What skills are currently in the Agent Skills Library?",
        source: .ui
    )

    _ = try await engine.generatePMConversationReply(to: ownerMessage.messageId, source: .ui)
    let request = try #require(await synthesisProvider.lastConversationRequest)
    let confirmedTruth = request.confirmedAppTruthSummary.joined(separator: "\n")

    #expect(confirmedTruth.contains("AGENT_SKILLS_LIBRARY_INDEX"))
    #expect(confirmedTruth.contains("AGENT_SKILL_RECORD id=\(AgentSkillSeed.disconfirmingEvidenceChecklistID)"))
    #expect(confirmedTruth.contains("Disconfirming Evidence Checklist"))
    #expect(confirmedTruth.contains("Portfolio Fit & Risk Lens"))
    #expect(confirmedTruth.contains("Source Quality And Corroboration"))
    #expect(confirmedTruth.contains("Long / Short Candidate Pressure Test"))
    #expect(confirmedTruth.contains("methodology guidance only"))
}

@Test("Anthropic PM request carries the same persisted skill-usage readback context")
func anthropicPMRequestCarriesPersistedSkillUsageReadbackContext() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-anthropic-agent-skill-usage")
    let now = Date(timeIntervalSince1970: 1_800_002_560)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let runtimeSettingsStore = PMRuntimeSettingsStore(fileURL: root.appendingPathComponent("pm-runtime-settings.json", isDirectory: false))
    let standingReportStore = AnalystStandingReportStore(
        reportsDirectory: root.appendingPathComponent("standing_reports", isDirectory: true),
        now: { now }
    )
    let memoStore = AnalystMemoStore(
        memosDirectory: root.appendingPathComponent("memos", isDirectory: true),
        now: { now }
    )
    let anthropicProvider = StubPMAnthropicSynthesisProvider(
        output: PMConversationOpenAISynthesisOutput(
            replyBody: "Anthropic PM readback used persisted Agent Skill usage.",
            resolution: PMConversationResolutionState(
                intentClass: .followUpQuestion,
                disposition: .conversationOnly
            )
        )
    )
    let openAIProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(replyBody: "OpenAI should not be used."),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Run the owner-facing PM desk.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await runtimeSettingsStore.upsert(
        PMRuntimeSettings(
            providerKind: .anthropic,
            credentialProfileId: LLMCredentialProfile.anthropicDefaultProfileID,
            runtimeIdentifier: "claude-sonnet-4-6",
            reasoningMode: .standard,
            updatedBy: "owner",
            updateSource: .userEdited,
            createdAt: now,
            updatedAt: now
        )
    )
    let skillUsage = makePMConversationAllSeededSkillUsageSummaries()
    _ = try await memoStore.upsert(
        AnalystMemo(
            memoId: "memo-technology-anthropic-skill-usage",
            analystId: "bench-sector-technology-analyst",
            charterId: "bench-sector-technology",
            taskId: "standing-report-task-standing-report-bench-sector-technology",
            findingId: nil,
            evidenceBundleId: nil,
            title: "Technology Analyst Standing Report",
            executiveSummary: "Technology memo with explicit Agent Skills.",
            currentView: "AI infrastructure remains constructive but confirmation is incomplete.",
            evidenceSummary: "Evidence was bounded to app-owned and policy-governed support.",
            uncertaintySummary: "Confirmation breadth is still the core uncertainty.",
            recommendedNextStep: "Monitor evidence confirmation before broadening conclusions.",
            confidence: 0.66,
            skillUsageSummaries: skillUsage,
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await standingReportStore.upsert(
        AnalystStandingReport(
            reportId: "standing-report-technology-anthropic-skill-usage",
            deliveryStatus: .reviewedByPM,
            analystId: "bench-sector-technology-analyst",
            charterId: "bench-sector-technology",
            scheduleId: "standing-report-bench-sector-technology",
            memoId: "memo-technology-anthropic-skill-usage",
            title: "Technology standing refresh: skill usage",
            summary: "Technology standing report with persisted Agent Skill usage.",
            cadenceIntervalSec: standingAnalystReportDefaultIntervalSec,
            reportingWindowSummary: "Technology skill usage review.",
            portfolioScopeSummary: "Technology sector coverage.",
            headlineView: "AI infrastructure signal with breadth confirmation still missing.",
            portfolioRelevanceSummary: "Relevant to technology watchlist and candidate review.",
            skillUsageSummaries: skillUsage,
            deliveredToPMInboxAt: now.addingTimeInterval(-60),
            createdAt: now.addingTimeInterval(-60),
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmRuntimeSettingsStore: runtimeSettingsStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        analystMemoStore: memoStore,
        analystStandingReportStore: standingReportStore,
        llmCredentialResolver: StubPMCommunicationLLMCredentialResolver(
            resolution: LLMCredentialResolution(
                status: .ready,
                apiKey: "test-anthropic-key",
                profileId: LLMCredentialProfile.anthropicDefaultProfileID,
                providerKind: .anthropic,
                matchedServiceOrLabel: "anthropic_api_key",
                account: "algo-trading",
                summary: "Test Anthropic key resolved."
            )
        ),
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: openAIProvider,
        pmAnthropicSynthesisProvider: anthropicProvider
    )
    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerMessage = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "What Agent Skills were used or considered in the latest Technology Analyst report?",
        source: .ui
    )

    _ = try await engine.generatePMConversationReply(to: ownerMessage.messageId, source: .ui)
    let request = try #require(await anthropicProvider.lastConversationRequest)
    let artifactContext = request.analystArtifactSummary.joined(separator: "\n")

    #expect(await openAIProvider.lastConversationRequest == nil)
    #expect(request.runtimeIdentifier == "claude-sonnet-4-6")
    #expect(artifactContext.contains("AGENT_SKILL_USAGE_FOR_LATEST_ANALYST_REPORT"))
    #expect(artifactContext.contains("Disconfirming Evidence Checklist"))
    #expect(artifactContext.contains("Portfolio Fit & Risk Lens"))
    #expect(artifactContext.contains("Source Quality And Corroboration"))
    #expect(artifactContext.contains("Long / Short Candidate Pressure Test"))
}

@Test("PM-selected Agent Skills persist on conversation-launched analyst task and enter analyst context")
func pmSelectedAgentSkillsPersistOnConversationLaunchedAnalystTask() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-selected-skill-tasking")
    let now = Date(timeIntervalSince1970: 1_800_002_620)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let charterStore = AnalystCharterStore(chartersDirectory: root.appendingPathComponent("charters", isDirectory: true))
    let delegationStore = PMDelegationStore(delegationsDirectory: root.appendingPathComponent("delegations", isDirectory: true))
    let taskStore = AnalystTaskStore(tasksDirectory: root.appendingPathComponent("tasks", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let skillStore = AgentSkillStore(skillsDirectory: root.appendingPathComponent("agent_skills", isDirectory: true), now: { now })
    let newsStore = NewsStore(newsDirectory: root.appendingPathComponent("news", isDirectory: true), now: { now })
    let strategyBriefStore = PortfolioStrategyBriefStore(
        fileURL: root.appendingPathComponent("portfolio_strategy_brief.json"),
        now: { now }
    )
    let launchRecorder = PMConversationActionPlanLaunchRecorder()
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "I’m asking the Technology Analyst to review NVDA with the selected Agent Skills.",
            actionPlan: PMConversationActionPlan(
                summary: "Launch Technology Analyst work with PM-selected Agent Skills.",
                actions: [
                    PMConversationActionIntent(
                        actionType: .launchAdHocAnalystDelegation,
                        summary: "Ask the Technology Analyst to review NVDA using selected methodology skills.",
                        title: "Review NVDA with selected Agent Skills",
                        body: "Review NVDA and explicitly apply the selected reusable methods.",
                        detail: "Owner requested the Disconfirming Evidence Checklist and Long / Short Candidate Pressure Test.",
                        charterId: "Technology Analyst",
                        proposalSymbol: "NVDA",
                        requestedOutputs: [.finding],
                        selectedSkillReferences: [
                            PMConversationAgentSkillReferenceIntent(
                                skillId: AgentSkillSeed.disconfirmingEvidenceChecklistID,
                                requirement: .required,
                                rationale: "Owner asked for disconfirming evidence."
                            ),
                            PMConversationAgentSkillReferenceIntent(
                                skillId: AgentSkillSeed.longShortCandidatePressureTestID,
                                requirement: .recommended,
                                rationale: "Owner asked for a long/short pressure test."
                            )
                        ]
                    )
                ]
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Delegates bounded analyst work with selected Agent Skills.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await charterStore.upsert(
        AnalystCharter(
            charterId: "bench-sector-technology",
            analystId: "bench-sector-technology-analyst",
            title: "Technology Analyst",
            coverageScope: "Technology and AI infrastructure",
            strategyFamily: "Long/Short Equity",
            summary: "Technology coverage",
            updatedBy: "owner",
            updateSource: .userEdited,
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        newsStore: newsStore,
        pmProfileStore: profileStore,
        portfolioStrategyBriefStore: strategyBriefStore,
        agentSkillStore: skillStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        pmDelegationStore: delegationStore,
        analystCharterStore: charterStore,
        analystTaskStore: taskStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider,
        analystWorkerLauncher: PMConversationActionPlanStubLauncher(recorder: launchRecorder)
    )
    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Ask the Technology Analyst to review NVDA using the Disconfirming Evidence Checklist and Long / Short Candidate Pressure Test.",
        source: .ui
    )

    let reply = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)
    let delegation = try #require(try await engine.listPMDelegations().first)
    let task = try #require(try await engine.listAnalystTasks().first)
    let launchRequest = try #require(await launchRecorder.lastRequest)
    let selectedSkillIds = delegation.taskingBrief?.selectedSkillReferences.map(\.skillId) ?? []
    let taskSkillIds = task.pmTaskingBrief?.selectedSkillReferences.map(\.skillId) ?? []
    let contextSkills = task.contextPack?.referencedSkills ?? []

    #expect(delegation.taskId == task.taskId)
    #expect(launchRequest.taskId == task.taskId)
    #expect(reply.conversationActionPlan?.actions.first?.targetId == delegation.delegationId)
    #expect(selectedSkillIds == [
        AgentSkillSeed.disconfirmingEvidenceChecklistID,
        AgentSkillSeed.longShortCandidatePressureTestID
    ])
    #expect(taskSkillIds == selectedSkillIds)
    #expect(task.symbols == ["NVDA"])
    #expect(contextSkills.map(\.skillId) == selectedSkillIds)
    #expect(contextSkills.allSatisfy { $0.availability == .active })
    #expect(contextSkills.allSatisfy { $0.documentBody?.isEmpty == false })
    #expect(contextSkills.allSatisfy { $0.referenceSources == [.pmConversation] })
}

@Test("Invalid PM-selected Agent Skill blocks analyst tasking before delegation launch")
func invalidPMSelectedAgentSkillBlocksConversationDelegation() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-invalid-selected-skill")
    let now = Date(timeIntervalSince1970: 1_800_002_640)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let charterStore = AnalystCharterStore(chartersDirectory: root.appendingPathComponent("charters", isDirectory: true))
    let delegationStore = PMDelegationStore(delegationsDirectory: root.appendingPathComponent("delegations", isDirectory: true))
    let taskStore = AnalystTaskStore(tasksDirectory: root.appendingPathComponent("tasks", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let skillStore = AgentSkillStore(skillsDirectory: root.appendingPathComponent("agent_skills", isDirectory: true), now: { now })
    let launchRecorder = PMConversationActionPlanLaunchRecorder()
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "I’ll ask the analyst to use the selected skill.",
            actionPlan: PMConversationActionPlan(
                summary: "Attempt skill-guided analyst delegation.",
                actions: [
                    PMConversationActionIntent(
                        actionType: .launchAdHocAnalystDelegation,
                        summary: "Ask the Technology Analyst to use a selected skill.",
                        title: "Review NVDA with selected skill",
                        body: "Review NVDA.",
                        detail: "Use the selected skill.",
                        charterId: "Technology Analyst",
                        selectedSkillReferences: [
                            PMConversationAgentSkillReferenceIntent(
                                skillId: "skill-fabricated-method",
                                requirement: .required,
                                rationale: "This id is not in the app-owned library."
                            )
                        ]
                    )
                ]
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Validates skill-guided tasking.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await charterStore.upsert(
        AnalystCharter(
            charterId: "bench-sector-technology",
            analystId: "bench-sector-technology-analyst",
            title: "Technology Analyst",
            coverageScope: "Technology and AI infrastructure",
            strategyFamily: "Long/Short Equity",
            summary: "Technology coverage",
            updatedBy: "owner",
            updateSource: .userEdited,
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        agentSkillStore: skillStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        pmDelegationStore: delegationStore,
        analystCharterStore: charterStore,
        analystTaskStore: taskStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider,
        analystWorkerLauncher: PMConversationActionPlanStubLauncher(recorder: launchRecorder)
    )
    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Ask the Technology Analyst to review NVDA using skill-fabricated-method.",
        source: .ui
    )

    let reply = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)

    #expect(try await engine.listPMDelegations().isEmpty)
    #expect(try await engine.listAnalystTasks().isEmpty)
    #expect(await launchRecorder.lastRequest == nil)
    #expect(reply.conversationActionPlan?.actions.first?.targetId == nil)
    #expect(reply.conversationActionPlan?.actions.first?.detail?.contains("not in the app-owned Skills Library") == true)
}

@Test("PM readback can retrieve Agent Skills selected for recent PM analyst tasking")
func pmReadbackRetrievesSelectedSkillsForRecentAnalystTasking() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-selected-skill-readback")
    let now = Date(timeIntervalSince1970: 1_800_002_660)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let charterStore = AnalystCharterStore(chartersDirectory: root.appendingPathComponent("charters", isDirectory: true))
    let delegationStore = PMDelegationStore(delegationsDirectory: root.appendingPathComponent("delegations", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let skillStore = AgentSkillStore(skillsDirectory: root.appendingPathComponent("agent_skills", isDirectory: true), now: { now })
    let selectedSkills = [
        AgentSkillTaskReference(
            skillId: AgentSkillSeed.disconfirmingEvidenceChecklistID,
            skillTitle: "Disconfirming Evidence Checklist",
            requirement: .required,
            source: .pmConversation,
            rationale: "Owner requested disconfirming evidence.",
            updatedBy: "pm-1",
            createdAt: now,
            updatedAt: now
        ),
        AgentSkillTaskReference(
            skillId: AgentSkillSeed.longShortCandidatePressureTestID,
            skillTitle: "Long / Short Candidate Pressure Test",
            requirement: .recommended,
            source: .pmConversation,
            rationale: "Owner requested long/short pressure testing.",
            updatedBy: "pm-1",
            createdAt: now,
            updatedAt: now
        )
    ]
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "I asked the Technology Analyst to use the persisted selected Agent Skills.",
            resolution: PMConversationResolutionState(intentClass: .followUpQuestion, disposition: .conversationOnly)
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Reads back skill-guided analyst tasking.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await charterStore.upsert(
        AnalystCharter(
            charterId: "bench-sector-technology",
            analystId: "bench-sector-technology-analyst",
            title: "Technology Analyst",
            coverageScope: "Technology and AI infrastructure",
            strategyFamily: "Long/Short Equity",
            summary: "Technology coverage",
            updatedBy: "owner",
            updateSource: .userEdited,
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await delegationStore.upsert(
        PMDelegationRecord(
            delegationId: "delegation-selected-skills",
            pmId: "pm-1",
            analystId: "bench-sector-technology-analyst",
            charterId: "bench-sector-technology",
            taskId: "task-selected-skills",
            title: "Review NVDA with selected Agent Skills",
            rationale: "Owner requested skill-guided Technology Analyst work.",
            taskingBrief: PMTaskingBrief(
                taskObjective: "Review NVDA with selected Agent Skills.",
                selectedSkillReferences: selectedSkills
            ),
            requestedOutputs: [.finding],
            status: .issued,
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        agentSkillStore: skillStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        pmDelegationStore: delegationStore,
        analystCharterStore: charterStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )
    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerMessage = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "What skills did you ask the Technology Analyst to use?",
        source: .ui
    )

    _ = try await engine.generatePMConversationReply(to: ownerMessage.messageId, source: .ui)
    let request = try #require(await synthesisProvider.lastConversationRequest)
    let artifactContext = request.analystArtifactSummary.joined(separator: "\n")

    #expect(artifactContext.contains("AGENT_SKILL_REQUESTS_FOR_PM_ANALYST_TASKING"))
    #expect(artifactContext.contains("skillId=\(AgentSkillSeed.disconfirmingEvidenceChecklistID)"))
    #expect(artifactContext.contains("Disconfirming Evidence Checklist"))
    #expect(artifactContext.contains("skillId=\(AgentSkillSeed.longShortCandidatePressureTestID)"))
    #expect(artifactContext.contains("Long / Short Candidate Pressure Test"))
    #expect(artifactContext.contains("Role: app-owned selected Agent Skill references requested by PM conversation/delegation tasking"))
}

@Test("PM conversation latest-reviewed lane index renders every standing analyst lane with PM review chronology")
func pmConversationLatestReviewedLaneIndexRendersEveryStandingAnalystLaneWithPMReviewChronology() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-all-lane-latest-reviewed")
    let base = Date(timeIntervalSince1970: 1_777_860_000)
    let reportTimes = [base.addingTimeInterval(-2_000)]
        + StandingAnalystBenchSeed.definitions.enumerated().map { index, _ in
            base.addingTimeInterval(Double(index * 100))
        }
    let decisionTimes = [base.addingTimeInterval(-1_900)]
        + StandingAnalystBenchSeed.definitions.enumerated().map { index, _ in
            base.addingTimeInterval(Double(index * 100) + 12)
        }
    let reportClock = PMCommunicationLockedDateSequence(reportTimes)
    let decisionClock = PMCommunicationLockedDateSequence(decisionTimes)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let standingReportStore = AnalystStandingReportStore(
        reportsDirectory: root.appendingPathComponent("standing_reports", isDirectory: true),
        now: { reportClock.next() }
    )
    let decisionStore = PMDecisionStore(
        decisionsDirectory: root.appendingPathComponent("decisions", isDirectory: true),
        now: { decisionClock.next() }
    )
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "The latest reviewed Recent News Analyst report is the shipping-risk review.",
            resolution: PMConversationResolutionState(
                intentClass: .followUpQuestion,
                disposition: .conversationOnly
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Run the owner-facing PM desk.",
            createdAt: base,
            updatedAt: base
        )
    )

    let olderRecentNewsReport = AnalystStandingReport(
        reportId: "standing-report-recent-news-older-ai-capex-all-lane",
        deliveryStatus: .reviewedByPM,
        analystId: recentNewsStandingAnalystID,
        charterId: recentNewsStandingAnalystCharterID,
        scheduleId: "standing-report-\(recentNewsStandingAnalystID)",
        memoId: "memo-recent-news-older-ai-capex-all-lane",
        title: "Recent News Analyst: older AI capex report",
        summary: "Older Recent News content that must not answer the latest report question.",
        cadenceIntervalSec: standingAnalystReportDefaultIntervalSec,
        reportingWindowSummary: "Older recent-news window.",
        portfolioScopeSummary: "Recent-news overlay coverage.",
        headlineView: "AI capex was the older material signal.",
        portfolioRelevanceSummary: "Older Recent News context.",
        sections: [
            AnalystStandingReportSection(
                sectionId: "older-ai-capex",
                kind: .materialDevelopments,
                summary: "Older AI capex signal.",
                items: [
                    AnalystStandingReportItem(
                        itemId: "older-ai-capex-signal",
                        headline: "AI capex was the only older material signal.",
                        detail: "This stale AI capex item must not be used when a newer Recent News report exists."
                    )
                ]
            )
        ],
        deliveredToPMInboxAt: reportTimes[0],
        createdAt: reportTimes[0],
        updatedAt: reportTimes[0]
    )
    _ = try await standingReportStore.upsert(olderRecentNewsReport)
    _ = try await decisionStore.upsert(
        PMDecisionRecord(
            decisionId: "pm-decision-older-recent-news-ai-capex",
            pmId: "pm-1",
            title: "Standing review conclusion: older Recent News AI capex",
            summary: "Older PM review for stale Recent News report.",
            recommendedAction: "Keep older AI capex context archived.",
            charterId: recentNewsStandingAnalystCharterID,
            primaryStandingReportId: olderRecentNewsReport.reportId,
            standingReportIds: [olderRecentNewsReport.reportId],
            createdAt: decisionTimes[0],
            updatedAt: decisionTimes[0]
        )
    )

    var expectedRecentNewsDecisionAt: Date?
    var expectedTechnologyDecisionAt: Date?
    for (index, definition) in StandingAnalystBenchSeed.definitions.enumerated() {
        let reportAt = reportTimes[index + 1]
        let decisionAt = decisionTimes[index + 1]
        let isRecentNews = definition.charterId == recentNewsStandingAnalystCharterID
        let title = isRecentNews
            ? "Recent News Analyst: Shipping-risk headline confirmed as material; GameStop-eBay bid remains low-confidence"
            : "\(definition.title) Standing Report"
        let headline = isRecentNews
            ? "Shipping-risk headline confirmed as material; GameStop-eBay bid remains low-confidence."
            : "\(definition.title) latest reviewed lane signal."
        let detail = isRecentNews
            ? "The latest Recent News Analyst report says the shipping-risk headline is the material signal while the GameStop-eBay bid remains low-confidence."
            : "\(definition.title) bounded detail for latest report retrieval."
        let report = AnalystStandingReport(
            reportId: "standing-report-\(definition.charterId)-latest-reviewed",
            deliveryStatus: .reviewedByPM,
            analystId: definition.analystId,
            charterId: definition.charterId,
            scheduleId: "standing-report-\(definition.charterId)",
            memoId: "memo-\(definition.charterId)-latest-reviewed",
            title: title,
            summary: headline,
            cadenceIntervalSec: standingAnalystReportDefaultIntervalSec,
            reportingWindowSummary: "\(definition.title) review window.",
            portfolioScopeSummary: "\(definition.title) coverage.",
            headlineView: headline,
            portfolioRelevanceSummary: "\(definition.title) portfolio relevance.",
            sections: [
                AnalystStandingReportSection(
                    sectionId: "\(definition.charterId)-material",
                    kind: .materialDevelopments,
                    summary: headline,
                    items: [
                        AnalystStandingReportItem(
                            itemId: "\(definition.charterId)-material-signal",
                            headline: headline,
                            detail: detail
                        )
                    ]
                )
            ],
            deliveredToPMInboxAt: reportAt,
            createdAt: reportAt,
            updatedAt: reportAt
        )
        _ = try await standingReportStore.upsert(report)
        _ = try await decisionStore.upsert(
            PMDecisionRecord(
                decisionId: "pm-decision-\(definition.charterId)-latest-reviewed",
                pmId: "pm-1",
                title: "Standing review conclusion: \(definition.title)",
                summary: "\(definition.title) PM review completed.",
                recommendedAction: "\(definition.title) PM treatment remains background review.",
                charterId: definition.charterId,
                primaryStandingReportId: report.reportId,
                standingReportIds: [report.reportId],
                createdAt: decisionAt,
                updatedAt: decisionAt
            )
        )
        if isRecentNews {
            expectedRecentNewsDecisionAt = decisionAt
        }
        if definition.charterId == "bench-sector-technology" {
            expectedTechnologyDecisionAt = decisionAt
        }
    }

    let engine = Engine(
        pmProfileStore: profileStore,
        pmDecisionStore: decisionStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        analystStandingReportStore: standingReportStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerMessage = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "For the latest Recent News Analyst report, what was the material signal?",
        source: .ui
    )

    _ = try await engine.generatePMConversationReply(to: ownerMessage.messageId, source: .ui)
    let request = try #require(await synthesisProvider.lastConversationRequest)
    let laneIndex = request.analystArtifactSummary.joined(separator: "\n")
    let renderedPrompt = makePMConversationPromptText(from: request)
    let recentNewsDecisionAt = try #require(expectedRecentNewsDecisionAt)
    let technologyDecisionAt = try #require(expectedTechnologyDecisionAt)

    #expect(request.analystArtifactSummary.count >= 4)
    #expect(request.analystArtifactSummary.count <= 28)
    #expect(laneIndex.contains("Named analyst full-report retrieval")
        || laneIndex.contains("Open analyst-lane full-report retrieval"))
    #expect(laneIndex.contains("FULL_ANALYST_REPORT_DOCUMENT"))
    #expect(laneIndex.contains("FULL_REPORT_SECTION"))
    let firstReportContext = try #require(request.analystArtifactSummary.dropFirst().first)
    #expect(firstReportContext.hasPrefix("FULL_ANALYST_REPORT_DOCUMENT"))
    for definition in StandingAnalystBenchSeed.definitions {
        #expect(laneIndex.contains("\(definition.title): latest reviewed"))
        #expect(renderedPrompt.contains("\(definition.title): latest reviewed"))
    }
    #expect(laneIndex.contains(DateCodec.formatISO8601(recentNewsDecisionAt)))
    #expect(laneIndex.contains("PM review decision updatedAt"))
    #expect(laneIndex.contains("Shipping-risk headline confirmed as material"))
    #expect(laneIndex.contains("GameStop-eBay bid remains low-confidence"))
    #expect(laneIndex.contains(DateCodec.formatISO8601(technologyDecisionAt)))
    #expect(!laneIndex.contains("AI capex was the only older material signal"))
    #expect(renderedPrompt.contains("Recent News Analyst: latest reviewed"))
    #expect(renderedPrompt.contains("Shipping-risk headline confirmed as material"))
    #expect(renderedPrompt.contains("GameStop-eBay bid remains low-confidence"))
    #expect(!renderedPrompt.contains("AI capex was the only older material signal"))
}

@Test("Normal model-backed follow-ups keep deterministic recovery summaries out of the prompt while still surfacing relevant analyst artifacts")
func normalModelBackedFollowUpsKeepDeterministicRecoverySummariesOutOfPrompt() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-clean-model-grounding")
    let now = Date(timeIntervalSince1970: 1_746_000_210)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let standingReportStore = AnalystStandingReportStore(reportsDirectory: root.appendingPathComponent("standing_reports", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutputs: [
            PMConversationOpenAISynthesisOutput(
                replyBody: "I’m carrying your proposed paper portfolio forward as the current working definition, and the cleaner short-side follow-up names still look like NYCB and KSS.",
                actionPlan: PMConversationActionPlan(
                    summary: "Carry the owner-defined paper portfolio forward as conversation-owned working truth.",
                    actions: [
                        PMConversationActionIntent(
                            actionType: .updateConversationWorkingTruth,
                            summary: "Current proposed paper portfolio is long NVDA, TSM, AVGO, AMZN, CRWD, NFLX, GOOG, AAPL, and TSLA with NYCB and KSS short.",
                            body: "Long positions: NVDA, TSM, AVGO, AMZN, CRWD, NFLX, GOOG, AAPL, TSLA. Short positions: NYCB, KSS.",
                            operatingTruthKind: .workingPortfolioDefinition,
                            sourceMessageIds: []
                        )
                    ]
                ),
                resolution: PMConversationResolutionState(
                    intentClass: .followUpQuestion,
                    disposition: .workingUnderstandingOnly,
                    workingUnderstandingSummary: "Use the owner-defined paper portfolio as the current conversation-owned working definition.",
                    operatingTruthKind: .workingPortfolioDefinition,
                    operatingTruthSummary: "Current proposed paper portfolio is long NVDA, TSM, AVGO, AMZN, CRWD, NFLX, GOOG, AAPL, and TSLA with NYCB and KSS short.",
                    operatingTruthBody: "Long positions: NVDA, TSM, AVGO, AMZN, CRWD, NFLX, GOOG, AAPL, TSLA. Short positions: NYCB, KSS."
                )
            ),
            PMConversationOpenAISynthesisOutput(
                replyBody: "For the current short sleeve, NYCB is still the stronger direct downside case, while KSS reads as a lower-conviction pressure test with a weaker catalyst path.",
                resolution: PMConversationResolutionState(
                    intentClass: .followUpQuestion,
                    disposition: .conversationOnly
                )
            )
        ],
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Keeps model-backed PM grounding focused on the active conversation and relevant analyst artifacts.",
            createdAt: now,
            updatedAt: now
        )
    )

    let financialsReport = AnalystStandingReport(
        reportId: "standing-report-nycb-clean-grounding",
        analystId: "bench-sector-financials-analyst",
        charterId: "bench-sector-financials",
        scheduleId: "standing-report-bench-sector-financials",
        memoId: "memo-standing-report-nycb-clean-grounding",
        title: "Financials Analyst Standing Report",
        summary: "Regional-bank downside still matters for the short book.",
        cadenceIntervalSec: 12 * 3_600,
        reportingWindowSummary: "Past 12 hours",
        portfolioScopeSummary: "Financials coverage",
        headlineView: "NYCB remains the clearest direct short in the bank setup.",
        portfolioRelevanceSummary: "Short-side financials pressure remains more relevant than new longs here.",
        sections: [
            AnalystStandingReportSection(
                sectionId: "financials-short-ideas",
                kind: .shortIdeas,
                items: [
                    AnalystStandingReportItem(
                        itemId: "nycb-clean-grounding",
                        headline: "NYCB remains the clearer direct downside expression.",
                        detail: "Funding pressure and residual balance-sheet skepticism still make NYCB the cleaner short expression after the bounce.",
                        symbol: "NYCB",
                        stance: .short,
                        conviction: 8
                    )
                ]
            )
        ],
        deliveredToPMInboxAt: now,
        createdAt: now,
        updatedAt: now
    )
    let consumerReport = AnalystStandingReport(
        reportId: "standing-report-kss-clean-grounding",
        analystId: "bench-sector-consumer-analyst",
        charterId: "bench-sector-consumer",
        scheduleId: "standing-report-bench-sector-consumer",
        memoId: "memo-standing-report-kss-clean-grounding",
        title: "Consumer Analyst Standing Report",
        summary: "Department-store pressure remains a lower-conviction hedge topic.",
        cadenceIntervalSec: 12 * 3_600,
        reportingWindowSummary: "Past 12 hours",
        portfolioScopeSummary: "Consumer coverage",
        headlineView: "KSS remains a lower-conviction short pressure test.",
        portfolioRelevanceSummary: "Selective consumer shorts still matter more than broad new adds.",
        sections: [
            AnalystStandingReportSection(
                sectionId: "consumer-short-ideas",
                kind: .shortIdeas,
                items: [
                    AnalystStandingReportItem(
                        itemId: "kss-clean-grounding",
                        headline: "KSS remains a lower-conviction short pressure test.",
                        detail: "Traffic and margin pressure keep KSS in the hedge discussion, but the case is less direct and less urgent than NYCB.",
                        symbol: "KSS",
                        stance: .short,
                        conviction: 5
                    )
                ]
            )
        ],
        deliveredToPMInboxAt: now.addingTimeInterval(-60),
        createdAt: now.addingTimeInterval(-60),
        updatedAt: now.addingTimeInterval(-60)
    )
    _ = try await standingReportStore.upsert(financialsReport)
    _ = try await standingReportStore.upsert(consumerReport)

    let engine = Engine(
        pmProfileStore: profileStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        analystStandingReportStore: standingReportStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    _ = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .pm,
        senderId: "pm-1",
        body: "From our recent conversation, the latest proposed initial paper portfolio is a structure centered on the names referenced most directly being NYCB, NVDA, TSM, AVGO, AMZN, CRWD, NFLX, and GOOG.",
        source: .ui
    )

    let compoundTurn = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: """
        Here is my current proposed paper portfolio.

        Long positions: NVDA, TSM, AVGO, AMZN, CRWD, NFLX, GOOG, AAPL, TSLA
        Short positions: NYCB, KSS

        Based on the recent work, are there any short-side names we should still be discussing?
        """,
        source: .ui
    )
    _ = try await engine.generatePMConversationReply(to: compoundTurn.messageId, source: .ui)

    let followUp = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "For these short positions, how strong is the case and why?",
        source: .ui
    )
    let reply = try await engine.generatePMConversationReply(to: followUp.messageId, source: .ui)
    let request = try #require(await synthesisProvider.lastConversationRequest)

    #expect(request.ownerMessageBody.contains("how strong is the case and why"))
    #expect(request.workingPortfolioDefinitionSummary.contains(where: {
        $0.contains("NYCB") && $0.contains("KSS") && $0.contains("AAPL")
    }))
    #expect(request.analystArtifactSummary.contains(where: {
        $0.contains("NYCB") && $0.lowercased().contains("conviction 8/10")
    }))
    #expect(request.analystArtifactSummary.contains(where: {
        $0.contains("KSS") && $0.lowercased().contains("conviction 5/10")
    }))
    #expect(request.recentConversationSummary.contains(where: {
        $0.contains("structure centered on the names referenced most directly")
    }) == false)
    #expect(reply.runtimeProvenance?.conversationTrace?.pathKind == .modelBacked)
    #expect(reply.runtimeProvenance?.conversationTrace?.visibleReplySource == .modelReply)
    #expect(reply.runtimeProvenance?.conversationTrace?.usedAnalystArtifactGrounding == true)
    #expect(reply.body.contains("NYCB"))
    #expect(reply.body.contains("KSS"))
    #expect(reply.body.contains("From our recent conversation") == false)
}

@Test("Scripted model-backed PM conversation keeps the latest ask primary across working truth, follow-up reasoning, historical recall, correction, and action choice")
func scriptedModelBackedPMConversationKeepsLatestAskPrimaryAcrossCoreScenarios() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-scripted-e2e")
    let now = Date(timeIntervalSince1970: 1_746_000_260)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let charterStore = AnalystCharterStore(chartersDirectory: root.appendingPathComponent("charters", isDirectory: true))
    let delegationStore = PMDelegationStore(delegationsDirectory: root.appendingPathComponent("delegations", isDirectory: true))
    let taskStore = AnalystTaskStore(tasksDirectory: root.appendingPathComponent("tasks", isDirectory: true))
    let memoStore = AnalystMemoStore(memosDirectory: root.appendingPathComponent("memos", isDirectory: true))
    let standingReportStore = AnalystStandingReportStore(reportsDirectory: root.appendingPathComponent("standing_reports", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let launchRecorder = PMConversationActionPlanLaunchRecorder()
    let costcoMemo = AnalystMemo(
        memoId: "memo-costco-scripted-e2e",
        analystId: "bench-sector-consumer-analyst",
        charterId: "bench-sector-consumer",
        pmId: "pm-1",
        title: "Costco consumer check",
        executiveSummary: "Costco still looks like a resilient, membership-driven compounder, but I would treat it as a candidate add rather than a rush trade after the recovery bounce.",
        currentView: "Traffic resilience and renewal strength still support the long thesis, while valuation now requires cleaner margin follow-through.",
        evidenceSummary: "Recent channel checks stayed constructive, renewal data held firm, and management execution remains ahead of most large-format retail peers.",
        uncertaintySummary: "The main open question is how much upside is already reflected after the market recovery and whether discretionary basket pressure shows up in the next quarter.",
        recommendedNextStep: "Keep Costco on the add shortlist, but require one more valuation-and-traffic check before turning it into a formal portfolio change recommendation.",
        confidence: 0.73,
        createdAt: now,
        updatedAt: now
    )
    _ = try await memoStore.upsert(costcoMemo)
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutputs: [
            PMConversationOpenAISynthesisOutput(
                replyBody: "I’m carrying your proposed paper portfolio forward as the current working definition. From the recent analyst work, NYCB stays the active short while KSS remains the cleaner secondary short discussion name.",
                actionPlan: PMConversationActionPlan(
                    summary: "Carry the owner-defined paper portfolio forward as conversation-owned working truth.",
                    actions: [
                        PMConversationActionIntent(
                            actionType: .updateConversationWorkingTruth,
                            summary: "Current proposed paper portfolio is long NVDA, TSM, AVGO, AMZN, CRWD, NFLX, GOOG, AAPL, and TSLA with NYCB and KSS short.",
                            body: "Long positions: NVDA, TSM, AVGO, AMZN, CRWD, NFLX, GOOG, AAPL, TSLA. Short positions: NYCB, KSS.",
                            operatingTruthKind: .workingPortfolioDefinition,
                            sourceMessageIds: []
                        )
                    ]
                ),
                resolution: PMConversationResolutionState(
                    intentClass: .followUpQuestion,
                    disposition: .workingUnderstandingOnly,
                    workingUnderstandingSummary: "Use the owner-defined paper portfolio as the current conversation-owned working definition.",
                    operatingTruthKind: .workingPortfolioDefinition,
                    operatingTruthSummary: "Current proposed paper portfolio is long NVDA, TSM, AVGO, AMZN, CRWD, NFLX, GOOG, AAPL, and TSLA with NYCB and KSS short.",
                    operatingTruthBody: "Long positions: NVDA, TSM, AVGO, AMZN, CRWD, NFLX, GOOG, AAPL, TSLA. Short positions: NYCB, KSS."
                )
            ),
            PMConversationOpenAISynthesisOutput(
                replyBody: "For the short sleeve, NYCB still has the stronger direct downside case, while KSS remains lower-conviction and more balance-sheet sensitive.",
                resolution: PMConversationResolutionState(
                    intentClass: .followUpQuestion,
                    disposition: .conversationOnly
                )
            ),
            PMConversationOpenAISynthesisOutput(
                replyBody: "Earlier this week, the previous proposed paper portfolio in our conversation was long MSFT and AMD with NYCB as the single short.",
                resolution: PMConversationResolutionState(
                    intentClass: .followUpQuestion,
                    disposition: .conversationOnly
                )
            ),
            PMConversationOpenAISynthesisOutput(
                replyBody: "Understood. I’m updating the working paper portfolio so COST replaces TSLA while keeping NYCB and KSS on the short side.",
                actionPlan: PMConversationActionPlan(
                    summary: "Update the conversation-owned working portfolio definition with the latest owner correction.",
                    actions: [
                        PMConversationActionIntent(
                            actionType: .updateConversationWorkingTruth,
                            summary: "Current proposed paper portfolio is long NVDA, TSM, AVGO, AMZN, CRWD, NFLX, GOOG, AAPL, and COST with NYCB and KSS short.",
                            body: "Long positions: NVDA, TSM, AVGO, AMZN, CRWD, NFLX, GOOG, AAPL, COST. Short positions: NYCB, KSS.",
                            operatingTruthKind: .workingPortfolioDefinition,
                            sourceMessageIds: []
                        )
                    ]
                ),
                resolution: PMConversationResolutionState(
                    intentClass: .correction,
                    disposition: .workingUnderstandingOnly,
                    workingUnderstandingSummary: "Update the current working paper portfolio so COST replaces TSLA.",
                    operatingTruthKind: .workingPortfolioDefinition,
                    operatingTruthSummary: "Current proposed paper portfolio is long NVDA, TSM, AVGO, AMZN, CRWD, NFLX, GOOG, AAPL, and COST with NYCB and KSS short.",
                    operatingTruthBody: "Long positions: NVDA, TSM, AVGO, AMZN, CRWD, NFLX, GOOG, AAPL, COST. Short positions: NYCB, KSS."
                )
            ),
            PMConversationOpenAISynthesisOutput(
                replyBody: "I’m launching Consumer Analyst work on Costco now and I’ll follow up once the memo is back.",
                actionPlan: PMConversationActionPlan(
                    summary: "Launch one bounded Costco analyst follow-up and then close the loop in conversation.",
                    actions: [
                        PMConversationActionIntent(
                            actionType: .launchAdHocAnalystDelegation,
                            summary: "Ask the consumer analyst to evaluate Costco as a possible portfolio addition after the recent recovery.",
                            title: "Review Costco as a possible portfolio addition",
                            body: "Pressure-test the current Costco long thesis, including resilience, valuation, and whether the latest recovery changes the entry quality.",
                            detail: "Return a bounded memo with a clear PM-ready conclusion on whether Costco belongs on the near-term add shortlist.",
                            charterId: "Consumer Analyst",
                            requestedOutputs: [.finding],
                            sourceMessageIds: []
                        )
                    ]
                ),
                resolution: PMConversationResolutionState(
                    intentClass: .followUpQuestion,
                    disposition: .conversationOnly
                )
            ),
            PMConversationOpenAISynthesisOutput(
                replyBody: "My PM read from the Consumer Analyst memo: Costco still looks like a resilient, membership-driven compounder, but it belongs on the add shortlist rather than being rushed after the recovery bounce. The full memo is in PM Inbox / Recent Analyst Activity.",
                actionPlan: PMConversationActionPlan(
                    summary: "Synthesize completed analyst task for owner follow-through.",
                    actions: [
                        PMConversationActionIntent(
                            actionType: .answerOnly,
                            summary: "Delivered PM-synthesized Costco analyst follow-through."
                        )
                    ]
                )
            )
        ],
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Keeps the latest owner ask primary across normal PM/User conversation.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await charterStore.upsert(
        AnalystCharter(
            charterId: "bench-sector-consumer",
            analystId: "bench-sector-consumer-analyst",
            title: "Consumer Analyst",
            coverageScope: "US consumer and retail",
            strategyFamily: "Long/Short Equity",
            summary: "Consumer coverage",
            updatedBy: "owner",
            updateSource: .userEdited,
            createdAt: now,
            updatedAt: now
        )
    )
    let earlierSession = PMCommunicationSession(
        sessionId: "session-scripted-e2e-earlier",
        channel: .inApp,
        pmId: "pm-1",
        participantId: "owner",
        participantDisplayName: "Owner",
        status: .closed,
        createdAt: now.addingTimeInterval(-(5 * 24 * 60 * 60)),
        updatedAt: now.addingTimeInterval(-(5 * 24 * 60 * 60))
    )
    _ = try await sessionStore.upsert(earlierSession)
    _ = try await messageStore.upsert(
        PMCommunicationMessage(
            messageId: "scripted-e2e-earlier-owner",
            sessionId: earlierSession.sessionId,
            direction: .incoming,
            senderRole: .owner,
            senderId: "owner",
            body: "For the earlier paper portfolio, keep MSFT and AMD long with NYCB as the single short.",
            sentAt: now.addingTimeInterval(-(5 * 24 * 60 * 60) + 60),
            createdAt: now.addingTimeInterval(-(5 * 24 * 60 * 60) + 60),
            updatedAt: now.addingTimeInterval(-(5 * 24 * 60 * 60) + 60)
        )
    )
    _ = try await messageStore.upsert(
        PMCommunicationMessage(
            messageId: "scripted-e2e-earlier-pm",
            sessionId: earlierSession.sessionId,
            direction: .outgoing,
            senderRole: .pm,
            senderId: "pm-1",
            body: "Understood. The previous proposed paper portfolio was long MSFT and AMD with NYCB on the short side.",
            sentAt: now.addingTimeInterval(-(5 * 24 * 60 * 60) + 120),
            replyToMessageId: "scripted-e2e-earlier-owner",
            createdAt: now.addingTimeInterval(-(5 * 24 * 60 * 60) + 120),
            updatedAt: now.addingTimeInterval(-(5 * 24 * 60 * 60) + 120)
        )
    )
    let nycbReport = AnalystStandingReport(
        reportId: "standing-report-scripted-e2e-nycb",
        analystId: "bench-sector-financials-analyst",
        charterId: "bench-sector-financials",
        scheduleId: "standing-report-bench-sector-financials",
        memoId: "memo-standing-report-scripted-e2e-nycb",
        title: "Financials Analyst Standing Report",
        summary: "Regional-bank downside still matters for the short book.",
        cadenceIntervalSec: 12 * 3_600,
        reportingWindowSummary: "Past 12 hours",
        portfolioScopeSummary: "Financials coverage",
        headlineView: "NYCB remains the clearest direct short in the bank setup.",
        portfolioRelevanceSummary: "Short-side financials pressure remains relevant.",
        sections: [
            AnalystStandingReportSection(
                sectionId: "financials-short-ideas",
                kind: .shortIdeas,
                items: [
                    AnalystStandingReportItem(
                        itemId: "scripted-e2e-nycb",
                        headline: "NYCB remains the clearer direct downside expression.",
                        detail: "Funding pressure and residual balance-sheet skepticism still make NYCB the cleaner short expression after the bounce.",
                        symbol: "NYCB",
                        stance: .short,
                        conviction: 8
                    )
                ]
            )
        ],
        deliveredToPMInboxAt: now,
        createdAt: now,
        updatedAt: now
    )
    let kssReport = AnalystStandingReport(
        reportId: "standing-report-scripted-e2e-kss",
        analystId: "bench-sector-consumer-analyst",
        charterId: "bench-sector-consumer",
        scheduleId: "standing-report-bench-sector-consumer",
        memoId: "memo-standing-report-scripted-e2e-kss",
        title: "Consumer Analyst Standing Report",
        summary: "Department-store pressure remains a lower-conviction hedge topic.",
        cadenceIntervalSec: 12 * 3_600,
        reportingWindowSummary: "Past 12 hours",
        portfolioScopeSummary: "Consumer coverage",
        headlineView: "KSS remains a lower-conviction short pressure test.",
        portfolioRelevanceSummary: "Selective consumer shorts still matter more than broad new adds.",
        sections: [
            AnalystStandingReportSection(
                sectionId: "consumer-short-ideas",
                kind: .shortIdeas,
                items: [
                    AnalystStandingReportItem(
                        itemId: "scripted-e2e-kss",
                        headline: "KSS remains a lower-conviction short pressure test.",
                        detail: "Traffic and margin pressure keep KSS in the hedge discussion, but the case is less direct and less urgent than NYCB.",
                        symbol: "KSS",
                        stance: .short,
                        conviction: 5
                    )
                ]
            )
        ],
        deliveredToPMInboxAt: now.addingTimeInterval(-60),
        createdAt: now.addingTimeInterval(-60),
        updatedAt: now.addingTimeInterval(-60)
    )
    _ = try await standingReportStore.upsert(nycbReport)
    _ = try await standingReportStore.upsert(kssReport)

    let engine = Engine(
        pmProfileStore: profileStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        pmDelegationStore: delegationStore,
        analystCharterStore: charterStore,
        analystTaskStore: taskStore,
        analystMemoStore: memoStore,
        analystStandingReportStore: standingReportStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider,
        analystWorkerLauncher: PMConversationActionPlanStubLauncher(
            recorder: launchRecorder,
            result: AnalystWorkerLaunchResult(
                openAIKeyConfigured: true,
                usedOpenAI: false,
                charterId: "bench-sector-consumer",
                taskId: nil,
                delegationId: nil,
                pmId: "pm-1",
                memoId: costcoMemo.memoId,
                memoTitle: costcoMemo.title,
                findingId: nil,
                findingTitle: nil,
                draftedSignalId: nil,
                draftedProposalId: nil,
                summary: "Consumer Analyst memo completed on Costco.",
                outputExcerpt: costcoMemo.executiveSummary
            )
        )
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let initialAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: """
        Here is my current proposed paper portfolio.

        Long positions: NVDA, TSM, AVGO, AMZN, CRWD, NFLX, GOOG, AAPL, TSLA
        Short positions: NYCB, KSS

        Based on the recent analyst work, are there any short-side names we should still be discussing?
        """,
        source: .ui
    )
    let firstReply = try await engine.generatePMConversationReply(to: initialAsk.messageId, source: .ui)

    let followUpAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "For the short sleeve, how strong is the case and why for NYCB and KSS?",
        source: .ui
    )
    let secondReply = try await engine.generatePMConversationReply(to: followUpAsk.messageId, source: .ui)

    let recallAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Earlier this week, what was the previous proposed paper portfolio before this latest version?",
        source: .ui
    )
    let thirdReply = try await engine.generatePMConversationReply(to: recallAsk.messageId, source: .ui)

    let correctionAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Correction: replace TSLA with COST in that working paper portfolio and keep the rest the same.",
        source: .ui
    )
    let fourthReply = try await engine.generatePMConversationReply(to: correctionAsk.messageId, source: .ui)

    let actionAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "What do you think about adding Costco to our portfolio?",
        source: .ui
    )
    let fifthReply = try await engine.generatePMConversationReply(to: actionAsk.messageId, source: .ui)

    let requests = await synthesisProvider.conversationRequests
    #expect(requests.count == 6)
    let firstRequest = try #require(requests.first)
    let secondRequest = requests[1]
    let thirdRequest = requests[2]
    let fourthRequest = requests[3]
    let fifthRequest = requests[4]
    let followThroughRequest = requests[5]
    let launchRequest = try #require(await launchRecorder.lastRequest)
    let messages = try await engine.listPMCommunicationMessages()
        .filter { $0.sessionId == session.sessionId }
        .sorted { lhs, rhs in
            if lhs.sentAt == rhs.sentAt {
                return lhs.messageId < rhs.messageId
            }
            return lhs.sentAt < rhs.sentAt
        }
    let followThrough = try #require(messages.last)

    #expect(firstReply.body.contains("NYCB"))
    #expect(firstReply.body.contains("KSS"))
    #expect(firstRequest.latestOwnerWorkingPortfolioUpdateSummary.isEmpty)
    #expect(firstRequest.ownerMessageBody.contains("TSLA"))
    #expect(firstRequest.ownerMessageBody.contains("NYCB"))
    #expect(firstRequest.recoveredContextSummary.isEmpty)
    #expect(firstReply.runtimeProvenance?.conversationTrace?.pathKind == .modelBacked)
    #expect(firstReply.runtimeProvenance?.conversationTrace?.visibleReplySource == .modelReply)

    #expect(secondReply.body.contains("NYCB"))
    #expect(secondReply.body.contains("KSS"))
    #expect(secondReply.body.contains("From our recent conversation") == false)
    #expect(secondRequest.workingPortfolioDefinitionSummary.contains(where: { $0.contains("TSLA") && $0.contains("KSS") }))
    #expect(secondRequest.analystArtifactSummary.contains(where: { $0.lowercased().contains("conviction 8/10") }))
    #expect(secondReply.runtimeProvenance?.conversationTrace?.pathKind == .modelBacked)
    #expect(secondReply.runtimeProvenance?.conversationTrace?.usedAnalystArtifactGrounding == true)

    #expect(thirdReply.body.contains("MSFT"))
    #expect(thirdReply.body.contains("AMD"))
    #expect(thirdRequest.detailedCommunicationHistorySummary.isEmpty == false)
    #expect(thirdReply.runtimeProvenance?.conversationTrace?.usedDetailedHistoryGrounding == true)

    #expect(fourthReply.body.contains("COST"))
    #expect(fourthReply.body.contains("From our recent conversation") == false)
    #expect(fourthRequest.latestOwnerWorkingPortfolioUpdateSummary.isEmpty)
    #expect(fourthRequest.ownerMessageBody.contains("replace TSLA with COST"))
    #expect(fourthReply.runtimeProvenance?.conversationTrace?.usedLatestOwnerWorkingPortfolioGrounding == false)

    #expect(fifthReply.body.contains("launching Consumer Analyst work on Costco"))
    #expect(fifthRequest.ownerMessageBody.contains("adding Costco"))
    #expect(fifthReply.runtimeProvenance?.conversationTrace?.actionPlanSource == .modelActionPlan)
    #expect(launchRequest.charterId == "bench-sector-consumer")
    #expect(followThrough.replyToMessageId == fifthReply.messageId)
    #expect(followThrough.body.contains("Costco still looks like a resilient, membership-driven compounder"))
    #expect(followThrough.body.contains("full memo is in PM Inbox"))
    #expect(followThroughRequest.plannerMode == "analyst_follow_through_synthesis")
    #expect(followThroughRequest.ownerMessageBody.contains("context for your reasoning"))
    #expect(followThroughRequest.ownerMessageBody.contains("not a deterministic script"))
    #expect(followThroughRequest.ownerMessageBody.contains("content block to paste"))
}

@Test("Runtime-failure fallback does not procedurally restate the latest owner portfolio update")
func fallbackObeysLatestOwnerSuppliedPortfolioUpdateInsteadOfRepeatingStaleRecoveredContext() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-last-turn-dominates-fallback")
    let now = Date(timeIntervalSince1970: 1_744_000_200)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Uses the latest owner-supplied portfolio list directly when model synthesis is unavailable.",
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: false, value: nil)
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    _ = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .pm,
        senderId: "pm-1",
        body: "From our recent conversation, the latest proposed initial paper portfolio is a structure centered on the names referenced most directly being NYCB, NVDA, TSM, AVGO, AMZN, CRWD, NFLX, and GOOG, the previously discussed short leg dropped from the latest version.",
        source: .ui
    )

    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: """
        Here is the current proposed paper portfolio.

        Long positions: NVDA, TSM, AVGO, AMZN, CRWD, NFLX, GOOG, AAPL, TSLA
        Short positions: NYCB

        There was a big recovery in the market this week, and so from your review of the recent analysts reports were there any high conviction suggestions for long and short positions that we should be discussing?
        """,
        source: .ui
    )
    let reply = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)

    #expect(reply.body.contains("I couldn't complete a PM answer because the PM runtime failed:"))
    #expect(reply.body.contains("AAPL") == false)
    #expect(reply.body.contains("TSLA") == false)
    #expect(reply.body.contains("NYCB") == false)
    #expect(reply.body.contains("previously discussed short leg dropped") == false)
    #expect(reply.body.contains("structure centered on the names referenced most directly") == false)
    #expect(reply.conversationResolution == nil)
    #expect(reply.conversationActionPlan == nil)
}

@Test("Runtime-failure fallback does not try to answer analyst follow-ups procedurally")
func fallbackHandlesInsufficientAnalystDetailNaturallyInsteadOfRevertingToStalePortfolioRecall() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-analyst-fallback-insufficient-detail")
    let now = Date(timeIntervalSince1970: 1_744_000_210)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Keeps fallback PM replies natural when analyst detail is thin.",
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: false, value: nil)
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    _ = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: """
        Here is the current proposed paper portfolio.

        Long positions: NVDA, TSM, AVGO, AMZN, CRWD, NFLX, GOOG, AAPL, TSLA
        Short positions: NYCB, KSS
        """,
        source: .ui
    )
    _ = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .pm,
        senderId: "pm-1",
        body: "From our recent conversation, the latest proposed initial paper portfolio is a structure centered on the names referenced most directly being NYCB, NVDA, TSM, AVGO, AMZN, CRWD, NFLX, and GOOG, the previously discussed short leg dropped from the latest version.",
        source: .ui
    )

    let followUp = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "For the analyst covering these positions what are their conviction levels and reasoning?",
        source: .ui
    )
    let reply = try await engine.generatePMConversationReply(to: followUp.messageId, source: .ui)

    #expect(reply.body.contains("I couldn't complete a PM answer because the PM runtime failed:"))
    #expect(reply.body.contains("Long positions: NVDA") == false)
    #expect(reply.body.contains("Short positions: NYCB, KSS") == false)
    #expect(reply.body.contains("latest proposed initial paper portfolio") == false)
    #expect(reply.body.contains("structure centered on the names referenced most directly") == false)
    #expect(reply.runtimeProvenance?.conversationTrace?.pathKind == .degradedFallback)
    #expect(reply.runtimeProvenance?.conversationTrace?.visibleReplySource == .deterministicFallback)
    #expect(reply.runtimeProvenance?.conversationTrace?.fallbackTrigger == .credentialUnavailable)
    #expect(reply.conversationResolution == nil)
    #expect(reply.conversationActionPlan == nil)
}

@Test("Runtime-failure fallback does not reconstruct working portfolios from recent conversation")
func fallbackWorkingPortfolioRepliesCanReconstructRecentConversationWithoutInstruction() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-working-portfolio-legacy-reconstruction")
    let now = Date(timeIntervalSince1970: 1_742_000_028.75)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Can reconstruct recent conversation-defined paper portfolios without a stored instruction.",
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: false, value: nil)
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    _ = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "For the initial paper portfolio, add ETFN and ISRG, keep 12 names in the long sleeve, and reserve capital for the hedge sleeve inside an 80% gross / $80K deployed framework.",
        source: .ui
    )
    _ = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .pm,
        senderId: "pm-1",
        body: "Understood. I will treat that as the latest proposed paper-portfolio structure while we keep holdings truth separate.",
        source: .ui
    )

    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "List the proposed initial paper portfolio from our recent communications over the last week.",
        source: .ui
    )
    let reply = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)

    #expect(reply.body.contains("I couldn't complete a PM answer because the PM runtime failed:"))
    #expect(reply.body.contains("ETFN") == false)
    #expect(reply.body.contains("ISRG") == false)
    #expect(reply.body.contains("12 names") == false)
    #expect(reply.body.contains("Here is the strongest earlier context I found") == false)
    #expect(reply.body.contains("bounded working-definition path") == false)
    #expect(reply.conversationResolution == nil)
    #expect(reply.conversationActionPlan == nil)
}

@Test("Runtime-failure fallback does not bind yes/no open loops into procedural reconstruction")
func yesReconstructFromConversationThreadBindsToWorkingPortfolioOpenLoop() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-working-portfolio-reconstruct-open-loop")
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))

    let engine = Engine(
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: false, value: nil)
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession()
    _ = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "For the initial paper portfolio, keep NYCB and MSFT on the list and hold a cash buffer.",
        source: .ui
    )
    _ = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .pm,
        senderId: "pm-primary",
        body: "I do not have a clean recent paper-portfolio definition to quote back yet. If you want, I can reconstruct the latest proposed paper-portfolio structure from our recent conversation and carry that forward as the current working version.",
        conversationResolution: PMConversationResolutionState(
            intentClass: .followUpQuestion,
            disposition: .clarificationRequired,
            pendingAsk: PMConversationPendingAskState(
                kind: .yesNoConfirmation,
                promptSummary: "Reconstruct the latest proposed paper-portfolio structure from our recent conversation and carry that forward as the current working version?",
                workingUnderstandingSummary: "Reconstruct the latest proposed initial paper portfolio from the recent conversation.",
                operatingTruthKind: .workingPortfolioDefinition,
                operatingTruthSummary: "Reconstruct the latest proposed initial paper portfolio from the recent conversation."
            ),
            sourceMessageIds: []
        ),
        source: .ui
    )

    let ownerReply = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Yes, reconstruct from our conversation thread.",
        source: .ui
    )
    let pmReply = try await engine.generatePMConversationReply(to: ownerReply.messageId, source: .ui)

    #expect(pmReply.body.contains("I couldn't complete a PM answer because the PM runtime failed:"))
    #expect(pmReply.body.contains("NYCB") == false)
    #expect(pmReply.body.contains("MSFT") == false)
    #expect(pmReply.body.contains("Here is the strongest earlier context I found") == false)
    #expect(pmReply.body.contains("bounded continuity") == false)
    #expect(pmReply.conversationResolution == nil)
    #expect(pmReply.conversationActionPlan == nil)
}

@Test("OpenAI conversation fallback after provider error is minimal and traceable")
func openAIConversationFallbackAfterProviderErrorStaysOwnerReadable() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-openai-error-fallback")
    let now = Date(timeIntervalSince1970: 1_742_000_029)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let strategyBriefStore = PortfolioStrategyBriefStore(fileURL: root.appendingPathComponent("portfolio_strategy_brief.json", isDirectory: false))

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Uses the model when available and a readable fallback when it is not.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await strategyBriefStore.upsert(
        PortfolioStrategyBrief(
            objectiveSummary: "Stay constructive while keeping earnings risk visible.",
            keyThemes: ["AI infrastructure", "earnings discipline"],
            currentRiskPosture: "Constructive with tighter earnings review.",
            reviewEscalationPosture: "Escalate only material posture changes.",
            updatedBy: "owner",
            updateSource: .userEdited,
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        portfolioStrategyBriefStore: strategyBriefStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: ThrowingPMOpenAISynthesisProvider()
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "How should I think about the current strategy and earnings risk?",
        source: .ui
    )
    let reply = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)

    #expect(reply.body.contains("I couldn't complete a PM answer because the PM runtime failed:"))
    #expect(reply.body.contains("could not reach the model provider"))
    #expect(reply.body.contains("Retry in a moment once the PM runtime is available again."))
    #expect(reply.body.contains("Relevant prior PM context I recovered") == false)
    #expect(reply.body.contains("I’m grounding this on the current objective") == false)
    #expect(reply.body.contains("The most relevant prior context I found") == false)
    #expect(reply.body.contains("If you want, I can go one layer deeper") == false)
    #expect(reply.runtimeProvenance?.usedOpenAI == false)
    #expect(reply.runtimeProvenance?.synthesisStatus == "fallback_openai_error")
    #expect(reply.runtimeProvenance?.conversationTrace?.pathKind == .degradedFallback)
    #expect(reply.runtimeProvenance?.conversationTrace?.visibleReplySource == .deterministicFallback)
    #expect(reply.runtimeProvenance?.conversationTrace?.fallbackTrigger == .networkFailure)
    #expect(reply.runtimeProvenance?.conversationTrace?.fallbackTriggerWasAllowedRuntimeFailure == true)
    #expect(reply.runtimeProvenance?.conversationTrace?.modelSynthesisAttempted == true)
    #expect(reply.runtimeProvenance?.conversationTrace?.modelProducedUsableReply == false)
    #expect(reply.runtimeProvenance?.conversationTrace?.visibleReplyModifiedAfterSynthesis == false)
    #expect(reply.conversationResolution == nil)
    #expect(reply.conversationActionPlan == nil)
}

@Test("Model-backed PM uncertainty stays on the model path instead of triggering deterministic fallback")
func modelBackedPMUncertaintyDoesNotTriggerFallback() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-model-uncertainty")
    let now = Date(timeIntervalSince1970: 1_744_000_220)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "I do not yet have enough clean analyst evidence on NYCB and KSS to give a conviction ranking. If you want, I can launch a tighter follow-up review on the short sleeve next."
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Keeps uncertainty on the model-backed PM path.",
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Regarding the proposed short positions for the paper portfolio, what are the conviction levels and reasoning for NYCB and KSS?",
        source: .ui
    )
    let reply = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)

    #expect(reply.body.contains("do not yet have enough clean analyst evidence"))
    #expect(reply.runtimeProvenance?.conversationTrace?.pathKind == .modelBacked)
    #expect(reply.runtimeProvenance?.conversationTrace?.visibleReplySource == .modelReply)
    #expect(reply.runtimeProvenance?.conversationTrace?.fallbackTrigger == nil)
    #expect(reply.runtimeProvenance?.conversationTrace?.modelSynthesisAttempted == true)
    #expect(reply.runtimeProvenance?.conversationTrace?.modelProducedUsableReply == true)
    #expect(reply.conversationResolution?.disposition != .durableApplyNow)
}

@Test("Owner asks seed a real primary PM identity instead of reusing the exercise PM profile")
func ownerAskSeedsPrimaryPMIdentityForConversationReplies() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-primary-pm-seed")
    let now = Date(timeIntervalSince1970: 1_742_000_026)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: PMProfile.operationalExercisePMID,
            displayName: "Operational Exercise PM",
            roleSummary: "Exercise-only PM identity.",
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession()
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Give me a concise PM view on the current setup.",
        source: .ui
    )
    let reply = try await engine.generatePMConversationReply(
        to: ownerAsk.messageId,
        source: .ui
    )
    let profiles = try await engine.listPMProfiles()

    #expect(session.pmId == PMProfile.primaryPMID)
    #expect(session.sessionId == "pm-user-in-app-\(PMProfile.primaryPMID)")
    #expect(reply.senderId == PMProfile.primaryPMID)
    #expect(profiles.contains(where: { $0.pmId == PMProfile.primaryPMID }))
    #expect(profiles.contains(where: { $0.pmId == PMProfile.operationalExercisePMID }))
}

@Test("Owner asks do not stop at recorded message only and duplicate PM replies stay blocked")
func ownerAskDoesNotStopAtRecordedMessageOnlyAndDuplicateRepliesStayBlocked() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-no-duplicate-reply")
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let engine = Engine(
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Give me a concise PM view on the current setup.",
        source: .ui
    )

    _ = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)

    await #expect(throws: PMConversationReplyGenerationError.replyAlreadyExists(messageId: ownerAsk.messageId)) {
        _ = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)
    }

    let messages = try await engine.listPMCommunicationMessages()
        .filter { $0.sessionId == session.sessionId }
    #expect(messages.count == 2)
    #expect(messages.contains { $0.senderRole == .owner })
    #expect(messages.contains { $0.senderRole == .pm })
}

@Test("Later in-app PM conversation turns answer the newest ask instead of repeating the first brief-review reply")
func laterInAppPMConversationTurnsAdvanceOnLatestAsk() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-multi-turn-latest-ask")
    let now = Date(timeIntervalSince1970: 1_742_000_026)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let strategyBriefStore = PortfolioStrategyBriefStore(fileURL: root.appendingPathComponent("portfolio_strategy_brief.json", isDirectory: false))

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Runs PM/User communication.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await strategyBriefStore.upsert(
        PortfolioStrategyBrief(
            title: "Current Portfolio Strategy Brief",
            documentBody: """
            ## Objective
            Keep the portfolio concentrated in high-conviction names while tightening downside review.

            ## Key Themes
            - concentration discipline
            - catalyst-aware sizing

            ## Current Risk Posture
            Constructive, but less tolerant of thesis drift.

            ## Review Posture
            Escalate meaningful posture changes quickly.
            """,
            objectiveSummary: "Keep the portfolio concentrated in high-conviction names while tightening downside review.",
            keyThemes: ["concentration discipline", "catalyst-aware sizing"],
            currentRiskPosture: "Constructive, but less tolerant of thesis drift.",
            reviewEscalationPosture: "Escalate meaningful posture changes quickly.",
            updatedBy: "owner",
            updateSource: .userEdited,
            createdAt: now,
            updatedAt: now
        )
    )
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutputs: [
            PMConversationOpenAISynthesisOutput(
                replyBody: "Before I would revise it, I would tighten these points: make the catalyst discipline explicit, define when a posture change becomes owner-facing, and make the escalation thresholds more concrete.",
                resolution: PMConversationResolutionState(
                    intentClass: .general,
                    disposition: .conversationOnly
                )
            ),
            PMConversationOpenAISynthesisOutput(
                replyBody: "Suggested Portfolio Strategy Brief revision note: clarify the catalyst-aware sizing rules, define what counts as thesis drift, and note that the saved Strategy Brief stays unchanged until you approve edits.",
                resolution: PMConversationResolutionState(
                    intentClass: .instruction,
                    disposition: .conversationOnly
                )
            ),
            PMConversationOpenAISynthesisOutput(
                replyBody: "For the Consumer Analyst Charter, Highest-priority changes: tighten the distinction between long candidate refreshes and hedge candidates, clarify cadence expectations, and make the escalation language more explicit.",
                resolution: PMConversationResolutionState(
                    intentClass: .general,
                    disposition: .conversationOnly
                )
            )
        ],
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        portfolioStrategyBriefStore: strategyBriefStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")

    let firstAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Please read the Portfolio Strategy Brief and give me your questions and comments.",
        source: .ui
    )
    let firstReply = try await engine.generatePMConversationReply(to: firstAsk.messageId, source: .ui)

    let secondAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Prepare a revision note.",
        source: .ui
    )
    let secondReply = try await engine.generatePMConversationReply(to: secondAsk.messageId, source: .ui)

    let thirdAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Can you read the Consumer Analyst Charter and provide suggested changes?",
        source: .ui
    )
    let thirdReply = try await engine.generatePMConversationReply(to: thirdAsk.messageId, source: .ui)

    #expect(firstReply.replyToMessageId == firstAsk.messageId)
    #expect(firstReply.body.contains("Before I would revise it, I would tighten these points:"))

    #expect(secondReply.replyToMessageId == secondAsk.messageId)
    #expect(secondReply.body.contains("Suggested Portfolio Strategy Brief revision note:"))
    #expect(secondReply.body.contains("saved Strategy Brief stays unchanged"))
    #expect(secondReply.body != firstReply.body)

    #expect(thirdReply.replyToMessageId == thirdAsk.messageId)
    #expect(thirdReply.body.contains("Consumer Analyst Charter"))
    #expect(thirdReply.body.contains("Highest-priority changes:"))
    #expect(thirdReply.body.contains("I am grounding this reply on your latest turn") == false)
    #expect(thirdReply.body.contains("Before I would revise it, I would tighten these points:") == false)
    #expect(thirdReply.body != secondReply.body)
}

@Test("PM conversation replies can explain analyst bench structure and standing review queue from app-owned operating context")
func pmConversationRepliesUseOperatingContextForBenchAndQueueQuestions() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-operating-context")
    let now = Date(timeIntervalSince1970: 1_742_000_028)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let strategyBriefStore = PortfolioStrategyBriefStore(fileURL: root.appendingPathComponent("portfolio_strategy_brief.json", isDirectory: false))
    let charterStore = AnalystCharterStore(chartersDirectory: root.appendingPathComponent("charters", isDirectory: true))
    let standingReportStore = AnalystStandingReportStore(reportsDirectory: root.appendingPathComponent("standing_reports", isDirectory: true))
    let scheduleStore = ScheduleStore(fileURL: root.appendingPathComponent("schedules.json", isDirectory: false))

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Runs PM/User communication.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await strategyBriefStore.upsert(
        PortfolioStrategyBrief(
            title: "Current Portfolio Strategy Brief",
            documentBody: """
            ## Objective
            Keep the PM grounded on the current analyst bench and review queue.
            """,
            objectiveSummary: "Keep the PM grounded on the current analyst bench and review queue.",
            keyThemes: ["analyst bench", "review queue"],
            currentRiskPosture: "Moderate",
            reviewEscalationPosture: "Escalate material changes to PM review.",
            updatedBy: "owner",
            updateSource: .userEdited,
            createdAt: now,
            updatedAt: now
        )
    )
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutputs: [
            PMConversationOpenAISynthesisOutput(
                replyBody: "The current app-owned analyst bench includes Technology Analyst, Recent News Analyst, Macro and International Analyst, and Portfolio Risk Analyst. Ad hoc PM tasking is currently available across the standing bench.",
                resolution: PMConversationResolutionState(
                    intentClass: .general,
                    disposition: .conversationOnly
                )
            ),
            PMConversationOpenAISynthesisOutput(
                replyBody: "PM review queue currently has 1 standing report awaiting PM review. The pending item is from the Macro and International Analyst, and it is sitting in the standing-review artifacts, not proposals, lane.",
                resolution: PMConversationResolutionState(
                    intentClass: .general,
                    disposition: .conversationOnly
                )
            )
        ],
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        portfolioStrategyBriefStore: strategyBriefStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        analystCharterStore: charterStore,
        analystStandingReportStore: standingReportStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider,
        scheduleStore: scheduleStore
    )

    _ = try await engine.listAnalystCharters()
    _ = try await engine.upsertSchedule(
        ScheduledJob(
            scheduleId: "standing-report-bench-overlay-macro-international",
            jobType: .standingAnalystReport,
            enabled: false,
            trigger: ScheduledJobTrigger(intervalSec: 12 * 3_600),
            params: [
                "analystId": .string("bench-overlay-macro-international-analyst"),
                "charterId": .string("bench-overlay-macro-international"),
                "analystTitle": .string("Macro and International Analyst")
            ],
            lastRunAt: now.addingTimeInterval(-1_800),
            lastRunSummary: "Paused for PM review.",
            nextRunAt: now.addingTimeInterval(12 * 3_600)
        ),
        source: AuditEventSource.ui
    )
    _ = try await standingReportStore.upsert(
        AnalystStandingReport(
            reportId: "standing-report-macro-awaiting-review",
            analystId: "bench-overlay-macro-international-analyst",
            charterId: "bench-overlay-macro-international",
            scheduleId: "standing-report-bench-overlay-macro-international",
            memoId: "memo-macro-awaiting-review",
            title: "Macro and International Analyst Standing Report",
            summary: "Rates sensitivity still needs PM review.",
            cadenceIntervalSec: 12 * 3_600,
            reportingWindowSummary: "Past 12 hours",
            portfolioScopeSummary: "Cross-sector macro overlay",
            headlineView: "Rates sensitivity remains a PM review item.",
            portfolioRelevanceSummary: "Macro context still matters for current positions.",
            deliveredToPMInboxAt: now.addingTimeInterval(-900),
            createdAt: now.addingTimeInterval(-900),
            updatedAt: now.addingTimeInterval(-900)
        )
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")

    let benchAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: PMCommunicationSenderRole.owner,
        senderId: "owner",
        body: "Who is on the analyst bench and who can I task ad hoc right now?",
        source: AuditEventSource.ui
    )
    let benchReply = try await engine.generatePMConversationReply(
        to: benchAsk.messageId,
        source: AuditEventSource.ui
    )

    #expect(benchReply.body.contains("current app-owned analyst bench"))
    #expect(benchReply.body.contains("Technology Analyst"))
    #expect(benchReply.body.contains("Recent News Analyst"))
    #expect(benchReply.body.contains("Macro and International Analyst"))
    #expect(benchReply.body.contains("Portfolio Risk Analyst"))
    #expect(benchReply.body.contains("Ad hoc PM tasking is currently available across the standing bench"))

    let queueAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: PMCommunicationSenderRole.owner,
        senderId: "owner",
        body: "What is waiting for review in the PM review queue right now?",
        source: AuditEventSource.ui
    )
    let queueReply = try await engine.generatePMConversationReply(
        to: queueAsk.messageId,
        source: AuditEventSource.ui
    )

    #expect(queueReply.body.contains("PM review queue currently has 1 standing report awaiting PM review."))
    #expect(queueReply.body.contains("Macro and International Analyst"))
    #expect(queueReply.body.contains("standing-review artifacts, not proposals"))
}

@Test("PM standing review wake preserves pending queue truth on app-ready when standing reports already exist")
func pmStandingReviewWakeTriggersOnAppReadyForExistingQueue() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-standing-review-wake-startup")
    let now = Date(timeIntervalSince1970: 1_742_000_300)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let notebookStore = PMNotebookStore(notebookDirectory: root.appendingPathComponent("notebook", isDirectory: true))
    let decisionStore = PMDecisionStore(decisionsDirectory: root.appendingPathComponent("decisions", isDirectory: true))
    let approvalStore = PMApprovalRequestStore(approvalRequestsDirectory: root.appendingPathComponent("approval_requests", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let charterStore = AnalystCharterStore(chartersDirectory: root.appendingPathComponent("charters", isDirectory: true))
    let standingReportStore = AnalystStandingReportStore(reportsDirectory: root.appendingPathComponent("standing_reports", isDirectory: true))
    let scheduleStore = ScheduleStore(fileURL: root.appendingPathComponent("schedules.json", isDirectory: false))
    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Consumes standing review work.",
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmNotebookStore: notebookStore,
        pmDecisionStore: decisionStore,
        pmApprovalRequestStore: approvalStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        analystCharterStore: charterStore,
        analystStandingReportStore: standingReportStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: false, value: nil),
        scheduleStore: scheduleStore
    )

    _ = try await engine.listAnalystCharters()
    _ = try await standingReportStore.upsert(
        makeStandingReviewWakeTestReport(
            reportId: "standing-report-startup-1",
            deliveredAt: now.addingTimeInterval(-120),
            updatedAt: now.addingTimeInterval(-120)
        )
    )

    let wakeMessage = try await engine.triggerPMStandingReviewWakeIfNeeded(
        trigger: .engineReady,
        source: .ui
    )
    let messages = try await engine.listPMCommunicationMessages()
    let notebookEntries = try await engine.listPMNotebookEntries()
    let decisions = try await engine.listPMDecisions()
    let approvalRequests = try await engine.listPMApprovalRequests()
    let reports = try await engine.listAnalystStandingReports()
    let contextPack = try await engine.assemblePMContextPack()

    #expect(wakeMessage == nil)
    #expect(messages.isEmpty)
    #expect(notebookEntries.isEmpty)
    #expect(decisions.isEmpty)
    #expect(approvalRequests.isEmpty)
    #expect(reports.first?.deliveryStatus == .pendingPMReview)
    #expect(contextPack.operatingContext.standingReviewQueue.pendingCount == 1)
}

@Test("New pending standing reports land in the PM review queue without auto-generating owner asks")
func newPendingStandingReportsWakePMOnQueueChange() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-standing-review-wake-queue-change")
    let now = Date(timeIntervalSince1970: 1_742_000_330)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let notebookStore = PMNotebookStore(notebookDirectory: root.appendingPathComponent("notebook", isDirectory: true))
    let decisionStore = PMDecisionStore(decisionsDirectory: root.appendingPathComponent("decisions", isDirectory: true))
    let approvalStore = PMApprovalRequestStore(approvalRequestsDirectory: root.appendingPathComponent("approval_requests", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let charterStore = AnalystCharterStore(chartersDirectory: root.appendingPathComponent("charters", isDirectory: true))
    let standingReportStore = AnalystStandingReportStore(reportsDirectory: root.appendingPathComponent("standing_reports", isDirectory: true))
    let scheduleStore = ScheduleStore(fileURL: root.appendingPathComponent("schedules.json", isDirectory: false))

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Consumes standing review work.",
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmNotebookStore: notebookStore,
        pmDecisionStore: decisionStore,
        pmApprovalRequestStore: approvalStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        analystCharterStore: charterStore,
        analystStandingReportStore: standingReportStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: false, value: nil),
        scheduleStore: scheduleStore
    )

    _ = try await engine.listAnalystCharters()
    _ = try await engine.upsertAnalystStandingReport(
        makeStandingReviewWakeTestReport(
            reportId: "standing-report-queue-change-1",
            deliveredAt: now,
            updatedAt: now,
            sections: [
                AnalystStandingReportSection(
                    sectionId: "risk-issues",
                    kind: .riskIssues,
                    items: [
                        AnalystStandingReportItem(
                            itemId: "rates-sensitive",
                            headline: "Reduce NVDA concentration before the next catalyst window",
                            detail: "Current single-name exposure remains too high relative to the next catalyst window and warrants an explicit de-risking decision.",
                            symbol: "NVDA",
                            priority: 9
                        )
                    ]
                )
            ],
            openQuestions: [
                "Should the PM prepare a more detailed hedge-expression follow-up after the concentration change is reviewed?"
            ]
        ),
        source: .ui
    )

    let messages = try await engine.listPMCommunicationMessages()
    let notebookEntries = try await engine.listPMNotebookEntries()
    let decisions = try await engine.listPMDecisions()
    let approvalRequests = try await engine.listPMApprovalRequests()
    let reports = try await engine.listAnalystStandingReports()
    let contextPack = try await engine.assemblePMContextPack()

    #expect(messages.isEmpty)
    #expect(notebookEntries.isEmpty)
    #expect(decisions.isEmpty)
    #expect(approvalRequests.isEmpty)
    #expect(reports.first?.deliveryStatus == .pendingPMReview)
    #expect(contextPack.operatingContext.standingReviewQueue.pendingCount == 1)
}

@Test("Standing review completion escalates concrete owner actions while closing the pending queue")
func standingReviewCompletionEscalatesConcreteOwnerActions() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-standing-review-owner-escalation")
    let now = Date(timeIntervalSince1970: 1_742_000_345)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let notebookStore = PMNotebookStore(notebookDirectory: root.appendingPathComponent("notebook", isDirectory: true))
    let decisionStore = PMDecisionStore(decisionsDirectory: root.appendingPathComponent("decisions", isDirectory: true))
    let approvalStore = PMApprovalRequestStore(approvalRequestsDirectory: root.appendingPathComponent("approval_requests", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let charterStore = AnalystCharterStore(chartersDirectory: root.appendingPathComponent("charters", isDirectory: true))
    let standingReportStore = AnalystStandingReportStore(reportsDirectory: root.appendingPathComponent("standing_reports", isDirectory: true))
    let scheduleStore = ScheduleStore(fileURL: root.appendingPathComponent("schedules.json", isDirectory: false))

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Consumes standing review work.",
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmNotebookStore: notebookStore,
        pmDecisionStore: decisionStore,
        pmApprovalRequestStore: approvalStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        analystCharterStore: charterStore,
        analystStandingReportStore: standingReportStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: false, value: nil),
        scheduleStore: scheduleStore
    )

    _ = try await engine.listAnalystCharters()
    _ = try await engine.upsertAnalystStandingReport(
        makeStandingReviewWakeTestReport(
            reportId: "standing-report-owner-escalation-1",
            deliveredAt: now,
            updatedAt: now,
            sections: [
                AnalystStandingReportSection(
                    sectionId: "risk-issues",
                    kind: .riskIssues,
                    items: [
                        AnalystStandingReportItem(
                            itemId: "reduce-concentration",
                            headline: "Reduce NVDA concentration before the next catalyst window",
                            detail: "Current single-name exposure remains too high relative to the next catalyst window and warrants an explicit de-risking decision.",
                            symbol: "NVDA",
                            priority: 9
                        )
                    ]
                )
            ],
            openQuestions: [
                "Should the PM prepare a more detailed hedge-expression follow-up after the concentration change is reviewed?"
            ]
        ),
        source: .ui
    )

    let summary = try await engine.completePendingStandingReviewCycle(source: .ui)
    let notebookEntries = try await engine.listPMNotebookEntries()
    let decisions = try await engine.listPMDecisions()
    let approvalRequests = try await engine.listPMApprovalRequests()
    let reports = try await engine.listAnalystStandingReports()
    let contextPack = try await engine.assemblePMContextPack()

    #expect(summary != nil)
    #expect(notebookEntries.count == 1)
    #expect(decisions.count == 1)
    #expect(approvalRequests.count == 1)
    #expect(decisions.first?.status == .active)
    #expect(approvalRequests.first?.status == .pending)
    #expect(approvalRequests.first?.subject.contains("Review standing analyst synthesis") == true)
    #expect(reports.first?.deliveryStatus == .reviewedByPM)
    #expect(contextPack.operatingContext.standingReviewQueue.pendingCount == 0)
}

@Test("Pending standing review sets do not spawn duplicate PM queue wakes for the same report set")
func alreadyReviewedStandingReportSetsDoNotSpawnDuplicateWakeMessages() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-standing-review-wake-idempotent")
    let now = Date(timeIntervalSince1970: 1_742_000_360)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let notebookStore = PMNotebookStore(notebookDirectory: root.appendingPathComponent("notebook", isDirectory: true))
    let decisionStore = PMDecisionStore(decisionsDirectory: root.appendingPathComponent("decisions", isDirectory: true))
    let approvalStore = PMApprovalRequestStore(approvalRequestsDirectory: root.appendingPathComponent("approval_requests", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let charterStore = AnalystCharterStore(chartersDirectory: root.appendingPathComponent("charters", isDirectory: true))
    let standingReportStore = AnalystStandingReportStore(reportsDirectory: root.appendingPathComponent("standing_reports", isDirectory: true))
    let scheduleStore = ScheduleStore(fileURL: root.appendingPathComponent("schedules.json", isDirectory: false))

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Consumes standing review work.",
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmNotebookStore: notebookStore,
        pmDecisionStore: decisionStore,
        pmApprovalRequestStore: approvalStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        analystCharterStore: charterStore,
        analystStandingReportStore: standingReportStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: false, value: nil),
        scheduleStore: scheduleStore
    )

    _ = try await engine.listAnalystCharters()
    let report = makeStandingReviewWakeTestReport(
        reportId: "standing-report-idempotent-1",
        deliveredAt: now,
        updatedAt: now
    )

    _ = try await engine.upsertAnalystStandingReport(report, source: .ui)
    let pending = try #require((try await engine.listAnalystStandingReports()).first)
    _ = try await engine.upsertAnalystStandingReport(pending, source: .ui)
    let duplicateWake = try await engine.triggerPMStandingReviewWakeIfNeeded(
        trigger: .engineReady,
        source: .ui
    )
    let messages = try await engine.listPMCommunicationMessages()
    let notebookEntries = try await engine.listPMNotebookEntries()
    let contextPack = try await engine.assemblePMContextPack()

    #expect(duplicateWake == nil)
    #expect(messages.isEmpty)
    #expect(notebookEntries.isEmpty)
    #expect(contextPack.operatingContext.standingReviewQueue.pendingCount == 1)
}

@Test("No-portfolio standing review completion still synthesizes candidate ideas for the owner")
func noPortfolioStandingReviewCompletionSynthesizesCandidateIdeas() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-standing-review-no-portfolio")
    let now = Date(timeIntervalSince1970: 1_742_000_390)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let notebookStore = PMNotebookStore(notebookDirectory: root.appendingPathComponent("notebook", isDirectory: true))
    let decisionStore = PMDecisionStore(decisionsDirectory: root.appendingPathComponent("decisions", isDirectory: true))
    let approvalStore = PMApprovalRequestStore(approvalRequestsDirectory: root.appendingPathComponent("approval_requests", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let charterStore = AnalystCharterStore(chartersDirectory: root.appendingPathComponent("charters", isDirectory: true))
    let standingReportStore = AnalystStandingReportStore(reportsDirectory: root.appendingPathComponent("standing_reports", isDirectory: true))
    let scheduleStore = ScheduleStore(fileURL: root.appendingPathComponent("schedules.json", isDirectory: false))

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Consumes standing review work.",
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmNotebookStore: notebookStore,
        pmDecisionStore: decisionStore,
        pmApprovalRequestStore: approvalStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        analystCharterStore: charterStore,
        analystStandingReportStore: standingReportStore,
        scheduleStore: scheduleStore
    )

    _ = try await engine.listAnalystCharters()
    _ = try await engine.upsertAnalystStandingReport(
        makeStandingReviewWakeTestReport(
            reportId: "standing-report-no-portfolio-1",
            deliveredAt: now,
            updatedAt: now,
            sections: [
                AnalystStandingReportSection(
                    sectionId: "long-ideas",
                    kind: .longIdeas,
                    items: [
                        AnalystStandingReportItem(
                            itemId: "qqq",
                            headline: "QQQ remains the cleaner long candidate",
                            detail: "Large-cap AI infrastructure stays the cleaner entry point.",
                            symbol: "QQQ",
                            stance: .long,
                            conviction: 8
                        )
                    ]
                ),
                AnalystStandingReportSection(
                    sectionId: "short-ideas",
                    kind: .shortIdeas,
                    items: [
                        AnalystStandingReportItem(
                            itemId: "iwm-hedge",
                            headline: "IWM hedge remains the cleaner pressure test",
                            detail: "Small-cap cyclicals remain more rate-sensitive.",
                            symbol: "IWM",
                            stance: .short,
                            conviction: 6
                        )
                    ]
                ),
                AnalystStandingReportSection(
                    sectionId: "macro-views",
                    kind: .macroViews,
                    items: [
                        AnalystStandingReportItem(
                            itemId: "ai-infra",
                            headline: "AI infrastructure leadership still dominates the macro transmission",
                            detail: "Cross-asset conditions still favor quality mega-cap leadership.",
                            stance: .macro
                        )
                    ]
                )
            ]
        ),
        source: .ui
    )

    let completionEntry = try await engine.completePendingStandingReviewCycle(source: .ui)
    let messages = try await engine.listPMCommunicationMessages()
    let notebookEntries = try await engine.listPMNotebookEntries()
    let completion = try #require(completionEntry ?? notebookEntries.first)
    let approvalRequests = try await engine.listPMApprovalRequests()
    let reports = try await engine.listAnalystStandingReports()
    let contextPack = try await engine.assemblePMContextPack()

    #expect(messages.isEmpty)
    #expect(completion.body.contains("No live portfolio is attached"))
    #expect(
        completion.body.contains("Disposition: Candidate ideas worth considering.")
            || completion.body.contains("Disposition: Follow-up analyst work warranted.")
    )
    #expect(completion.body.contains("long candidates: QQQ: QQQ remains the cleaner long candidate"))
    #expect(completion.body.contains("short or hedge ideas: IWM: IWM hedge remains the cleaner pressure test"))
    #expect(completion.body.contains("themes or expressions: AI infrastructure leadership still dominates the macro transmission"))
    #expect(approvalRequests.isEmpty)
    #expect(reports.first?.deliveryStatus == .reviewedByPM)
    #expect(contextPack.operatingContext.standingReviewQueue.pendingCount == 0)
}

@Test("Low-signal standing review completion stays background-only while preserving PM conclusion visibility")
func lowSignalStandingReviewStaysBackgroundOnly() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-standing-review-low-signal")
    let now = Date(timeIntervalSince1970: 1_742_000_395)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let notebookStore = PMNotebookStore(notebookDirectory: root.appendingPathComponent("notebook", isDirectory: true))
    let decisionStore = PMDecisionStore(decisionsDirectory: root.appendingPathComponent("decisions", isDirectory: true))
    let approvalStore = PMApprovalRequestStore(approvalRequestsDirectory: root.appendingPathComponent("approval_requests", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let charterStore = AnalystCharterStore(chartersDirectory: root.appendingPathComponent("charters", isDirectory: true))
    let standingReportStore = AnalystStandingReportStore(reportsDirectory: root.appendingPathComponent("standing_reports", isDirectory: true))
    let scheduleStore = ScheduleStore(fileURL: root.appendingPathComponent("schedules.json", isDirectory: false))

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Consumes standing review work.",
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmNotebookStore: notebookStore,
        pmDecisionStore: decisionStore,
        pmApprovalRequestStore: approvalStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        analystCharterStore: charterStore,
        analystStandingReportStore: standingReportStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: false, value: nil),
        scheduleStore: scheduleStore
    )

    _ = try await engine.listAnalystCharters()
    _ = try await engine.upsertAnalystStandingReport(
        makeStandingReviewWakeTestReport(
            reportId: "standing-report-low-signal-1",
            deliveredAt: now,
            updatedAt: now,
            sections: [
                AnalystStandingReportSection(
                    sectionId: "important-items",
                    kind: .importantItems,
                    items: [
                        AnalystStandingReportItem(
                            itemId: "no-fresh-update",
                            headline: "No fresh financial headline displaced current construction",
                            detail: "The current watchlist remains unchanged and no governed next step is warranted.",
                            priority: 9
                        )
                    ]
                )
            ]
        ),
        source: .ui
    )

    let completionEntry = try await engine.completePendingStandingReviewCycle(source: .ui)
    let notebookEntries = try await engine.listPMNotebookEntries()
    let decisions = try await engine.listPMDecisions()
    let approvalRequests = try await engine.listPMApprovalRequests()

    let summary = try #require(completionEntry ?? notebookEntries.first)
    let recommendedAction = try #require(decisions.first?.recommendedAction)
    #expect(summary.body.contains("quiet background PM work"))
    #expect(decisions.count == 1)
    #expect(decisions.first?.title.hasPrefix("Standing review conclusion: ") == true)
    #expect(
        recommendedAction.lowercased().contains("no owner-path escalation")
            || recommendedAction.lowercased().contains("monitor")
            || recommendedAction.lowercased().contains("no action")
    )
    #expect(approvalRequests.isEmpty)
}

@Test("Standing review conclusions use model-backed PM reasoning when provider and key are available")
func standingReviewConclusionsUseModelBackedPMReasoningWhenAvailable() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-standing-review-openai-backed")
    let now = Date(timeIntervalSince1970: 1_742_000_396)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let notebookStore = PMNotebookStore(notebookDirectory: root.appendingPathComponent("notebook", isDirectory: true))
    let decisionStore = PMDecisionStore(decisionsDirectory: root.appendingPathComponent("decisions", isDirectory: true))
    let approvalStore = PMApprovalRequestStore(approvalRequestsDirectory: root.appendingPathComponent("approval_requests", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let charterStore = AnalystCharterStore(chartersDirectory: root.appendingPathComponent("charters", isDirectory: true))
    let standingReportStore = AnalystStandingReportStore(reportsDirectory: root.appendingPathComponent("standing_reports", isDirectory: true))
    let scheduleStore = ScheduleStore(fileURL: root.appendingPathComponent("schedules.json", isDirectory: false))
    let runtimeSettingsStore = PMRuntimeSettingsStore(fileURL: root.appendingPathComponent("pm-runtime-settings.json", isDirectory: false))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "Unused conversation output."
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Model-backed PM review keeps the macro signal in monitor-only posture while the evidence remains bounded.",
            recommendedAction: "Monitor the current macro signal without escalating it to the owner."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Consumes standing review work.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await runtimeSettingsStore.upsert(
        PMRuntimeSettings(
            runtimeIdentifier: "gpt-5.4",
            reasoningMode: .deliberate,
            updatedBy: "pm-primary",
            updateSource: .pmControlPlane,
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmNotebookStore: notebookStore,
        pmRuntimeSettingsStore: runtimeSettingsStore,
        pmDecisionStore: decisionStore,
        pmApprovalRequestStore: approvalStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        analystCharterStore: charterStore,
        analystStandingReportStore: standingReportStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider,
        scheduleStore: scheduleStore
    )

    _ = try await engine.listAnalystCharters()
    _ = try await engine.upsertAnalystStandingReport(
        makeStandingReviewWakeTestReport(
            reportId: "standing-report-openai-1",
            deliveredAt: now,
            updatedAt: now,
            sections: [
                AnalystStandingReportSection(
                    sectionId: "important-items",
                    kind: .importantItems,
                    items: [
                        AnalystStandingReportItem(
                            itemId: "macro-monitor",
                            headline: "Macro pressure still merits monitoring",
                            detail: "The rate-sensitive setup is still present, but the evidence is not strong enough for owner escalation.",
                            priority: 7
                        )
                    ]
                )
            ]
        ),
        source: AuditEventSource.ui
    )

    _ = try await engine.completePendingStandingReviewCycle(source: AuditEventSource.ui)
    let decisions = try await engine.listPMDecisions()
    let decision = try #require(decisions.first)
    let request = try #require(await synthesisProvider.lastStandingReviewRequest)

    #expect(decision.summary.contains("Model-backed PM review"))
    #expect(decision.recommendedAction == "Monitor the current macro signal without escalating it to the owner.")
    #expect(decision.runtimeProvenance?.actualRuntimeIdentifier == "openai_responses[gpt-5.4]")
    #expect(decision.runtimeProvenance?.usedOpenAI == true)
    #expect(request.runtimeIdentifier == "gpt-5.4")
    #expect(request.reports.first?.sections.joined(separator: " ").localizedCaseInsensitiveContains("macro") == true)
    #expect((try await engine.listPMApprovalRequests()).isEmpty)
}

@Test("Run-now-like standing review results stay PM-background unless a concrete owner action is present")
func runNowLikeStandingReviewResultsStayBackgroundByDefault() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-standing-review-run-now-background")
    let now = Date(timeIntervalSince1970: 1_742_000_398)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let notebookStore = PMNotebookStore(notebookDirectory: root.appendingPathComponent("notebook", isDirectory: true))
    let decisionStore = PMDecisionStore(decisionsDirectory: root.appendingPathComponent("decisions", isDirectory: true))
    let approvalStore = PMApprovalRequestStore(approvalRequestsDirectory: root.appendingPathComponent("approval_requests", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let charterStore = AnalystCharterStore(chartersDirectory: root.appendingPathComponent("charters", isDirectory: true))
    let standingReportStore = AnalystStandingReportStore(reportsDirectory: root.appendingPathComponent("standing_reports", isDirectory: true))
    let scheduleStore = ScheduleStore(fileURL: root.appendingPathComponent("schedules.json", isDirectory: false))

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Consumes standing review work.",
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmNotebookStore: notebookStore,
        pmDecisionStore: decisionStore,
        pmApprovalRequestStore: approvalStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        analystCharterStore: charterStore,
        analystStandingReportStore: standingReportStore,
        scheduleStore: scheduleStore
    )

    _ = try await engine.listAnalystCharters()
    _ = try await engine.upsertAnalystStandingReport(
        makeStandingReviewWakeTestReport(
            reportId: "standing-report-run-now-background-1",
            deliveredAt: now,
            updatedAt: now,
            sections: [
                AnalystStandingReportSection(
                    sectionId: "important-items",
                    kind: .importantItems,
                    items: [
                        AnalystStandingReportItem(
                            itemId: "candidate-refresh",
                            headline: "Candidate worth considering: AVGO still looks cleaner than the current add list",
                            detail: "The current technology watchlist remains background-only until a stronger thesis change appears.",
                            priority: 9
                        )
                    ]
                )
            ],
            openQuestions: [
                "Should the PM keep AVGO in background monitoring before the next standing cycle?"
            ]
        ),
        source: .ui
    )

    let completionEntry = try await engine.completePendingStandingReviewCycle(source: .ui)
    let decisions = try await engine.listPMDecisions()
    let approvalRequests = try await engine.listPMApprovalRequests()
    let notebookEntries = try await engine.listPMNotebookEntries()
    let reports = try await engine.listAnalystStandingReports()
    let summary = try #require(completionEntry ?? notebookEntries.first)
    let recommendedAction = try #require(decisions.first?.recommendedAction)

    #expect(summary.body.contains("quiet background PM work") == true)
    #expect(decisions.count == 1)
    #expect(decisions.first?.title.hasPrefix("Standing review conclusion: ") == true)
    #expect(
        recommendedAction.lowercased().contains("background")
            || recommendedAction.lowercased().contains("monitor")
            || recommendedAction.lowercased().contains("no owner-path escalation")
    )
    #expect(approvalRequests.isEmpty)
    #expect(reports.first?.deliveryStatus == .reviewedByPM)
}

@Test("Completing standing review closes lingering low-signal standing-review asks from older queue semantics")
func standingReviewCompletionClosesLingeringLowSignalArtifacts() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-standing-review-close-legacy-background-artifacts")
    let now = Date(timeIntervalSince1970: 1_742_000_405)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let notebookStore = PMNotebookStore(notebookDirectory: root.appendingPathComponent("notebook", isDirectory: true))
    let decisionStore = PMDecisionStore(decisionsDirectory: root.appendingPathComponent("decisions", isDirectory: true))
    let approvalStore = PMApprovalRequestStore(approvalRequestsDirectory: root.appendingPathComponent("approval_requests", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let charterStore = AnalystCharterStore(chartersDirectory: root.appendingPathComponent("charters", isDirectory: true))
    let standingReportStore = AnalystStandingReportStore(reportsDirectory: root.appendingPathComponent("standing_reports", isDirectory: true))
    let scheduleStore = ScheduleStore(fileURL: root.appendingPathComponent("schedules.json", isDirectory: false))

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Consumes standing review work.",
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmNotebookStore: notebookStore,
        pmDecisionStore: decisionStore,
        pmApprovalRequestStore: approvalStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        analystCharterStore: charterStore,
        analystStandingReportStore: standingReportStore,
        scheduleStore: scheduleStore
    )

    let decision = PMDecisionRecord(
        decisionId: "pm-decision-legacy-standing-review",
        pmId: "pm-1",
        title: "Standing review escalation: Technology Analyst",
        summary: "Key issues: No fresh technology headline cleared the bounded filter. Follow-up worth weighing: Candidate worth considering: AVGO still looks cleaner than the current add list.",
        recommendedAction: "No fresh technology headline cleared the bounded filter",
        ownerAsk: "Review this standing-review synthesis and decide whether you want it to remain monitor-only or have me prepare a separate governed next step.",
        decisionType: .escalation,
        status: .active,
        createdAt: now,
        updatedAt: now
    )
    _ = try await engine.upsertPMDecision(decision, source: .ui)
    let request = PMApprovalRequest(
        approvalRequestId: "pm-approval-legacy-standing-review",
        pmId: "pm-1",
        subject: "Review standing analyst synthesis: Technology Analyst",
        rationale: "Standing analyst review surfaced an owner-relevant issue across 1 reviewed report. Most important: No fresh technology headline cleared the bounded filter. Potential follow-up: Candidate worth considering: AVGO still looks cleaner than the current add list.",
        requestType: .other,
        status: .pending,
        decisionId: decision.decisionId,
        createdAt: now,
        updatedAt: now
    )
    _ = try await engine.upsertPMApprovalRequest(request, source: .ui)

    let completion = try await engine.completePendingStandingReviewCycle(source: .ui)
    let decisions = try await engine.listPMDecisions()
    let approvalRequests = try await engine.listPMApprovalRequests()

    #expect(completion == nil)
    #expect(decisions.first?.status == .withdrawn)
    #expect(approvalRequests.first?.status == .withdrawn)
}

@Test("Standing review decisions persist explicit standing report linkage identities")
func standingReviewDecisionPersistsExplicitStandingReportLinkage() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-standing-review-linked-report-id")
    let now = Date(timeIntervalSince1970: 1_742_000_410)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let notebookStore = PMNotebookStore(notebookDirectory: root.appendingPathComponent("notebook", isDirectory: true))
    let decisionStore = PMDecisionStore(decisionsDirectory: root.appendingPathComponent("decisions", isDirectory: true))
    let approvalStore = PMApprovalRequestStore(approvalRequestsDirectory: root.appendingPathComponent("approval_requests", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let charterStore = AnalystCharterStore(chartersDirectory: root.appendingPathComponent("charters", isDirectory: true))
    let standingReportStore = AnalystStandingReportStore(reportsDirectory: root.appendingPathComponent("standing_reports", isDirectory: true))
    let scheduleStore = ScheduleStore(fileURL: root.appendingPathComponent("schedules.json", isDirectory: false))

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Consumes standing review work.",
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmNotebookStore: notebookStore,
        pmDecisionStore: decisionStore,
        pmApprovalRequestStore: approvalStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        analystCharterStore: charterStore,
        analystStandingReportStore: standingReportStore,
        scheduleStore: scheduleStore
    )

    _ = try await engine.listAnalystCharters()
    _ = try await engine.upsertAnalystStandingReport(
        makeStandingReviewWakeTestReport(
            reportId: "standing-report-linked-1",
            deliveredAt: now,
            updatedAt: now
        ),
        source: .ui
    )

    _ = try await engine.completePendingStandingReviewCycle(source: .ui)
    let decision = try #require((try await engine.listPMDecisions()).first)

    #expect(decision.primaryStandingReportId == "standing-report-linked-1")
    #expect(decision.standingReportIds == ["standing-report-linked-1"])
}

@Test("Standing review sequencing reviews the newest completed pending report first and preserves per-report linkage")
func standingReviewSequencingConsumesNewestCompletedPendingReportFirst() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-standing-review-linked-report-order")
    let now = Date(timeIntervalSince1970: 1_742_000_415)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let notebookStore = PMNotebookStore(notebookDirectory: root.appendingPathComponent("notebook", isDirectory: true))
    let decisionStore = PMDecisionStore(decisionsDirectory: root.appendingPathComponent("decisions", isDirectory: true))
    let approvalStore = PMApprovalRequestStore(approvalRequestsDirectory: root.appendingPathComponent("approval_requests", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let charterStore = AnalystCharterStore(chartersDirectory: root.appendingPathComponent("charters", isDirectory: true))
    let standingReportStore = AnalystStandingReportStore(reportsDirectory: root.appendingPathComponent("standing_reports", isDirectory: true))
    let scheduleStore = ScheduleStore(fileURL: root.appendingPathComponent("schedules.json", isDirectory: false))

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Consumes standing review work.",
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmNotebookStore: notebookStore,
        pmDecisionStore: decisionStore,
        pmApprovalRequestStore: approvalStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        analystCharterStore: charterStore,
        analystStandingReportStore: standingReportStore,
        scheduleStore: scheduleStore
    )

    _ = try await engine.listAnalystCharters()
    _ = try await engine.upsertAnalystStandingReport(
        makeStandingReviewWakeTestReport(
            reportId: "standing-report-cycle-1",
            deliveredAt: now,
            updatedAt: now
        ),
        source: .ui
    )
    _ = try await engine.upsertAnalystStandingReport(
        makeStandingReviewWakeTestReport(
            reportId: "standing-report-cycle-2",
            deliveredAt: now.addingTimeInterval(60),
            updatedAt: now.addingTimeInterval(60)
        ),
        source: .ui
    )

    _ = try await engine.completePendingStandingReviewCycle(source: .ui)
    let firstDecision = try #require((try await engine.listPMDecisions()).first)
    let firstContextPack = try await engine.assemblePMContextPack()

    #expect(firstDecision.primaryStandingReportId == "standing-report-cycle-2")
    #expect(firstDecision.standingReportIds == ["standing-report-cycle-2"])
    #expect(firstContextPack.operatingContext.standingReviewQueue.pendingCount == 1)

    _ = try await engine.completePendingStandingReviewCycle(source: .ui)
    let decisions = try await engine.listPMDecisions().sorted { $0.updatedAt > $1.updatedAt }
    let secondContextPack = try await engine.assemblePMContextPack()

    #expect(decisions.count == 2)
    #expect(decisions.map(\.primaryStandingReportId) == ["standing-report-cycle-1", "standing-report-cycle-2"])
    #expect(secondContextPack.operatingContext.standingReviewQueue.pendingCount == 0)
}

@Test("New standing review items can still trigger a fresh PM review cycle after prior queue closure")
func newStandingReviewItemsTriggerFreshCycleAfterPriorCompletion() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-standing-review-second-cycle")
    let now = Date(timeIntervalSince1970: 1_742_000_420)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let notebookStore = PMNotebookStore(notebookDirectory: root.appendingPathComponent("notebook", isDirectory: true))
    let decisionStore = PMDecisionStore(decisionsDirectory: root.appendingPathComponent("decisions", isDirectory: true))
    let approvalStore = PMApprovalRequestStore(approvalRequestsDirectory: root.appendingPathComponent("approval_requests", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let charterStore = AnalystCharterStore(chartersDirectory: root.appendingPathComponent("charters", isDirectory: true))
    let standingReportStore = AnalystStandingReportStore(reportsDirectory: root.appendingPathComponent("standing_reports", isDirectory: true))
    let scheduleStore = ScheduleStore(fileURL: root.appendingPathComponent("schedules.json", isDirectory: false))

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Consumes standing review work.",
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmNotebookStore: notebookStore,
        pmDecisionStore: decisionStore,
        pmApprovalRequestStore: approvalStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        analystCharterStore: charterStore,
        analystStandingReportStore: standingReportStore,
        scheduleStore: scheduleStore
    )

    _ = try await engine.listAnalystCharters()
    _ = try await engine.upsertAnalystStandingReport(
        makeStandingReviewWakeTestReport(
            reportId: "standing-report-cycle-1",
            deliveredAt: now,
            updatedAt: now
        ),
        source: .ui
    )

    _ = try await engine.completePendingStandingReviewCycle(source: .ui)

    let firstContextPack = try await engine.assemblePMContextPack()
    #expect(firstContextPack.operatingContext.standingReviewQueue.pendingCount == 0)

    _ = try await engine.upsertAnalystStandingReport(
        makeStandingReviewWakeTestReport(
            reportId: "standing-report-cycle-2",
            deliveredAt: now.addingTimeInterval(60),
            updatedAt: now.addingTimeInterval(60)
        ),
        source: .ui
    )

    let messages = try await engine.listPMCommunicationMessages()
    let notebookEntries = try await engine.listPMNotebookEntries()
    let reports = try await engine.listAnalystStandingReports()
    let contextPack = try await engine.assemblePMContextPack()

    #expect(messages.isEmpty)
    #expect(notebookEntries.count == 1)
    #expect(notebookEntries.allSatisfy { $0.tags.contains("pm_background_review") })
    #expect(reports.filter { $0.deliveryStatus == .pendingPMReview }.count == 1)
    #expect(contextPack.operatingContext.standingReviewQueue.pendingCount == 1)
}

@Test("Short negative follow-ups use the latest PM offer instead of repeating the earlier brief-review answer")
func shortNegativeFollowUpUsesLatestPMOffer() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-negative-follow-up")
    let now = Date(timeIntervalSince1970: 1_742_000_027)
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let strategyBriefStore = PortfolioStrategyBriefStore(fileURL: root.appendingPathComponent("portfolio_strategy_brief.json", isDirectory: false))

    _ = try await strategyBriefStore.upsert(
        PortfolioStrategyBrief(
            title: "Current Portfolio Strategy Brief",
            documentBody: """
            ## Objective
            Preserve capital through bounded event-aware supervision.
            """,
            objectiveSummary: "Preserve capital through bounded event-aware supervision.",
            currentRiskPosture: "Moderate risk posture with tighter review around earnings and SEC event clusters.",
            reviewEscalationPosture: "Escalate potentially material cases to PM review before any owner-facing request.",
            updatedBy: "owner",
            updateSource: .userEdited,
            createdAt: now,
            updatedAt: now
        )
    )
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutputs: [
            PMConversationOpenAISynthesisOutput(
                replyBody: "Before I would revise it, I would tighten these points: make the event-risk thresholds explicit, spell out what triggers PM escalation, and define what gets logged versus what becomes an owner-facing decision.",
                resolution: PMConversationResolutionState(
                    intentClass: .general,
                    disposition: .conversationOnly
                )
            ),
            PMConversationOpenAISynthesisOutput(
                replyBody: "Understood. I’ll leave the current saved Portfolio Strategy Brief unchanged. If you want, point me to the next document or question.",
                resolution: PMConversationResolutionState(
                    intentClass: .followUpQuestion,
                    disposition: .conversationOnly
                )
            )
        ],
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    let engine = Engine(
        portfolioStrategyBriefStore: strategyBriefStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession()
    let firstAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Please read the Portfolio Strategy Brief and give me your questions and comments.",
        source: .ui
    )
    _ = try await engine.generatePMConversationReply(to: firstAsk.messageId, source: .ui)

    let secondAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "No",
        source: .ui
    )
    let secondReply = try await engine.generatePMConversationReply(to: secondAsk.messageId, source: .ui)

    #expect(secondReply.replyToMessageId == secondAsk.messageId)
    #expect(secondReply.body.contains("leave the current saved Portfolio Strategy Brief unchanged"))
    #expect(secondReply.body.contains("point me to the next document or question"))
}

@Test("Clear yes replies bind to the immediately preceding PM confirmation question instead of falling into ambiguous short follow-up handling")
func yesReplyBindsToRecentPMConfirmationQuestion() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-yes-confirmation")
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "I’m taking that as a yes and will carry that forward as the current working conversation outcome for this thread.",
            resolution: PMConversationResolutionState(
                intentClass: .confirmation,
                disposition: .conversationOnly
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    let engine = Engine(
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession()
    _ = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .pm,
        senderId: "pm-primary",
        body: """
        Proposed reconstruction: 9 longs plus short NYCB.

        YES / NO: Freeze this proposed reconstruction as the working portfolio definition for this thread?

        If yes, I will carry that exact reconstruction forward in working conversation state.
        """,
        source: .ui
    )

    let ownerReply = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Yes",
        source: .ui
    )
    let pmReply = try await engine.generatePMConversationReply(to: ownerReply.messageId, source: .ui)

    #expect(pmReply.replyToMessageId == ownerReply.messageId)
    #expect(pmReply.body.contains("taking that as a yes"))
    #expect(pmReply.body.contains("working conversation outcome"))
    #expect(pmReply.body.contains("carry that forward as the current working conversation outcome"))
    #expect(pmReply.body.contains("cannot answer that confidently") == false)
}

@Test("Clear no replies bind to the immediately preceding PM confirmation question and keep the proposal unresolved")
func noReplyBindsToRecentPMConfirmationQuestion() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-no-confirmation")
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "I’m treating your \"No\" as a rejection of that proposal, so I will not carry that proposed outcome forward.",
            resolution: PMConversationResolutionState(
                intentClass: .confirmation,
                disposition: .conversationOnly
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    let engine = Engine(
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession()
    _ = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .pm,
        senderId: "pm-primary",
        body: """
        YES / NO: Should I carry forward the proposed reconstruction with short NYCB as the working thread baseline?
        """,
        source: .ui
    )

    let ownerReply = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "No",
        source: .ui
    )
    let pmReply = try await engine.generatePMConversationReply(to: ownerReply.messageId, source: .ui)

    #expect(pmReply.replyToMessageId == ownerReply.messageId)
    #expect(pmReply.body.contains("treating your \"No\" as a rejection"))
    #expect(pmReply.body.contains("will not carry that proposed outcome forward"))
}

@Test("Ambiguous short replies to a recent PM confirmation question trigger a targeted follow-up instead of losing the thread")
func ambiguousReplyToRecentPMConfirmationQuestionTriggersTargetedFollowUp() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-ambiguous-confirmation")
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "I’m still holding one active PM question open on whether to freeze that proposed reconstruction. Please answer that one directly with yes or no.",
            resolution: PMConversationResolutionState(
                intentClass: .followUpQuestion,
                disposition: .conversationOnly
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    let engine = Engine(
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession()
    _ = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .pm,
        senderId: "pm-primary",
        body: """
        YES / NO: Freeze the proposed reconstruction as the working portfolio definition for this thread?
        """,
        source: .ui
    )

    let ownerReply = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Maybe",
        source: .ui
    )
    let pmReply = try await engine.generatePMConversationReply(to: ownerReply.messageId, source: .ui)

    #expect(pmReply.replyToMessageId == ownerReply.messageId)
    #expect(pmReply.body.contains("still holding one active PM question open"))
    #expect(pmReply.body.contains("Please answer that one directly with yes or no"))
}

@Test("Explicit receipt-confirmation asks return a one-sentence PM acknowledgment instead of the long generic template")
func receiptConfirmationAskReturnsConciseAcknowledgment() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-receipt-confirmation")
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "Yes, I received your latest in-app turn.",
            resolution: PMConversationResolutionState(
                intentClass: .general,
                disposition: .conversationOnly
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    let engine = Engine(
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession()
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Please reply with one sentence confirming you received my latest in-app turn.",
        source: .ui
    )
    let reply = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)

    #expect(reply.replyToMessageId == ownerAsk.messageId)
    #expect(reply.body == "Yes, I received your latest in-app turn.")
}

@Test("Runtime-failure fallback stays minimal instead of reconstructing notebook or prior communication context")
func pmConversationRecoversNotebookAndPriorDiscussionContext() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-context-recovery")
    let now = Date(timeIntervalSince1970: 1_742_000_040)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let notebookStore = PMNotebookStore(notebookDirectory: root.appendingPathComponent("notebook", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let strategyBriefStore = PortfolioStrategyBriefStore(fileURL: root.appendingPathComponent("portfolio_strategy_brief.json", isDirectory: false))

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Recovers bounded PM context from app-owned memory.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await notebookStore.upsert(
        PMNotebookEntry(
            entryId: "note-earnings-buffer",
            pmId: "pm-1",
            title: "Earnings cash buffer note",
            body: "Keep more cash buffering around earnings clusters and revisit sizing only after the prints settle.",
            sourceSummary: "Prior PM note: keep more cash around earnings and reassess sizing after the event window.",
            createdAt: now.addingTimeInterval(-600),
            updatedAt: now.addingTimeInterval(-600)
        )
    )
    _ = try await strategyBriefStore.upsert(
        PortfolioStrategyBrief(
            objectiveSummary: "Compound steadily while keeping event-risk posture disciplined.",
            keyThemes: ["event-risk review", "cash flexibility"],
            currentRiskPosture: "Constructive with tighter earnings review.",
            reviewEscalationPosture: "Escalate material posture changes quickly.",
            updatedBy: "human owner",
            updateSource: .userEdited,
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmNotebookStore: notebookStore,
        portfolioStrategyBriefStore: strategyBriefStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: false, value: nil)
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    _ = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Before the next earnings cluster, keep more cash buffering and revisit sizing only after the prints.",
        source: .ui
    )
    _ = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .pm,
        senderId: "pm-1",
        body: "Understood. I will carry forward the earnings cash-buffering discussion in bounded PM context.",
        source: .ui
    )

    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Please check your notebook and remind me what we said earlier about earnings cash buffering.",
        source: .ui
    )
    let reply = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)

    #expect(reply.replyToMessageId == ownerAsk.messageId)
    #expect(reply.body.contains("I couldn't complete a PM answer because the PM runtime failed:"))
    #expect(reply.body.contains("Keep more cash buffering") == false)
    #expect(reply.body.contains("Earnings cash buffer note") == false)
    #expect(reply.body.contains("Here is the strongest earlier context I found") == false)
    #expect(reply.body.contains("bounded continuity") == false)
    #expect(reply.runtimeProvenance?.conversationTrace?.fallbackTrigger == .credentialUnavailable)
    #expect(reply.conversationResolution == nil)
    #expect(reply.conversationActionPlan == nil)
}

@Test("PM conversation recovery prioritizes same-day durable communication and fuller notebook text after relaunch")
func pmConversationRecoveryPrioritizesSameDayCommunicationAndNotebookTextAfterRelaunch() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-same-day-recovery")
    let now = Date(timeIntervalSince1970: 1_742_086_800)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let notebookStore = PMNotebookStore(notebookDirectory: root.appendingPathComponent("notebook", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let strategyBriefStore = PortfolioStrategyBriefStore(fileURL: root.appendingPathComponent("portfolio_strategy_brief.json", isDirectory: false))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(replyBody: "Recovered same-day context successfully."),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Recovers same-day PM continuity after relaunch.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await notebookStore.upsert(
        PMNotebookEntry(
            entryId: "note-earnings-buffer-detail",
            pmId: "pm-1",
            title: "Earnings cash buffer note",
            body: "Keep more cash buffering around earnings clusters, wait for the second post-print session before resizing, and treat implied-volatility spikes as context rather than a direct sizing trigger.",
            sourceSummary: "Prior PM note: keep more cash around earnings and reassess sizing after the event window.",
            createdAt: now.addingTimeInterval(-(3 * 60 * 60)),
            updatedAt: now.addingTimeInterval(-(3 * 60 * 60))
        )
    )
    _ = try await strategyBriefStore.upsert(
        PortfolioStrategyBrief(
            objectiveSummary: "Compound steadily while keeping event-risk posture disciplined.",
            keyThemes: ["event-risk review", "cash flexibility"],
            currentRiskPosture: "Constructive with tighter earnings review.",
            reviewEscalationPosture: "Escalate material posture changes quickly.",
            updatedBy: "owner",
            updateSource: .userEdited,
            createdAt: now,
            updatedAt: now
        )
    )

    let initialEngine = Engine(
        pmProfileStore: profileStore,
        pmNotebookStore: notebookStore,
        portfolioStrategyBriefStore: strategyBriefStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore
    )

    let session = try await initialEngine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    _ = try await initialEngine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Before the next earnings cluster, keep extra cash until the second post-print session and do not resize on the first headline.",
        source: .ui
    )
    _ = try await initialEngine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .pm,
        senderId: "pm-1",
        body: "Understood. I will carry forward the cash buffer and second post-print session rule.",
        source: .ui
    )
    _ = try await initialEngine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Also treat implied-volatility spikes as context, not as a direct trigger by themselves.",
        source: .ui
    )
    _ = try await initialEngine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .pm,
        senderId: "pm-1",
        body: "Agreed. Volatility spikes alone should not trigger sizing changes.",
        source: .ui
    )

    let relaunchedEngine = Engine(
        pmProfileStore: profileStore,
        pmNotebookStore: notebookStore,
        portfolioStrategyBriefStore: strategyBriefStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let ownerAsk = try await relaunchedEngine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "After reopening, remind me what we said earlier today about the earnings cash buffer, the second post-print session, and the notebook note.",
        source: .ui
    )
    let reply = try await relaunchedEngine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)
    let request = try #require(await synthesisProvider.lastConversationRequest)

    #expect(reply.body == "Recovered same-day context successfully.")
    #expect(request.recoveredContextSummary.count <= 6)
    #expect(request.recoveredContextSummary.contains(where: {
        $0.contains("Same-day communication thread")
            && $0.contains("second post-print session")
            && $0.contains("Volatility spikes alone should not trigger sizing changes")
    }))
    #expect(request.recoveredContextSummary.contains(where: {
        $0.contains("PM notebook: Earnings cash buffer note")
            && $0.contains("wait for the second post-print session before resizing")
    }))
}

@Test("PM conversation recovery includes fuller promoted notebook excerpts instead of tiny teaser snippets")
func pmConversationRecoveryIncludesFullerPromotedNotebookExcerpts() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-promoted-excerpt")
    let now = Date(timeIntervalSince1970: 1_742_086_920)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let notebookStore = PMNotebookStore(notebookDirectory: root.appendingPathComponent("notebook", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(replyBody: "Recovered promoted notebook context successfully."),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Recovers fuller promoted notebook context.",
            createdAt: now,
            updatedAt: now
        )
    )

    let initialEngine = Engine(
        pmProfileStore: profileStore,
        pmNotebookStore: notebookStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore
    )

    let session = try await initialEngine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let sourceMessage = try await initialEngine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Keep the semiconductor watchlist in monitoring mode until supply checks stabilize, and do not promote a thesis from one upbeat channel-check.",
        source: .ui
    )
    _ = try await initialEngine.promotePMCommunicationMessageToNotebookEntry(
        messageId: sourceMessage.messageId,
        pmId: "pm-1",
        title: "Semiconductor supply-check note",
        body: "Keep the semiconductor watchlist in monitoring mode until supply checks stabilize, and do not promote a thesis from one upbeat channel-check."
    )

    let relaunchedEngine = Engine(
        pmProfileStore: profileStore,
        pmNotebookStore: notebookStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let ownerAsk = try await relaunchedEngine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Please check the promoted notebook entry about semiconductor supply checks and remind me of the actual note.",
        source: .ui
    )
    _ = try await relaunchedEngine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)
    let request = try #require(await synthesisProvider.lastConversationRequest)

    #expect(request.recoveredContextSummary.contains(where: {
        $0.contains("Promoted communication outcome: Semiconductor supply-check note")
            && $0.contains("do not promote a thesis from one upbeat channel-check")
    }))
}

@Test("PM conversation recovery can reconstruct a bounded same-day full thread including PM replies")
func pmConversationRecoveryReconstructsBoundedSameDayThreadIncludingPMReplies() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-full-thread")
    let now = Date(timeIntervalSince1970: 1_742_087_040)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(replyBody: "Recovered the same-day thread successfully."),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Recovers full same-day PM threads.",
            createdAt: now,
            updatedAt: now
        )
    )

    let initialEngine = Engine(
        pmProfileStore: profileStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore
    )

    let session = try await initialEngine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    _ = try await initialEngine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Hold the semiconductor additions until after CPI and keep the hedge discussion open.",
        source: .ui
    )
    _ = try await initialEngine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .pm,
        senderId: "pm-1",
        body: "Understood. I will hold the semiconductor additions until after CPI and keep XLU as the cleaner hedge candidate for now.",
        source: .ui
    )
    _ = try await initialEngine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "If breadth improves after CPI, revisit the timing rather than forcing it before the print.",
        source: .ui
    )
    _ = try await initialEngine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .pm,
        senderId: "pm-1",
        body: "Agreed. I will wait for the post-CPI breadth read before revisiting timing.",
        source: .ui
    )

    let relaunchedEngine = Engine(
        pmProfileStore: profileStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let ownerAsk = try await relaunchedEngine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Please reconstruct today's full thread from our discussion, including what you told me back about CPI, the semiconductor timing, and the hedge.",
        source: .ui
    )
    _ = try await relaunchedEngine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)
    let request = try #require(await synthesisProvider.lastConversationRequest)

    #expect(request.recoveredContextSummary.contains(where: {
        $0.contains("Same-day communication thread")
            && $0.contains("owner: Hold the semiconductor additions until after CPI")
            && $0.contains("pm: Understood. I will hold the semiconductor additions until after CPI")
            && $0.contains("pm: Agreed. I will wait for the post-CPI breadth read")
    }))
}

@Test("PM conversation runtime carries a materially larger exact recent thread window for active back-and-forth")
func pmConversationRuntimeCarriesLargerExactRecentThreadWindow() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-exact-thread-window")
    let now = Date(timeIntervalSince1970: 1_742_087_120)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(replyBody: "Retained the active thread successfully."),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Keeps a larger exact-text recent thread window.",
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    for index in 0..<60 {
        _ = try await engine.createPMCommunicationMessage(
            sessionId: session.sessionId,
            senderRole: index.isMultiple(of: 2) ? .owner : .pm,
            senderId: index.isMultiple(of: 2) ? "owner" : "pm-1",
            body: index.isMultiple(of: 2)
                ? "Active thread owner detail \(index): keep the CPI hedge timing explicit for turn \(index)."
                : "Active thread PM detail \(index): acknowledged the CPI hedge timing nuance for turn \(index).",
            source: .ui
        )
    }

    let latestAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Use the active conversation itself and keep the exact CPI hedge timing detail in working memory.",
        source: .ui
    )
    let reply = try await engine.generatePMConversationReply(to: latestAsk.messageId, source: .ui)
    let request = try #require(await synthesisProvider.lastConversationRequest)
    let trace = try #require(reply.runtimeProvenance?.conversationTrace)
    let budgetTrace = try #require(trace.promptBudgetTrace)
    let recentLane = try #require(budgetTrace.lanes.first(where: { $0.lane == "recent_conversation" }))

    #expect(request.recentConversationSummary.count <= 24)
    #expect(request.recentConversationSummary.count >= 8)
    #expect(request.recentConversationSummary.contains(where: { $0.contains("latest ask") }))
    #expect(request.recentConversationSummary.contains(where: { $0.contains("Active thread PM detail 59") || $0.contains("Active thread PM detail 57") }))
    #expect(request.recentConversationSummary.contains(where: { $0.contains("Active thread owner detail 0") }) == false)
    #expect(recentLane.itemCount == request.recentConversationSummary.count)
    #expect(budgetTrace.totalPromptCharacterCount == trace.requestCharacterCount)
    #expect(budgetTrace.totalPromptCharacterCount <= budgetTrace.promptCharacterBudget)
}

@Test("Low-volume week-scale conversation stays available in the recent active-thread memory lane")
func pmConversationRuntimeCarriesLowVolumeWeekScaleRecentThreadMemory() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-week-scale-memory")
    let now = Date(timeIntervalSince1970: 1_742_200_000)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(replyBody: "Recovered week-scale context successfully."),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Keeps a low-volume week of exact PM/User conversation available for history recall.",
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    for index in 0..<120 {
        let sentAt = now.addingTimeInterval(-(6 * 24 * 60 * 60) + TimeInterval(index * 60))
        let body: String
        if index == 0 {
            body = "Week-scale anchor detail: keep the paper portfolio hedge sleeve as one short only while the long sleeve stays around 10 names."
        } else if index.isMultiple(of: 2) {
            body = "Owner week-scale detail \(index): keep the conversation memory intact for turn \(index)."
        } else {
            body = "PM week-scale detail \(index): acknowledged the prior week context for turn \(index)."
        }

        _ = try await messageStore.upsert(
            PMCommunicationMessage(
                messageId: "week-scale-message-\(index)",
                sessionId: session.sessionId,
                direction: index.isMultiple(of: 2) ? .incoming : .outgoing,
                senderRole: index.isMultiple(of: 2) ? .owner : .pm,
                senderId: index.isMultiple(of: 2) ? "owner" : "pm-1",
                body: body,
                sentAt: sentAt,
                createdAt: sentAt,
                updatedAt: sentAt
            )
        )
    }

    let latestAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "What did we say earlier this week about the hedge sleeve in the paper portfolio?",
        source: .ui
    )
    let reply = try await engine.generatePMConversationReply(to: latestAsk.messageId, source: .ui)
    let request = try #require(await synthesisProvider.lastConversationRequest)
    let trace = try #require(reply.runtimeProvenance?.conversationTrace)
    let budgetTrace = try #require(trace.promptBudgetTrace)

    #expect(request.recentConversationSummary.count <= 12)
    #expect(request.recentConversationSummary.contains(where: { $0.contains("latest ask") }))
    #expect(request.detailedCommunicationHistorySummary.contains(where: { $0.contains("Week-scale anchor detail") }))
    #expect(request.plannerMode == "owner_conversation_action_planning")
    #expect(trace.usedDetailedHistoryGrounding == true)
    #expect(budgetTrace.totalPromptCharacterCount <= budgetTrace.promptCharacterBudget)
}

@Test("Month-specific exact-entry recall works across non-April dates under accumulated PM history")
func pmConversationExactEntryRecallWorksAcrossMonthReferences() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-month-specific-entry")
    let now = Date(timeIntervalSince1970: 1_776_739_200) // 2026-04-21T12:00:00Z
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(replyBody: "Recovered the specific March portfolio entry."),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Recovers specific earlier PM/User entries across multi-month history.",
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let marchSession = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let marchOwnerDate = Date(timeIntervalSince1970: 1_772_600_100) // 2026-03-03T10:15:00Z
    let marchPMDate = Date(timeIntervalSince1970: 1_772_600_220)
    _ = try await messageStore.upsert(
        PMCommunicationMessage(
            messageId: "march-owner-portfolio",
            sessionId: marchSession.sessionId,
            direction: .incoming,
            senderRole: .owner,
            senderId: "owner",
            body: "Here is the proposed paper portfolio for the early-March version. Long positions: NVDA, TSM, META, AMZN. Short positions: NYCB, KSS.",
            sentAt: marchOwnerDate,
            createdAt: marchOwnerDate,
            updatedAt: marchOwnerDate
        )
    )
    _ = try await messageStore.upsert(
        PMCommunicationMessage(
            messageId: "march-pm-response",
            sessionId: marchSession.sessionId,
            direction: .outgoing,
            senderRole: .pm,
            senderId: "pm-1",
            body: "Understood. I’m carrying the March 3 working paper portfolio as long NVDA, TSM, META, AMZN and short NYCB, KSS.",
            sentAt: marchPMDate,
            replyToMessageId: "march-owner-portfolio",
            createdAt: marchPMDate,
            updatedAt: marchPMDate
        )
    )

    let aprilOwnerDate = Date(timeIntervalSince1970: 1_775_500_000)
    let aprilPMDate = Date(timeIntervalSince1970: 1_775_500_180)
    _ = try await messageStore.upsert(
        PMCommunicationMessage(
            messageId: "april-owner-portfolio",
            sessionId: marchSession.sessionId,
            direction: .incoming,
            senderRole: .owner,
            senderId: "owner",
            body: "Later we updated the paper portfolio to long NVDA, AVGO, AMZN and short NYCB only.",
            sentAt: aprilOwnerDate,
            createdAt: aprilOwnerDate,
            updatedAt: aprilOwnerDate
        )
    )
    _ = try await messageStore.upsert(
        PMCommunicationMessage(
            messageId: "april-pm-response",
            sessionId: marchSession.sessionId,
            direction: .outgoing,
            senderRole: .pm,
            senderId: "pm-1",
            body: "I’m treating the April revision as the newer working definition.",
            sentAt: aprilPMDate,
            replyToMessageId: "april-owner-portfolio",
            createdAt: aprilPMDate,
            updatedAt: aprilPMDate
        )
    )

    let latestAsk = try await engine.createPMCommunicationMessage(
        sessionId: marchSession.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "What was the proposed paper portfolio from your response on March 3 at 10:15 AM?",
        source: .ui
    )
    let reply = try await engine.generatePMConversationReply(to: latestAsk.messageId, source: .ui)
    let request = try #require(await synthesisProvider.lastConversationRequest)
    let trace = try #require(reply.runtimeProvenance?.conversationTrace)

    #expect(request.detailedCommunicationHistorySummary.count == 1)
    #expect(request.detailedCommunicationHistorySummary.first?.contains("Specific communication entry body window:") == true)
    #expect(request.detailedCommunicationHistorySummary.first?.contains("Long positions: NVDA, TSM, META, AMZN. Short positions: NYCB, KSS.") == true)
    #expect(request.detailedCommunicationHistorySummary.first?.contains("Later we updated the paper portfolio") == false)
    #expect(trace.usedDetailedHistoryGrounding == true)
    #expect(trace.pathKind == .modelBacked)
}

@Test("Month-scale portfolio recall avoids duplicate same-session history windows and stays within budget")
func pmConversationMonthScalePortfolioRecallAvoidsDuplicateSessionWindows() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-month-scale-history")
    let now = Date(timeIntervalSince1970: 1_776_739_200)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(replyBody: "Recovered the latest earlier-in-the-month portfolio."),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Recovers month-scale portfolio revisions without duplicating the same thread window.",
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    for week in 0..<5 {
        let ownerDate = now.addingTimeInterval(TimeInterval(-28 + (week * 7)) * 24 * 60 * 60)
        let pmDate = ownerDate.addingTimeInterval(120)
        let body: String
        switch week {
        case 2:
            body = "Here is the refreshed paper portfolio for the mid-month working version. Long positions: SONY, MDB, MELI, SHOP. Short positions: XRT, HYG."
        case 4:
            body = "Latest current proposal now is long NVDA, AVGO, AMZN and short NYCB only."
        default:
            body = "Portfolio revision week \(week): long AAPL, MSFT, META and short QQQ."
        }
        let ownerId = "month-owner-\(week)"
        _ = try await messageStore.upsert(
            PMCommunicationMessage(
                messageId: ownerId,
                sessionId: session.sessionId,
                direction: .incoming,
                senderRole: .owner,
                senderId: "owner",
                body: body,
                sentAt: ownerDate,
                createdAt: ownerDate,
                updatedAt: ownerDate
            )
        )
        _ = try await messageStore.upsert(
            PMCommunicationMessage(
                messageId: "month-pm-\(week)",
                sessionId: session.sessionId,
                direction: .outgoing,
                senderRole: .pm,
                senderId: "pm-1",
                body: "Acknowledged week \(week) portfolio revision.",
                sentAt: pmDate,
                replyToMessageId: ownerId,
                createdAt: pmDate,
                updatedAt: pmDate
            )
        )
    }

    let latestAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "What was the latest proposed paper portfolio from earlier this month?",
        source: .ui
    )
    let reply = try await engine.generatePMConversationReply(to: latestAsk.messageId, source: .ui)
    let request = try #require(await synthesisProvider.lastConversationRequest)
    let trace = try #require(reply.runtimeProvenance?.conversationTrace)
    let matchingSummaries = request.detailedCommunicationHistorySummary.filter {
        $0.contains("SONY") && $0.contains("MDB") && $0.contains("HYG")
    }

    #expect(matchingSummaries.count == 1)
    #expect(trace.usedDetailedHistoryGrounding == true)
    #expect(trace.promptBudgetTrace?.totalPromptCharacterCount ?? .max <= trace.promptBudgetTrace?.promptCharacterBudget ?? .max)
    #expect(trace.pathKind == .modelBacked)
}

@Test("Multi-month PM history keeps latest working truth authoritative and exposes prompt-profile compaction traces")
func pmConversationMultiMonthHistoryKeepsWorkingTruthAndPromptProfilesHealthy() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-multi-month-history")
    let now = Date(timeIntervalSince1970: 1_776_739_200)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let runtimeStore = PMRuntimeSettingsStore(fileURL: root.appendingPathComponent("pm-runtime-settings.json", isDirectory: false))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(replyBody: "Using the latest corrected working truth while keeping the long-horizon recall healthy."),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Maintains current working truth while handling multi-month PM/User history.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await runtimeStore.upsert(
        PMRuntimeSettings(
            runtimeIdentifier: "gpt-5",
            reasoningMode: .deliberate,
            updatedBy: "owner",
            updateSource: .userEdited,
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmRuntimeSettingsStore: runtimeStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let archiveSession = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    for cycle in 0..<14 {
        let cycleDate = now.addingTimeInterval(TimeInterval(-(110 - (cycle * 8))) * 24 * 60 * 60)
        let ownerId = "archive-owner-\(cycle)"
        let ownerBody = """
        Cycle \(cycle) proposed portfolio update. Long positions: NVDA, AVGO, AMZN, CRWD, META. Short positions: NYCB, KSS. Detailed rationale block \(cycle): \(String(repeating: "earnings discipline and revision memory ", count: 14))
        """
        _ = try await messageStore.upsert(
            PMCommunicationMessage(
                messageId: ownerId,
                sessionId: archiveSession.sessionId,
                direction: .incoming,
                senderRole: .owner,
                senderId: "owner",
                body: ownerBody,
                sentAt: cycleDate,
                createdAt: cycleDate,
                updatedAt: cycleDate
            )
        )
        _ = try await messageStore.upsert(
            PMCommunicationMessage(
                messageId: "archive-pm-\(cycle)",
                sessionId: archiveSession.sessionId,
                direction: .outgoing,
                senderRole: .pm,
                senderId: "pm-1",
                body: "PM carry-forward \(cycle): \(String(repeating: "keeping the operating context bounded and current ", count: 10))",
                sentAt: cycleDate.addingTimeInterval(180),
                replyToMessageId: ownerId,
                createdAt: cycleDate.addingTimeInterval(180),
                updatedAt: cycleDate.addingTimeInterval(180)
            )
        )
    }

    let activeSession = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    _ = try await engine.createPMCommunicationMessage(
        sessionId: activeSession.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Correction: use COST and NFLX in the current working portfolio, and drop KSS from the short sleeve.",
        source: .ui
    )
    let latestAsk = try await engine.createPMCommunicationMessage(
        sessionId: activeSession.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Given the latest correction, what is our current proposed paper portfolio and what did we say earlier this month about it?",
        source: .ui
    )
    let reply = try await engine.generatePMConversationReply(to: latestAsk.messageId, source: .ui)
    let request = try #require(await synthesisProvider.lastConversationRequest)
    let trace = try #require(reply.runtimeProvenance?.conversationTrace)
    let budgetTrace = try #require(trace.promptBudgetTrace)
    let profileTraces = trace.promptProfileTraces
    let balancedProfile = try #require(profileTraces.first(where: { $0.profile == "balanced" }))
    let compactProfile = try #require(profileTraces.first(where: { $0.profile == "compact" }))
    let minimalProfile = try #require(profileTraces.first(where: { $0.profile == "minimal" }))

    func laneCount(_ profile: PMConversationPromptProfileTrace, _ lane: String) -> Int {
        profile.lanes.first(where: { $0.lane == lane })?.itemCount ?? 0
    }

    #expect(request.recentConversationSummary.contains(where: { $0.contains("COST") && $0.contains("NFLX") && $0.contains("drop KSS") }))
    #expect(request.proposedTruthUpdateSummary.isEmpty)
    #expect(request.latestOwnerWorkingPortfolioUpdateSummary.isEmpty)
    #expect(profileTraces.count == 3)
    #expect(balancedProfile.totalPromptCharacterCount >= compactProfile.totalPromptCharacterCount)
    #expect(compactProfile.totalPromptCharacterCount >= minimalProfile.totalPromptCharacterCount)
    #expect(laneCount(balancedProfile, "recent_conversation") >= laneCount(compactProfile, "recent_conversation"))
    #expect(laneCount(compactProfile, "recent_conversation") >= laneCount(minimalProfile, "recent_conversation"))
    #expect(laneCount(balancedProfile, "detailed_history") >= laneCount(compactProfile, "detailed_history"))
    #expect(laneCount(compactProfile, "detailed_history") >= laneCount(minimalProfile, "detailed_history"))
    #expect(budgetTrace.totalPromptCharacterCount <= budgetTrace.promptCharacterBudget)
    #expect(trace.pathKind == .modelBacked)
    #expect(trace.modelProducedUsableReply == true)
}

@Test("PM conversation prompt budget trace records runtime-aware headroom and per-lane accounting")
func pmConversationPromptBudgetTraceRecordsRuntimeAwareHeadroom() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-prompt-budget-trace")
    let now = Date(timeIntervalSince1970: 1_746_100_000)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let runtimeStore = PMRuntimeSettingsStore(fileURL: root.appendingPathComponent("pm-runtime-settings.json", isDirectory: false))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(replyBody: "The latest proposed paper portfolio remains the current working list."),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Records PM prompt budgets with explicit runtime-aware headroom.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await runtimeStore.upsert(
        PMRuntimeSettings(
            runtimeIdentifier: "gpt-5.4",
            reasoningMode: .deliberate,
            updatedBy: "owner",
            updateSource: .userEdited,
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmRuntimeSettingsStore: runtimeStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "What was the latest proposed paper portfolio?",
        source: .ui
    )
    let reply = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)
    let trace = try #require(reply.runtimeProvenance?.conversationTrace)
    let budgetTrace = try #require(trace.promptBudgetTrace)
    let recentLane = try #require(budgetTrace.lanes.first(where: { $0.lane == "recent_conversation" }))
    let operatingLane = try #require(budgetTrace.lanes.first(where: { $0.lane == "operating_context" }))

    #expect(budgetTrace.totalContextWindowCharacterBudget == 120_000)
    #expect(budgetTrace.reservedOutputCharacterBudget == 32_000)
    #expect(budgetTrace.promptCharacterBudget == 88_000)
    #expect(budgetTrace.totalPromptCharacterCount <= budgetTrace.promptCharacterBudget)
    #expect(recentLane.itemCount >= 1)
    #expect(operatingLane.itemCount >= 0)
}

@Test("PM conversation synthesis request carries the PM's pending confirmation state alongside exact recent thread text")
func pmConversationRuntimeCarriesPendingConfirmationStateIntoSynthesisRequest() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-pending-open-loop")
    let now = Date(timeIntervalSince1970: 1_742_087_180)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(replyBody: "Bound the open loop successfully."),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Carries pending PM asks into synthesis.",
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    _ = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .pm,
        senderId: "pm-1",
        body: """
        Proposed reconstruction is 9 longs plus short NYCB.

        YES / NO: Freeze this proposed reconstruction as the working portfolio definition for this thread?
        """,
        source: .ui
    )
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Before we finalize that, what did you just ask me to confirm?",
        source: .ui
    )
    _ = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)
    let request = try #require(await synthesisProvider.lastConversationRequest)

    #expect(request.recentConversationSummary.contains(where: { $0.contains("latest unresolved ask") }))
    #expect(request.activeConversationStateSummary.contains(where: { $0.contains("Latest unresolved PM confirmation ask") }))
    #expect(request.activeConversationStateSummary.contains(where: { $0.contains("Freeze this proposed reconstruction") }))
}

@Test("PM conversation runtime classifies confirmed app truth, superseding updates, standing-review candidates, and conversation fragments separately")
func pmConversationRuntimeSeparatesTruthClassesAndSupersedingTopicUpdates() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-truth-classification")
    let now = Date(timeIntervalSince1970: 1_742_087_260)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let decisionStore = PMDecisionStore(decisionsDirectory: root.appendingPathComponent("decisions", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(replyBody: "Separated app truth from candidate and proposed truth successfully."),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "candidate_ideas_worth_considering",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Separates app truth from conversation and candidate ideas.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await decisionStore.upsert(
        PMDecisionRecord(
            decisionId: "decision-standing-candidates",
            pmId: "pm-1",
            title: "Standing review synthesis",
            summary: "Standing review preserved candidate names for later PM review.",
            decisionType: .recommendation,
            status: .active,
            standingReviewCandidateLongs: ["NVDA: NVDA remains the strongest standing-review long candidate"],
            standingReviewCandidateShorts: ["SMH: SMH remains the cleaner hedge candidate"],
            standingReviewCandidateThemes: ["AI infrastructure remains a candidate theme"],
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmDecisionStore: decisionStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    _ = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Keep ACN in the working book for now while we review the baseline.",
        source: .ui
    )
    _ = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .pm,
        senderId: "pm-1",
        body: "Understood. I will treat that as a working conversation assumption until app truth is clear.",
        source: .ui
    )
    _ = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Actually replace ACN with NYCB instead if we rebuild the book from today's discussion.",
        source: .ui
    )

    let latestAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Refresh me on what is current app truth versus a proposal or standing-review candidate.",
        source: .ui
    )
    let reply = try await engine.generatePMConversationReply(to: latestAsk.messageId, source: .ui)
    let request = try #require(await synthesisProvider.lastConversationRequest)
    let trace = try #require(reply.runtimeProvenance?.conversationTrace)
    let standingCandidateLane = try #require(trace.promptBudgetTrace?.lanes.first(where: { $0.lane == "standing_candidates" }))
    let fragmentLane = try #require(trace.promptBudgetTrace?.lanes.first(where: { $0.lane == "conversation_fragments" }))

    #expect(request.confirmedAppTruthSummary.contains(where: { $0.contains("none recorded") }))
    #expect(request.proposedTruthUpdateSummary.isEmpty)
    #expect(request.recentConversationSummary.contains(where: {
        $0.contains("replace ACN with NYCB")
    }))
    #expect(request.standingCandidateSummary.contains(where: {
        $0.contains("Standing-review candidate ideas only")
            && $0.contains("NVDA")
            && $0.contains("SMH")
    }))
    #expect(request.conversationFragmentSummary.isEmpty)
    #expect(standingCandidateLane.itemCount == request.standingCandidateSummary.count)
    #expect(fragmentLane.itemCount == 0)
}

@Test("Model-backed PM conversation resolution can apply a bounded working portfolio definition instruction without mutating holdings truth")
func pmConversationResolutionAppliesWorkingPortfolioDefinitionToPMInstructionPath() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-conversation-working-portfolio-apply")
    let now = Date(timeIntervalSince1970: 1_742_087_320)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let instructionStore = PMInstructionStore(instructionsDirectory: root.appendingPathComponent("instructions", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "Understood. I will carry that forward as the working paper-portfolio definition through the bounded PM instruction path.",
            resolution: PMConversationResolutionState(
                intentClass: .instruction,
                disposition: .durableApplyNow,
                workingUnderstandingSummary: "Use the conversation-derived working paper portfolio with NYCB replacing ACN until confirmed holdings are rebuilt.",
                durableTargetType: .pmInstruction,
                instructionTargetKind: .workingPortfolioDefinition,
                durableTitle: "Working paper portfolio definition",
                durableBody: "Carry the conversation-derived working paper portfolio with NYCB replacing ACN until confirmed holdings are rebuilt from app truth."
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Routes conversation-derived working definitions into bounded PM instructions.",
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmInstructionStore: instructionStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "For the working paper portfolio, replace ACN with NYCB until confirmed holdings are reconstructed from app truth.",
        source: .ui
    )
    let reply = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)
    let instructions = try await engine.listPMInstructions()
    let persistedOwnerMessage = try await engine.getPMCommunicationMessage(id: ownerAsk.messageId)

    let appliedInstruction = try #require(instructions.first)
    #expect(instructions.count == 1)
    #expect(appliedInstruction.category == "conversation_working_portfolio_definition")
    #expect(appliedInstruction.status == .active)
    #expect(appliedInstruction.body.contains("NYCB replacing ACN"))
    #expect(reply.conversationResolution?.disposition == .durableApplyNow)
    #expect(reply.conversationResolution?.durableTargetType == .pmInstruction)
    #expect(reply.conversationResolution?.instructionTargetKind == .workingPortfolioDefinition)
    #expect(reply.conversationResolution?.durableTargetId == appliedInstruction.instructionId)
    #expect(persistedOwnerMessage.promotion?.targetType == .instruction)
    #expect(persistedOwnerMessage.promotion?.targetId == appliedInstruction.instructionId)
}

@Test("Conversation-derived working portfolio instructions supersede older versions through the bounded PM instruction path")
func pmConversationResolutionArchivesSupersededWorkingPortfolioInstructions() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-conversation-working-portfolio-supersession")
    let now = Date(timeIntervalSince1970: 1_742_087_380)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let instructionStore = PMInstructionStore(instructionsDirectory: root.appendingPathComponent("instructions", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutputs: [
            PMConversationOpenAISynthesisOutput(
                replyBody: "I will carry forward the first working portfolio definition through the bounded PM instruction path.",
                resolution: PMConversationResolutionState(
                    intentClass: .instruction,
                    disposition: .durableApplyNow,
                    workingUnderstandingSummary: "Use ACN and MSFT as the conversation-derived working portfolio core until app truth is rebuilt.",
                    durableTargetType: .pmInstruction,
                    instructionTargetKind: .workingPortfolioDefinition,
                    durableTitle: "Working paper portfolio definition",
                    durableBody: "Carry the conversation-derived working paper portfolio with ACN and MSFT as the core names until confirmed holdings are rebuilt from app truth."
                )
            ),
            PMConversationOpenAISynthesisOutput(
                replyBody: "I updated the working portfolio definition and archived the older conversation-derived version.",
                resolution: PMConversationResolutionState(
                    intentClass: .correction,
                    disposition: .durableApplyNow,
                    workingUnderstandingSummary: "Replace ACN with NYCB in the conversation-derived working portfolio definition while keeping MSFT.",
                    durableTargetType: .pmInstruction,
                    instructionTargetKind: .workingPortfolioDefinition,
                    durableTitle: "Working paper portfolio definition",
                    durableBody: "Carry the conversation-derived working paper portfolio with NYCB and MSFT, replacing the earlier ACN version, until confirmed holdings are rebuilt from app truth."
                )
            )
        ],
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Archives superseded conversation-derived working definitions.",
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmInstructionStore: instructionStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let firstOwnerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "For the working paper portfolio, keep ACN and MSFT as the core names until app truth is rebuilt.",
        source: .ui
    )
    _ = try await engine.generatePMConversationReply(to: firstOwnerAsk.messageId, source: .ui)

    let correctionOwnerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Correction: replace ACN with NYCB in that working paper portfolio definition, but keep MSFT.",
        source: .ui
    )
    let correctionReply = try await engine.generatePMConversationReply(to: correctionOwnerAsk.messageId, source: .ui)
    let instructions = try await engine.listPMInstructions()
        .filter { $0.category == "conversation_working_portfolio_definition" }
        .sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.instructionId < rhs.instructionId
            }
            return lhs.updatedAt < rhs.updatedAt
        }

    #expect(instructions.count == 2)
    #expect(instructions.filter { $0.status == .active }.count == 1)
    #expect(instructions.filter { $0.status == .archived }.count == 1)
    #expect(instructions.last?.status == .active)
    #expect(instructions.last?.body.contains("NYCB and MSFT") == true)
    #expect(instructions.first?.body.contains("ACN and MSFT") == true)
    #expect(correctionReply.conversationResolution?.intentClass == .correction)
    #expect(correctionReply.conversationResolution?.durableTargetId == instructions.last?.instructionId)
}

@Test("Ambiguous short PM conversation replies preserve the pending ask and request targeted clarification instead of overwriting durable truth")
func pmConversationResolutionKeepsPendingAskWhenReplyStaysAmbiguous() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-conversation-ambiguity-clarification")
    let now = Date(timeIntervalSince1970: 1_742_087_430)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let instructionStore = PMInstructionStore(instructionsDirectory: root.appendingPathComponent("instructions", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "I still need one clarification: do you want me to freeze this as the working paper portfolio definition or revise it first?",
            resolution: PMConversationResolutionState(
                intentClass: .clarification,
                disposition: .clarificationRequired,
                ambiguitySummary: "The owner's short reply did not resolve whether the proposed working paper portfolio should be frozen or revised.",
                pendingAsk: PMConversationPendingAskState(
                    kind: .yesNoConfirmation,
                    promptSummary: "Freeze this proposed reconstruction as the working paper portfolio definition for this thread?",
                    workingUnderstandingSummary: "The PM reconstructed a conversation-derived working portfolio definition that still needs explicit owner confirmation.",
                    durableTargetType: .pmInstruction,
                    instructionTargetKind: .workingPortfolioDefinition,
                    durableTitle: "Working paper portfolio definition",
                    durableBody: "Carry the conversation-derived working paper portfolio definition only after explicit owner confirmation."
                )
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Keeps ambiguous conversation outcomes in clarification state.",
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmInstructionStore: instructionStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    _ = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .pm,
        senderId: "pm-1",
        body: """
        Proposed reconstruction is 9 longs plus short NYCB.

        YES / NO: Freeze this proposed reconstruction as the working paper portfolio definition for this thread?
        """,
        conversationResolution: PMConversationResolutionState(
            intentClass: .general,
            disposition: .durableChangeProposed,
            workingUnderstandingSummary: "The PM proposed a working paper portfolio definition that still needs explicit owner confirmation.",
            pendingAsk: PMConversationPendingAskState(
                kind: .yesNoConfirmation,
                promptSummary: "Freeze this proposed reconstruction as the working paper portfolio definition for this thread?",
                workingUnderstandingSummary: "The PM reconstructed a working paper portfolio definition that still needs explicit owner confirmation.",
                durableTargetType: .pmInstruction,
                instructionTargetKind: .workingPortfolioDefinition,
                durableTitle: "Working paper portfolio definition",
                durableBody: "Carry the conversation-derived working paper portfolio definition only after explicit owner confirmation."
            ),
            sourceMessageIds: []
        ),
        source: .ui
    )
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Maybe.",
        source: .ui
    )
    let reply = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)
    let instructions = try await engine.listPMInstructions()

    #expect(instructions.isEmpty)
    #expect(reply.conversationResolution?.intentClass == .clarification)
    #expect(reply.conversationResolution?.disposition == .clarificationRequired)
    #expect(reply.conversationResolution?.pendingAsk?.promptSummary.contains("Freeze this proposed reconstruction") == true)
    #expect(reply.conversationResolution?.pendingAsk?.durableTargetType == .pmInstruction)
}

@Test("Standing-review memory preserves analyst conclusions and stays separate from later owner conversation")
func standingReviewMemoryPreservesAnalystConclusionsAndStaysSeparateFromLaterConversation() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-standing-review-memory-separation")
    let now = Date(timeIntervalSince1970: 1_742_087_200)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let notebookStore = PMNotebookStore(notebookDirectory: root.appendingPathComponent("notebook", isDirectory: true))
    let decisionStore = PMDecisionStore(decisionsDirectory: root.appendingPathComponent("decisions", isDirectory: true))
    let approvalStore = PMApprovalRequestStore(approvalRequestsDirectory: root.appendingPathComponent("approvals", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let charterStore = AnalystCharterStore(chartersDirectory: root.appendingPathComponent("charters", isDirectory: true))
    let standingReportStore = AnalystStandingReportStore(reportsDirectory: root.appendingPathComponent("standing_reports", isDirectory: true))
    let scheduleStore = ScheduleStore(fileURL: root.appendingPathComponent("schedules.json", isDirectory: false))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(replyBody: "Recovered standing-review memory successfully."),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "candidate_ideas_worth_considering",
            summary: "Standing review preserved the analyst candidate list cleanly.",
            recommendedAction: "Keep the candidate list in PM background review."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Preserves standing-review conclusions separately from PM conversation.",
            createdAt: now,
            updatedAt: now
        )
    )

    let initialEngine = Engine(
        pmProfileStore: profileStore,
        pmNotebookStore: notebookStore,
        pmDecisionStore: decisionStore,
        pmApprovalRequestStore: approvalStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        analystCharterStore: charterStore,
        analystStandingReportStore: standingReportStore,
        scheduleStore: scheduleStore
    )

    _ = try await initialEngine.listAnalystCharters()
    _ = try await initialEngine.upsertAnalystStandingReport(
        makeStandingReviewWakeTestReport(
            reportId: "standing-report-analyst-memory-1",
            deliveredAt: now,
            updatedAt: now,
            sections: [
                AnalystStandingReportSection(
                    sectionId: "long-ideas",
                    kind: .longIdeas,
                    items: [
                        AnalystStandingReportItem(
                            itemId: "nvda-long",
                            headline: "NVDA remains the highest-conviction long candidate",
                            detail: "AI infrastructure backlog still supports the long case.",
                            symbol: "NVDA",
                            stance: .long,
                            conviction: 9
                        )
                    ]
                ),
                AnalystStandingReportSection(
                    sectionId: "short-ideas",
                    kind: .shortIdeas,
                    items: [
                        AnalystStandingReportItem(
                            itemId: "smh-hedge",
                            headline: "SMH hedge remains the cleaner short-side pressure test",
                            detail: "Semiconductor beta still makes it the cleaner hedge candidate.",
                            symbol: "SMH",
                            stance: .short,
                            conviction: 7
                        )
                    ]
                ),
                AnalystStandingReportSection(
                    sectionId: "follow-up",
                    kind: .followUp,
                    items: [
                        AnalystStandingReportItem(
                            itemId: "follow-up-1",
                            headline: "Re-check supply-chain commentary before the next cycle",
                            detail: "A cleaner update could improve conviction."
                        )
                    ]
                )
            ]
        ),
        source: AuditEventSource.ui
    )
    _ = try await initialEngine.completePendingStandingReviewCycle(source: AuditEventSource.ui)

    let decisions = try await initialEngine.listPMDecisions()
    let standingDecision = try #require(decisions.first(where: { $0.primaryStandingReportId == "standing-report-analyst-memory-1" }))
    #expect(standingDecision.standingReviewCandidateLongs == ["NVDA: NVDA remains the highest-conviction long candidate"])
    #expect(standingDecision.standingReviewCandidateShorts == ["SMH: SMH hedge remains the cleaner short-side pressure test"])
    #expect(standingDecision.standingReviewFollowUpItems == ["Re-check supply-chain commentary before the next cycle"])

    let session = try await initialEngine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    _ = try await initialEngine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: PMCommunicationSenderRole.owner,
        senderId: "owner",
        body: "From our later conversation, keep cash high and do not add any new longs until I say so.",
        source: AuditEventSource.ui
    )
    _ = try await initialEngine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: PMCommunicationSenderRole.pm,
        senderId: "pm-1",
        body: "Understood. I will keep that owner conversation direction separate from the standing-review record.",
        source: AuditEventSource.ui
    )

    let relaunchedEngine = Engine(
        pmProfileStore: profileStore,
        pmNotebookStore: notebookStore,
        pmDecisionStore: decisionStore,
        pmApprovalRequestStore: approvalStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        analystCharterStore: charterStore,
        analystStandingReportStore: standingReportStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider,
        scheduleStore: scheduleStore
    )

    let ownerAsk = try await relaunchedEngine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: PMCommunicationSenderRole.owner,
        senderId: "owner",
        body: "Please summarize what you preserved from standing-report review, especially the long and short ideas, not our later conversation.",
        source: AuditEventSource.ui
    )
    _ = try await relaunchedEngine.generatePMConversationReply(to: ownerAsk.messageId, source: AuditEventSource.ui)
    let request = try #require(await synthesisProvider.lastConversationRequest)

    #expect(request.plannerMode == "owner_conversation_action_planning")
    #expect(request.recoveredContextSummary.contains(where: {
        $0.contains("Standing-review memory:")
            && $0.contains("NVDA: NVDA remains the highest-conviction long candidate")
            && $0.contains("SMH: SMH hedge remains the cleaner short-side pressure test")
    }))
    #expect(request.recoveredContextSummary.contains(where: { $0.contains("cash high") }) == false)
}

@Test("PM runtime invocation failures record an honest system note instead of waiting forever")
func pmRuntimeInvocationFailuresRecordHonestSystemNote() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-runtime-failure")
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let runtimeSettingsStore = PMRuntimeSettingsStore(
        fileURL: root.appendingPathComponent("pm_runtime_settings.json", isDirectory: false)
    )

    _ = try await runtimeSettingsStore.upsert(
        PMRuntimeSettings(
            runtimeIdentifier: "bad runtime!",
            reasoningMode: .deliberate,
            validationStatus: nil,
            lastKnownGoodRuntime: nil,
            lastFallback: nil,
            updatedBy: "human owner",
            updateSource: .userEdited,
            createdAt: Date(timeIntervalSince1970: 1_742_000_027),
            updatedAt: Date(timeIntervalSince1970: 1_742_000_027)
        )
    )

    let engine = Engine(
        pmRuntimeSettingsStore: runtimeSettingsStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession()
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Please review the current Portfolio Strategy Brief and tell me what stands out.",
        source: .ui
    )

    await #expect(throws: RuntimeSelectionResolutionError.self) {
        _ = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)
    }

    let messages = try await engine.listPMCommunicationMessages()
        .filter { $0.sessionId == session.sessionId }

    #expect(messages.count == 2)
    #expect(messages.contains { $0.senderRole == .owner })
    let systemNote = try #require(messages.first(where: { $0.senderRole == .system }))
    #expect(systemNote.replyToMessageId == ownerAsk.messageId)
    #expect(systemNote.body.contains("PM runtime is invalid and no last-known-good fallback is available") == true)
}

@Test("Engine reactivates the in-app PM/User communication session when it was previously closed")
func engineReactivatesClosedInAppPMUserCommunicationSession() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-reactivate")
    let now = Date(timeIntervalSince1970: 1_742_000_050)
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let engine = Engine(pmCommunicationSessionStore: sessionStore)

    _ = try await sessionStore.upsert(
        PMCommunicationSession(
            sessionId: "pm-user-in-app-pm-1",
            channel: .inApp,
            pmId: "pm-1",
            participantId: "owner",
            participantDisplayName: "Owner",
            status: .closed,
            createdAt: now,
            updatedAt: now
        )
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")

    #expect(session.status == .active)
    #expect(session.sessionId == "pm-user-in-app-pm-1")
}

@Test("Communication promotion creates bounded PM durable records and updates promotion linkage")
func communicationPromotionCreatesDurableRecordsAndPromotionLinkage() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-promotion")
    let now = Date(timeIntervalSince1970: 1_742_000_100)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let notebookStore = PMNotebookStore(notebookDirectory: root.appendingPathComponent("notebook", isDirectory: true))
    let instructionStore = PMInstructionStore(instructionsDirectory: root.appendingPathComponent("instructions", isDirectory: true))
    let decisionStore = PMDecisionStore(decisionsDirectory: root.appendingPathComponent("decisions", isDirectory: true))
    let approvalStore = PMApprovalRequestStore(approvalRequestsDirectory: root.appendingPathComponent("approval_requests", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let delegationStore = PMDelegationStore(delegationsDirectory: root.appendingPathComponent("delegations", isDirectory: true))
    let charterStore = AnalystCharterStore(chartersDirectory: root.appendingPathComponent("charters", isDirectory: true))

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Promotes communication into durable records.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await charterStore.upsert(
        AnalystCharter(
            charterId: "bench-sector-technology",
            analystId: "tech-analyst",
            title: "Technology Analyst",
            coverageScope: "Technology equities",
            strategyFamily: "sector",
            summary: "Technology review",
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmInstructionStore: instructionStore,
        pmNotebookStore: notebookStore,
        pmDecisionStore: decisionStore,
        pmApprovalRequestStore: approvalStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        pmDelegationStore: delegationStore,
        analystCharterStore: charterStore
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")

    let notebookMessage = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: PMCommunicationSenderRole.owner,
        body: "Keep owner-facing escalation notes concise."
    )
    let notebook = try await engine.promotePMCommunicationMessageToNotebookEntry(
        messageId: notebookMessage.messageId,
        pmId: "pm-1",
        title: "Owner preference",
        body: "Keep owner-facing escalation notes concise."
    )

    let instructionMessage = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: PMCommunicationSenderRole.pm,
        body: "Treat this as a standing operating instruction."
    )
    let instruction = try await engine.promotePMCommunicationMessageToInstruction(
        messageId: instructionMessage.messageId,
        pmId: "pm-1",
        title: "Standing communication instruction",
        body: "Use concise PM/User language before escalating broader workflow detail."
    )

    let decisionMessage = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: PMCommunicationSenderRole.pm,
        body: "Current view: hold exposure steady pending stronger evidence."
    )
    let decision = try await engine.promotePMCommunicationMessageToDecision(
        messageId: decisionMessage.messageId,
        pmId: "pm-1",
        title: "Hold exposure steady",
        summary: "Maintain current sizing until the PM has stronger evidence."
    )

    let approvalMessage = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: PMCommunicationSenderRole.pm,
        body: "Please review this bounded approval request."
    )
    let approvalRequest = try await engine.promotePMCommunicationMessageToApprovalRequest(
        messageId: approvalMessage.messageId,
        pmId: "pm-1",
        subject: "Review PM recommendation",
        rationale: "Owner review is needed before any consequential portfolio action."
    )

    let delegationMessage = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: PMCommunicationSenderRole.owner,
        body: "Please route this question to the technology analyst."
    )
    let delegation = try await engine.promotePMCommunicationMessageToDelegation(
        messageId: delegationMessage.messageId,
        pmId: "pm-1",
        charterId: "bench-sector-technology",
        title: "Technology follow-up",
        rationale: "Promoted from in-app PM/User communication for bounded analyst review."
    )

    let messages = try await engine.listPMCommunicationMessages()
    let promotedNotebookMessage = try #require(messages.first(where: { $0.messageId == notebookMessage.messageId }))
    let promotedInstructionMessage = try #require(messages.first(where: { $0.messageId == instructionMessage.messageId }))
    let promotedDecisionMessage = try #require(messages.first(where: { $0.messageId == decisionMessage.messageId }))
    let promotedApprovalMessage = try #require(messages.first(where: { $0.messageId == approvalMessage.messageId }))
    let promotedDelegationMessage = try #require(messages.first(where: { $0.messageId == delegationMessage.messageId }))

    #expect(notebook.pmId == "pm-1")
    #expect(instruction.category == "communication_promotion")
    #expect(decision.summary.contains("stronger evidence"))
    #expect(approvalRequest.status == .pending)
    #expect(delegation.analystId == "tech-analyst")
    #expect(promotedNotebookMessage.promotion?.targetType == .notebookEntry)
    #expect(promotedNotebookMessage.promotion?.targetId == notebook.entryId)
    #expect(promotedInstructionMessage.promotion?.targetType == .instruction)
    #expect(promotedInstructionMessage.promotion?.targetId == instruction.instructionId)
    #expect(promotedDecisionMessage.promotion?.targetType == .decision)
    #expect(promotedDecisionMessage.promotion?.targetId == decision.decisionId)
    #expect(promotedApprovalMessage.promotion?.targetType == .approvalRequest)
    #expect(promotedApprovalMessage.promotion?.targetId == approvalRequest.approvalRequestId)
    #expect(promotedDelegationMessage.promotion?.targetType == .delegation)
    #expect(promotedDelegationMessage.promotion?.targetId == delegation.delegationId)
}

@Test("Conversation-derived interaction memory stays durable and source-linked without replaying raw transcript")
func communicationDerivedInteractionMemoryCreatesDurablePreferenceMemory() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-interaction-memory")
    let now = Date(timeIntervalSince1970: 1_742_000_150)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let interactionMemoryStore = PMInteractionMemoryStore(interactionMemoryDirectory: root.appendingPathComponent("interaction_memory", isDirectory: true))

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Carries durable interaction memory forward.",
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmInteractionMemoryStore: interactionMemoryStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let message = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: PMCommunicationSenderRole.owner,
        senderId: "owner",
        body: "Before concentrated adds, I want downside analysis and a crisp memo."
    )

    let memory = try await engine.createPMInteractionMemoryFromCommunicationMessage(
        messageId: message.messageId,
        pmId: "pm-1",
        kind: PMInteractionMemoryKind.ownerPreference,
        title: "Downside work before concentrated adds",
        summary: "Before concentrated adds, the owner wants downside analysis and a concise memo.",
        symbols: ["NVDA"],
        themes: ["AI"],
        riskPostures: ["Moderate"],
        recommendationTypes: [PMApprovalRequestType.portfolioAction.rawValue]
    )

    let memories = try await engine.listPMInteractionMemories()
    let stored = try #require(memories.first)
    let messages = try await engine.listPMCommunicationMessages()
    let storedMessage = try #require(messages.first(where: { $0.messageId == message.messageId }))

    #expect(stored.memoryId == memory.memoryId)
    #expect(stored.sourceCommunicationMessageId == message.messageId)
    #expect(storedMessage.promotion == nil)
}

private func makePMCommunicationTempDirectory(name: String) -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("TradingKitTests", isDirectory: true)
        .appendingPathComponent(name + "-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.removeItem(at: root)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private final class PMCommunicationLockedDateSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Date]
    private var index = 0

    init(_ values: [Date]) {
        self.values = values
    }

    func next() -> Date {
        lock.lock()
        defer { lock.unlock() }
        guard values.isEmpty == false else { return Date(timeIntervalSince1970: 0) }
        let value = values[min(index, values.count - 1)]
        index += 1
        return value
    }
}

private func makePMConversationAllSeededSkillUsageSummaries() -> [AgentSkillUsageSummary] {
    [
        AgentSkillUsageSummary(
            skillId: AgentSkillSeed.disconfirmingEvidenceChecklistID,
            skillTitle: "Disconfirming Evidence Checklist",
            requirement: .recommended,
            usage: .applied,
            usageSummary: "Checked what would weaken the Technology Analyst thesis."
        ),
        AgentSkillUsageSummary(
            skillId: AgentSkillSeed.portfolioFitRiskLensID,
            skillTitle: "Portfolio Fit & Risk Lens",
            requirement: .recommended,
            usage: .applied,
            usageSummary: "Mapped the technology signal back to current portfolio and watchlist relevance."
        ),
        AgentSkillUsageSummary(
            skillId: AgentSkillSeed.sourceQualityCorroborationID,
            skillTitle: "Source Quality And Corroboration",
            requirement: .recommended,
            usage: .considered,
            usageSummary: "Separated app-owned news from supplemental support and missing source gaps."
        ),
        AgentSkillUsageSummary(
            skillId: AgentSkillSeed.longShortCandidatePressureTestID,
            skillTitle: "Long / Short Candidate Pressure Test",
            requirement: .available,
            usage: .applied,
            usageSummary: "Pressure-tested candidate long and short implications without creating authority."
        )
    ]
}

private func makeStandingReviewWakeTestReport(
    reportId: String,
    deliveredAt: Date,
    updatedAt: Date,
    sections: [AnalystStandingReportSection] = [],
    openQuestions: [String] = []
) -> AnalystStandingReport {
    AnalystStandingReport(
        reportId: reportId,
        analystId: "bench-overlay-macro-international-analyst",
        charterId: "bench-overlay-macro-international",
        scheduleId: "standing-report-bench-overlay-macro-international",
        memoId: "memo-\(reportId)",
        title: "Macro and International Analyst Standing Report",
        summary: "Rates sensitivity remains queued for PM review.",
        cadenceIntervalSec: 12 * 3_600,
        reportingWindowSummary: "Past 12 hours",
        portfolioScopeSummary: "Cross-sector macro overlay",
        headlineView: "Rates sensitivity remains a PM review item.",
        portfolioRelevanceSummary: "Macro context still matters for current positions.",
        openQuestions: openQuestions,
        sections: sections,
        deliveredToPMInboxAt: deliveredAt,
        createdAt: deliveredAt,
        updatedAt: updatedAt
    )
}

@Test("Conversation-derived strategy brief revision updates the single brief and keeps communication as input only")
func conversationDerivedStrategyBriefRevisionUpdatesSingletonBrief() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-strategy-brief-revision")
    let now = Date(timeIntervalSince1970: 1_742_000_200)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let strategyBriefStore = PortfolioStrategyBriefStore(fileURL: root.appendingPathComponent("portfolio_strategy_brief.json", isDirectory: false))

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Updates the strategy brief from owner direction.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await strategyBriefStore.upsert(
        PortfolioStrategyBrief(
            title: "Current Portfolio Strategy Brief",
            documentBody: """
            ## Objective
            Compound steadily through quality technology exposure.

            ## Review Posture
            Escalate only when strategy posture may need to change.
            """,
            objectiveSummary: "",
            currentRiskPosture: "",
            reviewEscalationPosture: "",
            updatedBy: "human owner",
            updateSource: .userEdited,
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        portfolioStrategyBriefStore: strategyBriefStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerInstruction = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: PMCommunicationSenderRole.owner,
        senderId: "owner",
        body: "Shift the strategy toward more cash buffering around earnings and spell that out in the brief."
    )

    let updated = try await engine.revisePortfolioStrategyBriefFromCommunicationMessage(
        messageId: ownerInstruction.messageId,
        title: "Current Portfolio Strategy Brief",
        documentBody: """
        ## Objective
        Compound steadily through quality technology exposure while keeping more cash flexibility around earnings.

        ## Current Risk Posture
        Moderate with tighter review around earnings-related gaps.

        ## Review Posture
        Escalate strategy posture changes to PM review before any owner-facing action.

        ## Operating Notes
        Keep this long-form appendix visible in the shared brief so the owner can confirm the exact saved document after reload.
        """,
        updatedBy: "Primary PM",
        revisionSummary: "Conversation-derived revision from owner instruction: add more cash buffering around earnings.",
        source: AuditEventSource.ui
    )
    let fetched = try await engine.getPortfolioStrategyBrief()

    let messages = try await engine.listPMCommunicationMessages()
    let revisedMessage = try #require(messages.first(where: { $0.messageId == ownerInstruction.messageId }))

    #expect(updated.briefId == PortfolioStrategyBrief.singletonID)
    #expect(updated.updateSource == PortfolioStrategyBriefUpdateSource.conversationDerived)
    #expect(updated.updatedBy == "Primary PM")
    #expect(updated.revisionSummary?.contains("cash buffering around earnings") == true)
    #expect(updated.sourceCommunicationMessageId == ownerInstruction.messageId)
    #expect(updated.objectiveSummary.contains("cash flexibility around earnings"))
    #expect(updated.primaryDocumentBody.contains("## Operating Notes"))
    #expect(updated.primaryDocumentBody.contains("exact saved document after reload"))
    #expect(revisedMessage.promotion?.targetType == .strategyBrief)
    #expect(revisedMessage.promotion?.targetId == PortfolioStrategyBrief.singletonID)
    #expect(updated.documentBody?.contains(ownerInstruction.body) == false)
    #expect(fetched.documentBody == updated.documentBody)
    #expect(fetched.revisionSummary == updated.revisionSummary)
    #expect(fetched.primaryDocumentBody.contains("## Operating Notes"))
}

@Test("Model-backed PM replies persist a hidden action plan while the visible reply stays natural")
func modelBackedPMRepliesPersistHiddenActionPlansWhileVisibleReplyStaysNatural() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-hidden-action-plan")
    let now = Date(timeIntervalSince1970: 1_746_000_000)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "I’d keep the discussion focused on the names with the clearest catalyst support first.",
            actionPlan: PMConversationActionPlan(
                summary: "Answer the owner directly with no additional side effect.",
                actions: [
                    PMConversationActionIntent(
                        actionType: .answerOnly,
                        summary: "Answer only.",
                        sourceMessageIds: []
                    )
                ]
            ),
            resolution: PMConversationResolutionState(
                intentClass: .general,
                disposition: .conversationOnly
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Keeps the hidden action plan separate from the visible reply.",
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "How would you frame the current discussion around the paper portfolio?",
        source: .ui
    )
    let reply = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)
    let request = try #require(await synthesisProvider.lastConversationRequest)
    let actionPlan = try #require(reply.conversationActionPlan)

    #expect(request.plannerMode == "owner_conversation_action_planning")
    #expect(reply.body.contains("actionPlan") == false)
    #expect(reply.body.contains("answer_only") == false)
    #expect(actionPlan.actions.first?.actionType == .answerOnly)
}

@Test("Hidden PM instruction actions are validated through the bounded instruction apply path")
func hiddenPMInstructionActionsUseBoundedInstructionApplyPath() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-hidden-instruction-action")
    let now = Date(timeIntervalSince1970: 1_746_000_100)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let instructionStore = PMInstructionStore(instructionsDirectory: root.appendingPathComponent("instructions", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "Under your latest instruction, I’ll carry that forward as the working paper-portfolio definition.",
            actionPlan: PMConversationActionPlan(
                summary: "Update the conversation-owned working portfolio definition and record the bounded PM instruction.",
                actions: [
                    PMConversationActionIntent(
                        actionType: .upsertPMInstruction,
                        summary: "Carry forward the latest proposed working paper portfolio definition.",
                        title: "Working paper portfolio definition",
                        body: "Long NVDA, MSFT, and AVGO with NYCB as the working short until holdings truth is rebuilt.",
                        instructionTargetKind: .workingPortfolioDefinition,
                        operatingTruthKind: .workingPortfolioDefinition,
                        sourceMessageIds: []
                    )
                ]
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Promotes bounded PM instructions from model-chosen action plans.",
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmInstructionStore: instructionStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Use NVDA, MSFT, and AVGO as the current proposed long sleeve with NYCB as the working short.",
        source: .ui
    )
    let reply = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)

    let instructions = try await engine.listPMInstructions()
    let stored = try #require(instructions.last)
    #expect(stored.title == "Working paper portfolio definition")
    #expect(stored.category == "conversation_working_portfolio_definition")
    #expect(stored.body.contains("NYCB"))
    #expect(reply.conversationResolution?.durableTargetType == .pmInstruction)
    #expect(reply.conversationResolution?.durableTargetId == stored.instructionId)
    #expect(reply.conversationActionPlan?.actions.first?.targetId == stored.instructionId)
}

@Test("Hidden runtime-setting actions update the bounded PM runtime store safely")
func hiddenRuntimeSettingActionsUpdateBoundedPMRuntimeStoreSafely() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-hidden-runtime-action")
    let now = Date(timeIntervalSince1970: 1_746_000_200)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let runtimeStore = PMRuntimeSettingsStore(fileURL: root.appendingPathComponent("pm-runtime-settings.json", isDirectory: false))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "I’ll switch the PM runtime to the more deliberate setting you asked for and keep the rest of the workflow unchanged.",
            actionPlan: PMConversationActionPlan(
                summary: "Update the bounded PM runtime setting.",
                actions: [
                    PMConversationActionIntent(
                        actionType: .updateRuntimeSetting,
                        summary: "Set the PM runtime to gpt-5.4 with deliberate reasoning.",
                        runtimeSettingScope: .pm,
                        runtimeIdentifier: "gpt-5.4",
                        reasoningMode: .deliberate,
                        sourceMessageIds: []
                    )
                ]
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Updates PM runtime settings through hidden validated action plans.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await runtimeStore.upsert(
        PMRuntimeSettings(
            runtimeIdentifier: "gpt-5",
            reasoningMode: .standard,
            updatedBy: "owner",
            updateSource: .userEdited,
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmRuntimeSettingsStore: runtimeStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Move the PM runtime to gpt-5.4 with deliberate reasoning.",
        source: .ui
    )
    let reply = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)
    let settings = try await engine.getPMRuntimeSettings()

    #expect(settings.runtimeIdentifier == "gpt-5.4")
    #expect(settings.reasoningMode == .deliberate)
    #expect(reply.conversationActionPlan?.actions.first?.targetId == PMRuntimeSettings.singletonID)
}

@Test("Hidden analyst-charter actions update the bounded charter store safely")
func hiddenAnalystCharterActionsUpdateBoundedCharterStoreSafely() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-hidden-charter-action")
    let now = Date(timeIntervalSince1970: 1_746_000_300)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let charterStore = AnalystCharterStore(chartersDirectory: root.appendingPathComponent("charters", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "I’ll tighten that analyst charter so the scope and escalation rule match your latest direction.",
            actionPlan: PMConversationActionPlan(
                summary: "Update the consumer analyst charter.",
                actions: [
                    PMConversationActionIntent(
                        actionType: .updateAnalystCharter,
                        summary: "Consumer Analyst should focus on low-ticket resilience and tighten escalation around material demand changes.",
                        body: "## Scope\nCover low-ticket resilience, demand shifts, and margin pressure.\n\n## Escalation\nEscalate only when the development is material to the active paper portfolio discussion.",
                        detail: "Conversation-driven charter refinement for the consumer analyst.",
                        charterId: "charter-consumer-test",
                        sourceMessageIds: []
                    )
                ]
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Updates analyst charters through bounded hidden action plans.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await charterStore.upsert(
        AnalystCharter(
            charterId: "charter-consumer-test",
            analystId: "analyst-consumer-test",
            title: "Consumer Analyst",
            coverageScope: "US consumer",
            strategyFamily: "Long/Short Equity",
            summary: "Old summary",
            documentBody: "Old body",
            updatedBy: "owner",
            updateSource: .userEdited,
            createdAt: now,
            updatedAt: now
        )
    )

    let store = Store()
    let engine = Engine(
        store: store,
        pmProfileStore: profileStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        analystCharterStore: charterStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )
    let charterUpdateEvent = Task {
        await waitForPMWorkflowStoreEvent(
            named: "analyst_charter_updated",
            in: store.events
        )
    }

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: PMCommunicationSenderRole.owner,
        senderId: "owner",
        body: "Tighten the consumer analyst charter around low-ticket resilience and demand-change escalation.",
        source: AuditEventSource.ui
    )
    _ = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: AuditEventSource.ui)
    let charter = try await engine.getAnalystCharter(id: "charter-consumer-test")

    #expect(charter.summary.contains("low-ticket resilience"))
    #expect(charter.documentBody?.contains("Old body") == true)
    #expect(charter.documentBody?.contains("Escalation") == true)
    #expect(charter.revisionSummary?.contains("Conversation-driven charter refinement") == true)
    #expect(charter.updateSource == .pmConversation)
    #expect(await charterUpdateEvent.value == true)
}

@Test("Hidden Recent News charter action resolves canonical charter and appends material RSS source-article rule")
func hiddenRecentNewsCharterActionResolvesCanonicalCharterAndAppendsRSSSourceRule() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-recent-news-charter-action")
    let now = Date(timeIntervalSince1970: 1_746_000_330)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let instructionStore = PMInstructionStore(instructionsDirectory: root.appendingPathComponent("instructions", isDirectory: true))
    let charterStore = AnalystCharterStore(chartersDirectory: root.appendingPathComponent("charters", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "I’ll apply that Recent News Analyst charter update through the app-owned charter store now.",
            actionPlan: PMConversationActionPlan(
                summary: "Apply requested Recent News Analyst charter update.",
                actions: [
                    PMConversationActionIntent(
                        actionType: .updateAnalystCharter,
                        summary: "Modify the Recent News Analyst charter to require full linked-article review for potentially material RSS items.",
                        title: "Recent News Analyst charter update: require full linked-article review",
                        body: "Add requirement: For app-owned news brought into the app via RSS, if an item appears potentially material, the analyst must open the linked source article and read/review the full article. The analyst must not rely only on the RSS headline, snippet, or feed text when assessing materiality. If the linked article is inaccessible, the analyst should explicitly note that limitation.",
                        detail: "Update the Recent News Analyst charter to require source-article review for material RSS/news items.",
                        sourceMessageIds: []
                    )
                ]
            ),
            resolution: PMConversationResolutionState(
                intentClass: .instruction,
                disposition: .durableApplyNow,
                workingUnderstandingSummary: "Owner asked to update the Recent News Analyst charter.",
                operatingTruthKind: .operatingInstruction,
                operatingTruthSummary: "Owner asked to update the Recent News Analyst charter.",
                operatingTruthBody: "Record the linked-source article review requirement for Recent News Analyst.",
                durableTargetType: .pmInstruction,
                instructionTargetKind: .operatingInstruction,
                durableTitle: "Recent News Analyst linked-source review requirement",
                durableBody: "Require full linked-source article review for material RSS items."
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Updates canonical analyst charters through bounded hidden action plans.",
            createdAt: now,
            updatedAt: now
        )
    )

    let store = Store()
    let engine = Engine(
        store: store,
        pmProfileStore: profileStore,
        pmInstructionStore: instructionStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        analystCharterStore: charterStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )
    let charterUpdateEvent = Task {
        await waitForPMWorkflowStoreEvent(
            named: "analyst_charter_updated",
            in: store.events
        )
    }

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Can you modify the Recent News Analyst charter to include this requirement?",
        source: .ui
    )
    let reply = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)
    let charter = try await engine.getAnalystCharter(id: recentNewsStandingAnalystCharterID)
    let followThrough = try #require(
        try await engine.listPMCommunicationMessages()
            .filter {
                $0.sessionId == session.sessionId
                    && $0.senderRole == .pm
                    && $0.replyToMessageId == reply.messageId
            }
            .last
    )

    #expect(reply.conversationActionPlan?.actions.first?.targetId == recentNewsStandingAnalystCharterID)
    #expect(charter.title == recentNewsStandingAnalystTitle)
    #expect(charter.primaryDocumentBody.contains("## Mission"))
    #expect(charter.primaryDocumentBody.contains("## Material RSS Source-Article Review"))
    #expect(charter.primaryDocumentBody.contains("linked source article"))
    #expect(charter.primaryDocumentBody.contains("cannot be accessed"))
    #expect(charter.revisionSummary?.contains("source-article review") == true)
    #expect(charter.updateSource == .pmConversation)
    #expect(followThrough.body.contains("I updated and verified the Recent News Analyst charter"))
    #expect(followThrough.body.contains("Read-back verification confirmed"))
    #expect(try await engine.listPMInstructions().isEmpty)
    #expect(await charterUpdateEvent.value == true)

    let secondOwnerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Please retry that exact Recent News Analyst charter update.",
        source: .ui
    )
    _ = try await engine.generatePMConversationReply(to: secondOwnerAsk.messageId, source: .ui)
    let updatedAgain = try await engine.getAnalystCharter(id: recentNewsStandingAnalystCharterID)
    let ruleHeadingCount = updatedAgain.primaryDocumentBody
        .components(separatedBy: "## Material RSS Source-Article Review")
        .count - 1
    #expect(ruleHeadingCount == 1)
}

@Test("Recent News charter action updates canonical charter when duplicate titled charter exists")
func recentNewsCharterActionPrefersCanonicalCharterOverDuplicateTitle() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-recent-news-charter-duplicate")
    let now = Date(timeIntervalSince1970: 1_746_000_335)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let charterStore = AnalystCharterStore(chartersDirectory: root.appendingPathComponent("charters", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let duplicate = AnalystCharter(
        charterId: "legacy-recent-news-copy",
        analystId: "legacy-recent-news-analyst",
        title: recentNewsStandingAnalystTitle,
        coverageScope: "Legacy hidden recent-news copy",
        strategyFamily: "legacy",
        summary: "Legacy duplicate that should not receive PM charter updates.",
        documentBody: "Legacy duplicate body marker.",
        updatedBy: "legacy",
        updateSource: .systemSeed,
        createdAt: now,
        updatedAt: now
    )
    _ = try await charterStore.upsert(duplicate)
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "I’ll update the canonical Recent News Analyst charter.",
            actionPlan: PMConversationActionPlan(
                summary: "Update Recent News Analyst charter.",
                actions: [
                    PMConversationActionIntent(
                        actionType: .updateAnalystCharter,
                        summary: "Modify the Recent News Analyst charter to require full linked-article review for potentially material RSS items.",
                        body: "Add requirement: for app-ingested RSS/news that appears material, open the linked source article and review the full article; do not rely only on headline/snippet; if the linked article cannot be accessed, note that limitation.",
                        detail: "Recent News Analyst source-article review update."
                    )
                ]
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )
    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Updates canonical analyst charters.",
            createdAt: now,
            updatedAt: now
        )
    )
    let engine = Engine(
        pmProfileStore: profileStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        analystCharterStore: charterStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Modify the Recent News Analyst charter for material RSS article review.",
        source: .ui
    )
    _ = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)
    let canonical = try await engine.getAnalystCharter(id: recentNewsStandingAnalystCharterID)
    let unchangedDuplicate = try await engine.getAnalystCharter(id: duplicate.charterId)

    #expect(canonical.primaryDocumentBody.contains("## Material RSS Source-Article Review"))
    #expect(unchangedDuplicate.primaryDocumentBody == "Legacy duplicate body marker.")
}

@Test("PM charter verification ask receives current canonical charter body, not PMInstruction shadow truth")
func pmCharterVerificationAskReceivesCurrentCanonicalCharterBody() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-charter-body-context")
    let now = Date(timeIntervalSince1970: 1_746_000_340)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let instructionStore = PMInstructionStore(instructionsDirectory: root.appendingPathComponent("instructions", isDirectory: true))
    let charterStore = AnalystCharterStore(chartersDirectory: root.appendingPathComponent("charters", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "I’ll answer from the current charter body.",
            actionPlan: PMConversationActionPlan(
                summary: "Answer from current charter truth.",
                actions: [
                    PMConversationActionIntent(
                        actionType: .answerOnly,
                        summary: "Answer from current charter truth."
                    )
                ]
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )
    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Answers charter verification questions from canonical charter truth.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await instructionStore.upsert(
        PMInstruction(
            instructionId: "pm-instruction-shadow-charter-rule",
            pmId: "pm-1",
            title: "Requested Recent News charter rule",
            body: "Require the Recent News Analyst to open linked source articles for material RSS items.",
            category: "conversation_operating_instruction",
            status: .active,
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await charterStore.upsert(
        AnalystCharter(
            charterId: recentNewsStandingAnalystCharterID,
            analystId: recentNewsStandingAnalystID,
            title: recentNewsStandingAnalystTitle,
            coverageScope: "Recent news materiality.",
            strategyFamily: "standing overlay bench",
            summary: "Canonical current Recent News charter.",
            documentBody: """
            # Analyst Charter
            ## Role
            Recent News Analyst

            ## Source Policy And Research Conduct
            Current canonical charter body marker. This body intentionally does not yet contain the linked-source article review rule.
            """,
            benchRole: .overlay,
            updatedBy: "owner",
            updateSource: .userEdited,
            createdAt: now,
            updatedAt: now
        )
    )
    let engine = Engine(
        pmProfileStore: profileStore,
        pmInstructionStore: instructionStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        analystCharterStore: charterStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Are you able to see the current Recent Analyst Charter and identify whether that linked-source article change was implemented?",
        source: .ui
    )
    _ = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)
    let request = try #require(await synthesisProvider.lastConversationRequest)

    #expect(request.analystCharterDocumentSummary.contains(where: {
        $0.contains("canonical_analyst_charter id=\(recentNewsStandingAnalystCharterID)")
            && $0.contains("Current canonical charter body marker")
            && $0.contains("contains_material_rss_source_article_review_rule=no")
    }))
}

@Test("Unresolved hidden analyst-charter target records blocker instead of silently claiming success")
func unresolvedHiddenAnalystCharterTargetRecordsBlocker() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-unresolved-charter-action")
    let now = Date(timeIntervalSince1970: 1_746_000_360)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let charterStore = AnalystCharterStore(chartersDirectory: root.appendingPathComponent("charters", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "I’ll update that charter.",
            actionPlan: PMConversationActionPlan(
                summary: "Attempt an analyst charter update with an unresolved target.",
                actions: [
                    PMConversationActionIntent(
                        actionType: .updateAnalystCharter,
                        summary: "Update an unknown analyst charter.",
                        title: "Unknown Custom Analyst Charter",
                        body: "Add a new research requirement.",
                        sourceMessageIds: []
                    )
                ]
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Surfaces charter target blockers instead of silently dropping actions.",
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        analystCharterStore: charterStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Update the custom analyst charter.",
        source: .ui
    )
    let reply = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)
    let followThrough = try #require(
        try await engine.listPMCommunicationMessages()
            .filter {
                $0.sessionId == session.sessionId
                    && $0.senderRole == .pm
                    && $0.replyToMessageId == reply.messageId
            }
            .last
    )

    #expect(reply.conversationActionPlan?.actions.first?.targetId == nil)
    #expect(followThrough.body.contains("could not update the analyst charter"))
    #expect(followThrough.body.contains("target charter was not uniquely resolved"))
}

@Test("Unresolved hidden analyst-delegation target records blocker instead of ghost work")
func unresolvedHiddenAnalystDelegationTargetRecordsBlocker() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-unresolved-delegation-action")
    let now = Date(timeIntervalSince1970: 1_746_000_380)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let charterStore = AnalystCharterStore(chartersDirectory: root.appendingPathComponent("charters", isDirectory: true))
    let delegationStore = PMDelegationStore(delegationsDirectory: root.appendingPathComponent("delegations", isDirectory: true))
    let taskStore = AnalystTaskStore(tasksDirectory: root.appendingPathComponent("tasks", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let launchRecorder = PMConversationActionPlanLaunchRecorder()
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "I’ll do a bounded filer lookup for Situational Awareness LP.",
            actionPlan: PMConversationActionPlan(
                summary: "Attempt an ad hoc SEC filer lookup without a durable analyst target.",
                actions: [
                    PMConversationActionIntent(
                        actionType: .launchAdHocAnalystDelegation,
                        summary: "Research Situational Awareness LP 13F holdings.",
                        title: "SEC filer lookup for Situational Awareness LP",
                        body: "Identify the SEC filer and latest 13F holdings for Situational Awareness LP in San Francisco.",
                        detail: "Use a bounded lookup and report whether the current app can support the route.",
                        requestedOutputs: [.finding],
                        sourceMessageIds: []
                    )
                ]
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Routes research only through valid app-owned analyst targets.",
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        pmDelegationStore: delegationStore,
        analystCharterStore: charterStore,
        analystTaskStore: taskStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider,
        analystWorkerLauncher: PMConversationActionPlanStubLauncher(recorder: launchRecorder)
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Can you research the latest 13F holdings for Situational Awareness LP in San Francisco?",
        source: .ui
    )
    let reply = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)
    let followThroughs = try await engine.listPMCommunicationMessages()
        .filter {
            $0.sessionId == session.sessionId
                && $0.senderRole == .pm
                && $0.replyToMessageId == reply.messageId
        }
    let request = try #require(await synthesisProvider.lastConversationRequest)

    #expect(try await engine.listPMDelegations().isEmpty)
    #expect(try await engine.listAnalystTasks().isEmpty)
    #expect(await launchRecorder.lastRequest == nil)
    #expect(reply.body.contains("I could not launch that analyst task"))
    #expect(reply.body.contains("No delegation, task, or worker launch was created"))
    #expect(reply.runtimeProvenance?.conversationTrace?.visibleReplyModifiedAfterSynthesis == true)
    #expect(reply.conversationActionPlan?.actions.first?.targetId == nil)
    #expect(reply.conversationActionPlan?.actions.first?.charterId == nil)
    #expect(reply.conversationActionPlan?.actions.first?.detail?.contains("Work commitment consistency guard") == true)
    #expect(reply.conversationActionPlan?.actions.first?.detail?.contains("could not resolve an actual app-owned analyst/charter id") == true)
    #expect(reply.conversationActionPlan?.actions.first?.detail?.contains("Do not treat this as a research-capability limit") == true)
    #expect(followThroughs.isEmpty)
    #expect(request.operatingContextSummary.contains(where: { $0.contains("pm_operating_guide=") }))
    #expect(request.operatingContextSummary.contains(where: { $0.contains("ad_hoc_research_contract=") && $0.contains("13F") }))
    #expect(request.operatingContextSummary.contains(where: { $0.contains("ad_hoc_research_contract=") && $0.contains("Financials Analyst") }))
    #expect(request.operatingContextSummary.contains(where: { $0.contains("source_constraint_contract=") && $0.contains("PM action plan is not a source-policy authority") }))
    #expect(request.operatingContextSummary.contains(where: { $0.contains("Source restrictions come only from") }))
    #expect(request.operatingContextSummary.contains(where: { $0.contains("dedicated filings/ad hoc charter") }) == false)
    #expect(request.operatingContextSummary.contains(where: { $0.contains("confidence_contract=") && $0.contains("not deterministic blockers") }))
}

@Test("Visible analyst work commitment without hidden launch action is repaired before persistence")
func visibleAnalystWorkCommitmentWithoutHiddenLaunchActionIsRepairedBeforePersistence() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-work-commitment-guard")
    let now = Date(timeIntervalSince1970: 1_800_002_800)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let charterStore = AnalystCharterStore(chartersDirectory: root.appendingPathComponent("charters", isDirectory: true))
    let delegationStore = PMDelegationStore(delegationsDirectory: root.appendingPathComponent("delegations", isDirectory: true))
    let taskStore = AnalystTaskStore(tasksDirectory: root.appendingPathComponent("tasks", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let launchRecorder = PMConversationActionPlanLaunchRecorder()
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "I’ll put this to the Technology Analyst as a bounded META research task.",
            actionPlan: PMConversationActionPlan(
                summary: "Answer in conversation only even though the visible reply claims analyst work.",
                actions: [
                    PMConversationActionIntent(
                        actionType: .answerOnly,
                        summary: "Acknowledge META research request without launching work."
                    )
                ]
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Must not create ghost analyst work.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await charterStore.upsert(
        AnalystCharter(
            charterId: "bench-sector-technology",
            analystId: "bench-sector-technology-analyst",
            title: "Technology Analyst",
            coverageScope: "Technology and technology platforms",
            strategyFamily: "Long/Short Equity",
            summary: "Technology coverage",
            updatedBy: "owner",
            updateSource: .userEdited,
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        pmDelegationStore: delegationStore,
        analystCharterStore: charterStore,
        analystTaskStore: taskStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider,
        analystWorkerLauncher: PMConversationActionPlanStubLauncher(recorder: launchRecorder)
    )
    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Have an analyst research META.",
        source: .ui
    )

    let reply = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)

    #expect(reply.body.contains("I have not launched analyst work"))
    #expect(reply.body.contains("no delegation, analyst task, or worker launch exists"))
    #expect(reply.body.contains("I’ll put this to the Technology Analyst") == false)
    #expect(reply.conversationActionPlan?.actions.first?.actionType == .answerOnly)
    #expect(reply.conversationActionPlan?.actions.first?.detail?.contains("Work commitment consistency guard") == true)
    #expect(reply.runtimeProvenance?.conversationTrace?.visibleReplyModifiedAfterSynthesis == true)
    #expect(try await engine.listPMDelegations().isEmpty)
    #expect(try await engine.listAnalystTasks().isEmpty)
    #expect(await launchRecorder.lastRequest == nil)
}

@Test("Anthropic PM runtime also applies analyst work commitment guard")
func anthropicPMRuntimeAlsoAppliesAnalystWorkCommitmentGuard() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-anthropic-work-commitment-guard")
    let now = Date(timeIntervalSince1970: 1_800_002_810)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let charterStore = AnalystCharterStore(chartersDirectory: root.appendingPathComponent("charters", isDirectory: true))
    let delegationStore = PMDelegationStore(delegationsDirectory: root.appendingPathComponent("delegations", isDirectory: true))
    let taskStore = AnalystTaskStore(tasksDirectory: root.appendingPathComponent("tasks", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let runtimeSettingsStore = PMRuntimeSettingsStore(fileURL: root.appendingPathComponent("pm-runtime-settings.json", isDirectory: false))
    let launchRecorder = PMConversationActionPlanLaunchRecorder()
    let anthropicProvider = StubPMAnthropicSynthesisProvider(
        output: PMConversationOpenAISynthesisOutput(
            replyBody: "I’ll ask the Technology Analyst to research META now.",
            actionPlan: PMConversationActionPlan(
                summary: "Answer only while claiming analyst work.",
                actions: [
                    PMConversationActionIntent(
                        actionType: .answerOnly,
                        summary: "Acknowledge the META research ask without launching work."
                    )
                ]
            )
        )
    )
    let openAIProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(replyBody: "OpenAI should not be used."),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Must not create ghost analyst work.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await charterStore.upsert(
        AnalystCharter(
            charterId: "bench-sector-technology",
            analystId: "bench-sector-technology-analyst",
            title: "Technology Analyst",
            coverageScope: "Technology and technology platforms",
            strategyFamily: "Long/Short Equity",
            summary: "Technology coverage",
            updatedBy: "owner",
            updateSource: .userEdited,
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await runtimeSettingsStore.upsert(
        PMRuntimeSettings(
            providerKind: .anthropic,
            credentialProfileId: LLMCredentialProfile.anthropicDefaultProfileID,
            runtimeIdentifier: "claude-sonnet-4-6",
            reasoningMode: .standard,
            updatedBy: "owner",
            updateSource: .userEdited,
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmRuntimeSettingsStore: runtimeSettingsStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        pmDelegationStore: delegationStore,
        analystCharterStore: charterStore,
        analystTaskStore: taskStore,
        llmCredentialResolver: StubPMCommunicationLLMCredentialResolver(
            resolution: LLMCredentialResolution(
                status: .ready,
                apiKey: "test-anthropic-key",
                profileId: LLMCredentialProfile.anthropicDefaultProfileID,
                providerKind: .anthropic,
                matchedServiceOrLabel: "anthropic_api_key",
                account: "algo-trading",
                summary: "Test Anthropic key resolved."
            )
        ),
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: openAIProvider,
        pmAnthropicSynthesisProvider: anthropicProvider,
        analystWorkerLauncher: PMConversationActionPlanStubLauncher(recorder: launchRecorder)
    )
    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Have an analyst research META.",
        source: .ui
    )

    let reply = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)

    #expect(await openAIProvider.lastConversationRequest == nil)
    #expect(await anthropicProvider.lastConversationRequest != nil)
    #expect(reply.body.contains("I have not launched analyst work"))
    #expect(reply.runtimeProvenance?.actualProviderKind == .anthropic)
    #expect(reply.runtimeProvenance?.conversationTrace?.visibleReplyModifiedAfterSynthesis == true)
    #expect(try await engine.listPMDelegations().isEmpty)
    #expect(try await engine.listAnalystTasks().isEmpty)
    #expect(await launchRecorder.lastRequest == nil)
}

@Test("Hidden analyst-delegation actions create a bounded delegation and launch the external worker path")
func hiddenAnalystDelegationActionsCreateDelegationAndLaunchWorkerSafely() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-hidden-delegation-action")
    let now = Date(timeIntervalSince1970: 1_746_000_400)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let charterStore = AnalystCharterStore(chartersDirectory: root.appendingPathComponent("charters", isDirectory: true))
    let delegationStore = PMDelegationStore(delegationsDirectory: root.appendingPathComponent("delegations", isDirectory: true))
    let taskStore = AnalystTaskStore(tasksDirectory: root.appendingPathComponent("tasks", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let launchRecorder = PMConversationActionPlanLaunchRecorder()
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "I’m launching a bounded ad hoc analyst follow-up on that question now.",
            actionPlan: PMConversationActionPlan(
                summary: "Create and launch one bounded analyst delegation.",
                actions: [
                    PMConversationActionIntent(
                        actionType: .launchAdHocAnalystDelegation,
                        summary: "Ask the consumer analyst to pressure-test the highest-conviction adds and removals from the recent bounce.",
                        title: "Review highest-conviction adds and removals after the market recovery",
                        body: "Focus on the names with the strongest recent analyst support and explicitly challenge whether the market recovery changes the thesis.",
                        detail: "Return a bounded memo and one recommendation-ready conclusion.",
                        charterId: "bench-sector-consumer",
                        requestedOutputs: [.finding],
                        sourceMessageIds: []
                    )
                ]
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Delegates bounded analyst work through hidden PM action plans.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await charterStore.upsert(
        AnalystCharter(
            charterId: "bench-sector-consumer",
            analystId: "bench-sector-consumer-analyst",
            title: "Consumer Analyst",
            coverageScope: "US consumer",
            strategyFamily: "Long/Short Equity",
            summary: "Consumer coverage",
            updatedBy: "owner",
            updateSource: .userEdited,
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        pmDelegationStore: delegationStore,
        analystCharterStore: charterStore,
        analystTaskStore: taskStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider,
        analystWorkerLauncher: PMConversationActionPlanStubLauncher(recorder: launchRecorder)
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: PMCommunicationSenderRole.owner,
        senderId: "owner",
        body: "Launch a bounded analyst follow-up on the highest-conviction additions and removals from the recent recovery.",
        source: AuditEventSource.ui
    )
    let reply = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: AuditEventSource.ui)

    let delegations = try await engine.listPMDelegations()
    let delegation = try #require(delegations.last)
    let launchRequest = try #require(await launchRecorder.lastRequest)
    let request = try #require(await synthesisProvider.lastConversationRequest)
    #expect(delegation.charterId == "bench-sector-consumer")
    #expect(delegation.sourceCommunicationSessionId == session.sessionId)
    #expect(delegation.sourceCommunicationMessageId == ownerAsk.messageId)
    #expect(launchRequest.charterId == "bench-sector-consumer")
    #expect(launchRequest.delegationId == delegation.delegationId)
    #expect(reply.conversationActionPlan?.actions.first?.targetId == delegation.delegationId)
    #expect(request.operatingContextSummary.contains(where: {
        $0.contains("id=bench-sector-consumer") && $0.contains("title=Consumer Analyst")
    }))
}

@Test("Worker launch failure leaves durable delegation and visible blocker")
func workerLaunchFailureLeavesDurableDelegationAndVisibleBlocker() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-worker-launch-failure")
    let now = Date(timeIntervalSince1970: 1_800_002_820)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let charterStore = AnalystCharterStore(chartersDirectory: root.appendingPathComponent("charters", isDirectory: true))
    let delegationStore = PMDelegationStore(delegationsDirectory: root.appendingPathComponent("delegations", isDirectory: true))
    let taskStore = AnalystTaskStore(tasksDirectory: root.appendingPathComponent("tasks", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let launchRecorder = PMConversationActionPlanLaunchRecorder()
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "I’m launching the Technology Analyst META research task now.",
            actionPlan: PMConversationActionPlan(
                summary: "Create and launch one bounded Technology Analyst META research task.",
                actions: [
                    PMConversationActionIntent(
                        actionType: .launchAdHocAnalystDelegation,
                        summary: "Ask Technology Analyst to research META catalysts, valuation, liquidity, and 2026 technology product potential.",
                        title: "Technology Analyst META 2026 technology and valuation research",
                        body: "Research META earnings timing, developer conference timing, product rumors, valuation, cash/liquidity, buybacks, and whether META can make meaningful technology-platform progress in 2026.",
                        detail: "Return a PM-ready memo with source provenance and portfolio relevance.",
                        charterId: "Technology Analyst",
                        requestedOutputs: [.finding],
                        sourceMessageIds: []
                    )
                ]
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Records failed analyst worker launches.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await charterStore.upsert(
        AnalystCharter(
            charterId: "bench-sector-technology",
            analystId: "bench-sector-technology-analyst",
            title: "Technology Analyst",
            coverageScope: "Technology and technology platforms",
            strategyFamily: "Long/Short Equity",
            summary: "Technology coverage",
            updatedBy: "owner",
            updateSource: .userEdited,
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        pmDelegationStore: delegationStore,
        analystCharterStore: charterStore,
        analystTaskStore: taskStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider,
        analystWorkerLauncher: PMConversationActionPlanStubLauncher(
            recorder: launchRecorder,
            failureReason: "Could not connect to the server"
        )
    )
    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Have an analyst research META.",
        source: .ui
    )

    let reply = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)
    let delegation = try #require(try await engine.listPMDelegations().first)
    let task = try #require(try await engine.listAnalystTasks().first)
    let launchRequest = try #require(await launchRecorder.lastRequest)

    #expect(reply.body.contains("I could not launch that analyst task"))
    #expect(reply.body.contains("worker launch failed"))
    #expect(reply.body.contains("analyst is not currently running"))
    #expect(reply.runtimeProvenance?.conversationTrace?.visibleReplyModifiedAfterSynthesis == true)
    #expect(delegation.taskId == task.taskId)
    #expect(delegation.lastLaunch?.status == .failed)
    #expect(delegation.lastLaunch?.lastIssueSummary?.contains("Could not connect to the server") == true)
    #expect(delegation.sourceCommunicationMessageId == ownerAsk.messageId)
    #expect(launchRequest.delegationId == delegation.delegationId)
    #expect(reply.conversationActionPlan?.actions.first?.targetId == delegation.delegationId)
    #expect(reply.conversationActionPlan?.actions.first?.detail?.contains("Work commitment consistency guard") == true)
}

@Test("PM follow-up status prompt receives durable analyst task lifecycle truth")
func pmFollowUpStatusPromptReceivesDurableAnalystTaskLifecycleTruth() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-analyst-status-readback")
    let now = Date(timeIntervalSince1970: 1_800_002_840)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let charterStore = AnalystCharterStore(chartersDirectory: root.appendingPathComponent("charters", isDirectory: true))
    let delegationStore = PMDelegationStore(delegationsDirectory: root.appendingPathComponent("delegations", isDirectory: true))
    let taskStore = AnalystTaskStore(tasksDirectory: root.appendingPathComponent("tasks", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let launchRecorder = PMConversationActionPlanLaunchRecorder()
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutputs: [
            PMConversationOpenAISynthesisOutput(
                replyBody: "I’m launching the Technology Analyst META research task now.",
                actionPlan: PMConversationActionPlan(
                    summary: "Launch a bounded META research task.",
                    actions: [
                        PMConversationActionIntent(
                            actionType: .launchAdHocAnalystDelegation,
                            summary: "Ask Technology Analyst to research META catalysts, valuation, liquidity, and 2026 technology product potential.",
                            title: "Technology Analyst META 2026 technology and valuation research",
                            body: "Research META earnings timing, developer conference timing, product rumors, valuation, cash/liquidity, buybacks, and whether META can make meaningful technology-platform progress in 2026.",
                            detail: "Return a PM-ready memo with source provenance and portfolio relevance.",
                            charterId: "Technology Analyst",
                            requestedOutputs: [.finding],
                            sourceMessageIds: []
                        )
                    ]
                )
            ),
            PMConversationOpenAISynthesisOutput(
                replyBody: "The Technology Analyst META task is complete, and the app-owned delegation shows output ready for review.",
                actionPlan: PMConversationActionPlan(
                    summary: "Answer META analyst task status from durable delegation state.",
                    actions: [
                        PMConversationActionIntent(
                            actionType: .answerOnly,
                            summary: "Answer the META task status question."
                        )
                    ]
                )
            )
        ],
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Answers analyst task status from durable truth.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await charterStore.upsert(
        AnalystCharter(
            charterId: "bench-sector-technology",
            analystId: "bench-sector-technology-analyst",
            title: "Technology Analyst",
            coverageScope: "Technology and technology platforms",
            strategyFamily: "Long/Short Equity",
            summary: "Technology coverage",
            updatedBy: "owner",
            updateSource: .userEdited,
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        pmDelegationStore: delegationStore,
        analystCharterStore: charterStore,
        analystTaskStore: taskStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider,
        analystWorkerLauncher: PMConversationActionPlanStubLauncher(recorder: launchRecorder)
    )
    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let launchAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Have an analyst research META.",
        source: .ui
    )
    _ = try await engine.generatePMConversationReply(to: launchAsk.messageId, source: .ui)
    let delegation = try #require(try await engine.listPMDelegations().first)

    let statusAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Is the Technology Analyst still doing the META research?",
        source: .ui
    )
    let statusReply = try await engine.generatePMConversationReply(to: statusAsk.messageId, source: .ui)
    let requests = await synthesisProvider.conversationRequests
    let statusRequest = try #require(requests.last)
    let statusContext = statusRequest.operatingContextSummary.joined(separator: "\n")

    #expect(delegation.lastLaunch?.status == .healthy)
    #expect(statusReply.body.contains("complete"))
    #expect(statusContext.contains("pm_analyst_delegation id=\(delegation.delegationId)"))
    #expect(statusContext.contains("charter=bench-sector-technology"))
    #expect(statusContext.contains("task=\(delegation.taskId ?? "-")"))
    #expect(statusContext.contains("execution=Completed"))
    #expect(statusContext.contains("launch=healthy"))
    #expect(statusContext.contains("Technology Analyst META 2026 technology and valuation research"))
}

@Test("13F asset-manager research can route to Financials instead of requiring a bespoke route")
func thirteenFAssetManagerResearchCanRouteToFinancialsAnalyst() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-financials-13f-route")
    let now = Date(timeIntervalSince1970: 1_746_000_425)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let charterStore = AnalystCharterStore(chartersDirectory: root.appendingPathComponent("charters", isDirectory: true))
    let delegationStore = PMDelegationStore(delegationsDirectory: root.appendingPathComponent("delegations", isDirectory: true))
    let taskStore = AnalystTaskStore(tasksDirectory: root.appendingPathComponent("tasks", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let launchRecorder = PMConversationActionPlanLaunchRecorder()
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "I’m routing this to the Financials Analyst because 13F and asset-manager holdings work fits official-filings review.",
            actionPlan: PMConversationActionPlan(
                summary: "Create and launch one bounded Financials Analyst SEC/13F lookup.",
                actions: [
                    PMConversationActionIntent(
                        actionType: .launchAdHocAnalystDelegation,
                        summary: "Ask Financials to identify the filer and latest 13F holdings.",
                        title: "Situational Awareness LP latest 13F holdings lookup",
                        body: "Identify the SEC filer for Situational Awareness LP in San Francisco and extract latest 13F holdings. Use official SEC evidence when available, and use reputable secondary sources for discovery and corroboration if needed.",
                        detail: "Label official versus secondary evidence and report a precise blocker only after bounded discovery fails.",
                        charterId: "bench-sector-financials",
                        requestedOutputs: [.finding],
                        sourceMessageIds: []
                    )
                ]
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Routes asset-manager filings research through the closest valid analyst.",
            createdAt: now,
            updatedAt: now
        )
    )
    let financials = try #require(
        StandingAnalystBenchSeed().seededCharters(now: now)
            .first { $0.charterId == "bench-sector-financials" }
    )
    _ = try await charterStore.upsert(financials)

    let engine = Engine(
        pmProfileStore: profileStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        pmDelegationStore: delegationStore,
        analystCharterStore: charterStore,
        analystTaskStore: taskStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider,
        analystWorkerLauncher: PMConversationActionPlanStubLauncher(recorder: launchRecorder)
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: PMCommunicationSenderRole.owner,
        senderId: "owner",
        body: "Can you research the latest 13F holdings for Situational Awareness LP in San Francisco?",
        source: AuditEventSource.ui
    )
    let reply = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: AuditEventSource.ui)

    let delegation = try #require(try await engine.listPMDelegations().last)
    let task = try #require(try await engine.listAnalystTasks().last)
    let launchRequest = try #require(await launchRecorder.lastRequest)
    let request = try #require(await synthesisProvider.lastConversationRequest)

    #expect(delegation.charterId == "bench-sector-financials")
    #expect(delegation.taskId == task.taskId)
    #expect(delegation.sourceCommunicationMessageId == ownerAsk.messageId)
    #expect(launchRequest.charterId == "bench-sector-financials")
    #expect(launchRequest.delegationId == delegation.delegationId)
    #expect(reply.conversationActionPlan?.actions.first?.targetId == delegation.delegationId)
    #expect(request.operatingContextSummary.contains(where: {
        $0.contains("ad_hoc_research_contract=")
            && $0.contains("13F")
            && $0.contains("Financials Analyst")
    }))
    #expect(request.operatingContextSummary.contains(where: {
        $0.contains("source_constraint_contract=")
            && $0.contains("PM action plan is not a source-policy authority")
            && $0.contains("Do not add source-tier policy text")
    }))
    #expect(request.operatingContextSummary.contains(where: { $0.contains("dedicated filings/ad hoc charter") }) == false)
    #expect(request.operatingContextSummary.contains(where: {
        $0.contains("id=bench-sector-financials")
            && $0.contains("title=Financials Analyst")
    }))
}

@Test("PM source readback receives ad hoc analyst memo evidence source tiers")
func pmSourceReadbackReceivesAdHocAnalystMemoEvidenceSourceTiers() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-ad-hoc-source-tier-readback")
    let now = Date(timeIntervalSince1970: 1_746_000_435)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let charterStore = AnalystCharterStore(chartersDirectory: root.appendingPathComponent("charters", isDirectory: true))
    let memoStore = AnalystMemoStore(memosDirectory: root.appendingPathComponent("memos", isDirectory: true))
    let evidenceStore = AnalystEvidenceBundleStore(evidenceDirectory: root.appendingPathComponent("evidence", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "The latest Financials Analyst research used SEC EDGAR as official/primary and WhaleWisdom as secondary discovery evidence.",
            actionPlan: PMConversationActionPlan(
                summary: "Answer source-tier readback from app-owned analyst evidence.",
                actions: [
                    PMConversationActionIntent(
                        actionType: .answerOnly,
                        summary: "Answer source-tier readback."
                    )
                ]
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )
    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Answers source-tier readback from app-owned analyst evidence.",
            createdAt: now,
            updatedAt: now
        )
    )
    let financials = try #require(
        StandingAnalystBenchSeed().seededCharters(now: now)
            .first { $0.charterId == "bench-sector-financials" }
    )
    _ = try await charterStore.upsert(financials)
    _ = try await evidenceStore.upsert(
        AnalystEvidenceBundle(
            bundleId: "evidence-financials-13f-source-tier",
            analystId: "bench-sector-financials-analyst",
            charterId: "bench-sector-financials",
            taskId: "task-financials-13f-source-tier",
            refs: [
                AnalystEvidenceRef(
                    refId: "sec-edgar-search",
                    sourceKind: .web,
                    sourceIdentifier: "SEC EDGAR",
                    url: "https://www.sec.gov/edgar/search/",
                    title: "SEC EDGAR search",
                    summary: "Official SEC discovery path for filer identity and Form 13F accessions.",
                    freshnessNote: "source_tier=official_primary;worker_recorded_external_evidence"
                ),
                AnalystEvidenceRef(
                    refId: "whalewisdom-13f",
                    sourceKind: .web,
                    sourceIdentifier: "WhaleWisdom",
                    url: "https://whalewisdom.com/",
                    title: "WhaleWisdom 13F research",
                    summary: "Reputable secondary 13F aggregator supplied for discovery/corroboration; it did not independently confirm manager-specific holdings.",
                    freshnessNote: "source_tier=reputable_secondary;worker_recorded_external_evidence"
                )
            ],
            summary: "Financials 13F research checked official SEC discovery and a labeled secondary 13F discovery source.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await memoStore.upsert(
        AnalystMemo(
            memoId: "memo-financials-13f-source-tier",
            analystId: "bench-sector-financials-analyst",
            charterId: "bench-sector-financials",
            taskId: "task-financials-13f-source-tier",
            delegationId: "delegation-financials-13f-source-tier",
            pmId: "pm-1",
            evidenceBundleId: "evidence-financials-13f-source-tier",
            title: "Situational Awareness LP latest 13F holdings - SEC-first rerun",
            executiveSummary: "No manager-specific holdings table was verified from the bounded evidence.",
            currentView: "SEC EDGAR remains the official source path; WhaleWisdom was supplied only as labeled secondary discovery/corroboration.",
            evidenceSummary: "Official/primary: SEC EDGAR search. Reputable secondary: WhaleWisdom 13F research. Neither source produced a verified holdings table in this bounded artifact.",
            uncertaintySummary: "A holdings table should not be inferred until an official accession and information table are recovered.",
            recommendedNextStep: "Continue SEC-first retrieval and use secondary sources only as labeled discovery/corroboration.",
            confidence: 0.22,
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        analystCharterStore: charterStore,
        analystEvidenceBundleStore: evidenceStore,
        analystMemoStore: memoStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )
    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: PMCommunicationSenderRole.owner,
        senderId: "owner",
        body: "Which sources did the Financials Analyst use in the latest 13F research, and which were official or primary versus secondary?",
        source: AuditEventSource.ui
    )
    _ = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: AuditEventSource.ui)

    let request = try #require(await synthesisProvider.lastConversationRequest)
    let artifactSummary = request.analystArtifactSummary.joined(separator: "\n")
    let renderedPrompt = makePMConversationPromptText(from: request)
    #expect(artifactSummary.contains("AD_HOC_ANALYST_SOURCE_TIER_GROUNDING"))
    #expect(artifactSummary.contains("SEC EDGAR search"))
    #expect(artifactSummary.contains("sourceTier=Official / Primary"))
    #expect(artifactSummary.contains("WhaleWisdom 13F research"))
    #expect(artifactSummary.contains("sourceTier=Reputable Secondary"))
    #expect(artifactSummary.contains("Do not omit a listed reputable secondary source"))
    #expect(renderedPrompt.contains("WhaleWisdom 13F research"))
    #expect(renderedPrompt.contains("sourceTier=Reputable Secondary"))
}

@Test("Conversation-launched analyst work posts a grounded PM follow-through in the same session")
func conversationLaunchedAnalystWorkPostsGroundedFollowThroughInTheSameSession() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-analyst-follow-through")
    let now = Date(timeIntervalSince1970: 1_746_000_450)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let charterStore = AnalystCharterStore(chartersDirectory: root.appendingPathComponent("charters", isDirectory: true))
    let delegationStore = PMDelegationStore(delegationsDirectory: root.appendingPathComponent("delegations", isDirectory: true))
    let taskStore = AnalystTaskStore(tasksDirectory: root.appendingPathComponent("tasks", isDirectory: true))
    let memoStore = AnalystMemoStore(memosDirectory: root.appendingPathComponent("memos", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let launchRecorder = PMConversationActionPlanLaunchRecorder()
    let memo = AnalystMemo(
        memoId: "memo-costco-follow-through",
        analystId: "bench-sector-consumer-analyst",
        charterId: "bench-sector-consumer",
        pmId: "pm-1",
        title: "Costco consumer check",
        executiveSummary: "Costco still looks like a resilient, membership-driven compounder, but I would treat it as a candidate add rather than a rush trade after the recovery bounce.",
        currentView: "Traffic resilience and renewal strength still support the long thesis, while valuation now requires cleaner margin follow-through.",
        evidenceSummary: "Recent channel checks stayed constructive, renewal data held firm, and management execution remains ahead of most large-format retail peers.",
        uncertaintySummary: "The main open question is how much upside is already reflected after the market recovery and whether discretionary basket pressure shows up in the next quarter.",
        recommendedNextStep: "Keep Costco on the add shortlist, but require one more valuation-and-traffic check before turning it into a formal portfolio change recommendation.",
        confidence: 0.73,
        createdAt: now,
        updatedAt: now
    )
    _ = try await memoStore.upsert(memo)
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutputs: [
            PMConversationOpenAISynthesisOutput(
                replyBody: "I’m launching Consumer Analyst work on Costco now and I’ll follow up once the memo is back.",
                actionPlan: PMConversationActionPlan(
                    summary: "Launch one bounded Costco analyst follow-up and then close the loop in conversation.",
                    actions: [
                        PMConversationActionIntent(
                            actionType: .launchAdHocAnalystDelegation,
                            summary: "Ask the consumer analyst to evaluate Costco as a possible portfolio addition after the recent recovery.",
                            title: "Review Costco as a possible portfolio addition",
                            body: "Pressure-test the current Costco long thesis, including resilience, valuation, and whether the latest recovery changes the entry quality.",
                            detail: "Return a bounded memo with a clear PM-ready conclusion on whether Costco belongs on the near-term add shortlist.",
                            charterId: "Consumer Analyst",
                            requestedOutputs: [.finding],
                            sourceMessageIds: []
                        )
                    ]
                )
            ),
            PMConversationOpenAISynthesisOutput(
                replyBody: "The Consumer Analyst work is back. My PM read: Costco still looks like a resilient compounder, but the conclusion is to keep it on the add shortlist rather than rush a trade. The full memo is in PM Inbox if you want the source-level detail.",
                actionPlan: PMConversationActionPlan(
                    summary: "Synthesize completed analyst task for owner follow-through.",
                    actions: [
                        PMConversationActionIntent(
                            actionType: .answerOnly,
                            summary: "Delivered PM-synthesized analyst follow-through."
                        )
                    ]
                )
            )
        ],
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Launches bounded analyst work and closes the loop with the owner.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await charterStore.upsert(
        AnalystCharter(
            charterId: "bench-sector-consumer",
            analystId: "bench-sector-consumer-analyst",
            title: "Consumer Analyst",
            coverageScope: "US consumer and retail",
            strategyFamily: "Long/Short Equity",
            summary: "Consumer coverage",
            updatedBy: "owner",
            updateSource: .userEdited,
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        pmDelegationStore: delegationStore,
        analystCharterStore: charterStore,
        analystTaskStore: taskStore,
        analystMemoStore: memoStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider,
        analystWorkerLauncher: PMConversationActionPlanStubLauncher(
            recorder: launchRecorder,
            result: AnalystWorkerLaunchResult(
                openAIKeyConfigured: true,
                usedOpenAI: false,
                charterId: "bench-sector-consumer",
                taskId: nil,
                delegationId: nil,
                pmId: "pm-1",
                memoId: memo.memoId,
                memoTitle: memo.title,
                findingId: nil,
                findingTitle: nil,
                draftedSignalId: nil,
                draftedProposalId: nil,
                summary: "Consumer Analyst memo completed on Costco.",
                outputExcerpt: memo.executiveSummary
            )
        )
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "What do you think about adding Costco to our portfolio?",
        source: .ui
    )
    let reply = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)

    let launchRequest = try #require(await launchRecorder.lastRequest)
    let messages = try await engine.listPMCommunicationMessages()
        .filter { $0.sessionId == session.sessionId }
        .sorted { lhs, rhs in
            if lhs.sentAt == rhs.sentAt {
                return lhs.messageId < rhs.messageId
            }
            return lhs.sentAt < rhs.sentAt
        }
    let followThrough = try #require(messages.last)
    let delegations = try await engine.listPMDelegations()
    let delegation = try #require(delegations.last)

    #expect(messages.count == 3)
    #expect(reply.body.contains("launching Consumer Analyst work on Costco"))
    #expect(followThrough.messageId != reply.messageId)
    #expect(followThrough.replyToMessageId == reply.messageId)
    #expect(followThrough.body.contains("My PM read: Costco still looks like a resilient compounder"))
    #expect(followThrough.body.contains("full memo is in PM Inbox"))
    #expect(followThrough.body.contains("Recommended next step:") == false)
    let conversationRequests = await synthesisProvider.conversationRequests
    #expect(conversationRequests.count == 2)
    let request = try #require(conversationRequests.first)
    #expect(conversationRequests.last?.plannerMode == "analyst_follow_through_synthesis")
    #expect(conversationRequests.last?.ownerMessageBody.contains("Synthesize the analyst result for the owner") == true)
    #expect(conversationRequests.last?.ownerMessageBody.contains("context for your reasoning") == true)
    #expect(conversationRequests.last?.ownerMessageBody.contains("not a deterministic script") == true)
    #expect(conversationRequests.last?.ownerMessageBody.contains("content block to paste") == true)
    #expect(delegation.charterId == "bench-sector-consumer")
    #expect(delegation.sourceCommunicationSessionId == session.sessionId)
    #expect(delegation.sourceCommunicationMessageId == ownerAsk.messageId)
    #expect(delegation.followThrough?.status == .delivered)
    #expect(delegation.followThrough?.deliveredMessageId == followThrough.messageId)
    #expect(launchRequest.charterId == "bench-sector-consumer")
    #expect(reply.conversationActionPlan?.actions.first?.charterId == "bench-sector-consumer")
    #expect(request.operatingContextSummary.contains(where: {
        $0.contains("id=bench-sector-consumer") && $0.contains("title=Consumer Analyst")
    }))
}

@Test("Same PM source message reuses existing ad hoc analyst delegation")
func samePMSourceMessageReusesExistingAdHocAnalystDelegation() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-delegation-dedupe")
    let now = Date(timeIntervalSince1970: 1_746_000_455)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let charterStore = AnalystCharterStore(chartersDirectory: root.appendingPathComponent("charters", isDirectory: true))
    let delegationStore = PMDelegationStore(delegationsDirectory: root.appendingPathComponent("delegations", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Delegates bounded analyst work exactly once per owner message.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await charterStore.upsert(
        AnalystCharter(
            charterId: "bench-sector-technology",
            analystId: "bench-sector-technology-analyst",
            title: "Technology Analyst",
            coverageScope: "Technology and technology platforms",
            strategyFamily: "Long/Short Equity",
            summary: "Technology coverage",
            updatedBy: "owner",
            updateSource: .userEdited,
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        pmDelegationStore: delegationStore,
        analystCharterStore: charterStore
    )
    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Have the Technology Analyst research META.",
        source: .ui
    )

    let first = try await engine.promotePMCommunicationMessageToDelegation(
        messageId: ownerAsk.messageId,
        pmId: "pm-1",
        charterId: "bench-sector-technology",
        title: "Technology Analyst META research",
        rationale: "Owner requested ad hoc META research.",
        source: .ui
    )
    let second = try await engine.promotePMCommunicationMessageToDelegation(
        messageId: ownerAsk.messageId,
        pmId: "pm-1",
        charterId: "bench-sector-technology",
        title: "Technology Analyst META research",
        rationale: "Owner requested ad hoc META research.",
        source: .ui
    )
    let delegations = try await engine.listPMDelegations()

    #expect(first.delegationId == second.delegationId)
    #expect(delegations.count == 1)
    #expect(second.followThrough?.status == .pending)
    #expect(second.followThrough?.sourceCommunicationMessageId == ownerAsk.messageId)
}

@Test("Conversation-launched multi-question analyst task preserves checklist and target symbol")
func conversationLaunchedMultiQuestionAnalystTaskPreservesChecklistAndTargetSymbol() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-multi-question-task")
    let now = Date(timeIntervalSince1970: 1_746_000_458)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let charterStore = AnalystCharterStore(chartersDirectory: root.appendingPathComponent("charters", isDirectory: true))
    let delegationStore = PMDelegationStore(delegationsDirectory: root.appendingPathComponent("delegations", isDirectory: true))
    let taskStore = AnalystTaskStore(tasksDirectory: root.appendingPathComponent("tasks", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let launchRecorder = PMConversationActionPlanLaunchRecorder()
    let metaScope = "Research META for an example technology research portfolio. Answer: next earnings report timing; next developer conference / Meta Connect timing; credible public roadmap signals and expected timing for 2026 product releases; forward P/E and valuation context; available cash/liquidity and 2026 cash outlook; whether META is positioned for meaningful technology-platform progress in 2026; portfolio relevance and conclusion."
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "I’m launching Technology Analyst work on META now and I’ll follow up when the memo is back.",
            actionPlan: PMConversationActionPlan(
                summary: "Launch one bounded multi-question META research task.",
                actions: [
                    PMConversationActionIntent(
                        actionType: .launchAdHocAnalystDelegation,
                        summary: "Launch META research with Technology Analyst",
                        title: "META 2026 technology, earnings, events, valuation, and cash research",
                        body: "Use Technology Analyst charter bench-sector-technology. Tier 2 reputable financial data providers for market metrics; Tier 3 tech/product press for rumors. This PM-generated source-policy text must not become the analyst task description, checklist, or source policy.",
                        detail: "Tier 2 reputable financial data providers for market metrics; Tier 3 tech/product press for rumors. This PM-generated source-policy text must not become the analyst checklist or source policy.",
                        charterId: "Technology Analyst",
                        proposalSymbol: "AI",
                        liveOrderSymbol: "AI",
                        requestedOutputs: [.finding],
                        sourceMessageIds: []
                    )
                ]
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Launches bounded analyst work and closes the loop with the owner.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await charterStore.upsert(
        AnalystCharter(
            charterId: "bench-sector-technology",
            analystId: "bench-sector-technology-analyst",
            title: "Technology Analyst",
            coverageScope: "Technology and technology platforms",
            strategyFamily: "Long/Short Equity",
            summary: "Technology coverage",
            updatedBy: "owner",
            updateSource: .userEdited,
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        pmDelegationStore: delegationStore,
        analystCharterStore: charterStore,
        analystTaskStore: taskStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider,
        analystWorkerLauncher: PMConversationActionPlanStubLauncher(
            recorder: launchRecorder,
            result: AnalystWorkerLaunchResult(
                openAIKeyConfigured: true,
                usedOpenAI: false,
                charterId: "bench-sector-technology",
                taskId: nil,
                delegationId: nil,
                pmId: "pm-1",
                memoId: nil,
                memoTitle: nil,
                findingId: nil,
                findingTitle: nil,
                draftedSignalId: nil,
                draftedProposalId: nil,
                summary: "Technology Analyst task queued.",
                outputExcerpt: "Task queued."
            )
        )
    )
    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: metaScope,
        source: .ui
    )
    _ = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)

    let task = try #require(try await taskStore.loadAll().first)
    let questions = task.pmTaskingBrief?.researchQuestions ?? []
    let launchRequest = try #require(await launchRecorder.lastRequest)

    #expect(task.symbols.contains("META"))
    #expect(task.symbols.contains("AI") == false)
    #expect(task.pmTaskingBrief?.coverageRequired == true)
    #expect(task.pmTaskingBrief?.evidenceExpectation == nil)
    #expect(task.pmTaskingBrief?.whyNow == nil)
    #expect(task.description.contains("Tier 2") == false)
    #expect(task.description.contains("PM-generated source-policy") == false)
    #expect(questions.count >= 6)
    #expect(questions.contains(where: { $0.contains("next earnings report") }))
    #expect(questions.contains(where: { $0.contains("forward P/E") }))
    #expect(questions.contains(where: { $0.contains("available cash") || $0.contains("liquidity") }))
    #expect(questions.contains(where: { $0.contains("PM tasking brief") }) == false)
    #expect(questions.contains(where: { $0.contains("Evidence expectation") }) == false)
    #expect(questions.contains(where: { $0.contains("Tier 2") }) == false)
    #expect(launchRequest.charterId == "bench-sector-technology")
}

@Test("Hidden approval-routing actions can create a bounded PM decision and approval request")
func hiddenApprovalRoutingActionsCreateBoundedDecisionAndApprovalRequest() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-hidden-approval-action")
    let now = Date(timeIntervalSince1970: 1_746_000_500)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let decisionStore = PMDecisionStore(decisionsDirectory: root.appendingPathComponent("decisions", isDirectory: true))
    let approvalStore = PMApprovalRequestStore(approvalRequestsDirectory: root.appendingPathComponent("approval_requests", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "I’ll convert that into a bounded PM recommendation and route it into the normal owner approval loop.",
            actionPlan: PMConversationActionPlan(
                summary: "Create one PM recommendation and one bounded approval request.",
                actions: [
                    PMConversationActionIntent(
                        actionType: .createPMDecision,
                        summary: "Recommend a bounded runtime-posture update for the current PM workflow.",
                        title: "PM recommendation: runtime-posture update",
                        body: "Recommend moving the PM runtime into a more deliberate posture for owner-facing strategy work.",
                        detail: "Please review this bounded PM recommendation.",
                        decisionType: .recommendation,
                        sourceMessageIds: []
                    ),
                    PMConversationActionIntent(
                        actionType: .createPMApprovalRequest,
                        summary: "Route that bounded PM recommendation into owner approval.",
                        title: "Review PM recommendation: runtime-posture update",
                        body: "Please review whether the PM should adopt the more deliberate runtime posture.",
                        requestType: .operatingInstruction,
                        sourceMessageIds: []
                    )
                ]
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Routes bounded PM recommendations into the existing approval path.",
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmDecisionStore: decisionStore,
        pmApprovalRequestStore: approvalStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: PMCommunicationSenderRole.owner,
        senderId: "owner",
        body: "Turn that into a bounded PM recommendation and route it through the usual owner approval loop.",
        source: AuditEventSource.ui
    )
    let reply = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: AuditEventSource.ui)

    let decisions = try await engine.listPMDecisions()
    let approvalRequests = try await engine.listPMApprovalRequests()
    let decision = try #require(decisions.last)
    let approvalRequest = try #require(approvalRequests.last)
    #expect(decision.title == "PM recommendation: runtime-posture update")
    #expect(approvalRequest.decisionId == decision.decisionId)
    #expect(approvalRequest.requestType == PMApprovalRequestType.operatingInstruction)
    #expect(approvalRequest.status == PMApprovalRequestStatus.pending)
    #expect(reply.conversationActionPlan?.actions.count == 2)
    #expect(reply.conversationActionPlan?.actions.last?.targetId == approvalRequest.approvalRequestId)
}

@Test("In-app complete Live order instruction creates review item without submitting order")
func inAppCompleteLiveOrderInstructionCreatesReviewItemWithoutSubmittingOrder() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-live-order-review")
    let now = Date(timeIntervalSince1970: 1_746_000_620)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let decisionStore = PMDecisionStore(decisionsDirectory: root.appendingPathComponent("decisions", isDirectory: true))
    let approvalStore = PMApprovalRequestStore(approvalRequestsDirectory: root.appendingPathComponent("approval_requests", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "I created an in-app Live order review item in Command Center > Your Decisions. No order has been submitted.",
            actionPlan: PMConversationActionPlan(
                summary: "Create a PM decision and owner-visible Live order review item.",
                actions: [
                    PMConversationActionIntent(
                        actionType: .createPMDecision,
                        summary: "Review a Live market day order to buy 1 AAPL share.",
                        title: "Live order review: buy 1 AAPL",
                        body: "The owner asked to review a Live market day order to buy 1 AAPL share. This is a review artifact only.",
                        detail: "Review whether this Live order instruction should advance to the governed in-app order path. Do not submit an order from this conversation.",
                        decisionType: .recommendation,
                        sourceMessageIds: []
                    ),
                    PMConversationActionIntent(
                        actionType: .createPMApprovalRequest,
                        summary: "Surface the Live order instruction for in-app review.",
                        title: "Review Live order instruction: buy 1 AAPL",
                        body: "Review a Live market day order instruction to buy 1 AAPL share. This approval request does not submit an order.",
                        detail: "Approve only if this instruction should advance to the governed in-app order path; Live NEW/REPLACE still requires final local authentication when enabled.",
                        liveOrderSymbol: "AAPL",
                        liveOrderSide: .buy,
                        liveOrderQuantity: 1,
                        liveOrderType: .market,
                        liveOrderTimeInForce: .day,
                        requestType: .liveOrderReview,
                        sourceMessageIds: []
                    )
                ]
            ),
            resolution: PMConversationResolutionState(
                intentClass: .instruction,
                disposition: .durableApplyNow
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Surfaces Live order instructions as in-app review items without order submission.",
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        configuration: Configuration(environment: .live),
        pmProfileStore: profileStore,
        pmDecisionStore: decisionStore,
        pmApprovalRequestStore: approvalStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Review a live market day order to buy 1 AAPL share.",
        source: .ui
    )
    let reply = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)

    let messages = try await engine.listPMCommunicationMessages()
    let decisions = try await engine.listPMDecisions()
    let approvalRequests = try await engine.listPMApprovalRequests()
    let approval = try #require(approvalRequests.first)
    let ownerDecisionItems = makeOwnerDecisionDeskPresentations(
        approvalRequests: approvalRequests,
        decisions: decisions,
        delegations: [],
        tasks: [],
        findings: [],
        communicationMessages: messages,
        charters: [],
        memos: [],
        strategyBrief: nil
    )

    #expect(reply.body.contains("Command Center > Your Decisions"))
    #expect(reply.body.contains("No order has been submitted"))
    #expect(approval.requestType == .liveOrderReview)
    #expect(approval.status == .pending)
    #expect(approval.liveOrderReview?.symbol == "AAPL")
    #expect(approval.liveOrderReview?.quantity == 1)
    #expect(approval.liveOrderReview?.orderType == .market)
    #expect(approval.liveOrderReview?.timeInForce == .day)
    #expect(approval.sourceCommunicationMessageId == ownerAsk.messageId)
    #expect(approval.lastExecutionRoutingAssessment == nil)
    #expect((reply.conversationActionPlan?.actions.map(\.actionType) ?? []) == [.createPMDecision, .createPMApprovalRequest])
    #expect(reply.conversationActionPlan?.actions.last?.targetId == approval.approvalRequestId)
    #expect(ownerDecisionItems.count == 1)
    #expect(ownerDecisionItems.first?.approvalRequestId == approval.approvalRequestId)
    #expect(ownerDecisionItems.first?.requestTypeTitle == "Live Order Review")
    #expect(ownerDecisionItems.first?.boundaryNote.contains("governed Engine route") == true)
    #expect(ownerDecisionItems.first?.boundaryNote.contains("LocalAuthentication") == true)
}

@Test("In-app PM cash question receives explicit Live account cash truth")
func inAppPMCashQuestionReceivesExplicitLiveAccountCashTruth() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-live-cash-truth")
    let now = Date(timeIntervalSince1970: 1_746_000_625)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "The current Live cash in app-owned account truth is $758.03, with buying power of $80,996.",
            actionPlan: nil,
            resolution: PMConversationResolutionState(
                intentClass: .general,
                disposition: .conversationOnly
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Answers from app-owned account and portfolio truth.",
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        configuration: Configuration(environment: .live),
        pmProfileStore: profileStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider,
        nowDate: { now }
    )
    await engine.store.applyStartupSnapshot(
        account: Account(
            id: "acct-live-redacted",
            status: "ACTIVE",
            cash: "758.03",
            buyingPower: "80995.83",
            equity: "39739.88",
            multiplier: "2"
        ),
        positions: [
            Position(symbol: "AVGO", qty: "23", side: "long", marketValue: "8959.65")
        ],
        openOrders: []
    )
    await engine.store.setTradingSafetyState(
        isLive: true,
        isArmedForLiveTrading: false,
        armingSessionID: nil,
        killSwitchEnabled: true
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: PMCommunicationSenderRole.owner,
        senderId: "owner",
        body: "What is the current cash position in the live portfolio?",
        source: AuditEventSource.ui
    )
    _ = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: AuditEventSource.ui)

    let request = try #require(await synthesisProvider.lastConversationRequest)
    let confirmedTruth = request.confirmedAppTruthSummary.joined(separator: "\n")
    #expect(confirmedTruth.contains("Confirmed Live account cash truth in app-owned Store"))
    #expect(confirmedTruth.contains("cash $758.03"))
    #expect(confirmedTruth.contains("buying power $80,996"))
    #expect(confirmedTruth.contains("do not infer cash from holdings"))
    #expect(confirmedTruth.contains("acct-live-redacted") == false)
}

@Test("In-app incomplete Live order instruction asks follow-up and creates no approval")
func inAppIncompleteLiveOrderInstructionAsksFollowUpAndCreatesNoApproval() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-live-order-incomplete")
    let now = Date(timeIntervalSince1970: 1_746_000_630)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let approvalStore = PMApprovalRequestStore(approvalRequestsDirectory: root.appendingPathComponent("approval_requests", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "I need the missing Live order details before I can create an in-app review item: quantity or notional, order type, and time-in-force.",
            actionPlan: PMConversationActionPlan(
                summary: "Ask for missing Live order details before creating any approval item.",
                actions: [
                    PMConversationActionIntent(
                        actionType: .askFollowUp,
                        summary: "Ask for quantity or notional, order type, and time-in-force before Live order review.",
                        sourceMessageIds: []
                    )
                ]
            ),
            resolution: PMConversationResolutionState(
                intentClass: .ambiguous,
                disposition: .clarificationRequired
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Asks for missing direct Live order details before creating review artifacts.",
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        configuration: Configuration(environment: .live),
        pmProfileStore: profileStore,
        pmApprovalRequestStore: approvalStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Buy AAPL live.",
        source: .ui
    )
    let reply = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)

    #expect((try await engine.listPMApprovalRequests()).isEmpty)
    #expect(reply.body.contains("quantity or notional"))
    #expect(reply.body.contains("Touch ID") == false)
    #expect(reply.conversationActionPlan?.actions.map(\.actionType) == [.askFollowUp])
    #expect(reply.conversationResolution?.disposition == .clarificationRequired)
}

@Test("In-app PM reply cannot promise approval or Touch ID without durable artifact")
func inAppPMReplyCannotPromiseApprovalOrTouchIDWithoutDurableArtifact() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-live-order-ghost-approval")
    let now = Date(timeIntervalSince1970: 1_746_000_640)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let approvalStore = PMApprovalRequestStore(approvalRequestsDirectory: root.appendingPathComponent("approval_requests", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "I created the in-app approval. Approve via Touch ID or your Mac password in the app.",
            actionPlan: PMConversationActionPlan(
                summary: "Model failed to emit the consequential approval action.",
                actions: [
                    PMConversationActionIntent(
                        actionType: .answerOnly,
                        summary: "No durable approval action was emitted.",
                        sourceMessageIds: []
                    )
                ]
            ),
            resolution: PMConversationResolutionState(
                intentClass: .instruction,
                disposition: .conversationOnly
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Repairs visible Live approval commitments that lack durable app-owned truth.",
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        configuration: Configuration(environment: .live),
        pmProfileStore: profileStore,
        pmApprovalRequestStore: approvalStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Place that live order now.",
        source: .ui
    )
    let reply = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)

    #expect((try await engine.listPMApprovalRequests()).isEmpty)
    #expect(reply.body.contains("I have not created an in-app approval item"))
    #expect(reply.body.contains("No PM approval request"))
    #expect(reply.body.contains("Touch ID route"))
    #expect(reply.runtimeProvenance?.conversationTrace?.visibleReplyModifiedAfterSynthesis == true)
    #expect(reply.conversationActionPlan?.actions.first?.detail?.contains("Work commitment consistency guard") == true)
}

@Test("In-app PM readback cannot deny existing Live order review route truth")
func inAppPMReadbackCannotDenyExistingLiveOrderReviewRouteTruth() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-live-order-readback-denial")
    let now = Date(timeIntervalSince1970: 1_746_000_645)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let approvalStore = PMApprovalRequestStore(approvalRequestsDirectory: root.appendingPathComponent("approval_requests", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "I have not created an in-app approval item or Touch ID route for this. No PM approval request, governed order-review artifact, LocalAuthentication handoff, or order attempt exists yet.",
            actionPlan: PMConversationActionPlan(
                summary: "Answer with an incorrect denial of existing app-owned order-review truth.",
                actions: [
                    PMConversationActionIntent(
                        actionType: .answerOnly,
                        summary: "Incorrectly deny Live order review route truth.",
                        sourceMessageIds: []
                    )
                ]
            ),
            resolution: PMConversationResolutionState(
                intentClass: .general,
                disposition: .conversationOnly
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Repairs Live order review readbacks from app-owned truth.",
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        configuration: Configuration(environment: .live),
        pmProfileStore: profileStore,
        pmApprovalRequestStore: approvalStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider,
        nowDate: { now }
    )
    _ = try await engine.upsertPMApprovalRequest(
        PMApprovalRequest(
            approvalRequestId: "approval-live-avgo",
            pmId: "pm-1",
            subject: "Approve Live order review: Buy AVGO, $9,000 market DAY",
            rationale: "Owner asked to review a Live notional AVGO order.",
            requestType: .liveOrderReview,
            status: .resolved,
            liveOrderReview: PMLiveOrderReviewPayload(
                symbol: "AVGO",
                side: .buy,
                orderType: .market,
                timeInForce: .day,
                notionalAmount: Decimal(9_000),
                instructionSummary: "Buy $9,000 of AVGO to the nearest whole share."
            ),
            ownerResponse: .approved,
            ownerRespondedAt: now,
            lastExecutionRoutingAssessment: PMExecutionRoutingAssessment(
                approvalRequestId: "approval-live-avgo",
                decisionId: nil,
                proposalId: nil,
                proposalTitle: nil,
                proposalStatus: nil,
                environment: .live,
                isLiveArmed: true,
                killSwitchEnabled: false,
                status: .blockedExecutionPrerequisites,
                action: .submitLiveOrderReview,
                summary: "The approved Live order review is waiting for a usable AVGO price before it can size whole shares.",
                detail: "The owner supplied $9,000 notional and asked for nearest-share sizing, but Store had no usable AVGO live price yet. No order has been sent.",
                blockedReasons: [.marketPriceUnavailable]
            ),
            createdAt: now,
            updatedAt: now
        )
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: PMCommunicationSenderRole.owner,
        senderId: "owner",
        body: "Why was the AVGO Live order blocked again?",
        source: AuditEventSource.ui
    )
    let reply = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: AuditEventSource.ui)

    #expect(reply.body.contains("I need to correct that"))
    #expect(reply.body.contains("app-owned Live order-review truth does exist"))
    #expect(reply.body.contains("market_price_unavailable"))
    #expect(reply.body.contains("No PM approval request") == false)
    #expect(reply.runtimeProvenance?.conversationTrace?.visibleReplyModifiedAfterSynthesis == true)
}

@Test("In-app PM reply cannot claim Your Decisions when created approval is not owner-visible")
func inAppPMReplyCannotClaimYourDecisionsWhenCreatedApprovalIsNotOwnerVisible() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-live-order-not-owner-visible")
    let now = Date(timeIntervalSince1970: 1_746_000_650)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let decisionStore = PMDecisionStore(decisionsDirectory: root.appendingPathComponent("decisions", isDirectory: true))
    let approvalStore = PMApprovalRequestStore(approvalRequestsDirectory: root.appendingPathComponent("approval_requests", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "I created the in-app review item in Command Center > Your Decisions.",
            actionPlan: PMConversationActionPlan(
                summary: "Create a durable PM review that should remain background-only.",
                actions: [
                    PMConversationActionIntent(
                        actionType: .createPMDecision,
                        summary: "Record a monitor-only standing review synthesis.",
                        title: "Standing review escalation: Technology Analyst",
                        body: "The current synthesis is worth monitoring only.",
                        detail: "Remain monitor-only; no governed next step.",
                        decisionType: .recommendation,
                        sourceMessageIds: []
                    ),
                    PMConversationActionIntent(
                        actionType: .createPMApprovalRequest,
                        summary: "Create a background-only standing review record.",
                        title: "Review standing analyst synthesis: Technology Analyst",
                        body: "The latest standing review is background-only and should remain monitor-only.",
                        detail: "Remain monitor-only; no governed next step.",
                        sourceMessageIds: []
                    )
                ]
            ),
            resolution: PMConversationResolutionState(
                intentClass: .instruction,
                disposition: .durableApplyNow
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Repairs approval claims that do not project to owner decisions.",
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        configuration: Configuration(environment: .live),
        pmProfileStore: profileStore,
        pmDecisionStore: decisionStore,
        pmApprovalRequestStore: approvalStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Record that monitor-only standing review.",
        source: .ui
    )
    let reply = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)
    let decisions = try await engine.listPMDecisions()
    let approvalRequests = try await engine.listPMApprovalRequests()
    let approval = try #require(approvalRequests.first)
    let ownerDecisionItems = makeOwnerDecisionDeskPresentations(
        approvalRequests: approvalRequests,
        decisions: decisions,
        delegations: [],
        tasks: [],
        findings: [],
        communicationMessages: [],
        charters: [],
        memos: [],
        strategyBrief: nil
    )

    #expect(approval.status == .pending)
    #expect(ownerDecisionItems.isEmpty)
    #expect(reply.body.contains("not currently visible in Command Center > Your Decisions"))
    #expect(reply.body.contains("I have not placed or routed any order"))
    #expect(reply.runtimeProvenance?.conversationTrace?.visibleReplyModifiedAfterSynthesis == true)
    #expect(reply.conversationActionPlan?.actions.first?.detail?.contains("owner-decision projection") == true)
}

@Test("In-app pending Live order review repairs premature Touch ID handoff wording")
func inAppPendingLiveOrderReviewRepairsPrematureTouchIDHandoffWording() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-live-order-touchid-repair")
    let now = Date(timeIntervalSince1970: 1_746_000_660)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let decisionStore = PMDecisionStore(decisionsDirectory: root.appendingPathComponent("decisions", isDirectory: true))
    let approvalStore = PMApprovalRequestStore(approvalRequestsDirectory: root.appendingPathComponent("approval_requests", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "I created the in-app approval. Approve via Touch ID or your Mac password in the app.",
            actionPlan: PMConversationActionPlan(
                summary: "Create a PM decision and Live order review item, but model overclaimed LocalAuthentication readiness.",
                actions: [
                    PMConversationActionIntent(
                        actionType: .createPMDecision,
                        summary: "Review a Live market day order to buy 1 AAPL share.",
                        title: "Live order review: buy 1 AAPL",
                        body: "The owner asked to review a Live market day order to buy 1 AAPL share.",
                        detail: "Review whether this Live order instruction should advance to the governed in-app order path.",
                        decisionType: .recommendation,
                        sourceMessageIds: []
                    ),
                    PMConversationActionIntent(
                        actionType: .createPMApprovalRequest,
                        summary: "Surface the Live order instruction for in-app review.",
                        title: "Review Live order instruction: buy 1 AAPL",
                        body: "Review a Live market day order instruction to buy 1 AAPL share.",
                        detail: "Approve only if this instruction should advance to the governed in-app order path.",
                        liveOrderSymbol: "AAPL",
                        liveOrderSide: .buy,
                        liveOrderQuantity: 1,
                        liveOrderType: .market,
                        liveOrderTimeInForce: .day,
                        requestType: .liveOrderReview,
                        sourceMessageIds: []
                    )
                ]
            ),
            resolution: PMConversationResolutionState(
                intentClass: .instruction,
                disposition: .durableApplyNow
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Repairs premature LocalAuthentication wording after creating review truth.",
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        configuration: Configuration(environment: .live),
        pmProfileStore: profileStore,
        pmDecisionStore: decisionStore,
        pmApprovalRequestStore: approvalStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Review a live market day order to buy 1 AAPL share.",
        source: .ui
    )
    let reply = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)
    let approval = try #require((try await engine.listPMApprovalRequests()).first)

    #expect(approval.requestType == .liveOrderReview)
    #expect(approval.status == .pending)
    #expect(reply.body.contains("Command Center > Your Decisions"))
    #expect(reply.body.contains("It is not a Touch ID or Mac password prompt yet"))
    #expect(reply.body.contains("LocalAuthentication only happens later"))
    #expect(reply.runtimeProvenance?.conversationTrace?.visibleReplyModifiedAfterSynthesis == true)
    #expect(reply.conversationActionPlan?.actions.last?.targetId == approval.approvalRequestId)
}

@Test("PM readback receives routed Live order review truth and is not repaired as a ghost approval")
func pmReadbackReceivesRoutedLiveOrderReviewTruth() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-communication-live-order-route-readback")
    let now = Date(timeIntervalSince1970: 1_768_242_900)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let approvalStore = PMApprovalRequestStore(approvalRequestsDirectory: root.appendingPathComponent("approval_requests", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "I created the META Live order review, you approved it, Touch ID completed at the Engine boundary, and the order was submitted through the governed route.",
            actionPlan: PMConversationActionPlan(
                summary: "Answer Live order readback from app-owned route truth.",
                actions: [
                    PMConversationActionIntent(
                        actionType: .answerOnly,
                        summary: "Read back the routed META Live order from app truth.",
                        sourceMessageIds: []
                    )
                ]
            ),
            resolution: PMConversationResolutionState(
                intentClass: .followUpQuestion,
                disposition: .conversationOnly
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Reads back routed Live order review state.",
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        configuration: Configuration(environment: .live),
        pmProfileStore: profileStore,
        pmApprovalRequestStore: approvalStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )
    _ = try await engine.upsertPMApprovalRequest(
        PMApprovalRequest(
            approvalRequestId: "approval-live-meta-routed",
            pmId: "pm-1",
            subject: "Live Order Review — Buy META $10,000 Market DAY",
            rationale: "Owner-approved Live order review routed through the Engine.",
            requestedActionSummary: "Approve or reject the Live order review.",
            requestType: .liveOrderReview,
            status: .resolved,
            liveOrderReview: PMLiveOrderReviewPayload(
                symbol: "META",
                side: .buy,
                orderType: .market,
                timeInForce: .day,
                notionalAmount: Decimal(10_000),
                environment: .live,
                instructionSummary: "Buy META around $10,000 to the nearest whole share."
            ),
            ownerResponse: .approved,
            ownerRespondedAt: now.addingTimeInterval(20),
            lastExecutionRoutingAssessment: PMExecutionRoutingAssessment(
                approvalRequestId: "approval-live-meta-routed",
                decisionId: nil,
                proposalId: nil,
                proposalTitle: nil,
                proposalStatus: nil,
                environment: .live,
                isLiveArmed: true,
                killSwitchEnabled: false,
                status: .routedSuccessfully,
                action: .submitLiveOrderReview,
                summary: "The approved Live order review was routed through the Engine order path.",
                detail: "Sizing converted target notional 10000 using last trade price 599.58 into nearest whole-share quantity 17. Engine accepted the Live order submission attempt. LocalAuthentication remained at the final Engine boundary when enabled.",
                blockedReasons: []
            ),
            createdAt: now,
            updatedAt: now.addingTimeInterval(30)
        ),
        source: .system
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "What happened with the META Live order?",
        source: .ui
    )
    let reply = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)
    let request = try #require(await synthesisProvider.lastConversationRequest)
    let confirmedTruth = request.confirmedAppTruthSummary.joined(separator: "\n")

    #expect(confirmedTruth.contains("Confirmed Live order review route in app truth"))
    #expect(confirmedTruth.contains("META buy market day"))
    #expect(confirmedTruth.contains("route_status=routed_successfully"))
    #expect(confirmedTruth.contains("nearest whole-share quantity 17"))
    #expect(reply.body.contains("order was submitted through the governed route"))
    #expect(reply.body.contains("I have not created an in-app approval item") == false)
    #expect(reply.runtimeProvenance?.conversationTrace?.visibleReplyModifiedAfterSynthesis != true)
}

@Test("PM conversation surfaces a real owner approval step when initial paper-trade establishment would otherwise stall")
func pmConversationPaperEstablishmentAskSurfacesOwnerApprovalStep() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-conversation-paper-establishment-approval")
    let now = Date(timeIntervalSince1970: 1_746_001_200)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let instructionStore = PMInstructionStore(instructionsDirectory: root.appendingPathComponent("instructions", isDirectory: true))
    let decisionStore = PMDecisionStore(decisionsDirectory: root.appendingPathComponent("decisions", isDirectory: true))
    let approvalStore = PMApprovalRequestStore(approvalRequestsDirectory: root.appendingPathComponent("approval_requests", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "The current working paper portfolio is defined, so the next governed step is an owner-visible approval ask before any paper-establishment routing can run.",
            actionPlan: makePaperPortfolioEstablishmentModelActionPlan(
                summary: "Model interpreted the owner ask as needing an approval-ready PM decision for paper-establishment.",
                includeDecisionAndApprovalCreation: true,
                includeApproval: false,
                includeRoute: false
            ),
            resolution: PMConversationResolutionState(
                intentClass: .instruction,
                disposition: .conversationOnly
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Surfaces governed owner decisions when paper-establishment needs an explicit next step.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await instructionStore.upsert(
        PMInstruction(
            instructionId: "instruction-working-paper-portfolio",
            pmId: "pm-1",
            title: "Working paper portfolio definition",
            body: "Initial paper portfolio: long MSFT and NVDA, short NYCB, and keep a cash buffer until confirmed holdings are rebuilt from app truth.",
            category: "conversation_working_portfolio_definition",
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        configuration: Configuration(environment: .paper),
        pmProfileStore: profileStore,
        pmInstructionStore: instructionStore,
        pmDecisionStore: decisionStore,
        pmApprovalRequestStore: approvalStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "The working initial paper portfolio is already defined. What is the next governed step needed to establish the associated paper trades?",
        source: .ui
    )
    let reply = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)

    let decisions = try await engine.listPMDecisions()
    let approvalRequests = try await engine.listPMApprovalRequests()
    let allMessages = try await engine.listPMCommunicationMessages()
    let decision = try #require(decisions.last)
    let approvalRequest = try #require(approvalRequests.last)
    let sessionMessages = allMessages.filter { $0.sessionId == session.sessionId }
    let followThroughMessages = sessionMessages.filter {
        $0.senderRole == .pm && $0.replyToMessageId == reply.messageId
    }
    let followThrough = try #require(followThroughMessages.last)
    let ownerDecisionItems = makeOwnerDecisionDeskPresentations(
        approvalRequests: approvalRequests,
        decisions: decisions,
        delegations: [],
        tasks: [],
        findings: [],
        communicationMessages: allMessages,
        charters: [],
        memos: [],
        strategyBrief: nil
    )

    #expect(reply.runtimeProvenance?.conversationTrace?.actionPlanSource == .modelActionPlan)
    #expect(reply.conversationActionPlan?.actions.map(\.actionType) == [.createPMDecision, .createPMApprovalRequest])
    #expect(decision.title.contains("initial paper portfolio"))
    #expect(approvalRequest.requestType == .portfolioAction)
    #expect(approvalRequest.status == .pending)
    #expect(approvalRequest.proposalId == nil)
    #expect(approvalRequest.requestedActionSummary?.contains("governed paper-establishment workflow") == true)
    #expect(followThrough.body.contains("approval-ready PM ask"))
    #expect(followThrough.body.contains("No governed routing or paper-trade execution runs until that response is on record."))
    #expect(ownerDecisionItems.count == 1)
    #expect(ownerDecisionItems.first?.approvalRequestId == approvalRequest.approvalRequestId)
    #expect(ownerDecisionItems.first?.requestTypeTitle == "Portfolio Action")
    #expect(ownerDecisionItems.first?.ownerAsk.contains("governed paper-establishment workflow") == true)
}

@Test("PM conversation preserves a genuine clarification instead of forcing paper-establishment approval")
func pmConversationPaperEstablishmentAskPreservesModelClarification() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-conversation-paper-establishment-clarify")
    let now = Date(timeIntervalSince1970: 1_746_001_250)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let instructionStore = PMInstructionStore(instructionsDirectory: root.appendingPathComponent("instructions", isDirectory: true))
    let decisionStore = PMDecisionStore(decisionsDirectory: root.appendingPathComponent("decisions", isDirectory: true))
    let approvalStore = PMApprovalRequestStore(approvalRequestsDirectory: root.appendingPathComponent("approval_requests", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "Before I move this forward, do you want me to keep the current weights exactly as defined or revise the initial paper-trade sizing first?",
            actionPlan: PMConversationActionPlan(
                summary: "Ask one bounded clarification before moving toward paper-establishment.",
                actions: [
                    PMConversationActionIntent(
                        actionType: .askFollowUp,
                        summary: "Clarify whether the current weights should stand before paper establishment.",
                        sourceMessageIds: []
                    )
                ]
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Keeps genuine clarifications intact before any governed paper-establishment escalation.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await instructionStore.upsert(
        PMInstruction(
            instructionId: "instruction-working-paper-portfolio-clarify",
            pmId: "pm-1",
            title: "Working paper portfolio definition",
            body: "Initial paper portfolio: long MSFT and NVDA, short NYCB, and keep a cash buffer until confirmed holdings are rebuilt from app truth.",
            category: "conversation_working_portfolio_definition",
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        configuration: Configuration(environment: .paper),
        pmProfileStore: profileStore,
        pmInstructionStore: instructionStore,
        pmDecisionStore: decisionStore,
        pmApprovalRequestStore: approvalStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Please establish the initial paper portfolio trades.",
        source: .ui
    )
    let reply = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)

    let decisions = try await engine.listPMDecisions()
    let approvalRequests = try await engine.listPMApprovalRequests()

    #expect(reply.runtimeProvenance?.conversationTrace?.actionPlanSource == .modelActionPlan)
    #expect(reply.conversationActionPlan?.actions.map(\.actionType) == [.askFollowUp])
    #expect(decisions.isEmpty)
    #expect(approvalRequests.isEmpty)
}

@Test("Explicit owner instruction records approval and surfaces the real governed blocker for paper establishment")
func pmConversationExplicitPaperEstablishmentInstructionSurfacesSpecificGovernedBlocker() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-conversation-paper-establishment-approval-bridge-blocked")
    let now = Date(timeIntervalSince1970: 1_746_001_320)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let instructionStore = PMInstructionStore(instructionsDirectory: root.appendingPathComponent("instructions", isDirectory: true))
    let decisionStore = PMDecisionStore(decisionsDirectory: root.appendingPathComponent("decisions", isDirectory: true))
    let approvalStore = PMApprovalRequestStore(approvalRequestsDirectory: root.appendingPathComponent("approval_requests", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "Understood. I’m moving the current paper-portfolio target into the governed implementation path now.",
            actionPlan: makePaperPortfolioEstablishmentModelActionPlan(
                summary: "Model interpreted the owner turn as explicit approval to route the existing paper-establishment PM ask.",
                includeDecisionAndApprovalCreation: false,
                includeApproval: true,
                includeRoute: true
            ),
            resolution: PMConversationResolutionState(
                intentClass: .instruction,
                disposition: .conversationOnly
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Records explicit owner approval and surfaces specific governed blockers.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await instructionStore.upsert(
        PMInstruction(
            instructionId: "instruction-working-paper-portfolio-bridge",
            pmId: "pm-1",
            title: "Working paper portfolio definition",
            body: "Initial paper portfolio: long NVDA, TSM, AVGO, AMZN, GOOG, AAPL, CRWD, NFLX, and TSLA; short KSS and NYCB.",
            category: "conversation_working_portfolio_definition",
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        configuration: Configuration(environment: .paper),
        pmProfileStore: profileStore,
        pmInstructionStore: instructionStore,
        pmDecisionStore: decisionStore,
        pmApprovalRequestStore: approvalStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let originalAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "The working initial paper portfolio is already defined. Please establish the associated paper trades now.",
        source: .ui
    )
    let decision = try await engine.upsertPMDecision(
        PMDecisionRecord(
            decisionId: "pm-decision-paper-establishment-bridge",
            pmId: "pm-1",
            title: "PM recommendation: establish the initial paper portfolio through the governed paper workflow",
            summary: "The working target is defined, but the app still needs explicit owner approval and a governed next step before any paper-trade routing can occur.",
            recommendedAction: "Move the current working paper portfolio into the governed paper-establishment workflow now.",
            ownerAsk: "Decide whether I should move the current working paper portfolio into the governed paper-establishment workflow now.",
            sourceCommunicationMessageId: originalAsk.messageId,
            decisionType: .recommendation,
            status: .active,
            createdAt: now,
            updatedAt: now
        ),
        source: .ui
    )
    let pendingRequest = try await engine.createPMApprovalRequestFromDecision(
        decisionId: decision.decisionId,
        subject: "Review PM recommendation: establish the initial paper portfolio",
        rationale: "The working paper portfolio target is defined, but the app still needs explicit owner approval before governed paper-establishment routing can continue.",
        requestedActionSummary: "Approve moving the current working paper portfolio into the governed paper-establishment workflow now.",
        requestType: .portfolioAction,
        source: .ui
    )

    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Place the initial paper-portfolio trades now through the app.",
        source: .ui
    )
    let reply = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)

    let updatedRequest = try await engine.getPMApprovalRequest(id: pendingRequest.approvalRequestId)
    let allMessages = try await engine.listPMCommunicationMessages()
    let sessionMessages = allMessages.filter { $0.sessionId == session.sessionId }
    #expect(reply.runtimeProvenance?.conversationTrace?.actionPlanSource == .modelActionPlan)
    #expect(reply.conversationActionPlan?.actions.map(\.actionType) == [.approvePMApprovalRequest, .routeGovernedExecutionNextStep])
    #expect(updatedRequest.status == .resolved)
    #expect(updatedRequest.ownerResponse == .approved)
    #expect(updatedRequest.proposalId == nil)
    let followThroughMessages = sessionMessages.filter {
        $0.senderRole == .pm && $0.replyToMessageId == reply.messageId
    }
    #expect(followThroughMessages.isEmpty == false)
    if let followThrough = followThroughMessages.last {
        #expect(followThrough.body.contains("I recorded your explicit approval"))
        #expect(followThrough.body.contains("machine-readable weighted format yet"))
        #expect(followThrough.body.contains("waiting for the next governed app step") == false)
        #expect(followThrough.body.contains("actively placing those paper trades") == false)
    }
}

@Test("Explicit owner instruction can resolve a pending PM approval ask and route the approved paper step now")
func pmConversationExplicitPaperEstablishmentInstructionRoutesApprovedNextStep() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-conversation-paper-establishment-approval-bridge-routes")
    let now = Date(timeIntervalSince1970: 1_746_001_360)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let approvalStore = PMApprovalRequestStore(approvalRequestsDirectory: root.appendingPathComponent("approval_requests", isDirectory: true))
    let decisionStore = PMDecisionStore(decisionsDirectory: root.appendingPathComponent("decisions", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let proposalStore = ProposalStore(proposalsDirectory: root.appendingPathComponent("proposals", isDirectory: true))
    let paperRunStore = PaperRunStore(runsDirectory: root.appendingPathComponent("runs", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "Understood. I’m moving the current paper-portfolio target into the governed implementation path now.",
            actionPlan: makePaperPortfolioEstablishmentModelActionPlan(
                summary: "Model interpreted the owner turn as explicit approval to route the existing approved paper next step.",
                includeDecisionAndApprovalCreation: false,
                includeApproval: true,
                includeRoute: true
            ),
            resolution: PMConversationResolutionState(
                intentClass: .instruction,
                disposition: .conversationOnly
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Bridges explicit owner approval into real governed execution routing.",
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        configuration: Configuration(environment: .paper),
        pmProfileStore: profileStore,
        pmDecisionStore: decisionStore,
        pmApprovalRequestStore: approvalStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider,
        proposalStore: proposalStore,
        paperRunStore: paperRunStore
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let originalAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "The working initial paper portfolio is ready. Move it forward through the paper-safe governed path when you can.",
        source: .ui
    )
    _ = try await proposalStore.upsertProposal(
        makePMConversationGovernedExecutionProposal(
            id: "proposal-paper-establishment-approval-bridge",
            status: .approvedPaper
        )
    )
    let decision = try await engine.upsertPMDecision(
        PMDecisionRecord(
            decisionId: "pm-decision-paper-establishment-route",
            pmId: "pm-1",
            title: "PM recommendation: route the approved paper next step",
            summary: "The bounded paper proposal is already approved and only needs explicit owner confirmation before governed routing.",
            recommendedAction: "Route the approved paper-safe next step now.",
            ownerAsk: "Approve routing the already-approved paper-safe next step now.",
            sourceCommunicationMessageId: originalAsk.messageId,
            decisionType: .recommendation,
            status: .active,
            proposalId: "proposal-paper-establishment-approval-bridge",
            createdAt: now,
            updatedAt: now
        ),
        source: .ui
    )
    let pendingRequest = try await engine.createPMApprovalRequestFromDecision(
        decisionId: decision.decisionId,
        subject: "Review PM recommendation: route the approved paper step",
        rationale: "The linked paper proposal is already approved, so explicit owner approval can route it through the normal paper-safe path now.",
        requestedActionSummary: "Approve routing the already-approved paper-safe next step now.",
        requestType: .proposalReview,
        source: .ui
    )

    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Go ahead and place the initial paper-portfolio trades now.",
        source: .ui
    )
    let reply = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)

    let updatedRequest = try await engine.getPMApprovalRequest(id: pendingRequest.approvalRequestId)
    let runs = try await paperRunStore.listRuns(proposalId: "proposal-paper-establishment-approval-bridge")
    let allMessages = try await engine.listPMCommunicationMessages()
    let sessionMessages = allMessages.filter { $0.sessionId == session.sessionId }
    #expect(reply.runtimeProvenance?.conversationTrace?.actionPlanSource == .modelActionPlan)
    #expect(reply.conversationActionPlan?.actions.map(\.actionType) == [.approvePMApprovalRequest, .routeGovernedExecutionNextStep])
    #expect(updatedRequest.status == .resolved)
    #expect(updatedRequest.ownerResponse == .approved)
    #expect(runs.count == 1)
    let followThroughMessages = sessionMessages.filter {
        $0.senderRole == .pm && $0.replyToMessageId == reply.messageId
    }
    #expect(followThroughMessages.isEmpty == false)
    if let followThrough = followThroughMessages.last {
        #expect(followThrough.body.contains("I recorded your explicit approval"))
        #expect(followThrough.body.contains("paper-safe execution path"))
        #expect(followThrough.body.contains("waiting for the next governed app step") == false)
    }
    _ = try await engine.stopStrategy(id: "heartbeat")
}

@Test("Exact live paper-portfolio execution wording is not repaired into action when the model emits an incomplete plan")
func pmConversationExactLivePaperPortfolioExecutionInstructionDoesNotUseRawTextBridgeForWeakModelPlan() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-conversation-live-paper-portfolio-execution-repair")
    let now = Date(timeIntervalSince1970: 1_746_159_600)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let instructionStore = PMInstructionStore(instructionsDirectory: root.appendingPathComponent("instructions", isDirectory: true))
    let decisionStore = PMDecisionStore(decisionsDirectory: root.appendingPathComponent("decisions", isDirectory: true))
    let approvalStore = PMApprovalRequestStore(approvalRequestsDirectory: root.appendingPathComponent("approval_requests", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let proposalStore = ProposalStore(proposalsDirectory: root.appendingPathComponent("proposals", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "I can see the current target, but I need the governed approval artifact to be valid before anything can route.",
            actionPlan: PMConversationActionPlan(
                summary: "Capture the owner's execution instruction by opening the governed approval step for establishing the current proposed paper portfolio at the agreed target weights.",
                actions: [
                    PMConversationActionIntent(
                        actionType: .createPMApprovalRequest,
                        summary: "Open the paper-portfolio establishment approval step for the current target allocation.",
                        title: "Approval request: establish current proposed paper portfolio",
                        body: "Requested action: establish the current proposed paper portfolio at the agreed target weights. Portfolio target: Long NVDA 16%, TSM 11%, AVGO 11%, AMZN 11%, GOOG 11%, AAPL 10%, CRWD 10%, NFLX 10%, TSLA 10%; Short KSS -7%, NYCB -5%. This is a working portfolio definition and not confirmed executed holdings.",
                        detail: "Create a governed approval request to establish the current proposed paper portfolio using the latest conversation-owned target sizing: Long NVDA 16%, TSM 11%, AVGO 11%, AMZN 11%, GOOG 11%, AAPL 10%, CRWD 10%, NFLX 10%, TSLA 10%; Short KSS -7%, NYCB -5%.",
                        requestType: .portfolioAction,
                        sourceMessageIds: []
                    )
                ]
            ),
            resolution: PMConversationResolutionState(
                intentClass: .instruction,
                disposition: .workingUnderstandingOnly,
                workingUnderstandingSummary: "The active conversation-owned paper portfolio to establish remains: Long NVDA 16%, TSM 11%, AVGO 11%, AMZN 11%, GOOG 11%, AAPL 10%, CRWD 10%, NFLX 10%, TSLA 10%; Short KSS -7%, NYCB -5%. The owner instructed that it should be established.",
                operatingTruthKind: .workingPortfolioDefinition,
                operatingTruthSummary: "Current working paper portfolio target remains the agreed conviction-weighted long/short allocation, and the owner has instructed that it be established.",
                operatingTruthBody: "Paper portfolio target sizing to implement: Long NVDA 16%, TSM 11%, AVGO 11%, AMZN 11%, GOOG 11%, AAPL 10%, CRWD 10%, NFLX 10%, TSLA 10%; Short KSS -7%, NYCB -5%. This remains a target allocation and not confirmed executed holdings."
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Rejects incomplete model action plans instead of repairing them from owner wording.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await instructionStore.upsert(
        PMInstruction(
            instructionId: "instruction-working-paper-portfolio-live-wording",
            pmId: "pm-1",
            title: "Working paper portfolio definition",
            body: "Initial paper portfolio: Long NVDA 16%, TSM 11%, AVGO 11%, AMZN 11%, GOOG 11%, AAPL 10%, CRWD 10%, NFLX 10%, TSLA 10%; Short KSS -7%, NYCB -5%.",
            category: "conversation_working_portfolio_definition",
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        configuration: Configuration(environment: .paper),
        pmProfileStore: profileStore,
        pmInstructionStore: instructionStore,
        pmDecisionStore: decisionStore,
        pmApprovalRequestStore: approvalStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider,
        proposalStore: proposalStore
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: PMCommunicationSenderRole.owner,
        senderId: "owner",
        body: "Execute the trades required to implement the current proposed paper portfolio",
        source: AuditEventSource.ui
    )
    let reply = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: AuditEventSource.ui)

    let decisions = try await engine.listPMDecisions()
    let approvalRequests = try await engine.listPMApprovalRequests()
    let proposals = try await engine.listProposals()
    let allMessages = try await engine.listPMCommunicationMessages()
    let actionTypes = reply.conversationActionPlan?.actions.map { $0.actionType }

    #expect(reply.runtimeProvenance?.conversationTrace?.actionPlanSource == .modelActionPlan)
    #expect(actionTypes == [.createPMApprovalRequest])
    #expect(decisions.isEmpty)
    #expect(approvalRequests.isEmpty)
    #expect(proposals.isEmpty)

    let followThroughMessages = allMessages.filter { message in
        message.senderRole == PMCommunicationSenderRole.pm && message.replyToMessageId == reply.messageId
    }
    #expect(followThroughMessages.isEmpty)
}

@Test("Exact live paper-portfolio execution wording reaches actual paper order submission through the Engine pipeline")
func pmConversationExactLivePaperPortfolioExecutionInstructionSubmitsOrdersThroughEnginePipeline() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-conversation-live-paper-portfolio-order-submission")
    let now = Date(timeIntervalSince1970: 1_746_246_100)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let instructionStore = PMInstructionStore(instructionsDirectory: root.appendingPathComponent("instructions", isDirectory: true))
    let decisionStore = PMDecisionStore(decisionsDirectory: root.appendingPathComponent("decisions", isDirectory: true))
    let approvalStore = PMApprovalRequestStore(approvalRequestsDirectory: root.appendingPathComponent("approval_requests", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let store = Store()
    let rest = RecordingPMConversationRESTClient()
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "Understood. I’ve routed the current paper-portfolio establishment request forward at the agreed target weights.",
            actionPlan: makePaperPortfolioEstablishmentModelActionPlan(
                summary: "Model interpreted the owner turn as explicit approval to create, approve, and route the governed paper-establishment step."
            ),
            resolution: PMConversationResolutionState(
                intentClass: .instruction,
                disposition: .workingUnderstandingOnly,
                workingUnderstandingSummary: "The current working paper portfolio remains the latest agreed long/short target allocation, and the owner instructed that it should now be implemented.",
                operatingTruthKind: .workingPortfolioDefinition,
                operatingTruthSummary: "The current proposed paper portfolio remains the active working target to implement.",
                operatingTruthBody: "Initial paper portfolio: Long NVDA 16%, TSM 11%, AVGO 11%, AMZN 11%, GOOG 11%, AAPL 10%, CRWD 10%, NFLX 10%, TSLA 10%; Short KSS -7%, NYCB -5%."
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Routes explicit owner paper-portfolio execution requests into actual Engine order submission.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await instructionStore.upsert(
        PMInstruction(
            instructionId: "instruction-working-paper-portfolio-executable",
            pmId: "pm-1",
            title: "Working paper portfolio definition",
            body: "Initial paper portfolio: Long NVDA 16%, TSM 11%, AVGO 11%, AMZN 11%, GOOG 11%, AAPL 10%, CRWD 10%, NFLX 10%, TSLA 10%; Short KSS -7%, NYCB -5%.",
            category: "conversation_working_portfolio_definition",
            createdAt: now,
            updatedAt: now
        )
    )

    await rest.setAccount(
        Account(
            id: "acct-paper-establishment",
            status: "ACTIVE",
            cash: "100000",
            buyingPower: "200000",
            equity: "100000",
            multiplier: "2"
        )
    )
    await store.applyStartupSnapshot(
        account: Account(
            id: "acct-paper-establishment",
            status: "ACTIVE",
            cash: "100000",
            buyingPower: "200000",
            equity: "100000",
            multiplier: "2"
        ),
        positions: [],
        openOrders: []
    )
    await publishPaperPortfolioQuotes(
        store: store,
        pricesBySymbol: [
            "NVDA": 209,
            "TSM": 394,
            "AVGO": 399,
            "AMZN": 262,
            "GOOG": 347,
            "AAPL": 270,
            "CRWD": 448,
            "NFLX": 92,
            "TSLA": 372,
            "KSS": 14,
            "NYCB": 5
        ]
    )

    let engine = Engine(
        configuration: Configuration(environment: .paper),
        store: store,
        pmProfileStore: profileStore,
        pmInstructionStore: instructionStore,
        pmDecisionStore: decisionStore,
        pmApprovalRequestStore: approvalStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider,
        keychainProvider: pmConversationAlpacaKeychainProvider(),
        restClientFactory: { _ in rest },
        workingPaperPortfolioPriceRepairEnabled: false
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Execute the trades required to implement the current proposed paper portfolio",
        source: .ui
    )
    let reply = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)

    let approvalRequests = try await engine.listPMApprovalRequests()
    let approvalRequest = try #require(approvalRequests.last)
    let allMessages = try await engine.listPMCommunicationMessages()
    let followThroughMessages = allMessages.filter { message in
        message.sessionId == session.sessionId
            && message.senderRole == .pm
            && message.replyToMessageId == reply.messageId
    }
    let followThrough = try #require(followThroughMessages.last)
    let placedOrders = await rest.placedOrders()
    let placedSymbols = Set(placedOrders.map(\.symbol))
    let snapshot = await store.snapshot()

    #expect(reply.runtimeProvenance?.conversationTrace?.actionPlanSource == .modelActionPlan)
    #expect(reply.conversationActionPlan?.actions.map(\.actionType) == [
        .createPMDecision,
        .createPMApprovalRequest,
        .approvePMApprovalRequest,
        .routeGovernedExecutionNextStep
    ])
    #expect(approvalRequest.status == .resolved)
    #expect(approvalRequest.ownerResponse == .approved)
    #expect(await rest.placeOrderCallCount() == 11)
    #expect(placedSymbols == Set(["NVDA", "TSM", "AVGO", "AMZN", "GOOG", "AAPL", "CRWD", "NFLX", "TSLA", "KSS", "NYCB"]))
    #expect(placedOrders.allSatisfy { $0.type == .market && $0.timeInForce == .day })
    #expect(
        Dictionary(uniqueKeysWithValues: placedOrders.map { ($0.symbol, $0.qty) }) == [
            "NVDA": "76",
            "TSM": "27",
            "AVGO": "27",
            "AMZN": "41",
            "GOOG": "31",
            "AAPL": "37",
            "CRWD": "22",
            "NFLX": "108",
            "TSLA": "26",
            "KSS": "500",
            "NYCB": "1000"
        ]
    )
    #expect(snapshot.openOrders.count == 11)
    #expect(followThrough.body.contains("I submitted the current paper-portfolio establishment orders through the app."))
    #expect(followThrough.body.contains("Accepted order attempts:") == true)
    #expect(followThrough.body.contains("not confirmed as initiated") == false)
    #expect(followThrough.body.contains("instruction is on record") == false)
}

@Test("Missing NYCB price submits executable current paper-portfolio legs and leaves NYCB pending")
func pmConversationPaperPortfolioExecutionSubmitsLivePricedLegsWhenOnlyNYCBIsMissing() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-conversation-paper-portfolio-missing-nycb-partial")
    let now = Date(timeIntervalSince1970: 1_746_246_130)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let instructionStore = PMInstructionStore(instructionsDirectory: root.appendingPathComponent("instructions", isDirectory: true))
    let decisionStore = PMDecisionStore(decisionsDirectory: root.appendingPathComponent("decisions", isDirectory: true))
    let approvalStore = PMApprovalRequestStore(approvalRequestsDirectory: root.appendingPathComponent("approval_requests", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let store = Store()
    let rest = RecordingPMConversationRESTClient()
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "Understood. I’m routing the current paper-portfolio establishment step now.",
            actionPlan: makePaperPortfolioEstablishmentModelActionPlan(
                summary: "Model interpreted the owner turn as explicit approval to create, approve, and route the governed paper-establishment step."
            ),
            resolution: PMConversationResolutionState(
                intentClass: .instruction,
                disposition: .workingUnderstandingOnly,
                workingUnderstandingSummary: "The current working paper portfolio remains approved for governed paper execution.",
                operatingTruthKind: .workingPortfolioDefinition,
                operatingTruthSummary: "The current proposed paper portfolio remains the active working target to implement.",
                operatingTruthBody: "Initial paper portfolio: Long NVDA 16%, TSM 11%, AVGO 11%, AMZN 11%, GOOG 11%, AAPL 10%, CRWD 10%, NFLX 10%, TSLA 10%; Short KSS -7%, NYCB -5%."
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Routes executable current paper-portfolio legs while leaving unpriced symbols pending.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await instructionStore.upsert(
        PMInstruction(
            instructionId: "instruction-working-paper-portfolio-missing-nycb",
            pmId: "pm-1",
            title: "Working paper portfolio definition",
            body: "Initial paper portfolio: Long NVDA 16%, TSM 11%, AVGO 11%, AMZN 11%, GOOG 11%, AAPL 10%, CRWD 10%, NFLX 10%, TSLA 10%; Short KSS -7%, NYCB -5%.",
            category: "conversation_working_portfolio_definition",
            createdAt: now,
            updatedAt: now
        )
    )

    let account = Account(
        id: "acct-paper-establishment-missing-nycb",
        status: "ACTIVE",
        cash: "100000",
        buyingPower: "200000",
        equity: "100000",
        multiplier: "2"
    )
    await rest.setAccount(account)
    await store.applyStartupSnapshot(account: account, positions: [], openOrders: [])
    await publishPaperPortfolioQuotes(
        store: store,
        pricesBySymbol: [
            "NVDA": 209,
            "TSM": 394,
            "AVGO": 399,
            "AMZN": 262,
            "GOOG": 347,
            "AAPL": 270,
            "CRWD": 448,
            "NFLX": 92,
            "TSLA": 372,
            "KSS": 14
        ]
    )

    let engine = Engine(
        configuration: Configuration(environment: .paper),
        store: store,
        pmProfileStore: profileStore,
        pmInstructionStore: instructionStore,
        pmDecisionStore: decisionStore,
        pmApprovalRequestStore: approvalStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider,
        keychainProvider: pmConversationAlpacaKeychainProvider(),
        restClientFactory: { _ in rest },
        workingPaperPortfolioPriceRepairEnabled: false
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Please place the paper-portfolio trades for every name that has live pricing now.",
        source: .ui
    )
    let reply = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)

    let approvalRequest = try #require(try await engine.listPMApprovalRequests().last)
    let pendingState = try #require(approvalRequest.paperPortfolioExecutionPendingState)
    let allMessages = try await engine.listPMCommunicationMessages()
    let followThrough = try #require(
        allMessages.filter { message in
            message.sessionId == session.sessionId
                && message.senderRole == .pm
                && message.replyToMessageId == reply.messageId
        }.last
    )
    let placedOrders = await rest.placedOrders()
    let placedSymbols = Set(placedOrders.map(\.symbol))
    let snapshot = await store.snapshot()

    #expect(await rest.placeOrderCallCount() == 10)
    #expect(placedSymbols == Set(["NVDA", "TSM", "AVGO", "AMZN", "GOOG", "AAPL", "CRWD", "NFLX", "TSLA", "KSS"]))
    #expect(
        Dictionary(uniqueKeysWithValues: placedOrders.map { ($0.symbol, $0.qty) }) == [
            "NVDA": "76",
            "TSM": "27",
            "AVGO": "27",
            "AMZN": "41",
            "GOOG": "31",
            "AAPL": "37",
            "CRWD": "22",
            "NFLX": "108",
            "TSLA": "26",
            "KSS": "500"
        ]
    )
    #expect(snapshot.openOrders.count == 10)
    #expect(pendingState.status == .waitingForUsablePrices)
    #expect(Set(pendingState.missingPriceSymbols) == Set(["NYCB"]))
    #expect(approvalRequest.paperPortfolioExecutionLifecycleState?.status == .partiallySubmitted)
    #expect(approvalRequest.paperPortfolioExecutionLifecycleState?.orderAttemptCount == 10)
    #expect(approvalRequest.paperPortfolioExecutionLifecycleState?.acceptedOrderAttemptCount == 10)
    #expect(followThrough.body.contains("I submitted part of the current paper-portfolio establishment order set"))
    #expect(followThrough.body.contains("Accepted order attempts:") == true)
    #expect(followThrough.body.contains("usable prices to size these symbols: NYCB"))
    #expect(followThrough.body.contains("below one share") == false)
    #expect(followThrough.body.contains("instruction is on record") == false)
}

@Test("Paper-portfolio execution submits priced legs and leaves missing-price symbols pending")
func pmConversationPaperPortfolioExecutionSubmitsPricedLegsAndLeavesMissingSymbolsPending() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-conversation-paper-portfolio-partial-submission")
    let now = Date(timeIntervalSince1970: 1_746_246_160)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let instructionStore = PMInstructionStore(instructionsDirectory: root.appendingPathComponent("instructions", isDirectory: true))
    let decisionStore = PMDecisionStore(decisionsDirectory: root.appendingPathComponent("decisions", isDirectory: true))
    let approvalStore = PMApprovalRequestStore(approvalRequestsDirectory: root.appendingPathComponent("approval_requests", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let store = Store()
    let rest = RecordingPMConversationRESTClient()
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "Understood. I’ve captured your instruction to implement the current proposed paper portfolio.",
            actionPlan: makePaperPortfolioEstablishmentModelActionPlan(
                summary: "Model interpreted the owner turn as explicit approval to create, approve, and route the governed paper-establishment step."
            ),
            resolution: PMConversationResolutionState(
                intentClass: .instruction,
                disposition: .workingUnderstandingOnly,
                workingUnderstandingSummary: "The current working paper portfolio should now be implemented.",
                operatingTruthKind: .workingPortfolioDefinition,
                operatingTruthSummary: "The current proposed paper portfolio remains the active working target to implement.",
                operatingTruthBody: "Initial paper portfolio: Long NVDA 50%, TSM 25%; Short KSS -25%."
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Reports exact order-attempt blockers when only part of a paper portfolio can be sized.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await instructionStore.upsert(
        PMInstruction(
            instructionId: "instruction-working-paper-portfolio-partial",
            pmId: "pm-1",
            title: "Working paper portfolio definition",
            body: "Initial paper portfolio: Long NVDA 50%, TSM 25%; Short KSS -25%.",
            category: "conversation_working_portfolio_definition",
            createdAt: now,
            updatedAt: now
        )
    )

    await rest.setAccount(
        Account(
            id: "acct-paper-establishment-partial",
            status: "ACTIVE",
            cash: "100000",
            buyingPower: "200000",
            equity: "100000",
            multiplier: "2"
        )
    )
    await store.applyStartupSnapshot(
        account: Account(
            id: "acct-paper-establishment-partial",
            status: "ACTIVE",
            cash: "100000",
            buyingPower: "200000",
            equity: "100000",
            multiplier: "2"
        ),
        positions: [],
        openOrders: []
    )
    await publishPaperPortfolioQuotes(
        store: store,
        pricesBySymbol: [
            "NVDA": 100,
            "TSM": 100
        ]
    )

    let engine = Engine(
        configuration: Configuration(environment: .paper),
        store: store,
        pmProfileStore: profileStore,
        pmInstructionStore: instructionStore,
        pmDecisionStore: decisionStore,
        pmApprovalRequestStore: approvalStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider,
        keychainProvider: pmConversationAlpacaKeychainProvider(),
        restClientFactory: { _ in rest },
        workingPaperPortfolioPriceRepairEnabled: false
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Place the trades now to establish the proposed paper portfolio",
        source: .ui
    )
    let reply = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)

    let allMessages = try await engine.listPMCommunicationMessages()
    let followThroughMessages = allMessages.filter { message in
        message.sessionId == session.sessionId
            && message.senderRole == .pm
            && message.replyToMessageId == reply.messageId
    }
    let followThrough = try #require(followThroughMessages.last)
    let snapshot = await store.snapshot()
    let approvalRequest = try #require(try await engine.listPMApprovalRequests().last)
    let pendingState = try #require(approvalRequest.paperPortfolioExecutionPendingState)

    #expect(await rest.placeOrderCallCount() == 2)
    #expect(Set(snapshot.openOrders.map(\.symbol)) == Set(["NVDA", "TSM"]))
    #expect(Set(pendingState.missingPriceSymbols) == Set(["KSS"]))
    #expect(approvalRequest.paperPortfolioExecutionLifecycleState?.status == .partiallySubmitted)
    #expect(approvalRequest.paperPortfolioExecutionLifecycleState?.orderAttemptCount == 2)
    #expect(approvalRequest.paperPortfolioExecutionLifecycleState?.acceptedOrderAttemptCount == 2)
    #expect(followThrough.body.contains("usable prices to size these symbols: KSS"))
    #expect(followThrough.body.contains("I submitted part of the current paper-portfolio establishment order set"))
    #expect(followThrough.body.contains("Accepted order attempts:") == true)
    #expect(followThrough.body.contains("No new owner approval is required"))
    #expect(followThrough.body.contains("waiting for the next governed app step") == false)
    #expect(followThrough.body.contains("instruction is on record") == false)
}

@Test("Missing prices create one coherent approved pending paper-execution state and request price recovery")
func pmConversationPaperPortfolioExecutionMissingPricesArmsPendingRecoveryState() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-conversation-paper-portfolio-price-recovery-pending")
    let now = Date(timeIntervalSince1970: 1_746_333_100)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let instructionStore = PMInstructionStore(instructionsDirectory: root.appendingPathComponent("instructions", isDirectory: true))
    let decisionStore = PMDecisionStore(decisionsDirectory: root.appendingPathComponent("decisions", isDirectory: true))
    let approvalStore = PMApprovalRequestStore(approvalRequestsDirectory: root.appendingPathComponent("approval_requests", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let watchlistPersistence = FileWatchlistPersistence(fileURL: root.appendingPathComponent("watchlist.json"))
    let ownerWatchlist = ["AMD", "MSFT", "META"]
    watchlistPersistence.saveWatchlistSymbols(ownerWatchlist)
    let store = Store()
    await store.setWatchlistSymbols(ownerWatchlist)
    let rest = RecordingPMConversationRESTClient()
    let marketDataStream = AlpacaMarketDataStream(environment: .paper, feed: .test)
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "Understood. I’ve routed the current paper-portfolio establishment request forward at the agreed target weights.",
            actionPlan: makePaperPortfolioEstablishmentModelActionPlan(
                summary: "Model interpreted the owner turn as explicit approval to create, approve, and route the governed paper-establishment step."
            ),
            resolution: PMConversationResolutionState(
                intentClass: .instruction,
                disposition: .workingUnderstandingOnly,
                workingUnderstandingSummary: "The current working paper portfolio remains the latest agreed long/short target allocation, and the owner instructed that it should now be implemented.",
                operatingTruthKind: .workingPortfolioDefinition,
                operatingTruthSummary: "The current proposed paper portfolio remains the active working target to implement.",
                operatingTruthBody: "Initial paper portfolio: Long NVDA 16%, TSM 11%, AVGO 11%, AMZN 11%, GOOG 11%, AAPL 10%, CRWD 10%, NFLX 10%, TSLA 10%; Short KSS -7%, NYCB -5%."
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Records approved pending paper execution while requesting app-owned price recovery.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await instructionStore.upsert(
        PMInstruction(
            instructionId: "instruction-working-paper-portfolio-price-recovery",
            pmId: "pm-1",
            title: "Working paper portfolio definition",
            body: "Initial paper portfolio: Long NVDA 16%, TSM 11%, AVGO 11%, AMZN 11%, GOOG 11%, AAPL 10%, CRWD 10%, NFLX 10%, TSLA 10%; Short KSS -7%, NYCB -5%.",
            category: "conversation_working_portfolio_definition",
            createdAt: now,
            updatedAt: now
        )
    )

    await rest.setAccount(
        Account(
            id: "acct-paper-establishment-price-recovery",
            status: "ACTIVE",
            cash: "100000",
            buyingPower: "200000",
            equity: "100000",
            multiplier: "2"
        )
    )
    await store.applyStartupSnapshot(
        account: Account(
            id: "acct-paper-establishment-price-recovery",
            status: "ACTIVE",
            cash: "100000",
            buyingPower: "200000",
            equity: "100000",
            multiplier: "2"
        ),
        positions: [],
        openOrders: []
    )

    let engine = Engine(
        configuration: Configuration(environment: .paper),
        store: store,
        marketDataStream: marketDataStream,
        watchlistPersistence: watchlistPersistence,
        pmProfileStore: profileStore,
        pmInstructionStore: instructionStore,
        pmDecisionStore: decisionStore,
        pmApprovalRequestStore: approvalStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider,
        keychainProvider: pmConversationAlpacaKeychainProvider(),
        restClientFactory: { _ in rest },
        pmPendingPaperExecutionRetryDebounceWindow: 0,
        pmPendingPaperExecutionRetrySleep: { _ in },
        workingPaperPortfolioPriceRepairEnabled: false
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Execute the trades required to implement the current proposed paper portfolio",
        source: .ui
    )
    let reply = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)

    let approvalRequest = try #require(try await engine.listPMApprovalRequests().last)
    let followThrough = try #require(
        try await engine.listPMCommunicationMessages()
            .filter {
                $0.sessionId == session.sessionId
                    && $0.senderRole == .pm
                    && $0.replyToMessageId == reply.messageId
            }
            .last
    )
    let pendingState = try #require(approvalRequest.paperPortfolioExecutionPendingState)
    let subscriptions = await marketDataStream.currentDesiredSubscriptions()
    let expectedSymbols = Set(["NVDA", "TSM", "AVGO", "AMZN", "GOOG", "AAPL", "CRWD", "NFLX", "TSLA", "KSS", "NYCB"])

    #expect(approvalRequest.status == .resolved)
    #expect(approvalRequest.ownerResponse == .approved)
    #expect(pendingState.status == .waitingForUsablePrices)
    #expect(Set(pendingState.missingPriceSymbols) == expectedSymbols)
    #expect(Set(subscriptions.quotes) == expectedSymbols)
    #expect(Set(subscriptions.trades) == expectedSymbols)
    #expect(Set(subscriptions.bars) == expectedSymbols)
    #expect(watchlistPersistence.loadWatchlistSymbols() == ownerWatchlist.sorted())
    #expect((await store.snapshot()).watchlistSymbols == ownerWatchlist.sorted())
    #expect(await rest.placeOrderCallCount() == 0)
    #expect(followThrough.body.contains("I recorded your explicit approval"))
    #expect(followThrough.body.contains("usable prices to size these symbols"))
    #expect(followThrough.body.contains("market-data subscriptions") == true)
    #expect(followThrough.body.contains("No new owner approval is required") == true)
    #expect(followThrough.body.contains("approval-ready PM ask") == false)
}

@Test("Paper establishment uses bounded Engine-owned daily-bar price repair when Store prices are missing")
func pmConversationPaperPortfolioExecutionRepairsSizingPricesFromDailyBars() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-conversation-paper-portfolio-price-repair-bars")
    let now = Date(timeIntervalSince1970: 1_746_333_140)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let instructionStore = PMInstructionStore(instructionsDirectory: root.appendingPathComponent("instructions", isDirectory: true))
    let decisionStore = PMDecisionStore(decisionsDirectory: root.appendingPathComponent("decisions", isDirectory: true))
    let approvalStore = PMApprovalRequestStore(approvalRequestsDirectory: root.appendingPathComponent("approval_requests", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let store = Store()
    let rest = RecordingPMConversationRESTClient()
    let repairSymbols = ["NVDA", "TSM", "AVGO", "AMZN", "GOOG", "AAPL", "CRWD", "NFLX", "TSLA", "KSS", "NYCB"]
    let barsProvider = RecordingPMConversationBarsProvider(
        bars: repairSymbols.map { symbol in
            Bar(
                symbol: symbol,
                timeframe: .oneDay,
                timestamp: now.addingTimeInterval(-3_600),
                open: 99,
                high: 101,
                low: 98,
                close: 100,
                volume: 1_000_000
            )
        }
    )
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "Understood. I’m routing the current paper-portfolio establishment request now.",
            actionPlan: makePaperPortfolioEstablishmentModelActionPlan(
                summary: "Model selected explicit approval and routing for the current paper portfolio."
            ),
            resolution: PMConversationResolutionState(
                intentClass: .instruction,
                disposition: .workingUnderstandingOnly,
                workingUnderstandingSummary: "The owner instructed the PM to establish the current working paper portfolio.",
                operatingTruthKind: .workingPortfolioDefinition,
                operatingTruthSummary: "The current proposed paper portfolio remains the active working target.",
                operatingTruthBody: "Initial paper portfolio: Long NVDA 16%, TSM 11%, AVGO 11%, AMZN 11%, GOOG 11%, AAPL 10%, CRWD 10%, NFLX 10%, TSLA 10%; Short KSS -7%, NYCB -5%."
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Uses bounded Engine-owned price repair before declaring paper sizing blocked.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await instructionStore.upsert(
        PMInstruction(
            instructionId: "instruction-working-paper-portfolio-price-repair-bars",
            pmId: "pm-1",
            title: "Working paper portfolio definition",
            body: "Initial paper portfolio: Long NVDA 16%, TSM 11%, AVGO 11%, AMZN 11%, GOOG 11%, AAPL 10%, CRWD 10%, NFLX 10%, TSLA 10%; Short KSS -7%, NYCB -5%.",
            category: "conversation_working_portfolio_definition",
            createdAt: now,
            updatedAt: now
        )
    )
    let account = Account(
        id: "acct-paper-establishment-price-repair-bars",
        status: "ACTIVE",
        cash: "100000",
        buyingPower: "200000",
        equity: "100000",
        multiplier: "2"
    )
    await rest.setAccount(account)
    await store.applyStartupSnapshot(account: account, positions: [], openOrders: [])

    let engine = Engine(
        configuration: Configuration(environment: .paper),
        store: store,
        pmProfileStore: profileStore,
        pmInstructionStore: instructionStore,
        pmDecisionStore: decisionStore,
        pmApprovalRequestStore: approvalStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider,
        keychainProvider: pmConversationAlpacaKeychainProvider(),
        restClientFactory: { _ in rest },
        barsProviderFactory: { _ in barsProvider }
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Please try again to make the trades necessary to establish the initial paper portfolio.",
        source: .ui
    )
    let reply = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)
    let followThrough = try #require(
        try await engine.listPMCommunicationMessages()
            .filter {
                $0.sessionId == session.sessionId
                    && $0.senderRole == .pm
                    && $0.replyToMessageId == reply.messageId
            }
            .last
    )
    let approvalRequest = try #require(try await engine.listPMApprovalRequests().last)
    let snapshot = await store.snapshot()

    #expect(await barsProvider.fetchCallCount() >= 1)
    #expect(Set(await barsProvider.requestedSymbols()) == Set(repairSymbols))
    #expect(await rest.placeOrderCallCount() == 11)
    #expect(snapshot.openOrders.count == 11)
    #expect(approvalRequest.paperPortfolioExecutionPendingState == nil)
    #expect(approvalRequest.paperPortfolioExecutionLifecycleState?.status == .submitted)
    #expect(followThrough.body.contains("I submitted the current paper-portfolio establishment orders through the app."))
    #expect(followThrough.body.contains("usable prices to size these symbols") == false)
}

@Test("PM watchlist action adds symbols through app-owned watchlist and Portfolio Watch selection")
func pmConversationWatchlistActionAddsSymbolsAndReportsAppliedTruth() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-conversation-watchlist-add-action")
    let now = Date(timeIntervalSince1970: 1_746_333_160)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let watchlistPersistence = FileWatchlistPersistence(fileURL: root.appendingPathComponent("watchlist.json"))
    let chartWallStore = PortfolioWatchChartWallConfigurationStore(
        fileURL: root.appendingPathComponent("portfolio_watch_chart_wall.json"),
        now: { now }
    )
    let store = Store()
    watchlistPersistence.saveWatchlistSymbols(["NVDA"])
    await store.setWatchlistSymbols(["NVDA"])
    _ = try await chartWallStore.upsert(
        PortfolioWatchChartWallConfiguration(
            selectedSymbols: ["NVDA"],
            updatedBy: "owner",
            updateSource: .ui,
            createdAt: now,
            updatedAt: now
        )
    )
    let symbolsToAdd = ["TSM", "AVGO", "AMZN", "GOOG", "AAPL", "CRWD", "NFLX", "TSLA", "KSS", "NYCB"]
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "I’ll apply that watchlist update through the app now.",
            actionPlan: PMConversationActionPlan(
                summary: "Model selected app-owned watchlist update for explicit Portfolio Watch request.",
                actions: [
                    PMConversationActionIntent(
                        actionType: .updateWatchlistSymbols,
                        summary: "Add the current paper-portfolio symbols to Portfolio Watch while preserving NVDA.",
                        watchlistOperation: .add,
                        watchlistSymbols: symbolsToAdd,
                        sourceMessageIds: []
                    )
                ]
            ),
            resolution: PMConversationResolutionState(
                intentClass: .instruction,
                disposition: .conversationOnly
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Applies explicit watchlist changes through bounded app-owned actions.",
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        configuration: Configuration(environment: .paper),
        store: store,
        watchlistPersistence: watchlistPersistence,
        portfolioWatchChartWallConfigurationStore: chartWallStore,
        pmProfileStore: profileStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )
    let chartWallUpdateEvent = Task {
        await waitForPMWorkflowStoreEvent(
            named: "portfolio_watch_chart_wall_updated",
            in: store.events
        )
    }

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Can you add the symbols to the Portfolio Watch list? NVDA is already there.",
        source: .ui
    )
    let reply = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)
    let followThrough = try #require(
        try await engine.listPMCommunicationMessages()
            .filter {
                $0.sessionId == session.sessionId
                    && $0.senderRole == .pm
                    && $0.replyToMessageId == reply.messageId
            }
            .last
    )
    let snapshot = await store.snapshot()
    let chartWall = try await engine.getPortfolioWatchChartWallConfiguration()
    let expected = Set(symbolsToAdd + ["NVDA"])

    #expect(reply.conversationActionPlan?.actions.map(\.actionType) == [.updateWatchlistSymbols])
    #expect(Set(snapshot.watchlistSymbols) == expected)
    #expect(Set(watchlistPersistence.loadWatchlistSymbols()) == expected)
    #expect(Set(chartWall.selectedSymbols) == expected)
    #expect(await chartWallUpdateEvent.value == true)
    #expect(followThrough.body.contains("I added"))
    #expect(followThrough.body.contains("Portfolio Watch chart-wall selection now includes the requested valid symbols."))
}

@Test("Market-open follow-up does not create a duplicate approval ask after approval is already recorded")
func pmConversationMarketOpenFollowUpDoesNotCreateDuplicateApprovalAsk() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-conversation-paper-portfolio-market-open-no-duplicate-approval")
    let now = Date(timeIntervalSince1970: 1_746_333_180)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let instructionStore = PMInstructionStore(instructionsDirectory: root.appendingPathComponent("instructions", isDirectory: true))
    let decisionStore = PMDecisionStore(decisionsDirectory: root.appendingPathComponent("decisions", isDirectory: true))
    let approvalStore = PMApprovalRequestStore(approvalRequestsDirectory: root.appendingPathComponent("approval_requests", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let store = Store()
    let rest = RecordingPMConversationRESTClient()
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutputs: [
            PMConversationOpenAISynthesisOutput(
                replyBody: "Understood. I’ve routed the current paper-portfolio establishment request forward at the agreed target weights.",
                actionPlan: makePaperPortfolioEstablishmentModelActionPlan(
                    summary: "Model interpreted the owner turn as explicit approval to create, approve, and route the governed paper-establishment step."
                ),
                resolution: PMConversationResolutionState(
                    intentClass: .instruction,
                    disposition: .workingUnderstandingOnly,
                    workingUnderstandingSummary: "The current working paper portfolio remains the latest agreed long/short target allocation, and the owner instructed that it should now be implemented.",
                    operatingTruthKind: .workingPortfolioDefinition,
                    operatingTruthSummary: "The current proposed paper portfolio remains the active working target to implement.",
                    operatingTruthBody: "Initial paper portfolio: Long NVDA 16%, TSM 11%, AVGO 11%, AMZN 11%, GOOG 11%, AAPL 10%, CRWD 10%, NFLX 10%, TSLA 10%; Short KSS -7%, NYCB -5%."
                )
            ),
            PMConversationOpenAISynthesisOutput(
                replyBody: "The approved paper-portfolio establishment is still blocked on usable prices, so the next step depends on price availability rather than another owner approval ask.",
                resolution: PMConversationResolutionState(
                    intentClass: .followUpQuestion,
                    disposition: .conversationOnly
                )
            )
        ],
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Keeps one coherent approval state when paper execution is pending on prices.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await instructionStore.upsert(
        PMInstruction(
            instructionId: "instruction-working-paper-portfolio-market-open",
            pmId: "pm-1",
            title: "Working paper portfolio definition",
            body: "Initial paper portfolio: Long NVDA 16%, TSM 11%, AVGO 11%, AMZN 11%, GOOG 11%, AAPL 10%, CRWD 10%, NFLX 10%, TSLA 10%; Short KSS -7%, NYCB -5%.",
            category: "conversation_working_portfolio_definition",
            createdAt: now,
            updatedAt: now
        )
    )

    await rest.setAccount(
        Account(
            id: "acct-paper-establishment-market-open",
            status: "ACTIVE",
            cash: "100000",
            buyingPower: "200000",
            equity: "100000",
            multiplier: "2"
        )
    )
    await store.applyStartupSnapshot(
        account: Account(
            id: "acct-paper-establishment-market-open",
            status: "ACTIVE",
            cash: "100000",
            buyingPower: "200000",
            equity: "100000",
            multiplier: "2"
        ),
        positions: [],
        openOrders: []
    )

    let engine = Engine(
        configuration: Configuration(environment: .paper),
        store: store,
        pmProfileStore: profileStore,
        pmInstructionStore: instructionStore,
        pmDecisionStore: decisionStore,
        pmApprovalRequestStore: approvalStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider,
        keychainProvider: pmConversationAlpacaKeychainProvider(),
        restClientFactory: { _ in rest },
        pmPendingPaperExecutionRetryDebounceWindow: 0,
        pmPendingPaperExecutionRetrySleep: { _ in },
        workingPaperPortfolioPriceRepairEnabled: false
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let executeAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: PMCommunicationSenderRole.owner,
        senderId: "owner",
        body: "Execute the trades required to implement the current proposed paper portfolio",
        source: AuditEventSource.ui
    )
    _ = try await engine.generatePMConversationReply(
        to: executeAsk.messageId,
        source: AuditEventSource.ui
    )

    let followUpAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: PMCommunicationSenderRole.owner,
        senderId: "owner",
        body: "What happens when the markets open. Will the app somehow then provide you pricing information for the listed companies in the proposed paper portfolio?",
        source: AuditEventSource.ui
    )
    let followUpReply = try await engine.generatePMConversationReply(
        to: followUpAsk.messageId,
        source: AuditEventSource.ui
    )

    let approvalRequests = try await engine.listPMApprovalRequests()
    let sessionMessages = try await engine.listPMCommunicationMessages()
        .filter { $0.sessionId == session.sessionId }
    let followUpReplyMessageID = followUpReply.messageId
    let followUpArtifacts = sessionMessages.filter { message in
        message.senderRole == PMCommunicationSenderRole.pm
            && message.replyToMessageId == followUpReplyMessageID
    }

    #expect(approvalRequests.count == 1)
    #expect(approvalRequests.first?.status == .resolved)
    #expect(approvalRequests.first?.ownerResponse == .approved)
    #expect(approvalRequests.first?.paperPortfolioExecutionPendingState?.status == .waitingForUsablePrices)
    #expect(followUpReply.runtimeProvenance?.conversationTrace?.actionPlanSource == .modelResolution)
    #expect(
        followUpReply.conversationActionPlan?.actions.contains(where: {
            $0.actionType == PMConversationActionType.createPMApprovalRequest
        }) != true
    )
    #expect(followUpArtifacts.isEmpty)
}

@Test("Approved pending paper-portfolio execution retries automatically when usable prices arrive")
func pmConversationApprovedPendingPaperPortfolioExecutionRetriesOnPriceArrival() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-conversation-paper-portfolio-price-recovery-retry")
    let now = Date(timeIntervalSince1970: 1_746_333_260)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let instructionStore = PMInstructionStore(instructionsDirectory: root.appendingPathComponent("instructions", isDirectory: true))
    let decisionStore = PMDecisionStore(decisionsDirectory: root.appendingPathComponent("decisions", isDirectory: true))
    let approvalStore = PMApprovalRequestStore(approvalRequestsDirectory: root.appendingPathComponent("approval_requests", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let store = Store()
    let rest = RecordingPMConversationRESTClient()
    let marketDataStream = AlpacaMarketDataStream(environment: .paper, feed: .test)
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "Understood. I’ve routed the current paper-portfolio establishment request forward at the agreed target weights.",
            actionPlan: makePaperPortfolioEstablishmentModelActionPlan(
                summary: "Model interpreted the owner turn as explicit approval to create, approve, and route the governed paper-establishment step."
            ),
            resolution: PMConversationResolutionState(
                intentClass: .instruction,
                disposition: .workingUnderstandingOnly,
                workingUnderstandingSummary: "The current working paper portfolio remains the latest agreed long/short target allocation, and the owner instructed that it should now be implemented.",
                operatingTruthKind: .workingPortfolioDefinition,
                operatingTruthSummary: "The current proposed paper portfolio remains the active working target to implement.",
                operatingTruthBody: "Initial paper portfolio: Long NVDA 16%, TSM 11%, AVGO 11%, AMZN 11%, GOOG 11%, AAPL 10%, CRWD 10%, NFLX 10%, TSLA 10%; Short KSS -7%, NYCB -5%."
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Retries approved pending paper execution automatically when usable prices arrive.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await instructionStore.upsert(
        PMInstruction(
            instructionId: "instruction-working-paper-portfolio-price-retry",
            pmId: "pm-1",
            title: "Working paper portfolio definition",
            body: "Initial paper portfolio: Long NVDA 16%, TSM 11%, AVGO 11%, AMZN 11%, GOOG 11%, AAPL 10%, CRWD 10%, NFLX 10%, TSLA 10%; Short KSS -7%, NYCB -5%.",
            category: "conversation_working_portfolio_definition",
            createdAt: now,
            updatedAt: now
        )
    )

    await rest.setAccount(
        Account(
            id: "acct-paper-establishment-price-retry",
            status: "ACTIVE",
            cash: "100000",
            buyingPower: "200000",
            equity: "100000",
            multiplier: "2"
        )
    )
    await store.applyStartupSnapshot(
        account: Account(
            id: "acct-paper-establishment-price-retry",
            status: "ACTIVE",
            cash: "100000",
            buyingPower: "200000",
            equity: "100000",
            multiplier: "2"
        ),
        positions: [],
        openOrders: []
    )

    let engine = Engine(
        configuration: Configuration(environment: .paper),
        store: store,
        marketDataStream: marketDataStream,
        pmProfileStore: profileStore,
        pmInstructionStore: instructionStore,
        pmDecisionStore: decisionStore,
        pmApprovalRequestStore: approvalStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider,
        keychainProvider: pmConversationAlpacaKeychainProvider(),
        restClientFactory: { _ in rest },
        pmPendingPaperExecutionRetryDebounceWindow: 0,
        pmPendingPaperExecutionRetrySleep: { _ in },
        workingPaperPortfolioPriceRepairEnabled: false
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Execute the trades required to implement the current proposed paper portfolio",
        source: .ui
    )
    _ = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)

    let approvalRequest = try #require(try await engine.listPMApprovalRequests().last)
    #expect(await rest.placeOrderCallCount() == 0)
    #expect(approvalRequest.paperPortfolioExecutionPendingState?.status == .waitingForUsablePrices)

    await publishPaperPortfolioQuotes(
        store: store,
        pricesBySymbol: [
            "NVDA": 100,
            "TSM": 100,
            "AVGO": 100,
            "AMZN": 100,
            "GOOG": 100,
            "AAPL": 100,
            "CRWD": 100,
            "NFLX": 100,
            "TSLA": 100,
            "KSS": 100,
            "NYCB": 100
        ]
    )
    await engine.handleMarketDataEvent(
        .quote(
            MarketDataQuoteEvent(
                symbol: "NVDA",
                bidPrice: 100,
                askPrice: 100,
                bidSize: 10,
                askSize: 10,
                timestamp: "2026-04-28T13:30:00Z"
            )
        )
    )
    for _ in 0..<100 {
        let refreshedRequest = try await engine.getPMApprovalRequest(id: approvalRequest.approvalRequestId)
        let refreshedSubscriptions = await marketDataStream.currentDesiredSubscriptions()
        let refreshedSnapshot = await store.snapshot()
        if await rest.placeOrderCallCount() == 11,
           refreshedRequest.paperPortfolioExecutionPendingState == nil,
           refreshedSnapshot.openOrders.count == 11,
           refreshedSubscriptions.quotes.isEmpty,
           refreshedSubscriptions.trades.isEmpty,
           refreshedSubscriptions.bars.isEmpty {
            break
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }

    let updatedRequest = try await engine.getPMApprovalRequest(id: approvalRequest.approvalRequestId)
    let subscriptions = await marketDataStream.currentDesiredSubscriptions()
    let snapshot = await store.snapshot()
    let placedOrders = await rest.placedOrders()
    var retryFollowThrough: PMCommunicationMessage?
    for _ in 0..<100 {
        retryFollowThrough = try await engine.listPMCommunicationMessages()
            .filter {
                $0.sessionId == session.sessionId
                    && $0.senderRole == .pm
                    && $0.body.contains("Approved paper-portfolio execution retry update")
            }
            .last
        if retryFollowThrough != nil {
            break
        }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }

    #expect(await rest.placeOrderCallCount() == 11)
    #expect(Set(placedOrders.map(\.symbol)) == Set(["NVDA", "TSM", "AVGO", "AMZN", "GOOG", "AAPL", "CRWD", "NFLX", "TSLA", "KSS", "NYCB"]))
    #expect(updatedRequest.paperPortfolioExecutionPendingState == nil)
    #expect(snapshot.openOrders.count == 11)
    #expect(subscriptions.quotes.isEmpty)
    #expect(subscriptions.trades.isEmpty)
    #expect(subscriptions.bars.isEmpty)
    #expect(retryFollowThrough?.body.contains("I submitted the current paper-portfolio establishment orders through the app.") == true)
    #expect(retryFollowThrough?.body.contains("Accepted order attempts:") == true)
}

@Test("Direct PM re-instruction reuses approved pending paper execution and submits when prices are usable")
func pmConversationDirectReinstructionRetriesApprovedPendingPaperExecutionWhenPricesAreUsable() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-conversation-paper-portfolio-direct-retry-approved-pending")
    let now = Date(timeIntervalSince1970: 1_746_333_320)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let instructionStore = PMInstructionStore(instructionsDirectory: root.appendingPathComponent("instructions", isDirectory: true))
    let decisionStore = PMDecisionStore(decisionsDirectory: root.appendingPathComponent("decisions", isDirectory: true))
    let approvalStore = PMApprovalRequestStore(approvalRequestsDirectory: root.appendingPathComponent("approval_requests", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let store = Store()
    let rest = RecordingPMConversationRESTClient()
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutputs: [
            PMConversationOpenAISynthesisOutput(
                replyBody: "Understood. I’ve routed the current paper-portfolio establishment request forward at the agreed target weights.",
                actionPlan: makePaperPortfolioEstablishmentModelActionPlan(
                    summary: "Model interpreted the owner turn as explicit approval to create, approve, and route the governed paper-establishment step."
                ),
                resolution: PMConversationResolutionState(
                    intentClass: .instruction,
                    disposition: .workingUnderstandingOnly,
                    workingUnderstandingSummary: "The owner approved implementation of the working paper portfolio.",
                    operatingTruthKind: .workingPortfolioDefinition,
                    operatingTruthSummary: "The current proposed paper portfolio remains the active working target to implement.",
                    operatingTruthBody: "Initial paper portfolio: Long NVDA 16%, TSM 11%, AVGO 11%, AMZN 11%, GOOG 11%, AAPL 10%, CRWD 10%, NFLX 10%, TSLA 10%; Short KSS -7%, NYCB -5%."
                )
            ),
            PMConversationOpenAISynthesisOutput(
                replyBody: "I am treating this as a direct instruction and routing the governed execution step now.",
                actionPlan: makePaperPortfolioEstablishmentModelActionPlan(
                    summary: "Model interpreted the owner turn as a request to retry the existing approved pending paper-establishment execution.",
                    includeDecisionAndApprovalCreation: false,
                    includeApproval: false,
                    includeRoute: true
                ),
                resolution: PMConversationResolutionState(
                    intentClass: .instruction,
                    disposition: .conversationOnly
                )
            )
        ],
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Retries already-approved paper portfolio execution from direct owner re-instruction.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await instructionStore.upsert(
        PMInstruction(
            instructionId: "instruction-working-paper-portfolio-direct-retry",
            pmId: "pm-1",
            title: "Working paper portfolio definition",
            body: "Initial paper portfolio: Long NVDA 16%, TSM 11%, AVGO 11%, AMZN 11%, GOOG 11%, AAPL 10%, CRWD 10%, NFLX 10%, TSLA 10%; Short KSS -7%, NYCB -5%.",
            category: "conversation_working_portfolio_definition",
            createdAt: now,
            updatedAt: now
        )
    )

    await rest.setAccount(
        Account(
            id: "acct-paper-establishment-direct-retry",
            status: "ACTIVE",
            cash: "100000",
            buyingPower: "200000",
            equity: "100000",
            multiplier: "2"
        )
    )
    await store.applyStartupSnapshot(
        account: Account(
            id: "acct-paper-establishment-direct-retry",
            status: "ACTIVE",
            cash: "100000",
            buyingPower: "200000",
            equity: "100000",
            multiplier: "2"
        ),
        positions: [],
        openOrders: []
    )

    let engine = Engine(
        configuration: Configuration(environment: .paper),
        store: store,
        pmProfileStore: profileStore,
        pmInstructionStore: instructionStore,
        pmDecisionStore: decisionStore,
        pmApprovalRequestStore: approvalStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider,
        keychainProvider: pmConversationAlpacaKeychainProvider(),
        restClientFactory: { _ in rest },
        pmPendingPaperExecutionRetryDebounceWindow: 0,
        pmPendingPaperExecutionRetrySleep: { _ in },
        workingPaperPortfolioPriceRepairEnabled: false
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let executeAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Execute the trades required to implement the current proposed paper portfolio",
        source: .ui
    )
    _ = try await engine.generatePMConversationReply(to: executeAsk.messageId, source: .ui)

    let pendingRequest = try #require(try await engine.listPMApprovalRequests().last)
    #expect(pendingRequest.paperPortfolioExecutionPendingState?.status == .waitingForUsablePrices)
    #expect(await rest.placeOrderCallCount() == 0)

    await publishPaperPortfolioQuotes(
        store: store,
        pricesBySymbol: [
            "NVDA": 100,
            "TSM": 100,
            "AVGO": 100,
            "AMZN": 100,
            "GOOG": 100,
            "AAPL": 100,
            "CRWD": 100,
            "NFLX": 100,
            "TSLA": 100,
            "KSS": 100,
            "NYCB": 100
        ]
    )

    let directAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "This is a direct instruction to place the trades to establish the proposed paper portfolio. I already approved this in the Your Decisions section yesterday.",
        source: .ui
    )
    let directReply = try await engine.generatePMConversationReply(to: directAsk.messageId, source: .ui)
    let followThrough = try #require(
        try await engine.listPMCommunicationMessages()
            .filter {
                $0.sessionId == session.sessionId
                    && $0.senderRole == .pm
                    && $0.replyToMessageId == directReply.messageId
            }
            .last
    )
    let approvalRequests = try await engine.listPMApprovalRequests()
    let updatedRequest = try await engine.getPMApprovalRequest(id: pendingRequest.approvalRequestId)
    let snapshot = await store.snapshot()

    #expect(directReply.runtimeProvenance?.conversationTrace?.actionPlanSource == .modelActionPlan)
    #expect(directReply.conversationActionPlan?.actions.map(\.actionType) == [.routeGovernedExecutionNextStep])
    #expect(approvalRequests.count == 1)
    #expect(updatedRequest.paperPortfolioExecutionPendingState == nil)
    #expect(await rest.placeOrderCallCount() == 11)
    #expect(snapshot.openOrders.count == 11)
    #expect(followThrough.body.contains("I submitted the current paper-portfolio establishment orders through the app."))
    #expect(followThrough.body.contains("Accepted order attempts:"))
    #expect(followThrough.body.contains("approval-ready PM ask") == false)
    #expect(followThrough.body.contains("routing the governed execution step now") == false)
}

@Test("Model route action resolves latest approved paper-establishment ask when duplicate historical approvals exist")
func pmConversationRouteActionResolvesLatestApprovedPaperEstablishmentAsk() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-conversation-paper-portfolio-route-duplicate-approved")
    let now = Date(timeIntervalSince1970: 1_746_333_420)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let instructionStore = PMInstructionStore(instructionsDirectory: root.appendingPathComponent("instructions", isDirectory: true))
    let decisionStore = PMDecisionStore(decisionsDirectory: root.appendingPathComponent("decisions", isDirectory: true))
    let approvalStore = PMApprovalRequestStore(approvalRequestsDirectory: root.appendingPathComponent("approval_requests", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let store = Store()
    let rest = RecordingPMConversationRESTClient()
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "I’m routing the approved paper-establishment step now.",
            actionPlan: PMConversationActionPlan(
                summary: "Model selected governed routing for the already-approved paper portfolio.",
                actions: [
                    PMConversationActionIntent(
                        actionType: .routeGovernedExecutionNextStep,
                        summary: "Route the approved paper-establishment step.",
                        title: "Route approved paper portfolio",
                        body: "Route the already-approved initial paper portfolio through the governed paper-safe order path.",
                        sourceMessageIds: ["latest_owner_message"]
                    )
                ]
            ),
            resolution: PMConversationResolutionState(
                intentClass: .instruction,
                disposition: .conversationOnly
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Routes the latest app-owned approved paper establishment request.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await instructionStore.upsert(
        PMInstruction(
            instructionId: "instruction-working-paper-portfolio-duplicate-approved",
            pmId: "pm-1",
            title: "Working paper portfolio definition",
            body: "Initial paper portfolio: Long NVDA 16%, TSM 11%, AVGO 11%, AMZN 11%, GOOG 11%, AAPL 10%, CRWD 10%, NFLX 10%, TSLA 10%; Short KSS -7%, NYCB -5%.",
            category: "conversation_working_portfolio_definition",
            createdAt: now,
            updatedAt: now
        )
    )

    let olderApproval = PMApprovalRequest(
        approvalRequestId: "approval-old-paper-establishment",
        pmId: "pm-1",
        subject: "Review PM recommendation: establish the initial paper portfolio",
        rationale: "Older approved paper portfolio establishment ask.",
        requestType: .portfolioAction,
        status: .resolved,
        ownerResponse: .approved,
        ownerRespondedAt: now.addingTimeInterval(-120),
        createdAt: now.addingTimeInterval(-180),
        updatedAt: now.addingTimeInterval(-120)
    )
    let latestApproval = PMApprovalRequest(
        approvalRequestId: "approval-latest-paper-establishment",
        pmId: "pm-1",
        subject: "Review PM recommendation: execute the current working paper portfolio",
        rationale: "Latest approved current working paper portfolio establishment ask.",
        requestType: .portfolioAction,
        status: .resolved,
        ownerResponse: .approved,
        ownerRespondedAt: now.addingTimeInterval(-60),
        createdAt: now.addingTimeInterval(-90),
        updatedAt: now.addingTimeInterval(-60)
    )
    _ = try await approvalStore.upsert(olderApproval)
    _ = try await approvalStore.upsert(latestApproval)

    let account = Account(
        id: "acct-paper-establishment-latest-approved",
        status: "ACTIVE",
        cash: "100000",
        buyingPower: "200000",
        equity: "100000",
        multiplier: "2"
    )
    await rest.setAccount(account)
    await store.applyStartupSnapshot(account: account, positions: [], openOrders: [])
    await publishPaperPortfolioQuotes(
        store: store,
        pricesBySymbol: [
            "NVDA": 100,
            "TSM": 100,
            "AVGO": 100,
            "AMZN": 100,
            "GOOG": 100,
            "AAPL": 100,
            "CRWD": 100,
            "NFLX": 100,
            "TSLA": 100,
            "KSS": 100,
            "NYCB": 100
        ]
    )

    let engine = Engine(
        configuration: Configuration(environment: .paper),
        store: store,
        pmProfileStore: profileStore,
        pmInstructionStore: instructionStore,
        pmDecisionStore: decisionStore,
        pmApprovalRequestStore: approvalStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider,
        keychainProvider: pmConversationAlpacaKeychainProvider(),
        restClientFactory: { _ in rest }
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Please make the trades necessary to establish the initial paper portfolio today before the market closes.",
        source: .ui
    )
    let reply = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)
    let followThrough = try #require(
        try await engine.listPMCommunicationMessages()
            .filter {
                $0.sessionId == session.sessionId
                    && $0.senderRole == .pm
                    && $0.replyToMessageId == reply.messageId
            }
            .last
    )
    let snapshot = await store.snapshot()

    #expect(reply.conversationActionPlan?.actions.first?.targetId == latestApproval.approvalRequestId)
    #expect(await rest.placeOrderCallCount() == 11)
    #expect(snapshot.openOrders.count == 11)
    #expect(followThrough.body.contains("I submitted the current paper-portfolio establishment orders through the app."))
    #expect(followThrough.body.contains("Accepted order attempts:"))
    #expect(followThrough.body.contains("could not route") == false)
}

@Test("Owner approval response hands off paper establishment to Engine order submission when preconditions pass")
func pmApprovalResponseHandsOffPaperEstablishmentToOrderSubmission() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-approval-response-paper-establishment-handoff")
    let now = Date(timeIntervalSince1970: 1_746_500_240)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let instructionStore = PMInstructionStore(instructionsDirectory: root.appendingPathComponent("instructions", isDirectory: true))
    let approvalStore = PMApprovalRequestStore(approvalRequestsDirectory: root.appendingPathComponent("approval_requests", isDirectory: true))
    let store = Store()
    let rest = RecordingPMConversationRESTClient()

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Routes owner-approved paper-establishment requests.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await instructionStore.upsert(
        PMInstruction(
            instructionId: "instruction-working-paper-portfolio-approval-handoff",
            pmId: "pm-1",
            title: "Working paper portfolio definition",
            body: "Initial paper portfolio: Long NVDA 16%, TSM 11%, AVGO 11%, AMZN 11%, GOOG 11%, AAPL 10%, CRWD 10%, NFLX 10%, TSLA 10%; Short KSS -7%, NYCB -5%.",
            category: "conversation_working_portfolio_definition",
            createdAt: now,
            updatedAt: now
        )
    )
    let account = Account(
        id: "acct-approval-handoff",
        status: "ACTIVE",
        cash: "100000",
        buyingPower: "200000",
        equity: "100000",
        multiplier: "2"
    )
    await rest.setAccount(account)
    await store.applyStartupSnapshot(account: account, positions: [], openOrders: [])
    await publishPaperPortfolioQuotes(
        store: store,
        pricesBySymbol: [
            "NVDA": 100,
            "TSM": 100,
            "AVGO": 100,
            "AMZN": 100,
            "GOOG": 100,
            "AAPL": 100,
            "CRWD": 100,
            "NFLX": 100,
            "TSLA": 100,
            "KSS": 100,
            "NYCB": 100
        ]
    )

    let engine = Engine(
        configuration: Configuration(environment: .paper),
        store: store,
        pmProfileStore: profileStore,
        pmInstructionStore: instructionStore,
        pmApprovalRequestStore: approvalStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        keychainProvider: pmConversationAlpacaKeychainProvider(),
        restClientFactory: { _ in rest },
        workingPaperPortfolioPriceRepairEnabled: false
    )

    _ = try await engine.upsertPMApprovalRequest(
        PMApprovalRequest(
            approvalRequestId: "approval-paper-handoff-pass",
            pmId: "pm-1",
            subject: "Review PM recommendation: execute the current working paper portfolio",
            rationale: "The current working paper portfolio is approved for governed paper-establishment.",
            requestedActionSummary: "Approve executing the current working paper portfolio through the governed paper-establishment path now.",
            requestType: .portfolioAction,
            status: .pending,
            createdAt: now,
            updatedAt: now
        ),
        source: .system
    )

    let approved = try await engine.respondToPMApprovalRequest(
        requestId: "approval-paper-handoff-pass",
        response: .approved,
        source: .ui
    )
    let snapshot = await store.snapshot()
    let placedOrders = await rest.placedOrders()
    let paperStatus = await engine.agentControlStatusJSON()
        .objectValue?["paperEstablishmentExecution"]?
        .objectValue

    #expect(approved.status == .resolved)
    #expect(approved.ownerResponse == .approved)
    #expect(approved.paperPortfolioExecutionPendingState == nil)
    #expect(approved.paperPortfolioExecutionLifecycleState?.status == .submitted)
    #expect(approved.paperPortfolioExecutionLifecycleState?.orderAttemptCount == 11)
    #expect(approved.lastExecutionRoutingAssessment?.status == .routedSuccessfully)
    #expect(approved.lastExecutionRoutingAssessment?.action == .submitWorkingPortfolioEstablishmentOrders)
    #expect(await rest.placeOrderCallCount() == 11)
    #expect(Set(placedOrders.map(\.symbol)) == Set(["NVDA", "TSM", "AVGO", "AMZN", "GOOG", "AAPL", "CRWD", "NFLX", "TSLA", "KSS", "NYCB"]))
    #expect(snapshot.openOrders.count == 11)
    #expect(paperStatus?["state"]?.stringValue == "submitted")
    #expect(paperStatus?["orderAttemptCount"]?.intValue == 11)
}

@Test("Paper establishment route records missing Alpaca trading credentials before order submission")
func pmApprovalResponseRecordsPaperTradingCredentialBlockerWhenKeysAreMissing() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-approval-response-paper-establishment-missing-keys")
    let now = Date(timeIntervalSince1970: 1_746_500_260)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let instructionStore = PMInstructionStore(instructionsDirectory: root.appendingPathComponent("instructions", isDirectory: true))
    let approvalStore = PMApprovalRequestStore(approvalRequestsDirectory: root.appendingPathComponent("approval_requests", isDirectory: true))
    let store = Store()
    let rest = RecordingPMConversationRESTClient()

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Surfaces paper trading credential blockers before order submission.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await instructionStore.upsert(
        PMInstruction(
            instructionId: "instruction-working-paper-portfolio-missing-keys",
            pmId: "pm-1",
            title: "Working paper portfolio definition",
            body: "Initial paper portfolio: Long NVDA 16%, TSM 11%, AVGO 11%; Short KSS -7%.",
            category: "conversation_working_portfolio_definition",
            createdAt: now,
            updatedAt: now
        )
    )
    let account = Account(
        id: "acct-approval-handoff-missing-keys",
        status: "ACTIVE",
        cash: "100000",
        buyingPower: "200000",
        equity: "100000",
        multiplier: "2"
    )
    await rest.setAccount(account)
    await store.applyStartupSnapshot(account: account, positions: [], openOrders: [])
    await publishPaperPortfolioQuotes(
        store: store,
        pricesBySymbol: ["NVDA": 100, "TSM": 100, "AVGO": 100, "KSS": 100]
    )

    let engine = Engine(
        configuration: Configuration(environment: .paper),
        store: store,
        pmProfileStore: profileStore,
        pmInstructionStore: instructionStore,
        pmApprovalRequestStore: approvalStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        keychainProvider: pmConversationAlpacaKeychainProvider(paperReady: false),
        restClientFactory: { _ in rest },
        workingPaperPortfolioPriceRepairEnabled: false
    )

    _ = try await engine.upsertPMApprovalRequest(
        PMApprovalRequest(
            approvalRequestId: "approval-paper-handoff-missing-keys",
            pmId: "pm-1",
            subject: "Review PM recommendation: execute the current working paper portfolio",
            rationale: "The current working paper portfolio is approved for governed paper-establishment.",
            requestedActionSummary: "Approve executing the current working paper portfolio through the governed paper-establishment path now.",
            requestType: .portfolioAction,
            status: .pending,
            createdAt: now,
            updatedAt: now
        ),
        source: .system
    )

    let approved = try await engine.respondToPMApprovalRequest(
        requestId: "approval-paper-handoff-missing-keys",
        response: .approved,
        source: .ui
    )
    let paperStatus = await engine.agentControlStatusJSON()
        .objectValue?["paperEstablishmentExecution"]?
        .objectValue
    let credentialsStatus = await engine.agentControlStatusJSON()
        .objectValue?["alpacaTradingCredentials"]?
        .objectValue

    #expect(approved.status == .resolved)
    #expect(approved.ownerResponse == .approved)
    #expect(approved.paperPortfolioExecutionPendingState == nil)
    #expect(approved.paperPortfolioExecutionLifecycleState?.status == .blocked)
    #expect(approved.paperPortfolioExecutionLifecycleState?.orderPlanStatus == .blocked)
    #expect(approved.paperPortfolioExecutionLifecycleState?.blockedReasons == [.alpacaTradingCredentialsUnavailable])
    #expect(approved.paperPortfolioExecutionLifecycleState?.summary.contains("Paper Alpaca trading credentials are unavailable") == true)
    #expect(approved.paperPortfolioExecutionLifecycleState?.detail.contains("Existing account data may be from an earlier reconciliation") == true)
    #expect(approved.lastExecutionRoutingAssessment?.status == .blockedExecutionPrerequisites)
    #expect(approved.lastExecutionRoutingAssessment?.blockedReasons == [.alpacaTradingCredentialsUnavailable])
    #expect(await rest.placeOrderCallCount() == 0)
    #expect(paperStatus?["state"]?.stringValue == "blocked")
    #expect(paperStatus?["blockedReasons"]?.arrayValue?.contains(.string("alpaca_trading_credentials_unavailable")) == true)
    #expect(credentialsStatus?["ready"]?.boolValue == false)
    #expect(credentialsStatus?["accountDataCurrentlyOrderReady"]?.boolValue == false)
}

@Test("Owner approval response records exact blocker and pending state when paper prices are missing")
func pmApprovalResponseRecordsPaperEstablishmentBlockerWhenPricesAreMissing() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-approval-response-paper-establishment-missing-prices")
    let now = Date(timeIntervalSince1970: 1_746_500_300)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let instructionStore = PMInstructionStore(instructionsDirectory: root.appendingPathComponent("instructions", isDirectory: true))
    let approvalStore = PMApprovalRequestStore(approvalRequestsDirectory: root.appendingPathComponent("approval_requests", isDirectory: true))
    let store = Store()
    let rest = RecordingPMConversationRESTClient()
    let marketDataStream = AlpacaMarketDataStream(environment: .paper, feed: .test)

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Records exact blockers for approved paper-establishment requests.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await instructionStore.upsert(
        PMInstruction(
            instructionId: "instruction-working-paper-portfolio-approval-missing-prices",
            pmId: "pm-1",
            title: "Working paper portfolio definition",
            body: "Initial paper portfolio: Long NVDA 16%, TSM 11%; Short KSS -7%.",
            category: "conversation_working_portfolio_definition",
            createdAt: now,
            updatedAt: now
        )
    )
    let account = Account(
        id: "acct-approval-handoff-missing-prices",
        status: "ACTIVE",
        cash: "100000",
        buyingPower: "200000",
        equity: "100000",
        multiplier: "2"
    )
    await rest.setAccount(account)
    await store.applyStartupSnapshot(account: account, positions: [], openOrders: [])

    let engine = Engine(
        configuration: Configuration(environment: .paper),
        store: store,
        marketDataStream: marketDataStream,
        pmProfileStore: profileStore,
        pmInstructionStore: instructionStore,
        pmApprovalRequestStore: approvalStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        keychainProvider: pmConversationAlpacaKeychainProvider(),
        restClientFactory: { _ in rest },
        workingPaperPortfolioPriceRepairEnabled: false
    )

    _ = try await engine.upsertPMApprovalRequest(
        PMApprovalRequest(
            approvalRequestId: "approval-paper-handoff-missing-prices",
            pmId: "pm-1",
            subject: "Review PM recommendation: establish the initial paper portfolio",
            rationale: "The current working paper portfolio is ready for governed paper-establishment.",
            requestedActionSummary: "Approve moving the current working paper portfolio into the governed paper-establishment workflow now.",
            requestType: .portfolioAction,
            status: .pending,
            createdAt: now,
            updatedAt: now
        ),
        source: .system
    )

    let approved = try await engine.respondToPMApprovalRequest(
        requestId: "approval-paper-handoff-missing-prices",
        response: .approved,
        source: .ui
    )
    let subscriptions = await marketDataStream.currentDesiredSubscriptions()

    #expect(approved.paperPortfolioExecutionPendingState?.status == .waitingForUsablePrices)
    #expect(approved.paperPortfolioExecutionLifecycleState?.status == .waitingForUsablePrices)
    #expect(approved.paperPortfolioExecutionLifecycleState?.orderPlanStatus == .waitingForUsablePrices)
    #expect(Set(approved.paperPortfolioExecutionLifecycleState?.missingPriceSymbols ?? []) == Set(["NVDA", "TSM", "KSS"]))
    #expect(approved.paperPortfolioExecutionLifecycleState?.blockedReasons == [.marketPriceUnavailable])
    #expect(approved.lastExecutionRoutingAssessment?.status == .blockedExecutionPrerequisites)
    #expect(approved.lastExecutionRoutingAssessment?.blockedReasons.contains(.marketPriceUnavailable) == true)
    #expect(Set(subscriptions.quotes) == Set(["NVDA", "TSM", "KSS"]))
    #expect(await rest.placeOrderCallCount() == 0)
}

@Test("Route action for unapproved paper establishment records owner-approval blocker without submitting")
func pmRouteActionForUnapprovedPaperEstablishmentDoesNotSubmit() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-route-unapproved-paper-establishment-blocked")
    let now = Date(timeIntervalSince1970: 1_746_500_360)
    let instructionStore = PMInstructionStore(instructionsDirectory: root.appendingPathComponent("instructions", isDirectory: true))
    let approvalStore = PMApprovalRequestStore(approvalRequestsDirectory: root.appendingPathComponent("approval_requests", isDirectory: true))
    let store = Store()
    let rest = RecordingPMConversationRESTClient()

    _ = try await instructionStore.upsert(
        PMInstruction(
            instructionId: "instruction-working-paper-portfolio-unapproved-route",
            pmId: "pm-1",
            title: "Working paper portfolio definition",
            body: "Initial paper portfolio: Long NVDA 16%, TSM 11%; Short KSS -7%.",
            category: "conversation_working_portfolio_definition",
            createdAt: now,
            updatedAt: now
        )
    )
    let account = Account(
        id: "acct-unapproved-route",
        status: "ACTIVE",
        cash: "100000",
        buyingPower: "200000",
        equity: "100000",
        multiplier: "2"
    )
    await rest.setAccount(account)
    await store.applyStartupSnapshot(account: account, positions: [], openOrders: [])
    await publishPaperPortfolioQuotes(store: store, pricesBySymbol: ["NVDA": 100, "TSM": 100, "KSS": 100])

    let engine = Engine(
        configuration: Configuration(environment: .paper),
        store: store,
        pmInstructionStore: instructionStore,
        pmApprovalRequestStore: approvalStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        keychainProvider: pmConversationAlpacaKeychainProvider(),
        restClientFactory: { _ in rest }
    )

    _ = try await engine.upsertPMApprovalRequest(
        PMApprovalRequest(
            approvalRequestId: "approval-paper-unapproved-route",
            pmId: "pm-1",
            subject: "Review PM recommendation: establish the initial paper portfolio",
            rationale: "The current working paper portfolio still needs owner approval.",
            requestedActionSummary: "Approve moving the current working paper portfolio into the governed paper-establishment workflow now.",
            requestType: .portfolioAction,
            status: .pending,
            createdAt: now,
            updatedAt: now
        ),
        source: .system
    )

    let assessment = try await engine.routePMExecutionApprovedIntent(
        approvalRequestId: "approval-paper-unapproved-route",
        source: .ui
    )
    let request = try await engine.getPMApprovalRequest(id: "approval-paper-unapproved-route")

    #expect(assessment.status == .invalidState)
    #expect(assessment.blockedReasons == [.ownerApprovalRequired])
    #expect(request.lastExecutionRoutingAssessment?.blockedReasons == [.ownerApprovalRequired])
    #expect(request.paperPortfolioExecutionPendingState == nil)
    #expect(request.paperPortfolioExecutionLifecycleState == nil)
    #expect(await rest.placeOrderCallCount() == 0)
}

@Test("Approved PM handoff records live environment blocker instead of silently stopping")
func pmApprovalResponseRecordsLiveGovernedRouteBlocker() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-approval-response-live-route-blocker")
    let now = Date(timeIntervalSince1970: 1_746_500_420)
    let approvalStore = PMApprovalRequestStore(approvalRequestsDirectory: root.appendingPathComponent("approval_requests", isDirectory: true))
    let proposalStore = ProposalStore(proposalsDirectory: root.appendingPathComponent("proposals", isDirectory: true))
    let engine = Engine(
        configuration: Configuration(environment: .live),
        pmApprovalRequestStore: approvalStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        proposalStore: proposalStore
    )

    _ = try await proposalStore.upsertProposal(
        makePMConversationGovernedExecutionProposal(
            id: "proposal-live-blocked-paper-approved",
            status: .approvedPaper
        )
    )
    _ = try await engine.upsertPMApprovalRequest(
        PMApprovalRequest(
            approvalRequestId: "approval-live-blocked-paper-approved",
            pmId: "pm-1",
            subject: "Route approved proposal",
            rationale: "Owner approved the PM next step, but the linked proposal is paper-approved while the app is live.",
            requestType: .proposalReview,
            status: .pending,
            proposalId: "proposal-live-blocked-paper-approved",
            createdAt: now,
            updatedAt: now
        ),
        source: .system
    )

    let approved = try await engine.respondToPMApprovalRequest(
        requestId: "approval-live-blocked-paper-approved",
        response: .approved,
        source: .ui
    )

    #expect(approved.status == .resolved)
    #expect(approved.ownerResponse == .approved)
    #expect(approved.lastExecutionRoutingAssessment?.status == .blockedEnvironmentMismatch)
    #expect(approved.lastExecutionRoutingAssessment?.blockedReasons.contains(.environmentMismatch) == true)
    #expect(approved.lastExecutionRoutingAssessment?.summary.contains("currently set to Live") == true)
}

@Test("Approved PM handoff routes proposal-backed paper execution through existing strategy path")
func pmApprovalResponseHandsOffProposalBackedPaperExecution() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-approval-response-proposal-backed-route")
    let now = Date(timeIntervalSince1970: 1_746_500_480)
    let approvalStore = PMApprovalRequestStore(approvalRequestsDirectory: root.appendingPathComponent("approval_requests", isDirectory: true))
    let proposalStore = ProposalStore(proposalsDirectory: root.appendingPathComponent("proposals", isDirectory: true))
    let paperRunStore = PaperRunStore(runsDirectory: root.appendingPathComponent("runs", isDirectory: true))
    let engine = Engine(
        configuration: Configuration(environment: .paper),
        pmApprovalRequestStore: approvalStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        proposalStore: proposalStore,
        paperRunStore: paperRunStore
    )

    _ = try await proposalStore.upsertProposal(
        makePMConversationGovernedExecutionProposal(
            id: "proposal-approval-handoff-route",
            status: .approvedPaper
        )
    )
    _ = try await engine.upsertPMApprovalRequest(
        PMApprovalRequest(
            approvalRequestId: "approval-proposal-backed-route",
            pmId: "pm-1",
            subject: "Route approved proposal",
            rationale: "Owner approved the PM next step for the linked proposal.",
            requestType: .proposalReview,
            status: .pending,
            proposalId: "proposal-approval-handoff-route",
            createdAt: now,
            updatedAt: now
        ),
        source: .system
    )

    let approved = try await engine.respondToPMApprovalRequest(
        requestId: "approval-proposal-backed-route",
        response: .approved,
        source: .ui
    )
    let runs = try await paperRunStore.listRuns(proposalId: "proposal-approval-handoff-route")

    #expect(approved.status == .resolved)
    #expect(approved.ownerResponse == .approved)
    #expect(approved.lastExecutionRoutingAssessment?.status == .routedSuccessfully)
    #expect(approved.lastExecutionRoutingAssessment?.action == .startProposalExecution)
    #expect(runs.count == 1)
    _ = try await engine.stopStrategy(id: "heartbeat")
}

@Test("PM conversation prompt includes paper-establishment lifecycle when owner asks execution status")
func pmConversationPromptIncludesPaperEstablishmentLifecycleForExecutionStatusQuestion() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-conversation-paper-establishment-status-context")
    let now = Date(timeIntervalSince1970: 1_746_500_120)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let approvalStore = PMApprovalRequestStore(approvalRequestsDirectory: root.appendingPathComponent("approval_requests", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "The owner approval is recorded, but app truth has no active paper-establishment pending execution state or order-attempt lifecycle yet.",
            actionPlan: PMConversationActionPlan(
                summary: "Answer from app-owned paper-establishment lifecycle truth.",
                actions: [
                    PMConversationActionIntent(
                        actionType: .answerOnly,
                        summary: "Report the execution lifecycle state without creating a new approval or route."
                    )
                ]
            ),
            resolution: PMConversationResolutionState(
                intentClass: .followUpQuestion,
                disposition: .conversationOnly
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Answers paper-establishment execution status from app truth.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await approvalStore.upsert(
        PMApprovalRequest(
            approvalRequestId: "approval-paper-establishment-status-context",
            pmId: "pm-1",
            subject: "Review PM recommendation: establish the initial paper portfolio",
            rationale: "The current working paper portfolio is approved for governed paper-establishment.",
            requestedActionSummary: "Approve moving the current working paper portfolio into the governed paper-establishment workflow now.",
            requestType: .portfolioAction,
            status: .resolved,
            ownerResponse: .approved,
            ownerRespondedAt: now.addingTimeInterval(-3_600),
            createdAt: now.addingTimeInterval(-7_200),
            updatedAt: now.addingTimeInterval(-3_600)
        )
    )

    let engine = Engine(
        configuration: Configuration(environment: .paper),
        pmProfileStore: profileStore,
        pmApprovalRequestStore: approvalStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "Please check to see where the app is in executing the trades required to establish the initial paper portfolio.",
        source: .ui
    )
    _ = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)

    let request = try #require(await synthesisProvider.lastConversationRequest)
    let lifecycleIndex = try #require(
        request.confirmedAppTruthSummary.firstIndex {
            $0.contains("Confirmed paper-establishment execution lifecycle in app truth")
        }
    )
    #expect(lifecycleIndex <= 3)
    #expect(
        request.confirmedAppTruthSummary.contains {
            $0.contains("Alpaca trading credential")
        }
    )
    #expect(request.confirmedAppTruthSummary[lifecycleIndex].contains("no active pending execution/retry state"))
    #expect(request.confirmedAppTruthSummary[lifecycleIndex].contains("Alpaca order submission has not been attempted"))
}

@Test("Negative explain-only paper-portfolio wording does not record approval or route execution")
func pmConversationNegativePaperPortfolioExecutionWordingDoesNotEscalate() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-conversation-paper-portfolio-execution-negative-wording")
    let now = Date(timeIntervalSince1970: 1_746_159_660)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let instructionStore = PMInstructionStore(instructionsDirectory: root.appendingPathComponent("instructions", isDirectory: true))
    let decisionStore = PMDecisionStore(decisionsDirectory: root.appendingPathComponent("decisions", isDirectory: true))
    let approvalStore = PMApprovalRequestStore(approvalRequestsDirectory: root.appendingPathComponent("approval_requests", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "I can walk through the governed paper-portfolio implementation process, but I will not place anything yet.",
            resolution: PMConversationResolutionState(
                intentClass: .clarification,
                disposition: .conversationOnly
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Avoids false approval from hold-off wording.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await instructionStore.upsert(
        PMInstruction(
            instructionId: "instruction-working-paper-portfolio-negative-wording",
            pmId: "pm-1",
            title: "Working paper portfolio definition",
            body: "Initial paper portfolio: Long NVDA 16%, TSM 11%, AVGO 11%, AMZN 11%, GOOG 11%, AAPL 10%, CRWD 10%, NFLX 10%, TSLA 10%; Short KSS -7%, NYCB -5%.",
            category: "conversation_working_portfolio_definition",
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        configuration: Configuration(environment: .paper),
        pmProfileStore: profileStore,
        pmInstructionStore: instructionStore,
        pmDecisionStore: decisionStore,
        pmApprovalRequestStore: approvalStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: PMCommunicationSenderRole.owner,
        senderId: "owner",
        body: "Do not place the trades required to implement the current proposed paper portfolio yet; just explain the process.",
        source: AuditEventSource.ui
    )
    let reply = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: AuditEventSource.ui)

    let decisions = try await engine.listPMDecisions()
    let approvalRequests = try await engine.listPMApprovalRequests()
    let allMessages = try await engine.listPMCommunicationMessages()
    let followThroughMessages = allMessages.filter { message in
        message.senderRole == PMCommunicationSenderRole.pm && message.replyToMessageId == reply.messageId
    }
    let actionTypes = reply.conversationActionPlan?.actions.map { $0.actionType }

    #expect(reply.runtimeProvenance?.conversationTrace?.actionPlanSource == .modelResolution)
    #expect(actionTypes == [.answerOnly])
    #expect(decisions.isEmpty)
    #expect(approvalRequests.isEmpty)
    #expect(followThroughMessages.isEmpty)
}

@Test("PM conversation can draft a governed proposal and create linked approval artifacts")
func pmConversationCanDraftGovernedProposalAndApprovalArtifacts() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-conversation-governed-proposal")
    let now = Date(timeIntervalSince1970: 1_746_000_800)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let proposalStore = ProposalStore(proposalsDirectory: root.appendingPathComponent("proposals", isDirectory: true))
    let decisionStore = PMDecisionStore(decisionsDirectory: root.appendingPathComponent("decisions", isDirectory: true))
    let approvalStore = PMApprovalRequestStore(approvalRequestsDirectory: root.appendingPathComponent("approval_requests", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "I think Costco is worth moving into the governed paper workflow, so I’m drafting the proposal and setting up the owner approval ask now.",
            actionPlan: PMConversationActionPlan(
                summary: "Draft the governed Costco proposal, then create the linked PM recommendation and approval request.",
                actions: [
                    PMConversationActionIntent(
                        actionType: .createOrUpdateProposal,
                        summary: "Draft a bounded paper proposal to add Costco as a single-name long candidate.",
                        title: "Costco paper proposal",
                        body: "Create a bounded single-name paper proposal so the owner can review Costco through the existing governed path.",
                        proposalSymbol: "cost",
                        proposalSide: .buy,
                        proposalQuantity: 5,
                        sourceMessageIds: []
                    ),
                    PMConversationActionIntent(
                        actionType: .createPMDecision,
                        summary: "Recommend that Costco move into the governed paper proposal path.",
                        title: "PM recommendation: Costco governed paper proposal",
                        body: "Recommend advancing Costco into a bounded paper proposal review.",
                        detail: "Please review the Costco paper proposal recommendation.",
                        decisionType: .recommendation,
                        sourceMessageIds: []
                    ),
                    PMConversationActionIntent(
                        actionType: .createPMApprovalRequest,
                        summary: "Create the owner-facing PM ask for the Costco proposal recommendation.",
                        title: "Review PM recommendation: Costco paper proposal",
                        body: "Please review whether Costco should move forward through the governed paper proposal path.",
                        requestType: .proposalReview,
                        sourceMessageIds: []
                    )
                ]
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Drafts governed proposals from PM conversation.",
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        configuration: Configuration(environment: .paper),
        pmProfileStore: profileStore,
        pmDecisionStore: decisionStore,
        pmApprovalRequestStore: approvalStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider,
        proposalStore: proposalStore
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: PMCommunicationSenderRole.owner,
        senderId: "owner",
        body: "If Costco still makes sense, move it into the governed paper workflow and tee up whatever normal approval ask we need.",
        source: AuditEventSource.ui
    )
    let reply = try await engine.generatePMConversationReply(
        to: ownerAsk.messageId,
        source: AuditEventSource.ui
    )

    let proposals = try await engine.listProposals()
    let decisions = try await engine.listPMDecisions()
    let approvalRequests = try await engine.listPMApprovalRequests()
    let allMessages = try await engine.listPMCommunicationMessages()
    let proposal = try #require(proposals.last)
    let decision = try #require(decisions.last)
    let approvalRequest = try #require(approvalRequests.last)
    let sessionMessages = allMessages.filter { $0.sessionId == session.sessionId }
    let messages = sessionMessages.sorted { lhs, rhs in lhs.sentAt < rhs.sentAt }
    let followThroughMessages = messages.filter {
        $0.senderRole == PMCommunicationSenderRole.pm && $0.replyToMessageId == reply.messageId
    }
    let followThrough = try #require(followThroughMessages.last)

    #expect(reply.body.contains("Costco"))
    #expect(reply.body.contains("proposal"))
    #expect(proposal.strategyId == "paper_oneshot")
    #expect(proposal.scope.symbols == ["COST"])
    #expect(proposal.parameters["symbol"]?.stringValue == "COST")
    #expect(proposal.parameters["side"]?.stringValue == "buy")
    #expect(proposal.parameters["qty"]?.intValue == 5)
    #expect(proposal.approval.status == StrategyProposalStatus.draft)
    #expect(decision.proposalId == proposal.proposalId)
    #expect(approvalRequest.decisionId == decision.decisionId)
    #expect(approvalRequest.proposalId == proposal.proposalId)
    #expect(approvalRequest.requestType == PMApprovalRequestType.proposalReview)
    #expect(followThrough.body.contains("drafted the governed proposal"))
    #expect(followThrough.body.contains("approval-ready PM ask"))
    #expect(followThrough.body.contains("existing proposal review step"))
    #expect(followThrough.body.contains("targetId") == false)
}

@Test("PM conversation can route governed execution and explain blocked approval states naturally")
func pmConversationGovernedRoutingExplainsBlockedApprovalState() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-conversation-governed-route-blocked")
    let now = Date(timeIntervalSince1970: 1_746_000_900)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let proposalStore = ProposalStore(proposalsDirectory: root.appendingPathComponent("proposals", isDirectory: true))
    let decisionStore = PMDecisionStore(decisionsDirectory: root.appendingPathComponent("decisions", isDirectory: true))
    let approvalStore = PMApprovalRequestStore(approvalRequestsDirectory: root.appendingPathComponent("approval_requests", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let paperRunStore = PaperRunStore(runsDirectory: root.appendingPathComponent("runs", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "I’m drafting the proposal, setting up the approval ask, and checking whether any governed routing can happen yet.",
            actionPlan: PMConversationActionPlan(
                summary: "Draft the proposal, create the approval ask, and test routing through the existing governed path.",
                actions: [
                    PMConversationActionIntent(
                        actionType: .createOrUpdateProposal,
                        summary: "Draft a bounded paper proposal for Costco.",
                        title: "Costco paper proposal",
                        body: "Create the paper-safe Costco proposal in the governed path.",
                        proposalSymbol: "COST",
                        proposalSide: .buy,
                        proposalQuantity: 3,
                        sourceMessageIds: []
                    ),
                    PMConversationActionIntent(
                        actionType: .createPMDecision,
                        summary: "Recommend the Costco paper proposal for owner review.",
                        title: "PM recommendation: Costco paper proposal",
                        body: "Recommend advancing the Costco paper proposal into the normal owner review loop.",
                        detail: "Please review the Costco paper proposal recommendation.",
                        decisionType: .recommendation,
                        sourceMessageIds: []
                    ),
                    PMConversationActionIntent(
                        actionType: .createPMApprovalRequest,
                        summary: "Create the Costco owner approval request.",
                        title: "Review PM recommendation: Costco paper proposal",
                        body: "Please review the Costco paper proposal recommendation.",
                        requestType: .proposalReview,
                        sourceMessageIds: []
                    ),
                    PMConversationActionIntent(
                        actionType: .routeGovernedExecutionNextStep,
                        summary: "Route the Costco recommendation through the governed path if it is actually ready.",
                        sourceMessageIds: []
                    )
                ]
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Routes governed paper steps without bypassing approval.",
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        configuration: Configuration(environment: .paper),
        pmProfileStore: profileStore,
        pmDecisionStore: decisionStore,
        pmApprovalRequestStore: approvalStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider,
        proposalStore: proposalStore,
        paperRunStore: paperRunStore
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: PMCommunicationSenderRole.owner,
        senderId: "owner",
        body: "Move Costco forward if it’s ready, but only through the normal governed path.",
        source: AuditEventSource.ui
    )
    let reply = try await engine.generatePMConversationReply(
        to: ownerAsk.messageId,
        source: AuditEventSource.ui
    )

    let proposals = try await engine.listProposals()
    let approvalRequests = try await engine.listPMApprovalRequests()
    let allMessages = try await engine.listPMCommunicationMessages()
    let proposal = try #require(proposals.last)
    let approvalRequest = try #require(approvalRequests.last)
    let runs = try await paperRunStore.listRuns(proposalId: proposal.proposalId)
    let sessionMessages = allMessages.filter { $0.sessionId == session.sessionId }
    let messages = sessionMessages.sorted { lhs, rhs in lhs.sentAt < rhs.sentAt }
    let followThroughMessages = messages.filter {
        $0.senderRole == PMCommunicationSenderRole.pm && $0.replyToMessageId == reply.messageId
    }
    let followThrough = try #require(followThroughMessages.last)

    #expect(approvalRequest.status == PMApprovalRequestStatus.pending)
    #expect(runs.isEmpty)
    #expect(reply.conversationActionPlan?.actions.last?.targetId == approvalRequest.approvalRequestId)
    #expect(reply.conversationActionPlan?.actions.last?.detail?.contains("approved owner response") == true)
    #expect(followThrough.body.contains("approved owner response before the app can route the next governed step"))
    #expect(followThrough.body.contains("existing proposal review step"))
    #expect(followThrough.body.contains("actionType") == false)
}

@Test("PM conversation can route an approved paper proposal through the governed execution path")
func pmConversationCanRouteApprovedPaperProposal() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-conversation-governed-route-success")
    let now = Date(timeIntervalSince1970: 1_746_001_000)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let proposalStore = ProposalStore(proposalsDirectory: root.appendingPathComponent("proposals", isDirectory: true))
    let approvalStore = PMApprovalRequestStore(approvalRequestsDirectory: root.appendingPathComponent("approval_requests", isDirectory: true))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let paperRunStore = PaperRunStore(runsDirectory: root.appendingPathComponent("runs", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationOutput: PMConversationOpenAISynthesisOutput(
            replyBody: "The paper proposal is already approved, so I’m routing the next step through the existing governed execution path now.",
            actionPlan: PMConversationActionPlan(
                summary: "Route the approved paper proposal through the existing governed execution path.",
                actions: [
                    PMConversationActionIntent(
                        actionType: .routeGovernedExecutionNextStep,
                        summary: "Route the already-approved paper proposal through the existing governed execution path.",
                        targetId: "approval-route-success",
                        sourceMessageIds: []
                    )
                ]
            )
        ),
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Routes approved paper proposals through the governed path.",
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        configuration: Configuration(environment: .paper),
        pmProfileStore: profileStore,
        pmApprovalRequestStore: approvalStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider,
        proposalStore: proposalStore,
        paperRunStore: paperRunStore
    )

    _ = try await proposalStore.upsertProposal(makePMConversationGovernedExecutionProposal(id: "proposal-route-success", status: .approvedPaper))
    _ = try await engine.upsertPMApprovalRequest(
        PMApprovalRequest(
            approvalRequestId: "approval-route-success",
            pmId: "pm-1",
            subject: "Route approved paper proposal",
            rationale: "Owner approved the next paper-safe step.",
            requestType: .proposalReview,
            status: .resolved,
            proposalId: "proposal-route-success",
            ownerResponse: .approved,
            ownerRespondedAt: now,
            createdAt: now,
            updatedAt: now
        )
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: PMCommunicationSenderRole.owner,
        senderId: "owner",
        body: "That paper proposal is already approved. Route it through the normal governed execution path.",
        source: AuditEventSource.ui
    )
    let reply = try await engine.generatePMConversationReply(
        to: ownerAsk.messageId,
        source: AuditEventSource.ui
    )

    let runs = try await paperRunStore.listRuns(proposalId: "proposal-route-success")
    let allMessages = try await engine.listPMCommunicationMessages()
    let sessionMessages = allMessages.filter { $0.sessionId == session.sessionId }
    let messages = sessionMessages.sorted { lhs, rhs in lhs.sentAt < rhs.sentAt }
    let followThroughMessages = messages.filter {
        $0.senderRole == PMCommunicationSenderRole.pm && $0.replyToMessageId == reply.messageId
    }
    let followThrough = try #require(followThroughMessages.last)

    #expect(runs.count == 1)
    #expect(reply.conversationActionPlan?.actions.first?.targetId == "approval-route-success")
    #expect(reply.conversationActionPlan?.actions.first?.detail?.contains("paper-safe execution path") == true)
    #expect(followThrough.body.contains("paper-safe execution path"))
    #expect(followThrough.body.contains("proposal review path") == false)
    _ = try await engine.stopStrategy(id: "heartbeat")
}

@Test("PM conversation retries once with compacted grounding when the provider rejects an oversized request")
func pmConversationRetriesWithCompactedGroundingAfterOversizedProviderFailure() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-conversation-compact-retry")
    let now = Date(timeIntervalSince1970: 1_746_002_000)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let runtimeStore = PMRuntimeSettingsStore(fileURL: root.appendingPathComponent("pm-runtime-settings.json", isDirectory: false))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationResults: [
            .failure(.httpStatus(400, responseSummary: "code=context_length_exceeded type=invalid_request_error message=This request exceeded the model context length.")),
            .success(
                PMConversationOpenAISynthesisOutput(
                    replyBody: "The latest proposed paper portfolio is still the same working list we discussed, and I can walk through any name you want next.",
                    actionPlan: PMConversationActionPlan(
                        summary: "Answer directly after bounded retry compaction.",
                        actions: [
                            PMConversationActionIntent(
                                actionType: .answerOnly,
                                summary: "Answer directly.",
                                sourceMessageIds: []
                            )
                        ]
                    )
                )
            )
        ],
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Retries compact PM synthesis after oversized provider failures.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await runtimeStore.upsert(
        PMRuntimeSettings(
            runtimeIdentifier: "gpt-5",
            reasoningMode: .deliberate,
            updatedBy: "owner",
            updateSource: .userEdited,
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmRuntimeSettingsStore: runtimeStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    for index in 0..<22 {
        let ownerMessage = try await engine.createPMCommunicationMessage(
            sessionId: session.sessionId,
            senderRole: .owner,
            senderId: "owner",
            body: "Prior discussion block \(index): Here is additional portfolio and analyst context that keeps the PM thread realistic and long enough to exercise bounded compaction.",
            source: .ui
        )
        _ = try await engine.createPMCommunicationMessage(
            sessionId: session.sessionId,
            senderRole: .pm,
            senderId: "pm-1",
            body: "PM reply block \(index): I’m keeping that context in mind while we refine the proposed paper portfolio and review the analyst work.",
            replyToMessageId: ownerMessage.messageId,
            source: .ui
        )
    }

    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "What is the latest proposed paper portfolio again?",
        source: .ui
    )
    let reply = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)
    let requests = await synthesisProvider.conversationRequests
    let firstRequest = try #require(requests.first)
    let secondRequest = try #require(requests.last)
    let settings = try await engine.getPMRuntimeSettings()

    #expect(requests.count == 2)
    #expect(pmConversationPromptCharacterCount(for: secondRequest) < pmConversationPromptCharacterCount(for: firstRequest))
    #expect(reply.runtimeProvenance?.usedOpenAI == true)
    #expect(reply.runtimeProvenance?.conversationTrace?.modelAttemptCount == 2)
    #expect(reply.runtimeProvenance?.conversationTrace?.requestCompactionLevel == "compact")
    #expect(reply.runtimeProvenance?.conversationTrace?.structuredOutputSchemaName == "pm_conversation_reply")
    #expect(reply.runtimeProvenance?.conversationTrace?.structuredOutputSchemaLocallyValidated == true)
    #expect(reply.runtimeProvenance?.conversationTrace?.fallbackTrigger == nil)
    #expect(settings.executionStatus?.category == .accepted)
}

@Test("PM runtime settings surface the latest live execution failure instead of stale healthy preflight truth")
func pmRuntimeSettingsReflectLatestLiveExecutionFailure() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-runtime-settings-live-failure")
    let now = Date(timeIntervalSince1970: 1_746_002_100)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let runtimeStore = PMRuntimeSettingsStore(fileURL: root.appendingPathComponent("pm-runtime-settings.json", isDirectory: false))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationResults: [
            .failure(.httpStatus(400, responseSummary: "code=context_length_exceeded type=invalid_request_error message=This request exceeded the model context length."))
        ],
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Surfaces live PM runtime failures in Settings truth.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await runtimeStore.upsert(
        PMRuntimeSettings(
            runtimeIdentifier: "gpt-5",
            reasoningMode: .deliberate,
            updatedBy: "owner",
            updateSource: .userEdited,
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmRuntimeSettingsStore: runtimeStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "What was the latest proposed paper portfolio?",
        source: .ui
    )
    let reply = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)
    let settings = try await engine.getPMRuntimeSettings()
    let presentation = try #require(makeRuntimeOperabilityPresentation(pmRuntimeSettings: settings))

    #expect(reply.body.contains("the request was too large"))
    #expect(reply.runtimeProvenance?.conversationTrace?.fallbackTrigger == .requestTooLarge)
    #expect(reply.runtimeProvenance?.conversationTrace?.modelAttemptCount == 2)
    #expect(settings.validationStatus?.category == .accepted)
    #expect(settings.executionStatus?.category == .requestTooLarge)
    #expect(presentation.operabilityLabel == "Request Too Large")
    #expect(presentation.ownerSurfaceSummary.contains("latest live PM request was too large"))
}

@Test("PM runtime settings surface invalid structured-output schema failures distinctly from generic runtime failure")
func pmRuntimeSettingsReflectInvalidStructuredSchemaFailures() async throws {
    let root = makePMCommunicationTempDirectory(name: "pm-runtime-settings-invalid-schema")
    let now = Date(timeIntervalSince1970: 1_746_002_300)
    let profileStore = PMProfileStore(profilesDirectory: root.appendingPathComponent("profiles", isDirectory: true))
    let runtimeStore = PMRuntimeSettingsStore(fileURL: root.appendingPathComponent("pm-runtime-settings.json", isDirectory: false))
    let sessionStore = PMCommunicationSessionStore(sessionsDirectory: root.appendingPathComponent("sessions", isDirectory: true))
    let messageStore = PMCommunicationMessageStore(messagesDirectory: root.appendingPathComponent("messages", isDirectory: true))
    let synthesisProvider = StubPMOpenAISynthesisProvider(
        conversationResults: [
            .failure(.invalidSchema(reason: "schema_name=pm_conversation_reply schema_path=schema.properties.resolution required_mismatch"))
        ],
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput(
            disposition: "worth_monitoring",
            summary: "Unused standing review summary.",
            recommendedAction: "Unused standing review action."
        )
    )

    _ = try await profileStore.upsert(
        PMProfile(
            pmId: "pm-1",
            displayName: "Primary PM",
            roleSummary: "Surfaces invalid PM structured-output schemas distinctly.",
            createdAt: now,
            updatedAt: now
        )
    )
    _ = try await runtimeStore.upsert(
        PMRuntimeSettings(
            runtimeIdentifier: "gpt-5.4",
            reasoningMode: .standard,
            updatedBy: "owner",
            updateSource: .userEdited,
            createdAt: now,
            updatedAt: now
        )
    )

    let engine = Engine(
        pmProfileStore: profileStore,
        pmRuntimeSettingsStore: runtimeStore,
        pmCommunicationSessionStore: sessionStore,
        pmCommunicationMessageStore: messageStore,
        openAIKeyStatusProvider: StubPMOpenAIKeyProvider(configured: true, value: "test-openai-key"),
        pmOpenAISynthesisProvider: synthesisProvider
    )

    let session = try await engine.ensureInAppPMUserCommunicationSession(pmId: "pm-1")
    let ownerAsk = try await engine.createPMCommunicationMessage(
        sessionId: session.sessionId,
        senderRole: .owner,
        senderId: "owner",
        body: "What was the latest proposed paper portfolio?",
        source: .ui
    )
    let reply = try await engine.generatePMConversationReply(to: ownerAsk.messageId, source: .ui)
    let settings = try await engine.getPMRuntimeSettings()
    let presentation = try #require(makeRuntimeOperabilityPresentation(pmRuntimeSettings: settings))

    #expect(reply.body.contains("structured-output schema is invalid"))
    #expect(reply.body.contains("Check the PM runtime configuration or OpenAI access, then retry."))
    #expect(reply.runtimeProvenance?.conversationTrace?.fallbackTrigger == .invalidSchema)
    #expect(reply.runtimeProvenance?.conversationTrace?.structuredOutputSchemaName == "pm_conversation_reply")
    #expect(reply.runtimeProvenance?.conversationTrace?.structuredOutputSchemaLocallyValidated == false)
    #expect(reply.runtimeProvenance?.conversationTrace?.providerResponseAccepted == false)
    #expect(reply.runtimeProvenance?.conversationTrace?.providerResponseIssueSummary?.contains("schema_name=pm_conversation_reply") == true)
    #expect(settings.validationStatus?.category == .accepted)
    #expect(settings.executionStatus?.category == .invalidSchema)
    #expect(presentation.operabilityLabel == "Invalid Structured Output Schema")
}

private func makePMConversationGovernedExecutionProposal(
    id: String,
    status: StrategyProposalStatus
) -> StrategyProposal {
    StrategyProposal(
        proposalId: id,
        createdAt: Date(timeIntervalSince1970: 1_746_001_000),
        updatedAt: Date(timeIntervalSince1970: 1_746_001_000),
        createdBy: "pm",
        title: "Governed routing proposal",
        summary: "Route through the governed paper workflow.",
        strategyId: "heartbeat",
        parameters: ["intervalSec": .number(0.2)],
        scope: StrategyProposalScope(symbols: ["COST"]),
        intendedEnvironmentPaperOnly: true,
        constraints: StrategyProposalConstraints(
            maxOrdersPerMinute: 5,
            maxNotionalPerOrder: Decimal(string: "1000")!,
            maxDailyNotional: Decimal(string: "5000"),
            allowShort: false,
            allowOptions: false
        ),
        testPlan: StrategyProposalTestPlan(
            durationMinutes: 15,
            successMetrics: ["No crashes"],
            stopConditions: ["Excess errors"]
        ),
        rationale: "Exercise PM governed routing from conversation.",
        approval: StrategyProposalApproval(status: status)
    )
}

private struct StubPMOpenAIKeyProvider: OpenAIKeyStatusProviding {
    let configured: Bool
    let value: String?

    func isConfigured() -> Bool { configured }
    func apiKey() -> String? { value }
}

private func pmConversationAlpacaKeychainProvider(
    paperReady: Bool = true,
    liveReady: Bool = false
) -> KeychainCredentialsProvider {
    var values: [String: String] = [:]
    if paperReady {
        values["alpaca.api.key|algo-trading/paper"] = "paper-public-test-key"
        values["alpaca.secret.key|algo-trading/paper"] = "paper-secret-test-key"
    }
    if liveReady {
        values["alpaca.api.key|algo-trading/live"] = "live-public-test-key"
        values["alpaca.secret.key|algo-trading/live"] = "live-secret-test-key"
    }
    return KeychainCredentialsProvider(
        keyReader: PMConversationAlpacaKeyReader(values: values)
    )
}

private struct PMConversationAlpacaKeyReader: KeyReading {
    let values: [String: String]

    func readKey(service: String, account: String) -> String? {
        values["\(service)|\(account)"]
    }
}

private actor RecordingPMConversationRESTClient: AlpacaRESTServing {
    private var accountState = Account(
        id: "acct-1",
        status: "ACTIVE",
        cash: "100000",
        buyingPower: "200000",
        equity: "100000",
        multiplier: "2"
    )
    private var positionsState: [Position] = []
    private var openOrdersState: [Order] = []
    private var placeOrderInvocations = 0
    private var placedOrderRequests: [NewOrderRequest] = []

    func fetchAccount() async throws -> Account {
        accountState
    }

    func fetchPositions() async throws -> [Position] {
        positionsState
    }

    func fetchOpenOrders() async throws -> [Order] {
        openOrdersState
    }

    func fetchAsset(symbol: String) async throws -> Asset {
        Asset(
            symbol: symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
            tradable: true,
            marginable: true,
            shortable: true
        )
    }

    func fetchOptionContract(symbolOrID: String) async throws -> OptionContract {
        OptionContract(
            id: "opt-\(symbolOrID)",
            symbol: symbolOrID,
            underlyingSymbol: OptionContractSymbol.parse(symbolOrID)?.underlyingSymbol
        )
    }

    func placeOrder(request: NewOrderRequest) async throws -> Order {
        placeOrderInvocations += 1
        placedOrderRequests.append(request)
        let order = Order(
            id: "ord-pm-conversation-\(placeOrderInvocations)",
            clientOrderId: nil,
            symbol: request.symbol,
            qty: request.qty,
            side: request.side.rawValue,
            type: request.type.rawValue,
            timeInForce: request.timeInForce.rawValue,
            status: "new"
        )
        openOrdersState.append(order)
        return order
    }

    func replaceOrder(orderId: String, request: ReplaceOrderRequest) async throws -> Order {
        Order(
            id: orderId,
            symbol: "AAPL",
            qty: request.qty ?? "1",
            limitPrice: request.limitPrice,
            side: "buy",
            type: "limit",
            timeInForce: "day",
            status: "new"
        )
    }

    func cancelOrder(orderId: String) async throws {
        openOrdersState.removeAll { $0.id == orderId }
    }

    func setAccount(_ account: Account) {
        accountState = account
    }

    func placedOrders() -> [NewOrderRequest] {
        placedOrderRequests
    }

    func placeOrderCallCount() -> Int {
        placeOrderInvocations
    }
}

private actor RecordingPMConversationBarsProvider: BarsProviding {
    private let bars: [Bar]
    private var fetchInvocations = 0
    private var requestedSymbolHistory: [[String]] = []

    init(bars: [Bar]) {
        self.bars = bars
    }

    func fetchBars(
        symbols: [String],
        timeframe: BarTimeframe,
        start: Date,
        end: Date,
        limit: Int?,
        feed: ReplayFeed
    ) async throws -> [Bar] {
        _ = timeframe
        _ = start
        _ = end
        _ = limit
        _ = feed
        fetchInvocations += 1
        let normalizedSymbols = Array(MarketDataSubscriptionSet.normalized(symbols)).sorted()
        requestedSymbolHistory.append(normalizedSymbols)
        let requested = Set(normalizedSymbols)
        return bars.filter { requested.contains($0.symbol.uppercased()) }
    }

    func fetchCallCount() -> Int {
        fetchInvocations
    }

    func requestedSymbols() -> [String] {
        requestedSymbolHistory.flatMap { $0 }
    }
}

private func publishPaperPortfolioQuotes(
    store: Store,
    pricesBySymbol: [String: Double]
) async {
    for symbol in pricesBySymbol.keys.sorted() {
        guard let price = pricesBySymbol[symbol] else { continue }
        await store.publishMarketQuote(
            MarketDataQuoteEvent(
                symbol: symbol,
                bidPrice: price,
                askPrice: price,
                bidSize: 10,
                askSize: 10,
                timestamp: "2026-04-27T21:30:00Z"
            )
        )
    }
}

private func makePaperPortfolioEstablishmentModelActionPlan(
    summary: String = "Model interpreted the owner turn as approval to establish the current working paper portfolio.",
    targetApprovalRequestId: String? = nil,
    includeDecisionAndApprovalCreation: Bool = true,
    includeApproval: Bool = true,
    includeRoute: Bool = true
) -> PMConversationActionPlan {
    var actions: [PMConversationActionIntent] = []
    if includeDecisionAndApprovalCreation {
        actions.append(
            PMConversationActionIntent(
                actionType: .createPMDecision,
                summary: "Recommend establishing the current working paper portfolio through the governed paper-establishment workflow.",
                title: "PM recommendation: establish the initial paper portfolio",
                body: "The current working paper portfolio target is ready to evaluate through the governed paper-establishment workflow.",
                detail: "Approve moving the current working paper portfolio into the governed paper-establishment workflow now.",
                decisionType: .recommendation,
                requestType: .portfolioAction,
                sourceMessageIds: []
            )
        )
        actions.append(
            PMConversationActionIntent(
                actionType: .createPMApprovalRequest,
                summary: "Create the owner-facing PM ask for the current working paper-portfolio establishment.",
                title: "Review PM recommendation: establish the initial paper portfolio",
                body: "Approve establishing the current working paper portfolio through the governed paper-establishment workflow.",
                detail: "Approve moving the current working paper portfolio into the governed paper-establishment workflow now.",
                requestType: .portfolioAction,
                sourceMessageIds: []
            )
        )
    }
    if includeApproval {
        actions.append(
            PMConversationActionIntent(
                actionType: .approvePMApprovalRequest,
                summary: "Record the owner's explicit approval on the paper-portfolio establishment PM ask.",
                targetId: targetApprovalRequestId,
                sourceMessageIds: []
            )
        )
    }
    if includeRoute {
        actions.append(
            PMConversationActionIntent(
                actionType: .routeGovernedExecutionNextStep,
                summary: "Route the approved paper-portfolio establishment through the governed app-owned execution path.",
                targetId: targetApprovalRequestId,
                sourceMessageIds: []
            )
        )
    }
    return PMConversationActionPlan(summary: summary, actions: actions)
}

private actor StubPMOpenAISynthesisProvider: PMOpenAISynthesisProviding {
    let conversationResults: [Result<PMConversationOpenAISynthesisOutput, PMOpenAISynthesisError>]
    let standingReviewOutput: PMStandingReviewOpenAISynthesisOutput
    private(set) var lastConversationRequest: PMConversationOpenAISynthesisRequest?
    private(set) var conversationRequests: [PMConversationOpenAISynthesisRequest] = []
    private(set) var lastStandingReviewRequest: PMStandingReviewOpenAISynthesisRequest?
    private var nextConversationOutputIndex = 0

    init(
        conversationOutput: PMConversationOpenAISynthesisOutput,
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput
    ) {
        self.conversationResults = [.success(conversationOutput)]
        self.standingReviewOutput = standingReviewOutput
    }

    init(
        conversationOutputs: [PMConversationOpenAISynthesisOutput],
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput
    ) {
        self.conversationResults = conversationOutputs.map(Result.success)
        self.standingReviewOutput = standingReviewOutput
    }

    init(
        conversationResults: [Result<PMConversationOpenAISynthesisOutput, PMOpenAISynthesisError>],
        standingReviewOutput: PMStandingReviewOpenAISynthesisOutput
    ) {
        self.conversationResults = conversationResults
        self.standingReviewOutput = standingReviewOutput
    }

    func synthesizeConversationReply(
        request: PMConversationOpenAISynthesisRequest,
        apiKey: String
    ) async throws -> PMConversationOpenAISynthesisOutput {
        _ = apiKey
        lastConversationRequest = request
        conversationRequests.append(request)
        let index = min(nextConversationOutputIndex, max(conversationResults.count - 1, 0))
        let result = conversationResults[index]
        nextConversationOutputIndex += 1
        return try result.get()
    }

    func synthesizeStandingReview(
        request: PMStandingReviewOpenAISynthesisRequest,
        apiKey: String
    ) async throws -> PMStandingReviewOpenAISynthesisOutput {
        _ = apiKey
        lastStandingReviewRequest = request
        return standingReviewOutput
    }
}

private actor StubPMAnthropicSynthesisProvider: PMAnthropicSynthesisProviding {
    let output: PMConversationOpenAISynthesisOutput
    private(set) var lastConversationRequest: PMConversationOpenAISynthesisRequest?
    private(set) var lastAPIKey: String?

    init(output: PMConversationOpenAISynthesisOutput) {
        self.output = output
    }

    func synthesizeConversationReply(
        request: PMConversationOpenAISynthesisRequest,
        apiKey: String
    ) async throws -> PMConversationOpenAISynthesisOutput {
        lastConversationRequest = request
        lastAPIKey = apiKey
        return output
    }
}

private struct StubPMCommunicationLLMCredentialResolver: LLMCredentialResolving {
    let resolution: LLMCredentialResolution

    func resolve(profile: LLMCredentialProfile) -> LLMCredentialResolution {
        var updated = resolution
        updated.profileId = profile.profileId
        updated.providerKind = profile.providerKind
        updated.account = profile.keychainAccount
        return updated
    }
}

private actor PMConversationActionPlanLaunchRecorder {
    private(set) var requests: [AnalystWorkerLaunchRequest] = []

    var lastRequest: AnalystWorkerLaunchRequest? {
        requests.last
    }

    func record(_ request: AnalystWorkerLaunchRequest) {
        requests.append(request)
    }
}

private struct PMConversationActionPlanStubLauncher: AnalystWorkerLaunching {
    let recorder: PMConversationActionPlanLaunchRecorder
    var result: AnalystWorkerLaunchResult? = nil
    var failureReason: String? = nil

    func runOnce(request: AnalystWorkerLaunchRequest) async throws -> AnalystWorkerLaunchResult {
        await recorder.record(request)
        if let failureReason {
            throw AnalystWorkerLaunchError.workerLaunchFailed(reason: failureReason)
        }
        return result ?? AnalystWorkerLaunchResult(
            openAIKeyConfigured: true,
            usedOpenAI: false,
            charterId: request.charterId,
            taskId: request.taskId,
            delegationId: request.delegationId,
            pmId: request.pmId,
            findingId: nil,
            findingTitle: nil,
            draftedSignalId: nil,
            draftedProposalId: nil,
            summary: "Stub analyst worker launch completed.",
            outputExcerpt: "Stub launch."
        )
    }
}

private func waitForPMWorkflowStoreEvent(
    named targetName: String,
    in events: AsyncStream<StoreEvent>,
    timeoutNanoseconds: UInt64 = 1_000_000_000
) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            for await event in events {
                if event.name == targetName {
                    return true
                }
            }
            return false
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            return false
        }

        let result = await group.next() ?? false
        group.cancelAll()
        return result
    }
}

private actor ThrowingPMOpenAISynthesisProvider: PMOpenAISynthesisProviding {
    func synthesizeConversationReply(
        request _: PMConversationOpenAISynthesisRequest,
        apiKey _: String
    ) async throws -> PMConversationOpenAISynthesisOutput {
        throw PMOpenAISynthesisError.transport
    }

    func synthesizeStandingReview(
        request _: PMStandingReviewOpenAISynthesisRequest,
        apiKey _: String
    ) async throws -> PMStandingReviewOpenAISynthesisOutput {
        throw PMOpenAISynthesisError.transport
    }
}
