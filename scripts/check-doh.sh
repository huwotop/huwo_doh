#!/usr/bin/env bash
# 在 Debian/Ubuntu 上自检一个 DoH 反代端点是否可用、缓存是否生效。
#
# 用法:
#   ./scripts/check-doh.sh https://doh.huwo.kdns.fr/m8f2c3w1d3
#   ./scripts/check-doh.sh https://doh.huwo.kdns.fr/m8f2c3w1d3 --token <DOH_TOKEN>
#   DOH_RESOLVE_IP=104.21.96.154 ./scripts/check-doh.sh <url>   # 本机解析不到时强制指定 IP
#
# 依赖: curl、bash;python3 可选(仅用于 wireformat POST 测试)

set -u

URL="${1:-}"
shift || true

if [ -z "$URL" ]; then
  echo "用法: $0 <DoH 完整地址(含私有路径)> [--token 令牌]" >&2
  exit 2
fi

TOKEN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --token) TOKEN="${2:-}"; shift 2 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

# 统一在 CURL 数组里带好公共参数,后续所有请求直接 "${CURL[@]}"
CURL=(curl -sS --max-time 15 --retry 2 --retry-delay 1 --retry-connrefused)
if [ -n "${DOH_RESOLVE_IP:-}" ]; then
  HOST=$(printf '%s' "$URL" | sed -E 's#^https?://([^/:]+).*#\1#')
  CURL+=(--resolve "${HOST}:443:${DOH_RESOLVE_IP}")
fi
if [ -n "$TOKEN" ]; then
  CURL+=(-H "authorization: Bearer ${TOKEN}")
fi

PASS=0
FAIL=0
ok()   { echo "  [OK]   $1"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
note() { echo "         $1"; }

# 从响应头里取某个头的值
hdr() { tr -d '\r' | awk -v k="$1" 'index(tolower($0), k":")==1 { sub(/^[^:]*:[ ]*/, ""); print; exit }'; }

echo "== 0. 目标 =="
echo "  $URL"
[ -n "$TOKEN" ] && echo "  令牌: 已提供(只经 Authorization 头发送)"
[ -n "${DOH_RESOLVE_IP:-}" ] && echo "  强制解析: ${DOH_RESOLVE_IP}"

echo
echo "== 1. JSON 查询(Cloudflare 扩展接口,判断链路最快) =="
RESP=$("${CURL[@]}" -w '\n__CODE__%{http_code}' \
  -H 'accept: application/dns-json' "$URL?name=example.com&type=A" 2>/dev/null)
CODE1=${RESP##*__CODE__}
BODY=${RESP%$'\n'__CODE__*}

case "$CODE1" in
  200)
    if printf '%s' "$BODY" | grep -q '"Status":0'; then
      ok "HTTP 200,Status=0"
      ANS=$(printf '%s' "$BODY" | tr -d '\n' | sed -n 's/.*"Answer":\(\[[^]]*\]\).*/\1/p' | cut -c1-140)
      [ -n "$ANS" ] && note "Answer: $ANS"
    elif printf '%s' "$BODY" | grep -q '"Status"'; then
      bad "HTTP 200 但 DNS Status=$(printf '%s' "$BODY" | sed -n 's/.*"Status":\([0-9]*\).*/\1/p')"
    else
      bad "HTTP 200 但不是 DNS JSON: $(printf '%s' "$BODY" | head -c 120)"
    fi
    ;;
  401) bad "HTTP 401 → 需要令牌,用 --token 传入" ;;
  404) bad "HTTP 404 → 路径不对(检查 DOH_PATH,前导斜杠必须有,末尾不要加 /)" ;;
  500) bad "HTTP 500 → Worker 的 DOH_PATH 变量未设置或未重新部署: $(printf '%s' "$BODY" | head -c 100)" ;;
  000) bad "连不上(HTTP 000) → 域名解析 / 网络 / 证书问题" ;;
  *)   bad "HTTP $CODE1" ;;
esac

echo
echo "== 2. 错误路径应被拒(期望 404) =="
WRONG=$(printf '%s' "$URL" | sed -E 's#/[^/]+$#/doh-not-exist-check#')
CODE2=$("${CURL[@]}" -o /dev/null -w '%{http_code}' "$WRONG")
[ "$CODE2" = "404" ] && ok "错误路径返回 404" || bad "错误路径返回 $CODE2(期望 404,鉴权可能失效)"
note "测试地址: $WRONG"

echo
echo "== 3. 非法方法应被拒(期望 405) =="
CODE3=$("${CURL[@]}" -o /dev/null -w '%{http_code}' -X DELETE "$URL")
[ "$CODE3" = "405" ] && ok "DELETE 返回 405" || bad "DELETE 返回 $CODE3(期望 405)"

