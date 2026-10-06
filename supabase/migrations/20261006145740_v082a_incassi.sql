-- =============================================================================
-- v0.82a (06/10/2026) · Incassi: Shopify payouts and bank statements matched against orders
--   * payment_transactions / payment_payouts: Shopify Payments charges, refunds, fees and payouts. Today they come from the
--     Shopify admin CSV export (Finanze → Pagamenti → Esporta transazioni), because the Shopify connector has no payments scope.
--     payments_import() takes normalised rows, so an API feed can use the same entry point later.
--   * bank_transactions (existing table): statement rows imported from the bank CSV with bank_import(); duplicates skipped.
--   * recon_run(): links payment rows to orders, payouts to bank credits, bank credits to invoices / wholesale orders, applies
--     bank_rules (fees, ignore…), raises one console notice without amounts. Runs nightly (pg_cron) and after each import.
--   * v_recon_exceptions: what a person must look at (paid order with no payout, payout not in the bank, unknown credit…).
--     recon_ack() marks an item as checked; recon_set_bank() matches or classifies a bank row by hand.
--   * recon_status(): the numbers for the console tab "Incassi".
-- Connector rules: no destructive keywords, no top-level UPDATE. All functions run with the caller's rights (RLS applies).
-- =============================================================================
set search_path = fabula, public;

