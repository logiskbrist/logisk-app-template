---
name: open-preview
description: Guide the user through spinning up a preview environment for a change. Push a branch, then add the `preview` label to the resulting PR — that's what tells the platform to build a preview. Use when the user says "test this on a preview", "get me a URL", "let me try this before merging", or asks how previews work.
---

## The whole workflow

Two steps. Push, then label the PR.

```bash
git checkout -b feature/whatever
# ... make changes ...
git commit -am "<message>"
git push -u origin feature/whatever

# Wait ~10 s for the auto-drafted PR, then opt in to a preview:
gh pr edit --add-label preview
```

Within ~2 minutes of the label going on:

1. GitHub Actions `open-draft-pr` opens a draft PR to main (this happens on push, before the label).
2. GitHub Actions `build` builds the image and bumps the preview manifest.
3. ArgoCD's PullRequest generator sees the labeled PR and creates a preview Application.
4. The preview is live at `https://<branch-slug>-<app>.<customer-domain>/`.

Branch names like `feature/x` become `feature-x` in the URL (slashes → hyphens).

**Why the label is required:** the platform's ArgoCD ApplicationSet filters on `github.labels: [preview]`. PRs without the label get built (image is pushed to GHCR) but no preview Application is created — this is deliberate opt-in so draft/WIP/stale PRs don't accumulate preview environments.

## When to invoke this skill

The user is not sure how to test a change without merging to main. Explain the flow above, then execute the git commands (or let them do it if they prefer). Always add the label after `gh pr view` shows the PR exists — otherwise the reviewers won't see a preview URL to click.

## After pushing and labeling

```bash
# Confirm PR opened and label is on
gh pr view <PR-NUM> --json labels --jq '.labels[].name'

# Watch the build
gh run watch --repo <this-repo>

# Check ArgoCD saw the labeled PR (if you have kubectl)
kubectl get applications -n argocd | grep <app>-pr-
```

Compute the URL and tell the user:
- Slug = the branch name with `/` and `_` replaced by `-`, truncated to 50 chars.
- URL = `https://<slug>-<app>.<customer-domain>/`

## Preview lifetime

- Updates on every push to the branch (as long as the `preview` label is still on).
- Tears down when the PR is closed, merged, or the `preview` label is removed.
- Auto-expires after 7 days of PR inactivity: the nightly `preview-label-reaper` CronJob (in the `argocd` namespace) strips the `preview` label from PRs whose `updated_at` is older than 7 days. The PR stays open. Add the label back to bring the preview back.

## Preview isolation

- Frontend: same code as the branch, isolated from prod pods.
- Backend/DB: preview pod gets its own database `<app>_pr_<N>` if the app uses one. Data is empty by default; if the app defines `db:seed`, it runs on the first pod boot (gated by `SEED_ON_BOOT=1`).
- Secrets: preview pods see the same env vars as prod unless a preview-specific override is set with `/set-secret ... -f preview=true`.

## Related

- `/set-secret` with `-f preview=true` — inject test values just for previews.
- `/check-deploy` — see where the preview is in the deploy pipeline.
