# D-006 measurement data

The raw per-run files (about 1,490 files: `m1-m4`, `m5`, `m6`, `m7`, renderer proofs, logs, screenshots, `m9.json`) are in [`spikes/d006-data.tar.xz`](../../../spikes/d006-data.tar.xz) (4.3 MB), moved there by T-203 to keep them out of searches in `docs/`. Paths inside the archive are the old repository paths (`docs/decisions/d006-data/...`). To read them:

```sh
mkdir /tmp/d006 && tar -xJf spikes/d006-data.tar.xz -C /tmp/d006
```

Each run's `summary.md` and `environment.txt` stay in its directory here.
