import Foundation
import os

/// Talks directly to the Hermes API server's Sessions API (default :8642).
///
/// Replaces the relay → connector → Hermes-CLI pipe for chat. Responses are
/// structured JSON / SSE, so they carry no ANSI codes and keep reasoning in a
/// separate channel. Relay/connector are still used for sensors and pairing.
@MainActor
final class SessionsHermesClient: HermesClientProtocol {
    private static let logger = Logger(subsystem: "io.github.eulric90.talaria", category: "SessionsHermesClient")
    private static let modelsPath = "/v1/models"
    private static let modelOptionsPath = "/api/model/options"
    private static let sessionsPath = "/api/sessions"

    var connectionStatus: ConnectionStatus = .disconnected
    var currentConversation: Conversation?

    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let baseURLProvider: @MainActor () -> String?
    private let apiKeyProvider: @MainActor () -> String?

    /// The current Hermes Sessions API session id (e.g. "api_…"). Distinct from
    /// `currentConversation.id`, which is the client-side UUID used by the chat UI.
    private var apiSessionId: String?

    init(
        baseURLProvider: @escaping @MainActor () -> String?,
        apiKeyProvider: @escaping @MainActor () -> String?,
        session: URLSession = .shared
    ) {
        self.baseURLProvider = baseURLProvider
        self.apiKeyProvider = apiKeyProvider
        self.session = session
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    // MARK: - HermesClientProtocol

    func connect() async {
        connectionStatus = .connecting
        do {
            let _: ModelsResponse = try await getJSON(path: Self.modelsPath)
            connectionStatus = .connected
        } catch {
            Self.logger.warning("Sessions API /v1/models failed: \(error.localizedDescription)")
            connectionStatus = .error
        }
    }

    func disconnect() async {
        apiSessionId = nil
        connectionStatus = .disconnected
    }

    func send(
        message: String,
        attachments: [PendingAttachment] = [],
        clientMessageID: UUID
    ) async -> Message {
        do {
            let sessionId = try await ensureSession()
            let path = "\(Self.sessionsPath)/\(sessionId)/chat"
            let response: SyncChatResponse = try await postJSON(
                path: path,
                body: ChatTurnBody.make(message: message, attachments: attachments)
            )
            connectionStatus = .connected
            let content = response.message?.content ?? response.content ?? ""
            return Message(
                sender: .hermes,
                content: content,
                status: .delivered
            )
        } catch {
            connectionStatus = .error
            return Message(
                sender: .system,
                content: failureMessage(for: error),
                status: .failed
            )
        }
    }

    func sendStreaming(
        message content: String,
        attachments: [PendingAttachment] = [],
        clientMessageID: UUID
    ) -> AsyncStream<StreamingUpdate> {
        AsyncStream { continuation in
            Task { @MainActor [weak self] in
                guard let self else {
                    continuation.yield(.failed("Client deallocated"))
                    continuation.finish()
                    return
                }

                var capturedSessionId = ""
                var runId: String?
                var runStarted = false
                do {
                    let sessionId = try await self.ensureSession()
                    capturedSessionId = sessionId
                    let path = "\(Self.sessionsPath)/\(sessionId)/chat/stream"
                    let body = try self.encoder.encode(ChatTurnBody.make(message: content, attachments: attachments))
                    let request = try self.makeRequest(path: path, method: "POST", body: body, accept: "text/event-stream")

                    let (bytes, response) = try await self.session.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse,
                          (200 ..< 300).contains(httpResponse.statusCode) else {
                        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                        self.connectionStatus = .error
                        continuation.yield(.failed("Hermes API returned status \(code)."))
                        continuation.finish()
                        return
                    }

                    self.connectionStatus = .connected

                    var currentEvent = "message"
                    var currentData = ""
                    var assembledContent = ""
                    var finalMessageDelivered = false
                    var pendingFinalMessage: Message?
                    // #21 Tier 1: files the agent writes are streamed inline on
                    // `tool.started`; reconstruct them and attach to the final message.
                    var producedFiles: [MessageAttachment] = []

                    func dispatchEvent() {
                        defer {
                            currentEvent = "message"
                            currentData = ""
                        }
                        guard !currentData.isEmpty else { return }
                        switch currentEvent {
                        case "run.started":
                            runStarted = true
                            if let rid = self.decodeJSONString(currentData, key: "run_id") {
                                runId = rid
                            }
                        case "assistant.delta":
                            if let delta = self.decodeJSONString(currentData, key: "delta"),
                               !delta.isEmpty {
                                assembledContent += delta
                                continuation.yield(.textDelta(delta))
                            }
                        case "tool.started", "tool.completed":
                            // #11: `tool.started` carries name + args + preview;
                            // `tool.completed` is usually empty (no result payload
                            // today — verified against the live host), so it only
                            // yields when the server names the finished tool.
                            if let event = self.parseToolCallEvent(
                                currentData,
                                phase: currentEvent == "tool.started" ? .started : .completed
                            ) {
                                continuation.yield(.toolActivity(event))
                            }
                            // #21 Tier 1: a write surfaces only on `tool.started`,
                            // carrying the bytes inline. `tool.completed` is empty.
                            if currentEvent == "tool.started",
                               let file = self.parseWrittenFile(currentData) {
                                producedFiles.append(file)
                            }
                        case "tool.progress":
                            // Reasoning chunks ride on `_thinking`; drop them in
                            // Phase 1 (the disclosure UI is Phase 2 work).
                            break
                        case "assistant.completed":
                            // Streaming returns an empty final_response (text already
                            // streamed via assistant.delta), so the server sends content:"".
                            // Empty string is non-nil, so `?? assembledContent` won't fire;
                            // fall back to the assembled deltas when content is blank.
                            let declared = self.decodeJSONString(currentData, key: "content")
                            let finalContent = (declared?.isEmpty == false) ? declared! : assembledContent
                            pendingFinalMessage = Message(
                                sender: .hermes,
                                content: finalContent,
                                status: .delivered
                            )
                            // Defer `.finished` until run.completed delivers token usage.
                        case "run.completed":
                            let usage = self.decodeRunUsage(currentData)
                            var message = pendingFinalMessage
                                ?? Message(sender: .hermes, content: assembledContent, status: .delivered)
                            if !producedFiles.isEmpty { message.attachments = producedFiles }
                            continuation.yield(.finished(message, usage, nil))
                            finalMessageDelivered = true
                        case "done":
                            break
                        default:
                            break
                        }
                    }

                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        if line.hasPrefix(":") { continue }
                        if line.isEmpty {
                            dispatchEvent()
                            continue
                        }
                        if line.hasPrefix("event:") {
                            // URLSession's bytes.lines swallows the blank lines that
                            // separate SSE events, so the `line.isEmpty` dispatch above
                            // never fires. Flush the previous event when a new one begins.
                            if !currentData.isEmpty { dispatchEvent() }
                            currentEvent = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                        } else if line.hasPrefix("data:") {
                            let value = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                            if currentData.isEmpty {
                                currentData = value
                            } else {
                                currentData += "\n" + value
                            }
                        }
                    }

                    // Flush any pending event the server didn't terminate with a blank line.
                    if !currentData.isEmpty { dispatchEvent() }

                    if !finalMessageDelivered {
                        var fallbackMessage = pendingFinalMessage ?? Message(
                            sender: .hermes,
                            content: assembledContent,
                            status: .delivered
                        )
                        if !producedFiles.isEmpty { fallbackMessage.attachments = producedFiles }
                        continuation.yield(.finished(fallbackMessage, nil, nil))
                    }
                    continuation.finish()
                } catch {
                    self.connectionStatus = .error
                    Self.logger.warning("Sessions API stream failed: \(error.localizedDescription)")
                    if runStarted {
                        // Run committed server-side; a dropped stream (e.g. the app
                        // suspended on lock) is recoverable, not a failure.
                        continuation.yield(.interrupted(sessionId: capturedSessionId, runId: runId))
                    } else {
                        continuation.yield(.failed(self.failureMessage(for: error)))
                    }
                    continuation.finish()
                }
            }
        }
    }

