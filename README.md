# Container Mirror

This project copies container images from one registry to another.

The mirror list is stored in [`mirrors.json`](./mirrors.json). The scheduled
GitHub Actions workflow runs the mirror every two hours.

## Run Locally

Requirements:

- Python 3.10 or newer
- [`uv`](https://docs.astral.sh/uv/)
- [`regctl`](https://github.com/regclient/regclient/releases)

Create a credentials file:

```bash
cp .creds.example.json .creds.json
```

Edit `.creds.json`, then run:

```bash
uv run --script container-mirror.py
```

You can also provide credentials with `REGISTRY_CREDENTIALS` or set
`REGISTRY_CREDENTIALS_FILE` to another file.

## One-Time Mirror

Set `SOURCE`, `TARGET`, and `IMAGES` to mirror images without editing
`mirrors.json`:

```bash
SOURCE=codefloe.com/crow-plugins \
TARGET=quay.io/amrkmn/crow \
IMAGES="ansible clone" \
uv run --script container-mirror.py
```

## Configuration

| Variable | Default | Description |
| --- | --- | --- |
| `MIRRORS_FILE` | `mirrors.json` | Mirror definitions file |
| `REGISTRY_CREDENTIALS_FILE` | `.creds.json` | Credentials file |
| `REGISTRY_CREDENTIALS` | unset | Credentials as a JSON string |
| `TAG_FILTER` | `.*` | Regular expression for tags to mirror |
| `TAG_IGNORE` | unset | Comma, pipe, or regular-expression tag exclusions |
| `MAX_JOBS` | `4` | Images mirrored at the same time |
| `TAG_JOBS` | `4` | Tags checked at the same time for each image |
| `MIRROR_CACHE` | `.mirror-cache.json` | Digest cache file |
| `CACHE_TTL` | `0` | Hours to trust a cached source digest |
| `DRY_RUN` | `false` | Show planned copies without copying |
| `PLATFORM` | unset | Platform to copy, such as `linux/amd64` |

## Credentials

Credentials use this format:

```json
{
    "source": {
        "registry.example.com": {
            "user": "username",
            "password": "password"
        }
    },
    "destination": {
        "quay.io": {
            "user": "username",
            "password": "password"
        }
    }
}
```

Source registries may be anonymous. Destination credentials are required.

## Cache

The script stores the last known source digest for each tag in
`.mirror-cache.json`.

With the default `CACHE_TTL=0`, every tag checks both registries. This detects
deleted or changed destination tags and repairs them.

With `CACHE_TTL` set, a tag skips the source check only when the destination
still has the cached digest. If the destination is missing or different, the
script checks the source and copies the image when needed. Mutable tags such as
`latest` can remain stale for up to the configured TTL.

The GitHub Actions workflow restores the latest cache and saves an updated
cache after each run.

## GitHub Actions

The workflow runs from `.github/workflows/mirror.yml`:

- Scheduled every two hours
- Also available through manual dispatch
- Reads credentials from the `REGISTRY_CREDENTIALS` repository secret

## License

MIT. See [`LICENSE`](./LICENSE).
