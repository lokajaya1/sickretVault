## Apa yang berubah
<!-- 1–3 kalimat. Tautkan issue: Closes #123 -->

## Area
- [ ] Domain (murni)  - [ ] Gateway API  - [ ] Services  - [ ] Client/UI  - [ ] Config  - [ ] Tooling/Docs

## Cara uji
- [ ] `lune run tools/run-tests.luau` lulus
- [ ] Dicoba di Studio (Play Solo)
- [ ] Dicoba di Team Test / server live (wajib jika menyentuh API Roblox)
- [ ] Mobile emulator dicek (jika menyentuh UI)

## Checklist arsitektur
- [ ] `Domain/` tetap tanpa `GetService` / Instance / yield
- [ ] Panggilan API Roblox baru hanya lewat `server/Gateways/RobloxApi`
- [ ] Input client divalidasi di server (`IntentValidator`) + rate limit
- [ ] Nama remote baru ditambah di `RemoteNames`
- [ ] Docs diperbarui (`ARCHITECTURE` / `API_VERIFICATION` / `ROADMAP`) bila perlu