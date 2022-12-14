// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.15;

import "./Interface.sol";

// import "hardhat/console.sol";

contract GridexUtil {
    uint256 constant RatioBase = 10**19; // need 64 bits
    uint256 constant PriceBase = 2**68;
    uint256 constant FeeBase = 10000;
    uint256 constant GridCount = 64 * 256;
    uint256 constant LargeAmount = 1 << 95;

    function getBuyFromPoolsResult(
        uint256[] memory prices,
        IGridexInterface.Pool[] memory pools,
        uint256 stockToBuy,
        uint256 fee_m_d
    )
        public
        pure
        returns (
            uint256 totalPaidMoney,
            uint256 totalGotStock,
            uint64 lastSoldRatio
        )
    {
        if (pools.length == 0) {
            return (0, 0, 0);
        }
        uint256 grid = 0;
        (totalPaidMoney, totalGotStock) = (0, 0);
        uint256 priceHi = prices[grid] * uint64(fee_m_d >> 64); // (beginGrid + grid);
        for (; stockToBuy != 0 && grid < pools.length; grid++) {
            uint256 priceLo = priceHi;
            priceHi = prices[grid + 1] * uint64(fee_m_d >> 64); //(beginGrid + grid + 1);
            IGridexInterface.Pool memory pool = IGridexInterface.Pool({ // 需要是新的，原本的不能改
                totalShares: pools[grid].totalShares,
                totalStock: pools[grid].totalStock,
                soldRatio: pools[grid].soldRatio
            });
            if (pool.totalStock == 0 || pool.soldRatio == RatioBase) {
                // cannot deal
                continue;
            }
            uint256 price = (priceHi *
                pool.soldRatio +
                priceLo *
                (RatioBase - pool.soldRatio)) / RatioBase;
            uint256 soldStockOld = (uint256(pool.totalStock) *
                uint256(pool.soldRatio)) / RatioBase;
            uint256 leftStockOld = uint256(pool.totalStock) - soldStockOld;
            uint256 gotMoneyOld = (soldStockOld * (price + priceLo)) /
                (2 * PriceBase * uint64(fee_m_d));
            if (stockToBuy >= leftStockOld) {
                // buy all in pool
                uint256 gotMoneyNew = gotMoneyOld +
                    /*MoneyIncr:*/
                    (leftStockOld *
                        (price + priceHi) *
                        (FeeBase + (fee_m_d >> 128))) /
                    (2 * PriceBase * FeeBase * uint64(fee_m_d)); //fee in money
                uint256 totalStock = 1 + /*for rounding error*/
                    (gotMoneyNew * 2 * PriceBase * uint64(fee_m_d)) /
                    (priceHi + priceLo);
                gotMoneyNew =
                    (totalStock * (priceHi + priceLo)) /
                    (2 * PriceBase * uint64(fee_m_d));
                stockToBuy -= leftStockOld;
                totalGotStock += leftStockOld;
                pool.soldRatio = uint64(RatioBase);
                pool.totalStock = uint96(totalStock);
                totalPaidMoney += gotMoneyNew - gotMoneyOld;
            } else {
                // cannot buy all in pool
                uint256 stockFee = (stockToBuy * (fee_m_d >> 128)) / FeeBase; //fee in stock
                pool.totalStock += uint96(stockFee);
                uint256 soldStockNew = soldStockOld + stockToBuy;
                pool.soldRatio = uint64(
                    (RatioBase * soldStockNew) / pool.totalStock
                );
                price =
                    (priceHi *
                        pool.soldRatio +
                        priceLo *
                        (RatioBase - pool.soldRatio)) /
                    RatioBase;
                soldStockNew =
                    (uint256(pool.totalStock) * uint256(pool.soldRatio)) /
                    RatioBase;
                {
                    // to avoid "Stack too deep"
                    uint256 leftStockNew = pool.totalStock - soldStockNew;
                    //≈ totalStockOld+stockFee-soldStockOld-stockToBuy
                    uint256 gotMoneyNew = (soldStockNew * (price + priceLo)) /
                        (2 * PriceBase * uint64(fee_m_d));
                    totalGotStock += leftStockOld - leftStockNew; //≈ stockToBuy-stockFee
                    totalPaidMoney += gotMoneyNew - gotMoneyOld;
                } // to avoid "Stack too deep"
                stockToBuy = 0;
                lastSoldRatio = pool.soldRatio;
            }
        } //  不需要 pools[grid] = pool;
    }

    function getSellToPoolsResult(
        uint256[] memory prices,
        IGridexInterface.Pool[] memory pools, // 重复使用的
        uint256 stockToSell,
        uint256 fee_m_d
    )
        public
        pure
        returns (
            uint256 totalGotMoney,
            uint256 totalSoldStock,
            uint64 lastSoldRatio
        )
    {
        if (pools.length == 0) {
            return (0, 0, 0);
        }
        uint256 grid = pools.length - 1;
        (totalGotMoney, totalSoldStock) = (0, 0);
        uint256 priceLo = prices[grid + 1] * uint64(fee_m_d >> 64); // grid2price(beginGrid - (pools.length - grid - 1));
        for (; stockToSell != 0 && grid >= 0; grid--) {
            // >=
            uint256 priceHi = priceLo;
            priceLo = prices[grid] * uint64(fee_m_d >> 64); // (beginGrid - (pools.length - grid));
            IGridexInterface.Pool memory pool = IGridexInterface.Pool({ // 需要是新的，原本的不能改
                totalShares: pools[grid].totalShares,
                totalStock: pools[grid].totalStock,
                soldRatio: pools[grid].soldRatio
            });
            if (pool.totalStock == 0 || pool.soldRatio == 0) {
                if (grid == 0) {
                    // grid!==-1
                    break;
                }
                // cannot deal
                continue;
            }
            {
                // to avoid "Stack too deep"
                uint256 price = (priceHi *
                    pool.soldRatio +
                    priceLo *
                    (RatioBase - pool.soldRatio)) / RatioBase;
                uint256 soldStockOld = (uint256(pool.totalStock) *
                    uint256(pool.soldRatio)) / RatioBase;
                uint256 leftStockOld = pool.totalStock - soldStockOld;
                uint256 gotMoneyOld = (soldStockOld * (price + priceLo)) /
                    (2 * PriceBase * uint64(fee_m_d));
                uint256 stockFee = (soldStockOld * (fee_m_d >> 128)) / FeeBase;
                if (stockToSell >= soldStockOld + stockFee) {
                    // get all money all in pool
                    pool.soldRatio = 0;
                    pool.totalStock += uint96(stockFee); // fee in stock
                    stockToSell -= soldStockOld + stockFee;
                    totalSoldStock += soldStockOld + stockFee;
                    totalGotMoney += gotMoneyOld;
                } else {
                    // cannot get all money all in pool
                    stockFee = (stockToSell * (fee_m_d >> 128)) / FeeBase;
                    pool.totalStock += uint96(stockFee); // fee in stock
                    {
                        // to avoid "Stack too deep"
                        uint256 soldStockNew = soldStockOld +
                            stockFee -
                            stockToSell;
                        pool.soldRatio = uint64(
                            1 + (RatioBase * soldStockNew) / pool.totalStock
                        );
                        price =
                            (priceHi *
                                pool.soldRatio +
                                priceLo *
                                (RatioBase - pool.soldRatio)) /
                            RatioBase;
                        soldStockNew =
                            (uint256(pool.totalStock) *
                                uint256(pool.soldRatio)) /
                            RatioBase;
                        uint256 leftStockNew = pool.totalStock - soldStockNew;
                        // ≈ totalStockOld+stockFee-soldStockOld-stockFee+stockToSell
                        uint256 gotMoneyNew = (soldStockNew *
                            (price + priceLo)) /
                            (2 * PriceBase * uint64(fee_m_d));
                        totalSoldStock += leftStockNew - leftStockOld; //≈ stockToSell
                        totalGotMoney += gotMoneyOld - gotMoneyNew;
                    } // to avoid "Stack too deep"
                    lastSoldRatio = pool.soldRatio;
                    stockToSell = 0;
                }
            } // to avoid "Stack too deep"
            //  不需要 pools[grid] = pool;
            if (grid == 0) {
                // 防止grid=-1
                break;
            }
        }
    }
    
    function grids2prices(
        address gridexPair,
        uint256 beginGrid,
        uint256 length
    ) internal pure returns (uint256[] memory) {
        uint256[] memory prices = new uint256[](length);
        for (uint256 i = 0; i < length; i++) {
            prices[i] = IGridexPair(gridexPair).grid2price(beginGrid + i);
        }
        return (prices);
    }

    function getPools(
        address gridexPair,
        uint256 beginGrid,
        uint256 length
    ) internal view returns (IGridexInterface.Pool[] memory) {
        IGridexInterface.Pool[] memory pools = new IGridexInterface.Pool[](
            length
        );
        for (uint256 index = 0; index < length; index++) {
            pools[index] = IGridexPair(gridexPair).pools(beginGrid + index);
        }
        return pools;
    }

    function getPrice(
        uint256 priceLo,
        uint256 priceHi,
        uint256 soldRatio
    ) internal pure returns (uint256 price) {
        require(priceLo != 0 && priceHi != 0, "priceLo!=0 && priceHi!=0");
        price =
            (priceHi * soldRatio + priceLo * (RatioBase - soldRatio)) /
            RatioBase;
    }

    function getFee_m_d(address pairAddr, uint256 fee)
        public
        view
        returns (uint256)
    {
        IGridexInterface.Params memory p = IGridexPair(pairAddr).loadParams();
        uint256 fee_m_d = (fee << 128) | (p.priceMul << 64) | p.priceDiv;
        return fee_m_d;
    }

    function getLowGridAndHighGrid(address pairAddr)
        public
        view
        returns (uint256 lowGrid, uint256 highGrid)
    {
        uint256[] memory masks = IGridexPair(pairAddr).getMaskWords();
        (lowGrid, highGrid) = (GridCount, GridCount);
        uint256 lowMaskIndex = GridCount;
        uint256 highMaskIndex = GridCount;
        for (uint256 i = 0; i < masks.length; i++) {
            if (masks[i] != 0) {
                lowMaskIndex = i;
            }
            if (masks[masks.length - i - 1] != 0) {
                highMaskIndex = masks.length - i - 1;
            }
            if (lowMaskIndex != GridCount && highMaskIndex != GridCount) {
                break;
            }
        }
        if (lowMaskIndex == GridCount && highMaskIndex == GridCount) {
            return (GridCount, GridCount);
        }
        for (uint256 i = 0; i < 256; i++) {
            if (
                lowGrid == GridCount &&
                (masks[lowMaskIndex] & (uint256(1) << i)) != 0
            ) {
                lowGrid = 256 * lowMaskIndex + i;
            }
            if (
                highGrid == GridCount &&
                (masks[highMaskIndex] & (uint256(1) << (256 - i - 1))) != 0
            ) {
                highGrid = 256 * highMaskIndex + (256 - i - 1);
            }
            if (lowGrid != GridCount && highGrid != GridCount) {
                break;
            }
        }
    }
}
