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
    # no `with`: its exit waits for every thread, so one slow site would hold the answer far past `timeout`
    ex = ThreadPoolExecutor(max_workers=min(8, max(1, len(chs))))
    try:
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
    finally:
        ex.shutdown(wait=False, cancel_futures=True)
    results = [r for r in results if r['score'] >= min_score]
    results.sort(key=lambda r: (-r['score'], r['channel']))
    out = {'results': results, 'errors': errors, 'elapsed': round(time.time() - t0, 2)}
    if not channels_csv:
        with _search_lock:
            _search_cache[(query, ctype, year)] = (time.time(), out)
    return json.dumps(out, ensure_ascii=False)


# the last answer per (query, type, year): the source picker reuses what the player's own search just found
_search_cache = {}
_search_lock = threading.Lock()
SEARCH_TTL = 15 * 60


def _search_cached(query, ctype, year, timeout):
    with _search_lock:
        hit = _search_cache.get((query, ctype, int(year or 0)))
    if hit and time.time() - hit[0] < SEARCH_TTL:
        return hit[1]
    return json.loads(search(query, ctype, year, '', timeout))


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
            name = s.server.lower()
            out.append({'server': name, 'url': s.url, 'title': _clean(s.title), 'quality': _clean(getattr(s, 'quality', '') or ''),
                        'premium': bool(params.get('premium')), 'item': s.tojson(),
                        'id': _source_id(it.channel, name, s.url), 'channel': it.channel,
                        'host': _clean(getattr(s, 'serverName', '') or '') or params.get('name') or name,
                        'language': _clean(getattr(s, 'contentLanguage', '') or '')})
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
        if name in SINGLE_PROXY_SERVERS:
            _keep_proxy_alive(mod)
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


def _keep_proxy_alive(mod):
    """vidxgo stops its local proxy after 10 s without requests unless Kodi's player says it is playing, and the
    headless stubs never do: a paused video, or a player that has buffered a minute ahead (ExoPlayer waits until its
    buffer drops from 60 to 20 s; AVPlayer the same), found the proxy gone and failed over to another source. Our app
    owns the player, so the proxy stays up until the next vidxgo resolve replaces it (or the app exits)."""
    try:
        for k in ('WD_IDLE_PLAYED', 'WD_IDLE_NEVER'):
            if getattr(mod, k, 0) < 6 * 3600:
                setattr(mod, k, 6 * 3600)
    except Exception:
        log.warning(traceback.format_exc())


def play(item_json, max_servers=4, defer_single_proxy=0):
    """One-shot: servers() + resolve() until a playable URL is found. Returns JSON {url, headers, kind, server, tried}.

    defer_single_proxy (next-episode prefetch while another video plays): a server that plays through the add-on's one
    local proxy (SINGLE_PROXY_SERVERS) is not resolved, because resolving it restarts the proxy and stops the stream
    that is playing. When such a server is reached the answer is {url: None, deferred: True, server}: the item is
    right, the link is resolved at switch time."""
    _ensure()
    tried = []
    for s in json.loads(servers(item_json))[:max_servers]:
        if s['premium']:
            continue
        if defer_single_proxy and s['server'] in SINGLE_PROXY_SERVERS:
            return json.dumps({'url': None, 'deferred': True, 'server': s['server'], 'tried': tried, 'source': s['id'], 'channel': s['channel']})
        r = json.loads(resolve(s['item']))
        tried.append({'server': s['server'], 'ok': bool(r['urls']), 'error': r.get('error')})
        if r['urls']:
            best = r['urls'][0]
            return json.dumps({'url': best['url'], 'headers': best['headers'], 'kind': best['kind'], 'label': best['label'], 'server': s['server'], 'tried': tried, 'all': r['urls'],
                               'source': s['id'], 'channel': s['channel']}, ensure_ascii=False)
    return json.dumps({'url': None, 'tried': tried})


