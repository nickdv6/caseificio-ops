-- v0.99a–b for the Supabase dashboard SQL Editor (13/10/2026): office decisions and undo, from the 12/10 audit.
--   v0.99a  B-09 milk plan «Approva con … kg», warnings, «Ordina di nuovo» · B-11 DOP declaration «Segna inviata» · B-12 urgency,
--           «Annulla» and history · D-24 a decision stays decided · E-10 automatic approvals said and undoable · E-12/E-11 deadlines
--           every 10 minutes · B-13 post card = what gets published · FIX: a milk plan approved in the Console now reaches the farm
--   v0.99b  B-18 catalogue orders (limit, creator, «Annulla ordine») · B-19 milk forecast and Vendite from the Ingrosso plans ·
--           B-15 «Togli» from tomorrow / «Rimetti» · B-06 lot release and NC closing · B-22/B-23 what Shopify has · TRADE-06 notice
-- Same files as supabase/migrations/20261013210000_* and 20261013210100_* (built by make_v099_script.py).
-- One transaction: if any step fails nothing changes. It records the two versions in the migration history and refuses a second run.
-- Paste everything, Run, and check the last result shows 20261013210100 and 20261013210000 at the top.
-- AFTER this: deploy the trade-portal function, then the site (git push of branch v099-office to main).
begin;
do $chk$ begin
  if exists (select 1 from supabase_migrations.schema_migrations where version in ('20261013210000', '20261013210100')) then
    raise exception 'STOP: v0.99 is already in the migration history — nothing to do';
  end if;
  if (select max(version) from supabase_migrations.schema_migrations) <> '20261013200200' then
    raise exception 'STOP: the live history does not end at 20261013200200 (v098c_trade_quantities_prices) — tell Claude before applying';
  end if;
end $chk$;

-- ======================= v099a =======================
-- v0.99a · Audit 12/10/2026, office decisions and undo (1/2): the approvals in Console → Oggi.
--   D-24   A decided request cannot be decided again (BEFORE UPDATE guard); approving after its deadline is refused.
--   E-12   Deadlines are applied every 10 minutes (with the auto-approval cron), not once a day by the evening check.
--   E-11   An expiry posts «Scaduta senza decisione» with what it means; an expired milk plan is also pushed (no milk ordered).
--   B-12   decide_approval() decides with the signer from the login; every change of status goes into approvals.history.
--          v_approvals_recent lists what was decided or expired in the last 7 days; revoke_approval() («Annulla») puts a
--          decision back to «da decidere» while nothing has happened downstream: a milk plan until the Masseria has seen it, a
--          purchase order until it is sent, a promo until its posts are out, a post until it is scheduled, a DOP declaration
--          until it is marked sent, a rejection while still in time. A recall decision and an applied recipe dose never undo.
--   B-09   Milk plan: the approval carries the warnings (capacity, farm supply, minimum run, short history) so the card shows
--          them; «Approva con … kg» (decide_approval p_milk_kg) recomputes output and cost; after a rejection or an expiry
--          milk_order_again() proposes the day again or orders N kg directly.
--          FIX found while doing it: a milk plan decided by a person in the Console never reached the Masseria's page.
--          milk_plans has no UPDATE policy and the sync trigger ran as the user, so the update touched 0 rows; only
--          automatic approvals (run by the database) worked. The sync now runs as the database; stuck plans are repaired.
--   B-11   DOP declaration: approving approves the figures only; the monthly task closes with dop_declaration_sent()
--          (date and protocol or how it was sent). With disciplinare checks to look at, approving needs a note.
--   E-10   Auto-approval: plan_milk, propose_purchase_orders and sell_down_signals return when it will approve itself;
--          an automatic approval that commits milk or money is a 'warn' line, pushed on Telegram («Da decidere»), with what
--          can still be undone; posts written for an auto-approved promo wait for a person (status review); the message
--          points to Configurazione → Parametri → Approvazioni automatiche instead of «approve.*».
--   B-13   A post edited while it waits for approval refreshes its card (caption, hashtags, date, first image).

-- ============================================================================================================================
-- 1. Columns
-- ============================================================================================================================
alter table fabula.approvals add column if not exists history jsonb not null default '[]';
comment on column fabula.approvals.history is 'v0.99 (audit B-12/D-24): every change of status: [{at, from, to, by, note}]';
alter table fabula.purchase_orders add column if not exists created_by_id uuid references fabula.staff(id),
                                   add column if not exists cancelled_at timestamptz,
                                   add column if not exists cancelled_by_id uuid references fabula.staff(id),
                                   add column if not exists cancel_reason text;
comment on column fabula.purchase_orders.created_by_id is 'v0.99 (audit B-18): who created a manual order from the catalogue';
comment on column fabula.purchase_orders.cancel_reason is 'v0.99 (audit B-18): why the order was cancelled with «Annulla ordine» (cancel_po)';

-- ============================================================================================================================
-- 2. Helpers
-- ============================================================================================================================
-- «mer 14/10»
create or replace function fabula.it_day(p_d date) returns text language sql immutable set search_path = fabula, public as $$
  select (array['lun','mar','mer','gio','ven','sab','dom'])[extract(isodow from p_d)::int] || ' ' || to_char(p_d, 'DD/MM')
$$;
-- one word per kind of request, the same the Console uses
create or replace function fabula.approval_type(p_kind fabula.approval_kind, p_payload jsonb) returns text language sql immutable
set search_path = fabula, public as $$
  select case when p_kind = 'other' then coalesce(p_payload->>'type', 'other')
              when p_payload->>'type' = 'recipe_update' then 'recipe_update'
              when p_kind = 'price_change' and p_payload->>'type' = 'sell_down' then 'sell_down'
              else p_kind::text end
$$;

-- ============================================================================================================================
-- 3. FIX: decisions reach the milk plan (security definer) · «Annulla» puts things back · an expired PO is cancelled
-- ============================================================================================================================
create or replace function fabula.sync_po_from_approval() returns trigger
language plpgsql security definer set search_path = fabula, public, extensions as $$
declare pl jsonb;
begin
  if new.status is distinct from old.status then
    if new.related_table = 'purchase_orders' and new.related_id is not null then
      -- v0.99: rejected or expired = never approved → cancelled; back to pending («Annulla») → waiting for approval again.
      -- A sent or received order is never touched from here.
      update fabula.purchase_orders set status = case
               when new.status = 'approved' then 'approved'::fabula.po_status
               when new.status in ('rejected', 'expired') then 'cancelled'::fabula.po_status
               when new.status = 'pending' then 'pending_approval'::fabula.po_status
               else status end,
             updated_at = now()
       where id = new.related_id and status in ('draft', 'pending_approval', 'approved', 'cancelled')
         and not (status = 'cancelled' and cancel_reason is not null);
    elsif new.related_table = 'milk_plans' and new.related_id is not null then
      update fabula.milk_plans set status = case new.status when 'approved' then 'approved' when 'rejected' then 'rejected'
                                                            when 'expired' then 'rejected' when 'pending' then 'proposed' else status end
       where id = new.related_id and status in ('proposed', 'approved', 'rejected');
    elsif new.related_table = 'recipes' and new.status = 'approved' and new.payload->>'type' = 'recipe_update' then
      pl := new.payload;
      perform fabula.set_recipe(pl->>'finished_sku', pl->>'component_sku', (pl->>'basis')::fabula.recipe_basis, (pl->>'to_qty')::numeric,
                                (select round_up from fabula.recipes where id = (pl->>'recipe_id')::uuid),
                                (now() at time zone 'Europe/Rome')::date, 'measured', format('aggiornata da %s su %s lotti (approvazione %s)', pl->>'from_qty', pl->>'batches', new.id));
    end if;
  end if;
  return new;
end $$;
revoke all on function fabula.sync_po_from_approval() from public, anon, authenticated;

-- plans stuck at «proposed» after a person decided them in the Console (live: the 05/10 plan rejected by Nick)
update fabula.milk_plans mp set status = case a.status when 'approved' then 'approved' else 'rejected' end
  from fabula.approvals a
 where a.id = mp.approval_id and mp.status = 'proposed' and a.status in ('approved', 'rejected', 'expired')
   and not (a.status = 'approved' and exists (select 1 from fabula.milk_plans x where x.plan_date = mp.plan_date and x.id <> mp.id and x.status = 'approved'));

-- ============================================================================================================================
-- 4. D-24 · a decision stays decided; no approval after the deadline; the history line
-- ============================================================================================================================
create or replace function fabula.trg_approvals_decided_guard() returns trigger
language plpgsql set search_path = fabula, public as $$
declare v_who text;
begin
  new.history := coalesce(old.history, '[]'::jsonb);              -- the history only grows, and only here
  if new.status is not distinct from old.status then
    -- who decided, when and why stay as recorded (review 13/10: a direct update could rewrite the signer)
    if old.status <> 'pending' and coalesce(current_setting('fabula.approval_ctx', true), '') <> 'revoke'
       and (new.decided_by, new.decided_at, new.decision_note) is distinct from (old.decided_by, old.decided_at, old.decision_note) then
      raise exception using errcode = '22023', message = 'Una decisione registrata non si riscrive: per cambiare idea usa «Annulla» in Console → Oggi → Decise di recente';
    end if;
    return new;
  end if;
  if old.status <> 'pending' and coalesce(current_setting('fabula.approval_ctx', true), '') <> 'revoke' then
    raise exception using errcode = '22023',
      message = format('Richiesta già decisa%s%s: per cambiare idea usa «Annulla» in Console → Oggi → Decise di recente',
                       coalesce(' il ' || to_char(old.decided_at at time zone 'Europe/Rome', 'DD/MM "alle" HH24:MI'), ''), coalesce(' da ' || old.decided_by, ''));
  end if;
  if old.status = 'pending' and new.status = 'approved' and old.expires_at is not null and old.expires_at <= now() then
    raise exception using errcode = '22023',
      message = format('Richiesta scaduta %s alle %s: non si può più approvare.%s', fabula.it_day((old.expires_at at time zone 'Europe/Rome')::date),
                       to_char(old.expires_at at time zone 'Europe/Rome', 'HH24:MI'),
                       case when fabula.approval_type(old.kind, old.payload) = 'milk_plan'
                            then ' Se serve latte usa «Ordina di nuovo» in Decise di recente, o chiama la Masseria.'
                            else ' Il bot ne proporrà una nuova se serve ancora.' end);
  end if;
  if new.status <> 'pending' and new.decided_at is null then new.decided_at := now(); end if;
  v_who := case when new.status = 'pending' then nullif(current_setting('fabula.approval_by', true), '') else new.decided_by end;
  v_who := coalesce(v_who, (select full_name from fabula.staff where id = fabula.my_staff_id()), 'sistema');
  new.history := coalesce(old.history, '[]'::jsonb) || jsonb_build_object('at', now(), 'from', old.status, 'to', new.status, 'by', v_who,
                   'note', case when new.status = 'pending' then nullif(current_setting('fabula.approval_note', true), '') else new.decision_note end);
  return new;
