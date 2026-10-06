-- v0.81d (06/10/2026) · Nick: target opening date 15 Feb 2027. sales.plan_start stays empty (follows the opening month).
insert into fabula.settings (key, value, data_type, description, sort)
select key, '2027-02-15', data_type, description, sort from fabula.settings where key = 'mkt.store_opening_date'
on conflict (key) do update set value = excluded.value;