# ------------------------------------------------------------------ source picker ("Cambia fonte")
#
# The same API on Android (Chaquopy) and Apple (embedded CPython), so both apps show the same list:
#   sources_start(request_json) -> snapshot   starts (or reuses) the job that lists every source of a film / episode
#   sources_poll(job)           -> snapshot   what is known so far; the app polls it while the panel is open
#   source_play(job, id)        -> like play() for that one source (url, headers, kind, label, server, all, source, ...)
#   probe(url, headers_json, kind) -> {'ok', 'width', 'height', 'quality', 'codec', 'bitrate', 'note'}
# request_json: {"queries": [it, original], "type": "movie"|"tvshow", "year", "season", "episode", "probe": bool,
#                "known": [{"channel", "item", "title"}]}  (known = the search hit the player is using)
# snapshot: {"job", "state": "searching"|"listing"|"checking"|"done", "elapsed", "sources": [row...]}
# row: {"id", "channel", "site", "server", "host", "label", "language", "status": "listed"|"checking"|"ok"|"dead",
#       "quality": "4K"|"FHD"|"HD"|"SD"|"", "codec": "HEVC"|"H264"|"AV1"|"", "width", "height", "bitrate", "note"}
# Jobs live 20 minutes per title (a reopened panel is filled at once); 3 sources are checked at a time, each with
# time limits; a source that gives no link or whose link does not answer is "dead".

JOB_TTL = 20 * 60
RESOLVE_TIMEOUT = 25
PROBE_WORKERS = 3
_jobs = {}
_jobs_lock = threading.Lock()
_pool = ThreadPoolExecutor(max_workers=6)       # resolve calls that may overrun their time limit run here


def _source_id(channel, server, url):
    import hashlib
    return hashlib.sha1(('%s|%s|%s' % (channel, server, url)).encode('utf-8', 'replace')).hexdigest()[:12]


def _site_names():
    try:
        return {c['id']: c.get('name') or c['id'] for c in json.loads(channels())}
    except Exception:
        return {}


class _Job(object):
    def __init__(self, key, req):
        self.key = key
        self.req = req
        self.created = time.time()
        self.phase = 'searching'   # searching -> listing -> listed
        self.checked = False
        self.rows = []          # public rows, in listing order
        self.items = {}         # id -> server item json
        self.hits = {}          # id -> (channel, search item, title)
        self.resolved = {}      # id -> (time, urls ordered best first)
        self.lock = threading.Lock()
        self.probing = False
        self.listed = threading.Event()

    def snapshot(self):
        with self.lock:
            state = self.phase if self.phase != 'listed' else ('checking' if self.probing and not self.checked else 'done')
            return {'job': self.key, 'state': state, 'elapsed': round(time.time() - self.created, 1), 'sources': [dict(r) for r in self.rows]}

    def row(self, sid):
        for r in self.rows:
            if r['id'] == sid:
                return r
        return None

    def update(self, sid, **kv):
        with self.lock:
            r = self.row(sid)
            if r is not None:
                r.update(kv)


def _job_key(req):
    import hashlib
    k = json.dumps([req.get('type'), [q.strip().lower() for q in req.get('queries') or [] if q], int(req.get('year') or 0), int(req.get('season') or 0), int(req.get('episode') or 0)])
    return hashlib.sha1(k.encode('utf-8')).hexdigest()[:16]


def sources_start(request_json):
    _ensure()
    req = json.loads(request_json)
    key = _job_key(req)
    with _jobs_lock:
        for k in [k for k, j in _jobs.items() if time.time() - j.created > JOB_TTL]:
            del _jobs[k]
        job = _jobs.get(key)
        fresh = job is None
        if fresh:
            job = _jobs[key] = _Job(key, req)
    if fresh:
        threading.Thread(target=_list_sources, args=(job,), name='nx-sources', daemon=True).start()
    if req.get('probe') and not job.probing:
        job.probing = True
        threading.Thread(target=_check_sources, args=(job,), name='nx-probe', daemon=True).start()
    return json.dumps(job.snapshot(), ensure_ascii=False)


