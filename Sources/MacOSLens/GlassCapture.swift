import AppKit
import Metal
import QuartzCore

/// Renders a view's layer tree offscreen with Core Animation's own renderer, the way the window server would, so
/// Liquid Glass, backdrops and their content appear in check images. `cacheDisplay` and `CALayer.render(in:)` draw
/// glass as a flat blob without its content. Used only by the checks; the view's window is never shown.
@MainActor
enum GlassCapture {
    private static let device = MTLCreateSystemDefaultDevice()
    private static let queue = device?.makeCommandQueue()

    static func image(of view: NSView, scale: Int = 2) -> CGImage? {
        guard let device, let queue, let layer = view.layer, view.bounds.width >= 1, view.bounds.height >= 1 else {
            return nil
        }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        view.displayIfNeeded()
        let width = Int(view.bounds.width) * scale, height = Int(view.bounds.height) * scale
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width,
                                                                  height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .managed
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        // The renderer needs the layer as a root, in pixels.
        let parent = layer.superlayer
        let index = parent?.sublayers?.firstIndex(of: layer)
        let saved = (layer.anchorPoint, layer.position, layer.transform)
        layer.removeFromSuperlayer()
        defer {
            layer.anchorPoint = saved.0
            layer.position = saved.1
            layer.transform = saved.2
            if let parent, let index { parent.insertSublayer(layer, at: UInt32(index)) }
            CATransaction.flush()
        }
        let renderer = CARenderer(mtlTexture: texture, options: [kCARendererMetalCommandQueue: queue])
        renderer.layer = layer
        renderer.bounds = CGRect(x: 0, y: 0, width: width, height: height)
        layer.anchorPoint = .zero
        layer.position = .zero
        layer.transform = CATransform3DMakeScale(CGFloat(scale), CGFloat(scale), 1)
        CATransaction.flush()
        Thread.sleep(forTimeInterval: 0.05)
        renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
        renderer.addUpdate(renderer.bounds)
        renderer.render()
        renderer.endFrame()
        Thread.sleep(forTimeInterval: 0.2)
        guard let buffer = queue.makeCommandBuffer(), let blit = buffer.makeBlitCommandEncoder() else { return nil }
        blit.synchronize(resource: texture)
        blit.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        renderer.layer = nil

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let raw = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                bytesPerRow: width * 4, space: space, bitmapInfo: CGBitmapInfo(rawValue: info),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let upright = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        // The texture's first row is the top of the view.
        upright.translateBy(x: 0, y: CGFloat(height))
        upright.scaleBy(x: 1, y: -1)
        upright.draw(raw, in: CGRect(x: 0, y: 0, width: width, height: height))
        return upright.makeImage()
    }

    /// `rect`, in the view's points from the bottom left, cut from an image of the view at `scale`.
    static func crop(_ image: CGImage, _ rect: CGRect, viewHeight: CGFloat, scale: CGFloat = 2) -> CGImage? {
        image.cropping(to: CGRect(x: rect.minX * scale, y: (viewHeight - rect.maxY) * scale,
                                  width: rect.width * scale, height: rect.height * scale).integral)
    }
}