end $$;
revoke all on function fabula.trg_approvals_decided_guard() from public, anon, authenticated;
drop trigger if exists approvals_decided_guard on fabula.approvals;
create trigger approvals_decided_guard before update on fabula.approvals
  for each row execute function fabula.trg_approvals_decided_guard();
-- every decision goes through decide_approval / revoke_approval / dop_declaration_sent (definer: they check the profile, the
-- notes a recall or a DOP declaration needs, and sign with the login); a logged-in browser no longer updates the table itself
revoke update on fabula.approvals from authenticated;

-- ============================================================================================================================
-- 5. B-12 / B-09 / B-11 · deciding from the Console
-- ============================================================================================================================
create or replace function fabula.decide_approval(p_id uuid, p_decision text, p_note text default null, p_milk_kg numeric default null,
  p_confirm boolean default false)
returns jsonb language plpgsql security definer set search_path = fabula, public as $$
declare a fabula.approvals; v_type text; v_area text; v_who text; m fabula.milk_plans; v_farm numeric; v_cap numeric; v_price numeric;
        v_out numeric; v_cost numeric; v_next text; v_issues int; v_kg numeric;
begin
  select * into a from fabula.approvals where id = p_id for update;
  if not found then raise exception using errcode = '22023', message = 'Richiesta non trovata: aggiorna la pagina'; end if;
  v_area := fabula.approval_area(a.kind, a.payload);
  if auth.uid() is not null and not fabula.can(v_area, 3) then
    raise exception using errcode = '42501', message = format('Il tuo profilo vede questa richiesta ma non la decide: serve «gestisce» in %s', v_area);
  end if;
  if p_decision is null or p_decision not in ('approved', 'rejected') then
    raise exception using errcode = '22023', message = 'Decisione non valida: approvata o rifiutata';
  end if;
  if a.status <> 'pending' then
    raise exception using errcode = '22023', message = format('Richiesta già %s%s%s: aggiorna la pagina',
      case a.status when 'approved' then 'approvata' when 'rejected' then 'rifiutata' else 'scaduta' end, coalesce(' da ' || a.decided_by, ''),
      coalesce(' alle ' || to_char(a.decided_at at time zone 'Europe/Rome', 'HH24:MI'), ''));
  end if;
  v_type := fabula.approval_type(a.kind, a.payload);
  p_note := nullif(trim(coalesce(p_note, '')), '');
  if v_type = 'recall_assessment' and p_decision = 'rejected' and length(coalesce(p_note, '')) < 3 then
    raise exception using errcode = '22023', message = 'Scrivi nella nota perché il ritiro non serve';
  end if;
  if v_type = 'dop_declaration' and p_decision = 'approved' then
    v_issues := jsonb_array_length(case when jsonb_typeof(a.payload->'issues') = 'array' then a.payload->'issues' else '[]'::jsonb end);
    if v_issues > 0 and length(coalesce(p_note, '')) < 3 then
      raise exception using errcode = '22023', message = format('Ci sono %s controlli del disciplinare da vedere: spuntali o scrivi nella nota cosa hai verificato', v_issues);
    end if;
  end if;
  v_who := coalesce((select full_name from fabula.staff where id = fabula.my_staff_id()), 'sistema');

  if p_milk_kg is not null then                                  -- B-09 «Approva con … kg»
    if v_type <> 'milk_plan' or p_decision <> 'approved' then
      raise exception using errcode = '22023', message = 'I kg si cambiano solo approvando un piano latte';
    end if;
    select * into m from fabula.milk_plans where id = a.related_id for update;
    if not found then raise exception using errcode = '22023', message = 'Piano latte non trovato'; end if;
    v_kg := round(p_milk_kg, 1);
    v_cap := fabula.setting_num('milk.capacity_kg', 1200);
    if v_kg <= 0 then
      raise exception using errcode = '22023', message = 'kg di latte: scrivi un numero maggiore di zero (per non ordinare latte usa «Rifiuta»)';
    end if;
    if v_kg > v_cap then
      raise exception using errcode = '22023', message = format('%s kg sono più della capacità del caseificio (%s kg al giorno): controlla la virgola', trim_scale(v_kg), trim_scale(v_cap));
    end if;
    v_farm := fabula.farm_kg_available(m.plan_date);
    if v_kg > v_farm and not coalesce(p_confirm, false) then
      raise exception using errcode = '22023', hint = 'confirm',
        message = format('La Masseria ha %s kg disponibili per %s: ne chiedi %s, gli altri vanno presi da altri fornitori. Confermi?',
                         trim_scale(v_farm), fabula.it_day(m.plan_date), trim_scale(v_kg));
    end if;
    if v_kg <> m.milk_kg then
      v_price := coalesce((m.details->>'price_eur_per_kg')::numeric, fabula.setting_num('milk.price_eur_kg', 1.70));
      v_out := round(v_kg * coalesce(m.yield_pct_used, 30) / 100, 1);
      v_cost := round(v_kg * v_price, 2);
      update fabula.milk_plans set milk_kg = v_kg, planned_output_kg = v_out, est_cost_eur = v_cost,
             details = coalesce(details, '{}'::jsonb) || jsonb_build_object('original_milk_kg', m.milk_kg, 'changed_by', v_who, 'changed_at', now())
       where id = m.id;
      update fabula.approvals set amount_eur = v_cost,
             payload = payload || jsonb_build_object('milk_kg', v_kg, 'planned_output_kg', v_out, 'est_cost_eur', v_cost, 'original_milk_kg', m.milk_kg),
             summary = format('Latte per %s: %s kg (proposti %s kg)', fabula.it_day(m.plan_date), trim_scale(v_kg), trim_scale(m.milk_kg))
       where id = a.id;
      p_note := concat_ws(' · ', format('approvato con %s kg invece di %s', trim_scale(v_kg), trim_scale(m.milk_kg)), p_note);
    end if;
  end if;

  update fabula.approvals set status = p_decision::fabula.approval_status, decided_by = v_who, decided_at = now(), decision_note = p_note
   where id = a.id;

  if v_type = 'milk_plan' then
    select * into m from fabula.milk_plans where id = a.related_id;
    v_next := case when p_decision = 'approved' then format('La Masseria vede l''ordine: %s kg per %s', trim_scale(m.milk_kg), fabula.it_day(m.plan_date))
                   else format('Nessun ordine di latte per %s: se serve, «Ordina di nuovo» in Decise di recente', fabula.it_day(m.plan_date)) end;
  elsif v_type = 'purchase_order' then
    v_next := case when p_decision = 'approved' then format('%s approvato: invialo al fornitore in Operazioni', coalesce(a.payload->>'po_number', 'Ordine'))
                   else format('%s annullato', coalesce(a.payload->>'po_number', 'Ordine')) end;
  elsif v_type = 'dop_declaration' and p_decision = 'approved' then
    v_next := 'Dati approvati: stampa la dichiarazione, inviala al Consorzio e segnala inviata (Decise di recente)';
  elsif v_type = 'sell_down' and p_decision = 'approved' then
    v_next := 'Il codice compare sul tablet; i post sono in Marketing';
  end if;
  return jsonb_build_object('id', a.id, 'status', p_decision, 'type', v_type, 'next_it', v_next);
end $$;
revoke all on function fabula.decide_approval(uuid, text, text, numeric, boolean) from public, anon;
grant execute on function fabula.decide_approval(uuid, text, text, numeric, boolean) to authenticated, service_role;

