import MacLinkKit
import UIKit

/// What the trackpad should do with the fingers currently on the glass.
private enum TouchMode {
    case undecided
    case pointer
    /// A tap immediately followed by a press-and-hold: the left button is already down.
    case dragging
    case scrolling
    case pinching
    case threeFinger
}

@MainActor
protocol TrackpadTouchViewDelegate: AnyObject {
    func trackpad(_ view: TrackpadTouchView, didProduce event: PointerEvent)
    func trackpad(_ view: TrackpadTouchView, didSwipeThreeFingers direction: TrackpadTouchView.SwipeDirection)
    func trackpadDidClick(_ view: TrackpadTouchView, button: MouseButton)
}

/// Raw multi-touch surface behind the trackpad.
///
/// Written against `touchesBegan/Moved/Ended` rather than gesture recognisers on purpose: recognisers
/// add a delay while they decide who wins, and that delay is exactly the thing that makes a remote
/// trackpad feel broken. Here every sample is used the moment it arrives, and motion is coalesced
/// onto the display refresh so we send at most one packet per frame.
final class TrackpadTouchView: UIView {

    enum SwipeDirection { case up, down, left, right }

    weak var delegate: TrackpadTouchViewDelegate?

    var sensitivity: Double = 1.4
    var naturalScrolling = true
    var scrollSpeed: Double = 1.0
    var tapToClick = true
    /// Width of the Mac's desktop in points, reported by the host. Motion is scaled by
    /// desktop-width / trackpad-width so one swipe crosses the same fraction of the screen whether
    /// the Mac is a 13" laptop or driving a 4K monitor.
    var desktopWidth: Double = 0
    var hapticsEnabled = true

    // Gesture thresholds. `tapSlop` is generous because thumbs are imprecise, and `tapDuration`
    // matches the system's own tap window.
    private let tapSlop: CGFloat = 16
    private let tapDuration: TimeInterval = 0.3
    private let dragChainWindow: TimeInterval = 0.35
    private let pinchDecisionThreshold: CGFloat = 14

    private var mode: TouchMode = .undecided
    private var activeTouches: [UITouch] = []
    private var gestureStartTime: TimeInterval = 0
    private var gestureStartCentroid: CGPoint = .zero
    private var maxFingerCount = 0
    private var accumulatedDistance: CGFloat = 0

    private var lastCentroid: CGPoint = .zero
    private var lastSampleTime: TimeInterval = 0
    private var lastPinchDistance: CGFloat = 0
    private var pinchBaselineDistance: CGFloat = 0

    private var lastTapEndTime: TimeInterval = 0
    private var lastTapEndPoint: CGPoint = .zero

    private var didStartScrollPhase = false
    private var threeFingerAccumulated: CGVector = .zero
    private var didFireThreeFingerSwipe = false

    // Coalescing
    private var pendingMove = CGVector.zero
    private var pendingScroll = CGVector.zero
    private var pendingZoom: Double = 0
    private var displayLink: CADisplayLink?

