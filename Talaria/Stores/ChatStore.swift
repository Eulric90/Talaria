import Foundation
import UIKit
import os

private let chatLog = Logger(subsystem: "io.github.eulric90.talaria", category: "ChatStore")

@MainActor
@Observable
final class ChatStore {
    var conversation: Conversation?
    var isLoading = false
    var pendingMessageSentAt: Date?
    var lastTokenUsage: TokenUsage?

    /// Reachability of the Hermes Sessions API itself — the direct connection
    /// (localhost:8642) that actually carries chat, independent of the relay.
    /// The relay is offline by design, so the Chat screen drives its connectivity
    /// UI from this rather than relay-sourced host status (which would otherwise
    /// paint a false "offline" banner). Updated by `refreshDirectHealth()`.
    private(set) var directConnectionStatus: ConnectionStatus = .disconnected
    private var isPollingEnabled = false
    private var pollingTask: Task<Void, Never>?
    private var streamingTask: Task<Void, Never>?
    private(set) var streamingMessageID: UUID?

    var isStreaming: Bool { streamingMessageID != nil }

    /// Dynamic slash command catalog fetched from the connected Hermes host.
    /// Includes gateway commands, installed skills, custom personalities,
    /// and hidden quick-command metadata for manual slash dispatch.
    private(set) var commandCatalog: [SlashCommand] = SlashCommand.allBuiltIn

    /// Active model name from the Hermes agent config (e.g., "gpt-5.4-mini").
    private(set) var activeModelName: String?
    /// Context window size for the active model (e.g., 400000).
    private(set) var contextWindow: Int?

    var currentContextTokens: Int? {
        lastTokenUsage?.promptTokens
    }

    private let hermesClient: any HermesClientProtocol
    private let chatLiveActivity = LiveActivityService()
    private let notifications = LocalNotificationService()
    let persistence: any AppPersistenceStoreProtocol

    /// A run whose stream dropped (e.g. backgrounded on lock) but which is still
    /// running server-side. Reconciled via the Sessions messages endpoint when it
    /// completes. `sentAt` is captured here so reconcile is insulated from the
    /// relay-poll machinery that owns `pendingMessageSentAt`.
    private struct PendingRun {
        let sessionId: String
        let runId: String?
        let userMessageID: UUID
        let sentAt: Date
    }
    private var pendingRun: PendingRun?
    private var reconcileTask: Task<Void, Never>?

    /// Session id of the run awaiting reconcile, if any — what the relay's
    /// completion watcher needs to be told about (#38).
    var pendingRunSessionId: String? { pendingRun?.sessionId }

    /// Called when conversation content changes (new message, streaming complete).
    /// Used by AppContainer to push widget data updates.
    var onConversationChanged: (@MainActor () -> Void)?

    /// A run detached while the app was leaving the foreground — the in-app
    /// reconcile loop can't tick once suspended, so AppContainer hands the
    /// completion notify to the relay's APNs watcher (#38).
    var onRunDetached: (@MainActor (String) -> Void)?

    /// A previously detached run was reconciled in-app; AppContainer
    /// withdraws the relay watch so no stale push arrives.
    var onRunResolved: (@MainActor (String) -> Void)?

    init(hermesClient: any HermesClientProtocol, persistence: any AppPersistenceStoreProtocol) {
        self.hermesClient = hermesClient
        self.persistence = persistence
    }

    func loadConversationIfNeeded() async {
        if conversation == nil {
            conversation = persistence.loadConversationCache()
            if let cachedUsage = conversation?.latestUsage {
                lastTokenUsage = cachedUsage
            }
        }
        guard conversation == nil else { return }
        await loadConversation()
    }

    func loadConversation() async {
        isLoading = true
        defer { isLoading = false }
        let cachedConversation = conversation ?? persistence.loadConversationCache()
        conversation = mergeConversationMetadata(
            from: cachedConversation,
            into: await hermesClient.loadConversation()
        )
        if let latestUsage = conversation?.latestUsage {
            lastTokenUsage = latestUsage
        }
        if let conversation {
            persistence.saveConversationCache(conversation)
            onConversationChanged?()
        }
        restartPendingPollingIfNeeded()
    }

