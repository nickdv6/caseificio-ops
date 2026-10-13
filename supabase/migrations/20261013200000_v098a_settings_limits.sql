-- v0.98a · Audit 12/10/2026, numbers and limits: the settings (Configurazione → Parametri).
--   C-02 rest  Every number setting has a minimum, a maximum and a unit; a value outside is refused by the database with the
--              setting's name and the allowed range. High-impact settings carry a sentence on what changes; the page asks
--              before saving them, and a change is posted to the bell (Bot → «Configurazione») with who did it.
--   C-03       Choice settings (manual signed/draft, milk pasteurised/raw, tier basis, Shopify stock push) are a list: the
--              database turns «Firmato», «PASTORIZZATO», «Settimana» into the stored value or refuses what is not on the list.
--   D-13       A number written with a comma («1,70») is stored with a dot; a flag accepts sì/no; dates and months are checked.
--              setting_num() no longer breaks every caller on an unreadable value: it falls back to the default.
--   New settings used by v0.98b/c: the possible yield range of a batch (mozzarella and ricotta) and the kg per wholesale delivery
--   above which the portal asks to confirm, or refuses.
-- The format trigger of v0.95b (B2B cut-off, delivery days and windows) runs first; this check runs after it (name order).

-- ============================================================================================================================
-- 1. Columns
-- ============================================================================================================================
alter table fabula.settings add column if not exists min_value numeric,
                            add column if not exists max_value numeric,
                            add column if not exists unit text,
                            add column if not exists options jsonb,
                            add column if not exists impact_it text;
comment on column fabula.settings.min_value is 'v0.98 (audit C-02): lowest value accepted for a number setting (null = no minimum)';
comment on column fabula.settings.max_value is 'v0.98 (audit C-02): highest value accepted for a number setting (null = no maximum)';
comment on column fabula.settings.unit is 'v0.98 (audit C-02): unit shown next to the field in Configurazione (€/kg, %, kg, min…)';
comment on column fabula.settings.options is 'v0.98 (audit C-03): for kind = choice, the allowed values: [{"v": stored value, "l": label}]';
comment on column fabula.settings.impact_it is 'v0.98 (audit C-02): what a change does (high-impact settings only): asked before saving and posted to the bell';
alter table fabula.settings drop constraint if exists settings_kind_check;
alter table fabula.settings add constraint settings_kind_check check (kind in ('flag', 'date', 'month', 'time', 'weekdays', 'choice'));

-- ============================================================================================================================
-- 2. New settings
-- ============================================================================================================================
insert into fabula.settings (key, value, description, data_type, sort) values
  ('prod.yield_min_pct', '10', 'Resa minima possibile di un lotto di mozzarella (%): sotto, la chiusura è rifiutata come errore nei kg', 'number', 100),
  ('prod.yield_max_pct', '45', 'Resa massima possibile di un lotto di mozzarella (%): sopra, la chiusura è rifiutata come errore nei kg', 'number', 100),
  ('prod.ricotta_yield_min_pct', '2', 'Resa minima possibile di un lotto di ricotta sul siero (%): sotto, la chiusura è rifiutata come errore nei kg', 'number', 100),
  ('prod.ricotta_yield_max_pct', '25', 'Resa massima possibile di un lotto di ricotta sul siero (%): sopra, la chiusura è rifiutata come errore nei kg', 'number', 100),
  ('trade.confirm_kg_per_delivery', '25', 'Professionisti: kg per consegna oltre cui il portale chiede di confermare (se sono anche più di 3 volte il solito del cliente)', 'number', 100),
  ('trade.max_kg_per_delivery', '150', 'Professionisti: kg massimi per una consegna dal portale; per di più il cliente chiama il caseificio', 'number', 100)
on conflict (key) do nothing;

-- C-18 (Low, same table): the invite links last 24 hours (Supabase OTP); the repo seed still said 1. Live is already 24.
update fabula.settings set value = '24' where key = 'auth.link_hours' and value = '1';

