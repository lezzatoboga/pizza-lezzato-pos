-- =====================================================================
-- Jembatan pesanan: kirim ulang setelah saklar go-live menyala lagi
-- (keputusan Owner 14 Okt 2026, docs/SOP-SAKLAR-GO-LIVE.md)
--
-- Selama go_live_at website kosong, status dari POS ditolak 'sebelum_go_live'
-- (gagal, tidak dicoba ulang). Begitu jembatan menyala lagi (v_pesanan terisi),
-- web-orders-sync memanggil web_resend_after_golive():
--   * per pesanan yang punya status gagal 'sebelum_go_live': kirim HANYA status
--     terakhir POS (status pesanan, atau 'dibatalkan' bila dibatalkan kasir);
--   * hanya bila maju menurut aturan website (status akhir website tak bisa
--     diubah; selain 'dibatalkan' harus lebih maju dari status website);
--   * status yang sama dengan website → tidak dikirim; website sudah lebih maju
--     → tidak dikirim (kasir melanjutkan seperti biasa);
--   * keduanya status akhir tapi berbeda (mis. website selesai, POS dibatalkan)
--     → tidak dikirim, langsung masuk daftar Owner ('konflik_status');
--   * kiriman ulang yang DITOLAK website tidak dicoba lagi (gagal permanen) dan
--     masuk daftar Owner untuk diselesaikan manual (Pengaturan → Sinkron).
-- Baris gagal 'sebelum_go_live' yang sudah ditangani ditandai superseded_at.
-- =====================================================================

alter table public.web_status_outbox
  add column resend        boolean not null default false,  -- kiriman ulang setelah go-live
  add column superseded_at timestamptz,                    -- gagal sebelum_go_live yang sudah ditangani
  add column resolved_at   timestamptz,                    -- diselesaikan manual oleh Owner
  add column resolved_by   uuid references public.pos_users (id);

comment on column public.web_status_outbox.resend is
  'true = kiriman ulang status terakhir setelah saklar go-live menyala lagi (tidak dicoba berulang bila ditolak).';

-- Urutan status website (aturan "hanya maju" pos_set_order_status).
create or replace function public.web_status_rank(p_status text)
returns integer
language sql
immutable
set search_path = ''
as $$
  select case p_status
    when 'baru' then 0 when 'diterima' then 1 when 'diproses' then 2
    when 'siap_diambil' then 3 when 'sedang_diantar' then 3 when 'selesai' then 4
  end;
$$;

create or replace function public.web_resend_after_golive()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  r          record;
  v_pos      text;
  v_web      text;
  v_queued   integer := 0;
  v_manual   integer := 0;
  v_skipped  integer := 0;
begin
  for r in
    select w.id, w.web_status, t.status as tx_status, t.void_source, t.order_status
    from public.web_orders w
    join public.transactions t on t.id = w.transaction_id
    where exists (select 1 from public.web_status_outbox o
                  where o.web_order_id = w.id and o.failed_at is not null
                    and o.last_error = 'sebelum_go_live' and o.superseded_at is null)
    order by w.first_seen_at
    for update of w
  loop
    update public.web_status_outbox
    set superseded_at = now()
    where web_order_id = r.id and failed_at is not null
      and last_error = 'sebelum_go_live' and superseded_at is null;

    -- Status yang masih antre (aksi kasir sesudah saklar menyala) lebih baru: biarkan.
    if exists (select 1 from public.web_status_outbox o
               where o.web_order_id = r.id and o.sent_at is null and o.failed_at is null) then
      v_skipped := v_skipped + 1;
      continue;
    end if;

    if r.tx_status = 'voided' then
      if r.void_source = 'website' then   -- dibatalkan dari website: sudah sama
        v_skipped := v_skipped + 1;
        continue;
      end if;
      v_pos := 'dibatalkan';
    else
      v_pos := r.order_status;
    end if;
    v_web := r.web_status;

    -- Sudah sama.
    if v_pos = v_web or (v_pos = 'dibatalkan' and v_web = 'batal') then
      v_skipped := v_skipped + 1;
      continue;
    end if;

    if v_web in ('selesai', 'batal') then
      if v_pos in ('selesai', 'dibatalkan') then
        -- Keduanya status akhir tapi berbeda: tidak bisa dikirim → Owner.
        insert into public.web_status_outbox (web_order_id, status, resend, failed_at, last_error)
        values (r.id, v_pos, true, now(), 'konflik_status');
        v_manual := v_manual + 1;
      else
        v_skipped := v_skipped + 1;      -- website sudah selesai/batal; POS menyusul seperti biasa
      end if;
      continue;
    end if;

    if v_pos <> 'dibatalkan'
       and coalesce(public.web_status_rank(v_pos), 0) <= coalesce(public.web_status_rank(v_web), 0) then
      v_skipped := v_skipped + 1;        -- website sudah sama/lebih maju
      continue;
    end if;

    insert into public.web_status_outbox (web_order_id, status, resend)
    values (r.id, v_pos, true);
    v_queued := v_queued + 1;
  end loop;

  return jsonb_build_object('queued', v_queued, 'manual', v_manual, 'skipped', v_skipped);
end;
$$;

-- Owner menandai baris daftar "perlu diselesaikan manual" sudah ditangani.
create or replace function public.web_resend_resolve(p_outbox_id bigint)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := public.assert_owner_admin('manage_settings');
begin
  update public.web_status_outbox
  set resolved_at = now(), resolved_by = v_user
  where id = p_outbox_id and resend and failed_at is not null and resolved_at is null;
  if not found then
    raise exception 'TIDAK_DITEMUKAN: baris sudah ditangani atau bukan kiriman ulang yang gagal';
  end if;
end;
$$;

revoke all on function public.web_status_rank(text) from public, anon, authenticated;
revoke all on function public.web_resend_after_golive() from public, anon, authenticated;
revoke all on function public.web_resend_resolve(bigint) from public, anon;
grant execute on function public.web_resend_after_golive() to service_role;
grant execute on function public.web_resend_resolve(bigint) to authenticated;
