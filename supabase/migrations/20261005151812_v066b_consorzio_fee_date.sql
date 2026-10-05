-- v0.66b (05/10/2026) · Nick: Consorzio annual fee due 01/03/2027 (provisional until the Consorzio confirms).
do $$
declare n int;
begin
  update fabula.compliance_deadlines
     set due_on = date '2027-03-01',
         notes = concat_ws(' · ', nullif(notes, ''), 'Data provvisoria 01/03/2027 (Nick, 05/10/2026): confermare con il Consorzio')
   where due_on is null and done_on is null and kind = 'consorzio_fee';
  get diagnostics n = row_count;
  if n <> 1 then raise exception 'v066b: expected 1 deadline, found %', n; end if;
end $$;
