# CORE-ET Micro-Architecture Reference

Micro-architecture reference for the open-sourced CORE-ET RTL in [`rtl/`](../../rtl/).

Where this reference and the legacy documents in [`docs/u_arch/`](../u_arch/) (Markdown copies in [`docs/u_arch_md/`](../u_arch_md/)) disagree, the RTL is the source of truth and the difference is recorded.

**Status**

| Chapter | State |
|---|---|
| 1 ET-SoC-1 Overview | Written |
| 2 ET-Minion Core | Core Overview and Front End written; Integer Pipeline, Data Cache and VPU are headings only |
| 3 Neighborhood | Headings only |

## Contents

| Path | Purpose |
|---|---|
| `core-et-uarch.adoc` | Main document (Asciidoctor, book doctype): front matter and chapter includes |
| `chapters/` | One AsciiDoc file per chapter |
| `images/<chapter>/` | Figures used by that chapter (PNG) |
| `images/<chapter>/src/` | Editable figure sources: `*.drawio` (draw.io) and `td-*.json5` (WaveDrom originals of the timing diagrams) |
| `themes/uarch-theme.yml` | PDF theme |
| `docinfo.html` | HTML style (centered figure captions) |
| `tools/build.sh` | Builds all three output formats |
| `tools/build_docx.py` | Builds the DOCX: title page, table of contents, list of tables, list of figures |
| `plan/document-plan.adoc` | Chapter division and the template each unit section follows |
| `plan/chNN-source-trace.adoc` | Claim → source trace, one per written chapter |
| `study/frontend/` | Front End study notes (architecture and complete flow), the working basis for section 2.2. Not part of the reference document. |

Generated outputs, kept in the repository: `core-et-uarch.pdf`, `core-et-uarch.docx`, `core-et-uarch.html`.

## Building

```sh
tools/build.sh                     # HTML, PDF and DOCX
asciidoctor core-et-uarch.adoc     # HTML only
asciidoctor-pdf core-et-uarch.adoc # PDF only
python3 tools/build_docx.py        # DOCX only (needs pandoc 3.1+ on PATH, or PANDOC=/path/to/pandoc)
```

Study notes: `asciidoctor-pdf study/frontend/frontend-rtl-study.adoc`

## Figures

Every figure drawn for this document has a source in `images/<chapter>/src/`. After editing a source, export the PNG that the document uses:

```sh
drawio -x -f png -s 2 -b 10 -o images/ch02/<name>.png images/ch02/src/<name>.drawio
```

Figures taken from the ET-SoC-1 datasheet or from the presentations in [`docs/presentation/`](../presentation/) have no source file; their origin is recorded in the chapter source trace.
