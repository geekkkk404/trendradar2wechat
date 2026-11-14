# 微信 iLink bot 协议实战笔记

> **非官方文档**。本文是 [any2wechat](https://github.com/geekkkk404/any2wechat)（MIT）与
> trendradar2wechat 两个开源项目开发中沉淀的协议知识，来源 = 腾讯官方开源
> [Tencent/openclaw-weixin](https://github.com/Tencent/openclaw-weixin)（MIT）代码阅读 +
> 2026-11 生产环境实测（腾讯云 VPS + 个人微信 bot）。腾讯随时可能变更接口，本文不承诺时效。
> 英文版：[ilink-protocol-notes.en.md](ilink-protocol-notes.en.md)

**适合谁读**：想在微信里给个人号做一个 bot（扫码授权后，bot 能把消息发进读者的个人微信）的开发者。
常见检索场景：微信个人号消息推送、微信 bot 主动发送失败 `ret=-2`、iLink `context_token` 过期、
`ilinkai.weixin.qq.com` 接口、`ret=0` 但对方收不到消息。

## 1. 端点与请求头

- Base：`https://ilinkai.weixin.qq.com`，全部 JSON POST
- 鉴权头：`AuthorizationType: ilink_bot_token` + `Authorization: Bearer <bot_token>`
- `X-WECHAT-UIN`：base64(随机 uint32 字符串)
- `iLink-App-Id: bot`；`iLink-App-ClientVersion: "132104"`（对应官方 2.4.8，2026-11 观测值）
- 发送类请求的 `base_info` 携带 `channel_version: "2.4.8"` 与 `bot_agent`

## 2. 登录授权（QR 状态机）

1. `ilink/bot/get_bot_qrcode?bot_type=3`（body `{"local_token_list":[]}`）→ `{qrcode, qrcode_img_content}`；
   授权链接在 `liteapp.weixin.qq.com` 域，手机微信内打开即确认
2. 长轮询 `ilink/bot/get_qrcode_status?qrcode=...`（约 35s 一轮）状态机：
   `wait` → `scaned` →（可选 `need_verifycode`）→ `confirmed`；另有 `expired`，以及两个易踩的跳转分支
   `scaned_but_redirect` / `binded_redirect`（同一微信号已授权过 bot 时出现）
3. `confirmed` 返回 `bot_token` + `ilink_bot_id` + `ilink_user_id`（**扫码者 = 推送目标**）+
   可选 `baseurl`（IDC 重定向，需跟随）

## 3. 发送 `ilink/bot/sendmessage`

```json
{
  "msg": {
    "from_user_id": "",
    "to_user_id": "…",
    "client_id": "…",
    "message_type": 2,
    "message_state": 2,
    "item_list": [{ "type": 1, "text_item": { "text": "…" } }],
    "context_token": "…"
  },
  "base_info": { "channel_version": "2.4.8", "bot_agent": "…" }
}
```

`ret !== 0` 即失败。`item_list` 条目类型枚举含 IMAGE / VIDEO / FILE / VOICE；
图片路径 = `uploadFileToWeixin` CDN 上传（getuploadurl → 内容 AES-128-ECB 加密 → POST 带
`x-encrypted-param`）→ sendmessage `image_item`。

发送侧长度实测：单条 ~4.6k 字符文本服务端无压力（更长的内容做客户端分批是保守工程选择）。

## 4. 接收 `ilink/bot/getupdates`

body `{get_updates_buf, base_info}` → `resp.msgs[]`（每条带 `from_user_id` / `context_token`）+
`resp.get_updates_buf` 新游标。`ret/errcode === -14` = 会话被暂停（实测约 1 小时后恢复），需退避处理。

## 5. context_token：整个协议的钥匙

- 发送必须**原样回传一条从下行消息带来的** `context_token`（openclaw-weixin vendor 源码注释原文
  *"must be echoed verbatim"*）；它随每条下行消息（getupdates 的 `resp.msgs[]`）下发
- 没有用户消息 = 没有新鲜 token = 无法发送：**协议里不存在「纯主动发送的喇叭」形态**；
  无有效 token 发送 → `ret=-2 prepare failed`
- **实测 TTL 约 30 分钟**（证据：16 分钟龄发送成功 / 31 分钟龄边界失败 / 32 分钟龄全败）
- **架构结论**：定时推送在这个协议上是结构性不可靠的（推送间隔 > TTL 必败，用户不发消息就没有续约）。
  稳态形态是**拉取模式**——用户发消息触发抓取推送，消息自带新鲜 token，推送必达；
  混合形态则要设计极短间隔的续约轮询并接受不确定性

## 6. 风控与静默吞包（最危险的失败形态）

- **`ret=0` 但响应中没有服务端 `message_id` = 假成功**（真受理会回 message_id）——消息被服务端
  静默吞掉，对端收不到，而你的日志全绿
- 社区已知高发，openclaw-weixin issues：
  [#305](https://github.com/Tencent/openclaw-weixin/issues/305)、
  [#280](https://github.com/Tencent/openclaw-weixin/issues/280)、
  [#264](https://github.com/Tencent/openclaw-weixin/issues/264)、
  [#268](https://github.com/Tencent/openclaw-weixin/issues/268)、
  [#310](https://github.com/Tencent/openclaw-weixin/issues/310)、
  [#358](https://github.com/Tencent/openclaw-weixin/issues/358)、
  [#290](https://github.com/Tencent/openclaw-weixin/issues/290)
- 触发源实测：短时间高频发送（我们新会话 4 小时内 40+ 条、含图片与长文后触发）
- **常规自救（重扫/换 bot/重装）社区经验常无效，疑似跟随微信账号**；
  我们实测有效的路径 = 重装重扫 + 冷却（约 11 小时后上行恢复）
- 测试守则：新会话首小时 ≤5 条、图片慎发、验收用单条真实消息

## 7. 绑定语义与 owner 守卫

- 绑定 = 收到第一条带 `from_user_id` + `context_token` 的下行消息即成（**last-message-wins**：
  任何能给 bot 发消息者都会覆盖推送目标）
- 个人 bot 会话仅存在于扫码者微信（实测：两台手机各自扫码 = 改绑，非并行接收），实际风险低；
  但群聊/被他人添加等能力未穷尽——生产实现建议保留 owner 校验
  （比对凭证文件里的 `user_id` 与会话 `to_user_id`）

## 8. 启动与保活

- 启动时调用 `ilink/bot/msg/notifystart`（body 仅 `base_info`；官方 channel 启动即调，`ret=0`）
- listen 常驻长轮询本身即保活（持续拿新游标与新 context_token）

---

**免责**：本文与腾讯公司无任何关联，亦未获其背书；"微信 / WeChat" 为腾讯商标，仅作描述用途。
iLink 为较新接口，腾讯可能调整，不承诺永久可用。实现参考：[any2wechat](https://github.com/geekkkk404/any2wechat)（MIT）。
