# Verifikasi API Roblox

Sumber: Creator Hub (nama & bentuk API) + `src/server/Dev/Inspect.luau` (Play di Studio).
Cara ulang: set `Features.DevInspect = true`, klik **Play**, filter Output dengan `INSPECT`.
Terakhir diverifikasi: **16 Sep 2026** (Studio, akun uji userId 9503778706).

Satu-satunya pemanggil API ini di kode: `src/server/Gateways/RobloxApi.luau`.

## Ringkasan

| API | Dipakai lewat | Status | Catatan |
|---|---|---|---|
| `AvatarEditorService:GetAvatarRulesAsync()` | `getAvatarRules` | ✅ | cache 6 jam |
| `AvatarEditorService:SearchCatalogAsync(CatalogSearchParams)` | `searchCatalog` | ✅ | `Limit` 120 → 118 item (sebagian tersaring) |
| `CatalogPages:AdvanceToNextPageAsync()` | `nextPage` | ✅ | halaman 2 → 119 item |
| `AvatarEditorService:GetItemDetailsAsync(id, AvatarItemType)` | `getItemDetails` | ✅ | cache 1 jam |
| `AvatarEditorService:GetBatchItemDetailsAsync(ids, AvatarItemType)` | `getBatchItemDetails` | ✅ | **maks 100 id** per panggilan |
| `AvatarEditorService:GetOutfitDetailsAsync(outfitId)` | `getOutfitDetails` | ✅ | `Id` di respons berupa **string** |
| `AssetService:GetBundleDetailsAsync(bundleId)` | `getBundleDetails` | ✅ | `Items[]` sudah membawa `AssetType` |
| `Players:GetHumanoidDescriptionFromOutfitIdAsync(outfitId)` | `getDescriptionFromOutfitId` | ✅ | versi tanpa `Async` deprecated |
| `Players:GetHumanoidDescriptionFromUserIdAsync(userId)` | `getDescriptionFromUserId` | ✅ | versi tanpa `Async` deprecated |
| `Humanoid:ApplyDescriptionAsync(desc)` | `applyDescription` | ✅ | versi tanpa `Async` deprecated |

Docs Creator Hub tidak menyebut batas frekuensi (rate limit). Retry: 3 percobaan
dengan backoff; error permanen (`404`, `400`, `Invalid`, `not found`, `does not exist`,
`not allowed`, `maximum of`) tidak diulang.

## Batas & aturan (dari `GetAvatarRulesAsync`)

Kunci atas: `AccessoryRefinementLowerBounds`, `AccessoryRefinementTypes`,
`AccessoryRefinementUpperBounds`, `BasicBodyColorsPalette`, `BodyColorsPalette`,
`BundlesEnabledForUser`, `DefaultClothingAssetLists`, `EmotesEnabledForUser`,
`MinimumDeltaEBodyColorDifference`, `PlayerAvatarTypes`,
`ProportionsAndBodyTypeEnabledForUser`, `Scales`, `WearableAssetTypes`.
Tidak ada kunci `AccessoryRefinementLimits`.

### WearableAssetTypes (`{ Id, Name, MaxNumber }`, batas PER TIPE)

| MaxNumber | Tipe (Id) |
|---|---|
| 3 | Hat (8) |
| 6 | Face Makeup (88), Lip Makeup (89), Eye Makeup (90) |
| 0 | Emote Animation (61) |
| 1 | T-Shirt (2), Shirt (11), Pants (12), Gear (19), Torso (27), Right Arm (28), Left Arm (29), Left Leg (30), Right Leg (31), Hair/Face/Neck/Shoulder/Front/Back/Waist Accessory (41–47), Climb (48), Fall (50), Idle (51), Jump (52), Run (53), Swim (54), Walk (55) Animation, T-Shirt/Shirt/Pants/Jacket/Sweater/Shorts Accessory (64–69), Left/Right Shoe (70, 71), Dress Skirt (72), Eyebrow (76), Eyelash (77), Mood Animation (78), Dynamic Head (79) |

Tidak ada batas **total** aksesori → `Limits.MaxRigidAccessories` /
`MaxLayeredAccessories` tetap fallback (10).

### Scales (`{ Min, Max, Increment }`, increment 0.01)

| Skala | Min | Max |
|---|---|---|
| Height | 0.9 | 1.05 |
| Width | 0.7 | 1 |
| Head | 0.95 | 1 |
| BodyType | 0 | 1 |
| Proportion | 0 | 1 |

`Depth` tidak ada di rules.

### Accessory refinement

`AccessoryRefinementTypes = { 8, 42, 43, 44, 45, 46 }` (Hat, Face, Neck, Shoulder,
Front, Back). Batas bawah/atas per tipe:

- Position X/Y/Z: −0.25 … 0.25
- Rotation X: −30 … 30 (Front/Back: −15 … 15); Y/Z: −30 … 30
- Scale X/Y/Z: 0.8 … 1.2

