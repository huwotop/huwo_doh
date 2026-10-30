# huwo-doh

基于 Cloudflare Workers 的 DNS over HTTPS(DoH)私有反代。对外只暴露一条随机长路径,把请求转发到 `cloudflare-dns.com/dns-query`,并在边缘做 DNS-TTL 级别的缓存。

- 路径与令牌全部通过 Worker 变量配置,**不写死在代码里**,可随时更换而不改代码。
- 支持 RFC 8484 的 `GET ?dns=`、`POST`(wireformat)以及 `GET ?name=`(JSON)三种查询。
- 缓存 TTL 严格取自 DNS 记录的 TTL,不会因 CDN 规则把旧记录缓存数小时。
- 未配置路径时直接返回 500,不会退化成公开 DoH 端点。

---

## 目录结构

```
.
├── src/worker.js         # Worker 入口:鉴权 + 转发 + 缓存
├── wrangler.jsonc        # Worker 名称、入口、可观测性配置
├── package.json          # wrangler 依赖与 dev/deploy 脚本
├── .dev.vars.example     # 本地变量模板(复制为 .dev.vars)
├── .gitignore
├── AGENTS.md             # Workers 开发提示(可删除)
└── README.md
```

## 环境变量

| 变量 | 必填 | 说明 |
| --- | --- | --- |
| `DOH_PATH` | 是 | 对外暴露的私有路径,必须以 `/` 开头,例如 `/doh-9ba32d203ced8136869c2a13`。路径不匹配一律 404。 |
| `DOH_TOKEN` | 否 | 访问令牌。设置后客户端必须携带 `Authorization: Bearer <token>` 或 `?token=<token>`,否则 401。留空则仅靠路径鉴权。 |

生成随机值:

```bash
echo "/doh-$(openssl rand -hex 12)"   # DOH_PATH
openssl rand -hex 24                  # DOH_TOKEN(可选)
```

> `DOH_TOKEN` 若出现在 query string 中,会被剥离后再转发,也不会进入缓存 key。

---

## 本地开发

```bash
npm install
cp .dev.vars.example .dev.vars   # 填入自己的 DOH_PATH / DOH_TOKEN
npm run dev                      # 默认 http://localhost:8787
```

验证:

```bash
curl "http://localhost:8787/doh-你的路径?name=example.com&type=A" \
  -H "accept: application/dns-json"
```

`.dev.vars` 已被 `.gitignore` 忽略,不要提交。

---

## 部署方式一:连接 GitHub 自动部署(推荐)

仓库推送后,Cloudflare 会在每次 push 到生产分支时自动构建并部署。

### 1. 推送代码到 GitHub

```bash
git add .
git commit -m "feat: env-driven DoH worker"
git push origin main
```

### 2. 在 Cloudflare 创建 Worker 并连接仓库

1. 打开控制台 **Workers & Pages** → **Create application** → **GitHub**。
2. 授权并选择本仓库。
3. 项目名 / Worker 名称填写 **`huwo-doh`**。
   > 必须与 `wrangler.jsonc` 里的 `name` 完全一致,否则构建会失败。
4. 构建配置:
   - Build command: 留空(自动执行 `npm install`)
   - Deploy command: `npx wrangler deploy`
   - 生产分支: `main`
5. **Save and Deploy**。

### 3. 设置变量(关键)

进入该 Worker → **Settings** → **Variables and Secrets**:

| 名称 | 类型 | 值 |
| --- | --- | --- |
| `DOH_PATH` | Secret(加密) | `/doh-你的随机路径` |
| `DOH_TOKEN` | Secret(加密,可选) | 你的令牌 |

保存后 **重新部署一次**(Deployments → 对最新版本点 Retry,或再 push 一个提交),让新变量生效。

> `wrangler.jsonc` 中的 `keep_vars: true` 必须保留,否则每次自动部署都会清空控制台上设置的变量。

### 4. 已有 Worker 想接仓库

Worker 页面 → **Settings** → **Builds** → **Connect**,选择仓库并填入上面的构建配置即可。

---

## 部署方式二:本地 wrangler 部署

```bash
npm install
npx wrangler login

# 变量写成加密 Secret(推荐)
npx wrangler secret put DOH_PATH     # 输入 /doh-xxxx
npx wrangler secret put DOH_TOKEN    # 可选

npm run deploy
```

`npm run deploy` 等价于 `npx wrangler deploy`。首次部署后即可用
`https://huwo-doh.<你的子域>.workers.dev/<DOH_PATH>` 访问。

