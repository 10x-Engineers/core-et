# CORE-ET Micro-Architecture Reference

This folder will hold the single, self-contained micro-architecture reference for the open-sourced CORE-ET RTL in [`rtl/`](../../rtl/).

Once complete, this reference supersedes the legacy documents in [`docs/u_arch/`](../u_arch/), which are converted to Markdown in [`docs/u_arch_md/`](../u_arch_md/), and the relevant parts of [`docs/arch/`](../arch/).

**Status:** the document structure is being defined and no chapters have been written yet.

- **Scope:** only the RTL open-sourced in this repository is in scope. Blocks such as TBOX, RBOX, Shire Cache and NoC will be documented later.
- **Source of truth:** the RTL is a later revision than the legacy documents. Where they disagree, the implemented behavior wins, and the discrepancy is recorded.

| File | Purpose |
|---|---|
| `core-et-uarch.adoc` | Main AsciiDoc document (Asciidoctor, book doctype). Holds the front matter and includes the chapter files. |
| `chapters/` | One AsciiDoc file per written chapter. Chapter 1 (ET-SoC-1 Overview) is a heading skeleton with planned figures and tables. |
| `images/<chapter>/` | Figures per chapter. Editable draw.io sources are in `images/<chapter>/src/`. |
| `themes/uarch-theme.yml`, `docinfo.html` | PDF theme and HTML style (centered figure captions). |
| `tools/build_docx.py` | Builds `core-et-uarch.docx`: title page, table of contents, list of tables, list of figures. |
| `study/frontend/` | Front End study notes: architecture and complete flow. Input for Chapter 3; not part of the reference document. Build with `asciidoctor-pdf study/frontend/frontend-rtl-study.adoc`. |
| `plan/` | `document-plan.adoc` (chapter division and chapter template) and per-chapter source traces. |

Build:

- HTML: `asciidoctor core-et-uarch.adoc`
- PDF: `asciidoctor-pdf core-et-uarch.adoc`
- DOCX: `python3 tools/build_docx.py` (needs `pandoc` 3.1 or later on `PATH`, or `PANDOC=/path/to/pandoc`)
