-- v0.91a: legal name on every form/document = Società Agricola Masseria Cilentana S.S.
-- company.name (trading name / plant) stays "Caseificio Bubalina"; HACCP registers print it as "Stabilimento".
update fabula.settings set value = 'Società Agricola Masseria Cilentana S.S.' where key = 'company.legal_name';
