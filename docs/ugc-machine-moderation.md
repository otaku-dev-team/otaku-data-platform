# 机器审核接入位（#240 B2c 最后一项）

> 状态：**接入位已就绪，未接任何服务商**。默认 `provider=none`，线上行为与接入前完全一致。
> 站点选完服务商后，改两个环境变量即可生效，**不用改 Java、不用发版**。
> 相关代码：`backend-java/src/main/java/com/otaku/ugc/moderation/`

## 1. 为什么是「接入位」而不是「集成某家」

机器审核在国内是**站点自己采购、自己签合同**的事（内容合规责任主体是网站，平台只出工具，
见 `product-positioning.md` §A）。平台替站点绑死一家服务商，等于替客户做了采购决定；
更麻烦的是各家签名算法不同，绑死一家之后每次换供应商都要改业务代码、走一次发版。

所以平台侧只定一份**最小的协议**：一个 HTTP 端点，请求三个字段、响应一个字段。
服务商协议不一样，就在中间放一个适配器（几十行），谁写都行——站点 IT、我们、或者服务商自己。

## 2. 协议

### 请求

```http
POST <endpoint>
Content-Type: application/json; charset=utf-8
Authorization: Bearer <token>        # token 为空时不发这个头
```

```json
{ "site_key": "otaku", "scene": "comment", "text": "用户写的正文" }
```

| 字段 | 说明 |
|---|---|
| `site_key` | 站点键。服务商侧要按站点分开计费 / 分开策略时用它 |
| `scene` | `comment`（评论与回复）/ `review`（点评）。两类内容尺度不同，可分开配策略 |
| `text` | **只送正文**。不送用户名、作品名、IP——送出去的字段越少，数据边界越好解释 |

### 响应（2xx）

```json
{ "action": "pass", "reason": "可选，一句话说明" }
```

| `action` | 语义 | 同义写法（顺手认掉） |
|---|---|---|
| `pass` | 通过 | — |
| `review` | 拿不准，转人工 | `pending` |
| `reject` | 明确不合规 | `block` |

`reason` 只在 `reject` 时拼进给用户看的提示（截断到 120 字）。
**不要把服务商的内部错误码、机审分数塞进 `reason`**——那是给运维看的，不是给用户看的。

其余情况一律视为「服务商不可用」：非 2xx、超时、响应不是 JSON、`action` 认不出来。
**认不出来绝不猜成 `pass`**——静默放行会让「协议升级了但适配器没跟」变成一堆没人发现的漏审。

## 3. 判定怎么落到评论状态

| 站点发布策略 | `pass` | `review` | `reject` |
|---|---|---|---|
| `post`（先发后审，默认） | `published` | `pending` | `400 CONTENT_REJECTED` |
| `pre`（先审后发） | `pending` | `pending` | `400 CONTENT_REJECTED` |

三个刻意的口径：

1. **`review` 一定落 `pending`**，不管站点是哪种策略。否则「先发后审」的站点永远没有人工介入的时机，
   机器说「拿不准」等于放行。
2. **`reject` 不落库**。用户改完可以直接重发，平台也不替客户建违规档案——
   真要留证据是站点和服务商之间的事。
3. **编辑也过审核**。评论、点评修改正文都重新送审。否则「先发合规内容过审、再改成违规」
   就是一条现成的绕过路径（和 `pre` 站点编辑后回 `pending` 是同一个理由）。

## 4. 服务商挂了怎么办（`on-error`）

| 值 | 行为 | 适合 |
|---|---|---|
| `pass`（默认） | 放行 | 先发后审的站点。本来就能「先露出来再处置」，让服务商故障变成全站发不出评论，代价明显更大 |
| `review` | 一律转人工 | 严格模式。先发后审的站点也会落 `pending`，等站主看过才出现 |
| `reject` | 一律拒收 | 最严。**服务商一挂等于关掉本站发言**，只在监管要求明确时用 |

