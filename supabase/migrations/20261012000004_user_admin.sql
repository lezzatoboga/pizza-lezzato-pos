-- =====================================================================
-- Kelola pengguna & hak akses dari aplikasi (khusus Owner)
--
-- Keputusan Owner (2026-10-12):
--   - Hanya Owner: izin manage_users & manage_permissions selalu aktif
--     untuk role Owner dan tidak bisa diberikan ke role lain.
--   - Seluruh kolom Owner di matriks izin terkunci (semua izin aktif).
--   - Tidak bisa menonaktifkan/menurunkan Owner aktif terakhir; tidak bisa
--     mengubah role atau menonaktifkan diri sendiri.
--   - PIN 4–6 digit diisi Owner, disimpan sebagai hash bcrypt, tidak
--     pernah dikembalikan dan tidak pernah dicatat di log.
--   - Pengguna tidak pernah dihapus (hanya dinonaktifkan) agar riwayat
--     transaksi/shift/void tetap utuh.
--   - Nama unik di antara pengguna aktif.
--   - Jejak audit di user_admin_log, dibaca lewat RPC khusus Owner.
-- create_pos_user / set_pos_user_pin tetap ada untuk SQL Editor (darurat).
-- =====================================================================

-- ---------------------------------------------------------------------
-- Matriks izin lengkap; Owner semua aktif; izin admin hanya Owner
-- ---------------------------------------------------------------------
insert into public.role_permissions (role_id, permission_code, granted)
select r.id, p.code, false
from public.roles r cross join public.permissions p
on conflict (role_id, permission_code) do nothing;

update public.role_permissions rp
set granted = true
from public.roles r
where r.id = rp.role_id and r.code = 'owner' and not rp.granted;

update public.role_permissions rp
set granted = false
from public.roles r
where r.id = rp.role_id and r.code <> 'owner'
  and rp.permission_code in ('manage_users', 'manage_permissions') and rp.granted;

-- ---------------------------------------------------------------------
-- Nama unik di antara pengguna aktif (huruf besar/kecil & spasi diabaikan)
-- ---------------------------------------------------------------------
create or replace function public.normalize_user_name(p_name text)
returns text
language sql
immutable
set search_path = ''
as $$
  select lower(regexp_replace(btrim(p_name), '\s+', ' ', 'g'));
$$;

do $$
declare
  v_dupes text;
begin
  select string_agg(n, ', ') into v_dupes
  from (
    select min(name) as n from public.pos_users where active
    group by public.normalize_user_name(name) having count(*) > 1
  ) d;
  if v_dupes is not null then
    raise exception 'Ada nama pengguna aktif yang sama: %. Ubah atau nonaktifkan salah satunya dulu, lalu ulangi migrasi.', v_dupes;
  end if;
end;
$$;

create unique index pos_users_active_name_uq
  on public.pos_users (public.normalize_user_name(name)) where active;

-- ---------------------------------------------------------------------
-- Jejak audit
-- ---------------------------------------------------------------------
create table public.user_admin_log (
  id              uuid primary key default gen_random_uuid(),
  created_at      timestamptz not null default now(),
  actor_id        uuid references public.pos_users (id),
  target_user_id  uuid references public.pos_users (id),
  action          text not null,
  details         jsonb not null default '{}'::jsonb,
  constraint user_admin_log_action check (action in (
    'buat', 'ubah_nama', 'ubah_role', 'nonaktifkan', 'aktifkan',
    'reset_pin', 'buka_kunci', 'ubah_izin'))
);

create index user_admin_log_created_idx on public.user_admin_log (created_at desc);

alter table public.user_admin_log enable row level security;
grant select, insert, update, delete on public.user_admin_log to service_role;
-- authenticated: sengaja tanpa grant — dibaca lewat admin_audit_log().

