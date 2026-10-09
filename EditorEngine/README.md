# EditorEngine

随 macOS/iOS App 离线打包的 WKWebView 编辑内核。

- Milkdown/ProseMirror：即时编辑；
- CodeMirror 6：源码模式；
- Markdown-It：安全预览和导出 DOM；
- KaTeX：数学公式；
- Mermaid：图表预览及导出前 PNG 栅格化；
- TypeScript bridge：与 Swift 原生层交换版本化消息。

```bash
pnpm install --frozen-lockfile
pnpm check
pnpm test
pnpm build
```

生产文件输出到 `dist/`，由 Xcode 作为 folder resource 打包。运行时 CSP 禁止网络连接；本地资源由原生自定义 scheme 和文档目录隔离规则提供。若 Milkdown 无法保证源 Markdown 语义往返，控制器会切换到 CodeMirror，而不是保存被静默规范化的内容。
