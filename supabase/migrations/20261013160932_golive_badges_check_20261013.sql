-- Go-live board: badge printing as a check (13/10/2026). Doc: claude/golive-checklist-2026-10-05.md («Da fare insieme»).
-- The badge codes were regenerated on 13/10 (quick fixes, audit C-24), so every badge has to be printed again.
-- The check is automatic: a person counts as done once the tablet has logged a clock-in with their current
-- badge code (scan_events.code = staff.badge_code), which proves the printed badge exists and scans.
-- If a code is ever regenerated again, that person drops back to "to do" by itself.
-- ops_dashboard() is patched in place from its live definition; the anchor must match exactly once.

do $mig$
declare
  d text := pg_get_functiondef('fabula.ops_dashboard()'::regprocedure);
  a text := $a$'alerts_linked', (select jsonb_build_object($a$;
  r text := $r$'badges_printed', (select jsonb_build_object(
        'done', count(*) > 0 and count(*) filter (where b.scanned) = count(*),
        'detail', count(*) filter (where b.scanned) || ' of ' || count(*) || ' people have scanned their new badge on the tablet'
               || coalesce(' · still to print and scan: ' || string_agg(b.full_name, ', ') filter (where not b.scanned), '')
               || ' · Configurazione → Utenti → «Stampa tutti i badge» (codes changed on 13/10: older prints no longer work)')
        from (select s.full_name, exists (select 1 from fabula.scan_events e where e.code = s.badge_code) as scanned
                from fabula.staff s where s.active and s.badge_code is not null) b),
    'alerts_linked', (select jsonb_build_object($r$;
begin
  if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then
    raise exception 'ops_dashboard badges patch: anchor not found exactly once';
  end if;
  execute replace(d, a, r);
end $mig$;

insert into fabula.dash_checks (key, sort, label, kind, done, note, updated_at) values
  ('badges_printed', 28, 'Badges printed and scanned once on the tablet', 'auto', false, null, now())
on conflict (key) do update set label = excluded.label, sort = excluded.sort, kind = excluded.kind, updated_at = excluded.updated_at;
