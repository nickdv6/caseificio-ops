-- v0.63a (05/10/2026) · Consorzio DOP declaration on autopilot.
-- consorzio_declaration(month) (tier-2 draft of 02/10, never called by anything) now:
--   * covers every DOP product (products.is_dop), not one SKU;
--   * adds the disciplinare checks the Consorzio/RINA will ask about: milk made into mozzarella within 60 h
--     (measured from arrival, a lower bound — the rule counts from first milking), deliveries under fat 7.23 % /
--     protein 4.2 %, milk from suppliers not flagged DOP-registered, rejected milk;
--   * estimates the month's Consorzio contribution and RINA variable fee from two settings;
--   * stays one approval per month (kind dop_declaration, Console → Oggi).
-- pg_cron runs it on the 1st of every month at 05:30 UTC (07:30 Agropoli in summer, 06:30 in winter), before the
-- monthly review bot. Approving it in the Console closes that month's "Dichiarazione produzione Consorzio" task.
-- Sending it to the Consorzio stays manual until the official format/portal is known.

insert into fabula.settings(key, value, description, data_type, sort) values
 ('dop.consorzio_eur_kg', '0.044', 'Contributo Consorzio DOP €/kg di mozzarella certificata (STIMA da bilancio Consorzio 2025: confermare la tariffa con il Consorzio)', 'number', 80),
 ('dop.rina_eur_kg', '0.002', 'Quota variabile RINA €/kg di mozzarella controllata (tariffario RINA 04/12/2025)', 'number', 81)
on conflict (key) do nothing;

create or replace function fabula.consorzio_declaration(p_month date default null)
returns jsonb language plpgsql set search_path = fabula, public, extensions as $$
declare m0 date; m1 date; j jsonb; v_appr uuid; v_kg numeric; v_issues jsonb;
begin
  m0 := date_trunc('month', coalesce(p_month, (date_trunc('month', (now() at time zone 'Europe/Rome')::date) - interval '1 month')::date))::date;
  m1 := (m0 + interval '1 month')::date - 1;
  select coalesce(sum(b.output_kg), 0) into v_kg
    from fabula.production_batches b join fabula.products p on p.id = b.product_id
   where p.is_dop and b.batch_date between m0 and m1 and b.output_kg is not null;

  -- disciplinare checks (each item: what, how many, detail)
  select coalesce(jsonb_agg(i) filter (where (i->>'n')::int > 0), '[]') into v_issues from (
    select jsonb_build_object('check', 'latte_60h', 'it', 'Latte lavorato oltre 60 h dall''arrivo (limite: 60 h dalla prima mungitura)',
             'n', count(*), 'detail', coalesce(jsonb_agg(jsonb_build_object('lot', x.batch_lot, 'milk_lot', x.milk_lot, 'hours', round(x.h, 1))), '[]')) i
      from (select b.batch_lot, mi.milk_lot,
                   extract(epoch from (b.started_at - ((mi.intake_date + coalesce(mi.intake_time, '06:00')) at time zone 'Europe/Rome'))) / 3600 h
              from fabula.production_batches b join fabula.products p on p.id = b.product_id
              join fabula.batch_milk_inputs bmi on bmi.batch_id = b.id join fabula.milk_intake mi on mi.id = bmi.milk_intake_id
             where p.is_dop and b.batch_date between m0 and m1 and b.started_at is not null) x
     where x.h > 60
    union all
    select jsonb_build_object('check', 'grasso_proteine', 'it', 'Consegne sotto grasso 7,23 % o proteine 4,2 % (art. 3 disciplinare)',
             'n', count(*), 'detail', coalesce(jsonb_agg(jsonb_build_object('milk_lot', milk_lot, 'date', intake_date, 'fat_pct', fat_pct, 'protein_pct', protein_pct)), '[]'))
      from fabula.milk_intake where accepted and intake_date between m0 and m1 and (fat_pct < 7.23 or protein_pct < 4.2)
    union all
    select jsonb_build_object('check', 'fornitori_non_dop', 'it', 'Latte da fornitori non segnati come iscritti DOP (anagrafica)',
             'n', count(distinct mi.supplier_id), 'detail', coalesce(jsonb_agg(distinct p.legal_name), '[]'))
      from fabula.milk_intake mi join fabula.parties p on p.id = mi.supplier_id
     where mi.accepted and mi.intake_date between m0 and m1 and not p.is_dop_certified
    union all
    select jsonb_build_object('check', 'lotti_senza_latte', 'it', 'Lotti DOP senza latte collegato (tracciabilità)',
             'n', count(*), 'detail', coalesce(jsonb_agg(b.batch_lot), '[]'))
      from fabula.production_batches b join fabula.products p on p.id = b.product_id
     where p.is_dop and b.batch_date between m0 and m1 and b.output_kg is not null and coalesce(b.input_kind, 'milk') <> 'whey'
       and not exists (select 1 from fabula.batch_milk_inputs bmi where bmi.batch_id = b.id)
  ) s;

  select jsonb_build_object('month', to_char(m0, 'YYYY-MM'), 'from', m0, 'to', m1,
    'milk_in_kg', (select coalesce(sum(qty_kg), 0) from fabula.milk_intake where accepted and intake_date between m0 and m1),
    'milk_rejected_kg', (select coalesce(sum(qty_kg), 0) from fabula.milk_intake where accepted = false and intake_date between m0 and m1),
    'milk_suppliers', (select coalesce(jsonb_agg(jsonb_build_object('supplier', p.legal_name, 'kg', kg, 'dop_certified', p.is_dop_certified)), '[]')
                       from (select supplier_id, round(sum(qty_kg), 1) kg from fabula.milk_intake where accepted and intake_date between m0 and m1 group by supplier_id) x join fabula.parties p on p.id = x.supplier_id),
    'milk_processed_kg', (select coalesce(sum(b.milk_in_kg), 0) from fabula.production_batches b join fabula.products p on p.id = b.product_id where p.is_dop and b.batch_date between m0 and m1 and b.output_kg is not null),
    'mozzarella_dop_kg', v_kg,
    'by_product', (select coalesce(jsonb_agg(jsonb_build_object('product', name, 'kg', kg, 'batches', n)), '[]')
                     from (select p.name, sum(b.output_kg) kg, count(*) n from fabula.production_batches b join fabula.products p on p.id = b.product_id
                            where p.is_dop and b.batch_date between m0 and m1 and b.output_kg is not null group by p.name) y),
    'batches', (select count(*) from fabula.production_batches b join fabula.products p on p.id = b.product_id where p.is_dop and b.batch_date between m0 and m1 and b.output_kg is not null),
    'labels_printed', (select coalesce(sum(qty_printed), 0) from fabula.labels l where l.kind in ('batch_lot','retail_pack','wholesale_case') and (l.printed_at at time zone 'Europe/Rome')::date between m0 and m1),
    'lots', (select coalesce(jsonb_agg(b.batch_lot order by b.batch_date, b.batch_lot), '[]') from fabula.production_batches b join fabula.products p on p.id = b.product_id where p.is_dop and b.batch_date between m0 and m1 and b.output_kg is not null),
    'sold_kg', (select coalesce(-sum(sm.qty), 0) from fabula.stock_moves sm join fabula.products p on p.id = sm.product_id where p.is_dop and sm.move_type = 'sale' and (sm.moved_at at time zone 'Europe/Rome')::date between m0 and m1),
    'fees_estimate_eur', jsonb_build_object(
        'consorzio', round(v_kg * fabula.setting_num('dop.consorzio_eur_kg', 0.044), 2),
        'rina_variable', round(v_kg * fabula.setting_num('dop.rina_eur_kg', 0.002), 2),
        'note', 'Contributo Consorzio stimato: confermare la tariffa €/kg con il Consorzio'),
    'issues', v_issues,
    'consorzio', jsonb_build_object('name', 'Consorzio per la Tutela del Formaggio Mozzarella di Bufala Campana', 'address', 'Via Gasparri 1, 81100 Caserta',
                                    'cf', '03497570634', 'piva', '02236840613', 'sdi', 'USAL8PV'),
    'company', fabula.company_name(),
    'note', 'Preparata in automatico dai dati di produzione. Invio al Consorzio a mano finché non c''è il modulo/portale ufficiale.') into j;

  if not exists (select 1 from fabula.approvals where kind = 'dop_declaration' and payload->>'month' = to_char(m0, 'YYYY-MM') and status in ('pending','approved')) then
    insert into fabula.approvals (kind, requested_by, summary, payload, related_table)
    values ('dop_declaration', 'agent:monthly_review',
            format('Dichiarazione Consorzio %s: latte %s kg → mozzarella DOP %s kg in %s lotti, %s etichette%s', to_char(m0, 'MM/YYYY'),
                   round((j->>'milk_processed_kg')::numeric), round(v_kg), j->>'batches', j->>'labels_printed',
                   case when jsonb_array_length(v_issues) > 0 then format(' · %s controlli da vedere', jsonb_array_length(v_issues)) else '' end),
            j, 'consorzio') returning id into v_appr;
    j := j || jsonb_build_object('approval_id', v_appr, 'approval_created', true);
  else
    j := j || jsonb_build_object('approval_created', false);
  end if;
  return j;
