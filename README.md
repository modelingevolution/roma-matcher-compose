# RoMa Matcher Compose

AutoUpdater deploy package for the **RoMa matcher** service (Epic 029 · Feature 005). It mirrors the
one `roma-matcher` service into a base + per-arch override layout, pinned to a Harbor release tag, so
the matcher deploys as its own package whether or not rocket-welder is present on the device.

The service itself (Dockerfiles, wire contract, source) lives in
[`roma-matcher`](https://github.com/modelingevolution/roma-matcher). This repo only deploys the
pre-built multi-arch image — it never builds.

## Files

| File | Purpose |
|---|---|
| `docker-compose.yml` | Base service: pinned Harbor image, `runtime: nvidia`, `ROMA_*` env, loopback port `127.0.0.1:7662`, `/health` healthcheck, json-file logging. No `build`, no `depends_on`. |
| `docker-compose.x64.yml` | x86_64 override — `platform: linux/amd64`. AutoUpdater layers it on `uname -m` = `x86_64`. |
| `docker-compose.arm64.yml` | ARM64 override — `platform: linux/arm64`. AutoUpdater layers it on `uname -m` = `aarch64`. |
| `roma-matcher.version` | Bare semver of the pinned release. |
| `update-version.sh` | `set X.Y.Z` pins the image tag across base + overrides and writes the version file; `list` queries Harbor for available release tags. |
| `release.sh` | Pins the version, commits + pushes master, then creates + pushes the git tag AutoUpdater detects. |
| `.github/workflows/release.yml` | `repository_dispatch: promote-release` → runs `update-version.sh set` + `release.sh`. |

## Service contract

| Aspect | Value |
|---|---|
| Service / container | `roma-matcher` |
| Image | `docker.modelingevolution.com/roma-matcher/roma-matcher:<pinned tag>` — one multi-arch manifest (amd64 + arm64), pulled, never built |
| GPU | `runtime: nvidia`; `NVIDIA_VISIBLE_DEVICES=all`, `NVIDIA_DRIVER_CAPABILITIES=compute,utility` |
| `ROMA_*` env | `ROMA_WEIGHTS_DIR=/models`, `ROMA_DEVICE=cuda`, `ROMA_HOST=0.0.0.0`, `ROMA_PORT=7662` |
| Weights | Baked into the image — no host volume, no runtime provisioning |
| Ports | `127.0.0.1:7662:7662` — loopback-only |
| Healthcheck | `python3 -c urllib` on `/health`; interval 30s, timeout 10s, retries 3, start_period 180s |
| Restart | `unless-stopped` |
| `depends_on` | none |

Validate the resolved config anywhere (no GPU needed):

```bash
docker compose -f docker-compose.yml -f docker-compose.x64.yml config
```

`up -d` needs an NVIDIA-GPU host with the container runtime registered with Docker.

## AutoUpdater registration

Register this package as its own `Packages[]` entry in the device AutoUpdater `appsettings` — it tracks
its own version in its own `deployment.state.json`, independent of rocket-welder:

```json
{
  "Packages": [
    {
      "RepositoryUrl": "https://github.com/modelingevolution/roma-matcher-compose.git",
      "RepositoryLocation": "/data/repos/roma-matcher-compose",
      "DockerComposeDirectory": "./"
    }
  ]
}
```

AutoUpdater clones `RepositoryUrl` to `RepositoryLocation`, detects the newest git tag, selects the arch
override by `uname -m`, then `pull` → `down` → `up -d` with
`-f docker-compose.yml -f docker-compose.<arch>.yml`. Weights ship inside the image, so there is no
per-device provisioning step.

## Release flow

CI on `roma-matcher` builds the image on every master push. A single manual **promote** then cascades to
the device — stages 3–4 are automatic.

| # | Stage | Trigger | Produces |
|---|---|---|---|
| 1 | CI build | push to `roma-matcher` master | `latest` + `master-<sha>` multi-arch manifest on Harbor |
| 2 | Promote | manual `workflow_dispatch` on `roma-matcher` | release manifest `roma-matcher:X.Y.Z` (digest re-tag) |
| 3 | Compose release | promote dispatches **this repo** | version bump committed + pushed to master, then a git tag |
| 4 | Deploy | AutoUpdater detects the new tag | `pull` → `down` → `up -d` (weights ship in the image) |

### Dispatch contract

`roma-matcher`'s `promote.yml` POSTs to this repo's `/dispatches`:

```
event_type: promote-release
client_payload: { "version": "X.Y.Z" }
```

`release.yml` validates the version, confirms `roma-matcher:X.Y.Z` exists on Harbor (refusing to tag a
release with no image), then runs `update-version.sh set X.Y.Z` and `release.sh`. It uses the default
`GITHUB_TOKEN` (`contents: write`) to push to its own repo, and `HARBOR_USERNAME`/`HARBOR_PASSWORD`
secrets for the Harbor check. The pushed git tag is what AutoUpdater detects.

### Manual release

```bash
HARBOR_USERNAME='robot$roma-matcher+deploy-pull' HARBOR_PASSWORD='<secret>' \
  ./update-version.sh list          # see available release tags on Harbor
./release.sh 0.2.0                   # pin 0.2.0, commit + push master, push tag v0.2.0
./release.sh --dry-run               # preview without changing anything
```

## Weights

The RoMa weights (~1.6 GB) are **baked into the image** at build time in the
[`roma-matcher`](https://github.com/modelingevolution/roma-matcher) repo. The device needs no `oras`, no
host weights directory, and no migration hooks — the matcher loads its weights straight from the image.
