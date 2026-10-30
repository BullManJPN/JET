// 自動生成: python3 sim/gen_selftest.py  (手で直さない)
import Foundation

enum Selftest {
    static func run() -> Bool {
        var fails = 0, total = 0
        func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            total += 1
            if !ok { fails += 1; print("NG  \(name)  \(detail())") }
        }
        // difflib の ratio
        do { let r = SeqMatcher(Array("claud"), Array("claude")).ratio(); check("ratio claud/claude", abs(r - 0.9090909090909091) < 1e-12, "swift=\(r) python=0.9090909090909091") }
        do { let r = SeqMatcher(Array("anthropik"), Array("anthropic")).ratio(); check("ratio anthropik/anthropic", abs(r - 0.8888888888888888) < 1e-12, "swift=\(r) python=0.8888888888888888") }
        do { let r = SeqMatcher(Array("kubernets"), Array("kubernetes")).ratio(); check("ratio kubernets/kubernetes", abs(r - 0.9473684210526315) < 1e-12, "swift=\(r) python=0.9473684210526315") }
        do { let r = SeqMatcher(Array("swift"), Array("swiff")).ratio(); check("ratio swift/swiff", abs(r - 0.8) < 1e-12, "swift=\(r) python=0.8") }
        do { let r = SeqMatcher(Array("hugging"), Array("huggingface")).ratio(); check("ratio hugging/huggingface", abs(r - 0.7777777777777778) < 1e-12, "swift=\(r) python=0.7777777777777778") }
        do { let r = SeqMatcher(Array("quantisation"), Array("quantization")).ratio(); check("ratio quantisation/quantization", abs(r - 0.9166666666666666) < 1e-12, "swift=\(r) python=0.9166666666666666") }
        do { let r = SeqMatcher(Array("ollama"), Array("ollama")).ratio(); check("ratio ollama/ollama", abs(r - 1.0) < 1e-12, "swift=\(r) python=1.0") }
        do { let r = SeqMatcher(Array("abcde"), Array("xyz")).ratio(); check("ratio abcde/xyz", abs(r - 0.0) < 1e-12, "swift=\(r) python=0.0") }
        do { let r = SeqMatcher(Array("foundation"), Array("foundational")).ratio(); check("ratio foundation/foundational", abs(r - 0.9090909090909091) < 1e-12, "swift=\(r) python=0.9090909090909091") }
        do { let r = SeqMatcher(Array("analyzer"), Array("speechanalyzer")).ratio(); check("ratio analyzer/speechanalyzer", abs(r - 0.7272727272727273) < 1e-12, "swift=\(r) python=0.7272727272727273") }
        do { let r = SeqMatcher(Array(""), Array("")).ratio(); check("ratio /", abs(r - 1.0) < 1e-12, "swift=\(r) python=1.0") }
        do { let r = SeqMatcher(Array("a"), Array("")).ratio(); check("ratio a/", abs(r - 0.0) < 1e-12, "swift=\(r) python=0.0") }
        // 最長一致ブロック
        do { let got = SeqMatcher(["a", "b", "c", "d", "e"], ["a", "x", "c", "d", "y", "e"], autojunk: false).matchingBlocks().map { [$0.0, $0.1, $0.2] }; check("blocks a b c d e", got == [[0, 0, 1], [2, 2, 2], [4, 5, 1]], "swift=\(got)") }
        do { let got = SeqMatcher(["the", "quick", "brown", "fox"], ["quick", "brown", "the", "fox", "jumps"], autojunk: false).matchingBlocks().map { [$0.0, $0.1, $0.2] }; check("blocks the quick brown fox", got == [[1, 0, 2], [3, 3, 1]], "swift=\(got)") }
        do { let got = SeqMatcher(["x", "x", "x", "y"], ["x", "y", "x", "x"], autojunk: false).matchingBlocks().map { [$0.0, $0.1, $0.2] }; check("blocks x x x y", got == [[0, 2, 2]], "swift=\(got)") }
        do { let got = SeqMatcher([], ["a", "b"], autojunk: false).matchingBlocks().map { [$0.0, $0.1, $0.2] }; check("blocks -", got == [], "swift=\(got)") }
        do { let got = SeqMatcher(["a", "b", "c"], [], autojunk: false).matchingBlocks().map { [$0.0, $0.1, $0.2] }; check("blocks a b c", got == [], "swift=\(got)") }
        do { let got = SeqMatcher(["so", "the", "team", "was", "researchch", "about"], ["so", "the", "team", "was", "research", "about", "it"], autojunk: false).matchingBlocks().map { [$0.0, $0.1, $0.2] }; check("blocks so the team was researchch about", got == [[0, 0, 4], [5, 5, 1]], "swift=\(got)") }
        // 語の分割と正規化
        do { let got = W("Over past, A I'm Wi-Fi can’t stop... \"quoted\" 3.5 million, e-mail?"); check("W", got == ["Over", "past,", "A", "I'm", "Wi-Fi", "can’t", "stop.", "quoted", "3.", "5", "million,", "e-mail?"], "swift=\(got)") }
        do { let got = W("Hello, world! It's 5.2 GHz-ish; ok."); check("W", got == ["Hello,", "world!", "It's", "5.", "2", "GHz-ish", "ok."], "swift=\(got)") }
        do { let got = W("  spaces   and\ttabs.  "); check("W", got == ["spaces", "and", "tabs."], "swift=\(got)") }
        do { let got = N("Over"); check("N", got == "over", "swift=\(got)") }
        do { let got = N("past,"); check("N", got == "past", "swift=\(got)") }
        do { let got = N("Wi-Fi"); check("N", got == "wifi", "swift=\(got)") }
        do { let got = N("can’t"); check("N", got == "cant", "swift=\(got)") }
        do { let got = N("I'm"); check("N", got == "i'm", "swift=\(got)") }
        do { let got = N("3.5"); check("N", got == "35", "swift=\(got)") }
        do { let got = N("MLX's"); check("N", got == "mlx's", "swift=\(got)") }
        do { let got = N("Hello!"); check("N", got == "hello", "swift=\(got)") }
        do { let got = N("A.B"); check("N", got == "ab", "swift=\(got)") }
        // 用語補正
        if let cor = try? Corrector(termsPath: "asr/terms.txt", aliasesPath: "asr/term_aliases.tsv", thr: 0.84) {
            do { let got = cor.correct("We use clawed code with m l x and an SPK."); check("correct", got == "We use Claude Code with MLX and an SDK.", "swift=\(got)") }
            do { let got = cor.correct("I tried m l x on the apple silicon machine"); check("correct", got == "I tried MLX on the Apple silicon machine", "swift=\(got)") }
            do { let got = cor.correct("the quad core CPU"); check("correct", got == "the Claude core CPU", "swift=\(got)") }
            do { let got = cor.correct("Anthropick released Claud's new model"); check("correct", got == "Anthropic released Claude's new model", "swift=\(got)") }
            do { let got = cor.correct("Ollama and kubernets on a mac mini"); check("correct", got == "Ollama and Kubernetes on a Mac mini", "swift=\(got)") }
            do { let got = cor.correct("claude-code and S D K and m c p"); check("correct", got == "Claude-code and SDK and MCP", "swift=\(got)") }
            do { let got = cor.correct("Foundation models and private cloud compute are great"); check("correct", got == "Foundation Models and Private Cloud Compute are great", "swift=\(got)") }
            do { let got = cor.correct("Hugging face RAG pipelines, quantisation"); check("correct", got == "Hugging Face RAG pipelines, quantization", "swift=\(got)") }
            do { let got = cor.correct("Over the Claod and clod code stuff"); check("correct", got == "Over the Claude and Claude Code stuff", "swift=\(got)") }
            do { let got = cor.correct("cloud code, Claude   Code and claude-code"); check("correct", got == "Claude Code, Claude   Code and Claude-code", "swift=\(got)") }
            do { let got = cor.correct("Swiftt and Swfit and swift"); check("correct", got == "Swift and Swfit and Swift", "swift=\(got)") }
            do { let got = cor.correct("Atropic's claots"); check("correct", got == "Anthropic's Claude", "swift=\(got)") }
            do { let got = cor.correct("Hi, I work on the m l x team."); check("correct", got == "Hi, I work on the MLX team.", "swift=\(got)") }
            do { let got = cor.correct("We run local agentic AI on the map using molelex."); check("correct", got == "We run local agentic AI on the map using MLX.", "swift=\(got)") }
            do { let got = cor.correct("Can you explain why Claod is so good at writing code?"); check("correct", got == "Can you explain why Claude is so good at writing code?", "swift=\(got)") }
            do { let got = cor.correct("A feature we released on the web lets Quad create files by writing code."); check("correct", got == "A feature we released on the web lets Claude create files by writing code.", "swift=\(got)") }
            do { let got = cor.correct("Is quad writing scripts and taking actions on computers?"); check("correct", got == "Is Claude writing scripts and taking actions on computers?", "swift=\(got)") }
            do { let got = cor.correct("If you are building an agent with clod, try the clod code SPK."); check("correct", got == "If you are building an agent with Claude, try the Claude Code SDK.", "swift=\(got)") }
            do { let got = cor.correct("We are excited about developers using the Claude code SDK."); check("correct", got == "We are excited about developers using the Claude Code SDK.", "swift=\(got)") }
            do { let got = cor.correct("We built all of that into clawed code."); check("correct", got == "We built all of that into Claude Code.", "swift=\(got)") }
        } else { check("Corrector の読み込み(同梱の asr/terms.txt・term_aliases.tsv が jetcli の隣にありますか)", false) }
        print(fails == 0 ? "selftest OK (\(total) 件)" : "selftest NG: \(fails) / \(total) 件")
        return fails == 0
    }
}
