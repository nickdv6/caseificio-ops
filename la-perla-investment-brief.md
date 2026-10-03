# Investment brief: acquiring the Latteria Fabula equipment and launching La Perla del Cilento

**Prepared for:** Nick (Masseria Cilentana), as a handoff to Claude
**As of:** 2 October 2026. Model version: dashboard v44, plus the v45–v47 cost lines.
**Status:** pre-signing. Due diligence not started. Masseria Cilentana's 2023–2025 financials are **not yet in this brief** (see section 7).

---

## 0. Read this first (instructions for Claude)

- You are supporting a pre-acquisition feasibility analysis. Act as an Italian M&A analyst and agricultural tax advisor. Nick is the decision-maker; his partners Nicola Celso and Emilio Celso run hands-on trials at the Fabula facility.
- **The figures in this brief replace the older benchmarks** that may still appear in the project instructions: 20% yield, €16.80/kg price, €1.30/kg milk cost, €154,143 OpEx, €220,787 profit, 4.1-month payback, €5,250 IAP saving. All of those are out of date (see section 13).
- Every figure below is labelled by source: **[decided]** means Nick chose it, **[measured]** means it came from the 29/09 trial, **[seller]** means the seller said it and it has not been verified, **[model]** means it was calculated in the dashboard, **[derived]** means it was calculated for this brief from the model figures, and **[estimate]** means it is a researched or rule-of-thumb estimate.
- The whole case depends on the **seller's verbal volume (37,510 kg/yr)**. Nobody has verified it. Treat every profit figure as conditional on it.
- Don't invent Masseria Cilentana's historical numbers. Section 7 lists what to ask for.

---

## 1. The opportunity in one paragraph

Masseria Cilentana is a buffalo farm in the province of Salerno. Its milk ranks #68 nationally and #11 in its region on production and quality. Today it sells all of its milk to large cheese groups at about **€1.30/kg**, a price Nick describes as held down by coordinated buyer pricing. Latteria Fabula Srl is a small working caseificio with a retail shop in Agropoli, about 5 km from the farm. The plan is to buy Fabula's **equipment and business assets (not the company)** and take over its lease. The dairy would then run under a new brand, **La Perla del Cilento**, making **Mozzarella di Bufala Campana DOP** (always 100% buffalo, from a single herd) for the shop, a Shopify web store (perladelcilento.it) and local delivery apps. The farm would get about **€1.70/kg** for the milk the dairy uses. At the seller's stated volume the dairy makes about **€155,500/yr** net. All-in capital is about **€106,000**, so payback is about **8 months**. The downside is real: at half the stated volume, profit falls to about €12,400/yr and payback stretches to about 8.5 years. The deal is therefore only as good as the volume check in due diligence.

---

## 2. Parties and structure

| Item | Detail |
|---|---|
| Buyer | Masseria Cilentana, an agricultural business in Campania (project context says it has IAP status; **confirm**) |
| Target | Latteria Fabula Srl, Agropoli (SA). Seller P.IVA **06052830657** |
| Deal form | **Asset purchase** (equipment, fit-out, goodwill/customer base, lease takeover). No shares are bought, so Fabula's legacy tax, INPS and supplier liabilities stay with the seller **[decided]** |
| Excluded | The Fabula Cosmetics line (no SKUs, formulas or regulatory filings are acquired) **[decided]** |
| Operating entity | **Undecided.** Option A: run the dairy inside Masseria Cilentana as an *attività connessa* (art. 2135 c.c.). Option B: a new Srl. The model currently assumes **Option B with an ordinary IVA regime** and a milk invoice from the farm. The farm's accountant keeps its ledger offsite |
| Brand | La Perla del Cilento (shop, website, ops system, SOPs). The database schema is still called `fabula` |
| Lease | €1,200/month, commercial 6+6 (L. 392/1978). Seller says it is transferable by standard novation. **Get the landlord's written consent before closing** |
| Staff | 2 retail staff kept (1 full-time, 1 part-time). New hires: a casaro (€33,360/yr employer cost) and a casaro's helper, 6 h/day, €1,000/month net (≈ €22,532/yr employer cost, **estimate**, to confirm with the consulente del lavoro) |

---

## 3. Price and negotiation

