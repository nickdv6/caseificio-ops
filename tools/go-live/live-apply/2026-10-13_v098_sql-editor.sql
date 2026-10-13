-- v0.98a–c for the Supabase dashboard SQL Editor (13/10/2026): numbers and limits, from the 12/10 audit.
--   v0.98a  C-02/C-03/D-13 settings: limits, units, lists, high-impact changes to the bell, Italian commas, setting_num never breaks
--   v0.98b  D-06 batch yield and vat size + correct_batch_milk · D-07 milk: the database rejects, physical limits · D-27/B-14 recipe
--           doses ×2 need a confirmation and a reason · D-20 units and recipe items · D-19 dosing · D-18 goods receipt · FARM-07
--   v0.98c  TRADE-01 wholesale quantities (step, maximum, «Confermi?») · D-23 reserved prices and tiers
-- Same files as supabase/migrations/20261013200000_* … 20261013200200_* (built by make_v098_script.py).
-- One transaction: if any step fails nothing changes. It records the three versions in the migration history and refuses a second run.
-- Paste everything, Run, and check the last result shows 20261013200200, 20261013200100 and 20261013200000 at the top.
-- AFTER this: deploy the site (git pull/push of branch v098-numbers; the tablet then sends the milk correction, the pack lot and
-- the confirmations the database now asks for).
begin;
do $chk$ begin
  if exists (select 1 from supabase_migrations.schema_migrations where version in ('20261013200000', '20261013200100', '20261013200200')) then
    raise exception 'STOP: v0.98 is already in the migration history — nothing to do';
  end if;
  if (select max(version) from supabase_migrations.schema_migrations) <> '20261013160932' then
    raise exception 'STOP: the live history does not end at 20261013160932 (golive_badges_check_20261013) — tell Claude before applying';
  end if;
end $chk$;

-- ======================= v098a =======================
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

-- ======================= v098b =======================
-- v0.98b · Audit 12/10/2026, numbers and limits: production, milk, recipes, dosing, goods receipt, farm page.
--   D-06   A batch's yield must be possible (mozzarella 10–45 %, ricotta 2–25 %, settings prod.*yield_min/max_pct). Above the
--          maximum it is refused («Resa 200 %: impossibile… controlla i kg»); below the minimum it needs the reason of the loss.
--          The milk in a vat is at most the vat (prod.vat_kg) + 10 %; the whey for ricotta at most 95 % of the vat it came from
--          (D-30). correct_batch_milk() fixes the milk kg of a lot (with a reason), the milk it took and the raw-milk stock, so a
--          wrong start is not a dead end at the close.
--   D-07   Milk arrival: the database rejects milk over the CCP 1a limit itself (the tablet only shows it); temperature, kg, fat,
--          protein, pH and cells have physical limits, with Italian messages on the tablet.
--   D-27 / B-14  A recipe dose changed more than 2 times up or down needs an explicit confirmation and a reason; 0 is refused.
--          A same-day change keeps the previous value in the notes.
--   D-20   Units are written one way (kg, g, l, ml, pz or the name of the pack); an item in a recipe cannot change unit, be
--          archived or stop being counted until the recipe stops using it.
--   D-19   Dosing: a negative dose is refused; more than 3 times or under a third of the recipe needs a confirmation; the lot of
--          the pack used (rennet, cultures, salt) is kept; a closed batch takes no more doses.
--   D-18   Goods receipt: expired goods are refused; more than 3 times what is still to arrive, or a DDT price outside ±50 % of the
--          list, needs a confirmation.
--   FARM-07 The farm page gets the CCP 1a limits (alert and rejection) to warn before shipping.
-- Every «needs a confirmation» is an error with HINT 'confirm': the tablet and the console ask, then send p_confirm = true.

-- ============================================================================================================================
-- 1. D-06 / D-30 · bounds on a batch
-- ============================================================================================================================
alter table fabula.production_batches add column if not exists yield_note text;
comment on column fabula.production_batches.yield_note is 'v0.98 (audit D-06): why a yield is below prod.yield_min_pct (part of the batch lost)';

create or replace function fabula.trg_batch_bounds() returns trigger language plpgsql set search_path = fabula, public as $$
declare v_whey boolean := new.input_kind = 'whey'; v_vat numeric; v_par record; v_y numeric; v_lo numeric; v_hi numeric; v_what text;
begin
  if coalesce(new.source, '') in ('simulation', 'test') then return new; end if;
  if tg_op = 'INSERT' or new.milk_in_kg is distinct from old.milk_in_kg then
    if not v_whey then
      v_vat := fabula.setting_num('prod.vat_kg', null);
      if v_vat is not null and new.milk_in_kg > v_vat * 1.1 then
        raise exception using errcode = '23514', message = format(
          'Latte in caldaia %s kg: una caldaia ne tiene al massimo %s kg (Latte per lotto %s kg, +10 %%). Controlla i kg (senza punto: 310, non 3.100).',
          fabula._it_num(new.milk_in_kg), fabula._it_num(round(v_vat * 1.1)), fabula._it_num(v_vat));
      end if;
    elsif new.parent_batch_id is not null then
      select batch_lot, milk_in_kg into v_par from fabula.production_batches where id = new.parent_batch_id;
      if v_par.milk_in_kg is not null and new.milk_in_kg > v_par.milk_in_kg * 0.95 then
        raise exception using errcode = '23514', message = format('Siero per la ricotta %s kg: non può superare il latte della caldaia %s (%s kg). Controlla i kg.',
          fabula._it_num(new.milk_in_kg), v_par.batch_lot, fabula._it_num(v_par.milk_in_kg));
      end if;
    end if;
  end if;
  if new.output_kg is not null and new.milk_in_kg > 0
     and (tg_op = 'INSERT' or new.output_kg is distinct from old.output_kg or new.milk_in_kg is distinct from old.milk_in_kg) then
    v_y := round(new.output_kg / new.milk_in_kg * 100, 1);
    if v_whey then v_lo := fabula.setting_num('prod.ricotta_yield_min_pct', 2); v_hi := fabula.setting_num('prod.ricotta_yield_max_pct', 25); v_what := 'siero';
    else v_lo := fabula.setting_num('prod.yield_min_pct', 10); v_hi := fabula.setting_num('prod.yield_max_pct', 45); v_what := 'latte'; end if;
    if v_y > v_hi then
      raise exception using errcode = '23514', message = format(
        'Resa %s %%: impossibile (al massimo %s %%). Controlla i kg di %s (%s) e i kg prodotti (%s).',
        fabula._it_num(v_y), fabula._it_num(v_hi), v_what, fabula._it_num(new.milk_in_kg), fabula._it_num(new.output_kg));
    end if;
    if v_y < v_lo and length(trim(coalesce(new.yield_note, ''))) < 3 then
      raise exception using errcode = '23514', message = format(
        'Resa %s %%: troppo bassa per un lotto normale (di solito almeno %s %%). Controlla i kg di %s (%s) e i kg prodotti (%s); se una parte è andata persa, scrivi cosa è successo.',
        fabula._it_num(v_y), fabula._it_num(v_lo), v_what, fabula._it_num(new.milk_in_kg), fabula._it_num(new.output_kg));
    end if;
  end if;
  return new;
