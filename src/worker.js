/**
 * DoH 反代 Worker
 *
 * 必填变量:
 *   DOH_PATH  - 对外暴露的私有路径,如 /doh-9ba32d203ced8136869c2a13
 * 可选变量:
 *   DOH_TOKEN - 访问令牌。设置后必须携带 Authorization: Bearer <token>
 *               或 ?token=<token>;不设置则只靠 DOH_PATH 鉴权
 */

const UPSTREAM_HOST = 'cloudflare-dns.com'
const UPSTREAM_PATH = '/dns-query'

/** 归一化 DOH_PATH:补前导斜杠、去尾部斜杠 */
function normalizePath(value) {
  if (!value) return ''
  let p = String(value).trim()
  if (!p) return ''
  if (!p.startsWith('/')) p = '/' + p
  if (p.length > 1 && p.endsWith('/')) p = p.replace(/\/+$/, '')
  return p
}

/** 恒定时间字符串比较,避免逐字符提前返回泄露长度/前缀 */
function safeEqual(a, b) {
  const enc = new TextEncoder()
  const x = enc.encode(a)
  const y = enc.encode(b)
  if (x.length !== y.length) return false
  let diff = 0
  for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i]
  return diff === 0
}

/** 从 Authorization: Bearer 或 ?token= 中取出令牌 */
function extractToken(request, url) {
  const auth = request.headers.get('authorization') || ''
  if (auth.toLowerCase().startsWith('bearer ')) {
    return auth.slice(7).trim()
  }
  return url.searchParams.get('token') || ''
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url)

    // ===== 0. 读取并校验配置 =====
    const secretPath = normalizePath(env.DOH_PATH)
    if (!secretPath) {
      // 未配置路径时拒绝服务,而不是退化成公开端点
      return new Response('Worker misconfigured: DOH_PATH is not set', { status: 500 })
    }

    // ===== 1. 只允许 GET / POST(RFC 8484 规定的两种方法) =====
    if (request.method !== 'GET' && request.method !== 'POST') {
      return new Response('Method Not Allowed', { status: 405 })
    }

    // ===== 2. 路径校验(随机长路径是凭证之一,失败统一 404) =====
    if (url.pathname !== secretPath) {
      return new Response('Not Found', { status: 404 })
    }

    // ===== 3. 令牌校验(仅在 DOH_TOKEN 已配置时生效) =====
    const token = (env.DOH_TOKEN || '').trim()
    if (token && !safeEqual(extractToken(request, url), token)) {
      return new Response('Unauthorized', {
        status: 401,
        headers: {
          'www-authenticate': 'Bearer realm="doh"',
          'cache-control': 'no-store',
        },
      })
    }

    // 令牌可能出现在 query 中,不能透传给上游,也不能进入缓存 key
    const isJsonQuery = request.method === 'GET' && url.searchParams.has('name')
    url.searchParams.delete('token')

    // ===== 4. 缓存 key:用 Worker 自己域名且已剔掉 token 的 URL =====
    const cacheKey = request.method === 'GET' ? new Request(url.toString(), { method: 'GET' }) : null

    // ===== 5. 重写 URL 为上游 DoH 端点 =====
    url.protocol = 'https:'
    url.host = UPSTREAM_HOST
    url.pathname = UPSTREAM_PATH

    // ===== 6. 重建请求头,不透传客户端的 cookie / cf-* 等敏感头 =====
    const headers = new Headers()
    // GET 带 name 参数的是 JSON 查询;RFC 8484 的 GET(?dns=)和 POST 都是 wireformat
    headers.set('accept', isJsonQuery ? 'application/dns-json' : 'application/dns-message')

    // POST 必须带 content-type,否则上游直接回 415
    if (request.method === 'POST') {
      headers.set('content-type', 'application/dns-message')
    }

    // ===== 7. 命中缓存直接返回 =====
    const cache = caches.default
    if (cacheKey) {
      try {
        const cached = await cache.match(cacheKey)
        if (cached) {
          // 缓存的 Response 头不可变,重建后再标注 HIT
          const hit = new Response(cached.body, cached)
          hit.headers.set('x-cache', 'HIT')
          // Cloudflare 缓存层会把 cache-control 改写成 14400,
          // 用存入时的 x-dns-ttl 还原真实 DNS TTL
          const dnsTtl = cached.headers.get('x-dns-ttl')
          hit.headers.set(
            'cache-control',
            `private, max-age=${dnsTtl ?? cached.headers.get('cache-control') ?? 0}`
          )
          hit.headers.set('cdn-cache-control', 'no-store')
          return hit
        }
      } catch (_) {}
    }

    // ===== 8. 构造并转发请求 =====
    const upstreamReq = new Request(url.toString(), {
      method: request.method,
      headers,
      body: request.method === 'POST' ? await request.arrayBuffer() : undefined,
    })

    let resp
    try {
      // 上游 10s 超时,避免客户端长时间挂起
      resp = await fetch(upstreamReq, { signal: AbortSignal.timeout(10000) })
    } catch (e) {
      console.error('upstream fetch failed:', e.message)
      return new Response('Upstream error', { status: 502 })
    }

    // ===== 9. 返回响应;成功的 GET 响应写入缓存 =====
    // cloudflare-dns.com 的 JSON 接口不返回 cache-control 头,
    // 所以从 DNS 响应的 Answer TTL 里自己算缓存时长
    const respHeaders = new Headers()
    respHeaders.set('content-type', resp.headers.get('content-type') || 'application/dns-message')
    respHeaders.set('x-cache', 'MISS')

    const body = await resp.arrayBuffer()

    // 从 JSON 的 Answer/Authority 记录里取最小 TTL
    let ttl = null
    if (isJsonQuery && resp.ok) {
      try {
        const data = JSON.parse(new TextDecoder().decode(body))
        const records = [...(data.Answer || []), ...(data.Authority || [])]
        const ttls = records.map((r) => r.TTL).filter((t) => Number.isInteger(t) && t > 0)
        if (ttls.length) {
          ttl = Math.min(...ttls)
        }
      } catch (_) {}
    }

    // 客户端响应标 private:共享缓存(CDN)按规范从不缓存 private 响应,
    // 防止 zone 缓存规则把 DNS 结果在边缘缓存 4 小时导致记录陈旧
    respHeaders.set('cache-control', `private, max-age=${ttl ?? 0}`)
    respHeaders.set('cdn-cache-control', 'no-store')

    const response = new Response(body, {
      status: resp.status,
      headers: respHeaders,
    })

    if (cacheKey && ttl !== null) {
      // 写入 Cache API 的响应必须是可缓存的头(不能带 private / no-store),
      // TTL 严格等于 DNS TTL
      const cacheResp = new Response(body, {
        status: resp.status,
        headers: {
          'content-type': respHeaders.get('content-type') || 'application/dns-message',
          'cache-control': `max-age=${ttl}`,
          'x-dns-ttl': String(ttl),
        },
      })
      try {
        await cache.put(cacheKey, cacheResp)
      } catch (_) {}
    }

    return response
  },
}
