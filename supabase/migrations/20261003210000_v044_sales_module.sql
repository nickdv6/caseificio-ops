-- v044 · Modulo Vendite (03/10/2026)
-- Piano vendite su 5 canali per trasformare tutto il latte della Masseria (2.000 L/giorno a regime):
--   banco (negozio) · online (sito: spedizione + ritiro) · delivery (Glovo, Deliveroo, Just Eat) · ristoranti (ristoranti e pizzerie) · hotel (hotel, B&B, agriturismi, lidi)
-- Obiettivi = rampa per mese di piano (sales_ramp) × stagionalità del mese di calendario (sales_seasonality, normalizzata).
-- Pipeline B2B: sales_leads + sales_activities. Il bot Vendite legge fabula.sales_status().
set search_path = fabula, public;

-- ---------- settings ----------
insert into fabula.settings (key, value, description, data_type, sort) values
 ('sales.plan_start', '', 'Primo mese del piano vendite (AAAA-MM-01). Vuoto = usa il mese di mkt.store_opening_date; se vuote entrambe gli obiettivi non sono attivi', 'text', 110),
 ('sales.target_milk_l_day', '2000', 'Latte della Masseria da trasformare a regime (L/giorno)', 'number', 111),
 ('sales.yield_pct', '30', 'Resa mozzarella su latte (%) per convertire kg venduti ↔ litri di latte', 'number', 112),
 ('sales.lead_stale_days', '14', 'Giorni senza contatto dopo cui una trattativa aperta è "ferma"', 'number', 113),
 ('sales.min_active_leads', '25', 'Sotto questo numero di contatti aperti il bot Vendite cerca nuovi locali', 'number', 114),
 ('sales.research_per_run', '5', 'Nuovi locali che il bot Vendite può aggiungere per giro', 'number', 115),
 ('sales.lapsed_days', '14', 'Giorni senza ordini dopo cui un cliente ristorazione/hotel è "perso"', 'number', 116),
 ('sales.whey_sku_regex', '^RIC', 'Prodotti da siero (non consumano latte): esclusi dal calcolo litri', 'text', 117)
on conflict (key) do nothing;

-- ---------- channels of the plan ----------
create table if not exists fabula.sales_plan_channels (
  code text primary key,
  name_it text not null,
  price_net_eur_kg numeric(8,2) not null,          -- prezzo medio netto IVA che resta a noi
  full_kg_day numeric(8,1) not null,               -- obiettivo a regime (media annua, kg mozzarella/giorno)
  sort int not null default 0,
  notes text,
  active boolean not null default true
);
insert into fabula.sales_plan_channels (code, name_it, price_net_eur_kg, full_kg_day, sort, notes) values
 ('banco',      'Negozio (banco)',                       13.46, 150, 1, '€14/kg IVA 4% inclusa'),
 ('online',     'Online a casa (spedizione + ritiro)',   13.46,  40, 2, 'Sito Shopify; spedizione IT/AT/DE/FR e preordine con ritiro'),
 ('delivery',   'Glovo · Deliveroo · Just Eat',          13.46,  30, 3, 'Listino maggiorato per coprire la commissione: il netto resta ≈ prezzo banco'),
 ('ristoranti', 'Ristoranti e pizzerie',                 11.50, 260, 4, 'Listino ingrosso IVA esclusa (price.wholesale_moz_eur_kg)'),
 ('hotel',      'Hotel, B&B, agriturismi, lidi',         11.50, 120, 5, 'Molto stagionale: maggio–settembre')
on conflict (code) do nothing;

create table if not exists fabula.sales_ramp (
  channel text not null references fabula.sales_plan_channels(code) on update cascade,
  month_no int not null check (month_no >= 1),
  kg_day numeric(8,1) not null check (kg_day >= 0),   -- media annua (stagionalità esclusa); tra due ancore si interpola
  primary key (channel, month_no)
);
insert into fabula.sales_ramp (channel, month_no, kg_day) values
 ('banco',1,60),('banco',3,80),('banco',6,110),('banco',9,125),('banco',12,140),('banco',18,150),
 ('online',1,5),('online',3,10),('online',6,20),('online',9,26),('online',12,32),('online',18,40),
 ('delivery',1,5),('delivery',3,10),('delivery',6,18),('delivery',9,22),('delivery',12,25),('delivery',18,30),
 ('ristoranti',1,10),('ristoranti',3,40),('ristoranti',6,100),('ristoranti',9,145),('ristoranti',12,190),('ristoranti',18,260),
 ('hotel',1,5),('hotel',3,20),('hotel',6,50),('hotel',9,70),('hotel',12,90),('hotel',18,120)
on conflict do nothing;

