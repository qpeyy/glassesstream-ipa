# GlassesStream

Streams the live camera feed from paired Ray-Ban Meta glasses as an MJPEG stream over HTTP.

## Usage

1. Pair your Ray-Ban Meta glasses via Bluetooth before launching the app.
2. Open the app — it shows the phone's WiFi IP on screen.
3. On any device on the same WiFi, open `http://<phone-ip>:8080/stream` in a browser or VLC.

## Build

The GitHub Actions workflow (`.github/workflows/build-ipa.yml`) builds an unsigned `.ipa` on a macOS runner automatically on every push to `main`.

Download the artifact from the Actions run, then sideload with **AltServer** (it will re-sign with your Apple ID).

## Requirements

- iOS 16.0+, iPhone only
- Ray-Ban Meta glasses with the Meta Wearables Device Access Toolkit SDK
