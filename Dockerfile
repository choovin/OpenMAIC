# ---- Stage 1: Base ----
FROM node:22-alpine AS base

# 国内网络:换 alpine 源到阿里云 + 装 libc6-compat
RUN sed -i 's|dl-cdn.alpinelinux.org|mirrors.aliyun.com|g' /etc/apk/repositories
RUN apk add --no-cache libc6-compat

# 国内网络:用 npmmirror 安装 pnpm,跳过 corepack(后者从 GitHub releases 拉,国内不稳定)
# 当前 pnpm-lock.yaml 是 pnpm 9.x 生成的,装 pnpm 10.x 会触发 ERR_PNPM_LOCKFILE_BREAKING_CHANGE。
# 等本机升级到 10.x 并重新 lockfile 后再切回 pnpm@10.28.0。
ENV NPM_CONFIG_REGISTRY=https://registry.npmmirror.com
RUN npm install -g pnpm@9.15.0 && pnpm config set registry https://registry.npmmirror.com

WORKDIR /app

# ---- Stage 2: Dependencies ----
FROM base AS deps

# 同样的 alpine 源替换 + native build tools for sharp, @napi-rs/canvas
RUN sed -i 's|dl-cdn.alpinelinux.org|mirrors.aliyun.com|g' /etc/apk/repositories
RUN apk add --no-cache python3 build-base g++ cairo-dev pango-dev jpeg-dev giflib-dev librsvg-dev

COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY packages/ ./packages/
COPY scripts/ ./scripts/

# onnxruntime-node(@hyperframes/producer 的传递依赖,被 hoist 到 workspace root,只有 video-export
# profile 的 render-service 会用到)在 install 时从 onnxxruntimetmp.blob.core.windows.net 下载二进制,
# 国内网络下载失败 302。主 image 不需要它,跳过即可(变量名是 ONNXRUNTIME_NODE_INSTALL=skip),
# 启用 video-export 时再单独解决。
ENV ONNXRUNTIME_NODE_INSTALL=skip
RUN pnpm install --frozen-lockfile

# ---- Stage 3: Builder ----
FROM base AS builder

ARG ALLOWED_FRAME_ANCESTORS
ARG NEXT_PUBLIC_PERSISTENCE
ARG NEXT_PUBLIC_PERSISTENCE_TOKEN
ARG NEXT_PUBLIC_MAIC_EDITOR_ENABLED
ARG NEXT_PUBLIC_MAIC_EDITOR_RENDERER_ENABLED
ARG NEXT_PUBLIC_MAIC_PLAYBACK_RENDERER_ENABLED
ARG NEXT_PUBLIC_PI_CHAT_ENABLED
ARG NEXT_PUBLIC_SHOW_VOCATIONAL_TEST_UI
ARG NEXT_PUBLIC_ENABLE_VIDEO_EXPORT
ARG NEXT_PUBLIC_VIDEO_EXPORT_CTA_DESTINATION
ARG NEXT_PUBLIC_ENABLE_PPTX_IMPORT
ENV ALLOWED_FRAME_ANCESTORS=$ALLOWED_FRAME_ANCESTORS
ENV NEXT_PUBLIC_PERSISTENCE=$NEXT_PUBLIC_PERSISTENCE
ENV NEXT_PUBLIC_PERSISTENCE_TOKEN=$NEXT_PUBLIC_PERSISTENCE_TOKEN
ENV NEXT_PUBLIC_MAIC_EDITOR_ENABLED=$NEXT_PUBLIC_MAIC_EDITOR_ENABLED
ENV NEXT_PUBLIC_MAIC_EDITOR_RENDERER_ENABLED=$NEXT_PUBLIC_MAIC_EDITOR_RENDERER_ENABLED
ENV NEXT_PUBLIC_MAIC_PLAYBACK_RENDERER_ENABLED=$NEXT_PUBLIC_MAIC_PLAYBACK_RENDERER_ENABLED
ENV NEXT_PUBLIC_PI_CHAT_ENABLED=$NEXT_PUBLIC_PI_CHAT_ENABLED
ENV NEXT_PUBLIC_SHOW_VOCATIONAL_TEST_UI=$NEXT_PUBLIC_SHOW_VOCATIONAL_TEST_UI
ENV NEXT_PUBLIC_ENABLE_VIDEO_EXPORT=$NEXT_PUBLIC_ENABLE_VIDEO_EXPORT
ENV NEXT_PUBLIC_VIDEO_EXPORT_CTA_DESTINATION=$NEXT_PUBLIC_VIDEO_EXPORT_CTA_DESTINATION
ENV NEXT_PUBLIC_ENABLE_PPTX_IMPORT=$NEXT_PUBLIC_ENABLE_PPTX_IMPORT
ENV ALLOWED_FRAME_ANCESTORS=$ALLOWED_FRAME_ANCESTORS

COPY --from=deps /app/node_modules ./node_modules
COPY --from=deps /app/packages ./packages
COPY . .
COPY --from=deps /app/public/vendor ./public/vendor

RUN pnpm build

# ---- Stage 4: Runner ----
FROM node:22-alpine AS runner

WORKDIR /app

ENV NODE_ENV=production
ENV HOSTNAME=0.0.0.0
ENV PORT=3000

# 同上,换 alpine 源
RUN sed -i 's|dl-cdn.alpinelinux.org|mirrors.aliyun.com|g' /etc/apk/repositories
RUN apk add --no-cache libc6-compat cairo pango jpeg giflib librsvg

RUN addgroup --system --gid 1001 nodejs && \
    adduser --system --uid 1001 nextjs

COPY --from=builder /app/public ./public
COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/.next/static ./.next/static

USER nextjs

EXPOSE 3000

CMD ["node", "server.js"]
