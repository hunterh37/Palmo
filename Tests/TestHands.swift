import CoreGraphics
import Foundation

/// Builders for synthetic `DetectedHand`s with geometrically valid joints,
/// so gesture predicates (`isFist`, `isOpenPalmUp`, …) derive naturally from
/// the same math the Vision pipeline output would.
///
/// All positions are normalized (0...1) with a top-left origin. Tests use a
/// square video size (aspect == 1) so aspect-corrected space equals
/// normalized space and distances are easy to reason about.
enum TestHands {
    static let squareVideo = CGSize(width: 1000, height: 1000)

    /// Non-thumb finger tip/pip/knuckle triples.
    private static let fingers: [(tip: HandJointID, pip: HandJointID, knuckle: HandJointID, xOff: CGFloat)] = [
        (.indexTip, .indexIntermediateBase, .indexKnuckle, -0.045),
        (.middleTip, .middleIntermediateBase, .middleKnuckle, -0.015),
        (.ringTip, .ringIntermediateBase, .ringKnuckle, 0.015),
        (.littleTip, .littleIntermediateBase, .littleKnuckle, 0.045),
    ]

    /// Open palm held up: all four fingers extended above the wrist.
    static func openPalm(wrist: CGPoint = CGPoint(x: 0.5, y: 0.7)) -> DetectedHand {
        var points: [HandJointID: CGPoint] = [.wrist: wrist]
        for f in fingers {
            points[f.knuckle] = CGPoint(x: wrist.x + f.xOff, y: wrist.y - 0.15)
            points[f.pip] = CGPoint(x: wrist.x + f.xOff, y: wrist.y - 0.22)
            points[f.tip] = CGPoint(x: wrist.x + f.xOff, y: wrist.y - 0.35)
        }
        points[.thumbKnuckle] = CGPoint(x: wrist.x - 0.08, y: wrist.y - 0.05)
        points[.thumbTip] = CGPoint(x: wrist.x - 0.14, y: wrist.y - 0.14)
        return DetectedHand(points: points, isPinching: false, handSpan: 0.15,
                            isLeft: false)
    }

    /// A true fist: every finger curled, all tips tracked.
    static func fist(wrist: CGPoint = CGPoint(x: 0.5, y: 0.7)) -> DetectedHand {
        var points: [HandJointID: CGPoint] = [.wrist: wrist]
        for f in fingers {
            points[f.knuckle] = CGPoint(x: wrist.x + f.xOff, y: wrist.y - 0.15)
            points[f.pip] = CGPoint(x: wrist.x + f.xOff, y: wrist.y - 0.16)
            // Tip curls back near the wrist: closer than pip * 1.18.
            points[f.tip] = CGPoint(x: wrist.x + f.xOff, y: wrist.y - 0.08)
        }
        points[.thumbKnuckle] = CGPoint(x: wrist.x - 0.08, y: wrist.y - 0.05)
        points[.thumbTip] = CGPoint(x: wrist.x - 0.09, y: wrist.y - 0.08)
        return DetectedHand(points: points, isPinching: false, handSpan: 0.15,
                            isLeft: false)
    }

    /// Index finger extended with its tip at `tip`; other fingers curled.
    static func pointing(at tip: CGPoint) -> DetectedHand {
        let wrist = CGPoint(x: tip.x, y: tip.y + 0.35)
        var hand = fist(wrist: wrist)
        hand.points[.indexIntermediateBase] = CGPoint(x: tip.x, y: wrist.y - 0.22)
        hand.points[.indexTip] = tip
        return hand
    }

    /// Peace sign: index + middle extended, ring + little curled.
    static func peaceSign(wrist: CGPoint = CGPoint(x: 0.5, y: 0.7)) -> DetectedHand {
        var hand = fist(wrist: wrist)
        for f in fingers.prefix(2) {
            hand.points[f.pip] = CGPoint(x: wrist.x + f.xOff, y: wrist.y - 0.22)
            hand.points[f.tip] = CGPoint(x: wrist.x + f.xOff, y: wrist.y - 0.35)
        }
        return hand
    }

    /// Thumbs-up: all fingers curled, thumb clearly above the wrist.
    static func thumbsUp(wrist: CGPoint = CGPoint(x: 0.5, y: 0.7)) -> DetectedHand {
        var hand = fist(wrist: wrist)
        hand.points[.thumbKnuckle] = CGPoint(x: wrist.x, y: wrist.y - 0.10)
        hand.points[.thumbTip] = CGPoint(x: wrist.x, y: wrist.y - 0.20)
        return hand
    }

    /// Pinching hand with the pinch point (thumb/index midpoint) at `point`.
    static func pinching(at point: CGPoint) -> DetectedHand {
        var hand = openPalm(wrist: CGPoint(x: point.x, y: point.y + 0.3))
        hand.points[.thumbTip] = point
        hand.points[.indexTip] = point
        hand.isPinching = true
        return hand
    }
}