    func loadConversation() async -> Conversation {
        if let currentConversation { return currentConversation }
        let fresh = Conversation(title: "Hermes")
        currentConversation = fresh
        return fresh
    }

    /// Re-fetches the active session's messages from the host so an interrupted
    /// run can be reconciled. Reuses openSession's GET /messages + mapping.
    func reconcileFromServer() async -> Conversation? {
        guard let id = apiSessionId else { return nil }
        return try? await openSession(id)
    }

    func clearConversation() async throws -> Conversation {
        apiSessionId = nil
        let fresh = Conversation(title: "Hermes")
        currentConversation = fresh
        return fresh
    }

    func injectVoiceTranscript(voiceSessionId: UUID) async throws -> Conversation {
        // Voice transcript injection is a relay-side concept. The Sessions API
        // doesn't expose an equivalent endpoint, so leave the local conversation
        // untouched and let callers decide how to surface this.
        if let currentConversation { return currentConversation }
        let fresh = Conversation(title: "Hermes")
        currentConversation = fresh
        return fresh
    }

    // MARK: - Model controls

    /// Lists switchable model identifiers from the host's /api/model/options.
    func availableModels() async throws -> [String] {
        // The OpenAI-compatible /v1/models endpoint reports only the Hermes
        // agent itself as a single pseudo-model ("hermes-agent"). The real list
        // of switchable models lives at /api/model/options (provider-grouped —
        // the same source `hermes model` uses). Flatten the authenticated
        // providers' models into a de-duplicated, ordered id list.
        let response: ModelOptionsResponse = try await getJSON(path: Self.modelOptionsPath)
        var ids: [String] = []
        var seen = Set<String>()
        for provider in response.providers where provider.authenticated == true {
            for model in provider.models ?? [] where !model.isEmpty {
                if seen.insert(model).inserted { ids.append(model) }
            }
        }
        return ids
    }