def sources_poll(job_key):
    job = _jobs.get(job_key)
    if job is None:
        return json.dumps({'job': job_key, 'state': 'gone', 'sources': []})
    return json.dumps(job.snapshot(), ensure_ascii=False)


def _episode_item(hit_item, season, episode):
    eps = json.loads(episodes(hit_item))
    for e in eps:
        if e['season'] == season and e['episode'] == episode:
            return e['item']
    if season == 1:
        for e in eps:
            if e['season'] == 0 and e['episode'] == episode:
                return e['item']
    return None


def _list_sources(job):
    """Search (reusing the player's search), then findvideos on every matching site, in parallel."""
    req = job.req
    ctype = req.get('type') or 'movie'
    year, season, episode = int(req.get('year') or 0), int(req.get('season') or 0), int(req.get('episode') or 0)
    names = _site_names()
    hits, seen = [], set()
    for k in req.get('known') or []:
        if k.get('item') and k['item'] not in seen:
            seen.add(k['item']); hits.append((k.get('channel') or '', k['item'], k.get('title') or ''))
    try:
        for q in [q for q in req.get('queries') or [] if q and q.strip()]:
            r = _search_cached(q.strip(), ctype, year, 20)
            res = r.get('results', [])
            top = max([h['score'] for h in res] or [0])
            for h in res:
                # the same title only, not its sequel ("Il gladiatore II" scores 0.86 against "Il gladiatore"): with a
                # year the year decides (a hit without one must match well), without one only the closest matches
                if h['score'] < 0.6:
                    continue
                if year and (abs(h['year'] - year) > 1 if h.get('year') else h['score'] < 0.8):
                    continue
                if not year and h['score'] < top - 0.2:
                    continue
                if h['item'] not in seen and len(hits) < 12:
                    seen.add(h['item']); hits.append((h['channel'], h['item'], h['title']))
    except Exception:
        log.warning(traceback.format_exc())
    with job.lock:
        job.phase = 'listing'

    def one(hit):
        ch, item, title = hit
        try:
            target = _episode_item(item, season, episode) if ctype == 'tvshow' else item
            if not target:
                return hit, []
            return hit, json.loads(servers(target))
        except Exception:
            log.warning(traceback.format_exc())
            return hit, []

    from concurrent.futures import as_completed
    ex = ThreadPoolExecutor(max_workers=4)
    rank = {}
    try:
        futs = {ex.submit(one, h): n for n, h in enumerate(hits)}
        # rows show up as each site answers, but stay in the order of the search (best match first): the apps keep
        # the focus on a row by its id, so a row added above it does not move it
        for f in as_completed(futs, timeout=40):
            try:
                hit, srvs = f.result()
            except Exception:
                continue
            with job.lock:
                for k, s in enumerate(srvs):
                    if s['premium'] or job.row(s['id']) is not None:
                        continue
                    ch = s.get('channel') or hit[0]
                    job.items[s['id']] = s['item']
                    job.hits[s['id']] = hit
                    rank[s['id']] = (futs[f], k)
                    job.rows.append({'id': s['id'], 'channel': ch, 'site': names.get(ch, ch), 'server': s['server'], 'host': s.get('host') or s['server'],
                                     'label': s.get('quality') or '', 'language': s.get('language') or '', 'status': 'listed',
                                     'quality': '', 'codec': '', 'width': 0, 'height': 0, 'bitrate': 0, 'note': ''})
                job.rows.sort(key=lambda r: rank.get(r['id'], (99, 0)))
    except Exception as e:      # as_completed timed out (a slow site): what came is kept
        log.info('listing stopped after 40 s: %s' % e)
    finally:
        ex.shutdown(wait=False, cancel_futures=True)
    with job.lock:
        job.phase = 'listed'
    job.listed.set()


