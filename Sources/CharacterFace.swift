import CoreGraphics
import MetalKit
import simd

struct CharacterFaceUniforms {
    var eye0 = SIMD4<Float>.zero
    var eye1 = SIMD4<Float>.zero
    var motion = SIMD4<Float>.zero
    var mouth = SIMD4<Float>.zero
    var expression = SIMD4<Float>.zero
}

@MainActor
enum CharacterFace {
    static func texture(device: MTLDevice, image: CGImage) throws -> MTLTexture {
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw GoblinError(message: "The character transparency could not be prepared.")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let premultiplied = context.makeImage() else {
            throw GoblinError(message: "The character texture could not be prepared.")
        }
        let options: [MTKTextureLoader.Option: Any] = [.SRGB: false, .origin: MTKTextureLoader.Origin.topLeft]
        return try MTKTextureLoader(device: device).newTexture(cgImage: premultiplied, options: options)
    }

    static func uniforms(rig: CharacterRig) -> CharacterFaceUniforms {
        var result = CharacterFaceUniforms()
        for index in 0..<rig.eyes.count {
            let eye = rig.eyes[index]
            let bounds = SIMD4(Float(eye[0]), Float(eye[1]), Float(eye[2]), Float(eye[3]))
            if index == 0 { result.eye0 = bounds }
            else { result.eye1 = bounds }
        }
        result.mouth = SIMD4(Float(rig.mouth[0]), Float(rig.mouth[1]), Float(rig.mouth[2]), Float(rig.mouth[3]))
        return result
    }

    static func pipeline(device: MTLDevice) throws -> MTLRenderPipelineState {
        let library = try device.makeLibrary(source: source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "characterVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "characterFragment")
        let color = descriptor.colorAttachments[0]!
        color.pixelFormat = .bgra8Unorm
        color.isBlendingEnabled = true
        color.sourceRGBBlendFactor = .one
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.sourceAlphaBlendFactor = .one
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct VertexOut { float4 position [[position]]; float2 uv; };
    struct Face { float4 eye0; float4 eye1; float4 motion; float4 mouth; float4 expression; };
    vertex VertexOut characterVertex(uint id [[vertex_id]], const device float4 *vertices [[buffer(0)]]) {
        VertexOut out;
        out.position = float4(vertices[id].xy, 0.0, 1.0);
        out.uv = vertices[id].zw;
        return out;
    }
    float4 eyeColor(float2 uv, float4 eye, float4 original, texture2d<float> image,
                    texture2d<float> eyelids, sampler sample, float4 motion) {
        if (eye.z <= 0.0 || eye.w <= 0.0) { return original; }
        float2 p = (uv - eye.xy) / eye.zw;
        float radius = max(abs(p.x), abs(p.y));
        if (radius > 1.15) { return original; }
        float edge = 1.0 - smoothstep(1.0, 1.15, radius);
        float2 gaze = motion.yz * eye.zw * 0.25;
        float4 looking = image.sample(sample, uv - gaze);
        float4 openEye = mix(original, looking, edge);
        if (motion.x <= 0.0) { return openEye; }
        float upper = -1.0 + motion.x * 1.5;
        float lower = 1.0 - motion.x * 0.5;
        float lid = 1.0 - smoothstep(upper - 0.08, upper + 0.08, p.y);
        lid = max(lid, smoothstep(lower - 0.06, lower + 0.06, p.y));
        float4 closed = eyelids.sample(sample, uv);
        return mix(openEye, closed, lid * edge);
    }
    fragment float4 characterFragment(VertexOut in [[stage_in]], texture2d<float> image [[texture(0)]],
                                       texture2d<float> eyelids [[texture(1)]], constant Face &face [[buffer(0)]]) {
        constexpr sampler linearSample(filter::linear, address::clamp_to_edge);
        if (face.motion.w > 0.0) {
            float2 point = (in.uv - 0.5) * 2.0;
            float radius = dot(point, point);
            float alpha = exp(-radius * 3.0) * (1.0 - smoothstep(0.65, 1.0, radius)) * 0.22;
            return float4(0.0, 0.0, 0.0, alpha);
        }
        float4 color = image.sample(linearSample, in.uv);
        color = eyeColor(in.uv, face.eye0, color, image, eyelids, linearSample, face.motion);
        color = eyeColor(in.uv, face.eye1, color, image, eyelids, linearSample, face.motion);
        if (face.expression.x != 0.0) {
            float2 mouthSize = max(face.mouth.zw, float2(0.001));
            float2 mouthUV = (in.uv - face.mouth.xy) / mouthSize;
            if (abs(mouthUV.x) <= 1.0 && abs(mouthUV.y) <= 1.0) {
                float curve = (mouthUV.x * mouthUV.x - 0.5) * face.expression.x * 0.02;
                float2 warped = in.uv;
                warped.y -= curve;
                color = image.sample(linearSample, warped);
            }
        }
        if (face.expression.y != 0.0) {
            float4 eyes[2] = { face.eye0, face.eye1 };
            for (int index = 0; index < 2; index++) {
                float4 eye = eyes[index];
                float2 eyeSize = max(eye.zw, float2(0.001));
                float2 browUV = (in.uv - eye.xy) / eyeSize;
                if (abs(browUV.x) <= 1.4 && browUV.y >= -2.2 && browUV.y <= -1.2) {
                    float2 warped = in.uv;
                    warped.y -= face.expression.y * 0.008;
                    color = image.sample(linearSample, warped);
                }
            }
        }
        return color;
    }
    """
}
