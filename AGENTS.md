# AGENTS

## Test Commands
- Run test commands from the `UIHostingMenu` repository root.
- Required local validation should mirror CI: run package tests on the latest available iOS 18.x runtime and the latest available iOS 26.x runtime.
- CI resolves the latest available runtime for each major version dynamically:
  - iOS 18.x on `macos-15` with `iPhone 16`
  - iOS 26.x on `macos-26` with `iPhone 17`
- Local example commands, after replacing `OS=<version>` with your latest available major runtime:
  - `xcodebuild test -workspace .swiftpm/xcode/package.xcworkspace -scheme UIHostingMenu -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.x' -enableCodeCoverage NO -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1`
  - `xcodebuild test -workspace .swiftpm/xcode/package.xcworkspace -scheme UIHostingMenu -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.x' -enableCodeCoverage NO -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1`
- If the simulator name or OS version does not match your local environment:
  - `xcrun simctl list devices available`
- If you need to confirm Xcode destinations for the package scheme:
  - `xcodebuild -showdestinations -workspace .swiftpm/xcode/package.xcworkspace -scheme UIHostingMenu`
- If you need to confirm available package schemes:
  - `xcodebuild -list -json -workspace .swiftpm/xcode/package.xcworkspace`
- Do not rely on plain `swift test` for validation on macOS hosts. This package depends on `UIKit`, so verification should run against an iOS Simulator.

## Testing Policy
- `UIHostingMenu` tests use Swift Testing (`import Testing`, `@Test`, `#expect`).
- When changing behavior, add or update tests for the affected public behavior or bug fix.
- Focus automated coverage on package-level `UIHostingMenu` behavior and UIKit `UIMenuElement` materialization.
- The demo app is for sample/manual validation. Demo UI tests are not part of the required self-check for package changes unless the user explicitly asks for demo UI validation.
- The CI beta lane is optional and non-gating. It runs on `push` / `pull_request`, runs from `workflow_dispatch` only when `include_beta` is enabled, and skips itself when a pre-release Xcode or matching simulator is not installed on the runner.