## Bentuk respons

### Item katalog (`SearchCatalogAsync` / `GetItemDetailsAsync`)

`AssetType` (string, mis. `"Hat"`), `BundledItems`, `CollectibleItemId`,
`CreatorHasVerifiedBadge`, `CreatorName`, `CreatorTargetId`, `CreatorType`,
`Description`, `FavoriteCount`, `HasResellers`, `Id`, `ItemRestrictions`,
`ItemStatus`, `ItemType` (`"Asset"` / `"Bundle"`), `LowestPrice`,
`LowestResalePrice`, `Name`, `Price`, `ProductId`, `SaleLocationType`,
`TotalQuantity`, `UnitsAvailableForConsumption`.
`GetItemDetailsAsync` menambah: `ExpectedSellerId`, `IsPurchasable`, `Owned`.

### Batch

- 100 id → ✅ 100 hasil
- 101 / 120 / 150 / 200 id → ❌ `A maximum of 100 item details can be requested at once`
- Maka `Limits.ItemBatchSize = 100`.

### Bundle (`GetBundleDetailsAsync`)

Contoh: bundle `104915988289001` "Tallest male can shoes 3.0" (`BodyParts`).
Kunci: `BundleType`, `Description`, `Id`, `Items`, `Name`,
`PriceDiscountDetails`, `UserBasePriceInRobux`.

`Items[]` = `{ Id, Name, Type, AssetType? , SupportsHeadShapes? }`:

- 7 × `Type = "Asset"` (RightArm, Torso, LeftLeg, LeftArm, MoodAnimation, RightLeg, DynamicHead)
- 2 × `Type = "UserOutfit"` (tanpa `AssetType`)

### Outfit (`GetOutfitDetailsAsync`)

Bundle tubuh punya **dua** UserOutfit:

| # | Id | OutfitType | InventoryType | Isi |
|---|---|---|---|---|
| 1 | 6016977565474900 | `Avatar` | `Body` | 7 aset (tubuh lengkap) |
| 2 | 5533792516890598 | `DynamicHead` | `DynamicHead` | kepala + mood |

Kunci: `Assets[] { AssetType = { Id, Name }, CurrentVersionId, Id, Name }`,
`BodyColors` (Color3: `HeadColor`, `TorsoColor`, `LeftArmColor`, `RightArmColor`,
`LeftLegColor`, `RightLegColor`), `Id` (**string**), `InventoryType`, `IsEditable`,
`Name`, `OutfitType`, `PlayerAvatarType` (`"R15"`),
`Scale { BodyType, Depth, Head, Height, Proportion, Width }`.

## Dampak ke kode

- `BundleNormalizer` mengambil UserOutfit **pertama** → untuk bundle di atas itu
  outfit `Avatar` (benar). BundleService sebaiknya tetap memilih `OutfitType == "Avatar"`.
- Nama skala outfit (`Height`, `Width`, …) ≠ `AssetTypeMap.ScaleSlots`
  (`HeightScale`, `WidthScale`, …) → BundleService butuh adapter sebelum `enrich`.
- `Items[].AssetType` bisa dipakai sebagai tipe cadangan (tipe resmi tetap dari
  `getBatchItemDetails`).

  ## Temuan feature/tryon-layered (Studio, 16 Sep 2026)

### `HumanoidDescription:SetAccessories(list, true)`

| Entri | Hasil |
|---|---|
| rigid, `IsLayered = false`, **tanpa** `Order` | ⚠️ `Input table missing Order!` |
| rigid, `IsLayered = false`, `Order = 0` | ⚠️ `IsLayered is required to be true for entries where order is specified (or don't set IsLayered, and default value will be used)!` |
| rigid, **tanpa** `IsLayered`, `Order = 0` | ✅ tanpa warning |
| layered, `IsLayered = true`, `Order`, `Puffiness` | ✅ |

→ `DescriptionBuilder.toDescription`: rigid = `{ AssetId, AccessoryType, Order = 0 }`,
layered = `{ AssetId, AccessoryType, IsLayered = true, Order, Puffiness }`.

### Batas aksesori

- `GetAvatarRulesAsync().WearableAssetTypes[].Name` memakai spasi (`"Hair Accessory"`)
  → pakai `Id` lalu `AssetTypeMap.normalize(Id)`.
- Batas **per tipe** (Hat = 3, aksesori lain = 1, makeup = 6), tidak ada batas total.
- `ApplyDescriptionAsync` **tidak** menolak lebih dari batas (7 aksesori dipasang tanpa error)
  → server harus menegakkan batas sendiri: `AvatarRules` + `OutfitState.wear(..., maxPerType)`
  mengganti aksesori **tertua** dari tipe yang penuh.

### Remote

- `RemoteEvent:FireClient` sebelum client punya listener **ditahan** dan dikirim saat
  `OnClientEvent` pertama terhubung (StateChanged awal tetap diterima).
