-- v0.91b: plant address, responsabile autocontrollo, company email (Nick, 12/10/2026). CE number still pending.
update fabula.settings set value = 'Via Salvo D''Acquisto 17, 84043 Agropoli (SA)' where key = 'company.address';
update fabula.settings set value = 'Nicola Celso' where key = 'food.responsabile_autocontrollo';
update fabula.settings set value = 'info@bubalina.it' where key = 'company.email';
