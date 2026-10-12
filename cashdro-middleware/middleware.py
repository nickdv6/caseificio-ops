"""
middleware.py — Shopify POS ⇄ CashDro S ⇄ Epson FP-81 II RT bridge
====================================================================

Local store server (Mac mini / PC on the shop LAN) that:

  1. Accepts a cart snapshot from the Shopify POS UI extension
     ("Paga con CashDro" tile) over HTTPS.
  2. Drives the CashDro S cash recycler through its CashDro3WS web service:
        startOperation  →  acknowledgeOperationId  →  askOperation (poll)
     handling change dispensing, timeouts, cancellations and hardware errors.
     Any abort sends finishOperation so the recycler closes the operation
     and locks its slots.
  3. On a successful cash collection, builds the Italian fiscal XML
     (documento commerciale) and POSTs it to the Epson FP-81 II RT at
     /cgi-bin/fpmate.cgi, with one fiscal department per VAT rate.
  4. Journals every operation in SQLite for the end-of-day reconciliation
     (CashDro total vs Shopify POS `totalCashSales`).

Design notes
------------
* The POS extension does NOT block while the customer feeds notes into the
  recycler. POST /cash/transactions returns immediately with an id; the
  recycler loop runs as an asyncio task and the extension polls
  GET /cash/transactions/{id} once a second. POST .../cancel aborts it.
* Shopify POS UI extensions have no "payment" target: the extension cannot
  add a cash tender to the cart. After this server reports `completed`,
  the cashier still taps  Cash → exact amount  in Shopify POS to close the
  sale. The transaction id + fiscal document number are written to the cart
  as properties by the extension so the Shopify order carries the audit trail.
* IMPORTANT — double fiscalization: Shopify POS (Italy) can itself print
  the documento commerciale on an Epson RT when the sale is closed. Run ONE
  of the two paths, never both:
      EPSON_ENABLED=true   → this server fiscalizes; disable the fiscal
                             printer in Shopify POS for this register.
      EPSON_ENABLED=false  → this server only runs the recycler; Shopify POS
                             fiscalizes when the cashier taps Cash.
* All money values travel as integer euro-cents internally. Floats are only
  used at the Epson boundary, where the XML wants "12.50".

Verify-against-manual markers
-----------------------------
Lines tagged  # VERIFY  reference field names / status letters of the
CashDro3WS or Epson XML APIs that differ between firmware versions. They
are isolated in CashDroClient / EpsonClient so a mismatch is a one-line fix.

Run:  uvicorn middleware:app --host 0.0.0.0 --port 8443 \
        --ssl-keyfile certs/key.pem --ssl-certfile certs/cert.pem
"""

from __future__ import annotations

import asyncio
import hashlib
import hmac
import json
import logging
import os
import re
import sqlite3
import time
import uuid
from contextlib import asynccontextmanager
from dataclasses import dataclass, field
from datetime import datetime, timezone
from enum import Enum
from typing import Any, Optional
from xml.etree import ElementTree as ET
from xml.sax.saxutils import escape as xml_escape

import httpx
from fastapi import Depends, FastAPI, HTTPException, Request, status
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field, field_validator

try:  # optional: only needed when AUTH_MODE includes "session_token"
    import jwt  # PyJWT
except ImportError:  # pragma: no cover
    jwt = None

# ---------------------------------------------------------------------------
# Configuration (12-factor: everything from environment / .env)
# ---------------------------------------------------------------------------

try:  # load ./.env if present (never overrides real environment variables)
    from dotenv import load_dotenv
    load_dotenv()
except ImportError:  # pragma: no cover
    pass


def _env(name: str, default: Optional[str] = None, required: bool = False) -> str:
    val = os.getenv(name, default)
    if required and not val:
        raise RuntimeError(f"Missing required environment variable {name}")
    return val or ""


def _env_bool(name: str, default: bool) -> bool:
    return _env(name, "true" if default else "false").strip().lower() in {"1", "true", "yes", "on"}


@dataclass(frozen=True)
class Settings:
    # --- CashDro S ---
    cashdro_host: str = _env("CASHDRO_HOST", "192.168.1.50")
    cashdro_user: str = _env("CASHDRO_USER", "admin")
    cashdro_password: str = _env("CASHDRO_PASSWORD", "admin")
    cashdro_poll_interval_s: float = float(_env("CASHDRO_POLL_INTERVAL_S", "1.0"))
    # How long the customer has to finish inserting cash before we abort.
    cashdro_timeout_s: float = float(_env("CASHDRO_TIMEOUT_S", "180"))
    # Operation type for a sale ("cobro"). 1 = charge / sale on CashDro3WS.
    cashdro_sale_type: int = int(_env("CASHDRO_SALE_TYPE", "1"))  # VERIFY

    # --- Epson FP-81 II RT ---
    epson_enabled: bool = _env_bool("EPSON_ENABLED", True)
    epson_host: str = _env("EPSON_HOST", "192.168.1.60")
    epson_devid: str = _env("EPSON_DEVID", "local_printer")
    epson_operator: str = _env("EPSON_OPERATOR", "1")
    epson_timeout_ms: int = int(_env("EPSON_TIMEOUT_MS", "15000"))
    # Map VAT rate (%) → fiscal department programmed on the printer.
    # Default: 22% → dept 1 (cosmetics), 10% → dept 2, 4% → dept 3 (latticini).
    vat_departments: str = _env("VAT_DEPARTMENTS", "22:1,10:2,4:3")
    # Description printed as the payment line on the receipt.
    epson_cash_label: str = _env("EPSON_CASH_LABEL", "CONTANTI")
    # Italian law (L. 96/2017 art. 13-quater) rounds CASH payments to the
    # nearest 5 cents. CashDro S handles 1c/2c coins, so default off; switch
    # on if the commercialista / dealer asks for it.
    round_cash_to_5c: bool = _env_bool("ROUND_CASH_TO_5C", False)

    # --- Security ---
    # "session_token": verify Shopify POS session token JWT (recommended).
    # "hmac":          verify X-CashDro-Signature over timestamp.body.
    # "both":          require both.   "none": local testing only.
    auth_mode: str = _env("AUTH_MODE", "session_token")
    shopify_api_secret: str = _env("SHOPIFY_API_SECRET", "")
    shopify_api_key: str = _env("SHOPIFY_API_KEY", "")
    hmac_secret: str = _env("HMAC_SECRET", "")
    hmac_max_skew_s: int = int(_env("HMAC_MAX_SKEW_S", "120"))
    # Comma-separated allowed Origins. POS extensions run in a sandboxed
    # worker; their fetch Origin is typically "null" or a shopifycdn host.
    allowed_origins: str = _env(
        "ALLOWED_ORIGINS",
        "https://extensions.shopifycdn.com,https://cdn.shopify.com,null",
    )
    # Optional: only accept requests from these source IPs (the iPads).
    allowed_client_ips: str = _env("ALLOWED_CLIENT_IPS", "")

    # --- Misc ---
    journal_db: str = _env("JOURNAL_DB", "cashdro_journal.sqlite")
    store_name: str = _env("STORE_NAME", "Latteria Fabula")
    log_level: str = _env("LOG_LEVEL", "INFO")

    def vat_department_map(self) -> dict[int, int]:
        """Parse "22:1,10:2,4:3" into {2200: 1, 1000: 2, 400: 3} (rate in bp)."""
        out: dict[int, int] = {}
        for pair in self.vat_departments.split(","):
            pair = pair.strip()
            if not pair:
                continue
            rate, dept = pair.split(":")
            out[int(round(float(rate) * 100))] = int(dept)
        return out


