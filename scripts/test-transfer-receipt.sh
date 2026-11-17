#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
swiftc "$repo/KnightMusic/Core/Downloads/TransferReceipt.swift" \
  "$repo/scripts/TransferReceiptSmoke.swift" -o "$tmpdir/receipt-smoke"
"$tmpdir/receipt-smoke" "$tmpdir/receipts"