    func sendMessage(_ content: String, attachments: [PendingAttachment] = []) async {
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty || !attachments.isEmpty else { return }
        guard hasPendingDuplicateMessage(trimmedContent, attachments: attachments) == false else { return }

        let clientMessageID = UUID()
        let displayContent = trimmedContent.isEmpty && !attachments.isEmpty
            ? "[\(attachments.count) attachment\(attachments.count == 1 ? "" : "s")]"
            : trimmedContent
        let optimistic = Message(
            id: clientMessageID,
            clientMessageID: clientMessageID,
            sender: .user,
            content: displayContent,
            status: .sending,
            attachments: attachments.map { MessageAttachment(from: $0) }
        )
        if conversation == nil {
            conversation = Conversation(title: "Hermes")
        }
        conversation?.messages.append(optimistic)
        conversation?.lastActivity = optimistic.timestamp
        pendingMessageSentAt = optimistic.timestamp

        // Append a placeholder Hermes message for streaming content
        let placeholderID = UUID()
        let placeholder = Message(
            id: placeholderID,
            sender: .hermes,
            content: "",
            status: .sending,
            isStreaming: true
        )
        conversation?.messages.append(placeholder)
        streamingMessageID = placeholderID
        restartPendingPollingIfNeeded()

        Task { await self.notifications.requestAuthorizationIfNeeded() }
        let stream = hermesClient.sendStreaming(message: trimmedContent, attachments: attachments, clientMessageID: clientMessageID)
        var acceptedJobID: UUID?
        var needsPollingFallback = false

        streamingTask = Task { [weak self] in
            guard let self else { return }
            for await update in stream {
                if Task.isCancelled { break }
                switch update {
                case .messageSent(let jobID):
                    acceptedJobID = jobID

                case .textDelta(let delta):
                    if var conv = self.conversation,
                       let idx = conv.messages.firstIndex(where: { $0.id == placeholderID }) {
                        conv.messages[idx].content += delta
                        conv.messages[idx].toolActivity = nil
                        for i in conv.messages[idx].toolActivities.indices {
                            conv.messages[idx].toolActivities[i].isActive = false
                        }
                        self.conversation = conv
                    }

                case .toolActivity(let event):
                    if var conv = self.conversation,
                       let idx = conv.messages.firstIndex(where: { $0.id == placeholderID }) {
                        switch event.phase {
                        case .started:
                            // Tools run serially, so a new start resolves any
                            // still-active predecessor.
                            for i in conv.messages[idx].toolActivities.indices {
                                conv.messages[idx].toolActivities[i].isActive = false
                            }
                            // Anchor at the content streamed so far — this is
                            // what places the chip inline in the transcript (#10).
                            let activity = ToolActivity(
                                label: event.name,
                                detail: event.detail,
                                anchorOffset: conv.messages[idx].content.count
                            )
                            conv.messages[idx].toolActivities.append(activity)
                            conv.messages[idx].toolActivity = event.name
                        case .completed:
                            // tool.completed is usually empty on the wire; when
                            // it does name the tool, resolve its newest chip.
                            if let last = conv.messages[idx].toolActivities.lastIndex(where: {
                                $0.isActive && $0.label == event.name
                            }) {
                                conv.messages[idx].toolActivities[last].isActive = false
                            }
                        }
                        self.conversation = conv
                    }
                    if event.phase == .started {
                        // Show tool progress on Lock Screen / Dynamic Island
                        self.chatLiveActivity.startToolCall(toolName: event.name)
                        self.chatLiveActivity.updateToolProgress(event.name)
                    }

                case .finished(let finalMessage, let usage, let diff):
                    if let idx = self.conversation?.messages.firstIndex(where: { $0.id == placeholderID }) {
                        let activities = self.conversation?.messages[idx].toolActivities ?? []
                        var resolved = finalMessage
                        resolved.toolActivities = activities
                        resolved.codeDiff = diff
                        self.conversation?.messages[idx] = resolved
                    }
                    // The direct stream completed, so this message definitively
                    // succeeded — mark it delivered, recovering even if the relay
                    // polling fallback had already flipped it to .failed.
                    if let idx = self.conversation?.messages.firstIndex(where: { $0.id == clientMessageID }) {
                        if self.conversation?.messages[idx].status != .delivered {
                            self.conversation?.messages[idx].status = .delivered
                        }
                    }
                    self.conversation = self.mergeConversationMetadata(
                        from: self.conversation,
                        into: self.hermesClient.currentConversation
                    )
                    if let latestUsage = self.conversation?.latestUsage {
                        self.lastTokenUsage = latestUsage
                    } else if let usage {
                        self.lastTokenUsage = usage
                    }
                    self.detectModelSwitch(from: finalMessage.content)
                    self.streamingMessageID = nil
                    self.pendingMessageSentAt = nil
                    self.chatLiveActivity.endActivity()

                case .interrupted(let sessionId, let runId):
                    // Run committed server-side but the stream dropped (lock /
                    // background). Not a failure: mark the turn working and let the
                    // reconcile loop pick up the reply when it lands.
                    if let idx = self.conversation?.messages.firstIndex(where: { $0.id == placeholderID }) {
                        self.conversation?.messages.remove(at: idx)
                    }
                    if let idx = self.conversation?.messages.firstIndex(where: { $0.id == clientMessageID }) {
                        self.conversation?.messages[idx].status = .working
                    }
                    self.streamingMessageID = nil
                    self.chatLiveActivity.endActivity()
                    self.pendingRun = PendingRun(
                        sessionId: sessionId,
                        runId: runId,
                        userMessageID: clientMessageID,
                        sentAt: self.pendingMessageSentAt ?? .now
                    )
                    self.startReconcileLoopIfNeeded()
                    // Streams overwhelmingly detach because the app left the
                    // foreground (lock/background) — that's the case where only
                    // a remote push can announce completion. A rare in-app
                    // network blip also lands here; the watch is still harmless
                    // (the reconcile loop resolves first and cancels it).
                    if UIApplication.shared.applicationState != .active {
                        self.onRunDetached?(sessionId)
                    }

                case .failed(let errorMessage):
                    if let idx = self.conversation?.messages.firstIndex(where: { $0.id == placeholderID }) {
                        if acceptedJobID == nil {
                            self.conversation?.messages[idx] = Message(
                                sender: .system,
                                content: errorMessage,
                                status: .failed
                            )
                        } else {
                            self.conversation?.messages.remove(at: idx)
                        }
                    }
                    self.streamingMessageID = nil
                    self.chatLiveActivity.endActivity()
                    if let idx = self.conversation?.messages.firstIndex(where: { $0.id == clientMessageID }) {
                        self.conversation?.messages[idx].status = acceptedJobID == nil ? .failed : .sending
                    }
                    if acceptedJobID != nil {
                        needsPollingFallback = true
                    } else {
                        self.pendingMessageSentAt = nil
                    }
                }
            }
        }
        await streamingTask?.value
        streamingTask = nil

        // If streaming failed after the job was accepted, immediately refresh once
        // and then fall back to polling only if the server still hasn't delivered.
        if needsPollingFallback {
            let refreshed = await hermesClient.loadConversation()
            conversation = mergeConversationMetadata(from: conversation, into: refreshed)
            if let latestUsage = conversation?.latestUsage {
                lastTokenUsage = latestUsage
            }
            streamingMessageID = nil
            restartPendingPollingIfNeeded()
        }

        if !hasPendingMessages {
            pendingMessageSentAt = nil
        }

        if let conversation {
            persistence.saveConversationCache(conversation)
            onConversationChanged?()
        }
    }