create table if not exists fabula.sales_seasonality (
  channel text not null references fabula.sales_plan_channels(code) on update cascade,
  month smallint not null check (month between 1 and 12),
  factor numeric(5,2) not null check (factor >= 0),   -- relativo: viene normalizzato sulla media dei 12 mesi
  primary key (channel, month)
);
insert into fabula.sales_seasonality (channel, month, factor)
select c, m, f from (values
 ('banco',      array[0.75,0.75,0.85,0.95,1.05,1.25,1.45,1.60,1.15,0.90,0.75,0.95]),
 ('online',     array[0.90,0.90,1.00,1.05,1.00,0.90,0.80,0.70,1.00,1.10,1.20,1.45]),
 ('delivery',   array[0.70,0.70,0.80,0.90,1.00,1.30,1.60,1.80,1.10,0.80,0.70,0.90]),
 ('ristoranti', array[0.70,0.70,0.85,1.00,1.10,1.30,1.45,1.55,1.15,0.90,0.70,0.90]),
 ('hotel',      array[0.20,0.20,0.40,0.80,1.20,1.80,2.20,2.40,1.60,0.70,0.25,0.30])
) v(c, a), lateral unnest(a) with ordinality u(f, m)
on conflict do nothing;

-- ---------- customer segment ----------
alter table fabula.parties add column if not exists segment text;
do $$ begin
  alter table fabula.parties add constraint parties_segment_chk check (segment is null or segment in ('pizzeria','ristorante','hotel','bnb','agriturismo','lido','gastronomia','altro','privato'));
exception when duplicate_object then null; end $$;
comment on column fabula.parties.segment is 'Tipo di cliente per il piano vendite. Se vuoto si ricava dai tag Shopify (hotel, b&b, lido, agriturismo, ristorante, pizzeria…).';

