#!/usr/bin/env python3
"""Build core-et-uarch.docx from core-et-uarch.adoc.

Pipeline:
  1. asciidoctor (HTML5)    -> resolved cross-reference labels ("Figure 1", "Section 1.2.4")
  2. asciidoctor (DocBook5) -> structured input for pandoc; xrefs replaced by those labels
  3. pandoc (DOCX)          -> TOC, list of figures, list of tables, numbered headings
  4. post-processing        -> title page, page breaks, "Figure N." / "Table N." caption
                               numbers (SEQ fields), centered figure captions, and the order
                               Table of Contents, List of Tables, List of Figures
  5. pre-filled field results -> the TOC and both lists show their entries in any viewer;
                               Word regenerates them with page numbers on open (updateFields)

Requirements: asciidoctor and pandoc >= 3.1 (PANDOC env var or on PATH).

Usage: python3 tools/build_docx.py
"""
import html
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
DOCDIR = os.path.dirname(HERE)
SRC = os.path.join(DOCDIR, "core-et-uarch.adoc")
OUT = os.path.join(DOCDIR, "core-et-uarch.docx")
PANDOC = os.environ.get("PANDOC") or shutil.which("pandoc")

LUA_FILTER = r"""
-- Front matter (everything before the first chapter, whose id starts with "ch-") is unnumbered.
-- Admonition blocks get a bold label, e.g. "Note:".
local in_front = true
function Pandoc(doc)
  for _, b in ipairs(doc.blocks) do
    if b.t == "Header" and b.level == 1 and b.identifier:match("^ch%-") then in_front = false end
    if b.t == "Header" and in_front then table.insert(b.classes, "unnumbered") end
  end
  return doc
end
local labels = {note="Note", tip="Tip", important="Important", warning="Warning", caution="Caution"}
function Div(el)
  for _, c in ipairs(el.classes) do
    local label = labels[c]
    if label then
      local first = el.content[1]
      if first and first.t == "Div" and first.classes:includes("title") then
        table.remove(el.content, 1)
        first = el.content[1]
      end
      if first and (first.t == "Para" or first.t == "Plain") then
        table.insert(first.content, 1, pandoc.Space())
        table.insert(first.content, 1, pandoc.Strong({pandoc.Str(label .. ":")}))
      end
      return el
    end
  end
end
"""

W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"


def run(cmd, **kw):
    subprocess.run(cmd, check=True, **kw)


def xref_labels(html_file):
    """Map each anchor id to the label asciidoctor rendered for it."""
    text = open(html_file, encoding="utf-8").read()
    labels = {}
    for m in re.finditer(r'<a href="#([^"]+)">(.*?)</a>', text, re.S):
        label = html.unescape(re.sub(r"<[^>]+>", "", m.group(2))).strip()
        if label:
            labels.setdefault(m.group(1), label)
    return labels


def resolve_xrefs(docbook_file, labels):
    text = open(docbook_file, encoding="utf-8").read()

    def sub(m):
        target = m.group(1)
        label = labels.get(target, target)
        return f'<link linkend="{target}">{html.escape(label, quote=False)}</link>'

    text = re.sub(r'<xref linkend="([^"]+)"\s*/>', sub, text)
    open(docbook_file, "w", encoding="utf-8").write(text)


def page_break():
    return f'<w:p xmlns:w="{W}"><w:r><w:br w:type="page"/></w:r></w:p>'


def caption_prefix(kind, number):
    return (
        f'<w:r><w:t xml:space="preserve">{kind} </w:t></w:r>'
        f'<w:r><w:fldChar w:fldCharType="begin"/></w:r>'
        f'<w:r><w:instrText xml:space="preserve"> SEQ {kind} \\* ARABIC </w:instrText></w:r>'
        f'<w:r><w:fldChar w:fldCharType="separate"/></w:r>'
        f'<w:r><w:t>{number}</w:t></w:r>'
        f'<w:r><w:fldChar w:fldCharType="end"/></w:r>'
        f'<w:r><w:t xml:space="preserve">. </w:t></w:r>'
    )


def postprocess(docx_file):
    tmp = docx_file + ".tmp"
    with zipfile.ZipFile(docx_file) as zin, zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as zout:
        for item in zin.infolist():
            data = zin.read(item.filename)
            if item.filename == "word/document.xml":
                data = fix_document(data.decode("utf-8")).encode("utf-8")
            elif item.filename == "word/styles.xml":
                data = fix_styles(data.decode("utf-8")).encode("utf-8")
            elif item.filename == "word/settings.xml":
                data = fix_settings(data.decode("utf-8")).encode("utf-8")
            zout.writestr(item, data)
    os.replace(tmp, docx_file)


def fix_document(d):
    # Caption numbers.
    counters = {"ImageCaption": ("Figure", 0), "TableCaption": ("Table", 0)}

    def number(m):
        para = m.group(0)
        style = m.group(1)
        kind, n = counters[style]
        n += 1
        counters[style] = (kind, n)
        end_ppr = para.index("</w:pPr>") + len("</w:pPr>")
        return para[:end_ppr] + caption_prefix(kind, n) + para[end_ppr:]

    d = re.sub(r'<w:p>\s*<w:pPr>\s*<w:pStyle w:val="(ImageCaption|TableCaption)"\s*/>.*?</w:p>', number, d, flags=re.S)

    d = fill_lists(d)

    # Front matter: title page, then TOC, List of Tables, List of Figures, each on its own page.
    sdts = {}
    for m in re.finditer(r"<w:sdt>.*?</w:sdt>", d, re.S):
        gallery = re.search(r'w:docPartGallery w:val="([^"]+)"', m.group(0)).group(1)
        sdts[gallery] = m.group(0)
    start = d.index("<w:sdt>")
    end = d.rindex("</w:sdt>") + len("</w:sdt>")
    order = ["Table of Contents", "List of Tables", "List of Figures"]
    front = page_break() + "".join(sdts[g] + page_break() for g in order if g in sdts)
    d = d[:start] + front + d[end:]
    return d