-- ============================================================================================================================
-- 3. Limits, units, choices and impact. Keys missing from a database are skipped; settings not listed keep no limits.
-- ============================================================================================================================
update fabula.settings s set min_value = v.lo, max_value = v.hi, unit = v.u, impact_it = v.imp
  from (values
    ('approve.auto_delay_min', 5, 1440, 'min', 'Le richieste di routine si approvano da sole dopo questi minuti: con meno tempo puoi non fare in tempo a fermarle.'),
    ('approve.auto_po_max_eur', 0, 1000, '€', 'Gli ordini ai fornitori fino a questo importo si approvano da soli.'),
    ('approve.milk_tolerance_pct', 0, 50, '%', 'I piani latte entro questo scostamento si approvano da soli e la Masseria li vede.'),
    ('approve.promo_max_kg', 0, 200, 'kg', null),
    ('auth.link_hours', 1, 168, 'ore', null),
    ('benchmark.annual_profit_eur', 0, 5000000, '€', null),
    ('dop.consorzio_eur_kg', 0, 1, '€/kg', null),
    ('dop.rina_eur_kg', 0, 1, '€/kg', null),
    ('effluent.disposal_eur_m3', 0, 500, '€/m³', null),
    ('effluent.wash_water_l_per_kg_milk', 0, 20, 'l/kg', null),
    ('effluent.whey_pct_of_milk', 30, 95, '%', null),
    ('energy.eur_per_kwh', 0.01, 2, '€/kWh', null),
    ('energy.gas_eur_smc', 0.1, 10, '€/Smc', null),
    ('energy.sewer_eur_m3', 0, 20, '€/m³', null),
    ('energy.water_eur_m3', 0, 20, '€/m³', null),
    ('farm.default_kg_per_day', 0, 5000, 'kg', null),
    ('food.records_retention_years', 2, 10, 'anni', null),
    ('labor.contract_hours_week', 1, 60, 'ore', null),
    ('labor.hourly_cost_eur', 5, 100, '€/ora', null),
    ('labor.max_shift_hours', 4, 24, 'ore', null),
    ('labor.overtime_daily_hours', 0, 24, 'ore', null),
    ('labor.overtime_premium_pct', 0, 200, '%', null),
    ('milk.capacity_kg', 100, 10000, 'kg', 'Il piano latte non propone mai più di questi kg al giorno.'),
    ('milk.carry_pct', 0, 100, '%', null),
    ('milk.min_run_kg', 0, 5000, 'kg', null),
    ('milk.price_eur_kg', 0.5, 5, '€/kg', 'Cambia il costo di ogni conferimento senza prezzo e tutti i costi al kg.'),
    ('milk.raw_shelf_days', 1, 7, 'giorni', null),
    ('milk.round_kg', 1, 500, 'kg', null),
    ('milk.safety_pct', 0, 100, '%', null),
    ('milk.weight_tolerance_pct', 0, 20, '%', null),
    ('mkt.local_radius_km', 1, 200, 'km', null),
    ('notify.escalate_min', 5, 240, 'min', null),
    ('pickup.cutoff_hour', 0, 23, 'ora', null),
    ('pickup.slot_capacity_orders', 1, 500, 'ordini', null),
    ('pickup.walkin_share_pct', 0, 100, '%', null),
    ('price.retail_moz_eur_kg', 1, 100, '€/kg', null),
    ('price.wholesale_moz_eur_kg', 1, 100, '€/kg', null),
    ('prod.ricotta_yield_pct', 2, 25, '%', null),
    ('prod.vat_kg', 50, 3000, 'kg', 'Il piano di produzione riempie ogni caldaia fino a qui, e il tablet non accetta più di questo +10 % in un lotto.'),
    ('prod.yield_tolerance_pts', 0.5, 20, 'punti %', null),
    ('prod.yield_min_pct', 5, 40, '%', 'Sotto questa resa la chiusura di un lotto di mozzarella è rifiutata.'),
    ('prod.yield_max_pct', 20, 60, '%', 'Sopra questa resa la chiusura di un lotto di mozzarella è rifiutata.'),
    ('prod.ricotta_yield_min_pct', 0.5, 20, '%', 'Sotto questa resa la chiusura di un lotto di ricotta è rifiutata.'),
    ('prod.ricotta_yield_max_pct', 5, 40, '%', 'Sopra questa resa la chiusura di un lotto di ricotta è rifiutata.'),
    ('purchasing.cover_buffer_days', 0, 60, 'giorni', null),
    ('purchasing.default_lead_days', 0, 60, 'giorni', null),
    ('recon.order_days', 1, 60, 'giorni', null),
    ('recon.payout_days', 1, 60, 'giorni', null),
    ('sales.lapsed_days', 1, 365, 'giorni', null),
    ('sales.lead_stale_days', 1, 365, 'giorni', null),
    ('sales.min_active_leads', 0, 1000, 'contatti', null),
    ('sales.research_per_run', 0, 50, 'locali', null),
    ('sales.target_milk_l_day', 0, 20000, 'litri', null),
    ('sales.yield_pct', 10, 45, '%', null),
    ('sell.horizon_days', 0, 14, 'giorni', null),
    ('sell.min_kg_for_promo', 0, 500, 'kg', null),
    ('sell.promo_pct', 0, 90, '%', null),
    ('sell.wholesale_min_kg', 0, 1000, 'kg', null),
    ('ship.min_days_left_online', 0, 30, 'giorni', null),
    ('ship.min_days_left_wholesale', 0, 30, 'giorni', null),
    ('ship.tolerance_pct', 0.5, 50, '%', 'Oltre questo scostamento tra kg ordinati e pesati il tablet chiede conferma prima di spedire.'),
    ('shopify.mix_weight', 0, 1, '', null),
    ('shopify.reserve_kg', 0, 1000, 'kg', null),
    ('trade.confirm_kg_per_delivery', 5, 500, 'kg', null),
    ('trade.horizon_days', 7, 90, 'giorni', null),
    ('trade.max_kg_per_delivery', 10, 2000, 'kg', 'Oltre questi kg in una consegna il portale rifiuta il piano o la modifica.'),
    ('trade.min_order_kg', 0, 100, 'kg', 'Sotto questi kg il portale non accetta il piano o la modifica.'),
    ('trade.payment_terms_days', 0, 120, 'giorni', null),
    ('trade.recurring_discount_pct', 0, 50, '%', 'Sconto su ogni consegna di un piano attivo, per tutti i clienti.'),
    ('trial.days', 1, 30, 'giorni', null)
  ) as v(k, lo, hi, u, imp)
 where s.key = v.k;
