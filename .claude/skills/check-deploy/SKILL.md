---
name: check-deploy
description: Report the current state of the deploy pipeline for this app — Actions status, ArgoCD sync, pod health, image tag currently live. Use when the user asks "is it deployed?", "why is my change not showing?", "what's the status?", or when a deploy appears stuck.
---

## Layered check — stop at the first thing that's wrong

### 1. GitHub Actions

```bash
gh run list --repo <this-repo> --limit 3
```

Look for:
- `action_required` → the workflow is held for approval (usually the `open-draft-pr` GH App is misconfigured; escalate to Simen).
- `failure` → click into the run and read the failing step. Common: `docker/build-push` failing on lockfile mismatch, `sed` no-op if manifest already at the tag.
- `queued` for >5 min → GitHub-side capacity issue, not something to fix here.

If green, move on.

### 2. Manifest bump commit

Confirm the `newTag:` in `manifests/prod/kustomization.yaml` (or `manifests/preview/kustomization.yaml` for previews) matches the freshly-built image:

```bash
git log -1 --format="%h %s" manifests/prod/kustomization.yaml
grep newTag manifests/prod/kustomization.yaml
```

If the bump commit didn't land, the `update-*-manifest.yaml` workflow failed silently (usually a permissions issue). Actions logs will show.

### 3. ArgoCD Application

If you have kubectl:

```bash
kubectl get applications -n argocd | grep <app>
kubectl describe application -n argocd <app>-prod | grep -A5 -E 'Sync Status|Health|Message'
```

Common states:
- `Unknown` → clone failed. Check `.status.conditions` for message; usually SSH vs HTTPS or a bad PAT.
- `OutOfSync` → the manifest bump landed but ArgoCD hasn't picked it up yet. Wait 30s or force refresh in the ArgoCD UI.
- `Synced/Progressing` → syncing is happening, just watch.
- `Degraded` → one or more child resources unhealthy. Usually pod issues (see step 4).

If you don't have kubectl, say so and stop here. The developer needs to check.

### 4. Pod

```bash
kubectl get pods -n <customer-namespace> -l app=<app>
kubectl describe pod -n <customer-namespace> <pod-name> | tail -30
kubectl logs -n <customer-namespace> <pod-name> --tail=50
```

Common patterns:
- `ImagePullBackOff` → GHCR pull secret expired. Escalate to Simen; not fixable from the app repo.
- `CrashLoopBackOff` right after boot → check logs. Usually `prisma migrate deploy` failed, or the app throws on missing env var. Missing env var means ExternalSecrets sync hasn't happened — force it (see `/set-secret` after-steps).
- Pod Running but URL returns 502 → readiness probe failing. Check `/health` endpoint responds.

### 5. Live URL

```bash
curl -sS -o /dev/null -w 'HTTP %{http_code} in %{time_total}s\n' https://<app>.<customer-domain>/
curl https://<app>.<customer-domain>/env-demo
```

`/env-demo` (if present) reveals which env vars are set — useful when the pod is running but returning wrong data.

## What to say to the user

Report the first thing that's wrong AND the fix. E.g.:

> Actions succeeded, manifest bumped to `main-a1b2c3d`, ArgoCD synced, pod Running. But `/env-demo` shows `STRIPE_KEY: false` — the ExternalSecret hasn't picked up the value you set 2 minutes ago (refresh is hourly). Force it? [yes/no]

Don't dump raw output on the user unless they ask.

## Related

- `/rollback` — if the current deploy is broken, roll back.
- `/set-secret` — when the fix is a missing env var.