def para_text(p):
    return html.unescape("".join(re.findall(r"<w:t[^>]*>([^<]*)</w:t>", p)))


def entry(text, level=0, anchor=None):
    indent = f'<w:ind w:left="{level * 360}"/>' if level else ""
    run = f'<w:r><w:t xml:space="preserve">{html.escape(text, quote=False)}</w:t></w:r>'
    if anchor:
        run = f'<w:hyperlink w:anchor="{anchor}">{run}</w:hyperlink>'
    return f"<w:p><w:pPr><w:spacing w:after=\"60\"/>{indent}</w:pPr>{run}</w:p>"


def fill_lists(d):
    """Write cached results into the TOC, list-of-tables and list-of-figures fields."""
    toc = []
    for m in re.finditer(r'(?:<w:bookmarkStart w:id="\d+" w:name="([^"]+)"\s*/>\s*)?'
                         r'(<w:p>\s*<w:pPr>\s*<w:pStyle w:val="Heading([1-3])"\s*/>.*?</w:p>)', d, re.S):
        anchor, para, level = m.group(1), m.group(2), int(m.group(3))
        num = re.search(r'<w:rStyle w:val="SectionNumber"\s*/>\s*</w:rPr>\s*<w:t[^>]*>([^<]*)</w:t>', para)
        text = para_text(para)
        if num:
            text = num.group(1) + "  " + text[len(num.group(1)):]
        toc.append(entry(text, level - 1, anchor))
    figs = [entry(para_text(p)) for p in re.findall(r'<w:p>\s*<w:pPr>\s*<w:pStyle w:val="ImageCaption"\s*/>.*?</w:p>', d, re.S)]
    tabs = [entry(para_text(p)) for p in re.findall(r'<w:p>\s*<w:pPr>\s*<w:pStyle w:val="TableCaption"\s*/>.*?</w:p>', d, re.S)]
    results = {"Table of Contents": toc, "List of Figures": figs, "List of Tables": tabs}

    def fill(m):
        sdt = m.group(0)
        gallery = re.search(r'w:docPartGallery w:val="([^"]+)"', sdt).group(1)
        entries = results.get(gallery) or []
        field = re.search(r'<w:p><w:r><w:fldChar w:fldCharType="begin"[^>]*/><w:instrText[^>]*>.*?</w:instrText>'
                          r'<w:fldChar w:fldCharType="separate"\s*/><w:fldChar w:fldCharType="end"\s*/></w:r></w:p>', sdt, re.S)
        if not field or not entries:
            return sdt
        begin = re.search(r'<w:fldChar w:fldCharType="begin"[^>]*/><w:instrText[^>]*>.*?</w:instrText>'
                          r'<w:fldChar w:fldCharType="separate"\s*/>', field.group(0), re.S).group(0)
        body = list(entries)
        body[0] = body[0].replace("</w:pPr>", f"</w:pPr><w:r>{begin}</w:r>", 1)
        body[-1] = body[-1].replace("</w:p>", '<w:r><w:fldChar w:fldCharType="end"/></w:r></w:p>')
        return sdt.replace(field.group(0), "".join(body))

    return re.sub(r"<w:sdt>.*?</w:sdt>", fill, d, flags=re.S)


def fix_settings(s):
    # Ask Word to refresh the TOC and lists (adds page numbers) when the document is opened.
    if "<w:updateFields" in s:
        return s
    return re.sub(r"(<w:settings[^>]*>)", r'\1<w:updateFields w:val="true"/>', s, count=1)


def fix_styles(s):
    # Center figure captions.
    def center(m):
        block = m.group(0)
        if "<w:jc " in block:
            return block
        if "<w:pPr>" in block:
            return block.replace("<w:pPr>", '<w:pPr><w:jc w:val="center"/>', 1)
        if "<w:rPr>" in block:
            return block.replace("<w:rPr>", '<w:pPr><w:jc w:val="center"/></w:pPr><w:rPr>', 1)
        return block.replace("</w:style>", '<w:pPr><w:jc w:val="center"/></w:pPr></w:style>', 1)

    return re.sub(r'<w:style [^>]*w:styleId="ImageCaption".*?</w:style>', center, s, flags=re.S)


def main():
    if not PANDOC:
        sys.exit("pandoc not found: install it or set PANDOC=/path/to/pandoc")
    with tempfile.TemporaryDirectory() as tmp:
        html_out = os.path.join(tmp, "doc.html")
        db_out = os.path.join(tmp, "doc.xml")
        lua = os.path.join(tmp, "filter.lua")
        open(lua, "w").write(LUA_FILTER)
        run(["asciidoctor", "-o", html_out, SRC])
        run(["asciidoctor", "-b", "docbook5", "-o", db_out, SRC])
        resolve_xrefs(db_out, xref_labels(html_out))
        run([PANDOC, "-f", "docbook", "-t", "docx", "--toc", "--toc-depth=3", "--lof", "--lot",
             "--number-sections", f"--lua-filter={lua}", f"--resource-path={DOCDIR}",
             "-o", OUT, db_out])
    postprocess(OUT)
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
