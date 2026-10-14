-- v1.03b · Audit 12/10/2026, FARM-04: the Masseria's links.
--   * Two keys instead of one. The full link (milk.farm_token) is for the farm's owner: the dairy's orders, the last 30 days, the
--     month totals, corrections and «Visto». The QR in the barn gets its own key (milk.farm_ship_token): whoever scans it can only
--     record a shipment, see today's loads and correct one it recorded in the last 2 hours. A photo of the poster no longer opens
--     everything, and each one can be replaced without touching the other.
--   * «Chi spedisce»: every shipment records who sent it (milk_shipments.recorded_by) and from which link (source farm_page or
--     farm_qr). The names come from the setting milk.farm_people; the farm page asks once and remembers it on the phone.
--   * Configurazione → Utenti e accessi → «Link della Masseria» (titolare and soci, Sistema = gestisce): open, copy or send the full
--     link, print the poster, and «Genera nuovo link» / «Genera nuovo QR», which make a new random key on the server (no key is
--     typed by hand any more, v1.03a refuses one that is not 32-64 hex characters). The office is told in the Bot feed.
--   * The Console's Masseria card shows the links only to the same people, says that the full link gives full access, and prints
--     the poster with the QR key.
-- Rollback: none needed for data; the old single link keeps working as the full link.

-- ============================================================================================================================
-- 1. Settings and columns
-- ============================================================================================================================
insert into fabula.settings (key, value, description, data_type, sort) values
  ('milk.farm_ship_token', encode(extensions.gen_random_bytes(16), 'hex'),
   'Chiave del QR spedizioni appeso alla Masseria (solo registrare spedizioni): si rigenera da Configurazione → Utenti e accessi → Link della Masseria', 'text', 30),
  ('milk.farm_people', '',
   'Chi spedisce dalla Masseria: nomi separati da virgola (es. Mario, Luca). La pagina della Masseria chiede chi spedisce e lo ricorda sul telefono. Vuoto = scrivono il nome a mano', 'text', 32)
on conflict (key) do nothing;
update fabula.settings
   set description = 'Chiave del link completo della Masseria (ordini, storico, correzioni): si rigenera da Configurazione → Utenti e accessi → Link della Masseria'
 where key = 'milk.farm_token';

-- the full key now has to be 32-64 hex characters (v1.03a): one that is not (typed by hand before v1.03) could never open the page
-- again, so it is replaced here and the office is told to send the new link
do $mig$
begin
  if not exists (select 1 from fabula.settings where key = 'milk.farm_token' and value ~ '^[0-9a-f]{32,64}$') then
    insert into fabula.settings (key, value, description, data_type, sort)
    values ('milk.farm_token', encode(extensions.gen_random_bytes(16), 'hex'), 'Chiave del link completo della Masseria', 'text', 30)
    on conflict (key) do update set value = excluded.value;
    perform fabula.post_bot_message('configurazione', 'warn', 'Link della Masseria cambiato: va rimandato',
      'Con v1.03 il link della Masseria ha una chiave nuova (quella di prima non era nel formato giusto): il vecchio link non funziona più. Mandalo al titolare della Masseria da Configurazione → Utenti e accessi → Link della Masseria → «Manda su WhatsApp».');
  end if;
end $mig$;

alter table fabula.milk_shipments add column if not exists recorded_by text;
comment on column fabula.milk_shipments.recorded_by is 'v1.03b (audit FARM-04): who at the Masseria recorded the shipment (milk.farm_people, chosen on the farm page)';
comment on column fabula.milk_shipments.source is 'farm_page = the Masseria''s full link · farm_qr = the QR poster in the barn (v1.03b)';

-- ============================================================================================================================
-- 2. Which link was used
-- ============================================================================================================================
create or replace function fabula._farm_scope(p_token text) returns text
language sql stable security definer set search_path = fabula, public as $$
  select case when p_token is null or length(p_token) < 32 then null
              when p_token = (select value from fabula.settings where key = 'milk.farm_token') then 'full'
              when p_token = (select value from fabula.settings where key = 'milk.farm_ship_token') then 'qr' end
$$;
revoke all on function fabula._farm_scope(text) from public, anon, authenticated;

