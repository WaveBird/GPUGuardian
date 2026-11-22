#!/bin/bash
# Regenerate GPUGuardian.icns from the dependency-free Python source.
set -euo pipefail
cd "$(dirname "$0")"
python3 generate_icon.py