-- ---------- B2B pipeline ----------
create table if not exists fabula.sales_leads (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  segment text not null check (segment in ('pizzeria','ristorante','hotel','bnb','agriturismo','lido','gastronomia','altro')),
  town text, address text, phone text, email text, website text, instagram text,
  fit_note text, size_hint text, current_supplier text,
  source text not null default 'manuale', source_url text,
  stage text not null default 'nuovo' check (stage in ('nuovo','contattato','degustazione','offerta','cliente','perso','in_pausa')),
  priority smallint not null default 2 check (priority between 1 and 3),
  est_kg_week numeric(8,1),
  next_action text, next_action_date date, tasting_date date,
  party_id uuid references fabula.parties(id) on delete set null,
  owner_staff_id uuid references fabula.staff(id) on delete set null,
  lost_reason text, notes text,
  last_contact_at timestamptz,
  stage_changed_at timestamptz not null default now(),
  won_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists sales_leads_name_town_uq on fabula.sales_leads (lower(name), lower(coalesce(town, '')));
create index if not exists sales_leads_stage_idx on fabula.sales_leads (stage, next_action_date);

create table if not exists fabula.sales_activities (
  id uuid primary key default gen_random_uuid(),
  lead_id uuid not null references fabula.sales_leads(id) on delete cascade,
  at timestamptz not null default now(),
  kind text not null check (kind in ('chiamata','whatsapp','email','visita','degustazione','campione','offerta','ordine','nota')),
  outcome text check (outcome is null or outcome in ('positivo','neutro','negativo','nessuna_risposta')),
  note text,
  next_action text, next_action_date date,
  staff_name text,
  created_at timestamptz not null default now()
);
create index if not exists sales_activities_lead_idx on fabula.sales_activities (lead_id, at desc);

create or replace function fabula.trg_sales_lead_touch() returns trigger language plpgsql set search_path = fabula, public as $$
begin
  new.updated_at := now();
  if tg_op = 'UPDATE' and new.stage is distinct from old.stage then
    new.stage_changed_at := now();
    if new.stage = 'cliente' and new.won_at is null then new.won_at := now(); end if;
  end if;
  if tg_op = 'INSERT' and new.stage = 'cliente' and new.won_at is null then new.won_at := now(); end if;
  if new.est_kg_week is null then
    new.est_kg_week := case new.segment when 'pizzeria' then 15 when 'ristorante' then 8 when 'hotel' then 12 when 'bnb' then 3
      when 'agriturismo' then 5 when 'lido' then 10 when 'gastronomia' then 10 else 5 end;
  end if;
  return new;
end $$;
drop trigger if exists sales_leads_touch on fabula.sales_leads;
create trigger sales_leads_touch before insert or update on fabula.sales_leads for each row execute function fabula.trg_sales_lead_touch();

-- an activity moves the lead forward (never backwards) and carries the next step
create or replace function fabula.trg_sales_activity_apply() returns trigger language plpgsql set search_path = fabula, public as $$
declare v_stage text; v_rank int; v_new text;
begin
  select stage into v_stage from fabula.sales_leads where id = new.lead_id;
  v_rank := array_position(array['nuovo','contattato','degustazione','offerta','cliente'], v_stage);
  v_new := case when new.kind in ('chiamata','whatsapp','email','visita') then 'contattato'
                when new.kind in ('degustazione','campione') then 'degustazione'
                when new.kind = 'offerta' then 'offerta'
                when new.kind = 'ordine' then 'cliente' end;
  update fabula.sales_leads l set
     last_contact_at = case when new.kind <> 'nota' then greatest(coalesce(l.last_contact_at, new.at), new.at) else l.last_contact_at end,
     stage = case when v_new is not null and v_rank is not null and array_position(array['nuovo','contattato','degustazione','offerta','cliente'], v_new) > v_rank then v_new
                  when v_new is not null and l.stage = 'in_pausa' then v_new else l.stage end,
     tasting_date = case when new.kind = 'degustazione' and new.next_action_date is not null and l.tasting_date is null then new.next_action_date else l.tasting_date end,
     next_action = case when new.next_action is not null or new.next_action_date is not null then new.next_action else l.next_action end,
     next_action_date = case when new.next_action is not null or new.next_action_date is not null then new.next_action_date else l.next_action_date end
   where l.id = new.lead_id;
  return new;
end $$;
drop trigger if exists sales_activities_apply on fabula.sales_activities;
create trigger sales_activities_apply after insert on fabula.sales_activities for each row execute function fabula.trg_sales_activity_apply();

-- ---------- classification ----------
create or replace function fabula.sales_segment_channel(p_segment text) returns text language sql immutable set search_path = fabula, public as $$
  select case when p_segment in ('hotel','bnb','agriturismo','lido') then 'hotel'
              when p_segment in ('pizzeria','ristorante','gastronomia','altro') then 'ristoranti' end
$$;

create or replace function fabula.party_segment(p_party uuid) returns text language sql stable set search_path = fabula, public as $$
  select coalesce(p.segment,
    case when exists (select 1 from unnest(p.tags) t where lower(t) ~ '(hotel|albergo|b&b|bnb|bed|agritur|lido|resort|stabiliment)') then
           case when exists (select 1 from unnest(p.tags) t where lower(t) ~ 'agritur') then 'agriturismo'
                when exists (select 1 from unnest(p.tags) t where lower(t) ~ '(lido|stabiliment)') then 'lido'
                when exists (select 1 from unnest(p.tags) t where lower(t) ~ '(b&b|bnb|bed)') then 'bnb' else 'hotel' end
         when exists (select 1 from unnest(p.tags) t where lower(t) ~ 'pizz') then 'pizzeria'
         when exists (select 1 from unnest(p.tags) t where lower(t) ~ '(ristor|tratt|osteria|horeca)') then 'ristorante'
         when exists (select 1 from unnest(p.tags) t where lower(t) ~ '(gastronom|salumer|alimentari)') then 'gastronomia'
         when p.is_wholesale then 'ristorante' else 'privato' end)
  from fabula.parties p where p.id = p_party
$$;

create or replace function fabula.sales_order_channel(p_channel fabula.sales_channel, p_marketplace text, p_customer uuid) returns text
language sql stable set search_path = fabula, public as $$
  select case when p_marketplace is not null and p_marketplace <> '' then 'delivery'
              when p_channel = 'store_pos' then 'banco'
              when p_channel = 'shopify' then 'online'
              else coalesce(fabula.sales_segment_channel(fabula.party_segment(p_customer)), 'ristoranti') end
$$;

create or replace view fabula.v_sales_daily with (security_invoker = true) as
with s as (select coalesce(nullif((select value from fabula.settings where key = 'sales.whey_sku_regex'), ''), '^RIC') rx)
select o.order_date,
       fabula.sales_order_channel(o.channel, o.marketplace, o.customer_id) as channel,
       count(distinct o.id) as orders,
       count(distinct o.customer_id) as customers,
       round(sum(coalesce(l.kg_milk, 0)), 1) as kg,
       round(sum(coalesce(l.kg_all, 0)), 1) as kg_all,
       round(sum(coalesce(o.subtotal_eur, o.total_eur - coalesce(o.iva_eur, 0), 0)), 2) as revenue_net_eur
  from fabula.sales_orders o
  cross join s
  left join lateral (
     select sum(sol.qty) filter (where p.unit = 'kg' and p.sku !~ s.rx) as kg_milk,
            sum(sol.qty) filter (where p.unit = 'kg') as kg_all
       from fabula.sales_order_lines sol join fabula.products p on p.id = sol.product_id
      where sol.sales_order_id = o.id) l on true
 where o.status not in ('cancelled', 'refunded', 'draft')
 group by 1, 2;

-- ---------- targets ----------
create or replace function fabula.sales_plan_start() returns date language sql stable set search_path = fabula, public as $$
  select date_trunc('month', coalesce(
           nullif((select value from fabula.settings where key = 'sales.plan_start'), '')::date,
           nullif((select value from fabula.settings where key = 'mkt.store_opening_date'), '')::date))::date
$$;

create or replace function fabula.sales_month_no(p_date date) returns int language sql stable set search_path = fabula, public as $$
  select case when fabula.sales_plan_start() is null or p_date < fabula.sales_plan_start() then null
    else ((extract(year from p_date) - extract(year from fabula.sales_plan_start())) * 12
         + extract(month from p_date) - extract(month from fabula.sales_plan_start()))::int + 1 end
$$;

-- kg/day target for one channel on one date (ramp interpolated × seasonality normalised to a mean of 1)
create or replace function fabula.sales_target_kg_day(p_channel text, p_date date) returns numeric language plpgsql stable set search_path = fabula, public as $$
declare m int := fabula.sales_month_no(p_date); lo record; hi record; base numeric; sf numeric; savg numeric;
begin
  if m is null then return null; end if;
  select month_no, kg_day into lo from fabula.sales_ramp where channel = p_channel and month_no <= m order by month_no desc limit 1;
  select month_no, kg_day into hi from fabula.sales_ramp where channel = p_channel and month_no >= m order by month_no limit 1;
  if lo.month_no is null and hi.month_no is null then return null; end if;
  if lo.month_no is null then base := hi.kg_day;
  elsif hi.month_no is null or hi.month_no = lo.month_no then base := lo.kg_day;
  else base := lo.kg_day + (hi.kg_day - lo.kg_day) * (m - lo.month_no)::numeric / (hi.month_no - lo.month_no); end if;
  select avg(factor) into savg from fabula.sales_seasonality where channel = p_channel;
  select factor into sf from fabula.sales_seasonality where channel = p_channel and month = extract(month from p_date);
  return round(base * coalesce(sf / nullif(savg, 0), 1), 1);
end $$;

-- 24-month plan table (for the console and the plan doc)
create or replace view fabula.v_sales_plan_months with (security_invoker = true) as
with st as (select fabula.sales_plan_start() d),
     y as (select coalesce(nullif((select value from fabula.settings where key = 'sales.yield_pct'), '')::numeric, 30) / 100 r)
select g.m as month_no,
       (st.d + make_interval(months => g.m - 1))::date as month,
       c.code as channel, c.name_it, c.sort,
       fabula.sales_target_kg_day(c.code, (st.d + make_interval(months => g.m - 1))::date) as kg_day,
       round(fabula.sales_target_kg_day(c.code, (st.d + make_interval(months => g.m - 1))::date)
             * extract(day from (date_trunc('month', st.d + make_interval(months => g.m - 1)) + interval '1 month - 1 day')) * c.price_net_eur_kg, 0) as revenue_net_eur,
       round(fabula.sales_target_kg_day(c.code, (st.d + make_interval(months => g.m - 1))::date) / y.r, 0) as milk_l_day
  from st, y, generate_series(1, 24) g(m), fabula.sales_plan_channels c
 where st.d is not null and c.active;

-- ---------- lead helpers ----------
create or replace function fabula.sales_add_lead(p jsonb) returns jsonb language plpgsql set search_path = fabula, public as $$
declare v_id uuid; v_exists uuid;
begin
  perform fabula.require_perm('vendite', 2);
  if coalesce(trim(p->>'name'), '') = '' then raise exception 'name obbligatorio'; end if;
  select id into v_exists from fabula.sales_leads where lower(name) = lower(trim(p->>'name')) and lower(coalesce(town, '')) = lower(coalesce(trim(p->>'town'), ''));
  if v_exists is not null then return jsonb_build_object('id', v_exists, 'created', false, 'reason', 'già presente'); end if;
  if exists (select 1 from fabula.parties where active and lower(coalesce(trade_name, legal_name)) = lower(trim(p->>'name'))) then
    return jsonb_build_object('created', false, 'reason', 'già cliente');
  end if;
  insert into fabula.sales_leads (name, segment, town, address, phone, email, website, instagram, fit_note, size_hint, current_supplier,
                                  source, source_url, priority, est_kg_week, next_action, next_action_date, notes)
  values (trim(p->>'name'), coalesce(p->>'segment', 'ristorante'), nullif(p->>'town', ''), nullif(p->>'address', ''), nullif(p->>'phone', ''),
          nullif(p->>'email', ''), nullif(p->>'website', ''), nullif(p->>'instagram', ''), nullif(p->>'fit_note', ''), nullif(p->>'size_hint', ''),
          nullif(p->>'current_supplier', ''), coalesce(nullif(p->>'source', ''), 'manuale'), nullif(p->>'source_url', ''),
          coalesce((p->>'priority')::smallint, 2), nullif(p->>'est_kg_week', '')::numeric,
          coalesce(nullif(p->>'next_action', ''), 'Primo contatto (WhatsApp o visita)'),
          coalesce(nullif(p->>'next_action_date', '')::date, (now() at time zone 'Europe/Rome')::date + 2), nullif(p->>'notes', ''))
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'created', true);
end $$;

