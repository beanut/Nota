import Combine
import SwiftUI
import UIKit

/// Presentation mode: what an external display or AirPlay screen shows while it's connected. Instead of the
/// whole iPad screen, it shows only the page being worked on, read-only, fitted to the display, with no
/// chrome, and the laser pointer on it (`LaserTrail`).
///
/// InkKit holds the model and the view; the host app only connects the display. Each editor presents its
/// current page when it appears and whenever the page changes, so the display follows whichever note was
/// shown or written on last; ink shows on the display as each stroke is finished, and the laser as it moves.
///
/// ```swift
/// // In the app's external-display scene:
/// window.rootViewController = UIHostingController(rootView: PresentationMirror().inkTheme(theme))
/// ```
@MainActor
public final class InkPresentation: ObservableObject {
    /// The presentation every editor reports to and every mirror shows.
    public static let shared = InkPresentation()

    /// The page being presented, or nil when no editor is open.
    @Published public private(set) var page: CanvasDocument?
    /// Whether a display is showing the mirror now. Set by the host's external-display scene; the editor
    /// shows that it's presenting while it's on.
    @Published public var isMirroring = false
    /// The laser on `page`, as the canvas last drew it.
    public private(set) var laser = LaserTrail()

    /// Posted (object: the presentation) whenever `laser` changes.
    public static let laserDidChangeNotification = Notification.Name("InkPresentation.laserDidChange")

    public init() {}

    /// Makes `page` the one shown on the display.
    public func present(_ page: CanvasDocument) {
        guard self.page !== page else { return }
        self.page = page
        updateLaser(LaserTrail())
    }

    /// Stops presenting `page`, if it's the one being presented: its editor went away.
    public func stopPresenting(_ page: CanvasDocument) {
        guard self.page === page else { return }
        self.page = nil
        updateLaser(LaserTrail())
    }

    /// The laser on `page` changed. Ignored unless `page` is the one being presented.
    func laserDidChange(_ trail: LaserTrail, on page: CanvasDocument) {
        guard page === self.page, trail != laser else { return }
        updateLaser(trail)
    }

    private func updateLaser(_ trail: LaserTrail) {
        guard trail != laser else { return }
        laser = trail
        NotificationCenter.default.post(name: Self.laserDidChangeNotification, object: self)
    }
}

/// Where the mirror puts the page on the display: the whole page, as large as fits inside `margin`, centred.
enum PageMirrorLayout {
    /// Space kept round the page, in display points.
    static let margin: CGFloat = 24
    /// The most pixels across the page image is rendered at, so a 4K display doesn't render 8K pages.
    static let maximumPixelWidth = 4096

    static func transform(page: CGRect, in bounds: CGRect) -> ViewTransform {
        let m = margin
        return ViewTransform.fitting(page: page, in: bounds, insets: UIEdgeInsets(top: m, left: m, bottom: m, right: m),
                                     scaleRange: .leastNonzeroMagnitude ... .greatestFiniteMagnitude)
    }

    /// How many pixels wide to render the page to show it sharp at `transform` on a `displayScale` display.
    static func pixelWidth(page: CGRect, transform: ViewTransform, displayScale: CGFloat) -> Int {
        let width = (page.width * transform.scale * max(displayScale, 1)).rounded(.up)
        guard width.isFinite, width >= 1 else { return 1 }
        return min(Int(width), maximumPixelWidth)
    }
}

// MARK: - The mirror

/// The external display's view: the presented page and its laser, or a quiet hint while no note is open.
public struct PresentationMirror: View {
    @ObservedObject private var presentation: InkPresentation
    @Environment(\.inkTheme) private var theme

    /// Shows `presentation`, or `InkPresentation.shared` if it's nil.
    @MainActor public init(presentation: InkPresentation? = nil) {
        self.presentation = presentation ?? .shared
    }

    public var body: some View {
        ZStack {
            theme.color(\.desk)
            if presentation.page == nil {
                Text("Open a note on your iPad to present it here.")
                    .font(theme.headlineFont)
                    .foregroundStyle(theme.color(\.textSecondary))
            } else {
                PageMirrorRepresentable(presentation: presentation, theme: theme)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true) // a non-interactive display
    }
}

private struct PageMirrorRepresentable: UIViewRepresentable {
    let presentation: InkPresentation
    let theme: InkTheme

