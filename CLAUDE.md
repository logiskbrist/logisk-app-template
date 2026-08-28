# Working in this repo — for AI agents

You are helping a developer on an app deployed to Logiskbrist's managed platform. This document is the ground truth for what the platform does automatically, what you should do, and what you must not touch.

## The one paragraph

The customer pushes code, you help write it, and the platform deploys it. Every commit to `main` becomes production. Every push to any other branch becomes a preview environment with its own URL. Secrets live in Azure Key Vault and reach the app as env vars — never write them to git. Databases (if present) are provisioned and migrated by the app itself via Prisma; the platform provides one Postgres server, the app manages the databases on it. You don't run `kubectl`, you don't manage YAML, you don't touch Terraform. You edit code, push code, and — when needed — invoke six well-defined slash commands.

## Do not ask permission for derivable choices

The customer has limited technical background and hired an AI to make defensible defaults, not to be a menu. Configuration values with an obvious right answer must be picked and set without a "which do you want?" prompt. Ask only when the answer requires human judgement (Stripe live vs test key, is this the production Slack channel, what colour the logo should be).

Derivable and NOT worth asking about:

| Value | Derive as |
|---|---|
| `PGDATABASE` | **Per-preview isolation is the default.** Derived from `HOSTNAME` in the Dockerfile CMD — prod pods land on `<repo>` (underscored), preview pods on `<repo>_pr_<N>`. Signup on a preview never leaks to prod. Reaped when the PR closes. |
| `BETTER_AUTH_SECRET` (better-auth) | `openssl rand -base64 32`. `/set-secret` it once, don't ask. Use `BETTER_AUTH_SECRET` — the library reads that first and its error messages name it explicitly. `AUTH_SECRET` also works but confuses agents when errors mention BETTER_AUTH_SECRET. |
| `APP_NAME` | The repo name. `/set-secret` it if the app renders it in UI. |
| One-DB vs per-preview DB | **Per-preview.** Same rule as above — the derivation is in the Dockerfile CMD, no thought required. |
| Auth library | `better-auth`. |
| Which router | Server Actions + App Router (Next.js 15's default). |

If you're about to write a menu asking the developer to pick between two acceptable defaults, don't. Pick the one the docs recommend and keep going. The developer can override it later with a one-line change or `/set-secret` call.

Only stop and ask when:
- A value maps directly to a user-facing choice (business logic, branding, workflow).
- You've found a real bug or stale claim in this document (see the "known stable versions" rule).
- The user's request is genuinely ambiguous about *what* they want built.

## Tech stack — what to use

The platform runs Docker containers on a shared k3s cluster (`prod-01`, a Logisk Brist-managed server in Sandefjord — not Azure/AKS). **Everything you build must:**

1. Build into a Docker image (a `Dockerfile` at repo root, `pnpm install --frozen-lockfile` compatible).
2. Deploy through the platform's CI. **No hosted deploy platforms** — no Vercel, no Netlify, no Railway, no Fly, no Cloudflare Pages. If it doesn't produce a Docker image, it doesn't ship.
3. Run locally with `docker build && docker run` for debugging.

**Reference stack (new apps) vs. platform contract (all apps).** The template ships as **Next.js 15 App Router** and every app created with `/new-app` should stay that way — it's the tested, prescribed setup this document is written around. But the cluster contract is smaller than the template: any Docker image that serves HTTP on a known port with a `/health`-style endpoint runs fine. `/onboard-app` uses that to adopt existing repos (Express, Fastify, Vite+backend, plain Node) without rewriting them onto Next.js.

For everything below in this document, assume Next.js unless you're inside an `/onboard-app`ed repo — in which case the platform-glue sections (workflows, manifests, secrets, previews) still apply but the code-level guidance (Server Actions, App Router routes, `lib/prisma.ts` singleton) is aspirational, not mandatory.

### Known stable versions (last validated 2026-07-09)

The platform's conventions depend on specific major versions. Newer majors may have shifted APIs in ways the platform docs haven't caught up to. When you `pnpm add` a dep listed below, respect the pin. If you think a newer major is worth adopting, tell the developer explicitly — don't silently downgrade or work around API changes.

| Tool | Pin | Why pinned |
|---|---|---|
| Node | `24.x` | `node:24-slim` Dockerfile base; platform tested against Node 24 LTS. |
| pnpm | `10.x` | `packageManager` field; `--frozen-lockfile` behavior. |
| Next.js | `^15` | App Router. 16+ not yet validated. |
| React | `^19` | Server Components; matches Next.js 15's expected React major. |
| Prisma | `^7` | 7.x moved connection config to `prisma.config.ts`. Docs below assume 7.x. If you see docs referencing `datasource { url = env(...) }` in `schema.prisma`, they're stale — that's 6.x. |
| TypeScript | `^5.6` | Next.js 15 compatibility. |

**If a pin is more than 6 months old and you're about to work around a breaking change caused by a newer major, stop and flag it to the developer.** The platform maintainer needs to know so they can re-validate and bump the pin explicitly. Silent workarounds accumulate into invisible tech debt.

### What the template ships as

- **Next.js 15+ App Router**, TypeScript strict.
- **Node 24 (`node:24-slim`)**, pnpm 10 via corepack (`packageManager: pnpm@10.15.0`).
- `app/page.tsx` — placeholder home page.
- `app/api/health/route.ts` — `{ status: 'ok', tag }`, used by kubelet probes and by the preview/prod verification (see §Publishing).
- `app/api/env-demo/route.ts` — diagnostic showing which env vars are populated (no values).
- `test/health.test.ts` + `vitest.config.ts` — the default smoke test. Runs standalone locally, and against the deployment when `BASE_URL` is set.
- `next.config.ts` — no `output: 'standalone'`. Standalone strips node_modules and breaks `prisma migrate deploy` at container start (Prisma CLI is a devDep binary that Next's tracer doesn't see). The Dockerfile copies the full `node_modules` from the build stage instead.
- **Port 3000** (Next.js default), matched by the manifests.

Required `package.json` scripts (already present):
```json
"dev": "next dev",
"build": "next build",
"start": "next start",
"test": "vitest run"
```

Extend it. Don't replace the shell.

### Databases

- **Prisma 7** with `@prisma/client` when the app needs a database. Full setup in §Databases below. Prisma 7 requires `prisma.config.ts` — docs referencing `datasource { url = env(...) }` inside `schema.prisma` are 6.x and won't work.
- **PostgreSQL** by default — the platform provides `pg-<customer>` and every app in the customer's namespace gets Postgres connection env vars for free (see §Databases).

### Cache + queues

- **Redis** in-namespace at `redis:6379`.
- **ioredis** for the client.
- For background jobs, use **BullMQ**. Its worker process runs inside your Next.js pod or (recommended for long-running jobs) as a separate `route.ts` handler invoked by a k8s CronJob spec you add to `manifests/base/`.

### Auth (when needed)

- **`better-auth`** for authentication. Self-hosted, Prisma-native, App Router-friendly. Use `better-auth/adapters/prisma` for the DB adapter. Auth.js (`next-auth`) is fine for existing apps but not the default for new ones on this platform.
- **`@casl/prisma`** for authorization rules.
- **`@node-rs/argon2`** for password hashing. **Do NOT install the plain `argon2` package** — it compiles native code via `node-gyp` and would require `python` + `build-essential` added to `node:24-slim` to build in Docker. `@node-rs/argon2` ships prebuilt binaries and just works.

#### BETTER_AUTH_SECRET is a hard precondition — set it BEFORE the first pod boots

Better Auth's `create-context.mjs` calls `validateSecret`, which throws `BetterAuthError` when the secret is the built-in default and `NODE_ENV=production`. That crashes every request that imports `auth`. `/api/health` still answers 200 (it doesn't import auth), so the pod looks healthy while the app is dead.

