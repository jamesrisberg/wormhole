# Releasing Wormhole

Releases are built locally with `scripts/release-local.sh`, which archives,
exports with Developer ID, notarizes, staples, zips, signs the zip for
Sparkle, and prepends an item to `releases/appcast.xml`.

## One-time setup

Credentials come from `.env`, else `$HUD_ENV_FILE`, else
`~/.config/machud/release.env` (shared with the MacHUD apps' `hud-release.sh`).

1. `cp .env.example .env` and fill in `APPLE_TEAM_ID`, `APPLE_ID`,
   `APPLE_APP_SPECIFIC_PASSWORD`, and `DOWNLOAD_BASE_URL`
   (for GitHub Releases: `https://github.com/<owner>/wormhole/releases/download`).
2. `APPCAST_URL` must equal `SUFeedURL` in `wormhole/Info.plist`
   (`https://viawormhole.xyz/appcast.xml`). The script refuses to run otherwise.
3. The Sparkle EdDSA private key must be in your login keychain (default
   account). Its public half is `SUPublicEDKey` in `Info.plist`.
4. `sign_update` is found automatically in the Sparkle SPM artifacts under
   DerivedData once packages are resolved. Set `SPARKLE_SIGN_UPDATE` to
   override.

## Each release

1. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in Xcode, write the
   same version to `VERSION` (it mirrors `MARKETING_VERSION`), and move
   `[Unreleased]` in `CHANGELOG.md` into a `## [<version>] - <date>` section.
2. `scripts/release-local.sh` (use `NOTARIZE=0` for a dry run; `SKIP_APPCAST=1` builds,
   notarizes and zips without the Sparkle signature and appcast item).
3. Upload `build/wormhole.zip` to a GitHub release tagged `v<version>`:
   `gh release create v<version> build/wormhole.zip --title "Wormhole <version>"`.
4. Publish `releases/appcast.xml` at `APPCAST_URL` (set `SITE_DIR` to have the
   script copy it into your site folder).
5. Commit the appcast and version bump.

Zips are not committed; `releases/*.zip` is gitignored.

`scripts/release-local.sh appcast-urls` rewrites every enclosure URL in the
appcast from `DOWNLOAD_BASE_URL` (used after changing the download host).

## Feed hand-off (old feed URL)

Builds up to 1.2.0 check `https://www.jamesrisberg.xyz/wormhole/appcast.xml`.
Newer builds check `https://viawormhole.xyz/appcast.xml`. Existing installs
only move to the new feed if the **old** feed keeps working long enough to
deliver a build whose `SUFeedURL` is the new one. Do one of:

- Serve, at the old URL, an appcast whose newest item is the first build with
  the new `SUFeedURL` (a single hand-off release), or
- Make the old URL an HTTP redirect to the new appcast (Sparkle follows
  redirects).

Keep that in place until you are satisfied existing users have updated.

## Historical archives

The appcast lists these versions; to make their URLs resolve, upload each
zip (from the old private repo's `releases/`) under tag `v<title>`:

| Appcast title | Build | Archive |
|---|---|---|
| 1.2.0 | 6 | `releases/wormhole.zip` |
| 1.1.0 | 5 | `releases/previous/wormhole1.1.0.zip` |
| 1.0.1 | 3 | `releases/previous/wormhole1.0.1.zip` |
| 1.0 | 2 | `releases/previous/wormhole1.0.0.zip` |
| 1.5 | 1.5 | `releases/previous/wormhole0.1.5.zip` |
| 1.4 | 1.4 | `releases/previous/wormhole0.1.4.zip` |
| 1.3 | 1.3 | `releases/previous/wormhole0.1.3.zip` |

(Matched by byte length. Only the newest item matters to Sparkle; the older
ones can be dropped from the appcast instead.)
