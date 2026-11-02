import AppKit
import MetalKit
import QuartzCore
import SwiftUI

@MainActor
final class CharacterView: MTKView, MTKViewDelegate {
    var readSignals: (() -> CharacterSignals)?
    var motionEnabled = true {
        didSet {
            if motionEnabled == oldValue { return }
            link?.isPaused = mesh == nil
            draw()
        }
    }
    var onFailure: ((String) -> Void)?
    private var avatarID = ""
    private var mesh: CharacterMesh?
    private var motion = CharacterMotion()
    private var link: CADisplayLink?
    private var lastTime = 0.0
    private var imageSize = CGSize.zero
    private var texture: MTLTexture?
    private var eyelids: MTLTexture?
    private var pipeline: MTLRenderPipelineState?
    private var commands: MTLCommandQueue?
    private var indices: MTLBuffer?
    private var indexCount = 0
    private var face = CharacterFaceUniforms()
    private var frameBuffers: [MTLBuffer] = []
    private var nextBuffer = 0
    private let frameSlots = DispatchSemaphore(value: 3)

    override var isOpaque: Bool { false }

    init(frame: NSRect) {
        super.init(frame: frame, device: MTLCreateSystemDefaultDevice())
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        layer?.isOpaque = false
        isPaused = true
        // Static characters still need AppKit attachment and resize redraws.
        enableSetNeedsDisplay = true
        autoResizeDrawable = true
        delegate = self
        setAccessibilityElement(false)
    }

    required init(coder: NSCoder) { fatalError("Use init(frame:)") }

