-- Fabula v0.83h — "pausa fino al" writes one confirmation (the skip range is inserted directly, not through trade_add_exception)
set search_path = fabula, public, extensions;

create or replace function fabula.trade_set_status(p_customer uuid, p_status text, p_until date default null, p_actor text default 'customer')
returns jsonb language plpgsql set search_path = fabula, public as $$
declare msg text; s jsonb := fabula.trade_settings(); d1 date;
begin
  if p_status not in ('active','paused','cancelled') then raise exception 'Stato non valido' using errcode = '22023'; end if;
  if not exists (select 1 from fabula.trade_schedules where customer_id = p_customer) then raise exception 'Nessun piano consegne' using errcode = '22023'; end if;
  if p_status = 'paused' then
    if p_until is not null then
      d1 := fabula.trade_now_rome()::date + case when fabula.trade_can_change(fabula.trade_now_rome()::date + 1) then 1 else 2 end;
      if p_until < d1 then raise exception 'La pausa deve finire almeno il %', to_char(d1, 'DD/MM') using errcode = '22023'; end if;
      update fabula.trade_exceptions set cancelled_at = now() where customer_id = p_customer and kind = 'skip' and note = 'pausa' and cancelled_at is null and date_to >= d1;
      insert into fabula.trade_exceptions (customer_id, kind, date_from, date_to, note, created_by) values (p_customer, 'skip', d1, p_until, 'pausa', p_actor);
      update fabula.trade_schedules set paused_from = null, paused_until = p_until, updated_at = now(), updated_by = p_actor where customer_id = p_customer;
      msg := format('Piano in pausa dal %s al %s: riprende da solo il giorno dopo.', to_char(d1, 'DD/MM/YYYY'), to_char(p_until, 'DD/MM/YYYY'));
    else
      update fabula.trade_schedules set status = 'paused', paused_from = fabula.trade_now_rome()::date, paused_until = null, updated_at = now(), updated_by = p_actor where customer_id = p_customer;
      msg := 'Piano in pausa: nessuna consegna finché non lo riattivi. ' || case when not fabula.trade_can_change(fabula.trade_now_rome()::date + 1) then 'La consegna di domani è già confermata e sarà consegnata.' else '' end;
    end if;
  elsif p_status = 'active' then
    update fabula.trade_schedules set status = 'active', paused_from = null, paused_until = null, end_date = null, updated_at = now(), updated_by = p_actor where customer_id = p_customer;
    update fabula.trade_exceptions set cancelled_at = now() where customer_id = p_customer and kind = 'skip' and note = 'pausa' and cancelled_at is null and date_to >= fabula.trade_now_rome()::date;
    msg := 'Piano consegne riattivato.';
  else
    update fabula.trade_schedules set status = 'cancelled', end_date = fabula.trade_now_rome()::date, updated_at = now(), updated_by = p_actor where customer_id = p_customer;
    msg := 'Piano consegne annullato. ' || case when not fabula.trade_can_change(fabula.trade_now_rome()::date + 1) then 'La consegna di domani è già confermata e sarà consegnata.' else '' end;
  end if;
  perform fabula.trade_log(p_customer, p_actor, 'status_' || p_status, jsonb_build_object('until', p_until), msg);
  return jsonb_build_object('ok', true, 'message_it', msg);
end $$;
