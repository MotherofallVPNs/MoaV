# chart branch

Generated only. `star-history.svg` is the chart embedded in the main README;
`star-history.json` is the accumulated star history it renders from.

Both are written by `.github/workflows/star-history.yml` on `main`, which
force-pushes a single commit here whenever the numbers move. **Do not edit this
branch or open PRs against it** — the next run overwrites it.

The JSON is the state: each run reads it back and appends to it. Deleting it
loses every point that predates GitHub's restriction on reading star timestamps,
and CI cannot rebuild those — re-seeding needs a maintainer credential:

```bash
python3 scripts/gen-star-history.py --seed
```

Source: `scripts/gen-star-history.py` on `main`.
