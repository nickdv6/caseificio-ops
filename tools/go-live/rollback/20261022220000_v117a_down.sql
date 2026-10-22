-- Rollback of v1.17a (audit D-1): removes the login guard on the legal registers and puts back exactly what was live before it.
-- v1.17a only ADDED objects (one trigger function, five triggers); it changed no grant, policy, existing trigger or function, and no
-- data, so dropping them is the whole rollback. To use it, copy it into supabase/migrations under a new, later version and release it
-- through the pipeline like any other release (the pipeline never re-releases an older commit).

drop trigger if exists haccp_log_a0_login_guard on fabula.haccp_log;
drop trigger if exists batch_a0_login_guard on fabula.production_batches;
drop trigger if exists stock_moves_a0_login_guard on fabula.stock_moves;
drop trigger if exists lab_samples_a0_login_guard on fabula.lab_samples;
drop trigger if exists milk_intake_a0_login_guard on fabula.milk_intake;
drop function if exists fabula.trg_login_record_guard();
