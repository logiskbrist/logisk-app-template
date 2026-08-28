# logisk-app-template

Starter for a customer app deployed on Logiskbrist's shared k3s cluster (prod-01, Sandefjord). See [`../customer-paas-design.md`](../customer-paas-design.md) for the full design.

**AI agents: start with [`CLAUDE.md`](CLAUDE.md).** It has the platform overview, tech-stack guidance, invariants, and pointers to the slash-command skills under `.claude/skills/` (`/set-secret`, `/delete-secret`, `/list-secrets`, `/open-preview`, `/check-deploy`, `/rollback`). This README covers the human onboarding steps (placeholder substitution, first push); CLAUDE.md covers the ongoing workflow.

## What you get

- Minimal **Next.js 15 App Router + TypeScript** app with `/`, `/api/health`, and `/api/env-demo`. Port 3000.
- **Node 24 + pnpm 10** Dockerfile — multi-stage, copies the full `node_modules` from build to runner (not standalone; CLAUDE.md explains why).
- Full manifests for prod + preview overlays.
- GitHub Actions that compose reusable workflows from `<your-org>/logisk-platform-workflows` (lives in your own GH org, seeded during onboarding): build + deploy, AI review and preview verification on every PR, prod verification with automatic rollback, and the Logisk Brist review gate for critical apps.
- A **vitest** smoke test that runs standalone locally and against the live preview URL in CI.
- Secrets flow via ExternalSecrets Operator + Azure Key Vault — no dotenvx, no encrypted `.env` files in git.

## Layout

```
Dockerfile                          # node:24-slim + pnpm 10 + next build (non-standalone)
next.config.ts                      # no `output` key — see CLAUDE.md for why
package.json                        # Next.js 15, React 19, TypeScript, vitest
tsconfig.json
vitest.config.ts                    # node env, picks up test/**/*.test.ts
app/
  layout.tsx                        # root HTML skeleton
  page.tsx                          # home — "hello from <app>"
  api/health/route.ts               # kubelet probes + deploy verification; reports the image tag
  api/env-demo/route.ts             # shows which KV env vars are populated
test/
  health.test.ts                    # smoke test; hits BASE_URL when set, else the handler
manifests/
  base/
    deployment.yaml                 # envFrom: [app-secret] — populated by ExternalSecret
    service.yaml
    ingress.yaml                    # host set per environment
    external-secret.yaml            # dataFrom.find for prod AND preview KV prefixes
    kustomization.yaml
  prod/
    kustomization.yaml              # patches host + image tag
  preview/
    kustomization.yaml              # image tag only; ApplicationSet does host patching
.github/workflows/
  build.yaml                        # thin caller: build, deploy, verify prod (auto-rollback)
  checks.yaml                       # thin caller: AI review + preview verification on PRs
  review-gate.yaml                  # thin caller: Logisk Brist gate (critical apps only)
  set-secret.yaml                   # thin caller: workflow_dispatch → set-secret@v1
  delete-secret.yaml                # thin caller: workflow_dispatch → delete-secret@v1
```

## Substituting the placeholders

The template uses these placeholder tokens. Substitute them **once** after forking:

| Token | Replace with | Where it appears |
|---|---|---|
| `PLACEHOLDER_APP` | The app name (also the repo name), e.g. `web` | `manifests/**/*.yaml` |
| `PLACEHOLDER_CUSTOMERORG` | The customer's GitHub org, e.g. `acmeco` | `manifests/**/*.yaml` |
| `PLACEHOLDER_CUSTOMER_DOMAIN` | The customer's domain, e.g. `acme.no` | `manifests/prod/kustomization.yaml` |
| `PLACEHOLDER_HOST` | Untouched — replaced by kustomize patches | `manifests/base/ingress.yaml` |
| `PLACEHOLDER_TAG` | Untouched — bumped by CI | `manifests/prod/kustomization.yaml`, `manifests/preview/kustomization.yaml` |

Quick substitute:

```bash
APP=web
ORG=acmeco
DOMAIN=acme.no

find manifests .github -type f -name '*.yaml' -exec sed -i.bak \
  -e "s|PLACEHOLDER_APP|$APP|g" \
  -e "s|PLACEHOLDER_CUSTOMERORG|$ORG|g" \
  -e "s|PLACEHOLDER_CUSTOMER_DOMAIN|$DOMAIN|g" {} \;
find manifests .github -name '*.bak' -delete
```

