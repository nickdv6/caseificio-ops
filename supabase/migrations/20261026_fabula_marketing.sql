-- v0.26 Marketing: "Sempre 100% bufala" launch module
-- Channels (sito spedizione, ritiro su preordine, Glovo, Just Eat, banco POS), campaigns, content calendar with
-- claims check + approval, AI content jobs (Predis.ai via edge functions), asset library, influencer CRM + collabs,
-- pickup preorders derived from Shopify orders and fed into plan_milk(), code/channel performance views.
-- Connector rule: no destructive statements. Idempotent.

-- ---------- settings ----------
insert into fabula.settings (key, value, description, data_type, sort) values
 ('pickup.cutoff_hour', '18', 'Ora limite (Agropoli) per preordinare il ritiro del giorno dopo', 'number', 10),
 ('pickup.slots', '09:00-11:00,11:00-13:00,17:00-19:30', 'Fasce di ritiro in negozio (separate da virgola)', 'text', 20),
 ('pickup.slot_capacity_orders', '15', 'Ordini massimi per fascia di ritiro', 'number', 30),
 ('pickup.walkin_share_pct', '70', 'Quota delle vendite storiche al banco che resta "senza preordine" nel piano latte', 'number', 40),
 ('mkt.ai_provider', 'predis', 'Servizio AI per le bozze dei contenuti (predis)', 'text', 10),
 ('mkt.predis_brand_id', '', 'Predis.ai brand_id (la chiave API va nei segreti Supabase, non qui)', 'text', 20),
 ('mkt.output_language', 'italian', 'Lingua delle bozze AI', 'text', 30),
 ('mkt.brand_line', 'Sempre 100% bufala — dalle nostre bufale al banco.', 'Claim di marca usato nelle bozze', 'text', 40),
 ('mkt.hashtags', '#mozzarelladibufala #cilento #agropoli #100bufala #laperladelcilento', 'Hashtag di base', 'text', 50)
on conflict (key) do nothing;

-- ---------- channels ----------
create table if not exists fabula.mkt_channels (
  code text primary key,
  name text not null,
  kind text not null check (kind in ('web_ship','web_pickup','marketplace','pos','social','newsletter')),
  status text not null default 'planned' check (status in ('planned','applying','live','paused')),
  store_url text,
  commission_pct numeric(5,2),
  markup_pct numeric(5,2) not null default 0,
  utm_source text,
  notes text,
  sort int not null default 100,
  updated_at timestamptz not null default now()
);
insert into fabula.mkt_channels (code, name, kind, status, commission_pct, markup_pct, utm_source, notes, sort) values
 ('sito', 'Sito · spedizione refrigerata', 'web_ship', 'planned', null, 0, 'sito', 'perladelcilento.it — IT/AT/DE/FR, BRT', 10),
 ('ritiro', 'Sito · preordina e ritira', 'web_pickup', 'planned', null, 0, 'ritiro', 'Ordina entro le 18:00, ritira domani nella fascia scelta. Entra nel piano latte.', 20),
 ('banco', 'Banco · Shopify POS', 'pos', 'planned', null, 0, 'banco', 'Cassa con stampante RT', 30),
 ('glovo', 'Glovo · consegna Agropoli', 'marketplace', 'applying', 25, 34, 'glovo', 'Commissione da confermare nel contratto. Catalogo = collezione Glovo su Shopify.', 40),
 ('justeat', 'Just Eat · consegna Agropoli', 'marketplace', 'planned', 20, 25, 'justeat', 'Ordini sul tablet Just Eat → battuti su Shopify POS con pagamento "Just Eat". Commissione da confermare.', 50),
 ('instagram', 'Instagram', 'social', 'planned', null, 0, 'instagram', null, 60),
 ('facebook', 'Facebook', 'social', 'planned', null, 0, 'facebook', null, 70),
 ('tiktok', 'TikTok', 'social', 'planned', null, 0, 'tiktok', null, 80),
 ('google', 'Google Business Profile', 'social', 'planned', null, 0, 'google', 'Scheda Maps: orari, foto, recensioni, link preordine', 90),
 ('newsletter', 'Newsletter Shopify Email', 'newsletter', 'planned', null, 0, 'newsletter', null, 100),
 ('whatsapp', 'WhatsApp Business (canale/lista)', 'social', 'planned', null, 0, 'whatsapp', 'Annuncio "oggi al banco" + link preordine', 110)
on conflict (code) do nothing;

-- ---------- campaigns ----------
create table if not exists fabula.mkt_campaigns (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  goal text,
  starts_on date, ends_on date,
  channels text[] not null default '{}',
  budget_eur numeric(10,2) not null default 0,
  spent_eur numeric(10,2) not null default 0,
  discount_code text,
  status text not null default 'planned' check (status in ('planned','active','done','cancelled')),
  notes text,
  created_at timestamptz not null default now()
);

