-- v0.95b · Audit 12/10/2026, backlog items under an hour, severity High/Critical — farm weight, settings, print data, outside watcher.
-- (audit backlog: FARM-01, C-04, C-28, E-20 health part, PRINT-03 go-live check). Patches are guarded: no match, no change.

-- 1 · (FARM-01) A farm weight far from today's order and from the usual loads is not recorded until the farm confirms it.
--     farm_milk_ship gets p_confirm: false = check first (answers needs_confirm with the numbers), true = the farm has confirmed.
--     NULL (an older farm-order function that does not send it) keeps the old behaviour, so the order of deploys does not matter.
--     Under 50 kg is refused in every case: no real tanker load is that small.
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.farm_milk_ship(text,numeric,numeric,text,text)'::regprocedure);
  n := replace(d, 'p_note text DEFAULT NULL::text)', 'p_note text DEFAULT NULL::text, p_confirm boolean DEFAULT NULL::boolean)');
  n := replace(n, 'declare v_tok text := ', 'declare v_order numeric; v_left numeric; v_med numeric; v_nrec int; v_fit boolean; v_tok text := ');
  n := replace(n, E'  if p_temp is not null and (p_temp < -2 or p_temp > 40)',
$s$  if p_kg < 50 then raise exception 'Peso troppo basso: % kg. Scrivi i kg di latte caricati (almeno 50 kg; 1.050 si scrive 1050)', round(p_kg, 1) using errcode = '22023'; end if;
  if p_temp is not null and (p_temp < -2 or p_temp > 40)$s$);
  n := replace(n, E'  insert into fabula.milk_shipments (ship_date, supplier_id,',
$s$  -- v0.95b (audit FARM-01): compare with today's approved order (and what is still missing of it) and with the median of the last 10 loads
  if p_confirm is false then
    select milk_kg into v_order from fabula.milk_plans where status = 'approved' and plan_date = v_today order by milk_kg desc limit 1;
    v_left := v_order - coalesce((select sum(kg) from fabula.milk_shipments where ship_date = v_today and status <> 'cancelled'), 0);
    select count(*), percentile_cont(0.5) within group (order by kg) into v_nrec, v_med
      from (select kg from fabula.milk_shipments where status <> 'cancelled' order by shipped_at desc limit 10) x;
    if v_nrec < 3 then v_med := null; end if;
    v_fit := (v_order is null and v_med is null)
          or (v_order is not null and p_kg between v_order * 0.7 and v_order * 1.3)
          or (v_left > 0 and p_kg between v_left * 0.7 and v_left * 1.3)
          or (v_med is not null and p_kg between v_med * 0.7 and v_med * 1.3);
    if not v_fit then
      return jsonb_build_object('needs_confirm', true, 'kg', round(p_kg, 1), 'order_kg', v_order, 'left_kg', case when v_left > 0 then v_left end,
        'usual_kg', round(v_med),
        'message_it', case when v_order is not null
          then format('Hai scritto %s kg ma l''ordine di oggi è %s kg%s. È giusto?', fabula._it_num(round(p_kg, 1)), fabula._it_int(v_order),
                      case when v_left > 0 and v_left < v_order then format(' (ne mancano %s)', fabula._it_int(v_left)) else '' end)
          else format('Hai scritto %s kg: di solito una spedizione è di circa %s kg. È giusto?', fabula._it_num(round(p_kg, 1)), fabula._it_int(v_med)) end);
    end if;
  end if;
  insert into fabula.milk_shipments (ship_date, supplier_id,$s$);
  if position('p_confirm boolean' in n) = 0 or position('v_order numeric' in n) = 0 or position('Peso troppo basso' in n) = 0 or position('needs_confirm' in n) = 0 then
    raise exception 'v095b: farm_milk_ship patterns not found';
  end if;
  drop function fabula.farm_milk_ship(text,numeric,numeric,text,text);
  execute n;
end $mig$;
revoke execute on function fabula.farm_milk_ship(text,numeric,numeric,text,text,boolean) from public, anon, authenticated;
grant execute on function fabula.farm_milk_ship(text,numeric,numeric,text,text,boolean) to service_role;

-- 2 · (C-28) kg per Shopify piece is a weight in kg: 0 < kg ≤ 25. A piece typed in grams (250) is refused instead of deducting 250 kg
--     per sale. The title auto-mapper only maps weights in that range (a "30 kg" catering title stays unmapped instead of failing).
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.upsert_shopify_orders(jsonb)'::regprocedure);
  n := replace(d, $s$if v_kg is not null and (coalesce(l->>'product_type', '') ilike '%mozzarella%'$s$, $s$if v_kg > 0 and v_kg <= 25 and (coalesce(l->>'product_type', '') ilike '%mozzarella%'$s$);
  if n = d then raise exception 'v095b: upsert_shopify_orders auto-map pattern not found'; end if;
  execute n;
end $mig$;
alter table fabula.shopify_variant_map drop constraint if exists shopify_variant_map_kg_per_unit_check;
alter table fabula.shopify_variant_map add constraint shopify_variant_map_kg_per_unit_check check (kg_per_unit > 0 and kg_per_unit <= 25);

-- 3 · (C-04) B2B cut-off and delivery days: written the Italian way they are normalised ("18.00", "ore 18" → 18:00; "lun,mar" or
--     "1-6" → 1,2,3,4,5,6); anything unreadable is refused with a sentence instead of breaking the trade portal. The cut-off falls back
--     to 18:00 if the stored value is ever unreadable. Configurazione shows a time field and seven weekday boxes (settings.kind).
create or replace function fabula.trg_settings_format() returns trigger language plpgsql set search_path = fabula, public as $$
declare v text := lower(trim(coalesce(new.value, ''))); m text[]; x text; days int[] := '{}'; a int; b int;
begin
  if new.key = 'trade.cutoff_time' then
    m := regexp_match(v, '^(?:ore\s*)?(\d{1,2})(?:\s*[:.,h]\s*(\d{2}))?$');
    if m is null or m[1]::int > 23 or coalesce(m[2], '00')::int > 59 then
      raise exception 'Orario limite non valido: «%». Scrivilo come 18:00', new.value using errcode = '22023';
    end if;
    new.value := lpad(m[1], 2, '0') || ':' || coalesce(m[2], '00');
  elsif new.key = 'trade.default_window' then
    m := regexp_match(v, '^(\d{1,2})[:.](\d{2})\s*[-–]\s*(\d{1,2})[:.](\d{2})$');
    if m is null or m[1]::int > 23 or m[3]::int > 23 or m[2]::int > 59 or m[4]::int > 59 then
      raise exception 'Fascia di consegna non valida: «%». Scrivila come 07:00-09:00', new.value using errcode = '22023';
    end if;
    new.value := lpad(m[1], 2, '0') || ':' || m[2] || '-' || lpad(m[3], 2, '0') || ':' || m[4];
  elsif new.key = 'pickup.cutoff_hour' then
    if v !~ '^\d{1,2}$' or v::int > 23 then raise exception 'Ora limite ritiro non valida: «%». Scrivi l''ora intera, es. 18', new.value using errcode = '22023'; end if;
    new.value := v::int::text;
  elsif new.key = 'trade.delivery_days' then
    v := regexp_replace(v, '\s*-\s*', '-', 'g');
    foreach x in array regexp_split_to_array(v, '\s*[,;/ ]+\s*') loop
      continue when x = '';
      if x ~ '^[1-7]\s*-\s*[1-7]$' then
        a := split_part(x, '-', 1)::int; b := trim(split_part(x, '-', 2))::int;
        if a > b then raise exception 'Giorni di consegna: «%» va scritto dal più piccolo al più grande (es. 1-6)', x using errcode = '22023'; end if;
        days := days || array(select generate_series(a, b));
      elsif x ~ '^[1-7]$' then days := days || x::int;
      else
        a := array_position(array['lun','mar','mer','gio','ven','sab','dom'], left(x, 3));
        if a is null then raise exception 'Giorno di consegna non riconosciuto: «%». Usa 1 = lunedì … 7 = domenica, es. 1,2,3,4,5,6', x using errcode = '22023'; end if;
        days := days || a;
      end if;
    end loop;
    if cardinality(days) = 0 then raise exception 'Indica almeno un giorno di consegna (1 = lunedì … 7 = domenica)' using errcode = '22023'; end if;
    new.value := (select string_agg(dd::text, ',' order by dd) from (select distinct unnest(days) dd) z);
  end if;
  return new;
end $$;
drop trigger if exists settings_format on fabula.settings;
create trigger settings_format before insert or update of value on fabula.settings for each row
  when (new.key in ('trade.cutoff_time', 'trade.default_window', 'pickup.cutoff_hour', 'trade.delivery_days'))
  execute function fabula.trg_settings_format();
alter table fabula.settings drop constraint if exists settings_kind_check;
alter table fabula.settings add constraint settings_kind_check check (kind in ('flag', 'date', 'month', 'time', 'weekdays'));
update fabula.settings set kind = 'time' where key = 'trade.cutoff_time';
update fabula.settings set kind = 'weekdays' where key = 'trade.delivery_days';

create or replace function fabula.trade_cutoff_at(p_date date) returns timestamp language sql stable set search_path = fabula, public as $$
  -- v0.95b (audit C-04): an unreadable cut-off falls back to 18:00 instead of breaking the portal and Console → Ingrosso
  select (p_date - 1)::timestamp + case when fabula.setting_text('trade.cutoff_time', '18:00') ~ '^([01]?\d|2[0-3]):[0-5]\d(:[0-5]\d)?$'
                                        then fabula.setting_text('trade.cutoff_time', '18:00')::time else time '18:00' end
$$;

-- 4 · (E-20, health part) The outside watcher (GitHub, every 30 min) also fails when scheduled bots stopped running: a bot slot of
--     today, due in the last 4 hours and past its grace (+20 min for the database stand-in), with no run of the bot itself.
--     The nightly backup has its own check (backup_ok). Only a count is published (the endpoint is public).
create or replace function public.fabula_health() returns jsonb language sql stable security definer set search_path = fabula, public, pg_catalog as $$
  with d as (select (now() at time zone 'Europe/Rome')::date as day),
  slots as (
    select bs.agent, (d.day + t.due) at time zone 'Europe/Rome' as due_at, bs.grace_min
      from fabula.bot_schedule bs cross join d cross join unnest(bs.due_times) t(due)
     where bs.active and bs.agent <> 'backup_export' and extract(isodow from d.day) = any (bs.weekdays)
       and (bs.month_day is null or extract(day from d.day) = bs.month_day)),
  missed as (
    select s.agent from slots s
     where s.due_at + make_interval(mins => s.grace_min + 20) <= now() and s.due_at > now() - interval '4 hours'
       and not exists (select 1 from fabula.agent_runs ar where ar.agent = s.agent and ar.started_at >= s.due_at - interval '30 minutes'
                         and coalesce(ar.details->>'via', '') <> 'db_fallback'))
  select jsonb_build_object(
    'db', true,
    'cron_ok', coalesce((select start_time from cron.job_run_details where start_time is not null order by runid desc limit 1) > now() - interval '20 minutes', false),
    'backup_ok', exists (select 1 from fabula.agent_runs where agent = 'backup_export' and status = 'ok' and started_at > now() - interval '26 hours'),
    'bots_ok', not exists (select 1 from missed),
    'bots_missed', (select count(*) from missed),
    'at', now())
$$;

-- 5 · (PRINT-03) Go-live board: an automatic check that DDTs and purchase orders carry the legal name, the P.IVA and a street address.
create or replace function fabula.is_street_address(p text) returns boolean language sql immutable set search_path = fabula, public as $$
  select coalesce(p, '') ~* '(^|[[:space:],])(via|v\.le|viale|piazza|p\.zza|piazzale|corso|c\.so|largo|strada|str\.|località|loc\.|contrada|c\.da|vicolo|traversa|borgo|frazione|fraz\.|s\.s\.|ss|s\.p\.|sp)([[:space:].,]|$)'
$$;
create or replace function fabula.company_docs_check() returns jsonb language sql stable set search_path = fabula, public as $$
  with c as (select trim(coalesce(fabula.setting_text('company.legal_name', ''), '')) ln, trim(coalesce(fabula.setting_text('company.piva', ''), '')) piva,
                    trim(coalesce(fabula.setting_text('company.address', ''), '')) addr),
  m as (select array_remove(array[case when ln = '' then 'ragione sociale' end,
                                  case when piva !~* '^(it)?\s*\d{11}$' then 'P.IVA' end,
                                  case when not fabula.is_street_address(addr) then 'indirizzo (via e numero)' end], null) miss from c)
  select jsonb_build_object('done', cardinality(miss) = 0,
                            'detail', case when cardinality(miss) = 0 then 'Legal name, P.IVA and street address set'
                                           else 'Missing on DDTs: ' || array_to_string(miss, ', ') || ' (Configurazione → Azienda)' end) from m
$$;
insert into fabula.dash_checks (key, sort, label, kind) values ('company_docs', 9, 'Company data on DDTs and POs (legal name, P.IVA, street address)', 'auto')
on conflict (key) do nothing;
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.ops_dashboard()'::regprocedure);
  n := replace(d, E'  v_auto := jsonb_build_object(\n', E'  v_auto := jsonb_build_object(\n    ''company_docs'', fabula.company_docs_check(),   -- v0.95b (audit PRINT-03)\n');
  if n = d or (length(n) - length(replace(n, 'company_docs_check()', ''))) <> length('company_docs_check()') then
    raise exception 'v095b: ops_dashboard pattern not found (or found more than once)';
  end if;
  execute n;
end $mig$;