settings = Settings()
logging.basicConfig(
    level=settings.log_level,
    format="%(asctime)s %(levelname)-7s %(name)s: %(message)s",
)
log = logging.getLogger("cashdro-middleware")


# ---------------------------------------------------------------------------
# Domain models
# ---------------------------------------------------------------------------


class TxStatus(str, Enum):
    PENDING = "pending"                  # accepted, recycler not started yet
    COLLECTING = "collecting"            # recycler open, waiting for cash
    DISPENSING_CHANGE = "dispensing_change"
    FISCALIZING = "fiscalizing"          # cash done, printing on Epson
    COMPLETED = "completed"
    CANCELLED = "cancelled"              # cashier / customer abort
    TIMEOUT = "timeout"                  # customer walked away
    ERROR = "error"                      # hardware / protocol failure
    CHANGE_SHORT = "change_short"        # paid, but change incomplete: staff hands over the rest
    PAID_NO_RECEIPT = "paid_no_receipt"  # v0.93: paid, but the RT did not print — NEVER charge again

    @property
    def terminal(self) -> bool:
        return self in {
            TxStatus.COMPLETED, TxStatus.CANCELLED, TxStatus.TIMEOUT,
            TxStatus.ERROR, TxStatus.CHANGE_SHORT, TxStatus.PAID_NO_RECEIPT,
        }

    @property
    def paid(self) -> bool:
        """The customer's cash is in the machine: the sale must be closed, never retried."""
        return self in {TxStatus.COMPLETED, TxStatus.CHANGE_SHORT, TxStatus.PAID_NO_RECEIPT}


class TaxLineIn(BaseModel):
    """One tax line from Shopify POS. `rate` is a fraction (0.22) or a percent (22)."""
    title: Optional[str] = None
    rate: float

    def rate_bp(self) -> int:
        """Return the rate in basis points of a percent (22% → 2200)."""
        r = self.rate * 100 if self.rate <= 1 else self.rate
        return int(round(r * 100))


class LineItemIn(BaseModel):
    uuid: Optional[str] = None
    title: str
    sku: Optional[str] = None
    quantity: float = Field(gt=0)
    # Unit price, VAT inclusive, as shown in POS (euro).
    unit_price: float = Field(ge=0)
    # Total discount on this line in euro (POS line discounts + allocated cart discounts).
    discount_total: float = Field(default=0, ge=0)
    tax_lines: list[TaxLineIn] = Field(default_factory=list)
    taxable: bool = True
    # Weighed goods (set by the "Pesa" extension): the receipt prints
    # weight_kg × price_per_kg instead of quantity × unit_price.
    weight_kg: Optional[float] = Field(default=None, gt=0)
    price_per_kg: Optional[float] = Field(default=None, gt=0)

    @property
    def is_weighed(self) -> bool:
        return self.weight_kg is not None and self.price_per_kg is not None

    @field_validator("title")
    @classmethod
    def _clean_title(cls, v: str) -> str:
        v = re.sub(r"[^\w\sÀ-ÿ.,'()/%+-]", "", v).strip()
        return v or "Articolo"

    def unit_price_cents(self) -> int:
        return int(round(self.unit_price * 100))

    def discount_cents(self) -> int:
        return int(round(self.discount_total * 100))

    def gross_cents(self) -> int:
        # quantity may be fractional for weighed goods (e.g. 0.350 kg mozzarella)
        return int(round(self.unit_price * self.quantity * 100))

    def net_cents(self) -> int:
        return max(self.gross_cents() - self.discount_cents(), 0)

    def vat_rate_bp(self) -> int:
        if not self.taxable or not self.tax_lines:
            return 0
        # Shopify may attach several tax lines; Italy has a single IVA rate per item.
        return max(t.rate_bp() for t in self.tax_lines)


class CartIn(BaseModel):
    line_items: list[LineItemIn] = Field(min_length=1)
    # Grand total due, VAT inclusive, euro. Authoritative figure from POS.
    grand_total: float = Field(gt=0)
    subtotal: Optional[float] = None
    tax_total: Optional[float] = None
    currency: str = "EUR"
    note: Optional[str] = None

    def grand_total_cents(self) -> int:
        return int(round(self.grand_total * 100))