    func clearConversation() async throws {
        reconcileTask?.cancel()
        reconcileTask = nil
        if let abandoned = pendingRun {
            onRunResolved?(abandoned.sessionId)
        }
        pendingRun = nil
        streamingTask?.cancel()
        streamingTask = nil
        streamingMessageID = nil
        chatLiveActivity.endActivity()
        let fresh = try await hermesClient.clearConversation()
        conversation = fresh
        lastTokenUsage = fresh.latestUsage
        pendingMessageSentAt = nil
        persistence.saveConversationCache(fresh)
        onConversationChanged?()
        pollingTask?.cancel()
        pollingTask = nil
    }

    func cancelStreaming() {
        streamingTask?.cancel()
        streamingTask = nil
        chatLiveActivity.endActivity()

        // Finalize current streaming message with content received so far
        if let sid = streamingMessageID,
           var conv = conversation,
           let idx = conv.messages.firstIndex(where: { $0.id == sid }) {
            conv.messages[idx].isStreaming = false
            conv.messages[idx].status = .delivered
            for i in conv.messages[idx].toolActivities.indices {
                conv.messages[idx].toolActivities[i].isActive = false
            }
            conversation = conv
        }
        streamingMessageID = nil
        pendingMessageSentAt = nil

        if let conversation {
            persistence.saveConversationCache(conversation)
            onConversationChanged?()
        }
    }

