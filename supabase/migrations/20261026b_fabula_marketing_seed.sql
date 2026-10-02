-- v0.26b Marketing: public asset bucket + launch-plan generator (campaigns + 28 days of content briefs from a launch date)

insert into storage.buckets (id, name, public, file_size_limit) values ('marketing', 'marketing', true, 104857600) on conflict (id) do nothing;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname='storage' and tablename='objects' and policyname='marketing_auth_insert') then
    create policy marketing_auth_insert on storage.objects for insert to authenticated with check (bucket_id = 'marketing');
  end if;
  if not exists (select 1 from pg_policies where schemaname='storage' and tablename='objects' and policyname='marketing_auth_update') then
    create policy marketing_auth_update on storage.objects for update to authenticated using (bucket_id = 'marketing');
  end if;
end $$;

create or replace function fabula.mkt_seed_launch(p_launch date) returns jsonb language plpgsql as $$
declare c_pre uuid; c_launch uuid; c_deliv uuid; c_creat uuid; n int := 0; r record;
begin
  if exists (select 1 from fabula.mkt_campaigns where name like 'Lancio · %') then
    return jsonb_build_object('skipped', 'piano di lancio già creato');
  end if;
  insert into fabula.mkt_campaigns (name, goal, starts_on, ends_on, channels, budget_eur, status, notes) values
    ('Pre-lancio · Arriva La Perla', 'Far sapere ad Agropoli e dintorni che apriamo e che si può preordinare. Obiettivo: 300 follower locali, 150 iscritti WhatsApp/newsletter.',
     p_launch - 7, p_launch - 1, '{instagram,facebook,google,whatsapp}', 300, 'planned', 'Meta ads raggio 15 km (€200), cartoline QR al banco e nei bar vicini (€100).')
    returning id into c_pre;
  insert into fabula.mkt_campaigns (name, goal, starts_on, ends_on, channels, budget_eur, discount_code, status, notes) values
    ('Lancio · Sempre 100% bufala', 'Primo ordine in preordine-ritiro o online. Obiettivo: 120 preordini nei primi 21 giorni.',
     p_launch, p_launch + 20, '{ritiro,sito,instagram,facebook,tiktok,newsletter,whatsapp}', 2000, 'BENVENUTO10', 'planned',
     'Codice BENVENUTO10 = -10% primo ordine (crearlo in Shopify, 1 uso per cliente). Ads €1.200, stampa/QR €300, degustazione di apertura €500.')
    returning id into c_launch;
  insert into fabula.mkt_campaigns (name, goal, starts_on, ends_on, channels, budget_eur, status, notes) values
    ('Consegna ad Agropoli · Glovo e Just Eat', 'Attivare i due marketplace e portare i primi 50 ordini a domicilio.', p_launch + 3, p_launch + 27, '{glovo,justeat,instagram}', 600, 'planned',
     'Promo di attivazione sulle app (consegna gratuita/sconto finanziato) + post e sticker QR in vetrina.')
    returning id into c_deliv;
  insert into fabula.mkt_campaigns (name, goal, starts_on, ends_on, channels, budget_eur, status, notes) values
    ('Creator del Cilento', '8–12 creator locali (nano/micro) in visita alla filatura; codici personali con commissione tramite Shopify Collabs.', p_launch - 5, p_launch + 27, '{instagram,tiktok}', 1500, 'planned',
     'Prodotto regalato ~€600, compensi €900 per 2–3 micro creator. Ogni post con #adv / "in collaborazione con".')
    returning id into c_creat;

  for r in select * from (values
    (-7, '18:30', 'instagram', 'reel',     'origine',      c_pre,    'Teaser: all''alba nella masseria, le bufale e il secchio del latte. Testo: "Presto ad Agropoli. Sempre 100% bufala." Nessun prodotto ancora.'),
    (-6, '12:30', 'google',    'post',     'territorio',   c_pre,    'Scheda Google: annuncio apertura con data, orari e indirizzo; foto della vetrina.'),
    (-5, '18:30', 'instagram', 'carousel', 'origine',      c_pre,    'Chi siamo: dalla Masseria Cilentana al banco di Agropoli, la stessa mattina. 5 slide: bufale, mungitura, latte, caseificio, banco.'),
    (-4, '19:00', 'tiktok',    'reel',     'mestiere',     c_pre,    'La filatura a mano in 20 secondi, con il suono della pasta e dell''acqua calda. Niente musica di sottofondo.'),
    (-3, '18:30', 'instagram', 'post',     'ritiro',       c_pre,    'Come funziona il preordine: ordina sul sito entro le 18, scegli la fascia, ritiri domani senza fila. Link in bio.'),
    (-2, '12:00', 'whatsapp',  'post',     'ritiro',       c_pre,    'Messaggio lista WhatsApp: apriamo tra 2 giorni, link per preordinare il primo ritiro con BENVENUTO10.'),
    (-1, '18:30', 'instagram', 'story',    'ritiro',       c_pre,    'Countdown: domani si apre. Sticker conto alla rovescia + link preordine.'),
    ( 0, '08:00', 'instagram', 'reel',     'oggi_al_banco',c_launch, 'Giorno 1: la prima mozzarella del giorno esce dall''acqua. "Siamo aperti. Sempre 100% bufala." Orari + link preordine.'),
    ( 0, '09:00', 'newsletter','email',    'promo',        c_launch, 'Email di apertura agli iscritti: storia breve, preordine e ritiro, codice BENVENUTO10, spedizione refrigerata in IT/AT/DE/FR.'),
    ( 1, '08:30', 'instagram', 'story',    'oggi_al_banco',c_launch, 'Oggi al banco: bocconcini, ciliegine, treccia, ricotta. Foto vera del banco alle 8.'),
    ( 2, '18:30', 'instagram', 'carousel', 'ricetta',      c_launch, 'Come si mangia una mozzarella di bufala: a temperatura ambiente, non in frigo, entro 2–3 giorni; con pomodoro del Cilento e olio.'),
    ( 3, '18:30', 'instagram', 'post',     'promo',        c_deliv,  'Ora anche a domicilio ad Agropoli su Glovo e Just Eat. Per il prezzo migliore: preordina sul sito e ritira.'),
    ( 4, '19:00', 'tiktok',    'reel',     'mestiere',     c_launch, 'Il casaro taglia la cagliata: perché aspettiamo il momento giusto. Voce fuori campo del casaro.'),
    ( 5, '18:30', 'instagram', 'reel',     'collab',       c_creat,  'Prima visita creator alla filatura (contenuto del creator, ricondiviso). Verificare dicitura #adv / in collaborazione con.'),
    ( 6, '11:00', 'instagram', 'story',    'ritiro',       c_launch, 'Weekend: preordina entro le 18 di venerdì per il ritiro di sabato. Fasce quasi piene = sondaggio "a che ora passi?".'),
    ( 7, '18:30', 'instagram', 'post',     'origine',      c_launch, 'Una settimana dopo: grazie Agropoli. Numero di preordini ritirati (solo se vero) e foto dei clienti con consenso.'),
    ( 8, '18:30', 'facebook',  'post',     'territorio',   c_launch, 'Il Cilento a tavola: abbinamenti con prodotti di vicini (olio, pomodori) — taggare i produttori.'),
    ( 9, '19:00', 'tiktok',    'reel',     'mestiere',     c_launch, 'La ricotta: dal siero alla fuscella. "Niente si butta."'),
    (10, '18:30', 'instagram', 'carousel', 'ricetta',      c_launch, 'Tre ricette veloci con la treccia (insalata, pizza a fine cottura, panino).'),
    (11, '08:30', 'whatsapp',  'post',     'oggi_al_banco',c_launch, 'Oggi al banco + link preordine per domani.'),
    (12, '18:30', 'instagram', 'reel',     'collab',       c_creat,  'Seconda collaborazione creator: degustazione in caseificio. Dicitura obbligatoria.'),
    (13, '11:00', 'instagram', 'story',    'ritiro',       c_launch, 'Promemoria weekend: preordine e ritiro.'),
    (14, '18:30', 'instagram', 'post',     'origine',      c_launch, 'Le nostre bufale hanno un nome: ritratto di una bufala della masseria e del suo allevatore.'),
    (16, '18:30', 'instagram', 'carousel', 'promo',        c_launch, 'Spediamo refrigerato in Italia, Austria, Germania e Francia: come arriva la scatola (foto reali del pacco e del ghiaccio).'),
    (18, '19:00', 'tiktok',    'reel',     'mestiere',     c_launch, 'Domande al casaro (risposte ai commenti ricevuti).'),
    (20, '18:30', 'instagram', 'post',     'promo',        c_launch, 'Ultimi giorni per BENVENUTO10. Recensioni Google: chiedere di lasciarne una dopo il ritiro.'),
    (23, '18:30', 'instagram', 'reel',     'collab',       c_creat,  'Terza collaborazione creator (ricetta del creator). Dicitura obbligatoria.'),
    (27, '18:30', 'instagram', 'post',     'territorio',   c_launch, 'Un mese insieme: cosa abbiamo imparato, prossimi prodotti. Invito alla newsletter.')
  ) as t(d, hm, platform, fmt, pillar, camp, brief) loop
    insert into fabula.mkt_content (campaign_id, platform, format, pillar, scheduled_at, status, brief_it, hashtags, link_url)
    values (r.camp, r.platform, r.fmt, r.pillar, ((p_launch + r.d)::timestamp + r.hm::time) at time zone 'Europe/Rome', 'idea', r.brief,
            (select value from fabula.settings where key = 'mkt.hashtags'),
            case when r.pillar in ('ritiro','promo','oggi_al_banco') then 'https://perladelcilento.it/?utm_source=' || r.platform || '&utm_medium=social&utm_campaign=lancio' end);
    n := n + 1;
  end loop;
  return jsonb_build_object('campaigns', 4, 'content', n, 'from', p_launch - 7, 'to', p_launch + 27);
end $$;

insert into fabula.settings (key, value, description, data_type, sort) values
 ('price.retail_moz_eur_kg', '14', 'Prezzo al banco mozzarella €/kg (riferimento per i ricarichi marketplace)', 'number', 5)
on conflict (key) do nothing;
