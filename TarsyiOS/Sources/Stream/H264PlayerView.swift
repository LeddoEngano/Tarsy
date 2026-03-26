import SwiftUI
import AVFoundation

/// SwiftUI wrapper for AVSampleBufferDisplayLayer to show H.264 decoded video
struct H264PlayerView: UIViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> H264ContainerView {
        let view = H264ContainerView()
        view.setDisplayLayer(displayLayer)
        return view
    }

    func updateUIView(_ uiView: H264ContainerView, context: Context) {
        // Re-attach layer if it was removed (e.g., after fullscreen toggle)
        uiView.ensureLayerAttached(displayLayer)
    }
}

class H264ContainerView: UIView {
    private weak var displayLayer: AVSampleBufferDisplayLayer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setDisplayLayer(_ layer: AVSampleBufferDisplayLayer) {
        self.displayLayer?.removeFromSuperlayer()
        self.displayLayer = layer
        self.layer.addSublayer(layer)
        setNeedsLayout()
    }

    func ensureLayerAttached(_ layer: AVSampleBufferDisplayLayer) {
        if layer.superlayer !== self.layer {
            layer.removeFromSuperlayer()
            self.displayLayer = layer
            self.layer.addSublayer(layer)
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        displayLayer?.frame = bounds
    }
}
