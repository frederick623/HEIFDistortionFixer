#include <metal_stdlib>
using namespace metal;

kernel void distortionCorrection(
    texture2d<float, access::read> inputTexture [[texture(0)]],
    texture2d<float, access::write> outputTexture [[texture(1)]],
    constant float &distortionStrength [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    // Get texture dimensions
    uint width = inputTexture.get_width();
    uint height = inputTexture.get_height();
    
    // Normalized coordinates (0 to 1)
    float2 uv = float2(float(gid.x) / float(width), 1.0 - float(gid.y) / float(height));
    
    // Center coordinates around (0.5, 0.5)
    float2 centeredUV = uv - float2(0.5);
    
    // Radial distance from center
    float r = length(centeredUV);
    float r2 = r * r;
    
    // Derive k1, k2, and balance from distortionStrength
    float k1 = distortionStrength * 0.3; // Matches OpenCV's -0.3 * adjustment_factor (sign flipped for correction)
    float k2 = abs(distortionStrength) * 0.1; // Matches OpenCV's 0.1 * adjustment_factor
    float balance = abs(distortionStrength); // Interpolation strength (0.0 to 1.0)
    
    // Barrel/pincushion distortion: r' = r * (1 + k1 * r^2 + k2 * r^4)
    float distortionFactor = 1.0 + k1 * r2 + k2 * r2 * r2;
    float2 distortedUV = centeredUV * distortionFactor + float2(0.5);
    
    // Interpolate between original and corrected UV
    float2 finalUV = mix(uv, distortedUV, balance);
    
    // Write to output texture
    if (finalUV.x >= 0.0 && finalUV.x <= 1.0 && finalUV.y >= 0.0 && finalUV.y <= 1.0) {
        float4 color = inputTexture.read(uint2(finalUV.x * float(width), finalUV.y * float(height)));
        outputTexture.write(color, gid);
    } else {
        outputTexture.write(float4(0.0), gid); // Fill invalid areas with black
    }
}
