import { recoverTypedDataAddress } from "viem";
import type { HexAddress } from "../addressbook/types.ts";
import { Status, type DealTerms, type PackageMods } from "../deal/types.ts";
import { R, disabled, enabled, type Eval } from "../eligibility/errors.ts";
import { firstTermsRevert } from "../eligibility/terms.ts";
import { firstEngageRevert, firstResolveRevert } from "../slots/resolve.ts";
import { ZERO_MODS, type LivePolicy } from "../slots/types.ts";
import { eip712Domain, eip712Types, hashTerms, type Envelope } from "./eip712.ts";

export type CorePreflightInput = {
  terms: DealTerms;
  ha: Envelope;
  pa: Envelope;
  ca: Envelope | null;
  holderSig: `0x${string}` | null;
  providerSig: `0x${string}` | null;
  controllerSig: `0x${string}` | null;
  chainId: number;
  escrow: HexAddress;
  now: bigint;
  usedHolder: boolean;
  usedProvider: boolean;
  usedController: boolean;
  allowance: bigint | null;
  dealStatus: number | null;
  coreActivate: boolean;
  distinctController: boolean;
  packages: boolean;
  mods: PackageMods;
  policy: LivePolicy | null;
};

export type PreflightStep = { step: string; eval: Eval };

export async function preflightActivateCore(input: CorePreflightInput): Promise<PreflightStep[]> {
  const steps: PreflightStep[] = [];
  const push = (step: string, ev: Eval) => {
    steps.push({ step, eval: ev });
  };
  const p2p = input.terms.holder.toLowerCase() === input.terms.controller.toLowerCase();

  if (!input.coreActivate) {
    push("flag coreActivate", disabled("coreActivate off", "ui-policy"));
    return steps;
  }
  if (input.terms.packageIds.length !== 0 && !input.packages) {
    push("Core-only", disabled("packages off", "ui-policy"));
    return steps;
  }
  if (!p2p && !input.distinctController) {
    push("P2P", disabled("distinctController off", "ui-policy"));
    return steps;
  }

  push("Terms.hashTerms(HA)", firstTermsRevert(input.ha.terms));
  if (!steps[steps.length - 1]!.eval.enabled) return steps;
  push("Terms.hashTerms(PA)", firstTermsRevert(input.pa.terms));
  if (!steps[steps.length - 1]!.eval.enabled) return steps;

  const mismatch = hashTerms(input.ha.terms) !== hashTerms(input.pa.terms);
  push("TermsMismatch", mismatch ? disabled(R.TermsMismatch) : enabled());
  if (mismatch) return steps;

  if (input.now > input.ha.deadline || input.now > input.pa.deadline) {
    push("DeadlinePassed", disabled(R.DeadlinePassed));
    return steps;
  }
  push("DeadlinePassed", enabled());

  if (input.holderSig) {
    const recovered = await recoverTypedDataAddress({
      domain: eip712Domain(input.chainId, input.escrow),
      types: eip712Types,
      primaryType: "HolderAuthorization",
      message: envelopeMessage(input.ha),
      signature: input.holderSig,
    });
    push(
      "InvalidHolderSignature",
      recovered.toLowerCase() === input.terms.holder.toLowerCase()
        ? enabled()
        : disabled("Escrow.InvalidHolderSignature"),
    );
    if (!steps[steps.length - 1]!.eval.enabled) return steps;
  } else {
    push("InvalidHolderSignature", disabled("sin HolderAuthorization", "ui-policy"));
    return steps;
  }

  if (input.providerSig) {
    const recovered = await recoverTypedDataAddress({
      domain: eip712Domain(input.chainId, input.escrow),
      types: eip712Types,
      primaryType: "ProviderAgreement",
      message: envelopeMessage(input.pa),
      signature: input.providerSig,
    });
    push(
      "InvalidProviderSignature",
      recovered.toLowerCase() === input.terms.provider.toLowerCase()
        ? enabled()
        : disabled("Escrow.InvalidProviderSignature"),
    );
    if (!steps[steps.length - 1]!.eval.enabled) return steps;
  } else {
    push("InvalidProviderSignature", disabled("sin ProviderAgreement", "ui-policy"));
    return steps;
  }

  if (p2p) {
    push("CA (P2P dummy, ignored)", enabled());
  } else {
    if (!input.ca) {
      push("ControllerAcceptanceRequired", disabled(R.ControllerAcceptanceRequired));
      return steps;
    }
    if (input.ca.terms.controller.toLowerCase() !== input.terms.controller.toLowerCase()) {
      push("ControllerAcceptanceRequired", disabled(R.ControllerAcceptanceRequired));
      return steps;
    }
    push("ControllerAcceptanceRequired", enabled());
    if (hashTerms(input.ca.terms) !== hashTerms(input.ha.terms)) {
      push("TermsMismatch (CA)", disabled(R.TermsMismatch));
      return steps;
    }
    push("TermsMismatch (CA)", enabled());
    if (input.now > input.ca.deadline) {
      push("DeadlinePassed (CA)", disabled(R.DeadlinePassed));
      return steps;
    }
    push("DeadlinePassed (CA)", enabled());
    if (input.controllerSig) {
      const recovered = await recoverTypedDataAddress({
        domain: eip712Domain(input.chainId, input.escrow),
        types: eip712Types,
        primaryType: "ControllerAcceptance",
        message: envelopeMessage(input.ca),
        signature: input.controllerSig,
      });
      push(
        "InvalidControllerSignature",
        recovered.toLowerCase() === input.terms.controller.toLowerCase()
          ? enabled()
          : disabled("Escrow.InvalidControllerSignature"),
      );
      if (!steps[steps.length - 1]!.eval.enabled) return steps;
    } else {
      push("InvalidControllerSignature", disabled("sin ControllerAcceptance", "ui-policy"));
      return steps;
    }
    if (input.usedController) {
      push("NonceUsed (controller)", disabled("Escrow.NonceUsed"));
      return steps;
    }
    push("NonceUsed (controller)", enabled());
  }

  if (input.usedHolder || input.usedProvider) {
    push("NonceUsed", disabled("Escrow.NonceUsed"));
    return steps;
  }
  push("NonceUsed", enabled());

  const mods = input.mods ?? ZERO_MODS;
  if (!input.packages || input.terms.packageIds.length === 0) {
    push("_resolve Core-only []", enabled());
  } else if (!input.policy) {
    push("_resolve", disabled("policy de slots desconocida", "ui-policy"));
    return steps;
  } else {
    const resolved = firstResolveRevert(input.terms.packageIds, mods, input.policy);
    push("_resolve", resolved);
    if (!resolved.enabled) return steps;
  }

  if (input.dealStatus !== null && input.dealStatus !== Status.NONE) {
    push("DealExists", disabled("Escrow.DealExists"));
    return steps;
  }
  push("DealExists", enabled());

  if (!input.packages || input.terms.packageIds.length === 0) {
    push("_engage (Core: skip)", enabled());
  } else if (!input.policy) {
    push("_engage", disabled("policy de slots desconocida", "ui-policy"));
    return steps;
  } else {
    const engaged = firstEngageRevert(mods, input.policy);
    push("_engage", engaged);
    if (!engaged.enabled) return steps;
  }

  if (input.allowance === null) {
    push("pullExact", disabled("allowance desconocido", "ui-policy"));
    return steps;
  }
  if (input.allowance < input.terms.principal) {
    push("pullExact", disabled("Settlement.InexactPull"));
    return steps;
  }
  push("pullExact allowance >= principal", enabled());
  return steps;
}

function envelopeMessage(env: Envelope) {
  return {
    terms: {
      holder: env.terms.holder,
      controller: env.terms.controller,
      provider: env.terms.provider,
      token: env.terms.token,
      principal: env.terms.principal,
      fiatDuration: env.terms.fiatDuration,
      releaseDuration: env.terms.releaseDuration,
      disputeDuration: env.terms.disputeDuration,
      arbitrationDuration: env.terms.arbitrationDuration,
      packageIds: env.terms.packageIds,
    },
    nonce: env.nonce,
    deadline: env.deadline,
  };
}
