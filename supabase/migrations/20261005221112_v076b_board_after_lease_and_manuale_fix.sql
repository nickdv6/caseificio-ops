-- v0.76b (05/10/2026) · board text after the lease fix and the Manuale correction (DQA → RINA Agrifood in all 3 places).
insert into fabula.dash_checks (key, sort, label, kind, done, note, updated_at) values
 ('dop_control', 4, 'DOP: in the RINA control system, Consorzio marks ordered', 'manual', false, 'RINA adhesion as caseificio (€490) and the farm as allevatore (€80); Consorzio contrassegni for every pack; buffalo traceability platform; read the statute non-compete first. The Manuale already names RINA Agrifood (corrected 05/10).', now())
on conflict (key) do update set note = excluded.note, updated_at = excluded.updated_at;

insert into fabula.dash_areas (area, sort, built, reliable, automated, next_step, evidence, updated_at) values
 ('Compliance & HACCP', 7, 0, 0, 0, 'CE approval and SCIA moved to Masseria (record food.ce_approval_no); RINA adhesion (caseificio + farm) and Consorzio marks; HACCP training for everyone (Manuale → Formazione); consultant signs the Manuale; calibrate the pasteuriser, 2 scales and reference thermometer; MOZ-DOP moisture test; confirm the provisional deadline dates', '', now())
on conflict (area) do update set next_step = excluded.next_step, updated_at = excluded.updated_at;
