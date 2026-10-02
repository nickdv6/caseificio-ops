-- v0.30 · Milk quality at intake: protein % + somatic cells on the tablet "Arrivo latte" form (columns already existed),
-- and a per-supplier quality trend in the monthly review.
-- supplier_quality_trend(month, months=6): per supplier per month — deliveries, kg, rejected, fat %, protein %, SCC avg / >400k,
-- max temp / >4 °C, yield of the batches that used that milk, data coverage % — plus flags vs the previous month.

create or replace function fabula.supplier_quality_trend(p_month date default null, p_months int default 6)
returns jsonb language sql stable set search_path = fabula, public as $f$
with b as (
  select date_trunc('month', coalesce(p_month, (date_trunc('month', (now() at time zone 'Europe/Rome')::date) - interval '1 month')::date))::date m0),
r as (select m0, (m0 - make_interval(months => greatest(p_months, 2) - 1))::date f0, (m0 + interval '1 month')::date - 1 m1 from b),
d as (
  select mi.supplier_id, date_trunc('month', mi.intake_date)::date mon, mi.qty_kg, mi.accepted, mi.fat_pct, mi.protein_pct, mi.scc_cells_ml, mi.temperature_c,
         (select avg(pb.yield_pct) from fabula.production_batches pb join fabula.batch_milk_inputs bmi on bmi.batch_id = pb.id
           where bmi.milk_intake_id = mi.id and pb.output_kg is not null) yield_pct
  from fabula.milk_intake mi, r where mi.intake_date between r.f0 and r.m1),
m as (
  select supplier_id, mon, count(*) deliveries, round(sum(qty_kg)) kg, count(*) filter (where not accepted) rejected,
         round(avg(fat_pct), 2) fat_pct, round(avg(protein_pct), 2) protein_pct, round(avg(scc_cells_ml)) scc_avg,
         count(*) filter (where scc_cells_ml > 400000) scc_over_400k, round(max(temperature_c), 1) temp_max,
         count(*) filter (where temperature_c > 4) temp_over_4c, round(avg(yield_pct), 2) yield_pct,
         round(100.0 * count(fat_pct) / count(*)) fat_coverage_pct, round(100.0 * count(protein_pct) / count(*)) protein_coverage_pct,
         round(100.0 * count(scc_cells_ml) / count(*)) scc_coverage_pct
  from d group by 1, 2),
s as (
  select m.supplier_id, coalesce(p.legal_name, 'sconosciuto') supplier,
    jsonb_agg(jsonb_build_object('month', to_char(mon, 'YYYY-MM'), 'deliveries', deliveries, 'kg', kg, 'rejected', rejected, 'fat_pct', fat_pct, 'protein_pct', protein_pct,
      'scc_avg', scc_avg, 'scc_over_400k', scc_over_400k, 'temp_max', temp_max, 'temp_over_4c', temp_over_4c, 'yield_pct', yield_pct,
      'coverage_pct', jsonb_build_object('fat', fat_coverage_pct, 'protein', protein_coverage_pct, 'scc', scc_coverage_pct)) order by mon) months,
    (array_agg(m.fat_pct order by mon desc) filter (where mon = (select m0 from r)))[1] fat_now,
    (array_agg(m.fat_pct order by mon desc) filter (where mon = (select (m0 - interval '1 month')::date from r)))[1] fat_prev,
    (array_agg(m.protein_pct order by mon desc) filter (where mon = (select m0 from r)))[1] prot_now,
    (array_agg(m.protein_pct order by mon desc) filter (where mon = (select (m0 - interval '1 month')::date from r)))[1] prot_prev,
    (array_agg(m.scc_avg order by mon desc) filter (where mon = (select m0 from r)))[1] scc_now,
    (array_agg(m.scc_avg order by mon desc) filter (where mon = (select (m0 - interval '1 month')::date from r)))[1] scc_prev,
    sum(m.rejected) filter (where mon = (select m0 from r)) rej_now,
    sum(m.temp_over_4c) filter (where mon = (select m0 from r)) warm_now,
    (array_agg(m.scc_coverage_pct order by mon desc) filter (where mon = (select m0 from r)))[1] scc_cov_now
  from m left join fabula.parties p on p.id = m.supplier_id group by m.supplier_id, p.legal_name)
select jsonb_build_object(
  'month', (select to_char(m0, 'YYYY-MM') from r), 'months', p_months,
  'suppliers', coalesce(jsonb_agg(jsonb_build_object('supplier_id', supplier_id, 'supplier', supplier, 'months', months,
     'flags', to_jsonb(array_remove(array[
        case when fat_now is not null and fat_prev is not null and fat_now <= fat_prev - 0.3 then format('grasso in calo: %s%% → %s%%', fat_prev, fat_now) end,
        case when prot_now is not null and prot_prev is not null and prot_now <= prot_prev - 0.2 then format('proteine in calo: %s%% → %s%%', prot_prev, prot_now) end,
        case when scc_now > 400000 then format('cellule somatiche medie %s/ml (> 400.000)', scc_now)
             when scc_now is not null and scc_prev is not null and scc_now >= scc_prev * 1.25 then format('cellule somatiche in aumento: %s → %s/ml', scc_prev, scc_now) end,
        case when rej_now > 0 then format(case when rej_now = 1 then '1 consegna rifiutata' else '%s consegne rifiutate' end, rej_now) end,
        case when warm_now > 0 then format(case when warm_now = 1 then '1 consegna sopra 4 °C' else '%s consegne sopra 4 °C' end, warm_now) end,
        case when coalesce(scc_cov_now, 0) < 50 then 'cellule somatiche mancanti su oltre metà delle consegne: chiedere le analisi APA/ARA' end], null))) order by supplier), '[]'::jsonb),
  'note', 'Trend mensile per fornitore: grasso, proteine, cellule somatiche, temperature, rifiuti e resa delle caldaie che hanno usato quel latte. I flag confrontano il mese con il precedente.')
from s;
$f$;
grant execute on function fabula.supplier_quality_trend(date, int) to authenticated, service_role;

-- monthly_review(): add 'supplier_quality' next to 'milk_quality' (patched in place, idempotent)
do $$ declare d text; begin
  d := pg_get_functiondef('fabula.monthly_review(date)'::regprocedure);
  if position('supplier_quality' in d) = 0 then
    d := replace(d, '''milk_quality'', milkq,', '''milk_quality'', milkq, ''supplier_quality'', fabula.supplier_quality_trend(m0),');
    execute d;
  end if; end $$;
