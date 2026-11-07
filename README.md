# trendradar2wechat

> 买台 VPS，一条命令，[TrendRadar](https://github.com/sansan0/TrendRadar) 热点日报直达你的个人微信。

面向零基础读者的一键安装脚本：**无 Docker 原生部署**（Python/uv + systemd 定时 + Node 原生桥，
全新 VPS 约 2 分钟装完）、境内外 VPS 自适应、幂等可重跑、内置微信个人号推送桥
（[any2wechat](https://github.com/geekkkk404/any2wechat)，MIT）。

## 快速开始

在 SSH / 腾讯云 OrcaTerm 终端中执行（跟着提示扫码授权、微信里给 bot 发任意一条消息完成绑定即可）：

```bash
curl -fsSL --retry 3 https://geekkkk.com/trendradar.sh -o install.sh && bash install.sh --wechat-bridge --no-web
```

- `--wechat-bridge`：内置微信个人号推送桥（推荐；安装过程中出授权链接，手机微信确认）
- `--no-web`：不开放任何入站端口（最安全形态；热点推送不依赖网页）
- 全部选项：`bash install.sh --help`

部署后，微信里给 bot 发「帮助」即可对话式管理（暂停/恢复/改配置）；个性化配置推荐用
可视化配置页 **[geekkkk.com/trcfg](https://geekkkk.com/trcfg/)**——内置四套人群模板
（装机默认「全网热点」，另有极客开发/商业财经/硬新闻脱水）一键起步，也可自由勾选生成配置码，粘贴给 bot 即生效。

要求：Ubuntu 20.04+ / Debian 11+（x86_64 / arm64），1GB 内存起，**无需 Docker**
（Python ≥3.12 由脚本自动准备，Ubuntu 24.04 自带）。
TrendRadar 与推送桥由脚本在安装时从各自官方仓库获取并原生部署，本仓库只分发安装脚本与文档。

## 配置与自定义

部署后的个性化（关注关键词、推送分组、信息源取舍）见 **[配置指南](docs/config-guide.md)**。
读者配置外置于安装目录 `user-config/`（与上游源码隔离），升级 / 重跑安装脚本**永不覆盖**。

## 免责声明

- any2wechat 是独立开源项目，与腾讯公司无任何关联，亦未获其背书或赞助；
  "微信 / WeChat" 为腾讯商标，此处仅作描述消息去向之用途。
- 本项目与 TrendRadar 官方无关联：TrendRadar 为 GPL-3.0 开源项目
  （[sansan0/TrendRadar](https://github.com/sansan0/TrendRadar)），脚本在安装时从其
  官方仓库获取原版代码并按官方文档化配置项对接，不修改其源码。
- iLink 为较新接口，腾讯可能调整；不承诺永久可用。

## License

[MIT](LICENSE)（仅限本仓库的安装脚本与文档；TrendRadar / any2wechat 各自遵循其自身许可证）
