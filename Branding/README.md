# Mossmark 品牌资源

Mossmark 使用“折页 M”作为主标志：文档轮廓承载简洁的 `M`，右上折页使用克制的薄荷色强调。
主体 M 按视觉重心居中；折页不参与水平居中的基准计算。

- 深青：`#123B43`
- 折页薄荷：`#49D0C7`
- 暖纸白：`#F7F2E8`
- 深色背景：`#0F2A30`
- 深色模式薄荷：`#55DDD3`

`mossmark-logo-color.svg` 是透明背景主标志；`mossmark-logo-on-paper.svg`、
`mossmark-logo-monochrome.svg` 和 `mossmark-logo-dark.svg` 分别用于浅色底、单色和深色场景。
AppIcon PNG 均从这里的 iOS/macOS SVG 母版机械生成，不直接手工修改位图。macOS 使用带系统留白的圆角深青底，iOS 使用满幅深青底；两端的折页 M 使用相同的光学缩放，避免系统裁切后产生明显的视觉重量差。macOS 位图由 iOS 的无损 1024 px 母图按 macOS SVG 的 `72/880/196` 圆角几何裁出透明边缘，避免 SVG 预览器把白色底烘焙进 PNG。

```bash
swift scripts/generate-app-icons.swift Apps/MossmarkiOS/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png Apps/MossmarkMac/Assets.xcassets/AppIcon.appiconset rounded-alpha 123B43 16 32 64 128 256 512 1024
```