    // MARK: - Session lifecycle

    /// Switches the active model for the NEXT session. The Hermes agent
    /// dispatches `/model …` as a command turn; the chosen model applies once a
    /// fresh session is created. Returns the response text — it carries the
    /// authoritative "Context: N tokens" for the switched model, which the
    /// CTX meter's denominator reconciles against (#4).
    @discardableResult
    func switchModel(_ identifier: String) async throws -> String? {
        let sessionId = try await ensureSession()
        let path = "\(Self.sessionsPath)/\(sessionId)/chat"
        let response: SyncChatResponse = try await postJSON(
            path: path,
            body: ChatTurnBody.make(message: "/model \(identifier)", attachments: [])
        )
        return response.message?.content ?? response.content
    }

    // MARK: - Sessions list / open

    func listSessions() async throws -> [HermesSessionInfo] {
        let path = "\(Self.sessionsPath)?limit=50&order=recent&min_messages=1"
        let request = try makeRequest(path: path, method: "GET", body: nil, accept: "application/json")
        let (data, httpResponse) = try await session.data(for: request)
        try ensureSuccess(response: httpResponse, data: data)
        let response: SessionsListResponse
        do {
            response = try decoder.decode(SessionsListResponse.self, from: data)
        } catch {
            let snippet = String(data: data.prefix(500), encoding: .utf8) ?? "(binary)"
            Self.logger.error("listSessions: decode FAILED — \(error.localizedDescription, privacy: .public). Raw: \(snippet, privacy: .public)")
            throw error
        }
        Self.logger.verbose("listSessions: decoded \(response.data.count) rows")
        return response.data.map { row in
            HermesSessionInfo(
                id: row.id,
                title: row.title,
                preview: row.preview,
                model: row.model,
                source: row.source,
                messageCount: row.messageCount ?? 0,
                lastActive: row.lastActive.map { Date(timeIntervalSince1970: $0) },
                isActive: row.isActive ?? false
            )
        }
    }

    /// Adopts `id` as the active session and returns its full history. New
    /// messages then continue that thread (see ensureSession()).
    func openSession(_ id: String) async throws -> Conversation {
        let path = "\(Self.sessionsPath)/\(id)/messages"
        let request = try makeRequest(path: path, method: "GET", body: nil, accept: "application/json")
        let (data, httpResponse) = try await session.data(for: request)
        try ensureSuccess(response: httpResponse, data: data)
        let response: SessionMessagesResponse
        do {
            response = try decoder.decode(SessionMessagesResponse.self, from: data)
        } catch {
            let snippet = String(data: data.prefix(500), encoding: .utf8) ?? "(binary)"
            Self.logger.error("openSession: decode FAILED for '\(id, privacy: .public)' — \(error.localizedDescription, privacy: .public). Raw: \(snippet, privacy: .public)")
            throw error
        }
        Self.logger.verbose("openSession: decoded \(response.data.count) messages for '\(id)'")
        apiSessionId = response.sessionId ?? id
        let messages = response.data.compactMap(Self.mapStoredMessage)
        let convo = Conversation(
            title: "Hermes",
            messages: messages,
            lastActivity: messages.last?.timestamp ?? .now
        )
        currentConversation = convo
        connectionStatus = .connected
        return convo
    }

