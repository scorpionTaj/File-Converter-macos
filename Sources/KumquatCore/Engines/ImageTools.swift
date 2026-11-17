import Foundation
import CoreImage
import ImageIO

// Upscaling, metadata editing and batch renaming.
extension ImageEngine {
    /// Largest side an upscaled image may have; beyond this, memory use and file size stop making sense.
    static let maxUpscaledSide = 16_384

    /// High-quality Lanczos enlargement with light sharpening. This is resampling, not "AI" super-resolution:
    /// it adds no detail that wasn't there, but keeps edges much cleaner than a plain resize.
    static func upscaled(_ image: CGImage, factor: CGFloat) throws -> CGImage {
        guard CGFloat(max(image.width, image.height)) * factor <= CGFloat(maxUpscaledSide) else {
            throw KumquatError.nothingToDo("Already too large to upscale (the result would be over \(maxUpscaledSide)px).")
        }
        let input = CIImage(cgImage: image)
        let scaled = input
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: factor, kCIInputAspectRatioKey: 1])
            .applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: 1.5 * factor, kCIInputIntensityKey: 0.4])
        let extent = CGRect(x: 0, y: 0, width: (CGFloat(image.width) * factor).rounded(),
                            height: (CGFloat(image.height) * factor).rounded())
        guard let result = CIContext().createCGImage(scaled, from: extent,
                                                     format: .RGBA8,
                                                     colorSpace: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)) else {
            throw KumquatError.conversionFailed("Couldn't upscale the image.")
        }
        return result
    }
}

/// Changes to an image's date taken, title, author, copyright and location, parsed from
/// "date=2024-05-01 14:30; title=Beach; location=31.63,-8.01". An empty value removes the field.
/// Applied losslessly: the pixels are copied untouched.
public struct MetadataEdit: Equatable, Sendable {
    public enum Change: Equatable, Sendable {
        case set(String)
        case remove
    }

    public var date: Change?
    public var title: Change?
    public var artist: Change?
    public var copyright: Change?
    /// Latitude and longitude in degrees.
    public var location: LocationChange?

    public enum LocationChange: Equatable, Sendable {
        case set(latitude: Double, longitude: Double)
        case remove
    }

    /// Formats ImageIO can rewrite metadata for without re-encoding.
    public static let editableFormats: Set<Format> = [.jpg, .png, .tiff, .heic]

    public init(date: Change? = nil, title: Change? = nil, artist: Change? = nil, copyright: Change? = nil,
                location: LocationChange? = nil) {
        self.date = date
        self.title = title
        self.artist = artist
        self.copyright = copyright
        self.location = location
    }

    public var isEmpty: Bool { date == nil && title == nil && artist == nil && copyright == nil && location == nil }

