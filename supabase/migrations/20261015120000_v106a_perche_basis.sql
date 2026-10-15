-- v1.06a «Perché?» (15/10/2026): what every bot message was based on, kept by the database. Spec: project doc
-- claude/perche-spec-v106-2026-10-15.md. Part a: where the data is kept, how it reaches the message, the number check.
--   * fabula.message_basis: one row per read a bot (or the database) made before writing its message. The bot never copies the data:
--     its step-1 call is wrapped, select fabula.keep_basis('<agent>', '<function>', fabula.<function>()), so Postgres keeps what the
--     function returned and hands the same JSON to the bot.
--   * post_bot_message links the rows of the same agent from the last 60 minutes, not yet used, to the message it writes
--     (bot_messages.basis_at) and, for a bot's own reads, compares the message's numbers with the data (bot_messages.basis_check).
--   * The database's stand-in (bot_fallback_run, also «Esegui ora»), the auto-approvals and three food-safety alarms keep theirs too.
--   * v_bot_feed.has_basis, my_alarms() has_basis; Telegram: a «perché» link next to «apri».
--   * Configurazione → Panoramica → Sistema «Numeri dei messaggi»; nightly clean-up after 90 days (24 expected database jobs).
-- Part b (v106b): the explanations in Italian (fabula.message_why) and the prompts' new versions.

-- ============================== settings ==============================
insert into fabula.settings (key, value, description, data_type, kind, sort, impact_it, min_value, max_value, unit) values
  ('bots.basis_keep_days', '90', 'Per quanti giorni si conservano i dati dietro ai messaggi dei bot (pulsante «Perché?»).', 'number', null, 90,
   'Dopo questi giorni il «Perché?» di un messaggio più vecchio dice che i dati non ci sono più.', 7, 400, 'giorni'),
  ('bots.basis_max_kb', '256', 'Dimensione massima dei dati conservati per una lettura di un bot. Oltre, si conserva solo che erano troppo grandi.', 'number', null, 91,
   'Il «Perché?» di una lettura più grande dice che i dati erano troppo grandi per essere conservati.', 16, 2048, 'KB'),
  ('bots.number_check_all', '0', 'Mostra a tutti, nel «Perché?», i numeri di un messaggio che non si trovano nei dati letti dal bot. No = solo a chi gestisce il sistema.', 'number', 'flag', 92,
   'Mettilo a Sì quando il controllo, dopo un paio di settimane, segnala quasi solo errori veri (Configurazione → Panoramica → Sistema → «Numeri dei messaggi»).', null, null, null)
on conflict (key) do nothing;

-- ============================== where the data is kept ==============================
create table if not exists fabula.message_basis (
  id         bigserial primary key,
  agent      text not null check (agent ~ '^[a-z][a-z0-9_]{1,40}$'),
  call       text not null check (call ~ '^[a-z_][a-z0-9_]{1,60}$'),
  data       jsonb,
  extra      jsonb,
  bytes      integer not null default 0,
  too_big    boolean not null default false,
  kept_by    text not null default 'bot' check (kept_by in ('bot', 'database')),
  kept_at    timestamptz not null default now(),
  message_id bigint references fabula.bot_messages(id) on delete cascade deferrable initially deferred
);
comment on table fabula.message_basis is 'v1.06 («Perché?»): what a bot (kept_by bot) or the database (kept_by database) read before writing a message. keep_basis() adds a row; post_bot_message() links the rows of its agent from the last 60 minutes to the message; message_why() writes them out in Italian. data = exactly what the function returned; extra = what the database adds for the explanation (never seen by the bot, not used by the number check). Deleted after bots.basis_keep_days (basis_trim).';
create index if not exists message_basis_pending on fabula.message_basis (agent, kept_at desc) where message_id is null;
create index if not exists message_basis_message on fabula.message_basis (message_id) where message_id is not null;
alter table fabula.message_basis enable row level security;
revoke all on fabula.message_basis from public, anon, authenticated;
insert into fabula.table_areas (table_name, area, write_level, read_open) values ('message_basis', 'sistema', 3, false) on conflict do nothing;

alter table fabula.bot_messages add column if not exists basis_at timestamptz;
alter table fabula.bot_messages add column if not exists basis_check jsonb;
comment on column fabula.bot_messages.basis_at is 'v1.06: when the data behind this message (fabula.message_basis) was linked to it; null = no «Perché?».';
comment on column fabula.bot_messages.basis_check is 'v1.06: the numbers of the title and body compared with the data the bot read (only for a bot''s own reads): numbers, found, missing (max 10), dates, dates_found.';

