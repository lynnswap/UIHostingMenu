# UIHostingMenu

`UIHostingMenu` is a Swift package that builds UIKit `UIMenu` instances from SwiftUI menu content.

It provides an `NSHostingMenu`-style bridge for UIKit, letting controls such as `UIButton` and `UIBarButtonItem` reuse SwiftUI `Button`, `Divider`, and nested `Menu` declarations.

> [!WARNING]
> This package relies on undocumented APIs and runtime behavior, so extra care is needed before using it in App Store-bound projects.

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

let state = EditorMenuState()
let hostingMenu = UIHostingMenu(rootView: EditorMenuItems(state: state))

button.menu = try hostingMenu.menu()
button.showsMenuAsPrimaryAction = true

state.canReload = false
```

Declare menu content as SwiftUI that directly reads an `@Observable` source of truth. Do not rebuild or reassign the menu when the same source object changes; the visible menu follows SwiftUI/Observation reads.

Static menus work the same way:

```swift
button.menu = try UIHostingMenu(menuItems: {
    Button("Refresh") {}
    Divider()
    Menu("More") {
        Button("Share") {}
        Button("Delete", role: .destructive) {}
    }
}).menu()
```

## License

MIT. See [LICENSE](LICENSE).
