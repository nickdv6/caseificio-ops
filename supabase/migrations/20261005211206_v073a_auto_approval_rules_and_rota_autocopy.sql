-- v0.73a (05/10/2026) · Routine approvals approve themselves (with a window to say no) + the rota copies itself.
-- When a request is created, fabula.auto_approve_rule() checks it against conservative rules. If it qualifies it gets
-- auto_approve_at (now + approve.auto_delay_min, 60 min, and never after it expires) and auto_rule (why). It stays in
-- Console → Da approvare with "si approva da sola alle HH:MM" and can still be approved or rejected by hand. Every 10 min
-- pg_cron runs fabula.auto_approve_due(): requests still pending whose time has come are re-checked and approved with the
-- same status update the console makes (so the milk plan, purchase order and promo triggers run as usual), and a message
-- from "Zia Rosa · Approvazioni automatiche" lands in Configurazione → Bot.
-- Rules (each switchable off in Configurazione → Parametri):
--   milk plan   approve.auto_milk_plan = 1: real sales history for that weekday (≥ 3 of the last 4), no capacity / minimum
--               batch / farm shortfall, not a simulation, and milk within approve.milk_tolerance_pct (15 %) of the milk
--               actually worked on the last 4 same weekdays
--   purchase    approve.auto_po_max_eur (150, 0 = never): total ≤ limit, real (non-placeholder) supplier, known price, the
--               same item already received from that supplier at a unit price within 10 %
--   promo       approve.auto_promo = 1: counter promo only (no wholesale offer), standard discount (≤ sell.promo_pct),
--               at most approve.promo_max_kg (20) kg at risk
--   anything else (DOP declaration, recipes, recalls, social posts, ...) always waits for a person.
-- Rota: every Saturday, if next week has no rota yet and this week has one, it is copied (copy_rota_week) and noted.

alter table fabula.approvals add column if not exists auto_approve_at timestamptz;
alter table fabula.approvals add column if not exists auto_rule text;
comment on column fabula.approvals.auto_approve_at is 'v0.73: when this request approves itself if nobody decides before (null = needs a person)';
comment on column fabula.approvals.auto_rule is 'v0.73: the rule that makes it routine, shown on the card and in the decision note';

insert into fabula.settings(key, value, description, data_type, sort) values
 ('approve.auto_delay_min', '60', 'Minuti prima che una richiesta di routine si approvi da sola (nel frattempo si può approvare o rifiutare a mano)', 'number', 80),
 ('approve.auto_milk_plan', '1', 'Piano latte nella norma approvato da solo: 1 = sì, 0 = sempre a mano', 'number', 81),
 ('approve.milk_tolerance_pct', '15', 'Scostamento massimo (%) dal latte lavorato negli ultimi 4 stessi giorni per approvare da solo il piano latte', 'number', 82),
 ('approve.auto_po_max_eur', '150', 'Ordini fornitori di routine fino a questo importo (€) approvati da soli; 0 = sempre a mano', 'number', 83),
 ('approve.auto_promo', '1', 'Promo scorte standard al banco approvate da sole: 1 = sì, 0 = sempre a mano', 'number', 84),
 ('approve.promo_max_kg', '20', 'Kg a rischio massimi per approvare da sola una promo scorte', 'number', 85)
on conflict (key) do nothing;

