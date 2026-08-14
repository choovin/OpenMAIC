# OpenMAIC 项目说明(CLAUDE.md)

本文件为 Claude Code 在 **`/home/jmtms/OpenMAIC`** 项目目录下的入口上下文。读这份文件就能掌握:这是什么、怎么跑、踩过什么坑、哪里看日志。

## 1. 项目定位

**OpenMAIC**(Open Multi-Agent Interactive Classroom)——清华 THU-MAIC 团队的开源 AI 互动课堂平台(v0.3.1)。把任意主题/文档转化为多智能体互动的课堂:AI 老师讲解 + AI 同学讨论 + 白板绘图 + 测验/PBL/3D 模拟。

- 上游: <https://github.com/THU-MAIC/OpenMAIC>
- 技术栈: **Next.js 16.1.2** (App Router, Turbopack) + React 19.2 + TypeScript 5 + LangGraph 1.1 + Tailwind 4 + Vercel AI SDK 6
- 工作区: pnpm 10.28.0 + 7 个 `packages/*` 工作区子包(`@openmaic/dsl`、`@openmaic/generation`、`@openmaic/storage`、`@openmaic/importer`、`@openmaic/renderer`、`@openmaic/editor`、外加 `mathml2omml`、`pptxgenjs`)
- 文档: [`README.md`](README.md)(英文) / [`README-zh.md`](README-zh.md)(简体中文)

## 2. 本机部署拓扑

| 项 | 值 |
|---|---|
| 仓库路径 | `/home/jmtms/OpenMAIC` |
| 镜像 | `openmaic-openmaic:latest` (442MB,基于 `node:22-alpine`) |
| 容器名 | `openmaic-openmaic-1` |
| 监听 | `0.0.0.0:3000` (host 3000 端口 LISTEN,内网可达) |
| 数据卷 | `openmaic_openmaic-data` → `/app/data` |
| 隔离网络 | `openmaic_render` (internal,仅 video-export profile 用) |
| 副 service | `render-service`(video-export profile,默认不启)/ `postgres`(server-persistence profile,默认不启) |
| 公网入口 | ✅ **已通过 1Panel openresty 反代到 `https://maic.qikumr.com/`**(2026-08-12),HTTPS + HSTS 1y,反代核心在 `1Panel-openresty-TJKB` 容器内 `proxy/root.conf`,上游 `127.0.0.1:3000` |

跟 jmtms 业务栈(`jmtms-prod_default` 网络)是**完全隔离**的独立 docker compose,互不干扰。

## 3. 常用命令

```bash
# 看容器状态
sg docker -c "docker ps --filter 'name=openmaic' --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"

# 实时日志(追问题)
sg docker -c "docker logs openmaic-openmaic-1 -f --tail 200"

# 健康检查
curl -s -o /dev/null -w "page -> %{http_code}\n" http://localhost:3000/
curl -s http://localhost:3000/api/health
curl -s http://localhost:3000/api/access-code/status   # 应返回 enabled:true

# 改了 Dockerfile / package.json -> 重 build
sg docker -c "docker compose -f /home/jmtms/OpenMAIC/docker-compose.yml build openmaic"

# 改了 ALLOWED_FRAME_ANCESTORS(白名单 / CSP frame-ancestors)-> 必须重 build
# 见 §12:这是 build-time 配置,普通 force-recreate 不读 env_file 也不会重 build
sed -i 's|^ALLOWED_FRAME_ANCESTORS=.*|ALLOWED_FRAME_ANCESTORS=新值|' /home/jmtms/OpenMAIC/.env
sed -i 's|^ALLOWED_FRAME_ANCESTORS=.*|ALLOWED_FRAME_ANCESTORS=新值|' /home/jmtms/OpenMAIC/.env.local
sg docker -c "docker compose -f /home/jmtms/OpenMAIC/docker-compose.yml build --no-cache openmaic"
sg docker -c "docker compose -f /home/jmtms/OpenMAIC/docker-compose.yml up -d --force-recreate openmaic"

# 只改了 .env.local -> 必须 force-recreate(普通 restart 不会重读 env_file)
sg docker -c "docker compose -f /home/jmtms/OpenMAIC/docker-compose.yml up -d --force-recreate openmaic"

# 启停
sg docker -c "docker compose -f /home/jmtms/OpenMAIC/docker-compose.yml start openmaic"
sg docker -c "docker compose -f /home/jmtms/OpenMAIC/docker-compose.yml stop openmaic"

# 进容器调试(node:22-alpine 没装 curl,用 node 直接调)
sg docker -c "docker exec -it openmaic-openmaic-1 /bin/sh"
```