-- ---------- assets ----------
create table if not exists fabula.mkt_assets (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('photo','video','carousel','graphic')),
  url text not null,
  source text not null default 'caseificio' check (source in ('caseificio','predis','influencer','stock','other')),
  ai_generated boolean not null default false,
  consent_ok boolean not null default false,   -- faces: written consent on file
  hygiene_ok boolean not null default false,   -- hairnets, clean floor, no bare arms in curd
  caption text,
  tags text[] not null default '{}',
  created_at timestamptz not null default now()
);

-- ---------- claims rules ----------
create table if not exists fabula.mkt_claim_rules (
  id serial primary key,
  pattern text not null unique,
  severity text not null check (severity in ('block','warn','info')),
  message_it text not null,
  active boolean not null default true
);
insert into fabula.mkt_claim_rules (pattern, severity, message_it) values
 ('cilento\s+dop', 'block', 'Non esiste "Mozzarella di Bufala Cilento DOP": la denominazione è "Mozzarella di Bufala Campana DOP".'),
 ('burrata[^.]{0,20}dop', 'block', 'La burrata non è DOP.'),
 ('probiotic', 'block', '"Probiotico" è un claim salutistico non autorizzato (Reg. UE 1924/2006).'),
 ('(ricc[ao] di (proteine|calcio|vitamine)|più (proteine|calcio)|fa bene|salutar|dimagr)', 'warn', 'Claim nutrizionale/salutistico: ammesso solo nei termini del Reg. UE 1924/2006 — da verificare.'),
 ('(haccp\s+certificat|certificat[oa]\s+haccp|certificazione\s+haccp)', 'block', 'L''HACCP non è una certificazione: è un obbligo di autocontrollo.'),
 ('(biologic|organic|\mbio\M)', 'block', '"Biologico" solo con certificazione bio dell''operatore.'),
 ('(latte crudo|non pastorizzat)', 'warn', 'Latte crudo al consumatore: verificare la normativa (e il divieto in alcuni paesi UE) prima di pubblicizzarlo.'),
 ('(\mla migliore\M|\mil migliore\M|numero\s*1|\mn\.?\s*1\M|migliore d.italia)', 'warn', 'Superlativo assoluto: va dimostrato (pubblicità ingannevole, D.Lgs. 145/2007).'),
 ('(a differenza (delle|degli|di) altr|le altre mozzarelle|gli altri caseifici)', 'warn', 'Paragone con i concorrenti: tutte le DOP sono 100% bufala per disciplinare — non far intendere il contrario.'),
 ('(dal 2001|dal 19[0-9]{2}|da generazioni)', 'warn', 'Anno/tradizione da verificare con i documenti del caseificio.'),
 ('100\s*%\s*(di\s*)?(latte di\s*)?bufala', 'info', 'Ok sui prodotti di bufala. Mai accanto a prodotti di rivendita (burro, panna vaccini).'),
 ('(n\.?\s*11|11[°ºa]? in (campania|regione)|68[°ºa]? in italia)', 'warn', 'Classifica della Masseria: citare la fonte (ente, anno) o non usarla.')
on conflict (pattern) do nothing;

