-- v1.11 (21/10/2026) · no Consorzio declaration before the caseificio is under DOP control (re-audit 19/10, R-01)
--   On 05/10 consorzio_declaration() proposed «Dichiarazione Consorzio 09/2026: 0 kg» for a dairy that is not ours yet. It sat in
--   «Da decidere» in every morning summary for 15 days until Nick rejected it (20/10), and pg_cron (fabula_consorzio_declaration,
--   05:30 UTC on the 1st) would have made a 0 kg October one on 01/11.
--   Now:
--   * new setting dop.rina_code: the caseificio's RINA operator code for the DOP control (empty until RINA's initial inspection);
--   * with the code empty and no DOP lot in the month, the function still returns the month's figures but proposes nothing
--     (approval_created false, skipped true, skip_it says why);
--   * with the code set, the month is proposed as before, 0 kg included (a dairy under control declares every month);
--   * DOP lots in a month without the code (e.g. the trial week) are proposed, with one more check to see: «codice_rina»;
--   * the payload carries the code, for the paper sent to the Consorzio.
--   pg_cron, the approval, «Segna inviata» and the T-DOP task are unchanged.

insert into fabula.settings (key, value, description, data_type, sort) values
 ('dop.rina_code', '',
  'Codice operatore RINA del caseificio per la DOP (arriva dopo la visita iniziale di RINA). Finché è vuoto e nel mese non ci sono lotti DOP, la dichiarazione mensile al Consorzio non viene proposta',
  'text', 79)
on conflict (key) do nothing;

create or replace function fabula.consorzio_declaration(p_month date default null)
returns jsonb language plpgsql set search_path = fabula, public, extensions as $$
declare m0 date; m1 date; j jsonb; v_appr uuid; v_kg numeric; v_issues jsonb; v_batches int; v_code text;
begin
  m0 := date_trunc('month', coalesce(p_month, (date_trunc('month', (now() at time zone 'Europe/Rome')::date) - interval '1 month')::date))::date;
  m1 := (m0 + interval '1 month')::date - 1;
  v_code := fabula.setting_text('dop.rina_code');
  select coalesce(sum(b.output_kg), 0), count(*) into v_kg, v_batches
    from fabula.production_batches b join fabula.products p on p.id = b.product_id
   where p.is_dop and b.batch_date between m0 and m1 and b.output_kg is not null;

  -- disciplinare checks (each item: what, how many, detail)
  select coalesce(jsonb_agg(i) filter (where (i->>'n')::int > 0), '[]') into v_issues from (
    select jsonb_build_object('check', 'codice_rina', 'it', 'Lotti DOP senza il codice RINA del caseificio: prima del codice non si possono vendere né dichiarare come DOP (Configurazione → Sicurezza alimentare e DOP)',
             'n', case when v_code is null then v_batches else 0 end, 'detail', '[]'::jsonb) i
    union all
    select jsonb_build_object('check', 'latte_60h', 'it', 'Latte lavorato oltre 60 h dall''arrivo (limite: 60 h dalla prima mungitura)',
             'n', count(*), 'detail', coalesce(jsonb_agg(jsonb_build_object('lot', x.batch_lot, 'milk_lot', x.milk_lot, 'hours', round(x.h, 1))), '[]'))
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
    'batches', v_batches,
    'labels_printed', (select coalesce(sum(qty_printed), 0) from fabula.labels l where l.kind in ('batch_lot','retail_pack','wholesale_case') and (l.printed_at at time zone 'Europe/Rome')::date between m0 and m1),
    'lots', (select coalesce(jsonb_agg(b.batch_lot order by b.batch_date, b.batch_lot), '[]') from fabula.production_batches b join fabula.products p on p.id = b.product_id where p.is_dop and b.batch_date between m0 and m1 and b.output_kg is not null),
    'sold_kg', (select coalesce(-sum(sm.qty), 0) from fabula.stock_moves sm join fabula.products p on p.id = sm.product_id where p.is_dop and sm.move_type = 'sale' and (sm.moved_at at time zone 'Europe/Rome')::date between m0 and m1),
    'fees_estimate_eur', jsonb_build_object(
        'consorzio', round(v_kg * fabula.setting_num('dop.consorzio_eur_kg', 0.044), 2),
        'rina_variable', round(v_kg * fabula.setting_num('dop.rina_eur_kg', 0.002), 2),
        'note', 'Contributo Consorzio stimato: confermare la tariffa €/kg con il Consorzio'),
    'issues', v_issues,
    'rina_code', v_code,
    'consorzio', jsonb_build_object('name', 'Consorzio per la Tutela del Formaggio Mozzarella di Bufala Campana', 'address', 'Via Gasparri 1, 81100 Caserta',
                                    'cf', '03497570634', 'piva', '02236840613', 'sdi', 'USAL8PV'),
    'company', fabula.company_name(),
    'note', 'Preparata in automatico dai dati di produzione. Invio al Consorzio a mano finché non c''è il modulo/portale ufficiale.') into j;

  -- R-01: not under DOP control yet and nothing DOP made this month → nothing to declare, nothing to decide
  if v_code is null and v_batches = 0 then
    return j || jsonb_build_object('approval_created', false, 'skipped', true,
      'skip_it', format('Nessuna dichiarazione per %s: il caseificio non ha ancora il codice RINA (dop.rina_code) e nel mese non ci sono lotti DOP', to_char(m0, 'MM/YYYY')));
  end if;

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
comment on function fabula.consorzio_declaration(date) is 'v1.11 (R-01): the month''s DOP declaration as an approval; none while dop.rina_code is empty and the month has no DOP lot';
grant execute on function fabula.consorzio_declaration(date) to authenticated, service_role;
