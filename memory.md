# Memory — OpenMAIC 部署会话笔记

> 本文件记录 OpenMAIC 项目内部的关键决策、踩坑、待办。
> 区别于 `~/.claude/projects/-home-jmtms/memory/` 下的全局 memory(那个跨项目共享)。

---

## 📅 2026-08-12 — 公网反代接入

### 变更
- 域名: `https://maic.qikumr.com/`(DNS → 8.134.89.248,本机公网 IP)
- 反代: 1Panel openresty 容器 `1Panel-openresty-TJKB`(`1panel/openresty:1.31.1.1-0-noble`),监听 80/443
- 上游: `127.0.0.1:3000`(OpenMAIC 容器 host 端口)
- 协议: HTTPS(TLS 1.3)终止在 openresty,后端 HTTP
- 安全头: HSTS max-age=31536000(1 年)
- 头透传: Host / X-Real-IP / X-Forwarded-For / X-Forwarded-Proto / X-Forwarded-Port
- WebSocket 支持: `proxy_http_version 1.1` + Upgrade/Connection 头(OpenMAIC SSE 流式响应需要)
- WAF: 1Panel 1pwaf 自动开启,有 site_stat / req_uris / user_agents 等监控 db

### 验证(全部通过)
| 端点 | 期望 | 实际 |
|---|---|---|
| `https://maic.qikumr.com/` | 200,Next.js 首页 | ✅ 200,30KB |
| `https://maic.qikumr.com/api/health` | 200(白名单) | ✅ 200 |
| `https://maic.qikumr.com/api/access-code/status` | enabled:true | ✅ enabled:true,authenticated:false |
| `https://maic.qikumr.com/api/server-providers` 无 cookie | 401 | ✅ 401 "Access code required" |

中间件鉴权穿透反代正常工作——证明 ACCESS_CODE HMAC cookie 机制跟反代兼容(cookie 域名是浏览器自动绑定的,不需要服务端特殊处理)。

### ACCESS_CODE 强度评估(待用户确认)
- 当前: `maic020`(6 位字母数字,中等强度)
- 公网暴露后建议: 12+ 位带特殊字符的强密码
- 或者叠加: 1Panel 反代层 BasicAuth + IP 白名单做双层

---

## 📅 2026-08-11 / 12 — 部署会话总结

### 会话目标
在 `/home/jmtms` 主机部署清华 MAIC 团队的 **OpenMAIC v0.3.1**(AI 互动课堂平台),并接入 runnode 代理用国内模型。

### 最终成果
- ✅ 容器跑通: `openmaic-openmaic-1` 监听 `0.0.0.0:3000`
- ✅ LLM 链路通: OpenMAIC → Vercel AI SDK → `api.runnode.ai/v1` → `MiniMax-M3`
- ✅ 访问授权生效: ACCESS_CODE=`maic020`,HMAC 签名 cookie 机制
- ✅ 镜像大小: 442MB(基于 `node:22-alpine`)

### 踩坑清单(按踩坑顺序)

#### 坑 1: 国内 alpine 源慢(致命)
**现象**:第一次 `docker compose build openmaic` 卡在 `RUN apk add python3 build-base g++ cairo-dev ...`,177 个包要装 3-4 小时。
**根因**:alpine 默认源 `dl-cdn.alpinelinux.org` 在国内访问慢,68 个 runner 包要 455.2s。
**修复**:Dockerfile 三处 `RUN apk add` 前加 `RUN sed -i 's|dl-cdn.alpinelinux.org|mirrors.aliyun.com|g' /etc/apk/repositories`,提速到 34s/68 包(13 倍)。
**注意**:这导致所有 stage 的 layer cache miss,第一次 build 要重跑全部阶段;但后续 rebuild 走 cache 就快了。

#### 坑 2: corepack 拉 pnpm 失败
**现象**:`corepack enable && corepack prepare pnpm@10.28.0 --activate` 从 GitHub releases 拉 pnpm 二进制,国内访问 GitHub 不稳定。
**修复**:换成 `RUN npm install -g pnpm@10.28.0` 走 npmmirror,2.1s 装好。
**注意**:`ENV NPM_CONFIG_REGISTRY=https://registry.npmmirror.com` 也解决了 pnpm install 时 registry.npmjs.org 慢的问题。

#### 坑 3: docker compose restart 不重读 env_file(隐蔽)
**现象**:改完 `.env.local` 后 `docker compose restart`,容器内 env 还是旧的。
**根因**:`restart` 只是 SIGTERM 重启容器进程,env_file 在容器创建时已经嵌入到容器 config 里,restart 用的是缓存 config。
**修复**:改完 env 必须 `up -d --force-recreate` 才会重新创建容器并读取 env_file。