三种策略都会打一条 `WARN`（`机器审核不可用 site=... on-error=... cause=...`），
巡检时看这条日志就知道服务商健康度——不需要等用户投诉。

## 5. 配置

`backend-java/src/main/resources/application.yml` → `app.ugc.moderation.machine`：

| 环境变量 | 默认 | 说明 |
|---|---|---|
| `OTAKU_UGC_MACHINE_PROVIDER` | `none` | `none` = 不接入；`http` = 接入。**写错其他值启动即失败**（不允许静默退化成「不审核」） |
| `OTAKU_UGC_MACHINE_ENDPOINT` | 空 | 适配器地址。`provider=http` 时为空 → 启动即失败 |
| `OTAKU_UGC_MACHINE_TOKEN` | 空 | 发 `Authorization: Bearer <token>`，空则不发该头 |
| `OTAKU_UGC_MACHINE_TIMEOUT_MS` | `1500` | 单条送审超时。**这个值就是用户发评论时最多卡多久** |
| `OTAKU_UGC_MACHINE_ON_ERROR` | `pass` | 见上一节 |

## 6. 接一个新服务商：三步

1. **写适配器**（可以和我们同一台机器上跑，也可以站点自己跑）。
   二十年历史的厂商 SDK 都在这一步被消化掉，平台侧看不到。

   ```python
   # 30 行的最小适配器：把厂商协议翻成上面四个字段
   from http.server import BaseHTTPRequestHandler, HTTPServer
   import json, vendor_sdk

   class H(BaseHTTPRequestHandler):
       def do_POST(self):
           req = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
           r = vendor_sdk.check(text=req["text"])          # 换成厂商调用
           action = {"PASS": "pass", "BLOCK": "reject", "REVIEW": "review"}[r.label]
           body = json.dumps({"action": action, "reason": r.message}).encode()
           self.send_response(200)
           self.send_header("Content-Type", "application/json")
           self.send_header("Content-Length", str(len(body)))
           self.end_headers()
           self.wfile.write(body)
   HTTPServer(("127.0.0.1", 8099), H).serve_forever()
   ```

2. **改 `.env` 并重启后端**（只重启 backend，MySQL 不动）：

   ```bash
   OTAKU_UGC_MACHINE_PROVIDER=http
   OTAKU_UGC_MACHINE_ENDPOINT=http://127.0.0.1:8099/moderate
   OTAKU_UGC_MACHINE_TOKEN=...        # 适配器要校验就填
   OTAKU_UGC_MACHINE_ON_ERROR=pass
   ```

3. **冒烟四条**（每条都做完再算接好）：

   | 步骤 | 期望 |
   |---|---|
   | 正常内容发评论 | `201`，`status` 与站点策略一致 |
   | 触发一次 `reject` 关键词 | `400`，`error.code = CONTENT_REJECTED`，公开列表**没有**这条 |
   | 停掉适配器再发 | 按 `on-error` 表现；日志有 `机器审核不可用` |
   | 恢复适配器 | 不再出现 WARN |

## 7. 已知限制（刻意不做的部分）

- **同步调用、不重试**。发评论是用户等待的动作，重试只会让等待翻倍；失败按 `on-error` 兜底，
  比「悄悄重试三次然后仍然失败」对用户更诚实。
- **不做批量、不做图片**。当前只审正文文本；头像、图片、昵称都不在范围内
  （图片审核各家计价方式与文本完全不同，等真有站点要再说）。
- **不做机审结果持久化**。`ugc_comment` 没有「机审分数」列：那个字段一旦存在，
  就会被当成「内容质量分」在别处用起来，而它其实只是某家服务商某一天的判定。
  需要追溯时看服务商后台，平台只留一条 WARN/INFO 日志。
- **不替站点下结论**。「什么样算违规」写进站点与服务商的合同，不写进平台代码。

## 8. 回滚

把 `OTAKU_UGC_MACHINE_PROVIDER` 改回 `none`，重启 backend 即可——代码路径回到「一次布尔判断」，
不需要回滚版本。