-- ============================================================================================================================
-- 6. B-12 / E-10 · «Annulla»: what can still be undone, and the undo itself
-- ============================================================================================================================
-- null = it can be undone; otherwise the reason, in Italian, shown next to the decision
create or replace function fabula.approval_undo_block(a fabula.approvals) returns text
language plpgsql stable set search_path = fabula, public as $$   -- invoker: the list shows it with the reader's rights; revoke_approval re-checks as definer
declare v_type text; m fabula.milk_plans; po fabula.purchase_orders;
begin
  if a.status = 'pending' then return 'ancora da decidere'; end if;
  if a.status = 'expired' then return 'scaduta senza decisione'; end if;
  if a.decided_at < now() - interval '7 days' then return 'decisa più di 7 giorni fa'; end if;
  if a.expires_at is not null and a.expires_at <= now() then return 'il termine per decidere è passato'; end if;
  v_type := fabula.approval_type(a.kind, a.payload);
  if v_type = 'milk_plan' then
    select * into m from fabula.milk_plans where id = a.related_id;
    if not found then return 'piano latte non trovato'; end if;
    if a.status = 'approved' and m.farm_seen_at is not null then
      return format('la Masseria l''ha già visto %s alle %s: per cambiarlo chiamala', fabula.it_day((m.farm_seen_at at time zone 'Europe/Rome')::date),
                    to_char(m.farm_seen_at at time zone 'Europe/Rome', 'HH24:MI'));
    end if;
    if exists (select 1 from fabula.milk_plans x where x.plan_date = m.plan_date and x.id <> m.id and x.status in ('proposed', 'approved')) then
      return 'c''è già un altro piano per quel giorno';
    end if;
    return null;
  elsif v_type = 'purchase_order' then
    select * into po from fabula.purchase_orders where id = a.related_id;
    if not found then return 'ordine non trovato'; end if;
    if po.status in ('sent', 'partially_received', 'received') then return 'già inviato al fornitore: usa «Annulla ordine» in Operazioni'; end if;
    if po.cancel_reason is not null then return 'ordine annullato a mano'; end if;
    if a.status in ('rejected', 'expired') then                    -- back to «da approvare» only if nothing replaced it
      return (select format('c''è già un ordine più recente per gli stessi articoli (%s): rifare questo lo raddoppierebbe', x.po_number)
                from fabula.purchase_orders x
               where x.id <> po.id and x.supplier_id = po.supplier_id and x.created_at > po.created_at and x.status <> 'cancelled'
                 and exists (select 1 from fabula.purchase_order_lines l1 join fabula.purchase_order_lines l2 on l2.product_id = l1.product_id
                              where l1.purchase_order_id = x.id and l2.purchase_order_id = po.id)
               order by x.created_at desc limit 1);
    end if;
    return null;
  elsif v_type = 'sell_down' then
    if (a.requested_at at time zone 'Europe/Rome')::date < (now() at time zone 'Europe/Rome')::date then return 'promo di un altro giorno'; end if;
    if a.status = 'approved' and exists (select 1 from fabula.mkt_content c where c.id::text in (select jsonb_array_elements_text(coalesce(a.payload->'posts', '[]'::jsonb)))
                                          and c.status in ('scheduled', 'published')) then
      return 'i post della promo sono già programmati o pubblicati';
    end if;
    return null;
  elsif v_type = 'content_post' then
    if a.status = 'rejected' then return 'il post è tornato in bozza: rimandalo in approvazione da Marketing'; end if;
    if exists (select 1 from fabula.mkt_content where id = (a.payload->>'content_id')::uuid and status <> 'approved') then
      return 'il post è già programmato, pubblicato o cambiato: gestiscilo in Marketing';
    end if;
    return null;
  elsif v_type = 'recipe_update' then
    if a.status = 'approved' then return 'la dose è già cambiata: correggila in Ricette'; end if;
    return null;
  elsif v_type = 'dop_declaration' then
    if a.payload ? 'sent_at' then return 'già segnata come inviata al Consorzio'; end if;
    return null;
  elsif v_type = 'recall_assessment' then
    return 'decisione di sicurezza alimentare: resta nel registro (un ripensamento è una nuova valutazione, con il consulente)';
  end if;
  return 'questa decisione non si annulla da qui';
end $$;
revoke all on function fabula.approval_undo_block(fabula.approvals) from public, anon;
grant execute on function fabula.approval_undo_block(fabula.approvals) to authenticated, service_role;

create or replace function fabula.revoke_approval(p_id uuid, p_note text default null) returns jsonb
language plpgsql security definer set search_path = fabula, public as $$
declare a fabula.approvals; v_block text; v_who text; v_type text;
begin
  select * into a from fabula.approvals where id = p_id for update;
  if not found then raise exception using errcode = '22023', message = 'Richiesta non trovata: aggiorna la pagina'; end if;
  if auth.uid() is not null and not fabula.can(fabula.approval_area(a.kind, a.payload), 3) then
    raise exception using errcode = '42501', message = format('Il tuo profilo non può annullare questa decisione: serve «gestisce» in %s', fabula.approval_area(a.kind, a.payload));
  end if;
  v_type := fabula.approval_type(a.kind, a.payload);
  -- the farm page (farm_milk_seen) or a send can't slip in between the check and the undo
  if v_type = 'milk_plan' then perform 1 from fabula.milk_plans where id = a.related_id for update;
  elsif v_type = 'purchase_order' then perform 1 from fabula.purchase_orders where id = a.related_id for update; end if;
  v_block := fabula.approval_undo_block(a);
  if v_block is not null then raise exception using errcode = '22023', message = 'Non si annulla: ' || v_block; end if;
  v_who := coalesce((select full_name from fabula.staff where id = fabula.my_staff_id()), 'sistema');
  perform set_config('fabula.approval_ctx', 'revoke', true);
  perform set_config('fabula.approval_by', v_who, true);
  perform set_config('fabula.approval_note', 'annullata' || coalesce(': ' || nullif(trim(p_note), ''), ''), true);
  if v_type = 'sell_down' and a.status = 'approved' then          -- the promo's posts go, and the approvals of those posts
    update fabula.mkt_content set status = 'rejected'
     where id::text in (select jsonb_array_elements_text(coalesce(a.payload->'posts', '[]'::jsonb))) and status in ('draft', 'review', 'approved');
    update fabula.approvals set status = 'rejected', decided_by = v_who, decided_at = now(), decision_note = 'promo annullata'
     where status = 'pending' and payload->>'type' = 'content_post'
       and payload->>'content_id' in (select jsonb_array_elements_text(coalesce(a.payload->'posts', '[]'::jsonb)));
  end if;
  update fabula.approvals set status = 'pending', decided_by = null, decided_at = null, decision_note = null, auto_approve_at = null,
         auto_rule = format('decisione annullata da %s: decide una persona', v_who),
         payload = case when v_type = 'sell_down' then payload - 'posts' else payload end
   where id = a.id;
  perform set_config('fabula.approval_ctx', '', true);
  perform set_config('fabula.approval_by', '', true);
  perform set_config('fabula.approval_note', '', true);
  return jsonb_build_object('id', a.id, 'status', 'pending', 'was', a.status, 'type', v_type);
end $$;
revoke all on function fabula.revoke_approval(uuid, text) from public, anon;
grant execute on function fabula.revoke_approval(uuid, text) to authenticated, service_role;

-- a post put back in review by «Annulla» keeps its approval (no second card)
create or replace function fabula.mkt_approval_sync() returns trigger
language plpgsql set search_path = fabula, public, extensions as $$
declare v_block int;
begin
  if coalesce(new.payload->>'type', '') <> 'content_post' or new.status is not distinct from old.status then return new; end if;
  if new.status = 'approved' then
    select claims_blocking into v_block from fabula.mkt_content where id = (new.payload->>'content_id')::uuid;
    if coalesce(v_block, 0) > 0 then raise exception 'Il post ha % problemi bloccanti nel testo: correggili prima di approvare', v_block; end if;
    update fabula.mkt_content set status = 'approved', approved_by = new.decided_by where id = (new.payload->>'content_id')::uuid and status = 'review';
  elsif new.status = 'rejected' then
    update fabula.mkt_content set status = 'draft' where id = (new.payload->>'content_id')::uuid and status = 'review';
  elsif new.status = 'pending' and old.status = 'approved' then   -- v0.99: «Annulla»
    update fabula.mkt_content set status = 'review', approved_by = null where id = (new.payload->>'content_id')::uuid and status = 'approved';
  end if;
  return new;
end $$;

-- ============================================================================================================================
-- 7. E-12 / E-11 · deadlines every 10 minutes, with what an expiry means
-- ============================================================================================================================
create or replace function fabula.expire_approvals(p_now timestamptz default now()) returns integer
language plpgsql security definer set search_path = fabula, public as $$
declare a fabula.approvals; n int := 0; v_type text; v_what text; v_title text; v_out uuid;
begin
  for a in select * from fabula.approvals
            where status = 'pending' and expires_at is not null and expires_at <= p_now
              and coalesce(payload->>'type', '') <> 'recall_assessment'      -- v0.93a: a recall decision never lapses by itself
            order by expires_at for update skip locked loop
    update fabula.approvals set status = 'expired', decided_by = 'Scadenza', decided_at = p_now, decision_note = 'scaduta senza decisione'
     where id = a.id and status = 'pending';
    if not found then continue; end if;
    n := n + 1;
    v_type := fabula.approval_type(a.kind, a.payload);
    v_what := case v_type
      when 'milk_plan' then format('Nessun ordine di latte per %s: la Masseria non vede niente. Se serve latte, ordinalo da Console → Oggi → Decise di recente («Ordina di nuovo») o chiama la Masseria.',
                                   fabula.it_day((a.payload->>'plan_date')::date))
      when 'purchase_order' then case when coalesce((a.payload->>'manual')::boolean, false)
                                      then format('L''ordine %s (creato da %s dal catalogo) è annullato: se serve ancora rifallo da Anagrafiche → Fornitori.',
                                                  coalesce(a.payload->>'po_number', ''), coalesce(a.payload->>'created_by', '?'))
                                      else format('L''ordine %s è annullato: il bot Acquisti lo riproporrà se serve ancora.', coalesce(a.payload->>'po_number', '')) end
      when 'sell_down' then 'La promo non è partita: nessun codice sul tablet, nessun post.'
      when 'content_post' then 'Il post non è stato approvato in tempo: non esce. Riprogrammalo da Marketing se serve.'
      else 'Nessuna azione è stata fatta.' end;
    v_title := left('Scaduta senza decisione · ' || a.summary, 120);
    begin
      perform fabula.post_bot_message('auto_approve', 'warn', v_title, a.summary || E'\n\n' || v_what);
    exception when others then raise warning 'expire_approvals message %: %', a.id, sqlerrm;
    end;
    if v_type = 'milk_plan' and not coalesce((a.payload->>'is_simulation')::boolean, false) then
      begin
        v_out := fabula.notify_enqueue('decisions', v_title, v_what, 'Approvazioni', 'approvals', a.id::text, 'exp:' || a.id);
      exception when others then raise warning 'expire_approvals notify %: %', a.id, sqlerrm;
      end;
    end if;
  end loop;
  return n;
end $$;
revoke all on function fabula.expire_approvals(timestamptz) from public, anon, authenticated;
grant execute on function fabula.expire_approvals(timestamptz) to service_role;

-- the evening check now uses the same expiry (one message per expired request)
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.ops_health_check'::regproc);
  n := regexp_replace(d, $re$update fabula\.approvals set status = 'expired' where status = 'pending' and expires_at < now\(\)\s+and coalesce\(payload->>'type', ''\) <> 'recall_assessment';[^\n]*$re$,
                      'perform fabula.expire_approvals();   -- v0.99 (audit E-11/E-12): same expiry as the 10-minute cron, with its message');
  if n = d then raise exception 'v099a: ops_health_check expiry pattern not found'; end if;
  execute n;
