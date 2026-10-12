-- =====================================================================
-- Saklar jeda sinkron pelanggan
--
-- Akses baca pelanggan website (role pos_reader) sengaja dinonaktifkan di
-- sisi website; pengaktifannya dibahas bersama kontrak data jembatan
-- pesanan. Selama dijeda:
--   - cron tidak memanggil Edge Function sync-customers (lihat
--     20261012000002_customer_sync_pause_schedule.sql), jadi tidak ada
--     baris "failed" baru di menu_sync_runs;
--   - sync-customers menolak dengan status paused tanpa menyentuh website;
--   - tombol Sinkron hanya menyinkron menu.
-- Log lama di menu_sync_runs tidak dihapus.
-- =====================================================================

create table public.sync_settings (
  id                     boolean primary key default true check (id),  -- satu baris
  customers_paused       boolean not null default true,
  customers_paused_at    timestamptz,
  customers_paused_by    uuid references public.pos_users (id),
  customers_pause_note   text,
  updated_at             timestamptz not null default now()
);

insert into public.sync_settings (customers_paused, customers_paused_at, customers_pause_note)
values (
  true, now(),
  'Akses baca pelanggan website (pos_reader) dinonaktifkan di sisi website; '
  || 'diaktifkan kembali bersama kontrak data jembatan pesanan.'
);

alter table public.sync_settings enable row level security;
grant select, insert, update, delete on public.sync_settings to service_role;
grant select on public.sync_settings to authenticated;
create policy pos_users_read on public.sync_settings for select to authenticated
  using ((select public.current_pos_user_id()) is not null);

-- ---------------------------------------------------------------------
-- Status sinkron untuk indikator bilah atas & tab Pengaturan → Sinkron
-- ---------------------------------------------------------------------
create or replace function public.get_sync_status()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_settings public.sync_settings;
begin
  if public.current_pos_user_id() is null then
    raise exception 'TIDAK_LOGIN: sesi tidak valid';
  end if;

  select * into v_settings from public.sync_settings;

  return jsonb_build_object(
    'customers_paused', coalesce(v_settings.customers_paused, false),
    'customers_paused_at', v_settings.customers_paused_at,
    'customers_paused_by', (select name from public.pos_users where id = v_settings.customers_paused_by),
    'customers_pause_note', v_settings.customers_pause_note,
    -- Run terakhir per jenis (sukses atau gagal)
    'last_runs', coalesce((
      select jsonb_agg(jsonb_build_object(
        'kind', r.kind, 'status', r.status, 'error', r.error, 'created_at', r.created_at))
      from (
        select distinct on (kind) kind, status, error, created_at
        from public.menu_sync_runs
        order by kind, created_at desc
      ) r
    ), '[]'),
    -- Kapan data terakhir benar-benar tersinkron
    'last_success', jsonb_build_object(
      'menu', (select max(created_at) from public.menu_sync_runs
               where kind = 'menu' and status = 'success'),
      'customers', (select max(created_at) from public.menu_sync_runs
                    where kind = 'customers' and status = 'success')
    )
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Jeda / aktifkan kembali (manage_settings)
-- ---------------------------------------------------------------------
create or replace function public.set_customer_sync_paused(p_paused boolean, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.assert_permission('manage_settings');

  if p_paused is null then
    raise exception 'NILAI_TIDAK_VALID: pilih jeda atau aktif';
  end if;

  update public.sync_settings
  set customers_paused = p_paused,
      customers_paused_at = case when p_paused then now() end,
      customers_paused_by = case when p_paused then public.current_pos_user_id() end,
      customers_pause_note = case when p_paused then nullif(trim(p_note), '') end,
      updated_at = now();

  return public.get_sync_status();
end;
$$;

revoke all on function public.get_sync_status() from public, anon;
revoke all on function public.set_customer_sync_paused(boolean, text) from public, anon;
grant execute on function public.get_sync_status() to authenticated;
grant execute on function public.set_customer_sync_paused(boolean, text) to authenticated;