## 4. 配置文件

- **`.env.local`** — 所有运行时 env(权限 `chmod 600`,跟 git 仓库脱钩)
  - `ANTHROPIC_API_KEY` / `ANTHROPIC_BASE_URL` / `ANTHROPIC_MODELS` — LLM provider(走 runnode 代理,见 §6)
  - `DEFAULT_MODEL` — 服务端默认模型(必须指向已声明的 `provider:model`)
  - `ACCESS_CODE` — 站点访问密码(留空 = 不启用)
  - `ALLOWED_FRAME_ANCESTORS` — iframe 嵌入白名单(**build-time**,详见 §12),运行时改无效
  - `LOG_LEVEL` / `LOG_FORMAT` — 日志输出
  - `NEXT_PUBLIC_*` — 编译期注入前端的开关(改完必须重 build)
- **`.env`** — 仅放 `docker compose build` 自动注入的 build arg(目前只有 `ALLOWED_FRAME_ANCESTORS`)。**不**放密钥(密钥留 `.env.local`)
- **`docker-compose.yml`** — 4 个 service(openmaic / postgres / render-service + 默认网络/volume)
- **`Dockerfile`** — 4 阶段(base / deps / builder / runner),已针对国内网络做了 3 处改造(见 §5)
- **`server-providers.yml`** — 可选,挂载后可覆盖 env 配置(默认不存在)

## 5. 国内网络改造(Dockerfile 已改)

部署时遇到三个国内网络坑,已就地修复 Dockerfile。后续重 build 会保留这些改造:

| 坑 | 现象 | 修复 |
|---|---|---|
| corepack 从 GitHub releases 拉 pnpm | corepack prepare 经常超时 | 改成 `npm install -g pnpm@10.28.0` 走 npmmirror |
| alpine dl-cdn.alpinelinux.org 慢 | 68 包要 455s | 每处 `RUN apk add` 前加 `sed -i 's\|dl-cdn.alpinelinux.org\|mirrors.aliyun.com\|g' /etc/apk/repositories` |
| npm 默认 registry.npmjs.org 慢 | 大依赖超时 | `ENV NPM_CONFIG_REGISTRY=https://registry.npmmirror.com` |

## 6. LLM Provider 配置

OpenMAIC 通过 **Anthropic 兼容协议** 走 runnode 代理(`https://api.runnode.ai/v1`)用国内模型。Token 与 `~/.claude/settings.json` 共享,**计费共享配额**。

```bash
ANTHROPIC_API_KEY=sk-...                 # 同 Claude Code 的 token
ANTHROPIC_BASE_URL=https://api.runnode.ai/v1   # 必须带 /v1 后缀!
ANTHROPIC_MODELS=MiniMax-M2.7-highspeed,MiniMax-M3,GLM-5.1,GLM-5-Turbo,kimi-for-coding
DEFAULT_MODEL=anthropic:MiniMax-M3       # 最稳的一个(无 thinking)
```

**5 个模型的坑**:`MiniMax-M3` 默认无 thinking 最稳;`MiniMax-M2.7-highspeed` / `kimi-for-coding` 在 verify-model 写死的 `max_tokens=64` 下会把 token 全做 thinking 不留 text 触发 `AI_APICallError: Invalid JSON response`;`GLM-5.x` 在 runnode 上不返回 text block,不可用。