Order matters:
1. **First**: `openssl rand -base64 32 | xargs -I{} gh workflow run set-secret.yaml -f name=BETTER_AUTH_SECRET -f value={}` — no need to ask the developer, the value is random.
2. Wait for the k8s Secret to sync. The template's ExternalSecret has `refreshInterval: 1m` so this is normally quick, but you can force it: `kubectl annotate es <app>-secret force-sync=$(date +%s) -n <ns>` — then `kubectl rollout restart deploy/<app> -n <ns>` so a fresh pod picks up the env var.
3. **Then** push code that imports `auth`.

Use `BETTER_AUTH_SECRET`, not `AUTH_SECRET`. Better Auth's error messages name `BETTER_AUTH_SECRET` explicitly, and the library also reads `AUTH_SECRET` as a fallback — but the mismatch between "I set AUTH_SECRET" and "please set BETTER_AUTH_SECRET" confuses agents unnecessarily.

#### Behind an ingress that terminates TLS

Every app on this platform runs behind ingress-nginx which terminates TLS — the pod itself serves plain HTTP on port 3000. Better Auth's CSRF origin check compares the request's `Origin: https://…` header to a URL it derives from `request.url`, which is `http://…`. The check fails and every sign-in POST 4xxs. Two lines fix it, and both are needed:

