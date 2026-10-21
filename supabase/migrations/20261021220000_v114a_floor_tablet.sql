-- v1.14a (21/10/2026) · R-04 from the 19/10 re-audit (claude/golive-rescore-2026-10-19.md, «Reliable»):
-- the go-live check «Tablet di produzione aggiornato» ticked on any device. Nick's iPhone on the latest app turned it green on 19/10,
-- v1.08b turned it red again, and every device is «tablet-1» (audit A-35), so nobody could tell which one was the floor tablet.
--   * fabula.devices.floor: Configurazione → Utenti e accessi → Dispositivi marks the floor tablet(s) and names every device
--     (set_device, Sistema = gestisce). A named device keeps its name: the check-in no longer overwrites it, and the tablet takes it
--     for its own records (scan events, refused saves).
--   * The go-live check «tablet_checkin» and the trial's «Giorno 1 · tablet di produzione collegato» count only floor tablets.
--   * device_watch warns about an old app only on floor tablets (records waiting too long: every device, as before). Messages name a
--     device by the name given in Configurazione, or by what it is and who used it («iPhone di Nick») while it has none (a label
--     sent by the tablet itself is never trusted as a name). A floor tablet that stops checking in for 2 days is reported.
--   * «On the latest app» = that version or a newer one: the hourly site check can lag a release by up to an hour, and a tablet already
--     on the new app no longer counts as old (nor is told to update) meanwhile.

alter table fabula.devices add column if not exists floor boolean not null default false;
alter table fabula.devices add column if not exists named_at timestamptz;
alter table fabula.devices add column if not exists named_by uuid references fabula.staff(id);
comment on column fabula.devices.floor is 'v1.14 (R-04): a tablet used on the production floor. Only these count for the go-live check «Tablet di produzione aggiornato» and the trial''s day 1, and only these get the «app vecchia» warning. Set in Configurazione → Utenti e accessi → Dispositivi (fabula.set_device).';
create unique index if not exists devices_named_label_uq on fabula.devices (lower(label)) where named_at is not null;
comment on column fabula.devices.named_at is 'v1.14: when someone named the device in Configurazione (set_device). From then on the check-in keeps the name and the tablet adopts it.';

-- ============================== helpers (database only) ==============================
-- the number of an app version: perla-v79 → 79 (null when it is not one)
create or replace function fabula._app_ver_num(p text) returns int language sql immutable set search_path = fabula, public as $$
  select nullif(substring(coalesce(p, '') from 'perla-v([0-9]{1,6})'), '')::int
$$;
-- what a device is, from its browser's description (an iPad on Safari says «Macintosh»: only the device itself can tell)
create or replace function fabula._device_kind(p_ua text) returns text language sql immutable set search_path = fabula, public as $$
  select case when coalesce(p_ua, '') = '' then 'dispositivo'
              when p_ua ~* 'iPad' then 'iPad'
              when p_ua ~* 'iPhone' then 'iPhone'
              when p_ua ~* 'Android' and p_ua ~* 'Mobile' then 'telefono Android'
              when p_ua ~* 'Android' then 'tablet Android'
              when p_ua ~* 'Macintosh' then 'Mac o iPad'
              when p_ua ~* 'Windows' then 'PC Windows'
              when p_ua ~* 'CrOS' then 'Chromebook'
              when p_ua ~* 'Linux' then 'computer Linux'
              else 'browser' end
