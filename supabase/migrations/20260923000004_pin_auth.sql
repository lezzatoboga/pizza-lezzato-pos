-- =====================================================================
-- Autentikasi PIN
--
-- Alur: pilih nama → masukkan PIN → Edge Function `pos-pin-login`
-- memanggil verify_pos_user_pin() (service_role) → kalau benar, Edge
-- Function menerbitkan sesi Supabase Auth untuk auth user milik pos_user.
--
--   * PIN di-hash bcrypt di database (pgcrypto), 4–6 digit angka.
--   * 5x salah berturut-turut → akun terkunci 5 menit.
--   * Identitas di RLS: current_pos_user_id() / has_permission() membaca
--     pos_users lewat auth.uid() — user nonaktif otomatis kehilangan akses
--     walau sesinya masih ada.
--   * last_edited_by pesanan website diisi otomatis dari sesi login.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

alter table public.pos_users
  add column failed_pin_attempts integer not null default 0,
  add column pin_locked_until    timestamptz;

-- ---------------------------------------------------------------------
-- Kelola PIN (hanya service_role / SQL editor)
-- ---------------------------------------------------------------------
create or replace function public.assert_valid_pin(p_pin text)
returns void
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p_pin is null or p_pin !~ '^[0-9]{4,6}$' then
    raise exception 'PIN_TIDAK_VALID: PIN harus 4–6 digit angka';
  end if;
end;
$$;

