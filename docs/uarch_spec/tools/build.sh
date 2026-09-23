#!/bin/sh
# Build the micro-architecture reference in all output formats.
# Run from docs/uarch_spec:  tools/build.sh
set -e
cd "$(dirname "$0")/.."
asciidoctor core-et-uarch.adoc
asciidoctor-pdf core-et-uarch.adoc
python3 tools/build_docx.py
echo "built core-et-uarch.html, core-et-uarch.pdf, core-et-uarch.docx"
