-- v0.27 Marketing · campagna locale (insegne del nuovo negozio + pubblicità locale)
-- Owned by the Marketing module: lives on mkt_campaigns, read by the Marketing bot via mkt_local_status().
-- Connector rule: no destructive statements. Idempotent.

insert into fabula.settings (key, value, description, data_type, sort) values
 ('mkt.store_opening_date', '', 'Data di apertura del negozio di Agropoli (AAAA-MM-GG). Le scadenze delle insegne e della pubblicità si calcolano da qui.', 'text', 60),
 ('mkt.local_site_url', 'https://perladelcilento.it', 'Pagina a cui puntano i QR di insegne, volantini e manifesti', 'text', 70),
 ('mkt.local_radius_km', '15', 'Raggio della pubblicità locale a pagamento (km da Agropoli)', 'number', 80)
on conflict (key) do nothing;

create table if not exists fabula.mkt_local_items (
  id uuid primary key default gen_random_uuid(),
  campaign_id uuid references fabula.mkt_campaigns(id),
  code text not null unique,
  category text not null check (category in ('insegna','vetrina','interno','stradale','affissioni','stampa','digitale','radio','evento','partner')),
  title_it text not null,
  spec_it text,
  placement text,
  qty int not null default 1,
  phase text not null default 'pre_apertura' check (phase in ('pre_apertura','apertura','primi_90_giorni','stagione_2027')),
  vendor text,
  est_eur numeric(10,2) not null default 0,
  quote_eur numeric(10,2),
  actual_eur numeric(10,2),
  permit text not null default 'nessuno' check (permit in ('nessuno','suap_insegna','codice_strada','suolo_pubblico','affissioni_comune','paesaggistica','consorzio_logo')),
  permit_status text not null default 'n/a' check (permit_status in ('n/a','da_chiedere','richiesto','ottenuto','negato')),
  permit_ref text,
  utm_source text,
  discount_code text,
  due_on date,
  starts_on date, ends_on date,
  status text not null default 'idea' check (status in ('idea','da_preventivare','preventivo','in_approvazione','approvato','ordinato','installato','attivo','concluso','annullato')),
  approval_id uuid,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- QR link per item: site + utm, so web orders from a sign/flyer land with utm_source = item code (mkt_derive_order reads landing_site).
create or replace function fabula.mkt_local_qr(p_code text) returns text language sql stable as $$
  select coalesce((select nullif(value,'') from fabula.settings where key = 'mkt.local_site_url'), 'https://perladelcilento.it')
         || '/?utm_source=' || lower(p_code) || '&utm_medium=offline&utm_campaign=apertura-agropoli' $$;

-- Planned date when no due_on is set: relative to the opening date by phase.
create or replace function fabula.mkt_local_due(p_item fabula.mkt_local_items) returns date language sql stable as $$
  select coalesce(p_item.due_on,
    (select fabula.mkt_parse_date(value) from fabula.settings where key = 'mkt.store_opening_date')
      + case p_item.phase when 'pre_apertura' then case when p_item.permit <> 'nessuno' then -45 else -14 end
                          when 'apertura' then -3 when 'primi_90_giorni' then 30 else 180 end) $$;

create or replace function fabula.mkt_local_before() returns trigger language plpgsql as $$
declare v_amt numeric; v_appr uuid;
begin
  new.updated_at := now();
  if new.utm_source is null then new.utm_source := lower(new.code); end if;
  if new.permit = 'nessuno' then new.permit_status := 'n/a';
  elsif new.permit_status = 'n/a' then new.permit_status := 'da_chiedere'; end if;
  -- nothing goes up or on air without its permit
  if new.status in ('installato','attivo') and new.permit <> 'nessuno' and new.permit_status <> 'ottenuto' then
    raise exception '% (%): serve il permesso % prima di installare/attivare (stato: %)', new.code, new.title_it, new.permit, new.permit_status;
  end if;
  if new.status in ('ordinato','installato','attivo','concluso') and coalesce(new.quote_eur, new.est_eur) > 0
     and not exists (select 1 from fabula.approvals a where a.id = new.approval_id and a.status = 'approved') then
    raise exception '% (%): la spesa non è ancora approvata in console', new.code, new.title_it;
  end if;
  if new.status = 'in_approvazione' and (tg_op = 'INSERT' or old.status is distinct from 'in_approvazione') then
    v_amt := coalesce(new.quote_eur, new.est_eur);
    insert into fabula.approvals (kind, requested_by, summary, payload, related_table, related_id, amount_eur, expires_at)
    values ('other', 'agent:marketing',
            format('Campagna locale · %s %s · € %s%s%s', new.code, new.title_it, to_char(v_amt, 'FM999G990D00'),
                   case when new.quote_eur is null then ' (stima, manca preventivo)' else coalesce(' · ' || new.vendor, '') end,
                   case when new.permit <> 'nessuno' and new.permit_status <> 'ottenuto' then ' · permesso ' || new.permit || ': ' || new.permit_status else '' end),
            jsonb_build_object('type', 'local_spend', 'item_id', new.id, 'code', new.code, 'category', new.category,
                               'spec', new.spec_it, 'vendor', new.vendor, 'quote_eur', new.quote_eur, 'est_eur', new.est_eur,
                               'permit', new.permit, 'permit_status', new.permit_status, 'qr', fabula.mkt_local_qr(new.code)),
            'mkt_local_items', new.id, v_amt, now() + interval '7 days')
    returning id into v_appr;
    new.approval_id := v_appr;
  end if;
  return new;
end $$;

do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'mkt_local_before_trg') then
    create trigger mkt_local_before_trg before insert or update on fabula.mkt_local_items
      for each row execute function fabula.mkt_local_before();
  end if;
