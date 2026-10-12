"""
scale.py — legal-for-trade scale reader for the Fabula POS bridge
================================================================

Reads the NET weight from a CE-M approved counter scale (serial RS-232/USB
or Ethernet) and exposes it to the Shopify POS "Pesa" extension:

    GET /scale/weight?timeout=6     → {"weight_kg": 0.350, "stable": true, ...}
    GET /scale/products             → price-per-kg catalogue for the modal
    GET /scale/health

Mounted into middleware.py with  app.include_router(scale.router).

Metrology stance
----------------
The scale is the measuring instrument; this module only transports the
value it displays to the customer. We never compute or alter the weight,
we only accept a reading the instrument itself flags as STABLE (or, for
scales without a stability token, three identical consecutive readings).
The price computed downstream (weight × €/kg, rounded to the cent) must be
shown next to the weight on the receipt — the POS extension and the Epson
XML both do that.

Protocol
--------
Most counter scales talk a one-line ASCII frame, e.g.
    A&D / Dini Argeo style:   "ST,GS,+  0.350 kg\r\n"   (ST = stable, US = unstable)
    Many "protocollo cassa":  "W 0.350kg" or "0.350"
Configure SCALE_MODE (poll | stream), SCALE_REQUEST_CMD (what to send to get a
frame in poll mode) and SCALE_REGEX (named groups: value, unit, status, sign)
to match the dealer's protocol sheet. Everything else is protocol-agnostic.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import time
from pathlib import Path
from typing import Any, Optional

from fastapi import APIRouter, HTTPException, Query
from pydantic import BaseModel

log = logging.getLogger("scale")
router = APIRouter(prefix="/scale", tags=["scale"])


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

def _env(name: str, default: str = "") -> str:
    return os.getenv(name, default)


SCALE_ENABLED = _env("SCALE_ENABLED", "false").lower() in {"1", "true", "yes", "on"}
SCALE_TRANSPORT = _env("SCALE_TRANSPORT", "serial")          # serial | tcp
SCALE_PORT = _env("SCALE_PORT", "/dev/tty.usbserial-0001")  # serial device, or host:port for tcp
SCALE_BAUD = int(_env("SCALE_BAUD", "9600"))
SCALE_MODE = _env("SCALE_MODE", "poll")                      # poll | stream
SCALE_REQUEST_CMD = _env("SCALE_REQUEST_CMD", "W\\r\\n").encode().decode("unicode_escape")
SCALE_REGEX = re.compile(
    _env(
        "SCALE_REGEX",
        r"(?P<status>ST|US|OL)?[^\d+\-]*(?P<sign>[+-])?\s*(?P<value>\d+(?:[.,]\d+)?)\s*(?P<unit>kg|g)?",
    ),
    re.IGNORECASE,
)
SCALE_STABLE_READS = int(_env("SCALE_STABLE_READS", "3"))   # for scales with no ST/US token
SCALE_MIN_KG = float(_env("SCALE_MIN_KG", "0.005"))          # below this = empty plate
SCALE_PRODUCTS_FILE = _env("SCALE_PRODUCTS_FILE", "products_a_peso.json")


# ---------------------------------------------------------------------------
# Models
# ---------------------------------------------------------------------------

class Weight(BaseModel):
    weight_kg: float
    stable: bool
    overload: bool = False
    raw: str
    read_at: float


class WeighedProduct(BaseModel):
    sku: str
    title: str
    price_per_kg: float
    vat_rate: float            # 4, 10 or 22 — must exist in VAT_DEPARTMENTS
    tare_kg: float = 0.0       # default container tare if the scale isn't tared by hand
    shopify_variant_id: Optional[str] = None


# ---------------------------------------------------------------------------
# Transport
# ---------------------------------------------------------------------------

class ScaleTransport:
    """Opens the link lazily; one frame per read_frame() call."""

    def __init__(self) -> None:
        self._lock = asyncio.Lock()
        self._serial = None
        self._reader: Optional[asyncio.StreamReader] = None
        self._writer: Optional[asyncio.StreamWriter] = None

    async def _open(self) -> None:
        if SCALE_TRANSPORT == "tcp":
            if self._reader is None:
                host, port = SCALE_PORT.rsplit(":", 1)
                self._reader, self._writer = await asyncio.wait_for(
                    asyncio.open_connection(host, int(port)), timeout=3
                )
        else:
            if self._serial is None:
                import serial  # pyserial

                self._serial = serial.Serial(SCALE_PORT, SCALE_BAUD, timeout=1.0)

    async def close(self) -> None:
        if self._writer:
            self._writer.close()
        if self._serial:
            self._serial.close()
        self._reader = self._writer = self._serial = None

    async def read_frame(self) -> str:
        """Send the request (poll mode) and return one ASCII line from the scale."""
        async with self._lock:
            try:
                await self._open()
                if SCALE_TRANSPORT == "tcp":
                    assert self._reader and self._writer
                    if SCALE_MODE == "poll":
                        self._writer.write(SCALE_REQUEST_CMD.encode())
                        await self._writer.drain()
                    line = await asyncio.wait_for(self._reader.readline(), timeout=1.5)
                    return line.decode(errors="ignore").strip()
                # serial, blocking → thread
                def _io() -> str:
                    s = self._serial
                    if SCALE_MODE == "poll":
                        s.reset_input_buffer()
                        s.write(SCALE_REQUEST_CMD.encode())
                    return s.readline().decode(errors="ignore").strip()

                return await asyncio.to_thread(_io)
            except Exception as e:
                await self.close()  # reopen on next call
                raise HTTPException(502, f"Bilancia non raggiungibile: {e}") from e


_transport = ScaleTransport()


# ---------------------------------------------------------------------------
# Parsing + stability
# ---------------------------------------------------------------------------

def parse_frame(raw: str) -> Optional[Weight]:
    m = SCALE_REGEX.search(raw)
    if not m or not m.group("value"):
        return None
    value = float(m.group("value").replace(",", "."))
    unit = (m.group("unit") or "kg").lower()
    if unit == "g":
        value /= 1000.0
    if m.group("sign") == "-":
        value = -value
    status = (m.group("status") or "").upper()
    return Weight(
        weight_kg=round(value, 3),
        stable=(status == "ST") if status else False,  # resolved by caller if no token
        overload=(status == "OL"),
        raw=raw,
        read_at=time.time(),
    )


async def read_stable_weight(timeout_s: float) -> Weight:
    """
    Return the first reading the scale flags STABLE, or (for protocols without
    a status token) SCALE_STABLE_READS identical consecutive readings.
    """
    deadline = time.monotonic() + timeout_s
    history: list[float] = []
    last: Optional[Weight] = None
    while time.monotonic() < deadline:
        raw = await _transport.read_frame()
        w = parse_frame(raw)
        if w is None:
            await asyncio.sleep(0.15)
            continue
        last = w
        if w.overload:
            raise HTTPException(422, "Sovraccarico bilancia")
        has_token = bool(SCALE_REGEX.groupindex.get("status")) and bool(
            SCALE_REGEX.search(raw).group("status")
        )
        if has_token:
            if w.stable:
                return w
        else:
            history.append(w.weight_kg)
            if len(history) >= SCALE_STABLE_READS and len(set(history[-SCALE_STABLE_READS:])) == 1:
                w.stable = True
                return w
        await asyncio.sleep(0.2)
    raise HTTPException(
        408,
        f"Peso non stabile entro {timeout_s:.0f}s"
        + (f" (ultima lettura {last.weight_kg:.3f} kg)" if last else ""),
    )


# ---------------------------------------------------------------------------
# Catalogue
# ---------------------------------------------------------------------------

def load_products() -> list[WeighedProduct]:
    p = Path(SCALE_PRODUCTS_FILE)
    if not p.exists():
        return []
    return [WeighedProduct(**row) for row in json.loads(p.read_text(encoding="utf-8"))]


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@router.get("/health")
async def scale_health() -> dict[str, Any]:
    if not SCALE_ENABLED:
        return {"enabled": False}
    try:
        raw = await _transport.read_frame()
        return {"enabled": True, "ok": True, "raw": raw, "parsed": parse_frame(raw)}
    except HTTPException as e:
        return {"enabled": True, "ok": False, "error": e.detail}


@router.get("/weight", response_model=Weight)
async def scale_weight(timeout: float = Query(6.0, ge=1, le=20)) -> Weight:
    """Blocks until the scale reports a stable net weight (or `timeout` s)."""
    if not SCALE_ENABLED:
        raise HTTPException(503, "Bilancia disabilitata (SCALE_ENABLED=false)")
    w = await read_stable_weight(timeout)
    if w.weight_kg < SCALE_MIN_KG:
        raise HTTPException(422, "Piatto vuoto: appoggiare il prodotto sulla bilancia")
    return w


@router.get("/products", response_model=list[WeighedProduct])
async def scale_products() -> list[WeighedProduct]:
    return load_products()
