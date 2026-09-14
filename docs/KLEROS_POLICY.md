# PluriSwap Escrow — Arbitration Policy

Version 1.0. This is the `policyURI` document referenced by PluriSwap's Kleros dispute template. Pin it to IPFS and pass the multiaddr as `KLEROS_POLICY_URI` when deploying `KlerosAdapter`. Jurors in the Kleros Court read this before voting.

## 1. What is being decided

A PluriSwap escrow holds an ERC-20 amount (the **escrowed amount**) deposited by the **Holder**. The **Provider** was to complete an **off-chain payment** to the Holder (a bank transfer, a cash hand-off, a fiat payment of any kind) in exchange for that amount. The Provider signalled the payment as sent; the Holder disputed it and the case was escalated to Kleros.

The only question is: **who should receive the escrowed amount?**

- **Holder** (option 1): the payment was not completed as agreed. The escrowed amount returns to the Holder.
- **Provider** (option 2): the payment was completed as agreed. The escrowed amount is released to the Provider.
- **Refuse to Arbitrate** (option 0): the case cannot be decided on the evidence, or the request is invalid. The escrow splits 50/50; no party is penalised.

There is no partial award. Jurors do not set amounts, fees, or damages; the smart contract applies the outcome.

## 2. Parties and identifiers

The dispute template shows the Holder and Provider wallet addresses (also as aliases on evidence they submit), the token, the human-readable escrowed amount and the `dealId`. Evidence submitted from those two addresses comes from the parties themselves. Anyone else submitting evidence is a third party; weigh it accordingly.

## 3. Standard of decision

Decide on the **balance of probabilities**: which account is more likely true given the evidence in the case.

The Provider carries the burden of showing that the payment reached the Holder as agreed: correct recipient, correct amount, in the agreed currency and channel, within the deal's payment window. Typical supporting evidence: a payment receipt or bank statement excerpt showing recipient, amount, date and reference; screenshots of the payment channel; the parties' prior communication agreeing the payment details.

The Holder should show that the payment was not received, was short, was reversed, or went to the wrong recipient: account statements for the relevant period, chargeback or reversal notices, communication showing the agreed details differ from what was sent.

## 4. Guidance

- **Amount and recipient matter; formatting does not.** A payment that matches recipient and amount but differs in a free-text reference is still a completed payment.
- **Late is not the same as absent.** If the payment arrived after the deal's payment window but before the dispute was raised, and the Holder kept it, favour the Provider. If the Holder returned or rejected the late payment, favour the Holder.
- **Reversals.** A payment that was later reversed, charged back or clawed back is not completed. Favour the Holder unless the reversal was caused by the Holder.
- **Partial payments.** An incomplete payment is not completed. Favour the Holder. The parties could have settled a partial payment with a co-signed split before escalating; once in court there is no partial award.
- **Wrong recipient.** A payment sent to details other than those the Holder provided is not completed, unless the Holder supplied those details.
- **Silence.** A party that submits no evidence has not met its burden. If neither party submits usable evidence, refuse to arbitrate.
- **Off-platform promises.** Side agreements that change the escrow terms (different amount, different currency) are only relevant if both parties evidently agreed to them.

## 5. When to refuse to arbitrate

Use option 0 when:

- the evidence is insufficient or contradictory and neither account is more probable;
- the evidence is unreadable, unverifiable, or clearly fabricated on both sides;
- the case does not concern a PluriSwap escrow payment (wrong template, wrong case).

Refusing is not a tie-break in favour of either party: the contract splits the escrow evenly and releases any collateral both parties posted. Use it only when a decision is genuinely not possible.

## 6. What happens after the ruling

The ruling is delivered to the PluriSwap contract by Kleros once appeals are exhausted. The contract then releases the escrowed amount according to the option chosen, applies any protocol completion fee (only if the Provider receives funds), settles collateral (the losing party's bond, if any, goes to the winning party; on a refusal both bonds are returned) and records the outcome in the parties' on-chain reputation. None of this requires further action by jurors.

## 7. Evidence handling

Submit evidence through the Kleros Court interface for this case. Redact personal data that is not needed to establish recipient, amount, date and channel (for example, unrelated transactions on a bank statement). Evidence is public and permanent once submitted.