end $mig$;

-- ============================================================================================================================
-- 8. E-10 · automatic approvals: the deadlines first, then a pushed line for milk and money, with what can still be undone
-- ============================================================================================================================
create or replace function fabula.auto_approve_due(p_now timestamptz default now()) returns jsonb
language plpgsql security definer set search_path = fabula, public as $$
declare a fabula.approvals; r text; done jsonb := '[]'; v_exp int; v_type text; v_undo text; v_title text; v_body text; v_out uuid;
begin
  v_exp := fabula.expire_approvals(p_now);                       -- v0.99 (audit E-12)
  for a in select * from fabula.approvals where status = 'pending' and auto_approve_at is not null and auto_approve_at <= p_now
            and (expires_at is null or expires_at > p_now) order by auto_approve_at loop
    r := fabula.auto_approve_rule(a);
    if r is null then
      update fabula.approvals set auto_approve_at = null, auto_rule = 'non più di routine: decide una persona' where id = a.id;
      done := done || jsonb_build_object('id', a.id, 'summary', a.summary, 'approved', false);
      continue;
    end if;
    update fabula.approvals set status = 'approved', decided_by = 'Approvazione automatica', decided_at = p_now, decision_note = 'Regola: ' || r
     where id = a.id and status = 'pending';
    if found then
      v_type := fabula.approval_type(a.kind, a.payload);
      v_undo := case v_type
        when 'milk_plan' then 'Puoi annullarlo o cambiare i kg finché la Masseria non lo vede: Console → Oggi → Decise di recente → «Annulla».'
        when 'purchase_order' then 'Puoi annullarlo finché non lo invii al fornitore: Console → Oggi → Decise di recente → «Annulla».'
        when 'sell_down' then 'Il codice è sul tablet; i due post aspettano che una persona li approvi (Console → Oggi). Per fermare la promo: Decise di recente → «Annulla».'
        else 'Si annulla da Console → Oggi → Decise di recente.' end;
      v_title := left('Approvato da solo · ' || a.summary, 120);
      v_body := format(E'%s\n\nPerché: %s.\nNessuno l''aveva deciso entro le %s. %s\nLe regole si cambiano o si spengono in Configurazione → Parametri → Approvazioni automatiche.',
                       a.summary, r, to_char(a.auto_approve_at at time zone 'Europe/Rome', 'HH24:MI'), v_undo);
      perform fabula.post_bot_message('auto_approve', case when v_type in ('milk_plan', 'purchase_order', 'sell_down') then 'warn' else 'info' end, v_title, v_body);
      if v_type in ('milk_plan', 'purchase_order', 'sell_down') then
        begin
          v_out := fabula.notify_enqueue('decisions', v_title, v_body, 'Approvazioni automatiche', 'approvals', a.id::text, 'aa:' || a.id);
          update fabula.notify_outbox set escalate_at = null where id = v_out;     -- news to read, not a task to take
        exception when others then raise warning 'auto_approve notify %: %', a.id, sqlerrm;
        end;
      end if;
      done := done || jsonb_build_object('id', a.id, 'summary', a.summary, 'approved', true);
    end if;
  end loop;
  return jsonb_build_object('checked_at', p_now, 'results', done, 'expired', v_exp);
end $$;

-- the bots say when a proposal approves itself (the milk plan's warnings go into the approval for the card)
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.plan_milk'::regproc);
  n := replace(d, $s$jsonb_build_object('type', 'milk_plan', 'plan_date', d, 'milk_kg', v_milk_r, 'planned_output_kg', v_out, 'est_cost_eur', v_cost, 'rationale', v_rat)$s$,
                  $s$jsonb_build_object('type', 'milk_plan', 'plan_date', d, 'milk_kg', v_milk_r, 'planned_output_kg', v_out, 'est_cost_eur', v_cost, 'rationale', v_rat,
                             'capacity_hit', v_cap, 'min_run_applied', v_min, 'exceeds_farm_supply', v_farm_hit, 'farm_kg_available', v_farm,
                             'farm_shortfall_kg', v_farm_short, 'capped_to_farm', v_farm_hit and v_farm_cap, 'history_source', v_hist_src,
                             'history_days', v_n, 'yield_pct', v_yield, 'yield_source', v_yield_src, 'is_simulation', v_sim)$s$);
  if n = d then raise exception 'v099a: plan_milk payload pattern not found'; end if;
  d := n;
  n := replace(d, $s$'rationale', v_rat, 'plan_id', v_id, 'approval_id', v_appr);$s$,
                  $s$'rationale', v_rat, 'plan_id', v_id, 'approval_id', v_appr,
    'auto_approve_at', (select to_char(x.auto_approve_at at time zone 'Europe/Rome', 'HH24:MI') from fabula.approvals x where x.id = v_appr),
    'auto_rule', (select x.auto_rule from fabula.approvals x where x.id = v_appr and x.auto_approve_at is not null));$s$);
  if n = d then raise exception 'v099a: plan_milk return pattern not found'; end if;
  execute n;

  d := pg_get_functiondef('fabula.propose_purchase_orders'::regproc);
  n := replace(d, $s$'expected_date', p_date + sig.lead, 'price_missing', v_price = 0, 'adjusted', v_adj <> '');$s$,
                  $s$'expected_date', p_date + sig.lead, 'price_missing', v_price = 0, 'adjusted', v_adj <> '',
                                             'auto_approve_at', (select to_char(x.auto_approve_at at time zone 'Europe/Rome', 'HH24:MI') from fabula.approvals x where x.related_id = v_po and x.status = 'pending' limit 1));$s$);
  if n = d then raise exception 'v099a: propose_purchase_orders pattern not found'; end if;
  execute n;

  d := pg_get_functiondef('fabula.sell_down_signals'::regproc);
  n := replace(d, $s$'action', action, 'promo_price_eur_kg', case when action in ('promo_banco','offerta_ingrosso_e_promo') then round(v_price * (1 - promo / 100), 2) end);$s$,
                  $s$'action', action, 'promo_price_eur_kg', case when action in ('promo_banco','offerta_ingrosso_e_promo') then round(v_price * (1 - promo / 100), 2) end,
                                       'auto_approve_at', (select to_char(x.auto_approve_at at time zone 'Europe/Rome', 'HH24:MI') from fabula.approvals x
                                                            where x.requested_by = 'agent:sell_down' and x.payload->>'lot' = lot.lot_number and x.requested_at::date = p_date
                                                              and x.status = 'pending' order by x.requested_at desc limit 1));$s$);
  if n = d then raise exception 'v099a: sell_down_signals pattern not found'; end if;
  execute n;
end $mig$;

-- E-10 (4): posts of an auto-approved promo wait for a person; a person's approval names them
create or replace function fabula.sell_down_promo_posts() returns trigger
language plpgsql security definer set search_path = fabula, public as $$
declare v_name text; v_price text; v_list text; v_pct text; v_txt text; v_wa uuid; v_ig uuid; v_where text; v_auto boolean; v_status text; v_at timestamptz; v_brief text;
begin
  if new.kind <> 'price_change' or coalesce(new.payload->>'type', '') <> 'sell_down'
     or new.status <> 'approved' or old.status is not distinct from 'approved' or new.payload ? 'posts' then
    return new;
  end if;
  v_auto := new.decided_by = 'Approvazione automatica';
  v_status := case when v_auto then 'review' else 'approved' end;
  -- a post waiting for a person gets a little time to be read (its approval lapses at the scheduled time)
  v_at := case when v_auto then greatest(now() + interval '30 minutes', least(now() + interval '2 hours', (((now() at time zone 'Europe/Rome')::date + time '19:00') at time zone 'Europe/Rome')))
               else now() end;
  v_brief := case when v_auto then 'approvata automaticamente: rileggi il post e approvalo' else 'approvata da ' || coalesce(new.decided_by, 'Console') end;
  select name into v_name from fabula.products where sku = new.payload->>'sku';
  v_price := replace(to_char((new.payload->>'promo_price_eur_kg')::numeric, 'FM990.00'), '.', ',');
  v_list  := replace(to_char((new.payload->>'list_price_eur_kg')::numeric, 'FM990.00'), '.', ',');
  v_pct   := round((new.payload->>'promo_pct')::numeric)::text;
  v_where := coalesce(nullif((select value from fabula.settings where key = 'company.address'), ''), 'Agropoli');
  v_txt := format('Oggi al banco: %s a € %s/kg invece di € %s (−%s%%), fino a esaurimento. Ti aspettiamo da %s, %s.',
                  coalesce(v_name, 'mozzarella'), v_price, v_list, v_pct, fabula.company_name(), v_where);
  insert into fabula.mkt_content (platform, format, pillar, status, scheduled_at, brief_it, caption_it, approved_by)
  values ('whatsapp', 'post', 'oggi_al_banco', v_status, v_at, format('Promo scorte lotto %s, %s', new.payload->>'lot', v_brief), v_txt,
          case when v_auto then null else coalesce(new.decided_by, 'Console') end)
  returning id into v_wa;
  insert into fabula.mkt_content (platform, format, pillar, status, scheduled_at, brief_it, caption_it, approved_by)
  values ('instagram', 'story', 'oggi_al_banco', v_status, v_at, format('Promo scorte lotto %s, %s: foto del banco con la mozzarella in offerta', new.payload->>'lot', v_brief),
          format('Oggi al banco −%s%%: %s a € %s/kg. Fino a esaurimento!', v_pct, coalesce(v_name, 'mozzarella'), v_price),
          case when v_auto then null else coalesce(new.decided_by, 'Console') end)
  returning id into v_ig;
  update fabula.approvals set payload = payload || jsonb_build_object('posts', jsonb_build_array(v_wa, v_ig)) where id = new.id;
  return new;
end $$;

