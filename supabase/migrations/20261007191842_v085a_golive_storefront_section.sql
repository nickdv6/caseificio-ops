-- v0.85a: Storefront section on the Go-Live Board (curb appeal & exposure to-do, 07/10/2026)
create table if not exists fabula.dash_storefront (
  key text primary key check (key ~ '^[a-z_]+$'),
  phase text not null,
  phase_sort int not null,
  sort int not null default 0,
  label text not null,
  detail text,
  offset_days int not null,          -- due date = opening date + offset_days
  local_code text,                   -- optional link to mkt_local_items.code
  done boolean not null default false,
  done_at timestamptz,
  updated_at timestamptz not null default now()
);
alter table fabula.dash_storefront enable row level security;
revoke all on fabula.dash_storefront from anon;

do $$ begin
  if not exists (select 1 from pg_policies where schemaname='fabula' and tablename='dash_storefront' and policyname='dash_storefront_role_select') then
    create policy dash_storefront_role_select on fabula.dash_storefront for select to authenticated
      using ((select fabula.can_table('dash_storefront'::text, false)));
  end if;
end $$;

insert into fabula.dash_storefront (key, phase, phase_sort, sort, label, detail, offset_days, local_code) values
 ('sf_deed_assets','Before the deed',1,1,'Asset list: Google listing, phone number, sign box','Add Google Business Profile ownership, the shop phone number and the existing sign box, brackets and power feed to the asset purchase.',-75,null),
 ('sf_deed_removal','Before the deed',1,2,'Agree who removes the Fabula branding','Seller removes signs, window stickers, feather flag and planter print, or a price credit.',-75,null),
 ('sf_condo_consent','Before the deed',1,3,'Landlord and condominium consent for signs and awning','Written consent for front sign, projecting sign, side-wall sign and pergola awning; get the regolamento condominiale.',-75,null),
 ('sf_forecourt_land','Before the deed',1,4,'Forecourt: private or public land?','Decides whether tables, planter and A-board need a suolo pubblico permit.',-75,null),
 ('sf_brand_final','Brand final',2,1,'Brand and logo final','Sign quotes and the SUAP sign permit cannot start without it.',-70,null),
 ('sf_sign_brief','Brand final',2,2,'Sign brief','High contrast, readable at 30 m, one claim only. No DOP logo or DOP wording until the Consorzio authorises.',-70,null),
 ('sf_front_sign','Permit items',3,1,'Lit front sign, 5 m² or less','Stays inside the canone-unico exemption; reuse the existing sign box if sound.',-45,'SIG-01'),
 ('sf_blade_sign','Permit items',3,2,'Projecting sign at the right corner','Seen by traffic approaching along the building.',-45,'SIG-03'),
 ('sf_side_wall','Permit items',3,3,'Sign on the blank side wall facing the parking','Check against the 5 m² total and the condominium consent.',-45,null),
 ('sf_road_signs','Permit items',3,4,'Two road signs on the main approaches','Codice della Strada permit.',-45,'SIG-07'),
 ('sf_pergola','Permit items',3,5,'Pergola cover or awning in brand colours','Replace or open the umbrella.',-45,null),
 ('sf_consorzio_logo','Permit items',3,6,'Consorzio logo on signs (only if authorised)',null,-45,'SIG-08'),
 ('sf_strip_fabula','Pre-opening exposure',4,1,'Remove all Fabula branding','Side panels, window stickers, feather flag, planter print.',-31,null),
 ('sf_coming_soon','Pre-opening exposure',4,2,'"Coming soon" window wrap','Brand + "Apre il 15 febbraio" + QR code to the WhatsApp list or pre-orders.',-31,null),
 ('sf_google_profile','Pre-opening exposure',4,3,'Google listing: new name, photos, hours','Categories Caseificio and Negozio di formaggi, pre-order link, real photos; add Apple Maps and TripAdvisor.',-31,'ADV-01'),
 ('sf_planter','Pre-opening exposure',4,4,'Repaint and replant the planter; repaint the base and pergola post',null,-31,null),
 ('sf_window_light','Shopfront finish',5,1,'Window lighting brighter than the street','Stops the mirror effect; keep the window lit until about 22:00 in summer.',-14,null),
 ('sf_visible_making','Shopfront finish',5,2,'Cheesemaking visible from the street','Counter or stretching station in view; live stretching on weekend mornings.',-14,null),
 ('sf_window_vinyl','Shopfront finish',5,3,'Window stickers in one band only','Hours, payments, QR, "prodotta qui oggi"; keep the rest of the glass clear.',-14,'SIG-02'),
 ('sf_panels','Shopfront finish',5,4,'Replace product lists with 3 main products + herd → dairy → counter panel',null,-14,'SIG-06'),
 ('sf_today_board','Shopfront finish',5,5,'"Oggi al banco" board',null,-14,'SIG-04'),
 ('sf_price_list','Shopfront finish',5,6,'Price per kg and allergen list',null,-14,'SIG-05'),
 ('sf_outdoor','Shopfront finish',5,7,'Matching outdoor furniture; replace or drop the feather flag','Keep the milk churns as decoration.',-14,null),
 ('sf_flyers','Opening',6,1,'Flyers with BENVENUTO10',null,-3,'ADV-04'),
 ('sf_opening_stretch','Opening',6,2,'Live stretching demo outside on opening day',null,0,'ADV-08'),
 ('sf_reviews','After opening',7,1,'Ask early customers for Google reviews; weekly photos on the listing',null,30,null),
 ('sf_summer','After opening',7,2,'Hotel and beach-club postcards; evening lighting check',null,150,'ADV-09')
