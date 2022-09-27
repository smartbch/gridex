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
        int256 maxStock,
        int256 maxMoney
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

    function getMinAmount(uint256 stockToBuy, uint256 poolTotalStock)
        external
        pure
        returns (uint256);

    function grid2price(uint256 grid) external pure returns (uint256);

    function price2Grid(uint256 price) external view returns (uint256);
}