update fabula.settings set min_value = 0, max_value = 2000000, unit = '€' where key like 'opex.%' and data_type = 'number' and min_value is null;
-- flags: sì/no; a few switch behaviour for everyone
update fabula.settings set min_value = 0, max_value = 1 where kind = 'flag';
update fabula.settings s set impact_it = v.imp from (values
    ('bots.db_fallback', 'Con «No», quando un bot non parte nessuno fa il suo lavoro (piano latte, ordini, avvisi HACCP).'),
    ('trade.enabled', 'Con «No» il portale professionisti si chiude per tutti i clienti.'),
    ('approve.auto_milk_plan', 'Con «Sì» i piani latte nella norma partono verso la Masseria senza che nessuno li guardi.')
  ) as v(k, imp) where s.key = v.k;
-- choices (C-03): stored values unchanged, the page draws a list
update fabula.settings s set kind = 'choice', options = v.o::jsonb, impact_it = coalesce(v.imp, s.impact_it) from (values
    ('food.manuale_stato', '[{"v":"bozza","l":"Bozza"},{"v":"firmato","l":"Firmato"}]', 'Con «Firmato» i registri HACCP non escono più come bozza: solo dopo la firma di consulente e responsabile.'),
    ('food.milk_process', '[{"v":"pastorizzato","l":"Pastorizzato"},{"v":"crudo","l":"Crudo"}]', 'Decide se la sera viene ricordato il CCP 2 (pastorizzazione) mancante.'),
    ('trade.tier_basis', '[{"v":"delivery","l":"kg della singola consegna"},{"v":"week","l":"kg settimanali del piano"}]', 'Cambia il prezzo di ogni consegna dei professionisti.'),
    ('shopify.push_inventory', '[{"v":"0","l":"Solo report"},{"v":"1","l":"Aggiorna sempre"},{"v":"2","l":"Aggiorna da solo dopo la conta di apertura"}]', 'Con «Aggiorna sempre» le giacenze del database vanno subito su Shopify.')
  ) as v(k, o, imp) where s.key = v.k;

-- what is stored today must already respect the new limits: reported (not changed) if it does not, so the apply never fails on data
do $mig$
declare r record; n int := 0;
begin
  for r in select key, value, min_value, max_value from fabula.settings
            where data_type = 'number' and coalesce(kind, '') <> 'choice'
              and (trim(value) !~ '^[+-]?(\d+(\.\d*)?|\.\d+)$'
                   or (min_value is not null and trim(value)::numeric < min_value) or (max_value is not null and trim(value)::numeric > max_value)) loop
    raise notice 'v098a: % = «%» is outside %–%: fix it in Configurazione → Parametri', r.key, r.value, r.min_value, r.max_value;
    n := n + 1;
  end loop;
  if n > 0 then raise notice 'v098a: % settings to fix (the next save of each will ask for a value within its limits)', n; end if;
