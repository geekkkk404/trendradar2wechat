# WeChat iLink Bot Protocol — Field Notes

> **Unofficial documentation.** This is protocol knowledge accumulated while building
> [any2wechat](https://github.com/geekkkk404/any2wechat) (MIT) and trendradar2wechat.
> Sources: reading Tencent's official open-source
> [Tencent/openclaw-weixin](https://github.com/Tencent/openclaw-weixin) (MIT), plus production
> testing (Tencent Cloud VPS + personal WeChat bot, observed 2026-11). Tencent may change the
> interface at any time; no timeliness guarantee. 中文版：[ilink-protocol-notes.md](ilink-protocol-notes.md)

**Who this is for**: developers who want a bot inside WeChat that can deliver messages to a
reader's personal WeChat after a QR-scan authorization. Common search scenarios: personal WeChat
message push, bot主动发送失败 `ret=-2` / outbound send fails with `ret=-2`, iLink `context_token`
expiration, `ilinkai.weixin.qq.com` API, `ret=0` but the recipient never gets the message.

## 1. Endpoints & headers

- Base: `https://ilinkai.weixin.qq.com`, everything is JSON POST
- Auth headers: `AuthorizationType: ilink_bot_token` + `Authorization: Bearer <bot_token>`
- `X-WECHAT-UIN`: base64 of a random uint32 string
- `iLink-App-Id: bot`; `iLink-App-ClientVersion: "132104"` (maps to official 2.4.8, observed 2026-11)
- Send-type requests carry `base_info` with `channel_version: "2.4.8"` and `bot_agent`

## 2. Login / authorization (QR state machine)

1. `ilink/bot/get_bot_qrcode?bot_type=3` (body `{"local_token_list":[]}`) → `{qrcode, qrcode_img_content}`;
   the authorization link lives on the `liteapp.weixin.qq.com` domain — opened inside mobile WeChat, the user confirms there
2. Long-poll `ilink/bot/get_qrcode_status?qrcode=...` (~35s per round) state machine:
   `wait` → `scaned` → (optional `need_verifycode`) → `confirmed`; plus `expired`, and two
   redirect branches that are easy to trip: `scaned_but_redirect` / `binded_redirect`
   (appear when the same WeChat account has already authorized a bot)
3. `confirmed` returns `bot_token` + `ilink_bot_id` + `ilink_user_id`
   (**the scanner = the push target**) + optional `baseurl` (IDC redirect; follow it)

## 3. Sending: `ilink/bot/sendmessage`

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

`ret !== 0` means failure. Item types include IMAGE / VIDEO / FILE / VOICE; the image path is a CDN
upload via `uploadFileToWeixin` (getuploadurl → AES-128-ECB encrypt the payload → POST with
`x-encrypted-param`) → sendmessage `image_item`.

Measured: a single ~4.6k-character text sends fine server-side (client-side batching at 1.8k is a
conservative engineering choice).

## 4. Receiving: `ilink/bot/getupdates`

Body `{get_updates_buf, base_info}` → `resp.msgs[]` (each carries `from_user_id` /
`context_token`) + a new `resp.get_updates_buf` cursor. `ret/errcode === -14` means the session is
suspended (observed to recover after ~1 hour); back off and retry.

## 5. context_token: the key to the whole protocol

- Every send must **echo back verbatim** a `context_token` that arrived with a downstream message
  (the vendor source comments *"must be echoed verbatim"*); it is delivered with each inbound
  message in getupdates' `resp.msgs[]`
- No user message = no fresh token = no send: **the protocol has no "pure outbound transmitter"
  mode**; sending with a missing/expired token → `ret=-2 prepare failed`
- **Measured TTL: roughly 30 minutes** (evidence: sent at 16-min token age OK / 31-min age failed
  at the boundary / 32-min age failed consistently)
- **Architectural conclusion**: scheduled pushes are structurally unreliable on this protocol
  (interval > TTL always fails, and there is no renewal without a user message). The stable shape
  is **pull mode** — the user messages the bot, the message carries a fresh token, the reply always
  arrives. Hybrid designs need very short renewal polling and must accept uncertainty

## 6. Risk control & silent message swallowing (the most dangerous failure mode)

- **`ret=0` with no server-side `message_id` in the response = fake success** (a real accept
  returns a message ID) — the message is silently swallowed server-side while your logs stay green
- A known, frequently-reported community issue; see openclaw-weixin issues
  [#305](https://github.com/Tencent/openclaw-weixin/issues/305),
  [#280](https://github.com/Tencent/openclaw-weixin/issues/280),
  [#264](https://github.com/Tencent/openclaw-weixin/issues/264),
  [#268](https://github.com/Tencent/openclaw-weixin/issues/268),
  [#310](https://github.com/Tencent/openclaw-weixin/issues/310),
  [#358](https://github.com/Tencent/openclaw-weixin/issues/358),
  [#290](https://github.com/Tencent/openclaw-weixin/issues/290)
- Measured trigger: high-frequency sending in a short window (we tripped it with 40+ messages
  including images and long texts within 4 hours on a fresh session)
- **Common self-rescue (re-scan / new bot / reinstall) usually does NOT work per community
  experience; it appears to follow the WeChat account.** The path that worked for us:
  reinstall + re-scan + cooldown (outbound recovered after ~11 hours)
- Testing discipline: ≤5 messages in the first hour of a fresh session, go easy on images,
  validate with single real messages

## 7. Binding semantics & owner guard

- Binding happens on the first inbound message carrying `from_user_id` + `context_token`
  (**last-message-wins**: anyone who can message the bot overwrites the push target)
- A personal bot conversation exists only inside the scanner's WeChat (measured: scanning from a
  second phone = rebind, not parallel delivery), so real-world risk is low; group-chat /
  being-added-by-others capabilities are not exhaustively mapped — production implementations
  should keep an owner check (compare the credential file's `user_id` with the session's
  `to_user_id`)

## 8. Startup & keep-alive

- Call `ilink/bot/msg/notifystart` on startup (body carries only `base_info`; the official channel
  does this on start; `ret=0`)
- A resident long-poll listen loop is itself the keep-alive (continuously yields a fresh cursor and
  fresh context_tokens)

---

**Disclaimer**: unaffiliated with Tencent, not endorsed by it; "微信 / WeChat" is a Tencent
trademark, used descriptively only. iLink is a fairly new interface that Tencent may change; no
permanence guarantee. Reference implementation: [any2wechat](https://github.com/geekkkk404/any2wechat) (MIT).