create or replace function fabula._farm_people() returns jsonb
language sql stable security definer set search_path = fabula, public as $$
  select coalesce(jsonb_agg(x order by ord), '[]'::jsonb)
    from (select distinct on (lower(btrim(p))) btrim(p) as x, ord
            from regexp_split_to_table(coalesce((select value from fabula.settings where key = 'milk.farm_people'), ''), '\s*[,;\n]\s*') with ordinality t(p, ord)
           where btrim(p) <> '' order by lower(btrim(p)), ord) y
$$;
revoke all on function fabula._farm_people() from public, anon, authenticated;

-- the usual load: median of the last 10 loads of the last 30 days (null with fewer than 3)
create or replace function fabula._farm_usual_kg() returns numeric
language sql stable security definer set search_path = fabula, public as $$
  select case when count(*) >= 3 then round(percentile_cont(0.5) within group (order by kg)::numeric) end
    from (select kg from fabula.milk_shipments
           where status <> 'cancelled' and ship_date >= (now() at time zone 'Europe/Rome')::date - 30
           order by shipped_at desc limit 10) x
$$;
revoke all on function fabula._farm_usual_kg() from public, anon, authenticated;

-- ============================================================================================================================
-- 3. The farm page's functions (service role only, called by the farm-order server function)
-- ============================================================================================================================
create or replace function fabula.farm_milk_orders(p_token text) returns jsonb
language plpgsql stable security definer set search_path = fabula, public as $function$
declare v_today date := (now() at time zone 'Europe/Rome')::date; v_scope text := fabula._farm_scope(p_token);
begin
  if v_scope is null then return null; end if;
  if v_scope = 'qr' then
    -- the QR in the barn: today's loads and today's order only (enough to check the weight), nothing older
    return jsonb_build_object(
      'scope', 'qr',
      'company', fabula.company_name(),
      'receiving_hours', (select value from fabula.settings where key = 'company.receiving_hours'),
      'today', v_today,
      'people', fabula._farm_people(),
      'usual_kg', fabula._farm_usual_kg(),
      'shipments', (select coalesce(jsonb_agg(jsonb_build_object('milk_lot', s.milk_lot, 'kg', s.kg, 'shipped_at', s.shipped_at, 'ship_date', s.ship_date,
                                                                'temperature_c', s.temperature_c, 'ddt_number', s.ddt_number, 'status', s.status, 'received_at', s.received_at,
                                                                'cancel_reason', s.cancel_reason, 'cancelled_by', s.cancelled_by,
                                                                'original_kg', s.original_kg, 'correction_reason', s.correction_reason,
                                                                'recorded_by', s.recorded_by, 'source', s.source,
                                                                'can_amend', s.status = 'shipped' and s.source = 'farm_qr' and s.shipped_at > now() - interval '2 hours')
                                             order by s.shipped_at desc), '[]')
                      from fabula.milk_shipments s where s.ship_date = v_today),
      'milk_temp', (select jsonb_build_object('warn_max', warn_max, 'max', max_value) from fabula.haccp_control_points where code = 'CCP-MILK-TEMP' and active limit 1),
      'orders', (select coalesce(jsonb_agg(jsonb_build_object('plan_date', plan_date, 'milk_kg', milk_kg) order by plan_date), '[]')
                   from fabula.milk_plans where status = 'approved' and plan_date = v_today),
      'pending', '[]'::jsonb);
  end if;
  return jsonb_build_object(
    'scope', 'full',
    'company', fabula.company_name(),
    'receiving_hours', (select value from fabula.settings where key = 'company.receiving_hours'),
    'today', v_today,
    'people', fabula._farm_people(),
    'usual_kg', fabula._farm_usual_kg(),
    'shipments', (select coalesce(jsonb_agg(jsonb_build_object('milk_lot', s.milk_lot, 'kg', s.kg, 'shipped_at', s.shipped_at, 'ship_date', s.ship_date,
                                                              'temperature_c', s.temperature_c, 'ddt_number', s.ddt_number, 'status', s.status, 'received_at', s.received_at,
                                                              'arrival_temp_c', mi.temperature_c, 'rejection_reason', mi.rejection_reason,
                                                              'cancel_reason', s.cancel_reason, 'cancelled_by', s.cancelled_by,
                                                              'original_kg', s.original_kg, 'correction_reason', s.correction_reason,
                                                              'dairy_kg', mi.dairy_kg, 'entered_kg', mi.qty_kg,
                                                              'weight_note', case when mi.qty_kg is distinct from mi.farm_kg then mi.weight_note end,
                                                              'recorded_by', s.recorded_by, 'source', s.source,
                                                              'can_amend', s.status = 'shipped' and s.shipped_at > now() - interval '7 days')
                                           order by s.shipped_at desc), '[]')
                    from fabula.milk_shipments s left join fabula.milk_intake mi on mi.id = s.milk_intake_id
                   where s.ship_date >= v_today - 30),
    'month', jsonb_build_object(
        'received_kg', (select coalesce(sum(coalesce(mi2.qty_kg, s2.kg)), 0) from fabula.milk_shipments s2 left join fabula.milk_intake mi2 on mi2.id = s2.milk_intake_id
                                    where s2.status = 'received' and s2.ship_date >= date_trunc('month', v_today)::date),
        'shipments', (select count(*) from fabula.milk_shipments where status = 'received' and ship_date >= date_trunc('month', v_today)::date),
        'prev_received_kg', (select coalesce(sum(coalesce(mi2.qty_kg, s2.kg)), 0) from fabula.milk_shipments s2 left join fabula.milk_intake mi2 on mi2.id = s2.milk_intake_id
                               where s2.status = 'received'
                               and s2.ship_date >= (date_trunc('month', v_today) - interval '1 month')::date and s2.ship_date < date_trunc('month', v_today)::date)),
    'milk_temp', (select jsonb_build_object('warn_max', warn_max, 'max', max_value) from fabula.haccp_control_points where code = 'CCP-MILK-TEMP' and active limit 1),   -- v0.98 (FARM-07)
    'orders', (select coalesce(jsonb_agg(jsonb_build_object('plan_date', plan_date, 'milk_kg', milk_kg, 'seen_at', farm_seen_at) order by plan_date), '[]')
                 from fabula.milk_plans where status = 'approved' and plan_date between v_today and v_today + 7),
    'pending', (select coalesce(jsonb_agg(jsonb_build_object('plan_date', m.plan_date, 'milk_kg', m.milk_kg, 'decide_by', a.expires_at) order by m.plan_date), '[]')
                  from fabula.milk_plans m left join fabula.approvals a on a.id = m.approval_id
                 where m.status = 'proposed' and m.plan_date between v_today and v_today + 7
                   and (a.expires_at is null or a.expires_at > now())));
