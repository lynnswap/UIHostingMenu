# UIHostingMenu

`UIHostingMenu` is a proof of concept that builds a `UIMenu` from SwiftUI menu content.

It mirrors the idea of `NSHostingMenu` and bridges SwiftUI menu items through `SwiftUI.ContextMenuBridge`.

> This package relies on undocumented APIs and runtime behavior, so extra care is needed before using it in App Store-bound projects.

## Usage

```swift
import SwiftUI
import UIKit
import UIHostingMenu

let hostingMenu = UIHostingMenu(menuItems: {
    Button("Refresh") {}
    Divider()
    Menu("More") {
        Button("Share") {}
        Button("Delete", role: .destructive) {}
    }
})

try hostingMenu.install(on: button)
button.showsMenuAsPrimaryAction = true
```

`UIButton` integration now prefers `install(on:)`, which defers private configuration building until the interaction actually starts.

Legacy synchronous `menu()` materialization is only supported after an explicit warm-up:

```swift
let preparedMenu = try await hostingMenu.prepare(in: button)
button.menu = preparedMenu
```

Calling synchronous `menu()` during `viewDidLoad` without `prepare(in:)` is deprecated and returns `UIHostingMenuError.menuNotPrepared`.

## License

MIT. See [LICENSE](LICENSE).