create or replace function fabula.sales_log_activity(p_lead uuid, p_kind text, p_outcome text default null, p_note text default null,
                                                     p_next_action text default null, p_next_date date default null) returns uuid
language plpgsql set search_path = fabula, public as $$
declare v_id uuid; v_who text;
begin
  perform fabula.require_perm('vendite', 2);
  select full_name into v_who from fabula.staff where auth_user_id = auth.uid();
  insert into fabula.sales_activities (lead_id, kind, outcome, note, next_action, next_action_date, staff_name)
  values (p_lead, p_kind, nullif(p_outcome, ''), nullif(p_note, ''), nullif(p_next_action, ''), p_next_date, coalesce(v_who, 'sistema'))
  returning id into v_id;
  return v_id;
end $$;

-- leads that became customers in Shopify (same e-mail, phone digits or name) are linked and marked won; their segment is copied to the party
create or replace function fabula.sales_autolink_leads() returns jsonb language plpgsql set search_path = fabula, public as $$
declare r record; out jsonb := '[]'::jsonb; v_party uuid;
begin
  perform fabula.require_perm('vendite', 2);
  for r in select * from fabula.sales_leads where party_id is null and stage not in ('perso') loop
    select p.id into v_party from fabula.parties p
     where p.active and p.type in ('customer', 'both') and (
           (r.email is not null and lower(p.email) = lower(r.email))
        or (r.phone is not null and length(regexp_replace(r.phone, '\D', '', 'g')) >= 8
            and right(regexp_replace(coalesce(p.phone, ''), '\D', '', 'g'), 9) = right(regexp_replace(r.phone, '\D', '', 'g'), 9))
        or lower(coalesce(p.trade_name, p.legal_name)) = lower(r.name))
     limit 1;
    if v_party is not null then
      update fabula.sales_leads set party_id = v_party, stage = 'cliente' where id = r.id;
      update fabula.parties set segment = coalesce(segment, r.segment) where id = v_party;
      out := out || jsonb_build_object('lead', r.name, 'party_id', v_party);
    end if;
  end loop;
  return out;
