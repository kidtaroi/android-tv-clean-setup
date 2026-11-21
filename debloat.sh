#!/usr/bin/env bash
# Debloat-only entry point. Kept for anyone who wants the smaller workflow.
exec "$(dirname "${BASH_SOURCE[0]}")/setup.sh" --debloat-only "$@"