on conflict (key) do update set phase=excluded.phase, phase_sort=excluded.phase_sort, sort=excluded.sort,
  label=excluded.label, detail=excluded.detail, offset_days=excluded.offset_days, local_code=excluded.local_code, updated_at=now();

create or replace function fabula.storefront_board()
returns jsonb language sql stable
set search_path to 'fabula','public','extensions'
as $f$
  with o as (select nullif(fabula.setting_text('mkt.store_opening_date', null),'')::date as d),
  r as (
    select s.*, (select d from o) + s.offset_days as due_on,
           li.status as local_status, li.permit_status,
           (s.done or coalesce(li.status in ('installato','attivo','concluso'), false)) as is_done
      from fabula.dash_storefront s
      left join fabula.mkt_local_items li on li.code = s.local_code
  )
  select jsonb_build_object(
    'opening', (select d from o),
    'total', count(*), 'done', count(*) filter (where is_done),
    'overdue', count(*) filter (where not is_done and due_on < (now() at time zone 'Europe/Rome')::date),
    'items', coalesce(jsonb_agg(jsonb_build_object(
       'key', key, 'phase', phase, 'label', label, 'detail', detail, 'due_on', due_on,
       'local_code', local_code, 'local_status', local_status, 'permit_status', permit_status,
       'done', is_done, 'manual_done', done, 'linked_done', is_done and not done)
       order by phase_sort, sort), '[]'::jsonb))
  from r
$f$;

create or replace function fabula.dash_set_storefront(p_key text, p_done boolean)
returns jsonb language plpgsql
set search_path to 'fabula','public','extensions'
as $f$
declare r fabula.dash_storefront;
begin
  update fabula.dash_storefront
     set done = p_done, done_at = case when p_done then now() end, updated_at = now()
   where key = p_key
  returning * into r;
  if r.key is null then raise exception 'dash_set_storefront: unknown item %', p_key; end if;
  return to_jsonb(r);
end $f$;

revoke execute on function fabula.storefront_board() from public, anon, authenticated;
revoke execute on function fabula.dash_set_storefront(text, boolean) from public, anon, authenticated;
grant execute on function fabula.storefront_board() to service_role;
grant execute on function fabula.dash_set_storefront(text, boolean) to service_role;
