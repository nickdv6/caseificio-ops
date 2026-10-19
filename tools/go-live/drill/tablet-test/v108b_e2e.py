"""v1.08b «the app moves to app.bubalina.it» in the browser. Both addresses are served from the local fabula-tablet/ files through
Playwright routes (nothing reaches Netlify, GitHub or Supabase; Supabase calls get an empty answer), so the test runs anywhere.
- A Console page opened on the old Netlify address goes to the same page on https://app.bubalina.it, ?query and #hash kept.
- The tablet (index.html) with nothing waiting goes too, carrying its name and id (?device=, ?device_uid=); on the new address the
  id is kept and the parameter removed from the address bar.
- The tablet with a record waiting stays, says why in a bar (with the count), and goes by itself once the queue is empty.
- A refused save already reported to the office does not hold the tablet back; one not yet reported does.
- On the new address nothing moves, and an id already there is not replaced.
Expect "FAILURES: none"."""
import json, mimetypes, os
from urllib.parse import urlparse
from playwright.sync_api import sync_playwright

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '../../../../fabula-tablet'))
OLD, NEW = 'https://flourishing-swan-6729c4.netlify.app', 'https://app.bubalina.it'
fails = []


def check(name, cond, info=''):
    print(('PASS ' if cond else 'FAIL ') + name + (f'  [{str(info)[:300]}]' if info != '' else ''), flush=True)
    if not cond:
        fails.append(name)


def serve(route):
    path = urlparse(route.request.url).path
    f = os.path.join(ROOT, (path.lstrip('/') or 'index.html'))
    if os.path.isdir(f):
        f = os.path.join(f, 'index.html')
    if not os.path.isfile(f):
        return route.fulfill(status=404, body='not found')
    ctype = mimetypes.guess_type(f)[0] or 'application/octet-stream'
    route.fulfill(status=200, body=open(f, 'rb').read(), headers={'content-type': ctype})


def context(b):
    ctx = b.new_context(service_workers='block', locale='it-IT')
    ctx.route(OLD + '/**', serve)
    ctx.route(NEW + '/**', serve)
    ctx.route('**/*.supabase.co/**', lambda r: r.fulfill(status=200, body='{}', headers={'content-type': 'application/json', 'access-control-allow-origin': '*'}))
    return ctx


def seed(ctx, origin, items):
    """localStorage of one address, set from a tiny page on it (a 404 page of the routed host is enough)."""
    p = ctx.new_page()
    p.goto(origin + '/__seed__')
    p.evaluate("items => { localStorage.clear(); for (const [k, v] of Object.entries(items)) localStorage.setItem(k, v); }", items)
    p.close()


def wait_url(p, prefix, ms):
    try:
        p.wait_for_url(lambda u: u.startswith(prefix), timeout=ms)
        return True
    except Exception:
        return False


with sync_playwright() as pw:
    b = pw.chromium.launch()

    # 1. a Console page with ?query and #hash
    ctx = context(b)
    p = ctx.new_page()
    p.goto(OLD + '/console.html?x=1#oggi')
    moved = wait_url(p, NEW, 8000)
    check('Console on the old address → the same page on app.bubalina.it, query and hash kept', moved and p.url == NEW + '/console.html?x=1#oggi', p.url)
    ctx.close()

    # 2. the tablet with nothing waiting: name and id travel with it
    ctx = context(b)
    seed(ctx, OLD, {'fabula_device': 'tablet-2', 'perla_device_uid': '11111111-2222-4333-8444-555555555555',
                    'fabula_failed': json.dumps([{'qid': 'q1'}]), 'perla_failed_reported': json.dumps(['q1'])})
    p = ctx.new_page()
    p.goto(OLD + '/index.html')
    moved = wait_url(p, NEW, 8000)
    p.wait_for_timeout(500)
    st = p.evaluate("[localStorage.getItem('fabula_device'), localStorage.getItem('perla_device_uid'), location.search]") if moved else None
    check('tablet with nothing waiting (a refused save already reported does not count) → moves at once', moved, p.url)
    check('…as the same tablet: name and id kept on the new address', st and st[0] == 'tablet-2' and st[1] == '11111111-2222-4333-8444-555555555555', st)
    check('…and the id is not left in the address bar', st and 'device_uid' not in st[2] and 'device=tablet-2' in st[2], st)
    ctx.close()

    # 3. the tablet with a record waiting: it stays, says so, and moves once the queue is empty
    ctx = context(b)
    seed(ctx, OLD, {'fabula_queue': json.dumps([{'qid': 'a', 'table': 'haccp_logs'}, {'qid': 'b', 'table': 'haccp_logs'}])})
    p = ctx.new_page()
    errors = []
    p.on('pageerror', lambda e: errors.append(str(e)))
    p.goto(OLD + '/index.html')
    p.wait_for_timeout(2500)
    bar = p.evaluate("(document.getElementById('move-home') || {}).textContent || ''")
    check('tablet with records waiting: stays on the old address', p.url.startswith(OLD), p.url)
    check('…and says why, with the count', 'app.bubalina.it' in bar and '(2)' in bar and 'Non chiudere' in bar, bar)
    p.evaluate("localStorage.setItem('fabula_queue', '[]')")          # what app.js does once the records are sent
    moved = wait_url(p, NEW, 15000)
    check('…then moves by itself once nothing is waiting', moved, p.url)
    ctx.close()

    # 4. a refused save not yet reported holds the tablet back
    ctx = context(b)
    seed(ctx, OLD, {'fabula_failed': json.dumps([{'qid': 'z1'}]), 'perla_failed_reported': '[]'})
    p = ctx.new_page()
    p.goto(OLD + '/index.html')
    p.wait_for_timeout(2500)
    check('a refused save not yet reported to the office keeps the tablet on the old address',
          p.url.startswith(OLD) and '(1)' in p.evaluate("(document.getElementById('move-home') || {}).textContent || ''"), p.url)
    ctx.close()

    # 5. on the new address: nothing moves, an id already there is kept, the parameter goes
    ctx = context(b)
    seed(ctx, NEW, {'perla_device_uid': 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'})
    p = ctx.new_page()
    p.goto(NEW + '/index.html?device_uid=11111111-2222-4333-8444-555555555555')
    p.wait_for_timeout(2500)
    st = p.evaluate("[location.href, localStorage.getItem('perla_device_uid'), !!document.getElementById('move-home')]")
    check('new address: the page stays, no bar', st[0].startswith(NEW + '/index.html') and not st[2], st)
    check('…an id already there is not replaced, and the parameter leaves the address bar',
          st[1] == 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee' and 'device_uid' not in st[0], st)
    ctx.close()
    b.close()

print('FAILURES: ' + (', '.join(fails) if fails else 'none'))
