# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A self-hosted PyPI mirror that extracts dependencies from `orbit-core-agent`'s poetry.lock, downloads multi-platform wheels, generates a PEP 503 index, and deploys to AWS S3 + CloudFront.

## Commands

```bash
bash setup.sh              # Full setup: infra + download + index + deploy
bash setup.sh --refresh    # Skip infra, re-run phases 2-6 (re-download & sync)
```

## Architecture

**setup.sh** orchestrates 6 sequential phases:

1. **AWS Infrastructure** — S3 bucket (versioned, private) + CloudFront distribution with OAC/SigV4
2. **Export Requirements** — `poetry export` from `$ORBIT_PROJECT/poetry.lock` → `requirements-prod.txt` + `requirements-all.txt`. Falls back to `scripts/export_from_lock.py` if poetry CLI unavailable
3. **Download Packages** — `pip3 download --only-binary=:all:` for 5 platforms (linux x86/arm64, macOS arm64, Windows amd64, noarch), consolidated into `packages/all/`
4. **Generate Index** — `scripts/generate_index.py` scans `packages/all/`, computes SHA256 hashes, writes static HTML to `index/simple/`
5. **Push to S3** — `aws s3 sync` packages and index, then CloudFront cache invalidation
6. **Verify** — `scripts/verify_mirror.py` cross-checks requirements vs downloaded wheels

**Python scripts** (in `scripts/`):
- `export_from_lock.py` — Parses poetry.lock TOML directly (fallback when poetry CLI missing)
- `generate_index.py` — Generates PEP 503-compliant HTML index with SHA256 fragment URLs
- `verify_mirror.py` — Validates all required packages have at least one wheel present

## Configuration

`config.env` holds all settings: `BUCKET_NAME`, `AWS_PROFILE`, `AWS_REGION`, `ORBIT_PROJECT` path, and CloudFront IDs (populated by Phase 1).

## Key Conventions

- Package name normalization follows PEP 503: `re.sub(r"[-_.]+", "-", name).lower()`
- Index uses relative hrefs (`../../packages/{filename}`) so it works behind any CDN prefix
- Downloads continue on per-package failure (no abort on missing platform wheel)
- `packages/` and `index/` are gitignored build artifacts; `requirements-*.txt` are tracked

## Mirror URL

```
https://d10k6kc8ol2hfl.cloudfront.net/simple/
```

Usage: `pip install <pkg> --index-url https://d10k6kc8ol2hfl.cloudfront.net/simple/`
