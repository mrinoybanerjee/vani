#!/bin/bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

swift format lint --recursive --strict Sources Tests Package.swift
for script in scripts/*.sh Tests/Scripts/*.sh; do
    bash -n "$script"
done
git diff --check