def _resolve_limited(item_json):
    f = _pool.submit(resolve, item_json)
    try:
        return json.loads(f.result(timeout=RESOLVE_TIMEOUT))
    except Exception as e:
        return {'urls': [], 'error': 'timeout' if 'Timeout' in type(e).__name__ else str(e)[:200]}


_QRANK = {'4K': 4, 'FHD': 3, 'HD': 2, 'SD': 1, '': 0}


# Servers that play through ONE local proxy of the add-on (vidxgo: a single 127.0.0.1 relay, restarted by every
# resolve): checking them in the background would stop the stream that is playing. They are listed as playable and
# resolved only when picked.
SINGLE_PROXY_SERVERS = ('vidxgo',)


def _check_one(job, sid):
    with job.lock:
        server = ((job.row(sid) or {}).get('server') or '').lower()
    if server in SINGLE_PROXY_SERVERS:
        job.update(sid, status='ok', quality='', codec='', note='Si controlla quando la scegli')
        return
    job.update(sid, status='checking')
    r = _resolve_limited(job.items[sid])
    urls = r.get('urls') or []
    if not urls:
        err = r.get('error') or ''
        note = 'Non risponde' if err == 'timeout' else 'Errore del sito' if ('Traceback' in err or ', line ' in err) else 'File rimosso' if err else 'Nessun link'
        job.update(sid, status='dead', note=note)
        return
    probed = []
    for u in urls[:2]:
        p = probe(u['url'], json.dumps(u.get('headers') or {}), u.get('kind') or '', as_dict=True)
        probed.append((p, u))
        if p['ok'] and p['quality'] in ('4K', 'FHD'):
            break
    good = [(p, u) for p, u in probed if p['ok']]
    if not good:
        job.update(sid, status='dead', note=probed[0][0].get('note') or 'Non risponde')
        return
    good.sort(key=lambda pu: -(_QRANK.get(pu[0]['quality'], 0) * 10 + (1 if pu[0]['codec'] == 'HEVC' else 0)))
    best = good[0][0]
    ordered = [u for _, u in good] + [u for u in urls if all(u is not g for _, g in good)]
    with job.lock:
        job.resolved[sid] = (time.time(), ordered)
    job.update(sid, status='ok', quality=best['quality'], codec=best['codec'], width=best['width'], height=best['height'], bitrate=best['bitrate'], note='')


def _check_sources(job):
    """Checks the sources as they are listed, PROBE_WORKERS at a time, in the order of the list."""
    done, futs = set(), []
    ex = ThreadPoolExecutor(max_workers=PROBE_WORKERS)
    t0 = time.time()
    try:
        while time.time() - t0 < 180:
            with job.lock:
                todo = [r['id'] for r in job.rows if r['status'] == 'listed' and r['id'] not in done]
            for sid in todo:
                done.add(sid)
                futs.append(ex.submit(_check_one, job, sid))
            if job.listed.is_set() and not todo and all(f.done() for f in futs):
                break
            time.sleep(0.3)
    except Exception:
        log.warning(traceback.format_exc())
    finally:
        ex.shutdown(wait=False, cancel_futures=True)
    with job.lock:
        for r in job.rows:
            if r['status'] in ('listed', 'checking'):
                r['status'] = 'dead'; r['note'] = 'Non risponde'
        job.checked = True


def source_play(job_key, sid):
    """Plays one source of the list: its links (reused when checked in the last 2 minutes), best one first."""
    _ensure()
    job = _jobs.get(job_key)
    if job is None or sid not in job.items:
        return json.dumps({'url': None, 'error': 'gone'})
    with job.lock:
        cached = job.resolved.get(sid)
        row = dict(job.row(sid) or {})
        hit = job.hits.get(sid)
    if cached and time.time() - cached[0] < 120:
        urls = cached[1]
    else:
        r = _resolve_limited(job.items[sid])
        urls = r.get('urls') or []
        if not urls:
            job.update(sid, status='dead', note='Nessun link')
            return json.dumps({'url': None, 'error': r.get('error') or 'no link'})
    best = urls[0]
    out = {'url': best['url'], 'headers': best.get('headers') or {}, 'kind': best.get('kind') or 'progressive', 'label': best.get('label') or '',
           'server': row.get('server') or '', 'channel': row.get('channel') or '', 'source': sid, 'all': urls, 'tried': []}
    if hit:
        out['hit'] = {'channel': hit[0], 'item': hit[1], 'title': hit[2]}
    return json.dumps(out, ensure_ascii=False)