end $$;

-- campaign spent = sum of actual costs of its local items
create or replace function fabula.mkt_local_after() returns trigger language plpgsql as $$
begin
  update fabula.mkt_campaigns c
     set spent_eur = (select coalesce(sum(actual_eur), 0) from fabula.mkt_local_items i where i.campaign_id = c.id)
   where c.id = new.campaign_id;
  return null;
end $$;

do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'mkt_local_after_trg') then
    create trigger mkt_local_after_trg after insert or update of actual_eur, campaign_id on fabula.mkt_local_items
      for each row execute function fabula.mkt_local_after();
  end if;
end $$;

create or replace function fabula.mkt_local_approval_sync() returns trigger language plpgsql as $$
begin
  if coalesce(new.payload->>'type', '') <> 'local_spend' or new.status is not distinct from old.status then return new; end if;
  update fabula.mkt_local_items
     set status = case new.status when 'approved' then 'approvato' when 'rejected' then 'preventivo' when 'expired' then 'preventivo' else status end
   where id = (new.payload->>'item_id')::uuid and status = 'in_approvazione';
  return new;
end $$;

do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'approvals_mkt_local_sync') then
    create trigger approvals_mkt_local_sync after update on fabula.approvals for each row execute function fabula.mkt_local_approval_sync();
  end if;
end $$;

-- Attribution per item: web orders by utm_source, any order (web or POS) by the item's discount code.
create or replace view fabula.v_mkt_local_items as
select i.*, c.name as campaign, fabula.mkt_local_due(i) as planned_on, fabula.mkt_local_qr(i.code) as qr_url,
       (select count(*) from fabula.sales_orders o where o.status not in ('cancelled','refunded','draft')
          and (lower(o.utm_source) = i.utm_source or (i.discount_code is not null and upper(i.discount_code) = any(o.discount_codes)))) as orders,
       (select coalesce(round(sum(o.total_eur), 2), 0) from fabula.sales_orders o where o.status not in ('cancelled','refunded','draft')
          and (lower(o.utm_source) = i.utm_source or (i.discount_code is not null and upper(i.discount_code) = any(o.discount_codes)))) as revenue_eur
  from fabula.mkt_local_items i left join fabula.mkt_campaigns c on c.id = i.campaign_id;

