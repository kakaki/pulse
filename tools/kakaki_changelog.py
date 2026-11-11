#!/usr/bin/env python3
"""Writes the "Co nowego" / "What's new" section of the Pulse pages on kakaki.pl from the release tags.

Usage: python3 tools/kakaki_changelog.py [path/to/kakaki-pl]   (default: ~/Developer/KakakiSoft/kakaki-pl)
Each annotated tag vX has "PL: …" and "EN: …" lines (see release procedure). The section sits between
<!-- ZMIANY:START --> and <!-- ZMIANY:END --> in mac/pulse/index.html and en/mac/pulse/index.html.
"""
import html, os, re, subprocess, sys

repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
site = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/Developer/KakakiSoft/kakaki-pl")
LIMIT = 8

def git(*args):
    return subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True, check=True).stdout

releases = []
for tag in git("tag", "-l", "v*", "--sort=-v:refname").split():
    notes = git("tag", "-l", "--format=%(contents)", tag)
    lines = dict(re.findall(r"^(PL|EN):\s*(.+)$", notes, re.M))
    if "PL" in lines and "EN" in lines:
        y, m, d = git("log", "-1", "--format=%as", tag).strip().split("-")
        releases.append((tag[1:], f"{d}.{m}.{y}", lines))
    if len(releases) == LIMIT:
        break

def section(lang):
    title, more, sid = (("Co nowego", "Wszystkie wersje na GitHubie ↗", "zmiany") if lang == "PL"
                        else ("What's new", "All versions on GitHub ↗", "changes"))
    rows = "\n".join(f'      <h3>Pulse {v} <span class="szary">· {date}</span></h3>\n      <p>{html.escape(n[lang])}</p>'
                     for v, date, n in releases)
    return (f'<!-- ZMIANY:START -->\n      <h2 id="{sid}">{title}</h2>\n{rows}\n'
            f'      <p><a href="https://github.com/kakaki/pulse/releases">{more}</a></p>\n      <!-- ZMIANY:END -->')

for path, lang, toc in [("mac/pulse/index.html", "PL", '<li><a href="#zmiany">Co nowego</a></li>'),
                        ("en/mac/pulse/index.html", "EN", '<li><a href="#changes">What\'s new</a></li>')]:
    f = os.path.join(site, path)
    s = open(f, encoding="utf8").read()
    block = section(lang)
    if "<!-- ZMIANY:START -->" in s:
        s = re.sub(r"<!-- ZMIANY:START -->.*?<!-- ZMIANY:END -->", lambda _: block, s, flags=re.S)
    else:  # first run: before the questions
        anchor = '      <h2 id="pytania">' if lang == "PL" else '      <h2 id="faq">'
        s = s.replace(anchor, "      " + block + "\n" + anchor, 1)
        last = '<li><a href="#pytania">Pytania</a></li>' if lang == "PL" else '<li><a href="#faq">Questions</a></li>'
        s = s.replace(last, toc + last, 1)
    open(f, "w", encoding="utf8").write(s)
    print("updated", path, "with", len(releases), "releases")
