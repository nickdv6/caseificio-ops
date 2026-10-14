-- v1.02a · Audit 12/10/2026, E-18: Shopify orders, customers and stock are copied by the database's own server function
-- (`shopify-sync`), not by a Claude task that copies numbers by hand.
--   * The three Shopify «bots» become database jobs (bot_schedule.runner = 'db'): every 5 minutes pg_cron looks for a slot that
--     has come (06:05 customers, 06:11 orders, 07:32 and 13:32 stock, Rome time, Monday to Saturday) and calls the function with a
--     key only the database and the function know (fabula.job_secrets). A call that never started is repeated once after 20
--     minutes, a run that failed once after 20 minutes; after that the hourly check opens its incident as for any bot.
--   * The function logs its run (agent_runs) and the database writes the message (no LLM): what changed, what to do, and
--     «(invariato)» when nothing changed since the last run.
--   * Guards (E-18): the customer list must have as many customers as Shopify says it has, or nothing changes; one run never
--     deactivates more than shopify.max_deactivate_pct % of the Shopify customers (it lists them instead); the orders must match
--     Shopify's own count for the same period, without repeats, or nothing is written.
--   * Configurazione → Bot → «Esegui ora» starts a sync now (sistema 2, as for the other bots); the incident text says so.
-- Rollback: setting shopify.sync_enabled = 0 stops the database runs (the Claude tasks can be switched back on).

-- ============================================================================================================================
-- 1. Keys the database uses to call its own server functions (service role only; never in settings, which staff can read)
-- ============================================================================================================================
create table if not exists fabula.job_secrets (
  name       text primary key,
  value      text not null,
  created_at timestamptz not null default now()
);
alter table fabula.job_secrets enable row level security;
revoke all on fabula.job_secrets from public, anon, authenticated;
grant all on fabula.job_secrets to service_role;
insert into fabula.job_secrets (name, value) values ('shopify_sync', encode(extensions.gen_random_bytes(24), 'hex')) on conflict (name) do nothing;

-- one row per call the database made to a server function (the slot it was for, the attempt, who pressed «Esegui ora»)
create table if not exists fabula.db_job_calls (
  id           bigserial primary key,
  agent        text not null,
  slot         timestamptz,
  attempt      int not null default 1,
  requested_at timestamptz not null default now(),
  request_id   bigint,
  by_name      text,
  checked_at   timestamptz,          -- when the tick looked at the answer (net._http_response)
  http_status  int
);
create unique index if not exists db_job_calls_slot on fabula.db_job_calls (agent, slot, attempt) where slot is not null;
create index if not exists db_job_calls_recent on fabula.db_job_calls (agent, requested_at desc);
alter table fabula.db_job_calls enable row level security;
revoke all on fabula.db_job_calls from public, anon, authenticated;
grant all on fabula.db_job_calls to service_role;
grant usage, select on sequence fabula.db_job_calls_id_seq to service_role;

insert into fabula.security_accepted (key, reason) values
  ('rls_enabled_no_policy:fabula.job_secrets', 'by design (v1.02a, audit E-18): keys the database uses to call its own server functions; service role and definer functions only'),
  ('rls_enabled_no_policy:fabula.db_job_calls', 'by design (v1.02a, audit E-18): log of the database''s calls to server functions; read through definer functions only')
on conflict (key) do nothing;

insert into fabula.settings (key, value, description, data_type, sort, min_value, max_value, unit) values
  ('shopify.sync_enabled', '1', 'Sincronizzazione Shopify fatta dal database (ordini, clienti, giacenze): 1 = sì, 0 = spenta (si riaccendono i bot di Claude)', 'number', 50, 0, 1, null),
  ('shopify.sync_url', 'https://ojkquhzaeypsphncjqwy.supabase.co/functions/v1/shopify-sync', 'Indirizzo della funzione che sincronizza ordini, clienti e giacenze con Shopify', 'text', 51, null, null, null),
  ('shopify.orders_days', '3', 'Ordini Shopify: quanti giorni indietro la sincronizzazione rilegge gli ordini modificati', 'number', 54, 1, 30, 'giorni'),
  ('shopify.max_deactivate_pct', '5', 'Clienti Shopify: se in una volta spariscono più clienti di questa percentuale, la sincronizzazione non ne disattiva nessuno e li elenca', 'number', 55, 1, 100, '%')
on conflict (key) do nothing;

-- the backups (2-hourly, nightly, off-site) never carry the key nor the call log
create or replace function fabula.backup_table_list() returns text[]
language sql stable set search_path = fabula, public, extensions as $$
  select array_agg(table_name::text order by table_name)
    from information_schema.tables
   where table_schema = 'fabula' and table_type = 'BASE TABLE' and table_name not in ('job_secrets', 'db_job_calls')
$$;

-- ============================================================================================================================
-- 2. Who runs a scheduled job: a Claude task or the database
-- ============================================================================================================================
alter table fabula.bot_schedule add column if not exists runner text not null default 'claude';
do $mig$ begin
  if not exists (select 1 from pg_constraint where conname = 'bot_schedule_runner_chk') then
    alter table fabula.bot_schedule add constraint bot_schedule_runner_chk check (runner in ('claude', 'db'));
  end if;
end $mig$;
update fabula.bot_schedule set runner = 'db' where agent in ('shopify_orders', 'shopify_customers', 'shopify_inventory', 'backup_export');
comment on column fabula.bot_schedule.runner is 'claude = a Claude scheduled task does the job; db = the database runs it itself (pg_cron + a server function)';

create or replace function fabula.shopify_sync_agents() returns text[]
language sql immutable set search_path = fabula, public as $$
  select array['shopify_orders', 'shopify_customers', 'shopify_inventory']
$$;

-- Italian numbers for the messages the database writes: 1.234,50 (rule 4 of the message rules)
create or replace function fabula.it_num(p numeric, p_dec int default 0) returns text
language sql immutable set search_path = fabula, public as $$
  select case when p is null then 'n/d'
              else translate(to_char(round(p, greatest(p_dec, 0)), 'FM999,999,999,990' || case when p_dec > 0 then '.' || repeat('0', p_dec) else '' end), ',.', '.,') end