    private let impact = UIImpactFeedbackGenerator(style: .light)
    private let rigidImpact = UIImpactFeedbackGenerator(style: .rigid)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isUserInteractionEnabled = true
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            stopDisplayLink()
        } else {
            impact.prepare()
        }
    }

    // MARK: - Touch handling

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        let wasEmpty = activeTouches.isEmpty
        for touch in touches where !activeTouches.contains(touch) {
            activeTouches.append(touch)
        }
        maxFingerCount = max(maxFingerCount, activeTouches.count)

        let now = ProcessInfo.processInfo.systemUptime
        let centroid = self.centroid()

        if wasEmpty {
            gestureStartTime = now
            gestureStartCentroid = centroid
            accumulatedDistance = 0
            threeFingerAccumulated = .zero
            didFireThreeFingerSwipe = false

            // A quick tap followed straight away by a press means "pick this up and drag it".
            if activeTouches.count == 1,
               now - lastTapEndTime < dragChainWindow,
               hypot(centroid.x - lastTapEndPoint.x, centroid.y - lastTapEndPoint.y) < tapSlop * 2 {
                mode = .dragging
                delegate?.trackpad(self, didProduce: .button(button: .left, action: .down, clickCount: 1))
                if hapticsEnabled { rigidImpact.impactOccurred() }
            } else {
                mode = .undecided
            }
        } else if mode != .dragging {
            // A finger landed mid-gesture, so re-evaluate what this is.
            mode = .undecided
        }

        lastCentroid = centroid
        lastSampleTime = now
        if activeTouches.count == 2 {
            pinchBaselineDistance = pinchDistance()
            lastPinchDistance = pinchBaselineDistance
        }
        startDisplayLink()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
        guard !activeTouches.isEmpty else { return }

        let now = ProcessInfo.processInfo.systemUptime
        let centroid = self.centroid()
        let delta = CGVector(dx: centroid.x - lastCentroid.x, dy: centroid.y - lastCentroid.y)
        let dt = max(now - lastSampleTime, 1.0 / 240.0)
        accumulatedDistance += hypot(delta.dx, delta.dy)

        switch activeTouches.count {
        case 1:
            if mode == .undecided { mode = .pointer }
            if mode == .pointer || mode == .dragging {
                let scaled = accelerate(delta, dt: dt)
                pendingMove.dx += scaled.dx
                pendingMove.dy += scaled.dy
            }

        case 2:
            let distance = pinchDistance()
            if mode == .undecided || mode == .scrolling || mode == .pinching {
                // Decide once per gesture: if the fingers are separating faster than they are
                // travelling together, it is a pinch; otherwise it is a scroll.
                if mode == .undecided {
                    let spread = abs(distance - pinchBaselineDistance)
                    let travel = hypot(centroid.x - gestureStartCentroid.x, centroid.y - gestureStartCentroid.y)
                    if spread > pinchDecisionThreshold, spread > travel {
                        mode = .pinching
                    } else if travel > 3 || spread > pinchDecisionThreshold {
                        mode = .scrolling
                    }
                }

                if mode == .pinching {
                    if lastPinchDistance > 0 {
                        pendingZoom += Double((distance - lastPinchDistance) / max(lastPinchDistance, 1))
                    }
                } else if mode == .scrolling {
                    let direction: CGFloat = naturalScrolling ? 1 : -1
                    pendingScroll.dx += delta.dx * direction * scrollSpeed
                    pendingScroll.dy += delta.dy * direction * scrollSpeed
                }
            }
            lastPinchDistance = distance

        case 3:
            mode = .threeFinger
            threeFingerAccumulated.dx += delta.dx
            threeFingerAccumulated.dy += delta.dy
            evaluateThreeFingerSwipe()

        default:
            break
        }

        lastCentroid = centroid
        lastSampleTime = now
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        finish(touches, cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        finish(touches, cancelled: true)
    }

    private func finish(_ touches: Set<UITouch>, cancelled: Bool) {
        for touch in touches {
            activeTouches.removeAll { $0 === touch }
        }
        guard activeTouches.isEmpty else {
            // Fingers still down; keep the gesture alive but re-baseline so lifting one finger does
            // not register as a jump.
            lastCentroid = centroid()
            if activeTouches.count == 2 { lastPinchDistance = pinchDistance() }
            return
        }

        flushPending()
        let now = ProcessInfo.processInfo.systemUptime
        let duration = now - gestureStartTime

        switch mode {
        case .dragging:
            delegate?.trackpad(self, didProduce: .button(button: .left, action: .up, clickCount: 1))

        case .scrolling:
            // Only close the phase if one was actually opened, or the Mac gets an `ended` with no
            // matching `began` and some apps leave a scroll view stuck mid-rubber-band.
            if didStartScrollPhase {
                delegate?.trackpad(self, didProduce: .scroll(dx: 0, dy: 0, phase: cancelled ? .cancelled : .ended))
            }

        case .pinching:
            delegate?.trackpad(self, didProduce: .zoom(magnification: 0, phase: cancelled ? .cancelled : .ended))

        case .undecided, .pointer:
            // Nothing decided it into a drag or a scroll, so it was a tap.
            //
            // Measured as net displacement from where the finger landed, NOT as accumulated path
            // length. A real fingertip jitters a point or two per sample, and at 120 Hz a perfectly
            // still 150 ms tap piles up 20+ points of "movement" — enough to fail a 12 point slop
            // test every time. Path length grows with the sample rate; displacement does not.
            let drift = hypot(
                lastCentroid.x - gestureStartCentroid.x,
                lastCentroid.y - gestureStartCentroid.y
            )
            if !cancelled, tapToClick, duration < tapDuration, drift < tapSlop {
                let button: MouseButton
                switch maxFingerCount {
                case 1: button = .left
                case 2: button = .right
                default: button = .middle
                }
                emitClick(button)
                lastTapEndTime = now
                lastTapEndPoint = gestureStartCentroid
            }

        case .threeFinger:
            break
        }

        mode = .undecided
        maxFingerCount = 0
        didStartScrollPhase = false
        accumulatedDistance = 0
        pinchBaselineDistance = 0
        lastPinchDistance = 0
        stopDisplayLink()
    }

    private func emitClick(_ button: MouseButton) {
        if hapticsEnabled { impact.impactOccurred() }
        delegate?.trackpad(self, didProduce: .button(button: button, action: .down, clickCount: 1))
        delegate?.trackpad(self, didProduce: .button(button: button, action: .up, clickCount: 1))
        delegate?.trackpadDidClick(self, button: button)
    }

    private func evaluateThreeFingerSwipe() {
        guard !didFireThreeFingerSwipe else { return }
        let threshold: CGFloat = 42
        let dx = threeFingerAccumulated.dx
        let dy = threeFingerAccumulated.dy

        let direction: SwipeDirection?
        if abs(dx) > abs(dy), abs(dx) > threshold {
            direction = dx > 0 ? .right : .left
        } else if abs(dy) > threshold {
            direction = dy > 0 ? .down : .up
        } else {
            direction = nil
        }

        guard let direction else { return }
        didFireThreeFingerSwipe = true
        if hapticsEnabled { rigidImpact.impactOccurred() }
        delegate?.trackpad(self, didSwipeThreeFingers: direction)
    }

    // MARK: - Geometry

    private func centroid() -> CGPoint {
        guard !activeTouches.isEmpty else { return lastCentroid }
        var sum = CGPoint.zero
        for touch in activeTouches {
            let point = touch.location(in: self)
            sum.x += point.x
            sum.y += point.y
        }
        let count = CGFloat(activeTouches.count)
        return CGPoint(x: sum.x / count, y: sum.y / count)
    }

    private func pinchDistance() -> CGFloat {
        guard activeTouches.count >= 2 else { return 0 }
        let a = activeTouches[0].location(in: self)
        let b = activeTouches[1].location(in: self)
        return hypot(a.x - b.x, a.y - b.y)
    }

    /// Speed-dependent gain, so slow movement is precise and a flick crosses the screen.
    ///
    /// The base term is the ratio of the Mac's desktop width to the trackpad's width. Without it a
    /// finger travelling the full width of the pad moves the cursor only that many points — roughly
    /// a quarter of a laptop screen — which is what made this feel sluggish. With it, a full-width
    /// swipe at moderate speed crosses roughly the whole desktop.
    private func accelerate(_ delta: CGVector, dt: TimeInterval) -> CGVector {
        let magnitude = hypot(delta.dx, delta.dy)
        guard magnitude > 0 else { return .zero }

        let padWidth = max(Double(bounds.width), 1)
        let base = desktopWidth > 0 ? min(max(desktopWidth / padWidth, 1.5), 8.0) : 3.5

        let pointsPerSecond = Double(magnitude) / dt
        // Normalised around 900 pt/s, flattened with a fractional power, and clamped so one stray
        // fast sample cannot throw the cursor across three displays.
        let gain = min(max(pow(pointsPerSecond / 900.0, 0.6), 0.5), 2.2)
        let factor = CGFloat(sensitivity * base * gain)
        return CGVector(dx: delta.dx * factor, dy: delta.dy * factor)
    }

    // MARK: - Coalescing

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(flushTick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func flushTick() {
        flushPending()
    }

    private func flushPending() {
        if pendingMove != .zero {
            delegate?.trackpad(self, didProduce: .move(dx: Double(pendingMove.dx), dy: Double(pendingMove.dy)))
            pendingMove = .zero
        }

        if pendingScroll != .zero {
            let phase: GesturePhase = didStartScrollPhase ? .changed : .began
            didStartScrollPhase = true
            delegate?.trackpad(self, didProduce: .scroll(
                dx: Double(pendingScroll.dx),
                dy: Double(pendingScroll.dy),
                phase: phase
            ))
            pendingScroll = .zero
        }

        if pendingZoom != 0 {
            delegate?.trackpad(self, didProduce: .zoom(magnification: pendingZoom, phase: .changed))
            pendingZoom = 0
        }
    }
}
