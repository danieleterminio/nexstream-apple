# -*- coding: utf-8 -*-
"""NexStream engine bridge: runs the Stream4Me Kodi addon headless (sakee stubs) and exposes a small JSON API.

Called from Kotlin via Chaquopy. Every public function takes/returns plain str/int so the JNI boundary stays simple.
"""
import os, sys, json, re, time, threading, traceback, logging
from concurrent.futures import ThreadPoolExecutor, wait, FIRST_COMPLETED

log = logging.getLogger('nxbridge')
_state = {'ready': False, 'addon': None, 'data': None, 'lock': threading.Lock()}
ADDON_ID = 'plugin.video.s4me'


# ------------------------------------------------------------------ init
def init(addon_path, data_path):
    """addon_path: extracted Stream4Me folder. data_path: writable dir used as Kodi home (settings, cache, cookies)."""
    with _state['lock']:
        if _state['ready']:
            return json.dumps({'ok': True, 'already': True})
        t0 = time.time()
        profile = os.path.join(data_path, 'userdata')
        addon_data = os.path.join(profile, 'addon_data', ADDON_ID)
        for d in (addon_data, os.path.join(addon_data, 'settings_channels'), os.path.join(addon_data, 'settings_servers')):
            os.makedirs(d, exist_ok=True)
        os.environ['KODI_HOME'] = data_path
        os.environ['KODI_INTERACTIVE'] = '0'
        os.environ['KODI_STUB_VERBOSE'] = '0'
        sys.argv = ['plugin://%s/' % ADDON_ID, '1', '']
        for p in (addon_path, os.path.join(addon_path, 'lib')):
            if p not in sys.path:
                sys.path.insert(0, p)

        from sakee import addoninfo, stub
        info = addoninfo.AddonData(kodi_home_path=data_path, add_on_id=ADDON_ID, add_on_path=addon_path, kodi_profile_path=profile)
        addoninfo.get_add_on_info_from_calling_script = lambda *a, **k: info
        # route sakee's colored stdout prints to logging
        stub.KodiStub.print_line = staticmethod(lambda line, color=None, verbose=False: log.debug(line) if not verbose else None)

        import xbmc, xbmcvfs
        xbmc.translatePath = xbmcvfs.translatePath
        from platformcode import config, logger
        logger.DEBUG_ENABLED = False
        try:
            config.set_setting('tmdb_active', False)   # metadata is handled by the app (TMDB in Kotlin)
            config.set_setting('checklinks', False)
            config.set_setting('autoplay', False)
            config.set_setting('addon_update_enabled', False)
        except Exception:
            log.warning(traceback.format_exc())
        from core import httptools
        httptools.HTTPTOOLS_DEFAULT_DOWNLOAD_TIMEOUT = 20
        _state.update(ready=True, addon=addon_path, data=data_path)
        return json.dumps({'ok': True, 'elapsed': round(time.time() - t0, 2), 'python': sys.version.split()[0]})


def _ensure():
    if not _state['ready']:
        raise RuntimeError('nxbridge.init() not called')


def _item():
    from core.item import Item
    return Item


def _clean(s):
    s = re.sub(r'\[/?[A-Za-z][^\]]*\]', '', s or '')
    return re.sub(r'\s+', ' ', s).strip()


def _ctype(it):
    ct = (it.contentType or '').lower()
    if ct in ('movie', 'tvshow', 'episode', 'season'):
        return 'tvshow' if ct in ('tvshow', 'season', 'episode') else 'movie'
    return 'tvshow' if it.action == 'episodios' or it.contentSerieName else 'movie'


def _year(it):
    y = it.infoLabels.get('year') if isinstance(it.infoLabels, dict) else None
    try:
        y = int(str(y)[:4])
        return y if 1900 < y < 2100 else 0
    except Exception:
        m = re.search(r'\((\d{4})\)', it.title or '')
        return int(m.group(1)) if m else 0


def _pack(it, channel=None):
    return {
        'channel': channel or it.channel,
        'title': _clean(it.contentTitle or it.contentSerieName or it.fulltitle or it.title),
        'year': _year(it),
        'type': _ctype(it),
        'action': it.action,
        'url': it.url,
        'thumb': it.thumbnail or '',
        'item': it.tojson(),
    }


# ------------------------------------------------------------------ channels
def reload():
    """After the addon folder was replaced on disk: drop cached channel/server modules and parameter caches."""
    _ensure()
    n = 0
    for name in list(sys.modules):
        if name.startswith(('channels.', 'servers.', 'specials.')) or name in ('channels', 'servers', 'specials'):
            del sys.modules[name]; n += 1
    try:
        from core import channeltools, servertools
        channeltools.dict_channels_parameters.clear()
        servertools.dict_servers_parameters.clear()
        servertools.server_list.clear()
    except Exception:
        log.warning(traceback.format_exc())
    try:
        import importlib; importlib.invalidate_caches()
    except Exception:
        pass
    chans = json.loads(channels())
    return json.dumps({'ok': True, 'purged': n, 'channels': len(chans), 'active': sum(1 for c in chans if c.get('active'))})


