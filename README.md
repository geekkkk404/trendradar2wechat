# trendradar2wechat

> 买台 VPS，一条命令，[TrendRadar](https://github.com/sansan0/TrendRadar) 热点日报直达你的个人微信。

面向零基础读者的一键安装脚本：境内外 VPS 自适应、幂等可重跑、内置微信个人号推送桥
（[any2wechat](https://github.com/geekkkk404/any2wechat)，MIT）。

## 快速开始

在 SSH / 腾讯云 OrcaTerm 终端中执行（跟着提示扫码授权、微信里发一句「绑定」即可）：

```bash
curl -fsSL --retry 3 https://geekkkk.com/trendradar.sh -o install.sh && bash install.sh --wechat-bridge --no-web
```

- `--wechat-bridge`：内置微信个人号推送桥（推荐；安装过程中出授权链接，手机微信确认）
- `--no-web`：不开放任何入站端口（最安全形态；热点推送不依赖网页）
- 全部选项：`bash install.sh --help`

要求：Ubuntu 20.04+ / Debian 11+（x86_64 / arm64），1GB 内存起。
TrendRadar 与推送桥由脚本在安装时从各自官方仓库获取/构建，本仓库只分发安装脚本与文档。

## 免责声明

- any2wechat 是独立开源项目，与腾讯公司无任何关联，亦未获其背书或赞助；
  "微信 / WeChat" 为腾讯商标，此处仅作描述消息去向之用途。
- 本项目与 TrendRadar 官方无关联：TrendRadar 为 GPL-3.0 开源项目
  （[sansan0/TrendRadar](https://github.com/sansan0/TrendRadar)），脚本在安装时从其
  官方仓库获取原版代码并按官方文档化配置项对接，不修改其源码。
- iLink 为较新接口，腾讯可能调整；不承诺永久可用。

## License

[MIT](LICENSE)（仅限本仓库的安装脚本与文档；TrendRadar / any2wechat 各自遵循其自身许可证）
