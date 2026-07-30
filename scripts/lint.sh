#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

swift format lint --recursive --strict Sources Tests Package.swift
bash -n scripts/*.sh
git diff --check
