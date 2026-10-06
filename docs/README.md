# Documentation

Everything written about the open-sourced CORE-ET design. The RTL it describes is in [`rtl/`](../rtl/).

Two kinds of material live here, and the difference matters:

- **`uarch_spec/`** is the document being written. It is the deliverable.
- **`arch/`, `uarch/` and `uarch_md/`** are the legacy Esperanto documents. They are reference material only.

Where a legacy document and the RTL disagree, **the RTL is the source of truth**.

## Folders

| Folder | Contents |
|---|---|
| [`uarch_spec/`](uarch_spec/) | The CORE-ET micro-architecture reference: AsciiDoc source, figures, build scripts and the generated HTML and PDF. See its own [README](uarch_spec/README.md). |
| [`arch/`](arch/) | Architecture-level Esperanto documents: datasheet, programmer's reference manual, introduction, errata, card datasheet. Used for chip-level facts in Chapter 1. |
| [`uarch/`](uarch/) | Legacy micro-architecture specifications, one PDF per unit: Minion, Neighborhood MAS, Minion Shire, Shire Cache, ET-Link, VPU, DCache, Front End and I-cache descriptions. |
| [`uarch_md/`](uarch_md/) | Markdown conversions of the PDFs in `uarch/`, one folder per document, with the extracted figures. Easier to search and to quote from than the PDFs. |

## `uarch_spec/` at a glance

| Path | Contents |
|---|---|
| `core-et-uarch.adoc` | Document root: attributes, front matter, chapter includes |
| `chapters/` | One AsciiDoc file per chapter |
| `images/chNN/` | Figures for chapter NN, with editable sources in `images/chNN/src/` |
| `themes/` | asciidoctor-pdf theme |
| `tools/build.sh` | Builds the HTML and the PDF |
| `docinfo.html` | CSS applied to the HTML output |

## Building

```sh
cd docs/uarch_spec
tools/build.sh          # writes core-et-uarch.html and core-et-uarch.pdf
```

Requires `asciidoctor` and `asciidoctor-pdf`. Figures are committed as PNG, so draw.io is only needed to edit them; the sources sit next to each PNG in `images/chNN/src/`.


## Conventions

- Every statement in `uarch_spec/` must be traceable to the RTL or to a document in `arch/` or `uarch/`.
- `dv/` and `test/` are not used as sources.
- Figures are drawn in draw.io, or generated from WaveJSON by the `wave2dio.py` script kept beside the timing diagrams it builds. Either way an editable source sits next to the exported PNG.
