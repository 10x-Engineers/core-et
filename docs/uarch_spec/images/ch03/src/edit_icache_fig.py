#!/usr/bin/env python3
"""Apply micro-architecture review edits to the hand-drawn Neighborhood I-cache figure.

Reads the diagram exported from draw.io, then

  1. scales every font up so the figure stays readable when the PDF fits it to
     the text width, widening the label cells that would otherwise wrap,
  2. adds the per-thread miss counters and bid mask, names the L1 miss request
     registers, gives the two cache levels their geometry and labels the
     request and response paths.

Usage:  python3 edit_icache_fig.py            (writes src/fig-neigh-icache.drawio)
Export: drawio -x -f png -s 4 -b 10 --embed-diagram \
            -o fig-neigh-icache.drawio.png src/fig-neigh-icache.drawio
"""
import re, html, sys

SRC = "src/fig-neigh-icache-orig.drawio"     # diagram as drawn, never modified
P   = "src/fig-neigh-icache.drawio"

PRE = "baHdinmJLSFSZgvW50fk-"
M   = "M3V3uY50NwzzoyH6c7mj-"
V   = "6qOkQ3Uz0hVBDyB4pvz5-"

x = open(SRC, encoding="utf-8").read()

# ------------------------------------------------------------------ helpers
def cell(cid):
    m = re.search(r'<mxCell id="%s".*?(?:/>|</mxCell>)' % re.escape(cid), x, re.S)
    if not m:
        sys.exit("cell not found: " + cid)
    return m.group(0)

def replace_cell(cid, new):
    global x
    x = x.replace(cell(cid), new, 1)

def set_value(cid, htmlvalue):
    c = cell(cid)
    esc = html.escape(htmlvalue, quote=True)
    if 'value="' in c:
        new = re.sub(r'value="(?:[^"]*)"', lambda _: 'value="%s"' % esc, c, count=1)
    else:
        new = c.replace("<mxCell ", '<mxCell value="%s" ' % esc, 1)
    replace_cell(cid, new)

def set_geo(cid, **kw):
    c = cell(cid)
    def fix(m):
        g = m.group(0)
        for k, v in kw.items():
            if re.search(r'\b%s="' % k, g):
                g = re.sub(r'\b%s="[^"]*"' % k, '%s="%s"' % (k, v), g)
            else:
                g = g.replace("<mxGeometry", '<mxGeometry %s="%s"' % (k, v), 1)
        return g
    replace_cell(cid, re.sub(r'<mxGeometry[^>]*>', fix, c, count=1))

# ------------------------------------------------------- 1. font scaling
K = 1.25            # draw.io's default size is 12 px

def scale(m):
    c = m.group(0)
    v = re.search(r'value="([^"]*)"', c)
    if not v or not v.group(1).strip():
        return c
    if re.search(r'font-size:\s*[0-9.]+px', c):
        c = re.sub(r'font-size:\s*([0-9.]+)px',
                   lambda mm: "font-size: %dpx" % round(float(mm.group(1)) * K), c)
    elif 'fontSize=' in c:
        c = re.sub(r'fontSize=([0-9.]+)',
                   lambda mm: "fontSize=%d" % round(float(mm.group(1)) * K), c)
    else:
        c = re.sub(r'style="', 'style="fontSize=%d;' % round(12 * K), c, count=1)
    return c

x = re.sub(r'<mxCell\b.*?(?:/>|</mxCell>)', scale, x, flags=re.S)

# label cells that need more room at the larger size
set_geo(PRE + "80",  x="-23", width="80")     # 8:1 LRU ARB, north
set_geo(M   + "43",  x="-23", width="80")     # 8:1 LRU ARB, south
set_geo(PRE + "11",  x="-6",  width="50")     # RR ARB
set_geo(PRE + "49",  x="5",   width="80")     # L1 DATA RAM
set_geo(PRE + "45",  x="400", width="100")    # ICACHE_TOP
set_geo(PRE + "76",  x="75",  width="140")    # SHARED_ICACHE
set_geo(PRE + "4",   x="745", width="180")    # Shire Channel
set_geo(PRE + "52",  width="80")              # ICACHE
set_geo(M   + "118", x="133", width="60")     # Update Priority, north
set_geo(V   + "3",   x="133", width="60")     # Update Priority, south
set_geo(V   + "7",   x="-92", width="44")     # VM Conf., north
set_geo(V   + "9",   x="-92", width="44")     # VM Conf., south
set_geo(M   + "4",   x="55",  width="80")     # request register caption
set_geo(V   + "4",   x="-134", width="90")    # MINIONS x4, M0 - M3
set_geo(V   + "6",   x="-134", width="90")    # MINIONS x4, M4 - M7
for cid, xx in ((M + "8", "252.5"), (M + "9", "255")):   # PTW boxes
    set_geo(cid, x=xx, width="60")

