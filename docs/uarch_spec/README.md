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
python3 tools/build_docx.py        # DOCX only
```

Study notes: `asciidoctor-pdf study/frontend/frontend-rtl-study.adoc`

The DOCX build needs pandoc 3.1 or later. It is taken from `$PANDOC`, from `PATH`, or from a pypandoc installation. If pandoc is not installed system-wide, create it once:

```sh
python3 -m venv ~/.venvs/uarch-docs
~/.venvs/uarch-docs/bin/pip install pypandoc_binary
```

`tools/build_docx.py` then finds that pandoc by itself.

The Word file is built from the AsciiDoc source, not converted from the PDF: it keeps Word heading styles, a field-based table of contents, list of tables and list of figures, numbered captions and working cross-reference links. Converting `core-et-uarch.pdf` with a PDF-to-Word tool reconstructs each page from positioned text and loses all of that.

## Hosting on Read the Docs

[`.readthedocs.yaml`](../../.readthedocs.yaml) in the repository root builds this document on Read the Docs. It installs Asciidoctor and pandoc, converts `core-et-uarch.adoc` to HTML as the served page, copies `images/`, and puts the PDF and DOCX next to it so the page can offer them as downloads.

To publish:

1. Sign in at <https://app.readthedocs.org> with the GitHub account that owns the repository.
2. **Add project** → import `open_hw-core-et`. Read the Docs finds `.readthedocs.yaml` by itself.
3. Build. The document appears at `https://<project-slug>.readthedocs.io/`.
4. Optional: in **Settings → Automation rules**, build only the branches you want to publish.

The `rtd` attribute passed by the build adds the download links at the top of the page; local builds do not show them.


## Figures

Every figure drawn for this document has a source in `images/<chapter>/src/`. After editing a source, export the PNG that the document uses:

```sh
drawio -x -f png -s 2 -b 10 -o images/ch02/<name>.png images/ch02/src/<name>.drawio
```

Figures taken from the ET-SoC-1 datasheet or from the presentations in [`docs/presentation/`](../presentation/) have no source file; their origin is recorded in the chapter source trace.