-- what the database adds to a read, for the explanation only (the bot never sees it)
create or replace function fabula._basis_extra(p_call text, p_data jsonb) returns jsonb
language sql stable security definer set search_path = fabula, public as $$
  select case p_call
    -- the orders' own numbers (stock, use, terms, price) are in their approval, not in what propose_purchase_orders returns
    when 'propose_purchase_orders' then
      (select jsonb_build_object('orders', coalesce(jsonb_object_agg(a.payload->>'po_number', a.payload - 'supplier_email'), '{}'::jsonb))
         from fabula.approvals a
        where a.kind = 'purchase_order' and a.payload ? 'po_number'
          and a.payload->>'po_number' in (select c->>'po_number' from jsonb_array_elements(coalesce(p_data->'created', '[]'::jsonb)) c))
    -- the promo's full price is in its approval
    when 'sell_down_signals' then
      (select jsonb_build_object('promos', coalesce(jsonb_object_agg(a.payload->>'lot', jsonb_build_object('list_price_eur_kg', a.payload->'list_price_eur_kg',
                                                    'promo_price_eur_kg', a.payload->'promo_price_eur_kg', 'promo_pct', a.payload->'promo_pct')), '{}'::jsonb))
         from fabula.approvals a
        where a.requested_by = 'agent:sell_down' and a.payload ? 'lot' and a.requested_at::date = coalesce((p_data->>'date')::date, current_date))
  end
$$;
revoke all on function fabula._basis_extra(text, jsonb) from public, anon, authenticated;

-- the data without phone numbers and e-mails (they are in Anagrafiche; a read never needs to keep them)
create or replace function fabula._basis_strip(p jsonb) returns jsonb
language sql immutable set search_path = fabula, public as $$
  select case jsonb_typeof(p)
    when 'object' then (select coalesce(jsonb_object_agg(k, fabula._basis_strip(v)), '{}'::jsonb) from jsonb_each(p) e(k, v)
                         where lower(k) not in ('phone', 'telefono', 'cellulare', 'mobile', 'email', 'e_mail', 'supplier_email', 'lab_email', 'contact', 'to'))
    when 'array' then (select coalesce(jsonb_agg(fabula._basis_strip(v) order by o), '[]'::jsonb) from jsonb_array_elements(p) with ordinality a(v, o))
    else p end
$$;
revoke all on function fabula._basis_strip(jsonb) from public, anon, authenticated;

-- the bot's step 1: select fabula.keep_basis('<agent>', '<function>', fabula.<function>()) — returns the same JSON, keeps a copy
create or replace function fabula.keep_basis(p_agent text, p_call text, p_data jsonb, p_by text default 'bot') returns jsonb
language plpgsql security definer set search_path = fabula, public as $$
declare v_bytes int := coalesce(octet_length(p_data::text), 0);
        v_max int := greatest(coalesce(fabula.setting_num('bots.basis_max_kb', 256), 256), 16)::int * 1024;
begin
  if coalesce(p_agent, '') !~ '^[a-z][a-z0-9_]{1,40}$' or coalesce(p_call, '') !~ '^[a-z_][a-z0-9_]{1,60}$' then
    return p_data;                   -- never stand between the bot and its data: a wrong name only means nothing is kept
  end if;
  begin
    insert into fabula.message_basis (agent, call, data, extra, bytes, too_big, kept_by)
    values (p_agent, p_call, case when v_bytes <= v_max then fabula._basis_strip(p_data) end,
            case when v_bytes <= v_max then fabula._basis_extra(p_call, p_data) end, v_bytes, v_bytes > v_max,
            case when p_by = 'database' then 'database' else 'bot' end);
  exception when others then
    raise warning 'keep_basis %/%: %', p_agent, p_call, sqlerrm;
  end;
  return p_data;
end $$;
revoke all on function fabula.keep_basis(text, text, jsonb, text) from public, anon, authenticated;
grant execute on function fabula.keep_basis(text, text, jsonb, text) to service_role;
comment on function fabula.keep_basis(text, text, jsonb, text) is 'v1.06 («Perché?»): the bots wrap their step-1 read in it; it keeps a copy of what the function returned (fabula.message_basis) and returns the same JSON. post_bot_message links it to the message.';

