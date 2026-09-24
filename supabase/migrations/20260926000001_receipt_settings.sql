-- =====================================================================
-- Template struk per outlet (diatur dari Pengaturan → Template struk)
--
-- Logo disimpan SUDAH dikonversi (hitam-putih, 1 bit/titik, format raster
-- ESC/POS GS v 0) sebagai base64 — konversi dilakukan sekali di aplikasi
-- saat upload, jadi cetak tidak perlu mengolah gambar lagi.
-- =====================================================================

create table public.receipt_settings (
  outlet_id    uuid primary key references public.outlets (id),
  store_name   text not null default '',
  address      text not null default '',
  whatsapp     text not null default '',
  website      text not null default '',
  footer       text not null default '',
  logo_width   integer,        -- titik, kelipatan 8, maks. 384
  logo_height  integer,        -- titik, maks. 240
  logo_data    text,           -- base64 raster 1 bit/titik
  updated_at   timestamptz not null default now(),
  constraint receipt_settings_logo_complete check (
    (logo_width is null and logo_height is null and logo_data is null)
    or (logo_width between 8 and 384 and logo_width % 8 = 0
        and logo_height between 1 and 240
        and length(decode(logo_data, 'base64')) = logo_width / 8 * logo_height)
  )
);

create trigger receipt_settings_updated_at before update on public.receipt_settings
  for each row execute function public.set_updated_at();

alter table public.receipt_settings enable row level security;
grant select, insert, update, delete on public.receipt_settings to service_role;
grant select on public.receipt_settings to authenticated;
create policy pos_users_read on public.receipt_settings for select to authenticated
  using ((select public.current_pos_user_id()) is not null);

insert into public.receipt_settings (outlet_id, store_name, address, whatsapp, website, footer)
select id, 'Pizza Lezzato', 'Jl. Lobak 103 A, Pekanbaru', '081378099099', 'pizzalezzato.com',
       'Pilihan Ibu Bijak, Kesukaan Anak Hebat!'
from public.outlets
where code = 'PL';

-- ---------------------------------------------------------------------
-- Simpan teks template
-- ---------------------------------------------------------------------
create or replace function public.save_receipt_text(
  p_outlet_id uuid,
  p_store_name text,
  p_address text,
  p_whatsapp text,
  p_website text,
  p_footer text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.assert_permission('manage_settings');
  if nullif(trim(p_store_name), '') is null then
    raise exception 'NAMA_WAJIB: isi nama toko';
  end if;

  insert into public.receipt_settings (outlet_id, store_name, address, whatsapp, website, footer)
  values (p_outlet_id, trim(p_store_name), coalesce(trim(p_address), ''), coalesce(trim(p_whatsapp), ''),
          coalesce(trim(p_website), ''), coalesce(trim(p_footer), ''))
  on conflict (outlet_id) do update set
    store_name = excluded.store_name,
    address = excluded.address,
    whatsapp = excluded.whatsapp,
    website = excluded.website,
    footer = excluded.footer;
end;
$$;

-- Simpan / hapus logo (p_data null = hapus).
create or replace function public.save_receipt_logo(
  p_outlet_id uuid,
  p_width integer,
  p_height integer,
  p_data text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.assert_permission('manage_settings');

  insert into public.receipt_settings (outlet_id) values (p_outlet_id)
  on conflict (outlet_id) do nothing;

  begin
    update public.receipt_settings
    set logo_width = case when p_data is null then null else p_width end,
        logo_height = case when p_data is null then null else p_height end,
        logo_data = p_data
    where outlet_id = p_outlet_id;
  exception when check_violation or invalid_parameter_value then
    raise exception 'LOGO_TIDAK_VALID: data logo tidak valid, coba upload ulang';
  end;
end;
$$;

revoke execute on function public.save_receipt_text(uuid, text, text, text, text, text) from public, anon;
revoke execute on function public.save_receipt_logo(uuid, integer, integer, text) from public, anon;
grant execute on function public.save_receipt_text(uuid, text, text, text, text, text) to authenticated;
grant execute on function public.save_receipt_logo(uuid, integer, integer, text) to authenticated;
