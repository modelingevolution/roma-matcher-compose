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
| `docker-compose.yml` | Base service: pinned Harbor image, `runtime: nvidia`, `ROMA_*` env, weights volume, loopback port `127.0.0.1:7662`, `/health` healthcheck, json-file logging. No `build`, no `depends_on`. |
| `docker-compose.x64.yml` | x86_64 override — `platform: linux/amd64`. AutoUpdater layers it on `uname -m` = `x86_64`. |
| `docker-compose.arm64.yml` | ARM64 override — `platform: linux/arm64`. AutoUpdater layers it on `uname -m` = `aarch64`. |
| `roma-matcher.version` | Bare semver of the pinned release. |
| `update-version.sh` | `set X.Y.Z` pins the image tag across base + overrides and writes the version file; `list` queries Harbor for available release tags. |
| `release.sh` | Pins the version, commits + pushes master, then creates + pushes the git tag AutoUpdater detects. |
| `up-<ver>.sh` / `down-<ver>.sh` | Per-version migration hooks. `up` provisions the weights once (checksum-verified); `down` removes the empty models dir, never the weights. |
| `.github/workflows/release.yml` | `repository_dispatch: promote-release` → runs `update-version.sh set` + `release.sh`. |

## Service contract

| Aspect | Value |
|---|---|
| Service / container | `roma-matcher` |
| Image | `docker.modelingevolution.com/roma-matcher/roma-matcher:<pinned tag>` — one multi-arch manifest (amd64 + arm64), pulled, never built |
| GPU | `runtime: nvidia`; `NVIDIA_VISIBLE_DEVICES=all`, `NVIDIA_DRIVER_CAPABILITIES=compute,utility` |
| `ROMA_*` env | `ROMA_WEIGHTS_DIR=/models`, `ROMA_DEVICE=cuda`, `ROMA_HOST=0.0.0.0`, `ROMA_PORT=7662` |
| Volume | `/var/docker/data/roma-matcher/models:/models` |
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
override by `uname -m`, runs the version's `up-<ver>.sh`, then `pull` → `down` → `up -d` with
`-f docker-compose.yml -f docker-compose.<arch>.yml`.

## Release flow

CI on `roma-matcher` builds the image on every master push. A single manual **promote** then cascades to
the device — stages 3–4 are automatic.

| # | Stage | Trigger | Produces |
|---|---|---|---|
| 1 | CI build | push to `roma-matcher` master | `latest` + `master-<sha>` multi-arch manifest on Harbor |
| 2 | Promote | manual `workflow_dispatch` on `roma-matcher` | release manifest `roma-matcher:X.Y.Z` (digest re-tag) |
| 3 | Compose release | promote dispatches **this repo** | version bump committed + pushed to master, then a git tag |
| 4 | Deploy | AutoUpdater detects the new tag | `pull` → `down` → `up -d`; `up-<ver>.sh` provisions weights once |

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

## Weights provisioning

The weights are **never baked into the image** (~1.6 GB). They are published once as an
[ORAS](https://oras.land) artifact and fetched per device by `up-<ver>.sh`, SHA-256-verified, into
`/var/docker/data/roma-matcher/models`:

| File | Size | SHA-256 |
|---|---|---|
| `roma_outdoor.pth` | ~446 MB | `c7a45c80d41ad788a63c641d1b686d7cb3f297f40097c6f4e75039889e5cc8ba` |
| `dinov2_vitl14_pretrain.pth` | ~1.2 GB | `d5383ea8f4877b2472eb973e0fd72d557c7da5d3611bd527ceeb1d7162cbf428` |

`up-<ver>.sh` is idempotent: it skips the fetch when both files are present and verified, and fails the
update on any checksum mismatch. `oras` reuses the device's docker credential store; export
`HARBOR_USERNAME`/`HARBOR_PASSWORD` to override. `down-<ver>.sh` removes the models dir only if empty —
it never deletes the weights.

### One-time weights push

Publish the weights artifact once per release tag (re-tagging is a cheap digest copy when the weights
are unchanged):

```bash
cd ~/.cache/torch/hub/checkpoints      # holds roma_outdoor.pth + dinov2_vitl14_pretrain.pth
oras push docker.modelingevolution.com/roma-matcher/weights:0.1.0 \
  roma_outdoor.pth:application/octet-stream \
  dinov2_vitl14_pretrain.pth:application/octet-stream
```
