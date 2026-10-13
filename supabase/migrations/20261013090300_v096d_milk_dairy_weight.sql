-- v0.96d · Audit 12/10/2026, Critical item FARM-02 (part 2): the dairy's scale weight is no longer thrown away.
-- A delivery confirmed from a farm shipment keeps both weights: farm_kg (what the Masseria wrote) and dairy_kg (the reception
-- scale, BIL-01). Within the tolerance (setting milk.weight_tolerance_pct, 2 %) the farm's figure stays the one that counts.
-- Beyond it, a reason is required, the dairy's weight becomes qty_kg (stock, production, the farm's monthly total), the office
-- gets a notice and the farm sees the weighed kg and the reason on its page.

insert into fabula.settings (key, value, description, data_type) values
  ('milk.weight_tolerance_pct', '2', 'Arrivo latte: differenza massima (%) tra i kg della Masseria e quelli pesati qui senza dover scrivere il motivo; oltre, vale il peso del caseificio', 'number')
on conflict (key) do nothing;

alter table fabula.milk_intake add column if not exists farm_kg numeric(10,3);
alter table fabula.milk_intake add column if not exists dairy_kg numeric(10,3);
alter table fabula.milk_intake add column if not exists weight_note text;
comment on column fabula.milk_intake.farm_kg is 'v0.96d (FARM-02): kg written by the Masseria on its shipment';
comment on column fabula.milk_intake.dairy_kg is 'v0.96d (FARM-02): kg weighed at reception (BIL-01); qty_kg = dairy_kg when the difference is over the tolerance';
comment on column fabula.milk_intake.weight_note is 'v0.96d (FARM-02): why the two weights differ (required over the tolerance)';
do $mig$ begin
  if not exists (select 1 from pg_constraint where conname = 'milk_intake_dairy_kg_chk') then
    alter table fabula.milk_intake add constraint milk_intake_dairy_kg_chk check (dairy_kg is null or (dairy_kg > 0 and dairy_kg < 20000));
  end if;
end $mig$;

do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.milk_intake_shipment_check()'::regprocedure);
  n := replace(d, $s$  new.qty_kg := s.kg; new.milk_lot := s.milk_lot;$s$,
$s$  new.milk_lot := s.milk_lot; new.farm_kg := s.kg;
  -- v0.96d (audit FARM-02): the dairy's own scale reading stays next to the farm's; beyond the tolerance (with a reason) it is what entered
  if new.dairy_kg is not null and s.kg > 0
     and abs(new.dairy_kg - s.kg) > s.kg * coalesce(fabula.setting_num('milk.weight_tolerance_pct', 2), 2) / 100 then
    if coalesce(trim(new.weight_note), '') = '' then
      raise exception 'Pesato qui % kg, la Masseria ha scritto % kg (% %%): scrivi il motivo della differenza',
        replace(to_char(new.dairy_kg, 'FM999990.0'), '.', ','), replace(to_char(s.kg, 'FM999990.0'), '.', ','),
        replace(to_char(round((new.dairy_kg - s.kg) / s.kg * 100, 1), 'FMSG9990.0'), '.', ',') using errcode = '23514';
    end if;
    new.qty_kg := new.dairy_kg;
  else
    new.qty_kg := s.kg;
  end if;$s$);
  if n = d then raise exception 'v096d: milk_intake_shipment_check pattern not found'; end if;
  execute n;
end $mig$;

