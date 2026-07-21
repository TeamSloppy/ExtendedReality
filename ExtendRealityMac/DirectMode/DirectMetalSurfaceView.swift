import CoreImage
import MetalKit
import SwiftUI

struct DirectMetalSurfaceView: NSViewRepresentable {
    let pixelBuffer: CVPixelBuffer?

    func makeCoordinator() -> Renderer { Renderer() }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.delegate = context.coordinator
        view.framebufferOnly = false
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0.02, green: 0.02, blue: 0.025, alpha: 1)
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        if let device = view.device { context.coordinator.attach(device: device) }
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.pixelBuffer = pixelBuffer
        view.setNeedsDisplay(view.bounds)
    }

    final class Renderer: NSObject, MTKViewDelegate {
        var pixelBuffer: CVPixelBuffer?
        private var context: CIContext?
        func attach(device: MTLDevice) {
            context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let device = view.device,
                  let queue = device.makeCommandQueue(),
                  let commandBuffer = queue.makeCommandBuffer(),
                  let drawable = view.currentDrawable else { return }

            if let pixelBuffer, let context {
                let image = CIImage(cvPixelBuffer: pixelBuffer)
                let target = CGRect(origin: .zero, size: view.drawableSize)
                let scale = min(target.width / image.extent.width, target.height / image.extent.height)
                let fitted = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                    .transformed(by: CGAffineTransform(
                        translationX: (target.width - image.extent.width * scale) / 2,
                        y: (target.height - image.extent.height * scale) / 2
                    ))
                context.render(
                    fitted,
                    to: drawable.texture,
                    commandBuffer: commandBuffer,
                    bounds: target,
                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
                )
            }
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}

enum SpatialSourceMapping {
    static func globalPoint(
        canvasPoint: CGPoint,
        surfaceFrame: CGRect,
        sourceFrame: CGRect,
        sourceAspectRatio: CGFloat,
        rotationRadians: CGFloat = 0
    ) -> CGPoint? {
        guard surfaceFrame.width > 0, surfaceFrame.height > 0,
              sourceFrame.width > 0, sourceFrame.height > 0,
              sourceAspectRatio.isFinite, sourceAspectRatio > 0 else { return nil }

        let center = CGPoint(x: surfaceFrame.midX, y: surfaceFrame.midY)
        let translated = CGPoint(x: canvasPoint.x - center.x, y: canvasPoint.y - center.y)
        let cosine = cos(-rotationRadians)
        let sine = sin(-rotationRadians)
        let localCanvasPoint = CGPoint(
            x: translated.x * cosine - translated.y * sine + center.x,
            y: translated.x * sine + translated.y * cosine + center.y
        )
        let fitted = aspectFitRect(aspectRatio: sourceAspectRatio, in: surfaceFrame)
        guard fitted.contains(localCanvasPoint) else { return nil }
        let x = ((localCanvasPoint.x - fitted.minX) / fitted.width).clamped(to: 0 ... 1)
        let y = ((localCanvasPoint.y - fitted.minY) / fitted.height).clamped(to: 0 ... 1)
        return CGPoint(
            x: sourceFrame.minX + x * sourceFrame.width,
            y: sourceFrame.minY + y * sourceFrame.height
        )
    }

    static func aspectFitRect(aspectRatio: CGFloat, in bounds: CGRect) -> CGRect {
        let boundsRatio = bounds.width / max(bounds.height, 1)
        if boundsRatio > aspectRatio {
            let width = bounds.height * aspectRatio
            return CGRect(x: bounds.midX - width / 2, y: bounds.minY, width: width, height: bounds.height)
        }
        let height = bounds.width / aspectRatio
        return CGRect(x: bounds.minX, y: bounds.midY - height / 2, width: bounds.width, height: height)
    }
}
