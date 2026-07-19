#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION=debug "$ROOT/scripts/build-app.sh"
open "$ROOT/dist/Vani.app"
