// Append the four gestures on the same ground line as the existing bed photos.
import AppKit
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
func open(_ path: String) -> CGImage {
    let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!
    return CGImageSourceCreateImageAtIndex(source, 0, nil)!
}
let bed = open(args[1]), gestures = open(args[2])
let cell = bed.width / 4, side = gestures.width / 2
let context = CGContext(data: nil, width: cell*4, height: cell*4, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.draw(bed, in: CGRect(x: 0, y: cell, width: bed.width, height: bed.height))
context.interpolationQuality = .high
for i in 0..<4 {
    let crop = gestures.cropping(to: CGRect(x: (i%2)*side, y: (i/2)*side, width: side, height: side))!
    // The visible 609px bed spans 354px in a registered cell. Bottom is row 322.
    let ratio = 354.0 / 609
    let rect = CGRect(x: Double(i*cell)+Double(cell)/2-314*ratio,
                      y: Double(cell)-322-(Double(side)-503)*ratio,
                      width: Double(side)*ratio, height: Double(side)*ratio)
    context.draw(crop, in: rect)
}
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[3]) as CFURL,
                                          UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, context.makeImage()!, nil)
precondition(CGImageDestinationFinalize(dest))
