#!/usr/bin/env python3
"""Copies the shared message rules (tools/bots/MESSAGE-RULES.md, with {{AGENT}} filled in) into every bot prompt in
tools/bots/prompts/, so the prompts never drift apart (audit E-17). Run from the repo root after editing the rules:
    python3 tools/bots/sync_rules.py          # rewrite the prompts
    python3 tools/bots/sync_rules.py --check  # only report the prompts whose rules differ (exit 1 if any)
A prompt without a rules block (bot_watchdog) is left alone. The scheduled tasks hold their own copy of each prompt: after
a change, the prompts are pasted into the tasks (Claude can do it with the task ids in tools/bots/ROLLBACK-before-v087.md)."""
import glob, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
tpl = open(os.path.join(HERE, 'MESSAGE-RULES.md'), encoding='utf-8').read()
START, END = '=== MESSAGE RULES', '=== END MESSAGE RULES ==='
block = tpl[tpl.index(START):tpl.index(END) + len(END)]
check = '--check' in sys.argv
bad = []
for f in sorted(glob.glob(os.path.join(HERE, 'prompts', '*.txt'))):
    s = open(f, encoding='utf-8').read()
    if START not in s:
        continue
    i, j = s.index(START), s.index(END) + len(END)
    agent = os.path.basename(f)[:-4]
    m = re.search(r"where agent = '([a-z_]+)' and source = 'bot'", s[i:j])
    want = block.replace('{{AGENT}}', m.group(1) if m else agent)
    if s[i:j] != want:
        bad.append(agent)
        if not check:
            open(f, 'w', encoding='utf-8').write(s[:i] + want + s[j:])
print(('differ: ' if check else 'updated: ') + (', '.join(bad) or 'none'))
sys.exit(1 if check and bad else 0)