**SDK baseURL 坑**:Vercel AI SDK 的 `createAnthropic` 不会自动 append `/v1`,所以 `ANTHROPIC_BASE_URL` **必须显式带 `/v1`**。漏了 SDK 会拼出 `https://api.runnode.ai/messages`(404 HTML),报 `Invalid JSON response`。

**验证连通性**:
```bash
curl -X POST http://localhost:3000/api/verify-model \
  -H 'content-type: application/json' \
  -d '{"model":"anthropic:MiniMax-M3"}'
# 期望: {"success":true,"message":"Connection successful","response":"OK"}
```

`/api/server-providers` 返回的是当前生效的 provider 清单(LLM/TTS/ASR/PDF/Image/Video/WebSearch),改 env 后用它快速核对。

## 7. 访问授权(ACCESS_CODE)

OpenMAIC 用 **HMAC-SHA256 签名 cookie** 鉴权(`openmaic_access = timestamp.signature`,签名密钥 = ACCESS_CODE):

- 当前密码: `maic020`(6 位字母数字组合,内网防护够用,真要公网部署建议加长)
- 无 cookie 访问: 页面 → 200 + 前端弹密码框;API → 401 `Access code required`
- 白名单: `_next/static`、`_next/image`、`favicon.ico`、`logos/`、`/api/access-code/*`、`/api/health`
- 改 ACCESS_CODE 后所有现有 cookie 失效(签名校验失败),用户需重输

**改密码**:
```bash
sed -i 's/^ACCESS_CODE=.*/ACCESS_CODE=新密码/' /home/jmtms/OpenMAIC/.env.local
sg docker -c "docker compose -f /home/jmtms/OpenMAIC/docker-compose.yml up -d --force-recreate openmaic"
```

## 8. 公网反代(2026-08-12 已接入)

- **反代链**: 客户端 → 1Panel openresty(`1Panel-openresty-TJKB` 容器,监听 80/443)→ `127.0.0.1:3000` → OpenMAIC 容器
- **HTTPS 终止**: openresty,证书 `/www/sites/maic.qikumr.com/ssl/fullchain.pem`,TLS 1.3 + 现代 cipher suite
- **HTTP → HTTPS**: 301 重定向
- **安全头**: HSTS `max-age=31536000` (1 年)
- **头透传**: `Host`、`X-Real-IP`、`X-Forwarded-For`、`X-Forwarded-Proto`、`X-Forwarded-Port`,支持 WebSocket(Upgrade/Connection + http/1.1)
- **配置文件**: `/usr/local/openresty/nginx/conf/conf.d/maic.qikumr.com.conf` + `/www/sites/maic.qikumr.com/proxy/root.conf`
- **访问日志**: `/www/sites/maic.qikumr.com/log/access.log`(openresty 容器内)
- **WAF**: 1Panel 1pwaf 自动监控,有 site_stat / status_code_stats / req_uris 等 db

### 公网端验证(2026-08-12)
- `https://maic.qikumr.com/` → HTTP 200,Next.js 首页
- `https://maic.qikumr.com/api/health` → 200(白名单)
- `https://maic.qikumr.com/api/access-code/status` → `enabled:true`
- `https://maic.qikumr.com/api/server-providers` 无 cookie → **401 `Access code required`**(中间件穿透反代正常拦截)

## 9. 已知限制与下一步

- **未启用 BasicAuth 双层认证**——目前只有 OpenMAIC ACCESS_CODE 一层,够用但不够强。1Panel 反代可叠加 HTTP BasicAuth(或者 IP 白名单)做双保险
- **ACCESS_CODE 仍是 `maic020`**(6 位中等强度),公网暴露后建议改成 12+ 位强密码
- **没用 render-service / postgres**——MP4 导出降级到 ZIP 下载路径,课堂存储用 IndexedDB 本地模式。要用视频导出需 `docker compose --profile video-export up`

## 10. 跟 jmtms 业务栈的关系

