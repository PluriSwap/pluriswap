export const R = {
  WrongStatus: "Escrow.WrongStatus",
  Unauthorized: "Escrow.Unauthorized",
  EdgeOff: "Escrow.EdgeOff",
  PackageNotSelected: "Escrow.PackageNotSelected",
  PackageDrift: "Escrow.PackageDrift",
  NotRuled: "Escrow.NotRuled",
  DealExists: "Escrow.DealExists",
  DealIdMismatch: "Escrow.DealIdMismatch",
  DeadlineMismatch: "Escrow.DeadlineMismatch",
  DeadlinePassed: "Escrow.DeadlinePassed",
  BpsMismatch: "Escrow.BpsMismatch",
  IncompatiblePackages: "Escrow.IncompatiblePackages",
  UnknownPackage: "Escrow.UnknownPackage",
  PackageRequired: "Escrow.PackageRequired",
  PeerMismatch: "Escrow.PeerMismatch",
  TooEarly: "Clocks.TooEarly",
  TooLate: "Clocks.TooLate",
  Overflow: "Clocks overflow",
  HolderEqualsProvider: "Terms.HolderEqualsProvider",
  ZeroPrincipal: "Terms.ZeroPrincipal",
  UnsortedPackageIds: "Terms.UnsortedPackageIds",
  TermsMismatch: "Escrow.TermsMismatch",
  ControllerAcceptanceRequired: "Escrow.ControllerAcceptanceRequired",
  InvalidControllerSignature: "Escrow.InvalidControllerSignature",
  DraftEmpty: "draft-empty",
  NoOp: "no-op",
  NoSender: "no-sender",
  AlreadyUsed: "already used",
} as const;

export type ReasonKind = "kernel" | "ui-policy";
export type VerbClass = "rol" | "anyone" | "dual-sign";

export type Eval = {
  enabled: boolean;
  reasonKind: ReasonKind;
  reason: string;
};

export function disabled(reason: string, reasonKind: ReasonKind = "kernel"): Eval {
  return { enabled: false, reasonKind, reason };
}

export function enabled(reason = ""): Eval {
  return { enabled: true, reasonKind: "kernel", reason };
}