create or replace function public.create_pos_user(p_name text, p_role_code text, p_pin text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role_id uuid;
  v_id      uuid;
begin
  perform public.assert_valid_pin(p_pin);

  select id into v_role_id from public.roles where code = p_role_code;
  if v_role_id is null then
    raise exception 'Role % tidak ditemukan (pilihan: owner, supervisor, kasir)', p_role_code;
  end if;

  insert into public.pos_users (name, role_id, pin_hash)
  values (trim(p_name), v_role_id, extensions.crypt(p_pin, extensions.gen_salt('bf', 10)))
  returning id into v_id;

  return v_id;
end;
$$;

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
      pin_locked_until = null
  where id = p_user_id;

  if not found then
    raise exception 'Pengguna % tidak ditemukan', p_user_id;
  end if;
end;
$$;

-- Hasil: {status: 'ok' | 'invalid' | 'locked', ...}
-- Tidak pernah raise untuk PIN salah, supaya hitungan gagal ikut tersimpan.
create or replace function public.verify_pos_user_pin(p_user_id uuid, p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user public.pos_users%rowtype;
  v_max_attempts constant integer := 5;
  v_lock_duration constant interval := interval '5 minutes';
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
    set failed_pin_attempts = 0, pin_locked_until = null
    where id = p_user_id;

    return jsonb_build_object(
      'status', 'ok',
      'pos_user_id', v_user.id,
      'auth_user_id', v_user.auth_user_id
    );
  end if;

  if v_user.failed_pin_attempts + 1 >= v_max_attempts then
    update public.pos_users
    set failed_pin_attempts = 0, pin_locked_until = now() + v_lock_duration
    where id = p_user_id;

    return jsonb_build_object('status', 'locked', 'locked_until', now() + v_lock_duration);
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

-- ---------------------------------------------------------------------
-- Identitas & izin untuk RLS dan aplikasi
-- ---------------------------------------------------------------------
create or replace function public.current_pos_user_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select id from public.pos_users
  where auth_user_id = auth.uid() and active;
$$;

create or replace function public.has_permission(p_code text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((
    select rp.granted
    from public.pos_users u
    join public.role_permissions rp on rp.role_id = u.role_id
    where u.auth_user_id = auth.uid()
      and u.active
      and rp.permission_code = p_code
  ), false);
$$;

-- Profil pengguna yang sedang login + daftar izin yang aktif.
-- null kalau sesi tidak terhubung ke pos_user aktif.
create or replace function public.get_my_profile()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', u.id,
    'name', u.name,
    'role', jsonb_build_object('code', r.code, 'name', r.name),
    'permissions', coalesce((
      select jsonb_agg(rp.permission_code order by rp.permission_code)
      from public.role_permissions rp
      where rp.role_id = u.role_id and rp.granted
    ), '[]'::jsonb)
  )
  from public.pos_users u
  join public.roles r on r.id = u.role_id
  where u.auth_user_id = auth.uid() and u.active;
$$;

-- ---------------------------------------------------------------------
-- last_edited_by / last_edited_at otomatis untuk pesanan website.
-- Hanya dari sesi kasir; perubahan oleh jembatan API (service_role)
-- tidak dihitung sebagai edit. Nilai kiriman aplikasi diabaikan.
-- ---------------------------------------------------------------------
create or replace function public.stamp_website_edit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := public.current_pos_user_id();
begin
  if v_user is null then
    return new;
  end if;

  if new.channel = 'website'
     and (new.shipping_cost  is distinct from old.shipping_cost
       or new.subtotal       is distinct from old.subtotal
       or new.last_edited_at is distinct from old.last_edited_at) then
    new.last_edited_by := v_user;
    new.last_edited_at := now();
  else
    new.last_edited_by := old.last_edited_by;
    new.last_edited_at := old.last_edited_at;
  end if;

  return new;
end;
$$;

create trigger transactions_stamp_website_edit
  before update on public.transactions
  for each row execute function public.stamp_website_edit();

-- Perubahan item/topping pesanan website oleh kasir ikut tercatat,
-- walau aplikasi lupa memperbarui baris transaksinya.
create or replace function public.touch_website_transaction(p_transaction_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_transaction_id is null or public.current_pos_user_id() is null then
    return;
  end if;

  update public.transactions
  set last_edited_at = now()
  where id = p_transaction_id and channel = 'website' and not is_locked;
end;
$$;

create or replace function public.touch_on_item_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.touch_website_transaction(
    case when tg_op = 'DELETE' then old.transaction_id else new.transaction_id end
  );
  return null;
end;
$$;

create trigger transaction_items_touch_website
  after insert or update or delete on public.transaction_items
  for each row execute function public.touch_on_item_change();

create or replace function public.touch_on_addon_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_transaction_id uuid;
begin
  select transaction_id into v_transaction_id
  from public.transaction_items
  where id = case when tg_op = 'DELETE' then old.transaction_item_id else new.transaction_item_id end;

  perform public.touch_website_transaction(v_transaction_id);
  return null;
end;
$$;

create trigger transaction_item_addons_touch_website
  after insert or update or delete on public.transaction_item_addons
  for each row execute function public.touch_on_addon_change();

-- ---------------------------------------------------------------------
-- Hak eksekusi
-- ---------------------------------------------------------------------
revoke execute on function public.assert_valid_pin(text)                 from public, anon, authenticated;
revoke execute on function public.create_pos_user(text, text, text)      from public, anon, authenticated;
revoke execute on function public.set_pos_user_pin(uuid, text)           from public, anon, authenticated;
revoke execute on function public.verify_pos_user_pin(uuid, text)        from public, anon, authenticated;
revoke execute on function public.stamp_website_edit()                   from public, anon, authenticated;
revoke execute on function public.touch_website_transaction(uuid)        from public, anon, authenticated;
revoke execute on function public.touch_on_item_change()                 from public, anon, authenticated;
revoke execute on function public.touch_on_addon_change()                from public, anon, authenticated;

grant execute on function public.create_pos_user(text, text, text)       to service_role;
grant execute on function public.set_pos_user_pin(uuid, text)            to service_role;
grant execute on function public.verify_pos_user_pin(uuid, text)         to service_role;

revoke execute on function public.current_pos_user_id()                  from public, anon;
revoke execute on function public.has_permission(text)                   from public, anon;
revoke execute on function public.get_my_profile()                       from public, anon;
grant execute on function public.current_pos_user_id()                   to authenticated;
grant execute on function public.has_permission(text)                    to authenticated;
grant execute on function public.get_my_profile()                        to authenticated;
