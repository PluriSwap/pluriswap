export type LabForm = {
  wallet: string;
  subject: string;
  nullifier: string;
  dealId: string;
  ruling: string;
  mintTo: string;
  mintAmount: string;
  approveSpender: string;
  approveAmount: string;
  vault: string;
  depositAmount: string;
  warp: string;
};

export const emptyLabForm = (): LabForm => ({
  wallet: "",
  subject: "",
  nullifier: "",
  dealId: "",
  ruling: "1",
  mintTo: "",
  mintAmount: "1000000",
  approveSpender: "",
  approveAmount: "1000000",
  vault: "",
  depositAmount: "100000",
  warp: "100",
});
