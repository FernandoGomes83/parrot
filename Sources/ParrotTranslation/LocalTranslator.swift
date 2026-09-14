import Foundation
import Hub
import MLX
import Metal
import MLXLLM
import MLXLMCommon

/// Local, single-utterance translation. Every request gets a fresh KV cache.
public actor LocalTranslator: TextTranslating {
    public static let modelID = "mlx-community/translategemma-4b-it-4bit"
    private static let modelRevision = "5788ec08c047f3f2e17808101b8d9566ac930d58"
    private let modelDirectory: URL?
    private var container: ModelContainer?
    private var runtimeInitialized = false

    public init(modelDirectory: URL? = nil) {
        self.modelDirectory = modelDirectory
    }

    public func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        if container != nil { return }
        guard Self.hasMetalLibrary else { throw TranslationError.missingShaders }
        guard MTLCreateSystemDefaultDevice() != nil else { throw TranslationError.gpuUnavailable }
        try Task.checkCancellation()

        let directory: URL
        if let modelDirectory {
            directory = modelDirectory
        } else {
            let base = URL.applicationSupportDirectory.appending(path: "parrot/translation")
            let hub = HubApi(downloadBase: base)
            let cached = hub.localRepoLocation(Hub.Repo(id: Self.modelID))
            let marker = cached.appendingPathComponent(".parrot-download-complete")
            if (try? String(contentsOf: marker, encoding: .utf8)) == Self.modelRevision {
                directory = cached
            } else {
                directory = try await hub.snapshot(
                    from: Self.modelID, revision: Self.modelRevision,
                    matching: ["*.safetensors", "*.json", "*.jinja"]
                ) { progress($0.fractionCompleted) }
                // Hub may return a partially downloaded directory on cancellation.
                try Task.checkCancellation()
                try Data(Self.modelRevision.utf8).write(to: marker, options: .atomic)
            }
        }
        progress(1)
        runtimeInitialized = true
        let loaded = try await LLMModelFactory.shared.loadContainer(
            from: directory, using: TransformersTokenizerLoader()
        )
        try Task.checkCancellation()
        container = loaded
    }

    public func translate(_ text: String, languages: TranslationPair) async throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }
        guard languages.source != languages.target else { return text }
        guard let container else { throw TranslationError.notReady }
        guard text.count <= 24_000 else { throw TranslationError.inputTooLong }
        try Task.checkCancellation()

        return try await container.perform { context in
            // TranslateGemma's own template takes structured text and language codes.
            // A system prompt or a free-form chat message changes this model's contract.
            let protected = ProtectedTranslationInput(text)
            let content: [[String: String]] = [[
                "type": "text",
                "source_lang_code": languages.source.rawValue,
                "target_lang_code": languages.target.rawValue,
                "text": protected.text,
            ]]
            let tokens = try context.tokenizer.applyChatTemplate(messages: [[
                "role": "user", "content": content,
            ]])
            guard tokens.count <= 8_192 else { throw TranslationError.inputTooLong }
            let parameters = GenerateParameters(
                maxTokens: min(2_048, max(256, tokens.count * 3)), temperature: 0
            )
            var iterator = try TokenIterator(
                input: LMInput(tokens: MLXArray(tokens)),
                model: context.model,
                parameters: parameters
            )
            defer { Stream().synchronize() }
            var endings = context.configuration.eosTokenIds
            for symbol in [context.tokenizer.eosToken, "<end_of_turn>"].compactMap({ $0 }) {
                if let token = context.tokenizer.convertTokenToId(symbol) { endings.insert(token) }
            }
            var generated: [Int] = []
            var finished = false
            while let token = iterator.next() {
                try Task.checkCancellation()
                if endings.contains(token) {
                    finished = true
                    break
                }
                generated.append(token)
            }
            try Task.checkCancellation()
            guard finished else { throw TranslationError.incompleteOutput }
            let output = context.tokenizer.decode(tokenIds: generated)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !output.isEmpty else { throw TranslationError.emptyOutput }
            return try protected.restoring(in: output)
        }
    }

    public func unload() async {
        container = nil
        if runtimeInitialized { Memory.clearCache() }
    }

    /// SwiftPM can compile the code without compiling shaders. Check before MLX
    /// reaches the GPU so a partial install is a recoverable error, not a crash.
    private static var hasMetalLibrary: Bool {
        guard let executable = Bundle.main.executableURL else { return false }
        let roots = [executable.deletingLastPathComponent(),
                     executable.resolvingSymlinksInPath().deletingLastPathComponent()]
        let paths = ["mlx.metallib", "Resources/mlx.metallib",
                     "mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib",
                     "mlx-swift_Cmlx.bundle/default.metallib"]
        return roots.contains { root in
            paths.contains { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
        }
    }
}