-- ============================================================================================================================
-- 9. B-13 · a post edited while waiting refreshes its card; «Annulla» never makes a second card
-- ============================================================================================================================
create or replace function fabula.mkt_content_before() returns trigger
language plpgsql security definer set search_path = fabula, public, extensions as $$
declare v_ai boolean; v_appr uuid; v_img text; v_sum text;
begin
  select coalesce(bool_or(ai_generated), false) into v_ai from fabula.mkt_assets where id = any(new.asset_ids);
  new.claims := fabula.mkt_check_claims(concat_ws(' ', new.caption_it, new.caption_en, new.hashtags), new.collab_id is not null or new.pillar = 'collab', v_ai);
  new.claims_blocking := (select count(*) from jsonb_array_elements(new.claims) e where e->>'severity' = 'block');
  new.updated_at := now();
  -- v0.60: an approved/scheduled post whose text or media changes goes back to review when the new text fails the claims check
  -- or the editor can't approve marketing content; it used to stay approved
  if tg_op = 'UPDATE' and old.status in ('approved', 'scheduled') and new.status = old.status
     and (new.caption_it, new.caption_en, new.hashtags, new.asset_ids) is distinct from (old.caption_it, old.caption_en, old.hashtags, old.asset_ids)
     and (new.claims_blocking > 0 or (auth.uid() is not null and not fabula.can('marketing', 3))) then
    new.status := 'review'; new.approved_by := null;
  end if;
  select a.url into v_img from fabula.mkt_assets a where a.id = any(new.asset_ids) and a.kind <> 'video' order by array_position(new.asset_ids, a.id) limit 1;
  v_sum := format('Post %s %s%s: %s', new.platform, coalesce(to_char(new.scheduled_at at time zone 'Europe/Rome', 'DD/MM HH24:MI'), 'senza data'),
                  case when new.claims_blocking > 0 then format(' · ⚠ %s da correggere', new.claims_blocking) else '' end,
                  left(coalesce(new.caption_it, new.brief_it, ''), 90));
  if new.status = 'review' and (tg_op = 'INSERT' or old.status is distinct from 'review')
     and coalesce(current_setting('fabula.approval_ctx', true), '') <> 'revoke' then        -- v0.99: «Annulla» keeps the same card
    insert into fabula.approvals (kind, requested_by, summary, payload, related_table, related_id, expires_at)
    values ('other', 'agent:marketing', v_sum,
            jsonb_build_object('type', 'content_post', 'content_id', new.id, 'platform', new.platform, 'caption_it', new.caption_it, 'claims', new.claims,
                               'hashtags', new.hashtags, 'scheduled_at', new.scheduled_at, 'image_url', v_img),
            'mkt_content', new.id, coalesce(new.scheduled_at, now() + interval '7 days'))
    returning id into v_appr;
    new.approval_id := v_appr;
  elsif tg_op = 'UPDATE' and old.status = 'review' and new.status = 'review' and new.approval_id is not null
     and (new.caption_it, new.caption_en, new.hashtags, new.asset_ids, new.scheduled_at) is distinct from (old.caption_it, old.caption_en, old.hashtags, old.asset_ids, old.scheduled_at) then
    -- v0.99 (audit B-13): the card shows what will be approved, not what was sent for approval
    update fabula.approvals set summary = v_sum, expires_at = coalesce(new.scheduled_at, expires_at),
           payload = payload || jsonb_build_object('caption_it', new.caption_it, 'claims', new.claims, 'hashtags', new.hashtags,
                                                   'scheduled_at', new.scheduled_at, 'image_url', v_img, 'edited_at', now())
     where id = new.approval_id and status = 'pending';
  end if;
  return new;
end $$;
revoke all on function fabula.mkt_content_before() from public, anon, authenticated;

-- ============================================================================================================================
-- 10. B-11 · the DOP declaration: the figures are approved, the sending is recorded
-- ============================================================================================================================
drop trigger if exists approvals_dop_done on fabula.approvals;
drop function if exists fabula.dop_declaration_done();

create or replace function fabula.dop_declaration_sent(p_id uuid, p_sent_on date, p_protocol text default null, p_note text default null)
returns jsonb language plpgsql security definer set search_path = fabula, public as $$
declare a fabula.approvals; v_m0 date; v_who text; v_today date := (now() at time zone 'Europe/Rome')::date; n int;
begin
  select * into a from fabula.approvals where id = p_id and kind = 'dop_declaration' for update;
  if not found then raise exception using errcode = '22023', message = 'Dichiarazione non trovata: aggiorna la pagina'; end if;
  if auth.uid() is not null and not fabula.can('haccp', 3) then
    raise exception using errcode = '42501', message = 'Serve «gestisce» in Autocontrollo per segnare la dichiarazione inviata';
  end if;
  if a.status <> 'approved' then raise exception using errcode = '22023', message = 'Prima approva i dati della dichiarazione (Console → Oggi)'; end if;
  if a.payload ? 'sent_at' then
    raise exception using errcode = '22023', message = format('Già segnata come inviata il %s da %s', to_char((a.payload->>'sent_on')::date, 'DD/MM/YYYY'), a.payload->>'sent_by');
  end if;
  v_m0 := ((a.payload->>'month') || '-01')::date;
  if p_sent_on is null or p_sent_on > v_today then
    raise exception using errcode = '22023', message = 'Data di invio: oggi o un giorno passato';
  end if;
  if p_sent_on < (v_m0 + interval '1 month')::date then
    raise exception using errcode = '22023', message = format('La dichiarazione di %s si invia dal %s in poi', to_char(v_m0, 'MM/YYYY'), to_char((v_m0 + interval '1 month')::date, 'DD/MM/YYYY'));
  end if;
  if coalesce(trim(p_protocol), '') = '' and length(coalesce(trim(p_note), '')) < 3 then
    raise exception using errcode = '22023', message = 'Scrivi il numero di protocollo o come l''hai inviata (es. PEC del 05/11)';
  end if;
  v_who := coalesce((select full_name from fabula.staff where id = fabula.my_staff_id()), 'sistema');
  update fabula.approvals set payload = payload || jsonb_build_object('sent_on', p_sent_on, 'protocol', nullif(trim(p_protocol), ''),
           'sent_note', nullif(trim(p_note), ''), 'sent_by', v_who, 'sent_at', now())
   where id = a.id;
  update fabula.task_instances ti set status = 'done', completed_at = now(), completed_by_id = coalesce(fabula.my_staff_id(), ti.completed_by_id)
    from fabula.task_schedules ts
   where ts.id = ti.schedule_id and ts.code = 'T-DOP' and ti.status in ('due', 'overdue')
     and ti.due_at >= ((v_m0 + interval '1 month')::date::timestamp at time zone 'Europe/Rome')
     and ti.due_at <  ((v_m0 + interval '2 month')::date::timestamp at time zone 'Europe/Rome');
  get diagnostics n = row_count;
  return jsonb_build_object('id', a.id, 'month', a.payload->>'month', 'sent_on', p_sent_on, 'tasks_closed', n);
end $$;
revoke all on function fabula.dop_declaration_sent(uuid, date, text, text) from public, anon;
grant execute on function fabula.dop_declaration_sent(uuid, date, text, text) to authenticated, service_role;

-- ============================================================================================================================
-- 11. B-09 · after a rejection or an expiry: propose the day again, or order N kg directly
-- ============================================================================================================================
create or replace function fabula.milk_order_again(p_date date, p_kg numeric default null, p_note text default null, p_confirm boolean default false)
returns jsonb language plpgsql security definer set search_path = fabula, public as $$
declare v_today date := (now() at time zone 'Europe/Rome')::date; r jsonb; v_appr uuid; v_dec jsonb;
begin
  if auth.uid() is not null and not fabula.can('produzione', 3) then
    raise exception using errcode = '42501', message = 'Serve «gestisce» in Produzione per ordinare il latte';
  end if;
  if p_date is null or p_date < v_today or (p_date = v_today and (now() at time zone 'Europe/Rome')::time >= time '06:00') then
    raise exception using errcode = '22023', message = format('Per %s è tardi: la Masseria munge e spedisce al mattino. Chiamala.', coalesce(fabula.it_day(p_date), 'quel giorno'));
  end if;
  if extract(isodow from p_date) = 7 then raise exception using errcode = '22023', message = 'La domenica non si lavora'; end if;
  if exists (select 1 from fabula.milk_plans where plan_date = p_date and status in ('proposed', 'approved')) then
    raise exception using errcode = '22023', message = format('C''è già un piano latte per %s: decidilo in Console → Oggi', fabula.it_day(p_date));
  end if;
  r := fabula.plan_milk(p_date);
  v_appr := (r->>'approval_id')::uuid;
  if v_appr is null then raise exception using errcode = '22023', message = 'Piano latte non creato: ' || coalesce(r->>'skipped', r::text); end if;
  if p_kg is not null then
    v_dec := fabula.decide_approval(v_appr, 'approved', coalesce(nullif(trim(p_note), ''), 'ordinato a mano'), p_kg, p_confirm);
  end if;
  return jsonb_build_object('plan_date', p_date, 'approval_id', v_appr, 'proposed_kg', r->'milk_kg', 'approved', v_dec is not null, 'decision', v_dec);
end $$;
revoke all on function fabula.milk_order_again(date, numeric, text, boolean) from public, anon;
grant execute on function fabula.milk_order_again(date, numeric, text, boolean) to authenticated, service_role;

-- ============================================================================================================================
-- 12. B-12 · what was decided in the last 7 days (and the DOP declarations still to send), with «Annulla» where possible
-- ============================================================================================================================
create or replace view fabula.v_approvals_recent with (security_invoker = true) as
select a.id, a.kind, fabula.approval_type(a.kind, a.payload) as type, a.status, a.summary, a.amount_eur, a.payload, a.related_table, a.related_id,
       a.requested_by, a.requested_at, a.decided_by, a.decided_at, a.decision_note, a.expires_at, a.history,
       fabula.approval_undo_block(a) as undo_block,
       case when a.related_table = 'milk_plans' then
         (select jsonb_build_object('plan_date', mp.plan_date, 'milk_kg', mp.milk_kg, 'status', mp.status, 'farm_seen_at', mp.farm_seen_at,
                                    'other_active', exists (select 1 from fabula.milk_plans x where x.plan_date = mp.plan_date and x.id <> mp.id and x.status in ('proposed', 'approved')))
            from fabula.milk_plans mp where mp.id = a.related_id) end as milk
  from fabula.approvals a
 where (a.status <> 'pending' and coalesce(a.decided_at, a.requested_at) > now() - interval '7 days')
    or (a.kind = 'dop_declaration' and a.status = 'approved' and not (a.payload ? 'sent_at'));
