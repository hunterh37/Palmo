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

        /// Mirroring is done with a layer flip instead of the connection's
        /// isVideoMirrored: the connection can be nil when the view is first
        /// built (session still configuring) and never gets re-applied.
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
            layer = previewLayer
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layout() {
            super.layout()
            previewLayer.frame = bounds
        }
    }
}
