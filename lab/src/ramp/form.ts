export type RampForm = {
  ramp: string;
  token: string;
  amount: string;
  minAmountOut: string;
  dest: string;
  to: string;
  refund: string;
};

export const emptyRampForm = (): RampForm => ({
  ramp: "",
  token: "",
  amount: "1000000",
  minAmountOut: "0",
  dest: "40161",
  to: "",
  refund: "",
});
