-- v0.90a: go-live board — Procurement user-friendliness after the supply catalogue rework (v0.90, front end only).
update fabula.dash_areas
   set prev = coalesce(prev, '{}'::jsonb) || jsonb_build_object('usable', usable)
 where usable is not null;

update fabula.dash_areas
   set usable = 66,
       usable_why = 'v0.90 supply catalogue: Ordina mode (only the quantity is editable, unorderable items hidden), Proponi i sotto soglia, minimum order warned and pack multiples rounded as you type, one PO per supplier with a jump to Invia. Assegna articoli links a supplier to many items with prices in one save (was 4 taps and a reload per item). Purchase signals have an Ordina button, approved POs point to sending, and suppliers without email or phone are flagged before sending. Still behind Katana-class purchasing: orders go out by mailto or WhatsApp rather than from the app, 23 of 28 items have no supplier and 2 suppliers are placeholders, so nothing has been ordered for real.'
 where area = 'Procurement';