class CreateTransactionIn(BaseModel):
    # Caller-generated; retrying the same key returns the same transaction.
    idempotency_key: str = Field(min_length=8, max_length=128)
    pos_device_id: Optional[str] = None
    pos_location_id: Optional[str] = None
    staff_name: Optional[str] = None
    # Codice lotteria degli scontrini (8 alphanumerics) if the customer gives one.
    lottery_code: Optional[str] = Field(default=None, pattern=r"^[A-Z0-9]{8}$")
    cart: CartIn


class TransactionOut(BaseModel):
    id: str
    status: TxStatus
    message: str
    amount_due_cents: int
    amount_inserted_cents: int = 0
    change_due_cents: int = 0
    change_dispensed_cents: int = 0
    change_short_cents: int = 0          # v0.93: change the machine could not give — hand it over by hand
    paid: bool = False                   # v0.93: cash collected → close the sale, never retry
    cashdro_operation_id: Optional[str] = None
    fiscal_receipt_number: Optional[str] = None
    fiscal_receipt_date: Optional[str] = None
    fiscal_z_number: Optional[str] = None
    created_at: str
    finished_at: Optional[str] = None


@dataclass
class Transaction:
    id: str
    idempotency_key: str
    request: CreateTransactionIn
    amount_due_cents: int
    status: TxStatus = TxStatus.PENDING
    message: str = "In attesa"
    amount_inserted_cents: int = 0
    change_due_cents: int = 0
    change_dispensed_cents: int = 0
    change_short_cents: int = 0
    cashdro_operation_id: Optional[str] = None
    fiscal_receipt_number: Optional[str] = None
    fiscal_receipt_date: Optional[str] = None
    fiscal_z_number: Optional[str] = None
    created_at: datetime = field(default_factory=lambda: datetime.now(timezone.utc))
    finished_at: Optional[datetime] = None
    cancel_requested: bool = False
    task: Optional[asyncio.Task] = None

    def to_out(self) -> TransactionOut:
        return TransactionOut(
            id=self.id,
            status=self.status,
            message=self.message,
            amount_due_cents=self.amount_due_cents,
            amount_inserted_cents=self.amount_inserted_cents,
            change_due_cents=self.change_due_cents,
            change_dispensed_cents=self.change_dispensed_cents,
            change_short_cents=self.change_short_cents,
            paid=self.status.paid,
            cashdro_operation_id=self.cashdro_operation_id,
            fiscal_receipt_number=self.fiscal_receipt_number,
            fiscal_receipt_date=self.fiscal_receipt_date,
            fiscal_z_number=self.fiscal_z_number,
            created_at=self.created_at.isoformat(),
            finished_at=self.finished_at.isoformat() if self.finished_at else None,
        )


# ---------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------


class HardwareError(Exception):
    """Recycler or printer returned an error or is unreachable."""


class OperationCancelled(Exception):
    """Cashier or customer aborted the cash operation."""


class OperationTimeout(Exception):
    """Customer did not complete payment within CASHDRO_TIMEOUT_S."""


# ---------------------------------------------------------------------------
# CashDro S client  (CashDro3WS web service)
# ---------------------------------------------------------------------------


class CashDroClient:
    """
    Thin async client over the CashDro3WS HTTP API.

    Endpoint:  http://<host>/Cashdro3WS/index.php?operation=<op>&name=..&password=..&...
    Every call returns JSON  {"code": <int>, "data": <any>}  where code 1 = OK.

    Lifecycle used for a sale (the "3-step loop"):
        startOperation(type=1, parameters={"amount": cents, ...})  → operationId
        acknowledgeOperationId(operationId)                        → recycler opens
        askOperation(operationId)  ...polled...                    → state / totals
        finishOperation(operationId, type=…)                       → close / cancel

    Field names and state letters below are marked VERIFY: confirm them
    against the CashDro3WS manual shipped with the unit's firmware.
    """

    # askOperation "state" values                                   # VERIFY
    STATE_IN_PROGRESS = {"I", "P", "S"}   # initialised / in progress / started
    STATE_FINISHED = {"F"}                # finished OK
    STATE_CANCELLED = {"C", "K"}          # cancelled on the device
    STATE_ERROR = {"E"}                   # device error

    # finishOperation "type"                                        # VERIFY
    FINISH_CLOSE = 1     # close normally with what has been collected
    FINISH_CANCEL = 2    # cancel: return inserted cash, lock slots

    def __init__(self, s: Settings):
        self.base = f"http://{s.cashdro_host}/Cashdro3WS/index.php"
        self.auth = {"name": s.cashdro_user, "password": s.cashdro_password}
        self.http = httpx.AsyncClient(timeout=httpx.Timeout(10.0, connect=5.0))

    async def aclose(self) -> None:
        await self.http.aclose()

    async def _call(self, operation: str, **params: Any) -> Any:
        q = {"operation": operation, **self.auth, **params}
        try:
            r = await self.http.get(self.base, params=q)
            r.raise_for_status()
            payload = r.json()
        except httpx.HTTPError as e:
            raise HardwareError(f"CashDro unreachable during {operation}: {e}") from e
        except ValueError as e:
            raise HardwareError(f"CashDro returned non-JSON for {operation}: {r.text[:200]}") from e

        # Some firmwares return code as string; normalise.
        code = int(payload.get("code", 0))
        if code != 1:
            raise HardwareError(f"CashDro {operation} failed: code={code} data={payload.get('data')!r}")
        log.debug("CashDro %s → %s", operation, payload)
        return payload.get("data")

    async def ping(self) -> bool:
        try:
            await self._call("askOperation", operationId="0")  # harmless probe   # VERIFY
            return True
        except HardwareError:
            return False

    async def start_sale(self, amount_cents: int, ticket_ref: str, concept: str) -> str:
        """Step 1: register the sale. Returns the recycler's operationId."""
        parameters = json.dumps(
            {"amount": amount_cents, "ticket": ticket_ref, "concept": concept[:60]}
        )
        data = await self._call(
            "startOperation",
            type=settings.cashdro_sale_type,
            parameters=parameters,
        )
        op_id = str(data if not isinstance(data, dict) else data.get("operationId", ""))  # VERIFY
        if not op_id:
            raise HardwareError(f"startOperation returned no operationId: {data!r}")
        return op_id

    async def acknowledge(self, op_id: str) -> None:
        """Step 2: acknowledge → the recycler unlocks its slots and shows the amount."""
        await self._call("acknowledgeOperationId", operationId=op_id)

    async def ask(self, op_id: str) -> dict[str, Any]:
        """Step 3: poll operation status. Returns a normalised dict."""
        data = await self._call("askOperation", operationId=op_id)
        # Response shape is {"operations": [ {...} ]} on most firmwares.   # VERIFY
        op: dict[str, Any] = {}
        if isinstance(data, dict):
            ops = data.get("operations") or []
            op = ops[0] if ops else data
        elif isinstance(data, list) and data:
            op = data[0]
        return {
            "state": str(op.get("state", "")).upper(),                       # VERIFY
            "total_in": int(op.get("totalin", op.get("totalIn", 0)) or 0),   # VERIFY cents
            "total_out": int(op.get("totalout", op.get("totalOut", 0)) or 0),  # VERIFY cents
            "raw": op,
        }

    async def finish(self, op_id: str, cancel: bool) -> None:
        """Close the operation. cancel=True returns inserted cash and locks slots."""
        await self._call(
            "finishOperation",
            operationId=op_id,
            type=self.FINISH_CANCEL if cancel else self.FINISH_CLOSE,
        )


