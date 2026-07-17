import SwiftUI
import SceneKit

/// Palmo's 3D avatar: a chubby low-poly "bubble mesh" hand with a kawaii
/// face on the palm. Flat-shaded faceted geometry (generated procedurally,
/// no assets), glossy bean eyes that blink, a tiny mouth, blush cheeks, and
/// squash-and-stretch idle motion. Mirrors BuddyView's mood/gaze API so it
/// can drop into any call site.
struct PalmoAvatarView: NSViewRepresentable {
    var mood: BuddyMood = .idle
    /// Normalized -1...1 gaze target.
    var gaze: CGPoint = .zero
    /// Trigger a little greeting wave when this flips to true.
    var waving: Bool = false

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.allowsCameraControl = false
        view.rendersContinuously = true
        view.antialiasingMode = .multisampling4X
        view.scene = context.coordinator.buildScene()
        context.coordinator.startIdle()
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        context.coordinator.apply(mood: mood, gaze: gaze, waving: waving)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator {
        private let scene = SCNScene()
        private let handRoot = SCNNode()   // wave / sway
        private let squashRoot = SCNNode() // breathe squash-and-stretch
        private let faceRoot = SCNNode()   // gaze offset
        private var eyes: [SCNNode] = []
        private var squints: [SCNNode] = []
        private var cheeks: [SCNNode] = []
        private var mouthIdle = SCNNode()
        private var mouthHappy = SCNNode()
        private var mood: BuddyMood = .idle
        private var wasWaving = false
        private var blinking = false

        // Palette: pastel take on Brand colors.
        private static let bodyColor = NSColor(calibratedRed: 0.55, green: 0.62, blue: 1.0, alpha: 1)
        private static let bodyColor2 = NSColor(calibratedRed: 0.78, green: 0.62, blue: 0.98, alpha: 1)
        private static let cheekColor = NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.72, alpha: 1)
        private static let faceDark = NSColor(calibratedRed: 0.16, green: 0.14, blue: 0.24, alpha: 1)

        func buildScene() -> SCNScene {
            scene.background.contents = NSColor.clear

            let camera = SCNCamera()
            camera.fieldOfView = 28
            camera.zNear = 0.1
            camera.zFar = 100
            let camNode = SCNNode()
            camNode.camera = camera
            camNode.position = SCNVector3(0, 0.1, 7.2)
            scene.rootNode.addChildNode(camNode)

            // Soft top-left key + warm fill + cool ambient — plush-toy lighting.
            let key = SCNNode()
            key.light = SCNLight()
            key.light!.type = .directional
            key.light!.intensity = 780
            key.eulerAngles = SCNVector3(-0.55, -0.5, 0)
            scene.rootNode.addChildNode(key)

            let rim = SCNNode()
            rim.light = SCNLight()
            rim.light!.type = .directional
            rim.light!.intensity = 350
            rim.light!.color = NSColor(calibratedRed: 1.0, green: 0.8, blue: 0.9, alpha: 1)
            rim.eulerAngles = SCNVector3(0.4, 0.7, 0)
            scene.rootNode.addChildNode(rim)

            let ambient = SCNNode()
            ambient.light = SCNLight()
            ambient.light!.type = .ambient
            ambient.light!.intensity = 430
            ambient.light!.color = NSColor(calibratedRed: 0.82, green: 0.85, blue: 1.0, alpha: 1)
            scene.rootNode.addChildNode(ambient)

            scene.rootNode.addChildNode(handRoot)
            handRoot.addChildNode(squashRoot)
            buildHand(into: squashRoot)
            return scene
        }

        // MARK: Hand assembly

        private func buildHand(into parent: SCNNode) {
            var seed: UInt64 = 0x9E3779B9

            func bubble(_ scale: SCNVector3, at pos: SCNVector3,
                        tilt: SCNVector3 = SCNVector3(0, 0, 0),
                        color: NSColor, jitter: Float = 0.055,
                        subdivisions: Int = 2) -> SCNNode {
                let geo = LowPoly.icosphere(subdivisions: subdivisions,
                                            jitter: jitter, seed: &seed)
                geo.firstMaterial = Self.bodyMaterial(color)
                let node = SCNNode(geometry: geo)
                node.scale = scale
                node.position = pos
                node.eulerAngles = tilt
                parent.addChildNode(node)
                return node
            }

            // Palm: fat squished bubble.
            _ = bubble(SCNVector3(1.05, 1.0, 0.6), at: SCNVector3(0, -0.15, 0),
                       color: Self.bodyColor)

            // Four stubby baby fingers, fanned, tinted toward pink at the pinky.
            let fingerX: [CGFloat] = [-0.62, -0.22, 0.20, 0.60]
            let fingerH: [CGFloat] = [0.78, 0.95, 0.90, 0.70]
            for i in 0..<4 {
                let t = CGFloat(i) / 3.0
                let color = Self.bodyColor.blended(withFraction: t * 0.55,
                                                   of: Self.bodyColor2) ?? Self.bodyColor
                _ = bubble(SCNVector3(0.26, 0.62, 0.26),
                           at: SCNVector3(fingerX[i], 0.50 + fingerH[i] * 0.55, 0),
                           tilt: SCNVector3(0, 0, CGFloat(fingerX[i]) * -0.18),
                           color: color, jitter: 0.07)
            }

            // Thumb: chunky, off to the side.
            _ = bubble(SCNVector3(0.30, 0.56, 0.30),
                       at: SCNVector3(-1.10, -0.10, 0.05),
                       tilt: SCNVector3(0, 0, 0.7),
                       color: Self.bodyColor, jitter: 0.07)

            buildFace(on: parent)
        }