# ---- what a link really is: HLS master playlist, MP4 / MKV header, or the first TS segment of a media playlist

PROBE_UA = 'Mozilla/5.0 (Linux; Android 11; SHIELD Android TV) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'


def _quality_of(w, h):
    if not w and not h:
        return ''
    if h >= 1500 or w >= 3000:
        return '4K'
    if h >= 1000 or w >= 1800:
        return 'FHD'
    if h >= 700 or w >= 1200:
        return 'HD'
    return 'SD'


def _get(url, headers, nbytes, start=0, timeout=(6, 9)):
    """First `nbytes` of `url` (a Range request; servers that ignore it are cut off). Returns (status, final url, bytes)."""
    import requests
    try:
        import urllib3
        urllib3.disable_warnings()
    except Exception:
        pass
    try:
        from core import resolverdns
        resolverdns.install_dns_override()
    except Exception:
        pass
    h = {'User-Agent': PROBE_UA}
    h.update(headers or {})
    h['Range'] = 'bytes=%d-%d' % (start, start + nbytes - 1)
    with requests.get(url, headers=h, stream=True, timeout=timeout, allow_redirects=True, verify=False) as r:
        buf, t0 = b'', time.time()
        if r.status_code < 400:
            for chunk in r.iter_content(64 * 1024):
                buf += chunk
                if len(buf) >= nbytes or time.time() - t0 > 12:
                    break
        return r.status_code, r.url, buf[:nbytes]


class _Bits(object):
    def __init__(self, data):
        # emulation prevention bytes (00 00 03) go before parsing
        self.d = re.sub(b'\x00\x00\x03', b'\x00\x00', data)
        self.p = 0

    def u(self, n):
        v = 0
        for _ in range(n):
            byte = self.d[self.p >> 3]
            v = (v << 1) | ((byte >> (7 - (self.p & 7))) & 1)
            self.p += 1
        return v

    def ue(self):
        z = 0
        while self.u(1) == 0:
            z += 1
            if z > 31:
                raise ValueError('ue')
        return (1 << z) - 1 + self.u(z)

    def se(self):
        v = self.ue()
        return (v + 1) // 2 if v & 1 else -(v // 2)


def _h264_sps(nal):
    b = _Bits(nal[1:])
    profile = b.u(8); b.u(16); b.ue()
    chroma = 1
    if profile in (100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135):
        chroma = b.ue()
        if chroma == 3:
            b.u(1)
        b.ue(); b.ue(); b.u(1)
        if b.u(1):
            for i in range(8 if chroma != 3 else 12):
                if b.u(1):
                    last, nxt = 8, 8
                    for _ in range(16 if i < 6 else 64):
                        if nxt:
                            nxt = (last + b.se() + 256) % 256
                        last = nxt or last
    b.ue()
    poc = b.ue()
    if poc == 0:
        b.ue()
    elif poc == 1:
        b.u(1); b.se(); b.se()
        for _ in range(b.ue()):
            b.se()
    b.ue(); b.u(1)
    wmb, hmu = b.ue() + 1, b.ue() + 1
    frame_mbs_only = b.u(1)
    if not frame_mbs_only:
        b.u(1)
    b.u(1)
    cl = cr = ct = cb = 0
    if b.u(1):
        cl, cr, ct, cb = b.ue(), b.ue(), b.ue(), b.ue()
    w = wmb * 16 - 2 * (cl + cr)
    h = (2 - frame_mbs_only) * hmu * 16 - 2 * (2 - frame_mbs_only) * (ct + cb)
    return w, h


