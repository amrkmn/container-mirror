# container-mirror

Mirrors container images from multiple source registries to target registries.

## Sources mirrored

Defined in [`mirrors.json`](./mirrors.json):

| Source | Target | Images |
|--------|--------|--------|
| `codefloe.com/crow-plugins` | `quay.io/amrkmn/crow` | ansible, auto-releaser, clone, docker-buildx, renovate, sccache |
| `codeberg.org/forgejo` | `quay.io/amrkmn/forgejo` | forgejo, runner |

To add a new mirror group, add an entry to `mirrors.json`.

## Environment

| Variable | Default | Description |
|----------|---------|-------------|
| `MIRRORS_FILE` | `mirrors.json` | Path to mirror group definitions |
| `REGISTRY_CREDENTIALS` | — | JSON string with registry credentials |
| `REGISTRY_CREDENTIALS_FILE` | `.creds.json` | Path to credentials JSON file |
| `TAG_FILTER` | `.*` | ERE regex for tags to sync |
| `MAX_JOBS` | `4` | Parallel image mirrors per group |
| `DRY_RUN` | `false` | `true` = print copies without executing |

### Single-group mode (ad-hoc)

For quick one-off runs, set `SOURCE`, `TARGET`, and `IMAGES` directly — the script uses these instead of `mirrors.json`:

```bash
SOURCE=codefloe.com/crow-plugins \
  TARGET=quay.io/amrkmn/crow \
  IMAGES="ansible clone" \
  bash ./container-mirror.sh
```

## Credentials

Credentials live in a JSON file (or a `REGISTRY_CREDENTIALS` secret in CI):

```json
{
  "source": {
    "codefloe.com": { "user": "...", "password": "..." },
    "codeberg.org": { "user": "...", "password": "..." }
  },
  "destination": {
    "quay.io": { "user": "...", "password": "..." }
  }
}
```

Omit entries for registries that allow anonymous pulls. The script resolves credentials per-host from this JSON for each mirror group.

### Local use

Copy the example and fill in credentials:

```bash
cp .creds.example.json .creds.json
# edit .creds.json with your credentials
```

Then run — `.creds.json` is auto-discovered if present in the script directory:

```bash
bash ./container-mirror.sh
```

Or pass explicitly:

```bash
REGISTRY_CREDENTIALS_FILE=/path/to/creds.json bash ./container-mirror.sh
```

Or inline the JSON:

```bash
REGISTRY_CREDENTIALS='{...}' bash ./container-mirror.sh
```

### CI (GitHub Actions)

Set a repository secret named `REGISTRY_CREDENTIALS` with the JSON above. The workflow passes it directly — no per-job credential extraction needed.

## Crow plugin env vars

To use the mirrored clone image, update `CROW_PLUGINS_TRUSTED_CLONE`:

```env
CROW_PLUGINS_TRUSTED_CLONE=quay.io/amrkmn/crow/clone
```

See [CrowCI plugin env vars](https://crowci.dev/v5-9/configuration/env-vars/plugins/#plugins_trusted_clone).

## Automation

GitHub Actions runs all mirror groups every 2 hours (single job, no matrix). Manual dispatch available from the Actions tab.

## License

MIT. See [LICENSE](./LICENSE). Mirrored images retain their upstream licenses.