$$;
-- a quantity without useless decimals: 12 → «12», 12,5 → «12,5», 1200 → «1.200»
create or replace function fabula.it_qty(p numeric) returns text
language sql immutable set search_path = fabula, public as $$
  select case when p is null then 'n/d' else rtrim(rtrim(fabula.it_num(p, 2), '0'), ',') end
$$;

-- «1 prodotto», «3 prodotti»
create or replace function fabula.it_n(p_n numeric, p_one text, p_many text) returns text
language sql immutable set search_path = fabula, public as $$
  select fabula.it_qty(p_n) || ' ' || case when p_n = 1 then p_one else p_many end
$$;

-- ============================================================================================================================
-- 3. Customers: the whole Shopify list or nothing; never a mass deactivation (E-18)
-- ============================================================================================================================
drop function if exists fabula.upsert_shopify_customers(jsonb);
create function fabula.upsert_shopify_customers(p_rows jsonb, p_expected int default null) returns jsonb
language plpgsql set search_path = fabula, public, extensions as $$
declare r jsonb; v_id uuid; n_new int := 0; n_upd int := 0; n_off int := 0; v_tags text[]; v_name text; v_ws boolean; ids text[] := '{}';
        n_in int; n_active int; n_gone int := 0; v_cap int; v_pct numeric := greatest(coalesce(fabula.setting_num('shopify.max_deactivate_pct', 5), 5), 0);
        v_gone jsonb := '[]'::jsonb;
begin
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    raise exception using errcode = '22023', message = 'Lista clienti non valida: nessuna modifica';
  end if;
  n_in := jsonb_array_length(p_rows);
  -- v1.02a: a list that is not the whole of Shopify (a page lost, a read cut short) changes nothing
  if p_expected is not null and n_in <> p_expected then
    raise exception using errcode = 'P0001', message = format('Shopify ha %s clienti ma ne sono arrivati %s: nessuna modifica', p_expected, n_in);
  end if;
  if (select count(*) - count(distinct x->>'id') from jsonb_array_elements(p_rows) x) > 0 then
    raise exception using errcode = 'P0001', message = 'Lo stesso cliente compare due volte nella lista: nessuna modifica';
  end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    v_tags := coalesce((select array_agg(lower(t)) from jsonb_array_elements_text(coalesce(r->'tags', '[]'::jsonb)) t), '{}');
    v_ws := v_tags && array['ingrosso','b2b','wholesale','horeca'];
    v_name := coalesce(nullif(trim(r->>'company'), ''), nullif(trim(r->>'name'), ''), nullif(trim(concat_ws(' ', r->>'first_name', r->>'last_name')), ''), r->>'email', 'Cliente Shopify ' || (r->>'id'));
    ids := ids || (r->>'id');
    select id into v_id from fabula.parties where shopify_customer_id = r->>'id';
    if v_id is null and nullif(r->>'email', '') is not null then
      select id into v_id from fabula.parties where type = 'customer' and shopify_customer_id is null and lower(email) = lower(r->>'email') limit 1;
    end if;
    if v_id is null then
      insert into fabula.parties (type, legal_name, email, phone, city, payment_terms_days, source, shopify_customer_id, tags, is_wholesale, last_synced_at, orders_count, total_spent_eur, active)
      values ('customer', v_name, nullif(r->>'email', ''), nullif(r->>'phone', ''), nullif(r->>'city', ''), case when v_ws then 30 else 0 end, 'shopify', r->>'id', v_tags, v_ws, now(), (r->>'orders_count')::int, (r->>'total_spent')::numeric, true);
      n_new := n_new + 1;
    else
      update fabula.parties set legal_name = v_name, email = coalesce(nullif(r->>'email', ''), email), phone = coalesce(nullif(r->>'phone', ''), phone), city = coalesce(nullif(r->>'city', ''), city),
             source = 'shopify', shopify_customer_id = r->>'id', tags = v_tags, is_wholesale = v_ws or exists (select 1 from fabula.standing_orders s where s.customer_id = v_id and s.active),
             last_synced_at = now(), orders_count = (r->>'orders_count')::int, total_spent_eur = (r->>'total_spent')::numeric, notes = case when notes = 'placeholder' then null else notes end, active = true
       where id = v_id;
      n_upd := n_upd + 1;
    end if;
  end loop;
  -- customers that vanished from Shopify: deactivated (orders keep referencing them), but never more than the setting's share at once
  if n_in > 0 then
    select count(*) into n_active from fabula.parties where type = 'customer' and source = 'shopify' and active;
    select count(*) into n_gone from fabula.parties where type = 'customer' and source = 'shopify' and active and not (shopify_customer_id = any (ids));
    v_cap := greatest(1, floor(n_active * v_pct / 100))::int;
    if n_gone > v_cap then
      select coalesce(jsonb_agg(legal_name order by legal_name), '[]') into v_gone from (
        select legal_name from fabula.parties where type = 'customer' and source = 'shopify' and active and not (shopify_customer_id = any (ids))
         order by legal_name limit 10) g;
    elsif n_gone > 0 then
      update fabula.parties set active = false, last_synced_at = now() where type = 'customer' and source = 'shopify' and active and not (shopify_customer_id = any (ids));
      get diagnostics n_off = row_count;
    end if;
  end if;
  return jsonb_build_object('received', n_in, 'expected', p_expected, 'created', n_new, 'updated', n_upd, 'deactivated', n_off,
    'deactivation_blocked', case when n_gone > v_cap then n_gone else 0 end, 'deactivation_cap', v_cap, 'gone_names', v_gone,
    'placeholders_left', (select count(*) from fabula.parties where type = 'customer' and source = 'placeholder' and active),
    'wholesale', (select count(*) from fabula.parties where type = 'customer' and active and is_wholesale));
end $$;
revoke all on function fabula.upsert_shopify_customers(jsonb, int) from public, anon, authenticated;
grant execute on function fabula.upsert_shopify_customers(jsonb, int) to service_role;