-- 1 · tables -------------------------------------------------------------------------------------------------
create table if not exists fabula.payment_payouts (
  id            text primary key,                         -- provider payout id
  provider      text not null default 'shopify_payments',
  payout_date   date not null,
  status        text,                                     -- paid · in_transit · scheduled · failed · canceled
  gross_eur     numeric(12,2),
  fee_eur       numeric(12,2),
  net_eur       numeric(12,2) not null,
  currency      text not null default 'EUR',
  bank_ref      text,
  bank_tx_id    uuid references fabula.bank_transactions(id),
  match_note    text,
  matched_at    timestamptz,
  matched_by    uuid,
  source        text not null default 'csv',
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index if not exists payment_payouts_open_idx on fabula.payment_payouts (payout_date) where bank_tx_id is null;

create table if not exists fabula.payment_transactions (
  id             text primary key,                        -- provider id, or 'h:' + md5 of the row
  provider       text not null default 'shopify_payments',
  tx_at          timestamptz not null,
  tx_type        text not null,                           -- charge · refund · adjustment · chargeback · reserve …
  order_ref      text,                                    -- as exported: "#1001" or a Shopify gid
  sales_order_id uuid references fabula.sales_orders(id),
  payout_id      text,
  payout_date    date,
  payout_status  text,
  amount_eur     numeric(12,2) not null,
  fee_eur        numeric(12,2) not null default 0,
  net_eur        numeric(12,2) not null,
  payment_method text,
  currency       text not null default 'EUR',
  test           boolean not null default false,
  source         text not null default 'csv',
  raw            jsonb,
  created_at     timestamptz not null default now()
);
create index if not exists payment_tx_payout_idx on fabula.payment_transactions (payout_id);
create index if not exists payment_tx_order_idx on fabula.payment_transactions (sales_order_id);

alter table fabula.bank_transactions add column if not exists booking_date date;
alter table fabula.bank_transactions add column if not exists balance_eur numeric(12,2);
alter table fabula.bank_transactions add column if not exists match_kind text;          -- payout · invoice · order · rule kinds · manual kinds
alter table fabula.bank_transactions add column if not exists matched_payout_id text;
alter table fabula.bank_transactions add column if not exists match_note text;
alter table fabula.bank_transactions add column if not exists matched_at timestamptz;
alter table fabula.bank_transactions add column if not exists matched_by uuid;
alter table fabula.bank_transactions add column if not exists import_batch uuid;
alter table fabula.bank_transactions add column if not exists raw jsonb;
create index if not exists bank_tx_open_idx on fabula.bank_transactions (value_date) where match_kind is null;

create table if not exists fabula.bank_rules (
  id          uuid primary key default gen_random_uuid(),
  pattern     text not null,                              -- case-insensitive regex on description + counterparty
  direction   text not null default 'any' check (direction in ('in', 'out', 'any')),
  match_kind  text not null,                              -- bank_fee · cash_deposit · transfer · expense · ignore …
  note        text,
  account_code text,
  sort        int not null default 100,
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);
insert into fabula.bank_rules (pattern, direction, match_kind, note, sort)
select * from (values
  ('(commission|competenze|canone (mensile|conto)|spese (tenuta|invio)|imposta di bollo)', 'out', 'bank_fee', 'Spese e imposte bancarie', 10),
  ('versamento (di )?contant', 'in', 'cash_deposit', 'Versamento contanti del banco', 20),
  ('giroconto|giro conto', 'any', 'transfer', 'Giroconto tra conti propri', 30)
) v(pattern, direction, match_kind, note, sort)
where not exists (select 1 from fabula.bank_rules);

create table if not exists fabula.recon_acks (
  key        text primary key,                            -- v_recon_exceptions.key
  active     boolean not null default true,
  note       text,
  acked_by   uuid,
  acked_at   timestamptz not null default now()
);

insert into fabula.settings (key, value, description, data_type, sort) values
  ('recon.payout_days', '7', 'Giorni entro cui un versamento Shopify deve comparire in banca prima di segnalarlo', 'number', 90),
  ('recon.order_days', '3', 'Giorni dopo cui un ordine pagato con Shopify Payments senza transazione nel file pagamenti viene segnalato', 'number', 91),
  ('recon.bank_account', '', 'Nome del conto per gli estratti importati (es. "BCC Aquara 1234"). Vuoto = chiedi a ogni importazione', 'text', 92)
on conflict (key) do nothing;

-- 2 · access: area finanza (titolare, socio, amministrazione gestiscono; consulente vede) -----------------------------
do $$
declare t text;
begin
  foreach t in array array['payment_payouts', 'payment_transactions', 'bank_rules', 'recon_acks'] loop
    execute format('alter table fabula.%I enable row level security', t);
    execute format('grant select, insert, update on fabula.%I to authenticated', t);
    execute format('grant all on fabula.%I to service_role', t);
    insert into fabula.table_areas (table_name, area, read_open, write_level)
    values (t, 'finanza', false, case when t = 'bank_rules' then 3 else 2 end) on conflict (table_name) do nothing;
    if not exists (select 1 from pg_policy where polrelid = ('fabula.' || t)::regclass and polname = t || '_authenticated_all') then
      execute format('create policy %I on fabula.%I for all to authenticated using (true) with check (true)', t || '_authenticated_all', t);
      execute format('create policy %I on fabula.%I as restrictive for select to authenticated using ((select fabula.can_table(%L, false)))', t || '_role_select', t, t);
      execute format('create policy %I on fabula.%I as restrictive for insert to authenticated with check ((select fabula.can_table(%L, true)))', t || '_role_insert', t, t);
      execute format('create policy %I on fabula.%I as restrictive for update to authenticated using ((select fabula.can_table(%L, true)))', t || '_role_update', t, t);
    end if;
  end loop;
end $$;

-- 3 · imports ------------------------------------------------------------------------------------------------
-- Bank statement rows: [{date, value_date, amount, description, counterparty, ref, balance}], dates YYYY-MM-DD, amount signed.
-- The same file (or an overlapping export) can be imported again: rows already there are skipped.
create or replace function fabula.bank_import(p_account text, p_rows jsonb)
returns jsonb language plpgsql set search_path = fabula, public as $$
declare r jsonb; i int := 0; n_new int := 0; n_old int := 0; v_batch uuid := gen_random_uuid(); v_id text; v_amt numeric; v_val date; v_book date;
        v_key text; seen jsonb := '{}'; v_occ int; v_from date; v_to date; v_acc text := nullif(btrim(coalesce(p_account, '')), '');
begin
  if not fabula.can('finanza', 2) then raise exception 'Il tuo profilo non può importare movimenti bancari' using errcode = '42501'; end if;
  if v_acc is null then raise exception 'Indica il conto (es. "BCC Aquara 1234")'; end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then raise exception 'Nessuna riga da importare'; end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    i := i + 1;
    begin
      v_amt := round((r->>'amount')::numeric, 2);
      v_book := nullif(r->>'date', '')::date;
      v_val := coalesce(nullif(r->>'value_date', '')::date, v_book);
    exception when others then raise exception 'Riga %: data o importo non validi (%)', i, r::text; end;
    if v_amt is null or v_val is null then raise exception 'Riga %: data o importo mancanti', i; end if;
    -- identical rows in one file (two equal payments on the same day) get an occurrence number, so re-imports still match
    v_key := md5(lower(v_acc) || '|' || v_val || '|' || v_amt || '|' || lower(btrim(coalesce(r->>'description', ''))));
    v_occ := coalesce((seen->>v_key)::int, 0) + 1; seen := seen || jsonb_build_object(v_key, v_occ);
    v_id := coalesce(nullif(btrim(r->>'ref'), ''), 'h:' || v_key || ':' || v_occ);
    insert into fabula.bank_transactions (bank_account, value_date, booking_date, amount_eur, description, counterparty, external_id, balance_eur, source, import_batch, raw)
    values (v_acc, v_val, v_book, v_amt, nullif(btrim(coalesce(r->>'description', '')), ''), nullif(btrim(coalesce(r->>'counterparty', '')), ''), v_id,
            round(nullif(r->>'balance', '')::numeric, 2), 'csv', v_batch, r)
    on conflict (external_id) do nothing;
    if found then n_new := n_new + 1; else n_old := n_old + 1; end if;
    v_from := least(v_from, v_val); v_to := greatest(v_to, v_val);
  end loop;
  return jsonb_build_object('account', v_acc, 'rows', i, 'inserted', n_new, 'skipped', n_old, 'from', v_from, 'to', v_to, 'batch', v_batch);
end $$;

-- Payment provider rows (Shopify "transazioni dei pagamenti" export or API):
-- [{id, date, type, order, payout_id, payout_date, payout_status, amount, fee, net, payment_method, currency, test}]
-- Payout totals are rebuilt from all their rows; a payout already matched to the bank keeps its match.
create or replace function fabula.payments_import(p_provider text, p_rows jsonb, p_source text default 'csv')
returns jsonb language plpgsql set search_path = fabula, public as $$
declare r jsonb; i int := 0; n_new int := 0; n_upd int := 0; v_id text; v_type text; v_amt numeric; v_fee numeric; v_net numeric; v_at timestamptz;
        payouts text[] := '{}'; v_prov text := coalesce(nullif(btrim(p_provider), ''), 'shopify_payments'); n_pay int := 0; n_skip int := 0; v_ins boolean;
begin
  if not fabula.can('finanza', 2) then raise exception 'Il tuo profilo non può importare i pagamenti' using errcode = '42501'; end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then raise exception 'Nessuna riga da importare'; end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    i := i + 1;
    v_type := lower(btrim(coalesce(r->>'type', '')));
    if v_type in ('payout', 'transfer', '') then n_skip := n_skip + 1; continue; end if;   -- payout rows are rebuilt from their transactions
    begin
      v_at := (r->>'date')::timestamptz;
      v_amt := round((r->>'amount')::numeric, 2);
      v_fee := round(coalesce(nullif(r->>'fee', '')::numeric, 0), 2);
      v_net := round(coalesce(nullif(r->>'net', '')::numeric, (r->>'amount')::numeric - coalesce(nullif(r->>'fee', '')::numeric, 0)), 2);
    exception when others then raise exception 'Riga %: data o importi non validi (%)', i, r::text; end;
    if v_at is null or v_amt is null then raise exception 'Riga %: data o importo mancanti', i; end if;
    v_id := coalesce(nullif(btrim(r->>'id'), ''), 'h:' || md5(v_prov || '|' || v_at || '|' || v_type || '|' || coalesce(r->>'order', '') || '|' || v_amt || '|' || v_fee));
    insert into fabula.payment_transactions (id, provider, tx_at, tx_type, order_ref, payout_id, payout_date, payout_status, amount_eur, fee_eur, net_eur,
                                             payment_method, currency, test, source, raw)
    values (v_id, v_prov, v_at, v_type, nullif(btrim(coalesce(r->>'order', '')), ''), nullif(btrim(coalesce(r->>'payout_id', '')), ''),
            nullif(r->>'payout_date', '')::date, nullif(lower(btrim(coalesce(r->>'payout_status', ''))), ''), v_amt, v_fee, v_net,
            nullif(btrim(coalesce(r->>'payment_method', '')), ''), upper(coalesce(nullif(r->>'currency', ''), 'EUR')), coalesce((r->>'test')::boolean, false), coalesce(p_source, 'csv'), r)
    on conflict (id) do update set payout_id = coalesce(excluded.payout_id, payment_transactions.payout_id),
                                   payout_date = coalesce(excluded.payout_date, payment_transactions.payout_date),
                                   payout_status = coalesce(excluded.payout_status, payment_transactions.payout_status),
                                   raw = excluded.raw
    returning (xmax = 0) into v_ins;
    if v_ins then n_new := n_new + 1; else n_upd := n_upd + 1; end if;
    if nullif(btrim(coalesce(r->>'payout_id', '')), '') is not null then payouts := array_append(payouts, btrim(r->>'payout_id')); end if;
  end loop;
  -- (re)build the payouts touched by this file
  insert into fabula.payment_payouts (id, provider, payout_date, status, gross_eur, fee_eur, net_eur, currency, source)
  select t.payout_id, v_prov, max(t.payout_date), case when bool_or(t.payout_status = 'paid') then 'paid' else max(t.payout_status) end, sum(t.amount_eur), sum(t.fee_eur), sum(t.net_eur), max(t.currency), coalesce(p_source, 'csv')
    from fabula.payment_transactions t
   where t.payout_id = any(payouts) and not t.test and t.payout_date is not null
   group by t.payout_id
  on conflict (id) do update set payout_date = excluded.payout_date, status = excluded.status, gross_eur = excluded.gross_eur,
                                 fee_eur = excluded.fee_eur, net_eur = excluded.net_eur, updated_at = now();
  get diagnostics n_pay = row_count;
  return jsonb_build_object('provider', v_prov, 'rows', i, 'inserted', n_new, 'updated', n_upd, 'skipped', n_skip, 'payouts', n_pay);
end $$;

-- Payout-level rows (payout CSV or API): [{id, date, status, net, gross, fee, bank_ref}]. Totals from transactions win when both exist.
create or replace function fabula.payouts_import(p_provider text, p_rows jsonb, p_source text default 'csv')
returns jsonb language plpgsql set search_path = fabula, public as $$
declare r jsonb; i int := 0; v_id text; v_prov text := coalesce(nullif(btrim(p_provider), ''), 'shopify_payments'); v_date date; v_net numeric;
begin
  if not fabula.can('finanza', 2) then raise exception 'Il tuo profilo non può importare i versamenti' using errcode = '42501'; end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then raise exception 'Nessuna riga da importare'; end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    i := i + 1;
    begin v_date := (r->>'date')::date; v_net := round((r->>'net')::numeric, 2);
    exception when others then raise exception 'Riga %: data o importo non validi (%)', i, r::text; end;
    if v_date is null or v_net is null then raise exception 'Riga %: data o importo mancanti', i; end if;
    v_id := coalesce(nullif(btrim(r->>'id'), ''), 'd:' || v_prov || ':' || v_date || ':' || v_net);
    insert into fabula.payment_payouts (id, provider, payout_date, status, gross_eur, fee_eur, net_eur, bank_ref, source)
    values (v_id, v_prov, v_date, nullif(lower(btrim(coalesce(r->>'status', ''))), ''), round(nullif(r->>'gross', '')::numeric, 2),
            round(nullif(r->>'fee', '')::numeric, 2), v_net, nullif(btrim(coalesce(r->>'bank_ref', '')), ''), coalesce(p_source, 'csv'))
    on conflict (id) do update set status = coalesce(excluded.status, payment_payouts.status), bank_ref = coalesce(excluded.bank_ref, payment_payouts.bank_ref),
                                   gross_eur = coalesce(payment_payouts.gross_eur, excluded.gross_eur), fee_eur = coalesce(payment_payouts.fee_eur, excluded.fee_eur),
                                   updated_at = now();
  end loop;
  return jsonb_build_object('provider', v_prov, 'rows', i);
end $$;

-- 4 · matching -----------------------------------------------------------------------------------------------
create or replace function fabula.recon_norm(p text) returns text language sql immutable set search_path = fabula, public as $$
  select regexp_replace(lower(coalesce(p, '')), '[^a-z0-9]', '', 'g') $$;

-- does a bank row's text mention this party? (first significant word of the legal or trade name, 4+ letters)
create or replace function fabula.recon_mentions(p_text text, p_party uuid) returns boolean language sql stable set search_path = fabula, public as $$
  select exists (select 1 from fabula.parties p,
                   lateral (select w from regexp_split_to_table(lower(coalesce(p.trade_name, '') || ' ' || coalesce(p.legal_name, '')), '[^a-zà-ù0-9]+') w
                             where length(w) >= 4 and w not in ('srl', 'srls', 'snc', 'sas', 'spa', 'societa', 'azienda', 'agricola', 'ditta', 'della', 'delle', 'dello')) x
                  where p.id = p_party and lower(coalesce(p_text, '')) like '%' || x.w || '%') $$;

create or replace function fabula.recon_run()
returns jsonb language plpgsql set search_path = fabula, public as $$
declare p record; b record; v_match uuid; v_ids uuid[]; v_named int[]; v_dist int[]; n_ord int := 0; n_pay int := 0; n_inv int := 0; n_wo int := 0; n_rule int := 0; n_amb int := 0;
        v_who uuid := fabula.my_staff_id(); v_exc int; v_items jsonb;
begin
  if not fabula.can('finanza', 2) then raise exception 'Il tuo profilo non può abbinare gli incassi' using errcode = '42501'; end if;

  -- a. payment rows → orders (Shopify order name "#1001", or the order gid / numeric id)
  update fabula.payment_transactions t set sales_order_id = so.id
    from fabula.sales_orders so
   where t.sales_order_id is null and t.order_ref is not null and not t.test
     and (so.order_number = t.order_ref or so.order_number = '#' || ltrim(t.order_ref, '#') or so.shopify_order_id = t.order_ref
          or (t.order_ref ~ '^\d+$' and so.shopify_order_id like '%/' || t.order_ref));
  get diagnostics n_ord = row_count;

  -- b. payouts → bank credits: same amount to the cent, from 2 days before to 10 days after the payout date.
  --    Best candidate: "shopify" in the text, then the nearest date. Two equally good candidates = left for a person.
  for p in select * from fabula.payment_payouts where bank_tx_id is null and net_eur <> 0 and coalesce(status, 'paid') not in ('failed', 'canceled', 'cancelled')
           order by payout_date loop
    select array_agg(z.id order by z.named desc, z.dist), array_agg(z.named order by z.named desc, z.dist), array_agg(z.dist order by z.named desc, z.dist)
      into v_ids, v_named, v_dist
      from (select bt.id, ((coalesce(bt.description, '') || ' ' || coalesce(bt.counterparty, '')) ~* 'shopify')::int as named, abs(bt.value_date - p.payout_date) as dist
              from fabula.bank_transactions bt
             where bt.match_kind is null and bt.amount_eur = p.net_eur and bt.value_date between p.payout_date - 2 and p.payout_date + 10) z;
    if v_ids is null then continue; end if;
    if array_length(v_ids, 1) > 1 and v_named[1] = v_named[2] and v_dist[1] = v_dist[2] then n_amb := n_amb + 1; continue; end if;
    update fabula.bank_transactions set match_kind = 'payout', matched_payout_id = p.id, reconciled = true, matched_at = now(), matched_by = v_who,
           match_note = 'Versamento ' || case p.provider when 'shopify_payments' then 'Shopify' else p.provider end || ' del ' || to_char(p.payout_date, 'DD/MM/YYYY') where id = v_ids[1];
    update fabula.payment_payouts set bank_tx_id = v_ids[1], matched_at = now(), matched_by = v_who, updated_at = now() where id = p.id;
    n_pay := n_pay + 1;
  end loop;

  -- c. bank credits → open sales invoices: same total and (invoice number in the text, or the customer named and only one such invoice)
  for b in select * from fabula.bank_transactions where match_kind is null and amount_eur > 0 order by value_date loop
    v_match := null;
    select i.id into v_match from fabula.invoices i
     where i.direction = 'out' and i.status not in ('paid', 'void') and i.total_eur = b.amount_eur
       and (fabula.recon_norm(b.description || ' ' || coalesce(b.counterparty, '')) like '%' || fabula.recon_norm(i.invoice_number) || '%'
            and length(fabula.recon_norm(i.invoice_number)) >= 2)
     order by i.invoice_date limit 1;
    if v_match is null then
      select i.id into v_match from fabula.invoices i
       where i.direction = 'out' and i.status not in ('paid', 'void') and i.total_eur = b.amount_eur
         and fabula.recon_mentions(b.description || ' ' || coalesce(b.counterparty, ''), i.party_id)
         and (select count(*) from fabula.invoices j where j.direction = 'out' and j.status not in ('paid', 'void') and j.total_eur = b.amount_eur and j.party_id = i.party_id) = 1
       limit 1;
    end if;
    if v_match is not null then
      update fabula.bank_transactions set match_kind = 'invoice', matched_invoice_id = v_match, reconciled = true, matched_at = now(), matched_by = v_who where id = b.id;
      update fabula.invoices set status = 'paid', paid_at = b.value_date, payment_ref = b.external_id, updated_at = now() where id = v_match;
      n_inv := n_inv + 1; continue;
    end if;
    -- d. … or wholesale orders not yet invoiced: same total and (order number in the text, or the customer named and only one such order)
    select so.id into v_match from fabula.sales_orders so
     where so.channel = 'wholesale' and so.status not in ('cancelled', 'draft') and so.invoice_id is null and so.total_eur = b.amount_eur
       and not exists (select 1 from fabula.bank_transactions x where x.matched_order_id = so.id)
       and ((length(fabula.recon_norm(so.order_number)) >= 4 and fabula.recon_norm(b.description) like '%' || fabula.recon_norm(so.order_number) || '%')
            or (fabula.recon_mentions(b.description || ' ' || coalesce(b.counterparty, ''), so.customer_id)
                and (select count(*) from fabula.sales_orders s2 where s2.channel = 'wholesale' and s2.status not in ('cancelled', 'draft') and s2.invoice_id is null
                       and s2.total_eur = b.amount_eur and s2.customer_id = so.customer_id
                       and not exists (select 1 from fabula.bank_transactions x where x.matched_order_id = s2.id)) = 1))
     order by so.order_date limit 1;
    if v_match is not null then
      update fabula.bank_transactions set match_kind = 'order', matched_order_id = v_match, reconciled = true, matched_at = now(), matched_by = v_who where id = b.id;
      n_wo := n_wo + 1;
    end if;
  end loop;

  -- e. rules (bank fees, cash deposits, transfers…) on what is still open
  update fabula.bank_transactions bt set match_kind = r.match_kind, match_note = r.note, reconciled = (r.match_kind <> 'cash_deposit'), matched_at = now(), matched_by = v_who
    from (select distinct on (bt2.id) bt2.id, ru.match_kind, ru.note
            from fabula.bank_transactions bt2 join fabula.bank_rules ru on ru.active
                  and (coalesce(bt2.description, '') || ' ' || coalesce(bt2.counterparty, '')) ~* ru.pattern
                  and (ru.direction = 'any' or (ru.direction = 'in' and bt2.amount_eur > 0) or (ru.direction = 'out' and bt2.amount_eur < 0))
           where bt2.match_kind is null order by bt2.id, ru.sort) r
   where bt.id = r.id;
  get diagnostics n_rule = row_count;

  -- f. one console notice, no amounts (the console is seen by every profile)
  select count(*) into v_exc from fabula.v_recon_exceptions where severity <> 'info';
  if v_exc > 0 then
    v_items := jsonb_build_array(jsonb_build_object('code', 'recon', 'label_it', 'Apri Console → Incassi'));
    insert into fabula.notices (key, severity, title_it, items, expires_at)
    values ('recon', 'warn', format('Incassi: %s da controllare (Console → Incassi)', v_exc), v_items, now() + interval '3 days')
    on conflict (key) do update set title_it = excluded.title_it, items = excluded.items, severity = excluded.severity, expires_at = excluded.expires_at, resolved_at = null;
  else
    update fabula.notices set resolved_at = now() where key = 'recon' and resolved_at is null;
  end if;

  return jsonb_build_object('orders_linked', n_ord, 'payouts_matched', n_pay, 'invoices_paid', n_inv, 'wholesale_matched', n_wo,
                            'rules_applied', n_rule, 'ambiguous', n_amb, 'to_check', v_exc);
end $$;

-- 5 · what a person must look at ---------------------------------------------------------------------------------
-- key is stable, so recon_ack() can mark an item as checked; severity info = listed, not counted in the notice.
create or replace view fabula.v_recon_exceptions with (security_invoker = true) as
with cfg as (
  select coalesce(fabula.setting_num('recon.payout_days', 7), 7)::int as payout_days,
         coalesce(fabula.setting_num('recon.order_days', 3), 3)::int as order_days,
         (select min(tx_at at time zone 'Europe/Rome')::date from fabula.payment_transactions where provider = 'shopify_payments' and not test) as pay_from,
         (select max(tx_at at time zone 'Europe/Rome')::date from fabula.payment_transactions where provider = 'shopify_payments' and not test) as pay_to,
         (select max(value_date) from fabula.bank_transactions) as bank_to,
         (now() at time zone 'Europe/Rome')::date as today
), card_orders as (
  select so.*, coalesce(so.shopify_payload->>'payment_gateways', '') as gw from fabula.sales_orders so
   where so.channel in ('shopify', 'store_pos') and so.status in ('confirmed', 'fulfilled', 'refunded')
), x as (
  -- a paid card order with no charge in the payments file (only inside the period the file covers)
  select 'order_no_payment:' || o.id as key, 'warn' as severity, 'order_no_payment' as kind, o.order_date as on_date, o.total_eur as amount_eur,
         'Ordine ' || o.order_number || ' pagato con carta ma assente dal file pagamenti Shopify' as label_it, o.id::text as ref, null::uuid as bank_tx_id
    from card_orders o, cfg
   where o.gw ~* 'shopify_payments' and cfg.pay_from is not null and o.order_date between cfg.pay_from and least(cfg.pay_to, cfg.today - cfg.order_days)
     and not exists (select 1 from fabula.payment_transactions t where t.sales_order_id = o.id and t.tx_type = 'charge')
  union all
  -- charged amount differs from the order total
  select 'charge_mismatch:' || o.id, 'warn', 'charge_mismatch', o.order_date, o.total_eur - coalesce(s.charged, 0),
         'Ordine ' || o.order_number || ': incassati ' || replace(to_char(coalesce(s.charged, 0), 'FM999990.00'), '.', ',') || ' € su ' || replace(to_char(o.total_eur, 'FM999990.00'), '.', ',') || ' €',
         o.id::text, null
    from card_orders o join (select sales_order_id, sum(amount_eur) filter (where tx_type = 'charge') as charged from fabula.payment_transactions
                              where sales_order_id is not null and not test group by 1) s on s.sales_order_id = o.id
   where abs(coalesce(s.charged, 0) - o.total_eur) >= 0.01
  union all
  -- a charge or refund whose order is not in the ops system
  select 'tx_no_order:' || t.id, 'warn', 'tx_no_order', (t.tx_at at time zone 'Europe/Rome')::date, t.amount_eur,
         'Pagamento Shopify (' || t.tx_type || coalesce(', ordine ' || t.order_ref, '') || ') senza ordine nel gestionale', t.id, null
    from fabula.payment_transactions t
   where t.sales_order_id is null and not t.test and t.tx_type in ('charge', 'refund')
  union all
  -- a payout that should be in the bank by now (only when the bank statement covers those days)
  select 'payout_not_in_bank:' || p.id, 'alert', 'payout_not_in_bank', p.payout_date, p.net_eur,
         'Versamento Shopify del ' || to_char(p.payout_date, 'DD/MM/YYYY') || ' non trovato in banca', p.id, null
    from fabula.payment_payouts p, cfg
   where p.bank_tx_id is null and coalesce(p.status, 'paid') not in ('failed', 'canceled', 'cancelled') and p.net_eur <> 0
     and cfg.bank_to is not null and p.payout_date + cfg.payout_days <= cfg.bank_to
  union all
  select 'payout_failed:' || p.id, 'alert', 'payout_failed', p.payout_date, p.net_eur,
         'Versamento Shopify del ' || to_char(p.payout_date, 'DD/MM/YYYY') || ' non riuscito (' || p.status || ')', p.id, null
    from fabula.payment_payouts p where p.status in ('failed', 'canceled', 'cancelled')
  union all
  -- money in that nothing explains
  select 'bank_credit:' || bt.id, 'warn', 'bank_credit', bt.value_date, bt.amount_eur,
         'Entrata non riconosciuta: ' || coalesce(nullif(bt.description, ''), '(senza descrizione)'), bt.id::text, bt.id
    from fabula.bank_transactions bt where bt.match_kind is null and bt.amount_eur > 0
  union all
  -- money out not yet classified (listed, not counted)
  select 'bank_debit:' || bt.id, 'info', 'bank_debit', bt.value_date, bt.amount_eur,
         'Uscita da classificare: ' || coalesce(nullif(bt.description, ''), '(senza descrizione)'), bt.id::text, bt.id
    from fabula.bank_transactions bt where bt.match_kind is null and bt.amount_eur < 0
)
select x.* from x where not exists (select 1 from fabula.recon_acks a where a.key = x.key and a.active);
grant select on fabula.v_recon_exceptions to authenticated, service_role;

-- 6 · by hand ------------------------------------------------------------------------------------------------
-- p_kind: payout (p_ref = payout id) · invoice (invoice uuid) · order (sales order uuid) · bank_fee · cash_deposit · transfer ·
--         expense · supplier · salary · tax · other · ignore (note required) · clear (undo any match)
create or replace function fabula.recon_set_bank(p_bank_tx uuid, p_kind text, p_ref text default null, p_note text default null)
returns jsonb language plpgsql set search_path = fabula, public as $$
declare b fabula.bank_transactions; v_who uuid := fabula.my_staff_id(); v_kind text := lower(btrim(coalesce(p_kind, ''))); v_note text := nullif(btrim(coalesce(p_note, '')), '');
        p fabula.payment_payouts; v_inv fabula.invoices; v_so fabula.sales_orders;
begin
  if not fabula.can('finanza', 2) then raise exception 'Il tuo profilo non può abbinare gli incassi' using errcode = '42501'; end if;
  select * into b from fabula.bank_transactions where id = p_bank_tx for update;
  if b.id is null then raise exception 'Movimento non trovato'; end if;
  -- undo whatever was there
  update fabula.payment_payouts set bank_tx_id = null, matched_at = null, matched_by = null, match_note = null, updated_at = now() where bank_tx_id = b.id;
  if b.matched_invoice_id is not null then
    update fabula.invoices set status = 'approved', paid_at = null, payment_ref = null, updated_at = now() where id = b.matched_invoice_id and payment_ref = b.external_id and status = 'paid';
  end if;
  update fabula.bank_transactions set match_kind = null, matched_payout_id = null, matched_invoice_id = null, matched_order_id = null, reconciled = false,
         match_note = null, matched_at = null, matched_by = null where id = b.id;
  if v_kind = 'clear' then return jsonb_build_object('id', b.id, 'kind', null); end if;

  if v_kind = 'payout' then
    select * into p from fabula.payment_payouts where id = p_ref;
    if p.id is null then raise exception 'Versamento non trovato'; end if;
    if p.bank_tx_id is not null then raise exception 'Questo versamento è già abbinato a un altro movimento'; end if;
    update fabula.bank_transactions set match_kind = 'payout', matched_payout_id = p.id, reconciled = true, matched_at = now(), matched_by = v_who,
           match_note = coalesce(v_note, case when p.net_eur <> b.amount_eur then 'Abbinato a mano: importi diversi (' || p.net_eur || ' / ' || b.amount_eur || ')' end) where id = b.id;
    update fabula.payment_payouts set bank_tx_id = b.id, matched_at = now(), matched_by = v_who, match_note = v_note, updated_at = now() where id = p.id;
  elsif v_kind = 'invoice' then
    select * into v_inv from fabula.invoices where id = p_ref::uuid;
    if v_inv.id is null then raise exception 'Fattura non trovata'; end if;
    update fabula.bank_transactions set match_kind = 'invoice', matched_invoice_id = v_inv.id, reconciled = true, matched_at = now(), matched_by = v_who, match_note = v_note where id = b.id;
    if v_inv.direction = 'out' or b.amount_eur < 0 then
      update fabula.invoices set status = 'paid', paid_at = b.value_date, payment_ref = b.external_id, updated_at = now() where id = v_inv.id;
    end if;
  elsif v_kind = 'order' then
    select * into v_so from fabula.sales_orders where id = p_ref::uuid;
    if v_so.id is null then raise exception 'Ordine non trovato'; end if;
    update fabula.bank_transactions set match_kind = 'order', matched_order_id = v_so.id, reconciled = true, matched_at = now(), matched_by = v_who, match_note = v_note where id = b.id;
  elsif v_kind in ('bank_fee', 'cash_deposit', 'transfer', 'expense', 'supplier', 'salary', 'tax', 'other', 'ignore') then
    if v_kind in ('other', 'ignore') and v_note is null then raise exception 'Scrivi una nota: cosa è questo movimento?'; end if;
    update fabula.bank_transactions set match_kind = v_kind, reconciled = true, matched_at = now(), matched_by = v_who, match_note = v_note where id = b.id;
  else
    raise exception 'Tipo di abbinamento sconosciuto: %', p_kind;
  end if;
  return jsonb_build_object('id', b.id, 'kind', v_kind);
end $$;

create or replace function fabula.recon_ack(p_key text, p_note text default null, p_active boolean default true)
returns jsonb language plpgsql set search_path = fabula, public as $$
begin
  if not fabula.can('finanza', 2) then raise exception 'Il tuo profilo non può segnare gli incassi come controllati' using errcode = '42501'; end if;
  if p_active and nullif(btrim(coalesce(p_note, '')), '') is null then raise exception 'Scrivi una nota: perché va bene così?'; end if;
  insert into fabula.recon_acks (key, active, note, acked_by, acked_at) values (p_key, p_active, nullif(btrim(coalesce(p_note, '')), ''), fabula.my_staff_id(), now())
  on conflict (key) do update set active = excluded.active, note = coalesce(excluded.note, recon_acks.note), acked_by = excluded.acked_by, acked_at = now();
  return jsonb_build_object('key', p_key, 'active', p_active);
end $$;

-- candidates for a bank row (same amount ± 1 €, nearby dates), for the console picker
create or replace function fabula.recon_candidates(p_bank_tx uuid)
returns jsonb language sql stable set search_path = fabula, public as $$
  with b as (select * from fabula.bank_transactions where id = p_bank_tx)
  select jsonb_build_object(
    'payouts', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'date', p.payout_date, 'net', p.net_eur, 'status', p.status) order by abs(p.net_eur - b.amount_eur), abs(p.payout_date - b.value_date)), '[]')
                  from fabula.payment_payouts p, b where p.bank_tx_id is null and abs(p.net_eur - b.amount_eur) <= 1 and p.payout_date between b.value_date - 20 and b.value_date + 3),
    'invoices', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'number', i.invoice_number, 'date', i.invoice_date, 'total', i.total_eur,
                                                              'party', coalesce(pa.trade_name, pa.legal_name)) order by i.invoice_date), '[]')
                   from fabula.invoices i left join fabula.parties pa on pa.id = i.party_id, b
                  where i.status not in ('paid', 'void') and abs(i.total_eur - abs(b.amount_eur)) <= 1 and i.direction = case when b.amount_eur > 0 then 'out'::fabula.invoice_direction else 'in'::fabula.invoice_direction end),
    'orders', (select coalesce(jsonb_agg(jsonb_build_object('id', so.id, 'number', so.order_number, 'date', so.order_date, 'total', so.total_eur,
                                                            'party', coalesce(pa.trade_name, pa.legal_name)) order by so.order_date desc), '[]')
                 from fabula.sales_orders so left join fabula.parties pa on pa.id = so.customer_id, b
                where b.amount_eur > 0 and so.channel = 'wholesale' and so.status not in ('cancelled', 'draft') and so.invoice_id is null
                  and abs(so.total_eur - b.amount_eur) <= 1 and so.order_date between b.value_date - 90 and b.value_date
                  and not exists (select 1 from fabula.bank_transactions x where x.matched_order_id = so.id))
  ) from b $$;

