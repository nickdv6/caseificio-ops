-- v0.39f · 2026-10-02 · remaining €1.30 milk constants (monthly review, sell-down value, simulator) read the milk price setting
do $$
declare f record; d text;
begin
  for f in select p.oid from pg_proc p where p.pronamespace = 'fabula'::regnamespace and p.prokind = 'f'
             and p.proname in ('monthly_review', 'sell_down_signals', 'simulate_days') loop
    d := pg_get_functiondef(f.oid);
    d := regexp_replace(d, '([^0-9.])1\.30([^0-9])', '\1fabula.setting_num(''milk.price_eur_kg'', 1.70)\2', 'g');
    execute d;
  end loop;
end $$;
