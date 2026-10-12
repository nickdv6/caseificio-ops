"""
simulator.py — fake CashDro3WS + fake Epson fpmate.cgi for development.

Lets you run middleware.py end-to-end with no hardware:

    uvicorn simulator:app --port 9000
    CASHDRO_HOST=127.0.0.1:9000 EPSON_HOST=127.0.0.1:9000 AUTH_MODE=none \
        uvicorn middleware:app --port 8080

Behaviour: once an operation is acknowledged, the "customer" inserts a note
every ~1.5 s until the amount is covered (with a 0.50 € overpay to exercise
change dispensing). Set SIM_CANCEL_AFTER_S to make the customer walk away.
"""

import asyncio
import itertools
import json
import os
import time
from typing import Any

from fastapi import FastAPI, Request, Response

app = FastAPI(title="CashDro S + Epson FP-81 II RT + scale simulator")

# --- fake scale: TCP on SIM_SCALE_PORT, answers "W\r\n" with an A&D-style frame.
# Middleware config:  SCALE_ENABLED=true SCALE_TRANSPORT=tcp SCALE_PORT=127.0.0.1:9001
SIM_SCALE_PORT = int(os.getenv("SIM_SCALE_PORT", "9001"))
SIM_SCALE_KG = float(os.getenv("SIM_SCALE_KG", "0.350"))


async def _scale_conn(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    unstable = 2  # first two frames unstable, then stable — exercises the stability wait
    try:
        while await reader.readline():
            status = "US" if unstable > 0 else "ST"
            unstable -= 1
            writer.write(f"{status},GS,+  {SIM_SCALE_KG:.3f} kg\r\n".encode())
            await writer.drain()
    except (ConnectionError, asyncio.CancelledError):
        pass
    finally:
        writer.close()


@app.on_event("startup")
async def _start_scale() -> None:
    await asyncio.start_server(_scale_conn, "127.0.0.1", SIM_SCALE_PORT)
_ops: dict[str, dict[str, Any]] = {}
_ids = itertools.count(1000)
_receipts = itertools.count(1)
SIM_CANCEL_AFTER_S = float(os.getenv("SIM_CANCEL_AFTER_S", "0"))


@app.get("/Cashdro3WS/index.php")
async def cashdro(request: Request):
    q = request.query_params
    op = q.get("operation")
    if op == "startOperation":
        params = json.loads(q.get("parameters", "{}"))
        oid = str(next(_ids))
        _ops[oid] = {
            "operationid": oid, "amount": int(params["amount"]), "state": "I",
            "totalin": 0, "totalout": 0, "ack_at": None, "finished": False,
        }
        return {"code": 1, "data": oid}
    oid = q.get("operationId", "")
    if op == "acknowledgeOperationId":
        _ops[oid]["ack_at"] = time.monotonic()
        _ops[oid]["state"] = "P"
        return {"code": 1, "data": ""}
    if op == "askOperation":
        if oid == "0":
            return {"code": 1, "data": {"operations": []}}
        o = _ops[oid]
        _advance(o)
        return {"code": 1, "data": {"operations": [o]}}
    if op == "finishOperation":
        o = _ops[oid]
        o["finished"] = True
        if q.get("type") == "2" and o["state"] not in {"F"}:
            o["state"] = "C"
        return {"code": 1, "data": ""}
    return {"code": 0, "data": f"unknown operation {op}"}


def _advance(o: dict[str, Any]) -> None:
    """Simulate a customer feeding 10 € notes until covered (+ 0.50 € overpay)."""
    if o["finished"] or o["ack_at"] is None or o["state"] in {"F", "C", "E"}:
        return
    elapsed = time.monotonic() - o["ack_at"]
    if SIM_CANCEL_AFTER_S and elapsed > SIM_CANCEL_AFTER_S:
        o["state"] = "C"
        return
    target = o["amount"] + 50
    inserted = min(int(elapsed // 1.5) * 1000, target)
    if inserted >= o["amount"] and inserted < target:
        inserted = target
    o["totalin"] = inserted
    if inserted >= o["amount"]:
        o["totalout"] = inserted - o["amount"]
        o["state"] = "F"


@app.post("/cgi-bin/fpmate.cgi")
async def fpmate(request: Request):
    body = (await request.body()).decode()
    if "queryPrinterStatus" in body:
        xml = '<response success="true" code="" status="20110" />'
    else:
        n = next(_receipts)
        print("=== FISCAL XML RECEIVED ===\n" + body)
        xml = (
            '<response success="true" code="" status="2">'
            "<addInfo><elementList>fiscalReceiptNumber,fiscalReceiptDate,zRepNumber</elementList>"
            f"<fiscalReceiptNumber>{n:04d}</fiscalReceiptNumber>"
            f"<fiscalReceiptDate>{time.strftime('%d/%m/%Y')}</fiscalReceiptDate>"
            "<zRepNumber>0123</zRepNumber></addInfo></response>"
        )
    env = (
        '<?xml version="1.0" encoding="utf-8"?>'
        '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/">'
        f"<soapenv:Body>{xml}</soapenv:Body></soapenv:Envelope>"
    )
    return Response(content=env, media_type="text/xml")
