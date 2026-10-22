#!/bin/bash
# Builds bin/mednotes-import from a hand-listed subset of the app's sources.
# Xcode never compiles this list, so keep it in sync by hand: every type a
# listed file references must be defined in a listed file, and every listed
# file must need only system modules (no AppKit, SwiftUI or EventKit).
#
# The CLI is a plaintext read-only import tool: it never opens the user's
# encrypted store and never links libsodium or SQLCipher.
#
#   ./scripts/build_cli.sh          compile the optimised binary into bin/
#   ./scripts/build_cli.sh --check  typecheck the same list and stop; the
#                                   MedNotesTests target runs this on every
#                                   build so drift fails the test build
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

SOURCES=(
  CLI/main.swift
  MedNotes/Support/LenientCodable.swift
  MedNotes/Support/EncryptedBackupFormat.swift
  MedNotes/Support/DataRoot.swift
  MedNotes/Models/Patient.swift
  MedNotes/Models/Core.swift
  MedNotes/Storage/SQLConnection.swift
  MedNotes/Storage/AttachmentStore.swift
  MedNotes/Storage/Schema.swift
  MedNotes/Storage/Database.swift
  MedNotes/Import/JSONImporter.swift
  MedNotes/Services/Services.swift
  MedNotes/Services/MarkdownExportService.swift
  MedNotes/Services/LinkingService.swift
  MedNotes/Services/TemplateService.swift
)

case "${1:-}" in
  --check)
    echo "🔎 Typechecking mednotes-import CLI sources..."
    xcrun swiftc -typecheck -parse-as-library "${SOURCES[@]}"
    echo "✅ CLI sources typecheck"
    ;;
  "")
    mkdir -p bin
    echo "🔨 Compiling mednotes-import CLI tool..."
    xcrun swiftc -O -parse-as-library "${SOURCES[@]}" \
      -lsqlite3 \
      -o bin/mednotes-import
    echo "✅ Binary ready at bin/mednotes-import"
    ;;
  *)
    echo "usage: $0 [--check]" >&2
    exit 2
    ;;
esac
