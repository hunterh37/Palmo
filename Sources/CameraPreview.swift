import SwiftUI
import AVFoundation

/// Live camera preview backed by `AVCaptureVideoPreviewLayer`, mirrored to
/// match the operator's expectation of a selfie view.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    var mirrored: Bool

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateNSView(_ nsView: PreviewView, context: Context) {
        nsView.mirrored = mirrored
    }

    final class PreviewView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()

        /// Mirroring is a horizontal flip of `previewLayer`. Note it must be a
        /// SUBLAYER (not the view's backing layer): AppKit manages a backing
        /// layer's geometry and resets its affineTransform on every layout, so
        /// the flip would silently never apply.
        var mirrored = false {
            didSet { applyMirror() }
        }

        private func applyMirror() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer.setAffineTransform(
                mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity)
            CATransaction.commit()
        }
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer = CALayer()
            layer?.addSublayer(previewLayer)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer.frame = bounds
            CATransaction.commit()
            // Re-assert the flip after resizing the sublayer's frame.
            applyMirror()
        }
    }
}
