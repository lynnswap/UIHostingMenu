import Observation
import SwiftUI
import UIKit

@MainActor
@Observable
private final class UIHostingMenuDemoModel {
    var number = 3
    var selectedColor: UIHostingMenuDemoColorSelection?
}

private enum UIHostingMenuDemoColorSelection: String {
    case indigo = "Indigo"
    case purple = "Purple"
    case red = "Red"
    case blue = "Blue"

    var uiColor: UIColor {
        switch self {
        case .indigo: return .systemIndigo
        case .purple: return .systemPurple
        case .red: return .systemRed
        case .blue: return .systemBlue
        }
    }
}

@MainActor
private struct UIHostingMenuDemoMenuItemsView: View {
    var model: UIHostingMenuDemoModel

    var body: some View {
        Stepper(
            value: Bindable(model).number,
            in: 0...20
        ) {
            Text("Number: \(model.number.formatted(.number))")
        }
        Divider()

        Button {
            model.selectedColor = .blue
        } label: {
            Label {
                Text("Blue")
            } icon: {
                Image(systemName: "circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.blue)
            }
        }
        .menuActionDismissBehavior(.disabled)
        Menu("More") {
            Button {
                model.selectedColor = .purple
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
                model.selectedColor = .red
            } label: {
                Label {
                    Text("Red")
                } icon: {
                    Image(systemName: "circle.fill")
                }
            }
            Menu("Moana") {
                Button {
                    model.selectedColor = .indigo
                } label: {
                    Label {
                        Text("Indigo")
                    } icon: {
                        Image(systemName: "circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.indigo)
                    }
                }
            }
        }
    }
}

@MainActor
public struct UIHostingMenuDemoView: UIViewControllerRepresentable {
    public init() {}

    public func makeUIViewController(context: Context) -> UINavigationController {
        UINavigationController(rootViewController: UIHostingMenuDemoViewController())
    }

    public func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}
}

@MainActor
public final class UIHostingMenuDemoViewController: UIViewController {
    private let button = UIButton(type: .system)
    private let statusLabel = UILabel()
    private let navigationNumberLabel = UILabel()
    private var didConfigureMenu = false
    private var lastAppliedSelectedColor: UIHostingMenuDemoColorSelection?
    private let defaultBackgroundColor = UIColor.systemBackground
    private let model = UIHostingMenuDemoModel()
    private lazy var hostingMenu = UIHostingMenu(rootView: makeMenuItemsView())

    public init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = defaultBackgroundColor
        configureViews()
        startObservationLoop()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didConfigureMenu else { return }
        didConfigureMenu = true
        configureMenu()
    }

    private func configureViews() {
        navigationItem.largeTitleDisplayMode = .never
        navigationNumberLabel.textAlignment = .center
        navigationNumberLabel.textColor = .label
        navigationNumberLabel.font = .monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
        navigationNumberLabel.text = "Number: \(model.number)"
        navigationNumberLabel.accessibilityIdentifier = "MiniApp.navigationNumberLabel"
        navigationItem.titleView = navigationNumberLabel

        button.configuration = .filled()
        button.configuration?.title = "Open UIHostingMenu"
        button.showsMenuAsPrimaryAction = true
        button.accessibilityIdentifier = "MiniApp.openMenuButton"

        statusLabel.textAlignment = .center
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0
        statusLabel.text = "Tap button to open menu"
        statusLabel.accessibilityIdentifier = "MiniApp.statusLabel"

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
        hostingMenu.updateRootView(makeMenuItemsView())

        do {
            button.menu = try hostingMenu.menu()
        } catch {
            let message = "Menu build failed: \(error.localizedDescription)"
            button.menu = nil
            statusLabel.text = message
        }
    }

    private func startObservationLoop() {
        withObservationTracking { [weak self] in
            guard let self else { return }
            self.applyNumberText(self.model.number)
            self.applySelectedColorState(self.model.selectedColor)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.startObservationLoop()
            }
        }
    }

    private func makeMenuItemsView() -> UIHostingMenuDemoMenuItemsView {
        UIHostingMenuDemoMenuItemsView(model: model)
    }

    private func applySelectionState(text: String, color: UIColor) {
        let targetBackgroundColor = color.withAlphaComponent(0.3)

        applyStatusText(text)

        UIView.animate(
            withDuration: 0.28,
            delay: 0,
            options: [.curveEaseInOut, .allowUserInteraction]
        ) {
            self.view.backgroundColor = targetBackgroundColor
        }
    }

    private func applyStatusText(_ text: String) {
        UIView.transition(
            with: statusLabel,
            duration: 0.18,
            options: [.transitionCrossDissolve, .allowUserInteraction]
        ) {
            self.statusLabel.text = text
        }
    }

    private func applyNumberText(_ number: Int) {
        UIView.transition(
            with: navigationNumberLabel,
            duration: 0.18,
            options: [.transitionCrossDissolve, .allowUserInteraction]
        ) {
            self.navigationNumberLabel.text = "Number: \(number)"
        }
    }

    private func applySelectedColorState(_ selection: UIHostingMenuDemoColorSelection?) {
        guard selection != lastAppliedSelectedColor else { return }
        lastAppliedSelectedColor = selection

        guard let selection else {
            applyStatusText("Tap button to open menu")
            UIView.animate(
                withDuration: 0.28,
                delay: 0,
                options: [.curveEaseInOut, .allowUserInteraction]
            ) {
                self.view.backgroundColor = self.defaultBackgroundColor
            }
            return
        }

        applySelectionState(
            text: "Selected: \(selection.rawValue)",
            color: selection.uiColor
        )
    }
}