        private func buildFace(on parent: SCNNode) {
            faceRoot.position = SCNVector3(0, -0.12, 0.62)
            parent.addChildNode(faceRoot)

            // Bean eyes — glossy smooth spheres (contrast against faceted body).
            for x in [-0.34, 0.34] {
                let eye = SCNNode(geometry: SCNSphere(radius: 0.135))
                (eye.geometry as? SCNSphere)?.segmentCount = 28
                eye.geometry?.firstMaterial = Self.glossyDark()
                eye.scale = SCNVector3(0.85, 1.15, 0.6)
                eye.position = SCNVector3(x, 0.12, 0)
                faceRoot.addChildNode(eye)
                eyes.append(eye)

                // Tiny white catchlight glued to each eye — instant life.
                let glint = SCNNode(geometry: SCNSphere(radius: 0.038))
                glint.geometry?.firstMaterial = Self.unlit(.white)
                glint.position = SCNVector3(0.045, 0.06, 0.11)
                eye.addChildNode(glint)

                // Happy squint: "∩" arc, hidden by default.
                let arc = SCNNode(geometry: LowPoly.arcShape(radius: 0.14,
                                                             thickness: 0.055))
                arc.geometry?.firstMaterial = Self.glossyDark()
                arc.position = SCNVector3(x, 0.10, 0.02)
                arc.isHidden = true
                faceRoot.addChildNode(arc)
                squints.append(arc)

                // Blush cheeks.
                let cheek = SCNNode(geometry: SCNSphere(radius: 0.10))
                cheek.geometry?.firstMaterial = Self.blush()
                cheek.scale = SCNVector3(1.2, 0.7, 0.4)
                cheek.position = SCNVector3(x * 1.55, -0.12, -0.02)
                cheek.opacity = 0.55
                faceRoot.addChildNode(cheek)
                cheeks.append(cheek)
            }

            // Idle mouth: tiny soft dash.
            mouthIdle = SCNNode(geometry: SCNCapsule(capRadius: 0.03, height: 0.16))
            mouthIdle.geometry?.firstMaterial = Self.glossyDark()
            mouthIdle.eulerAngles = SCNVector3(0, 0, CGFloat.pi / 2)
            mouthIdle.position = SCNVector3(0, -0.22, 0.02)
            faceRoot.addChildNode(mouthIdle)

            // Happy mouth: open "D" smile (flat top, curved bottom), hidden.
            mouthHappy = SCNNode(geometry: LowPoly.smileShape(width: 0.30,
                                                              depth: 0.17))
            mouthHappy.geometry?.firstMaterial = Self.glossyDark()
            mouthHappy.position = SCNVector3(0, -0.20, 0.02)
            mouthHappy.isHidden = true
            faceRoot.addChildNode(mouthHappy)
        }

        // MARK: Materials

        private static func bodyMaterial(_ color: NSColor) -> SCNMaterial {
            let m = SCNMaterial()
            m.lightingModel = .blinn
            m.diffuse.contents = color
            m.specular.contents = NSColor(white: 1, alpha: 0.18)
            m.shininess = 0.35
            m.emission.contents = color.withAlphaComponent(0.05)
            return m
        }

        private static func glossyDark() -> SCNMaterial {
            let m = SCNMaterial()
            m.lightingModel = .blinn
            m.diffuse.contents = faceDark
            m.specular.contents = NSColor.white
            m.shininess = 0.9
            return m
        }

        private static func blush() -> SCNMaterial {
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = cheekColor
            return m
        }

        private static func unlit(_ color: NSColor) -> SCNMaterial {
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = color
            return m
        }

        // MARK: Life