end $$;
revoke all on function fabula.trg_batch_bounds() from public, anon, authenticated;
drop trigger if exists batch_yield_bounds on fabula.production_batches;
create trigger batch_yield_bounds before insert or update of milk_in_kg, output_kg, yield_note on fabula.production_batches
  for each row execute function fabula.trg_batch_bounds();

-- the yield note can be written at the close like the other close fields (the closed-lot guard of v0.96 lists what may change)
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.trg_batch_closed_guard()'::regprocedure);
  n := replace(d, $s$'hold_released_by_id','hold_at','yield_expected_pct','yield_flag',$s$, $s$'hold_released_by_id','hold_at','yield_expected_pct','yield_flag','yield_note',$s$);
  if n = d then raise exception 'v098b: trg_batch_closed_guard free list not found'; end if;
  execute n;
end $mig$;

-- the milk of a lot was typed wrong (31 for 310): fixed with a reason, together with the milk it took and the raw-milk stock
create or replace function fabula.correct_batch_milk(p_batch_lot text, p_milk_kg numeric, p_reason text, p_staff_id uuid default null, p_yield_note text default null)
returns jsonb language plpgsql security definer set search_path = fabula, public as $$
-- the person who corrects is the operator the tablet sends (the shared login is the device's: audit A-01), if active
declare b fabula.production_batches%rowtype; v_name text; v_when text; v_own boolean; n int; i record; v_lot text; v_raw uuid;
        v_by uuid := coalesce((select id from fabula.staff where id = p_staff_id and active), fabula.my_staff_id());
begin
  if length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'Scrivi il motivo della correzione (es. errore di battitura)' using errcode = '22023'; end if;
  if p_milk_kg is null or p_milk_kg <= 0 then raise exception 'Scrivi i kg giusti' using errcode = '22023'; end if;
  select * into b from fabula.production_batches where batch_lot = upper(trim(p_batch_lot)) for update;
  if b.id is null then raise exception 'Lotto sconosciuto: %', p_batch_lot using errcode = '22023'; end if;
  -- an open lot: whoever produces (it is being closed); a closed one: its casaro within 15 minutes, else the production manager
  v_own := b.output_kg is null or (b.casaro_id = v_by and coalesce(b.finished_at, b.created_at) > now() - interval '15 minutes');
  perform fabula.require_perm('produzione', case when v_own then 2 else 3 end);
  if p_milk_kg = b.milk_in_kg then return jsonb_build_object('ok', true, 'batch_lot', b.batch_lot, 'milk_in_kg', b.milk_in_kg, 'unchanged', true); end if;
  select full_name into v_name from fabula.staff where id = v_by;
  v_when := to_char(now() at time zone 'Europe/Rome', 'DD/MM HH24:MI');
  perform set_config('fabula.correct_ctx', 'on', true);
  if b.input_kind = 'milk' then
    select count(*) into n from fabula.batch_milk_inputs where batch_id = b.id;
    if n > 1 then raise exception 'Il lotto % usa il latte di % consegne: per correggere i kg chiama il responsabile produzione', b.batch_lot, n using errcode = '22023'; end if;
    if n = 1 then
      select * into i from fabula.batch_milk_inputs where batch_id = b.id;
      update fabula.batch_milk_inputs set qty_kg = p_milk_kg where batch_id = b.id and milk_intake_id = i.milk_intake_id;   -- batch_milk_left checks what is left
      select milk_lot into v_lot from fabula.milk_intake where id = i.milk_intake_id;
      select id into v_raw from fabula.products where sku = 'RAW-MILK';
      if v_raw is not null then
        insert into fabula.stock_moves (product_id, lot_number, qty, move_type, reason, source)
        values (v_raw, v_lot, i.qty_kg - p_milk_kg, 'adjustment', format('Correzione kg in caldaia lotto %s: %s', b.batch_lot, trim(p_reason)), 'tablet');
      end if;
    end if;
  end if;
  update fabula.production_batches
     set milk_in_kg = p_milk_kg, yield_note = coalesce(nullif(trim(p_yield_note), ''), yield_note),
         notes = concat_ws(E'\n', notes, format('[%s] %s in caldaia corretto da %s: %s → %s kg (%s)', v_when, case when b.input_kind = 'whey' then 'siero' else 'latte' end,
                                                coalesce(v_name, 'utente'), fabula._it_num(b.milk_in_kg), fabula._it_num(p_milk_kg), trim(p_reason)))
   where id = b.id;
  perform set_config('fabula.correct_ctx', '', true);
  insert into fabula.record_corrections (table_name, row_id, changes, reason, corrected_by_id, corrected_by)
  values ('production_batches', b.id, jsonb_build_object('milk_in_kg', jsonb_build_array(b.milk_in_kg, p_milk_kg)), trim(p_reason), v_by, v_name);
  return jsonb_build_object('ok', true, 'batch_lot', b.batch_lot, 'milk_in_kg', p_milk_kg, 'was_kg', b.milk_in_kg);
end $$;
revoke all on function fabula.correct_batch_milk(text, numeric, text, uuid, text) from public, anon;
grant execute on function fabula.correct_batch_milk(text, numeric, text, uuid, text) to authenticated, service_role;

-- a closed lot corrected to a low yield («Correggi» in Autocontrollo) can say what was lost
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.correct_record(text,uuid,jsonb,text,uuid)'::regprocedure);
  n := replace(d, $s$when 'production_batches' then array['output_kg','curd_ph','whey_kg']$s$,
                  $s$when 'production_batches' then array['output_kg','curd_ph','whey_kg','yield_note']$s$);
  n := replace(n, $s$           whey_kg = case when p_changes ? 'whey_kg' then (p_changes ->> 'whey_kg')::numeric else whey_kg end,$s$,
                  $s$           whey_kg = case when p_changes ? 'whey_kg' then (p_changes ->> 'whey_kg')::numeric else whey_kg end,
           yield_note = case when p_changes ? 'yield_note' then nullif(trim(p_changes ->> 'yield_note'), '') else yield_note end,   -- v0.98 (D-06)$s$);
  if position('''yield_note'']' in n) = 0 or position('yield_note = case when p_changes' in n) = 0 then raise exception 'v098b: correct_record patterns not found'; end if;
  execute n;
end $mig$;

-- the tablet sends it in the same atomic save as the close (offline too)
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.save_ops(jsonb,uuid,timestamptz,timestamptz)'::regprocedure);
  n := replace(d, $s$'log_batch_step','record_batch_consumable','log_milk_check','badge_in','badge_out'];$s$,
                  $s$'log_batch_step','record_batch_consumable','log_milk_check','badge_in','badge_out','correct_batch_milk'];$s$);
  n := replace(n, $s$when 'badge_out' then 'fine turno' else v_label end;$s$,
                  $s$when 'badge_out' then 'fine turno' when 'correct_batch_milk' then 'correzione dei kg in caldaia' else v_label end;$s$);
  if position('''correct_batch_milk''];' in n) = 0 or position('correzione dei kg in caldaia' in n) = 0 then raise exception 'v098b: save_ops patterns not found'; end if;
  execute n;
end $mig$;

-- ============================================================================================================================
-- 2. D-07 · milk arrival: the database decides the rejection, and readings have physical limits
-- ============================================================================================================================
create or replace function fabula.trg_milk_accept_decide() returns trigger language plpgsql set search_path = fabula, public as $$
declare v_max numeric;
begin
  if new.accepted is false or new.temperature_c is null then return new; end if;
  select max_value into v_max from fabula.haccp_control_points where code = 'CCP-MILK-TEMP' and active;
  if v_max is not null and new.temperature_c > v_max then
    new.accepted := false;
    new.rejection_reason := concat_ws(' · ', nullif(new.rejection_reason, ''),
      format('temperatura %s °C oltre il limite di %s °C', fabula._it_num(new.temperature_c), fabula._it_num(v_max)));
  end if;
  return new;
end $$;
revoke all on function fabula.trg_milk_accept_decide() from public, anon, authenticated;
drop trigger if exists milk_intake_accept_decide on fabula.milk_intake;
create trigger milk_intake_accept_decide before insert on fabula.milk_intake for each row execute function fabula.trg_milk_accept_decide();

do $mig$
declare c record;
begin
  for c in select * from (values
      ('milk_intake_temperature_range', 'temperature_c is null or temperature_c between -2 and 45', 'Temperatura del latte impossibile: si legge tra −2 e 45 °C. Controlla la virgola (4,5 non 45).'),
      ('milk_intake_qty_max', 'qty_kg <= 5000', 'Più di 5.000 kg di latte in una consegna: controlla i kg (scrivili senza punto: 1200).'),
      ('milk_intake_fat_range', 'fat_pct is null or fat_pct between 3 and 15', 'Grasso del latte impossibile: tra il 3 e il 15 %. Controlla la virgola.'),
      ('milk_intake_protein_range', 'protein_pct is null or protein_pct between 2 and 8', 'Proteine del latte impossibili: tra il 2 e l''8 %. Controlla la virgola.'),
      ('milk_intake_ph_range', 'ph is null or ph between 5.5 and 7.5', 'pH del latte impossibile: tra 5,5 e 7,5. Controlla la virgola.'),
      ('milk_intake_scc_range', 'scc_cells_ml is null or scc_cells_ml between 0 and 10000000', 'Cellule somatiche impossibili: tra 0 e 10.000.000 per ml.')
    ) v(name, expr, msg) loop
    if not exists (select 1 from pg_constraint where conname = c.name and conrelid = 'fabula.milk_intake'::regclass) then
      execute format('alter table fabula.milk_intake add constraint %I check (%s) not valid', c.name, c.expr);
      begin
        execute format('alter table fabula.milk_intake validate constraint %I', c.name);
      exception when check_violation then
        raise notice 'v098b: some milk deliveries are outside «%»: new ones are checked, old ones stay as they are', c.name;
      end;
    end if;
    execute format('comment on constraint %I on fabula.milk_intake is %L', c.name, c.msg);
  end loop;
end $mig$;

-- ============================================================================================================================
-- 3. D-27 / B-14 · recipe doses
-- ============================================================================================================================
drop function if exists fabula.update_recipe_dose(uuid, numeric, boolean, text, integer, text);
create or replace function fabula.update_recipe_dose(p_recipe_id uuid, p_qty numeric, p_round_up boolean default null, p_instruction text default null,
                                                     p_step_order integer default null, p_notes text default null, p_confirm boolean default false)
returns uuid language plpgsql set search_path = fabula, public, extensions as $$
declare r fabula.recipes%rowtype; v_id uuid; d date := (now() at time zone 'Europe/Rome')::date; v_ratio numeric; v_comp text; v_unit text; v_log text;
begin
  select * into r from fabula.recipes where id = p_recipe_id;
  if r.id is null then raise exception 'Ricetta non trovata' using errcode = '22023'; end if;
  if p_qty is null or p_qty <= 0 then raise exception 'Dose non valida: scrivi una quantità maggiore di zero (per togliere il componente usa «Togli»)' using errcode = '22023'; end if;
  select name, unit into v_comp, v_unit from fabula.products where id = r.component_product_id;
  -- v0.98 (audit D-27/B-14): 2 times up or down is almost always a comma or a zero too many: it needs a confirmation and a reason
  if r.qty_per_unit > 0 and p_qty <> r.qty_per_unit then
    v_ratio := p_qty / r.qty_per_unit;
    if (v_ratio > 2 or v_ratio < 0.5) and not coalesce(p_confirm, false) then
      raise exception using errcode = '22023', hint = 'confirm', message = format(
        '%s: la dose passa da %s a %s %s, %s volte %s. Controlla la virgola; se è giusto conferma e scrivi il motivo.', v_comp,
        fabula._it_num(r.qty_per_unit), fabula._it_num(p_qty), v_unit, fabula._it_num(round(case when v_ratio >= 1 then v_ratio else 1 / v_ratio end, 1)),
        case when v_ratio >= 1 then 'di più' else 'di meno' end);
    end if;
    if (v_ratio > 2 or v_ratio < 0.5) and length(trim(coalesce(p_notes, ''))) < 3 then
      raise exception 'Scrivi il motivo di una dose cambiata così tanto (%)', v_comp using errcode = '22023';
    end if;
  end if;
  v_log := case when p_qty <> r.qty_per_unit then format('[%s] dose %s → %s%s', to_char(now() at time zone 'Europe/Rome', 'DD/MM HH24:MI'),
                fabula._it_num(r.qty_per_unit), fabula._it_num(p_qty), coalesce(': ' || nullif(trim(p_notes), ''), '')) end;
  if r.valid_from >= d then
    -- a change on the same day overwrites the row: the previous dose stays in the notes (and in the Registro modifiche)
    update fabula.recipes set qty_per_unit = p_qty, round_up = coalesce(p_round_up, round_up),
           instruction_it = case when p_instruction is null then instruction_it else nullif(btrim(p_instruction), '') end,
           step_order = coalesce(p_step_order, step_order), notes = concat_ws(E'\n', nullif(notes, ''), v_log), source = 'console'
     where id = r.id;
    return r.id;
  end if;
  update fabula.recipes set valid_to = d - 1 where id = r.id;
  insert into fabula.recipes (finished_product_id, component_product_id, basis, qty_per_unit, round_up, valid_from, source, notes, phase, step_order, instruction_it)
  values (r.finished_product_id, r.component_product_id, r.basis, p_qty, coalesce(p_round_up, r.round_up), d, 'console', concat_ws(E'\n', nullif(r.notes, ''), v_log),
          r.phase, coalesce(p_step_order, r.step_order), case when p_instruction is null then r.instruction_it else nullif(btrim(p_instruction), '') end)
  returning id into v_id;
  return v_id;
end $$;
revoke all on function fabula.update_recipe_dose(uuid, numeric, boolean, text, integer, text, boolean) from public, anon;
grant execute on function fabula.update_recipe_dose(uuid, numeric, boolean, text, integer, text, boolean) to authenticated, service_role;

do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.add_recipe_component(text,text,fabula.recipe_basis,numeric,boolean,text,integer,text)'::regprocedure);
  n := replace(d, $s$  if p_phase not in ('start','close') then raise exception 'Fase non valida (start | close)'; end if;$s$,
                  $s$  if p_phase not in ('start','close') then raise exception 'Fase non valida (start | close)'; end if;
  if p_qty is null or p_qty <= 0 then raise exception 'Scrivi la dose: una quantità maggiore di zero' using errcode = '22023'; end if;   -- v0.98 (audit D-27)$s$);
  if n = d then raise exception 'v098b: add_recipe_component pattern not found'; end if;
  execute n;
end $mig$;

-- ============================================================================================================================
-- 4. D-20 · units written one way; an item in a recipe keeps its unit and stays active and counted
-- ============================================================================================================================
create or replace function fabula._unit_norm(p text) returns text language sql immutable set search_path = fabula, public as $$
  select case lower(trim(coalesce(p, '')))
           when 'litri' then 'l' when 'litro' then 'l' when 'lt' then 'l' when 'lt.' then 'l' when 'l.' then 'l'
           when 'millilitri' then 'ml' when 'ml.' then 'ml'
           when 'grammi' then 'g' when 'gr' then 'g' when 'gr.' then 'g' when 'g.' then 'g'
           when 'chili' then 'kg' when 'chilo' then 'kg' when 'kilo' then 'kg' when 'kg.' then 'kg'
           when 'pezzi' then 'pz' when 'pezzo' then 'pz' when 'pz.' then 'pz' when 'pc' then 'pz'
           else lower(trim(coalesce(p, ''))) end $$;
create or replace function fabula.trg_products_guard() returns trigger language plpgsql set search_path = fabula, public as $$
declare v_rec text;
begin
  -- a new item, or a unit that really changes: written one way; an old item keeps its unit as it is when only other fields change
  if tg_op = 'INSERT' or fabula._unit_norm(new.unit) is distinct from fabula._unit_norm(old.unit) then
    new.unit := fabula._unit_norm(new.unit);
    if new.unit !~ '^[a-zàèéìòù]{1,12}$' then
      raise exception 'Unità non valida «%»: usa kg, g, l, ml, pz o il nome della confezione (conf, rotolo, scatola…)', new.unit using errcode = '22023';
    end if;
  else
    new.unit := old.unit;
  end if;
  if tg_op = 'UPDATE' and (fabula._unit_norm(new.unit) is distinct from fabula._unit_norm(old.unit) or (old.active and not new.active) or (old.track_stock and not new.track_stock)) then
    select string_agg(distinct f.name, ', ') into v_rec from fabula.recipes r join fabula.products f on f.id = r.finished_product_id
     where r.component_product_id = new.id and (r.valid_to is null or r.valid_to >= (now() at time zone 'Europe/Rome')::date);
    if v_rec is not null then
      raise exception '«%» è nella ricetta di %: prima toglilo dalla ricetta o cambia le dosi in Console → Ricette (le dosi sono in %)', new.name, v_rec, old.unit using errcode = '23514';
    end if;
  end if;
  return new;
end $$;
revoke all on function fabula.trg_products_guard() from public, anon, authenticated;
update fabula.products set unit = fabula._unit_norm(unit) where unit is distinct from fabula._unit_norm(unit) and fabula._unit_norm(unit) ~ '^[a-zàèéìòù]{1,12}$';
do $mig$ declare r record; begin
  for r in select sku, unit from fabula.products where fabula._unit_norm(unit) !~ '^[a-zàèéìòù]{1,12}$' loop
    raise notice 'v098b: % has the unit «%»: it stays, a new unit for it must be a word (kg, l, pz, conf…)', r.sku, r.unit;
  end loop; end $mig$;
drop trigger if exists products_guard on fabula.products;
create trigger products_guard before insert or update of unit, active, track_stock on fabula.products for each row execute function fabula.trg_products_guard();

-- ============================================================================================================================
-- 5. D-19 · dosing
-- ============================================================================================================================
do $mig$ begin
  if not exists (select 1 from pg_constraint where conname = 'batch_consumables_qty_nonneg') then
    alter table fabula.batch_consumables add constraint batch_consumables_qty_nonneg check (qty >= 0) not valid;
    begin alter table fabula.batch_consumables validate constraint batch_consumables_qty_nonneg;
    exception when check_violation then raise notice 'v098b: some old doses are negative: new ones are checked'; end;
  end if;
end $mig$;
comment on constraint batch_consumables_qty_nonneg on fabula.batch_consumables is 'Quantità dosata negativa: scrivi la quantità usata (0 se non l''hai messo)';

drop function if exists fabula.record_batch_consumable(text, text, numeric, numeric, uuid);
create or replace function fabula.record_batch_consumable(p_batch_lot text, p_sku text, p_qty numeric, p_qty_standard numeric, p_staff_id uuid default null,
                                                          p_lot text default null, p_confirm boolean default false)
returns text language plpgsql set search_path = fabula, public, extensions as $$
declare b record; v_comp uuid; v_name text; v_unit text; v_rec uuid; v_lot text := nullif(upper(trim(coalesce(p_lot, ''))), '');
begin
  select * into b from fabula.production_batches where batch_lot = p_batch_lot;
  select id, name, unit into v_comp, v_name, v_unit from fabula.products where sku = p_sku;
  if b is null or v_comp is null then raise exception 'Lotto o SKU sconosciuto: % / %', p_batch_lot, p_sku using errcode = '22023'; end if;
  -- v0.98 (audit D-19)
  if b.output_kg is not null then
    raise exception 'Il lotto % è già chiuso: i dosaggi si registrano prima della chiusura', p_batch_lot using errcode = '22023';
  end if;
  if p_qty is null or p_qty < 0 then raise exception 'Quantità di % non valida: scrivi la quantità usata (0 se non l''hai messo)', v_name using errcode = '22023'; end if;
  if coalesce(p_qty_standard, 0) > 0 and not coalesce(p_confirm, false) and (p_qty > p_qty_standard * 3 or p_qty < p_qty_standard / 3) then
    raise exception using errcode = '22023', hint = 'confirm', message = format('%s: %s %s contro %s previsti dalla ricetta. Controlla la virgola; se è giusto conferma.',
      v_name, fabula._it_num(round(p_qty, 4)), v_unit, fabula._it_num(round(p_qty_standard, 4)));
  end if;
  if exists (select 1 from fabula.batch_consumables where batch_id = b.id and product_id = v_comp) then
    perform fabula.correct_batch_consumable(p_batch_lot, p_sku, p_qty, 'riconferma da tablet');
    update fabula.batch_consumables set confirmed_at = now(), confirmed_by_id = coalesce(p_staff_id, confirmed_by_id),
           qty_standard = coalesce(qty_standard, p_qty_standard), lot_number = coalesce(v_lot, lot_number)
     where batch_id = b.id and product_id = v_comp;
    return 'corrected';
  end if;
  select id into v_rec from fabula.recipes
   where finished_product_id = b.product_id and component_product_id = v_comp
     and valid_from <= b.batch_date and (valid_to is null or valid_to >= b.batch_date)
   order by valid_from desc limit 1;
  insert into fabula.batch_consumables (batch_id, product_id, qty, recipe_id, qty_standard, entry, confirmed_at, confirmed_by_id, lot_number)
  values (b.id, v_comp, p_qty, v_rec, p_qty_standard, case when p_qty = p_qty_standard then 'confirmed' else 'corrected' end, now(), p_staff_id, v_lot);
  insert into fabula.stock_moves (product_id, lot_number, qty, move_type, batch_id, source, reason)
  values (v_comp, v_lot, -p_qty, 'production_in', b.id, 'tablet',
          format('Lotto %s: dosato e confermato %s (ricetta %s)', p_batch_lot, p_qty, p_qty_standard));
  return 'recorded';
end $$;
revoke all on function fabula.record_batch_consumable(text, text, numeric, numeric, uuid, text, boolean) from public, anon;
grant execute on function fabula.record_batch_consumable(text, text, numeric, numeric, uuid, text, boolean) to authenticated, service_role;

-- ============================================================================================================================
-- 6. D-18 · goods receipt
-- ============================================================================================================================
drop function if exists fabula.receive_purchase_order(text, jsonb, uuid, text, text);
create or replace function fabula.receive_purchase_order(p_po_number text, p_lines jsonb, p_staff_id uuid default null, p_ddt text default null,
                                                         p_notes text default null, p_confirm boolean default false)
returns jsonb language plpgsql security definer set search_path = fabula, public as $$
declare po record; l jsonb; pl record; v_rcpt uuid; v_move uuid; v_price numeric; v_list numeric; v_qty numeric; v_exp date; v_left numeric;
        n int := 0; over jsonb := '[]'; price_changes jsonb := '[]'; v_status fabula.po_status; v_received numeric := 0;
        v_today date := (now() at time zone 'Europe/Rome')::date;
begin
  perform fabula.require_perm('magazzino', 2);
  select * into po from fabula.purchase_orders where po_number = p_po_number;
  if po is null then raise exception 'Ordine sconosciuto: %', p_po_number using errcode = '22023'; end if;
  if po.status not in ('approved','sent','partially_received') then raise exception 'Ordine % in stato %: non ricevibile', p_po_number, po.status using errcode = '22023'; end if;
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'Nessuna riga ricevuta' using errcode = '22023'; end if;

  insert into fabula.goods_receipts (purchase_order_id, ddt_number, received_by_id, notes) values (po.id, p_ddt, p_staff_id, p_notes) returning id into v_rcpt;

  for l in select * from jsonb_array_elements(p_lines) loop
    v_qty := (l->>'qty')::numeric;
    continue when v_qty is null or v_qty <= 0;
    select pol.*, p.sku, p.unit, p.name into pl from fabula.purchase_order_lines pol join fabula.products p on p.id = pol.product_id
     where pol.purchase_order_id = po.id and p.sku = l->>'sku' limit 1;
    if pl is null then raise exception 'Riga % non presente nell''ordine %', l->>'sku', p_po_number using errcode = '22023'; end if;
    -- v0.98 (audit D-18): expired goods are not received; ten times the order or a price ten times the list is a typing slip
    v_exp := nullif(l->>'expiry', '')::date;
    if v_exp is not null and v_exp < v_today then
      raise exception '% scaduto il %: non riceverlo, apri una non conformità per il fornitore', pl.name, to_char(v_exp, 'DD/MM/YYYY') using errcode = '22023';
    end if;
    v_left := greatest(pl.qty_ordered - pl.qty_received, 0);
    if v_qty > v_left * 3 and not coalesce(p_confirm, false) then
      raise exception using errcode = '22023', hint = 'confirm', message = format('%s: ricevuti %s %s, ne mancavano %s (ordinati %s). Controlla la quantità; se è giusto conferma.',
        pl.name, fabula._it_num(v_qty), pl.unit, fabula._it_num(v_left), fabula._it_num(pl.qty_ordered));
    end if;
    v_price := coalesce(nullif(l->>'unit_price','')::numeric, pl.unit_price_eur);
    if v_price is not null and v_price < 0 then raise exception 'Prezzo negativo per %', pl.name using errcode = '22023'; end if;
    select price_eur into v_list from fabula.supplier_prices where supplier_id = po.supplier_id and product_id = pl.product_id order by valid_from desc limit 1;
    -- compared with the order's price (what the tablet shows as «listino»), else the supplier's latest price
    if nullif(l->>'unit_price','') is not null and coalesce(nullif(pl.unit_price_eur, 0), v_list) > 0 and not coalesce(p_confirm, false)
       and (v_price > coalesce(nullif(pl.unit_price_eur, 0), v_list) * 1.5 or v_price < coalesce(nullif(pl.unit_price_eur, 0), v_list) * 0.5) then
      raise exception using errcode = '22023', hint = 'confirm', message = format('%s: prezzo sul DDT %s €/%s contro %s €/%s in listino. Controlla la virgola; se è giusto conferma.',
        pl.name, fabula._it_num(v_price), pl.unit, fabula._it_num(coalesce(nullif(pl.unit_price_eur, 0), v_list)), pl.unit);
    end if;
    insert into fabula.stock_moves (product_id, lot_number, expiry_date, qty, move_type, purchase_order_id, unit_cost_eur, source, reason)
    values (pl.product_id, nullif(l->>'lot',''), v_exp, v_qty, 'purchase_receipt', po.id, v_price, 'tablet',
            format('Ricevuto %s %s su ordine %s%s', v_qty, pl.unit, p_po_number, case when p_ddt is not null then ' · DDT ' || p_ddt else '' end))
    returning id into v_move;
    insert into fabula.goods_receipt_lines (receipt_id, po_line_id, product_id, qty_received, supplier_lot, expiry_date, unit_price_eur, stock_move_id)
    values (v_rcpt, pl.id, pl.product_id, v_qty, nullif(l->>'lot',''), v_exp, v_price, v_move);
    update fabula.purchase_order_lines set qty_received = qty_received + v_qty where id = pl.id;

    if pl.qty_received + v_qty > pl.qty_ordered * 1.02 then
      over := over || jsonb_build_object('sku', pl.sku, 'ordered', pl.qty_ordered, 'received_total', pl.qty_received + v_qty);
    end if;
    -- DDT price differs from the latest list price → record it so procurement uses the real one
    if nullif(l->>'unit_price','') is not null and v_list is distinct from v_price then
      insert into fabula.supplier_prices (supplier_id, product_id, price_eur, valid_from, source) values (po.supplier_id, pl.product_id, v_price, v_today, 'ddt');
      price_changes := price_changes || jsonb_build_object('sku', pl.sku, 'from', v_list, 'to', v_price);
    end if;
    n := n + 1; v_received := v_received + v_qty * coalesce(v_price, 0);
  end loop;
  if n = 0 then raise exception 'Nessuna quantità ricevuta' using errcode = '22023'; end if;

  select case when bool_and(qty_received >= qty_ordered) then 'received'::fabula.po_status else 'partially_received'::fabula.po_status end
    into v_status from fabula.purchase_order_lines where purchase_order_id = po.id;
  update fabula.purchase_orders set status = v_status where id = po.id;

  return jsonb_build_object('receipt_id', v_rcpt, 'po_number', p_po_number, 'lines', n, 'value_eur', round(v_received, 2),
                            'po_status', v_status, 'over_delivered', over, 'price_changes', price_changes);
end $$;
revoke all on function fabula.receive_purchase_order(text, jsonb, uuid, text, text, boolean) from public, anon;
grant execute on function fabula.receive_purchase_order(text, jsonb, uuid, text, text, boolean) to authenticated, service_role;

-- ============================================================================================================================
-- 7. FARM-07 · the farm page warns before shipping warm milk
-- ============================================================================================================================
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.farm_milk_orders(text)'::regprocedure);
  n := replace(d, $s$    'orders', (select coalesce(jsonb_agg(jsonb_build_object('plan_date', plan_date, 'milk_kg', milk_kg, 'seen_at', farm_seen_at) order by plan_date), '[]')$s$,
                  $s$    'milk_temp', (select jsonb_build_object('warn_max', warn_max, 'max', max_value) from fabula.haccp_control_points where code = 'CCP-MILK-TEMP' and active limit 1),   -- v0.98 (FARM-07)
    'orders', (select coalesce(jsonb_agg(jsonb_build_object('plan_date', plan_date, 'milk_kg', milk_kg, 'seen_at', farm_seen_at) order by plan_date), '[]')$s$);
  if n = d then raise exception 'v098b: farm_milk_orders pattern not found'; end if;
  execute n;
end $mig$;

-- ============================================================================================================================
-- 8. The definer functions check the caller inside: accepted in the evening security check
-- ============================================================================================================================
insert into fabula.security_accepted (key, reason, accepted_at) values
 ('authenticated_security_definer_function_executable:fabula.correct_batch_milk(p_batch_lot text, p_milk_kg numeric, p_reason text, p_staff_id uuid, p_yield_note text)',
  'by design (v0.98b, audit D-06): require_perm(produzione, 2 on an open lot / 3 on a closed one); reason required; one milk input only', now()),
 ('authenticated_security_definer_function_executable:fabula.receive_purchase_order(p_po_number text, p_lines jsonb, p_staff_id uuid, p_ddt text, p_notes text, p_confirm boolean)',
  'by design (v0.98b, audit D-18): same as before plus p_confirm; require_perm(magazzino, 2) first', now())
on conflict (key) do update set reason = excluded.reason, accepted_at = excluded.accepted_at;
delete from fabula.security_accepted
 where key = 'authenticated_security_definer_function_executable:fabula.receive_purchase_order(p_po_number text, p_lines jsonb, p_staff_id uuid, p_ddt text, p_notes text)';

-- ======================= v098c =======================
-- v0.98c · Audit 12/10/2026, numbers and limits: wholesale (B2B portal and Console → Ingrosso).
--   TRADE-01  A quantity must be a multiple of the product's step (a whole number of Shopify units: 2,5 kg used to be invoiced as
--             3 on Shopify). A delivery that goes up past trade.max_kg_per_delivery is refused for customers («chiama il
--             caseificio»; the dairy's staff are not held to it); one over 3 times the customer's usual for that day (and over
--             trade.confirm_kg_per_delivery) needs a confirmation: the error ends with «Confermi?» (code P0001, relayed by the
--             trade-portal function) and the page sends the same save with confirm = true. Only pages that can answer ask
--             (payload can_confirm: the portal and Console → Ingrosso from v0.98), so an older portal page is never stuck on it.
--   D-23      Reserved prices: above zero and not above the base price («11,50» typed as 1150); minimum and step are whole units
--             (Shopify sells whole pieces); kg per piece 0–25. Tiers: a price above zero and not above the product's reserved
--             price, discounts up to 50 %. trade_price() never returns a price above the list or below zero (D-13).

-- ============================================================================================================================
-- 1. Helpers
-- ============================================================================================================================
-- one line: in the list, at least the minimum, a multiple of the step; returns its kg
create or replace function fabula.trade_qty_check(p_variant text, p_qty numeric) returns numeric
language plpgsql stable set search_path = fabula, public as $$
declare tp fabula.trade_products%rowtype; v_name text;
begin
  select * into tp from fabula.trade_products where variant_id = p_variant and active and trade_price_eur is not null;
  if tp.variant_id is null then raise exception 'Prodotto non in listino: %', p_variant using errcode = '22023'; end if;
  v_name := tp.title || coalesce(' ' || nullif(tp.variant_title, ''), '');
  if p_qty < tp.min_qty then
    raise exception 'Quantità sotto il minimo per %: almeno % %', v_name, fabula._it_num(tp.min_qty), tp.unit_label using errcode = '22023';
  end if;
  if tp.step_qty > 0 and mod(p_qty, tp.step_qty) <> 0 then
    raise exception 'La quantità di % va a multipli di % % (hai scritto %)', v_name, fabula._it_num(tp.step_qty), tp.unit_label, fabula._it_num(p_qty) using errcode = '22023';
  end if;
  return p_qty * tp.kg_per_unit;
end $$;
revoke all on function fabula.trade_qty_check(text, numeric) from public, anon;
grant execute on function fabula.trade_qty_check(text, numeric) to authenticated, service_role;

-- what the current plan delivers on a weekday (kg; 0 = nothing that day)
create or replace function fabula.trade_plan_day_kg(p_customer uuid, p_weekday int) returns numeric
language sql stable set search_path = fabula, public as $$
  select coalesce(sum(l.qty * tp.kg_per_unit), 0)
    from fabula.trade_schedule_lines l
    join fabula.trade_products tp on tp.variant_id = l.variant_id
    join fabula.trade_schedule_days sd on sd.customer_id = l.customer_id and sd.weekday = l.weekday and sd.active
   where l.customer_id = p_customer and l.weekday = p_weekday and l.qty > 0 $$;
revoke all on function fabula.trade_plan_day_kg(uuid, int) from public, anon;
grant execute on function fabula.trade_plan_day_kg(uuid, int) to authenticated, service_role;

-- the customer's usual kg for a weekday: what the current plan has that day, else the plan's average delivery (null = no plan yet)
create or replace function fabula.trade_usual_kg(p_customer uuid, p_weekday int) returns numeric
language sql stable set search_path = fabula, public as $$
  with d as (
    select l.weekday, sum(l.qty * tp.kg_per_unit) kg
      from fabula.trade_schedule_lines l
      join fabula.trade_products tp on tp.variant_id = l.variant_id
      join fabula.trade_schedule_days sd on sd.customer_id = l.customer_id and sd.weekday = l.weekday and sd.active
     where l.customer_id = p_customer and l.qty > 0
     group by l.weekday)
  select coalesce((select kg from d where weekday = p_weekday), (select avg(kg) from d)) $$;
revoke all on function fabula.trade_usual_kg(uuid, int) from public, anon;
grant execute on function fabula.trade_usual_kg(uuid, int) to authenticated, service_role;

-- one delivery that goes up: refused over the maximum (p_max: customers, not the dairy's staff); over 3 times the usual (and over
-- the confirm threshold) it needs confirm = true. p_label names the delivery in the message («Sabato», «Consegna del 14/02»).
create or replace function fabula.trade_day_kg_check(p_label text, p_kg numeric, p_usual numeric, p_confirm boolean, p_max boolean default true) returns void
language plpgsql stable set search_path = fabula, public as $$
declare v_max numeric := fabula.setting_num('trade.max_kg_per_delivery', 150); v_conf numeric := fabula.setting_num('trade.confirm_kg_per_delivery', 25);
begin
  if p_kg is null or p_kg <= 0 then return; end if;
  if coalesce(p_max, true) and p_kg > v_max then
    raise exception '%: % kg. Dal portale si arriva a % kg per consegna: per quantità più grandi chiama il caseificio.',
      p_label, fabula._it_num(round(p_kg, 2)), fabula._it_num(v_max) using errcode = '22023';
  end if;
  if coalesce(p_confirm, false) or p_kg <= greatest(v_conf, coalesce(p_usual, 0) * 3) then return; end if;
  if p_usual > 0 then
    raise exception '%: % kg, più di 3 volte il solito (% kg). Confermi?', p_label, fabula._it_num(round(p_kg, 2)), fabula._it_num(round(p_usual, 2))
      using errcode = 'P0001', hint = 'confirm';
  end if;
  raise exception '%: % kg, è tanto per una consegna. Confermi?', p_label, fabula._it_num(round(p_kg, 2)) using errcode = 'P0001', hint = 'confirm';
end $$;
revoke all on function fabula.trade_day_kg_check(text, numeric, numeric, boolean, boolean) from public, anon;
grant execute on function fabula.trade_day_kg_check(text, numeric, numeric, boolean, boolean) to authenticated, service_role;

-- ============================================================================================================================
-- 2. The weekly plan: every line and every day checked before anything is written
-- ============================================================================================================================
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.trade_save_schedule(uuid,jsonb,text)'::regprocedure);
  n := replace(d, $s$  existed := exists (select 1 from fabula.trade_schedules where customer_id = p_customer);
$s$, $s$  existed := exists (select 1 from fabula.trade_schedules where customer_id = p_customer);
  -- v0.98 (audit TRADE-01): every line a multiple of its step; a day that goes up compared with the plan as it is now is checked
  -- against the maximum (customers only) and the usual («Confermi?» only to a page that can answer it: can_confirm)
  for d, kgd in select dk, (select coalesce(sum(fabula.trade_qty_check(k, (p_payload->'days'->dk->'lines'->>k)::numeric)), 0)
                              from jsonb_object_keys(coalesce(p_payload->'days'->dk->'lines', '{}'::jsonb)) k
                             where coalesce((p_payload->'days'->dk->'lines'->>k)::numeric, 0) > 0)
                  from jsonb_object_keys(coalesce(p_payload->'days', '{}'::jsonb)) dk where dk ~ '^[1-7]$' loop
    if kgd > fabula.trade_plan_day_kg(p_customer, d::int) then
      perform fabula.trade_day_kg_check(initcap(fabula.trade_wd_it(d::int)), kgd, fabula.trade_usual_kg(p_customer, d::int),
                                        coalesce((p_payload->>'confirm')::boolean, false) or not coalesce((p_payload->>'can_confirm')::boolean, false),
                                        p_actor = 'customer');
    end if;
  end loop;
$s$);
  if n = d then raise exception 'v098c: trade_save_schedule pattern not found'; end if;
  execute n;
end $mig$;

-- ============================================================================================================================
-- 3. A one-day change (override): the same checks on the delivery as it would become
-- ============================================================================================================================
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.trade_add_exception(uuid,jsonb,text,boolean)'::regprocedure);
  n := replace(d, $s$    if (p_payload->>'qty')::numeric > 0 and (p_payload->>'qty')::numeric < tp.min_qty then raise exception 'Quantità sotto il minimo (%)', trim_scale(tp.min_qty) using errcode = '22023'; end if;
$s$, $s$    if (p_payload->>'qty')::numeric > 0 and (p_payload->>'qty')::numeric < tp.min_qty then raise exception 'Quantità sotto il minimo (%)', trim_scale(tp.min_qty) using errcode = '22023'; end if;
    -- v0.98 (audit TRADE-01): a multiple of the step, and the day's delivery as it would become within the limits
    if coalesce((p_payload->>'qty')::numeric, 0) < 0 then raise exception 'Quantità non valida' using errcode = '22023'; end if;
    if (p_payload->>'qty')::numeric > 0 then perform fabula.trade_qty_check(tp.variant_id, (p_payload->>'qty')::numeric); end if;
    for dd in select g::date from generate_series(d1, least(d2, d1 + 62), interval '1 day') g loop
      continue when not fabula.trade_is_delivery_day(dd);
      select coalesce(sum(e.kg), 0) into v_kg from fabula.trade_effective_lines(dd) e where e.customer_id = p_customer and e.variant_id <> tp.variant_id;
      v_kg := v_kg + coalesce((p_payload->>'qty')::numeric, 0) * tp.kg_per_unit;
      continue when v_kg <= (select coalesce(sum(e.kg), 0) from fabula.trade_effective_lines(dd) e where e.customer_id = p_customer);   -- only a delivery that goes up
      perform fabula.trade_day_kg_check('Consegna del ' || to_char(dd, 'DD/MM'), v_kg, fabula.trade_usual_kg(p_customer, extract(isodow from dd)::int),
                                        coalesce((p_payload->>'confirm')::boolean, false) or not coalesce((p_payload->>'can_confirm')::boolean, false),
                                        p_actor = 'customer');
    end loop;
$s$);
  if n = d then raise exception 'v098c: trade_add_exception pattern not found'; end if;
  execute n;
end $mig$;

-- ============================================================================================================================
-- 4. D-23 · reserved prices, minimum and step; tiers
-- ============================================================================================================================
create or replace function fabula.trg_trade_product_guard() returns trigger language plpgsql set search_path = fabula, public as $$
declare v_name text := new.title || coalesce(' ' || nullif(new.variant_title, ''), '');
begin
  -- the price only when it is the one changing: the nightly Shopify sync updates the base price and must not be stopped by it
  if new.trade_price_eur is not null and (tg_op = 'INSERT' or new.trade_price_eur is distinct from old.trade_price_eur) then
    if new.trade_price_eur <= 0 then raise exception 'Prezzo riservato di %: scrivi un prezzo maggiore di zero', v_name using errcode = '23514'; end if;
    if new.base_price_eur is not null and new.trade_price_eur > new.base_price_eur then
      raise exception 'Prezzo riservato di % a % €: è più alto del prezzo base (% €). Controlla la virgola (11,50 non 1150).',
        v_name, fabula._it_num(new.trade_price_eur), fabula._it_num(new.base_price_eur) using errcode = '23514';
    end if;
  end if;
  if tg_op = 'INSERT' or new.min_qty is distinct from old.min_qty or new.step_qty is distinct from old.step_qty then
    if new.min_qty <= 0 or new.step_qty <= 0 or new.min_qty <> trunc(new.min_qty) or new.step_qty <> trunc(new.step_qty) then
      raise exception 'Minimo e passo di % vanno in unità intere maggiori di zero: Shopify vende pezzi interi da % kg', v_name, fabula._it_num(new.kg_per_unit) using errcode = '23514';
    end if;
  end if;
  if new.kg_per_unit <= 0 or new.kg_per_unit > 25 then
    raise exception 'kg per pezzo di % impossibili: % (tra 0 e 25; 250 g = 0,25)', v_name, fabula._it_num(new.kg_per_unit) using errcode = '23514';
  end if;
  return new;
end $$;
revoke all on function fabula.trg_trade_product_guard() from public, anon, authenticated;
drop trigger if exists trade_products_guard on fabula.trade_products;
create trigger trade_products_guard before insert or update on fabula.trade_products for each row execute function fabula.trg_trade_product_guard();

create or replace function fabula.trg_trade_tier_guard() returns trigger language plpgsql set search_path = fabula, public as $$
declare v_list numeric;
begin
  if new.price_eur is not null then
    if new.price_eur <= 0 then raise exception 'Prezzo dello scaglione: scrivi un prezzo maggiore di zero' using errcode = '23514'; end if;
    select max(trade_price_eur) into v_list from fabula.trade_products where active and (variant_id = new.variant_id or new.variant_id is null);
    if v_list is not null and new.price_eur > v_list then
      raise exception 'Prezzo dello scaglione % €: è più alto del prezzo riservato (% €), non sarebbe uno sconto. Controlla la virgola.',
        fabula._it_num(new.price_eur), fabula._it_num(v_list) using errcode = '23514';
    end if;
  end if;
  if new.discount_pct is not null and new.discount_pct > 50 then
    raise exception 'Sconto dello scaglione % %%: al massimo il 50 %%. Controlla.', fabula._it_num(new.discount_pct) using errcode = '23514';
  end if;
  return new;
end $$;
revoke all on function fabula.trg_trade_tier_guard() from public, anon, authenticated;
drop trigger if exists trade_price_tiers_guard on fabula.trade_price_tiers;
create trigger trade_price_tiers_guard before insert or update of price_eur, discount_pct, variant_id on fabula.trade_price_tiers
  for each row execute function fabula.trg_trade_tier_guard();

-- trade_price: a tier never costs more than the list, and the final price stays between 0 and the list
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.trade_price(uuid,text,numeric,boolean)'::regprocedure);
  n := replace(d, $s$    v_tier := case when t.price_eur is not null then t.price_eur else round(v_list * (1 - t.discount_pct / 100), 2) end;$s$,
                  $s$    v_tier := least(v_list, case when t.price_eur is not null then t.price_eur else round(v_list * (1 - t.discount_pct / 100), 2) end);   -- v0.98 (D-23)$s$);
  n := replace(n, $s$  else v_final := least(v_tier, round(v_list * (1 - v_rec / 100), 2)); end if;$s$,
                  $s$  else v_final := least(v_tier, round(v_list * (1 - v_rec / 100), 2)); end if;
  v_final := greatest(0, least(v_final, v_list));                             -- v0.98 (D-13/D-23): never above the list, never below zero$s$);
  if position('least(v_list, case when t.price_eur' in n) = 0 or position('greatest(0, least(v_final, v_list))' in n) = 0 then
    raise exception 'v098c: trade_price patterns not found';
  end if;
  execute n;
end $mig$;

insert into supabase_migrations.schema_migrations (version, name) values
  ('20261013200000', 'v098a_settings_limits'),
  ('20261013200100', 'v098b_batch_milk_recipe_limits'),
  ('20261013200200', 'v098c_trade_quantities_prices');
commit;

select version, name from supabase_migrations.schema_migrations order by version desc limit 6;
