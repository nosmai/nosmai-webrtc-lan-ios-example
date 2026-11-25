# Nosmai Effects with WebRTC over a local network on iOS

Two iPhones discover each other on the same Wi-Fi using MultipeerConnectivity. WebRTC carries the host’s filtered video and microphone audio. The example handles discovery and signaling without a separate signaling service.

## Requirements

- Xcode, CocoaPods and two physical iOS devices running iOS 15 or later.
- A Nosmai Effects licence for the broadcaster’s bundle identifier. The Xcode project uses `com.nosmai.quickstart.webrtc`.
- The Podfile pins `NosmaiCameraSDK 3.0.7` and `WebRTC-SDK 144.7559.09`.

## Set up the project

From the repository root, create the local configuration and install the dependencies.

```sh
cp Configuration/Example.plist Configuration/Local.plist
pod install
open NosmaiWebRTCDemo.xcworkspace
```

In Xcode, select your signing team for the app target. If you change the bundle identifier, use the same identifier when registering the Nosmai licence. Set these fields in `Configuration/Local.plist`, which Git ignores.

- `nosmaiAPIKey` — App-bound Nosmai Effects licence for the broadcasting device. A viewer can leave this field empty.
- `roomName` — A shared room name for local peer discovery.

Connect both devices to the same Wi-Fi network and allow Local Network access. Use a network that allows communication between clients. Use this discovery flow on a trusted local network.

## Broadcast and watch

1. On the first phone, select **Go Live (Host)** and allow camera and microphone access.
2. On the second phone, select **Watch (Audience)** and join the same room.
3. Open the host’s effects controls and apply a visible effect. Check the result on the viewer.
4. Leave the broadcast from the live screen to release the camera and session resources.

## Add Nosmai to an existing app

Keep your signaling and ICE configuration in an existing WebRTC app. Create the outgoing video track with an `RTCVideoSource` and feed Nosmai buffers to its capturer. Add the track to your peer connection and render the remote track with `RTCMTLVideoView`. In this example, `LocalSignaling.swift` exchanges SDP and ICE messages over the local network.

- [LiveViewController.swift](NosmaiWebRTCDemo/LiveViewController.swift) shows capture, publication, remote playback and teardown.
- [EffectsPanelView.swift](NosmaiWebRTCDemo/EffectsPanelView.swift) applies beauty controls, Cloud Filters and AR effects on the broadcaster.
- [LocalSignaling.swift](NosmaiWebRTCDemo/LocalSignaling.swift) handles peer discovery, offers, answers and ICE candidates.

## References

- [Nosmai iOS quickstart](https://nosmai.com/docs/effects/quickstart/ios/)
- [Register a Nosmai licence](https://nosmai.com/docs/effects/license-key/)
- [WebRTC iOS example with a browser viewer](https://github.com/nosmai/nosmai-webrtc-ios-example)