end $mig$;

-- ============================================================================================================================
-- 4. The check (after settings_format, which normalises the B2B cut-off and delivery days)
-- ============================================================================================================================
create or replace function fabula.trg_settings_validate() returns trigger language plpgsql set search_path = fabula, public as $$
declare v text := trim(coalesce(new.value, '')); n numeric; k text; lbl text; u text; o jsonb; m text[]; other numeric; r fabula.settings%rowtype;
begin
  -- (an «insert … on conflict do nothing» seed leaves the row as it is; a «do update» is checked by the update that follows)
  if tg_op = 'INSERT' and exists (select 1 from fabula.settings where key = new.key) then return new; end if;
  r := new;
  k := coalesce(r.kind, '');
  lbl := left(coalesce(nullif(regexp_replace(coalesce(r.description, ''), '\s*:.*$', ''), ''), new.key), 90);
  u := coalesce(' ' || nullif(r.unit, ''), '');
  if k in ('time', 'weekdays') then return new; end if;                -- settings_format (v0.95b) has already normalised them
  if k = 'choice' then
    select x into o from jsonb_array_elements(coalesce(r.options, '[]'::jsonb)) x
     where lower(x ->> 'v') = lower(v) or lower(x ->> 'l') = lower(v) limit 1;
    if o is null then
      raise exception '«%»: scegli uno dei valori dell''elenco (%)', lbl,
        (select string_agg(x ->> 'l', ', ') from jsonb_array_elements(coalesce(r.options, '[]'::jsonb)) x) using errcode = '22023';
    end if;
    new.value := o ->> 'v';
    return new;
  end if;
  if k = 'flag' then
    if lower(v) in ('1', 'sì', 'si', 'true', 'vero', 'on') then new.value := '1';
    elsif lower(v) in ('0', 'no', 'false', 'falso', 'off') then new.value := '0';
    else raise exception '«%»: scegli Sì o No', lbl using errcode = '22023'; end if;
    return new;
  end if;
  if k = 'date' then
    if v = '' then new.value := ''; return new; end if;                -- documented as «Vuoto = …»
    m := regexp_match(v, '^(\d{1,2})[/.-](\d{1,2})[/.-](\d{4})$');
    if m is not null then v := m[3] || '-' || lpad(m[2], 2, '0') || '-' || lpad(m[1], 2, '0'); end if;
    begin
      if v !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'x'; end if;
      perform v::date;
    exception when others then
      raise exception '«%»: data non valida «%». Scrivila come 25/01/2027', lbl, new.value using errcode = '22023';
    end;
    new.value := v; return new;
  end if;
  if k = 'month' then
    if v = '' then new.value := ''; return new; end if;
    m := regexp_match(v, '^(\d{4})-(\d{1,2})(?:-\d{1,2})?$');
    if m is null then m := (select array[x[2], x[1]] from regexp_match(v, '^(\d{1,2})[/.-](\d{4})$') x); end if;
    if m is null or m[2]::int not between 1 and 12 then
      raise exception '«%»: mese non valido «%». Scrivilo come 03/2027', lbl, new.value using errcode = '22023';
    end if;
    new.value := m[1] || '-' || lpad(m[2], 2, '0') || '-01'; return new;
  end if;
  if r.data_type <> 'number' then return new; end if;              -- free text
  -- a number: Italian comma accepted («1,70», «1.300,5»), stored with a dot
  v := replace(v, ' ', '');
  if v ~ '^[+-]?\d{1,3}(\.\d{3})+,\d+$' then v := replace(replace(v, '.', ''), ',', '.');
  elsif v ~ '^[+-]?\d+,\d+$' then v := replace(v, ',', '.'); end if;
  if v !~ '^[+-]?(\d+(\.\d*)?|\.\d+)$' then
    raise exception '«%»: scrivi un numero (es. 1,70)%', lbl, case when v = '' then '' else format(', non «%s»', new.value) end using errcode = '22023';
  end if;
  n := v::numeric;
  if (r.min_value is not null and n < r.min_value) or (r.max_value is not null and n > r.max_value) then
    raise exception using errcode = '22023', message = format('«%s»: %s non è possibile: scrivi un valore tra %s e %s. Controlla la virgola.', lbl,
      fabula._it_num(n) || u, coalesce(nullif(fabula._it_num(r.min_value), ''), '…'), coalesce(nullif(fabula._it_num(r.max_value), ''), '…') || u);
  end if;
  -- a minimum and a maximum of the same thing stay in order
  if new.key in ('prod.yield_min_pct', 'prod.ricotta_yield_min_pct') then
    other := fabula.setting_num(replace(new.key, '_min_', '_max_'), null);
    if other is not null and n >= other then
      raise exception using errcode = '22023', message = format('«%s»: %s deve essere più basso del massimo (%s)', lbl, fabula._it_num(n) || u, fabula._it_num(other) || u);
    end if;
  elsif new.key in ('prod.yield_max_pct', 'prod.ricotta_yield_max_pct') then
    other := fabula.setting_num(replace(new.key, '_max_', '_min_'), null);
    if other is not null and n <= other then
      raise exception using errcode = '22023', message = format('«%s»: %s deve essere più alto del minimo (%s)', lbl, fabula._it_num(n) || u, fabula._it_num(other) || u);
    end if;
  end if;
  new.value := v;
  return new;