end $$;
grant execute on function fabula.consorzio_declaration(date) to authenticated, service_role;

-- approving the declaration closes the task "Dichiarazione produzione Consorzio" due in the following month
create or replace function fabula.dop_declaration_done() returns trigger
language plpgsql security definer set search_path = fabula, public as $$
declare v_m0 date;
begin
  if new.kind = 'dop_declaration' and new.status = 'approved' and old.status is distinct from 'approved' then
    v_m0 := ((new.payload->>'month') || '-01')::date;
    update fabula.task_instances ti set status = 'done', completed_at = now(), completed_by_id = coalesce(fabula.my_staff_id(), ti.completed_by_id)
      from fabula.task_schedules ts
     where ts.id = ti.schedule_id and ts.code = 'T-DOP' and ti.status in ('due', 'overdue')
       and ti.due_at >= ((v_m0 + interval '1 month')::date::timestamp at time zone 'Europe/Rome')
       and ti.due_at <  ((v_m0 + interval '2 month')::date::timestamp at time zone 'Europe/Rome');
  end if;
  return new;
end $$;
revoke all on function fabula.dop_declaration_done() from public, anon, authenticated;
do $$ begin
  if not exists (select 1 from pg_trigger where tgrelid = 'fabula.approvals'::regclass and tgname = 'approvals_dop_done') then
    create trigger approvals_dop_done after update of status on fabula.approvals for each row execute function fabula.dop_declaration_done();
  end if;
end $$;

select cron.schedule('fabula_consorzio_declaration', '30 5 1 * *', $c$select fabula.consorzio_declaration()$c$);
