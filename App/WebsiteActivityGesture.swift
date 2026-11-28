import UIKit
import SwiftUI

/// Counts actual touches in WebKit without JavaScript messages or reading page
/// inputs. Never recognizes, cancels or delays a website's own gesture.
@MainActor final class WebsiteActivityGesture:UIGestureRecognizer,UIGestureRecognizerDelegate {
    private let activity:()->Void
    init(activity:@escaping()->Void) {
        self.activity=activity
        super.init(target:nil,action:nil)
        cancelsTouchesInView=false
        delaysTouchesBegan=false
        delaysTouchesEnded=false
        delegate=self
    }
    override func touchesBegan(_ touches:Set<UITouch>,with event:UIEvent){activity()}
    override func touchesMoved(_ touches:Set<UITouch>,with event:UIEvent){activity()}
    override func touchesEnded(_ touches:Set<UITouch>,with event:UIEvent){activity();state = .failed}
    override func touchesCancelled(_ touches:Set<UITouch>,with event:UIEvent){state = .failed}
    override func canPrevent(_ preventedGestureRecognizer:UIGestureRecognizer)->Bool {false}
    override func canBePrevented(by preventingGestureRecognizer:UIGestureRecognizer)->Bool {false}
    func gestureRecognizer(_ gestureRecognizer:UIGestureRecognizer,shouldRecognizeSimultaneouslyWith otherGestureRecognizer:UIGestureRecognizer)->Bool {true}
}

/// Observe window touches without placing a SwiftUI gesture above Buttons,
/// NavigationLinks, Lists or presented sheets. The probe itself never hits.
@MainActor struct WindowActivityObserver: UIViewRepresentable {
    let activity: () -> Void
    func makeUIView(context: Context) -> ActivityProbeView {
        ActivityProbeView(activity: activity)
    }
    func updateUIView(_ view: ActivityProbeView, context: Context) {
        view.activity = activity
    }
    static func dismantleUIView(_ view: ActivityProbeView, coordinator: ()) {
        view.detach()
    }
}

@MainActor final class ActivityProbeView: UIView {
    var activity: () -> Void
    private weak var observedWindow: UIWindow?
    private var observer: WebsiteActivityGesture?
    init(activity: @escaping () -> Void) {
        self.activity = activity
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }
    required init?(coder: NSCoder) { return nil }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window !== observedWindow else { return }
        detach()
        guard let window else { return }
        let observer = WebsiteActivityGesture { [weak self] in self?.activity() }
        window.addGestureRecognizer(observer)
        observedWindow = window
        self.observer = observer
    }
    func detach() {
        if let observer { observedWindow?.removeGestureRecognizer(observer) }
        observer = nil
        observedWindow = nil
    }
}
