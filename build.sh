#!/usr/bin/env bash
set -euo pipefail

# Simple build script for debtui

OUT="debtui"

echo "Building debtui..."
odin build src -out:"$OUT" -o:speed -microarch:native -vet -vet-style -vet-semicolon

echo "Built: ./$OUT"
echo "Run with: ./$OUT"
