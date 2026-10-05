-- v044c · fix sales_status(): alias 'ch' collided with the PL/pgSQL variable ch
create or replace function fabula.sales_status(p_date date default null) returns jsonb language plpgsql stable set search_path = fabula, public as $$
declare
  d date := coalesce(p_date, (now() at time zone 'Europe/Rome')::date);
  m0 date := date_trunc('month', d)::date;
  days_in int := extract(day from (date_trunc('month', d) + interval '1 month - 1 day'))::int;
  elapsed int := extract(day from d)::int;     -- includes today (sales of today may still arrive)
  yld numeric := coalesce(nullif((select value from fabula.settings where key = 'sales.yield_pct'), '')::numeric, 30) / 100;
  stale_d int := coalesce(nullif((select value from fabula.settings where key = 'sales.lead_stale_days'), '')::int, 14);
  min_leads int := coalesce(nullif((select value from fabula.settings where key = 'sales.min_active_leads'), '')::int, 25);
  per_run int := coalesce(nullif((select value from fabula.settings where key = 'sales.research_per_run'), '')::int, 5);
  lapsed_d int := coalesce(nullif((select value from fabula.settings where key = 'sales.lapsed_days'), '')::int, 14);
  cap numeric := coalesce(nullif((select value from fabula.settings where key = 'milk.capacity_kg'), '')::numeric, 1200);
  farm numeric := coalesce(nullif((select value from fabula.settings where key = 'farm.default_kg_per_day'), '')::numeric, 0);
  tgt_l numeric := coalesce(nullif((select value from fabula.settings where key = 'sales.target_milk_l_day'), '')::numeric, 2000);
  ps date := fabula.sales_plan_start();
  mno int := fabula.sales_month_no(d);
  ch jsonb; tot jsonb; act_n int;