def channels():
    """Active channels with categories/languages (from channels/*.json)."""
    _ensure()
    out = []
    cdir = os.path.join(_state['addon'], 'channels')
    for f in sorted(os.listdir(cdir)):
        if not f.endswith('.json'):
            continue
        try:
            d = json.load(open(os.path.join(cdir, f), encoding='utf-8'))
            out.append({'id': d.get('id'), 'name': d.get('name'), 'active': bool(d.get('active')),
                        'categories': d.get('categories', []), 'language': d.get('language', [])})
        except Exception:
            pass
    return json.dumps(out)


def _channel_module(ch):
    return __import__('channels.%s' % ch, fromlist=['channels.%s' % ch])


# ------------------------------------------------------------------ search
def _norm(s):
    s = _clean(s).lower()
    s = re.sub(r'\(.*?\)|\[.*?\]', ' ', s)
    s = re.sub(r'[^a-z0-9àèéìòù ]+', ' ', s)
    s = re.sub(r'\b(ita|sub ita|streaming|hd|the|il|la|lo|le|gli|i|un|una|serie tv|stagione \d+|\d+x\d+)\b', ' ', s)
    return re.sub(r'\s+', ' ', s).strip()


def _score(q, title, year, want_year):
    a, b = _norm(q), _norm(title)
    if not a or not b:
        return 0.0
    if a == b:
        s = 1.0
    elif a in b or b in a:
        s = 0.55 + 0.4 * (min(len(a), len(b)) / max(len(a), len(b)))
    else:
        wa, wb = set(a.split()), set(b.split())
        s = len(wa & wb) / max(1, len(wa | wb))
    if want_year and year:
        s += 0.15 if abs(year - want_year) <= 1 else -0.2
    return s


def _search_one(ch, query, ctype, want_year):
    """Run a channel's search(); return (channel, [packed results], error)."""
    res = []
    try:
        mod = _channel_module(ch)
        if not hasattr(mod, 'search'):
            return ch, res, 'no search'
        Item = _item()
        item = Item(channel=ch, action='search', contentType=ctype if ctype in ('movie', 'tvshow') else '', extra=ctype)
        items = mod.search(item, query) or []
        for it in items:
            if it.action not in ('findvideos', 'episodios'):
                continue
            p = _pack(it, ch)
            if ctype in ('movie', 'tvshow') and p['type'] != ctype:
                # some channels don't set contentType reliably: keep if action is compatible
                if ctype == 'tvshow' and it.action != 'episodios':
                    continue
                if ctype == 'movie' and it.action != 'findvideos':
                    continue
            p['score'] = round(_score(query, p['title'], p['year'], want_year), 3)
            res.append(p)
    except Exception:
        return ch, res, traceback.format_exc()[-800:]
    return ch, res, None


def search(query, ctype='', year=0, channels_csv='', timeout=12, min_score=0.45):
    """Search all (or given) channels concurrently. Returns JSON: {results: [...sorted by score], errors: {ch: msg}}."""
    _ensure()
    if channels_csv:
        chs = [c for c in channels_csv.split(',') if c]
    else:
        chs = []
        for c in json.loads(channels()):
            cats = set(c['categories'])
            if not c['active'] or cats & {'torrent', 'music'} or cats <= {'live'}:
                continue
            if ctype == 'movie' and 'movie' not in cats:
                continue
            if ctype == 'tvshow' and not (cats & {'tvshow', 'anime'}):
                continue
            chs.append(c['id'])
    year = int(year or 0)
    results, errors = [], {}
    t0 = time.time()
    with ThreadPoolExecutor(max_workers=min(8, max(1, len(chs)))) as ex:
        futs = {ex.submit(_search_one, ch, query, ctype, year): ch for ch in chs}
        done, pending = wait(futs, timeout=timeout)
        for f in done:
            ch, res, err = f.result()
            results.extend(res)
            if err:
                errors[ch] = err
        for f in pending:
            errors[futs[f]] = 'timeout'
            f.cancel()
    results = [r for r in results if r['score'] >= min_score]
    results.sort(key=lambda r: (-r['score'], r['channel']))
    return json.dumps({'results': results, 'errors': errors, 'elapsed': round(time.time() - t0, 2)}, ensure_ascii=False)


# ------------------------------------------------------------------ episodes
_EP_RX = [re.compile(r'(\d{1,2})x(\d{1,3})', re.I), re.compile(r'S(\d{1,2})\s*E(\d{1,3})', re.I), re.compile(r'Stagione\s*(\d+).*?Episodio\s*(\d+)', re.I), re.compile(r'Ep(?:isodio)?\.?\s*(\d{1,3})', re.I)]