    public static func parse(_ text: String) throws -> MetadataEdit {
        var edit = MetadataEdit()
        for rawPart in text.split(separator: ";") {
            let part = rawPart.trimmingCharacters(in: .whitespaces)
            guard !part.isEmpty else { continue }
            guard let equals = part.firstIndex(of: "=") else {
                throw KumquatError.invalidInput("“\(part)” should look like field=value, e.g. title=Beach.")
            }
            let key = part[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let value = part[part.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            let change: Change = value.isEmpty ? .remove : .set(value)
            switch key {
            case "date", "taken", "datetaken":
                if case .set(let raw) = change {
                    guard let date = parseDate(raw) else {
                        throw KumquatError.invalidInput("“\(raw)” isn't a date. Use 2024-05-01 or 2024-05-01 14:30.")
                    }
                    edit.date = .set(exifDate(date))
                } else {
                    edit.date = .remove
                }
            case "title", "description", "caption": edit.title = change
            case "artist", "author", "creator": edit.artist = change
            case "copyright": edit.copyright = change
            case "location", "gps":
                if value.isEmpty || value.lowercased() == "remove" {
                    edit.location = .remove
                } else {
                    let numbers = value.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
                    guard numbers.count == 2, let lat = numbers[0], let lon = numbers[1],
                          (-90...90).contains(lat), (-180...180).contains(lon) else {
                        throw KumquatError.invalidInput("“\(value)” isn't a location. Use latitude,longitude, e.g. 31.63,-8.01.")
                    }
                    edit.location = .set(latitude: lat, longitude: lon)
                }
            default:
                throw KumquatError.invalidInput("Unknown field “\(key)”. Use date, title, artist, copyright or location.")
            }
        }
        guard !edit.isEmpty else { throw KumquatError.nothingToDo("No changes entered.") }
        return edit
    }

    static func parseDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm",
                       "yyyy:MM:dd HH:mm:ss", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    /// EXIF's "2024:05:01 14:30:00" (local time, no zone).
    static func exifDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.string(from: date)
    }

    /// XMP paths behind each field, all removed when the field is cleared. (Removing them before setting a
    /// value makes ImageIO drop the new value from the EXIF block, so setting just overwrites.)
    private static let paths: [WritableKeyPath<MetadataEdit, Change?>: [String]] = [
        \.date: ["exif:DateTimeOriginal", "exif:DateTimeDigitized", "xmp:CreateDate", "photoshop:DateCreated"],
        \.title: ["tiff:ImageDescription", "dc:description", "dc:title"],
        \.artist: ["tiff:Artist", "dc:creator"],
        \.copyright: ["tiff:Copyright", "dc:rights"],
    ]

    /// Image-property keys each field is written to: EXIF/TIFF, and IPTC too, because ImageIO only rewrites
    /// TIFF strings in files without an IPTC block and maps them to IPTC (and XMP) otherwise.
    private static let properties: [WritableKeyPath<MetadataEdit, Change?>: [(dictionary: CFString, key: CFString, list: Bool)]] = [
        \.date: [(kCGImagePropertyExifDictionary, kCGImagePropertyExifDateTimeOriginal, false),
                 (kCGImagePropertyExifDictionary, kCGImagePropertyExifDateTimeDigitized, false)],
        \.title: [(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFImageDescription, false),
                  (kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCCaptionAbstract, false)],
        \.artist: [(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFArtist, false),
                   (kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCByline, true)],
        \.copyright: [(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFCopyright, false),
                      (kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCCopyrightNotice, false)],
    ]

    /// Writes a copy of `input` with the changes, without re-encoding the pixels.
    func apply(_ input: URL, to output: URL) throws {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil), let type = CGImageSourceGetType(source),
              let destination = CGImageDestinationCreateWithURL(output as CFURL, type, 1, nil) else {
            throw KumquatError.invalidInput("\(input.lastPathComponent) isn't a readable image.")
        }
        let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil).flatMap { CGImageMetadataCreateMutableCopy($0) }
            ?? CGImageMetadataCreateMutable()
        for (field, paths) in Self.paths {
            guard let change = self[keyPath: field] else { continue }
            guard case .set(let value) = change else {
                for path in paths { CGImageMetadataRemoveTagWithPath(metadata, nil, path as CFString) }
                continue
            }
            for (dictionary, key, list) in Self.properties[field] ?? [] {
                let typed: CFTypeRef = list ? [value] as CFArray : value as CFString
                guard CGImageMetadataSetValueMatchingImageProperty(metadata, dictionary, key, typed) else {
                    throw KumquatError.conversionFailed("Couldn't set \(key) on \(input.lastPathComponent).")
                }
            }
        }
        if case .set(let latitude, let longitude) = location {
            let gps: [(CFString, CFTypeRef)] = [
                (kCGImagePropertyGPSLatitude, abs(latitude) as CFNumber),
                (kCGImagePropertyGPSLatitudeRef, (latitude < 0 ? "S" : "N") as CFString),
                (kCGImagePropertyGPSLongitude, abs(longitude) as CFNumber),
                (kCGImagePropertyGPSLongitudeRef, (longitude < 0 ? "W" : "E") as CFString),
            ]
            for (key, value) in gps {
                guard CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyGPSDictionary, key, value) else {
                    throw KumquatError.conversionFailed("Couldn't set the location on \(input.lastPathComponent).")
                }
            }
        }
        var options: [CFString: Any] = [kCGImageDestinationMetadata: metadata, kCGImageDestinationMergeMetadata: false]
        if location == .remove { options[kCGImageMetadataShouldExcludeGPS] = true }
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error) else {
            let reason = error?.takeRetainedValue().localizedDescription ?? "unsupported format"
            throw KumquatError.conversionFailed("Couldn't rewrite the metadata of \(input.lastPathComponent) (\(reason)).")
        }
    }
}

/// Names for renamed copies: "Holiday {date} {n}" → "Holiday 2024-05-01 03".
public enum RenamePattern {
    public static func render(_ pattern: String, original: URL, index: Int, count: Int, date: Date) throws -> String {
        var name = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        guard !name.isEmpty else { throw KumquatError.nothingToDo("No name entered.") }
        // Without {n}, several files would all get the same name; number them anyway.
        if count > 1, !name.contains("{n}") { name += " {n}" }
        let digits = max(2, String(count).count)
        let number = String(index + 1)
        let calendar = Calendar(identifier: .gregorian)
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let day = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        name = name
            .replacingOccurrences(of: "{name}", with: FormatRegistry.baseName(of: original))
            .replacingOccurrences(of: "{n}", with: String(repeating: "0", count: max(0, digits - number.count)) + number)
            .replacingOccurrences(of: "{date}", with: day)
        return name
    }

    /// When a photo was taken (EXIF), otherwise when the file was created.
    public static func date(of url: URL) -> Date {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String,
           let date = MetadataEdit.parseDate(text) {
            return date
        }
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate ?? Date()
    }
}