# ---------------------------------------------------------------------------
# Epson FP-81 II RT client  (fpmate.cgi XML API)
# ---------------------------------------------------------------------------


class EpsonClient:
    """
    Builds and sends the documento commerciale to the Epson RT printer.

    Endpoint: http://<host>/cgi-bin/fpmate.cgi?devid=<devid>&timeout=<ms>
    Body: SOAP envelope with <printerFiscalReceipt>. The printer answers
          <response success="true|false" code="..." status="..."> plus <addInfo>
          containing fiscalReceiptNumber / fiscalReceiptDate / zRepNumber.

    VAT handling: the printer holds the VAT rate per department, so each
    line is sent with the department mapped from its Shopify tax rate.
    Prices are VAT-inclusive, euro with 2 decimals.
    """

    def __init__(self, s: Settings):
        self.s = s
        self.url = f"http://{s.epson_host}/cgi-bin/fpmate.cgi"
        self.dept_map = s.vat_department_map()
        self.http = httpx.AsyncClient(timeout=httpx.Timeout(s.epson_timeout_ms / 1000 + 5, connect=5.0))

    async def aclose(self) -> None:
        await self.http.aclose()

    # -- helpers -------------------------------------------------------------

    @staticmethod
    def _eur(cents: int) -> str:
        return f"{cents / 100:.2f}"

    def department_for(self, rate_bp: int) -> int:
        try:
            return self.dept_map[rate_bp]
        except KeyError:
            raise HTTPException(
                status.HTTP_422_UNPROCESSABLE_ENTITY,
                f"No fiscal department configured for VAT rate {rate_bp / 100:.2f}% "
                f"(VAT_DEPARTMENTS={self.s.vat_departments}).",
            )

    def build_receipt_xml(self, tx: Transaction) -> str:
        """
        Compose the fiscal receipt. Rules:
          * one printRecItem per cart line, department = VAT rate
          * line discounts → printRecItemAdjustment (type 0 = discount on item)
          * total paid in cash → printRecTotal paymentType=0 (contanti)
          * optional lottery code → printRecLotteryID
          * trailer message with the middleware transaction id (audit trail)
        """
        op = xml_escape(self.s.epson_operator)
        parts: list[str] = [f'<beginFiscalReceipt operator="{op}" />']

        for li in tx.request.cart.line_items:
            dept = self.department_for(li.vat_rate_bp())
            desc = xml_escape(li.title[:38])  # printer line width
            if li.is_weighed:
                # Legal metrology: receipt shows net weight × unit price per kg.
                qty = f"{li.weight_kg:.3f}"
                unit = self._eur(int(round(li.price_per_kg * 100)))
            else:
                qty = f"{li.quantity:.3f}"
                unit = self._eur(li.unit_price_cents())
            parts.append(
                f'<printRecItem operator="{op}" description="{desc}" quantity="{qty}" '
                f'unitPrice="{unit}" department="{dept}" justification="1" />'
            )
            if li.discount_cents() > 0:
                parts.append(
                    f'<printRecItemAdjustment operator="{op}" adjustmentType="0" '
                    f'description="SCONTO" amount="{self._eur(li.discount_cents())}" '
                    f'department="{dept}" justification="1" />'
                )

        if tx.request.lottery_code:
            parts.append(
                f'<printRecLotteryID operator="{op}" code="{xml_escape(tx.request.lottery_code)}" />'
            )

        parts.append(
            f'<printRecTotal operator="{op}" description="{xml_escape(self.s.epson_cash_label)}" '
            f'payment="{self._eur(tx.amount_due_cents)}" paymentType="0" index="0" justification="1" />'
        )
        # Trailer line (messageType 3 = additional trailer) carrying our id.   # VERIFY
        parts.append(
            f'<printRecMessage operator="{op}" messageType="3" index="1" font="1" '
            f'message="{xml_escape("Rif. " + tx.id[:18])}" />'
        )
        parts.append(f'<endFiscalReceipt operator="{op}" />')

        body = "\n      ".join(parts)
        return (
            '<?xml version="1.0" encoding="utf-8"?>\n'
            '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">\n'
            "  <s:Body>\n"
            "    <printerFiscalReceipt>\n"
            f"      {body}\n"
            "    </printerFiscalReceipt>\n"
            "  </s:Body>\n"
            "</s:Envelope>\n"
        )

    async def _post(self, xml: str) -> ET.Element:
        try:
            r = await self.http.post(
                self.url,
                params={"devid": self.s.epson_devid, "timeout": self.s.epson_timeout_ms},
                content=xml.encode("utf-8"),
                headers={"Content-Type": "text/xml; charset=utf-8"},
            )
            r.raise_for_status()
        except httpx.HTTPError as e:
            raise HardwareError(f"Epson unreachable: {e}") from e
        try:
            root = ET.fromstring(r.text)
        except ET.ParseError as e:
            raise HardwareError(f"Epson returned invalid XML: {r.text[:200]}") from e
        # The <response> element is nested inside the SOAP body.
        resp = root.find(".//response")
        if resp is None:
            raise HardwareError(f"Epson response missing <response>: {r.text[:200]}")
        if resp.get("success", "false").lower() != "true":
            raise HardwareError(
                f"Epson rejected command: code={resp.get('code')} status={resp.get('status')}"
            )
        return resp

    async def print_receipt(self, tx: Transaction) -> dict[str, Optional[str]]:
        """Send the fiscal receipt; returns fiscal number / date / Z counter."""
        xml = self.build_receipt_xml(tx)
        log.info("Epson: printing receipt for tx %s (%s €)", tx.id, self._eur(tx.amount_due_cents))
        log.debug("Epson XML:\n%s", xml)
        resp = await self._post(xml)

        def _info(tag: str) -> Optional[str]:
            el = resp.find(f".//addInfo/{tag}")
            return el.text.strip() if el is not None and el.text else None

        return {
            "number": _info("fiscalReceiptNumber"),
            "date": _info("fiscalReceiptDate"),
            "z": _info("zRepNumber"),
        }

    async def status(self) -> dict[str, Any]:
        """Query printer status (paper, cover, fiscal memory)."""
        xml = (
            '<?xml version="1.0" encoding="utf-8"?>'
            '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>'
            f'<printerCommand><queryPrinterStatus operator="{xml_escape(self.s.epson_operator)}" '
            'statusType="0" /></printerCommand></s:Body></s:Envelope>'
        )
        resp = await self._post(xml)
        return {"status": resp.get("status"), "code": resp.get("code")}


