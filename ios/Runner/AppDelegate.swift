import Flutter
import UIKit
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    registerCameraMetadataChannel(
      engineBridge.applicationRegistrar.messenger()
    )
  }

  private func registerCameraMetadataChannel(_ messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "powerline_measure/camera_metadata",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handleCameraMetadata(call, result: result)
    }
  }

  private func handleCameraMetadata(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    guard call.method == "getCameraMetadata" else {
      result(FlutterMethodNotImplemented)
      return
    }

    let arguments = call.arguments as? [String: Any]
    let requestedName = arguments?["cameraName"] as? String
    let discovery = AVCaptureDevice.DiscoverySession(
      deviceTypes: [
        .builtInWideAngleCamera,
        .builtInUltraWideCamera,
        .builtInTelephotoCamera,
      ],
      mediaType: .video,
      position: .back
    )
    let device = discovery.devices.first(where: {
      requestedName != nil && $0.uniqueID == requestedName
    }) ?? discovery.devices.first(where: {
      requestedName != nil && $0.localizedName == requestedName
    }) ?? discovery.devices.first(where: {
      $0.deviceType == .builtInWideAngleCamera
    }) ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    guard let device else {
      result(nil)
      return
    }

    let format = device.activeFormat
    let baseFov = Double(format.videoFieldOfView)
    let correctedFov = Double(format.geometricDistortionCorrectedVideoFieldOfView)
    let usableBaseFov = baseFov > 0 ? baseFov : 0.0
    let usableCorrectedFov = correctedFov > 0 ? correctedFov : usableBaseFov
    let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
    let formatWidth = Double(dimensions.width)
    let formatHeight = Double(dimensions.height)
    let longSide = formatWidth > formatHeight ? formatWidth : formatHeight
    let shortSide = formatWidth < formatHeight ? formatWidth : formatHeight
    let formatAspect: Double
    if shortSide > 0 {
      formatAspect = longSide / shortSide
    } else {
      formatAspect = 1.0
    }
    let portraitFov: Double
    if usableCorrectedFov > 0 {
      let halfAngle = usableCorrectedFov * Double.pi / 360.0
      let portraitAngle = atan(tan(halfAngle) / formatAspect)
      portraitFov = portraitAngle * 360.0 / Double.pi
    } else {
      portraitFov = 0.0
    }
    var metadata: [String: Any] = [:]
    metadata["cameraName"] = device.uniqueID
    metadata["cameraModel"] = device.localizedName
    metadata["baseFovDegrees"] = usableBaseFov
    metadata["correctedFovDegrees"] = usableCorrectedFov
    metadata["portraitFovDegrees"] = portraitFov
    metadata["zoomFactor"] = device.videoZoomFactor
    metadata["formatWidth"] = dimensions.width
    metadata["formatHeight"] = dimensions.height
    result(metadata)
  }
}
