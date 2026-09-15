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

    let cameraMetadataChannel = FlutterMethodChannel(
      name: "powerline_measure/camera_metadata",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
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
      let device = discovery.devices.first(where: {
        requestedName != nil && $0.uniqueID == requestedName
      }) ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
      guard let device else {
        result(nil)
        return
      }

      let format = device.activeFormat
      let baseFov = format.videoFieldOfView
      let correctedFov = format.geometricDistortionCorrectedVideoFieldOfView
      let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
      result([
        "cameraName": device.uniqueID,
        "cameraModel": device.localizedName,
        "baseFovDegrees": baseFov,
        "correctedFovDegrees": correctedFov,
        "zoomFactor": device.videoZoomFactor,
        "formatWidth": dimensions.width,
        "formatHeight": dimensions.height,
      ])
    }
  }
}
