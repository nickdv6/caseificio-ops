#!/usr/bin/env python3
"""Copies the shared message rules (tools/bots/MESSAGE-RULES.md, with {{AGENT}} and {{VERSION}} filled in) into every bot prompt in
tools/bots/prompts/, so the prompts never drift apart (audit E-17). Run from the repo root after editing the rules or a prompt:
    python3 tools/bots/sync_rules.py               # rewrite the prompts (rules block + version)
    python3 tools/bots/sync_rules.py --check       # only report the prompts that differ (exit 1 if any)
    python3 tools/bots/sync_rules.py --versions    # print the expected versions as SQL values for fabula.bot_prompt_versions
A prompt without a rules block (bot_watchdog) is left alone. A prompt marked RETIRED (its job now runs in the database: the Shopify
syncs since v1.02) keeps its rules in step, for a rollback, but has no expected version: the database posts under that name.

v1.05 (audit E-17): each prompt carries a version, a short hash of the whole prompt, which the bot passes to post_bot_message
(p_prompt). The database keeps the expected versions in fabula.bot_prompt_versions (set by a migration: after changing a prompt, run
--versions and put the values in a new migration); fabula.prompt_drift() lists the scheduled tasks still running an older copy.
The scheduled tasks hold their own copy of each prompt: after a change, the prompts are pasted into the tasks (Claude can do it with
the task ids in tools/bots/ROLLBACK-before-v087.md).

v1.06 («Perché?»): --check also fails when a bot in BASIS calls one of its step-1 functions without fabula.keep_basis(…), which keeps
what the function returned for the «Perché?» button of the message."""
import glob, hashlib, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
tpl = open(os.path.join(HERE, 'MESSAGE-RULES.md'), encoding='utf-8').read()
START, END = '=== MESSAGE RULES', '=== END MESSAGE RULES ==='
block = tpl[tpl.index(START):tpl.index(END) + len(END)]
check, versions = '--check' in sys.argv, '--versions' in sys.argv


def build(path):
    """(agent, the prompt as it should be, its version) or None for a prompt without rules."""
    s = open(path, encoding='utf-8').read()
    if START not in s:
        return None
    i, j = s.index(START), s.index(END) + len(END)
    m = re.search(r"where agent = '([a-z_]+)' and source = 'bot'", s[i:j])
    agent = m.group(1) if m else os.path.basename(path)[:-4]
    draft = s[:i] + block.replace('{{AGENT}}', agent) + s[j:]
    version = hashlib.sha1(draft.encode('utf-8')).hexdigest()[:10]   # over the prompt with the {{VERSION}} placeholder
    return agent, s, draft.replace('{{VERSION}}', version), version


# v1.06 («Perché?»): the reads these bots wrap in fabula.keep_basis('<agent>', '<function>', fabula.<function>(…)), so the database
# keeps what the function returned for the «Perché?» button. --check fails when one is called without the wrapper.
BASIS = {'milk_planning': ['plan_milk'], 'procurement': ['propose_purchase_orders'], 'sell_down': ['sell_down_signals'],
         'wholesale_orders': ['confirm_standing_orders'], 'haccp_nudge': ['haccp_evening_status'], 'daily_brief': ['daily_brief', 'weekly_brief'],
         'monthly_review': ['monthly_review'], 'ops_health': ['ops_health_check', 'infra_checks'], 'compliance_calendar': ['compliance_calendar']}


def basis_problems(agent, s):
    """Every call of the bot's step-1 functions must be inside keep_basis('<this agent>', '<function>', …); at least one must exist."""
    out = []
    for fn in BASIS.get(agent, []):
        prefix = "fabula.keep_basis('%s', '%s', " % (agent, fn)
        wrapped = s.count(prefix + 'fabula.%s(' % fn)
        unwrapped = len(re.findall(r"(?<!%s)fabula\.%s\(" % (re.escape(prefix), fn), s))
        if wrapped == 0 or unwrapped > 0:
            out.append(f'{agent}: {fn}() not wrapped in keep_basis(\'{agent}\', \'{fn}\', …)')
    return out


bad, rows, basis_bad = [], [], []
for f in sorted(glob.glob(os.path.join(HERE, 'prompts', '*.txt'))):
    r = build(f)
    if not r:
        continue
    agent, cur, want, version = r
    basis_bad += basis_problems(agent, cur)
    if not cur.lstrip().startswith('RETIRED'):
        rows.append((agent, version))
    if cur != want:
        bad.append(agent)
        if not check and not versions:
            open(f, 'w', encoding='utf-8').write(want)
if versions:
    print(',\n'.join(f"  ('{a}', '{v}')" for a, v in rows))
    sys.exit(0)
print(('differ: ' if check else 'updated: ') + (', '.join(bad) or 'none'))
if basis_bad:
    print('keep_basis: ' + '; '.join(basis_bad))
sys.exit(1 if check and (bad or basis_bad) else 0)
