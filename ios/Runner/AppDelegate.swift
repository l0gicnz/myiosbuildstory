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

    let binaryMessenger = engineBridge.applicationRegistrar.messenger()
    let cameraMetadataChannel = FlutterMethodChannel(
      name: "powerline_measure/camera_metadata",
      binaryMessenger: binaryMessenger
    )
    cameraMetadataChannel.setMethodCallHandler { call, result in
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
      // camera's Flutter description name is not guaranteed to be the
      // AVCaptureDevice uniqueID on every iOS release. Prefer an exact match,
      // then match the human-readable name, and finally use the wide camera.
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
      let baseFov = format.videoFieldOfView
      let correctedFov = format.geometricDistortionCorrectedVideoFieldOfView
      // Some newer formats report zero for the corrected value. The base FOV
      // remains usable for scale estimation in that case.
      let usableBaseFov = baseFov > 0 ? baseFov : 0.0
      let usableCorrectedFov = correctedFov > 0 ? correctedFov : usableBaseFov
      let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
      let longSide = Double(max(dimensions.width, dimensions.height))
      let shortSide = Double(min(dimensions.width, dimensions.height))
      let formatAspect = shortSide > 0 ? longSide / shortSide : 1.0
      let portraitFov = usableCorrectedFov > 0
        ? 2.0 * atan(
            tan((usableCorrectedFov * Double.pi / 180.0) / 2.0) / formatAspect
          ) * 180.0 / Double.pi
        : 0.0
      result([
        "cameraName": device.uniqueID,
        "cameraModel": device.localizedName,
        "baseFovDegrees": usableBaseFov,
        "correctedFovDegrees": usableCorrectedFov,
        "portraitFovDegrees": portraitFov,
        "zoomFactor": device.videoZoomFactor,
        "formatWidth": dimensions.width,
        "formatHeight": dimensions.height,
      ])
    }
  }
}
