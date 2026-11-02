import AppKit
import MetalKit
import XCTest
@testable import Goblin

final class CharacterRendererTests: XCTestCase {
    @MainActor
    func testTransparentPNGColorsDoNotLeakAndPartialEdgesCompositeOnce() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let pipeline = try CharacterFace.pipeline(device: device)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let pixels: [UInt8] = [250, 80, 20, 0, 200, 100, 40, 128, 64, 128, 200, 255]
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(width: 3, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
                                         bytesPerRow: 12, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                         provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent))
        let input = try CharacterFace.texture(device: device, image: image)
        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 6, height: 1, mipmapped: false)
        outputDescriptor.storageMode = .shared
        outputDescriptor.usage = [.renderTarget]
        let output = try XCTUnwrap(device.makeTexture(descriptor: outputDescriptor))
        let vertices: [SIMD4<Float>] = [SIMD4(-1,-1,0,1), SIMD4(1,-1,1,1), SIMD4(-1,1,0,0), SIMD4(1,1,1,0)]
        let buffer = try XCTUnwrap(device.makeBuffer(bytes: vertices, length: vertices.count * MemoryLayout<SIMD4<Float>>.stride))
        var face = CharacterFaceUniforms()
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        pass.colorAttachments[0].storeAction = .store
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setFragmentTexture(input, index: 0)
        encoder.setFragmentTexture(input, index: 1)
        encoder.setFragmentBytes(&face, length: MemoryLayout<CharacterFaceUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
        var rendered = [UInt8](repeating: 0, count: 24)
        rendered.withUnsafeMutableBytes {
            output.getBytes($0.baseAddress!, bytesPerRow: 24, from: MTLRegionMake2D(0, 0, 6, 1), mipmapLevel: 0)
        }
        let expected: [UInt8] = [0, 0, 0, 0, 5, 13, 25, 32, 15, 38, 75, 96,
                                 65, 70, 91, 160, 155, 109, 73, 223, 200, 128, 64, 255]
        for index in expected.indices {
            XCTAssertEqual(Double(rendered[index]), Double(expected[index]), accuracy: 1)
        }
    }

    @MainActor
    func testNativeGPUProducesTheApprovedFigureAndBlink() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let pipeline = try CharacterFace.pipeline(device: device)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let catalog = try JSONDecoder().decode(CharacterRigCatalog.self, from: Data(contentsOf: root.appendingPathComponent("Resources/character-rigs.json")))
        let image = try XCTUnwrap(NSImage(contentsOf: root.appendingPathComponent("Resources/Standing/guard.png")))
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let input = try CharacterFace.texture(device: device, image: cg)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: cg.width, height: cg.height, mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .shared
        let output = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let vertices: [SIMD4<Float>] = [SIMD4(-1,-1,0,1), SIMD4(1,-1,1,1), SIMD4(-1,1,0,0), SIMD4(1,1,1,0)]
        let buffer = try XCTUnwrap(device.makeBuffer(bytes: vertices, length: vertices.count * MemoryLayout<SIMD4<Float>>.stride))
        let rig = try XCTUnwrap(catalog.avatars["guard"])
        var face = CharacterFace.uniforms(rig: rig)
        let closedImage = try XCTUnwrap(NSImage(contentsOf: root.appendingPathComponent("Resources/Eyelids/guard.png")))
        let closedCG = try XCTUnwrap(closedImage.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let eyelids = try CharacterFace.texture(device: device, image: closedCG)
        var frames: [[UInt8]] = []
        for blink in [Float(0), Float(1)] {
            face.motion.x = blink
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = output
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
            pass.colorAttachments[0].storeAction = .store
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setFragmentTexture(input, index: 0)
            encoder.setFragmentTexture(eyelids, index: 1)
            encoder.setFragmentBytes(&face, length: MemoryLayout<CharacterFaceUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            XCTAssertEqual(command.status, .completed, command.error?.localizedDescription ?? "GPU command failed")
            var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
            pixels.withUnsafeMutableBytes { bytes in
                output.getBytes(bytes.baseAddress!, bytesPerRow: cg.width * 4, from: MTLRegionMake2D(0, 0, cg.width, cg.height), mipmapLevel: 0)
            }
            frames.append(pixels)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: cg.width, pixelsHigh: cg.height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: cg.width * 4, bitsPerPixel: 32))
            let destination = try XCTUnwrap(bitmap.bitmapData)
            for index in stride(from: 0, to: pixels.count, by: 4) {
                destination[index] = pixels[index + 2]
                destination[index + 1] = pixels[index + 1]
                destination[index + 2] = pixels[index]
                destination[index + 3] = pixels[index + 3]
            }
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            if let capturePath = ProcessInfo.processInfo.environment["GOBLIN_CAPTURE_DIR"] {
                let directory = URL(fileURLWithPath: capturePath)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let file = directory.appendingPathComponent("goblin-render-blink-\(Int(blink)).png")
                try png.write(to: file)
                print("GPU render:", file.path)
            }
        }
        var opaque = 0
        var changed = 0
        for index in stride(from: 0, to: frames[0].count, by: 4) {
            if frames[0][index + 3] > 20 { opaque += 1 }
            if frames[0][index] != frames[1][index] { changed += 1 }
        }
        XCTAssertGreaterThan(opaque, 30_000)
        XCTAssertGreaterThan(changed, 200)
        XCTAssertLessThan(changed, 2_000)
    }
}