-- the rule a request qualifies under (null = a person decides)
create or replace function fabula.auto_approve_rule(a fabula.approvals) returns text
language plpgsql stable security definer set search_path = fabula, public as $$
declare d jsonb; m record; v_avg numeric; v_tol numeric; v_max numeric; v_prod uuid; v_sup uuid; v_last numeric; p jsonb := coalesce(a.payload, '{}');
begin
  if a.status is distinct from 'pending' then return null; end if;

  -- milk plan
  if a.kind = 'other' and p->>'type' = 'milk_plan' and fabula.setting_num('approve.auto_milk_plan', 1) = 1 and a.related_table = 'milk_plans' then
    select * into m from fabula.milk_plans where id = a.related_id;
    if not found then return null; end if;
    d := coalesce(m.details, '{}');
    v_avg := nullif((d->>'last_4w_same_weekday_milk_kg')::numeric, 0);
    v_tol := fabula.setting_num('approve.milk_tolerance_pct', 15);
    if d->>'history_source' = 'same_weekday_4w' and coalesce((d->>'history_days')::int, 0) >= 3 and v_avg is not null
       and not coalesce((d->>'capacity_hit')::boolean, false) and not coalesce((d->>'min_run_applied')::boolean, false)
       and not coalesce((d->>'exceeds_farm_supply')::boolean, false) and not coalesce((d->>'is_simulation')::boolean, false)
       and abs(m.milk_kg - v_avg) <= v_avg * v_tol / 100 then
      return format('piano latte nella norma: %s kg contro %s kg lavorati in media negli ultimi 4 stessi giorni (±%s%%), dentro capacità e disponibilità della Masseria',
                    trim_scale(m.milk_kg), trim_scale(round(v_avg, 0)), trim_scale(v_tol));
    end if;
    return null;
  end if;

  -- purchase order
  if a.kind = 'purchase_order' and a.related_table = 'purchase_orders' then
    v_max := fabula.setting_num('approve.auto_po_max_eur', 150);
    if v_max <= 0 or coalesce(a.amount_eur, 0) <= 0 or a.amount_eur > v_max or coalesce((p->>'unit_price_eur')::numeric, 0) <= 0 then return null; end if;
    select po.supplier_id into v_sup from fabula.purchase_orders po where po.id = a.related_id;
    if v_sup is null or fabula.is_placeholder_party(v_sup) then return null; end if;
    select id into v_prod from fabula.products where sku = p->>'sku';
    select l.unit_price_eur into v_last from fabula.purchase_order_lines l join fabula.purchase_orders po on po.id = l.purchase_order_id
     where po.supplier_id = v_sup and l.product_id = v_prod and po.id <> a.related_id and po.status in ('received', 'partially_received') and l.unit_price_eur > 0
     order by po.order_date desc limit 1;
    if v_last is null or abs((p->>'unit_price_eur')::numeric - v_last) > v_last * 0.10 then return null; end if;
    return format('ordine di routine: € %s (limite € %s), fornitore e articolo già ricevuti, prezzo € %s (ultima volta € %s)',
                  to_char(a.amount_eur, 'FM999990.00'), trim_scale(v_max),
                  case when (p->>'unit_price_eur')::numeric = round((p->>'unit_price_eur')::numeric, 2) then to_char((p->>'unit_price_eur')::numeric, 'FM99990.00') else trim_scale(round((p->>'unit_price_eur')::numeric, 4))::text end,
                  case when v_last = round(v_last, 2) then to_char(v_last, 'FM99990.00') else trim_scale(round(v_last, 4))::text end);
  end if;

  -- sell-down promo at the counter
  if a.kind = 'price_change' and p->>'type' = 'sell_down' and fabula.setting_num('approve.auto_promo', 1) = 1 then
    if p->>'action' = 'promo_banco' and coalesce((p->>'promo_pct')::numeric, 999) <= fabula.setting_num('sell.promo_pct', 30)
       and coalesce((p->>'at_risk_kg')::numeric, 999) <= fabula.setting_num('approve.promo_max_kg', 20) then
      return format('promo standard al banco: -%s%% su %s kg a rischio del lotto %s (limite %s kg)',
                    trim_scale((p->>'promo_pct')::numeric), trim_scale((p->>'at_risk_kg')::numeric), p->>'lot', trim_scale(fabula.setting_num('approve.promo_max_kg', 20)));
    end if;
    return null;
  end if;
  return null;
end $$;
revoke all on function fabula.auto_approve_rule(fabula.approvals) from public, anon, authenticated;

-- set the timer when the request is created
create or replace function fabula.trg_approvals_auto_rule() returns trigger
language plpgsql security definer set search_path = fabula, public as $$
declare r text;
begin
  if new.status = 'pending' and new.auto_approve_at is null then
    r := fabula.auto_approve_rule(new);
    if r is not null then
      new.auto_rule := r;
      new.auto_approve_at := least(now() + make_interval(mins => fabula.setting_num('approve.auto_delay_min', 60)::int),
                                   coalesce(new.expires_at - interval '15 minutes', 'infinity'::timestamptz));
      if new.auto_approve_at < now() then new.auto_approve_at := now(); end if;
    end if;
  end if;
  return new;
