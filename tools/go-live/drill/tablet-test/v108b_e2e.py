"""v1.08b «the app moves to app.bubalina.it» in the browser. Both addresses are served from the local fabula-tablet/ files through
Playwright routes (nothing reaches Netlify, GitHub or Supabase; Supabase calls get an empty answer), so the test runs anywhere.
The new address «is ready» when its sw.js says perla-v75 or later (it does once the release is approved); the test serves v74 to
play «before the approval», and no answer at all to play «offline».
- Before the approval, or offline: nothing moves and the tablet shows no bar.
- A Console page on the old address goes to the same page on https://app.bubalina.it, ?query and #hash kept.
- The tablet with nothing waiting goes at once, carrying its name and id (?device=, ?device_uid=); on the new address the id is
  taken and the parameter removed from the address bar.
- The tablet with records waiting stays and says what is waiting; once sent it does NOT move by itself in the middle of the work:
  the «Passa al nuovo indirizzo» button turns on, and a tap moves it.
- Any refused save (reported to the office or not) and a photo still to send hold the tablet back.
- A Console page with something waiting on that tablet stays, and the old address keeps its copy of the app (no clean-up).
- A path that would leave the new address (//other-site/…) stays on app.bubalina.it.
- On the new address nothing moves; an id already there is kept while that address has its own work waiting, else replaced.
Expect "FAILURES: none"."""
import json, mimetypes, os
from urllib.parse import urlparse
from playwright.sync_api import sync_playwright

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '../../../../fabula-tablet'))
OLD, NEW = 'https://flourishing-swan-6729c4.netlify.app', 'https://app.bubalina.it'
UID = '11111111-2222-4333-8444-555555555555'
fails = []


def check(name, cond, info=''):
    print(('PASS ' if cond else 'FAIL ') + name + (f'  [{str(info)[:300]}]' if info != '' else ''), flush=True)
    if not cond:
        fails.append(name)


def serve(route, new_sw=None):
    path = urlparse(route.request.url).path
    if new_sw is not None and path == '/sw.js':          # the new address's version, as the release would publish it
        if new_sw == 'down':
            return route.abort('internetdisconnected')
        return route.fulfill(status=200, body=f"const CACHE = '{new_sw}';", headers={'content-type': 'text/javascript', 'access-control-allow-origin': '*'})
    f = os.path.join(ROOT, (path.lstrip('/') or 'index.html'))
    if os.path.isdir(f):
        f = os.path.join(f, 'index.html')
    if not os.path.isfile(f) and os.path.isfile(os.path.join(ROOT, os.path.basename(path))):
        f = os.path.join(ROOT, os.path.basename(path))   # a lenient host: //anything/index.html still serves the app
    if not os.path.isfile(f):
        return route.fulfill(status=404, body='not found')
    ctype = mimetypes.guess_type(f)[0] or 'application/octet-stream'
    route.fulfill(status=200, body=open(f, 'rb').read(), headers={'content-type': ctype, 'access-control-allow-origin': '*'})


def context(b, new_sw='perla-v75'):
    ctx = b.new_context(service_workers='block', locale='it-IT')
    ctx.elsewhere = []
    ctx.route(OLD + '/**', serve)
    ctx.route(NEW + '/**', lambda r: serve(r, new_sw))
    ctx.route('**/*.supabase.co/**', lambda r: r.fulfill(status=200, body='{}', headers={'content-type': 'application/json', 'access-control-allow-origin': '*'}))
    ctx.route('https://evil.example/**', lambda r: (ctx.elsewhere.append(r.request.url), r.fulfill(status=200, body='elsewhere')))
    return ctx


def seed(ctx, origin, items, photos=0, cache=False):
    """localStorage (and photos, a cache) of one address, set from a tiny page on it (a 404 page of the routed host is enough)."""
    p = ctx.new_page()
    p.goto(origin + '/__seed__')
    p.evaluate("items => { localStorage.clear(); for (const [k, v] of Object.entries(items)) localStorage.setItem(k, v); }", items)
    if photos:
        p.evaluate("""n => new Promise((res, rej) => { const r = indexedDB.open('perla_photos', 1);
          r.onupgradeneeded = () => r.result.createObjectStore('p', { keyPath: 'id' });
          r.onsuccess = () => { const t = r.result.transaction('p', 'readwrite'); for (let i = 0; i < n; i++) t.objectStore('p').put({ id: 'ph' + i, blob: 'x' });
            t.oncomplete = () => { r.result.close(); res(); }; t.onerror = () => rej(t.error); }; r.onerror = () => rej(r.error); })""", photos)
    if cache:
        p.evaluate("caches.open('perla-v74').then(c => c.put('/x', new Response('x')))")
    p.close()


def wait_url(p, prefix, ms):
    try:
        p.wait_for_url(lambda u: u.startswith(prefix), timeout=ms)
        return True
    except Exception:
        return False


def bar(p):
    return p.evaluate("""(() => { const b = document.getElementById('move-home'); if (!b) return null;
      const k = b.querySelector('button'); return { text: b.textContent, on: !k.disabled }; })()""")


