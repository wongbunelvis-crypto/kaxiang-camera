import SwiftUI
import AVFoundation
import Vision
import CoreImage
import UIKit
import Combine

@main
struct KaxiangApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

final class CameraEngine: NSObject, ObservableObject {
    @Published var frame: UIImage?
    @Published var errorText: String?
    @Published var selected = 0 {
        didSet { rebuildBackground() }
    }

    var usingFront = true

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "kaxiang.camera.queue")
    private let ciContext = CIContext()
    private let maskRequest = VNGeneratePersonSegmentationRequest()
    private let output = AVCaptureVideoDataOutput()
    private var backgroundCI: CIImage?
    private var configured = false
    private var lastProcess: CFTimeInterval = 0
    private var currentInput: AVCaptureDeviceInput?

    override init() {
        super.init()
        maskRequest.qualityLevel = .balanced
        maskRequest.outputPixelFormat = kCVPixelFormatType_OneComponent8
        rebuildBackground()
    }

    func rebuildBackground() {
        let size = CGSize(width: 720, height: 960)
        let img = Backgrounds.image(index: selected, size: size)
        backgroundCI = CIImage(image: img)
    }

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted else {
                DispatchQueue.main.async { self.errorText = "摄像头权限被拒绝，请到设置里允许" }
                return
            }
            self.queue.async {
                self.configure()
                if !self.session.isRunning { self.session.startRunning() }
            }
        }
    }

    func stop() {
        queue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    func flip() {
        queue.async {
            self.usingFront.toggle()
            self.configure(force: true)
        }
    }

    private func configure(force: Bool = false) {
        if configured && !force { return }
        session.beginConfiguration()
        session.sessionPreset = .high

        if let old = currentInput {
            session.removeInput(old)
            currentInput = nil
        }

        let position: AVCaptureDevice.Position = usingFront ? .front : .back
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
            currentInput = input
        }

        if !configured {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.setSampleBufferDelegate(self, queue: queue)
            output.alwaysDiscardsLateVideoFrames = true
            if session.canAddOutput(output) { session.addOutput(output) }
        }
        if let conn = output.connection(with: .video), conn.isVideoOrientationSupported {
            conn.videoOrientation = .portrait
        }
        session.commitConfiguration()
        configured = true
    }
}

extension CameraEngine: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        guard now - lastProcess > 0.045 else { return }
        lastProcess = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([maskRequest])
        } catch {
            return
        }
        guard let maskBuffer = maskRequest.results?.first?.pixelBuffer else { return }

        let person = CIImage(cvPixelBuffer: pixelBuffer)
        let mask = CIImage(cvPixelBuffer: maskBuffer)
        let sx = person.extent.width / max(mask.extent.width, 1)
        let sy = person.extent.height / max(mask.extent.height, 1)
        let scaledMask = mask.transformed(by: CGAffineTransform(scaleX: sx, y: sy))

        guard let bg = backgroundCI, let filter = CIFilter(name: "CIBlendWithMask") else { return }
        let bgScaled = bg.transformed(by: CGAffineTransform(
            scaleX: person.extent.width / bg.extent.width,
            y: person.extent.height / bg.extent.height
        ))
        filter.setValue(person, forKey: kCIInputImageKey)
        filter.setValue(bgScaled, forKey: kCIInputBackgroundImageKey)
        filter.setValue(scaledMask, forKey: kCIInputMaskImageKey)
        guard var result = filter.outputImage else { return }

        if usingFront {
            result = result.transformed(by: CGAffineTransform(scaleX: -1, y: 1))
            result = result.transformed(by: CGAffineTransform(translationX: result.extent.width, y: 0))
        }

        guard let cg = ciContext.createCGImage(result, from: result.extent) else { return }
        let image = UIImage(cgImage: cg)
        DispatchQueue.main.async {
            self.frame = image
        }
    }
}

enum Backgrounds {
    static let names: [String] = [
        "深空星云", "落日海滩", "极光", "霓虹都市", "雪山", "樱花粉雾",
        "海底蓝", "沙漠金", "森林晨雾", "赛博网格", "米白极简", "薄荷",
        "蜜桃", "书架虚化", "云海", "雨夜霓虹", "胶片暖橙", "彩虹渐变",
        "舞台聚光", "月球表面", "磨砂玻璃", "银河", "赛博粉紫", "极简石墨"
    ]

    static let count = names.count

