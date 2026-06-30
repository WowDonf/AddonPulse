# Releasing AddonPulse

This project uses the BigWigs packager via GitHub Actions to build and upload
zips to CurseForge, Wago, and GitHub Releases automatically whenever you push a
version tag. After the one-time setup below, every release is two commands.

The packager fetches the minimap-button libraries (`LibStub`, `CallbackHandler`,
`LibDataBroker`, `LibDBIcon`) into `Libs/` at build time — see `.pkgmeta` — so
they're never committed to the repo but always ship inside the released zip.

## One-time setup

### 1. Create the projects

Go to **CurseForge** and **Wago**, sign in, and create a new addon project for
AddonPulse on each.

- CurseForge: https://www.curseforge.com/wow/addons → "Upload an addon"
- Wago: https://addons.wago.io/ → "Create"

You don't need to upload a zip yet — just claim the project name and let it sit
empty. The first GitHub Actions release will populate it. Use
`CurseForge-description.md` for the long description on each listing.

### 2. Grab the project IDs and add them to the TOC

After creating each project, copy:

- **CurseForge Project ID** — visible in the upper-right of the project page,
  near the title. Numeric, like `123456`.
- **Wago Project ID** — visible in the project's "Tools" page. Looks like
  `LbN39A2k`.

Add two lines to `AddonPulse.toc` near the top:

```
## X-Curse-Project-ID: 123456
## X-Wago-ID: LbN39A2k
```

These let the CurseForge / Wago client apps recognize installed copies and
auto-update them.

### 3. Create API tokens

- **CurseForge API key**: https://legacy.curseforge.com/account/api-tokens →
  "Generate a New Token". Copy the long string.
- **Wago API token**: https://addons.wago.io/account/apikeys → "Create API
  Key" → copy the value.

### 4. Add the tokens as GitHub secrets

In your GitHub repo: **Settings → Secrets and variables → Actions → New
repository secret**. Add two:

- Name: `CF_API_KEY`        Value: your CurseForge token
- Name: `WAGO_API_TOKEN`    Value: your Wago token

(`GITHUB_TOKEN` is provided automatically by GitHub Actions; don't add it
manually.)

### 5. Push the repo to GitHub

```
git init
git add .
git commit -m "Initial commit: v0.10.0"
git branch -M main
git remote add origin git@github.com:WowDonf/AddonPulse.git
git push -u origin main
```

## Releasing a new version

1. **Bump the version.** Edit `## Version:` in `AddonPulse.toc` and add a new
   entry at the top of `CHANGELOG.md`. (The packager pulls release notes from
   `CHANGELOG.md` — see the `manual-changelog` block in `.pkgmeta`.)

2. **Commit and tag.** The tag name must start with `v` to trigger the
   workflow:

   ```
   git add AddonPulse.toc CHANGELOG.md
   git commit -m "Release v0.10.1"
   git tag v0.10.1
   git push && git push --tags
   ```

3. **Watch the build.** Open the Actions tab on GitHub. The `Release` workflow
   runs in 1–2 minutes; when green, CurseForge, Wago, and GitHub Releases all
   show the new file.

## Test runs without releasing

To dry-run the build locally before tagging, install the packager:

```
curl -s https://raw.githubusercontent.com/BigWigsMods/packager/master/release.sh | bash
```

Then run it from the repo root. It produces a zip in `.release/` (with the libs
fetched into `Libs/`) without uploading anywhere — handy for confirming the
packaged copy loads in-game before you tag.

## Before you tag — a checklist

- `luacheck .` is clean (0 warnings / 0 errors).
- The new build has actually been **loaded in a live client** and exercised
  (open the window, run a fight, reload, check the Sessions tab).
- `## Interface:` lists the current live patch(es) so it doesn't load "out of
  date" — `120007` (12.0.7) and `120100` (12.1).
- `CHANGELOG.md` has a dated entry for the version you're tagging.

## Troubleshooting

- **The workflow ran but nothing appeared on CurseForge.** Check `CF_API_KEY`
  is set in GitHub repo secrets and that the CurseForge project ID in the TOC
  matches the project.
- **"Could not find a TOC file"** — the packager expects `AddonPulse.toc` at
  the repo root. Don't nest the addon inside a subfolder.
- **Tag pushed but workflow didn't trigger.** Tag must start with `v`
  (lowercase) and be pushed with `git push --tags`.
- **Released zip is missing the minimap button.** The libs are externals fetched
  at build time; confirm the `externals` block in `.pkgmeta` is intact and the
  packager step had network access.