begin
  with c as (select * from fabula.sales_plan_channels where active),
       mtd as (select channel, sum(kg) kg, sum(revenue_net_eur) rev, sum(orders) orders from fabula.v_sales_daily where order_date between m0 and d group by 1),
       l7 as (select channel, sum(kg) kg from fabula.v_sales_daily where order_date between d - 6 and d group by 1),
       rows as (
         select c.code, c.name_it, c.sort, c.full_kg_day, c.price_net_eur_kg,
                fabula.sales_target_kg_day(c.code, d) t,
                coalesce(mtd.kg, 0) mkg, coalesce(mtd.rev, 0) mrev, coalesce(mtd.orders, 0) mord, coalesce(l7.kg, 0) / 7.0 l7d
           from c left join mtd on mtd.channel = c.code left join l7 on l7.channel = c.code)
  select jsonb_agg(jsonb_build_object(
           'code', code, 'name', name_it, 'full_kg_day', full_kg_day,
           'target_kg_day', t, 'month_target_kg', round(t * days_in, 0), 'month_target_eur', round(t * days_in * price_net_eur_kg, 0),
           'mtd_kg', round(mkg, 1), 'mtd_kg_day', round(mkg / elapsed, 1), 'last7_kg_day', round(l7d, 1),
           'mtd_revenue_eur', round(mrev, 0), 'mtd_orders', mord,
           'pct_of_target', case when t > 0 then round(100 * (mkg / elapsed) / t) end,
           'needed_kg_day_rest', case when t is not null and days_in > elapsed then greatest(0, round((t * days_in - mkg) / (days_in - elapsed), 1)) end)
         order by sort),
         jsonb_build_object(
           'target_kg_day', round(sum(t), 1), 'mtd_kg_day', round(sum(mkg) / elapsed, 1), 'last7_kg_day', round(sum(l7d), 1),
           'mtd_revenue_eur', round(sum(mrev), 0), 'month_target_eur', round(sum(t * days_in * price_net_eur_kg), 0),
           'milk_l_day_last7', round(sum(l7d) / yld, 0), 'milk_l_day_target_month', round(sum(t) / yld, 0),
           'milk_l_day_full', tgt_l, 'plant_capacity_l_day', cap, 'farm_l_day_setting', farm,
           'pct_of_full_volume', round(100 * (sum(l7d) / yld) / nullif(tgt_l, 0)),
           'capacity_warning', (sum(t) / yld) > cap * 0.9)
    into ch, tot from rows;

  select count(*) into act_n from fabula.sales_leads where stage in ('nuovo','contattato','degustazione','offerta');

  return jsonb_build_object(
    'date', d, 'plan_start', ps, 'month_no', mno, 'plan_missing', ps is null, 'yield_pct', yld * 100,
    'channels', coalesce(ch, '[]'::jsonb), 'totals', tot,
    'pipeline', jsonb_build_object(
       'active_n', act_n,
       'by_stage', (select coalesce(jsonb_agg(jsonb_build_object('stage', stage, 'n', n, 'est_kg_week', kg) order by array_position(array['nuovo','contattato','degustazione','offerta','cliente','in_pausa','perso'], stage)), '[]')
                      from (select stage, count(*) n, round(sum(est_kg_week), 0) kg from fabula.sales_leads group by stage) s),
       'by_channel', (select coalesce(jsonb_agg(jsonb_build_object('channel', chn, 'open_n', n, 'open_kg_week', kg)), '[]')
                      from (select fabula.sales_segment_channel(segment) chn, count(*) n, round(sum(est_kg_week), 0) kg
                              from fabula.sales_leads where stage in ('nuovo','contattato','degustazione','offerta') group by 1) s),
       'open_kg_day', (select round(coalesce(sum(est_kg_week), 0) / 7, 1) from fabula.sales_leads where stage in ('contattato','degustazione','offerta'))),
    'actions_due', (select coalesce(jsonb_agg(x order by x->>'due', (x->>'priority')::int), '[]') from (
        select jsonb_build_object('id', id, 'name', name, 'segment', segment, 'town', town, 'stage', stage, 'priority', priority,
                 'phone', phone, 'instagram', instagram, 'next_action', next_action, 'due', next_action_date,
                 'overdue_days', d - next_action_date, 'est_kg_week', est_kg_week, 'fit_note', fit_note, 'current_supplier', current_supplier) x
          from fabula.sales_leads
         where stage in ('nuovo','contattato','degustazione','offerta') and next_action_date <= d + 1
         order by next_action_date, priority limit 15) q),
    'stale', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'town', town, 'stage', stage,
                 'days_since_contact', d - (last_contact_at at time zone 'Europe/Rome')::date)), '[]')
                from (select * from fabula.sales_leads where stage in ('contattato','degustazione','offerta')
                        and (last_contact_at is null or (last_contact_at at time zone 'Europe/Rome')::date < d - stale_d)
                      order by last_contact_at nulls first limit 10) s),
    'tastings_next_7d', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'town', town, 'date', tasting_date) order by tasting_date), '[]')
                from fabula.sales_leads where tasting_date between d and d + 7 and stage not in ('perso','cliente')),
    'won_this_month', (select coalesce(jsonb_agg(jsonb_build_object('name', name, 'segment', segment, 'est_kg_week', est_kg_week)), '[]')
                from fabula.sales_leads where won_at >= m0),
    'lost_this_month', (select count(*) from fabula.sales_leads where stage = 'perso' and stage_changed_at >= m0),
    'accounts', jsonb_build_object(
       'active_b2b_30d', (select count(distinct o.customer_id) from fabula.sales_orders o
                           where o.channel = 'wholesale' and o.order_date > d - 30 and o.status not in ('cancelled','refunded','draft')),
       'standing_kg_week', (select round(coalesce(sum(qty_kg), 0), 1) from fabula.standing_orders where active),
       'lapsed', (select coalesce(jsonb_agg(jsonb_build_object('customer', coalesce(p.trade_name, p.legal_name), 'phone', p.phone,
                          'last_order', x.last_order, 'days', d - x.last_order) order by x.last_order), '[]')
                    from (select customer_id, max(order_date) last_order from fabula.sales_orders
                           where channel = 'wholesale' and status not in ('cancelled','refunded','draft') group by 1) x
                    join fabula.parties p on p.id = x.customer_id
                   where x.last_order < d - lapsed_d and x.last_order > d - 120 and p.notes is distinct from 'placeholder'
                     and not exists (select 1 from fabula.standing_orders s where s.customer_id = x.customer_id and s.active))),
    'marketplaces', (select coalesce(jsonb_agg(jsonb_build_object('code', m.code, 'name', m.name, 'status', m.status,
                        'commission_pct', m.commission_pct, 'markup_pct', m.markup_pct,
                        'orders_30d', (select count(*) from fabula.sales_orders o where o.marketplace = m.code and o.order_date > d - 30 and o.status not in ('cancelled','refunded','draft')))
                        order by m.sort), '[]') from fabula.mkt_channels m where m.kind = 'marketplace'),
    'web', (select jsonb_build_object('site_status', (select status from fabula.mkt_channels where code = 'sito'),
                     'pickup_status', (select status from fabula.mkt_channels where code = 'ritiro'))),
    'research', jsonb_build_object('min_active_leads', min_leads, 'active_n', act_n, 'needed', least(per_run, greatest(0, min_leads - act_n)), 'per_run', per_run,
                     'towns_covered', (select coalesce(jsonb_agg(distinct town), '[]') from fabula.sales_leads where town is not null))
  );
end $$;