    nonisolated private static func mapStoredMessage(_ m: SessionMessagesResponse.StoredMessage) -> Message? {
        let sender: MessageSender
        switch (m.role ?? "").lowercased() {
        case "user": sender = .user
        case "assistant": sender = .hermes
        default: return nil   // skip system / tool / other roles
        }
        let text = (m.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let ts = m.timestamp.map { Date(timeIntervalSince1970: $0) } ?? .now

        // #10: restore the tool timeline when the API includes tool_calls on
        // an assistant row. The stored transcript carries no position data, so
        // reloaded chips anchor at the head of the message (offset 0).
        let activities: [ToolActivity]
        if sender == .hermes {
            activities = m.toolCalls.compactMap { call in
                guard let name = call.name, !name.isEmpty, name != "_thinking" else { return nil }
                return ToolActivity(label: name, startedAt: ts, isActive: false, detail: call.detail)
            }
        } else {
            activities = []
        }

        // An assistant row can be tool-calls-only (the text lands on a later
        // row) — keep it so the chips survive history reload.
        guard !text.isEmpty || !activities.isEmpty else { return nil }
        return Message(
            sender: sender,
            content: text,
            timestamp: ts,
            status: .delivered,
            toolActivities: activities
        )
    }

    private func ensureSession() async throws -> String {
        if let apiSessionId { return apiSessionId }
        let response: CreateSessionResponse = try await postJSON(
            path: Self.sessionsPath,
            body: EmptyBody()
        )
        apiSessionId = response.session.id
        if currentConversation == nil {
            currentConversation = Conversation(title: "Hermes")
        }
        return response.session.id
    }

    // MARK: - HTTP plumbing

    private func getJSON<T: Decodable>(path: String) async throws -> T {
        let request = try makeRequest(path: path, method: "GET", body: nil, accept: "application/json")
        let (data, response) = try await session.data(for: request)
        try ensureSuccess(response: response, data: data)
        return try decoder.decode(T.self, from: data)
    }

    private func postJSON<Body: Encodable, T: Decodable>(path: String, body: Body) async throws -> T {
        let encodedBody = try encoder.encode(body)
        let request = try makeRequest(path: path, method: "POST", body: encodedBody, accept: "application/json")
        let (data, response) = try await session.data(for: request)
        try ensureSuccess(response: response, data: data)
        return try decoder.decode(T.self, from: data)
    }

    private func makeRequest(path: String, method: String, body: Data?, accept: String) throws -> URLRequest {
        guard let baseURL = baseURLProvider()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !baseURL.isEmpty,
              let url = URL(string: normalizedBaseURL(baseURL) + path) else {
            throw SessionsClientError.notConfigured("Hermes API base URL is not set.")
        }
        guard let apiKey = apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty else {
            throw SessionsClientError.notConfigured("Hermes API key is not set.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.httpBody = body
        request.timeoutInterval = 300
        return request
    }

    private func normalizedBaseURL(_ raw: String) -> String {
        var trimmed = raw
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }

    private func ensureSuccess(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SessionsClientError.requestFailed("Hermes API returned an invalid response.")
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let bodySnippet = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw SessionsClientError.requestFailed(
                "Hermes API returned status \(httpResponse.statusCode). \(bodySnippet)"
            )
        }
    }

    nonisolated private func decodeJSONString(_ raw: String, key: String) -> String? {
        guard let data = raw.data(using: .utf8) else { return nil }
        if let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            return dict[key] as? String
        }
        return nil
    }

    /// #11: builds a `ToolCallEvent` from a `tool.started` / `tool.completed`
    /// payload (`{tool_name, args:{…}, preview}`). `_thinking` is the reasoning
    /// channel, never a tool call. Returns nil when no tool name is present —
    /// the norm for `tool.completed`, whose payload is empty on the wire today.
    nonisolated private func parseToolCallEvent(_ raw: String, phase: ToolCallEvent.Phase) -> ToolCallEvent? {
        guard let data = raw.data(using: .utf8),
              let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let name = payload["tool_name"] as? String,
              !name.isEmpty,
              name != "_thinking"
        else { return nil }
        guard phase == .started else {
            return ToolCallEvent(name: name, phase: .completed)
        }
        return ToolCallEvent(name: name, phase: .started, detail: Self.toolCallDetail(from: payload))
    }

    /// Compact single-line input summary for a tool chip (#11): the server's
    /// `preview` when present, else up to three `args` entries with long values
    /// elided so the collapsed chip stays phone-sized.
    nonisolated private static func toolCallDetail(from payload: [String: Any]) -> String? {
        if let preview = payload["preview"] as? String,
           !preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return preview
        }
        guard let args = payload["args"] as? [String: Any], !args.isEmpty else { return nil }
        // Lead with the params that identify what the call touched.
        let priority = ["path", "file_path", "filename", "command", "query", "url", "pattern"]
        let orderedKeys = args.keys.sorted { a, b in
            let ia = priority.firstIndex(of: a) ?? Int.max
            let ib = priority.firstIndex(of: b) ?? Int.max
            return ia == ib ? a < b : ia < ib
        }
        let pairs = orderedKeys.prefix(3).map { "\($0): \(compactArgValue(args[$0] ?? ""))" }
        return pairs.isEmpty ? nil : pairs.joined(separator: " · ")
    }