# ---------------------------------------------------------------------------
# SQLite journal (source for end-of-day reconciliation)
# ---------------------------------------------------------------------------


class Journal:
    DDL = """
    CREATE TABLE IF NOT EXISTS cash_ops (
        id TEXT PRIMARY KEY,
        idempotency_key TEXT UNIQUE NOT NULL,
        pos_device_id TEXT,
        staff_name TEXT,
        status TEXT NOT NULL,
        message TEXT,
        amount_due_cents INTEGER NOT NULL,
        amount_inserted_cents INTEGER DEFAULT 0,
        change_due_cents INTEGER DEFAULT 0,
        change_dispensed_cents INTEGER DEFAULT 0,
        cashdro_operation_id TEXT,
        fiscal_receipt_number TEXT,
        fiscal_receipt_date TEXT,
        fiscal_z_number TEXT,
        cart_json TEXT NOT NULL,
        created_at TEXT NOT NULL,
        finished_at TEXT
    );
    CREATE INDEX IF NOT EXISTS ix_cash_ops_created ON cash_ops(created_at);
    """

    def __init__(self, path: str):
        self.path = path
        with self._conn() as c:
            c.executescript(self.DDL)

    def _conn(self) -> sqlite3.Connection:
        c = sqlite3.connect(self.path, isolation_level=None)
        c.row_factory = sqlite3.Row
        return c

    def upsert(self, tx: Transaction) -> None:
        with self._conn() as c:
            c.execute(
                """
                INSERT INTO cash_ops (id, idempotency_key, pos_device_id, staff_name, status, message,
                    amount_due_cents, amount_inserted_cents, change_due_cents, change_dispensed_cents,
                    cashdro_operation_id, fiscal_receipt_number, fiscal_receipt_date, fiscal_z_number,
                    cart_json, created_at, finished_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(id) DO UPDATE SET
                    status=excluded.status, message=excluded.message,
                    amount_inserted_cents=excluded.amount_inserted_cents,
                    change_due_cents=excluded.change_due_cents,
                    change_dispensed_cents=excluded.change_dispensed_cents,
                    cashdro_operation_id=excluded.cashdro_operation_id,
                    fiscal_receipt_number=excluded.fiscal_receipt_number,
                    fiscal_receipt_date=excluded.fiscal_receipt_date,
                    fiscal_z_number=excluded.fiscal_z_number,
                    finished_at=excluded.finished_at
                """,
                (
                    tx.id, tx.idempotency_key, tx.request.pos_device_id, tx.request.staff_name,
                    tx.status.value, tx.message, tx.amount_due_cents, tx.amount_inserted_cents,
                    tx.change_due_cents, tx.change_dispensed_cents, tx.cashdro_operation_id,
                    tx.fiscal_receipt_number, tx.fiscal_receipt_date, tx.fiscal_z_number,
                    tx.request.cart.model_dump_json(), tx.created_at.isoformat(),
                    tx.finished_at.isoformat() if tx.finished_at else None,
                ),
            )

    def day(self, day_iso: str) -> list[dict[str, Any]]:
        with self._conn() as c:
            rows = c.execute(
                "SELECT * FROM cash_ops WHERE substr(created_at,1,10)=? ORDER BY created_at",
                (day_iso,),
            ).fetchall()
        return [dict(r) for r in rows]


# ---------------------------------------------------------------------------
# Transaction engine
# ---------------------------------------------------------------------------


