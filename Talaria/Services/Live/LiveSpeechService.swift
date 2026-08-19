@preconcurrency import AVFoundation
import Foundation
import OSLog
@preconcurrency import Speech

/// On-device speech-to-text using Apple's Speech framework.
/// Used for dictation in the chat composer — not for voice mode (which uses OpenAI Realtime).
///
/// This uses the modern iOS 26 Speech analyzer/transcriber stack instead of the
/// older `SFSpeechRecognizer` live-audio callback path. The newer APIs are a much
/// better fit for Swift concurrency and are less fragile around queue ownership.
@MainActor
@Observable
final class LiveSpeechService {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "io.github.eulric90.talaria",
        category: "Dictation"
    )
    private static let startupTimeout: Duration = .seconds(4)

    private(set) var isListening = false
    private(set) var transcript = ""
    private(set) var authorizationStatus: SFSpeechRecognizerAuthorizationStatus

    var onAutoStop: ((_ finalTranscript: String) -> Void)?
    var onTranscriptChange: ((_ transcript: String) -> Void)?

    private let controller = DictationController()
    private var streamTask: Task<Void, Never>?

    init() {
        authorizationStatus = SFSpeechRecognizer.authorizationStatus()
        Self.logger.verbose("Initialized speech authorization status: \(String(describing: self.authorizationStatus))")
    }

    var supportsOnDevice: Bool {
        true
    }

    func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let currentStatus = SFSpeechRecognizer.authorizationStatus()
        if currentStatus != .notDetermined {
            authorizationStatus = currentStatus
            Self.logger.verbose("Speech authorization already resolved: \(String(describing: currentStatus))")
            return currentStatus
        }

        let status: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        authorizationStatus = status
        Self.logger.verbose("Speech authorization callback returned: \(String(describing: status))")
        return status
    }

    func startListening() async throws {
        Self.logger.verbose("Dictation start requested")

        let speechAuthorized: Bool
        if authorizationStatus == .authorized {
            speechAuthorized = true
        } else {
            Self.logger.verbose("Requesting speech authorization")
            speechAuthorized = await requestAuthorization() == .authorized
        }
        guard speechAuthorized else {
            Self.logger.error("Speech authorization denied or unavailable")
            throw SpeechError.unavailable
        }
        Self.logger.verbose("Speech authorization granted")

        let microphoneStatus = AVAudioApplication.shared.recordPermission
        if microphoneStatus == .undetermined {
            Self.logger.verbose("Requesting microphone permission")
            guard await AVAudioApplication.requestRecordPermission() else {
                Self.logger.error("Microphone permission denied")
                throw SpeechError.microphoneDenied
            }
        } else if microphoneStatus != .granted {
            Self.logger.error("Microphone permission unavailable")
            throw SpeechError.microphoneDenied
        }
        Self.logger.verbose("Microphone permission granted")

        guard !isListening else { return }

        transcript = ""
        streamTask?.cancel()

        let stream: AsyncStream<DictationController.Event>
        do {
            stream = try await startControllerWithTimeout()
        } catch {
            Self.logger.error("Dictation startup failed: \(error.localizedDescription, privacy: .public)")
            Task {
                await controller.stop()
            }
            throw error
        }

        Self.logger.verbose("Dictation startup completed")
        isListening = true

        streamTask = Task { [weak self] in
            guard let self else { return }
            for await event in stream {
                await MainActor.run {
                    switch event {
                    case .partial(let text):
                        Self.logger.verbose("Dictation partial received")
                        self.transcript = text
                        self.onTranscriptChange?(text)
                    case .finished(let text):
                        Self.logger.verbose("Dictation finished")
                        self.transcript = text
                        self.isListening = false
                        self.onTranscriptChange?(text)
                        if !text.isEmpty {
                            self.onAutoStop?(text)
                        }
                    case .failed:
                        Self.logger.error("Dictation stream failed")
                        self.isListening = false
                    }
                }
            }
        }
    }

    func stopListening() {
        guard isListening else { return }
        Self.logger.verbose("Dictation stop requested")
        isListening = false
        streamTask?.cancel()
        streamTask = nil

        Task {
            await controller.stop()
        }
    }

    private func startControllerWithTimeout() async throws -> AsyncStream<DictationController.Event> {
        let controller = self.controller

        return try await withThrowingTaskGroup(of: AsyncStream<DictationController.Event>.self) { group in
            group.addTask {
                try await controller.start()
            }

            group.addTask {
                try await Task.sleep(for: Self.startupTimeout)
                throw SpeechError.startupTimedOut
            }

            let stream = try await group.next()!
            group.cancelAll()
            return stream
        }
    }

    enum SpeechError: LocalizedError {
        case unavailable
        case microphoneDenied
        case startupTimedOut

        var errorDescription: String? {
            switch self {
            case .unavailable:
                "Speech recognition is not available on this device."
            case .microphoneDenied:
                "Microphone access is required for dictation."
            case .startupTimedOut:
                "Dictation took too long to start."
            }
        }
    }
}