end $function$;

-- recording a load: either link; p_by = who (v1.03b), stored with the link it came from
drop function if exists fabula.farm_milk_ship(text, numeric, numeric, text, text, boolean);
create or replace function fabula.farm_milk_ship(p_token text, p_kg numeric, p_temp numeric default null, p_ddt text default null, p_note text default null,
                                                 p_confirm boolean default null, p_by text default null) returns jsonb
language plpgsql security definer set search_path = fabula, public as $function$
declare v_order numeric; v_left numeric; v_med numeric; v_fit boolean; v_scope text := fabula._farm_scope(p_token);
        v_today date := (now() at time zone 'Europe/Rome')::date; v_n int; v_lot text; r fabula.milk_shipments;
        v_by text := nullif(left(btrim(regexp_replace(coalesce(p_by, ''), '\s+', ' ', 'g')), 60), '');
begin
  if v_scope is null then return null; end if;
  if p_kg is null or p_kg <= 0 or p_kg > 5000 then raise exception 'Peso non valido: %', p_kg using errcode = '22023'; end if;
  if p_kg < 50 then raise exception 'Peso troppo basso: % kg. Scrivi i kg di latte caricati (almeno 50 kg; 1.050 si scrive 1050)', round(p_kg, 1) using errcode = '22023'; end if;
  if p_temp is not null and (p_temp < -2 or p_temp > 40) then raise exception 'Temperatura non valida: %', p_temp using errcode = '22023'; end if;
  perform pg_advisory_xact_lock(hashtext('farm_milk_ship'));
  -- a second tap within 3 minutes with the same weight returns the shipment already recorded
  select * into r from fabula.milk_shipments where kg = round(p_kg, 1) and shipped_at > now() - interval '3 minutes' and status <> 'cancelled' order by shipped_at desc limit 1;
  if found then return jsonb_build_object('id', r.id, 'milk_lot', r.milk_lot, 'kg', r.kg, 'shipped_at', r.shipped_at, 'recorded_by', r.recorded_by, 'duplicate', true); end if;
  select count(*) into v_n from fabula.milk_shipments where ship_date = v_today;
  if v_n >= 8 then raise exception 'Troppe spedizioni oggi (%)', v_n using errcode = '22023'; end if;
  v_lot := 'M' || to_char(v_today, 'YYMMDD') || '-' || (v_n + 1);
  while exists (select 1 from fabula.milk_shipments where milk_lot = v_lot) or exists (select 1 from fabula.labels where upper(code) = upper('LOT:' || v_lot)) loop
    v_n := v_n + 1; v_lot := 'M' || to_char(v_today, 'YYMMDD') || '-' || (v_n + 1);
  end loop;
  -- v0.95b (audit FARM-01): compare with today's approved order (and what is still missing of it) and with the median of the last 10 loads
  if p_confirm is false then
    select milk_kg into v_order from fabula.milk_plans where status = 'approved' and plan_date = v_today order by milk_kg desc limit 1;
    v_left := v_order - coalesce((select sum(kg) from fabula.milk_shipments where ship_date = v_today and status <> 'cancelled'), 0);
    v_med := fabula._farm_usual_kg();
    v_fit := (v_order is null and v_med is null)
          or (v_order is not null and p_kg between v_order * 0.7 and v_order * 1.3)
          or (v_left > 0 and p_kg between v_left * 0.7 and v_left * 1.3)
          or (v_med is not null and p_kg between v_med * 0.7 and v_med * 1.3);
    if not coalesce(v_fit, false) then   -- NULL = no reference matched (e.g. no order today and the weight far from the usual loads)
      return jsonb_build_object('needs_confirm', true, 'kg', round(p_kg, 1), 'order_kg', v_order, 'left_kg', case when v_left > 0 then v_left end,
        'usual_kg', v_med,
        'message_it', case when v_order is not null
          then format('Hai scritto %s kg ma l''ordine di oggi è %s kg%s. È giusto?', fabula._it_num(round(p_kg, 1)), fabula._it_int(v_order),
                      case when v_left > 0 and v_left < v_order then format(' (ne mancano %s)', fabula._it_int(v_left)) else '' end)
          else format('Hai scritto %s kg: di solito una spedizione è di circa %s kg. È giusto?', fabula._it_num(round(p_kg, 1)), fabula._it_int(v_med)) end);
    end if;
  end if;
  insert into fabula.milk_shipments (ship_date, supplier_id, kg, milk_lot, temperature_c, ddt_number, note, recorded_by, source)
  values (v_today, nullif((select value from fabula.settings where key = 'milk.farm_supplier_id'), '')::uuid, round(p_kg, 1), v_lot,
          p_temp, nullif(left(trim(coalesce(p_ddt, '')), 40), ''), nullif(left(trim(coalesce(p_note, '')), 300), ''), v_by,
          case v_scope when 'qr' then 'farm_qr' else 'farm_page' end)
  returning * into r;
  return jsonb_build_object('id', r.id, 'milk_lot', r.milk_lot, 'kg', r.kg, 'shipped_at', r.shipped_at, 'recorded_by', r.recorded_by);