class CashEngine:
    """Owns in-flight transactions and runs the recycler/printer workflow."""

    def __init__(self, s: Settings):
        self.s = s
        self.cashdro = CashDroClient(s)
        self.epson = EpsonClient(s)
        self.journal = Journal(s.journal_db)
        self.txs: dict[str, Transaction] = {}
        self.by_idem: dict[str, str] = {}
        # The recycler serves one customer at a time.
        self.device_lock = asyncio.Lock()

    async def aclose(self) -> None:
        for tx in self.txs.values():
            if tx.task and not tx.task.done():
                tx.cancel_requested = True
        await self.cashdro.aclose()
        await self.epson.aclose()

    # -- validation -----------------------------------------------------------

    def _validate_cart(self, req: CreateTransactionIn) -> int:
        cart = req.cart
        if cart.currency.upper() != "EUR":
            raise HTTPException(422, "Only EUR carts can be fiscalized in Italy.")
        items_total = sum(li.net_cents() for li in cart.line_items)
        due = cart.grand_total_cents()
        # The fiscal receipt must equal the cash collected. Tolerate 1 cent of
        # Shopify's per-line rounding, otherwise refuse rather than mis-fiscalize.
        if abs(items_total - due) > 1:
            raise HTTPException(
                422,
                f"Cart lines total {items_total / 100:.2f} € but grand_total is {due / 100:.2f} €. "
                "Cart-level discounts must be allocated to lines (discount_total) before sending.",
            )
        for li in cart.line_items:
            if li.is_weighed:
                # weight × €/kg (rounded to the cent) must equal what POS charged,
                # otherwise the receipt and the cash collected would disagree.
                expected = int(round(li.weight_kg * li.price_per_kg * 100))
                if abs(expected - li.gross_cents()) > 1:
                    raise HTTPException(
                        422,
                        f"Weighed line '{li.title}': {li.weight_kg:.3f} kg × {li.price_per_kg:.2f} €/kg "
                        f"= {expected / 100:.2f} € but POS line is {li.gross_cents() / 100:.2f} €.",
                    )
            if self.s.epson_enabled:
                self.epson.department_for(li.vat_rate_bp())  # raises 422 on unknown rate
        if self.s.round_cash_to_5c:
            due = int(round(due / 5.0)) * 5
        return due

    # -- public API -----------------------------------------------------------

    def create(self, req: CreateTransactionIn) -> Transaction:
        if req.idempotency_key in self.by_idem:
            return self.txs[self.by_idem[req.idempotency_key]]
        due = self._validate_cart(req)
        tx = Transaction(
            id=f"CD-{datetime.now().strftime('%Y%m%d')}-{uuid.uuid4().hex[:8].upper()}",
            idempotency_key=req.idempotency_key,
            request=req,
            amount_due_cents=due,
        )
        self.txs[tx.id] = tx
        self.by_idem[req.idempotency_key] = tx.id
        self.journal.upsert(tx)
        tx.task = asyncio.create_task(self._run(tx), name=f"cashdro-{tx.id}")
        return tx

    def get(self, tx_id: str) -> Transaction:
        try:
            return self.txs[tx_id]
        except KeyError:
            raise HTTPException(404, "Transaction not found")

    def request_cancel(self, tx_id: str) -> Transaction:
        tx = self.get(tx_id)
        if tx.status.terminal:
            return tx
        if tx.status == TxStatus.FISCALIZING:
            raise HTTPException(409, "Cash already collected; receipt is printing and cannot be cancelled.")
        tx.cancel_requested = True
        return tx

    # -- workflow -------------------------------------------------------------

    def _set(self, tx: Transaction, st: TxStatus, msg: str) -> None:
        tx.status, tx.message = st, msg
        if st.terminal:
            tx.finished_at = datetime.now(timezone.utc)
        self.journal.upsert(tx)
        log.info("tx %s → %s (%s)", tx.id, st.value, msg)

    async def _run(self, tx: Transaction) -> None:
        async with self.device_lock:  # serialise access to the recycler
            try:
                await self._collect_cash(tx)
            except OperationCancelled:
                self._set(tx, TxStatus.CANCELLED, "Operazione annullata")
                return
            except OperationTimeout:
                self._set(tx, TxStatus.TIMEOUT, "Tempo scaduto, contanti restituiti")
                return
            except HardwareError as e:
                if tx.amount_inserted_cents > 0:
                    # v0.93 (audit POS-01/04): cash may still be in the machine — say what to check, never "riprova" blindly
                    self._set(tx, TxStatus.ERROR,
                              f"Collegamento con la CashDro perso con {tx.amount_inserted_cents / 100:.2f} € inseriti. "
                              "Guarda lo schermo della CashDro: se dice «operazione annullata» i contanti sono stati resi; "
                              "altrimenti premi Annulla sulla CashDro. Non far pagare di nuovo prima di aver controllato.")
                else:
                    self._set(tx, TxStatus.ERROR, f"La CashDro non risponde, nessun contante inserito. Riprova. ({e})")
                return
            except Exception as e:  # defensive: never leave a tx non-terminal
                log.exception("Unexpected failure in tx %s", tx.id)
                self._set(tx, TxStatus.ERROR, f"Errore interno: {e}")
                return

        # v0.93 (audit POS-03): change the machine could not give stays visible to the end (it used to be overwritten by
        # "completed"), the cashier must confirm handing it over, and the day journal counts it.
        short = f" · RESTO MANCANTE: dai {tx.change_short_cents / 100:.2f} € a mano." if tx.change_short_cents else ""
        done_status = TxStatus.CHANGE_SHORT if tx.change_short_cents else TxStatus.COMPLETED

        if not self.s.epson_enabled:
            self._set(tx, done_status, f"Pagato{short} Chiudi la vendita su Shopify: Contanti → importo esatto")
            return

        self._set(tx, TxStatus.FISCALIZING, "Stampa documento commerciale…")
        try:
            info = await self.epson.print_receipt(tx)
            tx.fiscal_receipt_number = info["number"]
            tx.fiscal_receipt_date = info["date"]
            tx.fiscal_z_number = info["z"]
            self._set(
                tx, done_status,
                f"Pagato, scontrino n. {info['number'] or '?'}{short} Chiudi la vendita su Shopify: Contanti → importo esatto",
            )
        except (HardwareError, HTTPException) as e:
            # v0.93 (audit POS-01): the cash is collected — a terminal PAID state, so the till never offers "Riprova".
            self._set(tx, TxStatus.PAID_NO_RECEIPT,
                      f"IL CLIENTE HA PAGATO {tx.amount_due_cents / 100:.2f} €: NON incassare di nuovo. "
                      f"Lo scontrino NON è stato stampato ({getattr(e, 'detail', e)}): emettilo a mano dalla stampante fiscale.{short} "
                      "Poi chiudi la vendita su Shopify: Contanti → importo esatto.")

    async def _collect_cash(self, tx: Transaction) -> None:
        if tx.cancel_requested:
            raise OperationCancelled()

        # Step 1 — start
        tx.cashdro_operation_id = await self.cashdro.start_sale(
            tx.amount_due_cents, ticket_ref=tx.id, concept=self.s.store_name
        )
        self.journal.upsert(tx)

        # Step 2 — acknowledge (recycler shows the amount and opens slots)
        try:
            await self.cashdro.acknowledge(tx.cashdro_operation_id)
        except HardwareError:
            await self._safe_finish(tx, cancel=True)
            raise
        self._set(tx, TxStatus.COLLECTING, f"Inserire {tx.amount_due_cents / 100:.2f} €")

        # Step 3 — poll until finished / cancelled / timeout
        deadline = time.monotonic() + self.s.cashdro_timeout_s
        last_in = -1
        while True:
            if tx.cancel_requested:
                await self._safe_finish(tx, cancel=True)
                raise OperationCancelled()
            if time.monotonic() > deadline:
                await self._safe_finish(tx, cancel=True)
                raise OperationTimeout()

            # v0.93 (audit POS-04): one slow answer (a crumpled note being validated, a Wi-Fi blip) is retried before
            # giving up; on a real loss the operation is cancelled so the machine returns the cash and is free again.
            for attempt in range(3):
                try:
                    st = await self.cashdro.ask(tx.cashdro_operation_id)
                    break
                except HardwareError:
                    if attempt == 2:
                        await self._safe_finish(tx, cancel=True)
                        raise
                    await asyncio.sleep(1.0 + attempt)
            tx.amount_inserted_cents = st["total_in"]
            tx.change_dispensed_cents = st["total_out"]
            tx.change_due_cents = max(tx.amount_inserted_cents - tx.amount_due_cents, 0)

            if tx.amount_inserted_cents != last_in:
                last_in = tx.amount_inserted_cents
                remaining = max(tx.amount_due_cents - tx.amount_inserted_cents, 0)
                if remaining > 0:
                    self._set(tx, TxStatus.COLLECTING, f"Inseriti {last_in / 100:.2f} €, mancano {remaining / 100:.2f} €")
                else:
                    self._set(tx, TxStatus.DISPENSING_CHANGE, f"Erogazione resto {tx.change_due_cents / 100:.2f} €")

            state = st["state"]
            if state in CashDroClient.STATE_FINISHED:
                break
            if state in CashDroClient.STATE_CANCELLED:
                raise OperationCancelled()
            if state in CashDroClient.STATE_ERROR:
                await self._safe_finish(tx, cancel=True)
                raise HardwareError(f"device reported error state: {st['raw']}")

            await asyncio.sleep(self.s.cashdro_poll_interval_s)

        # Finished: verify the money actually balances before fiscalizing.
        if tx.amount_inserted_cents < tx.amount_due_cents:
            # Device says finished but short-paid → treat as cancelled, return cash.
            await self._safe_finish(tx, cancel=True)
            raise HardwareError(
                f"finished with {tx.amount_inserted_cents} inserted < {tx.amount_due_cents} due"
            )
        await self._safe_finish(tx, cancel=False)

        if tx.change_dispensed_cents + 1 < tx.change_due_cents:
            # Cash is in the machine but change could not be fully dispensed: still fiscalize (the sale happened);
            # _run ends in CHANGE_SHORT so the cashier hands over the rest. Not set here: a terminal status now would
            # stop the till polling before the receipt is printed.
            tx.change_short_cents = tx.change_due_cents - tx.change_dispensed_cents
            log.warning("tx %s: change short by %d cents", tx.id, tx.change_short_cents)

    async def _safe_finish(self, tx: Transaction, cancel: bool) -> None:
        """Always try to close the recycler operation; never mask the original error."""
        if not tx.cashdro_operation_id:
            return
        try:
            await self.cashdro.finish(tx.cashdro_operation_id, cancel=cancel)
        except HardwareError as e:
            log.error("finishOperation(cancel=%s) failed for %s: %s", cancel, tx.id, e)


