-- Quick fixes 13/10/2026, after the go-live re-audit. Doc: claude/quick-fixes-2026-10-13.md
-- 1. Security check: the 4 v0.89 supply-catalogue functions reviewed and accepted. Each calls
--    require_perm('acquisti', 2|3) as its first statement, runs no dynamic SQL and has its search_path pinned.
-- 2. Badge codes (audit C-24/PRINT-13): random 10-character codes instead of STAFF:<NAME>.
--    A missing or weak code is replaced on insert or on change (this also covers invite-user,
--    which still sends STAFF:<NAME><2 digits>), and the existing codes are regenerated.
--    Printed badges made before this migration stop working: print them again.

insert into fabula.security_accepted (key, reason, accepted_at) values
  ('authenticated_security_definer_function_executable:fabula.add_supply_item(p_name text, p_category text, p_unit text, p_supplier_id uuid, p_price_eur numeric, p_spec text)',
   'by design (v0.89, reviewed 13/10/2026): adds a supply item from the catalogue; require_perm(acquisti, 3) first, no dynamic SQL, search_path pinned', now()),
  ('authenticated_security_definer_function_executable:fabula.create_manual_po(p_supplier_id uuid, p_lines jsonb, p_notes text)',
   'by design (v0.89, reviewed 13/10/2026): creates a purchase order from the catalogue; require_perm(acquisti, 2) first, no dynamic SQL, search_path pinned (approval and cancel behaviour tracked separately as audit B-18)', now()),
  ('authenticated_security_definer_function_executable:fabula.link_supplier_item(p_product_id uuid, p_supplier_id uuid, p_price_eur numeric, p_make_preferred boolean)',
   'by design (v0.89, reviewed 13/10/2026): links a supplier to an item with its price; require_perm(acquisti, 3) first, no dynamic SQL, search_path pinned', now()),
  ('authenticated_security_definer_function_executable:fabula.unlink_supplier_item(p_product_id uuid, p_supplier_id uuid)',
   'by design (v0.89, reviewed 13/10/2026): unlinks a supplier from an item; require_perm(acquisti, 3) first, no dynamic SQL, search_path pinned', now())
on conflict (key) do nothing;

create or replace function fabula.new_badge_code()
returns text
language plpgsql
volatile
set search_path = fabula, public, extensions
as $$
declare
  abc constant text := '23456789ABCDEFGHJKMNPQRSTUVWXYZ';   -- 31 symbols, no 0/O or 1/I/L
  b bytea;
  c text;
  i int;
begin
  loop
    b := extensions.gen_random_bytes(10);
    c := 'STAFF:';
    for i in 0 .. 9 loop
      c := c || substr(abc, (get_byte(b, i) % 31) + 1, 1);
    end loop;
    exit when not exists (select 1 from fabula.staff where badge_code = c);
  end loop;
  return c;
end $$;

comment on function fabula.new_badge_code() is
  'Random badge code STAFF:<10 symbols> (about 49 bits). Audit C-24: the old STAFF:<NAME> codes could be guessed and typed on the tablet.';

create or replace function fabula.trg_staff_badge_code()
returns trigger
language plpgsql
set search_path = fabula, public
as $$
begin
  if new.badge_code is null or new.badge_code !~ '^STAFF:[2-9A-HJKMNP-Z]{10}$' then
    new.badge_code := fabula.new_badge_code();
  end if;
  return new;
end $$;

revoke execute on function fabula.new_badge_code() from anon;
revoke execute on function fabula.trg_staff_badge_code() from anon;

do $$
begin
  if not exists (select 1 from pg_trigger where tgrelid = 'fabula.staff'::regclass and tgname = 'staff_badge_code') then
    create trigger staff_badge_code before insert or update of badge_code on fabula.staff
      for each row execute function fabula.trg_staff_badge_code();
  end if;
  -- regenerate every weak code (the trigger supplies the new value)
  update fabula.staff set badge_code = null
   where badge_code is null or badge_code !~ '^STAFF:[2-9A-HJKMNP-Z]{10}$';
end $$;