def _hevc_sps(nal):
    b = _Bits(nal[2:])
    b.u(4)
    sub = b.u(3)
    b.u(1)
    b.u(88); b.u(8)                       # general profile / tier / level
    flags = [(b.u(1), b.u(1)) for _ in range(sub)]
    if sub > 0:
        for _ in range(sub, 8):
            b.u(2)
    for pp, lp in flags:
        if pp:
            b.u(88)
        if lp:
            b.u(8)
    b.ue()
    chroma = b.ue()
    if chroma == 3:
        b.u(1)
    w, h = b.ue(), b.ue()
    if b.u(1):
        sx, sy = (2, 2) if chroma == 1 else (2, 1) if chroma == 2 else (1, 1)
        l, r, t, bt = b.ue(), b.ue(), b.ue(), b.ue()
        w -= sx * (l + r); h -= sy * (t + bt)
    return w, h


def _scan_nal(data):
    """Width, height and codec from the first SPS found in an Annex-B byte stream."""
    i = 0
    while True:
        i = data.find(b'\x00\x00\x01', i)
        if i < 0 or i + 4 >= len(data):
            return None
        hdr = data[i + 3]
        nal = data[i + 3:i + 3 + 400]
        try:
            if hdr & 0x9F == 0x07 and (hdr & 0x60):               # H.264 SPS (nal_ref_idc != 0)
                w, h = _h264_sps(nal)
                if 100 < w < 8000 and 100 < h < 5000:
                    return w, h, 'H264'
            elif (hdr >> 1) & 0x3F == 33 and len(nal) > 2:         # HEVC SPS
                w, h = _hevc_sps(nal)
                if 100 < w < 8000 and 100 < h < 5000:
                    return w, h, 'HEVC'
        except Exception:
            pass
        i += 3


def _ts_payloads(data):
    """Joins the payloads of the TS packets of each PID (a segment may carry a fake image header in front)."""
    start = -1
    for k in range(min(len(data) - 376, 4096)):
        if data[k] == 0x47 and data[k + 188] == 0x47 and data[k + 376] == 0x47:
            start = k
            break
    if start < 0:
        return None
    pids = {}
    for p in range(start, len(data) - 187, 188):
        pk = data[p:p + 188]
        if pk[0] != 0x47:
            break
        pid = ((pk[1] & 0x1F) << 8) | pk[2]
        afc = (pk[3] >> 4) & 3
        off = 4
        if afc & 2:
            off += 1 + pk[4]
        if afc & 1 and off < 188:
            pids.setdefault(pid, bytearray()).extend(pk[off:])
    return [bytes(v) for v in pids.values()]


def _mp4_video(data):
    """Width / height / codec of the video sample entry in an MP4 'moov' (or an fMP4 init segment)."""
    for tag, codec in ((b'hvc1', 'HEVC'), (b'hev1', 'HEVC'), (b'avc1', 'H264'), (b'avc3', 'H264'), (b'av01', 'AV1'), (b'vp09', 'VP9')):
        i = data.find(tag)
        while i >= 4:
            size = int.from_bytes(data[i - 4:i], 'big')
            if 86 <= size < 1 << 20 and i + 32 <= len(data):
                w, h = int.from_bytes(data[i + 28:i + 30], 'big'), int.from_bytes(data[i + 30:i + 32], 'big')
                if 100 < w < 8000 and 100 < h < 5000:
                    return w, h, codec
            i = data.find(tag, i + 4)
    return None


def _mp4_moov_offset(data):
    """Where 'moov' starts when it is not at the head of the file (walks the top-level boxes)."""
    p = 0
    while p + 8 <= len(data):
        size = int.from_bytes(data[p:p + 4], 'big')
        kind = data[p + 4:p + 8]
        if size == 1 and p + 16 <= len(data):
            size = int.from_bytes(data[p + 8:p + 16], 'big')
        if kind == b'moov':
            return p
        if size < 8:
            return None
        p += size
    return p if p > len(data) else None


