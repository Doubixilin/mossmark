import Foundation
import ImageIO
import MarkdownCore

enum MarkdownExportImageLoader {
    static func loadImages(
        for document: MarkdownExportDocument,
        documentURL: URL?
    ) -> [String: MarkdownExportImage] {
        guard let documentURL else { return [:] }
        var images: [String: MarkdownExportImage] = [:]

        for source in MarkdownExportParser.imageSources(in: document) {
            guard let url = MarkdownResourceResolver.resolve(
                reference: source,
                relativeTo: documentURL
            ),
            let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
            (values.fileSize ?? 0) <= 100 * 1_024 * 1_024,
            let data = try? Data(contentsOf: url)
            else {
                continue
            }

            var width = 800
            var height = 600
            if let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
               let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any]
            {
                width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? width
                height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? height
            }
            images[source] = MarkdownExportImage(
                data: data,
                fileExtension: url.pathExtension,
                widthPixels: width,
                heightPixels: height
            )
        }
        return images
    }
}
