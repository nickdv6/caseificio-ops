-- v0.81b: record reviewed security exceptions introduced by v0.81 (login state)
insert into fabula.security_accepted (key, reason) values
  ('authenticated_security_definer_function_executable:fabula.staff_logins()',
   'by design: Utenti e ruoli login state (v0.81); raises 42501 unless service_role or can_manage_users(); staff_login_rows() itself is service_role only — reviewed v0.81b'),
  ('advisor:auth_otp_long_expiry',
   'by design: Email OTP expiry raised to 24 h on 06/10 so invite links survive until the invitee opens them (1 h links expired before use); small staff, reviewed v0.81b')
on conflict (key) do nothing;