-- ---------------------------------------------------------------------
-- Pembantu internal
-- ---------------------------------------------------------------------
-- Izin admin + harus role Owner (lapis kedua kalau izin salah diberikan).
create or replace function public.assert_owner_admin(p_code text)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user uuid := public.current_pos_user_id();
begin
  perform public.assert_permission(p_code);
  if not exists (
    select 1 from public.pos_users u join public.roles r on r.id = u.role_id
    where u.id = v_user and r.code = 'owner'
  ) then
    raise exception 'TIDAK_BERIZIN: fitur ini khusus Owner';
  end if;
  return v_user;
end;
$$;

create or replace function public.admin_log(
  p_actor uuid, p_target uuid, p_action text, p_details jsonb default '{}'::jsonb
)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.user_admin_log (actor_id, target_user_id, action, details)
  values (p_actor, p_target, p_action, coalesce(p_details, '{}'::jsonb));
$$;

create or replace function public.clean_user_name(p_name text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_name text := regexp_replace(btrim(coalesce(p_name, '')), '\s+', ' ', 'g');
begin
  if v_name = '' then
    raise exception 'NAMA_WAJIB: isi nama pengguna';
  end if;
  if length(v_name) > 40 then
    raise exception 'NAMA_TERLALU_PANJANG: nama maksimal 40 karakter';
  end if;
  return v_name;
end;
$$;

create or replace function public.assert_name_available(p_name text, p_except uuid default null)
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if exists (
    select 1 from public.pos_users
    where active and public.normalize_user_name(name) = public.normalize_user_name(p_name)
      and id is distinct from p_except
  ) then
    raise exception 'NAMA_SUDAH_DIPAKAI: sudah ada pengguna aktif bernama "%"', p_name;
  end if;
end;
$$;

-- Owner aktif selain p_except.
create or replace function public.other_active_owner_count(p_except uuid)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select count(*)::integer
  from public.pos_users u join public.roles r on r.id = u.role_id
  where u.active and r.code = 'owner' and u.id <> p_except;
$$;

-- ---------------------------------------------------------------------
-- Daftar pengguna (tanpa pin_hash)
-- ---------------------------------------------------------------------
create or replace function public.admin_list_users()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform public.assert_owner_admin('manage_users');

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', u.id,
      'name', u.name,
      'role_code', r.code,
      'role_name', r.name,
      'active', u.active,
      'failed_pin_attempts', u.failed_pin_attempts,
      'pin_locked_until', case when u.pin_locked_until > now() then u.pin_locked_until end,
      'pin_lockout_level', u.pin_lockout_level,
      'created_at', u.created_at,
      'last_sign_in_at', a.last_sign_in_at,
      'is_me', u.id = public.current_pos_user_id()
    ) order by u.active desc,
               case r.code when 'owner' then 1 when 'supervisor' then 2 else 3 end,
               lower(u.name))
    from public.pos_users u
    join public.roles r on r.id = u.role_id
    left join auth.users a on a.id = u.auth_user_id
  ), '[]');
end;
$$;

