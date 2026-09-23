-- =====================================================================
-- Kurir karyawan: semua role KECUALI Owner (Supervisor & Kasir).
-- Dijaga di daftar pilihan dan di validasi server.
-- =====================================================================

create or replace function public.list_courier_staff()
returns table (id uuid, name text)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if public.current_pos_user_id() is null then
    raise exception 'TIDAK_LOGIN: sesi tidak valid';
  end if;
  return query
    select u.id, u.name
    from public.pos_users u
    join public.roles r on r.id = u.role_id
    where u.active and r.code <> 'owner'
    order by u.name;
end;
$$;

create or replace function public.resolve_courier(p_courier jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_type text := p_courier ->> 'type';
  v_id   uuid;
begin
  if v_type = 'karyawan' then
    select u.id into v_id
    from public.pos_users u
    join public.roles r on r.id = u.role_id
    where u.id = nullif(p_courier ->> 'user_id', '')::uuid and u.active and r.code <> 'owner';
    if v_id is null then
      raise exception 'KURIR_TIDAK_VALID: pilih karyawan pengantar';
    end if;
    return jsonb_build_object('type', v_type, 'user_id', v_id, 'courier_id', null);
  elsif v_type = 'freelance' then
    select id into v_id from public.couriers
    where id = nullif(p_courier ->> 'courier_id', '')::uuid and active;
    if v_id is null then
      raise exception 'KURIR_TIDAK_VALID: pilih kurir freelance';
    end if;
    return jsonb_build_object('type', v_type, 'user_id', null, 'courier_id', v_id);
  elsif v_type in ('shopee_express', 'maxim') then
    return jsonb_build_object('type', v_type, 'user_id', null, 'courier_id', null);
  end if;

  raise exception 'KURIR_TIDAK_VALID: pilih jenis kurir';
end;
$$;

revoke execute on function public.resolve_courier(jsonb) from public, anon, authenticated;
revoke execute on function public.list_courier_staff() from public, anon;
grant execute on function public.list_courier_staff() to authenticated;
