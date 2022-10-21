// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.15;

import "./GridexUtil.sol";

// import "hardhat/console.sol";

contract ArbitrageUtil is GridexUtil {
    function _buyFromPools(
        address gridexPair,
        uint256 stockToBuy,
        uint256 grid,
        uint256 stopGrid,
        uint256 fee_m_d
    )
        internal
        view
        returns (
            uint256 totalPaidMoney,
            uint256 totalGotStock,
            uint64 lastSoldRatio
        )
    {
        bool isSell = false;
        uint256 length = stopGrid - grid;
        uint256 beginGrid = isSell ? (grid - length + 1) : grid;
        IGridexInterface.Pool[] memory pools = getPools(
            gridexPair,
            beginGrid,
            length
        );
        uint256[] memory prices = grids2prices(
            gridexPair,
            beginGrid,
            length + 1
        );
        (totalPaidMoney, totalGotStock, lastSoldRatio) = GridexUtil
            .getBuyFromPoolsResult(prices, pools, stockToBuy, fee_m_d);
    }

    function _sellToPools(
        address gridexPair,
        uint256 stockToSell,
        uint256 grid,
        uint256 stopGrid,
        uint256 fee_m_d
    )
        internal
        view
        returns (
            uint256 totalGotMoney,
            uint256 totalSoldStock,
            uint64 lastSoldRatio
        )
    {
        bool isSell = true;
        uint256 length = grid - stopGrid;
        uint256 beginGrid = isSell ? (grid - length + 1) : grid;
        IGridexInterface.Pool[] memory pools = getPools(
            gridexPair,
            beginGrid,
            length
        );
        uint256[] memory prices = grids2prices(
            gridexPair,
            beginGrid,
            length + 1
        );
        (totalGotMoney, totalSoldStock, lastSoldRatio) = GridexUtil
            .getSellToPoolsResult(prices, pools, stockToSell, fee_m_d);
    }

    function getArbitrageResult(address pairAddr, uint256 grid)
        external
        view
        returns (
            int256[6] memory result // lowGrid midGrid  highGrid totalGotStock totalGotMoney arbitragedPrice
        )
    {
        (uint256 lowGrid, uint256 highGrid) = getLowGridAndHighGrid(pairAddr);
        result[0] = int256(lowGrid);
        result[2] = int256(highGrid);
        if (result[0] == result[2]) {
            return result;
        }
        // uint256 maxLength = highGrid - lowGrid + 1;
        // for (uint256 i = 0; i < maxLength; i++) {
        //     uint256 left = lowGrid + i;
        //     uint256 right = highGrid - i;
        //     if (left > right) {
        //         break;
        //     }
        //     Pool memory pool = IGridexPair(pairAddr).pools(left);
        //     if (
        //         result[0] == 0 &&
        //         pool.totalShares != 0 &&
        //         pool.soldRatio != RatioBase
        //     ) {
        //         result[0] = int256(left);
        //     }
        //     pool = IGridexPair(pairAddr).pools(right);
        //     if (
        //         result[2] == 0 && pool.totalShares != 0 && pool.soldRatio != 0
        //     ) {
        //         result[2] = int256(right);
        //     }
        //     if (result[0] != 0 && result[2] != 0) {
        //         break;
        //     }
        // }
        // if (result[0] == result[2]) {
        //     // pools正常
        //     return result;
        // }
        int256 length = int256(result[2]) - int256(result[0]) + 1;
        int256 left = int256(grid);
        int256 right = int256(grid);
        bool flag = false;
        for (int256 index = 0; index < length; index++) {
            if (index == 0) {
                result[1] = int256(grid);
            } else if (
                (left > result[0] && index % 2 == 0) || right == result[2]
            ) {
                left--;
                result[1] = left;
            } else if (
                (right < result[2] && index % 2 == 1) || left == result[0]
            ) {
                right++;
                result[1] = right;
            }
            int256[3] memory curResult = getArbitrageSingleResult(
                pairAddr,
                uint256(result[0]),
                uint256(result[1]),
                uint256(result[2])
            );
            uint256 price = getPrice(
                IGridexPair(pairAddr).grid2price(uint256(result[1])),
                IGridexPair(pairAddr).grid2price(uint256(result[1]) + 1),
                uint256(result[2])
            );
            IGridexInterface.Params memory p = IGridexPair(pairAddr).loadParams();
            if (curResult[0] >= 0 && curResult[1] >= 0) {
                flag = true;
            } else if (curResult[0] > 0 && curResult[1] < 0) {
                uint256 dealPrice = (uint256(-curResult[1]) * p.priceMul) /
                    (uint256(curResult[0]) * p.priceDiv);
                if (dealPrice > price) {
                    flag = true;
                }
            } else if (curResult[0] < 0 && curResult[1] > 0) {
                uint256 dealPrice = (uint256(curResult[1]) * p.priceDiv) /
                    (uint256(-curResult[0]) * p.priceDiv);
                if (dealPrice < price) {
                    flag = true;
                }
            }
            if (flag) {
                result[3] = curResult[0];
                result[4] = curResult[1];
                result[5] = int256(price);
                break;
            }
        }
        require(flag, "getArbitrageResult: no best grid");
    }

    function getArbitrageSingleResult(
        address pairAddr,
        uint256 lowGrid,
        uint256 midGrid,
        uint256 highGrid
    )
        public
        view
        returns (
            int256[3] memory result // totalGotStock totalGotMoney lastSoldRatio
        )
    {
        uint256 fee_m_d = (IGridexPair(pairAddr).loadParams().priceMul << 64) |
            IGridexPair(pairAddr).loadParams().priceDiv;
        (uint256 paidMoney, uint256 gotStock, ) = _buyFromPools(
            pairAddr,
            LargeAmount,
            lowGrid,
            midGrid,
            fee_m_d
        );
        (uint256 gotMoney, uint256 soldStock, ) = _sellToPools(
            pairAddr,
            LargeAmount,
            highGrid,
            midGrid,
            fee_m_d
        );
        if (paidMoney <= gotMoney && soldStock <= gotStock) {
            result[2] = int256(
                uint256(IGridexPair(pairAddr).pools(midGrid).soldRatio)
            );
        }
        if (soldStock > gotStock && paidMoney < gotMoney) {
            address pairAddr_ = pairAddr;
            uint256 midGrid_ = midGrid;
            (uint256 m, uint256 s, uint64 lastSoldRatio) = _buyFromPools(
                pairAddr_,
                soldStock - gotStock,
                midGrid_,
                midGrid_ + 1,
                fee_m_d
            );
            gotStock += s;
            paidMoney += m;
            result[2] = int256(uint256(lastSoldRatio));
        }
        if (paidMoney > gotMoney && soldStock < gotStock) {
            address pairAddr_ = pairAddr;
            uint256 midGrid_ = midGrid;
            (uint256 m, uint256 s, uint64 lastSoldRatio) = _sellToPools(
                pairAddr_,
                gotStock - soldStock,
                midGrid_,
                midGrid_ - 1,
                fee_m_d
            );
            gotMoney += m;
            soldStock += s;
            result[2] = int256(uint256(lastSoldRatio));
        }
        result[0] = int256(gotStock) - int256(soldStock);
        result[1] = int256(gotMoney) - int256(paidMoney);
        if (result[0] == 0 && result[1] == 0) {
            result[2] = int256(
                uint256(IGridexPair(pairAddr).pools(midGrid).soldRatio)
            );
        }
    }
}
