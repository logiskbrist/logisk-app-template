---
name: delete-secret
description: Remove an env var from Azure Key Vault for this app. The env var disappears from the running pod on the next ExternalSecrets refresh. Use when the user wants to "remove" / "delete" / "unset" a secret or env var, or when rotating credentials to also drop the old-name variant.
---

## When to use

- User says "remove", "delete", "unset", "get rid of" a secret / env var.
- Rotating a credential where the *name* changes (delete old, set new).

Do NOT use to "clear" a value — set to an empty string via `/set-secret` instead if that's what they mean.

## How to invoke

```bash
gh workflow run delete-secret.yaml \
  --repo <this-repo> \
  -f name=<UPPERCASE_NAME>
```

Preview-only variant:
```bash
gh workflow run delete-secret.yaml \
  --repo <this-repo> \
  -f name=<UPPERCASE_NAME> \
  -f preview=true
```

Wait:
```bash
gh run watch --repo <this-repo>
```

## Constraints

- `name` matches `^[A-Z_][A-Z0-9_]*$`.
- Deletes are recoverable within Azure's soft-delete window (default 90 days) — `az keyvault secret recover` on the operator side. Say so if the user seems to be deleting by accident.
- If the secret doesn't exist, the workflow succeeds with a no-op message.

## After it succeeds

Same as `/set-secret` — the env var will disappear from the pod on the next ExternalSecrets refresh. Force-sync + rollout if immediate propagation matters.

## Related

- `/set-secret`, `/list-secrets`