grant select on fabula.v_approvals_recent to authenticated, service_role;

-- ============================================================================================================================
-- 13. The definer functions check the caller inside: accepted in the evening security check
-- ============================================================================================================================
insert into fabula.security_accepted (key, reason, accepted_at) values
 ('authenticated_security_definer_function_executable:fabula.decide_approval(p_id uuid, p_decision text, p_note text, p_milk_kg numeric, p_confirm boolean)',
  'by design (v0.99a, audit B-12/B-09): can(approval area, 3) first; signer from the login', now()),
 ('authenticated_security_definer_function_executable:fabula.revoke_approval(p_id uuid, p_note text)',
  'by design (v0.99a, audit B-12/E-10): can(approval area, 3) first; approval_undo_block decides what can be undone', now()),
 ('authenticated_security_definer_function_executable:fabula.dop_declaration_sent(p_id uuid, p_sent_on date, p_protocol text, p_note text)',
  'by design (v0.99a, audit B-11): can(haccp, 3) first', now()),
 ('authenticated_security_definer_function_executable:fabula.milk_order_again(p_date date, p_kg numeric, p_note text, p_confirm boolean)',
  'by design (v0.99a, audit B-09): can(produzione, 3) first; decides through decide_approval', now())
on conflict (key) do update set reason = excluded.reason, accepted_at = excluded.accepted_at;