| | € |
|---|---|
| Seller's ask | 75,000 |
| **Nick's target close [decided 30/09]** | **50,000** |
| Suggested opening offer | ~40,000–45,000 |
| Fallback if the seller holds above €50K | A deferred, volume-linked portion (≈ €15K paid after 12 months of verified sales) |

**Why the price should be lower:** most of the projected profit comes from Masseria Cilentana's milk, from the yield, and from the new brand and channels, not from anything the seller built. The seller's volumes are verbal only and the retail sales ledger is handwritten. The price should rest on verified seller earnings and an independent equipment appraisal.

---

## 4. Capital required (all-in, at the €50K target)

| Line | € | Note |
|---|---|---|
| Asset purchase | 50,000 | Target price |
| Refrigerated milk truck | 15,000 | 5 km farm-to-dairy run |
| Registration / transfer tax | ~4,000 | **Uncertain**, see section 10 |
| Notary, legal, due diligence, inspection | ~5,000 | |
| Equipment contingency (F-gas, boiler) | ~8,000 | Equipment condition is unverified |
| Working capital | ~20,000 | ≈ 6 weeks of non-milk costs, opening stock, lease deposit |
| DOP adhesion (RINA: dairy €490 + farm €80) | 570 | One-off |
| POS and operations hardware (v45) | ~3,000 | Epson FP-81 II RT bundle €759, WisePad 3, cash drawer, till tablet, 2 floor tablets, scale, label and A4 printers, network, 10% contingency |
| Launch photoshoot (v46) | 500 | Real caseificio footage, with commercial rights |
| **Total** | **≈ 106,070** | Rounded to **~€106K** |

Not yet in the total: local launch campaign and signage, ≈ €7,450 (inside the €15,900 marketing benchmark, see section 8). A possible **PSR Campania grant of €10–25K** (20–50% of €50K) is **[estimate]**, not banked.

---

## 5. Operating model: the dairy on its own (base case, net of IVA)

