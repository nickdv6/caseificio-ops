"""v0.96 (audit A-01): the floor tablet asks «Chi sta registrando?» before any record. The e2e tests start with a stored login, so
they also store the operator the way a badge scan or a password login does: the staff row linked to that login, just active."""
import json, subprocess, time

def op_js(sess, db='restore_drill'):
    sub = sess['user']['id']
    r = subprocess.run(['su', 'postgres', '-c', f"psql -At -d {db} -c \"select id || '|' || full_name from fabula.staff where auth_user_id = '{sub}' limit 1\""],
                       capture_output=True, text=True).stdout.strip()
    if '|' not in r: return ''
    sid, name = r.split('|', 1); now = int(time.time() * 1000)
    op = {'id': sid, 'full_name': name, 'badge_code': None, 'via': 'login', 'at': now, 'last': now}
    return f"; localStorage.setItem('perla_operator_v1', {json.dumps(json.dumps(op))})"

def answer_ask(pg, yes=True, wait=300):
    """v0.97 (audit A-17/A-07): confirmations are a question on screen (.ask) whose buttons work after 1,5 s — no more «premi Salva di
    nuovo». Answers it if there is one; returns its text ('' if none)."""
    pg.wait_for_timeout(wait)
    txt = pg.evaluate("(document.querySelector('.ask') || {}).innerText || ''")
    if txt:
        pg.wait_for_timeout(1600)
        pg.evaluate(f"(() => {{ const b = document.querySelectorAll('.ask button'); (b[{0 if yes else 1}] || b[0]).click(); }})()")
        pg.wait_for_timeout(1500)
    return txt