-- ---------- content calendar ----------
create table if not exists fabula.mkt_content (
  id uuid primary key default gen_random_uuid(),
  campaign_id uuid references fabula.mkt_campaigns(id),
  collab_id uuid,
  platform text not null default 'instagram' check (platform in ('instagram','facebook','tiktok','google','newsletter','whatsapp','sito')),
  format text not null default 'post' check (format in ('post','carousel','reel','story','email','article')),
  pillar text not null default 'origine' check (pillar in ('origine','mestiere','oggi_al_banco','ricetta','ritiro','territorio','collab','promo')),
  scheduled_at timestamptz,
  status text not null default 'idea' check (status in ('idea','generating','draft','review','approved','scheduled','published','rejected')),
  brief_it text,
  caption_it text,
  caption_en text,
  hashtags text,
  asset_ids uuid[] not null default '{}',
  link_url text,
  ai_provider text,
  ai_job_id uuid,
  claims jsonb not null default '[]',
  claims_blocking int not null default 0,
  approval_id uuid,
  approved_by text,
  published_url text,
  metrics jsonb not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists fabula.mkt_ai_jobs (
  id uuid primary key default gen_random_uuid(),
  provider text not null default 'predis',
  content_id uuid references fabula.mkt_content(id),
  request jsonb not null default '{}',
  external_ids text[] not null default '{}',
  status text not null default 'queued' check (status in ('queued','in_progress','completed','error')),
  response jsonb,
  error text,
  requested_by text,
  created_at timestamptz not null default now(),
  completed_at timestamptz
);

-- ---------- influencers ----------
create table if not exists fabula.mkt_influencers (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  handle text,
  platform text not null default 'instagram' check (platform in ('instagram','tiktok','youtube','facebook','blog','altro')),
  followers int,
  engagement_pct numeric(5,2),
  city text, region text,
  niche text,           -- food, chef, travel Cilento, family, fitness...
  email text, phone text,
  status text not null default 'prospect' check (status in ('prospect','contacted','negotiating','gifted','posted','affiliate','declined','paused')),
  discount_code text,
  commission_pct numeric(5,2),
  collabs_url text,
  agcom_registered boolean not null default false,
  last_contact_on date,
  next_action text,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists mkt_influencers_code_uq on fabula.mkt_influencers (upper(discount_code)) where discount_code is not null;

create table if not exists fabula.mkt_collabs (
  id uuid primary key default gen_random_uuid(),
  influencer_id uuid not null references fabula.mkt_influencers(id),
  campaign_id uuid references fabula.mkt_campaigns(id),
  kind text not null default 'gift' check (kind in ('gift','paid','affiliate','event')),
  agreed_on date,
  deliverables text,
  fee_eur numeric(10,2) not null default 0,
  product_value_eur numeric(10,2) not null default 0,
  disclosure_ok boolean,          -- post carries #adv / "in collaborazione con"
  ai_disclosure_ok boolean,
  post_url text, posted_on date,
  reach int, saves int,
  notes text,
  created_at timestamptz not null default now()
);

-- tier: AGCOM registry threshold 500k followers on one platform (or 1M avg monthly views)
create or replace function fabula.mkt_tier(p_followers int) returns text language sql immutable as $$
  select case when p_followers is null then null when p_followers < 10000 then 'nano' when p_followers < 100000 then 'micro'
              when p_followers < 500000 then 'mid' else 'macro (registro AGCOM)' end $$;

-- ---------- Shopify-derived fields on orders ----------
alter table fabula.sales_orders add column if not exists fulfilment_kind text;
alter table fabula.sales_orders add column if not exists pickup_date date;
alter table fabula.sales_orders add column if not exists pickup_slot text;
alter table fabula.sales_orders add column if not exists pickup_status text;
alter table fabula.sales_orders add column if not exists marketplace text;
alter table fabula.sales_orders add column if not exists discount_codes text[];
alter table fabula.sales_orders add column if not exists utm_source text;
alter table fabula.sales_orders add column if not exists utm_campaign text;
create index if not exists sales_orders_pickup_idx on fabula.sales_orders (pickup_date) where pickup_date is not null;

create or replace function fabula.mkt_parse_date(p text) returns date language plpgsql immutable as $$
declare s text := btrim(replace(coalesce(p,''), '/', '-'));
begin
  if s = '' then return null; end if;
  if s ~ '^\d{4}-\d{1,2}-\d{1,2}' then return to_date(substr(s,1,10), 'YYYY-MM-DD'); end if;
  if s ~ '^\d{1,2}-\d{1,2}-\d{4}' then return to_date(s, 'DD-MM-YYYY'); end if;
  return s::date;
exception when others then return null;
end $$;

create or replace function fabula.mkt_url_param(p_url text, p_key text) returns text language sql immutable as $$
  select nullif(substring(coalesce(p_url,'') from '[?&]' || p_key || '=([^&#]+)'), '') $$;

create or replace function fabula.mkt_next_open_day(p date) returns date language sql immutable as $$
  select case when extract(isodow from p + 1) = 7 then p + 2 else p + 1 end $$;

-- Reads the flattened Shopify payload the Ordini Shopify bot sends. Optional keys the bot should include:
-- note_attributes [{name,value}] (pickup app / theme date picker), shipping_lines [{title}], delivery_method,
-- discount_codes [str|{code}], payment_gateways [str], landing_site, utm_source, utm_campaign.
create or replace function fabula.mkt_derive_order() returns trigger language plpgsql as $$
declare p jsonb := new.shopify_payload; a jsonb := '{}'; ship text; gw text; src text; v_pick boolean; v_d text; codes text[];
begin
  if p is null then
    new.fulfilment_kind := coalesce(new.fulfilment_kind, case new.channel when 'wholesale' then 'wholesale' when 'store_pos' then 'pos' else null end);
    return new;
  end if;
  select coalesce(jsonb_object_agg(lower(btrim(coalesce(x->>'name', x->>'key'))), x->>'value'), '{}') into a
    from jsonb_array_elements(case when jsonb_typeof(p->'note_attributes') = 'array' then p->'note_attributes' else '[]' end) x
   where coalesce(x->>'name', x->>'key') is not null;
  select lower(coalesce(string_agg(coalesce(x->>'title', x #>> '{}'), ' '), '')) into ship
    from jsonb_array_elements(case when jsonb_typeof(p->'shipping_lines') = 'array' then p->'shipping_lines' else '[]' end) x;
  ship := ship || ' ' || lower(coalesce(p->>'delivery_method', ''));
  gw  := lower(coalesce(p->>'payment_gateways', '') || ' ' || coalesce(p->>'gateway', ''));
  src := lower(coalesce(p->>'source_name', ''));
  v_pick := ship ~ '(ritiro|pick.?up|retrait|abholung|recogida)' or a ?| array['pickup-date','pickup date','data ritiro','data di ritiro','pickup_date'];
  new.marketplace := case when gw ~ 'glovo' or src ~ 'glovo' then 'glovo' when gw ~ 'just.?eat' or src ~ 'just.?eat' then 'justeat' else null end;
  select array_agg(distinct upper(coalesce(x->>'code', x #>> '{}'))) into codes
    from jsonb_array_elements(case when jsonb_typeof(p->'discount_codes') = 'array' then p->'discount_codes' else '[]' end) x;
  new.discount_codes := codes;
  new.utm_source := coalesce(p->>'utm_source', fabula.mkt_url_param(p->>'landing_site', 'utm_source'), new.utm_source);
  new.utm_campaign := coalesce(p->>'utm_campaign', fabula.mkt_url_param(p->>'landing_site', 'utm_campaign'), new.utm_campaign);
  if v_pick and new.marketplace is null and new.channel = 'shopify' then
    v_d := coalesce(a->>'pickup-date', a->>'pickup date', a->>'data ritiro', a->>'data di ritiro', a->>'pickup_date');
    new.pickup_date := coalesce(fabula.mkt_parse_date(v_d), new.pickup_date, fabula.mkt_next_open_day(new.order_date));
    new.pickup_slot := coalesce(a->>'pickup-time', a->>'pickup time', a->>'fascia ritiro', a->>'fascia di ritiro', a->>'pickup_time', new.pickup_slot);
    new.fulfilment_kind := 'pickup';
    new.pickup_status := case when new.status = 'fulfilled' then 'ritirato' when new.status in ('cancelled','refunded') then 'annullato'
                              else coalesce(nullif(new.pickup_status, 'annullato'), 'da_preparare') end;
  else
    new.fulfilment_kind := case when new.marketplace is not null then 'marketplace' when new.channel = 'store_pos' then 'pos'
                                when new.channel = 'wholesale' then 'wholesale' else 'ship' end;
  end if;
  return new;
end $$;

do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'sales_orders_mkt_derive') then
    create trigger sales_orders_mkt_derive before insert or update on fabula.sales_orders
      for each row execute function fabula.mkt_derive_order();
  end if;
end $$;

-- ---------- preorder views ----------
create or replace view fabula.v_preorder_demand as
select o.pickup_date, l.product_id, round(sum(l.qty), 2) as kg, count(distinct o.id) as orders
  from fabula.sales_orders o join fabula.sales_order_lines l on l.sales_order_id = o.id
 where o.fulfilment_kind = 'pickup' and o.status = 'confirmed' and o.pickup_date is not null
 group by o.pickup_date, l.product_id;

create or replace view fabula.v_pickups_upcoming as
select o.id, o.order_number, o.pickup_date, o.pickup_slot, o.pickup_status, o.status, o.total_eur,
       coalesce(p.trade_name, p.legal_name, o.shopify_payload->>'customer_name', o.shopify_payload->>'email') as customer,
       coalesce(p.phone, o.shopify_payload->>'phone') as phone,
       (select round(sum(l.qty), 2) from fabula.sales_order_lines l where l.sales_order_id = o.id) as kg,
       (select string_agg(coalesce(li->>'quantity','') || '× ' || coalesce(li->>'title','') || coalesce(' ' || nullif(li->>'variant_title',''), ''), ', ')
          from jsonb_array_elements(coalesce(o.shopify_payload->'line_items', '[]')) li) as items
  from fabula.sales_orders o left join fabula.parties p on p.id = o.customer_id
 where o.fulfilment_kind = 'pickup' and o.pickup_date >= (now() at time zone 'Europe/Rome')::date - 1
   and o.status not in ('cancelled','refunded')
 order by o.pickup_date, o.pickup_slot nulls last, o.order_number;

create or replace view fabula.v_pickup_slot_load as
select o.pickup_date, coalesce(o.pickup_slot, 'senza fascia') as slot, count(*) as orders,
       fabula.setting_num('pickup.slot_capacity_orders', 15) as capacity
  from fabula.sales_orders o
 where o.fulfilment_kind = 'pickup' and o.status = 'confirmed' and o.pickup_date >= (now() at time zone 'Europe/Rome')::date
 group by 1, 2;

create or replace function fabula.mkt_set_pickup_status(p_order uuid, p_status text) returns jsonb language plpgsql as $$
begin
  if p_status not in ('da_preparare','pronto','ritirato','non_ritirato') then raise exception 'stato non valido: %', p_status; end if;
  update fabula.sales_orders set pickup_status = p_status, updated_at = now() where id = p_order and fulfilment_kind = 'pickup';
  if not found then raise exception 'ordine di ritiro non trovato'; end if;
  return jsonb_build_object('order', p_order, 'pickup_status', p_status,
    'note', case when p_status = 'ritirato' then 'Segna l''ordine come evaso in Shopify (POS o admin): lo scarico di magazzino avviene alla sincronizzazione.' end);
end $$;

-- ---------- performance views ----------
create or replace view fabula.v_mkt_channel_sales_30d as
select coalesce(o.marketplace, o.fulfilment_kind, o.channel::text) as channel,
       count(*) as orders, round(sum(o.total_eur), 2) as revenue_eur,
       round(sum((select coalesce(sum(l.qty),0) from fabula.sales_order_lines l where l.sales_order_id = o.id)), 1) as kg,
       round(avg(o.total_eur), 2) as avg_order_eur
  from fabula.sales_orders o
 where o.order_date >= (now() at time zone 'Europe/Rome')::date - 30 and o.status not in ('cancelled','refunded','draft')
 group by 1;

create or replace view fabula.v_mkt_code_performance as
select upper(c.code) as code,
       i.id as influencer_id, i.name as influencer, cp.id as campaign_id, cp.name as campaign,
       count(o.id) as orders, coalesce(round(sum(o.total_eur), 2), 0) as revenue_eur,
       min(o.order_date) as first_order, max(o.order_date) as last_order
  from (select upper(discount_code) code from fabula.mkt_influencers where discount_code is not null
        union select upper(discount_code) from fabula.mkt_campaigns where discount_code is not null
        union select distinct unnest(discount_codes) from fabula.sales_orders where discount_codes is not null) c
  left join fabula.sales_orders o on upper(c.code) = any(o.discount_codes) and o.status not in ('cancelled','refunded','draft')
  left join fabula.mkt_influencers i on upper(i.discount_code) = upper(c.code)
  left join fabula.mkt_campaigns cp on upper(cp.discount_code) = upper(c.code)
 group by 1, 2, 3, 4, 5;

create or replace view fabula.v_mkt_influencers as
select i.*, fabula.mkt_tier(i.followers) as tier,
       (select count(*) from fabula.mkt_collabs c where c.influencer_id = i.id) as collabs,
       (select max(c.posted_on) from fabula.mkt_collabs c where c.influencer_id = i.id) as last_post,
       coalesce(p.orders, 0) as code_orders, coalesce(p.revenue_eur, 0) as code_revenue_eur,
       (select coalesce(sum(c.fee_eur + c.product_value_eur), 0) from fabula.mkt_collabs c where c.influencer_id = i.id) as cost_eur
  from fabula.mkt_influencers i
  left join fabula.v_mkt_code_performance p on p.influencer_id = i.id;

-- ---------- claims check on content ----------
create or replace function fabula.mkt_check_claims(p_text text, p_is_collab boolean default false, p_has_ai boolean default false)
returns jsonb language plpgsql stable as $$
declare r record; out jsonb := '[]'; t text := lower(coalesce(p_text, ''));
begin
  for r in select * from fabula.mkt_claim_rules where active order by case severity when 'block' then 1 when 'warn' then 2 else 3 end, id loop
    if t ~* r.pattern then
      out := out || jsonb_build_object('severity', r.severity, 'message', r.message_it, 'match', substring(t from r.pattern));
    end if;
  end loop;
  if p_is_collab and t !~* '(#adv|#ad\M|pubblicit|in collaborazione con|#sponsorizzato|#partnership|prodotto (regalato|offerto))' then
    out := out || jsonb_build_object('severity', 'block', 'message', 'Contenuto in collaborazione senza dicitura (#adv, "pubblicità" o "in collaborazione con @laperladelcilento") — Digital Chart IAP e linee guida AGCOM.', 'match', null);
  end if;
  if p_has_ai and t !~* '(#ai\M|#aigenerated|generat[ao] con (l.)?ia|immagine (creata con )?ia|creat[ao] con intelligenza artificiale)' then
    out := out || jsonb_build_object('severity', 'warn', 'message', 'Immagine/video generati con IA: indicarlo nel testo (trasparenza; obbligo per i creator registrati AGCOM).', 'match', null);
  end if;
  return out;
end $$;

create or replace function fabula.mkt_content_before() returns trigger language plpgsql as $$
declare v_ai boolean; v_appr uuid;
begin
  select coalesce(bool_or(ai_generated), false) into v_ai from fabula.mkt_assets where id = any(new.asset_ids);
  new.claims := fabula.mkt_check_claims(concat_ws(' ', new.caption_it, new.caption_en, new.hashtags), new.collab_id is not null or new.pillar = 'collab', v_ai);
  new.claims_blocking := (select count(*) from jsonb_array_elements(new.claims) e where e->>'severity' = 'block');
  new.updated_at := now();
  -- moving to review opens an approval card on the console
  if new.status = 'review' and (tg_op = 'INSERT' or old.status is distinct from 'review') then
    insert into fabula.approvals (kind, requested_by, summary, payload, related_table, related_id, expires_at)
    values ('other', 'agent:marketing',
            format('Post %s %s%s: %s', new.platform, coalesce(to_char(new.scheduled_at at time zone 'Europe/Rome', 'DD/MM HH24:MI'), 'senza data'),
                   case when new.claims_blocking > 0 then format(' · ⚠ %s da correggere', new.claims_blocking) else '' end,
                   left(coalesce(new.caption_it, new.brief_it, ''), 90)),
            jsonb_build_object('type', 'content_post', 'content_id', new.id, 'platform', new.platform, 'caption_it', new.caption_it, 'claims', new.claims),
            'mkt_content', new.id, coalesce(new.scheduled_at, now() + interval '7 days'))
    returning id into v_appr;
    new.approval_id := v_appr;
  end if;
  return new;
end $$;

do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'mkt_content_before_trg') then
    create trigger mkt_content_before_trg before insert or update on fabula.mkt_content
      for each row execute function fabula.mkt_content_before();
  end if;
end $$;

create or replace function fabula.mkt_approval_sync() returns trigger language plpgsql as $$
declare v_block int;
begin
  if coalesce(new.payload->>'type', '') <> 'content_post' or new.status is not distinct from old.status then return new; end if;
  if new.status = 'approved' then
    select claims_blocking into v_block from fabula.mkt_content where id = (new.payload->>'content_id')::uuid;
    if coalesce(v_block, 0) > 0 then raise exception 'Il post ha % problemi bloccanti nel testo: correggili prima di approvare', v_block; end if;
    update fabula.mkt_content set status = 'approved', approved_by = new.decided_by where id = (new.payload->>'content_id')::uuid and status = 'review';
  elsif new.status = 'rejected' then
    update fabula.mkt_content set status = 'draft' where id = (new.payload->>'content_id')::uuid and status = 'review';
  end if;
  return new;
end $$;

do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'approvals_mkt_sync') then
    create trigger approvals_mkt_sync after update on fabula.approvals for each row execute function fabula.mkt_approval_sync();
  end if;
end $$;

-- ---------- AI jobs (Predis.ai) ----------
-- Brief sent to the AI service: content brief + brand line + guardrails, in Italian.
create or replace function fabula.mkt_ai_brief(p_content uuid) returns text language sql stable as $$
  select concat_ws(' ',
    coalesce(c.brief_it, c.caption_it, 'Post per La Perla del Cilento'),
    '— Marca: La Perla del Cilento, caseificio ad Agropoli (Cilento). Claim: ' || coalesce((select value from fabula.settings where key = 'mkt.brand_line'), 'Sempre 100% bufala') || '.',
    'Mozzarella di Bufala Campana DOP fatta ogni mattina con il latte delle bufale della nostra masseria.',
    case c.pillar when 'ritiro' then 'Invita a preordinare sul sito entro le 18 e ritirare il giorno dopo in negozio.'
                  when 'oggi_al_banco' then 'Tono: annuncio del giorno, fresco, breve.'
                  when 'ricetta' then 'Includi un consiglio d''uso semplice (temperatura ambiente, non in frigo, consumare in 2-3 giorni).' else '' end,
    'Vietato: claim salutistici, superlativi non dimostrati, paragoni con altri caseifici, "Cilento DOP".')
  from fabula.mkt_content c where c.id = p_content $$;

create or replace function fabula.mkt_ai_queue(p_content uuid, p_media text default 'single_image', p_n int default 1, p_by text default null)
returns jsonb language plpgsql as $$
declare v_job uuid; v_brief text;
begin
  v_brief := fabula.mkt_ai_brief(p_content);
  if v_brief is null then raise exception 'contenuto non trovato'; end if;
  insert into fabula.mkt_ai_jobs (provider, content_id, request, requested_by)
  values (coalesce((select value from fabula.settings where key = 'mkt.ai_provider'), 'predis'), p_content,
          jsonb_build_object('text', v_brief, 'media_type', p_media, 'n_posts', greatest(1, least(p_n, 4)),
                             'output_language', coalesce((select value from fabula.settings where key = 'mkt.output_language'), 'italian'),
                             'brand_id', (select nullif(value, '') from fabula.settings where key = 'mkt.predis_brand_id')),
          p_by)
  returning id into v_job;
  update fabula.mkt_content set status = 'generating', ai_job_id = v_job, ai_provider = 'predis' where id = p_content;
  return jsonb_build_object('job_id', v_job, 'request', (select request from fabula.mkt_ai_jobs where id = v_job));
end $$;

-- Called by the predis-webhook edge function (service role) when a post is completed / errors.
create or replace function fabula.mkt_ai_complete(p_external_id text, p_status text, p_caption text, p_media jsonb, p_raw jsonb default null)
returns jsonb language plpgsql security definer set search_path = fabula, public as $$
declare j fabula.mkt_ai_jobs%rowtype; m text; v_ids uuid[] := '{}'; v_id uuid;
begin
  select * into j from fabula.mkt_ai_jobs where p_external_id = any(external_ids) order by created_at desc limit 1;
  if j.id is null then return jsonb_build_object('ok', false, 'reason', 'job sconosciuto'); end if;
  if p_status = 'completed' then
    for m in select jsonb_array_elements_text(coalesce(p_media, '[]')) loop
      insert into fabula.mkt_assets (kind, url, source, ai_generated, consent_ok, hygiene_ok, caption, tags)
      values (case when m ~* '\.(mp4|mov|webm)' then 'video' else 'graphic' end, m, 'predis', true, true, false, p_caption, array['predis', p_external_id])
      returning id into v_id; v_ids := v_ids || v_id;
    end loop;
    update fabula.mkt_ai_jobs set status = 'completed', response = coalesce(response, '[]'::jsonb) || coalesce(p_raw, '{}'::jsonb), completed_at = now() where id = j.id;
    update fabula.mkt_content set status = case when status = 'generating' then 'draft' else status end,
           caption_it = coalesce(caption_it, p_caption), asset_ids = asset_ids || v_ids where id = j.content_id;
  else
    update fabula.mkt_ai_jobs set status = 'error', error = coalesce(p_raw::text, 'errore'), completed_at = now() where id = j.id;
    update fabula.mkt_content set status = 'idea' where id = j.content_id and status = 'generating';
  end if;
  return jsonb_build_object('ok', true, 'job', j.id, 'content', j.content_id, 'assets', coalesce(array_length(v_ids, 1), 0));
end $$;

-- ---------- influencer outreach draft ----------
create or replace function fabula.mkt_outreach_draft(p_influencer uuid, p_kind text default 'dm') returns text language sql stable as $$
  select case when p_kind = 'email' then
    format(E'Oggetto: Mozzarella di bufala appena fatta — ti va di assaggiarla?\n\nCiao %s,\n\nsono Nick de La Perla del Cilento, il caseificio di Agropoli dove facciamo la Mozzarella di Bufala Campana DOP ogni mattina, solo con il latte delle bufale della nostra masseria. Sempre 100%% bufala.\n\nSeguiamo %s e ci piace come racconti %s. Ti invitiamo a vedere una lavorazione dal vivo (di mattina presto, quando si fila la pasta) e a portare a casa una selezione dei nostri prodotti, senza nessun obbligo di pubblicazione.\n\nSe poi ti va di parlarne, possiamo darti un codice sconto personale per la tua community con una commissione sulle vendite (gestito con Shopify Collabs). Ogni contenuto andrebbe segnalato come collaborazione (#adv / "in collaborazione con").\n\nTi va? Dimmi un giorno comodo.\n\nUn saluto,\nNick\nLa Perla del Cilento · perladelcilento.it',
      split_part(i.name, ' ', 1), coalesce('@' || ltrim(i.handle, '@'), 'il tuo profilo'), coalesce(i.niche, 'il cibo e il territorio'))
  else
    format(E'Ciao %s! Siamo La Perla del Cilento, caseificio ad Agropoli: mozzarella di bufala DOP fatta ogni mattina col latte delle nostre bufale 🐃 Ci piacciono molto i tuoi contenuti su %s. Ti andrebbe di venire a vedere la filatura e assaggiare, senza impegno? Se poi ti piace, abbiamo un codice sconto personale per la tua community. Ti scrivo i dettagli in privato? — Nick',
      split_part(i.name, ' ', 1), coalesce(i.niche, 'cibo e Cilento'))
  end
  from fabula.mkt_influencers i where i.id = p_influencer $$;

-- ---------- weekly status (for a Monday marketing bot) ----------
create or replace function fabula.mkt_weekly_status(p_from date default null) returns jsonb language sql stable as $$
  with d as (select coalesce(p_from, (now() at time zone 'Europe/Rome')::date) d0)
  select jsonb_build_object(
    'from', d0, 'to', d0 + 6,
    'content_next_7d', (select coalesce(jsonb_agg(jsonb_build_object('when', to_char(scheduled_at at time zone 'Europe/Rome','DY DD/MM HH24:MI'), 'platform', platform, 'pillar', pillar, 'status', status,
                         'no_asset', cardinality(asset_ids) = 0, 'blocking', claims_blocking, 'text', left(coalesce(caption_it, brief_it, ''), 80)) order by scheduled_at), '[]')
                        from fabula.mkt_content where scheduled_at >= d0 and scheduled_at < d0 + 7),
    'content_gaps', 7 - (select count(distinct (scheduled_at at time zone 'Europe/Rome')::date) from fabula.mkt_content where scheduled_at >= d0 and scheduled_at < d0 + 7 and status <> 'rejected'),
    'to_review', (select count(*) from fabula.mkt_content where status = 'review'),
    'ai_jobs_stuck', (select count(*) from fabula.mkt_ai_jobs where status in ('queued','in_progress') and created_at < now() - interval '2 hours'),
    'influencers_follow_up', (select coalesce(jsonb_agg(jsonb_build_object('name', name, 'handle', handle, 'status', status, 'last_contact', last_contact_on, 'next', next_action)), '[]')
                              from fabula.mkt_influencers where status in ('contacted','negotiating','gifted') and (last_contact_on is null or last_contact_on < d0 - 7)),
    'collabs_missing_disclosure', (select count(*) from fabula.mkt_collabs where post_url is not null and disclosure_ok is not true),
    'codes', (select coalesce(jsonb_agg(to_jsonb(p) order by p.revenue_eur desc), '[]') from fabula.v_mkt_code_performance p where p.orders > 0),
    'channels_30d', (select coalesce(jsonb_agg(to_jsonb(c) order by c.revenue_eur desc), '[]') from fabula.v_mkt_channel_sales_30d c),
    'pickups_next_7d', (select coalesce(jsonb_agg(jsonb_build_object('date', pickup_date, 'orders', orders, 'kg', kg) order by pickup_date), '[]')
                        from (select pickup_date, sum(orders) orders, sum(kg) kg from fabula.v_preorder_demand where pickup_date between d0 and d0 + 6 group by 1) x),
    'channels_not_live', (select coalesce(jsonb_agg(name order by sort), '[]') from fabula.mkt_channels where status <> 'live'),
    'budget', jsonb_build_object('year_eur', fabula.setting_num('opex.marketing_eur_year', 15900),
                                 'campaigns_budget_eur', (select coalesce(sum(budget_eur), 0) from fabula.mkt_campaigns where status <> 'cancelled'),
                                 'spent_eur', (select coalesce(sum(spent_eur), 0) from fabula.mkt_campaigns) + (select coalesce(sum(fee_eur + product_value_eur), 0) from fabula.mkt_collabs)))
  from d $$;

-- ---------- RLS ----------
do $$ declare t text; begin
  foreach t in array array['mkt_channels','mkt_campaigns','mkt_assets','mkt_claim_rules','mkt_content','mkt_ai_jobs','mkt_influencers','mkt_collabs'] loop
    execute format('alter table fabula.%I enable row level security', t);
    if not exists (select 1 from pg_policies where schemaname = 'fabula' and tablename = t and policyname = t || '_authenticated_all') then
      execute format('create policy %I on fabula.%I for all to authenticated using (true) with check (true)', t || '_authenticated_all', t);
    end if;
    execute format('grant select, insert, update on fabula.%I to authenticated', t);
    execute format('grant all on fabula.%I to service_role', t);
  end loop;
end $$;
grant usage, select on sequence fabula.mkt_claim_rules_id_seq to authenticated;
grant select on fabula.v_preorder_demand, fabula.v_pickups_upcoming, fabula.v_pickup_slot_load, fabula.v_mkt_channel_sales_30d,
                fabula.v_mkt_code_performance, fabula.v_mkt_influencers to authenticated;

-- ---------- plan_milk(): add pickup preorders to retail demand ----------
-- retail = max(history retail, preorders + walk-in share of history). Patched in place so the rest of the function is untouched.
do $mig$
declare f text; g text; nl text := chr(10);
begin
  select pg_get_functiondef(p.oid) into f from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'fabula' and p.proname = 'plan_milk';
  if position('v_pre' in f) > 0 then return; end if;
  g := replace(f, 'v_wd text;', 'v_wd text; v_pre numeric := 0; v_walk numeric;');
  g := replace(g, '  v_retail := round(v_total - v_whole_hist, 1);',
       '  v_retail := round(v_total - v_whole_hist, 1);' || nl ||
       '  select coalesce(sum(kg),0) into v_pre from fabula.v_preorder_demand where pickup_date = d and product_id = v_moz;' || nl ||
       '  if v_pre > 0 then v_walk := round(v_retail * fabula.setting_num(''pickup.walkin_share_pct'', 70) / 100, 1); v_retail := greatest(v_retail, v_pre + v_walk); end if;');
  g := replace(g, 'ultime 4 sett. %s kg%s, giacenza', 'ultime 4 sett. %s kg%s%s, giacenza');
  g := replace(g, 'else '''' end,' || nl || '    round(v_carry,0)',
       'else '''' end,' || nl || '    case when v_pre > 0 then format('' + preordini ritiro %s kg'', trim_scale(v_pre)) else '''' end,' || nl || '    round(v_carry,0)');
  g := replace(g, '''wholesale_confirmed_kg'', v_whole_conf,', '''wholesale_confirmed_kg'', v_whole_conf, ''preorder_kg'', v_pre,');
  if (length(g) - length(replace(g, 'v_pre', ''))) / 5 < 8 then raise exception 'plan_milk patch did not match (% occurrences)', (length(g) - length(replace(g, 'v_pre', ''))) / 5; end if;
  execute g;
end $mig$;