end $$;

-- ready-to-send Italian messages (WhatsApp/e-mail). Brand rules: never imply other DOP are not 100% buffalo; never attach "Cilento" to the DOP name.
create or replace function fabula.sales_lead_message(p_lead uuid, p_kind text default 'primo_contatto') returns text
language plpgsql stable set search_path = fabula, public as $$
declare l fabula.sales_leads; px numeric := coalesce(nullif((select value from fabula.settings where key = 'price.wholesale_moz_eur_kg'), '')::numeric, 11.5);
        hook text; pxs text;
begin
  select * into l from fabula.sales_leads where id = p_lead;
  if l.id is null then return null; end if;
  pxs := replace(to_char(px, 'FM990.00'), '.', ',');
  hook := case l.segment
    when 'pizzeria' then 'per una margherita o una pizza con bufala, consegnata fresca ogni mattina'
    when 'ristorante' then 'per caprese, antipasti e piatti con bufala, consegnata fresca ogni mattina'
    when 'hotel' then 'per la colazione e il ristorante dell''hotel, in formati da buffet (bocconcini, ciliegine, nodini)'
    when 'bnb' then 'per la colazione dei vostri ospiti, anche in piccole quantità'
    when 'agriturismo' then 'per la vostra cucina e le colazioni, con una filiera corta da raccontare agli ospiti'
    when 'lido' then 'per insalate, caprese e panini del vostro bar-ristorante, consegnata fresca ogni mattina'
    else 'per la vostra attività, consegnata fresca ogni mattina' end;
  return case p_kind
    when 'primo_contatto' then format(
      'Buongiorno %s! Sono Nick de La Perla del Cilento, il nuovo caseificio-bottega di Agropoli. Facciamo Mozzarella di Bufala Campana DOP solo con il latte delle nostre bufale della Masseria Cilentana, lavorato lo stesso giorno della mungitura. Vorrei proporvela %s. Posso passare questa settimana a farvela assaggiare? Bastano 10 minuti.',
      l.name, hook)
    when 'follow_up' then format(
      'Buongiorno %s, sono Nick de La Perla del Cilento. Vi avevo scritto per un assaggio della nostra mozzarella di bufala DOP. Se vi va, passo io con un campione nel giorno che preferite: mi dite quando siete più tranquilli?',
      l.name)
    when 'degustazione' then format(
      'Grazie %s! Confermo: passo %s con un campione di mozzarella di bufala DOP appena fatta (bocconcini e treccia) così la provate in cucina. Se avete un formato preferito ditemelo e lo porto.',
      l.name, coalesce(to_char(coalesce(l.tasting_date, l.next_action_date), 'DD/MM'), 'nei prossimi giorni'))
    when 'offerta' then format(
      'Buongiorno %s, come promesso ecco la proposta de La Perla del Cilento: Mozzarella di Bufala Campana DOP a € %s/kg IVA esclusa, consegna gratuita ad Agropoli e dintorni ogni mattina entro le 10, ordine fisso settimanale modificabile entro le 18 del giorno prima, fattura elettronica a fine mese. Possiamo partire già da lunedì: mi dite quanti kg vi servono per giorno?',
      l.name, pxs)
    else null end;
end $$;

