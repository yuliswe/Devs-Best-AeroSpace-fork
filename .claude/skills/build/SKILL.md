---
name: build
description: How to build, test, and run AeroSpace from sources. Load whenever a task requires compiling this project, running its tests, or verifying that a change builds.
---

# Building AeroSpace

AeroSpace is built with Swift Package Manager through wrapper scripts in the repo root. Always build through the scripts rather than calling `swift build` directly, because every script sources `script/setup.sh`, which sanitizes `PATH` and routes `swift` through `swiftly` so that the toolchain version matches the `.swift-version` file (currently 6.3.2). The scripts require bash 5 (`brew install bash`) and `cd` to the repo root themselves, so they can be invoked from anywhere.

## The commands I actually need

- `./build-debug.sh` is the standard debug build. It regenerates generated sources (skipping the xcodeproj and cmd-help, which are slow or rarely change), runs `swift build` plus the test target, and copies the `aerospace` CLI binary and the `AeroSpaceApp` binary into `.debug/`. Xcode is not involved.
- `./run-cli.sh <args>` builds and then runs the `aerospace` CLI directly, forwarding all arguments to the binary. This is the fastest way to try a command change.
- `./swift-test.sh` runs the unit tests (`swift test` with noise filtered out). This is the quick check after a change.
- `./test.sh` is the full CI-style check, in which the project is built with `-Xswiftc -warnings-as-errors`, unit tests run, the CLI binary is smoke-tested (`-h`, `--version` must report `0.0.0-SNAPSHOT SNAPSHOT`), and `./lint.sh`, `./generate.sh`, and a check for uncommitted generated files all run.
- `./run-debug.sh` builds and then launches the debug `AeroSpaceApp` itself.
- `./format.sh` formats the code and `./lint.sh` lints it.
- `./generate.sh` regenerates generated files (the `xcode/AeroSpace.xcodeproj` project and sources whose names end in `Generated`). Run it after changing the grammar or command definitions.

## Release build (rarely needed)

`./build-release.sh` builds a universal (arm64 + x86_64) release into `.release/` using xcodebuild, and it additionally builds the docs and shell completion first. It requires a self-signed codesign certificate named `aerospace-codesign-certificate` in Keychain Access, plus extra dependencies (rust, bash, fish for shell completion; Ruby >= 3.0 with `bundler install` for man pages; optional `xcbeautify` for readable logs). `./install-from-sources.sh` wraps it and installs the result as a brew cask. For a debug build none of this is needed.

## Gotchas

- If `swiftly` is not installed, the scripts fall back to the system `swift` with a warning; the build may still work but is not the pinned toolchain. Install it with `brew install swiftly`.
- `swift build` alone does not build the test target, which is why `build-debug.sh` runs a second `swift build --target AppBundleTests`.
- Build outputs land in `.build/` (SPM), `.debug/` (debug binaries), `.release/` (release artifacts), and `.xcode-build/` (xcodebuild), all of which are gitignored.
- More detail lives in `dev-docs/development.md`.
