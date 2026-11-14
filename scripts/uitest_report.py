"""Turns the xcresulttool output of a UI test run into something to look at.
usage: python3 scripts/uitest_report.py build/out
  reads  build/out/uitest-tests.json (xcresulttool get test-results tests) and build/out/uitest/manifest.json
         (xcresulttool export attachments)
  writes build/out/uitest/<Class>/<test>/<NN-step>.png (screenshots renamed and grouped per test) and
         build/out/uitest-summary.md (pass/fail per test with the failure messages); prints the summary."""
import json, os, re, shutil, sys

out = sys.argv[1] if len(sys.argv) > 1 else 'build/out'
shots = os.path.join(out, 'uitest')


def safe(s):
    return re.sub(r'[^A-Za-z0-9._-]+', '_', s).strip('_') or 'x'


# 1. screenshots: <Class>/<test>/<name>.png
manifest = os.path.join(shots, 'manifest.json')
moved = 0
if os.path.exists(manifest):
    with open(manifest) as f:
        entries = json.load(f)
    for e in entries if isinstance(entries, list) else []:
        tid = e.get('testIdentifier') or e.get('testIdentifierURL') or 'unknown'
        parts = [p for p in re.split(r'[/]', tid.replace('()', '')) if p]
        cls, test = (parts[-2], parts[-1]) if len(parts) >= 2 else ('Other', parts[-1] if parts else 'unknown')
        folder = os.path.join(shots, safe(cls), safe(test))
        os.makedirs(folder, exist_ok=True)
        for a in e.get('attachments', []):
            src = os.path.join(shots, a.get('exportedFileName', ''))
            if not os.path.isfile(src):
                continue
            name = a.get('suggestedHumanReadableName') or os.path.basename(src)
            # "01-launched_0_UUID.png" -> "01-launched.png"
            base, ext = os.path.splitext(name)
            base = re.sub(r'_\d+_[0-9A-Fa-f-]{36}$', '', base)
            if a.get('isAssociatedWithFailure'):
                base += '-FAILURE'
            dst = os.path.join(folder, safe(base) + (ext or '.png'))
            n = 2
            while os.path.exists(dst):
                dst = os.path.join(folder, f'{safe(base)}-{n}{ext or ".png"}'); n += 1
            shutil.move(src, dst)
            moved += 1
print(f'screenshots: {moved} grouped under {shots}/<Class>/<test>/')

# 2. pass / fail per test
cases = []


def walk(node, path):
    kind = node.get('nodeType', '')
    name = node.get('name', '')
    if kind == 'Test Case':
        msgs = []

        def fails(n):
            for c in n.get('children', []) or []:
                if c.get('nodeType') == 'Failure Message':
                    msgs.append(c.get('name', ''))
                fails(c)
        fails(node)
        cases.append({'class': path[-1] if path else '', 'test': name, 'result': node.get('result', '?'),
                      'duration': node.get('duration', ''), 'failures': msgs})
        return
    nxt = path + [name] if kind in ('Test Suite', 'Unit test bundle', 'UI test bundle') else path
    for c in node.get('children', []) or []:
        walk(c, nxt)


tests_json = os.path.join(out, 'uitest-tests.json')
if os.path.exists(tests_json):
    try:
        with open(tests_json) as f:
            data = json.load(f)
        for n in data.get('testNodes', []):
            walk(n, [])
    except Exception as ex:  # keep the run going: the raw json is in the artifact
        print('could not read the test list:', ex)

passed = sum(1 for c in cases if c['result'] == 'Passed')
failed = [c for c in cases if c['result'] == 'Failed']
lines = [f'# Apple TV UI tests: {passed} passed, {len(failed)} failed, {len(cases)} total', '']
lines += ['| Result | Test | Time | Failure |', '|---|---|---|---|']
for c in cases:
    msg = ' / '.join(m.replace('|', '\\|').replace('\n', ' ') for m in c['failures'])[:400]
    mark = {'Passed': 'PASS', 'Failed': 'FAIL', 'Skipped': 'SKIP'}.get(c['result'], c['result'])
    lines.append(f"| {mark} | {c['class']}/{c['test']} | {c['duration']} | {msg} |")
text = '\n'.join(lines) + '\n'
with open(os.path.join(out, 'uitest-summary.md'), 'w') as f:
    f.write(text)
print(text)
step = os.environ.get('GITHUB_STEP_SUMMARY')
if step:
    with open(step, 'a') as f:
        f.write(text)