with sync_playwright() as pw:
    b = pw.chromium.launch()

    # 1. before the approval (the new address still serves v74) and offline: nothing moves, no bar
    for state, label in (('perla-v74', 'before the release is approved (new address on v74)'), ('down', 'when the new address does not answer (offline)')):
        ctx = context(b, state)
        p = ctx.new_page()
        p.goto(OLD + '/console.html?x=1')
        p.wait_for_timeout(2500)
        stay_console = p.url.startswith(OLD)
        p.goto(OLD + '/index.html')
        p.wait_for_timeout(2500)
        check(f'{label}: the Console and the tablet stay on the old address, no bar', stay_console and p.url.startswith(OLD) and bar(p) is None, [p.url, bar(p)])
        ctx.close()

    # 2. a Console page with ?query and #hash, once the new address serves v1.08b
    ctx = context(b)
    p = ctx.new_page()
    p.goto(OLD + '/console.html?x=1#oggi')
    moved = wait_url(p, NEW, 8000)
    check('Console on the old address → the same page on app.bubalina.it, query and hash kept', moved and p.url == NEW + '/console.html?x=1#oggi', p.url)
    ctx.close()

    # 3. the tablet with nothing waiting: name and id travel with it
    ctx = context(b)
    seed(ctx, OLD, {'fabula_device': 'tablet-2', 'perla_device_uid': UID})
    p = ctx.new_page()
    p.goto(OLD + '/index.html')
    moved = wait_url(p, NEW, 8000)
    p.wait_for_timeout(500)
    st = p.evaluate("[localStorage.getItem('fabula_device'), localStorage.getItem('perla_device_uid'), location.search]") if moved else None
    check('tablet with nothing waiting → moves when it starts', moved, p.url)
    check('…as the same tablet: name and id kept on the new address', st and st[0] == 'tablet-2' and st[1] == UID, st)
    check('…and the id is not left in the address bar', st and 'device_uid' not in st[2] and 'device=tablet-2' in st[2], st)
    ctx.close()

    # 4. the tablet with records waiting: it stays, says what is waiting, and after they are sent waits for a tap
    ctx = context(b)
    seed(ctx, OLD, {'fabula_queue': json.dumps([{'qid': 'a', 'table': 'haccp_logs'}, {'qid': 'b', 'table': 'haccp_logs'}])})
    p = ctx.new_page()
    errors = []
    p.on('pageerror', lambda e: errors.append(str(e)))
    p.goto(OLD + '/index.html')
    p.wait_for_timeout(2500)
    s = bar(p)
    check('tablet with records waiting: stays on the old address', p.url.startswith(OLD), p.url)
    check('…the bar says what is waiting, and the button is off', s and '2 registrazioni da inviare' in s['text'] and 'app.bubalina.it' in s['text'] and not s['on'], s)
    p.evaluate("localStorage.setItem('fabula_queue', '[]')")          # what app.js does once the records are sent
    p.wait_for_timeout(12000)
    s = bar(p)
    check('…once sent it does not move by itself in the middle of the work', p.url.startswith(OLD), p.url)
    check('…the button turns on and the bar says nothing is left', s and s['on'] and 'non resta niente' in s['text'], s)
    p.click('#move-home button')
    moved = wait_url(p, NEW, 8000)
    check('…a tap on «Passa al nuovo indirizzo» moves it', moved, p.url)
    check('…no page errors', not errors, errors)
    ctx.close()

    # 5. refused saves (reported or not) and photos hold the tablet back
    for items, photos, want, label in (
            ({'fabula_failed': json.dumps([{'qid': 'z1'}]), 'perla_failed_reported': json.dumps(['z1'])}, 0, '1 salvataggio rifiutato da rifare o scartare',
             'a refused save already reported to the office'),
            ({}, 1, '1 foto da inviare', 'a photo still to send')):
        ctx = context(b)
        seed(ctx, OLD, items, photos=photos)
        p = ctx.new_page()
        p.goto(OLD + '/index.html')
        p.wait_for_timeout(2500)
        s = bar(p)
        check(f'{label} keeps the tablet on the old address, and the bar says so', p.url.startswith(OLD) and s and want in s['text'] and not s['on'], [p.url, s])
        ctx.close()

    # 6. a Console page with something waiting on that tablet: stays, and the old address keeps its copy of the app
    ctx = context(b)
    seed(ctx, OLD, {'fabula_queue': json.dumps([{'qid': 'a'}])}, cache=True)
    p = ctx.new_page()
    p.goto(OLD + '/console.html')
    p.wait_for_timeout(2500)
    keys = p.evaluate("caches.keys()")
    check('Console with a record waiting on this tablet: stays, no bar, the app\'s copy kept', p.url.startswith(OLD) and bar(p) is None and 'perla-v74' in keys, [p.url, keys])
    ctx.close()

    # 7. a path that would point elsewhere stays on the new address
    ctx = context(b)
    p = ctx.new_page()
    p.goto(OLD + '//evil.example/index.html')
    moved = wait_url(p, NEW + '/', 8000)
    p.wait_for_timeout(300)
    check('//other-site/… on the old address → still app.bubalina.it, never another site', moved and not ctx.elsewhere, [p.url, ctx.elsewhere])
    ctx.close()

    # 8. on the new address: nothing moves; an id there is kept while that address has its own work waiting, else replaced
    for items, keep, label in (
            ({'perla_device_uid': 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee', 'fabula_queue': json.dumps([{'qid': 'n1'}])}, True, 'with work waiting there: its own id is kept'),
            ({'perla_device_uid': 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'}, False, 'with nothing waiting there: the tablet\'s id is taken')):
        ctx = context(b)
        seed(ctx, NEW, items)
        p = ctx.new_page()
        p.goto(NEW + '/index.html?device_uid=' + UID)
        p.wait_for_timeout(2500)
        st = p.evaluate("[location.href, localStorage.getItem('perla_device_uid'), !!document.getElementById('move-home')]")
        want = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee' if keep else UID
        check(f'new address {label}; the page stays, no bar, the parameter leaves the address bar',
              st[0].startswith(NEW + '/index.html') and not st[2] and st[1] == want and 'device_uid' not in st[0], st)
        ctx.close()
    b.close()

print('FAILURES: ' + (', '.join(fails) if fails else 'none'))