- 完全独立部署(独立 docker network,独立镜像,独立数据卷)
- 没有共享凭据、共享网络、共享存储
- 如果未来要让 jmtms 业务调用 OpenMAIC 课堂生成,需把 `openmaic_default` 加入 `jmtms-prod_default`,或走 1Panel 反代路径

## 11. 相关 memory

- 本会话部署踩坑的全局记录: `~/.claude/projects/-home-jmtms/memory/openmaic-deploy-2026-08-11.md`
- 本项目级记忆笔记: [`memory.md`](memory.md)

## 12. iframe 嵌入白名单(`ALLOWED_FRAME_ANCESTORS`)

OpenMAIC 默认响应头是 `X-Frame-Options: SAMEORIGIN` + `Content-Security-Policy: frame-ancestors 'self'`,**任何外部站点用 `<iframe>` 嵌都会被浏览器拒绝**(报"拒绝了连接请求")。

### 怎么放开

`next.config.ts:22-34` 已经预留开关,读 env **`ALLOWED_FRAME_ANCESTORS`**(空格分隔多个):

```bash
# 示例:放行 localhost 自嵌 + 一个公网站点
ALLOWED_FRAME_ANCESTORS="http://localhost:3000 https://partner.example.com"
```

设置后,**`X-Frame-Options` 会自动消失**(它没有 allow-list 语法,只支持 `SAMEORIGIN`),只留 `frame-ancestors 'self' <白名单>`。CSP 与 XFO 同时存在时浏览器取更严格者;删 XFO 是必要的,否则 `SAMEORIGIN` 会盖住白名单。

### ⚠️ 这是 build-time 配置,不是 runtime

`next.config.ts` 的 `headers()` 在 **`pnpm build` 阶段**求值,standalone 输出把求值结果烧进镜像。意味着:

- **改 `.env.local` 不够**:`env_file` 只在 runtime 注入容器,build 阶段读不到
- **`docker compose build` 默认只读 `.env`,不读 `.env.local`**
- **`--force-recreate` 不解决问题**:它重启容器但用的是旧镜像,next.config 早烧进去了

正确流程(已写在 §3 命令索引):

```bash
# 1) 改两处 env:.env 给 build arg 自动取,.env.local 留作源码参考
sed -i 's|^ALLOWED_FRAME_ANCESTORS=.*|ALLOWED_FRAME_ANCESTORS=新值|' /home/jmtms/OpenMAIC/.env
sed -i 's|^ALLOWED_FRAME_ANCESTORS=.*|ALLOWED_FRAME_ANCESTORS=新值|' /home/jmtms/OpenMAIC/.env.local

# 2) 显式 rebuild(build 阶段 .env 被 compose 读出来注入 ARG)
sg docker -c "docker compose -f /home/jmtms/OpenMAIC/docker-compose.yml build --no-cache openmaic"

# 3) 强制 recreate(用新镜像)
sg docker -c "docker compose -f /home/jmtms/OpenMAIC/docker-compose.yml up -d --force-recreate openmaic"
```

### 验证

**必须从公网入口看**,因为反代可能覆盖头:

```bash
curl -sI https://maic.qikumr.com/ | grep -iE 'x-frame|content-security|frame-ancestors'
# 期望:
#   Content-Security-Policy: frame-ancestors 'self' http://localhost:3000 ...
#   (不应再看到 X-Frame-Options)
```

### 协议要严格匹配

写 `https://` 就不能嵌 `http://` 的页面,反之亦然。本地开发用 `http://localhost:3000`,公网部署用 `https://...`。`*` 通配符不推荐(浏览器对 `frame-ancestors *` 处理不一致)。

### 涉及的文件

- `next.config.ts` — headers() 求值逻辑
- `Dockerfile` — builder 阶段 `ARG ALLOWED_FRAME_ANCESTORS` + `ENV ALLOWED_FRAME_ANCESTORS=...`
- `docker-compose.yml` — `args:` 块透传 build arg
- `.env` — compose 自动读取(放 build arg)
- `.env.local` — 源码参考 + runtime 兜底(虽然 build 用不到)
