import type { HexBytes32 } from "../addressbook/types.ts";
import type { PackageMods } from "./types.ts";

/** Recompute vivo por slot vs packageIds firmados. liveId null = policy no leída. */
export type DriftRow = { slot: keyof PackageMods; liveId: HexBytes32 | null; inSigned: boolean };