-- ============================================================================================================================
-- 4. Orders: checked against Shopify's own count for the period before anything is written (E-18)
-- ============================================================================================================================
create or replace function fabula.upsert_shopify_orders(p_rows jsonb, p_expected jsonb) returns jsonb
language plpgsql set search_path = fabula, public, extensions as $$
declare n int; v_sum numeric; v_dup int;
begin
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    raise exception using errcode = '22023', message = 'Lista ordini non valida: nessuna modifica';
  end if;
  n := jsonb_array_length(p_rows);
  select coalesce(sum(nullif(x->>'total', '')::numeric), 0), count(*) - count(distinct x->>'id') into v_sum, v_dup from jsonb_array_elements(p_rows) x;
  if v_dup > 0 then
    raise exception using errcode = 'P0001', message = format('%s ordini compaiono due volte nella lista: nessuna modifica', v_dup);
  end if;
  if p_expected ? 'count' and n <> (p_expected->>'count')::int then
    raise exception using errcode = 'P0001', message = format('Shopify ha %s ordini nel periodo ma ne sono arrivati %s: nessuna modifica', p_expected->>'count', n);
  end if;
  if p_expected ? 'total' and round(v_sum, 2) <> round((p_expected->>'total')::numeric, 2) then
    raise exception using errcode = 'P0001', message = format('Il totale degli ordini letti (€ %s) non è quello di Shopify (€ %s): nessuna modifica',
                                                              fabula.it_num(v_sum, 2), fabula.it_num((p_expected->>'total')::numeric, 2));
  end if;
  return fabula.upsert_shopify_orders(p_rows) || jsonb_build_object('checked', jsonb_build_object('count', n, 'total', round(v_sum, 2)));
end $$;
revoke all on function fabula.upsert_shopify_orders(jsonb, jsonb) from public, anon, authenticated;
grant execute on function fabula.upsert_shopify_orders(jsonb, jsonb) to service_role;
revoke all on function fabula.upsert_shopify_orders(jsonb) from public, anon, authenticated;
grant execute on function fabula.upsert_shopify_orders(jsonb) to service_role;
revoke all on function fabula.mark_shopify_fulfilled(uuid, text) from public, anon, authenticated;
grant execute on function fabula.mark_shopify_fulfilled(uuid, text) to service_role;

-- what the stock run needs from the database, in one call
create or replace function fabula.shopify_inventory_plan() returns jsonb
language sql stable set search_path = fabula, public as $$
  select jsonb_build_object(
    'push', fabula.shopify_push_enabled(),
    'setting', fabula.setting_num('shopify.push_inventory', 0),
    'counted', exists (select 1 from fabula.stock_counts where status = 'posted'),
    'rows', coalesce((select jsonb_agg(to_jsonb(v) order by v.label) from fabula.v_shopify_inventory_push v), '[]'::jsonb))
$$;
revoke all on function fabula.shopify_inventory_plan() from public, anon, authenticated;
grant execute on function fabula.shopify_inventory_plan() to service_role;

-- ============================================================================================================================
-- 5. Calling the function: by the clock, or by «Esegui ora»
-- ============================================================================================================================
create or replace function fabula.shopify_sync_call(p_agent text, p_by text default null, p_slot timestamptz default null, p_attempt int default 1,
                                                    p_at timestamptz default now())
returns bigint language plpgsql security definer set search_path = fabula, public, extensions as $$
declare v_url text := fabula.setting_text('shopify.sync_url'); v_key text; v_req bigint;
begin
  if not (p_agent = any (fabula.shopify_sync_agents())) then
    raise exception using errcode = '22023', message = 'Sincronizzazione Shopify sconosciuta: ' || coalesce(p_agent, '');
  end if;
  select value into v_key from fabula.job_secrets where name = 'shopify_sync';
  if coalesce(v_url, '') = '' or v_key is null then
    raise exception using errcode = 'P0001', message = 'Sincronizzazione Shopify non configurata: manca l''indirizzo della funzione o la sua chiave';
  end if;
  select net.http_post(url := v_url, body := jsonb_build_object('agent', p_agent, 'by', p_by, 'slot', p_slot),
                       headers := jsonb_build_object('Content-Type', 'application/json', 'x-sync-secret', v_key), timeout_milliseconds := 150000)
    into v_req;
  insert into fabula.db_job_calls (agent, slot, attempt, request_id, by_name, requested_at) values (p_agent, p_slot, p_attempt, v_req, p_by, p_at);
  return v_req;
end $$;
revoke all on function fabula.shopify_sync_call(text, text, timestamptz, int, timestamptz) from public, anon, authenticated;

-- a call that never reached the function (not published, a login asked, no answer): why, in plain words
create or replace function fabula.shopify_call_error_it(p_status int, p_timed_out boolean, p_msg text) returns text
language sql immutable set search_path = fabula, public as $$
  select case
    when p_status = 404 then 'la funzione shopify-sync non è pubblicata su Supabase (Edge Functions)'
    when p_status = 401 then 'la funzione chiede un login: va pubblicata senza verifica del login (verify_jwt = false)'
    when p_status = 403 then 'la chiave con cui il database chiama la funzione non è quella giusta'
    when p_status >= 500 then format('la funzione ha dato errore (HTTP %s): Supabase → Edge Functions → shopify-sync → Logs', p_status)
    when coalesce(p_timed_out, false) then 'la funzione non ha risposto entro 150 secondi'
    when p_status is not null then format('la funzione ha risposto HTTP %s', p_status)
    else 'chiamata non riuscita: ' || coalesce(left(p_msg, 160), 'nessun dettaglio') end
$$;

