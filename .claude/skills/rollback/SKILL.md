---
name: rollback
description: Roll production back to a previously deployed image tag. Use when the user says "rollback", "revert the deploy", "the last deploy broke things", or when `/check-deploy` shows prod is broken and reverting is faster than fixing forward.
---

## Two strategies — pick based on urgency

### Fast rollback (single-commit revert)

When you know the broken commit and can revert cleanly. Preserves git history.

```bash
git checkout main
git pull
# Find the offending commit
git log --oneline -20

# Revert it
git revert <bad-sha> --no-edit
git push origin main
```

The revert commit triggers a build → new image → new tag → deploy. Elapsed time: ~2-4 minutes.

### Faster rollback (manifest pin)

When the fix isn't obvious or the revert would conflict. Pin the manifest to the last known-good tag.

```bash
# Find the last known-good tag from history
git log --oneline manifests/prod/kustomization.yaml | head -5

# Edit the manifest directly
sed -i "s|newTag: .*|newTag: main-<known-good-sha>|" manifests/prod/kustomization.yaml
git commit -am "rollback: pin to <known-good-sha> [skip ci]"
git push origin main
```

The `[skip ci]` tag prevents CI from re-building. ArgoCD picks up the manifest change and syncs to the pinned tag. Elapsed time: ~30 seconds.

**Important:** any subsequent push to main will rebuild and overwrite the pinned tag. Coordinate with the developer — they need to actually fix the bug next, not just re-push.

## When to escalate instead of rollback

- If the failure is at the pod level (image OK but crashing on runtime config, e.g. missing env var), rolling back the image tag won't help. Use `/check-deploy` to identify the root cause first.
- If the failure is at the platform level (ArgoCD OutOfSync, image pull failure), rolling back only wastes time. Escalate to Simen.

## Verify

After push:
- `/check-deploy` — new deploy underway, pod runs the old image.
- `curl https://<app>.<customer-domain>/` — confirm behavior matches the old code.

## Post-mortem hint for the developer

If you rolled back, the app is stable but a bug still exists. Suggest opening a branch to fix it forward, land the fix via a normal PR + preview, then let the platform re-deploy on merge.