echo
echo "== 4. wireformat GET(?dns=),标准 DoH 客户端走的就是这条 =="
DNSQ='AAABAAABAAAAAAAAB2V4YW1wbGUDY29tAAABAAE'   # example.com A
CODE4=$("${CURL[@]}" -o /tmp/_doh_wf.bin -w '%{http_code}' \
  -H 'accept: application/dns-message' "$URL?dns=$DNSQ")
SIZE4=$(wc -c < /tmp/_doh_wf.bin 2>/dev/null | tr -d ' ')
if [ "$CODE4" = "200" ] && [ "${SIZE4:-0}" -gt 12 ]; then
  ok "HTTP 200,收到 ${SIZE4} 字节二进制报文"
else
  bad "HTTP $CODE4,大小 ${SIZE4:-0} 字节"
fi

echo
echo "== 5. wireformat POST =="
if command -v python3 >/dev/null 2>&1; then
  python3 -c 'import base64;open("/tmp/_doh_q.bin","wb").write(base64.urlsafe_b64decode("AAABAAABAAAAAAAAB2V4YW1wbGUDY29tAAABAAE"+"=="))'
  CODE5=$("${CURL[@]}" -o /tmp/_doh_post.bin -w '%{http_code}' \
    -X POST -H 'content-type: application/dns-message' -H 'accept: application/dns-message' \
    --data-binary @/tmp/_doh_q.bin "$URL")
  SIZE5=$(wc -c < /tmp/_doh_post.bin 2>/dev/null | tr -d ' ')
  if [ "$CODE5" = "200" ] && [ "${SIZE5:-0}" -gt 12 ]; then
    ok "HTTP 200,收到 ${SIZE5} 字节二进制报文"
  else
    bad "HTTP $CODE5(415 = 上游拒收 content-type,POST 转发有问题)"
  fi
else
  note "未安装 python3,跳过"
fi

echo
echo "== 6. 缓存是否生效(同一查询连续 4 次) =="
note "缓存按 Cloudflare 机房隔离,只有落在同一机房才会 MISS → HIT;"
note "不同机房(看 cf-ray 后缀,如 -SOF/-HKG)各自独立。"
HITS=0
for i in 1 2 3 4; do
  H=$("${CURL[@]}" -o /dev/null -D - -H 'accept: application/dns-json' \
    "$URL?name=example.com&type=A" 2>/dev/null)
  XC=$(printf '%s' "$H" | hdr x-cache)
  TTL=$(printf '%s' "$H" | hdr x-dns-ttl)
  CC=$(printf '%s' "$H" | hdr cache-control)
  RAY=$(printf '%s' "$H" | hdr cf-ray)
  [ "${XC:-}" = "HIT" ] && HITS=$((HITS+1))
  echo "  第 $i 次: x-cache=${XC:-<无>}  x-dns-ttl=${TTL:-<无>}  ${CC:+cache-control=$CC}  ray=${RAY:-?}"
  sleep 1
done
if [ "$HITS" -ge 1 ]; then
  ok "命中缓存 $HITS/4 次,缓存生效"
else
  bad "4 次均未命中:可能每次落到不同机房,或 TTL 极短"
  note "固定机房重试: DOH_RESOLVE_IP=<该域名的 A 记录> $0 $URL"
fi

echo
echo "== 7. 缓存过期验证(TTL 到点后应重新回源) =="
H=$("${CURL[@]}" -o /dev/null -D - -H 'accept: application/dns-json' \
  "$URL?name=example.com&type=A" 2>/dev/null)
TTL=$(printf '%s' "$H" | hdr x-dns-ttl)
if [ -n "${TTL:-}" ] && [ "$TTL" -gt 0 ] 2>/dev/null; then
  WAIT=$((TTL + 2))
  if [ "$WAIT" -le 65 ]; then
    echo "  等待 ${WAIT}s(TTL=${TTL}+2)后重查..."
    sleep "$WAIT"
    XC2=$("${CURL[@]}" -o /dev/null -D - -H 'accept: application/dns-json' \
      "$URL?name=example.com&type=A" 2>/dev/null | hdr x-cache)
    if [ "${XC2:-}" = "MISS" ]; then
      ok "TTL 过期后重新回源(x-cache=MISS),缓存时长跟随 DNS TTL"
    else
      bad "TTL 过期后仍为 ${XC2:-<无>},缓存时长可能不受 TTL 控制"
    fi
  else
    note "TTL=${TTL}s 太长,跳过等待(可手动 sleep $WAIT 后再查一次 x-cache)"
  fi
else
  note "未取到 x-dns-ttl,跳过"
fi

echo
echo "== 8. 响应头抽样 =="
"${CURL[@]}" -o /dev/null -D - -H 'accept: application/dns-json' \
  "$URL?name=example.com&type=A" 2>/dev/null \
  | tr -d '\r' | grep -iE '^(HTTP/|x-cache|x-dns-ttl|cache-control|content-type|cf-cache-status|age|cf-ray):' | sed 's/^/  /'

echo
echo "== 结果: 通过 $PASS 项,失败 $FAIL 项 =="
[ "$FAIL" -eq 0 ] || exit 1