end $function$;
revoke all on function fabula.farm_milk_ship(text, numeric, numeric, text, text, boolean, text) from public, anon, authenticated;
grant execute on function fabula.farm_milk_ship(text, numeric, numeric, text, text, boolean, text) to service_role;

-- correcting or cancelling a load in transit: the full link for any load of the last 7 days, the QR only for a load it recorded
-- in the last 2 hours
drop function if exists fabula.farm_milk_amend(text, text, numeric, boolean, text);
create or replace function fabula.farm_milk_amend(p_token text, p_lot text, p_kg numeric default null, p_cancel boolean default false,
                                                  p_reason text default null, p_by text default null) returns jsonb
language plpgsql security definer set search_path = fabula, public as $function$
declare v_scope text := fabula._farm_scope(p_token);
        r fabula.milk_shipments; v_reason text := nullif(left(trim(coalesce(p_reason, '')), 300), '');
        v_by text := nullif(left(btrim(regexp_replace(coalesce(p_by, ''), '\s+', ' ', 'g')), 60), '');
        v_who text;
begin
  if v_scope is null then return null; end if;
  v_who := 'La Masseria' || coalesce(' (' || v_by || ')', '');
  select * into r from fabula.milk_shipments where milk_lot = p_lot for update;
  if not found then raise exception 'Spedizione % non trovata', p_lot using errcode = '22023'; end if;
  if r.status <> 'shipped' then
    raise exception 'La spedizione % è già stata %: non si può più cambiare. Chiama il caseificio.', r.milk_lot,
      case r.status when 'received' then 'ricevuta dal caseificio' when 'rejected' then 'respinta dal caseificio' else 'annullata' end using errcode = '22023';
  end if;
  if v_scope = 'qr' and (r.source is distinct from 'farm_qr' or r.shipped_at < now() - interval '2 hours') then
    raise exception 'Dal QR si corregge solo una spedizione registrata dal QR nelle ultime 2 ore: per la % chiama il caseificio.', r.milk_lot using errcode = '22023';
  end if;
  if r.shipped_at < now() - interval '7 days' then raise exception 'La spedizione % è di più di 7 giorni fa: chiama il caseificio.', r.milk_lot using errcode = '22023'; end if;
  if v_reason is null or length(v_reason) < 3 then raise exception 'Scrivi il motivo (es. «registrata due volte», «peso sbagliato»)' using errcode = '22023'; end if;
  if coalesce(p_cancel, false) then
    update fabula.milk_shipments set status = 'cancelled', cancelled_at = now(), cancelled_by = 'Masseria', cancel_reason = v_reason
     where id = r.id returning * into r;
    perform fabula.post_bot_message('masseria', 'warn', 'Masseria: spedizione ' || r.milk_lot || ' annullata',
      format('%s ha annullato la spedizione %s (%s kg, partita %s). Motivo: %s. Sul tablet non compare più tra quelle in arrivo.',
             v_who, r.milk_lot, replace(to_char(r.kg, 'FM99990.0'), '.', ','), to_char(r.shipped_at at time zone 'Europe/Rome', 'DD/MM HH24:MI'), v_reason));
  else
    if p_kg is null or p_kg <= 0 or p_kg > 5000 then raise exception 'Peso non valido: %', p_kg using errcode = '22023'; end if;
    if round(p_kg, 1) = r.kg then raise exception 'Il peso è già % kg', replace(to_char(r.kg, 'FM99990.0'), '.', ',') using errcode = '22023'; end if;
    update fabula.milk_shipments set original_kg = coalesce(original_kg, kg), kg = round(p_kg, 1), corrected_at = now(), correction_reason = v_reason
     where id = r.id returning * into r;
    perform fabula.post_bot_message('masseria', 'info', 'Masseria: peso corretto su ' || r.milk_lot,
      format('%s ha corretto la spedizione %s: %s kg (prima %s kg). Motivo: %s.',
             v_who, r.milk_lot, replace(to_char(r.kg, 'FM99990.0'), '.', ','), replace(to_char(r.original_kg, 'FM99990.0'), '.', ','), v_reason));
  end if;
  return jsonb_build_object('milk_lot', r.milk_lot, 'kg', r.kg, 'status', r.status, 'original_kg', r.original_kg);
