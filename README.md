# UIHostingMenu

`UIHostingMenu` is a Swift package that builds UIKit `UIMenu` instances from SwiftUI menu content.

It provides an `NSHostingMenu`-style bridge for UIKit, letting controls such as `UIButton` and `UIBarButtonItem` reuse SwiftUI `Button`, `Divider`, and nested `Menu` declarations.

Menu content is evaluated in a detached SwiftUI hosting view.

> [!WARNING]
> This package relies on undocumented APIs and runtime behavior, so extra care is needed before using it in App Store-bound projects.

## Requirements

- iOS 18.4 or later
- Swift 6.3 or later

## Usage

```swift
import Observation
import SwiftUI
import UIKit
import UIHostingMenu

@Observable
final class EditorMenuState {
    var canReload = true
    var selectedFormat = "JSON"

    func reload() {
        canReload = false
    }
}

struct EditorMenuItems: View {
    var state: EditorMenuState

    var body: some View {
        Button("Reload") {
            state.reload()
        }
        .disabled(!state.canReload)

        Divider()

        Menu("Format: \(state.selectedFormat)") {
            Button("JSON") { state.selectedFormat = "JSON" }
            Button("HTML") { state.selectedFormat = "HTML" }
        }
    }
}

// During asynchronous app setup, prepare once for every menu in the process.
try await UIHostingMenuRuntime.prepare()

// Subsequent menu creation and assignment are synchronous.
let state = EditorMenuState()
let hostingMenu = UIHostingMenu(rootView: EditorMenuItems(state: state))
button.menu = try hostingMenu.menu()
button.showsMenuAsPrimaryAction = true

state.canReload = false
```

Declare menu content as SwiftUI that directly reads an `@Observable` source of truth. Do not rebuild or reassign the menu when the same source object changes; the visible menu follows SwiftUI/Observation reads.

`UIHostingMenuRuntime.prepare()` shares native method preparation across all menus, including menus with different content types. Await it once during app setup; menus created before or after that call can then be built synchronously without awaiting each instance. Repeated or concurrent calls share the same preparation, and cancelling a waiter does not cancel that shared work.

If app setup does not prepare the runtime, the first hosting menu starts preparation in the background. `menu()` remains synchronous and throws `UIHostingMenuError.notPrepared` while that shared preparation is in progress. Instance `prepare()` remains available to wait for the runtime and prepare that menu's host. Preparation and materialization failures propagate to the caller. Replacing `rootView` reuses the host and its bound methods.

Static menus work the same way:

```swift
let staticMenu = UIHostingMenu(menuItems: {
    Button("Refresh") {}
    Divider()
    Menu("More") {
        Button("Share") {}
        Button("Delete", role: .destructive) {}
    }
})
button.menu = try staticMenu.menu()
```

## Migration

### Native menu preparation

- Await `UIHostingMenuRuntime.prepare()` once during app setup to use all hosting menus synchronously. Calls to each instance's `prepare()` are then unnecessary.
- `menu(at:)` remains synchronous. It can throw `notPrepared` while shared preparation is in progress; instance `prepare()` can still wait for readiness when the runtime was not prepared during app setup.
- `contextMenuBridgeNotFound`, `configurationMethodUnavailable`, `configurationBuildFailed`, and `actionProviderMissing` have been replaced by `menuCoordinatorNotFound`. ABIBridge lookup and invocation errors propagate directly; `menuBuildFailed` still reports a missing native menu result.

### v0.2.0

These notes apply when upgrading from `v0.1.x` or earlier to `v0.2.0`.

- `requestUpdate(after:)` and `setNeedsUpdate()` have been removed. Menu updates are driven by SwiftUI reading `@Observable` source-of-truth objects.
- Move mutable menu inputs into an `@Observable` object and read that object from the SwiftUI menu view.
- Do not rebuild or reassign the menu when properties on the same source object change.
- Use `updateRootView(_:)` only when replacing the SwiftUI root view or switching to a different source object.
- If an update should be delayed, schedule the model mutation itself and let SwiftUI/Observation deliver the menu update.

## License

MIT. See [LICENSE](LICENSE).
