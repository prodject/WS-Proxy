# WS-Proxy

Native iOS app shell for a local Telegram MTProto proxy.

## Current scope

- SwiftUI app shell
- persisted proxy settings
- `tg://proxy` link generation
- local proxy listener scaffold on `Network.framework`
- in-app log viewer
- MTProto handshake parsing and bridge scaffolding
- outbound WebSocket client and packet splitter layers
- CI workflow that builds and publishes an `.ipa` artifact
- release build script for GitHub Actions and local macOS runners

## Project layout

- `Sources/WSProxyApp` - iOS app sources
- `Tests/WSProxyAppTests` - unit tests
- `Scripts/build_ios_ipa.sh` - reproducible IPA build and packaging script
- `.github/workflows/ios-release.yml` - GitHub Actions build

## Build flow

The repository is designed to be built on GitHub Actions without a local Xcode install.

CI uses XcodeGen to generate the Xcode project and then runs a single reproducible shell script on a macOS runner.

Tag pushes like `v0.2.0` produce versioned artifacts such as `WSProxy-0.2.0+42.ipa`.
Non-tag builds keep a dev-style version string.

## Notes

- The proxy runtime is scaffolded in Swift and ready to be replaced with the MTProto bridge implementation.
- `tg-ws-proxy-main/` is ignored and treated only as a reference source tree.