create or replace function fabula.mkt_local_status(p_date date default null) returns jsonb language sql stable as $$
  with d as (select coalesce(p_date, (now() at time zone 'Europe/Rome')::date) d0,
                    (select fabula.mkt_parse_date(value) from fabula.settings where key = 'mkt.store_opening_date') opening),
  it as (select v.* from fabula.v_mkt_local_items v where v.status <> 'annullato'),
  camp as (select c.* from fabula.mkt_campaigns c where c.id in (select campaign_id from it))
  select jsonb_build_object(
    'date', d0,
    'opening_date', opening,
    'days_to_opening', opening - d0,
    'opening_missing', opening is null,
    'campaigns', (select coalesce(jsonb_agg(jsonb_build_object('name', name, 'status', status, 'budget_eur', budget_eur, 'spent_eur', spent_eur,
                          'committed_eur', (select coalesce(sum(coalesce(actual_eur, quote_eur, est_eur)), 0) from it where it.campaign_id = camp.id and it.status in ('approvato','ordinato','installato','attivo','concluso')),
                          'planned_eur', (select coalesce(sum(coalesce(actual_eur, quote_eur, est_eur)), 0) from it where it.campaign_id = camp.id),
                          'discount_code', discount_code)), '[]') from camp),
    'marketing_year_eur', fabula.setting_num('opex.marketing_eur_year', 15900),
    'by_status', (select coalesce(jsonb_object_agg(status, n), '{}') from (select status, count(*) n from it group by 1) s),
    'permits_to_request', (select coalesce(jsonb_agg(jsonb_build_object('code', code, 'title', title_it, 'permit', permit, 'status', permit_status, 'planned_on', planned_on) order by planned_on nulls last, code), '[]')
                             from it where permit <> 'nessuno' and permit_status in ('da_chiedere','negato')),
    'permits_waiting', (select coalesce(jsonb_agg(jsonb_build_object('code', code, 'title', title_it, 'permit', permit, 'ref', permit_ref)), '[]')
                          from it where permit_status = 'richiesto'),
    'quotes_needed', (select coalesce(jsonb_agg(jsonb_build_object('code', code, 'title', title_it, 'spec', spec_it, 'est_eur', est_eur, 'planned_on', planned_on) order by planned_on nulls last, code), '[]')
                        from it where status in ('idea','da_preventivare') and est_eur > 0),
    'ready_for_approval', (select coalesce(jsonb_agg(jsonb_build_object('code', code, 'title', title_it, 'quote_eur', quote_eur, 'vendor', vendor)), '[]')
                             from it where status = 'preventivo'),
    'awaiting_decision', (select coalesce(jsonb_agg(jsonb_build_object('code', code, 'title', title_it, 'eur', coalesce(quote_eur, est_eur))), '[]')
                            from it where status = 'in_approvazione'),
    'due_14d', (select coalesce(jsonb_agg(jsonb_build_object('code', code, 'title', title_it, 'status', status, 'planned_on', planned_on) order by planned_on), '[]')
                  from it where planned_on between d0 and d0 + 14 and status not in ('installato','attivo','concluso')),
    'overdue', (select coalesce(jsonb_agg(jsonb_build_object('code', code, 'title', title_it, 'status', status, 'planned_on', planned_on) order by planned_on), '[]')
                  from it where planned_on < d0 and status not in ('installato','attivo','concluso')),
    'live', (select coalesce(jsonb_agg(jsonb_build_object('code', code, 'title', title_it, 'orders', orders, 'revenue_eur', revenue_eur,
                         'cost_eur', coalesce(actual_eur, quote_eur, est_eur), 'ends_on', ends_on) order by revenue_eur desc), '[]')
               from it where status in ('installato','attivo','concluso')),
    'shop_sales_weekly', (select coalesce(jsonb_agg(jsonb_build_object('week', wk, 'pos_eur', pos, 'pickup_eur', pick) order by wk), '[]') from (
                            select date_trunc('week', order_date)::date wk,
                                   round(sum(total_eur) filter (where channel = 'store_pos'), 2) pos,
                                   round(sum(total_eur) filter (where fulfilment_kind = 'pickup'), 2) pick
                              from fabula.sales_orders where order_date >= d0 - 56 and status not in ('cancelled','refunded','draft') group by 1) w)
  ) from d $$;

do $$ declare t text; begin
  foreach t in array array['mkt_local_items'] loop
    execute format('alter table fabula.%I enable row level security', t);
    if not exists (select 1 from pg_policies where schemaname = 'fabula' and tablename = t and policyname = t || '_authenticated_all') then
      execute format('create policy %I on fabula.%I for all to authenticated using (true) with check (true)', t || '_authenticated_all', t);
    end if;
    execute format('grant select, insert, update on fabula.%I to authenticated', t);
    execute format('grant all on fabula.%I to service_role', t);
  end loop;