    nonisolated private static func compactArgValue(_ value: Any) -> String {
        switch value {
        case let string as String:
            if string.count > 80 {
                let bytes = ByteCountFormatter.string(fromByteCount: Int64(string.utf8.count), countStyle: .file)
                return "\(bytes) text"
            }
            return string.replacingOccurrences(of: "\n", with: " ")
        case let number as NSNumber:
            return number.stringValue
        case is [Any]:
            return "[…]"
        case is [String: Any]:
            return "{…}"
        default:
            return String(describing: value)
        }
    }

    /// #21 Tier 1: pulls an agent-written file out of a `tool.started` payload.
    /// Recognizes `write_file` / `create_file`; tolerant of arg-key drift
    /// (`args`/`arguments`/`input`, `path`/`file_path`, `content`/`text`) so a
    /// minor server-shape change doesn't silently drop the attachment. Returns
    /// nil for any other tool or when path/content are absent.
    nonisolated private func parseWrittenFile(_ raw: String) -> MessageAttachment? {
        guard let data = raw.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(ToolStartedEnvelope.self, from: data)
        else { return nil }
        let tool = (envelope.toolName ?? "").lowercased()
        guard tool == "write_file" || tool == "create_file" else { return nil }
        guard let args = envelope.args,
              let path = args.path, !path.isEmpty,
              let content = args.content
        else { return nil }
        return MessageAttachment.agentFile(remotePath: path, content: content)
    }

    private func failureMessage(for error: Error) -> String {
        if let sessionsError = error as? SessionsClientError {
            return sessionsError.errorDescription ?? "Hermes API request failed."
        }
        let described = error.localizedDescription
        return described.isEmpty ? "Hermes API request failed." : described
    }

    // MARK: - Wire types

    private struct EmptyBody: Encodable {}

    /// Extracts token usage from a `run.completed` SSE payload. Hermes emits
    /// Anthropic-style keys (input/output/total); map onto TokenUsage's
    /// prompt/completion/total. Returns nil if usage is absent or unparseable.
    nonisolated private func decodeRunUsage(_ data: String) -> TokenUsage? {
        guard let raw = data.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(RunCompletedEnvelope.self, from: raw),
              let usage = envelope.usage
        else { return nil }
        return TokenUsage(
            promptTokens: usage.inputTokens,
            completionTokens: usage.outputTokens,
            totalTokens: usage.totalTokens
        )
    }

    private struct RunCompletedEnvelope: Decodable {
        let usage: RunCompletedUsage?
    }

