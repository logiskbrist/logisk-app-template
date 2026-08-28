# syntax=docker/dockerfile:1

# ---- build ------------------------------------------------------------------
FROM node:24-slim AS build
WORKDIR /usr/src/app

COPY package.json pnpm-lock.yaml* .npmrc* ./
RUN corepack enable && corepack prepare pnpm@10.15.0 --activate \
    && pnpm install --frozen-lockfile

COPY . .

# When you add Prisma, add these BEFORE `pnpm build`:
#
#   # Dummy env vars — prisma.config.ts resolves DATABASE_URL eagerly at load time,
#   # and Better Auth logs a scary error during Next's prerender if AUTH_SECRET is
#   # missing. Both dummies stay in the build stage — they never reach the runner.
#   ENV DATABASE_URL=postgres://x@x:5432/x
#   ENV BETTER_AUTH_SECRET=build-time-only
#   RUN pnpm prisma generate
RUN pnpm build

# ---- run --------------------------------------------------------------------
# Non-standalone: full node_modules is copied so `prisma migrate deploy`
# (a devDependency binary) is available at container start. Image lands
# around 300 MB — worth it for the simpler mental model.
FROM node:24-slim AS runner
WORKDIR /usr/src/app

ENV NODE_ENV=production
ENV PORT=3000
ENV HOSTNAME=0.0.0.0

# Set by build-and-push.yaml as a docker build-arg. `/api/health` reports it as
# `tag`, which is how verify-preview and verify-prod know which version is live.
ARG IMAGE_TAG
ENV IMAGE_TAG=${IMAGE_TAG}

# openssl is not in node:24-slim. Prisma's query engine needs it for TLS to
# Azure Postgres (sslmode=require). Without it Prisma prints a "libssl not
# detected" warning and falls back to a bundled version that may fail on some
# hosts. ~4 MB added; worth it.
RUN apt-get update && apt-get install -y --no-install-recommends openssl \
    && rm -rf /var/lib/apt/lists/*

RUN corepack enable && corepack prepare pnpm@10.15.0 --activate

COPY --from=build /usr/src/app/node_modules ./node_modules
COPY --from=build /usr/src/app/.next ./.next
COPY --from=build /usr/src/app/public ./public
COPY --from=build /usr/src/app/package.json ./
# When you add Prisma, also copy:
#   COPY --from=build /usr/src/app/prisma ./prisma
#   COPY --from=build /usr/src/app/prisma.config.ts ./
#   COPY --from=build /usr/src/app/generated ./generated
#   COPY --from=build /usr/src/app/scripts ./scripts

EXPOSE 3000

# When you add Prisma, replace CMD with (see CLAUDE.md § Databases for the ensure-db.mjs script):
# Substitute <repo-name> (hyphens ok, matches HOSTNAME) and <repo_name> (underscores,
# Postgres identifier) with your repo name. Per-preview isolation: prod pods land on
# <repo_name>, preview pods on <repo_name>_pr_<N>.
#   CMD ["sh", "-c", "\
#     case \"${HOSTNAME:-}\" in \
#       <repo-name>-pr-*) PR=${HOSTNAME#<repo-name>-pr-}; PR=${PR%%-*}; PGDATABASE=\"<repo_name>_pr_${PR}\" ;; \
#       *) PGDATABASE=\"<repo_name>\" ;; \
#     esac && \
#     export PGDATABASE && \
#     node scripts/ensure-db.mjs && \
#     export DATABASE_URL=\"postgresql://${PGUSER}:${PGPASSWORD}@${PGHOST}:${PGPORT}/${PGDATABASE}?sslmode=require\" && \
#     pnpm prisma migrate deploy && \
#     pnpm start"]
CMD ["pnpm", "start"]
