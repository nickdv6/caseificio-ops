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
the task ids in tools/bots/ROLLBACK-before-v087.md)."""
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


bad, rows = [], []
for f in sorted(glob.glob(os.path.join(HERE, 'prompts', '*.txt'))):
    r = build(f)
    if not r:
        continue
    agent, cur, want, version = r
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
sys.exit(1 if check and bad else 0)