    func injectVoiceTranscript(
        voiceSessionId: UUID,
        duration: TimeInterval,
        transcriptItems: [TranscriptItem],
        voiceTranscriptSyncEnabled: Bool = true
    ) async {
        // Compose transcript messages locally — the Sessions API has no
        // inject endpoint, so the old hermesClient.injectVoiceTranscript
        // was a documented no-op. The full transcript is already on-device.
        let finalizedItems = transcriptItems.filter { !$0.isPartial }
        guard !finalizedItems.isEmpty else { return }

        if conversation == nil {
            conversation = Conversation(title: "Hermes")
        }

        // System banner
        let systemBanner = Message(
            sender: .system,
            content: "[Voice session ended]",
            voiceSessionDuration: duration
        )

        // Map transcript speakers to message senders
        let transcriptMessages: [Message] = finalizedItems.compactMap { item in
            let sender: MessageSender = switch item.speaker {
            case .user: .voiceUser
            case .hermes: .voiceHermes
            case .system: .system
            }
            let trimmed = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return Message(sender: sender, content: trimmed)
        }

        conversation?.messages.append(systemBanner)
        conversation?.messages.append(contentsOf: transcriptMessages)
        conversation?.lastActivity = systemBanner.timestamp

        if let conversation {
            persistence.saveConversationCache(conversation)
            onConversationChanged?()
        }

        // Optionally sync transcript to Sessions API as a text turn
        if voiceTranscriptSyncEnabled {
            let transcriptText = buildTranscriptText(
                transcriptItems: finalizedItems,
                duration: duration
            )
            // Non-fatal: local transcript persists even if the sync send fails.
            _ = await hermesClient.send(
                message: transcriptText,
                attachments: [],
                clientMessageID: UUID()
            )
        }
    }

    /// Builds a plain-text transcript from voice session items for delivery
    /// to the Sessions API so the agent has context for the next exchange.
    private func buildTranscriptText(
        transcriptItems: [TranscriptItem],
        duration: TimeInterval
    ) -> String {
        let minutes = Int(duration) / 60
        let secs = Int(duration) % 60
        var lines = ["[Voice session ended — \(minutes):\(String(format: "%02d", secs))]"]
        for item in transcriptItems {
            let speaker = switch item.speaker {
            case .user: "User"
            case .hermes: "Hermes"
            case .system: "System"
            }
            lines.append("\(speaker): \(item.text)")
        }
        return lines.joined(separator: "\n\n")
    }

    func exportConversationToFile() {
        guard let conversation else { return }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: Date())
        let filename = "hermes_conversation_\(timestamp).json"

        let exportData: [String: Any] = [
            "title": conversation.title,
            "sessionId": conversation.id.uuidString,
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "messageCount": conversation.messages.count,
            "messages": conversation.messages.map { msg in
                [
                    "role": msg.sender.rawValue,
                    "content": msg.content,
                    "timestamp": ISO8601DateFormatter().string(from: msg.timestamp),
                ] as [String: String]
            },
        ]

        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let fileURL = dir.appendingPathComponent(filename)

