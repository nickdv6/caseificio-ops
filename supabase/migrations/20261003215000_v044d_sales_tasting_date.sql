-- v044d · tasting_date: a logged 'degustazione' = the tasting happened (activity date); a next step that names a tasting schedules it.
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
     tasting_date = case when new.kind in ('degustazione','campione') then (new.at at time zone 'Europe/Rome')::date
                         when new.next_action ~* 'degust|assaggi|campion' and new.next_action_date is not null then new.next_action_date
                         else l.tasting_date end,
     next_action = case when new.next_action is not null or new.next_action_date is not null then new.next_action else l.next_action end,
     next_action_date = case when new.next_action is not null or new.next_action_date is not null then new.next_action_date else l.next_action_date end
   where l.id = new.lead_id;
  return new;
end $$;
