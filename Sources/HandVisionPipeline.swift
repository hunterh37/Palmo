import AVFoundation
import Vision
import CoreGraphics

/// Canonical hand joints used by the overlay and gesture logic.
enum HandJointID: CaseIterable, Hashable {
    case wrist
    case thumbKnuckle, thumbIntermediateBase, thumbIntermediateTip, thumbTip
    case indexKnuckle, indexIntermediateBase, indexIntermediateTip, indexTip
    case middleKnuckle, middleIntermediateBase, middleIntermediateTip, middleTip
    case ringKnuckle, ringIntermediateBase, ringIntermediateTip, ringTip
    case littleKnuckle, littleIntermediateBase, littleIntermediateTip, littleTip
}

/// A detected hand reduced to normalized (0...1, top-left origin) image points
/// plus the derived gesture facts the menu needs.
struct DetectedHand: Identifiable {
    let id = UUID()
    /// Normalized (0...1, top-left origin) screen points for overlay drawing.
    var points: [HandJointID: CGPoint]
    var isPinching: Bool
    /// Wrist to middle knuckle span in normalized units (depth proxy).
    var handSpan: CGFloat
    var isLeft: Bool

    /// Non-thumb fingers whose tip is meaningfully farther from the wrist
    /// than the middle of the finger: a proxy for "finger extended".
    var extendedFingerCount: Int {
        guard let wrist = points[.wrist] else { return 0 }
        let fingers: [(HandJointID, HandJointID)] = [
            (.indexTip, .indexIntermediateBase),
            (.middleTip, .middleIntermediateBase),
            (.ringTip, .ringIntermediateBase),
            (.littleTip, .littleIntermediateBase),
        ]
        var count = 0
        for (tip, pip) in fingers {
            guard let t = points[tip], let p = points[pip] else { continue }
            if dist(t, wrist) > dist(p, wrist) * 1.18 { count += 1 }
        }
        return count
    }

    /// Open palm held up: at least 4 extended fingers with fingertips above
    /// the wrist (top-left origin, smaller y is higher).
    var isOpenPalmUp: Bool {
        guard let wrist = points[.wrist] else { return false }
        guard extendedFingerCount >= 4 else { return false }
        let tips: [HandJointID] = [.indexTip, .middleTip, .ringTip, .littleTip]
        let above = tips.compactMap { points[$0] }.filter { $0.y < wrist.y }.count
        return above >= 3
    }

    var isFist: Bool { extendedFingerCount <= 1 }

    /// Center of the palm: average of the wrist and the four knuckles.
    var palmCenter: CGPoint? {
        let ids: [HandJointID] = [.wrist, .indexKnuckle, .middleKnuckle,
                                  .ringKnuckle, .littleKnuckle]
        let pts = ids.compactMap { points[$0] }
        guard pts.count >= 3 else { return nil }
        let sum = pts.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(pts.count), y: sum.y / CGFloat(pts.count))
    }

    var indexTip: CGPoint? { points[.indexTip] }
    var pinchPoint: CGPoint? {
        guard let t = points[.thumbTip], let i = points[.indexTip] else { return nil }
        return CGPoint(x: (t.x + i.x) / 2, y: (t.y + i.y) / 2)
    }

    private func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}

/// Runs `VNDetectHumanHandPoseRequest` on each camera frame. Lives off the
/// main actor: the capture delegate fires on `queue`, results are handed back
/// via `onFrame`.
final class HandVisionPipeline: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let queue = DispatchQueue(label: "dicyanin.handorbmenu.vision")

    /// Called on `queue` with the hands found in a frame (0, 1, or 2) and the
    /// pixel size of that frame (needed to undo aspect-fill cropping).
    var onFrame: (([DetectedHand], CGSize) -> Void)?

    /// Selfie mirroring (read on `queue`).
    var mirrored = true

    private let request: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 2
        return r
    }()

    private static let visionJoint: [HandJointID: VNHumanHandPoseObservation.JointName] = [
        .wrist: .wrist,
        .thumbKnuckle: .thumbCMC, .thumbIntermediateBase: .thumbMP,
        .thumbIntermediateTip: .thumbIP, .thumbTip: .thumbTip,
        .indexKnuckle: .indexMCP, .indexIntermediateBase: .indexPIP,
        .indexIntermediateTip: .indexDIP, .indexTip: .indexTip,
        .middleKnuckle: .middleMCP, .middleIntermediateBase: .middlePIP,
        .middleIntermediateTip: .middleDIP, .middleTip: .middleTip,
        .ringKnuckle: .ringMCP, .ringIntermediateBase: .ringPIP,
        .ringIntermediateTip: .ringDIP, .ringTip: .ringTip,
        .littleKnuckle: .littleMCP, .littleIntermediateBase: .littlePIP,
        .littleIntermediateTip: .littleDIP, .littleTip: .littleTip,
    ]

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return
        }
        let observations = request.results ?? []
        var hands = observations.compactMap { map($0) }
        hands.sort { ($0.points[.wrist]?.x ?? 0) < ($1.points[.wrist]?.x ?? 0) }
        if hands.count == 2 {
            hands[0].isLeft = true
            hands[1].isLeft = false
        }
        let frameSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer),
                               height: CVPixelBufferGetHeight(pixelBuffer))
        onFrame?(hands, frameSize)
    }

    private func map(_ observation: VNHumanHandPoseObservation) -> DetectedHand? {
        guard let raw = try? observation.recognizedPoints(.all) else { return nil }
        func pt(_ name: VNHumanHandPoseObservation.JointName, min: Float = 0.3) -> CGPoint? {
            guard let p = raw[name], p.confidence > min else { return nil }
            return CGPoint(x: p.location.x, y: p.location.y) // bottom-left origin, y up
        }
        // Without a confident wrist and middle knuckle the hand is degenerate
        // (sliding off-frame); treat as not detected.
        guard let wrist = pt(.wrist, min: 0.4),
              let middleMCP = pt(.middleMCP, min: 0.4) else { return nil }
        let handSpan = hypot(middleMCP.x - wrist.x, middleMCP.y - wrist.y)
        guard handSpan > 0.035 else { return nil }
        let margin: CGFloat = 0.02
        let inFrame = { (p: CGPoint) in
            p.x > margin && p.x < 1 - margin && p.y > margin && p.y < 1 - margin
        }
        guard inFrame(wrist) || inFrame(middleMCP) else { return nil }

        // Flip to top-left origin, honoring selfie mirroring.
        func flip(_ p: CGPoint) -> CGPoint {
            CGPoint(x: mirrored ? 1 - p.x : p.x, y: 1 - p.y)
        }
        var points: [HandJointID: CGPoint] = [:]
        for (id, vn) in Self.visionJoint {
            guard let p = pt(vn, min: 0.15) else { continue }
            points[id] = flip(p)
        }
        points[.wrist] = flip(wrist)

        let thumbTip = pt(.thumbTip) ?? wrist
        let indexTip = pt(.indexTip) ?? wrist
        let pinchDist = hypot(thumbTip.x - indexTip.x, thumbTip.y - indexTip.y)
        let isPinching = handSpan > 0.04 && pinchDist < handSpan * 0.45

        return DetectedHand(points: points,
                            isPinching: isPinching,
                            handSpan: handSpan,
                            isLeft: (points[.wrist]?.x ?? 0.5) < 0.5)
    }
}
