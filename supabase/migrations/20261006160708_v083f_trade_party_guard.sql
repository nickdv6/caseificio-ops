-- Fabula v0.83f — the nightly Shopify customer sync (upsert_shopify_customers) rewrites legal_name from the Shopify customer and
-- is_wholesale from the tags. An approved trade customer keeps the business name given in the application and stays wholesale,
-- whatever the sync sends (the sync is recognised by last_synced_at moving).
set search_path = fabula, public, extensions;

create or replace function fabula.trg_party_trade_guard() returns trigger language plpgsql set search_path = fabula, public as $$
begin
  if old.trade_status = 'approved' and new.last_synced_at is distinct from old.last_synced_at then
    new.legal_name := old.legal_name;
    new.trade_name := coalesce(old.trade_name, new.trade_name);
    new.is_wholesale := true;
    new.tags := (select array_agg(distinct t) from unnest(coalesce(new.tags, '{}') || array['ingrosso']) t);
  end if;
  if new.trade_status = 'approved' then new.is_wholesale := true; end if;
  return new;
end $$;
do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'parties_trade_guard' and tgrelid = 'fabula.parties'::regclass) then
    create trigger parties_trade_guard before update on fabula.parties for each row execute function fabula.trg_party_trade_guard();
  end if;
end $$;
