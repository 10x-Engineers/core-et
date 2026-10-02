#!/usr/bin/env python3
"""Decision flow of a demand lookup in the L0 micro-cache.

Every outcome a lookup can have, and which of them leaves the thread with no
line requested on its behalf.  Conditions are the RTL expressions evaluated in
F2 (icache_micro_cache.v).

Usage:  python3 gen_miss_flow.py && drawio -x -f png -s 3 -b 10 \
            -o ../fig-ll-miss-flow.png fig-ll-miss-flow.drawio
"""
import html

W, H = 190, 54          # decision box
BW, BH = 210, 62        # outcome box
cells = []
n = [0]

def esc(s):
    return html.escape(s, quote=True).replace('\n', '&lt;br&gt;')

def box(x, y, w, h, label, style):
    n[0] += 1
    i = "n%d" % n[0]
    cells.append('<mxCell id="%s" value="%s" style="%s" vertex="1" parent="1">'
                 '<mxGeometry x="%s" y="%s" width="%s" height="%s" as="geometry"/></mxCell>'
                 % (i, esc(label), style, x, y, w, h))
    return i

DEC = ("rhombus;whiteSpace=wrap;html=1;fillColor=#dae8fc;strokeColor=#6c8ebf;"
       "fontSize=13;fontStyle=1;")
OK = ("rounded=1;whiteSpace=wrap;html=1;fillColor=#d5e8d4;strokeColor=#82b366;fontSize=12;")
WAIT = ("rounded=1;whiteSpace=wrap;html=1;fillColor=#fff2cc;strokeColor=#d6b656;fontSize=12;")
BAD = ("rounded=1;whiteSpace=wrap;html=1;fillColor=#f8cecc;strokeColor=#b85450;fontSize=12;"
       "strokeWidth=2;")
START = ("rounded=1;whiteSpace=wrap;html=1;fillColor=#e1d5e7;strokeColor=#9673a6;fontSize=13;"
         "fontStyle=1;")

def edge(a, b, label="", style=""):
    n[0] += 1
    cells.append('<mxCell id="e%d" value="%s" style="edgeStyle=orthogonalEdgeStyle;rounded=0;html=1;'
                 'endArrow=blockThin;endFill=1;strokeWidth=1.5;fontSize=12;'
                 'labelBackgroundColor=#ffffff;%s" edge="1" parent="1" source="%s" target="%s">'
                 '<mxGeometry relative="1" as="geometry"/></mxCell>'
                 % (n[0], esc(label), style, a, b))

X = 40                      # decision column
XO = 330                    # outcome column
start = box(X, 20, W, 44, "Lookup reaches F2", START)

d1 = box(X, 100, W, H, "f2_hit ?", DEC)
o1 = box(XO, 104, BW, BH, "Respond with the block.\nPriority updated.\nMiss counter cleared.", OK)

d2 = box(X, 200, W, H, "TLB miss ?", DEC)
o2 = box(XO, 204, BW, BH, "Translation requested from the PTW.\nMiss response, thread sleeps.", WAIT)

d3 = box(X, 300, W, H, "page or access fault ?", DEC)
o3 = box(XO, 304, BW, BH, "Fault reported with the response.\nPriority updated, counters cleared.\n"
                          "Core takes the trap.", OK)

d4 = box(X, 400, W, H, "f0_miss_state == Ready ?", DEC)
o4 = box(XO, 396, BW, BH, "Miss accepted.\nLine requested from the L1.\nMiss response, thread sleeps.", WAIT)

o5 = box(XO, 500, BW, 76, "MISS DROPPED\nNo line is requested.\nMiss response, thread sleeps.\n"
                          "Priority unchanged, counter + 1.", BAD)

edge(start, d1)
edge(d1, o1, "yes")
edge(d1, d2, "no")
edge(d2, o2, "yes")
edge(d2, d3, "no")
edge(d3, o3, "yes")
edge(d3, d4, "no")
edge(d4, o4, "yes")
edge(d4, o5, "no", "exitX=0.5;exitY=1;exitDx=0;exitDy=0;strokeColor=#b85450;strokeWidth=2;")

note = box(XO + BW + 30, 500, 230, 76,
           "The thread waits for a fill that was never requested. "
           "It is woken by the next fill done and tries again.", 
           "text;html=1;whiteSpace=wrap;align=left;verticalAlign=middle;fontSize=12;fontColor=#b85450;")

open("fig-ll-miss-flow.drawio", "w").write(
    '<mxfile><diagram name="miss-flow"><mxGraphModel><root><mxCell id="0"/>'
    '<mxCell id="1" parent="0"/>' + "".join(cells) + '</root></mxGraphModel></diagram></mxfile>')
print("wrote fig-ll-miss-flow.drawio")