The `.github/workflows/*.yaml` files reference `<your-org>/logisk-platform-workflows` — that repo lives in your own GH org, not Logiskbrist's. `PLACEHOLDER_CUSTOMERORG` is the substitution point.

Also update `package.json`'s `name` field and set the repo topic:

```bash
gh repo edit --add-topic logisk-platform
```

## First push

```bash
git add . && git commit -m "initial customization" && git push
```

Within ~2 minutes:
1. `build.yaml` builds the Docker image and pushes it to GHCR.
2. `bump-prod` sed-patches `manifests/prod/kustomization.yaml` and pushes back.
3. The ArgoCD SCM Provider ApplicationSet discovers the repo, creates `<app>-prod`, syncs it into the customer namespace.
4. cert-manager sees the Ingress and issues a Let's Encrypt cert via HTTP01 (~30-90s on first hit).
5. `verify-prod` polls `/api/health` until it reports the new tag. If it never does, it rolls the prod manifest back to the previous tag and opens an issue.

## Adding secrets

Never commit secrets to git. Set them with the workflow:

```bash
gh workflow run set-secret.yaml \
  -f name=STRIPE_KEY \
  -f value='sk_live_...'
```

Value goes straight to `lb-kv-<customer>` under the name `<app>-prod-STRIPE-KEY`. Within one hour (the ExternalSecret's refresh interval), `STRIPE_KEY` appears as an env var on the app pod. To force immediate sync:

```bash
kubectl annotate externalsecret -n <customer> app-secret \
  force-sync=$(date +%s) --overwrite
```

To override just for previews:

```bash
gh workflow run set-secret.yaml -f name=STRIPE_KEY -f value='sk_test_...' -f preview=true
```

The preview pod sees `sk_test_...`; the prod pod keeps seeing `sk_live_...`. Same env var name.

Reload on secret change is *not* automatic — either install [Reloader](https://github.com/stakater/Reloader) in the customer namespace, or trigger a rollout manually with `kubectl rollout restart deploy/app`.

## Previews

Every non-main branch gets a preview at `<branch-slug>-<app>.<customer-domain>`. Just push the branch — the `open-draft-pr` workflow opens a draft PR, the ArgoCD PullRequest generator sees it, and a preview Application appears within ~60 seconds.

Preview cleanup: closing or merging the PR removes the preview immediately. Idle PRs are auto-closed after 7 days (see `stale-preview-reaper` in the platform-workflows repo).

## Adding a database

If your app needs Postgres:

1. Add Prisma: `pnpm add prisma @prisma/client`.
2. Create `prisma/schema.prisma` and `prisma.config.ts` — see the Databases section of [`CLAUDE.md`](CLAUDE.md) for exact contents. Prisma 7 keeps `datasource.url` in `prisma.config.ts`, NOT in `schema.prisma`.
3. Update the Dockerfile: add `RUN pnpm prisma generate` before `pnpm build`, add the runner-stage COPYs for `prisma`, `prisma.config.ts`, `generated`, `scripts`, and change the CMD to `sh -c 'ensure-db + migrate deploy + pnpm start'`. Exact snippet in [`CLAUDE.md`](CLAUDE.md) § Databases.
4. `PGHOST`, `PGUSER`, `PGPASSWORD`, `PGPORT` are already available on the pod (customer-wide baseline). `PGDATABASE` defaults to the repo name via the `${PGDATABASE:-<repo>}` fallback in the Dockerfile CMD — **do NOT `/set-secret PGDATABASE`**.

## Verification checklist

After the first push, expect:

- `https://<app>.<customer-domain>/` → placeholder home page rendered by Next.js
- `https://<app>.<customer-domain>/api/health` → `{"status":"ok","tag":"main-c42aae2"}` — `tag` is the image tag the running container was built from; the platform's deploy verification polls it. Locally (outside Docker) it's `null`.
- `https://<app>.<customer-domain>/api/env-demo` → `{"present":{"STRIPE_KEY":false,"DATABASE_URL":false,"API_KEY":false,"PGHOST":true,"PGDATABASE":false}}` — reveals which KV-sourced env vars are populated. `PGDATABASE` shows `false` here even after you add Prisma; it's set inside the Dockerfile CMD, not from KV.

Push a branch and expect the same at `<branch>-<app>.<customer-domain>/`.
