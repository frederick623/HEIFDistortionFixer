import SwiftUI
import PhotosUI
import MetalKit
import Photos
import CoreImage
import Combine

struct ContentView: View {
    @State private var selectedItem: PhotosPickerItem?
    @State private var inputImage: UIImage?
    @State private var correctedImage: UIImage?
    @State private var distortionStrength: Float = 0.0 // Single parameter (-1.0 to 1.0)
    @State private var debounceSubject = PassthroughSubject<Float, Never>()
    @State private var cancellables = Set<AnyCancellable>()
    
    var body: some View {
        VStack {
            // Image display
            if let correctedImage = correctedImage {
                Image(uiImage: correctedImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 400)
            } else if let inputImage = inputImage {
                Image(uiImage: inputImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 400)
            } else {
                Text("Select an image to begin")
                    .foregroundColor(.gray)
                    .frame(maxHeight: 400)
            }
            
            // Single slider for distortion strength
            VStack {
                Text("Distortion Strength: \(distortionStrength, specifier: "%.3f")")
                Slider(value: $distortionStrength, in: -2.0...2.0, step: 0.1)
                    .padding()
                    .onChange(of: distortionStrength) { newValue in
                                            debounceSubject.send(newValue)
                                        }
                                }
                    .onAppear {
                        // Debounce slider updates to prevent rapid processing
                        debounceSubject
                            .debounce(for: .milliseconds(100), scheduler: DispatchQueue.main)
                            .sink { value in
                                updateImage(distortionStrength: value)
                            }
                            .store(in: &cancellables)
            }
            
            // Photo picker and save button
            PhotosPicker("Select Image", selection: $selectedItem, matching: .images)
                .padding()
                .onChange(of: selectedItem) { newItem in
                    loadImage(from: newItem)
                }
            
            Button("Save Corrected Image") {
                saveImage()
            }
            .disabled(correctedImage == nil)
            .padding()
            .background(Color.blue)
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding()
    }
    
    func loadImage(from item: PhotosPickerItem?) {
        guard let item = item else { return }
        item.loadTransferable(type: Data.self) { result in
            switch result {
            case .success(let data):
                if let data = data, let uiImage = UIImage(data: data) {
                    DispatchQueue.main.async {
                        inputImage = uiImage
                        updateImage(distortionStrength: distortionStrength)
                    }
                }
            case .failure(let error):
                print("Error loading image: \(error)")
            }
        }
    }
    
    func updateImage(distortionStrength: Float){
        guard let inputImage = inputImage else { return }
        guard let cgImage = inputImage.cgImage else { return }
        
        // Process with Metal
        if let correctedCGImage = MetalProcessor.processImage(cgImage, distortionStrength: distortionStrength) {
            DispatchQueue.main.async {
                correctedImage = UIImage(cgImage: correctedCGImage)
            }
        }
    }
    
    func saveImage() {
        guard let correctedImage = correctedImage else { return }
        PHPhotoLibrary.requestAuthorization { status in
            if status == .authorized {
                PHPhotoLibrary.shared().performChanges {
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, data: correctedImage.jpegData(compressionQuality: 1.0)!, options: nil)
                } completionHandler: { success, error in
                    DispatchQueue.main.async {
                        if success {
                            print("Image saved to Photos")
                        } else if let error = error {
                            print("Error saving image: \(error)")
                        }
                    }
                }
            }
        }
    }
}

// Metal processing class
class MetalProcessor {
    static let device = MTLCreateSystemDefaultDevice()!
    static let commandQueue = device.makeCommandQueue()!
    static let library = device.makeDefaultLibrary()!
    static let kernel = library.makeFunction(name: "distortionCorrection")!
    static let pipelineState: MTLComputePipelineState = {
        try! device.makeComputePipelineState(function: kernel)
    }()
    static let ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false]) // Reusable CIContext
    
    static func processImage(_ inputCGImage: CGImage, distortionStrength: Float) -> CGImage? {
        // Create Metal texture from CGImage
        let textureLoader = MTKTextureLoader(device: device)
        guard let inputTexture = try? textureLoader.newTexture(cgImage: inputCGImage, options: nil) else {
            print("Failed to create input texture")
            return nil
        }
        
        // Create output texture
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: inputTexture.pixelFormat,
            width: inputTexture.width,
            height: inputTexture.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let outputTexture = device.makeTexture(descriptor: descriptor) else {
            print("Failed to create output texture")
            return nil
        }
        
        // Create command buffer
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let commandEncoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }
        
        // Set pipeline and textures
        commandEncoder.setComputePipelineState(pipelineState)
        commandEncoder.setTexture(inputTexture, index: 0)
        commandEncoder.setTexture(outputTexture, index: 1)
        
        // Set distortion strength
        var distortionStrength = distortionStrength
        commandEncoder.setBytes(&distortionStrength, length: MemoryLayout<Float>.size, index: 0)
        
        // Dispatch threads
        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroupCount = MTLSize(
            width: (inputTexture.width + threadgroupSize.width - 1) / threadgroupSize.width,
            height: (inputTexture.height + threadgroupSize.height - 1) / threadgroupSize.height,
            depth: 1
        )
        commandEncoder.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadgroupSize)
        commandEncoder.endEncoding()
        
        // Commit and wait
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        // Convert output texture to CIImage
        guard let ciImage = CIImage(mtlTexture: outputTexture, options: nil) else { return nil }
        
        // Output full image (mimicking OpenCV) or crop minimally
        let outputCIImage = ciImage // Optionally: .cropped(to: validRect) for minimal cropping
        guard let outputCGImage = ciContext.createCGImage(outputCIImage, from: outputCIImage.extent) else { return nil }
        
        return outputCGImage
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