        do {
            let data = try JSONSerialization.data(withJSONObject: exportData, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: fileURL)
            // Append a system message confirming the save (caller handles this)
        } catch {
            // Export failed silently — caller can check
        }
    }

    func setConversationTitle(_ title: String) {
        conversation?.title = title
        if let conversation {
            persistence.saveConversationCache(conversation)
            onConversationChanged?()
        }
    }

    func retryMessage(_ message: Message) async {
        // Remove the failed message
        conversation?.messages.removeAll { $0.id == message.id }

        // Determine the user content to retry (attachments can't be recovered from metadata)
        let sourceMessage: Message?
        if message.sender == .user {
            sourceMessage = message
        } else {
            sourceMessage = conversation?.messages.last(where: { $0.sender == .user })
        }

        guard let sourceMessage else { return }
        let attachments = sourceMessage.attachments.compactMap(PendingAttachment.restore)
        let content = normalizedRetryContent(for: sourceMessage)
        guard !content.isEmpty || !attachments.isEmpty else { return }

        await sendMessage(content, attachments: attachments)
    }

    func setPollingEnabled(_ isEnabled: Bool) {
        isPollingEnabled = isEnabled
        if isEnabled {
            restartPendingPollingIfNeeded()
        } else {
            pollingTask?.cancel()
            pollingTask = nil
        }
    }

    // MARK: - Direct Sessions API health

    /// Probes the direct Sessions API (`/v1/models`, via the client's `connect()`)
    /// and records the outcome in `directConnectionStatus`. The probe creates no
    /// chat session and has no side effect beyond the status. While a response is
    /// actively streaming the connection is, by definition, live, so we skip the
    /// probe and report `.connected`.
    func refreshDirectHealth() async {
        guard !isStreaming else {
            directConnectionStatus = .connected
            return
        }
        await hermesClient.connect()
        directConnectionStatus = hermesClient.connectionStatus
    }

    // MARK: - Model controls

    /// Model identifiers exposed by the connected host. Returns [] when the host
    /// is unreachable so callers can fall back to placeholder options.
    func availableModels() async -> [String] {
        (try? await hermesClient.availableModels()) ?? []
    }

    /// Switches the active model. Applies to the NEXT session (the Hermes agent
    /// dispatches `/model` as a command turn), so start a new chat for it to take
    /// effect. Updates the displayed model immediately for toolbar feedback.
    ///
    /// The CTX denominator reconciles against the host's `/model` response
    /// ("Context: N tokens") — Hermes's own number for the switched model. It is
    /// NEVER seeded from the client-side nominal table here; that table stays a
    /// read-time display fallback only (resolvedContextWindow), because its
    /// nominal windows run ~1.4x above Hermes's effective ones (#4).
    @discardableResult
    func selectModel(_ identifier: String) async -> Bool {
        do {
            let responseText = try await hermesClient.switchModel(identifier)
            activeModelName = identifier
            updateContextWindow(
                responseText.flatMap(Self.reportedContextWindow(in:)),
                source: "model-switch response"
            )
            return true
        } catch {
            return false
        }
    }

    // MARK: - Sessions

    /// Recent sessions from the host. Returns [] when unreachable.
    func loadSessions() async -> [HermesSessionInfo] {
        do {
            let sessions = try await hermesClient.listSessions()
            chatLog.verbose("loadSessions: got \(sessions.count) sessions")
            return sessions
        } catch {
            chatLog.error("loadSessions: FAILED — \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Opens an existing session: loads its history and continues that thread.
    func openSession(_ id: String) async {
        chatLog.verbose("openSession: opening '\(id)'")
        streamingTask?.cancel()
        streamingTask = nil
        streamingMessageID = nil
        chatLiveActivity.endActivity()
        pollingTask?.cancel()
        pollingTask = nil
        do {
            let convo = try await hermesClient.openSession(id)
            conversation = convo
            lastTokenUsage = convo.latestUsage
            pendingMessageSentAt = nil
            persistence.saveConversationCache(convo)
            onConversationChanged?()
            chatLog.verbose("openSession: loaded \(convo.messages.count) messages for '\(id)'")
        } catch {
            chatLog.error("openSession: FAILED for '\(id, privacy: .public)' — \(error.localizedDescription, privacy: .public)")
        }
    }

    func replaceCommandCatalog(_ catalog: [SlashCommand], activeModel: String? = nil, contextWindow: Int? = nil) {
        commandCatalog = catalog.isEmpty ? SlashCommand.allBuiltIn : catalog
        if let activeModel { activeModelName = activeModel }
        if let contextWindow { updateContextWindow(contextWindow, source: "command catalog") }
    }

    func resetCommandCatalog() {
        commandCatalog = SlashCommand.allBuiltIn
        activeModelName = nil
        updateContextWindow(nil, source: "catalog reset")
    }

    /// Drops back to the built-in command list WITHOUT discarding the active
    /// model or its Hermes-reported context window. Used when a catalog refresh
    /// merely failed (the relay is offline by design much of the time) — a
    /// transient fetch failure must not demote the CTX denominator from a
    /// Hermes-reported value to the nominal client-side table (#4).
    func restoreBuiltInCatalog() {
        commandCatalog = SlashCommand.allBuiltIn
    }

    func reset() {
        pollingTask?.cancel()
        pollingTask = nil
        isPollingEnabled = false
        resetCommandCatalog()
        conversation = nil
        isLoading = false
        pendingMessageSentAt = nil
        lastTokenUsage = nil
        persistence.clearConversationCache()
    }

    func resolvedContextWindow(fallbackModelName: String?) -> Int? {
        contextWindow ?? Self.inferredContextWindow(for: fallbackModelName)
    }

    private var hasPendingMessages: Bool {
        conversation?.messages.contains(where: { $0.sender == .user && $0.status == .sending }) == true
    }

    private func hasPendingDuplicateMessage(_ content: String, attachments: [PendingAttachment]) -> Bool {
        conversation?.messages.contains(where: {
            $0.sender == .user
                && $0.status == .sending
                && normalizedRetryContent(for: $0) == content
                && attachmentSignature(for: $0.attachments) == attachmentSignature(for: attachments.map { MessageAttachment(from: $0) })
        }) == true
    }

    private static let maxPollAttempts = 30 // 30 × 2s = 60 seconds max

    private func restartPendingPollingIfNeeded() {
        guard isPollingEnabled, hasPendingMessages else {
            pollingTask?.cancel()
            pollingTask = nil
            return
        }

        guard pollingTask == nil else { return }

        pollingTask = Task { [weak self] in
            guard let self else { return }
            var attempts = 0

            while !Task.isCancelled, attempts < Self.maxPollAttempts {
                attempts += 1
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { break }
                let fresh = await self.hermesClient.loadConversation()
                self.conversation = self.mergeConversationMetadata(from: self.conversation, into: fresh)
                if let latestUsage = self.conversation?.latestUsage {
                    self.lastTokenUsage = latestUsage
                }
                if let conversation = self.conversation {
                    self.persistence.saveConversationCache(conversation)
                    self.onConversationChanged?()
                }
                if self.hasPendingMessages == false {
                    self.pendingMessageSentAt = nil
                    break
                }
            }

            // If we exhausted attempts, mark stuck messages as failed — but only
            // when no direct stream is still in flight. A tool-heavy turn can run
            // past the 60s poll window, and the stream (not the relay) is the
            // authority on delivery, so we must not preempt it with a false failure.
            if attempts >= Self.maxPollAttempts, self.hasPendingMessages, self.streamingMessageID == nil {
                if var conv = self.conversation {
                    for i in conv.messages.indices where conv.messages[i].sender == .user && conv.messages[i].status == .sending {
                        conv.messages[i].status = .failed
                    }
                    self.conversation = conv
                    self.persistence.saveConversationCache(conv)
                }
                self.pendingMessageSentAt = nil
            }

            if self.pollingTask?.isCancelled == false {
                self.pollingTask = nil
            }
        }
    }

    /// Re-attaches transient streaming artifacts (tool timeline, code diff) onto the
    /// canonical conversation that the relay returned, since the relay knows nothing
    /// about those client-only fields.
    // MARK: - Interrupted-run reconcile (Phase 1)

    /// Called on app foreground to catch a run that finished while the app was
    /// suspended and the in-app loop couldn't tick.
    func reconcilePendingRuns() async {
        guard let pending = pendingRun else { return }
        if await attemptReconcile(pending) == false {
            startReconcileLoopIfNeeded()
        }
    }

    private func startReconcileLoopIfNeeded() {
        guard reconcileTask == nil, pendingRun != nil else { return }
        reconcileTask = Task { [weak self] in
            guard let self else { return }
            var attempts = 0
            let maxAttempts = 60 // 60 x 2s = ~2 min, the background-run ceiling
            while !Task.isCancelled, attempts < maxAttempts {
                attempts += 1
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let pending = self.pendingRun else { break }
                if await self.attemptReconcile(pending) { break }
            }
            self.reconcileTask = nil
        }
    }

    /// One reconcile pass: fetch the server's view of the session; if the
    /// assistant reply landed after the run started, adopt it, notify, and clear
    /// the pending run. Returns true when resolved.
    @discardableResult
    private func attemptReconcile(_ pending: PendingRun) async -> Bool {
        guard let serverConvo = await hermesClient.reconcileFromServer() else { return false }
        let reply = serverConvo.messages.last(where: {
            $0.sender == .hermes
                && $0.timestamp > pending.sentAt
                && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })
        guard let reply else { return false }

        conversation = mergeConversationMetadata(from: conversation, into: serverConvo)
        if let latestUsage = conversation?.latestUsage {
            lastTokenUsage = latestUsage
        }
        pendingRun = nil
        pendingMessageSentAt = nil
        onRunResolved?(pending.sessionId)
        if let conversation {
            persistence.saveConversationCache(conversation)
            onConversationChanged?()
        }
        if UIApplication.shared.applicationState != .active {
            notifications.notifyRunCompleted(preview: reply.content)
        }
        return true
    }

    private func mergeConversationMetadata(
        from localConversation: Conversation?,
        into refreshedConversation: Conversation?
    ) -> Conversation? {
        guard var refreshedConversation else { return localConversation }
        guard let localConversation else { return refreshedConversation }

        if refreshedConversation.latestUsage == nil {
            refreshedConversation.latestUsage = localConversation.latestUsage
        }

        for index in refreshedConversation.messages.indices {
            let remote = refreshedConversation.messages[index]

            // Prefer exact UUID match (works when the relay echoes back the same ID).
            let local: Message?
            if let byID = localConversation.messages.first(where: { $0.id == remote.id }) {
                local = byID
            } else if let remoteClientMessageID = remote.clientMessageID {
                local = localConversation.messages.first(where: {
                    $0.id == remoteClientMessageID || $0.clientMessageID == remoteClientMessageID
                })
            } else if let remoteJobID = remote.jobID {
                // Fallback: the streaming placeholder had a client-generated UUID that
                // differs from the server-assigned message ID.  Match on jobID + sender
                // instead, but only for Hermes messages that actually carry artifacts.
                local = localConversation.messages.first(where: {
                    $0.jobID == remoteJobID
                        && $0.sender == remote.sender
                        && $0.sender == .hermes
                        && (!$0.toolActivities.isEmpty || $0.codeDiff != nil)
                })
            } else {
                local = nil
            }

            guard let local else { continue }

            if !local.toolActivities.isEmpty {
                refreshedConversation.messages[index].toolActivities = local.toolActivities
                refreshedConversation.messages[index].toolActivity = local.toolActivity
            }

            if let diff = local.codeDiff, refreshedConversation.messages[index].codeDiff == nil {
                refreshedConversation.messages[index].codeDiff = diff
            }

            if !local.attachments.isEmpty {
                refreshedConversation.messages[index].attachments = mergeAttachments(
                    local.attachments,
                    onto: refreshedConversation.messages[index].attachments
                )
            }
        }

        // Preserve any local message the relay hasn't echoed back yet — not just
        // streaming placeholders, but also just-sent user messages still in flight.
        // The relay assigns its own message IDs, so a local message is "confirmed"
        // only if the refreshed conversation contains it by id OR by clientMessageID.
        // Anything unconfirmed must survive the merge, otherwise a sent message
        // vanishes the instant the first poll/refresh returns without it.
        let refreshedIDs = Set(refreshedConversation.messages.map(\.id))
        let refreshedClientIDs = Set(refreshedConversation.messages.compactMap(\.clientMessageID))
        let localIDs = Set(localConversation.messages.map(\.id))
        let unconfirmedLocals = localConversation.messages.filter { local in
            if refreshedIDs.contains(local.id) { return false }
            if let clientID = local.clientMessageID, refreshedClientIDs.contains(clientID) { return false }
            // The Sessions API assigns its own message IDs and never echoes
            // clientMessageID back, so an in-flight optimistic user message can
            // only ever be confirmed by content: a remote user copy that didn't
            // identity-match some other local message supersedes it. Without
            // this, the .sending duplicate outlives every refresh and lands
            // after the recovered reply (or gets falsely marked failed).
            if local.sender == .user, local.status == .sending,
               refreshedConversation.messages.contains(where: { remote in
                   remote.sender == .user
                       && remote.clientMessageID == nil
                       && remote.content == local.content
                       && !localIDs.contains(remote.id)
               }) {
                return false
            }
            return true
        }
        refreshedConversation.messages.append(contentsOf: unconfirmedLocals)

        return refreshedConversation
    }

    private func mergeAttachments(_ localAttachments: [MessageAttachment], onto remoteAttachments: [MessageAttachment]) -> [MessageAttachment] {
        guard !remoteAttachments.isEmpty else { return localAttachments }

        return remoteAttachments.enumerated().map { index, remote in
            let match = localAttachments.first(where: {
                $0.fileName == remote.fileName && $0.mimeType == remote.mimeType
            }) ?? localAttachments[safe: index]
            guard let match else { return remote }
            return MessageAttachment(
                id: remote.id,
                kind: remote.kind,
                fileName: remote.fileName,
                mimeType: remote.mimeType,
                thumbnailBase64: remote.thumbnailBase64 ?? match.thumbnailBase64,
                localStoragePath: match.localStoragePath
            )
        }
    }

    private func normalizedRetryContent(for message: Message) -> String {
        if !message.attachments.isEmpty,
           message.content.range(of: #"^\[\d+ attachment"#, options: .regularExpression) != nil {
            return ""
        }
        return message.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func attachmentSignature(for attachments: [MessageAttachment]) -> String {
        attachments
            .map { "\($0.kind)|\($0.fileName)|\($0.mimeType)" }
            .sorted()
            .joined(separator: "||")
    }

    // MARK: - Model Switch Detection

    /// Detect a model switch from the agent's response text.
    /// Updates activeModelName and contextWindow immediately so the
    /// toolbar chip reflects the change in the same render frame.
    // Regex for context window in /model response: "Context: 1,000,000 tokens"
    nonisolated(unsafe) private static let contextWindowPattern = /Context:\s*([\d,]+)\s*tokens/

    /// Extracts the Hermes-reported context window from a `/model` response
    /// ("Context: 262,144 tokens"). This is the authoritative denominator
    /// source for the CTX meter (#4). Nil when the response carries none.
    nonisolated static func reportedContextWindow(in text: String) -> Int? {
        guard let match = text.firstMatch(of: contextWindowPattern) else { return nil }
        let raw = String(match.1).replacingOccurrences(of: ",", with: "")
        guard let value = Int(raw), value > 0 else { return nil }
        return value
    }

    /// Single write path for the CTX denominator, logging every change with its
    /// source so a wrong meter reading is a one-line log read (#4 acceptance).
    private func updateContextWindow(_ value: Int?, source: String) {
        guard value != contextWindow else { return }
        contextWindow = value
        if let value {
            chatLog.notice("contextWindow ← \(value) [\(source, privacy: .public)]")
        } else {
            chatLog.notice("contextWindow ← nil [\(source, privacy: .public)] — display falls back to inferred table")
        }
    }

    private func detectModelSwitch(from text: String) {
        // Match: "Model switched to `claude-sonnet-4-6`" or "Model switched: gpt-4-turbo"
        // Model ids can be slashed (e.g. "anthropic/claude-opus-4.8" from the nous
        // portal), so the capture class must include `/`. Inside a `/.../` regex
        // literal the slash is escaped as `\/`. Keep `-` last so it stays literal.
        let patterns: [Regex<(Substring, Substring)>] = [
            /[Mm]odel\s+switched\s+to\s+`?([A-Za-z0-9._\/-]+)`?/,
            /[Mm]odel\s+switched:\s+`?([A-Za-z0-9._\/-]+)`?/,
        ]
        for pattern in patterns {
            if let match = text.firstMatch(of: pattern) {
                let newModel = String(match.1)
                activeModelName = newModel

                // v0.8.0: the /model response includes "Context: N tokens"
                // — parse it directly instead of relying on a heuristic table.
                // If absent, clear and let the next catalog refresh resolve it.
                updateContextWindow(
                    Self.reportedContextWindow(in: text),
                    source: "chat /model response"
                )
                return
            }
        }
    }

    /// Fallback-only lookup for cases where the connector has not yet provided
    /// an explicit context window. This should never overwrite a known value.
    static func inferredContextWindow(for modelName: String?) -> Int? {
        guard let modelName, !modelName.isEmpty else { return nil }
        let n = modelName.lowercased()

        if n.contains("claude-opus-4-6") || n.contains("claude-opus-4.6")
            || n.contains("claude-sonnet-4-6") || n.contains("claude-sonnet-4.6") {
            return 1_000_000
        }
        if n.contains("claude") { return 200_000 }
        if n.contains("gpt-4.1") { return 1_047_576 }
        if n.contains("gpt-5") { return 128_000 }
        if n.contains("gpt-4") { return 128_000 }
        if n.contains("gemini") { return 1_048_576 }
        if n.contains("gemma-4-31b") || n.contains("gemma-4-26b") { return 256_000 }
        if n.contains("gemma-3") { return 131_072 }
        if n.contains("gemma") { return 8_192 }
        if n.contains("deepseek") { return 128_000 }
        if n.contains("llama") { return 131_072 }
        if n.contains("qwen") { return 131_072 }
        if n.contains("minimax") { return 204_800 }
        if n.contains("glm") { return 202_752 }
        if n.contains("kimi") { return 262_144 }
        if n.contains("mimo-v2-pro") || n.contains("mimo-v2-omni") { return 1_048_576 }
        return 128_000
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
