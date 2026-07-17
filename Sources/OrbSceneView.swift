import SwiftUI
import SceneKit

/// Transparent SceneKit layer that renders the menu orbs as real 3D spheres
/// (lit, glossy, glowing) over the live camera preview. An orthographic
/// camera is scaled so one scene unit equals one view point, letting the
/// normalized layout from the engine map straight onto the video.
struct OrbSceneView: NSViewRepresentable {
    let orbs: [OrbDisplay]
    let size: CGSize
    let videoSize: CGSize

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.allowsCameraControl = false
        view.rendersContinuously = true
        view.antialiasingMode = .multisampling4X
        view.scene = context.coordinator.buildScene()
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        context.coordinator.apply(orbs: orbs, size: size, videoSize: videoSize)
    }

    final class Coordinator {
        private let scene = SCNScene()
        private let cameraNode = SCNNode()
        private let orbRoot = SCNNode()
        private var nodes: [String: SCNNode] = [:]

        func buildScene() -> SCNScene {
            scene.background.contents = NSColor.clear

            let camera = SCNCamera()
            camera.usesOrthographicProjection = true
            camera.zNear = 1
            camera.zFar = 2000
            cameraNode.camera = camera
            cameraNode.position = SCNVector3(0, 0, 600)
            scene.rootNode.addChildNode(cameraNode)

            let key = SCNNode()
            let keyLight = SCNLight()
            keyLight.type = .omni
            keyLight.intensity = 1400
            key.light = keyLight
            key.position = SCNVector3(-250, 350, 500)
            scene.rootNode.addChildNode(key)

            let fill = SCNNode()
            let fillLight = SCNLight()
            fillLight.type = .ambient
            fillLight.intensity = 420
            fillLight.color = NSColor(calibratedRed: 0.75, green: 0.82, blue: 1.0, alpha: 1)
            fill.light = fillLight
            scene.rootNode.addChildNode(fill)

            scene.rootNode.addChildNode(orbRoot)
            return scene
        }

        func apply(orbs: [OrbDisplay], size: CGSize, videoSize: CGSize) {
            guard size.width > 0, size.height > 0 else { return }
            (cameraNode.camera)?.orthographicScale = Double(size.height / 2)

            SCNTransaction.begin()
            SCNTransaction.disableActions = true

            var seen = Set<String>()
            for orb in orbs {
                seen.insert(orb.id)
                let node = nodes[orb.id] ?? makeOrbNode(orb)
                nodes[orb.id] = node
                if node.parent == nil { orbRoot.addChildNode(node) }

                let p = point(orb.center, size: size, videoSize: videoSize)
                let radius = orb.radiusNorm * drawnSize(size: size, videoSize: videoSize).height
                let s = max(radius * orb.scale, 0.001)
                node.position = SCNVector3(p.x - size.width / 2,
                                           size.height / 2 - p.y,
                                           CGFloat(orb.pop) * 60)
                node.scale = SCNVector3(s, s, s)
                style(node, orb: orb)
            }
            for (id, node) in nodes where !seen.contains(id) {
                node.removeFromParentNode()
                nodes[id] = nil
            }
            SCNTransaction.commit()
        }

        private func makeOrbNode(_ orb: OrbDisplay) -> SCNNode {
            let sphere = SCNSphere(radius: 1)
            sphere.segmentCount = 48
            let node = SCNNode(geometry: sphere)

            // Inner core glow.
            let core = SCNNode(geometry: SCNSphere(radius: 0.55))
            core.name = "core"
            node.addChildNode(core)

            // Slow idle spin sells the 3D.
            node.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 9)))
            return node
        }

        private func style(_ node: SCNNode, orb: OrbDisplay) {
            let (r, g, b) = orb.action?.color ?? (0.55, 0.75, 1.0)
            let color = NSColor(calibratedRed: r, green: g, blue: b, alpha: 1)

            let shell = node.geometry?.firstMaterial ?? SCNMaterial()
            shell.lightingModel = .physicallyBased
            shell.diffuse.contents = color.withAlphaComponent(0.42)
            shell.metalness.contents = 0.15
            shell.roughness.contents = 0.12
            shell.transparency = orb.isCommand ? 0.92 : 0.85
            shell.emission.contents = color.withAlphaComponent(orb.highlighted ? 0.95 : 0.30)
            shell.fresnelExponent = 1.6
            shell.isDoubleSided = false
            node.geometry?.firstMaterial = shell

            if let core = node.childNode(withName: "core", recursively: false) {
                let m = core.geometry?.firstMaterial ?? SCNMaterial()
                m.lightingModel = .constant
                m.diffuse.contents = NSColor.white.withAlphaComponent(0.0)
                m.emission.contents = color.withAlphaComponent(orb.highlighted ? 1.0 : 0.65)
                m.transparency = 0.75
                core.geometry?.firstMaterial = m
            }
        }

        private func drawnSize(size: CGSize, videoSize: CGSize) -> CGSize {
            guard videoSize.width > 0, videoSize.height > 0 else { return size }
            let scale = max(size.width / videoSize.width, size.height / videoSize.height)
            return CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        }

        /// Maps a normalized (0...1, top-left origin) video point into view
        /// space, matching the preview layer's aspect-fill scale and crop.
        private func point(_ p: CGPoint, size: CGSize, videoSize: CGSize) -> CGPoint {
            let drawn = drawnSize(size: size, videoSize: videoSize)
            let offset = CGPoint(x: (size.width - drawn.width) / 2,
                                 y: (size.height - drawn.height) / 2)
            return CGPoint(x: offset.x + p.x * drawn.width,
                           y: offset.y + p.y * drawn.height)
        }
    }
}
