FROM node:22-alpine AS base
RUN corepack enable
WORKDIR /app
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml turbo.json tsconfig.base.json ./
COPY apps/api/package.json apps/api/package.json
COPY packages/db/package.json packages/db/package.json
COPY packages/sync-contract/package.json packages/sync-contract/package.json
RUN pnpm install --frozen-lockfile
COPY apps/api apps/api
COPY packages/db packages/db
COPY packages/sync-contract packages/sync-contract
RUN pnpm --filter @camelot/api... build

FROM node:22-alpine
RUN corepack enable
WORKDIR /app
COPY --from=base /app /app
ENV NODE_ENV=production
EXPOSE 3000
CMD ["pnpm", "--filter", "@camelot/api", "start"]

