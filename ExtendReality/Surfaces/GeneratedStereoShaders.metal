#include <metal_stdlib>
using namespace metal;

struct GeneratedStereoRasterData {
    float4 position [[position]];
    float2 uv;
};

struct GeneratedStereoUniforms {
    float2 sourceSize;
    float2 targetSize;
    float disparityFraction;
    float eyeSign;
    uint hasDepth;
    uint rotation;
};

struct SDRVideoUniforms {
    float2 sourceSize;
    float2 targetSize;
    uint rotation;
    uint padding;
};

vertex GeneratedStereoRasterData generatedStereoVertex(uint vertexID [[vertex_id]]) {
    const float2 positions[4] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0,  1.0),
    };
    const float2 textureCoordinates[4] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 0.0),
    };
    GeneratedStereoRasterData output;
    output.position = float4(positions[vertexID], 0.0, 1.0);
    output.uv = textureCoordinates[vertexID];
    return output;
}

float2 orientedSourceSize(float2 sourceSize, uint rotation) {
    return rotation == 1 || rotation == 3
        ? sourceSize.yx
        : sourceSize;
}

float2 sourceUVForOrientedUV(float2 uv, uint rotation) {
    switch (rotation) {
        case 1: return float2(uv.y, 1.0 - uv.x);
        case 2: return float2(1.0 - uv.x, 1.0 - uv.y);
        case 3: return float2(1.0 - uv.y, uv.x);
        default: return uv;
    }
}

float2 aspectFitContentUV(
    float2 displayUV,
    float2 sourceSize,
    float2 targetSize,
    thread bool& outside)
{
    float sourceAspect = sourceSize.x / max(sourceSize.y, 1.0);
    float targetAspect = targetSize.x / max(targetSize.y, 1.0);
    float2 contentUV = displayUV;
    outside = false;

    if (sourceAspect > targetAspect) {
        float displayedHeight = targetAspect / sourceAspect;
        float margin = (1.0 - displayedHeight) * 0.5;
        outside = contentUV.y < margin || contentUV.y > 1.0 - margin;
        contentUV.y = (contentUV.y - margin) / max(displayedHeight, 0.0001);
    } else {
        float displayedWidth = sourceAspect / targetAspect;
        float margin = (1.0 - displayedWidth) * 0.5;
        outside = contentUV.x < margin || contentUV.x > 1.0 - margin;
        contentUV.x = (contentUV.x - margin) / max(displayedWidth, 0.0001);
    }
    return clamp(contentUV, 0.0, 1.0);
}

fragment float4 sdrVideoFragment(
    GeneratedStereoRasterData input [[stage_in]],
    texture2d<float> sourceTexture [[texture(0)]],
    constant SDRVideoUniforms& uniforms [[buffer(0)]])
{
    constexpr sampler linearSampler(
        coord::normalized,
        address::clamp_to_edge,
        filter::linear
    );
    bool outside = false;
    float2 contentUV = aspectFitContentUV(
        input.uv,
        orientedSourceSize(uniforms.sourceSize, uniforms.rotation),
        uniforms.targetSize,
        outside
    );
    if (outside) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }
    return sourceTexture.sample(
        linearSampler,
        sourceUVForOrientedUV(contentUV, uniforms.rotation)
    );
}

fragment float4 generatedStereoFragment(
    GeneratedStereoRasterData input [[stage_in]],
    texture2d<float> sourceTexture [[texture(0)]],
    texture2d<float> depthTexture [[texture(1)]],
    constant GeneratedStereoUniforms& uniforms [[buffer(0)]])
{
    constexpr sampler linearSampler(
        coord::normalized,
        address::clamp_to_edge,
        filter::linear
    );

    bool outside = false;
    float2 contentUV = aspectFitContentUV(
        input.uv,
        orientedSourceSize(uniforms.sourceSize, uniforms.rotation),
        uniforms.targetSize,
        outside
    );
    if (outside) {
        return float4(0.0, 0.0, 0.0, 1.0);
    }

    if (uniforms.hasDepth == 0 || uniforms.disparityFraction <= 0.0) {
        return sourceTexture.sample(
            linearSampler,
            sourceUVForOrientedUV(contentUV, uniforms.rotation)
        );
    }

    // Backward gather approximates a depth-tested forward warp. Candidate
    // samples are reprojected into the current eye and the closest match wins;
    // this naturally fills small disocclusion gaps without a second texture.
    float bestScore = 1000.0;
    float2 bestUV = sourceUVForOrientedUV(contentUV, uniforms.rotation);
    float searchRadius = uniforms.disparityFraction * 0.55;
    for (int index = -4; index <= 4; ++index) {
        float fraction = float(index) / 4.0;
        float2 candidateDisplayUV = float2(
            clamp(contentUV.x + fraction * searchRadius, 0.0, 1.0),
            contentUV.y
        );
        float2 candidateSourceUV = sourceUVForOrientedUV(
            candidateDisplayUV,
            uniforms.rotation
        );
        float depth = depthTexture.sample(linearSampler, candidateSourceUV).r;
        float projectedX = candidateDisplayUV.x
            + uniforms.eyeSign * (depth - 0.5) * uniforms.disparityFraction;
        float error = abs(projectedX - contentUV.x);
        // When two surfaces project to the same pixel, prefer the nearer one.
        float score = error - depth * 0.00001;
        if (score < bestScore) {
            bestScore = score;
            bestUV = candidateSourceUV;
        }
    }

    return sourceTexture.sample(linearSampler, bestUV);
}
