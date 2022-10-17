// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.15;

import "./GridexUtil.sol";

// import "hardhat/console.sol";

contract SharesUtil is GridexUtil {
    function calcInitPool(
        address pairAddress,
        uint256 grid,
        uint256 totalStock,
        uint256 soldRatio
    ) internal view returns (uint256 leftStock, uint256 gotMoney) {
        require(soldRatio <= RatioBase, "invalid-ratio");
        IGridexInterface.Pool memory pool;
        pool.totalStock = uint96(totalStock);
        pool.soldRatio = uint64(soldRatio);
        IGridexInterface.Params memory p = IGridexPair(pairAddress)
            .loadParams();
        uint256 priceLo = IGridexPair(pairAddress).grid2price(grid) *
            p.priceMul;
        uint256 priceHi = IGridexPair(pairAddress).grid2price(grid + 1) *
            p.priceMul;
        (leftStock, , gotMoney) = IGridexPair(pairAddress).calcPool(
            p.priceDiv,
            priceLo,
            priceHi,
            pool.totalStock,
            pool.soldRatio
        );
    }

    function calcChangeShares(
        address pairAddr,
        uint256 grid,
        IGridexInterface.Pool memory pool,
        int160 sharesDelta
    ) public view returns (int256 leftStockDelta, int256 gotMoneyDelta) {
        uint256 soldRatio = uint64(uint160(sharesDelta)); // encode soldRatio in the low bits
        sharesDelta >>= 64; //remove the soldRatio
        if (sharesDelta == 0) {
            return (0, 0);
        }

        if (pool.totalShares == 0) {
            require(sharesDelta > 0, "pool-not-init");
            (uint256 leftStock, uint256 gotMoney) = calcInitPool(
                pairAddr,
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
        IGridexInterface.Params memory p = IGridexPair(pairAddr).loadParams();
        (leftStockDelta, gotMoneyDelta) = calcPoolDelta(
            pairAddr,
            p.priceDiv,
            IGridexPair(pairAddr).grid2price(grid) * p.priceMul,
            IGridexPair(pairAddr).grid2price(grid + 1) * p.priceMul,
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
                minGrid + i,
                pool,
                sharesDeltas[i]
            );

            deltaMoney += m;
        }
    }

    function getSharesDeltas(
        address pairAddr,
        uint256 minGrid,
        uint256 midGrid,
        uint256 midGridSoldRatio,
        uint256 maxGrid,
        uint256 totalAmount
    ) internal view returns (int160[] memory sharesDeltas) {
        if (minGrid > midGrid) {
            //只有stock
            uint256 length = maxGrid - minGrid + 1;
            sharesDeltas = new int160[](length);
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
            uint256 length = maxGrid - minGrid + 1;
            sharesDeltas = new int160[](length);
            for (uint256 i = 0; i < length; i++) {
                uint256 grid = minGrid + i;
                uint256 amount = totalAmount >> (length - i);
                if (i == length - 1) {
                    amount += totalAmount >> length;
                }
                IGridexInterface.Params memory p = IGridexPair(pairAddr)
                    .loadParams();
                uint256 priceHi = IGridexPair(pairAddr).grid2price(grid + 1) *
                    p.priceMul;
                uint256 priceLo = IGridexPair(pairAddr).grid2price(grid) *
                    p.priceMul;
                IGridexInterface.Pool memory pool = IGridexPair(pairAddr).pools(
                    grid
                );
                uint256 stock = (amount * (2 * PriceBase * p.priceDiv)) /
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
            uint256 length = maxGrid - minGrid + 1;
            sharesDeltas = new int160[](length);
            for (uint256 i = 0; i < length; i++) {
                uint256 grid = minGrid + i;

                IGridexInterface.Pool memory pool = IGridexPair(pairAddr).pools(
                    grid
                );
                uint256 amount = totalAmount >>
                    (
                        (grid < midGrid)
                            ? (midGrid - grid + 1)
                            : (grid - midGrid + 1)
                    );
                if (grid == midGrid) {
                    amount += totalAmount >> ((maxGrid - midGrid + 1));
                }
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
