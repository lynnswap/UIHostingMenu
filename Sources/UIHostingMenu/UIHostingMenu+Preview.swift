import SwiftUI
import UIKit

@MainActor
private final class UIHostingMenuPreviewViewController: UIViewController {
    private let button = UIButton(type: .system)
    private let statusLabel = UILabel()
    private var didConfigureMenu = false
    private let defaultBackgroundColor = UIColor.systemBackground

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = defaultBackgroundColor
        configureViews()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didConfigureMenu else { return }
        didConfigureMenu = true
        configureMenu()
    }

    private func configureViews() {
        button.configuration = .filled()
        button.configuration?.title = "Open UIHostingMenu"
        button.showsMenuAsPrimaryAction = true

        statusLabel.textAlignment = .center
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0
        statusLabel.text = "Tap button to open menu"

        let stack = UIStackView(arrangedSubviews: [button, statusLabel])
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    private func configureMenu() {
        let hostingMenu = UIHostingMenu(menuItems: { [weak self] in
            Button {
                self?.applySelectionState(
                    text: "Selected: Indigo",
                    color: .systemIndigo
                )
            } label: {
                Label {
                    Text("Indigo")
                } icon: {
                    Image(systemName: "circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.indigo)
                }
            }
            Divider()
            Menu("More") {
                Button {
                    self?.applySelectionState(
                        text: "Selected: Purple",
                        color: .systemPurple
                    )
                } label: {
                    Label {
                        Text("Purple")
                    } icon: {
                        Image(systemName: "circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.purple)
                    }
                }
                Button(role: .destructive) {
                    self?.applySelectionState(
                        text: "Selected: Red",
                        color: .systemRed
                    )
                } label:{
                    Label {
                        Text("Red")
                    } icon: {
                        Image(systemName: "circle.fill")
                    }
                }
            }
        })

        do {
            button.menu = try hostingMenu.menu()
        } catch {
            let message = "Menu build failed: \(error.localizedDescription)"
            button.menu = nil
            statusLabel.text = message
        }
    }

    private func applySelectionState(text: String, color: UIColor) {
        let targetBackgroundColor = color.withAlphaComponent(0.3)

        UIView.transition(
            with: statusLabel,
            duration: 0.18,
            options: [.transitionCrossDissolve, .allowUserInteraction]
        ) {
            self.statusLabel.text = text
        }

        UIView.animate(
            withDuration: 0.28,
            delay: 0,
            options: [.curveEaseInOut, .allowUserInteraction]
        ) {
            self.view.backgroundColor = targetBackgroundColor
        }
    }
}

#Preview("UIHostingMenu UIKit Preview") {
    UIHostingMenuPreviewViewController()
}
