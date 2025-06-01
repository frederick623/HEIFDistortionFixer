#include <metal_stdlib>
using namespace metal;

struct CameraMatrix {
    float fx; // Focal length X
    float fy; // Focal length Y
    float cx; // Principal point X
    float cy; // Principal point Y
};

// First pass: Generate mapping texture (distorted UV coordinates for each undistorted pixel)
kernel void generateMapping(
    texture2d<float, access::write> mappingTexture [[texture(0)]],
    constant float &distortionStrength [[buffer(0)]],
    constant CameraMatrix &cameraMatrix [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint width = mappingTexture.get_width();
    uint height = mappingTexture.get_height();
    
    // Pixel coordinates (undistorted image)
    float x = float(gid.x);
    float y = float(gid.y);
    
    // Normalize to camera coordinates
    float xn = (x - cameraMatrix.cx) / cameraMatrix.fx;
    float yn = (y - cameraMatrix.cy) / cameraMatrix.fy;
    
    // Radial distance
    float r = sqrt(xn * xn + yn * yn);
    float r2 = r * r;
    float r4 = r2 * r2;
    
    // Distortion parameters
    float k1 = distortionStrength * 0.3; // Matches OpenCV's -0.3 * adjustment_factor
    float k2 = abs(distortionStrength) * 0.1; // Matches OpenCV's 0.1 * adjustment_factor
    float p1 = distortionStrength * 0.01; // Small tangential coefficient
    float p2 = distortionStrength * 0.01; // Small tangential coefficient
    float balance = abs(distortionStrength); // Interpolation strength
    
    // Radial distortion
    float distortionFactor = 1.0 + k1 * r2 + k2 * r4;
    float xd_radial = xn * distortionFactor;
    float yd_radial = yn * distortionFactor;
    
    // Tangential distortion
    float xd_tangential = 2.0 * p1 * xn * yn + p2 * (r2 + 2.0 * xn * xn);
    float yd_tangential = p1 * (r2 + 2.0 * yn * yn) + 2.0 * p2 * xn * yn;
    
    // Total distorted coordinates
    float xd = xd_radial + xd_tangential;
    float yd = yd_radial + yd_tangential;
    
    // Convert back to pixel coordinates
    float xd_pixel = xd * cameraMatrix.fx + cameraMatrix.cx;
    float yd_pixel = yd * cameraMatrix.fy + cameraMatrix.cy;
    
    // Normalize to UV coordinates (0 to 1)
    float2 distortedUV = float2(xd_pixel / float(width), 1.0 - yd_pixel / float(height)); // Flip Y for Metal
    
    // Interpolate with undistorted UV
    float2 undistortedUV = float2(float(gid.x) / float(width), 1.0 - float(gid.y) / float(height));
    float2 finalUV = mix(undistortedUV, distortedUV, balance);
    
    // Write to mapping texture
    mappingTexture.write(float4(finalUV, 0.0, 1.0), gid); // Store UV as RG, ignore BA
}

// Second pass: Apply mapping to sample input image
kernel void applyMapping(
    texture2d<float, access::read> inputTexture [[texture(0)]],
    texture2d<float, access::read> mappingTexture [[texture(1)]],
    texture2d<float, access::write> outputTexture [[texture(2)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint width = inputTexture.get_width();
    uint height = inputTexture.get_height();
    
    // Read source UV from mapping texture
    float4 mapping = mappingTexture.read(gid);
    float2 sourceUV = mapping.xy;
    
    // Sample input texture if UV is valid
    if (sourceUV.x >= 0.0 && sourceUV.x <= 1.0 && sourceUV.y >= 0.0 && sourceUV.y <= 1.0) {
        float4 color = inputTexture.read(uint2(sourceUV.x * float(width), sourceUV.y * float(height)));
        outputTexture.write(color, gid);
    } else {
        outputTexture.write(float4(0.0), gid); // Fill invalid areas with black
    }
}