-- 7 · the numbers for the console --------------------------------------------------------------------------------
create or replace function fabula.recon_status(p_from date default null, p_to date default null)
returns jsonb language sql stable set search_path = fabula, public as $$
  with d as (select coalesce(p_from, (now() at time zone 'Europe/Rome')::date - 60) as d0, coalesce(p_to, (now() at time zone 'Europe/Rome')::date) as d1),
  tx as (select t.* from fabula.payment_transactions t, d where not t.test and (t.tx_at at time zone 'Europe/Rome')::date between d.d0 and d.d1),
  po as (select p.* from fabula.payment_payouts p, d where p.payout_date between d.d0 and d.d1),
  bk as (select b.* from fabula.bank_transactions b, d where b.value_date between d.d0 and d.d1),
  pos_cash as (select coalesce(sum(so.total_eur), 0) as eur, count(*) as n from fabula.sales_orders so, d
                where so.channel = 'store_pos' and so.status in ('confirmed', 'fulfilled') and so.order_date between d.d0 and d.d1
                  and coalesce(so.shopify_payload->>'payment_gateways', '') ~* '(cash|contant)')
  select jsonb_build_object(
    'from', (select d0 from d), 'to', (select d1 from d),
    'payments', jsonb_build_object(
      'charges_eur', (select coalesce(sum(amount_eur), 0) from tx where tx_type = 'charge'),
      'charges_n', (select count(*) from tx where tx_type = 'charge'),
      'refunds_eur', (select coalesce(sum(amount_eur), 0) from tx where tx_type = 'refund'),
      'other_eur', (select coalesce(sum(amount_eur), 0) from tx where tx_type not in ('charge', 'refund')),
      'fees_eur', (select coalesce(sum(fee_eur), 0) from tx),
      'fee_pct', (select case when sum(amount_eur) filter (where tx_type = 'charge') > 0
                              then round(100 * sum(fee_eur) / sum(amount_eur) filter (where tx_type = 'charge'), 2) end from tx),
      'net_eur', (select coalesce(sum(net_eur), 0) from tx),
      'first_tx', (select min(tx_at) from fabula.payment_transactions where not test),
      'last_tx', (select max(tx_at) from fabula.payment_transactions where not test),
      'last_import', (select max(created_at) from fabula.payment_transactions)),
    'payouts', jsonb_build_object(
      'n', (select count(*) from po), 'net_eur', (select coalesce(sum(net_eur), 0) from po),
      'in_bank_n', (select count(*) from po where bank_tx_id is not null), 'in_bank_eur', (select coalesce(sum(net_eur), 0) from po where bank_tx_id is not null),
      'waiting_n', (select count(*) from fabula.payment_payouts where bank_tx_id is null and coalesce(status, 'paid') not in ('failed', 'canceled', 'cancelled')),
      'waiting_eur', (select coalesce(sum(net_eur), 0) from fabula.payment_payouts where bank_tx_id is null and coalesce(status, 'paid') not in ('failed', 'canceled', 'cancelled')),
      'list', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'date', p.payout_date, 'status', p.status, 'gross', p.gross_eur, 'fee', p.fee_eur, 'net', p.net_eur,
                                                            'bank_date', b.value_date, 'bank_text', b.description, 'note', p.match_note,
                                                            'orders', (select count(distinct t.sales_order_id) from fabula.payment_transactions t where t.payout_id = p.id))
                                         order by p.payout_date desc), '[]')
                 from po p left join fabula.bank_transactions b on b.id = p.bank_tx_id)),
    'bank', jsonb_build_object(
      'accounts', (select coalesce(jsonb_agg(jsonb_build_object('account', a.bank_account, 'last_date', a.last_date, 'balance', a.balance, 'rows', a.n) order by a.bank_account), '[]')
                     from (select bank_account, max(value_date) as last_date, count(*) as n,
                                  (select balance_eur from fabula.bank_transactions z where z.bank_account = y.bank_account and z.balance_eur is not null
                                    order by z.value_date desc, z.created_at desc limit 1) as balance
                             from fabula.bank_transactions y group by bank_account) a),
      'in_eur', (select coalesce(sum(amount_eur), 0) from bk where amount_eur > 0),
      'out_eur', (select coalesce(sum(amount_eur), 0) from bk where amount_eur < 0),
      'open_in_n', (select count(*) from fabula.bank_transactions where match_kind is null and amount_eur > 0),
      'open_out_n', (select count(*) from fabula.bank_transactions where match_kind is null and amount_eur < 0),
      'by_kind', (select coalesce(jsonb_object_agg(k, eur), '{}') from (select coalesce(match_kind, 'da_abbinare') as k, sum(amount_eur) as eur from bk group by 1) z)),
    'cash', jsonb_build_object(
      'pos_cash_eur', (select eur from pos_cash), 'pos_cash_n', (select n from pos_cash),
      'deposited_eur', (select coalesce(sum(amount_eur), 0) from bk where match_kind = 'cash_deposit'),
      'orders_without_gateway', (select count(*) from fabula.sales_orders so, d where so.channel in ('shopify', 'store_pos') and so.order_date between d.d0 and d.d1
                                    and so.status in ('confirmed', 'fulfilled', 'refunded') and coalesce(so.shopify_payload->>'payment_gateways', '') = '')),
    'exceptions', (select coalesce(jsonb_agg(to_jsonb(e) order by case e.severity when 'alert' then 0 when 'warn' then 1 else 2 end, e.on_date desc), '[]')
                     from (select * from fabula.v_recon_exceptions limit 300) e),
    'exceptions_n', (select count(*) from fabula.v_recon_exceptions where severity <> 'info')
  ) $$;

-- 8 · grants: functions run with the caller's rights; anon gets nothing ----------------------------------------------
revoke all on function fabula.bank_import(text, jsonb) from public, anon;
revoke all on function fabula.payments_import(text, jsonb, text) from public, anon;
revoke all on function fabula.payouts_import(text, jsonb, text) from public, anon;
revoke all on function fabula.recon_run() from public, anon;
revoke all on function fabula.recon_set_bank(uuid, text, text, text) from public, anon;
revoke all on function fabula.recon_ack(text, text, boolean) from public, anon;
revoke all on function fabula.recon_candidates(uuid) from public, anon;
revoke all on function fabula.recon_status(date, date) from public, anon;
grant execute on function fabula.bank_import(text, jsonb), fabula.payments_import(text, jsonb, text), fabula.payouts_import(text, jsonb, text),
  fabula.recon_run(), fabula.recon_set_bank(uuid, text, text, text), fabula.recon_ack(text, text, boolean), fabula.recon_candidates(uuid),
  fabula.recon_status(date, date) to authenticated, service_role;

-- 9 · nightly run (06:40 Rome in summer, after the Shopify orders bot) --------------------------------------------
select cron.schedule('fabula_recon', '40 4 * * *', $c$select fabula.recon_run()$c$);