    private struct RunCompletedUsage: Decodable {
        let inputTokens: Int
        let outputTokens: Int
        let totalTokens: Int
        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case totalTokens = "total_tokens"
        }
    }

    /// `tool.started` payload for the file-write probe (#21). Tolerant of arg-key
    /// drift across Hermes versions — the canonical shape is
    /// `{tool_name, args:{path, content}}`.
    private struct ToolStartedEnvelope: Decodable {
        let toolName: String?
        let args: WrittenFileArgs?

        enum CodingKeys: String, CodingKey {
            case toolName = "tool_name"
            case name, tool
            case args, arguments, input
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)

            var resolvedName: String?
            for key in [CodingKeys.toolName, .name, .tool] {
                if let value = try? c.decodeIfPresent(String.self, forKey: key) {
                    resolvedName = value
                    break
                }
            }
            toolName = resolvedName

            var resolvedArgs: WrittenFileArgs?
            for key in [CodingKeys.args, .arguments, .input] {
                if let value = try? c.decodeIfPresent(WrittenFileArgs.self, forKey: key) {
                    resolvedArgs = value
                    break
                }
            }
            args = resolvedArgs
        }
    }

    private struct WrittenFileArgs: Decodable {
        let path: String?
        let content: String?

        enum CodingKeys: String, CodingKey {
            case path, content
            case filePath = "file_path"
            case filename, text
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)

            var resolvedPath: String?
            for key in [CodingKeys.path, .filePath, .filename] {
                if let value = try? c.decodeIfPresent(String.self, forKey: key) {
                    resolvedPath = value
                    break
                }
            }
            path = resolvedPath

            var resolvedContent: String?
            for key in [CodingKeys.content, .text] {
                if let value = try? c.decodeIfPresent(String.self, forKey: key) {
                    resolvedContent = value
                    break
                }
            }
            content = resolvedContent
        }
    }

    /// The chat-turn request body. `input` encodes either as a plain string
    /// (text-only turn — byte-identical to the old behavior) or, when image
    /// attachments are present, as an OpenAI-style content-parts array the
    /// Hermes API server's `_normalize_multimodal_content` accepts:
    /// `{"type":"text",...}` + `{"type":"image_url","image_url":{"url":
    /// "data:<mime>;base64,<data>"}}`. Only image attachments are transmitted —
    /// the endpoint rejects file/document parts (`unsupported_content_type`). (#43)
    private struct ChatTurnBody: Encodable {
        let input: TurnInput

        private enum CodingKeys: String, CodingKey { case input }

        // Nonisolated logger — the enclosing client is @MainActor, but this
        // nested value type isn't, so it can't reach the class's isolated one.
        private static let logger = Logger(subsystem: "io.github.eulric90.talaria", category: "SessionsHermesClient")

        /// Build a turn body from the composer's message + staged attachments.
        /// Images become `image_url` data-URL parts; a non-empty message becomes
        /// a leading text part. With no images the body stays a plain string so
        /// existing text turns are unchanged on the wire.
        static func make(message: String, attachments: [PendingAttachment]) -> ChatTurnBody {
            let images = attachments.filter { $0.kind == .image }
            guard !images.isEmpty else {
                return ChatTurnBody(input: .text(message))
            }

            var parts: [ContentPart] = []
            if !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parts.append(.text(message))
            }

            // Respect the API server's ~1 MB request-body budget. Each image is
            // already capped at 350 KB raw (~470 KB base64) by PendingAttachment;
            // accumulate up to a conservative aggregate budget so a stack of
            // images can't trip a hard server rejection, then stop.
            var remainingBudget = 900 * 1024
            for image in images {
                let dataURL = "data:\(image.mimeType);base64,\(image.base64Data)"
                let cost = dataURL.utf8.count
                guard cost <= remainingBudget else {
                    Self.logger.warning("Skipping image attachment — aggregate body budget exceeded")
                    continue
                }
                remainingBudget -= cost
                parts.append(.imageURL(dataURL: dataURL))
            }

            // If every image was skipped and there's no text, fall back to a
            // string so we never emit an empty array (the server 400s empty turns).
            guard !parts.isEmpty else {
                return ChatTurnBody(input: .text(message))
            }
            return ChatTurnBody(input: .parts(parts))
        }

        /// `input` is a string for text-only turns, or an array of content parts
        /// when images ride along. Encoded as an unkeyed single value either way.
        enum TurnInput: Encodable {
            case text(String)
            case parts([ContentPart])

            func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case .text(let text):
                    try container.encode(text)
                case .parts(let parts):
                    try container.encode(parts)
                }
            }
        }

        enum ContentPart: Encodable {
            case text(String)
            case imageURL(dataURL: String)

            private enum CodingKeys: String, CodingKey {
                case type, text
                case imageURL = "image_url"
            }
            private struct ImageURLValue: Encodable { let url: String }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                switch self {
                case .text(let text):
                    try container.encode("text", forKey: .type)
                    try container.encode(text, forKey: .text)
                case .imageURL(let dataURL):
                    try container.encode("image_url", forKey: .type)
                    try container.encode(ImageURLValue(url: dataURL), forKey: .imageURL)
                }
            }
        }
    }

    private struct CreateSessionResponse: Decodable {
        let session: SessionEnvelope
        struct SessionEnvelope: Decodable {
            let id: String
        }
    }

    private struct SyncChatResponse: Decodable {
        let message: AssistantMessage?
        let content: String?
        struct AssistantMessage: Decodable {
            let content: String
        }
    }

    private struct ModelsResponse: Decodable {
        let data: [ModelInfo]?
        struct ModelInfo: Decodable {
            let id: String?
        }
    }

    /// Subset of /api/model/options needed to flatten the picker list. Extra
    /// keys (provider labels, auth hints, pricing, current selection) are
    /// ignored; `models` is a flat list of model-id strings per provider.
    private struct ModelOptionsResponse: Decodable {
        let providers: [ProviderRow]
        struct ProviderRow: Decodable {
            let models: [String]?
            let authenticated: Bool?
        }
    }

    private struct SessionsListResponse: Decodable {
        let data: [Row]
        struct Row: Decodable {
            let id: String
            let title: String?
            let preview: String?
            let model: String?
            let source: String?
            let messageCount: Int?
            let lastActive: Double?
            let isActive: Bool?
            enum CodingKeys: String, CodingKey {
                case id, title, preview, model, source
                case messageCount = "message_count"
                case lastActive = "last_active"
                case isActive = "is_active"
            }
        }
    }

    private struct SessionMessagesResponse: Decodable {
        let sessionId: String?
        let data: [StoredMessage]
        enum CodingKeys: String, CodingKey {
            case sessionId = "session_id"
            case data
        }
        struct StoredMessage: Decodable {
            let role: String?
            let content: String?
            let timestamp: Double?
            /// Tool calls the API attaches to an assistant row, when it does
            /// (#10 — tolerant: absent/unknown shapes decode to []).
            let toolCalls: [StoredToolCall]
            enum CodingKeys: String, CodingKey {
                case role, content, timestamp
                case createdAt = "created_at"
                case toolCalls = "tool_calls"
            }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                role = try c.decodeIfPresent(String.self, forKey: .role)
                let ts = try? c.decodeIfPresent(Double.self, forKey: .timestamp)
                let created = try? c.decodeIfPresent(Double.self, forKey: .createdAt)
                timestamp = (ts ?? nil) ?? (created ?? nil)
                // content may be a plain string or an array of {type, text} parts.
                if let s = try? c.decode(String.self, forKey: .content) {
                    content = s
                } else if let parts = try? c.decode([ContentPart].self, forKey: .content) {
                    content = parts.compactMap(\.text).joined(separator: "\n")
                } else {
                    content = nil
                }
                toolCalls = (try? c.decodeIfPresent([StoredToolCall].self, forKey: .toolCalls)) ?? []
            }
            struct ContentPart: Decodable {
                let type: String?
                let text: String?
            }
        }

        /// One stored tool call — tolerant of shape drift: flat
        /// `{name|tool_name|tool}` or OpenAI-style `{function:{name}}`;
        /// `preview` is kept as the chip detail when present.
        struct StoredToolCall: Decodable {
            let name: String?
            let detail: String?

            enum CodingKeys: String, CodingKey {
                case name, tool, function, preview
                case toolName = "tool_name"
            }
            struct FunctionEnvelope: Decodable {
                let name: String?
            }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                var resolved: String?
                for key in [CodingKeys.name, .toolName, .tool] {
                    if let value = try? c.decodeIfPresent(String.self, forKey: key), value.isEmpty == false {
                        resolved = value
                        break
                    }
                }
                if resolved == nil,
                   let function = try? c.decodeIfPresent(FunctionEnvelope.self, forKey: .function) {
                    resolved = function.name
                }
                name = resolved
                detail = (try? c.decodeIfPresent(String.self, forKey: .preview)) ?? nil
            }
        }
    }

    enum SessionsClientError: LocalizedError {
        case notConfigured(String)
        case requestFailed(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured(let message), .requestFailed(let message):
                return message
            }
        }
    }
}
