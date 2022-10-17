// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.15;

interface IGridexInterface {
    struct Pool {
        uint96 totalShares;
        uint96 totalStock;
        uint64 soldRatio;
    }

    struct Params {
        address stock;
        address money;
        uint256 priceDiv;
        uint256 priceMul;
        uint256 fee;
    }
}

interface IGridexPair {
    function loadParams()
        external
        view
        returns (IGridexInterface.Params memory params);

    function pools(uint256 grid)
        external
        view
        returns (IGridexInterface.Pool memory pool);

    function getMaskWords() external view returns (uint256[] memory masks);

    function batchChangeShares(
        uint256 grid,
        int160[] calldata sharesDelta,
        uint256 maxStock,
        uint256 maxMoney
    ) external payable returns (int256 paidStock, int256 paidMoney);

    function arbitrageAndBatchChangeShares(
        uint256 lowGrid,
        uint256 midGrid,
        uint256 highGrid,
        uint256 grid,
        int160[] calldata sharesDelta,
        uint256 maxStock,
        uint256 maxMoney
    ) external payable returns (int256 paidStock, int256 paidMoney);

    function buyFromPools(
        uint256 maxAveragePrice,
        uint256 stockToBuy,
        uint256 grid,
        uint256 stopGrid
    ) external payable returns (uint256 totalPaidMoney, uint256 totalGotStock);

    function sellToPools(
        uint256 minAveragePrice,
        uint256 stockToSell,
        uint256 grid,
        uint256 stopGrid
    ) external payable returns (uint256 totalGotMoney, uint256 totalSoldStock);

    function grid2price(uint256 grid) external pure returns (uint256);

    function price2Grid(uint256 price) external view returns (uint256);

    function calcPool(
        uint256 priceDiv,
        uint256 priceLo,
        uint256 priceHi,
        uint96 totalStock,
        uint64 soldRatio
    )
        external
        pure
        returns (
            uint256 leftStock,
            uint256 soldStock,
            uint256 gotMoney
        );

    function calcPrice(
        uint256 priceLo,
        uint256 priceHi,
        uint64 soldRatio
    ) external pure returns (uint256 price);
}
