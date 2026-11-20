# LocalType

A macOS menu-bar app that suggests how to finish your sentence in **any app**, using a language model that runs **entirely on your Mac**. Independent, unofficial project inspired by tools like Cotypist; not affiliated with them.

- Ghost-text suggestion at the caret · each **Tab** accepts one word · **⌥Tab** accepts it all · **Esc** dismisses
- Models: MLX-Serve (default when installed; uses any chat model it has, nothing downloaded), a built-in [llama.cpp](https://github.com/ggml-org/llama.cpp) engine (Metal, download / import GGUF in-app), or Ollama
- Screen context: reads the window you're typing in (ScreenCaptureKit + on-device Vision OCR) so replies fit the conversation
- Emoji completion: `:fire` → 🔥, `:thumbs_up` → 👍 (↓/↑ for other matches)
- Per-app enable/disable, typo guard with suggested fixes, custom style instructions, optional clipboard context,
  optional local writing history for personalization, battery pausing, remappable shortcuts, local statistics
- No accounts, no analytics, nothing sent anywhere

## Build

Requires macOS 14+, Apple Silicon, Swift 5.9+ (Command Line Tools are enough).

```bash
./scripts/fetch-llama.sh   # downloads the prebuilt llama.cpp framework into Vendor/
./build.sh                 # builds and signs LocalType.app (ad-hoc; use SIGN_ID="My Cert" ./build.sh to sign with your own certificate)
open LocalType.app
```

On first launch a setup window walks through **Accessibility** permission (required), the model, and the optional extras (screen context needs **Screen Recording**). With MLX-Serve running, LocalType picks a loaded chat model automatically; smaller models answer faster. Without it, open *Models…* and download a GGUF (e.g. Qwen2.5 3B).

Self-tests: `--selftest model.gguf "text"` (built-in engine), `--selftest-mlx "text"` (MLX-Serve), `--selftest-emoji ":fir"`, `--selftest-screen <pid>`.

Headless engine check: `LocalType.app/Contents/MacOS/LocalType --selftest model.gguf "Some text to continue"`

## How it works

An event tap watches keystrokes; after a short pause the Accessibility API reads the text before the caret, the model continues it, and a click-through panel shows the result at the caret. Tab is swallowed only while a suggestion is visible. Accepted text is typed back with synthetic key events. With MLX-Serve, instruct models are asked through the chat endpoint to continue the text at a ‸ cursor marker (raw continuation makes them degenerate), and the reply is re-joined to the text (spacing, mid-word, echoes).

## Limits

Apps that don't expose caret bounds via Accessibility (some Electron apps, terminals) get no suggestions. The first screen-context read in a session takes ~25 s while the OCR model loads (it's warmed up in the background at launch); after that ~0.3 s. Ad-hoc builds lose the Accessibility grant on every rebuild; sign with your own certificate (`SIGN_ID=…`) to keep it.

## License

MIT. llama.cpp is MIT-licensed; downloaded models carry their own licenses.
