# AGENTS

## Test Commands
- Run test commands from the `UIHostingMenu` repository root.
- Run hosted Swift Testing tests with the `UIHostingMenuHostedTests` scheme in the existing `UIHostingMenu.xcworkspace`. The host is the `MenuTestHost` application target in `Tools/MiniApp/MiniApp.xcodeproj`. It starts UIKit without linking UIHostingMenu, so native static dependencies are linked only by the test bundle.
- Required local validation: run the hosted suite on the latest available iOS 18.x, 26.x, and 27.x runtimes. Run it on affected older minor runtimes when changing native runtime integration.
- CI uses the latest stable Xcode 26 on `macos-26` and the latest Xcode 27, including prereleases, on `xcode-27`.
- CI discovers every installed, available iOS runtime at or above the package's iOS 18.4 deployment target. Each runtime identifier gets a separate job; CI does not download additional runtimes. Use local installed runtimes to cover versions absent from CI runners.
- Each CI job creates an iPhone supported by the selected runtime and deletes it afterward. Logs and the result bundle are uploaded even when tests fail.
- Local example commands, replacing the OS version and device name with an installed destination:
  - `xcodebuild test -workspace UIHostingMenu.xcworkspace -scheme UIHostingMenuHostedTests -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' -enableCodeCoverage NO -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1`
  - `xcodebuild test -workspace UIHostingMenu.xcworkspace -scheme UIHostingMenuHostedTests -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' -enableCodeCoverage NO -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1`
  - `xcodebuild test -workspace UIHostingMenu.xcworkspace -scheme UIHostingMenuHostedTests -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.2' -enableCodeCoverage NO -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1`
- Find destinations with `xcrun simctl list devices available` or `xcodebuild -showdestinations -workspace UIHostingMenu.xcworkspace -scheme UIHostingMenuHostedTests`.
- Do not rely on plain `swift test` on macOS hosts; the package depends on UIKit.

## CI Script Validation
- Run `python3 -m unittest discover -s .github/scripts/tests -p 'test_*.py'`, `ruby -c .github/scripts/resolve-xcode.rb`, `actionlint`, and `git diff --check` when changing CI scripts or workflows.
- `.github/scripts/ios-runtime-matrix.py` uses runtime identifiers reported by `simctl` for discovery and Simulator creation. Do not reconstruct them from version strings.

## Testing Policy
- `UIHostingMenu` tests use Swift Testing (`import Testing`, `@Test`, `#expect`).
- When changing behavior, add or update tests for the affected public behavior or bug fix.
- Focus automated coverage on package-level `UIHostingMenu` behavior and UIKit `UIMenuElement` materialization.
- The demo app is for sample/manual validation. Demo UI tests are not part of the required self-check for package changes unless the user explicitly asks for demo UI validation.
- Hosted test sources are copied into `Tools/MiniApp/UIHostingMenuHostedTests`. Keep regression coverage consistent with the SwiftPM suite in `Tests/UIHostingMenuTests` when updating tests.
- Both CI Xcode lanes are required. An unavailable Xcode or an empty supported-runtime matrix fails the job instead of skipping coverage.
