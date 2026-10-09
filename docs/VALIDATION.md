# 当前验证记录

日期：2026-10-09。版本：1.0.0。范围：苔记（Mossmark）源码的自动化测试、无签名构建与资源核查。

## 本轮执行

| 检查 | 结果 | 证据范围 |
| --- | --- | --- |
| 锁定前端依赖安装 | 通过 | `pnpm install --frozen-lockfile` |
| 前端类型检查 | 通过 | `pnpm check` |
| 前端测试 | 62/62 通过 | 7 个测试文件；渲染、语义往返、安全、查找、表格与分页 |
| 前端生产构建 | 通过 | `pnpm build`；离线资源与已提交产物一致 |
| Swift 核心测试 | 40/40 通过 | 编码、资源隔离、图片、统计、大纲和 OOXML |
| macOS 无签名构建 | 通过 | `MossmarkMac`，arm64 macOS，独立构建目录 |
| iOS Simulator 无签名构建 | 通过 | `MossmarkiOS`，generic iOS Simulator，独立构建目录 |
| 项目与依赖许可证 | 通过 | 329 组件 SBOM 和第三方声明重新生成；4 个原文来源有版本及 SHA-256 |
| 许可证生成失败路径 | 通过 | 在临时目录验证原文缺失与校验错误均停止，已有声明和 SBOM 不被替换 |
| 源码预检 | 通过 | `scripts/release-preflight.sh` |
| 本地化与脚本语法 | 通过 | 中英文 strings 的 `plutil -lint`、shell 语法与 Node 语法检查 |
| 源码核查 | 已执行 | 结果与范围见 [源码核查记录](release/public-source-check-2026-10-09.md) |

工具链：Xcode 27.0、Swift 6.4、Node.js 22.15.0、pnpm 11.12.0。

构建包含项目 LICENSE、第三方声明、隐私清单及离线编辑器。

## 验证边界

本记录覆盖自动化测试、构建及资源核查。以下场景仍需人工验收：

- iPhone/iPad 真机中文输入、键盘、选区、撤销、文档库及图片导入；
- 真机 PDF/DOCX 保存与分享，Word 和 Pages 打开／编辑；
- 长文档、多图片／图表和低内存压力、恢复行为；
- VoiceOver、动态字体、旋转、分屏与前后台；
- macOS 正式 Developer ID 签名、公证及外部下载后的安装。

已知功能边界见 [已知限制](KNOWN_LIMITATIONS.md)。

## 演示截图

README 中的演示截图用于展示界面，不作为当前版本的真机验收证据。