```ts
export const auth = betterAuth({
  advanced: { trustedProxyHeaders: true },   // MUST be nested — top-level key type-checks but is silently ignored
  baseURL: {
    allowedHosts: [
      APP_HOST,                     // <app>.<customer-domain>
      `*-${APP_HOST}`,              // <branch>-<app>.<customer-domain> (previews)
      'localhost:3000',
    ],
  },
  // ...adapter, plugins, etc.
})
```

The `*-` wildcard is what covers per-branch preview hostnames. This is universal for every app on the platform — if you're adding Better Auth, add these two lines.

**Do NOT write `trustedProxyHeaders: true` at the top level of `betterAuth({...})`.** It type-checks, `next build` passes, sign-in requests look like they work — because a dynamic `baseURL` already defaults proxy trust to `true`. But Better Auth 1.6.23's only runtime read is `options.advanced?.trustedProxyHeaders`, so the top-level key is silently ignored. The first time you turn `baseURL` static (or upstream changes the default), CSRF starts rejecting every sign-in and you'll wonder why. Verify by grep'ing the installed `dist/` for how the option is actually **read**, not just by whether the build passes.

### Observability

- Structured JSON logs to stdout — the cluster's Loki parses JSON.
- Prometheus metrics on `/api/metrics` when the app has meaningful counters — the cluster's Prometheus scrapes namespace pods automatically.

### What NOT to use

- **No hosted deploy platforms.** Vercel, Netlify, Railway, Fly, Cloudflare Pages, Render — everything runs on the shared cluster.
- **No `.env` files.** Config comes from Key Vault via `/set-secret`.
- **No dotenvx in the container.** Env vars come from `envFrom` on the Deployment; there's nothing to decrypt.
- **No custom Dockerfile base images.** Stick with `node:24-slim`.
- **No `nodemon`, no `pm2`.** k8s manages the process; use `next dev` locally.
- **No Pages Router.** New apps are App Router only. Don't mix.
- **No `getServerSideProps` / `getStaticProps`.** Those belong to Pages Router. Use Server Components + `revalidate` in App Router.

## What runs automatically

| Trigger | What happens |
|---|---|
| Push to `main` | GitHub Actions builds image → pushes to GHCR → bumps `manifests/prod/kustomization.yaml` → ArgoCD syncs to prod namespace. Live at `https://<app>.<customer-domain>/`. |
| …then, still on `main` | `verify-prod` polls `https://<app>.<customer-domain>/api/health` until it reports the tag just shipped. **If it never does, prod is automatically rolled back to the previous tag and an issue is opened: «Publisering rullet tilbake: `<app>`».** A failed deploy does not stay live. |
| Push to any non-main branch | Draft PR opens automatically → build/push image → bumps `manifests/preview/kustomization.yaml` → ArgoCD creates a preview Application. Live at `https://<branch-slug>-<app>.<customer-domain>/`. |
| PR opened / updated | `checks.yaml` runs two required checks: **`ai-review`** reads the diff and comments findings on the PR (skipped when the org has no `ANTHROPIC_API_KEY`), and **`verify-preview`** waits for the preview to actually serve this PR's tag, then runs `pnpm test` against it. |
| PR opened / updated, **critical apps only** | `review-gate.yaml` checks the diff for sensitive changes and, if it finds one, blocks the merge until `@godtbrod/logiskbrist-reviewers` approves. Non-critical apps: no-op. Re-runs on review submission, so an approval unblocks without a new push. |
| Close/merge a PR | Preview Application and its DB (if any) are removed within ~1 minute. |
| Idle 7 days | The stale-preview reaper closes the PR, which triggers teardown. Reopen the PR to restore. |

## Your slash commands

Six skills defined in `.claude/skills/`. Prefer these over ad-hoc shell commands — they know the naming rules, safety checks, and follow-ups.

| Command | Purpose |
|---|---|
| `/set-secret` | Add or update an env var (goes to Key Vault, appears on the pod) |
| `/delete-secret` | Remove one |
| `/list-secrets` | Show what's currently set for this app |
| `/open-preview` | Guide for opening a preview (usually just: push the branch) |
| `/check-deploy` | Where's the current deploy? Actions + ArgoCD status |
| `/rollback` | Roll production back to a previous image tag |