    private static let palettes: [(UIColor, UIColor, UIColor)] = [
        (UIColor(red: 0.06, green: 0.04, blue: 0.14, alpha: 1), UIColor(red: 0.48, green: 0.35, blue: 1.0, alpha: 1), UIColor(red: 0.16, green: 0.83, blue: 0.73, alpha: 1)),
        (UIColor(red: 0.16, green: 0.10, blue: 0.27, alpha: 1), UIColor(red: 0.97, green: 0.48, blue: 0.27, alpha: 1), UIColor(red: 1.0, green: 0.75, blue: 0.40, alpha: 1)),
        (UIColor(red: 0.02, green: 0.07, blue: 0.11, alpha: 1), UIColor(red: 0.16, green: 0.83, blue: 0.73, alpha: 1), UIColor(red: 0.38, green: 0.43, blue: 1.0, alpha: 1)),
        (UIColor(red: 0.03, green: 0.04, blue: 0.08, alpha: 1), UIColor(red: 0.10, green: 0.20, blue: 0.40, alpha: 1), UIColor(red: 0.94, green: 0.70, blue: 0.35, alpha: 1)),
        (UIColor(red: 0.56, green: 0.72, blue: 0.85, alpha: 1), UIColor(red: 0.85, green: 0.90, blue: 0.93, alpha: 1), UIColor(red: 0.96, green: 0.97, blue: 0.96, alpha: 1)),
        (UIColor(red: 1.0, green: 0.90, blue: 0.93, alpha: 1), UIColor(red: 1.0, green: 0.82, blue: 0.87, alpha: 1), UIColor(red: 1.0, green: 0.55, blue: 0.68, alpha: 1)),
        (UIColor(red: 0.04, green: 0.31, blue: 0.39, alpha: 1), UIColor(red: 0.01, green: 0.19, blue: 0.25, alpha: 1), UIColor(red: 0.47, green: 0.90, blue: 1.0, alpha: 1)),
        (UIColor(red: 1.0, green: 0.85, blue: 0.63, alpha: 1), UIColor(red: 0.88, green: 0.54, blue: 0.29, alpha: 1), UIColor(red: 0.77, green: 0.44, blue: 0.20, alpha: 1)),
        (UIColor(red: 0.87, green: 0.93, blue: 0.88, alpha: 1), UIColor(red: 0.56, green: 0.71, blue: 0.61, alpha: 1), UIColor(red: 0.16, green: 0.25, blue: 0.18, alpha: 1)),
        (UIColor(red: 0.04, green: 0.02, blue: 0.13, alpha: 1), UIColor(red: 0.09, green: 0.04, blue: 0.20, alpha: 1), UIColor(red: 0.16, green: 0.83, blue: 0.73, alpha: 1)),
        (UIColor(red: 0.98, green: 0.97, blue: 0.95, alpha: 1), UIColor(red: 0.91, green: 0.89, blue: 0.84, alpha: 1), UIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1)),
        (UIColor(red: 0.86, green: 1.0, blue: 0.96, alpha: 1), UIColor(red: 0.50, green: 0.88, blue: 0.78, alpha: 1), UIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1)),
        (UIColor(red: 1.0, green: 0.85, blue: 0.79, alpha: 1), UIColor(red: 1.0, green: 0.62, blue: 0.54, alpha: 1), UIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1)),
        (UIColor(red: 0.29, green: 0.21, blue: 0.15, alpha: 1), UIColor(red: 0.11, green: 0.08, blue: 0.06, alpha: 1), UIColor(red: 0.94, green: 0.75, blue: 0.43, alpha: 1)),
        (UIColor(red: 0.81, green: 0.91, blue: 1.0, alpha: 1), UIColor(red: 0.96, green: 0.98, blue: 1.0, alpha: 1), UIColor(red: 0.86, green: 0.91, blue: 0.95, alpha: 1)),
        (UIColor(red: 0.03, green: 0.07, blue: 0.13, alpha: 1), UIColor(red: 1.0, green: 0.31, blue: 0.63, alpha: 1), UIColor(red: 0.24, green: 0.71, blue: 1.0, alpha: 1)),
        (UIColor(red: 1.0, green: 0.76, blue: 0.48, alpha: 1), UIColor(red: 0.70, green: 0.31, blue: 0.12, alpha: 1), UIColor(red: 1.0, green: 0.90, blue: 0.70, alpha: 1)),
        (UIColor(red: 1.0, green: 0.42, blue: 0.42, alpha: 1), UIColor(red: 0.36, green: 0.88, blue: 0.70, alpha: 1), UIColor(red: 0.71, green: 0.42, blue: 1.0, alpha: 1)),
        (UIColor(red: 0.02, green: 0.02, blue: 0.02, alpha: 1), UIColor(red: 0.10, green: 0.10, blue: 0.10, alpha: 1), UIColor(red: 1.0, green: 0.94, blue: 0.78, alpha: 1)),
        (UIColor(red: 0.23, green: 0.23, blue: 0.24, alpha: 1), UIColor(red: 0.08, green: 0.09, blue: 0.10, alpha: 1), UIColor(red: 0.55, green: 0.55, blue: 0.57, alpha: 1)),
        (UIColor(red: 0.87, green: 0.91, blue: 0.92, alpha: 1), UIColor(red: 0.73, green: 0.78, blue: 0.80, alpha: 1), UIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1)),
        (UIColor(red: 0.01, green: 0.02, blue: 0.04, alpha: 1), UIColor(red: 0.24, green: 0.27, blue: 0.55, alpha: 1), UIColor(red: 0.85, green: 0.86, blue: 1.0, alpha: 1)),
        (UIColor(red: 0.17, green: 0.04, blue: 0.24, alpha: 1), UIColor(red: 0.35, green: 0.06, blue: 0.42, alpha: 1), UIColor(red: 1.0, green: 0.47, blue: 0.86, alpha: 1)),
        (UIColor(red: 0.13, green: 0.15, blue: 0.17, alpha: 1), UIColor(red: 0.05, green: 0.06, blue: 0.07, alpha: 1), UIColor(red: 0.92, green: 0.92, blue: 0.90, alpha: 1))
    ]

    private static var cache: [Int: UIImage] = [:]
    private static let lock = NSLock()

    static func image(index: Int, size: CGSize) -> UIImage {
        lock.lock()
        if let hit = cache[index] { lock.unlock(); return hit }
        lock.unlock()

        let palette = palettes[index % palettes.count]
        let renderer = UIGraphicsImageRenderer(size: size)
        let img = renderer.image { ctx in
            let c = ctx.cgContext
            let colors = [palette.0.cgColor, palette.1.cgColor, palette.2.cgColor] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.55, 1]) {
                c.drawLinearGradient(g, start: CGPoint(x: 0, y: 0), end: CGPoint(x: size.width * 0.4, y: size.height), options: [])
            }
            var seed = UInt64(index + 3) * 733
            func next() -> CGFloat {
                seed = seed &* 16807 % 2147483647
                return CGFloat(seed % 1000) / 1000.0
            }
            for i in 0..<8 {
                let r = 24 + next() * size.width * 0.28
                let x = next() * size.width
                let y = next() * size.height
                c.setFillColor(UIColor(white: 1, alpha: i % 2 == 0 ? 0.10 : 0.22).cgColor)
                c.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
            }
            c.setFillColor(UIColor(white: 0, alpha: 0.25).cgColor)
            c.fill(CGRect(x: 0, y: size.height * 0.86, width: size.width, height: size.height * 0.14))
        }

        lock.lock()
        cache[index] = img
        lock.unlock()
        return img
    }
}

