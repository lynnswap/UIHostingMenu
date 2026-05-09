# UIHostingMenu

`UIHostingMenu` is a Swift package that builds UIKit `UIMenu` instances from SwiftUI menu content.

It provides an `NSHostingMenu`-style bridge for UIKit, letting controls such as `UIButton` and `UIBarButtonItem` reuse SwiftUI `Button`, `Divider`, and nested `Menu` declarations.

> [!WARNING]
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

button.menu = try hostingMenu.menu()
button.showsMenuAsPrimaryAction = true
```

## License

MIT. See [LICENSE](LICENSE).
