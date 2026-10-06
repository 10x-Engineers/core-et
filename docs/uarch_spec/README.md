# CORE-ET Micro-Architecture Reference

Micro-architecture reference for the open-sourced CORE-ET RTL in [`rtl/`](../../rtl/).

Where this reference and the legacy documents in [`docs/uarch/`](../uarch/) (Markdown copies in [`docs/uarch_md/`](../uarch_md/)) disagree, the RTL is the source of truth and the difference is recorded.

**Status**

| Chapter | State |
|---|---|
| 1 ET-SoC-1 Overview | Written. Describes the ET-SoC-1 chip; the RTL in this repository is one Neighborhood behind an AXI port, so the scope of this chapter is under review |
| 2 ET-Minion Core | Core Overview and Front End written; Integer Pipeline, Data Cache and VPU are headings only |
| 3 Neighborhood | Overview, Neighborhood Instruction Cache and Front End – I-Cache Interface written; L0 Micro-Cache, L1 Instruction Cache, Page-Table Walker, Memory Request and Response Path, Tensor Support and Synchronization are headings only |

## Contents

| Path | Purpose |
|---|---|
| `core-et-uarch.adoc` | Main document (Asciidoctor, book doctype): front matter and chapter includes |
| `chapters/` | One AsciiDoc file per chapter |
| `images/<chapter>/` | Figures used by that chapter (PNG) |
| `images/<chapter>/src/` | Editable figure sources: `*.drawio` (draw.io) and `td-*.json5` (WaveDrom originals of the timing diagrams) |
| `themes/uarch-theme.yml` | PDF theme |
| `docinfo.html` | HTML style (centered figure captions) |
| `tools/build.sh` | Builds the HTML and the PDF |

Generated outputs, kept in the repository: `core-et-uarch.pdf` and `core-et-uarch.html`.

## Building

```sh
tools/build.sh                     # HTML and PDF
asciidoctor core-et-uarch.adoc     # HTML only
asciidoctor-pdf core-et-uarch.adoc # PDF only
```
