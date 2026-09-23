-- =====================================================================
-- Kunci PIN bertingkat: setiap 5x salah berturut-turut, akun dikunci
-- makin lama — 5 menit → 30 menit → 24 jam (dan 24 jam seterusnya) —
-- sampai ada login berhasil atau Owner mengganti PIN.
-- =====================================================================

alter table public.pos_users
  add column pin_lockout_level integer not null default 0;

comment on column public.pos_users.pin_lockout_level is
  'Berapa kali akun sudah dikunci sejak login berhasil terakhir. Menentukan lama kunci berikutnya.';

create or replace function public.pin_lock_duration(p_level integer)
returns interval
language sql
immutable
set search_path = ''
as $$
  select case
    when p_level <= 1 then interval '5 minutes'
    when p_level = 2  then interval '30 minutes'
    else interval '24 hours'
  end;
$$;

create or replace function public.verify_pos_user_pin(p_user_id uuid, p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user public.pos_users%rowtype;
  v_max_attempts constant integer := 5;
  v_level integer;
  v_until timestamptz;
begin
  select * into v_user from public.pos_users where id = p_user_id for update;

  if not found or not v_user.active then
    return jsonb_build_object('status', 'invalid');
  end if;

  if v_user.pin_locked_until is not null and v_user.pin_locked_until > now() then
    return jsonb_build_object('status', 'locked', 'locked_until', v_user.pin_locked_until);
  end if;

  if p_pin is not null and extensions.crypt(p_pin, v_user.pin_hash) = v_user.pin_hash then
    update public.pos_users
    set failed_pin_attempts = 0, pin_locked_until = null, pin_lockout_level = 0
    where id = p_user_id;

    return jsonb_build_object(
      'status', 'ok',
      'pos_user_id', v_user.id,
      'auth_user_id', v_user.auth_user_id
    );
  end if;

  if v_user.failed_pin_attempts + 1 >= v_max_attempts then
    v_level := v_user.pin_lockout_level + 1;
    v_until := now() + public.pin_lock_duration(v_level);

    update public.pos_users
    set failed_pin_attempts = 0, pin_locked_until = v_until, pin_lockout_level = v_level
    where id = p_user_id;

    return jsonb_build_object('status', 'locked', 'locked_until', v_until);
  end if;

  update public.pos_users
  set failed_pin_attempts = failed_pin_attempts + 1
  where id = p_user_id;

  return jsonb_build_object(
    'status', 'invalid',
    'attempts_left', v_max_attempts - (v_user.failed_pin_attempts + 1)
  );
end;
$$;

-- Owner mengganti PIN = membuka semua kunci.
create or replace function public.set_pos_user_pin(p_user_id uuid, p_pin text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.assert_valid_pin(p_pin);

  update public.pos_users
  set pin_hash = extensions.crypt(p_pin, extensions.gen_salt('bf', 10)),
      failed_pin_attempts = 0,
      pin_locked_until = null,
      pin_lockout_level = 0
  where id = p_user_id;

  if not found then
    raise exception 'Pengguna % tidak ditemukan', p_user_id;
  end if;
end;
$$;

revoke execute on function public.pin_lock_duration(integer) from public, anon, authenticated;
revoke execute on function public.verify_pos_user_pin(uuid, text) from public, anon, authenticated;
revoke execute on function public.set_pos_user_pin(uuid, text) from public, anon, authenticated;
grant execute on function public.verify_pos_user_pin(uuid, text) to service_role;
grant execute on function public.set_pos_user_pin(uuid, text) to service_role;