Read the `SKILL.md` in each folder before invoking — they contain the exact commands and follow-up steps.

## Publishing, review and the critical-app gate

### How a change goes live

1. **Branch.** Never commit to `main` and never push to `main` directly. Work on a branch — that's what produces a preview and a PR to review.
2. **Preview.** Pushing the branch opens a draft PR and deploys a preview at `https://<branch-slug>-<app>.<customer-domain>/`.
3. **Checks.** `ai-review` comments on the diff; `verify-preview` waits until the preview serves this exact image tag and then runs `pnpm test` against it. On critical apps, `review-gate` may also require a Logisk Brist approval. These are the required status checks.
4. **Merge.** Only once the checks are green.
5. **Prod verify.** The merge builds, deploys, and then `verify-prod` confirms prod is serving the new tag. If it isn't, the platform rolls prod back to the previous tag by itself and opens an issue «Publisering rullet tilbake: `<app>`».

### One piece of work = one branch = one preview («testversjon»)

Every preview is shareable — a colleague can open the URL and see the work without anything being merged. So keep pieces of work apart:

- **When a new request comes in, decide whether it belongs to the branch you're on or is a new thing.** Same thing («ja, og legg til en knapp for …» while you're mid-feature): keep going. New thing (a different feature, an unrelated fix, something they want to show separately): start a new branch from a fresh `main`. If it's genuinely unclear and there is more than one candidate, ask one plain question — «Er dette en ny ting, eller en del av det vi holder på med (*eksport til Excel*)?» — never with the words branch/PR.
- **Naming.** `feature/<short-slug-of-what-they-said>` or `fix/…`; PR title in Norwegian describing the change (the user sees that title as the testversjon's name). Preview URL slug = branch name lowercased, non-alphanumerics → `-`, max 50 chars.
- **Tell the user, in their words:** «Jeg lager en egen testversjon for dette: *eksport til Excel*. Adressen kommer om noen minutter — den kan du sende til kolleger.» When it's live, give the URL once.
- **Switching** («jobb videre på svinnrapporten»): commit or stash what's open, check out that branch, say which testversjon you're now in.
- **Several at once is normal.** «Hva jobber vi på?» → open PRs as a list: name, URL, status (*under arbeid* / *klar til publisering* / *venter på godkjenning fra Logisk Brist*).
- **After a publish**, other open branches keep going; rebase/merge `main` into them quietly if they need it. Previews idle for 7 days are closed by the platform — warn the user the day before, reopen on request.

**When the user says «publiser» (or "ship it", "legg det ut"), use the org-level `/publish` skill.** It drives this flow end to end — pushes the branch, waits for the checks, merges, and watches the prod verification. Don't improvise it with ad-hoc `git push` / `gh pr merge` calls, and never push to `main` to skip the checks.

### The critical-app gate

Apps marked critical (repo topic `logisk-critical`, or the org property `criticality=critical`) require an approving review from `@godtbrod/logiskbrist-reviewers` when the diff touches a sensitive area:

- **Authentication and authorization** — sign-in, sessions, roles, permission checks.
- **Database** — schema changes, migrations, anything destructive.
- **Money** — payments, invoicing, pricing, refunds.
- **Platform glue** — `.github/workflows/**`, `manifests/**`, `Dockerfile`.
- **Secrets and egress** — secret handling, and new outbound network calls to third parties.

Ordinary apps never see this gate; it reports success immediately.

**Never try to route around this gate.** Don't split a sensitive change into innocuous-looking commits, don't move sensitive code to dodge the path patterns, don't remove the `logisk-critical` topic, don't edit or disable `review-gate.yaml`, and don't merge with admin rights. If the gate blocks and the user is in a hurry, say so plainly and tell them to ask Logisk Brist for a review — that is the fix. The gate exists because a bad change on these apps costs real money or real trust.

### Making the checks catch more

Two levers, both worth using as the app grows:

- **`/api/health` reports `tag`** — the image tag the running container was built from (`IMAGE_TAG`, baked in by the build). This is how `verify-preview` and `verify-prod` distinguish "the new version is live" from "the old pod is still answering". Keep the field.
- **`pnpm test` runs against the preview.** `verify-preview` sets `BASE_URL` to the preview URL, so tests can hit a real deployment. Add unit tests under `test/**/*.test.ts`, or Playwright specs under `verify/` that drive `BASE_URL` end to end. Every test you add there is a check that runs before the customer sees the change — this is the highest-leverage place to add safety on this platform.

## What you can freely edit

- `app/**` — pages, layouts, API routes. This is where 99% of changes go.
- `components/**`, `lib/**`, or any folder you create — organize as the app grows.
- `package.json` — add dependencies. Do NOT change the `name` field by hand — the app name is baked into the image, manifests, secret naming and database name; a rename is done with the org-level `/rename-app` skill, which changes all of them together.
- `Dockerfile` — refine build. Preserve the `pnpm install --frozen-lockfile`, `pnpm build`, and the runner-stage COPY of `node_modules` + `.next`. Multi-stage is preserved by default.
- `next.config.ts` — add config as needed. Do NOT set `output: 'standalone'`; the runtime image needs the full `node_modules` for `prisma migrate deploy` at container start.
- `README.md` — customer-facing docs. This file (`CLAUDE.md`) is separate.

## What you should not touch

- `manifests/base/external-secret.yaml` — the KV-name pattern is coupled to the workflows. Changing it silently breaks env-var sync.
- `manifests/base/deployment.yaml` `envFrom:` — the Secret name here is coupled to the ExternalSecret target.
- `manifests/base/service.yaml` selector and `manifests/base/deployment.yaml` pod labels — the `env: prod` label distinguishes prod pods from preview pods and the preview AppSet patches it. Removing it breaks the isolation.
- Port `3000` in the manifests — that's Next.js's default; the probes and Service targetPort all point at it. If you change the app to a different port, update all three manifests together.
- `.github/workflows/*` — thin callers of reusable workflows in `<your-org>/logisk-platform-workflows`. Edits usually mean you're trying to work around the platform rather than with it.
- `.github/workflows/checks.yaml` and `.github/workflows/review-gate.yaml` in particular — these are the required checks and the Logisk Brist review gate. Weakening them is never the answer to a red check; fix the change instead.
- The `tag` field on `/api/health` — `verify-preview` and `verify-prod` use it to tell a live new version from a stale pod. Drop it and both verifications start timing out (and prod starts rolling itself back). Add fields next to it freely.
- The repo topic (`logisk-platform`) — it's how ArgoCD discovers this repo. Removing it silently orphans the app from the platform. Same for `logisk-critical` where it's set: that one marks the app as critical, and removing it disables the review gate.

If you think you *need* to touch one of these, stop and ask the developer.

## Secrets — the golden rule

**Never write secret values to git.** Not in code, not in `.env`, not in comments, not in commit messages.

Env vars appear on the pod via ExternalSecrets Operator, which mirrors Azure Key Vault into a k8s Secret consumed by `envFrom` on the Deployment. The pipeline:

1. AI runs `/set-secret NAME VALUE`.
2. Workflow authenticates to Azure via OIDC (federated cred, no stored password).
3. `az keyvault secret set --name <app>-prod-<NAME-HYPHENIZED>` — value is masked in logs.
4. ExternalSecret picks it up (`refreshInterval: 1m` on the shipped template, or immediately if force-synced).
5. Env var appears on the running pod. Trigger a rollout so the new value takes effect — `/check-deploy` shows how (there is no Reloader on the cluster).

**Prod and preview are fully separated — no inheritance between them.** Each pod reads only its own env's vars:

| KV name | Env var on… | Who sets it |
|---|---|---|
| `<app>-prod-<NAME>` | prod pods | `/set-secret NAME VALUE` |
| `<app>-preview-<NAME>` | preview pods | `/set-secret NAME VALUE -f preview=true` |
| `shared-prod-<NAME>` | all prod pods, every app | platform, once per customer (e.g. `shared-prod-PGHOST`) |
| `shared-preview-<NAME>` | all preview pods, every app | platform, once per customer |

Setting a `<app>-prod-*` value does **not** propagate to previews, and vice versa. If a preview needs a var, set the `<app>-preview-*` variant explicitly — otherwise the preview pod boots without it and any code path that reads it will 500. Same story for the `shared-*` split at the platform level.

This is deliberate. Previews should never accidentally hit prod Stripe / prod SMS / prod anything just because someone forgot to override.

**Bootstrap a preview quickly.** When you want a preview to behave "just like prod except X," the fastest path is:

```bash
# 1. Copy every prod value into its preview counterpart (safe defaults; then trim).
az keyvault secret list --vault-name lb-kv-<customer> --query "[?starts_with(name, '<app>-prod-')].name" -o tsv \
  | while read k; do
      v=$(az keyvault secret show --vault-name lb-kv-<customer> --name "$k" --query value -o tsv)
      az keyvault secret set --vault-name lb-kv-<customer> --name "${k/<app>-prod-/<app>-preview-}" --value "$v" >/dev/null
    done

# 2. Overwrite the risky ones with test-mode values.
gh workflow run set-secret.yaml -f name=STRIPE_KEY -f value='sk_test_...' -f preview=true
gh workflow run set-secret.yaml -f name=TWILIO_AUTH_TOKEN -f value='<test token>' -f preview=true

# 3. Delete anything you specifically want previews NOT to have.
gh workflow run delete-secret.yaml -f name=NETS_CHECKOUT_KEY -f preview=true    # forces test-mode fallback in code
```

Env var names must match `^[A-Z_][A-Z0-9_]*$`. Underscores map to hyphens in Key Vault and back to underscores on the way out.

**Reading env vars in Next.js:**
- **Server code** (Server Components, `route.ts` handlers, Server Actions): `process.env.NAME` — read at runtime, always fresh.
- **Client code** (Client Components, `'use client'`): only `NEXT_PUBLIC_*` prefixed vars are exposed, and they're **baked into the client bundle at `next build`** — set them with `/set-secret` BEFORE the first push, then again anytime you change them and want the change to reflect in the client.

## Databases — the app's job (fully)

The platform provides **one Postgres server per customer** (`pg-<customer>`). Everything above that layer — creating databases, running migrations, seeding, isolating per-preview data — is the app's responsibility.

Prisma **7.x** is the pinned major (see the versions table above).

### What the platform gives you

`PGHOST`, `PGUSER`, `PGPASSWORD`, `PGPORT` land on the pod automatically — populated once per customer via KV secrets `shared-prod-*` (for prod pods) and `shared-preview-*` (for preview pods, mirrored from the same Postgres server by convention). Every app inherits them without any `/set-secret` calls. Do NOT `/set-secret` them; do NOT commit them; do NOT rebuild the plumbing.

### The three files you need

**1. `prisma/schema.prisma`** — no `url` field on the datasource (that moved to `prisma.config.ts` in v7). The `output` field on the generator is now required.

```prisma
datasource db {
  provider = "postgresql"
}

generator client {
  provider = "prisma-client"
  // Resolved relative to this schema file (prisma/schema.prisma), so
  // `../generated/prisma` lands at the repo root. Matches the singleton
  // import below (@/generated/prisma/client → tsconfig maps @/* → ./*).
  output   = "../generated/prisma"
}

model User {
  id    Int    @id @default(autoincrement())
  email String @unique
}
```

**2. `prisma.config.ts`** — at project root:

```ts
import "dotenv/config";
import { defineConfig, env } from "prisma/config";

export default defineConfig({
  schema: "prisma/schema.prisma",
  migrations: { path: "prisma/migrations" },
  datasource: { url: env("DATABASE_URL") },
});
```

The Prisma CLI reads this at `prisma migrate deploy` time; the `env()` helper resolves against `process.env` at run time (populated by our envFrom).

**3. `Dockerfile` CMD** — derive `PGDATABASE` from `HOSTNAME` so previews get their own database, then construct `DATABASE_URL`, then migrate, then start. Replace `<repo-name>` (hyphens allowed, for pattern matching HOSTNAME) and `<repo_name>` (underscores only, for the Postgres identifier) with your actual repo name:

```dockerfile
CMD ["sh", "-c", "\
  case \"${HOSTNAME:-}\" in \
    <repo-name>-pr-*) \
      PR=${HOSTNAME#<repo-name>-pr-}; PR=${PR%%-*}; \
      PGDATABASE=\"<repo_name>_pr_${PR}\" ;; \
    *) \
      PGDATABASE=\"<repo_name>\" ;; \
  esac && \
  export PGDATABASE && \
  export DATABASE_URL=\"postgresql://${PGUSER}:${PGPASSWORD}@${PGHOST}:${PGPORT}/${PGDATABASE}?sslmode=require\" && \
  pnpm prisma migrate deploy && \
  pnpm start"]
```

Prod pod hostnames look like `app-<hash>-<random>` and hit the `*)` case → `<repo_name>`. Preview pod hostnames look like `<repo-name>-pr-<N>-app-<hash>-<random>` and hit the `<repo-name>-pr-*` case → `<repo_name>_pr_<N>`.

Postgres identifiers with hyphens work only when quoted, and Prisma migration files can't reliably quote the DB name in every context — using underscores throughout avoids the whole class of problem.

In the **build stage**, add `pnpm prisma generate` before `pnpm build`, AND placeholders for the two env vars that get resolved at load-time (never evaluated for real at build; they exist only to satisfy config parsing):

```dockerfile
# prisma.config.ts resolves env("DATABASE_URL") eagerly, even for `prisma generate`.
# Better Auth logs a scary "secret validation" error if BETTER_AUTH_SECRET is missing
# during Next.js's build-time prerender. Both dummies stay in the build stage — they
# never reach the runner image.
ENV DATABASE_URL=postgres://x@x:5432/x
ENV BETTER_AUTH_SECRET=build-time-only

RUN pnpm prisma generate
RUN pnpm build
```

In the **runner stage**, copy the Prisma pieces AND the ensure-db script + generated client:

```dockerfile
COPY --from=build /usr/src/app/prisma ./prisma
COPY --from=build /usr/src/app/prisma.config.ts ./
COPY --from=build /usr/src/app/generated ./generated
COPY --from=build /usr/src/app/scripts ./scripts
```

The template ships with a **non-standalone** Next.js runtime — the full `node_modules` is copied into the runner image so `pnpm prisma migrate deploy` (a devDependency binary) is available at container start. If you switch to `output: 'standalone'` in `next.config.ts`, migrations break because Next.js's file tracer only carries deps your app code actually imports, and nothing imports the `prisma` CLI. Leave standalone off.

### PGDATABASE — per-preview by default, per-app for prod

**Default: previews get their own database, prod uses one.** The Dockerfile CMD above derives the name from `HOSTNAME`:

- Prod pod (`app-<hash>-<random>`) → `<repo_name>` (a single DB shared by all prod pods for this app).
- Preview pod (`<repo>-pr-<N>-app-<hash>-<random>`) → `<repo_name>_pr_<N>` (a DB per PR).

Signups, test data, destructive migrations on a preview never touch prod. When the PR closes, the platform's `preview-cleanup.yaml` workflow drops the preview DB — see `.github/workflows/preview-cleanup.yaml` in the template. **Do not ask the developer which isolation model to use — pick per-preview.**

Prisma's `migrate deploy` will fail if the database doesn't exist yet. Add a tiny pre-migrate script (`scripts/ensure-db.mjs`) that creates the DB if missing. **Postgres has no `CREATE DATABASE IF NOT EXISTS`** — probe first, then create, and tolerate SQLSTATE `42P04` in case two pods race on a cold start:

```js
// scripts/ensure-db.mjs
import { Client } from 'pg'
const name = process.env.PGDATABASE
const c = new Client({
  host: process.env.PGHOST, port: Number(process.env.PGPORT),
  user: process.env.PGUSER, password: process.env.PGPASSWORD,
  database: 'postgres', ssl: { rejectUnauthorized: false },
})
await c.connect()
const { rows } = await c.query('SELECT 1 FROM pg_database WHERE datname = $1', [name])
if (rows.length === 0) {
  try { await c.query(`CREATE DATABASE "${name}"`) }  // quoted — repo names contain hyphens
  catch (e) { if (e.code !== '42P04') throw e }        // 42P04 = duplicate_database (race)
}
await c.end()
console.log(`db ${name} ready`)
```

Wire it into the Dockerfile CMD:

```dockerfile
CMD ["sh", "-c", "\
  export PGDATABASE=\"${PGDATABASE:-<repo-name>}\" && \
  node scripts/ensure-db.mjs && \
  export DATABASE_URL=\"postgresql://${PGUSER}:${PGPASSWORD}@${PGHOST}:${PGPORT}/${PGDATABASE}?sslmode=require\" && \
  pnpm prisma migrate deploy && \
  pnpm start"]
```

### Opt-out: shared database for cache-only apps

Very rare. Only if the app has literally no user-facing state and previews-with-shared-data would be fine — an internal read-only dashboard against prod data, a caching proxy. Change the Dockerfile CMD to hardcode `PGDATABASE`:

```dockerfile
export PGDATABASE=\"<repo_name>\"
```

Note that this removes the whole reason previews exist as isolated environments. If you're tempted, ask the developer explicitly first (this is a business decision, not a derivable choice).

### Reading Prisma from Next.js

Prisma 7's generated `PrismaClientOptions` is a discriminated union that requires either `adapter` or `accelerateUrl`. `new PrismaClient()` fails typecheck. Use the pg driver adapter:

```ts
import { PrismaClient } from '@/generated/prisma/client'
import { PrismaPg } from '@prisma/adapter-pg'

const globalForPrisma = globalThis as unknown as { prisma?: PrismaClient }

export const prisma =
  globalForPrisma.prisma ??
  new PrismaClient({
    adapter: new PrismaPg({ connectionString: process.env.DATABASE_URL! }),
  })

if (process.env.NODE_ENV !== 'production') globalForPrisma.prisma = prisma
```

`pnpm add @prisma/adapter-pg pg` and `pnpm add -D @types/pg`. Use `prisma` in Server Components, Server Actions, and `route.ts` handlers. Never import from a Client Component.

### Runtime notes

- Migrations run on every pod boot. `prisma migrate deploy` is fast (~200ms) when there's nothing to do. Broken migrations crash-loop the pod — use `/check-deploy` to inspect logs.
- `prisma.config.ts` resolves `env("DATABASE_URL")` eagerly at load time — even `prisma generate` fails without it set. The Dockerfile snippet above uses a `postgres://x@x:5432/x` dummy for the build stage; that dummy stays out of the runner image.
- `prisma migrate diff` renamed `--to-schema-datamodel` → `--to-schema` in v7. Rare, but bites if you generate diffs from CI.

## Server Actions — one rule that bites

Files marked `'use server'` may only export async functions. **Any other export is a build error.**

```ts
// app/actions.ts
'use server'

export async function createPost(fd: FormData) { /* ... */ }   // ok
export type PostInput = { title: string; body: string }         // ok — types erase
export const MAX_POST_LENGTH = 500                              // BUILD ERROR
```

Move shared constants to a plain module (e.g. `lib/constants.ts`) and import them from both the action and any component that needs them.

## Placeholder substitution (first fork only)

If you see `PLACEHOLDER_APP`, `PLACEHOLDER_CUSTOMERORG`, `PLACEHOLDER_CUSTOMER_DOMAIN`, or `PLACEHOLDER_HOST` in files under `manifests/`, this repo hasn't been customized yet. See `README.md` for the sed one-liner. Do this once, commit, then never see these placeholders again.

## When something breaks

1. `/check-deploy` first — surfaces the most common failures (Actions failed, ArgoCD OutOfSync, ImagePullBackOff, CrashLoopBackOff).
2. Actions logs — click through from `gh run watch --repo <this-repo>`. Broken workflows are almost always caller mistakes, not platform bugs.
3. If ArgoCD reports OutOfSync but Actions succeeded, the kustomize manifest is malformed. Diff the last known-good commit.
4. If pods crash on start with DB errors, the migration is broken — inspect `pnpm prisma migrate deploy` locally first.
5. If secrets don't appear in `/api/env-demo`, the ExternalSecret refresh hasn't fired yet. Wait or force-sync (see `/check-deploy`).

Never edit YAML in-place to work around a failure. Fix the root cause and let the platform reconverge.

## What this repo depends on (informational)

You don't manage these, but knowing they exist helps you reason about failures:

- `<your-org>/logisk-platform-workflows` — the reusable workflows your `.github/workflows/*` call. Lives in your own GitHub org, seeded during onboarding.
- The customer's namespace on the shared k3s cluster (`prod-01`, Sandefjord) — where prod and preview pods live.
- `lb-kv-<customer-short-slug>` — the Azure Key Vault storing your env-var values (e.g. `lb-kv-gb` for godtbrod). Key Vault stays in Azure even though the cluster doesn't.
- `pg-<customer>` — the Postgres server the platform provides. Your DB names are just databases inside it.
- ArgoCD on the cluster — a `<customer>-main-appset` (SCM Provider, by `logisk-platform` topic) creates the prod Application; a `<customer>-preview-appset` (SCM × PullRequest) does previews per PR.

## Style

Be concise. Explain intent, not mechanics — the platform handles mechanics. When the developer asks "how do I add a secret?", the answer is `/set-secret NAME VALUE` and one sentence on where it goes, not a paragraph on Key Vault.
