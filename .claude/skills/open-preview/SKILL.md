---
name: open-preview
description: Guide the user through spinning up a preview environment for a change. In practice this is just "push a branch" — the platform opens a PR and provisions a preview automatically. Use when the user says "test this on a preview", "get me a URL", "let me try this before merging", or asks how previews work.
---

## The whole workflow

There isn't one. This is the point of the platform.

```bash
git checkout -b feature/whatever
# ... make changes ...
git commit -am "<message>"
git push -u origin feature/whatever
```

That's it. Within ~2 minutes:

1. GitHub Actions `open-draft-pr` opens a draft PR to main.
2. GitHub Actions `build` builds the image and bumps the preview manifest.
3. ArgoCD's PullRequest generator sees the PR and creates a preview Application.
4. The preview is live at `https://<branch-slug>-<app>.<customer-domain>/`.

Branch names like `feature/x` become `feature-x` in the URL (slashes → hyphens).

## When to invoke this skill

The user is not sure how to test a change without merging to main. Explain the flow above, then execute the git commands (or let them do it if they prefer).

## After pushing

```bash
# Confirm PR opened
gh pr list --repo <this-repo> --head <branch-name>

# Watch the build
gh run watch --repo <this-repo>

# Check ArgoCD saw it (if you have kubectl)
kubectl get applications -n argocd | grep <app>-pr-
```

Compute the URL and tell the user:
- Slug = the branch name with `/` and `_` replaced by `-`, truncated to 50 chars.
- URL = `https://<slug>-<app>.<customer-domain>/`

## Preview lifetime

- Updates on every push to the branch.
- Tears down when the PR is closed or merged.
- Auto-closed after 7 days of inactivity by the stale-preview reaper. Reopen to restore.

## Preview isolation

- Frontend: same code as the branch, isolated from prod pods.
- Backend/DB: preview pod gets its own database `<app>_pr_<N>` if the app uses one. Data is empty by default; if the app defines `db:seed`, it runs on the first pod boot (gated by `SEED_ON_BOOT=1`).
- Secrets: preview pods see the same env vars as prod unless a preview-specific override is set with `/set-secret ... -f preview=true`.

## Related

- `/set-secret` with `-f preview=true` — inject test values just for previews.
- `/check-deploy` — see where the preview is in the deploy pipeline.
