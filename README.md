# ente-backup

A self-contained container image that keeps an incremental local backup of an
[Ente Photos](https://ente.io/) library, on a schedule, with dead-man's-switch
monitoring via [Healthchecks.io](https://healthchecks.io).

Built for QNAP Container Station, but it's a plain container — it runs anywhere.

Derived from [bentasker/ente-cli-docker](https://codeberg.org/bentasker/ente-cli-docker)
and the accompanying [blog post](https://www.bentasker.co.uk/posts/documentation/general/automating-backup-of-photos-from-ente.html).

## What's different from upstream

|              | upstream                           | here                                            |
| ------------ | ---------------------------------- | ----------------------------------------------- |
| Scheduling   | external (k8s CronJob / host cron) | built-in loop, no host cron needed              |
| Monitoring   | none                               | Healthchecks pings with file counts             |
| `curl`       | not present                        | installed at build time, verified at build time |
| CLI source   | compiled from git                  | Ente's official released binary                 |
| Base         | pinned snapshot                    | current Wolfi at build time                     |
| Default user | `nonroot` (65532)                  | root — see below                                |

The upstream image is excellent; the changes here are about removing runtime
dependencies. Installing packages at container start meant every restart
depended on a reachable package repo, and a rolling `curl` eventually needed a
newer glibc than the pinned base provided — which broke monitoring silently.

The build now asserts `curl --version` and that the `ente` binary can load its
libraries. Both fail the build rather than the backup.

### Verifying the release checksum

`ENTE_SHA256` in the workflow is empty by default, which means the download is
unverified. Fill it in: run the build once, read the `>> actual sha256:` line
from the log, confirm it against the asset on the
[release page](https://github.com/ente-io/ente/releases), and paste it in.
After that, a tampered or truncated download fails the build.

## Setup

### 1. Publish the image

Push this repo to GitHub. The workflow builds on every push to `main` and on
version tags, publishing to `ghcr.io/<you>/ente-backup`.

**GHCR packages are private by default, even from a public repo.** After the
first successful build: repo → Packages → `ente-backup` → Package settings →
Change visibility → Public. Without this your NAS gets a 401 on pull and it is
not obvious why.

Cut a release with a tag:

```sh
git tag v1.0.0 && git push origin v1.0.0
```

### 2. Authenticate the CLI (once, interactive)

There is no programmatic way to log in, so this step is manual:

```sh
docker run --rm -it \
  -v /share/Container/ente/config:/cli-data \
  -v /share/Multimedia/Photos/Ente:/cli-export \
  --entrypoint /usr/bin/ente \
  ghcr.io/lptr/ente-backup:v1.0.0 account add
```

Enter `/cli-export/` when asked for the export directory. The path must already
exist — the setup flow will not create it.

### 3. Deploy

Create a check at Healthchecks.io, put its ping URL in `HC_URL`, and deploy
`docker-compose.yml` via Container Station → Applications → Create Application.

## Configuration

| Variable   | Default      | Meaning                                                          |
| ---------- | ------------ | ---------------------------------------------------------------- |
| `HC_URL`   | _(required)_ | Healthchecks ping URL. The wrapper exits if unset.               |
| `INTERVAL` | `3600`       | Seconds between the end of one export and the start of the next. |

Volumes:

- `/cli-data` — CLI database **and credentials**. Keep off broadly-shared paths.
- `/cli-export` — where photos land.

## Bumping the Ente CLI

Edit `ENTE_RELEASE` in `.github/workflows/build.yml`, matching a `cli-v*` tag
from [ente-io/ente releases](https://github.com/ente-io/ente/releases). Push,
tag, redeploy.

## Running as non-root

The image runs as root because QNAP shares are created root-owned and a
non-root container cannot write to them without intervention. To run
unprivileged, add `user: "65532:65532"` to the compose service and:

```sh
chown -R 65532:65532 /share/Container/ente/config /share/Multimedia/Photos/Ente
```

## Known limitations

- **Exports are per-account.** Albums shared _with_ you by another Ente user are
  not exported. If your household has multiple Ente accounts, each needs its own
  `account add` and its own export. Check the file count against what the app
  reports — a backup that silently covers a fraction of your library is worse
  than none, because it feels safe.
- **No overlap protection beyond the loop.** Runs are sequential by
  construction, but manually triggering `ente export` against the same config
  directory while the loop is running is untested and unlikely to end well.
- **A ping proves the process exited 0**, not that your photos are intact. The
  file count and size in the ping body are there so you can eyeball the trend.
- **This is a sync, not a versioned backup.** The cli-v0.2.3 changelog includes
  "sync deleted files before syncing new/updates files", which suggests
  deletions in Ente propagate to the local copy. If that is so, deleting photos
  in Ente — accidentally, or because someone got into the account — removes
  them here too, and this protects you against Ente vanishing but not against
  data loss _within_ Ente. Verify the behaviour before you rely on it, and
  consider snapshotting the export directory if it matters.
- **This is one copy, on one machine, in one building.** It does not protect
  against fire, theft, or a failed volume. Consider a second copy elsewhere.

## Licence

The Ente CLI is AGPL-3.0-only. The wrapper script and packaging here are
MIT unless you decide otherwise.