    func configure(id: String, resources: URL, image: () -> NSImage?) throws {
        if avatarID == id { return }
        detach()
        guard let device, let source = image(), let cgImage = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw GoblinError(message: "The character renderer could not load its image or Metal device.")
        }
        if pipeline == nil { pipeline = try CharacterFace.pipeline(device: device) }
        if commands == nil { commands = device.makeCommandQueue() }
        texture = try CharacterFace.texture(device: device, image: cgImage)
        eyelids = texture
        imageSize = CGSize(width: cgImage.width, height: cgImage.height)
        mesh = nil
        face = CharacterFaceUniforms()
        let catalogURL = resources.appendingPathComponent("character-rigs.json")
        let data = try Data(contentsOf: catalogURL)
        let catalog = try JSONDecoder().decode(CharacterRigCatalog.self, from: data)
        if let rig = catalog.avatars[id] {
            guard rig.isValid else { throw GoblinError(message: "The character rig is invalid: " + id) }
            mesh = CharacterMesh(rig: rig, aspect: imageSize.width / imageSize.height)
            face = CharacterFace.uniforms(rig: rig)
            let lidURL = resources.appendingPathComponent("Eyelids").appendingPathComponent(id + ".png")
            guard let closedImage = NSImage(contentsOf: lidURL),
                  let closedCGImage = closedImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw GoblinError(message: "The character blink texture could not be loaded: " + id)
            }
            eyelids = try CharacterFace.texture(device: device, image: closedCGImage)
        }
        var triangles: [UInt16] = []
        let columns = mesh == nil ? 1 : CharacterMesh.columns
        let rows = mesh == nil ? 1 : CharacterMesh.rows
        for row in 0..<rows {
            for column in 0..<columns {
                let a = UInt16(row * (columns + 1) + column)
                let b = a + 1
                let c = a + UInt16(columns + 1)
                triangles += [a, b, c, b, c + 1, c]
            }
        }
        indices = device.makeBuffer(bytes: triangles, length: triangles.count * MemoryLayout<UInt16>.stride)
        indexCount = triangles.count
        let vertexCount = mesh?.source.count ?? 4
        let byteCount = vertexCount * MemoryLayout<SIMD4<Float>>.stride
        var buffers: [MTLBuffer] = []
        for _ in 0..<3 {
            guard let buffer = device.makeBuffer(length: byteCount, options: .storageModeShared) else {
                throw GoblinError(message: "The character renderer could not allocate its frame buffers.")
            }
            buffers.append(buffer)
        }
        frameBuffers = buffers
        nextBuffer = 0
        avatarID = id
        motion = CharacterMotion()
        startDisplayLink()
        draw()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { detach() }
        else { startDisplayLink() }
    }

    private func startDisplayLink() {
        if link != nil || window == nil { return }
        lastTime = 0
        let display = displayLink(target: self, selector: #selector(advanceFrame(_:)))
        display.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        display.add(to: .main, forMode: .common)
        display.isPaused = !motionEnabled || mesh == nil
        link = display
    }

    @objc private func advanceFrame(_ display: CADisplayLink) {
        draw()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let viewport = bounds
        guard viewport.width > 0, viewport.height > 0, let pipeline, let commands,
              let texture, let indices, !frameBuffers.isEmpty else { return }
        if frameSlots.wait(timeout: .now()) != .success { return }
        guard let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
              let command = commands.makeCommandBuffer(),
              let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            frameSlots.signal()
            return
        }
        let buffer = frameBuffers[nextBuffer]
        nextBuffer = (nextBuffer + 1) % frameBuffers.count
        let now = CACurrentMediaTime()
        let delta = lastTime > 0 ? now - lastTime : 1.0 / 60.0
        lastTime = now
        let pose = motion.advance(seconds: delta, signals: readSignals?() ?? CharacterSignals(), enabled: motionEnabled)
        let source = mesh?.source ?? [SIMD2<Float>(0, 0), SIMD2(1, 0), SIMD2(0, 1), SIMD2(1, 1)]
        let destination = mesh?.destinations(for: pose) ?? source
        let scale = min(viewport.width / imageSize.width, viewport.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        let left = (viewport.width - width) / 2
        let vertices = buffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: source.count)
        for index in source.indices {
            let point = destination[index]
            let x = (left + Double(point.x) * width) / viewport.width * 2 - 1
            let y = Double(point.y) * height / viewport.height * 2 - 1
            vertices[index] = SIMD4(Float(x), Float(y), source[index].x, 1 - source[index].y)
        }
        face.motion = SIMD4(Float(pose.blink), Float(pose.gazeX), Float(pose.gazeY), 0)
        face.expression = SIMD4(Float(pose.smile), Float(pose.brow), 0, 0)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentTexture(eyelids, index: 1)
        if let mesh {
            let center = left + mesh.rig.pelvis[0] * width
            let halfWidth = width * 0.28
            let bottom = height * 0.005
            let top = height * 0.035
            let x0 = Float((center - halfWidth) / viewport.width * 2 - 1)
            let x1 = Float((center + halfWidth) / viewport.width * 2 - 1)
            let y0 = Float(bottom / viewport.height * 2 - 1)
            let y1 = Float(top / viewport.height * 2 - 1)
            let quad = [SIMD4(x0, y0, Float(0), Float(1)), SIMD4(x1, y0, Float(1), Float(1)),
                        SIMD4(x0, y1, Float(0), Float(0)), SIMD4(x1, y1, Float(1), Float(0))]
            var shadow = CharacterFaceUniforms()
            shadow.motion.w = 1
            encoder.setVertexBytes(quad, length: quad.count * MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.setFragmentBytes(&shadow, length: MemoryLayout<CharacterFaceUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setFragmentBytes(&face, length: MemoryLayout<CharacterFaceUniforms>.stride, index: 0)
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: indexCount, indexType: .uint16, indexBuffer: indices, indexBufferOffset: 0)
        encoder.endEncoding()
        command.present(drawable)
        let slots = frameSlots
        command.addCompletedHandler { [weak self] completed in
            slots.signal()
            if completed.status != .error { return }
            let message = completed.error?.localizedDescription ?? "Metal could not render the character."
            Task { @MainActor [weak self] in
                self?.detach()
                self?.onFailure?(message)
            }
        }
        command.commit()
        link?.isPaused = !motionEnabled || mesh == nil
    }

    func detach() {
        link?.invalidate()
        link = nil
        lastTime = 0
    }
}

@MainActor
struct LivingCharacter: NSViewRepresentable {
    let store: GoblinStore
    let reduceMotion: Bool

    func makeNSView(context: Context) -> CharacterView {
        CharacterView(frame: NSRect(x: 0, y: 0, width: CompanionLayout.figureWidth, height: CompanionLayout.figureHeight))
    }

    func updateNSView(_ view: CharacterView, context: Context) {
        view.motionEnabled = store.preferences.animations && !reduceMotion
        view.onFailure = { [weak store] message in store?.error = message }
        do {
            try view.configure(id: store.selectedAvatar, resources: store.resources) { store.avatarImage(standing: true) }
        } catch { store.error = error.localizedDescription }
        view.readSignals = { [weak store] in store?.characterSignals ?? CharacterSignals() }
    }

    static func dismantleNSView(_ view: CharacterView, coordinator: ()) {
        view.detach()
        view.readSignals = nil
    }
}
