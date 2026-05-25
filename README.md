# crow-plugins-mirror

Mirrors selected images from `codefloe.com/crow-plugins` to `quay.io/amrkmn/crow`.

## Using the mirror

Update image references to point at the mirror:

```env
codefloe.com/crow-plugins/ansible       → quay.io/amrkmn/crow/ansible 
codefloe.com/crow-plugins/auto-releaser → quay.io/amrkmn/crow/auto-releaser
codefloe.com/crow-plugins/clone         → quay.io/amrkmn/crow/clone
codefloe.com/crow-plugins/docker-buildx → quay.io/amrkmn/crow/docker-buildx
codefloe.com/crow-plugins/renovate      → quay.io/amrkmn/crow/renovate
codefloe.com/crow-plugins/sccache       → quay.io/amrkmn/crow/sccache
```

## Important

To use `quay.io/amrkmn/crow/clone`, update `CROW_PLUGINS_TRUSTED_CLONE` as documented in [CrowCI plugin env vars](https://crowci.dev/v5-9/configuration/env-vars/plugins/#plugins_trusted_clone):

```env
CROW_PLUGINS_TRUSTED_CLONE=quay.io/amrkmn/crow/clone
```

## Automation

GitHub Actions runs `crow-plugins-mirror.sh` every 2 hours and also supports manual runs from the Actions tab.

## License

This repository is licensed under the MIT License. See [LICENSE](./LICENSE).

Mirrored images retain their respective upstream licenses. Check the upstream repositories for the applicable license of each mirrored image.
