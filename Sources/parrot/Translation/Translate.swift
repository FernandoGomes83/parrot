import ArgumentParser
import Foundation
import ParrotTranslation

/// The same local translator as the menu option, usable without microphone access.
struct Translate: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Translate text locally (downloads the model on first use).")

    @Option(name: .customLong("from"), help: "Source language code, e.g. pt-BR, en, es.")
    var source: TranslationLanguage = .portuguese

    @Option(name: .customLong("to"), help: "Target language code, e.g. en, es, fr.")
    var target: TranslationLanguage = .english

    @Option(name: .long, help: "Use an already downloaded MLX model directory.")
    var modelDirectory: String?

    @Argument(help: "Text to translate. Omit to read standard input.")
    var text: String?

    func run() throws {
        let input: String
        if let text {
            input = text
        } else {
            guard isatty(STDIN_FILENO) == 0 else {
                throw ValidationError("Pass text as an argument or pipe it into parrot translate.")
            }
            input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        }
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if source == target {
            print(input)
            return
        }
        let engine = LocalTranslator(modelDirectory: modelDirectory.map { URL(fileURLWithPath: $0) })
        let pair = TranslationPair(source: source, target: target)
        let done = DispatchSemaphore(value: 0)
        var result: Result<String, Error>?
        Task.detached {
            do {
                try await engine.prepare { _ in }
                let started = Date()
                let output = try await engine.translate(input, languages: pair)
                FileHandle.standardError.write(Data(String(format: "translated in %.2fs\n", Date().timeIntervalSince(started)).utf8))
                result = .success(output)
            } catch {
                result = .failure(error)
            }
            done.signal()
        }
        done.wait()
        print(try result!.get())
    }
}

extension TranslationLanguage: ExpressibleByArgument {}
