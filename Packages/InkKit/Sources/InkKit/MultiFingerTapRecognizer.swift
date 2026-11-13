import UIKit

/// Recognizes an exact N-finger single tap immediately on touch-up with zero multi-tap delay,
/// and avoids UIKit's built-in `UITapGestureRecognizer` failure dependencies with iPadOS's
/// system three-finger productivity tap recognizers.
final class MultiFingerTapRecognizer: UIGestureRecognizer {
    let numberOfTouchesRequired: Int
    private let maxDuration: TimeInterval = 0.35
    private let maxMovement: CGFloat = 28

    private var startPositions: [UITouch: CGPoint] = [:]
    private var activeTouches: Set<UITouch> = []
    private var maxTouchCount = 0
    private var startTime: TimeInterval = 0

    init(touchesRequired: Int, target: Any?, action: Selector?) {
        numberOfTouchesRequired = touchesRequired
        super.init(target: target, action: action)
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func reset() {
        super.reset()
        startPositions.removeAll()
        activeTouches.removeAll()
        maxTouchCount = 0
        startTime = 0
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard let view else { state = .failed; return }
        for touch in touches {
            if startPositions.isEmpty {
                startTime = touch.timestamp
            }
            startPositions[touch] = touch.location(in: view)
            activeTouches.insert(touch)
        }
        maxTouchCount = max(maxTouchCount, startPositions.count)
        if maxTouchCount > numberOfTouchesRequired {
            state = .failed
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let view else { state = .failed; return }
        for touch in touches {
            if touch.timestamp - startTime > maxDuration {
                state = .failed
                return
            }
            if let start = startPositions[touch],
               touch.location(in: view).distance(to: start) > maxMovement {
                state = .failed
                return
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        guard let view else { state = .failed; return }
        for touch in touches {
            if touch.timestamp - startTime > maxDuration {
                state = .failed
                return
            }
            if let start = startPositions[touch],
               touch.location(in: view).distance(to: start) > maxMovement {
                state = .failed
                return
            }
            activeTouches.remove(touch)
        }
        if activeTouches.isEmpty {
            state = (maxTouchCount == numberOfTouchesRequired) ? .ended : .failed
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        state = .failed
    }
}