# ---------------------------------------------------------------------------
# Security
# ---------------------------------------------------------------------------


def _client_ip(request: Request) -> str:
    return request.client.host if request.client else ""


def _verify_hmac(request: Request, body: bytes) -> None:
    sig = request.headers.get("X-CashDro-Signature", "")
    ts = request.headers.get("X-CashDro-Timestamp", "")
    if not sig or not ts.isdigit():
        raise HTTPException(401, "Missing HMAC signature headers")
    if abs(int(time.time()) - int(ts)) > settings.hmac_max_skew_s:
        raise HTTPException(401, "Signature timestamp outside allowed window")
    expected = hmac.new(
        settings.hmac_secret.encode(), ts.encode() + b"." + body, hashlib.sha256
    ).hexdigest()
    if not hmac.compare_digest(expected, sig):
        raise HTTPException(401, "Invalid HMAC signature")


def _verify_session_token(request: Request) -> None:
    """
    Shopify POS session tokens are HS256 JWTs signed with the app's API
    secret, issued by shopify.sessionToken.get() in the extension.
    """
    if jwt is None:
        raise HTTPException(500, "PyJWT not installed; pip install pyjwt")
    auth = request.headers.get("Authorization", "")
    if not auth.startswith("Bearer "):
        raise HTTPException(401, "Missing Shopify session token")
    try:
        claims = jwt.decode(
            auth[7:],
            settings.shopify_api_secret,
            algorithms=["HS256"],
            audience=settings.shopify_api_key or None,
            options={"verify_aud": bool(settings.shopify_api_key)},
            leeway=10,
        )
    except jwt.PyJWTError as e:
        raise HTTPException(401, f"Invalid session token: {e}")
    request.state.shop = claims.get("dest")


