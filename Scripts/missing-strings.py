#!/usr/bin/env python3
"""列出還沒有英文翻譯的介面字串。先 `swift build`，編譯器會把用到的 key 寫進 .stringsdata。"""
import glob, json, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TABLES = {
    'RFCore': 'Sources/RFCore/Resources/en.lproj/Localizable.strings',
    'RenderFilm': 'Localization/RenderFilm/en.lproj/Localizable.strings',
    'RenderFilmBatch': 'Localization/RenderFilmBatch/en.lproj/Localizable.strings',
}
CJK = re.compile(r'[一-鿿]')

used = {}
for f in glob.glob(os.path.join(ROOT, '.build/**/*.stringsdata'), recursive=True):
    m = re.search(r'/(RFCore|RenderFilmBatch|RenderFilm)-[a-z]\.build/', f)
    if not m:
        continue
    for items in json.load(open(f)).get('tables', {}).values():
        used.setdefault(m.group(1), set()).update(i['key'] for i in items if CJK.search(i['key']))

missing = 0
for target, rel in TABLES.items():
    if not os.path.exists(os.path.join(ROOT, rel)):
        continue
    have = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', os.path.join(ROOT, rel)]))
    for key in sorted(used.get(target, set()) - have.keys()):
        print(f'{target}\t{key}')
        missing += 1
sys.exit(1 if missing else 0)
