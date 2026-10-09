# ADR-0001：Swift 原生外壳与本地 Web 编辑内核

- 状态：Implemented，真机 IME 待验收
- 日期：2026-08-24

## 背景

产品需要同时提供 macOS/iOS 的原生文件体验和接近 Typora 的 WYSIWYM 编辑。纯 TextKit 实现完整 Markdown 富编辑需要自行解决解析、选区、表格、嵌套结构、IME 和序列化；Electron 不能自然覆盖 iOS。

## 决策

- SwiftUI 作为双端 UI 主框架，必要处使用 AppKit/UIKit；
- macOS 用 `DocumentGroup` 管理系统文档生命周期；iOS/iPadOS 用 App 内文档库与 `OpenedDocumentStore` 管理副本、延迟保存及退出／后台时的写入；
- WKWebView 只加载 App 内本地资源；
- Milkdown/ProseMirror 作为 WYSIWYM 编辑器；
- CodeMirror 6 作为源码模式；
- Swift 与 JavaScript 之间使用有版本号的消息协议；
- npm 依赖以精确版本和 `pnpm-lock.yaml` 固定。

## 后果

优点：

- 双端共享编辑行为和渲染样式；
- 原生文件、菜单、键盘、分享和打印；
- 可复用成熟编辑组件。

代价：

- 必须维护 Swift/JavaScript 桥；
- iOS contenteditable/IME 只能通过真机证明；
- Web 序列化不能直接视为无损。

## 否决方案

- 纯 TextKit：首版成本过高；
- Electron/Tauri 单体：无法合理覆盖 iOS；
- 只做源码加分栏预览：不满足 Typora 式核心体验。
