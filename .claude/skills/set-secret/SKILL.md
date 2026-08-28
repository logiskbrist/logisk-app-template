---
name: set-secret
description: Add or update an environment variable for this app. Value goes to Azure Key Vault (never git) and appears on the running pod as an env var. Use for API keys, credentials, DB passwords, feature flags, or anything the user says is "a secret" or "an env var". Supports a preview-only override with -f preview=true.
---

## When to use

- User says "set" / "add" / "create" a secret, env var, API key, credential, token, password.
- User says "rotate" a secret — same command with the new value.
- User wants a preview-only value that differs from prod (e.g. sandbox Stripe key on previews) — pass `-f preview=true`.

Do NOT edit `.env` files, do NOT put values in code, do NOT commit `secrets.yaml`. Those don't propagate to the cluster.

## How to invoke

```bash
gh workflow run set-secret.yaml \
  --repo <this-repo> \
  -f name=<UPPERCASE_NAME> \
  -f value='<the value>'
```

Preview-only override:
```bash
gh workflow run set-secret.yaml \
  --repo <this-repo> \
  -f name=<UPPERCASE_NAME> \
  -f value='<the value>' \
  -f preview=true
```

Wait for it to finish:
```bash
gh run watch --repo <this-repo>
```

## Constraints

- `name` must match `^[A-Z_][A-Z0-9_]*$`. Lowercase or hyphens will be rejected. This is because env-var names in the container must be valid, and Key Vault names can't contain underscores — the workflow translates `NAME` → `<app>-{prod,preview}-NAME` with underscores → hyphens.
- `value` is masked in workflow logs via `::add-mask::`. Do not `echo` it in any other step you add.
- Values with shell metacharacters (`$`, backticks, quotes) — wrap in single quotes when passing via `-f`.

## After it succeeds

The KV secret is written immediately. It reaches the pod's env vars via ExternalSecrets refresh, which is 1 hour by default.

To force immediate propagation (only when the user is watching):

```bash
kubectl annotate externalsecret -n <customer-namespace> <app>-secret \
  force-sync=$(date +%s) --overwrite
kubectl rollout restart deploy/<app> -n <customer-namespace>
```

If you don't know `<customer-namespace>` or don't have `kubectl` access, tell the user "the new value will appear on the pod within 1 hour, or immediately if the developer force-syncs and rolls the deployment."

## Verify

The `/env-demo` endpoint on the running app (if it's the template's example endpoint) reports which known env vars are populated. Curl it after a force-sync to confirm.

## Related

- `/delete-secret` — remove one.
- `/list-secrets` — see what's currently set.