-- ---------- status read by the Vendite bot and the console ----------
create or replace function fabula.sales_status(p_date date default null) returns jsonb language plpgsql stable set search_path = fabula, public as $$
declare
  d date := coalesce(p_date, (now() at time zone 'Europe/Rome')::date);
  m0 date := date_trunc('month', d)::date;
  days_in int := extract(day from (date_trunc('month', d) + interval '1 month - 1 day'))::int;
  elapsed int := extract(day from d)::int;     -- includes today (sales of today may still arrive)
  yld numeric := coalesce(nullif((select value from fabula.settings where key = 'sales.yield_pct'), '')::numeric, 30) / 100;
  stale_d int := coalesce(nullif((select value from fabula.settings where key = 'sales.lead_stale_days'), '')::int, 14);
  min_leads int := coalesce(nullif((select value from fabula.settings where key = 'sales.min_active_leads'), '')::int, 25);
  per_run int := coalesce(nullif((select value from fabula.settings where key = 'sales.research_per_run'), '')::int, 5);
  lapsed_d int := coalesce(nullif((select value from fabula.settings where key = 'sales.lapsed_days'), '')::int, 14);
  cap numeric := coalesce(nullif((select value from fabula.settings where key = 'milk.capacity_kg'), '')::numeric, 1200);
  farm numeric := coalesce(nullif((select value from fabula.settings where key = 'farm.default_kg_per_day'), '')::numeric, 0);
  tgt_l numeric := coalesce(nullif((select value from fabula.settings where key = 'sales.target_milk_l_day'), '')::numeric, 2000);
  ps date := fabula.sales_plan_start();
  mno int := fabula.sales_month_no(d);
  ch jsonb; tot jsonb; act_n int;