struct ContentView: View {
    @StateObject private var engine = CameraEngine()
    @State private var captured: UIImage?
    @State private var showSaved = false

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.05, blue: 0.06).ignoresSafeArea()

            VStack(spacing: 14) {
                HStack {
                    Circle().fill(Color(red: 0.16, green: 0.83, blue: 0.73)).frame(width: 7, height: 7)
                    Text("抠像相机").font(.system(size: 13, weight: .medium)).foregroundColor(.white.opacity(0.85))
                    Spacer()
                    Text("实时").font(.system(size: 11)).foregroundColor(.white.opacity(0.45))
                }
                .padding(.horizontal, 4)

                ZStack {
                    RoundedRectangle(cornerRadius: 22).fill(Color.black)
                    if let img = engine.frame {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 22))
                    } else {
                        VStack(spacing: 10) {
                            ProgressView().tint(.white)
                            Text(engine.errorText ?? "正在打开摄像头…")
                                .font(.system(size: 13))
                                .foregroundColor(.white.opacity(0.6))
                        }
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.white.opacity(0.08), lineWidth: 1))

                HStack(spacing: 40) {
                    Button {
                        engine.flip()
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath.camera")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 46, height: 46)
                            .background(Color.white.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }

                    Button {
                        save()
                    } label: {
                        ZStack {
                            Circle().fill(Color.white).frame(width: 76, height: 76)
                            Circle().stroke(Color.black.opacity(0.25), lineWidth: 2).frame(width: 60, height: 60)
                        }
                    }

                    Button {
                        engine.selected = (engine.selected + 1) % Backgrounds.count
                    } label: {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 46, height: 46)
                            .background(Color.white.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("换背景").font(.system(size: 13, weight: .medium)).foregroundColor(.white)
                        Spacer()
                        Text("\(engine.selected + 1) / \(Backgrounds.count)")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.45))
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(0..<Backgrounds.count, id: \.self) { i in
                                Button {
                                    engine.selected = i
                                } label: {
                                    VStack(spacing: 5) {
                                        Image(uiImage: Backgrounds.image(index: i, size: CGSize(width: 152, height: 200)))
                                            .resizable()
                                            .frame(width: 64, height: 84)
                                            .clipShape(RoundedRectangle(cornerRadius: 10))
                                            .overlay(RoundedRectangle(cornerRadius: 10)
                                                .stroke(engine.selected == i ? Color(red: 0.16, green: 0.83, blue: 0.73) : Color.white.opacity(0.12),
                                                        lineWidth: engine.selected == i ? 2 : 1))
                                        Text(Backgrounds.names[i])
                                            .font(.system(size: 10))
                                            .foregroundColor(engine.selected == i ? Color(red: 0.16, green: 0.83, blue: 0.73) : .white.opacity(0.5))
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(12)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 18))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
        .onAppear { engine.start() }
        .alert("已保存", isPresented: $showSaved) {
            Button("好", role: .cancel) {}
        } message: {
            Text("照片已经存进相册了")
        }
    }

    private func save() {
        guard let img = engine.frame else { return }
        UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
        showSaved = true
    }
}
