### Gridex: yet another solution for concentrated market making

We propose yet another solution for concentrated market making: Gridex. It is an alternative to UniswapV3 and is free to be used by every DEX on smartBCH.

You can check out its source code here: https://github.com/smartbch/gridex/blob/main/contracts/Gridex.sol . It is not fully tested or audited. We hope the community can help us review and test it. Its source code is very short and the idea is very straightforward.

#### Overview

Automatic market making must follow some curve. Bancor, Uniswap, and curve.fi all have different curves. From Infinitesimal Calculus, we know that every curve can be approximated by many straight lines. If we look at a small enough part of a curve, it is like a straight line. And straight price line is a special case of Bancor market maker.

The general idea of Gridex is to use many small Bancor pools and let each pool take charge of a small price range. If the pools are dense enough, we can approximate any curve. The market-making effect which can be achieved by UniswapV3 or Curve.fi, can also be approached by Gridex. Interacting with several pools may use more gas. However, this is not a big problem on smartBCH now.

Currently, the source code implements three different price grids: 4.42%, 1.08% (for non-stable coins) and 0.27% (for stablecoins). Usually, Gridex is used in parallel with UniswapV2: Gridex for concentrated market making and UniswapV2 for the whole-price-range market making. Because of arbitragers, Gridex's price and UniswapV2's price are almost the same. We can anticipate that in practice only a few pools around the UniswapV2 price have liquidity.

Each small pool has its own fungible liquidity token, implemented in ERC1155. This is different from the NFT scheme used by UniswapV3. Fungible tokens are more flexible. For example, some rewards can be distributed to a small pool's liquid providers as long as UniswapV2's price falls into its price range.

#### User experience

Gridex uses several 256-bit bit-masks to denote which pools have liquidity, with one bit corresponding to one pool. You can also query the pools in a price range, to know their liquidity amount and your liquidity token amounts in them (if any).

When you deal with the pools or provide liquidity to them, you only need to consider the ones whose prices are near the price of UniswapV2. Also, a DEX DApp's page only needs to show information about these pools.

All the pools in Gridex must be in a "normalized status": only one pool contains the stock token and the money token and its price is the current price of Gridex; the pools whose price range is higher than the current price must only have stock tokens; the pools whose price range is lower than the current price must only have money tokens. If they are not in such a normalized status, anyone can use `batchTrade` function to arbitrage risklessly.

A DApp can help users to add liquidity in the same way as UniswapV3. The user specifies the planned price range for market making and the amount of the money token (or the stock token). Only one token's amount is necessary because the amount of the other token can be automatically calculated given the current price. Again, to maintain the normalized status, if the current price fall in between a pool's price range, then you add stock and money to it; if the current price is lower(higher) than a pool's price range, then you add only stock (money) to it, respectively.

If the pools are not in a normalized status, you can use the `arbitrageAndBatchChangeShares` function, which will arbitrage to change the pools into the normalized status and then add liquidity to them.

Suppose the ratio between two adjacent pools is α, how should we distribute the tokens into pools in order to approximate the effect of UniswapV3? The answer is: as the price increases, the stock amount (if any) in each pool decreases in geometric progression, with the ratio equaling 1/sqrt(α); while the money amount (if any) in each pool increases in geometric progression, with the ratio equaling sqrt(α). Please refer to the appendix for equation deducing.

#### Appendix

Suppose the intial price of a UniswapV2 pair is P; its stock and money amounts are S and M; after dealing its stock amount is reduced by ΔS and its money amount is increased by ΔM, which causes the price rises to αP.

```
(S-ΔS)*(M+ΔM) = S*M    (1)
M = S*P               (2)
M+ΔM = (S-ΔS)*αP      (3)
Put(2) (3) into (1), we have:
(S-ΔS)*(S-ΔS)*α = S*S
(S-ΔS)/S = 1/sqrt(α)

So when UniswapV2 price rises to αP, the stock amount is reduced to 1/sqrt(α), similarly, the money amount is increased to sqrt(α), 
because of constant product. 
Now we know the relationship of the total amounts of stock and money. Next let us consider their changed amount, i.e., ΔS and ΔM

From (1) we know:
S*M - M*ΔS + S*ΔM - ΔS*ΔM = S*M
S*ΔM = M*ΔS + ΔS*ΔM
ΔM/M = ΔS/S + (ΔS*ΔM)/(M*S)

When ΔS and ΔM are small enough, we have
ΔM/M = ΔS/S

Now we know the ratio between changed amounts equals the ratio between total amounts. 
```

Following is an example which shows four small pools (Pool1~Pool4) containing stock and money. "max stock" means the stock amount when the pool has sold no stock out. "max money" means the total money that can be got when the pool has sold all the stock out.

Please note the stock and money amounts change in geometric progression.

```
---------------------------------------------------------------------------
            P            P*α          P*α*α          P*(α**3)       P*(α**4)
------------+-------------+--------------+--------------+---------------+--
            |  Pool1      |    Pool2     |    Pool3     |   Pool4       |
------------+-------------+--------------+--------------+---------------+--
 max stock  |  S*(α**1.5) |     S*α      |  S*(α**0.5)  |     S         |
------------+-------------+--------------+--------------+---------------+--
 max money  |    M*α      |  M*(α**1.5)  |   M*(α**2)   |  M*(α**2.5)   |
------------+-------------+--------------+--------------+---------------+--
```