begin
  with c as (select * from fabula.sales_plan_channels where active),
       mtd as (select channel, sum(kg) kg, sum(revenue_net_eur) rev, sum(orders) orders from fabula.v_sales_daily where order_date between m0 and d group by 1),
       l7 as (select channel, sum(kg) kg from fabula.v_sales_daily where order_date between d - 6 and d group by 1),
       rows as (
         select c.code, c.name_it, c.sort, c.full_kg_day, c.price_net_eur_kg,
                fabula.sales_target_kg_day(c.code, d) t,
                coalesce(mtd.kg, 0) mkg, coalesce(mtd.rev, 0) mrev, coalesce(mtd.orders, 0) mord, coalesce(l7.kg, 0) / 7.0 l7d
           from c left join mtd on mtd.channel = c.code left join l7 on l7.channel = c.code)
  select jsonb_agg(jsonb_build_object(
           'code', code, 'name', name_it, 'full_kg_day', full_kg_day,
           'target_kg_day', t, 'month_target_kg', round(t * days_in, 0), 'month_target_eur', round(t * days_in * price_net_eur_kg, 0),
           'mtd_kg', round(mkg, 1), 'mtd_kg_day', round(mkg / elapsed, 1), 'last7_kg_day', round(l7d, 1),
           'mtd_revenue_eur', round(mrev, 0), 'mtd_orders', mord,
           'pct_of_target', case when t > 0 then round(100 * (mkg / elapsed) / t) end,
           'needed_kg_day_rest', case when t is not null and days_in > elapsed then greatest(0, round((t * days_in - mkg) / (days_in - elapsed), 1)) end)
         order by sort),
         jsonb_build_object(
           'target_kg_day', round(sum(t), 1), 'mtd_kg_day', round(sum(mkg) / elapsed, 1), 'last7_kg_day', round(sum(l7d), 1),
           'mtd_revenue_eur', round(sum(mrev), 0), 'month_target_eur', round(sum(t * days_in * price_net_eur_kg), 0),
           'milk_l_day_last7', round(sum(l7d) / yld, 0), 'milk_l_day_target_month', round(sum(t) / yld, 0),
           'milk_l_day_full', tgt_l, 'plant_capacity_l_day', cap, 'farm_l_day_setting', farm,
           'pct_of_full_volume', round(100 * (sum(l7d) / yld) / nullif(tgt_l, 0)),
           'capacity_warning', (sum(t) / yld) > cap * 0.9)
    into ch, tot from rows;

  select count(*) into act_n from fabula.sales_leads where stage in ('nuovo','contattato','degustazione','offerta');

  return jsonb_build_object(
    'date', d, 'plan_start', ps, 'month_no', mno, 'plan_missing', ps is null, 'yield_pct', yld * 100,
    'channels', coalesce(ch, '[]'::jsonb), 'totals', tot,
    'pipeline', jsonb_build_object(
       'active_n', act_n,
       'by_stage', (select coalesce(jsonb_agg(jsonb_build_object('stage', stage, 'n', n, 'est_kg_week', kg) order by array_position(array['nuovo','contattato','degustazione','offerta','cliente','in_pausa','perso'], stage)), '[]')
                      from (select stage, count(*) n, round(sum(est_kg_week), 0) kg from fabula.sales_leads group by stage) s),
       'by_channel', (select coalesce(jsonb_agg(jsonb_build_object('channel', ch, 'open_n', n, 'open_kg_week', kg)), '[]')
                      from (select fabula.sales_segment_channel(segment) ch, count(*) n, round(sum(est_kg_week), 0) kg
                              from fabula.sales_leads where stage in ('nuovo','contattato','degustazione','offerta') group by 1) s),
       'open_kg_day', (select round(coalesce(sum(est_kg_week), 0) / 7, 1) from fabula.sales_leads where stage in ('contattato','degustazione','offerta'))),
    'actions_due', (select coalesce(jsonb_agg(x order by x->>'due', (x->>'priority')::int), '[]') from (
        select jsonb_build_object('id', id, 'name', name, 'segment', segment, 'town', town, 'stage', stage, 'priority', priority,
                 'phone', phone, 'instagram', instagram, 'next_action', next_action, 'due', next_action_date,
                 'overdue_days', d - next_action_date, 'est_kg_week', est_kg_week, 'fit_note', fit_note, 'current_supplier', current_supplier) x
          from fabula.sales_leads
         where stage in ('nuovo','contattato','degustazione','offerta') and next_action_date <= d + 1
         order by next_action_date, priority limit 15) q),
    'stale', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'town', town, 'stage', stage,
                 'days_since_contact', d - (last_contact_at at time zone 'Europe/Rome')::date)), '[]')
                from (select * from fabula.sales_leads where stage in ('contattato','degustazione','offerta')
                        and (last_contact_at is null or (last_contact_at at time zone 'Europe/Rome')::date < d - stale_d)
                      order by last_contact_at nulls first limit 10) s),
    'tastings_next_7d', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'town', town, 'date', tasting_date) order by tasting_date), '[]')
                from fabula.sales_leads where tasting_date between d and d + 7 and stage not in ('perso','cliente')),
    'won_this_month', (select coalesce(jsonb_agg(jsonb_build_object('name', name, 'segment', segment, 'est_kg_week', est_kg_week)), '[]')
                from fabula.sales_leads where won_at >= m0),
    'lost_this_month', (select count(*) from fabula.sales_leads where stage = 'perso' and stage_changed_at >= m0),
    'accounts', jsonb_build_object(
       'active_b2b_30d', (select count(distinct o.customer_id) from fabula.sales_orders o
                           where o.channel = 'wholesale' and o.order_date > d - 30 and o.status not in ('cancelled','refunded','draft')),
       'standing_kg_week', (select round(coalesce(sum(qty_kg), 0), 1) from fabula.standing_orders where active),
       'lapsed', (select coalesce(jsonb_agg(jsonb_build_object('customer', coalesce(p.trade_name, p.legal_name), 'phone', p.phone,
                          'last_order', x.last_order, 'days', d - x.last_order) order by x.last_order), '[]')
                    from (select customer_id, max(order_date) last_order from fabula.sales_orders
                           where channel = 'wholesale' and status not in ('cancelled','refunded','draft') group by 1) x
                    join fabula.parties p on p.id = x.customer_id
                   where x.last_order < d - lapsed_d and x.last_order > d - 120 and p.notes is distinct from 'placeholder'
                     and not exists (select 1 from fabula.standing_orders s where s.customer_id = x.customer_id and s.active))),
    'marketplaces', (select coalesce(jsonb_agg(jsonb_build_object('code', m.code, 'name', m.name, 'status', m.status,
                        'commission_pct', m.commission_pct, 'markup_pct', m.markup_pct,
                        'orders_30d', (select count(*) from fabula.sales_orders o where o.marketplace = m.code and o.order_date > d - 30 and o.status not in ('cancelled','refunded','draft')))
                        order by m.sort), '[]') from fabula.mkt_channels m where m.kind = 'marketplace'),
    'web', (select jsonb_build_object('site_status', (select status from fabula.mkt_channels where code = 'sito'),
                     'pickup_status', (select status from fabula.mkt_channels where code = 'ritiro'))),
    'research', jsonb_build_object('min_active_leads', min_leads, 'active_n', act_n, 'needed', least(per_run, greatest(0, min_leads - act_n)), 'per_run', per_run,
                     'towns_covered', (select coalesce(jsonb_agg(distinct town), '[]') from fabula.sales_leads where town is not null))
  );
end $$;

-- ---------- access (area vendite) ----------
insert into fabula.table_areas (table_name, area, write_level, read_open) values
 ('sales_plan_channels', 'vendite', 3, false), ('sales_ramp', 'vendite', 3, false), ('sales_seasonality', 'vendite', 3, false),
 ('sales_leads', 'vendite', 2, false), ('sales_activities', 'vendite', 2, false)
on conflict (table_name) do update set area = excluded.area, write_level = excluded.write_level, read_open = excluded.read_open;

