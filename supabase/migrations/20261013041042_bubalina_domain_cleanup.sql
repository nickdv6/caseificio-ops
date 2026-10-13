-- 13/10/2026: replace leftover "La Perla del Cilento" / perladelcilento.it references with Caseificio Bubalina / bubalina.it.
-- Functions are patched in place from their current definitions (pg_get_functiondef), so nothing else in them changes.
do $mig$
declare
  r record; d text; d2 text;
begin
  for r in select * from (values
    ('fabula.mkt_local_qr(text)',                      '''https://perladelcilento.it''',              '''https://www.bubalina.it'''),
    ('fabula.trade_settings()',                         '''https://www.perladelcilento.it''',          '''https://www.bubalina.it'''),
    ('fabula.mkt_seed_launch(date)',                    '''https://perladelcilento.it/?utm_source=''', '(rtrim(coalesce(fabula._setting(''trade.store_url''), ''https://www.bubalina.it''), ''/'') || ''/?utm_source='')'),
    ('fabula.mkt_outreach_draft(uuid,text)',            '· perladelcilento.it',                        '· bubalina.it'),
    ('fabula.mkt_check_claims(text,boolean,boolean)',   '@laperladelcilento',                          '@caseificiobubalina'),
    ('fabula.company_name(boolean)',                    '''La Perla del Cilento''',                    '''Caseificio Bubalina''')
  ) as t(fn, old, new) loop
    d  := pg_get_functiondef(r.fn::regprocedure);
    d2 := replace(d, r.old, r.new);
    if d2 = d then
      raise exception 'pattern not found in %: %', r.fn, r.old;
    end if;
    execute d2;
  end loop;
end $mig$;

update fabula.settings set value = 'https://www.bubalina.it' where key = 'trade.store_url';
update fabula.settings set value = replace(value, '#laperladelcilento', '#caseificiobubalina') where key = 'mkt.hashtags';
update fabula.mkt_channels set notes = replace(notes, 'perladelcilento.it', 'bubalina.it') where code = 'sito';