-- ============================== the number check ==============================
-- the numbers and dates written in a text, each number with the values it can mean: «1.200» = 1200 (Italian) or 1.2, «1530.40» (the
-- database's own text) = 1530.4, «20,5 %» = 20.5, «−8 %» = −8 (signed: a sign written before the digits is compared too).
-- p_message: also leave out the EN line, the ready-to-send drafts («> …»), the «(invariato dal …)» notes, the list numbering and the
-- phone numbers — they are not the data's numbers.
create or replace function fabula._basis_tokens(p_text text, p_message boolean default true)
returns table (tok text, kind text, vals numeric[], decs integer[], pct boolean, signed boolean)
language plpgsql immutable set search_path = fabula, public as $$
declare t text := coalesce(p_text, ''); m text[]; s text; v numeric[]; d int[]; g numeric;
begin
  if p_message then
    t := regexp_replace(t, '^[ \t]*EN[ \t]*[—–-].*$', '', 'gn');
    t := regexp_replace(t, '^[ \t]*>.*$', '', 'gn');
    t := regexp_replace(t, '\(invariat[oi][^)]*\)', ' ', 'gi');
    t := regexp_replace(t, '^([ \t]*)[0-9]{1,2}[.)]([ \t])', '\1\2', 'gn');
    t := regexp_replace(t, '(\+39[ \t]?)?(3[0-9]{2}|0[0-9]{1,3})[ \t]?[0-9]{3}[ \t]?[0-9]{3,4}', ' ', 'g');   -- Italian phone numbers
  end if;
  t := regexp_replace(t, '\mCCP[ \t]*[0-9]+[ \t]*[a-z]?\M', ' ', 'gi');                     -- «CCP 3», «CCP 1b»
  t := regexp_replace(t, '\m(cella frigo|cella|frigo)[ \t]+[0-9]{1,2}(?![0-9]|[.,][0-9])', ' ', 'gi');   -- the glossary's «cella frigo 1»
  -- codes and lots (CF-01, L20261015-A, PO-20261015-01, perla-v72, 48h): a word with both letters and digits is not a number
  t := regexp_replace(t, '[[:alnum:]_.-]*([[:alpha:]][[:alnum:]_-]*[[:digit:]]|[[:digit:]][[:alnum:]_-]*[[:alpha:]])[[:alnum:]_.-]*', ' ', 'g');
  t := regexp_replace(t, '\m[0-9]{1,2}:[0-9]{2}\M', ' ', 'g');                             -- times («ore 06:00»)
  t := regexp_replace(t, '\m(ore|alle|dalle|entro le)[ \t]+[0-9]{1,2}\M', ' ', 'gi');      -- «alle 6»
  -- lengths of time («4 settimane», «30 giorni», «60 ore»): the bot's own instructions, not data
  t := regexp_replace(t, '\m[0-9]+[ \t]+(settimane|settimana|giorni|giorno|mesi|mese|ore|ora|minuti|minuto|anni|anno)\M', ' ', 'gi');
  for m in select regexp_matches(t, '\m([0-9]{1,2})/([0-9]{1,2})(/[0-9]{2,4})?\M', 'g') loop
    if m[1]::int between 1 and 31 and m[2]::int between 1 and 12 then
      tok := m[1]::int || '/' || m[2]::int; kind := 'date'; vals := null; decs := null; pct := false; signed := false; return next;
    end if;
  end loop;
  t := regexp_replace(t, '\m[0-9]{1,2}/[0-9]{1,2}(/[0-9]{2,4})?\M', ' ', 'g');
  t := regexp_replace(t, '(^|[^0-9.,])20[2-3][0-9](?![0-9]|[.,][0-9])', '\1 ', 'g');               -- years (not «2040,00»)
  for m in select regexp_matches(t, '(^|[^[:alnum:]])([+−-]?)([0-9][0-9.,]*[0-9]|[0-9])([ \t]*%)?', 'g') loop
    s := m[3]; v := '{}'; d := '{}'; g := case when m[2] in ('−', '-') then -1 else 1 end;
    if s ~ '^[0-9]{1,3}(\.[0-9]{3})+(,[0-9]+)?$' then                                    -- Italian thousands «1.200», «1.440,50»
      v := v || g * replace(replace(s, '.', ''), ',', '.')::numeric; d := d || coalesce(length(substring(s from ',([0-9]+)$')), 0);
    end if;
    if s ~ '^[0-9]+,[0-9]+$' then                                                         -- Italian decimal «20,5»
      v := v || g * replace(s, ',', '.')::numeric; d := d || length(substring(s from ',([0-9]+)$'));
    end if;
    if s ~ '^[0-9]{1,3}(,[0-9]{3})+(\.[0-9]+)?$' then                                    -- English thousands «1,200»
      v := v || g * replace(s, ',', '')::numeric; d := d || coalesce(length(substring(s from '\.([0-9]+)$')), 0);
    end if;
    if s ~ '^[0-9]+\.[0-9]+$' then                                                        -- the database's own «1530.40», or «1.2»
      v := v || g * s::numeric; d := d || length(substring(s from '\.([0-9]+)$'));
    end if;
    if s ~ '^[0-9]+$' then v := v || g * s::numeric; d := d || 0; end if;
    continue when cardinality(v) = 0;                                                    -- «1.2.3»: not a number
    tok := m[2] || s || case when m[4] is not null then ' %' else '' end; kind := 'num'; vals := v; decs := d;
    pct := m[4] is not null; signed := m[2] <> '';
    return next;
  end loop;
end $$;
revoke all on function fabula._basis_tokens(text, boolean) from public, anon, authenticated;

-- every number in the data (also the ones written inside its texts, the digits of its codes — «CF-01» is 1 — and the length of
-- every list, which a bot may count) and every date, as «d/m»
create or replace function fabula._basis_values(p_data jsonb, out nums numeric[], out dates text[])
language plpgsql stable set search_path = fabula, public as $$
declare v jsonb; s text; r record; n int := 0; x date; c text[];
begin
  nums := '{}'; dates := '{}';
  for v in select j from jsonb_path_query(coalesce(p_data, 'null'::jsonb), 'lax $.**') j loop
    if jsonb_typeof(v) = 'number' then
      nums := nums || (v #>> '{}')::numeric;
    elsif jsonb_typeof(v) = 'array' then
      nums := nums || jsonb_array_length(v)::numeric;
    elsif jsonb_typeof(v) = 'string' then
      s := v #>> '{}'; n := n + 1;
      continue when n > 5000 or length(s) > 4000 or s = '';
      if s ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}' then
        begin
          x := left(s, 10)::date; dates := dates || (extract(day from x)::int || '/' || extract(month from x)::int);
          if length(s) > 10 then x := (s::timestamptz at time zone 'Europe/Rome')::date; dates := dates || (extract(day from x)::int || '/' || extract(month from x)::int); end if;
        exception when others then null;
        end;
      elsif s ~ '^-?[0-9]+(\.[0-9]+)?$' then
        nums := nums || s::numeric;
      else
        for r in select * from fabula._basis_tokens(s, false) loop
          if r.kind = 'date' then dates := dates || r.tok; else nums := nums || r.vals; end if;
        end loop;
        for c in select regexp_matches(s, '[[:alpha:]][-_]?([0-9]{1,6})', 'g') loop nums := nums || c[1]::numeric; end loop;
      end if;
    end if;
  end loop;
end $$;
revoke all on function fabula._basis_values(jsonb) from public, anon, authenticated;

-- the check of one message against the bot's own reads linked to it: a number matches when the data has it at the precision written
-- (rounded: «12» for 12,4, not «13»), with its sign when one is written, or ×100 for a percentage written from a fraction
create or replace function fabula._basis_check(p_text text, p_message_id bigint) returns jsonb
language plpgsql stable set search_path = fabula, public as $$
declare v_nums numeric[] := '{}'; v_dates text[] := '{}'; b record; t record; n int := 0; f int := 0; nd int := 0; fd int := 0;
        miss text[] := '{}'; ok boolean;
begin
  if not exists (select 1 from fabula.message_basis where message_id = p_message_id and kept_by = 'bot' and data is not null)
     or exists (select 1 from fabula.message_basis where message_id = p_message_id and kept_by = 'database') then
    return null;                     -- only a bot's own words are checked; the database writes its text from the same numbers
  end if;
  for b in select data from fabula.message_basis where message_id = p_message_id and kept_by = 'bot' and data is not null loop
    select v_nums || x.nums, v_dates || x.dates into v_nums, v_dates from fabula._basis_values(b.data) x;
  end loop;
  for t in select * from fabula._basis_tokens(p_text, true) loop
    if t.kind = 'date' then
      nd := nd + 1;
      if t.tok = any (v_dates) then fd := fd + 1; elsif not (t.tok = any (miss)) then miss := miss || t.tok; end if;
    else
      n := n + 1;
      select exists (select 1 from unnest(t.vals, t.decs) c(v, d), unnest(v_nums) x
                      where case when t.signed then abs(x - c.v) else abs(abs(x) - abs(c.v)) end <= 0.5 * power(10::numeric, -c.d) + 0.0000001
                         or (t.pct and case when t.signed then abs(x * 100 - c.v) else abs(abs(x) * 100 - abs(c.v)) end <= 0.5 * power(10::numeric, -c.d) + 0.0000001))
        into ok;
      if ok then f := f + 1; elsif not (t.tok = any (miss)) then miss := miss || t.tok; end if;
    end if;
  end loop;
  return jsonb_build_object('checked_at', now(), 'numbers', n, 'found', f, 'dates', nd, 'dates_found', fd, 'missing', to_jsonb(miss[1:10]));
end $$;
revoke all on function fabula._basis_check(text, bigint) from public, anon, authenticated;

-- ============================== post_bot_message: the data goes with the message ==============================
create or replace function fabula.post_bot_message(p_agent text, p_severity text, p_title text, p_body text, p_run_id uuid default null::uuid,
                                                   p_link text default null::text, p_link_label text default null::text, p_prompt text default null::text)
 returns bigint
 language plpgsql
 security definer
 set search_path to 'fabula', 'public'
as $function$
declare v_id bigint; v_sev text := case when p_severity in ('info','warn','alert') then p_severity else 'info' end;
        v_link text := fabula.safe_link(nullif(trim(p_link), '')); v_appr uuid; v_prompt text := nullif(left(btrim(coalesce(p_prompt, '')), 40), '');
        v_new boolean := false; v_n int := 0; v_check jsonb; v_since timestamptz; v_db boolean;
begin
  -- a milk plan or a promo links to its own card, and the message closes when that request is decided (E-05)
  if p_agent in ('milk_planning', 'sell_down') then
    select a.id into v_appr from fabula.approvals a
     where a.status = 'pending' and a.requested_at > now() - interval '3 hours'
       and fabula.approval_type(a.kind, a.payload) = case p_agent when 'milk_planning' then 'milk_plan' else 'sell_down' end
     order by a.requested_at desc limit 1;
    if v_appr is not null and v_link is null then v_link := 'console.html#oggi&appr=' || v_appr; end if;
  end if;
  v_link := coalesce(v_link, fabula.bot_default_link(p_agent));
  select id into v_id from fabula.bot_messages
   where agent = p_agent and source = 'auto' and created_at > now() - interval '90 minutes'
   order by created_at desc limit 1;
  if v_id is null then v_new := true; v_id := nextval(pg_get_serial_sequence('fabula.bot_messages', 'id')); end if;
  -- v1.06 («Perché?»): what this agent read since its previous message (at most an hour ago) and has not used yet goes with this
  -- message. When the database read (its stand-in, its own alarms), only its reads go: a read left by a bot run that stopped is not
  -- what the database's message says.
  select greatest(now() - interval '60 minutes', coalesce(max(created_at), '-infinity'::timestamptz)) into v_since
    from fabula.bot_messages where agent = p_agent and id <> v_id;
  select bool_or(kept_by = 'database') into v_db from fabula.message_basis where agent = p_agent and message_id is null and kept_at >= v_since;
  if v_db is not null then
    if not v_new then delete from fabula.message_basis where message_id = v_id; end if;
    update fabula.message_basis set message_id = v_id
     where agent = p_agent and message_id is null and kept_at >= v_since and (not v_db or kept_by = 'database');
    get diagnostics v_n = row_count;
    begin
      v_check := fabula._basis_check(coalesce(p_title, '') || E'\n' || coalesce(p_body, ''), v_id);
    exception when others then
      v_check := jsonb_build_object('error', left(sqlerrm, 200));      -- the check never stops a message
    end;
  end if;
  if not v_new then
    update fabula.bot_messages set severity = v_sev, title = coalesce(nullif(p_title, ''), title), body = p_body, source = 'bot',
           run_id = coalesce(p_run_id, run_id), read_at = null, read_by = null, created_at = now(),
           resolved_at = null, resolved_by_id = null, resolution = null,
           action_url = v_link, action_label = coalesce(nullif(trim(p_link_label), ''), fabula.link_label(v_link)), approval_id = coalesce(v_appr, approval_id),
           prompt_version = v_prompt,
           basis_at = case when v_n > 0 then now() else basis_at end, basis_check = case when v_n > 0 then v_check else basis_check end
     where id = v_id;
    delete from fabula.bot_message_reads where message_id = v_id;       -- new content: unread again for everyone
  else
    insert into fabula.bot_messages (id, agent, run_id, severity, title, body, source, action_url, action_label, approval_id, prompt_version, basis_at, basis_check)
    values (v_id, p_agent, p_run_id, v_sev, coalesce(nullif(p_title, ''), fabula.bot_display_name(p_agent)), p_body, 'bot',
            v_link, coalesce(nullif(trim(p_link_label), ''), fabula.link_label(v_link)), v_appr, v_prompt,
            case when v_n > 0 then now() end, v_check);
  end if;
  return v_id;
end $function$;
revoke all on function fabula.post_bot_message(text, text, text, text, uuid, text, text, text) from public, anon, authenticated;
grant execute on function fabula.post_bot_message(text, text, text, text, uuid, text, text, text) to service_role;

-- ============================== the database's own reads ==============================
do $do$
declare d text; n text;
begin
  -- the stand-in (automatic, and «Esegui ora»): what it read goes with the message its caller posts next; the evening check keeps the
  -- system checks with it
  d := pg_get_functiondef('fabula.bot_fallback_run(text,date)'::regprocedure);
  n := replace(d, $p$    begin x := fabula.infra_checks(); exception when others then x := '{}'::jsonb; end;$p$,
                  $p$    begin x := fabula.infra_checks(); exception when others then x := '{}'::jsonb; end;
    r := r || jsonb_build_object('infra_checks', x);                 -- v1.06 («Perché?»): the system checks go with the evening check's data$p$);
  if n = d then raise exception 'v106a: bot_fallback_run infra pattern not found'; end if;
  d := n;
  n := replace(d, $p$  return jsonb_build_object('severity', sev, 'title', ttl, 'body', body, 'summary', summ, 'result', r);$p$,
                  $p$  -- v1.06 («Perché?»): what the database read goes with the message its caller posts next (bot_fallback, run_bot_fallback)
  if r is not null then
    perform fabula.keep_basis(p_agent, case p_agent when 'milk_planning' then 'plan_milk' when 'procurement' then 'propose_purchase_orders'
                                                    when 'wholesale_orders' then 'confirm_standing_orders' when 'haccp_nudge' then 'haccp_evening_status'
                                                    when 'ops_health' then 'ops_health_check' when 'sell_down' then 'sell_down_signals' else p_agent end, r, 'database');
  end if;
  return jsonb_build_object('severity', sev, 'title', ttl, 'body', body, 'summary', summ, 'result', r);$p$);
  if n = d then raise exception 'v106a: bot_fallback_run return pattern not found'; end if;
  execute n;

  -- an auto-approval: the rule, the request and when nobody decided
  d := pg_get_functiondef('fabula.auto_approve_due(timestamptz)'::regprocedure);
  n := replace(d, $p$      perform fabula.post_bot_message('auto_approve', $p$,
                  $p$      perform fabula.keep_basis('auto_approve', 'auto_approve', jsonb_build_object('approval_id', a.id, 'type', v_type, 'summary', a.summary,
                'rule_it', r, 'amount_eur', a.amount_eur, 'payload', coalesce(a.payload, '{}'::jsonb) - 'rationale' - 'supplier_email',
                'requested_at', a.requested_at, 'auto_approve_at', a.auto_approve_at, 'decided_at', p_now), 'database');   -- v1.06 («Perché?»)
      perform fabula.post_bot_message('auto_approve', $p$);
  if n = d then raise exception 'v106a: auto_approve_due pattern not found'; end if;
  execute n;

  -- a lot closed without its CCP: which points it needed, what was recorded, the limits
  d := pg_get_functiondef('fabula.trg_batch_ccp_check()'::regprocedure);
  n := replace(d, $p$    perform fabula.post_bot_message('sicurezza', 'alert',$p$,
                  $p$    perform fabula.keep_basis('sicurezza', 'batch_ccp', jsonb_build_object('lot', new.batch_lot, 'input_kind', new.input_kind, 'closed_at', now(),
      'missing', to_jsonb(v_missing), 'held', true,
      'points', (select coalesce(jsonb_agg(jsonb_build_object('code', cp.code, 'ccp_no', cp.ccp_no, 'name', cp.name, 'limit_it', cp.critical_limit_it,
                                                             'min', cp.min_value, 'max', cp.max_value, 'unit', cp.unit,
                                                             'value', lv.measured_value, 'logged_at', lv.logged_at) order by cp.sort, cp.code), '[]'::jsonb)
                   from fabula.haccp_control_points cp
                   left join lateral (select l.measured_value, l.logged_at from fabula.haccp_log l
                                       where l.batch_id = new.id and l.control_point_id = cp.id and l.measured_value is not null
                                       order by l.logged_at desc limit 1) lv on true
                  where cp.code = any (v_need))), 'database');   -- v1.06 («Perché?»)
    perform fabula.post_bot_message('sicurezza', 'alert',$p$);
  if n = d then raise exception 'v106a: trg_batch_ccp_check pattern not found'; end if;
  execute n;

  -- milk rejected: the delivery, the reason, the lots held
  d := pg_get_functiondef('fabula.milk_reject(uuid,text,uuid,uuid,text)'::regprocedure);
  n := replace(d, $p$  perform fabula.post_bot_message('sicurezza', 'alert',$p$,
                  $p$  perform fabula.keep_basis('sicurezza', 'milk_reject', jsonb_build_object('milk_lot', mi.milk_lot, 'qty_kg', mi.qty_kg, 'reason', p_reason,
      'intake_date', mi.intake_date, 'ddt_number', mi.ddt_number, 'temperature_c', mi.temperature_c, 'lots_held', to_jsonb(v_held),
      'new_reject', v_new_reject), 'database');   -- v1.06 («Perché?»)
  perform fabula.post_bot_message('sicurezza', 'alert',$p$);
  if n = d then raise exception 'v106a: milk_reject pattern not found'; end if;
  execute n;

  -- the evening production watch: the open lots and the milk close to 60 hours
  d := pg_get_functiondef('fabula.prod_watch(timestamptz)'::regprocedure);
  n := replace(d, $p$  perform fabula.post_bot_message(case when n_milk > 0 then 'sicurezza' else 'produzione' end, 'warn', v_title,$p$,
                  $p$  perform fabula.keep_basis(case when n_milk > 0 then 'sicurezza' else 'produzione' end, 'prod_watch', jsonb_build_object('date', v_day, 'checked_at', p_now,
      'warn_hours', 48, 'dop_limit_hours', 60,
      'open_batches', (select coalesce(jsonb_agg(jsonb_build_object('lot', batch_lot, 'started', coalesce(started_at, batch_date::timestamptz)) order by batch_lot), '[]'::jsonb)
                         from fabula.production_batches where output_kg is null and batch_date <= v_day and coalesce(source, '') not in ('simulation', 'test')),
      'old_milk', (select coalesce(jsonb_agg(jsonb_build_object('lot', m.milk_lot, 'left_kg', m.left_kg, 'arrived', m.arrived,
                                                               'hours', round(extract(epoch from p_now - m.arrived) / 3600)) order by m.arrived), '[]'::jsonb)
                     from (select mi.milk_lot, ((mi.intake_date + coalesce(mi.intake_time, time '07:00')) at time zone 'Europe/Rome') arrived,
                                  mi.qty_kg - coalesce((select sum(bmi.qty_kg) from fabula.batch_milk_inputs bmi where bmi.milk_intake_id = mi.id), 0) left_kg
                             from fabula.milk_intake mi where mi.accepted and coalesce(mi.source, '') <> 'simulation' and mi.intake_date >= v_day - 5) m
                    where m.left_kg > 1 and m.arrived <= p_now - interval '48 hours')), 'database');   -- v1.06 («Perché?»)
  perform fabula.post_bot_message(case when n_milk > 0 then 'sicurezza' else 'produzione' end, 'warn', v_title,$p$);
  if n = d then raise exception 'v106a: prod_watch pattern not found'; end if;
  execute n;

  -- Telegram: a «perché» link next to «apri» when the message has its data (the Console opens it for every office profile)
  d := pg_get_functiondef('fabula.trg_notify_bot_message()'::regprocedure);
  n := replace(d, $p$    if v_dec and new.severity <> 'alert' and v_id is not null then$p$,
                  $p$    if v_id is not null and new.basis_at is not null and coalesce(fabula.setting_text('infra.site_url'), '') <> '' then   -- v1.06 («Perché?»)
      update fabula.notify_outbox set text_html = text_html || ' · <a href="' || rtrim(fabula.setting_text('infra.site_url'), '/')
                                                  || '/console.html#oggi&perche=' || new.id || '">perché</a>'
       where id = v_id;
    end if;
    if v_dec and new.severity <> 'alert' and v_id is not null then$p$);
  if n = d then raise exception 'v106a: trg_notify_bot_message pattern not found'; end if;
  execute n;
end $do$;

-- ============================== the feed, the alarms ==============================
create or replace view fabula.v_bot_feed with (security_invoker = true) as
 select id, agent, run_id, created_at, severity, title, body, source, notice_key, read_at, resolved_at, resolution, action_url, action_label, approval_id,
    fabula.bot_title(agent) as agent_title,
    (select n.nickname from fabula.bot_nicknames n where n.agent = m.agent) as agent_nickname,
    (select s.full_name from fabula.staff s where s.id = m.resolved_by_id) as resolved_by,
    (exists (select 1 from fabula.bot_message_reads r where r.message_id = m.id and r.staff_id = fabula.my_staff_id())) as read_by_me,
    (select string_agg((s.full_name || ' '::text) || to_char((r.read_at at time zone 'Europe/Rome'::text), 'DD/MM HH24:MI'::text), ' · '::text order by r.read_at)
       from fabula.bot_message_reads r join fabula.staff s on s.id = r.staff_id where r.message_id = m.id) as seen_by,
    read_at is null and (severity = 'alert'::text or not (exists (select 1 from fabula.bot_message_reads r where r.message_id = m.id and r.staff_id = fabula.my_staff_id()))) as for_me,
    basis_at is not null as has_basis
   from fabula.bot_messages m;

create or replace function fabula.my_alarms() returns jsonb
language sql stable security definer set search_path = fabula, public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'agent', x.agent, 'agent_title', fabula.bot_display_name(x.agent), 'created_at', x.created_at,
                                               'title', x.title, 'action_url', x.action_url, 'action_label', x.action_label, 'area', x.area,
                                               'has_basis', x.basis_at is not null)       -- v1.06 («Perché?»)
                            order by x.created_at desc), '[]'::jsonb)
    from (select m.*, fabula.message_area(m.agent, m.title) as area from fabula.bot_messages m
           where m.severity = 'alert' and m.read_at is null and m.notice_key is null and m.created_at > now() - interval '30 days'
           order by m.created_at desc limit 200) x
   where auth.uid() is not null and (fabula.can('sistema', 1) or fabula.can(x.area, 1))
$$;

-- ============================== Panoramica → Sistema: «Numeri dei messaggi» ==============================
create or replace function fabula._basis_check_summary() returns jsonb
language sql stable security definer set search_path = fabula, public as $$
  select jsonb_build_object('done', n_bad * 10 <= n_all,       -- a single slip is listed, the card turns «da controllare» above one in ten
    'detail', case when n_all = 0 then 'Nessun messaggio dei bot con i dati letti negli ultimi 7 giorni (le istruzioni nuove dei bot li mandano)'
                   when n_bad = 0 then format('Ultimi 7 giorni: i numeri di %s messaggi dei bot sono tutti nei dati che hanno letto', n_all)
                   else format('Ultimi 7 giorni: %s su %s messaggi dei bot %s numeri che non sono nei dati letti (%s). Aprili da Configurazione → Bot → «Perché?»',
                               n_bad, n_all, case when n_bad = 1 then 'ha' else 'hanno' end, agents) end,
    'count', n_bad, 'checked', n_all)
    from (select count(*) filter (where m.basis_check ? 'numbers') n_all,
                 count(*) filter (where jsonb_array_length(coalesce(m.basis_check -> 'missing', '[]'::jsonb)) > 0) n_bad,
                 string_agg(distinct fabula.bot_title(m.agent), ', ') filter (where jsonb_array_length(coalesce(m.basis_check -> 'missing', '[]'::jsonb)) > 0) agents
            from fabula.bot_messages m where m.created_at > now() - interval '7 days' and m.basis_check is not null) x
$$;
revoke all on function fabula._basis_check_summary() from public, anon, authenticated;

create or replace function fabula.system_checks() returns jsonb
language plpgsql stable security definer set search_path = fabula, public as $$
declare c jsonb; pd jsonb;
begin
  if not fabula.can('sistema', 1) then raise exception 'Il tuo profilo non vede lo stato del sistema' using errcode = '42501'; end if;
  c := fabula.infra_checks(); pd := fabula.prompt_drift();
  c := c || jsonb_build_object('bot_prompts', jsonb_build_object('done', (pd ->> 'count')::int = 0,
            'detail', coalesce(pd ->> 'line_it', 'I bot girano con le istruzioni aggiornate del repo')),
            'number_check', fabula._basis_check_summary());                     -- v1.06 («Perché?»)
  return (select jsonb_agg(jsonb_build_object('key', k, 'label_it', l, 'done', coalesce((c -> k ->> 'done')::boolean, false), 'detail', c -> k ->> 'detail') order by o)
            from (values (1, 'uptime', 'Sito e funzioni del server'), (2, 'cron_jobs', 'Attività programmate del database'), (3, 'vault_secret', 'Segreto del backup'),
                         (4, 'offsite_backup', 'Copia del backup fuori sede'), (5, 'outside_watcher', 'Monitor esterno (GitHub)'), (6, 'restore_tested', 'Prova di ripristino'),
                         (7, 'bot_prompts', 'Istruzioni dei bot'), (8, 'number_check', 'Numeri dei messaggi'), (9, 'repo_sync', 'Migrazioni: GitHub e database'),
                         (10, 'app_deployed', 'App del tablet pubblicata'), (11, 'advisors_clean', 'Sicurezza del database')) v(o, k, l));
end $$;

-- ============================== clean-up ==============================
create or replace function fabula.basis_trim() returns integer
language plpgsql security definer set search_path = fabula, public as $$
declare n int; m int;
begin
  delete from fabula.message_basis where message_id is null and kept_at < now() - interval '1 day';     -- read but never posted
  get diagnostics n = row_count;
  delete from fabula.message_basis where kept_at < now() - make_interval(days => greatest(coalesce(fabula.setting_num('bots.basis_keep_days', 90), 90), 7)::int);
  get diagnostics m = row_count;
  return n + m;
end $$;
revoke all on function fabula.basis_trim() from public, anon, authenticated;
select cron.schedule('fabula_basis_trim', '20 3 * * *', $c$select fabula.basis_trim()$c$);
insert into fabula.cron_jobs_expected (jobname, schedule, purpose_it) values
  ('fabula_basis_trim', '20 3 * * *', 'Pulizia dei dati dietro ai messaggi dei bot («Perché?», dopo i giorni di conservazione dei Parametri)')
on conflict (jobname) do nothing;
