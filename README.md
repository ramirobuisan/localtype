# LocalType

A macOS menu-bar app that suggests how to finish your sentence in **any app**, using a language model that runs **entirely on your Mac**. Independent, unofficial project inspired by tools like Cotypist; not affiliated with them.

- Ghost-text suggestion at the caret · **Tab** accepts · **⌥Tab** accepts one word · **Esc** dismisses
- Built-in [llama.cpp](https://github.com/ggml-org/llama.cpp) engine (Metal), no server needed. Ollama also supported.
- Download / import GGUF models in-app
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

Grant **Accessibility** permission when asked (System Settings → Privacy & Security). Then open *Models…* from the menu-bar icon and download a model (e.g. Qwen2.5 3B).

Headless engine check: `LocalType.app/Contents/MacOS/LocalType --selftest model.gguf "Some text to continue"`

## How it works

An event tap watches keystrokes; after a short pause the Accessibility API reads the text before the caret, the model continues it, and a click-through panel shows the result at the caret. Tab is swallowed only while a suggestion is visible. Accepted text is typed back with synthetic key events.

## Limits

Apps that don't expose caret bounds via Accessibility (some Electron apps, terminals) get no suggestions. Screenshot-based context isn't implemented. The app is ad-hoc signed, so Accessibility permission may need re-granting after rebuilds.

## License

MIT. llama.cpp is MIT-licensed; downloaded models carry their own licenses.