        func startIdle() {
            // Breathe: gentle squash-and-stretch, never uniform scale.
            let inhale = SCNAction.customAction(duration: 1.6) { node, t in
                let p = CGFloat(sin(Double(t) / 1.6 * .pi)) // 0→1→0
                node.scale = SCNVector3(1 + p * 0.025, 1 - p * 0.03, 1 + p * 0.025)
            }
            squashRoot.runAction(.repeatForever(.sequence([inhale, .wait(duration: 0.4)])))

            // Slow dreamy sway.
            let sway = SCNAction.sequence([
                .rotateTo(x: 0, y: 0.10, z: 0.045, duration: 2.6, usesShortestUnitArc: true),
                .rotateTo(x: 0, y: -0.10, z: -0.045, duration: 2.6, usesShortestUnitArc: true),
            ])
            sway.timingMode = .easeInEaseOut
            handRoot.runAction(.repeatForever(sway))

            scheduleBlink()
        }

        private func scheduleBlink() {
            let wait = Double.random(in: 2.0...5.5)
            let doubleBlink = Double.random(in: 0...1) < 0.25
            var actions: [SCNAction] = [.wait(duration: wait)]
            let close = SCNAction.customAction(duration: 0.09) { node, t in
                node.scale.y = 1.15 - (1.15 - 0.06) * (t / 0.09)
            }
            let open = SCNAction.customAction(duration: 0.12) { node, t in
                node.scale.y = 0.06 + (1.15 - 0.06) * (t / 0.12)
            }
            actions += [close, .wait(duration: 0.05), open]
            if doubleBlink { actions += [.wait(duration: 0.12), close, .wait(duration: 0.04), open] }
            let seq = SCNAction.sequence(actions)
            blinking = true
            for eye in eyes { eye.runAction(seq) }
            DispatchQueue.main.asyncAfter(deadline: .now() + wait + 0.7) { [weak self] in
                self?.blinking = false
                self?.scheduleBlink()
            }
        }

        func apply(mood: BuddyMood, gaze: CGPoint, waving: Bool) {
            if waving && !wasWaving { wave() }
            wasWaving = waving

            // Gaze: face slides a touch, whole hand leans toward the target.
            let target = mood == .thinking ? CGPoint(x: 0.4, y: 0.6) : gaze
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.28
            faceRoot.position = SCNVector3(CGFloat(target.x) * 0.10,
                                           -0.12 + CGFloat(target.y) * 0.08, 0.62)
            handRoot.eulerAngles.x = CGFloat(-target.y) * 0.12
            SCNTransaction.commit()

            guard mood != self.mood else { return }
            self.mood = mood

            let happy = mood == .happy
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.2
            for eye in eyes { eye.isHidden = happy }
            for arc in squints { arc.isHidden = !happy }
            mouthIdle.isHidden = happy
            mouthHappy.isHidden = !happy
            for cheek in cheeks { cheek.opacity = happy ? 1.0 : 0.55 }
            SCNTransaction.commit()

            if happy { hop() }
        }

        /// Friendly side-to-side wave — Palmo IS a hand, lean into it.
        private func wave() {
            handRoot.removeAllActions()
            var swings: [SCNAction] = []
            for i in 0..<3 {
                let a: CGFloat = i == 2 ? 0.12 : 0.30
                swings.append(.rotateTo(x: 0, y: 0, z: a, duration: 0.16, usesShortestUnitArc: true))
                swings.append(.rotateTo(x: 0, y: 0, z: -a, duration: 0.16, usesShortestUnitArc: true))
            }
            swings.append(.rotateTo(x: 0, y: 0, z: 0, duration: 0.18, usesShortestUnitArc: true))
            let seq = SCNAction.sequence(swings)
            seq.timingMode = .easeInEaseOut
            handRoot.runAction(seq) { [weak self] in
                Task { @MainActor in self?.restartSway() }
            }
        }

        private func restartSway() {
            let sway = SCNAction.sequence([
                .rotateTo(x: 0, y: 0.10, z: 0.045, duration: 2.6, usesShortestUnitArc: true),
                .rotateTo(x: 0, y: -0.10, z: -0.045, duration: 2.6, usesShortestUnitArc: true),
            ])
            sway.timingMode = .easeInEaseOut
            handRoot.runAction(.repeatForever(sway))
        }

        /// Happy little bounce.
        private func hop() {
            let up = SCNAction.moveBy(x: 0, y: 0.18, z: 0, duration: 0.14)
            up.timingMode = .easeOut
            let down = SCNAction.moveBy(x: 0, y: -0.18, z: 0, duration: 0.18)
            down.timingMode = .easeIn
            squashRoot.runAction(.sequence([up, down]))
        }
    }
}

// MARK: - Procedural low-poly geometry

