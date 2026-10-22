import Foundation
import ImageIO
import CoreGraphics
import CoreImage
import Vision

/// Image conversions and edits with ImageIO/Core Graphics. SVG is rasterised through Quick Look.
public struct ImageEngine: ConversionEngine {
    public let id = EngineID.image

    public init() {}

    public func convert(_ input: URL, from source: Format, to target: Format, output: URL, context: EngineContext) async throws -> URL {
        if target == .pdf {
            try await PDFEngine.makePDF(fromImages: [input], output: output, context: context)
            return output
        }
        let options = context.options
        let image = try Self.limited(try await Self.loadImage(input, source: source, context: context),
                                     maxDimension: options.maxImageDimension)
        try await Self.write(image, to: output, format: target, quality: options.quality(for: target),
                             metadata: Self.metadataProperties(of: input, policy: options.metadata), context: context)
        return output
    }

    /// Scales down so the longest side is at most `maxDimension` (0 = no limit). Never enlarges.
    static func limited(_ image: CGImage, maxDimension: Int) throws -> CGImage {
        let longest = max(image.width, image.height)
        guard maxDimension > 0, longest > maxDimension else { return image }
        return try resized(image, scale: CGFloat(maxDimension) / CGFloat(longest))
    }

    /// EXIF/TIFF/IPTC (and GPS unless removed) from the source, for writing into the converted file.
    /// Orientation is reset because the pixels are already upright, and pixel sizes are dropped
    /// because the image may have been resized.
    static func metadataProperties(of url: URL, policy: MetadataPolicy) -> [CFString: Any]? {
        guard policy != .removeAll,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        var keys = [kCGImagePropertyExifDictionary, kCGImagePropertyExifAuxDictionary,
                    kCGImagePropertyTIFFDictionary, kCGImagePropertyIPTCDictionary]
        if policy == .keep { keys.append(kCGImagePropertyGPSDictionary) }
        var result: [CFString: Any] = [:]
        for key in keys {
            if let value = properties[key] { result[key] = value }
        }
        guard !result.isEmpty else { return nil }
        if var exif = result[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = nil
            exif[kCGImagePropertyExifPixelYDimension] = nil
            result[kCGImagePropertyExifDictionary] = exif
        }
        if var tiff = result[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            result[kCGImagePropertyTIFFDictionary] = tiff
        }
        result[kCGImagePropertyOrientation] = 1
        return result
    }

    // MARK: Reading

    static func loadImage(_ url: URL, source: Format?, context: EngineContext) async throws -> CGImage {
        var url = url
        if source == .svg { url = try await rasterizeSVG(url, context: context) }
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(imageSource) > 0 else {
            throw KumquatError.invalidInput("\(url.lastPathComponent) isn't a readable image.")
        }
        return try orientedImage(from: imageSource)
    }