do $$ declare t text; begin
  foreach t in array array['sales_plan_channels','sales_ramp','sales_seasonality','sales_leads','sales_activities'] loop
    execute format('alter table fabula.%I enable row level security', t);
    execute format('drop policy if exists %I on fabula.%I', t || '_authenticated_all', t);
    execute format('create policy %I on fabula.%I for all to authenticated using (true) with check (true)', t || '_authenticated_all', t);
    execute format('drop policy if exists %I on fabula.%I', t || '_role_select', t);
    execute format('create policy %I on fabula.%I as restrictive for select to authenticated using ((select fabula.can_table(%L, false)))', t || '_role_select', t, t);
    execute format('drop policy if exists %I on fabula.%I', t || '_role_insert', t);
    execute format('create policy %I on fabula.%I as restrictive for insert to authenticated with check ((select fabula.can_table(%L, true)))', t || '_role_insert', t, t);
    execute format('drop policy if exists %I on fabula.%I', t || '_role_update', t);
    execute format('create policy %I on fabula.%I as restrictive for update to authenticated using ((select fabula.can_table(%L, true)))', t || '_role_update', t, t);
    execute format('drop policy if exists %I on fabula.%I', t || '_role_delete', t);
    execute format('create policy %I on fabula.%I as restrictive for delete to authenticated using ((select fabula.can_table(%L, true)))', t || '_role_delete', t, t);
    execute format('grant select, insert, update, delete on fabula.%I to authenticated, service_role', t);
    execute format('revoke all on fabula.%I from anon', t);
  end loop;
end $$;
grant select on fabula.v_sales_daily, fabula.v_sales_plan_months to authenticated, service_role;
revoke all on fabula.v_sales_daily, fabula.v_sales_plan_months from anon;

do $$ declare f text; begin
  foreach f in array array['sales_segment_channel(text)','party_segment(uuid)','sales_order_channel(fabula.sales_channel,text,uuid)','sales_plan_start()',
    'sales_month_no(date)','sales_target_kg_day(text,date)','sales_add_lead(jsonb)','sales_log_activity(uuid,text,text,text,text,date)',
    'sales_autolink_leads()','sales_lead_message(uuid,text)','sales_status(date)','trg_sales_lead_touch()','trg_sales_activity_apply()'] loop
    execute format('revoke all on function fabula.%s from public, anon', f);
    execute format('grant execute on function fabula.%s to authenticated, service_role', f);
  end loop;
end $$;

-- console page "vendite" for profiles that see the vendite area
create or replace function fabula.my_permissions() returns jsonb language sql stable security definer set search_path = fabula, public as $function$
  select case when s.id is null then jsonb_build_object('staff_id', null, 'active', false, 'areas', '{}'::jsonb, 'pages', '{}'::jsonb)
  else jsonb_build_object(
    'staff_id', s.id, 'full_name', s.full_name, 'job_role', s.role, 'role', r.code, 'role_name', r.name_it, 'home', r.home, 'active', s.active,
    'can_manage_users', r.can_manage_users,
    'areas', (select jsonb_object_agg(a.code, coalesce(rp.level, case when a.code = 'comune' then 2 else 0 end)) from fabula.app_areas a
              left join fabula.role_permissions rp on rp.role_code = r.code and rp.area = a.code),
    'pages', jsonb_build_object(
       'tablet',   exists (select 1 from fabula.role_permissions where role_code = r.code and area in ('produzione','haccp','magazzino','spedizioni') and level >= 2),
       'console',  exists (select 1 from fabula.role_permissions where role_code = r.code and area in ('produzione','acquisti','vendite','magazzino','personale','finanza') and level >= 1),
       'haccp',    exists (select 1 from fabula.role_permissions where role_code = r.code and area = 'haccp' and level >= 1),
       'marketing',exists (select 1 from fabula.role_permissions where role_code = r.code and area = 'marketing' and level >= 1),
       'vendite',  exists (select 1 from fabula.role_permissions where role_code = r.code and area = 'vendite' and level >= 1),
       'pacchetto',exists (select 1 from fabula.role_permissions where role_code = r.code and area = 'finanza' and level >= 1),
       'admin',    exists (select 1 from fabula.role_permissions where role_code = r.code and area = 'sistema' and level >= 1)))
  end
  from (select 1) x left join fabula.staff s on s.auth_user_id = auth.uid() and s.active left join fabula.app_roles r on r.code = s.app_role
$function$;

-- ---------- Vendite bot: schedule + watchdog ----------
insert into fabula.bot_schedule (agent, name_it, due_times, weekdays, month_day, grace_min, active)
values ('sales', 'Vendite', array['08:04'::time], array[1,3,5], null, 45, true)
on conflict (agent) do update set name_it = excluded.name_it, due_times = excluded.due_times, weekdays = excluded.weekdays, active = true;

create or replace function fabula.expected_bots(p_date date) returns table(agent text) language sql immutable set search_path = fabula, public, extensions as $function$
  select a from unnest(array['daily_brief','procurement','wholesale_orders','milk_planning','sell_down','haccp_nudge','shopify_customers','shopify_orders','shopify_inventory']) a where extract(isodow from p_date) between 1 and 6
  union all select 'weekly_brief' where extract(isodow from p_date) = 1
  union all select 'compliance_calendar' where extract(isodow from p_date) = 2
  union all select 'marketing' where extract(isodow from p_date) in (1, 4)
  union all select 'sales' where extract(isodow from p_date) in (1, 3, 5)
  union all select 'monthly_review' where extract(day from p_date) = 1
  union all select 'backup_export'
$function$;
