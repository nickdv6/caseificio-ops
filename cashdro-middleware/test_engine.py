"""
test_engine.py — v0.93 checks of the cash workflow with a fake CashDro and a fake Epson (no hardware, no network).

    pip install -r requirements.txt
    AUTH_MODE=none python3 test_engine.py        # expect "FAILURES: none"

Covers the audit fixes of 12/10/2026:
  POS-01  receipt printer fails after the cash is in → terminal "paid_no_receipt" (paid = true), never "error"
  POS-03  change the machine could not give → final status "change_short" with change_short_cents (was overwritten
          by "completed"), and the day journal counts it
  POS-04  one slow answer from the CashDro is retried; a lost connection with cash inserted cancels the operation and
          the message tells the cashier what to check
"""
import asyncio
import os
import tempfile

os.environ.setdefault("AUTH_MODE", "none")
os.environ["JOURNAL_DB"] = os.path.join(tempfile.mkdtemp(), "journal.sqlite3")
os.environ["CASHDRO_POLL_INTERVAL_S"] = "0.01"

import middleware as m  # noqa: E402

fails = []


def check(name, cond, info=""):
    print(("PASS " if cond else "FAIL ") + name + (f"  [{info}]" if info else ""))
    if not cond:
        fails.append(name)


class FakeCashDro:
    def __init__(self, answers, ask_errors=0):
        self.answers = list(answers)   # dicts returned by ask(), last one repeats
        self.ask_errors = ask_errors   # first N ask() calls raise HardwareError
        self.finished = []

    async def start_sale(self, cents, ticket_ref, concept):
        return "OP-1"

    async def acknowledge(self, op):
        return None

    async def ask(self, op):
        if self.ask_errors > 0:
            self.ask_errors -= 1
            raise m.HardwareError("CashDro unreachable during askOperation: ReadTimeout")
        return self.answers.pop(0) if len(self.answers) > 1 else self.answers[0]

    async def finish(self, op, cancel):
        self.finished.append(cancel)

    async def aclose(self):
        pass


class FakeEpson:
    def __init__(self, fail=False):
        self.fail = fail

    def department_for(self, rate_bp):
        return 3

    async def print_receipt(self, tx):
        if self.fail:
            raise m.HardwareError("Epson: carta esaurita")
        return {"number": "0042-0007", "date": "15/02/2027", "z": "42"}

    async def aclose(self):
        pass


def req(key):
    return m.CreateTransactionIn(
        idempotency_key=key,
        cart=m.CartIn(grand_total=27.40, line_items=[m.LineItemIn(
            title="Mozzarella", quantity=1, unit_price=27.40,
            tax_lines=[m.TaxLineIn(rate=0.04)])]),
    )


def st(state, inn, out=0):
    return {"state": state, "total_in": inn, "total_out": out, "raw": state}


async def run(cashdro, epson, key, epson_enabled=True):
    s = m.Settings(epson_enabled=epson_enabled, cashdro_poll_interval_s=0.01, journal_db=os.environ["JOURNAL_DB"])
    eng = m.CashEngine(s)
    eng.cashdro, eng.epson = cashdro, epson
    tx = eng.create(req(key))
    await tx.task
    return eng, tx


async def main():
    # 1 · POS-03: 30 € in, 2,60 € change due, machine gives 0,60 €
    eng, tx = await run(FakeCashDro([st("P", 3000), st("F", 3000, 60)]), FakeEpson(), "k-short-000001")
    out = tx.to_out()
    check("change short: final status is change_short (was overwritten by completed)", tx.status == m.TxStatus.CHANGE_SHORT, tx.status)
    check("change short: amount to hand over is 2,00 €", out.change_short_cents == 200, out.change_short_cents)
    check("change short: receipt still printed and sale marked paid", out.fiscal_receipt_number == "0042-0007" and out.paid)
    check("change short: message tells the cashier", "RESTO MANCANTE: dai 2.00 €" in tx.message, tx.message)

    # 2 · normal sale
    eng, tx = await run(FakeCashDro([st("P", 3000), st("F", 3000, 260)]), FakeEpson(), "k-ok-00000001")
    check("normal sale: completed, nothing short", tx.status == m.TxStatus.COMPLETED and tx.change_short_cents == 0 and tx.to_out().paid)

    # 3 · POS-01: printer fails after the cash is in
    eng, tx = await run(FakeCashDro([st("F", 2740)]), FakeEpson(fail=True), "k-noreceipt01")
    out = tx.to_out()
    check("printer fails after payment: paid_no_receipt, not error", tx.status == m.TxStatus.PAID_NO_RECEIPT, tx.status)
    check("paid_no_receipt is terminal and paid", tx.status.terminal and out.paid)
    check("paid_no_receipt message says not to charge again", "NON incassare di nuovo" in tx.message and "emettilo a mano" in tx.message, tx.message)

    # 4 · POS-04: two slow answers are retried, the sale completes
    eng, tx = await run(FakeCashDro([st("P", 1000), st("F", 2740)], ask_errors=2), FakeEpson(), "k-retry-00001")
    check("two failed polls are retried and the sale completes", tx.status == m.TxStatus.COMPLETED, f"{tx.status} {tx.message}")

    # 5 · POS-04: connection lost for good after cash was inserted
    cd = FakeCashDro([st("P", 1000)], ask_errors=0)
    s = m.Settings(epson_enabled=True, cashdro_poll_interval_s=0.01, journal_db=os.environ["JOURNAL_DB"])
    eng = m.CashEngine(s)
    eng.cashdro, eng.epson = cd, FakeEpson()

    async def flaky_ask(op, _n=[0]):
        _n[0] += 1
        if _n[0] == 1:
            return st("P", 1000)
        raise m.HardwareError("CashDro unreachable during askOperation: ReadTimeout")
    cd.ask = flaky_ask
    tx = eng.create(req("k-lost-000001"))
    await tx.task
    out = tx.to_out()
    check("connection lost with cash inserted: error, not paid", tx.status == m.TxStatus.ERROR and not out.paid, tx.status)
    check("…the operation is cancelled so the machine returns the cash", cd.finished == [True], cd.finished)
    check("…the message says what to check and not to charge again",
          "10.00 € inseriti" in tx.message and "Non far pagare di nuovo" in tx.message, tx.message)

    # 6 · day journal
    day = tx.created_at.date().isoformat()
    rows = m.Journal(os.environ["JOURNAL_DB"]).day(day)
    paid = [r for r in rows if r["status"] in {"completed", "change_short", "paid_no_receipt"}]
    check("journal: change_short and paid_no_receipt rows are stored as paid sales",
          {r["status"] for r in paid} >= {"change_short", "paid_no_receipt", "completed"}, sorted({r['status'] for r in rows}))
    m.engine = eng
    summary = await m.journal_day(day)
    check("journal: change short counted (2,00 €), receipt to issue by hand listed",
          summary["change_short_cents"] == 200 and len(summary["receipts_to_issue_by_hand"]) == 1, {k: summary[k] for k in ('change_short_cents', 'receipts_to_issue_by_hand')})


asyncio.run(main())
print("FAILURES: " + (", ".join(fails) if fails else "none"))