def _ebml_vint(d, p, keep_marker):
    b0 = d[p]
    n = 1
    while n <= 8 and not (b0 & (0x80 >> (n - 1))):
        n += 1
    if n > 8:
        raise ValueError('vint')
    v = b0 if keep_marker else b0 & ((0x80 >> (n - 1)) - 1)
    for k in range(1, n):
        v = (v << 8) | d[p + k]
    unknown = not keep_marker and v == (1 << (7 * n)) - 1
    return v, n, unknown


def _mkv_video(data):
    """PixelWidth / PixelHeight / CodecID of the first video track of a Matroska / WebM header."""
    MASTER = {0x18538067, 0x1654AE6B, 0xAE, 0xE0}
    found = {}

    def walk(p, end, depth):
        while p < end and p < len(data) - 2:
            eid, n1, _ = _ebml_vint(data, p, True)
            size, n2, unknown = _ebml_vint(data, p + n1, False)
            body = p + n1 + n2
            if eid == 0x1F43B675:              # Cluster: the header is over
                return True
            if eid in MASTER:
                if eid == 0xAE and 'w' not in found:
                    found.pop('codec', None)     # the codec of this track, not of an audio track before it
                if walk(body, len(data) if unknown else min(end, body + size), depth + 1):
                    return True
                if eid == 0xAE and 'w' in found:
                    return True
            elif eid in (0xB0, 0xBA, 0x86) and body + size <= len(data):
                v = data[body:body + size]
                if eid == 0x86:
                    found.setdefault('codec', v.decode('ascii', 'replace'))
                else:
                    found.setdefault('w' if eid == 0xB0 else 'h', int.from_bytes(v, 'big'))
            if unknown:
                return False
            p = body + size
        return False

    try:
        if data[:4] != b'\x1a\x45\xdf\xa3':
            return None
        size, n2, _ = _ebml_vint(data, 4, False)
        walk(4 + n2 + size, len(data), 0)
    except Exception:
        pass
    if 'w' in found and 'h' in found:
        c = found.get('codec', '')
        codec = 'HEVC' if 'HEVC' in c else 'H264' if 'AVC' in c else 'AV1' if 'AV1' in c else 'VP9' if 'VP9' in c else ''
        return found['w'], found['h'], codec
    return None


def _parse_attrs(s):
    return dict((k.upper(), v.strip('"')) for k, v in re.findall(r'([A-Z0-9-]+)=("[^"]*"|[^,]*)', s))


def _probe_segment(url, headers):
    st, final, data = _get(url, headers, 400 * 1024)
    if st >= 400 or not data:
        return None, st
    if data[4:8] in (b'ftyp', b'styp', b'moof', b'moov') or data[4:8] == b'sidx':
        return _mp4_video(data), st
    pays = _ts_payloads(data)
    for p in pays or []:
        v = _scan_nal(p)
        if v:
            return v, st
    return _scan_nal(data), st