end $$;
revoke all on function fabula.trg_settings_validate() from public, anon, authenticated;
drop trigger if exists settings_validate on fabula.settings;
create trigger settings_validate before insert or update of value on fabula.settings for each row execute function fabula.trg_settings_validate();

-- a change to a high-impact setting goes to the bell, with who made it (the Registro modifiche keeps every change anyway)
create or replace function fabula.trg_settings_impact_notice() returns trigger language plpgsql security definer set search_path = fabula, public as $$
declare v_who text; lbl text := left(coalesce(nullif(regexp_replace(coalesce(new.description, ''), '\s*:.*$', ''), ''), new.key), 90);
        u text := coalesce(' ' || nullif(new.unit, ''), ''); fmt text;
begin
  if new.impact_it is null or old.value is not distinct from new.value then return null; end if;
  select full_name into v_who from fabula.staff where id = fabula.my_staff_id();
  -- a migration or the SQL editor (no request): nothing to report; a bot through the API is «Un bot o il sistema»
  if v_who is null and coalesce(nullif(current_setting('request.jwt.claims', true), ''), nullif(current_setting('request.jwt.claim.role', true), '')) is null then return null; end if;
  fmt := case when new.kind = 'flag' then 'flag' when new.kind = 'choice' then 'choice' else 'num' end;
  begin
    perform fabula.post_bot_message('configurazione', 'warn', left(format('Parametro cambiato: %s', lbl), 70),
      format(E'%s ha cambiato «%s»: %s → %s.\n%s\n\nSe non era voluto, rimettilo da Configurazione → Parametri (il valore di prima è nel Registro modifiche).',
             coalesce(v_who, 'Un bot o il sistema'), lbl,
             case fmt when 'flag' then case when old.value = '1' then 'Sì' else 'No' end
                      when 'choice' then coalesce((select x ->> 'l' from jsonb_array_elements(new.options) x where x ->> 'v' = old.value limit 1), old.value)
                      else coalesce(fabula._it_num(nullif(old.value, '')::numeric) || u, old.value) end,
             case fmt when 'flag' then case when new.value = '1' then 'Sì' else 'No' end
                      when 'choice' then coalesce((select x ->> 'l' from jsonb_array_elements(new.options) x where x ->> 'v' = new.value limit 1), new.value)
                      else coalesce(fabula._it_num(nullif(new.value, '')::numeric) || u, new.value) end,
             new.impact_it), null);
  exception when others then raise warning 'settings impact notice %: %', new.key, sqlerrm;   -- never blocks the save
  end;
  return null;
end $$;
revoke all on function fabula.trg_settings_impact_notice() from public, anon, authenticated;
drop trigger if exists settings_impact_notice on fabula.settings;
create trigger settings_impact_notice after update of value on fabula.settings for each row execute function fabula.trg_settings_impact_notice();

-- ============================================================================================================================
-- 5. D-13: an unreadable stored value no longer breaks every caller — they get their default
-- ============================================================================================================================
create or replace function fabula.setting_num(p_key text, p_default numeric) returns numeric language sql stable set search_path = fabula, public as $$
  select coalesce((select case when trim(value) ~ '^[+-]?(\d+(\.\d*)?|\.\d+)$' then trim(value)::numeric end from fabula.settings where key = p_key), p_default) $$;