end $function$;
revoke all on function fabula.farm_milk_amend(text, text, numeric, boolean, text, text) from public, anon, authenticated;
grant execute on function fabula.farm_milk_amend(text, text, numeric, boolean, text, text) to service_role;

-- «Visto» on an order: the full link only
create or replace function fabula.farm_milk_seen(p_token text, p_plan_date date) returns boolean
language plpgsql security definer set search_path = fabula, public as $function$
declare n int;
begin
  if fabula._farm_scope(p_token) is distinct from 'full' then return false; end if;
  update fabula.milk_plans set farm_seen_at = coalesce(farm_seen_at, now()) where plan_date = p_plan_date and status = 'approved';
  get diagnostics n = row_count;
  return n > 0;
end $function$;

-- ============================================================================================================================
-- 4. The dairy's side: links for the titolare and soci only, and a new key made on the server
-- ============================================================================================================================
-- (was: anyone with Produzione or Acquisti could read the full link through the Console)
create or replace function fabula.farm_order_link() returns text
language sql stable security definer set search_path = fabula, public as $$
  select case when fabula.perm_level('sistema') >= 3
              then 'latte.html?t=' || (select value from fabula.settings where key = 'milk.farm_token') end
$$;

create or replace function fabula.farm_links() returns jsonb
language plpgsql stable security definer set search_path = fabula, public as $$
declare v_full text; v_qr text;
begin
  if fabula.perm_level('sistema') < 3 then return null; end if;
  select value into v_full from fabula.settings where key = 'milk.farm_token';
  select value into v_qr from fabula.settings where key = 'milk.farm_ship_token';
  return jsonb_build_object(
    'full', case when v_full is not null then 'latte.html?t=' || v_full end,
    'qr', case when v_qr is not null then 'latte.html?t=' || v_qr || '&azione=spedizione' end,
    'poster', case when v_qr is not null then 'latte.html?t=' || v_qr || '&stampa=1' end,
    'people', fabula._farm_people(),
    'people_text', coalesce((select value from fabula.settings where key = 'milk.farm_people'), ''),
    'full_changed_at', (select max(at) from fabula.audit_log where table_name = 'settings' and row_key = 'milk.farm_token'),
    'qr_changed_at', (select max(at) from fabula.audit_log where table_name = 'settings' and row_key = 'milk.farm_ship_token'),
    'qr_last_used_at', (select max(shipped_at) from fabula.milk_shipments where source = 'farm_qr'),
    'full_last_used_at', (select max(shipped_at) from fabula.milk_shipments where source = 'farm_page'));
