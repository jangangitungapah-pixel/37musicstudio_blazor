# 37 Music Studio Blazor - Shell Overhaul Audit

Tanggal audit: 15/6/2026, 17.30.26

## Tujuan

Dokumen ini mengunci rencana overhaul shell app sebelum perubahan UI dilakukan. Fase ini hanya audit dan dokumentasi, belum mengubah behavior, route, auth, storage, atau logic halaman.

## NuGet yang Sudah Terpasang

| Area | Package | Status Pemakaian |
|---|---|---|
| Host | Microsoft.FluentUI.AspNetCore.Components | Dipakai sebagai bahasa visual utama shell |
| Host | Radzen.Blazor | Dipakai seperlunya untuk utility/admin pattern |
| Client | Microsoft.FluentUI.AspNetCore.Components | Dipakai sebagai arah komponen dan token UI |
| Client | Radzen.Blazor | Dipakai seperlunya, bukan visual utama shell |

Keputusan: tidak install NuGet baru untuk fase shell. Maksimalkan FluentUI dan Radzen yang sudah ada.

## File Shell yang Diaudit

| File | Peran |
|---|---|
| `37musicstudio_blazor.Client/Pages/StudioAdminLayout.razor` | Struktur shell, sidebar, nav, main content, mobile topbar, bottom nav |
| `37musicstudio_blazor/wwwroot/css/studio-admin-shell.css` | Global shell styling, font, layout, sidebar, schedule base, mobile nav |
| `37musicstudio_blazor.Client/Components/StudioIcon.razor` | Icon dictionary untuk sidebar dan bottom nav |

## Struktur Shell Saat Ini

- Root shell: `.studio-admin-shell`
- Desktop sidebar: `.studio-admin-sidebar`
- Brand block: `.studio-shell-brand`
- Navigation: `.studio-shell-nav`
- Navigation item: `.studio-shell-nav-item`
- Main content: `.studio-admin-main`
- Mobile topbar: `.studio-mobile-topbar`
- Mobile bottom nav: `.studio-bottom-nav`

## Navigasi Saat Ini

| Label | Short Label | Route | Icon |
|---|---|---|---|
| Dashboard | Home | `/dashboard` | `layout-dashboard` |
| Schedule | Schedule | `/schedule` | `calendar-days` |
| Customer | Customer | `/customers` | `users` |
| Inventory | Inventory | `/inventory` | `settings` |
| Gallery | Gallery | `/gallery` | `image` |
| Billing / POS | POS | `/billing` | `wallet-cards` |
| Pembukuan | Buku | `/bookkeeping` | `book-open` |
| Settings | Settings | `/settings` | `settings` |

## Masalah UI Shell Saat Ini

1. Navigasi masih flat, belum ada grouping seperti Overview, Operasional, Keuangan, dan System.
2. Active state sudah ada, tapi belum cukup premium untuk admin portal modern.
3. Sidebar belum punya hierarchy visual yang kuat.
4. Mobile bottom nav perlu dipastikan hanya memuat item paling penting.
5. Token shell belum dikunci sebagai pondasi untuk overhaul halaman lain.
6. CSS shell bercampur dengan schedule styling lama, jadi patch berikutnya harus pakai marker block agar aman.

## Prinsip Overhaul Shell

- Tidak mengubah route.
- Tidak mengubah auth.
- Tidak mengubah storage.
- Tidak mengubah logic halaman.
- Tidak menghapus halaman.
- Tidak install dependency baru.
- Pakai CSS marker block untuk patch modern shell.
- Build harus hijau tiap fase.

## Target Visual Shell Baru

Konsep: 37 Studio Command Shell

Karakter:
- Dark elegant
- Soft glass
- Sidebar grouped
- Active state lebih tegas
- Topbar mobile compact
- Bottom nav aman untuk thumb reach
- Spacing lebih dewasa
- Focus state jelas
- Typography tetap konsisten dengan Montserrat yang sudah ada

## Token CSS yang Akan Dikunci

```css
:root {
    --studio-shell-sidebar-width: 18rem;
    --studio-shell-mobile-nav-height: 4.35rem;
    --studio-shell-radius-xl: 1.45rem;
    --studio-shell-radius-lg: 1.12rem;
    --studio-shell-radius-md: 0.85rem;

    --studio-shell-bg: #070b13;
    --studio-shell-surface: rgba(15, 23, 42, 0.76);
    --studio-shell-surface-strong: rgba(15, 23, 42, 0.92);
    --studio-shell-border: rgba(148, 163, 184, 0.16);

    --studio-shell-text: #f8fafc;
    --studio-shell-muted: rgba(226, 232, 240, 0.62);
    --studio-shell-subtle: rgba(226, 232, 240, 0.42);

    --studio-shell-accent: #d8a85f;
    --studio-shell-accent-2: #8d7cff;
    --studio-shell-success: #22c55e;
    --studio-shell-danger: #ef4444;
}
```

## Rencana Grouping Sidebar

### Overview
- Dashboard

### Operasional
- Schedule
- Customer
- Inventory
- Gallery

### Keuangan
- Billing / POS
- Pembukuan

### System
- Settings

## Bottom Nav Mobile Target

Maksimal 5 item utama:

- Home
- Schedule
- Customer
- POS
- Buku

Settings tetap ada di sidebar desktop. Untuk mobile, Settings bisa tetap lewat topbar/menu lanjutan di fase berikutnya kalau diperlukan.

## Phase Berikutnya

### Phase 16B
Implementasi grouped sidebar + modern shell token.

File yang akan disentuh:
- `StudioAdminLayout.razor`
- `studio-admin-shell.css`

Perubahan yang diizinkan:
- Struktur nav grouping
- Class shell tambahan
- CSS marker block modern shell
- Active state
- Sidebar footer polish
- Mobile bottom nav polish

Perubahan yang tidak diizinkan:
- Business logic
- Storage
- Auth
- Cloudinary
- Schedule behavior
- Billing behavior
- Pembukuan behavior