end $$;
grant select on fabula.v_mkt_local_items to authenticated;

-- Seed: the local launch campaign and its line items (estimates incl. IVA, to replace with quotes).
insert into fabula.mkt_campaigns (name, goal, channels, budget_eur, discount_code, status, notes)
select 'Apertura Agropoli · campagna locale',
       'Far sapere a residenti e passanti che il negozio è aperto, portarli al banco e al preordine-ritiro; misurare ogni insegna/annuncio con QR (utm) o codice sconto.',
       array['banco','ritiro','google','instagram','facebook','whatsapp'], 7450, 'BENVENUTO10', 'planned',
       'Insegne ≈ €4.750 una tantum (investimento, non OpEx) + pubblicità di lancio ≈ €2.700 dal budget marketing €15.900/anno. Codice BENVENUTO10 da creare su Shopify (vale anche al POS).'
where not exists (select 1 from fabula.mkt_campaigns where name = 'Apertura Agropoli · campagna locale');

insert into fabula.mkt_local_items (campaign_id, code, category, title_it, spec_it, placement, qty, phase, est_eur, permit, discount_code, status, notes)
select c.id, x.code, x.category, x.title, x.spec, x.placement, x.qty, x.phase, x.est, x.permit, x.dc, 'da_preventivare', x.notes
  from fabula.mkt_campaigns c,
  (values
   ('SIG-01','insegna','Insegna frontale La Perla del Cilento',
    'Lettere scatolate o pannello retroilluminato LED, logo + "La Perla del Cilento · Caseificio". Tenere la superficie ≤ 5 m² (esenzione canone unico per l''insegna di esercizio). Palette navy #1e3a5f / avorio / oro.',
    'facciata sopra l''ingresso', 1, 'pre_apertura', 2500, 'suap_insegna', null::text,
    'L''autorizzazione dell''insegna attuale è a nome del venditore: chiedere copia in due diligence. Verificare vincoli (centro storico / paesaggistica) con SUAP Agropoli.'),
   ('SIG-02','vetrina','Vetrofanie: logo, orari, preordine con QR, pagamenti',
    'Logo, orari di apertura, "Preordina entro le 18, ritira domani" + QR, carte accettate, "Sempre 100% bufala". Pellicola PVC prespaziata.',
    'vetrine e porta', 1, 'pre_apertura', 350, 'nessuno', null,
    'Alcuni regolamenti comunali contano le vetrofanie con logo come insegna: verificare con SUAP.'),
   ('SIG-03','insegna','Insegna a bandiera (perpendicolare)',
    'Doppia faccia, ~60×60 cm, visibile da chi arriva lungo la strada.', 'facciata, a bandiera', 1, 'pre_apertura', 600, 'suap_insegna', null,
    'Se sporge su strada pubblica servono anche altezza minima e nulla osta dell''ente proprietario (Codice della Strada).'),
   ('SIG-04','vetrina','Lavagna esterna "Oggi al banco"',
    'Cavalletto o lavagna scrivibile: prodotti del giorno, orario della filatura, QR preordine.', 'marciapiede davanti all''ingresso', 1, 'apertura', 150, 'suolo_pubblico', null,
    'Occupazione di suolo pubblico (canone unico) se fuori dalla soglia del negozio.'),
   ('SIG-05','interno','Listino prezzi €/kg e tabella allergeni',
    'Cartellini prezzo per prodotto (prezzo €/kg obbligatorio), listino a parete, informazioni allergeni per i prodotti sfusi (Reg. UE 1169/2011).', 'banco e parete', 1, 'pre_apertura', 250, 'nessuno', null, null),
   ('SIG-06','interno','Pannello filiera: dalla Masseria al banco',
    'Foto delle bufale della Masseria Cilentana, il percorso latte → filatura → banco, QR verso la pagina "chi siamo".', 'parete interna', 1, 'pre_apertura', 300, 'nessuno', null,
    'Nessun claim di classifica senza fonte (vedi mkt_claim_rules).'),
   ('SIG-07','stradale','Preinsegne stradali di indicazione',
    'Cartelli di direzione sulle due vie d''accesso principali.', 'strade d''accesso', 2, 'pre_apertura', 600, 'codice_strada', null,
    'Autorizzazione dell''ente proprietario della strada (Comune / Provincia / ANAS) + canone.'),
   ('SIG-08','vetrina','Logo Consorzio Mozzarella di Bufala Campana DOP',
    'Esporre il logo del Consorzio solo se autorizzati; altrimenti solo la dicitura sul prodotto.', 'vetrina / banco', 1, 'pre_apertura', 0, 'consorzio_logo', null,
    'Da chiarire con il Consorzio insieme all''iscrizione (vedi doc dop-fees).'),
   ('ADV-01','digitale','Google Business Profile del negozio',
    'Scheda Maps con indirizzo, orari, foto del banco e della filatura, link al preordine (utm adv-01). Rispondere alle recensioni.', 'Google Maps', 1, 'pre_apertura', 0, 'nessuno', null,
    'Verifica della scheda tramite cartolina/video: farla subito, richiede giorni.'),
   ('ADV-02','digitale','Annunci Meta (Instagram + Facebook) raggio 15 km',
    'Due settimane intorno all''apertura, ~€20/giorno; creatività dal modulo contenuti; link con utm adv-02 e codice BENVENUTO10.', 'Agropoli e comuni vicini', 1, 'apertura', 300, 'nessuno', 'BENVENUTO10', null),
   ('ADV-03','digitale','Google Ads locale (ricerca "mozzarella Agropoli")',
    'Campagna di ricerca/Maps su parole chiave locali, 30 giorni.', 'Google', 1, 'apertura', 200, 'nessuno', null, null),
   ('ADV-04','stampa','Volantini A5 + distribuzione porta a porta',
    '5.000 volantini A5 fronte/retro con QR (utm adv-04) e codice BENVENUTO10; distribuzione nei quartieri vicini.', 'Agropoli centro e frazioni', 5000, 'apertura', 450, 'nessuno', 'BENVENUTO10', null),
   ('ADV-05','affissioni','Manifesti con le pubbliche affissioni del Comune',
    '~50 fogli 70×100 per 15 giorni, QR utm adv-05.', 'impianti comunali Agropoli', 50, 'apertura', 250, 'affissioni_comune', null,
    'Prenotazione e tariffa all''ufficio affissioni / concessionario del Comune.'),
   ('ADV-06','digitale','Testata online locale (articolo o banner)',
    'Articolo sull''apertura o banner per 2 settimane su una testata del Cilento.', 'web locale', 1, 'apertura', 300, 'nessuno', null, 'Contenuti sponsorizzati: dicitura "pubblicità".'),
   ('ADV-07','radio','Spot radio locale',
    'Pacchetto 2 settimane, 15–20″, in apertura.', 'radio del territorio', 1, 'apertura', 500, 'nessuno', null, 'Attribuzione: chiedere in cassa "come ci hai conosciuto" o codice dedicato.'),
   ('ADV-08','evento','Inaugurazione con degustazione e filatura dal vivo',
    'Mattina di apertura: assaggi gratuiti, filatura a vista, invito a residenti e attività vicine.', 'negozio', 1, 'apertura', 500, 'nessuno', null,
    'Se si usa spazio esterno: suolo pubblico. Assaggi gratuiti, nessuna somministrazione a pagamento.'),
   ('ADV-09','partner','Strutture ricettive e lidi: cartoline con QR',
    'Cartoline/espositori in hotel, B&B e lidi con QR (utm adv-09) e codice dedicato per struttura.', 'Agropoli e costa', 1, 'stagione_2027', 200, 'nessuno', null, 'Da attivare per la stagione 2027 (aprile).'),
   ('ADV-10','digitale','Lista WhatsApp "Oggi al banco"',
    'Iscrizione con QR in vetrina e al banco; un messaggio al giorno con i prodotti e il link al preordine.', 'WhatsApp Business', 1, 'apertura', 0, 'nessuno', null, null)
  ) as x(code, category, title, spec, placement, qty, phase, est, permit, dc, notes)
 where c.name = 'Apertura Agropoli · campagna locale'
on conflict (code) do nothing;
