import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "hardhat/console.sol";
import "./Interface.sol";

contract TestERC20 is ERC20 {
    uint8 private _decimals;

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    ) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function mint(address account, uint256 amount) public payable {
        _mint(account, amount);
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}

contract TestGridexUtil {
    uint256 constant RatioBase = 10**19; // need 64 bits
    uint256 constant PriceBase = 2**68;
    uint256 constant FeeBase = 10000;
    uint256 constant GridCount = 64 * 256;

    function getDeltaForInitPool(
        address pairAddress,
        uint256 grid,
        uint256 totalStock,
        uint256 soldRatio
    ) public view returns (uint256 deltaStock, uint256 deltaMoney) {
        require(soldRatio <= RatioBase, "invalid-ration");
        totalStock = uint96(totalStock);
        soldRatio = uint64(soldRatio);
        IGridexInterface.Params memory p = IGridexPair(pairAddress).loadParams();
        {
            // to avoid "Stack too deep"
            uint256 priceHi = IGridexPair(pairAddress).grid2price(grid + 1) *
                p.priceMul;
            uint256 priceLo = IGridexPair(pairAddress).grid2price(grid) *
                p.priceMul;
            uint256 soldStock = (totalStock * soldRatio) / RatioBase;
            deltaStock = totalStock - soldStock;
            uint256 price = (priceHi *
                soldRatio +
                priceLo *
                (RatioBase - soldRatio)) / RatioBase;
            deltaMoney = soldStock != 0
                ? ((soldStock * (price + priceLo)) /
                    (2 * PriceBase * p.priceDiv))
                : 0;
        }
    }

    function getDeltaForchangeShares(
        address pairAddress,
        uint256 grid,
        IGridexInterface.Pool memory pool,
        int160 sharesDelta
    ) public view returns (uint256 deltaStock, uint256 deltaMoney) {
        uint256 soldRatio = uint64(uint160(sharesDelta)); // encode soldRatio in the low bits
        sharesDelta >>= 64; //remove the soldRatio
        if (sharesDelta == 0) {
            return (0, 0);
        }

        if (pool.totalShares == 0) {
            require(sharesDelta > 0, "pool-not-init");
            return
                getDeltaForInitPool(
                    pairAddress,
                    grid,
                    uint256(int256(sharesDelta)),
                    soldRatio
                );
        }

        IGridexInterface.Params memory p = IGridexPair(pairAddress).loadParams();
        uint256 priceHi = IGridexPair(pairAddress).grid2price(grid + 1) *
            p.priceMul;
        uint256 priceLo = IGridexPair(pairAddress).grid2price(grid) *
            p.priceMul;
        uint256 price = (priceHi *
            uint256(pool.soldRatio) +
            priceLo *
            (RatioBase - uint256(pool.soldRatio))) / RatioBase;
        uint256 leftStockOld;
        uint256 gotMoneyOld;
        {
            // to avoid "Stack too deep"
            uint256 soldStockOld = (uint256(pool.totalStock) *
                uint256(pool.soldRatio)) / RatioBase;
            leftStockOld = uint256(pool.totalStock) - soldStockOld;
            gotMoneyOld =
                (soldStockOld * (price + priceLo)) /
                (2 * PriceBase * p.priceDiv);
        }

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
        uint256 leftStockNew;
        uint256 gotMoneyNew;
        {
            // to avoid "Stack too deep"
            uint256 soldStockNew = (uint256(pool.totalStock) *
                uint256(pool.soldRatio)) / RatioBase;
            leftStockNew = uint256(pool.totalStock) - soldStockNew;
            gotMoneyNew =
                (soldStockNew * (price + priceLo)) /
                (2 * PriceBase * p.priceDiv);
        }

        if (sharesDelta > 0) {
            uint256 deltaStock = leftStockNew - leftStockOld;
            uint256 deltaMoney = gotMoneyNew - gotMoneyOld;
            return (deltaStock, deltaMoney);
        } else {
            uint256 deltaStock = leftStockOld - leftStockNew;
            uint256 deltaMoney = gotMoneyOld - gotMoneyNew;
            return (deltaStock, deltaMoney);
        }
    }
}
