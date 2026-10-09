#!/usr/bin/env swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum RenderMode: String {
    case opaque
    case alpha
    case roundedAlpha = "rounded-alpha"
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard CommandLine.arguments.count >= 6 else {
    fail("usage: generate-app-icons.swift <source.png> <output-directory> <opaque|alpha|rounded-alpha> <background-hex> <size> [size ...]")
}

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
guard let mode = RenderMode(rawValue: CommandLine.arguments[3]) else {
    fail("mode must be opaque or alpha")
}

let hex = CommandLine.arguments[4].trimmingCharacters(in: CharacterSet(charactersIn: "#"))
guard hex.count == 6, let rgb = Int(hex, radix: 16) else {
    fail("background color must be a six-digit hex value")
}

let sizes = CommandLine.arguments.dropFirst(5).map { value -> Int in
    guard let size = Int(value), size > 0 else { fail("invalid icon size: \(value)") }
    return size
}

guard
    let sourceProvider = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
    let source = CGImageSourceCreateImageAtIndex(sourceProvider, 0, nil),
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
else {
    fail("unable to load source image: \(sourceURL.path)")
}

let red = CGFloat((rgb >> 16) & 0xff) / 255
let green = CGFloat((rgb >> 8) & 0xff) / 255
let blue = CGFloat(rgb & 0xff) / 255

try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

for size in sizes {
    // Render through an alpha-capable surface even for opaque output. SVG
    // thumbnails supplied by Quick Look are RGBA; drawing them directly into
    // a skip-alpha bitmap can drop the foreground on current CoreGraphics.
    let alphaInfo: CGImageAlphaInfo = .premultipliedLast
    let bitmapInfo = CGBitmapInfo(rawValue: alphaInfo.rawValue).union(.byteOrder32Big)

    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: bitmapInfo.rawValue
    ) else {
        fail("unable to allocate \(size)x\(size) bitmap")
    }

    let target = CGRect(x: 0, y: 0, width: size, height: size)
    context.clear(target)
    if mode == .roundedAlpha {
        let scale = CGFloat(size) / 1024
        let tile = CGRect(x: 72 * scale, y: 72 * scale, width: 880 * scale, height: 880 * scale)
        context.addPath(CGPath(
            roundedRect: tile,
            cornerWidth: 196 * scale,
            cornerHeight: 196 * scale,
            transform: nil
        ))
        context.clip()
    }
    context.interpolationQuality = .high
    context.draw(source, in: target)

    if mode == .roundedAlpha,
       let bytes = context.data?.assumingMemoryBound(to: UInt8.self) {
        let cornerAlpha = bytes[3]
        let centerAlpha = bytes[((size / 2) * context.bytesPerRow) + ((size / 2) * 4) + 3]
        guard cornerAlpha == 0, centerAlpha == 255 else {
            fail("rounded-alpha validation failed for \(size)x\(size)")
        }
    }

    guard let renderedImage = context.makeImage() else {
        fail("unable to create \(size)x\(size) image")
    }

    let image: CGImage
    if mode == .opaque {
        guard let sourceBytes = context.data?.assumingMemoryBound(to: UInt8.self) else {
            fail("unable to read \(size)x\(size) icon pixels")
        }
        var opaqueData = Data(count: size * size * 3)
        opaqueData.withUnsafeMutableBytes { rawDestination in
            let destination = rawDestination.bindMemory(to: UInt8.self)
            let background = (
                UInt16((red * 255).rounded()),
                UInt16((green * 255).rounded()),
                UInt16((blue * 255).rounded())
            )
            for y in 0 ..< size {
                for x in 0 ..< size {
                    let sourceOffset = y * context.bytesPerRow + x * 4
                    let destinationOffset = (y * size + x) * 3
                    let inverseAlpha = UInt16(255 - sourceBytes[sourceOffset + 3])
                    destination[destinationOffset] = UInt8(
                        min(255, UInt16(sourceBytes[sourceOffset]) + background.0 * inverseAlpha / 255)
                    )
                    destination[destinationOffset + 1] = UInt8(
                        min(255, UInt16(sourceBytes[sourceOffset + 1]) + background.1 * inverseAlpha / 255)
                    )
                    destination[destinationOffset + 2] = UInt8(
                        min(255, UInt16(sourceBytes[sourceOffset + 2]) + background.2 * inverseAlpha / 255)
                    )
                }
            }
        }
        let opaqueBitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        guard let provider = CGDataProvider(data: opaqueData as CFData),
              let opaqueImage = CGImage(
                  width: renderedImage.width,
                  height: renderedImage.height,
                  bitsPerComponent: renderedImage.bitsPerComponent,
                  bitsPerPixel: 24,
                  bytesPerRow: size * 3,
                  space: colorSpace,
                  bitmapInfo: opaqueBitmapInfo,
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              )
        else {
            fail("unable to flatten \(size)x\(size) icon")
        }
        image = opaqueImage
    } else {
        image = renderedImage
    }

    let destinationURL = outputURL.appendingPathComponent("AppIcon-\(size).png")
    guard let destination = CGImageDestinationCreateWithURL(
        destinationURL as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        fail("unable to create PNG destination: \(destinationURL.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fail("unable to encode PNG: \(destinationURL.path)")
    }
}