#### 坑 4: ANTHROPIC_BASE_URL 必须带 /v1 后缀(SDK 行为)
**现象**:`verify-model` 报 `AI_APICallError: Invalid JSON response`,即使手动 curl `/v1/messages` 正常。
**根因**:Vercel AI SDK 的 `createAnthropic({ baseURL })` 不会自动 append `/v1`,会直接拼到 baseURL 后。如果 baseURL = `https://api.runnode.ai`,SDK 拼出 `https://api.runnode.ai/messages`(404 HTML);只有 baseURL = `https://api.runnode.ai/v1` 才拼出 `https://api.runnode.ai/v1/messages`(对的)。
**修复**:`ANTHROPIC_BASE_URL=https://api.runnode.ai/v1`。

#### 坑 5: verify-model 写死 max_tokens=64 太小
**现象**:MiniMax-M2.7-highspeed / kimi-for-coding 在 verify-model(`max_tokens=64`)下把 token 全做 thinking,没余量生成 text,触发 "Invalid JSON response"。
**根因**:OpenMAIC 的 verify-model 路由在 `app/api/verify-model/route.ts` 写死 `maxOutputTokens: 64`,某些模型 thinking 占比高。
**修复**:`DEFAULT_MODEL=anthropic:MiniMax-M3`(默认无 thinking),verify-model 通过。其它模型在真实生成场景(通常 max_tokens 256+)正常工作。

#### 坑 6: verify-model 调用格式
**现象**:第一次 curl `{"provider":"anthropic","model":"MiniMax-M3"}` 报 "API key required for provider: openai"。
**根因**:OpenMAIC 的 `resolveModel({ modelString, ... })` 用的是 `provider:model` 单字符串格式,不是分开的 `provider` + `model` 字段。
**修复**:`{"model":"anthropic:MiniMax-M3"}`。

### 关键配置文件位置

```
/home/jmtms/OpenMAIC/
├── .env.local                         # chmod 600,所有 env
├── Dockerfile                         # 4 stage,已改 alpine 源 + pnpm 安装
├── docker-compose.yml                 # openmaic + 可选 postgres/render-service
└── .dockerignore                      # 排除了 .env*、node_modules、render-service/

# 公网反代配置(1Panel openresty 容器内,不在本机文件系统)
/usr/local/openresty/nginx/conf/conf.d/maic.qikumr.com.conf    # 站点(server_name + TLS)
/www/sites/maic.qikumr.com/proxy/root.conf                      # upstream 反代规则
/www/sites/maic.qikumr.com/log/access.log                       # 访问日志
```

### 启动验证脚本(快速回归)

```bash
# 1. 容器状态
sg docker -c "docker ps --filter 'name=openmaic' --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"
# 期望: Up X minutes, 0.0.0.0:3000->3000/tcp

# 2. 健康检查(白名单,不受 ACCESS_CODE 影响)
curl -s http://localhost:3000/api/health
# 期望: {"success":true,"status":"ok",...}

# 3. ACCESS_CODE 启用状态
curl -s http://localhost:3000/api/access-code/status
# 期望: {"success":true,"enabled":true,"authenticated":false}

# 4. API 鉴权拦截(无 cookie 应 401)
curl -s -w "\nHTTP %{http_code}\n" http://localhost:3000/api/server-providers
# 期望: 401, "Access code required"

# 5. Provider 配置
curl -s http://localhost:3000/api/server-providers
# 期望: providers.anthropic.models 列出 5 个国内模型

# 6. LLM 连通性
curl -X POST http://localhost:3000/api/verify-model \
  -H 'content-type: application/json' \
  -d '{"model":"anthropic:MiniMax-M3"}'
# 期望: {"success":true,"message":"Connection successful","response":"OK"}
```

---

## 📋 待办

### 短期
- [ ] 浏览器实际测试生成一次课堂,验证从输入到生成完成的全流程
- [ ] 看 `docker logs openmaic-openmaic-1` 跟踪真实课堂生成的 provider 调用链
- [ ] 评估 ACCESS_CODE=`maic020` 强度是否够(已暴露公网后,建议加长到 12+ 位)
- [ ] 评估要不要在 1Panel 反代层叠加 BasicAuth / IP 白名单做双层防护

### 中期
- [ ] 启用 `--profile video-export`(MP4 渲染)
- [ ] 启用 `--profile server-persistence`(Postgres 持久化课堂)
- [ ] 监控告警:容器内存/磁盘/API 错误率 + 1pwaf 异常请求告警

### 长期
- [ ] 跟 jmtms 业务栈打通(让 jmtms 业务能调 OpenMAIC 课堂生成 API)
- [ ] 备份策略:`openmaic_openmaic-data` 卷定期备份

---

## 🔗 相关链接

- 项目主页: <https://open.maic.chat/>
- GitHub: <https://github.com/THU-MAIC/OpenMAIC>
- 论文: JCST 2026 "From MOOC to MAIC"
- 全局 memory: `~/.claude/projects/-home-jmtms/memory/openmaic-deploy-2026-08-11.md`
- jmtms 主机根目录: `/home/jmtms/CLAUDE.md`
