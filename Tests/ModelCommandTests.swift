import Foundation

private func check(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
    if !condition() { fatalError("FAILED (line \(line)): \(message)") }
}

@main
struct ModelCommandTests {
    static func main() {
        let catalog = [
            "anthropic": ["claude-opus-5-5", "claude-sonnet-5-5"],
            "openai": ["gpt-5", "gpt-5-mini"],
        ]
        check(ModelCommand.parse("/model") == .picker, "bare /model opens the picker")
        check(ModelCommand.parse("/model reset") == .reset, "reset")
        check(ModelCommand.parse("/model default") == .reset, "default")
        check(ModelCommand.parse("/model --provider openai gpt-5") == .model(query: "gpt-5", provider: "openai"), "--provider flag")
        check(ModelCommand.parse("/effort high") == .effort("high"), "effort high")
        check(ModelCommand.parse("/effort bogus") == .badEffort("bogus"), "bad effort")
        check(ModelCommand.parse("hello there") == nil, "plain text")
        check(ModelCommand.parse("/models") == nil, "/models is not /model")
        check(ModelCommand.parse("/help") == nil, "other slash commands pass through")

        check(ModelCommand.resolve("sonnet-5.5", catalog: catalog) == .found(provider: "anthropic", model: "claude-sonnet-5-5"), "unique suffix match with dots")
        check(ModelCommand.resolve("anthropic:claude-opus-5-5", catalog: catalog) == .found(provider: "anthropic", model: "claude-opus-5-5"), "provider:name")
        if case .ambiguous(let names) = ModelCommand.resolve("gpt", catalog: catalog) { check(names.count == 2, "two gpt matches") }
        else { check(false, "gpt should be ambiguous") }
        check(ModelCommand.resolve("nonesuch", catalog: catalog) == .unknown, "unknown")

        func c(_ m: String) -> RuntimeChoice { RuntimeChoice(provider: "p", model: m, effort: nil) }
        let merged = RecentModels.merged([c("a"), c("b")], [c("b"), c("c"), c("d"), c("e"), c("f"), c("g"), c("h")])
        check(merged.map(\.model) == ["a", "b", "c", "d", "e", "f"], "dedupe, first wins, capped at 6: \(merged.map(\.model))")
        check(RecentModels.merged([RuntimeChoice.botDefault], []).isEmpty, "choices without a model are skipped")
        print("ModelCommand suite passed")
    }
}