### Key assumptions
| Assumption | Value | Source |
|---|---|---|
| Annual cheese volume | **37,510 kg** (70 kg/day off-season, 200 kg/day summer; ≈ 103 kg/day average) | **[seller]**, unverified |
| Yield | **30%** (3.33 kg milk per kg of mozzarella) | **[decided 29/09]**. Trial: 37% fresh, ~32% after 30 h in governing liquid, ~65% moisture |
| Milk needed | 125,033 kg/yr (≈ 343 kg/day average; plant nameplate 1,200 kg/day; farm can supply ~1,300 kg/day) | [model] |
| Milk price paid to the farm | **€1.70/kg + 10% IVA** (IVA recoverable) | **[decided]** |
| Shelf price | **€14.00/kg including 4% IVA** → €13.46/kg net. This is the store's current price, and Nick is keeping it | **[decided]** |
| Complementary resale (bread, honey, oil, wine, aged cheese, cured meats) | €90,000/yr at shelf → €83,074 net; COGS €50,400 | [model] |
| Process | **Pasteurised milk** (HTST ≥ 72 °C/15 s, CCP 2), natural whey starter, calf rennet | **[decided 02/10]** |
| Fixed OpEx benchmarks | Labour €68,205 · utilities €27,660 · consumables €27,978 · marketing €15,900 · lease €14,400 (plus casaro's helper, DOP fees €2,909/yr, hardware/e-invoicing ≈ €950/yr, AI social tool €700/yr) | [model] |

### Base-case P&L (annual)
| | € |
|---|---|
| Cheese revenue (37,510 kg × €14 ÷ 1.04) | 504,942 |
| Complementary revenue (net) | 83,074 |
| **Total revenue** | **588,016** |
| Milk (125,033 kg × €1.70) | (212,556) |
| Complementary COGS | (50,400) |
| Other operating costs (labour incl. casaro and helper, utilities, consumables, marketing, lease, DOP) | (167,931) **[derived]** |
| **Net operating profit (v43)** | **157,129** |
| Less v45 hardware/e-invoicing and v47 AI social tool fixed costs | ≈ (1,650) |
| **Net operating profit, current (v47)** | **≈ 155,500 (~€12,960/month)** |
| Payback on €106K | **≈ 8.2 months** |

Profit is before income tax. If the dairy sits inside the farm as an *attività connessa*, income tax may be cadastral (reddito agrario) rather than on actual profit, which could be the biggest single number in the plan. **Confirm with the commercialista.**

### Scenarios (from the v43 model, before the ≈ €1,650 v45–v47 fixed costs)
| Scenario | Channel mix | Net profit €/yr |
|---|---|---|
| Wholesale fallback | Everything sold to trade at €11/kg | 65,862 |
| **Base** | 100% shop at €14/kg + complementary products | **157,129** |
| Upside A | 80% shop + 20% e-commerce at €21/kg | 207,624 |
| Upside B | 60% shop + 40% e-commerce at €21/kg | 258,118 |
| **Conservative** | 50% of the seller's volume (18,755 kg) | **≈ 13,100 (≈ 12,400 after v47)** → payback ≈ 8.6 years |

E-commerce benchmarks: Flash Market €23.60/kg and CasaBufala online €37.80/kg (Sept 2026 scrape). €21/kg is used as a deliberate discount to those.

**Implied break-even [derived]:** interpolating between the base and the 50% cases gives a contribution of ≈ €7.68 per kg of cheese. That puts break-even at **≈ 17,100 kg/yr (≈ 47 kg/day, ≈ 46% of the seller's stated volume)**. An older figure of 13,300 kg/yr was calculated before the helper, the 30% yield change and the IVA treatment, and should no longer be used.

### IVA (cash flow, not profit)
Purchases carry about 10% IVA and cheese sales carry 4%, so the dairy builds an **IVA credit of ≈ €5–7K/yr** that can be refunded or offset in F24 (offsets above €5K need a visto di conformità). This holds only in the ordinary IVA regime. Under the agricultural special regime (dairy inside the farm), it doesn't arise.

---

## 6. Group effect (farm + dairy)

| | € /yr | Source |
|---|---|---|
| Dairy net profit (v47) | ≈ 155,500 | [model] |
| Farm's premium on milk sold to the dairy (125,033 kg × €0.40 above the €1.30 market) | 50,013 | [model] |
| **Incremental group gain, base** | **≈ 205,500** | [derived] |
| Incremental group gain, conservative (50% volume) | ≈ 37,400 | [model] |

The dashboard's "group €450,957/yr" figure adds dairy profit, the farm's **gross** milk revenue from the dairy (€212,556) and "freed" milk sold at wholesale (62,517 kg × €1.30). It mixes profit with gross revenue, so don't use it as a profit number. The incremental-gain line above is the meaningful comparison.

If the dairy is run **inside** Masseria Cilentana, the €1.70 transfer price is an internal number with no invoice. The group gain is then the same total, just without the split between the two entities.

---

## 7. Masseria Cilentana: three-year financial picture (2023–2025)

**Status: NOT PROVIDED.** None of the material available so far (the project docs, the ops system or past chats) contains the farm's historical accounts. Its ledger is kept by its accountant offsite. Before relying on this brief for any financing or structuring decision, Claude should ask Nick for the documents below and fill in the table.

### What we know about the farm today
- Buffalo milk ranked **#68 nationally, #11 regionally** on production and quality **[stated by Nick]**.
- Sells **100% of its milk wholesale at ≈ €1.30/kg** to large cheese groups **[stated]**.
- Supply available to the dairy: **~1,300 kg/day** (the ops-system setting `farm.default_kg_per_day`; Nick restored this value) **[stated]**. If that were sustained all year, it would be ≈ 474,500 kg and ≈ €617K of gross milk revenue at €1.30. **This is [derived] only. Check it against the real delivery records.**
- Milk quality on the trial day: fat 8.20%, protein 4.45%, pH 6.90, 4 °SH. That is above the DOP minimums of fat ≥ 7.23% and protein ≥ 4.2%. Milking is at 04:00, with milk at the dairy by 06:30.
- Project context says it holds **IAP** status. **Confirm** the holder (person or company) and the date.

### Table to fill (from the accountant)
| | 2023 | 2024 | 2025 |
|---|---|---|---|
| Milk delivered (kg) | | | |
| Average price received (€/kg) | | | |
| Milk revenue | | | |
| Livestock sales (calves, culls) | | | |
| CAP/PAC payments and other subsidies | | | |
| Other revenue | | | |
| Feed and forage | | | |
| Labour (employees + family/INPS agricoltori) | | | |
| Veterinary, AI, herd health | | | |
| Energy and fuel | | | |
| Rent / land costs | | | |
| Maintenance, insurance, other | | | |
| EBITDA | | | |
| Depreciation | | | |
| Interest | | | |
| Taxes | | | |
| **Net result** | | | |
| Cash at year end | | | |
| Bank debt / leases at year end | | | |
| Herd (total head / lactating) | | | |
| kg milk per lactating head | | | |
| Main buyers and contract terms (notice periods, exit penalties) | | | |

### Documents to request
Bilanci or rendiconti 2023–2025; Modello Redditi / IRAP / IVA returns; milk-buyer statements or invoices (kg × price, monthly); AGEA/PAC payment statements; loan and leasing schedules; herd register (BDN) extract; current milk supply contracts.

### Questions the farm numbers must answer
1. **Can the farm fund ≈ €106K** from cash, or what financing is needed (bank, ISMEA, PSR)?
2. **Seasonality:** how does monthly farm output compare with the dairy's summer peak, and with the milk still owed to existing buyers?
3. **Exit cost:** what does diverting ~125,000 kg/yr away from current buyers cost (notice periods, penalties, lost volume bonuses)?
4. **IAP tests:** does the farm still meet the IAP income and time tests once dairy revenue is added? Does own milk stay the **prevailing** input (needed for *attività connessa* treatment)?
5. **Real farm margin at €1.30/kg:** this shows how much of the €0.40/kg transfer premium is genuine new value and how much is a reallocation between entities.

---

## 8. Launching La Perla del Cilento

### Brand and positioning
- Line: **"Sempre 100% bufala, dalle nostre bufale al banco."** The pitch is single herd and same-day milk. Never imply that other DOP producers aren't 100% buffalo.
- Quality-led. Plans include website pre-orders for in-store pickup, influencer and creator partnerships, and a launch photoshoot. The trading name must not attach "Cilento" to the DOP name (see section 9).

### Website (Shopify, perladelcilento.it, Basic plan)
- **Never gone live.** The storefront is likely still password-protected. Store ownership has moved to Nick's main Shopify user.
- About 20 products, 9 collections. Prices include IVA. Languages: IT + EN/DE/FR/ES (152 fields translated per language). Ships to **Italy, Austria, Germany, France** on BRT carrier-calculated rates (+5%). Checkout to each EU country still needs testing. Free shipping in Italy from €99.90.
- **Overselling allowed** on all dairy variants (production follows orders). Paid, unshipped web orders feed the next day's milk plan.
- **Launch blockers still open:** policies with placeholder text (Terms, a clothing-template refund policy, a phone placeholder); Ricotta has no price; duplicate 500 g variants on La Perla Classica; B2B and subscription copy with price-maths errors and products that aren't made (burrata, caciocavallo "podolico", pecorino di bufala); health claims on olive oil; subscriptions have no selling plans; EU OSS VAT registration once EU sales pass €10K/yr; P.IVA and address in the footer.

### Sales channels
| Channel | Status |
|---|---|
| Shop counter | **Shopify POS** is the only till, with an **Epson FP-81 II RT** fiscal printer (buy once the selling P.IVA is final) |
| Web shop | Built, not live |
| Store pickup / pre-order | Designed (pickup slots, BENVENUTO10 code to create) |
| Glovo (local delivery, Agropoli) | Catalog collection and landing page ready; partner account to open |
| Just Eat, Deliveroo | Planned. Orders are rung through POS; prices marked up to cover the 15–25% commission |
| Wholesale (HoReCa) | Standing orders supported (€11–11.50/kg). Not in the base case |

### Marketing budget (inside the €15,900/yr benchmark unless noted)
- Launch plan ≈ €12,065, including the local opening campaign of **€7,450**: signage ≈ €4,750 (LED fascia sign €2,500, window graphics, projecting sign, road signs, price/allergen boards) and local ads ≈ €2,700 (Meta and Google local, 5,000 flyers, posters, local web/radio, an opening event with live stretching).
- AI social content tool (Predis.ai) €700/yr and photoshoot €500. Both are budgeted on top of the €15,900.

### Operations system (already built)
- Supabase "Caseificio" database, a tablet PWA and an owner console, all branded La Perla. It covers milk planning, guided dosing, lot traceability, HACCP CCP logging with lot holds, the lab sampling plan, purchasing and goods receipt, stock counts, shifts, Shopify order and customer sync, shipping/DDT, a marketing module, and a monthly package for the commercialista.
- Access is by role (10 profiles, from owner to consultant). Nicola Celso and Emilio Celso are admins with the Socio profile. Only Nick manages users.
- E-invoicing will run on **Fatture in Cloud** (Standard, €144/yr).
- Before go-live: purge the simulated September data, enter the real suppliers, staff, doses and equipment dates, and push the latest code commit (v0.40, `18d8b39`, still only on Nick's Mac).

### The AI agent team (bots)
The management layer (purchasing, planning, compliance, sales sync, marketing, accounting) is run by **scheduled AI bots** instead of office staff. That is why the €68,205 labour benchmark has no admin or office hire. Each bot reads a single database function and reports in Italian. **Bots propose and people decide:** purchase orders, milk plans, promos, recipe changes, content posts and local spending all go to an approval queue in the owner console. The only things bots write on their own are order and customer syncs from Shopify and routine status changes.

**Live: 15 bots, Agropoli time (Europe/Rome)**

| Bot | When | What it does | Needs approval? |
|---|---|---|---|
| Clienti Shopify | Mon–Sat 06:05 | Syncs customers from Shopify, which is the master customer list | No |
| Ordini Shopify | Mon–Sat 06:11 | Imports web and POS orders, books stock against lots by first expiry, closes the POS day, marks packed shipments as fulfilled in Shopify with tracking | No |
| Acquisti (procurement) | Mon–Sat 06:20 | Proposes purchase orders from stock cover, supplier lead times and minimum orders | Yes, each PO |
| Brief del mattino | Mon–Sat 06:47 | Daily brief: production, sales, stock, what needs doing today | — |
| Brief settimanale | Mon 07:08 | Weekly P&L estimate against the **€2,990/week** benchmark (= €155,500/yr), yield, waste, sales by channel, milk-plan accuracy | — |
| Manutenzioni e scadenze | Tue 07:17 | Compliance calendar: machine calibration and maintenance, HACCP training, lab sampling, pest control, permits. Drafts messages to technicians | — |
| Sell-down | Mon–Sat 07:23 | Spots lots at risk of expiring and proposes counter promos or wholesale offers | Yes, price changes |
| Revisione mensile | 1st of month 07:41 | Monthly review: recall drill, recipe tuning, milk quality per supplier, unit cost and margin by channel, food-safety summary | Yes, recipe updates |
| Marketing | Mon + Thu 07:53 | Runs the local launch campaign (permits, quotes, spending) and the content calendar | Yes, spending and posts |
| Ordini ingrosso | Mon–Sat 18:20 | Confirms standing wholesale orders for tomorrow and drafts WhatsApp confirmations | — |
| Piano latte | Mon–Sat 18:52 | Sizes tomorrow's milk order from sales history, wholesale orders, web pre-orders and what the farm has available (a 1,200 kg plan costs €2,040 at €1.70) | Yes, each plan |
| Chiusura serata | Mon–Sat 19:02 | Evening HACCP nudge: missing cold checks, CCP records, open batches, effluent log, unshipped orders | — |
| Controllo sistema | Mon–Sat 20:36 | System health: data quality, stale approvals, negative stock, silent tablet | — |
| Allarme bot | Hourly :50, 06:50–21:50 Mon–Sat | Watchdog: alerts if any bot errors, misses a slot or gets stuck | — |
| Giacenze Shopify | Scheduled, **inactive** | Pushes stock levels to Shopify. Switched off because overselling is allowed | — |

**Safety nets:** a database heartbeat (pg_cron, hourly) flags missed bot runs even if the scheduler itself fails. Since v0.40, every bot's report and every alert lands in one **bot dashboard** feed (Configurazione → Bot, with an unread counter in the console). An audit log records who or which bot changed what.

**Planned or not yet wired**
- **Contabilità (accounting):** spec written for the commercialista. On the 1st it drafts deferred invoices for wholesale customers, then sends approved ones to SDI via Fatture in Cloud. On Mondays it matches incoming supplier invoices to goods received and the farm's milk delivery notes, and it prepares a monthly package for the accountant. About a day to build once the commercialista answers the IVA and numbering questions. **Depends on the entity decision**: inside Masseria Cilentana it's one Fatture in Cloud account; with a separate Srl it's two.
- **Consorzio DOP monthly declaration:** the function is built (milk in, DOP kg made, lots, labels, kg sold). It goes into the monthly bot once the Consorzio confirms the official format.
- **AI social content (Predis.ai, €700/yr):** connection built. It needs the subscription, brand kit and keys.
- **Delivery apps (Glovo, Just Eat, Deliveroo):** no bot. Orders are rung through Shopify POS, so the Ordini Shopify bot already captures them.

**Running costs not yet in the plan's OpEx:** the Supabase Pro plan, the Claude subscription that runs the scheduled bots, and hosting (Netlify). Add them to the fixed-cost line once confirmed.

---

## 9. Regulatory: DOP and food safety

- **The DOP zone fits:** all of the province of Salerno is inside it, so both the farm and the dairy qualify.
- **Binding rules:** whole buffalo milk processed within 60 h of milking; **natural whey starter only** (no commercial cultures); calf rennet; **moisture ≤ 65%**, fat on dry matter ≥ 52%; **packing must happen in the same plant** (so a sealer is needed, and it is still unconfirmed in the inventory); every pack carries the Consorzio mark; no extra geographic qualifiers; smoked product must be named "…DOP affumicata"; single pieces ≤ 800 g.
- **Fees:** RINA Agrifood (control body) plus Consorzio contributions, which are payable whether or not you join. The model uses **€2,909/yr + €570 adhesion** at 37,510 kg. At full 1,200 kg/day capacity it would be ≈ €7,700/yr. The Consorzio's per-kg rate (≈ €0.044/kg) is an **estimate**.
- **The Consorzio statute has a non-compete clause:** members and their partners may not take part in competing ventures. Get it read narrowly before joining.
- **HACCP plan:** drafted (Italian) and needs a consultant to sign it. Key items: milk arrives 2.5 h after milking at ≤ 8 °C (needs farm cooling or an ASL authorisation); an antibiotic test on every delivery; pasteurisation as CCP 2 (the **calibration certificate is needed from the seller**); about 100 lab analyses per year.
- **From the seller:** CE approval number (Reg. 853/2004), AUA / wastewater discharge permit and analyses, water analyses, pest-control contract, scale metrology checks, staff training certificates, the existing sign permit.

---

## 10. Tax structuring: open points and flags

| Topic | Current model | Flag |
|---|---|---|
| **Entity** | Separate Srl, ordinary IVA regime | The *attività connessa* inside Masseria Cilentana could tax the dairy on a cadastral basis and remove the milk invoicing. Prevalence of own milk has to be proven (the ops data already records this). **Decision pending.** |
| **Registration tax** | ~€4,000 (8% IAP vs 15% standard; "IAP saving" ≈ €3,500 at €50K) | **Likely wrong basis.** The 8%/15% rates match agricultural-land transfers. As far as I know, a pure equipment purchase from a VAT-registered Srl carries **22% IVA (recoverable) plus a fixed registration tax**. A *cessione d'azienda* (going concern including the lease and goodwill) is outside IVA and pays registration tax of about **3% on movables and goodwill**. Confirm with the commercialista before quoting any IAP saving. |
| **IRAP** | Dashboard: 1.9% agricultural vs 3.9% | Agricultural producers within art. 32 TUIR have been **exempt from IRAP since 2016**, as far as I know. Verify; this affects only the separate-Srl option. |
| **IVA on cheese** | iva-position: **4%** on cheese | An older dashboard panel cites a 10% output rate and an 8.8% compensation rate. Those conflict with the 4% used in the model. Confirm the rate and regime. |
| **Milk IVA** | 10% on farm-to-dairy milk | Confirm. |
| **Grants** | PSR Campania 2023–27 (up to 50%), ISMEA | Eligibility and timing to confirm. Usually requires applying **before** spending. |

---

## 11. Risks and gating conditions

**Three conditions before signing:**
1. An **independent engineering inspection** of all production equipment: rating plates, capacities, CE declarations, the pasteuriser, the milk tanks' refrigerant (F-gas), and the boiler or steam supply.
2. **DURC / P.IVA 06052830657 clearance**, plus written confirmation that no asset is leased, under a lien, or carries a subsidy resale restriction.
3. **At least two years of actual sales and tax records** (corrispettivi, Modello Redditi, IVA) to verify the 37,510 kg/yr claim.

**Main risks:**
- **Volume:** profit drops to ≈ €12K/yr at half the stated volume, and break-even is ≈ 46% of the stated volume. This is the biggest risk.
- **Moisture and DOP compliance:** the trial cheese was ~70% fresh / ~65% settled, right at the cap. A lab test is needed.
- **Labour scaling:** stretching is done by hand.
- **Equipment items not yet seen:** cold room, boiler, packaging sealer, brine tank, pumps, water treatment.
- **Energy price shocks:** the dashboard stress test showed a high break-even tolerance, but it was calculated on old assumptions.
- **Exit friction** from the farm's current milk buyers (section 7).
- **Lease:** the landlord's consent, indexation, and whether the permitted use covers both the dairy and the shop.

---

## 12. Decision log

| Date | Decision |
|---|---|
| 29/09 | Yield 30% (was 20%); retail price €14/kg including IVA, kept (€16.80 dropped) |
| 29/09 | Casaro's helper added (€1,000/month net) |
| 30/09 | Milk €1.70/kg + 10% IVA; all figures net of IVA |
| 30/09 | **Target close price €50,000**; open lower; deferred volume-linked portion if needed |
| 02/10 | Pasteurised milk |
| 02/10 | Shopify POS as the only till plus Epson RT fiscal printer; OpenFiskal ruled out |
| 02/10 | Fatture in Cloud for e-invoicing (Aruba ruled out) |
| 02/10 | Overselling allowed on the website and POS |
| 02/10 | EU shipping limited to AT/DE/FR; Glovo, Just Eat and Deliveroo as local channels |
| 02/10 | Hardware ≈ €3,000, photoshoot €500, AI social tool €700/yr added to the plan |
| Earlier | Asset purchase, not shares; cosmetics excluded; 2 retail staff kept |
| **Open** | Operating entity (inside the farm or a separate Srl) |

---

## 13. Superseded figures (do not use)

| Old | Current |
|---|---|
| Yield 20% | 30% |
| Price €16.80/kg | €14.00/kg including IVA (€13.46 net) |
| Milk €1.30 or €1.75/kg | €1.70/kg ex IVA |
| OpEx €154,143 | See section 5 (other operating costs ≈ €167,931 plus milk and complementary COGS) |
| Profit €220,787 / €89K / €64K | ≈ €155,500 (v47) |
| Payback 4.1 or 13 months | ≈ 8.2 months on €106K |
| Ask-based capital €97.5K or €130K | ≈ €106K at the €50K target |
| IAP registration saving €5,250 | Unverified, see section 10 |
| Break-even 13,300 kg/yr | ≈ 17,100 kg/yr [derived] |
| Daily capacity 1,200 kg milk → 240 kg cheese | Nameplate only. The model is sales-limited at 37,510 kg/yr cheese (≈ 343 kg milk/day average) |

---

## 14. Suggested next tasks for Claude

1. Get and analyse Masseria Cilentana's 2023–2025 accounts (section 7). Then build a combined farm + dairy three-year projection and a funding plan for the ≈ €106K.
2. Model the **entity decision** (inside the farm vs a separate Srl): tax, IVA, bookkeeping cost, liability.
3. Draft the **due diligence request list** for the seller (sections 9 and 11) and a **negotiation brief** for the €40–50K range.
4. Draft the questions for the **commercialista** (section 10) and the **landlord** (lease).
5. Plan a **Year 1 ramp** (for example 40% → 70% → 100% of stated volume) with monthly cash flow, including the IVA credit timing.
6. Write a **launch checklist** for the Shopify site and channels (section 8 blockers).
7. Finish the **bot team**: build the Contabilità bot once the entity and IVA questions are answered, wire the Consorzio declaration, and put a cost on running the bots.

---

## 15. Source documents (in the Caseificio project)

investment-recommendation-2026-09-29 · prova-resa-2026-09-29 · iva-position · dop-fees · dop-rules · equipment-inventory-2026-10-02 · food-safety-haccp-2026-10-02 · marketing-module-2026-10-02 · shopify-store-audit / shopify-conversion-audit / shopify-eu-launch (2026-10-01) · ops-system-action-points · disciplinare_mozzarella_2008.pdf · statuto.pdf (Consorzio)
