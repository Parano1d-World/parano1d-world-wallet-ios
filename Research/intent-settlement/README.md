# Independent NOID quote fee reference

**Arithmetic reference only.** The functions here do not run in NOID consensus and cannot charge a real user, hold funds, guarantee a fill or prove a cross-chain payment. Do not connect them to the wallet's live submission path. Run `node --test fee-reference.test.mjs` to check the integer rounding examples.

the developer's ecosystem app does not depend on the NOID team changing the chain. The existing SafeTrade NOID/USDT market is an external purchase route. Existing native NOID/token markets use the current protocol's fee and locked reserves. A separate market-maker quote service may someday offer actual source-chain USDC/USDT for actual NOID from maker inventory, but that is a different settlement and trust model.

The proposed 100-basis-point operator convenience fee belongs only to an opt-in independent quote. It can be withheld from the gross NOID the maker delivers if the maker and the buyer agree to the exact net output. The service must disclose source gas, maker spread, operator fee, destination network fee, expiry, finality, refund conditions and counterparty risk before approval. The existing native pool does not enforce this fee or allocate its 30-basis-point fee to the app.

Before taking funds, build a signed quote format, replay protection, maker inventory checks, settlement monitoring, explicit failure and refund states, small-value tests and independent security and legal review. If one leg can finalize while another fails, describe the route as counterparty assisted rather than atomic or trustless. Do not solicit passive liquidity deposits against the existing permanently locked NOID pool.

See [the independent acquisition and trading plan](../../Docs/NATIVE-DEX-PLAN.md).
