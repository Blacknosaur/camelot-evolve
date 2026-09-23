# Camelot Camera (Android)

Companion app: turns an Android phone into a second camera for a multi-cam session hosted by the
iOS app. It discovers the host over Bonjour (`_camelot-sock._tcp`, NSD), connects over TCP, keeps
an NTP-style clock offset, streams a 720p H.264 feed from a MediaCodec input surface, records a
1080p file locally with MediaRecorder when the camera can run three streams, and pushes that file
to the host in chunks after the host stops the take. Wire format is shared with the iOS peers
(`clients/ios/Camelot/MultiCamProtocol.swift`): a 4-byte length prefix per frame, then a tag byte
(1 control JSON, 2 video packet, 3 file chunk).

Build and install (JDK 17, Android SDK with platform 35):

```bash
./gradlew :app:installDebug
```

The activity is locked to landscape so the encoder's sensor-oriented frames are upright.
