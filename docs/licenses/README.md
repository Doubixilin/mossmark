# 第三方许可证来源

`THIRD_PARTY_NOTICES.md` 和 `docs/release/runtime-sbom.json` 由已安装的运行时依赖生成。先执行 `pnpm install --frozen-lockfile` 与 `swift package resolve`，再运行 `node scripts/generate-runtime-legal.mjs`。

生成器优先读取安装包内的 LICENSE、COPYING、NOTICE 原文。以下四个固定版本没有单独打包许可证文件，原文保存在 `upstream/`：

| 组件 | 原文位置 |
| --- | --- |
| fastdom 1.0.12 | npm 发布包的 README License 小节，包 SHA-512 与锁文件匹配 |
| strictdom 1.0.1 | 对应发布提交的 README License 小节 |
| punycode.js 2.3.1 | 对应版本标签的 LICENSE-MIT.txt |
| remark-math 6.0.0 | 对应发布提交的仓库根 license |

`upstream/manifest.json` 记录版本、来源 URL 和文件 SHA-256；fastdom 还记录发布包完整性摘要，其他来源固定到版本提交。生成器只接受版本匹配且校验通过的原文；缺少原文或校验不符时停止，不根据 npm author 字段编造版权声明。更新这些依赖时需要重新核对对应版本的上游授权文本。

ZIPFoundation 的版本和提交来自 `Package.resolved`，生成前同时校验本机 checkout 的提交。所有依赖继续按各自许可证授权，项目根 MIT 许可证不替代第三方授权。