-- ======================= v099b =======================
-- v0.99b · Audit 12/10/2026, office decisions and undo (2/2): orders, wholesale forecast, recipes, holds and NCs, B2B prices.
--   B-18   Catalogue orders: a line without a price is refused unless «prezzo da confermare» is ticked; the creator is stored;
--          above approve.auto_po_max_eur, with a price to confirm, or from a «registra» profile, the order waits for approval in Console → Oggi
--          (one card with every line); cancel_po() («Annulla ordine», with a reason) for orders not yet received, with the
--          message for the supplier when it had already been sent.
--   B-19   The 7-day milk forecast takes wholesale from the Ingrosso plans (trade_effective_lines), no longer from the old
--          «Ordini fissi» grid, which books nothing (the Console grid is gone).
--   B-15   «Togli» on a recipe component ends it from tomorrow (today's lots still dose it), as the button always said, or at once
--          when it was put in today; restore_recipe_component() undoes it the same day; a removed row can't be «saved» back.
--   B-06   A held lot is not released while its recall assessment is undecided, nor after a recall was decided; a release can name the conforming analysis
--          (checked against the lot); an NC closes only with its corrective action.
--   B-22/23 B2B price list: what was last sent to Shopify is kept per product and per tier, so Ingrosso shows «da inviare»
--          after a change; a tier is a price or a discount, never both.

-- ============================================================================================================================
-- 1. B-18 · catalogue orders
-- ============================================================================================================================
create or replace function fabula.create_manual_po(p_supplier_id uuid, p_lines jsonb, p_notes text default null)
returns jsonb language plpgsql security definer set search_path = fabula, public, extensions as $$
declare v_date date := (now() at time zone 'Europe/Rome')::date; v_po uuid; v_no text; v_seq int; v_lead int; l jsonb;
        v_price numeric; v_iva numeric; v_sub numeric := 0; v_ivat numeric := 0; v_n int := 0; v_sup text; v_email text; v_missing int := 0;
        v_name text; v_sku text; v_unit text; v_lines jsonb := '[]'; v_who text; v_max numeric; v_needs boolean; v_appr uuid;
begin
  perform fabula.require_perm('acquisti', 2);
  select legal_name, email into v_sup, v_email from fabula.parties where id = p_supplier_id and active;
  if v_sup is null then raise exception using errcode = '22023', message = 'Fornitore non trovato'; end if;
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then raise exception using errcode = '22023', message = 'Nessuna riga da ordinare'; end if;
  v_who := coalesce((select full_name from fabula.staff where id = fabula.my_staff_id()), 'console');
  select coalesce(max(t.lead_time_days), fabula.setting_num('purchasing.default_lead_days', 5)::int) into v_lead
    from fabula.supplier_products t where t.supplier_id = p_supplier_id and t.product_id in (select (x->>'product_id')::uuid from jsonb_array_elements(p_lines) x);
  select count(*) + 1 into v_seq from fabula.purchase_orders where order_date = v_date;
  loop
    v_no := 'PO-' || to_char(v_date, 'YYYYMMDD') || '-' || lpad(v_seq::text, 2, '0');
    exit when not exists (select 1 from fabula.purchase_orders where po_number = v_no);
    v_seq := v_seq + 1;
  end loop;
  insert into fabula.purchase_orders (po_number, supplier_id, status, order_date, expected_date, drafted_by, rationale, notes, source, created_by_id)
  values (v_no, p_supplier_id, 'draft', v_date, v_date + v_lead, 'human', 'Ordine manuale dal catalogo forniture', nullif(trim(p_notes), ''), 'console:catalogo', fabula.my_staff_id())
  returning id into v_po;
  for l in select * from jsonb_array_elements(p_lines) loop
    if coalesce((l->>'qty')::numeric, 0) <= 0 then continue; end if;
    select name, sku, unit, coalesce(iva_rate, 22) into v_name, v_sku, v_unit, v_iva from fabula.products where id = (l->>'product_id')::uuid;
    v_price := null;              -- review 13/10: never a price from the browser (a −€ line could pull the total under the limit)
    if v_price is null then
      select price_eur into v_price from fabula.supplier_prices where supplier_id = p_supplier_id and product_id = (l->>'product_id')::uuid and valid_from <= v_date order by valid_from desc, created_at desc limit 1;
    end if;
    if v_price is null then
      select price_eur into v_price from fabula.v_supplier_price_history where supplier_id = p_supplier_id and product_id = (l->>'product_id')::uuid and source = 'DDT' order by price_date desc limit 1;
    end if;
    if v_price <= 0 then v_price := null; end if;
    -- v0.99 (audit B-18): no silent €0 lines
    if v_price is null and not coalesce((l->>'price_tbc')::boolean, false) then
      raise exception using errcode = '22023',
        message = format('%s: manca il prezzo di %s. Scrivilo toccando il fornitore, oppure spunta «prezzo da confermare»', coalesce(v_name, 'articolo'), v_sup);
    end if;
    if v_price is null then v_missing := v_missing + 1; end if;
    insert into fabula.purchase_order_lines (purchase_order_id, product_id, qty_ordered, unit_price_eur, iva_rate)
    values (v_po, (l->>'product_id')::uuid, (l->>'qty')::numeric, coalesce(v_price, 0), v_iva);
    insert into fabula.supplier_products (supplier_id, product_id) values (p_supplier_id, (l->>'product_id')::uuid) on conflict do nothing;
    v_sub := v_sub + round((l->>'qty')::numeric * coalesce(v_price, 0), 2);
    v_ivat := v_ivat + round((l->>'qty')::numeric * coalesce(v_price, 0) * v_iva / 100, 2);
    v_lines := v_lines || jsonb_build_object('sku', v_sku, 'name', v_name, 'qty', (l->>'qty')::numeric, 'unit', v_unit, 'unit_price_eur', v_price,
                                             'total_eur', round((l->>'qty')::numeric * coalesce(v_price, 0), 2));
    v_n := v_n + 1;
  end loop;
  if v_n = 0 then raise exception using errcode = '22023', message = 'Nessuna quantità maggiore di zero'; end if;
  -- above the automatic limit, or from a profile that only «registra», a person approves it in Console → Oggi
  v_max := fabula.setting_num('approve.auto_po_max_eur', 150);
  -- a line «prezzo da confermare» counts € 0, so the real total is unknown: a person approves it whatever the profile
  v_needs := v_sub > v_max or v_missing > 0 or (auth.uid() is not null and not fabula.can('acquisti', 3));
  update fabula.purchase_orders set subtotal_eur = v_sub, iva_eur = v_ivat, total_eur = v_sub + v_ivat,
         status = case when v_needs then 'pending_approval'::fabula.po_status else 'approved'::fabula.po_status end
   where id = v_po;
  if v_needs then
    insert into fabula.approvals (kind, requested_by, summary, payload, related_table, related_id, amount_eur, expires_at)
    values ('purchase_order', v_who,
            format('Ordine %s: %s %s a %s, € %s (creato da %s dal catalogo)', v_no, v_n, case when v_n = 1 then 'riga' else 'righe' end, v_sup,
                   replace(to_char(v_sub, 'FM9999990.00'), '.', ','), v_who),
            jsonb_build_object('po_number', v_no, 'supplier', v_sup, 'supplier_email', v_email, 'lines', v_lines, 'total_eur', v_sub,
                               'created_by', v_who, 'manual', true, 'expected_date', v_date + v_lead, 'price_missing', v_missing > 0,
                               'over_limit', v_sub > v_max, 'limit_eur', v_max),
            'purchase_orders', v_po, v_sub, now() + interval '7 days')
    returning id into v_appr;
  end if;
  return jsonb_build_object('po_number', v_no, 'supplier', v_sup, 'lines', v_n, 'subtotal_eur', v_sub, 'expected_date', v_date + v_lead,
                            'price_missing', v_missing, 'status', case when v_needs then 'pending_approval' else 'approved' end,
                            'needs_approval', v_needs, 'approval_id', v_appr, 'limit_eur', v_max);
end $$;
revoke all on function fabula.create_manual_po(uuid, jsonb, text) from public, anon;
grant execute on function fabula.create_manual_po(uuid, jsonb, text) to authenticated, service_role;

create or replace function fabula.cancel_po(p_po_number text, p_reason text) returns jsonb
language plpgsql security definer set search_path = fabula, public as $$
declare po fabula.purchase_orders; v_who text; s record;
begin
  perform fabula.require_perm('acquisti', 2);
  if length(coalesce(trim(p_reason), '')) < 3 then raise exception using errcode = '22023', message = 'Scrivi perché annulli l''ordine'; end if;
  select * into po from fabula.purchase_orders where po_number = upper(trim(p_po_number)) for update;
  if not found then raise exception using errcode = '22023', message = format('Ordine %s non trovato', p_po_number); end if;
  if po.status = 'cancelled' then raise exception using errcode = '22023', message = format('L''ordine %s è già annullato', po.po_number); end if;
  if po.status in ('received', 'partially_received') or exists (select 1 from fabula.goods_receipts g where g.purchase_order_id = po.id) then
    raise exception using errcode = '22023', message = format('L''ordine %s è già stato ricevuto (anche in parte): non si annulla. Registra un reso al fornitore', po.po_number);
  end if;
  v_who := coalesce((select full_name from fabula.staff where id = fabula.my_staff_id()), 'sistema');
  update fabula.purchase_orders set status = 'cancelled', cancelled_at = now(), cancelled_by_id = fabula.my_staff_id(), cancel_reason = trim(p_reason), updated_at = now(),
         notes = concat_ws(E'\n', notes, format('[%s] annullato da %s: %s', to_char(now() at time zone 'Europe/Rome', 'DD/MM HH24:MI'), v_who, trim(p_reason)))
   where id = po.id;
  update fabula.approvals set status = 'rejected', decided_by = v_who, decided_at = now(), decision_note = 'ordine annullato: ' || trim(p_reason)
   where related_table = 'purchase_orders' and related_id = po.id and status = 'pending';
  select legal_name, email, phone into s from fabula.parties where id = po.supplier_id;
  return jsonb_build_object('po_number', po.po_number, 'was_status', po.status, 'was_sent', po.status = 'sent', 'supplier', s.legal_name,
    'email', s.email, 'phone', s.phone,
    'message_it', case when po.status = 'sent' then format('Buongiorno, vi chiediamo di annullare il nostro ordine %s del %s. Ci scusiamo per il disturbo. Grazie, %s',
                                                           po.po_number, to_char(po.order_date, 'DD/MM/YYYY'), fabula.company_name()) end);
end $$;
revoke all on function fabula.cancel_po(text, text) from public, anon;
grant execute on function fabula.cancel_po(text, text) to authenticated, service_role;

-- ============================================================================================================================
-- 2. B-19 · the 7-day milk forecast reads the Ingrosso plans
-- ============================================================================================================================
do $mig$
declare d text; n text;
begin
  d := pg_get_functiondef('fabula.demand_7d'::regproc);
  n := replace(d, $s$select coalesce(sum(so.qty_kg), 0) into v_stand from fabula.standing_orders so where so.active and so.product_id = v_moz and so.weekday = extract(isodow from d);$s$,
                  $s$select coalesce(sum(t.kg), 0) into v_stand from fabula.trade_effective_lines(d) t where t.product_id = v_moz;   -- v0.99 (audit B-19): the Ingrosso plans, not the old grid$s$);
  if n = d then raise exception 'v099b: demand_7d standing pattern not found'; end if;
  d := n;
  n := replace(d, $s$when v_stand > 0 then 'ordini fissi'$s$, $s$when v_stand > 0 then 'piani ingrosso'$s$);
  if n = d then raise exception 'v099b: demand_7d label pattern not found'; end if;
  execute n;
end $mig$;

-- ============================================================================================================================
-- 3. B-15 · «Togli» ends a component from tomorrow; the same day it can be put back
-- ============================================================================================================================
drop function if exists fabula.end_recipe_component(uuid);
create function fabula.end_recipe_component(p_recipe_id uuid) returns jsonb
language plpgsql set search_path = fabula, public, extensions as $$
declare r fabula.recipes; v_today date := (now() at time zone 'Europe/Rome')::date; v_who text; v_now boolean;
begin
  select * into r from fabula.recipes where id = p_recipe_id;
  if not found then raise exception using errcode = '22023', message = 'Componente non trovato: aggiorna la pagina'; end if;
  if r.valid_to is not null then raise exception using errcode = '22023', message = 'Componente già tolto dalla ricetta'; end if;
  v_who := coalesce((select full_name from fabula.staff where id = fabula.my_staff_id()), 'sistema');
  -- added (or changed) today: it stops at once, also for today's lots not yet dosed (review 13/10); otherwise from tomorrow
  v_now := r.valid_from >= v_today;
  update fabula.recipes set valid_to = case when v_now then v_today - 1 else v_today end,
         notes = concat_ws(E'\n', notes, format('[%s] tolto da %s: %s', to_char(now() at time zone 'Europe/Rome', 'DD/MM HH24:MI'), v_who,
                                                 case when v_now then 'non si dosa più già da ora (era stato inserito oggi)' else 'da domani non si dosa più' end))
   where id = p_recipe_id and valid_to is null;
  if not found then raise exception using errcode = '42501', message = 'Non tolto: il tuo profilo non può modificare le ricette'; end if;
  return jsonb_build_object('recipe_id', p_recipe_id, 'valid_to', case when v_now then v_today - 1 else v_today end, 'now', v_now);
end $$;
grant execute on function fabula.end_recipe_component(uuid) to authenticated, service_role;

create or replace function fabula.restore_recipe_component(p_recipe_id uuid) returns jsonb
language plpgsql set search_path = fabula, public, extensions as $$
declare r fabula.recipes; v_today date := (now() at time zone 'Europe/Rome')::date;
begin
  select * into r from fabula.recipes where id = p_recipe_id;
  if not found then raise exception using errcode = '22023', message = 'Componente non trovato: aggiorna la pagina'; end if;
  if r.valid_to is distinct from v_today then
    raise exception using errcode = '22023', message = 'Si rimette solo il giorno in cui è stato tolto: aggiungilo di nuovo dalla riga in fondo';
  end if;
  if exists (select 1 from fabula.recipes x where x.finished_product_id = r.finished_product_id and x.component_product_id = r.component_product_id
              and x.id <> r.id and (x.valid_to is null or x.valid_to > v_today)) then
    raise exception using errcode = '22023', message = 'Il componente è già di nuovo nella ricetta';
  end if;
  update fabula.recipes set valid_to = null,
         notes = concat_ws(E'\n', notes, format('[%s] rimesso nella ricetta', to_char(now() at time zone 'Europe/Rome', 'DD/MM HH24:MI')))
   where id = p_recipe_id;
  if not found then raise exception using errcode = '42501', message = 'Non rimesso: il tuo profilo non può modificare le ricette'; end if;
  return jsonb_build_object('recipe_id', p_recipe_id, 'valid_to', null);
end $$;
grant execute on function fabula.restore_recipe_component(uuid) to authenticated, service_role;

-- a dose saved on a removed row would put the component back from today without saying so
do $mig$
declare d text := pg_get_functiondef('fabula.update_recipe_dose(uuid, numeric, boolean, text, integer, text, boolean)'::regprocedure); n text;
begin
  n := replace(d, $o$  select name, unit into v_comp, v_unit from fabula.products where id = r.component_product_id;$o$,
               $n$  select name, unit into v_comp, v_unit from fabula.products where id = r.component_product_id;
  if r.valid_to is not null then   -- v0.99b (review 13/10)
    raise exception 'Componente tolto dalla ricetta: per rimetterlo usa «Rimetti» (oggi) o aggiungilo di nuovo dalla riga in fondo' using errcode = '22023';
  end if;$n$);
  if n = d then raise exception 'v099b: update_recipe_dose pattern not found'; end if;
  execute n;
end $mig$;

-- the editor shows the end date (a component taken out today is still dosed today: «tolto da domani · Rimetti»)
create or replace view fabula.v_recipe_editor with (security_invoker = true) as
 SELECT r.id AS recipe_id,
    f.sku AS finished_sku,
    f.name AS finished_name,
    c.id AS component_id,
    c.sku AS component_sku,
    c.name AS component_name,
    c.unit,
    (r.basis)::text AS basis,
    r.qty_per_unit,
    r.round_up,
    r.phase,
    r.step_order,
    r.instruction_it,
    r.valid_from,
    r.source,
    r.notes,
    r.valid_to
   FROM ((fabula.recipes r
     JOIN fabula.products f ON ((f.id = r.finished_product_id)))
     JOIN fabula.products c ON ((c.id = r.component_product_id)))
  WHERE ((r.valid_from <= ((now() AT TIME ZONE 'Europe/Rome'::text))::date) AND ((r.valid_to IS NULL) OR (r.valid_to >= ((now() AT TIME ZONE 'Europe/Rome'::text))::date)))
  ORDER BY f.sku, r.phase DESC, r.step_order, c.name;

-- ============================================================================================================================
-- 4. B-06 · lot release and NC closing
-- ============================================================================================================================
drop function if exists fabula.release_lot_hold(text, uuid, text);
create function fabula.release_lot_hold(p_lot text, p_staff_id uuid, p_note text, p_sample_code text default null) returns text
language plpgsql security definer set search_path = fabula, public, extensions as $$
declare v_lot text := upper(trim(coalesce(p_lot, ''))); v_s record; v_r record;
begin
  perform fabula.require_perm('haccp', 3);   -- v0.60: only HACCP managers release a lot, also through the API
  if length(coalesce(trim(p_note), '')) < 5 then raise exception using errcode = '22023', message = 'Serve una motivazione (es. esito analisi conforme, valutazione del consulente)'; end if;
  -- v0.99 (audit B-06): an open recall decision keeps the lot held
  -- and a decided recall keeps it held for good: the latest assessment of the lot decides (review 13/10)
  select status, decided_by, decided_at into v_r from fabula.approvals
   where payload->>'type' = 'recall_assessment' and upper(payload->>'lot') = v_lot order by requested_at desc limit 1;
  if v_r.status = 'pending' then
    raise exception using errcode = '22023',
      message = format('Prima decidi la valutazione di ritiro/richiamo del lotto %s (Console → Oggi): finché è aperta il lotto resta bloccato', v_lot);
  elsif v_r.status = 'approved' then
    raise exception using errcode = '22023',
      message = format('Per il lotto %s è stato deciso il ritiro/richiamo (%s, %s): non si sblocca. Il prodotto in giacenza va smaltito o reso come da procedura di ritiro',
                       v_lot, coalesce(v_r.decided_by, '?'), coalesce(to_char(v_r.decided_at at time zone 'Europe/Rome', 'DD/MM/YYYY'), ''));
  end if;
  if nullif(trim(p_sample_code), '') is not null then
    select s.sample_code, s.report_no, s.report_date into v_s from fabula.lab_samples s
     where s.sample_code = upper(trim(p_sample_code)) and upper(s.lot_number) = v_lot and s.outcome = 'conforme';
    if not found then
      raise exception using errcode = '22023', message = format('Il campione %s non è un''analisi conforme del lotto %s', upper(trim(p_sample_code)), v_lot);
    end if;
    p_note := format('analisi conforme %s%s · %s', v_s.sample_code, coalesce(' (referto ' || v_s.report_no || coalesce(' del ' || to_char(v_s.report_date, 'DD/MM/YYYY'), '') || ')', ''), trim(p_note));
  end if;
  perform set_config('fabula.hold_ctx', 'on', true);   -- v0.95a: the hold guard lets this update through
  update fabula.production_batches set food_safety_hold = false, hold_released_at = now(),
         hold_released_by_id = case when auth.uid() is not null then fabula.my_staff_id() else p_staff_id end,   -- a user can't sign as someone else
         notes = concat_ws(E'\n', notes, format('[%s] sblocco: %s', to_char(now() at time zone 'Europe/Rome', 'DD/MM HH24:MI'), trim(p_note)))
   where batch_lot = v_lot and food_safety_hold;
  if not found then raise exception using errcode = '22023', message = format('Lotto %s non bloccato', v_lot); end if;
  return 'released';
end $$;
revoke all on function fabula.release_lot_hold(text, uuid, text, text) from public, anon;
grant execute on function fabula.release_lot_hold(text, uuid, text, text) to authenticated, service_role;

create or replace function fabula.trg_nc_close_guard() returns trigger
language plpgsql security definer set search_path = fabula, public as $$
begin
  if auth.uid() is null then return new; end if;                 -- bots / SQL
  if (new.status = 'closed') is distinct from (old.status = 'closed') then
    perform fabula.require_perm('haccp', 3);
    if new.status = 'closed' then
      if coalesce(trim(new.corrective_action), '') = '' then      -- v0.99 (audit B-06): the browser asked; now the database does too
        raise exception using errcode = '22023', message = 'Scrivi l''azione correttiva prima di chiudere la non conformità';
      end if;
      new.closed_by_id := fabula.my_staff_id(); new.closed_at := now();
    else new.closed_by_id := null; new.closed_at := null; end if;
  elsif new.closed_by_id is distinct from old.closed_by_id then
    new.closed_by_id := old.closed_by_id;
  end if;
  return new;
end $$;

-- ============================================================================================================================
-- 5. B-22 / B-23 · what Shopify has, per product and per tier
-- ============================================================================================================================
alter table fabula.trade_products add column if not exists synced_price_eur numeric,
                                  add column if not exists synced_min_qty numeric,
                                  add column if not exists synced_step_qty numeric,
                                  add column if not exists synced_active boolean;
comment on column fabula.trade_products.synced_price_eur is 'v0.99 (audit B-22): reserved price last sent to Shopify (with synced_min_qty, synced_step_qty, synced_active): a difference = «da inviare»';
update fabula.trade_products set synced_price_eur = trade_price_eur, synced_min_qty = min_qty, synced_step_qty = step_qty, synced_active = active
 where synced_at is not null and synced_at >= updated_at and synced_active is null;
alter table fabula.trade_price_tiers add column if not exists changed_at timestamptz not null default now(),
                                     add column if not exists synced_at timestamptz;
comment on column fabula.trade_price_tiers.synced_at is 'v0.99 (audit B-23): last «Invia a Shopify» after which this tier was in the price list (or removed from it)';
update fabula.trade_price_tiers set synced_at = changed_at where synced_at is null;
create or replace function fabula.trg_trade_tier_changed() returns trigger language plpgsql set search_path = fabula, public as $$
begin
  if tg_op = 'INSERT' or (new.variant_id, new.min_qty, new.price_eur, new.discount_pct, new.active) is distinct from (old.variant_id, old.min_qty, old.price_eur, old.discount_pct, old.active) then
    new.changed_at := now();
  end if;
  return new;
end $$;
drop trigger if exists trade_price_tiers_changed on fabula.trade_price_tiers;
create trigger trade_price_tiers_changed before insert or update on fabula.trade_price_tiers for each row execute function fabula.trg_trade_tier_changed();
update fabula.trade_price_tiers set discount_pct = null where price_eur is not null and discount_pct is not null;   -- the old sync used the price
alter table fabula.trade_price_tiers drop constraint if exists trade_price_tiers_one_kind;
alter table fabula.trade_price_tiers add constraint trade_price_tiers_one_kind check (price_eur is null or discount_pct is null);
comment on constraint trade_price_tiers_one_kind on fabula.trade_price_tiers is 'Uno scaglione è un prezzo €/kg oppure uno sconto %, non tutti e due';
-- audit B-23: a € 0 tier would give the product away (the browser already refuses it; now the database does too)
update fabula.trade_price_tiers set active = false, price_eur = null, discount_pct = 0, note = concat_ws(' ', note, '[v0.99: prezzo 0 € tolto]')
 where price_eur is not null and price_eur <= 0;
alter table fabula.trade_price_tiers drop constraint if exists trade_price_tiers_price_pos;
alter table fabula.trade_price_tiers add constraint trade_price_tiers_price_pos check (price_eur is null or price_eur > 0);

-- ============================================================================================================================
-- 5b. TRADE-06 · a customer who stops the plan from the portal: the office sees it on the dashboard the same minute
--     (customer e-mail/WhatsApp confirmations need a customer messaging channel: backlog)
-- ============================================================================================================================
do $mig$
declare d text := pg_get_functiondef('fabula.trade_set_status(uuid, text, date, text)'::regprocedure); n text;
begin
  n := replace(d, $o$  perform fabula.trade_log(p_customer, p_actor, 'status_' || p_status, jsonb_build_object('until', p_until), msg);$o$,
               $n$  perform fabula.trade_log(p_customer, p_actor, 'status_' || p_status, jsonb_build_object('until', p_until), msg);
  if p_actor = 'customer' and (p_status = 'cancelled' or (p_status = 'paused' and p_until is null)) then   -- v0.99b (audit TRADE-06)
    begin
      perform fabula.post_bot_message('wholesale_orders', 'warn',
        left(format('%s ha %s dal portale', coalesce((select coalesce(trade_name, legal_name) from fabula.parties where id = p_customer), 'Un cliente'),
                    case when p_status = 'cancelled' then 'annullato il piano consegne' else 'messo in pausa il piano senza data' end), 120),
        msg || E'

' || coalesce('Se non era voluto chiamalo: ' || nullif((select phone from fabula.parties where id = p_customer), '') || '. ', '')
            || 'Ingrosso → Clienti e piani.');
    exception when others then raise warning 'trade_set_status message: %', sqlerrm;
    end;
  end if;$n$);
  if n = d then raise exception 'v099b: trade_set_status pattern not found'; end if;
  execute n;
end $mig$;

-- ============================================================================================================================
-- 5c. B-19 · the Vendite numbers read the Ingrosso plans too (the old grid is frozen)
-- ============================================================================================================================
do $mig$
declare d text := pg_get_functiondef('fabula.sales_status(date)'::regprocedure); n text;
begin
  n := replace(d, $o$'standing_kg_week', (select round(coalesce(sum(qty_kg), 0), 1) from fabula.standing_orders where active),$o$,
               $n$'standing_kg_week', (select round(coalesce(sum(e.kg), 0), 1) from generate_series(d + 1, d + 7, interval '1 day') g
                                      cross join lateral fabula.trade_effective_lines(g::date) e),   -- v0.99b (audit B-19): next 7 days of plans$n$);
  n := replace(n, $o$and not exists (select 1 from fabula.standing_orders s where s.customer_id = x.customer_id and s.active))),$o$,
                  $n$and not exists (select 1 from fabula.trade_schedules s where s.customer_id = x.customer_id and s.status = 'active'))),$n$);
  if n = d or n !~ 'trade_schedules s where' or n ~ 'standing_orders' then raise exception 'v099b: sales_status patterns not found'; end if;
  execute n;
