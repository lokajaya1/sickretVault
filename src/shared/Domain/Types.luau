--!strict
-- Model data outfit. Plain table (bisa di-JSON, di-clone, dikirim lewat remote).

export type Accessory = {
	assetId: number,
	assetType: string, -- nama Enum.AvatarAssetType
	isLayered: boolean,
	order: number?, -- hanya layered
	puffiness: number?, -- hanya layered (0..1)
	source: number?, -- bundleId jika berasal dari bundle
	seq: number?, -- urutan dipakai (untuk mengganti yang tertua saat batas per tipe penuh)
}

export type SlotValue = {
	id: number, -- 0 = default/kosong
	source: number?, -- bundleId asal
}

export type OutfitState = {
	rig: string, -- "R15" | "R6"
	bodyParts: { [string]: SlotValue }, -- Head, Torso, LeftArm, RightArm, LeftLeg, RightLeg
	animations: { [string]: SlotValue }, -- Idle/Walk/Run/Jump/Fall/Climb/Swim/Mood
	classic: { [string]: SlotValue }, -- Shirt, Pants, GraphicTShirt, Face
	accessories: { [string]: Accessory }, -- key = tostring(assetId)
	colors: { [string]: string }, -- HeadColor.. -> hex
	scales: { [string]: number }, -- HeightScale..
}

export type BundlePart = {
	assetId: number,
	name: string,
	assetType: string,
	kind: string, -- "bodyPart" | "animation" | "classic" | "accessory" | "unknown"
	slot: string?,
}

export type BundleInfo = {
	bundleId: number,
	name: string,
	bundleType: string?,
	outfitId: number?,
	parts: { BundlePart },
	-- nilai bawaan outfit bundle (skala) bila enrichment berhasil; opsional
	outfitScales: { [string]: number }?,
	-- item yang bentuknya tidak dikenali (untuk log/inspeksi, tidak dipakai)
	unknownItems: { { id: any, type: any } },
}

-- Data enrichment opsional dari UserOutfit bundle (hasil adapter, bukan API mentah)
export type OutfitEnrichment = {
	scales: { [string]: number }?,
	moodAnimation: number?,
}

export type Intent =
	{ op: "wear", assetId: number }
	| { op: "remove", assetId: number }
	| { op: "wearBundle", bundleId: number, partIds: { number }?, useBundleScales: boolean? }
	| { op: "removeBundle", bundleId: number }
	| { op: "setLayerOrder", assetId: number, order: number }
	| { op: "removeKind", kind: string } -- Item Removal per kategori (OutfitState.KINDS)
	| { op: "undo" }
	| { op: "redo" }
	| { op: "reset" }

-- Roblox mewajibkan ModuleScript mengembalikan tepat satu nilai (bukan nil).
return {}