/// Faceted icosphere generator: subdivided icosahedron with per-face normals
/// and a dash of deterministic vertex jitter so every bubble reads as
/// hand-sculpted rather than machine-smooth.
enum LowPoly {
    static func icosphere(subdivisions: Int, jitter: Float,
                          seed: inout UInt64) -> SCNGeometry {
        // Icosahedron base.
        let t = Float((1.0 + sqrt(5.0)) / 2.0)
        let base: [SIMD3<Float>] = [
            SIMD3(-1, t, 0), SIMD3(1, t, 0), SIMD3(-1, -t, 0), SIMD3(1, -t, 0),
            SIMD3(0, -1, t), SIMD3(0, 1, t), SIMD3(0, -1, -t), SIMD3(0, 1, -t),
            SIMD3(t, 0, -1), SIMD3(t, 0, 1), SIMD3(-t, 0, -1), SIMD3(-t, 0, 1),
        ]
        var verts: [SIMD3<Float>] = base.map { simd_normalize($0) }
        var faces: [(Int, Int, Int)] = [
            (0, 11, 5), (0, 5, 1), (0, 1, 7), (0, 7, 10), (0, 10, 11),
            (1, 5, 9), (5, 11, 4), (11, 10, 2), (10, 7, 6), (7, 1, 8),
            (3, 9, 4), (3, 4, 2), (3, 2, 6), (3, 6, 8), (3, 8, 9),
            (4, 9, 5), (2, 4, 11), (6, 2, 10), (8, 6, 7), (9, 8, 1),
        ]

        for _ in 0..<subdivisions {
            var midCache: [UInt64: Int] = [:]
            func midpoint(_ a: Int, _ b: Int) -> Int {
                let key = UInt64(min(a, b)) << 32 | UInt64(max(a, b))
                if let i = midCache[key] { return i }
                verts.append(simd_normalize((verts[a] + verts[b]) * 0.5))
                midCache[key] = verts.count - 1
                return verts.count - 1
            }
            var next: [(Int, Int, Int)] = []
            for (a, b, c) in faces {
                let ab = midpoint(a, b), bc = midpoint(b, c), ca = midpoint(c, a)
                next += [(a, ab, ca), (b, bc, ab), (c, ca, bc), (ab, bc, ca)]
            }
            faces = next
        }

        // Deterministic jitter along each vertex normal (bubble wobble).
        for i in verts.indices {
            verts[i] *= 1.0 + (rand(&seed) - 0.5) * 2 * jitter
        }

        // Explode into flat-shaded triangles (per-face normals).
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        positions.reserveCapacity(faces.count * 3)
        for (a, b, c) in faces {
            let (va, vb, vc) = (verts[a], verts[b], verts[c])
            let n = simd_normalize(simd_cross(vb - va, vc - va))
            positions += [va, vb, vc]
            normals += [n, n, n]
        }
        let indices: [Int32] = Array(0..<Int32(positions.count))

        let vSource = SCNGeometrySource(vertices: positions.map(SCNVector3.init))
        let nSource = SCNGeometrySource(normals: normals.map(SCNVector3.init))
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        return SCNGeometry(sources: [vSource, nSource], elements: [element])
    }

    /// Happy-squint "∩" arc: an extruded stroked arc band.
    static func arcShape(radius: CGFloat, thickness: CGFloat) -> SCNGeometry {
        let path = NSBezierPath()
        let outer = radius + thickness / 2
        let inner = radius - thickness / 2
        path.appendArc(withCenter: .zero, radius: outer,
                       startAngle: 20, endAngle: 160, clockwise: false)
        path.appendArc(withCenter: .zero, radius: inner,
                       startAngle: 160, endAngle: 20, clockwise: true)
        path.close()
        path.flatness = 0.005
        let shape = SCNShape(path: path, extrusionDepth: 0.05)
        shape.chamferRadius = 0.015
        return shape
    }

    /// Open "D" smile: flat top edge, round bottom.
    static func smileShape(width: CGFloat, depth: CGFloat) -> SCNGeometry {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: -width / 2, y: 0))
        path.line(to: NSPoint(x: width / 2, y: 0))
        path.curve(to: NSPoint(x: -width / 2, y: 0),
                   controlPoint1: NSPoint(x: width * 0.45, y: -depth * 1.9),
                   controlPoint2: NSPoint(x: -width * 0.45, y: -depth * 1.9))
        path.close()
        path.flatness = 0.005
        let shape = SCNShape(path: path, extrusionDepth: 0.05)
        shape.chamferRadius = 0.02
        return shape
    }

    /// Tiny deterministic PRNG (splitmix64) → 0..1.
    private static func rand(_ state: inout UInt64) -> Float {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        return Float(z >> 40) / Float(1 << 24)
    }
}

private extension SCNVector3 {
    init(_ v: SIMD3<Float>) {
        self.init(CGFloat(v.x), CGFloat(v.y), CGFloat(v.z))
    }
}