$$;
-- how messages call a device: the name given in Configurazione, else what it is and who used it last (the label a tablet sends
-- with ?device= is not trusted: any login could send the floor tablet's name, or nothing)
create or replace function fabula._device_name(p_uid text) returns text language sql stable set search_path = fabula, public as $$
  select case when d.named_at is not null and coalesce(btrim(d.label), '') <> '' then d.label
              else fabula._device_kind(d.user_agent) || coalesce(' di ' || nullif(split_part(btrim(s.full_name), ' ', 1), ''), '') end
    from fabula.devices d left join fabula.staff s on s.id = d.staff_id
   where d.device_uid = p_uid
$$;
revoke all on function fabula._app_ver_num(text) from public, anon;
grant execute on function fabula._app_ver_num(text) to authenticated, service_role;   -- pure; ops_dashboard() runs as its caller
revoke all on function fabula._device_kind(text) from public, anon, authenticated;
revoke all on function fabula._device_name(text) from public, anon, authenticated;

-- ============================== check-in: a named device keeps its name ==============================
create or replace function fabula.device_checkin(p_device_uid text, p_label text, p_version text, p_queue_len integer, p_oldest timestamp with time zone,
                                                 p_failed jsonb default '[]'::jsonb, p_user_agent text default null::text)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'fabula', 'public'
as $function$
declare v_staff uuid := fabula.my_staff_id(); f jsonb; n int := 0; v_new jsonb := '[]'; v_what text; d fabula.devices; v_name text;
begin
  if v_staff is null then raise exception 'Solo il personale può registrare un dispositivo' using errcode = '42501'; end if;
  if coalesce(p_device_uid, '') !~ '^[A-Za-z0-9_-]{6,64}$' then raise exception 'Identificativo dispositivo non valido'; end if;
  insert into fabula.devices (device_uid, label, staff_id, app_version, queue_len, oldest_queued_at, failed_len, user_agent, last_seen_at)
  values (p_device_uid, left(p_label, 40), v_staff, left(p_version, 20), greatest(coalesce(p_queue_len, 0), 0), p_oldest,
          jsonb_array_length(coalesce(p_failed, '[]')), left(p_user_agent, 200), now())
  on conflict (device_uid) do update set label = case when devices.named_at is null then excluded.label else devices.label end,   -- v1.14
         staff_id = excluded.staff_id, app_version = excluded.app_version,
         queue_len = excluded.queue_len, oldest_queued_at = excluded.oldest_queued_at, failed_len = excluded.failed_len,
         user_agent = coalesce(excluded.user_agent, devices.user_agent), last_seen_at = now(),
         warned = case when excluded.queue_len = 0 then devices.warned - 'queue' else devices.warned end
  returning * into d;
  v_name := fabula._device_name(p_device_uid);
  for f in select * from jsonb_array_elements(coalesce(p_failed, '[]')) limit 50 loop
    continue when coalesce(f->>'qid', '') = '' or length(f::text) > 100000;
    v_what := coalesce((select o->>'table' from jsonb_array_elements(coalesce(f->'ops', '[]')) o where o ? 'table' limit 1),
                       (select o->>'rpc' from jsonb_array_elements(coalesce(f->'ops', '[]')) o where o ? 'rpc' limit 1), '?');
    -- v1.14: the same name as the alarm's title (resolve_tablet_reject closes the alarm by «(name)»)
    insert into fabula.tablet_rejects (qid, device_uid, device_label, staff_id, what, ops, error, code, failed_at)
    values (f->>'qid', p_device_uid, left(v_name, 40), v_staff, v_what, coalesce(f->'ops', '[]'), left(f->>'error', 500), left(f->>'code', 20),
            case when f->>'failed_at' ~ '^\d+$' then to_timestamp((f->>'failed_at')::bigint / 1000.0) else now() end)
    on conflict (qid) do nothing;
    get diagnostics n = row_count;
    if n > 0 then v_new := v_new || jsonb_build_object('what', v_what, 'error', left(f->>'error', 200)); end if;
  end loop;
  if jsonb_array_length(v_new) > 0 then
    perform fabula.post_bot_message(case when exists (select 1 from jsonb_array_elements(v_new) x
                                                         where x->>'what' ~ '^(log_ccp|log_milk_check|haccp_log|close_open_task|milk_intake|record_receipt_check|log_batch_step|effluent_log)$')
                                                    then 'sicurezza' else 'tablet' end, 'alert',
      format('%s registrazion%s rifiutat%s dal database (%s)', jsonb_array_length(v_new), case when jsonb_array_length(v_new) = 1 then 'e' else 'i' end,
             case when jsonb_array_length(v_new) = 1 then 'a' else 'e' end, left(coalesce(v_name, 'tablet'), 40)),
      format(E'Il dispositivo «%s» (%s) ha inviato registrazioni fatte senza rete che il database non ha accettato:\n%s\n\nLe trovi in Autocontrollo → Registri → «Registrazioni rifiutate»: vanno rifatte (dal tablet, 🛡 → Ricopia da foglio di carta, con l''ora vera) o corrette, poi «Segna come rifatta». Se è una registrazione HACCP (CCP, temperature, pulizie) va rifatta oggi.',
             coalesce(v_name, 'tablet'), (select full_name from fabula.staff where id = v_staff),
             (select string_agg('• ' || fabula.tablet_reject_what(x->>'what') || ': ' || coalesce(x->>'error', 'errore'), E'\n') from jsonb_array_elements(v_new) x)));
  end if;
  -- v1.14: the name given in Configurazione goes back to the tablet, which uses it for its own records
  return jsonb_build_object('ok', true, 'reported', jsonb_array_length(v_new), 'live_version', fabula.live_app_version(),
                            'name', case when d.named_at is not null then d.label end, 'floor', d.floor);
end $function$;
revoke all on function fabula.device_checkin(text, text, text, int, timestamptz, jsonb, text) from public, anon;
grant execute on function fabula.device_checkin(text, text, text, int, timestamptz, jsonb, text) to authenticated, service_role;

-- ============================== watchdog: old app only on floor tablets ==============================
create or replace function fabula.device_watch(p_now timestamp with time zone default now())
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'fabula', 'public'
as $function$
declare d record; v_live text := fabula.live_app_version(); v_rel timestamptz; out jsonb := '[]'; v_name text;
begin
  -- v0.79: the release time is when the live version last changed (kept in infra.sw_seen = '<version>|<time>'),
  -- not the last successful check (that moved every hour, so the old-app warning never fired)
  if v_live is not null and split_part(coalesce((select value from fabula.settings where key = 'infra.sw_seen'), ''), '|', 1) is distinct from v_live then
    insert into fabula.settings (key, value, description, data_type, sort, updated_at)
    values ('infra.sw_seen', v_live || '|' || p_now::text, 'Versione dell''app in linea e da quando (aggiornato da device_watch)', 'text', 99, now())
    on conflict (key) do update set value = excluded.value, updated_at = now();
  end if;
  v_rel := nullif(split_part(coalesce((select value from fabula.settings where key = 'infra.sw_seen'), ''), '|', 2), '')::timestamptz;
  for d in select * from fabula.devices where last_seen_at > p_now - interval '14 days' loop
    v_name := fabula._device_name(d.device_uid);
    -- records waiting more than 2 h (from the last check-in; a tablet that stopped checking in keeps its last report): every device
    if d.queue_len > 0 and d.oldest_queued_at < p_now - interval '2 hours'
       and coalesce((d.warned->>'queue')::timestamptz, '-infinity') < p_now - interval '1 day' then
      perform fabula.post_bot_message('tablet', 'warn', format('%s: %s registrazioni in attesa da %s', v_name, d.queue_len,
                to_char(d.oldest_queued_at at time zone 'Europe/Rome', 'DD/MM HH24:MI')),
        format(E'%s «%s» ha %s registrazioni salvate senza rete e non ancora arrivate al database (la più vecchia delle %s). Ultimo contatto: %s.\nControllare che sia acceso e connesso al Wi-Fi e aprire l''app: partono da sole.',
               case when d.floor then 'Il tablet' else 'Il dispositivo' end, v_name, d.queue_len, to_char(d.oldest_queued_at at time zone 'Europe/Rome', 'HH24:MI "del" DD/MM'),
               to_char(d.last_seen_at at time zone 'Europe/Rome', 'DD/MM HH24:MI')));
      update fabula.devices set warned = warned || jsonb_build_object('queue', p_now) where device_uid = d.device_uid;
      out := out || jsonb_build_object('device', v_name, 'kind', 'queue');
    end if;
    -- v1.14: a floor tablet that stopped checking in (switched off, off the Wi-Fi, or its storage was cleared: then it comes back
    -- as a new, unmarked device). Two days, so a closed day is not reported; then every 3 days while it stays in the 14-day window.
    if d.floor and d.last_seen_at < p_now - interval '2 days'
       and coalesce((d.warned->>'silent')::timestamptz, '-infinity') < p_now - interval '3 days' then
      perform fabula.post_bot_message('tablet', 'warn', format('%s non si collega da %s', v_name,
                fabula.it_n(extract(day from p_now - d.last_seen_at)::int, 'giorno', 'giorni')),
        format(E'Il tablet del caseificio «%s» non si collega dal %s. Controllare che sia acceso, con il Wi-Fi, e aprire l''app.\nSe in Configurazione → Utenti e accessi → Dispositivi compare come nuovo dispositivo (succede se la memoria del browser è stata cancellata), dagli il nome e segna lì «Tablet del caseificio»; a quello vecchio togli il segno. Se il caseificio è chiuso, ignora.',
               v_name, to_char(d.last_seen_at at time zone 'Europe/Rome', 'DD/MM HH24:MI')));
      update fabula.devices set warned = warned || jsonb_build_object('silent', p_now) where device_uid = d.device_uid;
      out := out || jsonb_build_object('device', v_name, 'kind', 'silent');
    end if;
    -- old app a day after the release: v1.14 only on the floor tablets (a socio's phone or computer updates when it is next opened)
    if d.floor and v_live is not null and fabula._app_ver_num(d.app_version) < fabula._app_ver_num(v_live) and v_rel < p_now - interval '1 day'
       and d.last_seen_at > p_now - interval '1 day'
       and coalesce((d.warned->>'version')::timestamptz, '-infinity') < p_now - interval '1 day' then
      perform fabula.post_bot_message('tablet', 'warn', format('%s usa ancora la versione %s (attuale %s)', v_name, d.app_version, v_live),
        format('Il tablet «%s» non ha caricato l''ultima versione dell''app. Sul tablet compare «Aggiorna»: toccalo, oppure chiudi e riapri l''app con la rete.', v_name));
      update fabula.devices set warned = warned || jsonb_build_object('version', p_now) where device_uid = d.device_uid;
      out := out || jsonb_build_object('device', v_name, 'kind', 'version');
    end if;
  end loop;
  return jsonb_build_object('checked_at', p_now, 'warnings', out);
end $function$;
revoke all on function fabula.device_watch(timestamptz) from public, anon, authenticated;

-- ============================== Configurazione → Dispositivi ==============================
create or replace function fabula.device_list() returns jsonb
language plpgsql stable security definer set search_path = fabula, public as $$
declare v_live text := fabula.live_app_version();
begin
  if not fabula.can('sistema', 1) then raise exception using errcode = '42501', message = 'Il tuo profilo non vede i dispositivi'; end if;
  return jsonb_build_object('can_edit', fabula.can('sistema', 3), 'live_version', v_live, 'devices', coalesce((
    select jsonb_agg(jsonb_build_object(
             'device_uid', d.device_uid, 'label', d.label, 'named', d.named_at is not null, 'name', fabula._device_name(d.device_uid),
             'floor', d.floor, 'kind', fabula._device_kind(d.user_agent), 'staff', s.full_name, 'app_version', d.app_version,
             'latest', case when fabula._app_ver_num(v_live) is not null then coalesce(fabula._app_ver_num(d.app_version) >= fabula._app_ver_num(v_live), false) end,
             'queue_len', d.queue_len, 'failed_len', d.failed_len, 'first_seen_at', d.first_seen_at, 'last_seen_at', d.last_seen_at,
             'named_at', d.named_at, 'named_by', nb.full_name)
           order by d.floor desc, d.last_seen_at desc nulls last)
      from fabula.devices d left join fabula.staff s on s.id = d.staff_id left join fabula.staff nb on nb.id = d.named_by), '[]'::jsonb));
end $$;
revoke all on function fabula.device_list() from public, anon;
grant execute on function fabula.device_list() to authenticated;

-- a device is named (and marked as a floor tablet or not) by the titolare or a socio; the change goes to «Registro modifiche»
create or replace function fabula.set_device(p_device_uid text, p_label text, p_floor boolean) returns jsonb
language plpgsql security definer set search_path = fabula, public as $$
declare o fabula.devices; n fabula.devices; v_label text := nullif(regexp_replace(btrim(coalesce(p_label, '')), '\s+', ' ', 'g'), '');
        v_sid uuid := fabula.my_staff_id(); v_old_name text;
begin
  if auth.uid() is not null then perform fabula.require_perm('sistema', 3); end if;
  select * into o from fabula.devices where device_uid = p_device_uid for update;
  if o.device_uid is null then raise exception using errcode = 'P0002', message = 'Dispositivo non trovato: ricarica la pagina'; end if;
  if v_label is null or length(v_label) < 2 or length(v_label) > 40 then
    raise exception using errcode = '22023', message = 'Il nome va da 2 a 40 caratteri (es. «Tablet laboratorio», «iPhone di Nick»)';
  end if;
  if exists (select 1 from fabula.devices where device_uid <> p_device_uid and named_at is not null and lower(label) = lower(v_label)) then
    raise exception using errcode = '23505', message = format('«%s» è già il nome di un altro dispositivo: scegline un altro', v_label);
  end if;
  v_old_name := fabula._device_name(p_device_uid);
  begin
    update fabula.devices set label = v_label, floor = coalesce(p_floor, floor), named_at = now(), named_by = v_sid
     where device_uid = p_device_uid returning * into n;
  exception when unique_violation then          -- two people naming two devices the same at the same moment
    raise exception using errcode = '23505', message = format('«%s» è già il nome di un altro dispositivo: scegline un altro', v_label);
  end;
  if o.label is distinct from n.label or o.floor is distinct from n.floor or o.named_at is null then
    insert into fabula.audit_log (table_name, row_key, action, changed, old_data, new_data, actor_staff_id, actor)
    values ('devices', p_device_uid, 'update',
            array_remove(array[case when o.label is distinct from n.label then 'label' end, case when o.floor is distinct from n.floor then 'floor' end], null),
            jsonb_build_object('name', v_old_name, 'label', o.label, 'floor', o.floor),
            jsonb_build_object('name', n.label, 'label', n.label, 'floor', n.floor),
            v_sid, coalesce((select full_name from fabula.staff where id = v_sid), case when auth.uid() is null then 'bot/service' else 'utente' end));
  end if;
  return jsonb_build_object('device_uid', n.device_uid, 'label', n.label, 'floor', n.floor, 'named_at', n.named_at);
end $$;
revoke all on function fabula.set_device(text, text, boolean) from public, anon;
grant execute on function fabula.set_device(text, text, boolean) to authenticated;

-- ============================== the go-live check and the trial's day 1: floor tablets only ==============================
do $mig$
declare
  d text := pg_get_functiondef('fabula.ops_dashboard()'::regprocedure);
  a text := $a$    'tablet_checkin', (select jsonb_build_object('done', count(*) filter (where app_version = fabula.live_app_version() and last_seen_at > now() - interval '2 days') > 0,
        'detail', case when count(*) = 0 then 'No tablet has checked in yet: open the app once on each tablet with Wi-Fi'
                       else count(*) || ' device(s) · ' || count(*) filter (where app_version = fabula.live_app_version()) || ' on the latest app · last seen '
                            || to_char(max(last_seen_at) at time zone 'Europe/Rome', 'DD/MM HH24:MI') end)
        from fabula.devices),
$a$;
  r text := $r$    'tablet_checkin', (select jsonb_build_object(   -- v1.14 (R-04): only the devices marked as floor tablets count
        'done', coalesce(bool_or(dv.floor and dv.last_seen_at > now() - interval '2 days'
                                 and fabula._app_ver_num(dv.app_version) >= fabula._app_ver_num(fabula.live_app_version())), false),
        'detail', case when count(*) filter (where dv.floor) = 0
                         then 'No device is marked as the floor tablet: Configurazione → Utenti e accessi → Dispositivi, tick «Tablet del caseificio» on the one whose code is at the bottom of the tablet''s home screen'
                              || case when count(*) > 0 then ' · ' || count(*) || ' other device(s) checked in, not counted' else '' end
                       else string_agg(dv.label || ' on ' || coalesce(dv.app_version, '?')
                                       || case when fabula._app_ver_num(fabula.live_app_version()) is null then ' (app in line unknown: site check down)'
                                               when fabula._app_ver_num(dv.app_version) >= fabula._app_ver_num(fabula.live_app_version()) then ' (latest)' else ' (old app)' end
                                       || ' · last seen ' || to_char(dv.last_seen_at at time zone 'Europe/Rome', 'DD/MM HH24:MI')
                                       || case when dv.last_seen_at <= now() - interval '2 days' then ' (over 2 days ago: open the app on it)' else '' end, '; ' order by dv.last_seen_at desc) filter (where dv.floor)
                            || case when count(*) filter (where not dv.floor) > 0 then ' · ' || count(*) filter (where not dv.floor) || ' other device(s) not counted' else '' end end)
        from fabula.devices dv),
$r$;
begin
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'v114a: ops_dashboard tablet_checkin anchor not found exactly once'; end if;
  execute replace(d, a, r);

  d := pg_get_functiondef('fabula.trial_check(date)'::regprocedure);
  a := $a$    select count(*) into a from fabula.devices where last_seen_at >= v_from and app_version = fabula.live_app_version();
    steps := steps || jsonb_build_object('step', 'Giorno 1 · tablet di produzione collegato, app aggiornata', 'ok', a > 0, 'detail', a || ' dispositivi oggi');
$a$;
  r := $r$    select count(*), string_agg(label, ', ' order by label) into a, t from fabula.devices   -- v1.14 (R-04): floor tablets only
     where floor and last_seen_at >= v_from and fabula._app_ver_num(app_version) >= fabula._app_ver_num(fabula.live_app_version());
    steps := steps || jsonb_build_object('step', 'Giorno 1 · tablet di produzione collegato, app aggiornata', 'ok', a > 0,
             'detail', case when a > 0 then t || ': collegato, app aggiornata'
                            when not exists (select 1 from fabula.devices where floor) then 'nessun dispositivo segnato come «Tablet del caseificio» (Configurazione → Utenti e accessi → Dispositivi)'
                            else 'il tablet del caseificio non si è collegato con l''ultima app' end);
$r$;
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then raise exception 'v114a: trial_check day-1 anchor not found exactly once'; end if;
  execute replace(d, a, r);
end $mig$;

update fabula.dash_checks
   set label = 'Floor tablet (marked in Configurazione → Dispositivi) checked in on the latest app',
       hint_it = 'Si chiude da solo quando il tablet del caseificio si collega con l''ultima versione. Il tablet si segna una volta: Configurazione → Utenti e accessi → Dispositivi → «Tablet del caseificio» sulla riga con il suo codice (in fondo alla schermata del tablet).',
       updated_at = now()
 where key = 'tablet_checkin';

insert into fabula.security_accepted (key, reason) values
  ('authenticated_security_definer_function_executable:fabula.device_list()', 'by design (v1.14, R-04): Configurazione → Dispositivi, the devices that check in; Sistema ≥ vede'),
  ('authenticated_security_definer_function_executable:fabula.set_device(p_device_uid text, p_label text, p_floor boolean)', 'by design (v1.14, R-04): names a device and marks the floor tablet; Sistema = gestisce, written to the audit log')
on conflict (key) do nothing;

comment on function fabula.set_device(text, text, boolean) is 'v1.14 (R-04, A-35): names a device and marks it as a floor tablet (or not). Sistema = gestisce. Audit: fabula.audit_log, table «devices».';
