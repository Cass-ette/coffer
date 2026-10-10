# Coffer macOS fork

来源：https://github.com/horizontalsystems/TronKit.swift，版本 1.5.2（MIT；见 LICENSE）。

TronKit 的 Package.swift 增加 `.macOS(.v10_15)` 平台。

HsToolKit.Swift 固化在 `Vendor/HsToolKit.Swift`，TronKit 改为本地路径依赖；HsToolKit 的 Package.swift 同样增加 `.macOS(.v10_15)`。

HsToolKit 的 `BackgroundModeObserver` 类及 WebSocket 对它的订阅用 `#if canImport(UIKit)` 保护；macOS 不使用 iOS 的后台任务 API。

其余 TronKit 加密、派生、签名代码保持上游实现。Coffer 仅调用公开 API。

黄金冒烟用例：`abandon` × 11 + `about`，路径 `m/44'/195'/0'/0/0`，派生地址 `TUEZSdKsoDHQMeZwihtdoBiN46zxhGWYdH`。自动回归见 `CofferCore/Tests/CofferCoreTests/TronWalletServiceTests.swift`。
