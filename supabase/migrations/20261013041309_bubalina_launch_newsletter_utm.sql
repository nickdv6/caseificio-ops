-- 13/10/2026: launch-plan newsletter links get utm_medium=email (GA4 "Email" channel) instead of social.
-- Patched in place from the current definition; fails if the expected text isn't there.
do $mig$
declare d text; d2 text;
begin
  d  := pg_get_functiondef('fabula.mkt_seed_launch(date)'::regprocedure);
  d2 := replace(d, '''&utm_medium=social&utm_campaign=lancio''',
                   '''&utm_medium='' || case when r.platform = ''newsletter'' then ''email'' else ''social'' end || ''&utm_campaign=lancio''');
  if d2 = d then
    raise exception 'pattern not found in fabula.mkt_seed_launch(date)';
  end if;
  execute d2;
end $mig$;