> 如果用 `npx wrangler secret put`,变量已是加密状态,不需要再在控制台重复设置。

---

## 客户端配置

假设 Worker 地址为 `https://huwo-doh.example.workers.dev`,`DOH_PATH=/doh-abc123`。

**JSON 查询(A记录)**

```bash
curl "https://huwo-doh.example.workers.dev/doh-abc123?name=example.com&type=A" \
  -H "accept: application/dns-json"
```

**wireformat 查询(RFC 8484,GET)**

```bash
curl "https://huwo-doh.example.workers.dev/doh-abc123?dns=AAABAAABAAAAAAAAA3d3dwdleGFtcGxlA2NvbQAAAQAB" \
  -H "accept: application/dns-message" --output resp.bin
```

**带令牌**

```bash
curl -H "Authorization: Bearer <DOH_TOKEN>" \
  "https://huwo-doh.example.workers.dev/doh-abc123?name=example.com&type=A" \
  -H "accept: application/dns-json"

# 或(适合不能自定义 header 的客户端)
curl "https://huwo-doh.example.workers.dev/doh-abc123?name=example.com&type=A&token=<DOH_TOKEN>" \
  -H "accept: application/dns-json"
```

**系统 / 浏览器 DoH**:多数系统级 DoH 只允许填一个 URL、不能加自定义 header。
这种情况请把 URL 填成 `https://huwo-doh.example.workers.dev/doh-abc123`(不带 token),
或使用 `?token=` 形式并在客户端支持的前提下拼接完整地址。

---

## 缓存行为

- `GET` 请求会按 URL(已剔除 `token`)写入 `caches.default`,命中的响应带 `x-cache: HIT`。
- 缓存时长取 DNS 响应中 `Answer` / `Authority` 的最小 TTL;无 TTL 或非 200 响应不缓存。
- 返回给客户端的响应头固定 `cache-control: private, max-age=<TTL>` 与 `cdn-cache-control: no-store`,避免 zone 缓存规则把结果在边缘缓存 4 小时。
- `POST`(wireformat)请求不缓存,直接透传。

## 安全建议

- `DOH_PATH` 使用足够长的随机串,不要用 `doh`、`dns` 这类可猜路径。
- 需要防滥用时配置 `DOH_TOKEN`;两者叠加等于「路径 + 令牌」双因子。
- 令牌只走 HTTPS;若担心日志泄露,优先用 `Authorization` 头而不是 `?token=`
  (本项目已开启 `redact_query_string`,但仍建议用 header)。
- 更换路径或令牌后在控制台更新变量并重新部署,旧地址立即失效。

## 验证部署是否正常

把 `<域名>` 和 `<DOH_PATH>` 换成自己的值,逐条执行:

```bash
# 1. JSON 查询:应返回 200 + {"Status":0,...,"Answer":[...]}
curl "https://<域名><DOH_PATH>?name=example.com&type=A" -H "accept: application/dns-json"

# 2. 错误路径:应返回 404
curl -o /dev/null -w "%{http_code}\n" "https://<域名>/wrong"

# 3. 非法方法:应返回 405
curl -o /dev/null -w "%{http_code}\n" -X DELETE "https://<域名><DOH_PATH>"

# 4. wireformat POST:应返回 200,响应体为二进制 DNS 报文
curl "https://<域名><DOH_PATH>" -X POST \
  -H "content-type: application/dns-message" -H "accept: application/dns-message" \
  --data-binary @query.bin -o resp.bin -w "%{http_code}\n"
```

成功时的响应头应包含 `x-cache: MISS`(首次)或 `x-cache: HIT`(命中缓存),以及
`cache-control: private, max-age=<DNS TTL>`。

## 故障排查

| 现象 | 原因 / 处理 |
| --- | --- |
| `Worker misconfigured: DOH_PATH is not set` | 变量没设置,或设置了但没重新部署。补齐后重新部署。 |
| 404 `Not Found` | 请求路径与 `DOH_PATH` 不一致(注意前导 `/`、结尾不要多加 `/`)。 |
| 401 `Unauthorized` | 设置了 `DOH_TOKEN` 但未携带或携带错误。 |
| 502 `Upstream error` | 上游 `cloudflare-dns.com` 超时(10s)。重试或检查 Worker 出网。 |
| 构建报 Worker 名称不匹配 | 控制台的 Worker 名称必须等于 `wrangler.jsonc` 的 `name`(`huwo-doh`)。 |
| 部署后变量丢失 | `wrangler.jsonc` 缺少 `keep_vars: true`。 |

## License

[MIT](./LICENSE)