-- ---------------------------------------------------------------------
-- Tambah pengguna
-- ---------------------------------------------------------------------
create or replace function public.admin_create_user(p_name text, p_role_code text, p_pin text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := public.assert_owner_admin('manage_users');
  v_name  text := public.clean_user_name(p_name);
  v_role  public.roles;
  v_id    uuid;
begin
  perform public.assert_valid_pin(p_pin);
  select * into v_role from public.roles where code = p_role_code;
  if v_role.id is null then
    raise exception 'ROLE_TIDAK_VALID: pilih Owner, Supervisor, atau Kasir';
  end if;
  perform public.assert_name_available(v_name);

  insert into public.pos_users (name, role_id, pin_hash)
  values (v_name, v_role.id, extensions.crypt(p_pin, extensions.gen_salt('bf', 10)))
  returning id into v_id;

  perform public.admin_log(v_actor, v_id, 'buat',
    jsonb_build_object('name', v_name, 'role', v_role.name));
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- Ubah nama / role
-- ---------------------------------------------------------------------
create or replace function public.admin_update_user(p_user_id uuid, p_name text, p_role_code text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor    uuid := public.assert_owner_admin('manage_users');
  v_user     public.pos_users;
  v_old_role public.roles;
  v_new_role public.roles;
  v_name     text := public.clean_user_name(p_name);
begin
  select * into v_user from public.pos_users where id = p_user_id for update;
  if v_user.id is null then
    raise exception 'PENGGUNA_TIDAK_ADA: pengguna tidak ditemukan';
  end if;
  select * into v_old_role from public.roles where id = v_user.role_id;
  select * into v_new_role from public.roles where code = p_role_code;
  if v_new_role.id is null then
    raise exception 'ROLE_TIDAK_VALID: pilih Owner, Supervisor, atau Kasir';
  end if;

  if v_new_role.id <> v_old_role.id then
    if v_user.id = v_actor then
      raise exception 'TIDAK_BOLEH: Anda tidak bisa mengubah role akun Anda sendiri';
    end if;
    if v_old_role.code = 'owner' and v_user.active
       and public.other_active_owner_count(v_user.id) = 0 then
      raise exception 'OWNER_TERAKHIR: harus ada minimal satu Owner aktif';
    end if;
  end if;

  if v_name <> v_user.name then
    if v_user.active then
      perform public.assert_name_available(v_name, v_user.id);
    end if;
    update public.pos_users set name = v_name, updated_at = now() where id = v_user.id;
    perform public.admin_log(v_actor, v_user.id, 'ubah_nama',
      jsonb_build_object('from', v_user.name, 'to', v_name));
  end if;

  if v_new_role.id <> v_old_role.id then
    update public.pos_users set role_id = v_new_role.id, updated_at = now() where id = v_user.id;
    perform public.admin_log(v_actor, v_user.id, 'ubah_role',
      jsonb_build_object('from', v_old_role.name, 'to', v_new_role.name));
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- Nonaktifkan / aktifkan
-- ---------------------------------------------------------------------
create or replace function public.admin_set_user_active(p_user_id uuid, p_active boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := public.assert_owner_admin('manage_users');
  v_user  public.pos_users;
  v_role  text;
begin
  if p_active is null then
    raise exception 'NILAI_TIDAK_VALID: pilih aktif atau nonaktif';
  end if;
  select * into v_user from public.pos_users where id = p_user_id for update;
  if v_user.id is null then
    raise exception 'PENGGUNA_TIDAK_ADA: pengguna tidak ditemukan';
  end if;
  if v_user.active = p_active then
    return;
  end if;
  select code into v_role from public.roles where id = v_user.role_id;

  if not p_active then
    if v_user.id = v_actor then
      raise exception 'TIDAK_BOLEH: Anda tidak bisa menonaktifkan akun Anda sendiri';
    end if;
    if v_role = 'owner' and public.other_active_owner_count(v_user.id) = 0 then
      raise exception 'OWNER_TERAKHIR: harus ada minimal satu Owner aktif';
    end if;
  else
    perform public.assert_name_available(v_user.name, v_user.id);
  end if;

  update public.pos_users set active = p_active, updated_at = now() where id = v_user.id;
  perform public.admin_log(v_actor, v_user.id, case when p_active then 'aktifkan' else 'nonaktifkan' end);
end;
$$;

-- ---------------------------------------------------------------------
-- Reset PIN (sekaligus buka kunci) & buka kunci
-- ---------------------------------------------------------------------
create or replace function public.admin_reset_pin(p_user_id uuid, p_pin text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := public.assert_owner_admin('manage_users');
begin
  perform public.assert_valid_pin(p_pin);
  update public.pos_users
  set pin_hash = extensions.crypt(p_pin, extensions.gen_salt('bf', 10)),
      failed_pin_attempts = 0,
      pin_locked_until = null,
      pin_lockout_level = 0,
      updated_at = now()
  where id = p_user_id;
  if not found then
    raise exception 'PENGGUNA_TIDAK_ADA: pengguna tidak ditemukan';
  end if;
  perform public.admin_log(v_actor, p_user_id, 'reset_pin');
end;
$$;

create or replace function public.admin_unlock_pin(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid := public.assert_owner_admin('manage_users');
begin
  update public.pos_users
  set failed_pin_attempts = 0,
      pin_locked_until = null,
      pin_lockout_level = 0,
      updated_at = now()
  where id = p_user_id;
  if not found then
    raise exception 'PENGGUNA_TIDAK_ADA: pengguna tidak ditemukan';
  end if;
  perform public.admin_log(v_actor, p_user_id, 'buka_kunci');
end;
$$;

-- ---------------------------------------------------------------------
-- Matriks izin
-- ---------------------------------------------------------------------
create or replace function public.admin_role_permissions()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform public.assert_owner_admin('manage_permissions');

  return jsonb_build_object(
    'roles', (
      select jsonb_agg(jsonb_build_object('code', code, 'name', name)
        order by case code when 'owner' then 1 when 'supervisor' then 2 else 3 end)
      from public.roles),
    'permissions', (
      select jsonb_agg(jsonb_build_object(
        'code', p.code,
        'label', p.label,
        'owner_only', p.code in ('manage_users', 'manage_permissions'),
        'granted', (
          select jsonb_object_agg(r.code, coalesce(rp.granted, false))
          from public.roles r
          left join public.role_permissions rp
            on rp.role_id = r.id and rp.permission_code = p.code)
      ) order by p.sort_order, p.code)
      from public.permissions p)
  );
end;
$$;

-- p_changes: [{"role": "supervisor", "permission": "void_transaction", "granted": true}, ...]
create or replace function public.admin_set_role_permissions(p_changes jsonb)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor   uuid := public.assert_owner_admin('manage_permissions');
  v_change  jsonb;
  v_role    public.roles;
  v_perm    public.permissions;
  v_granted boolean;
  v_old     boolean;
  v_count   integer := 0;
begin
  if p_changes is null or jsonb_typeof(p_changes) <> 'array' then
    raise exception 'PERUBAHAN_TIDAK_VALID: daftar perubahan tidak valid';
  end if;

  for v_change in select * from jsonb_array_elements(p_changes) loop
    select * into v_role from public.roles where code = v_change ->> 'role';
    select * into v_perm from public.permissions where code = v_change ->> 'permission';
    v_granted := (v_change ->> 'granted')::boolean;
    if v_role.id is null or v_perm.id is null or v_granted is null then
      raise exception 'PERUBAHAN_TIDAK_VALID: role atau izin tidak dikenal';
    end if;
    if v_role.code = 'owner' then
      raise exception 'TIDAK_BOLEH: izin role Owner terkunci (selalu aktif)';
    end if;
    if v_perm.code in ('manage_users', 'manage_permissions') and v_granted then
      raise exception 'TIDAK_BOLEH: izin "%" khusus Owner', v_perm.label;
    end if;

    select granted into v_old from public.role_permissions
    where role_id = v_role.id and permission_code = v_perm.code;
    if v_old is not distinct from v_granted then
      continue;
    end if;

    insert into public.role_permissions (role_id, permission_code, granted)
    values (v_role.id, v_perm.code, v_granted)
    on conflict (role_id, permission_code)
    do update set granted = excluded.granted, updated_at = now();

    perform public.admin_log(v_actor, null, 'ubah_izin', jsonb_build_object(
      'role', v_role.name, 'permission', v_perm.code, 'label', v_perm.label,
      'from', coalesce(v_old, false), 'to', v_granted));
    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

-- ---------------------------------------------------------------------
-- Riwayat perubahan
-- ---------------------------------------------------------------------
create or replace function public.admin_audit_log(p_limit integer default 100)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform public.assert_owner_admin('manage_users');

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', l.id,
      'created_at', l.created_at,
      'actor', a.name,
      'target', t.name,
      'action', l.action,
      'details', l.details
    ) order by l.created_at desc)
    from (
      select * from public.user_admin_log
      order by created_at desc
      limit least(greatest(coalesce(p_limit, 100), 1), 500)
    ) l
    left join public.pos_users a on a.id = l.actor_id
    left join public.pos_users t on t.id = l.target_user_id
  ), '[]');
end;
$$;

-- ---------------------------------------------------------------------
-- Pilihan filter laporan: sertakan status aktif pengguna & kurir
-- (label "(nonaktif)" di aplikasi)
-- ---------------------------------------------------------------------
create or replace function public.report_filter_options()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform public.assert_any_permission(
    array['view_sales_report', 'view_transaction_detail', 'view_finance_report']);

  return jsonb_build_object(
    'platforms', coalesce((
      select jsonb_agg(jsonb_build_object('id', id, 'name', name) order by sort_order, name)
      from public.marketplace_platforms), '[]'),
    'payment_methods', coalesce((
      select jsonb_agg(jsonb_build_object('id', id, 'name', name) order by sort_order, name)
      from public.payment_methods), '[]'),
    'bank_accounts', coalesce((
      select jsonb_agg(jsonb_build_object('id', id, 'name', bank_name) order by sort_order, bank_name)
      from public.bank_accounts), '[]'),
    'users', coalesce((
      select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'active', active)
        order by active desc, name)
      from public.pos_users), '[]'),
    'couriers', coalesce((
      select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'active', active)
        order by active desc, name)
      from public.couriers), '[]'),
    'categories', coalesce((
      select jsonb_agg(jsonb_build_object('slug', x.slug, 'name', x.name) order by x.sort, x.name)
      from (
        select s.slug, coalesce(c.label, initcap(s.slug)) as name, coalesce(c.sort_order, 9999) as sort
        from (select distinct category_snapshot as slug from public.transaction_items
              union select slug from public.menu_categories_cache) s
        left join public.menu_categories_cache c on c.slug = s.slug
      ) x), '[]'),
    'products', coalesce((
      select jsonb_agg(jsonb_build_object('id', product_id, 'name', name) order by name)
      from (
        select product_id, (array_agg(product_name_snapshot order by created_at desc))[1] as name
        from public.transaction_items group by product_id
      ) p), '[]')
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Hak eksekusi
-- ---------------------------------------------------------------------
revoke all on function public.normalize_user_name(text) from public, anon, authenticated;
revoke all on function public.assert_owner_admin(text) from public, anon, authenticated;
revoke all on function public.admin_log(uuid, uuid, text, jsonb) from public, anon, authenticated;
revoke all on function public.clean_user_name(text) from public, anon, authenticated;
revoke all on function public.assert_name_available(text, uuid) from public, anon, authenticated;
revoke all on function public.other_active_owner_count(uuid) from public, anon, authenticated;

revoke all on function public.admin_list_users() from public, anon;
revoke all on function public.admin_create_user(text, text, text) from public, anon;
revoke all on function public.admin_update_user(uuid, text, text) from public, anon;
revoke all on function public.admin_set_user_active(uuid, boolean) from public, anon;
revoke all on function public.admin_reset_pin(uuid, text) from public, anon;
revoke all on function public.admin_unlock_pin(uuid) from public, anon;
revoke all on function public.admin_role_permissions() from public, anon;
revoke all on function public.admin_set_role_permissions(jsonb) from public, anon;
revoke all on function public.admin_audit_log(integer) from public, anon;

grant execute on function public.admin_list_users() to authenticated;
grant execute on function public.admin_create_user(text, text, text) to authenticated;
grant execute on function public.admin_update_user(uuid, text, text) to authenticated;
grant execute on function public.admin_set_user_active(uuid, boolean) to authenticated;
grant execute on function public.admin_reset_pin(uuid, text) to authenticated;
grant execute on function public.admin_unlock_pin(uuid) to authenticated;
grant execute on function public.admin_role_permissions() to authenticated;
grant execute on function public.admin_set_role_permissions(jsonb) to authenticated;
grant execute on function public.admin_audit_log(integer) to authenticated;
