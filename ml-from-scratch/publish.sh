#!/usr/bin/env bash
# Build the site plus the Medium-friendly copies, then push to GitHub Pages.
set -euo pipefail

quarto render                    # the real site           -> _site/
quarto render --profile medium   # Medium-friendly copies  -> _site/medium/
quarto publish gh-pages --no-render
