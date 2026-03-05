# UIHostingMenu

`UIHostingMenu` is a proof of concept that builds a `UIMenu` from SwiftUI menu content.

It mirrors the idea of `NSHostingMenu` and bridges SwiftUI menu items through `SwiftUI.ContextMenuBridge`.

> This package uses private API, so extra care is needed before using it in App Store-bound projects.

## Requirements

- iOS 18.0+
- Swift 6.2
- Xcode 17+

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

button.menu = try hostingMenu.menu()
button.showsMenuAsPrimaryAction = true
```

If your menu content changes:

```swift
hostingMenu.updateRootView(newMenuItemsView)
hostingMenu.setNeedsUpdate()
```

## License

MIT. See [LICENSE](LICENSE).