    func makeUIView(context _: Context) -> PageMirrorView {
        PageMirrorView(presentation: presentation, theme: theme)
    }

    func updateUIView(_ view: PageMirrorView, context _: Context) {
        view.apply(theme)
    }
}

/// Draws the presented page, fitted, and the laser over it. The page is rendered in the background with
/// `PageRenderer` (template, objects, ink and tape, as a thumbnail is) each time it changes, a render at a
/// time; the laser has its own layer and follows every move.
final class PageMirrorView: UIView {
    private let presentation: InkPresentation
    private var theme: InkTheme
    private let pageLayer = CALayer()
    private let laserView = LaserView()
    private var observation: AnyCancellable?
    private var laserObserver: NSObjectProtocol?
    private weak var page: CanvasDocument?
    private var renderInFlight = false
    private var renderRequested = false
    private var renderedSize = CGSize.zero
    private let renderQueue = DispatchQueue(label: "InkPresentation.render", qos: .userInitiated)

    init(presentation: InkPresentation, theme: InkTheme) {
        self.presentation = presentation
        self.theme = theme
        super.init(frame: .zero)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        pageLayer.contentsGravity = .resize
        pageLayer.shadowOpacity = 0.18
        pageLayer.shadowRadius = 8
        pageLayer.shadowOffset = CGSize(width: 0, height: 2)
        layer.addSublayer(pageLayer)
        laserView.color = theme.laser.uiColor
        laserView.pageTransform = { [weak self] in self?.pageTransform ?? ViewTransform() }
        addSubview(laserView)
        observation = presentation.$page.sink { [weak self] page in
            // Sent before the change is stored.
            DispatchQueue.main.async { self?.show(page) }
        }
        laserObserver = NotificationCenter.default.addObserver(forName: InkPresentation.laserDidChangeNotification,
                                                               object: presentation, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.laserDidChange() }
        }
        show(presentation.page)
    }

    deinit {
        if let laserObserver {
            NotificationCenter.default.removeObserver(laserObserver)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ theme: InkTheme) {
        self.theme = theme
        laserView.color = theme.laser.uiColor
        pageLayer.shadowColor = theme.shadow.resolvedColor(with: traitCollection).cgColor
    }

    /// The page's transform into this view.
    var pageTransform: ViewTransform {
        guard let page else { return ViewTransform() }
        return PageMirrorLayout.transform(page: page.pageBounds, in: bounds)
    }

    private func show(_ newPage: CanvasDocument?) {
        guard newPage !== page else { return }
        page?.stopObservingChanges(self)
        page = newPage
        pageLayer.contents = nil
        newPage?.observeChanges(self) { [weak self] in self?.requestRender() }
        laserDidChange()
        setNeedsLayout()
        requestRender()
    }

    private func laserDidChange() {
        laserView.trail = presentation.page === page ? presentation.laser : LaserTrail()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        laserView.frame = bounds
        let frame = page.map { pageTransform.toView($0.pageBounds) } ?? .zero
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pageLayer.frame = frame
        pageLayer.shadowPath = CGPath(rect: CGRect(origin: .zero, size: frame.size), transform: nil)
        pageLayer.shadowColor = theme.shadow.resolvedColor(with: traitCollection).cgColor
        CATransaction.commit()
        if frame.size != renderedSize {
            requestRender()
        }
    }

    private func requestRender() {
        guard page != nil, bounds.width > 0, bounds.height > 0 else { return }
        if renderInFlight {
            renderRequested = true
        } else {
            startRender()
        }
    }

    private func startRender() {
        guard let page else { return }
        let snapshot = page.snapshot()
        let transform = pageTransform
        let size = transform.toView(page.pageBounds).size
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 2
        let width = PageMirrorLayout.pixelWidth(page: page.pageBounds, transform: transform, displayScale: scale)
        let palette = theme.palette(for: snapshot.template.paper)
        renderInFlight = true
        renderQueue.async { [weak self] in
            let image = PageRenderer.image(of: snapshot, pixelWidth: width) { _ in palette }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                renderInFlight = false
                if let image, self.page?.id == snapshot.pageID {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    pageLayer.contents = image
                    CATransaction.commit()
                    renderedSize = size
                }
                if renderRequested {
                    renderRequested = false
                    startRender()
                }
            }
        }
    }
}