end $$;
revoke all on function fabula.trg_approvals_auto_rule() from public, anon, authenticated;
do $$ begin
  if not exists (select 1 from pg_trigger where tgrelid = 'fabula.approvals'::regclass and tgname = 'approvals_auto_rule') then
    create trigger approvals_auto_rule before insert on fabula.approvals for each row execute function fabula.trg_approvals_auto_rule();
  end if;
end $$;

-- every 10 minutes: approve the routine requests whose time has come (re-checked first)
create or replace function fabula.auto_approve_due(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = fabula, public as $$
declare a fabula.approvals; r text; done jsonb := '[]';
begin
  for a in select * from fabula.approvals where status = 'pending' and auto_approve_at is not null and auto_approve_at <= p_now
            and (expires_at is null or expires_at > p_now) order by auto_approve_at loop
    r := fabula.auto_approve_rule(a);
    if r is null then
      update fabula.approvals set auto_approve_at = null, auto_rule = 'non più di routine: decide una persona' where id = a.id;
      done := done || jsonb_build_object('id', a.id, 'summary', a.summary, 'approved', false);
      continue;
    end if;
    update fabula.approvals set status = 'approved', decided_by = 'Approvazione automatica', decided_at = p_now, decision_note = 'Regola: ' || r
     where id = a.id and status = 'pending';
    if found then
      perform fabula.post_bot_message('auto_approve', 'info', 'Approvato da solo · ' || left(a.summary, 90),
        format(E'%s\n\nPerché: %s.\nNessuno l''aveva deciso entro le %s. Le regole si cambiano o si spengono in Configurazione → Parametri (approve.*).',
               a.summary, r, to_char(a.auto_approve_at at time zone 'Europe/Rome', 'HH24:MI')));
      done := done || jsonb_build_object('id', a.id, 'summary', a.summary, 'approved', true);
    end if;
  end loop;
  return jsonb_build_object('checked_at', p_now, 'results', done);
end $$;
revoke all on function fabula.auto_approve_due(timestamptz) from public, anon, authenticated;

insert into fabula.bot_nicknames (agent, nickname, title_it, sort, updated_at)
values ('auto_approve', 'Zia Rosa', 'Approvazioni automatiche', coalesce((select max(sort) + 1 from fabula.bot_nicknames), 50), now())
on conflict (agent) do nothing;

-- the rota copies itself on Saturday when next week is still empty
create or replace function fabula.rota_autocopy(p_today date default ((now() at time zone 'Europe/Rome')::date)) returns jsonb
language plpgsql security definer set search_path = fabula, public as $$
declare v_this date := date_trunc('week', p_today)::date; v_next date := date_trunc('week', p_today)::date + 7; n int;
begin
  if not exists (select 1 from fabula.rota_entries where work_date between v_this and v_this + 6) then
    return jsonb_build_object('copied', 0, 'reason', 'questa settimana non ha turni');
  end if;
  if exists (select 1 from fabula.rota_entries where work_date between v_next and v_next + 6) then
    return jsonb_build_object('copied', 0, 'reason', 'la prossima settimana ha già dei turni');
  end if;
  n := fabula.copy_rota_week(v_this, v_next);
  if n > 0 then
    perform fabula.post_bot_message('auto_approve', 'info', format('Turni della settimana del %s copiati', to_char(v_next, 'DD/MM')),
      format('La prossima settimana non aveva turni: copiati i %s turni di questa settimana (lavoro e riposo). Correggili in Console → Personale → Turni.', n));
  end if;
  return jsonb_build_object('copied', n, 'week', v_next);
end $$;
revoke all on function fabula.rota_autocopy(date) from public, anon, authenticated;

select cron.schedule('fabula_auto_approve', '*/10 * * * *', $c$select fabula.auto_approve_due()$c$);
select cron.schedule('fabula_rota_autocopy', '5 9 * * 6', $c$select fabula.rota_autocopy()$c$);
