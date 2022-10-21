// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.15;

import "./GridexUtil.sol";

// import "hardhat/console.sol";

contract SharesUtil is GridexUtil {
    function calcInitPool(
        address pairAddress,
        IGridexInterface.Params memory params,
        uint256 grid,
        uint256 totalStock,
        uint256 soldRatio
    ) internal pure returns (uint256 leftStock, uint256 gotMoney) {
        require(soldRatio <= RatioBase, "invalid-ratio");
        IGridexInterface.Pool memory pool;
        pool.totalStock = uint96(totalStock);
        pool.soldRatio = uint64(soldRatio);
        uint256 priceLo = IGridexPair(pairAddress).grid2price(grid) *
            params.priceMul;
        uint256 priceHi = IGridexPair(pairAddress).grid2price(grid + 1) *
            params.priceMul;
        (leftStock, , gotMoney) = IGridexPair(pairAddress).calcPool(
            params.priceDiv,
            priceLo,
            priceHi,
            pool.totalStock,
            pool.soldRatio
        );
    }

    function calcChangeShares(
        address pairAddr,
        IGridexInterface.Params memory params,
        uint256 grid,
        IGridexInterface.Pool memory pool,
        int160 sharesDelta
    ) public pure returns (int256 leftStockDelta, int256 gotMoneyDelta) {
        uint256 soldRatio = uint64(uint160(sharesDelta)); // encode soldRatio in the low bits
        sharesDelta >>= 64; //remove the soldRatio
        if (sharesDelta == 0) {
            return (0, 0);
        }

        if (pool.totalShares == 0) {
            require(sharesDelta > 0, "pool-not-init");
            (uint256 leftStock, uint256 gotMoney) = calcInitPool(
                pairAddr,
                params,
                grid,
                uint256(int256(sharesDelta)),
                soldRatio
            );
            return (int256(leftStock), int256(gotMoney));
        }
        uint96 totalStockOld = pool.totalStock;
        if (sharesDelta > 0) {
            pool.totalStock += uint96(
                (uint256(pool.totalStock) * uint256(int256(sharesDelta))) /
                    uint256(pool.totalShares)
            );
        } else {
            pool.totalStock -= uint96(
                (uint256(pool.totalStock) * uint256(int256(-sharesDelta))) /
                    uint256(pool.totalShares)
            );
        }
        (leftStockDelta, gotMoneyDelta) = calcPoolDelta(
            pairAddr,
            params.priceDiv,
            IGridexPair(pairAddr).grid2price(grid) * params.priceMul,
            IGridexPair(pairAddr).grid2price(grid + 1) * params.priceMul,
            totalStockOld,
            pool.soldRatio,
            pool.totalStock,
            pool.soldRatio
        );
    }

    function calcPoolDelta(
        address pairAddr,
        uint256 priceDiv,
        uint256 priceLo,
        uint256 priceHi,
        uint96 totalStockOld,
        uint64 soldRatioOld,
        uint96 totalStockNew,
        uint64 soldRatioNew
    ) private pure returns (int256 leftStockDelta, int256 gotMoneyDelta) {
        (uint256 leftStockOld, , uint256 gotMoneyOld) = IGridexPair(pairAddr)
            .calcPool(priceDiv, priceLo, priceHi, totalStockOld, soldRatioOld);
        (uint256 leftStockNew, , uint256 gotMoneyNew) = IGridexPair(pairAddr)
            .calcPool(priceDiv, priceLo, priceHi, totalStockNew, soldRatioNew);
        leftStockDelta = int256(leftStockNew) - int256(leftStockOld);
        gotMoneyDelta = int256(gotMoneyNew) - int256(gotMoneyOld);
    }

    function getSharesResult(
        address pairAddr,
        IGridexInterface.Params memory params,
        uint256[3] memory prices, //  minPrice, currPrice maxPrice
        uint256 totalAmount // maxGrid < midGrid： moneyAmount ；其他为stockAmount
    )
        public
        view
        returns (
            int256 deltaMoney,
            uint256 minGrid,
            int160[] memory sharesDeltas
        )
    {
        minGrid = IGridexPair(pairAddr).price2Grid(prices[0]);
        uint256 midGrid = IGridexPair(pairAddr).price2Grid(prices[1]);
        uint256 midGridSoldRatio;
        {
            uint256 priceLo = IGridexPair(pairAddr).grid2price(midGrid);
            uint256 priceHi = IGridexPair(pairAddr).grid2price(midGrid + 1);
            midGridSoldRatio =
                ((prices[1] - priceLo) * RatioBase) /
                (priceHi - priceLo);
        }
        uint256 maxGrid = IGridexPair(pairAddr).price2Grid(
            (prices[2] * (10**5 - 1)) / (10**5)
        );

        sharesDeltas = getSharesDeltas(
            pairAddr,
            params,
            minGrid,
            midGrid,
            midGridSoldRatio,
            maxGrid,
            totalAmount
        );

        for (uint256 i = 0; i < sharesDeltas.length; i++) {
            uint256 grid = minGrid + i;
            IGridexInterface.Pool memory pool = IGridexPair(pairAddr).pools(
                grid
            );
            if (grid == midGrid) {
                pool.soldRatio = uint64(midGridSoldRatio);
            } else if (grid < midGrid) {
                pool.soldRatio = uint64(RatioBase);
            } else if (grid > midGrid) {
                pool.soldRatio = 0;
            }
            (, int256 m) = calcChangeShares(
                pairAddr,
                params,
                minGrid + i,
                pool,
                sharesDeltas[i]
            );

            deltaMoney += m;
        }
    }

    function getSharesDeltas(
        address pairAddr,
        IGridexInterface.Params memory params,
        uint256 minGrid,
        uint256 midGrid,
        uint256 midGridSoldRatio,
        uint256 maxGrid,
        uint256 totalAmount
    ) internal view returns (int160[] memory sharesDeltas) {
        uint256 length = maxGrid - minGrid + 1;
        sharesDeltas = new int160[](length);
        if (minGrid > midGrid) {
            //只有stock
            for (uint256 i = 0; i < length; i++) {
                uint256 grid = minGrid + i;
                IGridexInterface.Pool memory pool = IGridexPair(pairAddr).pools(
                    grid
                );
                uint256 amount = totalAmount >> (i + 1);
                if (i == length - 1) {
                    amount += totalAmount >> length;
                }
                uint256 shareDelta = pool.totalStock != 0
                    ? ((uint256(pool.totalShares) * uint256(int256(amount))) /
                        uint256(pool.totalStock))
                    : amount;
                sharesDeltas[i] = int160(int256(shareDelta << 64));
            }
        } else if (maxGrid < midGrid) {
            for (uint256 i = 0; i < length; i++) {
                uint256 grid = minGrid + i;
                uint256 amount = totalAmount >> (length - i);
                if (i == length - 1) {
                    amount += totalAmount >> length;
                }
                uint256 priceHi = IGridexPair(pairAddr).grid2price(grid + 1) *
                    params.priceMul;
                uint256 priceLo = IGridexPair(pairAddr).grid2price(grid) *
                    params.priceMul;
                IGridexInterface.Pool memory pool = IGridexPair(pairAddr).pools(
                    grid
                );
                uint256 stock = (amount * (2 * PriceBase * params.priceDiv)) /
                    (priceHi + priceLo);
                uint256 shareDelta;
                if (pool.totalStock == 0) {
                    shareDelta = stock;
                } else {
                    shareDelta =
                        (uint256(pool.totalShares) * uint256(int256(stock))) /
                        uint256(pool.totalStock);
                }
                sharesDeltas[i] =
                    int160(int256(shareDelta << 64)) +
                    int160(int256(RatioBase));
            }
        } else if (midGrid >= minGrid && midGrid <= maxGrid) {
            uint256[] memory amounts = new uint256[](length);
            {
                // function start() {
                //     const rb = 100;
                //     sr = 20;
                //     const minGrid = 15;
                //     const midGrid = 20;
                //     const maxGrid = 35;
                //     const stockAmount = 10000;
                //     const rightLength = maxGrid - midGrid + 1;
                //     const rightRates = new Array(rightLength).fill(0).map((_, i) => 2 ** (rightLength - 1 - i) * (i == 0 ? (rb - sr) / rb : 1))
                //     const rightRatesSum = rightRates.reduce((x, y) => x + y)
                //     const x = stockAmount / rightRatesSum
                //     const rightAmounts = rightRates.map(r => r * x)
                //     console.log(rightAmounts, rightAmounts.reduce((x, y) => x + y))
                // }start()
                uint256 onlyMoneyLength = midGrid - minGrid;
                uint256 validStockLength = maxGrid - midGrid + 1;
                uint256 stockRatesSum;
                for (uint256 i = 0; i < validStockLength; i++) {
                    amounts[onlyMoneyLength + i] =
                        (2**(validStockLength - 1 - i) *
                            100000 * // 防止(RatioBase - midGridSoldRatio)远小于RatioBase
                            (
                                i == 0
                                    ? (RatioBase - midGridSoldRatio)
                                    : RatioBase
                            )) /
                        RatioBase;
                    stockRatesSum += amounts[onlyMoneyLength + i];
                }
                for (uint256 i = 0; i < validStockLength; i++) {
                    amounts[onlyMoneyLength + i] =
                        (totalAmount * amounts[onlyMoneyLength + i]) /
                        stockRatesSum; // stockAmount
                }
                uint256 midGridToatlStockAmount = (amounts[onlyMoneyLength] *
                    RatioBase) / (RatioBase - midGridSoldRatio);
                for (uint256 i = 0; i < onlyMoneyLength; i++) {
                    amounts[i] =
                        midGridToatlStockAmount >>
                        (onlyMoneyLength - i); // 约等于stockAmount等比
                }
            }
            for (uint256 i = 0; i < length; i++) {
                uint256 grid = minGrid + i;
                IGridexInterface.Pool memory pool = IGridexPair(pairAddr).pools(
                    grid
                );
                uint256 amount = amounts[i];
                uint256 shareDelta;
                if (pool.totalStock == 0) {
                    if (grid == midGrid) {
                        shareDelta =
                            (amount * RatioBase) /
                            (RatioBase - midGridSoldRatio);
                    } else {
                        shareDelta = uint256(int256(amount));
                    }
                } else {
                    shareDelta = ((uint256(pool.totalShares) *
                        uint256(int256(amount))) / uint256(pool.totalStock));
                }
                sharesDeltas[i] = int160(int256(shareDelta << 64));
                if (grid == midGrid) {
                    sharesDeltas[i] += int160(uint160(midGridSoldRatio));
                } else if (grid < midGrid) {
                    sharesDeltas[i] += int160(int256(RatioBase));
                }
            }
        }
        return sharesDeltas;
    }
}