def probe(url, headers_json='{}', kind='', as_dict=False):
    """What a playable link really carries. Never raises; ok=False when the link does not answer."""
    from urllib.parse import urljoin
    out = {'ok': False, 'width': 0, 'height': 0, 'quality': '', 'codec': '', 'bitrate': 0, 'note': ''}
    try:
        headers = json.loads(headers_json or '{}') if isinstance(headers_json, str) else (headers_json or {})
        st, final, data = _get(url, headers, 512 * 1024)
        if st >= 400 or not data:
            out['note'] = 'Errore %s' % st if st >= 400 else 'Nessun dato'
            return out if as_dict else json.dumps(out)
        out['ok'] = True
        w = h = 0
        codec = ''
        head = data[:16].lstrip(b'\xef\xbb\xbf \r\n\t')
        if head.startswith(b'#EXTM3U'):
            text = data.decode('utf-8', 'replace')
            lines = [l.strip() for l in text.splitlines()]
            variants = []
            for i, l in enumerate(lines):
                if l.startswith('#EXT-X-STREAM-INF:'):
                    a = _parse_attrs(l.split(':', 1)[1])
                    m = re.match(r'(\d+)x(\d+)', a.get('RESOLUTION', ''))
                    nxt = next((x for x in lines[i + 1:] if x and not x.startswith('#')), '')
                    variants.append((int(m.group(1)) if m else 0, int(m.group(2)) if m else 0, int(a.get('BANDWIDTH', '0') or 0), a.get('CODECS', ''), nxt))
            if variants:
                vw, vh, bw, cs, uri = max(variants, key=lambda v: (v[1], v[2]))
                w, h = vw, vh
                out['bitrate'] = bw // 1000
                codec = 'HEVC' if re.search(r'hvc1|hev1', cs) else 'AV1' if 'av01' in cs else 'H264' if 'avc1' in cs else ''
                if not h and uri:                     # no RESOLUTION: look inside the best variant
                    sub = json.loads(probe(urljoin(final, uri), headers, 'hls'))
                    w, h, codec = sub['width'], sub['height'], codec or sub['codec']
            else:                                     # a media playlist: the init segment or the first segment
                init = re.search(r'#EXT-X-MAP:.*URI="([^"]+)"', text)
                seg = init.group(1) if init else next((x for x in lines if x and not x.startswith('#')), '')
                if seg:
                    v, sst = _probe_segment(urljoin(final, seg), headers)
                    if v:
                        w, h, codec = v
                    elif sst >= 400:
                        out['ok'] = False; out['note'] = 'Errore %s' % sst
        elif b'<MPD' in data[:2048]:
            text = data.decode('utf-8', 'replace')
            reps = []
            for m in re.finditer(r'<(?:Representation|AdaptationSet)\b([^>]*)>', text):
                a = dict(re.findall(r'(\w+)="([^"]*)"', m.group(1)))
                if a.get('width', '').isdigit() and a.get('height', '').isdigit():
                    reps.append((int(a['width']), int(a['height']), int(a.get('bandwidth', '0') or 0) if a.get('bandwidth', '').isdigit() else 0, a.get('codecs', '')))
            if reps:
                w, h, bw, cs = max(reps, key=lambda v: (v[1], v[2]))
                out['bitrate'] = bw // 1000
                codec = 'HEVC' if re.search(r'hvc1|hev1', cs) else 'AV1' if 'av01' in cs else 'H264' if 'avc1' in cs else ''
        elif data[:4] == b'\x1a\x45\xdf\xa3':
            v = _mkv_video(data)
            if v:
                w, h, codec = v
        elif data[4:8] in (b'ftyp', b'moov', b'free', b'mdat', b'wide', b'skip'):
            v = _mp4_video(data)
            if not v:
                off = _mp4_moov_offset(data)
                if off and off > len(data) - 64:
                    _, _, tail = _get(final, headers, 768 * 1024, start=off)
                    v = _mp4_video(tail)
            if v:
                w, h, codec = v
        else:
            v = None
            pays = _ts_payloads(data)
            for p in pays or []:
                v = _scan_nal(p)
                if v:
                    break
            if v:
                w, h, codec = v
        out.update(width=w, height=h, codec=codec, quality=_quality_of(w, h))
    except Exception as e:
        out['ok'] = False
        out['note'] = 'Non risponde' if 'Timeout' in type(e).__name__ or 'Connection' in type(e).__name__ else type(e).__name__
    return out if as_dict else json.dumps(out)


def version():
    _ensure()
    try:
        import xml.etree.ElementTree as ET
        return ET.parse(os.path.join(_state['addon'], 'addon.xml')).getroot().attrib.get('version', '?')
    except Exception:
        return '?'