async def require_auth(request: Request) -> None:
    """FastAPI dependency: origin / IP allow-list + token or HMAC check."""
    origin = request.headers.get("Origin")
    allowed = {o.strip() for o in settings.allowed_origins.split(",") if o.strip()}
    if origin is not None and origin not in allowed:
        raise HTTPException(403, f"Origin {origin} not allowed")

    ips = {i.strip() for i in settings.allowed_client_ips.split(",") if i.strip()}
    if ips and _client_ip(request) not in ips:
        raise HTTPException(403, "Client IP not allowed")

    mode = settings.auth_mode
    if mode == "none":
        return
    body = await request.body()
    if mode in {"hmac", "both"}:
        if not settings.hmac_secret:
            raise HTTPException(500, "HMAC_SECRET not configured")
        _verify_hmac(request, body)
    if mode in {"session_token", "both"}:
        if not settings.shopify_api_secret:
            raise HTTPException(500, "SHOPIFY_API_SECRET not configured")
        _verify_session_token(request)


# ---------------------------------------------------------------------------
# FastAPI app
# ---------------------------------------------------------------------------

engine: CashEngine


@asynccontextmanager
async def lifespan(app: FastAPI):
    global engine
    engine = CashEngine(settings)
    log.info(
        "CashDro middleware up — recycler %s, Epson %s (%s), auth=%s",
        settings.cashdro_host, settings.epson_host,
        "enabled" if settings.epson_enabled else "DISABLED (Shopify POS fiscalizes)",
        settings.auth_mode,
    )
    try:
        yield
    finally:
        await engine.aclose()


app = FastAPI(
    title="CashDro ⇄ Shopify POS middleware",
    version="1.0.0",
    lifespan=lifespan,
)
app.add_middleware(
    CORSMiddleware,
    allow_origins=[o.strip() for o in settings.allowed_origins.split(",") if o.strip() and o.strip() != "null"],
    allow_origin_regex=None,
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["Authorization", "Content-Type", "X-CashDro-Signature", "X-CashDro-Timestamp"],
    allow_credentials=False,
)

# Scale endpoints (/scale/weight, /scale/products, /scale/health) — see scale.py
import scale as _scale  # noqa: E402

app.include_router(_scale.router, dependencies=[Depends(require_auth)])


@app.get("/health")
async def health() -> dict[str, Any]:
    """Liveness + hardware reachability. Not authenticated: no data exposed."""
    cashdro_ok = await engine.cashdro.ping()
    epson: dict[str, Any] = {"enabled": settings.epson_enabled}
    if settings.epson_enabled:
        try:
            epson.update(await engine.epson.status(), ok=True)
        except HardwareError as e:
            epson.update(ok=False, error=str(e))
    return {
        "ok": cashdro_ok and (not settings.epson_enabled or epson.get("ok", False)),
        "cashdro": {"host": settings.cashdro_host, "ok": cashdro_ok},
        "epson": epson,
        "in_flight": [t.id for t in engine.txs.values() if not t.status.terminal],
        "time": datetime.now(timezone.utc).isoformat(),
    }


@app.post("/cash/transactions", response_model=TransactionOut, status_code=202,
          dependencies=[Depends(require_auth)])
async def create_transaction(payload: CreateTransactionIn) -> TransactionOut:
    """
    Start a cash sale on the recycler. Returns 202 immediately; poll the id.
    Idempotent on `idempotency_key` so a retried POST never double-charges.
    """
    busy = [t for t in engine.txs.values() if not t.status.terminal]
    if busy and payload.idempotency_key not in engine.by_idem:
        raise HTTPException(409, f"Recycler busy with {busy[0].id}; cancel it or wait.")
    return engine.create(payload).to_out()


@app.get("/cash/transactions/{tx_id}", response_model=TransactionOut,
         dependencies=[Depends(require_auth)])
async def get_transaction(tx_id: str) -> TransactionOut:
    return engine.get(tx_id).to_out()


@app.post("/cash/transactions/{tx_id}/cancel", response_model=TransactionOut,
          dependencies=[Depends(require_auth)])
async def cancel_transaction(tx_id: str) -> TransactionOut:
    """Abort: the recycler returns inserted cash and locks the slots."""
    return engine.request_cancel(tx_id).to_out()


@app.get("/cash/journal/{day}", dependencies=[Depends(require_auth)])
async def journal_day(day: str) -> dict[str, Any]:
    """Day journal for reconciliation against Shopify POS totalCashSales."""
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", day):
        raise HTTPException(422, "day must be YYYY-MM-DD")
    rows = engine.journal.day(day)
    completed = [r for r in rows if r["status"] in {"completed", "change_short", "paid_no_receipt"}]
    return {
        "day": day,
        "count": len(rows),
        "completed": len(completed),
        "cash_collected_cents": sum(r["amount_due_cents"] for r in completed),
        # v0.93: counted on every paid sale (a short-change sale whose receipt then failed is paid_no_receipt)
        "change_short_cents": sum(
            max((r["change_due_cents"] or 0) - (r["change_dispensed_cents"] or 0), 0)
            for r in completed if (r["change_due_cents"] or 0) - (r["change_dispensed_cents"] or 0) > 1
        ),
        "receipts_to_issue_by_hand": [r["id"] for r in rows if r["status"] == "paid_no_receipt"],
        "rows": rows,
    }


@app.exception_handler(HardwareError)
async def _hw_error(_: Request, exc: HardwareError):
    from fastapi.responses import JSONResponse
    return JSONResponse(status_code=502, content={"detail": str(exc)})


if __name__ == "__main__":  # convenience for `python middleware.py`
    import uvicorn

    uvicorn.run(
        "middleware:app",
        host="0.0.0.0",
        port=int(os.getenv("PORT", "8443")),
        ssl_keyfile=os.getenv("SSL_KEYFILE") or None,
        ssl_certfile=os.getenv("SSL_CERTFILE") or None,
        reload=False,
    )
