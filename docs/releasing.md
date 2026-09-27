# Releasing ai-polish.nvim

## Version policy

Git tags are the source of truth for release versions. Use annotated tags named `vMAJOR.MINOR.PATCH`, following [Semantic Versioning](https://semver.org/). The first planned release is `v0.1.0`; adding these instructions does not publish that version.

- Before 1.0, keep patch updates compatible within a minor series. Use a new minor version for new features or breaking changes, and explain breaking changes in the release notes.
- Starting with 1.0, use patch versions for compatible fixes, minor versions for compatible features, and major versions for breaking changes.
- Never move or reuse a published tag. Ship a new version for corrections.
- The automated release workflow accepts numeric release tags only, without prerelease or build suffixes.

Compatibility covers the documented commands, mappings, configuration, and Lua API. There is no separate version constant to keep in sync. Plugin managers install Git revisions; GitHub Releases provide the corresponding human-readable change history.

## Publish a release

Run these commands from a checkout of this repository with push access. Merge the release changes into `master` first, complete manual verification, and confirm that CI passes for the exact commit to release. Tag publication is a separate maintainer action; opening or merging a PR does not publish a version.

For the first release, fetch the merged commit and inspect it:

```sh
git fetch origin master --tags
git log -1 --format=fuller origin/master
gh run list --workflow ci.yml --branch master --limit 5
```

Choose the successful CI run for the inspected commit and use `gh run view RUN_ID --json headSha,conclusion` to confirm its SHA and result. Replace `RELEASE_COMMIT_SHA` below with that full SHA; do not tag an unmerged feature branch.

```sh
git tag -a v0.1.0 RELEASE_COMMIT_SHA -m "ai-polish.nvim v0.1.0"
git show --no-patch v0.1.0
git push origin refs/tags/v0.1.0
```

Pushing the tag starts the [Release workflow](../.github/workflows/release.yml). It validates the tag format and that the commit belongs to `master`, runs the existing Neovim test matrix, lint, and format checks against the tagged commit, then publishes a GitHub Release with generated notes. No binary assets or package registry are needed for this Lua plugin.

The Git tag becomes available to plugin managers as soon as it is pushed, before the Release workflow finishes. That is why the commit must already have passed CI and manual verification. A failed release workflow does not remove or move the tag.

Verify the workflow and publication:

```sh
gh run list --workflow release.yml --limit 5
gh release view v0.1.0
```

Review the generated English release notes on GitHub and add any migration guidance before announcing the release. For subsequent releases, replace `v0.1.0` throughout with the selected version.

## Verify installation

Once the tag is public, use this lazy.nvim spec in a separate test configuration:

```lua
{
  "umiyosh/ai-polish.nvim",
  version = "^0.1.0",
  cmd = "AiPolish",
  opts = {},
}
```

Remove any local `dir`/`dev` override and conflicting `branch`, `tag`, or `commit` selector from that test configuration. Run `:Lazy update ai-polish.nvim`, restart Neovim, and inspect the plugin revision in `:Lazy`. Run `:AiPolish` on a test document with an API key configured; confirm progress, review, and cancellation work. To pin the exact first release instead, replace `version` with `tag = "v0.1.0"`.

References: [lazy.nvim versioning](https://lazy.folke.io/spec/versioning), [vim-plug plugin options](https://github.com/junegunn/vim-plug#plug-options), [GitHub CLI release creation](https://cli.github.com/manual/gh_release_create).
