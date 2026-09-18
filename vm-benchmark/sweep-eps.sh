#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

RATES=(250 500 750 1000)

for rate in "${RATES[@]}"; do
  export VEGETA_EPS=$rate
  export LOGGEN_EPS=$rate
  ~/src/orca/bin/orca bench
done
