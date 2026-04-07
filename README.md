# WS-Proxy

Native iOS app shell for a local Telegram MTProto proxy.

## Current scope

- SwiftUI app shell
- persisted proxy settings
- `tg://proxy` link generation
- CI workflow that builds and publishes an `.ipa` artifact

## Project layout

- `Sources/WSProxyApp` - iOS app sources
- `Tests/WSProxyAppTests` - unit tests
- `.github/workflows/ios-release.yml` - GitHub Actions build

## Build flow

The repository is designed to be built on GitHub Actions without a local Xcode install.

CI uses XcodeGen to generate the Xcode project and then runs `xcodebuild` on a macOS runner.

The current workflow packages an `.ipa` artifact from the built app bundle.

## Notes

- The proxy runtime is scaffolded in Swift and ready to be replaced with the MTProto bridge implementation.
- `tg-ws-proxy-main/` is ignored and treated only as a reference source tree.
