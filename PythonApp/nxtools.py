# -*- coding: utf-8 -*-
"""Small helpers the Swift side calls next to nxbridge: things that are one line in Python and a library in Swift
(zip archives, gzip). Uses the addon's own `requests` (with its certifi bundle: the app has no system CA store to give
to Python's ssl), so nxbridge.init() must have run first."""
import os, json, zipfile, shutil, gzip

SKIP_DIRS = ('tests', 'tools', '.github', '.git')


def fetch_text(url, accept='*/*', timeout=10):
    import requests
    r = requests.get(url, headers={'Accept': accept, 'User-Agent': 'NexStream'}, timeout=timeout)
    return json.dumps({'status': r.status_code, 'text': r.text})


def download_addon(user, repo, sha, dest_dir, tmp_zip):
    """Downloads the addon at commit `sha` and extracts it into `dest_dir` (emptied first), without the "addon-<sha>/" prefix."""
    import requests
    if os.path.isdir(dest_dir):
        shutil.rmtree(dest_dir, ignore_errors=True)
    os.makedirs(dest_dir, exist_ok=True)
    with requests.get('https://codeload.github.com/%s/%s/zip/%s' % (user, repo, sha), stream=True, timeout=40, headers={'User-Agent': 'NexStream'}) as r:
        if r.status_code != 200:
            return json.dumps({'ok': False, 'error': 'zip http %s' % r.status_code})
        with open(tmp_zip, 'wb') as f:
            for chunk in r.iter_content(256 * 1024):
                if chunk:
                    f.write(chunk)
    files = 0
    root = os.path.realpath(dest_dir)
    with zipfile.ZipFile(tmp_zip) as z:
        for info in z.infolist():
            name = info.filename
            rel = name.split('/', 1)[1] if '/' in name else ''
            if not rel or name.endswith('/'):
                continue
            top = rel.split('/', 1)[0]
            if top in SKIP_DIRS or '__pycache__' in rel:
                continue
            out = os.path.realpath(os.path.join(dest_dir, rel))
            if not out.startswith(root):
                continue
            os.makedirs(os.path.dirname(out), exist_ok=True)
            with z.open(info) as src, open(out, 'wb') as dst:
                shutil.copyfileobj(src, dst)
            files += 1
    try:
        os.remove(tmp_zip)
    except OSError:
        pass
    ok = files >= 200 and os.path.exists(os.path.join(dest_dir, 'addon.xml')) and os.path.exists(os.path.join(dest_dir, 'channels.json'))
    return json.dumps({'ok': ok, 'files': files})


def gunzip(src, dst):
    """Expands a gzip file (the XMLTV guides) to `dst`. Returns the number of bytes written."""
    n = 0
    with gzip.open(src, 'rb') as i, open(dst, 'wb') as o:
        while True:
            b = i.read(1024 * 1024)
            if not b:
                break
            o.write(b)
            n += len(b)
    return str(n)
