# ADR-0003：PDF 与 DOCX 导出策略

- 状态：Implemented，待真机和跨软件验收
- 日期：2026-08-24

## PDF

使用统一 HTML 和 Print CSS。WebKit 先生成一个覆盖全文的 PDF，再由 CoreGraphics 切成 A4 页面；Mermaid 在网页端栅格为 PNG，由原生层按文档坐标叠加。图表期望数量与成功解码数量不一致时取消导出。

## DOCX

验证结果：Apple attributed-string OOXML 无法满足结构可控和跨平台一致性要求，因此采用限定范围 Swift OOXML Writer：

1. 标题、列表、表格、脚注、链接和图片使用原生 OOXML 部件；
2. Mermaid 复用网页端 PNG；
3. 数学当前为 Cambria Math 可编辑文本样式，后续只有在跨软件测试证明必要时才实现 OMML；
4. Pandoc 只作为外部测试对照，不是运行时依赖。

不允许因为某个 API 能生成 `.docx` 文件就宣称功能完成。验收要求包括结构检查，以及在 Word for Mac、Word for iOS、Pages 和 LibreOffice 中打开真实文档。

## v1 降级规则

- Mermaid 在 DOCX 中嵌入高分辨率 PNG；数学保留为可编辑公式文本；
- 任意 HTML 无法转换时给出明确诊断；
- 不支持元素不得静默消失；
- 导出失败不影响原 Markdown 文件。