end $mig$;

-- ============================================================================================================================
-- 6. Security check
-- ============================================================================================================================
insert into fabula.security_accepted (key, reason, accepted_at) values
 ('authenticated_security_definer_function_executable:fabula.create_manual_po(p_supplier_id uuid, p_lines jsonb, p_notes text)',
  'by design (v0.89a, v0.99b audit B-18): require_perm(acquisti, 2) first; above the automatic limit or from level 2 the order waits for approval', now()),
 ('authenticated_security_definer_function_executable:fabula.cancel_po(p_po_number text, p_reason text)',
  'by design (v0.99b, audit B-18): require_perm(acquisti, 2) first; never a received order', now()),
 ('authenticated_security_definer_function_executable:fabula.release_lot_hold(p_lot text, p_staff_id uuid, p_note text, p_sample_code text)',
  'by design (v0.60, v0.99b audit B-06): require_perm(haccp, 3) first; signer from the login; blocked while a recall decision is open or after a recall', now())
on conflict (key) do update set reason = excluded.reason, accepted_at = excluded.accepted_at;
delete from fabula.security_accepted
 where key = 'authenticated_security_definer_function_executable:fabula.release_lot_hold(p_lot text, p_staff_id uuid, p_note text)';

insert into supabase_migrations.schema_migrations (version, name) values
  ('20261013210000', 'v099a_approvals_decide_undo'),
  ('20261013210100', 'v099b_orders_recipes_holds_prices');
commit;

select version, name from supabase_migrations.schema_migrations order by version desc limit 5;