    /// Full-size image with EXIF orientation applied (plain `CGImageSourceCreateImageAtIndex` ignores it).
    static func orientedImage(from source: CGImageSource) throws -> CGImage {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        if max(width, height) > 0 {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height),
                kCGImageSourceShouldCacheImmediately: true,
            ]
            if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) { return image }
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw KumquatError.invalidInput("Couldn't decode the image.")
        }
        return image
    }

    static func rasterizeSVG(_ url: URL, context: EngineContext) async throws -> URL {
        let outDir = context.workDirectory.appendingPathComponent("svg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        try await ProcessRunner.runChecked(SystemTool.qlmanage, ["-t", "-s", "2048", "-o", outDir.path, url.path], timeout: 60)
        guard let png = try FileManager.default.contentsOfDirectory(at: outDir, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension.lowercased() == "png" }) else {
            throw KumquatError.conversionFailed("Quick Look couldn't render \(url.lastPathComponent).")
        }
        return png
    }

    // MARK: Writing

    static func uti(for format: Format) -> String? {
        switch format {
        case .jpg: return "public.jpeg"
        case .png: return "public.png"
        case .heic: return "public.heic"
        case .tiff: return "public.tiff"
        case .bmp: return "com.microsoft.bmp"
        case .gif: return "com.compuserve.gif"
        case .ico: return "com.microsoft.ico"
        case .icns: return "com.apple.icns"
        case .webp: return "org.webmproject.webp"
        case .avif: return "public.avif"
        case .jp2: return "public.jpeg-2000"
        default: return nil
        }
    }

    static let writableTypes: Set<String> = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])

    static func canWrite(_ format: Format) -> Bool {
        uti(for: format).map { writableTypes.contains($0) } ?? false
    }

    static func write(_ image: CGImage, to url: URL, format: Format, quality: Double,
                      metadata: [CFString: Any]? = nil, context: EngineContext) async throws {
        if canWrite(format) {
            try encode(image, to: url, format: format, quality: quality, metadata: metadata)
        } else if format == .webp || format == .avif {
            let png = context.scratchURL("png")
            try encode(image, to: png, format: .png, quality: 1)
            try await MediaEngine.encodeStillImage(png, to: url, format: format, quality: quality, tools: context.tools)
        } else {
            throw KumquatError.engineUnavailable("\(format.name) encoding")
        }
    }

    static func encode(_ image: CGImage, to url: URL, format: Format, quality: Double,
                       metadata: [CFString: Any]? = nil) throws {
        guard let type = Self.uti(for: format) else { throw KumquatError.noRoute(from: "image", to: format.name) }
        let representations: [CGImage]
        switch format {
        case .jpg, .bmp, .jp2:
            representations = [flattened(image)]
        case .ico:
            let sizes = [16, 32, 48, 256].filter { $0 <= max(image.width, image.height) || $0 == 16 }
            representations = sizes.map { squared(image, size: $0) }
        case .icns:
            representations = [16, 32, 64, 128, 256, 512, 1024].map { squared(image, size: $0) }
        default:
            representations = [image]
        }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, representations.count, nil) else {
            throw KumquatError.engineUnavailable("\(format.name) encoding")
        }
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if let metadata, representations.count == 1 {
            properties.merge(metadata) { current, _ in current }
        }
        for representation in representations {
            CGImageDestinationAddImage(destination, representation, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else {
            // Unusual metadata can make an encoder refuse the file; the pixels matter more.
            if metadata != nil { return try encode(image, to: url, format: format, quality: quality) }
            throw KumquatError.conversionFailed("Couldn't write \(format.name).")
        }
    }

    // MARK: Pixel operations

    static func makeContext(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: max(width, 1), height: max(height, 1), bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    static func render(width: Int, height: Int, _ draw: (CGContext) -> Void) throws -> CGImage {
        guard let context = makeContext(width: width, height: height) else {
            throw KumquatError.conversionFailed("Out of memory for a \(width)×\(height) image.")
        }
        context.interpolationQuality = .high
        draw(context)
        guard let image = context.makeImage() else { throw KumquatError.conversionFailed("Couldn't render the image.") }
        return image
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    /// Composites transparency onto white, for formats without alpha.
    static func flattened(_ image: CGImage) -> CGImage {
        guard hasAlpha(image) else { return image }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        return (try? render(width: image.width, height: image.height) { ctx in
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(rect)
            ctx.draw(image, in: rect)
        }) ?? image
    }

    /// Aspect-fit into a transparent square, for icons.
    static func squared(_ image: CGImage, size: Int) -> CGImage {
        let scale = CGFloat(size) / CGFloat(max(image.width, image.height))
        let width = CGFloat(image.width) * scale, height = CGFloat(image.height) * scale
        let rect = CGRect(x: (CGFloat(size) - width) / 2, y: (CGFloat(size) - height) / 2, width: width, height: height)
        return (try? render(width: size, height: size) { $0.draw(image, in: rect) }) ?? image
    }

    static func resized(_ image: CGImage, scale: CGFloat) throws -> CGImage {
        let width = max(Int((CGFloat(image.width) * scale).rounded()), 1)
        let height = max(Int((CGFloat(image.height) * scale).rounded()), 1)
        return try render(width: width, height: height) { $0.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height)) }
    }

    static func rotated(_ image: CGImage, clockwise: Bool) throws -> CGImage {
        let width = image.width, height = image.height
        return try render(width: height, height: width) { ctx in
            if clockwise {
                ctx.translateBy(x: 0, y: CGFloat(width))
                ctx.rotate(by: -.pi / 2)
            } else {
                ctx.translateBy(x: CGFloat(height), y: 0)
                ctx.rotate(by: .pi / 2)
            }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    static func flipped(_ image: CGImage) throws -> CGImage {
        try render(width: image.width, height: image.height) { ctx in
            ctx.translateBy(x: CGFloat(image.width), y: 0)
            ctx.scaleBy(x: -1, y: 1)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
    }

    static func grayscale(_ image: CGImage) throws -> CGImage {
        let input = CIImage(cgImage: image)
        let output = input.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        guard let result = CIContext().createCGImage(output, from: input.extent) else {
            throw KumquatError.conversionFailed("Couldn't apply the filter.")
        }
        return result
    }

    // MARK: Tools

    /// Tools keep the source format when ImageIO can write it, otherwise save PNG (or JPEG for camera RAW).
    static func toolOutputFormat(for source: Format) -> Format {
        if Format.imageOutputs.contains(source), canWrite(source) || source == .webp || source == .avif { return source }
        return source == .raw ? .jpg : .png
    }

    static func runTool(_ tool: ToolID, input: URL, source: Format, parameter: String? = nil,
                        context: EngineContext) async throws -> ToolArtifact {
        let image = try await loadImage(input, source: source, context: context)
        var format = toolOutputFormat(for: source)
        var quality = context.options.quality(for: format)
        let result: CGImage

        switch tool {
        case .imageCompress:
            if source == .png, let pngquant = context.tools.pngquant {
                let output = context.scratchURL("png")
                let status = try await ProcessRunner.run(pngquant, ["--quality=60-85", "--skip-if-larger", "--output", output.path, input.path]).status
                // 98/99 mean "would not be smaller / below quality floor": fall through to a re-encode.
                if status == 0 {
                    return ToolArtifact(url: output, message: SizeReport.savings(original: input, result: output))
                }
            }
            switch format {
            case .png:
                throw KumquatError.nothingToDo(context.tools.pngquant == nil
                    ? "Install pngquant (brew install pngquant) to compress PNGs, or convert to WebP/HEIC."
                    : "This PNG is already well compressed.")
            case .tiff, .bmp:
                // Uncompressed formats: re-encoding is the compression.
                format = hasAlpha(image) ? .png : .jpg
            default:
                break
            }
            quality = 0.6
            result = image
        case .imageResizeHalf:
            result = try resized(image, scale: 0.5)
        case .imageResizeCustom:
            let spec = try ResizeSpec.parse(parameter ?? "")
            let size = spec.size(forWidth: image.width, height: image.height)
            result = try render(width: size.width, height: size.height) {
                $0.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
            }
        case .imageFit1920:
            let longest = max(image.width, image.height)
            guard longest > 1920 else { throw KumquatError.nothingToDo("Already 1920px or smaller.") }
            result = try resized(image, scale: 1920 / CGFloat(longest))
        case .imageRotateLeft:
            result = try rotated(image, clockwise: false)
        case .imageRotateRight:
            result = try rotated(image, clockwise: true)
        case .imageFlip:
            result = try flipped(image)
        case .imageGrayscale:
            result = try grayscale(image)
        case .imageRemoveBackground:
            result = try removeBackground(image)
            format = .png
        case .imageExtractText:
            let text = try TextRecognizer.recognize(image)
            guard !text.isEmpty else { throw KumquatError.nothingToDo("No text found in the image.") }
            let output = context.scratchURL("txt")
            try text.write(to: output, atomically: true, encoding: .utf8)
            return ToolArtifact(url: output, message: "Text copied", clipboardText: text)
        case .stripMetadata:
            let output = context.scratchURL(format.fileExtension)
            try stripMetadata(input, to: output, format: format, fallbackImage: image, quality: quality)
            return ToolArtifact(url: output, message: "Metadata removed")
        default:
            throw KumquatError.nothingToDo("\(tool.title) doesn't apply to images.")
        }

        let output = context.scratchURL(format.fileExtension)
        try await write(result, to: output, format: format, quality: quality, context: context)
        let message = tool == .imageCompress ? SizeReport.savings(original: input, result: output) : nil
        return ToolArtifact(url: output, message: message)
    }

    /// Animated GIF, one frame per image, scaled to fit the first image's size.
    static func makeAnimatedGIF(from urls: [URL], output: URL, context: EngineContext, frameDelay: Double = 0.6) async throws {
        var frames: [CGImage] = []
        for url in urls {
            try Task.checkCancellation()
            frames.append(try await loadImage(url, source: FormatRegistry.format(for: url), context: context))
        }
        guard let first = frames.first else { throw KumquatError.nothingToDo("No images.") }
        let maxSide = 1200
        let scale = min(1, CGFloat(maxSide) / CGFloat(max(first.width, first.height)))
        let width = Int(CGFloat(first.width) * scale), height = Int(CGFloat(first.height) * scale)
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, "com.compuserve.gif" as CFString, frames.count, nil) else {
            throw KumquatError.engineUnavailable("GIF encoding")
        }
        let fileProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
        CGImageDestinationSetProperties(destination, fileProperties)
        let frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: frameDelay]] as CFDictionary
        for frame in frames {
            let fitted = try render(width: width, height: height) { ctx in
                ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
                let factor = min(CGFloat(width) / CGFloat(frame.width), CGFloat(height) / CGFloat(frame.height))
                let w = CGFloat(frame.width) * factor, h = CGFloat(frame.height) * factor
                ctx.draw(frame, in: CGRect(x: (CGFloat(width) - w) / 2, y: (CGFloat(height) - h) / 2, width: w, height: h))
            }
            CGImageDestinationAddImage(destination, fitted, frameProperties)
        }
        guard CGImageDestinationFinalize(destination) else { throw KumquatError.conversionFailed("Couldn't write the GIF.") }
    }

    // MARK: Public helpers for the annotation editor

    /// Loads any supported image (including SVG and RAW) with orientation applied.
    public static func loadImage(at url: URL) async throws -> CGImage {
        let work = try FileManager.default.makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let context = EngineContext(options: ConversionOptions(), tools: ToolLocator(), workDirectory: work)
        return try await loadImage(url, source: FormatRegistry.format(for: url), context: context)
    }

    /// Format edited copies are saved in: the original's when ImageIO can write it, otherwise PNG.
    public static func editableFormat(for url: URL) -> Format {
        toolOutputFormat(for: FormatRegistry.format(for: url) ?? .png)
    }

    /// Writes an image, using FFmpeg for WebP/AVIF when ImageIO can't.
    public static func save(_ image: CGImage, to url: URL, format: Format, quality: Double = 0.9) async throws {
        let work = try FileManager.default.makeWorkDirectory()
        defer { try? FileManager.default.removeItem(at: work) }
        let context = EngineContext(options: ConversionOptions(), tools: ToolLocator(), workDirectory: work)
        try await write(image, to: url, format: format, quality: quality, context: context)
    }

    /// Copies the image without EXIF/GPS/XMP. Lossless when the format is unchanged.
    static func stripMetadata(_ input: URL, to output: URL, format: Format, fallbackImage: CGImage, quality: Double) throws {
        if let source = CGImageSourceCreateWithURL(input as CFURL, nil),
           let type = CGImageSourceGetType(source),
           FormatRegistry.format(for: input) == format,
           let destination = CGImageDestinationCreateWithURL(output as CFURL, type, 1, nil) {
            let options: [CFString: Any] = [
                kCGImageDestinationMetadata: CGImageMetadataCreateMutable(),
                kCGImageDestinationMergeMetadata: false,
                kCGImageMetadataShouldExcludeXMP: true,
                kCGImageMetadataShouldExcludeGPS: true,
            ]
            var error: Unmanaged<CFError>?
            if CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error) {
                return
            }
        }
        // Re-encoding from pixels drops every metadata block.
        try encode(fallbackImage, to: output, format: format, quality: quality)
    }

    static func removeBackground(_ image: CGImage) throws -> CGImage {
        if #available(macOS 14.0, *) {
            let request = VNGenerateForegroundInstanceMaskRequest()
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try handler.perform([request])
            guard let observation = request.results?.first else {
                throw KumquatError.nothingToDo("Couldn't find a subject to cut out.")
            }
            let buffer = try observation.generateMaskedImage(ofInstances: observation.allInstances, from: handler,
                                                             croppedToInstancesExtent: false)
            let masked = CIImage(cvPixelBuffer: buffer)
            guard let result = CIContext().createCGImage(masked, from: masked.extent) else {
                throw KumquatError.conversionFailed("Couldn't render the cut-out.")
            }
            return result
        }
        throw KumquatError.engineUnavailable("Background removal (macOS 14 or later)")
    }
}

/// On-device text recognition with Vision.
enum TextRecognizer {
    static func recognize(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if #available(macOS 13.0, *) { request.automaticallyDetectsLanguage = true }
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}
