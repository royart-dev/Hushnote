#!/usr/bin/env python3
"""Regenerates Sources/Hushnote/LogoGeometry.swift from design/Hushnote_Logo.svg.
Run from the repository root after the logo artwork changes: python3 scripts/make-logo-geometry.py
Handles the absolute M/L/H/V/C/Z path commands and the single rounded-rect pill the artwork uses."""
import re

svg = open('design/Hushnote_Logo.svg').read()
d = re.search(r'<path d="([^"]+)"', svg).group(1)
w, h = re.search(r'viewBox="0 0 ([\d.]+) ([\d.]+)"', svg).groups()
x, y, pw, ph, rx = re.search(r'<rect x="([\d.]+)" y="([\d.]+)" width="([\d.]+)" height="([\d.]+)" rx="([\d.]+)"', svg).groups()
if re.search(r'[a-z]', re.sub(r'e-?\d', '', d)):
    raise SystemExit('Relative path commands are not supported; export the logo with absolute coordinates.')

tokens = re.findall(r'[MCVHLZ]|-?[\d.]+(?:e-?\d+)?', d)
fmt = lambda v: ('%.4f' % v).rstrip('0').rstrip('.')
pt = lambda a, b: f'CGPoint(x: {fmt(a)}, y: {fmt(b)})'
ops, i, cur, cmd = [], 0, (0.0, 0.0), None

def num():
    global i
    i += 1
    return float(tokens[i - 1])

while i < len(tokens):
    if tokens[i] in 'MCVHLZ':
        cmd = tokens[i]; i += 1
    if cmd == 'M':
        cur = (num(), num()); ops.append(f'p.move(to: {pt(*cur)})'); cmd = 'L'
    elif cmd == 'L':
        cur = (num(), num()); ops.append(f'p.addLine(to: {pt(*cur)})')
    elif cmd == 'H':
        cur = (num(), cur[1]); ops.append(f'p.addLine(to: {pt(*cur)})')
    elif cmd == 'V':
        cur = (cur[0], num()); ops.append(f'p.addLine(to: {pt(*cur)})')
    elif cmd == 'C':
        a = [num() for _ in range(6)]; cur = (a[4], a[5])
        ops.append(f'p.addCurve(to: {pt(a[4], a[5])}, control1: {pt(a[0], a[1])}, control2: {pt(a[2], a[3])})')
    elif cmd == 'Z':
        ops.append('p.closeSubpath()'); cmd = None

body = '\n'.join('        ' + op for op in ops)
w, h, x, y, pw, ph, rx = map(float, (w, h, x, y, pw, ph, rx))
open('Sources/Hushnote/LogoGeometry.swift', 'w').write(f'''import CoreGraphics

/// The Hushnote mark, generated from design/Hushnote_Logo.svg (viewBox {fmt(w)} x {fmt(h)}, SVG coordinates, y down).
/// The H carries the wordmark; the pill in its pinched crossbar is the voice, drawn in the signal colour.
/// Regenerate with scripts/make-logo-geometry.py rather than editing by hand.
enum LogoGeometry {{
    static let size = CGSize(width: {fmt(w)}, height: {fmt(h)})
    static let pill = CGRect(x: {fmt(x)}, y: {fmt(y)}, width: {fmt(pw)}, height: {fmt(ph)})
    static let mark: CGPath = {{
        let p = CGMutablePath()
{body}
        return p
    }}()
    static let pillPath = CGPath(roundedRect: pill, cornerWidth: {fmt(rx)}, cornerHeight: {fmt(rx)}, transform: nil)

    /// Aspect-fits the artwork into a y-down `rect`.
    static func transform(into rect: CGRect) -> CGAffineTransform {{
        let scale = min(rect.width / size.width, rect.height / size.height)
        return CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                 tx: rect.midX - size.width * scale / 2, ty: rect.midY - size.height * scale / 2)
    }}
}}
''')
print(f'Wrote Sources/Hushnote/LogoGeometry.swift ({len(ops)} path operations)')