-- every 5 minutes: (1) runs left half-way, (2) calls that never reached the function, (3) the slots of today (Rome) with no run yet
create or replace function fabula.shopify_sync_tick(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = fabula, public as $$
declare v_day date := (p_now at time zone 'Europe/Rome')::date; r record; c record; h record; v_due timestamptz; v_n int; v_t timestamptz;
        done jsonb := '[]'::jsonb; v_run uuid; v_err text; n_stale int; n_failed int := 0;
begin
  if coalesce(fabula.setting_num('shopify.sync_enabled', 1), 1) <> 1 then return jsonb_build_object('enabled', false); end if;
  -- (1) a run that started and never finished (the function was stopped half-way): failed, so the retry below can run
  update fabula.agent_runs set status = 'error', finished_at = p_now,
         error = 'Interrotta: la funzione si è fermata a metà (tempo scaduto o riavvio)', summary = 'interrotta'
   where agent = any (fabula.shopify_sync_agents()) and status = 'running' and finished_at is null
     and started_at < p_now - interval '15 minutes' and started_at > p_now - interval '2 days';
  get diagnostics n_stale = row_count;
  -- (2) the answer to each call: when the function never ran, the run is recorded as failed with the reason
  for c in select j.* from fabula.db_job_calls j
            where j.checked_at is null and j.request_id is not null and j.requested_at > p_now - interval '1 day' and j.requested_at <= p_now - interval '2 minutes'
            order by j.id loop
    select r2.status_code, r2.timed_out, r2.error_msg into h from net._http_response r2 where r2.id = c.request_id;
    if not found then
      -- no answer stored yet; after 30 minutes there will be none (pg_net keeps answers for a few hours)
      if c.requested_at < p_now - interval '30 minutes' then update fabula.db_job_calls set checked_at = p_now where id = c.id; end if;
      continue;
    end if;
    update fabula.db_job_calls set checked_at = p_now, http_status = h.status_code where id = c.id;
    continue when h.status_code between 200 and 299 or h.status_code = 409;
    -- the function did run (e.g. pg_net stopped waiting but the run went on): its own record says how it went
    continue when exists (select 1 from fabula.agent_runs ar where ar.agent = c.agent and ar.started_at >= c.requested_at - interval '1 minute');
    v_err := fabula.shopify_call_error_it(h.status_code, h.timed_out, h.error_msg);
    insert into fabula.agent_runs (agent, started_at, finished_at, status, summary, error, details)
    values (c.agent, c.requested_at, p_now, 'error', 'non partita', left(v_err, 500),
            jsonb_strip_nulls(jsonb_build_object('via', 'db', 'http_status', h.status_code, 'by', c.by_name, 'slot', c.slot, 'fp', md5('error:' || v_err))))
    returning id into v_run;
    perform fabula.post_bot_message(c.agent, 'alert', fabula.bot_title(c.agent) || ' non partita',
      format(E'**Da fare**\n1. Avvisa Nick: %s.\n\n**In breve**\n- La sincronizzazione con Shopify non è partita: nessun dato è stato cambiato.\n- Quando è sistemato: Configurazione → Bot → %s → «Esegui ora».',
             v_err, fabula.bot_title(c.agent)), v_run, 'admin.html#bots');
    n_failed := n_failed + 1;
  end loop;
  -- (3) the slots
  for r in select bs.agent, t.due from fabula.bot_schedule bs cross join unnest(bs.due_times) t(due)
            where bs.active and bs.runner = 'db' and bs.agent = any (fabula.shopify_sync_agents())
              and extract(isodow from v_day) = any (bs.weekdays) and (bs.month_day is null or extract(day from v_day) = bs.month_day)
            order by t.due loop
    v_due := (v_day + r.due) at time zone 'Europe/Rome';
    continue when p_now < v_due or p_now >= v_due + interval '3 hours';
    -- a run since the slot that did not fail, or is still running: done
    continue when exists (select 1 from fabula.agent_runs ar where ar.agent = r.agent and ar.started_at >= v_due - interval '5 minutes' and ar.status in ('ok', 'running'));
    select count(*), max(requested_at) into v_n, v_t from fabula.db_job_calls where agent = r.agent and slot = v_due;
    -- the call at the slot, and one more 20 minutes later if the function never started or failed; then the hourly check's incident
    continue when v_n >= 2 or (v_n = 1 and v_t > p_now - interval '20 minutes');
    begin
      perform fabula.shopify_sync_call(r.agent, null, v_due, v_n + 1, p_now);
      done := done || jsonb_build_object('agent', r.agent, 'slot', to_char(r.due, 'HH24:MI'), 'attempt', v_n + 1);
    exception when others then
      done := done || jsonb_build_object('agent', r.agent, 'slot', to_char(r.due, 'HH24:MI'), 'error', left(sqlerrm, 200));
    end;
  end loop;
  return jsonb_build_object('enabled', true, 'calls', done, 'stale', n_stale, 'not_started', n_failed);
end $$;
revoke all on function fabula.shopify_sync_tick(timestamptz) from public, anon, authenticated;

-- «Esegui ora» (from run_bot_fallback, which checks the permission): asks again if it already ran today or was just started
create or replace function fabula.shopify_sync_now(p_agent text, p_confirm boolean default false) returns jsonb
language plpgsql security definer set search_path = fabula, public as $$
declare v_who text := coalesce((select full_name from fabula.staff where id = fabula.my_staff_id()), 'sistema');
        v_day date := (now() at time zone 'Europe/Rome')::date; v_last record; v_recent timestamptz;
begin
  if coalesce(fabula.setting_num('shopify.sync_enabled', 1), 1) <> 1 then
    raise exception using errcode = '22023', message = 'La sincronizzazione Shopify del database è spenta (Configurazione → Parametri → Shopify): la fanno i bot di Claude';
  end if;
  select ar.started_at, ar.status into v_last from fabula.agent_runs ar
   where ar.agent = p_agent and ar.started_at >= (v_day::timestamp) at time zone 'Europe/Rome' order by ar.started_at desc limit 1;
  select max(requested_at) into v_recent from fabula.db_job_calls where agent = p_agent and requested_at > now() - interval '10 minutes';
  if v_last.status = 'running' and v_last.started_at > now() - interval '10 minutes' then
    raise exception using errcode = '22023', message = format('%s è in corso dalle %s: il risultato arriva qui tra poco', fabula.bot_title(p_agent), to_char(v_last.started_at at time zone 'Europe/Rome', 'HH24:MI'));
  end if;
  if (v_last.started_at is not null or v_recent is not null) and not coalesce(p_confirm, false) then
    raise exception using errcode = '22023', hint = 'confirm',
      message = case when v_recent is not null and (v_last.started_at is null or v_recent > v_last.started_at)
                     then format('%s è stato avviato alle %s: rifarlo adesso?', fabula.bot_title(p_agent), to_char(v_recent at time zone 'Europe/Rome', 'HH24:MI'))
                     else format('%s ha già girato oggi alle %s: rifarlo adesso?', fabula.bot_title(p_agent), to_char(v_last.started_at at time zone 'Europe/Rome', 'HH24:MI')) end;
  end if;
  perform fabula.shopify_sync_call(p_agent, v_who, null, 1);
  return jsonb_build_object('agent', p_agent, 'started', true, 'title', fabula.bot_title(p_agent) || ' avviata',
                            'summary', 'Il risultato arriva in Configurazione → Bot entro un paio di minuti');
end $$;
revoke all on function fabula.shopify_sync_now(text, boolean) from public, anon, authenticated;

-- ============================================================================================================================
-- 6. Called by the function: start of a run, end of a run (the message is written here, from the numbers only)
-- ============================================================================================================================
create or replace function fabula.shopify_sync_start(p_agent text, p_by text default null, p_slot timestamptz default null) returns uuid
language plpgsql security definer set search_path = fabula, public as $$
declare v_id uuid;
begin
  if not (p_agent = any (fabula.shopify_sync_agents())) then
    raise exception using errcode = '22023', message = 'Sincronizzazione Shopify sconosciuta: ' || coalesce(p_agent, '');
  end if;
  perform pg_advisory_xact_lock(hashtext('shopify_sync:' || p_agent));
  if exists (select 1 from fabula.agent_runs where agent = p_agent and status = 'running' and finished_at is null and started_at > now() - interval '10 minutes') then
    raise exception using errcode = 'P0001', message = 'Sincronizzazione già in corso';
  end if;
  insert into fabula.agent_runs (agent, status, details)
  values (p_agent, 'running', jsonb_strip_nulls(jsonb_build_object('via', 'db', 'by', p_by, 'slot', p_slot)))
  returning id into v_id;
  return v_id;
end $$;
revoke all on function fabula.shopify_sync_start(text, text, timestamptz) from public, anon, authenticated;
grant execute on function fabula.shopify_sync_start(text, text, timestamptz) to service_role;

-- a technical error in plain words (the full text stays in the run's record)
create or replace function fabula.shopify_error_it(p_err text) returns text
language sql immutable set search_path = fabula, public as $$
  select case
    when p_err is null or p_err = '' then 'errore senza dettagli'
    when p_err ~* 'not_configured' then 'la funzione non ha le credenziali dell''app Shopify «Caseificio ops» (vanno messe nei secrets della funzione)'
    when p_err ~* 'nessuna modifica' then p_err
    when p_err ~* '(429|throttl|troppe richieste)' then 'Shopify ha rallentato le richieste: riprova tra qualche minuto'
    when p_err ~* '(access denied|required access|must have access|scope)' then 'all''app Shopify «Caseificio ops» manca un permesso (' || left(p_err, 140) || ')'
    when p_err ~* '(401|invalid api key|token)' then 'Shopify non accetta le credenziali dell''app «Caseificio ops»: vanno rinnovate'
    when p_err ~* '(5\d\d|timeout|timed out|network|fetch failed|connection)' then 'Shopify non ha risposto: riprova tra qualche minuto'
    else 'errore tecnico: ' || left(p_err, 160) end
$$;

create or replace function fabula.shopify_sync_finish(p_run uuid, p_result jsonb) returns jsonb
language plpgsql security definer set search_path = fabula, public as $$
declare v_run fabula.agent_runs%rowtype; a text; res jsonb := coalesce(p_result, '{}'::jsonb); ok boolean; err text;
        sev text := 'info'; ttl text; todo text[] := '{}'; facts text[] := '{}'; summ text; link text; fp text; prev_fp text; same boolean := false;
        u jsonb; n int; n_on int; n_pos int; n_ws int; v_sum numeric; x jsonb; v_names text; v_new_unmapped text; v_msg bigint; days int;
begin
  select * into v_run from fabula.agent_runs where id = p_run for update;
  if v_run.id is null then raise exception using errcode = 'P0002', message = 'Esecuzione non trovata'; end if;
  a := v_run.agent; ok := coalesce((res->>'ok')::boolean, false); err := res->>'error';
  -- the previous finished run of the same job: to say «(invariato)» instead of repeating the same problem
  select ar.details->>'fp' into prev_fp from fabula.agent_runs ar
   where ar.agent = a and ar.id <> p_run and ar.finished_at is not null and ar.details ? 'fp' order by ar.started_at desc limit 1;

  if not ok then
    ttl := case a when 'shopify_orders' then 'Ordini Shopify non copiati' when 'shopify_customers' then 'Clienti Shopify non copiati' else 'Giacenze Shopify non controllate' end;
    sev := case when a = 'shopify_inventory' and coalesce((res->>'push')::int, fabula.shopify_push_enabled()) = 0 then 'warn' else 'alert' end;
    todo := array[format('Riprova: Configurazione → Bot → %s → «Esegui ora». Se l''errore si ripete, avvisa Nick.', fabula.bot_title(a))];
    facts := array['Causa: ' || fabula.shopify_error_it(err),
                   case a when 'shopify_orders' then 'Nessun ordine è stato scritto: il controllo blocca tutto se i numeri non tornano con Shopify.'
                          when 'shopify_customers' then 'Nessun cliente è stato modificato o disattivato.'
                          else 'Le quantità su Shopify non sono state toccate.' end];
    summ := 'errore: ' || left(coalesce(err, ''), 200);
    fp := md5('error:' || coalesce(err, ''));

  elsif a = 'shopify_orders' then
    u := coalesce(res->'upsert', '{}'::jsonb); days := coalesce((res#>>'{window,days}')::int, 3);
    select count(*), count(*) filter (where channel = 'shopify'), count(*) filter (where channel = 'store_pos'), count(*) filter (where channel = 'wholesale'), coalesce(sum(total_eur), 0)
      into n, n_on, n_pos, n_ws, v_sum
      from fabula.sales_orders where source = 'shopify' and created_at >= v_run.started_at and status <> 'cancelled';
    -- shipments: failed, blocked by a missing permission, done
    if jsonb_array_length(coalesce(res#>'{fulfil,failed}', '[]')) > 0 then
      sev := 'alert';
      ttl := case when jsonb_array_length(res#>'{fulfil,failed}') = 1 then 'Spedizione ' || (res#>>'{fulfil,failed,0,order}') || ' non confermata su Shopify'
                  else fabula.it_n(jsonb_array_length(res#>'{fulfil,failed}'), 'spedizione', 'spedizioni') || ' non confermate su Shopify' end;
      for x in select * from jsonb_array_elements(res#>'{fulfil,failed}') loop
        todo := todo || format('Conferma a mano su Shopify la spedizione %s (Shopify risponde: %s)', x->>'order', left(coalesce(x->>'error', 'errore senza dettagli'), 160));
      end loop;
    end if;
    if res#>>'{fulfil,blocked}' = 'scope' and coalesce((res#>>'{fulfil,pending}')::int, 0) > 0 then
      sev := case when sev = 'alert' then sev else 'warn' end;
      ttl := coalesce(ttl, fabula.it_n((res#>>'{fulfil,pending}')::int, 'spedizione', 'spedizioni') || ' da confermare a mano su Shopify');
      todo := todo || format('Conferma a mano su Shopify le spedizioni %s: all''app «Caseificio ops» manca il permesso per le spedizioni', res#>>'{fulfil,orders}');
    end if;
    -- products sold that are not linked to the stock: new ones are news, the same list is «invariato»
    select string_agg(v->>'label', ', ' order by v->>'label') into v_names from jsonb_array_elements(coalesce(u->'unmapped_variants', '[]')) v;
    select string_agg(v->>'label', ', ' order by v->>'label') into v_new_unmapped from jsonb_array_elements(coalesce(u->'unmapped_variants', '[]')) v
     where not exists (select 1 from fabula.agent_runs ar, jsonb_array_elements(coalesce(ar.details#>'{upsert,unmapped_variants}', ar.details->'unmapped_variants', '[]')) pv
                        where ar.id = (select id from fabula.agent_runs where agent = a and id <> p_run and status = 'ok' and finished_at is not null order by started_at desc limit 1)
                          and pv->>'variant_id' = v->>'variant_id');
    if v_new_unmapped is not null then
      sev := case when sev = 'alert' then sev else 'warn' end;
      if n = 0 then ttl := coalesce(ttl, left('Collega al magazzino: ' || v_new_unmapped, 70)); end if;
      todo := todo || format('Collega al magazzino: %s (Configurazione → Prodotti Shopify)', v_new_unmapped);
      link := 'admin.html#prodotti';
    end if;
    ttl := coalesce(ttl, case when n > 0 then format('%s%s · € %s', fabula.it_n(n, 'ordine nuovo', 'ordini nuovi'),
                                                       case when n_pos > 0 and n_on + n_ws > 0 then format(' (%s online, %s al banco)', n_on + n_ws, n_pos) when n_pos > 0 then ' al banco' else ' online' end,
                                                       fabula.it_num(v_sum, 2))
                              else 'Nessun ordine nuovo' end);
    facts := facts || case when coalesce((res#>>'{shopify,count}')::int, 0) = 0 then format('Nessun ordine negli ultimi %s giorni', days)
                           else format('Ordini modificati negli ultimi %s giorni: %s (%s al banco) · nuovi %s · aggiornati %s',
                                       days, res#>>'{shopify,count}', coalesce(res#>>'{shopify,pos}', '0'), coalesce(u->>'created', '0'), coalesce(u->>'updated', '0')) end;
    for x in select jsonb_build_object('d', c.closing_date, 't', c.rt_total_eur, 'n', c.rt_receipts) from fabula.pos_daily_closings c
              where c.source = 'shopify_pos' and c.closing_date = any (array(select (j #>> '{}')::date from jsonb_array_elements(coalesce(res->'pos_days', '[]')) j))
              order by c.closing_date desc limit 3 loop
      facts := facts || format('Cassa di %s: € %s, %s scontrini (da Shopify POS)', fabula.it_day((x->>'d')::date), fabula.it_num((x->>'t')::numeric, 2), x->>'n');
    end loop;
    if coalesce((res#>>'{fulfil,done}')::int, 0) > 0 then facts := facts || ('Spedizioni confermate su Shopify: ' || (res#>>'{fulfil,done}')); end if;
    if v_names is not null and v_new_unmapped is null then
      facts := facts || format('%s al magazzino (invariato): le vendite non lo scaricano', fabula.it_n(jsonb_array_length(u->'unmapped_variants'), 'prodotto Shopify non collegato', 'prodotti Shopify non collegati'));
    end if;
    if jsonb_array_length(coalesce(res->'limited', '[]')) > 0 then
      facts := facts || 'Indirizzi e telefoni dei clienti non leggibili dall''app Shopify: manca il permesso sui dati protetti dei clienti'::text;
    end if;
    summ := format('%s ordini letti, %s nuovi, %s aggiornati, %s giorni di cassa, %s spedizioni confermate, %s righe non collegate',
                   coalesce(res#>>'{shopify,count}', '0'), coalesce(u->>'created', '0'), coalesce(u->>'updated', '0'), coalesce(u->>'pos_days_closed', '0'),
                   coalesce(res#>>'{fulfil,done}', '0'), coalesce(u->>'unmapped_lines', '0'));
    fp := md5(coalesce(v_names, '') || '|' || coalesce(res#>>'{fulfil,failed}', '') || '|' || coalesce(res#>>'{fulfil,orders}', ''));

  elsif a = 'shopify_customers' then
    u := coalesce(res->'upsert', '{}'::jsonb);
    if coalesce((u->>'deactivation_blocked')::int, 0) > 0 then
      select string_agg(g #>> '{}', ', ') into v_names from jsonb_array_elements(coalesce(u->'gone_names', '[]')) g;
      ttl := format('%s da Shopify: nessuno disattivato', fabula.it_n((u->>'deactivation_blocked')::int, 'cliente sparito', 'clienti spariti'));
      todo := todo || format('Controlla su Shopify se sono stati cancellati davvero: %s%s. Se sì, disattivali a mano in Console → Anagrafiche → Clienti.',
                             v_names, case when (u->>'deactivation_blocked')::int > 10 then format(' e altri %s', (u->>'deactivation_blocked')::int - 10) else '' end);
      facts := facts || format('Più di %s in una volta: per prudenza la sincronizzazione non toglie nessuno', u->>'deactivation_cap');
      link := 'console.html#anag';
    end if;
    ttl := coalesce(ttl, case when coalesce((u->>'created')::int, 0) > 0 then fabula.it_n((u->>'created')::int, 'nuovo cliente', 'nuovi clienti') || ' da Shopify'
                              when coalesce((u->>'deactivated')::int, 0) > 0 then fabula.it_n((u->>'deactivated')::int, 'cliente disattivato', 'clienti disattivati') || ' (non più su Shopify)'
                              else 'Clienti allineati con Shopify' end);
    facts := array[format('%s clienti su Shopify · %s nuovi · %s aggiornati · %s disattivati · %s all''ingrosso',
                          coalesce(u->>'received', '0'), coalesce(u->>'created', '0'), coalesce(u->>'updated', '0'), coalesce(u->>'deactivated', '0'), coalesce(u->>'wholesale', '0'))] || facts;
    if coalesce((u->>'placeholders_left')::int, 0) > 0 then
      facts := facts || format('%s ancora un nome provvisorio («Cliente 1»…): rinominali col nome vero in Console → Anagrafiche → Clienti', fabula.it_n((u->>'placeholders_left')::int, 'cliente ha', 'clienti hanno'));
    end if;
    summ := format('%s letti, %s nuovi, %s aggiornati, %s disattivati%s', coalesce(u->>'received', '0'), coalesce(u->>'created', '0'), coalesce(u->>'updated', '0'),
                   coalesce(u->>'deactivated', '0'), case when coalesce((u->>'deactivation_blocked')::int, 0) > 0 then ', ' || (u->>'deactivation_blocked') || ' spariti non disattivati' else '' end);
    fp := md5(coalesce(u->>'deactivation_blocked', '0') || '|' || coalesce(v_names, ''));
    if coalesce((u->>'deactivation_blocked')::int, 0) > 0 then sev := 'warn'; end if;   -- new customers are news, not a warning (E-05/E-07)

  else   -- shopify_inventory
    if res->>'blocked' = 'scope' then
      ttl := 'Giacenze non confrontate con Shopify: manca un permesso';
      todo := todo || ('Aggiungi all''app Shopify «Caseificio ops» i permessi per giacenze e sedi: ' || coalesce(res->>'missing', 'read_inventory, write_inventory, read_locations')
                       || ' (Shopify Dev Dashboard → app → Versioni)');
      facts := facts || 'Shopify continua con le quantità che ha: il magazzino del caseificio non le cambia finché manca il permesso.'::text;
      sev := 'warn';
      fp := md5('scope:' || coalesce(res->>'missing', ''));
    else
      n := coalesce(jsonb_array_length(res->'variants'), 0);
      ttl := case when coalesce((res->>'push')::int, 0) = 1 then format('Shopify aggiornato: %s, %s kg disponibili', fabula.it_n(coalesce((res->>'set_count')::int, 0), 'prodotto', 'prodotti'), fabula.it_qty((res->>'available_kg')::numeric))
                  when coalesce((res->>'setting')::numeric, 0) = 2 and not coalesce((res->>'counted')::boolean, false) then 'Shopify non aggiornato: in attesa della conta di apertura'
                  else 'Shopify non aggiornato: aggiornamento spento' end;
      if n = 0 then facts := facts || 'Nessun prodotto Shopify collegato al magazzino (Configurazione → Prodotti Shopify)'::text; end if;
      if jsonb_array_length(coalesce(res->'errors', '[]')) > 0 then
        sev := 'alert';
        todo := todo || ('Shopify ha rifiutato l''aggiornamento: ' || (select string_agg(e #>> '{}', '; ') from jsonb_array_elements(res->'errors') e));
      end if;
      if jsonb_array_length(coalesce(res->'untracked', '[]')) > 0 then
        todo := todo || format('Attiva «Monitora quantità» su %s in Shopify (prodotto → variante): %s', fabula.it_n(jsonb_array_length(res->'untracked'), 'prodotto', 'prodotti'),
                               (select string_agg(e #>> '{}', ', ') from jsonb_array_elements(res->'untracked') e));
      end if;
      if jsonb_array_length(coalesce(res->'selling_at_zero', '[]')) > 0 then
        todo := todo || format('%s anche a scorte zero: in Shopify togli «Continua a vendere quando esaurito» (%s)', fabula.it_n(jsonb_array_length(res->'selling_at_zero'), 'prodotto si vende', 'prodotti si vendono'),
                               (select string_agg(e #>> '{}', ', ') from jsonb_array_elements(res->'selling_at_zero') e));
      end if;
      if jsonb_array_length(coalesce(res->'not_found', '[]')) > 0 then
        todo := todo || format('Sistema i collegamenti in Configurazione → Prodotti Shopify: %s non esistono più su Shopify',
                               (select string_agg(e #>> '{}', ', ') from jsonb_array_elements(res->'not_found') e));
        link := 'admin.html#prodotti';
      end if;
      facts := facts || format('Mozzarella disponibile in magazzino: %s kg%s', fabula.it_qty(coalesce((res->>'available_kg')::numeric, 0)),
                               case when not coalesce((res->>'counted')::boolean, false) then ' (0 kg è normale prima della conta di apertura)' else '' end);
      for x in select * from jsonb_array_elements(coalesce(res->'variants', '[]')) v
                where v->>'shopify_qty' is not null and (v->>'shopify_qty')::int <> (v->>'available_units')::int and not coalesce((v->>'set')::boolean, false)
                order by v->>'label' limit 5 loop
        facts := facts || format('%s: magazzino %s · Shopify %s', x->>'label', x->>'available_units', x->>'shopify_qty');
      end loop;
      if n > 1 then
        facts := facts || case when exists (select 1 from jsonb_array_elements(res->'variants') v where v->>'split_basis' = 'parti_uguali')
                               then 'Disponibilità divisa in parti uguali tra i prodotti (nessuna vendita nelle ultime 4 settimane)'
                               else 'Disponibilità divisa tra i prodotti in base alle vendite delle ultime 4 settimane' end;
      end if;
      if coalesce((res->>'push')::int, 0) = 0 and coalesce((res->>'setting')::numeric, 0) = 2 and not coalesce((res->>'counted')::boolean, false) then
        facts := facts || 'Si aggiornerà da solo dopo la conta di apertura (tablet → Conta magazzino)'::text;
      end if;
      -- Shopify shows stock the dairy does not have, and stops at zero: it would sell what is not there
      if exists (select 1 from jsonb_array_elements(coalesce(res->'variants', '[]')) v
                  where (v->>'shopify_qty')::int > (v->>'available_units')::int and coalesce(v->>'policy', 'DENY') = 'DENY' and not coalesce((v->>'set')::boolean, false)) then
        sev := case when sev = 'alert' then sev else 'warn' end;
      end if;
      if array_length(todo, 1) > 0 then sev := case when sev = 'alert' then sev else 'warn' end; end if;
      fp := md5(coalesce(res->>'push', '') || '|' || coalesce((select string_agg(concat_ws(':', v->>'variant_id', v->>'available_units', v->>'shopify_qty', v->>'tracked', v->>'policy'), ',' order by v->>'variant_id')
                                                                  from jsonb_array_elements(coalesce(res->'variants', '[]')) v), '')
                || '|' || coalesce(res->>'errors', '') || '|' || coalesce(res->>'not_found', ''));
    end if;
    summ := case when res->>'blocked' = 'scope' then 'permessi Shopify mancanti: ' || coalesce(res->>'missing', '')
                 when coalesce((res->>'push')::int, 0) = 1 then format('%s varianti aggiornate su Shopify, %s kg disponibili, %s non tracciate', coalesce(res->>'set_count', '0'),
                                                                     fabula.it_qty(coalesce((res->>'available_kg')::numeric, 0)), jsonb_array_length(coalesce(res->'untracked', '[]')))
                 else format('solo confronto: %s varianti, %s kg disponibili — Shopify non modificato', jsonb_array_length(coalesce(res->'variants', '[]')),
                             fabula.it_qty(coalesce((res->>'available_kg')::numeric, 0))) end;
  end if;

  -- the same as last time: one short line, no warning (rule 5 of the message rules, done by the numbers). The same alarm while
  -- the earlier one is still open: no new alarm and no new Telegram (the open one stays until someone marks it «Risolto»)
  if prev_fp is not null and fp = prev_fp
     and ((ok and sev = 'warn')
          or (sev = 'alert' and exists (select 1 from fabula.bot_messages m join fabula.agent_runs ar on ar.id = m.run_id
                                         where m.agent = a and m.severity = 'alert' and m.read_at is null and ar.details->>'fp' = fp))) then
    if sev = 'alert' then facts := facts || 'Lo stesso allarme è ancora aperto qui sotto: si chiude con «Risolto» o quando il problema sparisce.'::text; end if;
    same := true; sev := 'info';
    ttl := left(ttl, 58) || ' (invariato)';
  end if;

  update fabula.agent_runs set finished_at = clock_timestamp(), status = case when ok then 'ok' else 'error' end, summary = left(summ, 500),
         error = case when ok then null else left(coalesce(err, 'errore senza dettagli'), 500) end,
         details = coalesce(details, '{}'::jsonb) || (res - 'ok') || jsonb_build_object('fp', fp)
   where id = p_run;
  v_msg := fabula.post_bot_message(a, sev, left(ttl, 120),
             concat_ws(E'\n\n',
               case when array_length(todo, 1) > 0 and not same then '**Da fare**' || E'\n' || (select string_agg(i || '. ' || t, E'\n' order by i) from unnest(todo) with ordinality u(t, i)) end,
               case when array_length(facts, 1) > 0 then '**In breve**' || E'\n' || (select string_agg('- ' || f, E'\n') from unnest(facts) f) end,
               case when coalesce(res->>'by', v_run.details->>'by') is not null then 'Avviata a mano da ' || coalesce(res->>'by', v_run.details->>'by') || '.' end),
             p_run, link);
  return jsonb_build_object('run', p_run, 'severity', sev, 'title', ttl, 'message_id', v_msg, 'same', same);
end $$;
revoke all on function fabula.shopify_sync_finish(uuid, jsonb) from public, anon, authenticated;
grant execute on function fabula.shopify_sync_finish(uuid, jsonb) to service_role;

-- ============================================================================================================================
-- 7. «Esegui ora» and the hourly check know these jobs run in the database
-- ============================================================================================================================
do $mig$
declare d text := pg_get_functiondef('fabula.run_bot_fallback'::regproc); n text;
begin
  n := replace(d, $o$  perform fabula.require_perm('sistema', 2);
$o$, $n$  perform fabula.require_perm('sistema', 2);
  if p_agent = any (fabula.shopify_sync_agents()) then return fabula.shopify_sync_now(p_agent, p_confirm); end if;   -- v1.02a: a database job, run now
$n$);
  if n = d then raise exception 'v102a: run_bot_fallback pattern not found'; end if;
  execute n;
end $mig$;

do $mig$
declare d text := pg_get_functiondef('fabula.bot_watchdog'::regproc); n text;
begin
  n := replace(d, $o$             when r.agent = 'pg_cron' then null
$o$, $n$             when r.agent = any (fabula.shopify_sync_agents())
             then 'La sincronizzazione con Shopify la fa il database. Per riprovare: Configurazione → Bot → «Esegui ora»; la causa è nel messaggio del bot.'
             when r.agent = 'pg_cron' then null
$n$);
  if n = d then raise exception 'v102a: bot_watchdog pattern not found'; end if;
  execute n;
end $mig$;

-- ============================================================================================================================
-- 8. The clock
-- ============================================================================================================================
do $mig$ begin
  if exists (select 1 from cron.job where jobname = 'fabula_shopify_sync') then perform cron.unschedule('fabula_shopify_sync'); end if;
  perform cron.schedule('fabula_shopify_sync', '*/5 * * * *', $c$select fabula.shopify_sync_tick()$c$);
end $mig$;