def _parse_ep(it):
    s = it.infoLabels.get('season') if isinstance(it.infoLabels, dict) else None
    e = it.infoLabels.get('episode') if isinstance(it.infoLabels, dict) else None
    if not s:
        s = getattr(it, 'contentSeason', None)
    if not e:
        e = getattr(it, 'contentEpisodeNumber', None)
    try:
        if s and e:
            return int(s), int(e)
    except Exception:
        pass
    t = _clean(it.title)
    for rx in _EP_RX[:3]:
        m = rx.search(t)
        if m:
            return int(m.group(1)), int(m.group(2))
    m = _EP_RX[3].search(t)
    if m:
        return 1, int(m.group(1))
    return 0, 0


def episodes(item_json):
    """Expand a tvshow result into episodes. Returns JSON list of {season, episode, title, item}."""
    _ensure()
    Item = _item()
    it = Item().fromjson(item_json)
    mod = _channel_module(it.channel)
    out = []
    try:
        eps = mod.episodios(it) or []
        for e in eps:
            if e.action not in ('findvideos',):
                continue
            s, n = _parse_ep(e)
            out.append({'season': s, 'episode': n, 'title': _clean(e.title), 'item': e.tojson()})
    except Exception:
        log.warning(traceback.format_exc())
    return json.dumps(out, ensure_ascii=False)


# ------------------------------------------------------------------ servers / resolve
def servers(item_json):
    """findvideos (+play) for a movie or episode item. Returns JSON list of server candidates."""
    _ensure()
    Item = _item()
    it = Item().fromjson(item_json)
    mod = _channel_module(it.channel)
    out = []
    try:
        srvs = mod.findvideos(it) if hasattr(mod, 'findvideos') else [it]
        if hasattr(mod, 'play'):
            tmp = []
            for s in srvs:
                try:
                    p = mod.play(s)
                    tmp.append(p[0] if p else s)
                except Exception:
                    tmp.append(s)
            srvs = tmp
        from core import servertools
        for s in srvs:
            if not s.server:
                continue
            params = servertools.get_server_parameters(s.server.lower()) or {}
            out.append({'server': s.server.lower(), 'url': s.url, 'title': _clean(s.title), 'quality': getattr(s, 'quality', '') or '',
                        'premium': bool(params.get('premium')), 'item': s.tojson()})
    except Exception:
        log.warning(traceback.format_exc())
    # free servers first, 'directo' first of all
    out.sort(key=lambda s: (s['premium'], 0 if s['server'] == 'directo' else 1))
    return json.dumps(out, ensure_ascii=False)


def _split_url(u):
    direct, _, hdr = u.partition('|')
    headers = {}
    if hdr:
        for kv in hdr.split('&'):
            k, _, v = kv.partition('=')
            if k:
                headers[k.strip()] = v.strip()
    return direct, headers


def resolve(server_item_json):
    """Resolve a server item into direct playable URLs. Returns JSON list of {url, headers, label, kind}."""
    _ensure()
    Item = _item()
    s = Item().fromjson(server_item_json)
    name = (s.server or '').lower()
    out = []
    try:
        mod = __import__('servers.%s' % name, fromlist=['servers.%s' % name])
        if hasattr(mod, 'test_video_exists'):
            ok, msg = mod.test_video_exists(s.url)
            if not ok:
                return json.dumps({'urls': [], 'error': str(msg)})
        urls = mod.get_video_url(s.url, video_password=getattr(s, 'password', '')) if 'video_password' in mod.get_video_url.__code__.co_varnames else mod.get_video_url(s.url)
        for label, u in [(x[0], x[1]) for x in urls]:
            direct, headers = _split_url(u)
            if direct.startswith('magnet:'):
                continue
            path = direct.split('?')[0].lower(); lab = (label or '').lower()
            kind = 'hls' if ('.m3u8' in path or 'hls' in lab or '/playlist/' in path) else 'dash' if ('.mpd' in path or 'dash' in lab) else 'progressive'
            out.append({'url': direct, 'headers': headers, 'label': _clean(label), 'kind': kind})
    except Exception:
        return json.dumps({'urls': out, 'error': traceback.format_exc()[-600:]})
    return json.dumps({'urls': out, 'error': None}, ensure_ascii=False)


def play(item_json, max_servers=4):
    """One-shot: servers() + resolve() until a playable URL is found. Returns JSON {url, headers, kind, server, tried}."""
    _ensure()
    tried = []
    for s in json.loads(servers(item_json))[:max_servers]:
        if s['premium']:
            continue
        r = json.loads(resolve(s['item']))
        tried.append({'server': s['server'], 'ok': bool(r['urls']), 'error': r.get('error')})
        if r['urls']:
            best = r['urls'][0]
            return json.dumps({'url': best['url'], 'headers': best['headers'], 'kind': best['kind'], 'label': best['label'], 'server': s['server'], 'tried': tried, 'all': r['urls']}, ensure_ascii=False)
    return json.dumps({'url': None, 'tried': tried})


def version():
    _ensure()
    try:
        import xml.etree.ElementTree as ET
        return ET.parse(os.path.join(_state['addon'], 'addon.xml')).getroot().attrib.get('version', '?')
    except Exception:
        return '?'
