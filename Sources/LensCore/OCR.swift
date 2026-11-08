import AppKit
import Vision

public struct RecognizedText {
    public let text: String
    public let bounds: CGRect
}

public enum OCR {
    public static func recognize(_ image: CGImage) throws -> [RecognizedText] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            return RecognizedText(text: text, bounds: observation.boundingBox)
        }.sorted {
            if abs($0.bounds.midY - $1.bounds.midY) > 0.02 { return $0.bounds.midY > $1.bounds.midY }
            return $0.bounds.minX < $1.bounds.minX
        }
    }

    /// Text lines and salient objects near a tap, found on this Mac with Apple Vision. This approximates
    /// Android's tap-to-select; it is not Google's segmentation. Boxes are normalized with a bottom-left origin.
    public static func tapCandidates(_ image: CGImage) throws -> (text: [CGRect], objects: [CGRect]) {
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .fast
        text.usesLanguageCorrection = false
        let objects = VNGenerateObjectnessBasedSaliencyImageRequest()
        try VNImageRequestHandler(cgImage: image).perform([text, objects])
        return ((text.results ?? []).map(\.boundingBox),
                (objects.results ?? []).flatMap { ($0.salientObjects ?? []).map(\.boundingBox) })
    }

    public static func fixture() throws -> CGImage {
        let image = NSImage(size: NSSize(width: 640, height: 240))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 640, height: 240).fill()
        ("HELLO LENS 123" as NSString).draw(
            at: NSPoint(x: 35, y: 100),
            withAttributes: [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black]
        )
        image.unlockFocus()
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw LensError.message("Could not generate the test image.")
        }
        return cgImage
    }
}