# ---------------------------------------------------------- 2. new content
NEW = []
def add(s):
    NEW.append("        " + s.strip())

def esc(s):
    return html.escape(s, quote=True)

GREY = "rgb(153, 153, 153)"
def small(txt, size=8, color=GREY, face="Garamond"):
    return '<font face="%s" style="font-size: %spx; color: %s;"><b>%s</b></font>' % (
        face, size, color, txt)

def lines(*rows, **kw):
    return "".join("<div>%s</div>" % small(r, **kw) for r in rows)

def textcell(cid, parent, xx, yy, w, h, value):
    add('<mxCell id="%s" value="%s" style="text;html=1;whiteSpace=wrap;strokeColor=none;'
        'fillColor=none;align=center;verticalAlign=middle;rounded=0;connectable=0;" '
        'vertex="1" parent="%s"><mxGeometry x="%s" y="%s" width="%s" height="%s" '
        'as="geometry" /></mxCell>' % (cid, esc(value), parent, xx, yy, w, h))

# miss counters and bid mask, one block per arbiter
for tag, arb_rect, top in (("n", PRE + "78", 334), ("s", M + "41", 484)):
    bid = "mc-%s" % tag
    add('<mxCell id="%s" value="%s" style="rounded=0;whiteSpace=wrap;html=1;'
        'fillColor=#dae8fc;strokeColor=#6c8ebf;strokeWidth=0.7;" vertex="1" parent="1">'
        '<mxGeometry x="130" y="%s" width="70" height="30" as="geometry" /></mxCell>'
        % (bid, esc(lines("Miss Counters", "+ Bid Mask", "(per thread)",
                          color="rgb(59, 90, 130)")), top))
    add('<mxCell id="%s-e" style="edgeStyle=orthogonalEdgeStyle;rounded=0;html=1;'
        'exitX=0.62;exitY=0;exitDx=0;exitDy=0;entryX=0.72;entryY=1;entryDx=0;entryDy=0;'
        'endArrow=blockThin;endFill=1;endSize=4;strokeWidth=1.2;strokeColor=#6c8ebf;" '
        'edge="1" parent="1" source="%s" target="%s">'
        '<mxGeometry relative="1" as="geometry" /></mxCell>' % (bid, bid, arb_rect))

# response, fill done and request labels
ORANGE = "rgb(215, 155, 0)"
textcell("lbl-resp-n", "1", -50, 314, 92, 12, small("Response + Fill Done", color=ORANGE))
textcell("lbl-resp-s", "1", -50, 464, 92, 12, small("Response + Fill Done", color=ORANGE))
textcell("lbl-req-n", "1", -34, 283, 68, 10, small("Fetch Requests"))
textcell("lbl-req-s", "1", -34, 433, 68, 10, small("Fetch Requests"))

# the two L1 miss request staging registers
textcell("lbl-l1req", "1", 336, 336, 58, 22, lines("L1 Miss Request", "Register", size=7))

# cache geometry
L0_DETAIL = lines("16 x 64 B lines, fully associative", "16-entry iTLB + PMA",
                  size=7, color="rgb(102, 61, 10)")
set_geo(PRE + "16", x="5", y="10", width="100", height="30")
set_geo(PRE + "24", x="5", y="10", width="100", height="30")
textcell("l0-geo-n", PRE + "14", 3, 44, 104, 20, L0_DETAIL)
textcell("l0-geo-s", PRE + "22", 3, 44, 104, 20, L0_DETAIL)

set_geo(PRE + "6", x="5", y="8", width="100", height="32")
textcell("l1-geo", PRE + "7", 3, 44, 104, 18,
         lines("128 sets x 4 ways, 64 B line", size=7, color="rgb(102, 61, 10)"))

# ECC block
set_geo(PRE + "62", x="587", y="221", width="90", height="38")
set_geo(PRE + "60", width="90", height="38")
set_geo(PRE + "61", x="4", y="5", width="82", height="28")
set_value(PRE + "61",
          '<b style="color: rgb(153, 0, 0); font-size: 14px;">ECC</b>'
          '<div><font style="font-size: 8px; color: rgb(153, 0, 0);">'
          '<b>Check + Error Log</b></font></div>')

x = x.replace("      </root>", "\n".join(NEW) + "\n      </root>", 1)
open(P, "w", encoding="utf-8").write(x)
print("fonts x%.2f, cells added: %d" % (K, len(NEW)))