end $$;

create or replace function fabula.farm_link_rotate(p_which text) returns jsonb
language plpgsql security definer set search_path = fabula, public as $$
declare v_key text; v_who text;
begin
  perform fabula.require_perm('sistema', 3);
  if p_which is null or p_which not in ('full', 'qr') then raise exception 'Scegli quale link rigenerare' using errcode = '22023'; end if;
  v_key := case p_which when 'full' then 'milk.farm_token' else 'milk.farm_ship_token' end;
  update fabula.settings set value = encode(extensions.gen_random_bytes(16), 'hex') where key = v_key;
  if not found then raise exception 'Impostazione % mancante: chiedi a Claude', v_key using errcode = '22023'; end if;
  select full_name into v_who from fabula.staff where id = fabula.my_staff_id();
  perform fabula.post_bot_message('configurazione', 'info',
    case p_which when 'full' then 'Nuovo link della Masseria' else 'Nuovo QR spedizioni della Masseria' end,
    case p_which
      when 'full' then format('%s ha generato un nuovo link completo per la Masseria: quello vecchio non funziona più. Va mandato al titolare della Masseria (Configurazione → Utenti e accessi → Link della Masseria → Manda su WhatsApp).', coalesce(v_who, 'Qualcuno'))
      else format('%s ha generato un nuovo QR per le spedizioni: il poster appeso alla Masseria non funziona più. Va ristampato e sostituito (Configurazione → Utenti e accessi → Link della Masseria → Stampa il poster).', coalesce(v_who, 'Qualcuno')) end);
  return fabula.farm_links();
end $$;

-- the poster in the barn still carries the full key until it is replaced: the office is reminded once
select fabula.post_bot_message('configurazione', 'warn', 'Masseria: stampa il nuovo QR e cambia il link',
  'v1.03 dà al poster della stalla una chiave sua, che serve solo a registrare le spedizioni. Il poster appeso adesso porta ancora il link completo. '
  || 'Da Configurazione → Utenti e accessi → Link della Masseria: 1) «Stampa il poster» e sostituisci quello appeso; 2) «Genera nuovo link» e mandalo al titolare della Masseria con «Manda su WhatsApp» (così il vecchio poster smette di funzionare); 3) scrivi i nomi in «Chi spedisce».');

revoke all on function fabula.farm_links() from public, anon;
revoke all on function fabula.farm_link_rotate(text) from public, anon;
grant execute on function fabula.farm_links() to authenticated;
grant execute on function fabula.farm_link_rotate(text) to authenticated;

insert into fabula.security_accepted (key, reason) values
  ('authenticated_security_definer_function_executable:fabula.farm_links()', 'by design (v1.03b, audit FARM-04): returns the Masseria links only to Sistema = gestisce (perm_level check), null otherwise'),
  ('authenticated_security_definer_function_executable:fabula.farm_link_rotate(p_which text)', 'by design (v1.03b, audit FARM-04): require_perm(sistema, 3); makes a new random key on the server')
on conflict (key) do nothing;