private actor DictationController {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "io.github.eulric90.talaria",
        category: "DictationController"
    )

    enum Event: Sendable {
        case partial(String)
        case finished(String)
        case failed
    }

    private let audioEngine = AVAudioEngine()

    private var transcriber: DictationTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var audioConverter: AVAudioConverter?
    private var reservedLocale: Locale?
    private var analyzerTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var outputContinuation: AsyncStream<Event>.Continuation?

    func start() async throws -> AsyncStream<Event> {
        stop()
        Self.logger.verbose("Preparing dictation controller")

        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: .current) else {
            Self.logger.error("No supported locale equivalent to current locale")
            throw LiveSpeechService.SpeechError.unavailable
        }

        let transcriber = DictationTranscriber(locale: locale, preset: .progressiveShortDictation)
        self.transcriber = transcriber
        if try await AssetInventory.reserve(locale: locale) {
            reservedLocale = locale
            Self.logger.verbose("Reserved speech locale: \(locale.identifier)")
        }

        let assetStatus = await AssetInventory.status(forModules: [transcriber])
        Self.logger.verbose("Speech asset status: \(String(describing: assetStatus))")

        let session = AVAudioSession.sharedInstance()
        Self.logger.verbose("Configuring audio session")
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)
        let inputFormat = inputNode.outputFormat(forBus: 0)
        let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber],
            considering: inputFormat
        ) ?? inputFormat
        let formatsMatch =
            inputFormat.sampleRate == analyzerFormat.sampleRate &&
            inputFormat.channelCount == analyzerFormat.channelCount &&
            inputFormat.commonFormat == analyzerFormat.commonFormat &&
            inputFormat.isInterleaved == analyzerFormat.isInterleaved
        let converter = formatsMatch ? nil : AVAudioConverter(from: inputFormat, to: analyzerFormat)
        converter?.primeMethod = .none
        audioConverter = converter
        Self.logger.verbose(
            "Using analyzer format sampleRate=\(analyzerFormat.sampleRate) channels=\(analyzerFormat.channelCount)"
        )

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        Self.logger.verbose("Preparing speech analyzer")
        try await analyzer.prepareToAnalyze(in: analyzerFormat) { progress in
            Self.logger.verbose("Speech asset progress totalUnitCount=\(progress.totalUnitCount) completedUnitCount=\(progress.completedUnitCount)")
        }
        self.analyzer = analyzer

        var localInputContinuation: AsyncStream<AnalyzerInput>.Continuation?
        let inputStream = AsyncStream<AnalyzerInput> { continuation in
            localInputContinuation = continuation
            self.inputContinuation = continuation
        }

        let outputStream = AsyncStream<Event> { continuation in
            self.outputContinuation = continuation
        }

        Self.logger.verbose("Installing audio tap")
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            if let convertedBuffer = Self.convertBuffer(buffer, using: converter, outputFormat: analyzerFormat) {
                localInputContinuation?.yield(AnalyzerInput(buffer: convertedBuffer))
            }
        }

        Self.logger.verbose("Starting audio engine")
        audioEngine.prepare()
        try audioEngine.start()
        Self.logger.verbose("Audio engine started")

        analyzerTask = Task { [weak self] in
            do {
                Self.logger.verbose("Speech analyzer start(inputSequence:) entered")
                try await analyzer.start(inputSequence: inputStream)
            } catch {
                Self.logger.error("Speech analyzer failed: \(error.localizedDescription, privacy: .public)")
                await self?.emit(.failed)
                await self?.stop()
            }
        }

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        Self.logger.verbose("Received final dictation result")
                        await self?.emit(.finished(text))
                        await self?.stop()
                        break
                    } else {
                        Self.logger.verbose("Received partial dictation result")
                        await self?.emit(.partial(text))
                    }
                }
            } catch {
                Self.logger.error("Transcriber results failed: \(error.localizedDescription, privacy: .public)")
                await self?.emit(.failed)
                await self?.stop()
            }
        }

        return outputStream
    }

    func stop() {
        Self.logger.verbose("Stopping dictation controller")
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        inputContinuation?.finish()
        inputContinuation = nil

        analyzerTask?.cancel()
        resultsTask?.cancel()
        analyzerTask = nil
        resultsTask = nil

        let analyzer = analyzer
        self.analyzer = nil
        self.transcriber = nil
        self.audioConverter = nil
        let reservedLocale = self.reservedLocale
        self.reservedLocale = nil
        if let analyzer {
            Task {
                await analyzer.cancelAndFinishNow()
            }
        }
        if let reservedLocale {
            Task {
                _ = await AssetInventory.release(reservedLocale: reservedLocale)
            }
        }

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        outputContinuation?.finish()
        outputContinuation = nil
    }

    private func emit(_ event: Event) {
        outputContinuation?.yield(event)
    }

    nonisolated private static func convertBuffer(
        _ inputBuffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter?,
        outputFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        final class ConversionState: @unchecked Sendable {
            var didProvideInput = false
        }

        guard let converter else { return inputBuffer }

        let frameRatio = outputFormat.sampleRate / inputBuffer.format.sampleRate
        let outputFrameCapacity = max(
            inputBuffer.frameLength,
            AVAudioFrameCount(ceil(Double(inputBuffer.frameLength) * frameRatio)) + 32
        )

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputFrameCapacity
        ) else {
            Self.logger.error("Failed to allocate converted audio buffer")
            return nil
        }

        let state = ConversionState()
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if state.didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            } else {
                state.didProvideInput = true
                outStatus.pointee = .haveData
                return inputBuffer
            }
        }

        switch status {
        case .haveData, .inputRanDry, .endOfStream:
            return outputBuffer.frameLength > 0 ? outputBuffer : nil
        case .error:
            if let conversionError {
                Self.logger.error("Audio conversion failed: \(conversionError.localizedDescription, privacy: .public)")
            } else {
                Self.logger.error("Audio conversion failed with unknown error")
            }
            return nil
        @unknown default:
            Self.logger.error("Audio conversion returned unknown status")
            return nil
        }
    }
}