-- the office is told (notice, also on the tablet Home), once per delivery
create or replace function fabula.trg_milk_weight_notice()
returns trigger language plpgsql security definer set search_path = fabula, public as $$
begin
  if new.shipment_id is null or new.farm_kg is null or new.qty_kg is not distinct from new.farm_kg then return null; end if;
  insert into fabula.notices (key, severity, title_it, items, expires_at)
  values ('milk_weight:' || new.milk_lot, 'warn',
          format('Latte %s: pesato qui %s kg, la Masseria ha scritto %s kg (%s %%): vale il peso del caseificio', new.milk_lot,
                 replace(to_char(new.qty_kg, 'FM999990.0'), '.', ','), replace(to_char(new.farm_kg, 'FM999990.0'), '.', ','),
                 replace(to_char(round((new.qty_kg - new.farm_kg) / new.farm_kg * 100, 1), 'FMSG9990.0'), '.', ',')),
          jsonb_build_array(jsonb_build_object('label_it', 'Motivo: ' || coalesce(new.weight_note, '—')),
                            jsonb_build_object('label_it', 'La Masseria lo vede sulla sua pagina; controlla il conto del latte del mese')),
          now() + interval '7 days')
  on conflict (key) do update set title_it = excluded.title_it, items = excluded.items, resolved_at = null, expires_at = excluded.expires_at;
  return null;
end $$;
revoke all on function fabula.trg_milk_weight_notice() from public, anon, authenticated;
drop trigger if exists milk_intake_weight_notice on fabula.milk_intake;
create trigger milk_intake_weight_notice after insert on fabula.milk_intake for each row execute function fabula.trg_milk_weight_notice();

-- the farm sees both weights and the reason; its month total counts what entered
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.farm_milk_orders(text)'::regprocedure);
  n := replace(d, $s$'original_kg', s.original_kg, 'correction_reason', s.correction_reason)$s$,
                  $s$'original_kg', s.original_kg, 'correction_reason', s.correction_reason,
                                                              'dairy_kg', mi.dairy_kg, 'entered_kg', mi.qty_kg,
                                                              'weight_note', case when mi.qty_kg is distinct from mi.farm_kg then mi.weight_note end)$s$);
  n := replace(n, $s$'received_kg', (select coalesce(sum(kg), 0) from fabula.milk_shipments where status = 'received' and ship_date >= date_trunc('month', v_today)::date),$s$,
                  $s$'received_kg', (select coalesce(sum(coalesce(mi2.qty_kg, s2.kg)), 0) from fabula.milk_shipments s2 left join fabula.milk_intake mi2 on mi2.id = s2.milk_intake_id
                                    where s2.status = 'received' and s2.ship_date >= date_trunc('month', v_today)::date),$s$);
  n := replace(n, $s$'prev_received_kg', (select coalesce(sum(kg), 0) from fabula.milk_shipments where status = 'received'
                               and ship_date >= (date_trunc('month', v_today) - interval '1 month')::date and ship_date < date_trunc('month', v_today)::date)),$s$,
                  $s$'prev_received_kg', (select coalesce(sum(coalesce(mi2.qty_kg, s2.kg)), 0) from fabula.milk_shipments s2 left join fabula.milk_intake mi2 on mi2.id = s2.milk_intake_id
                               where s2.status = 'received'
                               and s2.ship_date >= (date_trunc('month', v_today) - interval '1 month')::date and s2.ship_date < date_trunc('month', v_today)::date)),$s$);
  if position('''dairy_kg'', mi.dairy_kg' in n) = 0 or position('sum(coalesce(mi2.qty_kg, s2.kg))' in n) = 0
     or (length(n) - length(replace(n, 'sum(coalesce(mi2.qty_kg, s2.kg))', ''))) / length('sum(coalesce(mi2.qty_kg, s2.kg))') <> 2 then
    raise exception 'v096d: farm_milk_orders patterns not found';
  end if;
  execute n;
end $mig$;

-- the milk register (MOD-01) prints the two weights when they differ
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.haccp_register(text,date,date)'::regprocedure);
  n := replace(d, $s$'kg', fabula._it_num(mi.qty_kg),$s$,
                  $s$'kg', case when mi.farm_kg is not null and mi.qty_kg is distinct from mi.farm_kg
                                then fabula._it_num(mi.qty_kg) || ' (pesati qui; Masseria ' || fabula._it_num(mi.farm_kg) || ': ' || coalesce(mi.weight_note, '') || ')'
                                else fabula._it_num(mi.qty_kg) end,$s$);
  if n = d then raise exception 'v096d: haccp_register milk kg pattern not found'; end if;
  execute n;
end $mig$;
