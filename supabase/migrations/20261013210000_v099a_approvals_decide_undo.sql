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
