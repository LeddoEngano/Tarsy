import AppKit
import Combine
import TarsyShared

/// Orchestrates the floating UltraContext overlay button lifecycle.
/// Only active in DEBUG builds — experimental feature.
@MainActor
final class OverlayManager: ObservableObject {
    private let windowObserver = TerminalWindowObserver()
    private let ultraContextClient = UltraContextClient()
    private let contextInjector = ContextInjector()

    private var overlayWindow: OverlayButtonWindow?
    private var pickerPanel: ContextPickerPanel?
    private var cancellables = Set<AnyCancellable>()
    private var isStarted = false

    func start() {
        guard !isStarted else { return }
        isStarted = true

        windowObserver.startObserving()

        // React to terminal focus changes
        windowObserver.$isTerminalFocused
            .removeDuplicates()
            .sink { [weak self] focused in
                if focused {
                    self?.showOverlayButton()
                } else {
                    self?.hideOverlayButton()
                    self?.dismissPicker()
                }
            }
            .store(in: &cancellables)

        // React to terminal window frame changes
        windowObserver.$terminalWindowFrame
            .removeDuplicates()
            .sink { [weak self] frame in
                guard frame != .zero else { return }
                self?.overlayWindow?.anchorToTerminalWindow(frame)
            }
            .store(in: &cancellables)

        #if DEBUG
        print("[OverlayManager] Started — watching for terminal windows")
        #endif
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false

        windowObserver.stopObserving()
        hideOverlayButton()
        dismissPicker()
        cancellables.removeAll()

        #if DEBUG
        print("[OverlayManager] Stopped")
        #endif
    }

    // MARK: - Overlay Button

    private func showOverlayButton() {
        guard overlayWindow == nil else {
            overlayWindow?.orderFront(nil)
            return
        }

        let window = OverlayButtonWindow { [weak self] in
            self?.onOverlayButtonClicked()
        }
        window.anchorToTerminalWindow(windowObserver.terminalWindowFrame)
        window.orderFront(nil)
        overlayWindow = window
    }

    private func hideOverlayButton() {
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
    }

    // MARK: - Context Picker

    private func onOverlayButtonClicked() {
        if pickerPanel != nil {
            dismissPicker()
            return
        }

        // Load sessions then show picker
        Task {
            await ultraContextClient.loadSessions()
            showPicker(sessions: ultraContextClient.sessions)
        }
    }

    private func showPicker(sessions: [UltraContextSession]) {
        dismissPicker()

        guard let buttonFrame = overlayWindow?.frame else { return }

        let panel = ContextPickerPanel(
            sessions: sessions,
            onSelect: { [weak self] session in
                self?.onContextSelected(session)
            },
            onDismiss: { [weak self] in
                self?.dismissPicker()
            }
        )
        panel.anchorToButton(buttonFrame)
        panel.makeKeyAndOrderFront(nil)
        pickerPanel = panel
    }

    private func dismissPicker() {
        pickerPanel?.orderOut(nil)
        pickerPanel = nil
    }

    // MARK: - Injection

    private func onContextSelected(_ session: UltraContextSession) {
        dismissPicker()

        Task {
            await contextInjector.inject(session: session, client: ultraContextClient)
        }
    }
}
