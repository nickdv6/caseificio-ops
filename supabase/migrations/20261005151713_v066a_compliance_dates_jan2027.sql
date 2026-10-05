-- v0.66a (05/10/2026) · Nick: assume 30/01/2027 for 7 of the 8 undated compliance deadlines (HACCP manual review, pest control,
-- electrical check, extinguishers, waste-water analysis, AUA discharge permit check, whey collection contract).
-- The Consorzio annual fee stays without a date until the Consorzio confirms it.
do $$
declare n int;
begin
  update fabula.compliance_deadlines
     set due_on = date '2027-01-30',
         notes = concat_ws(' · ', nullif(notes, ''), 'Data provvisoria 30/01/2027 (Nick, 05/10/2026): confermare')
   where due_on is null and done_on is null
     and kind in ('haccp_plan_review', 'pest_control', 'electrical_check', 'extinguishers', 'environment');
  get diagnostics n = row_count;
  if n <> 7 then raise exception 'v066a: expected 7 deadlines, found %', n; end if;
end $$;
