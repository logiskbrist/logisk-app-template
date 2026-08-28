---
name: list-secrets
description: Show which environment variables are currently set for this app. Prefer the workflow path — it needs no local Azure or cluster access. Use when the user asks "what secrets are set", "what env vars does the app have", or before setting a new secret to avoid duplicates.
---

## Three paths, prefer the first

### Path 1 — via the workflow (no local Azure or cluster access needed)

```bash
gh workflow run list-secrets.yaml --repo <this-repo>

# Wait for it to finish
sleep 3
RUN_ID=$(gh run list --repo <this-repo> --workflow list-secrets --limit 1 --json databaseId --jq '.[0].databaseId')
gh run watch --repo <this-repo> "$RUN_ID"

# Read the output
gh run view "$RUN_ID" --repo <this-repo> --log \
  | awk '/PROD_SECRETS_START/,/PREVIEW_SECRETS_END/' \
  | grep -Ev 'START|END'
```

Or open the run in the browser (`gh run view "$RUN_ID" --repo <this-repo> --web`) to see the Markdown summary rendered.

The workflow queries Key Vault via OIDC and prints env-var names — never values.

### Path 2 — from the k8s Secret (only if you have kubectl)

```bash
kubectl get secret -n <customer-namespace> app-secret -o jsonpath='{.data}' | jq 'keys'
```

Returns a JSON array of env-var names as the pod currently sees them. Values are base64-encoded; do NOT decode and print them — the user is watching your logs. Note: only shows what ExternalSecrets has synced (up to 1h lag from KV).

### Path 3 — from Key Vault directly (only if you have `az` CLI locally)

```bash
az keyvault secret list --vault-name lb-kv-<customer> \
  --query "[?starts_with(name, '<app>-')].name" -o tsv
```

Reverse the mapping: strip `<app>-prod-` or `<app>-preview-`, then swap `-` → `_`.

## Constraints (all paths)

- Never print values, only names.
- If Path 2 shows fewer keys than Path 1, the ExternalSecret hasn't refreshed yet — call it out.
- If Path 1 shows both a prod and a preview entry for the same name, the preview overrides the prod value on preview pods only.

## What to tell the user

Just the names. Grouped as prod-only / preview-only / both if that's meaningful. If they need a value, ask why — usually the answer is `/set-secret` a new value, not read the current one.

## Related

- `/set-secret`, `/delete-secret`
