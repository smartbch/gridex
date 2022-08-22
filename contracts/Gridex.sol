// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.15;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
// import "hardhat/console.sol";

// Gridex can support the price range from 1/(2**32) to 2**32. The prices within this range is divided to 16384 grids, and 
// the ratio between a pair of adjacent prices is alpha=2**(1/256.)=1.0027112750502025
// A bancor-style market-making pool can be created between a pair of adjacent prices, i.e. priceHi and priceLo.
// Theoretically, there are be 16383 pools. But in pratice, only a few pools with reasonable prices exist.
//
//                    * priceHi
//                   /|
//                  / |       priceHi: the high price
//                 /  |       priceLo: the low price
//                /   |       price: current price
//               /    |       sold stock: the stock amount that has been sold out (the a-b line)
//         price*     |       left stock: the stock amount that has NOT been sold out (the b-c line)
//             /|     |       total stock: sum of the sold stock and the left stock (the a-c line)
//            /=|     |       got money: the money amount got by selling stock (the left trapezoid area)
//           /==|     |                  got money = soldStock*(price+priceLo)/2
//          /===|     |       sold ratio = sold stock / total stock
//         /====|     |
// priceLo*=====|     |
//        |=====|     |
//        |=got=|     |
//        |money|     |
//        |=====|_____|
//        a     b     c
//        |sold |left |
//        |stock|stock|
//
// You can deal with a pool by selling stock to it or buying stock from it. And the dealing price is calculated as:
// price = priceLo*(1-soldRatio) + priceHi*soldRatio
// So, if none of the pool's stock is sold, the price is priceLo, if all of the pool's stock is sold, the price is priceHi
// 
// You can add stock and money to a pool to provide more liquidity. The added stock and money must keep the current 
// stock/money ratio of the pool, such that "price" and "soldRatio" are unchanged. After adding you get shares of the pool.
//
// A pool may contains tokens from many different accounts. For each account we record its "shares" amount, which denotes 
// how much of the tokens is owned by this account. For each pool we record its "total shares" amount, which is the sum
// of all the accounts' shares. Shares are like Uniswap-V2's liquidity token. But they are not implemented as ERC20 here.

abstract contract GridexLogicAbstract is ERC1155{
	uint public stock_priceDiv;
	uint public money_priceMul;

	struct Pool {
		uint96 totalShares;
		uint96 totalStock;
		uint64 soldRatio;
	}

	struct PoolWithMyShares {
		uint96 totalShares;
		uint96 totalStock;
		uint64 soldRatio;
		uint96 myShares;
	}

	struct Params {
		address stock;
		address money;
		uint priceDiv;
		uint priceMul;
	}

	address constant private SEP206Contract = address(uint160(0x2711));
	uint constant GridCount = 64*256;
	uint constant MaskWordCount = 64;
	uint constant private RatioBase = 10**19; // need 64 bits
	uint constant private PriceBase = 2**68;
	uint constant MASK16 = (1<<16)-1;
	uint constant FeeBase = 10000;
	uint private _fee;
	address immutable private factoryAddress;

	Pool[GridCount] public pools;
	uint[MaskWordCount] internal maskWords;

	function getPrice(uint grid) internal virtual returns (uint);
	function getMaskWords() view external virtual returns (uint[] memory masks);

	constructor() {
		factoryAddress = msg.sender;
	}
	
	function setFee(uint fee) payable external {
		require(msg.sender == factoryAddress, 'only factoryAddress');
		_fee = fee;
	}

	function getFee() internal view returns(uint) {
		return _fee;
	}

	function getPoolAndMyShares(uint start, uint end) view external returns (PoolWithMyShares[] memory arr) {
		arr = new PoolWithMyShares[](end-start);
		for(uint i=start; i<end; i++) {
			Pool memory pool = pools[i];
			uint j = i-start;
			arr[j].totalShares = pool.totalShares;
			arr[j].totalStock = pool.totalStock;
			arr[j].soldRatio = pool.soldRatio;
			arr[j].myShares = uint96(balanceOf(msg.sender, j));
		}
	}

	function loadParams() view public returns (Params memory params) {
		(params.stock, params.priceDiv) = (address(uint160(stock_priceDiv>>96)), uint96(stock_priceDiv));
		(params.money, params.priceMul) = (address(uint160(money_priceMul>>96)), uint96(money_priceMul));
	}

	function safeTransfer(address coinType, address receiver, uint amount) internal {
		if(amount == 0) {
			return;
		}
		(bool success, bytes memory data) = coinType.call(
			abi.encodeWithSignature("transfer(address,uint256)", receiver, amount));
		bool ret = abi.decode(data, (bool));
		require(success && ret, "trans-fail");
	}

	function safeReceive(address coinType, uint amount, bool bchExclusive) internal {
		if(amount == 0) {
			return;
		}
		if(coinType == SEP206Contract) {
			require(msg.value == amount, "value-mismatch");
		} else {
			require(!bchExclusive || msg.value == 0, "dont-send-bch");
			IERC20(coinType).transferFrom(msg.sender, address(this), uint(amount));
		}
	}

	function initPool(uint grid, uint totalStock, uint soldRatio) public payable returns (uint leftStock, uint gotMoney) {
		require(soldRatio<=RatioBase, "invalid-ration");
		Pool memory pool = pools[grid];
		require(pool.totalShares ==0, "already created");
		pool.totalStock = uint96(totalStock);
		pool.totalShares = uint96(totalStock);
		pool.soldRatio = uint64(soldRatio);
		{ // to avoid "Stack too deep"
			uint priceHi = getPrice(grid+1);
			uint priceLo = getPrice(grid);
			uint soldStock = totalStock*soldRatio/RatioBase;
			leftStock = totalStock-soldStock;
			uint price = (priceHi*soldRatio + priceLo*(RatioBase-soldRatio)) /RatioBase + 1;
			gotMoney = soldStock!=0 ? (soldStock*(price+priceLo)/(2*PriceBase) + 1) : 0;
			_mint(msg.sender, grid, pool.totalShares, "");
			pools[grid] = pool;
		}
		address stock = address(uint160(stock_priceDiv>>96));
		address money = address(uint160(money_priceMul>>96));
		bool bchExclusive = stock != SEP206Contract && money != SEP206Contract;
		safeReceive(stock, leftStock, bchExclusive);
		safeReceive(money, gotMoney, bchExclusive);
		(uint wordIdx, uint bitIdx) = (grid/256, grid%256);
		maskWords[wordIdx] |= (uint(1)<<bitIdx); // set bit
	}

	function arbitrageAndBatchChangeShares(uint midGrid, uint highGrid, uint lowGrid,
	                         uint grid, int160[] calldata sharesDelta, int maxStock, int maxMoney) public 
	                         payable returns (int paidStock, int paidMoney) {
		(uint totalGotStock, uint totalGotMoney) = arbitrage(midGrid, highGrid, lowGrid);
		(paidStock, paidMoney) = batchChangeShares(grid, sharesDelta, maxStock, maxMoney);
		paidStock -= int(totalGotStock);
		paidMoney -= int(totalGotMoney);
	}

	function batchChangeShares(uint grid, int160[] calldata sharesDelta, int maxStock, int maxMoney) public 
	                                                       payable returns (int paidStock, int paidMoney) {
		for(uint i=0; i<sharesDelta.length; i++) {
			int160 delta = sharesDelta[i];
			(uint s, uint m) = changeShares(grid+i, delta);
			if(delta>0) {
				paidStock += int(s);
				paidMoney += int(m);
			} else {
				paidStock -= int(s);
				paidMoney -= int(m);
			}
		}
		require(paidStock <= maxStock, "too-much-stock-paid");
		require(paidMoney <= maxMoney, "too-much-money-paid");
	}

	function changeShares(uint grid, int160 sharesDelta) public payable returns (uint, uint) {
		Pool memory pool = pools[grid];
		if(pool.totalShares == 0) {
			uint soldRatio = uint64(uint160(sharesDelta)); // encode soldRatio in the low bits
			sharesDelta >>= 64;
			require(sharesDelta > 0, "pool-not-init");
			return initPool(grid, uint(int(sharesDelta)), soldRatio);
		}
		sharesDelta >>= 64; //remove the useless soldRatio

		uint priceHi = getPrice(grid+1);
		uint priceLo = getPrice(grid);
		uint price = (priceHi*uint(pool.soldRatio) + priceLo*(RatioBase-uint(pool.soldRatio)))/RatioBase;
		uint leftStockOld;
		uint gotMoneyOld;
		{ // to avoid "Stack too deep"
			uint soldStockOld = uint(pool.totalStock)*uint(pool.soldRatio)/RatioBase;
			leftStockOld = uint(pool.totalStock)-soldStockOld;
			gotMoneyOld = soldStockOld*(price+priceLo)/(2*PriceBase);
		}

		if(sharesDelta>0) {
			pool.totalStock += uint96(uint(pool.totalStock)*uint(int(sharesDelta))/uint(pool.totalShares));
			pool.totalShares += uint96(int96(sharesDelta));
			_mint(msg.sender, grid, uint96(int96(sharesDelta)), "");
			pools[grid] = pool;
		} else {
			pool.totalStock -= uint96(uint(pool.totalStock)*uint(int(-sharesDelta))/uint(pool.totalShares));
			pool.totalShares -= uint96(int96(-sharesDelta));
			_burn(msg.sender, grid, uint96(int96(-sharesDelta)));
			pools[grid] = pool;
		}
		uint leftStockNew;
		uint gotMoneyNew;
		{ // to avoid "Stack too deep"
			uint soldStockNew = uint(pool.totalStock)*uint(pool.soldRatio)/RatioBase;
			leftStockNew = uint(pool.totalStock)-soldStockNew;
			gotMoneyNew = soldStockNew*(price+priceLo)/(2*PriceBase);
		}

		address stock = address(uint160(stock_priceDiv>>96));
		address money = address(uint160(money_priceMul>>96));
		bool bchExclusive = stock != SEP206Contract && money != SEP206Contract;
		if(sharesDelta>0) {
			uint deltaStock = leftStockNew-leftStockOld;
			uint deltaMoney = gotMoneyNew-gotMoneyOld + 1;
			safeReceive(stock, deltaStock, bchExclusive);
			safeReceive(money, deltaMoney, bchExclusive);
			return (deltaStock, deltaMoney);
		} else {
			uint deltaStock = leftStockOld-leftStockNew;
			uint deltaMoney = gotMoneyOld-gotMoneyNew - 1;
			safeTransfer(stock, msg.sender, deltaStock);
			safeTransfer(money, msg.sender, deltaMoney);
			return (deltaStock, deltaMoney);
		}
	}

	function buyFromPools(uint maxAveragePrice, uint stockToBuy, uint grid, uint stopGrid) external payable 
								returns (uint totalPaidMoney, uint totalGotStock) {
		uint fee = getFee();
		(totalPaidMoney, totalGotStock) = _buyFromPools(stockToBuy, grid, stopGrid, fee);
		require(totalPaidMoney*PriceBase <= totalGotStock*maxAveragePrice, "price-too-high");
		Params memory params = loadParams();
		safeReceive(params.money, totalPaidMoney, params.money != SEP206Contract);
		safeTransfer(params.stock, msg.sender, totalGotStock);
	}

	function _buyFromPools(uint stockToBuy, uint grid, uint stopGrid, uint fee) internal
								returns (uint totalPaidMoney, uint totalGotStock) {
		(totalPaidMoney, totalGotStock) = (0, 0);
		uint priceHi = getPrice(grid);
		for(; stockToBuy != 0 && grid < stopGrid; grid++) {
			uint priceLo = priceHi;
			priceHi = getPrice(grid+1);
			Pool memory pool = pools[grid];
			if(pool.totalStock == 0 || pool.soldRatio == RatioBase) { // cannot deal
				continue;
			}
			uint price = (priceHi*pool.soldRatio + priceLo*(RatioBase-pool.soldRatio))/RatioBase;
			uint soldStockOld = uint(pool.totalStock)*uint(pool.soldRatio)/RatioBase;
			uint leftStockOld = uint(pool.totalStock)-soldStockOld;
			uint gotMoneyOld = soldStockOld*(price+priceLo)/(2*PriceBase);
			if(stockToBuy >= leftStockOld) { // buy all in pool
				uint gotMoneyNew = gotMoneyOld+
				    /*MoneyIncr:*/ leftStockOld*(price+priceHi)*(FeeBase+fee)/(2*FeeBase); //fee in money
				uint totalStock = 1/*for rounding error*/+gotMoneyNew*2*PriceBase/(priceHi+priceLo);
				gotMoneyNew = totalStock*(priceHi+priceLo)/(2*PriceBase);
				stockToBuy -= leftStockOld;
				totalGotStock += leftStockOld;
				pool.soldRatio = uint64(RatioBase);
				pool.totalStock = uint96(totalStock);
				totalPaidMoney += gotMoneyNew-gotMoneyOld;
			} else { // cannot buy all in pool
				uint stockFee = stockToBuy*fee/FeeBase; //fee in stock
				pool.totalStock += uint96(stockFee);
				uint soldStockNew = soldStockOld+stockToBuy;
				pool.soldRatio = uint64(RatioBase*soldStockNew/pool.totalStock);
				price = (priceHi*pool.soldRatio + priceLo*(RatioBase-pool.soldRatio))/RatioBase;
				soldStockNew = uint(pool.totalStock)*uint(pool.soldRatio)/RatioBase;
				{ // to avoid "Stack too deep"
				uint leftStockNew = pool.totalStock-soldStockNew; 
				                //≈ totalStockOld+stockFee-soldStockOld-stockToBuy
				uint gotMoneyNew = soldStockNew*(price+priceLo)/(2*PriceBase);
				totalGotStock += leftStockOld-leftStockNew; //≈ stockToBuy-stockFee
				totalPaidMoney += gotMoneyNew-gotMoneyOld;
				} // to avoid "Stack too deep"
				stockToBuy = 0;
			}
			pools[grid] = pool;
		}
	}

	function sellToPools(uint minAveragePrice, uint stockToSell, uint grid, uint stopGrid) external payable 
								returns (uint totalGotMoney, uint totalSoldStock) {
		uint fee = getFee();
		(totalGotMoney, totalSoldStock) = _sellToPools(stockToSell, grid, stopGrid, fee);
		require(totalSoldStock*minAveragePrice <= totalGotMoney*PriceBase, "price-too-low");
		Params memory params = loadParams();
		safeReceive(params.stock, totalSoldStock, params.stock != SEP206Contract);
		safeTransfer(params.money, msg.sender, totalGotMoney);
	}

	function _sellToPools(uint stockToSell, uint grid, uint stopGrid, uint fee) internal
								returns (uint totalGotMoney, uint totalSoldStock) {
		(totalGotMoney, totalSoldStock) = (0, 0);
		uint priceLo = getPrice(grid);
		for(; stockToSell != 0 && grid>stopGrid; grid--) {
			uint priceHi = priceLo;
			priceLo = getPrice(grid-1);
			Pool memory pool = pools[grid];
			if(pool.totalStock == 0 || pool.soldRatio == 0) { // cannot deal
				continue;
			}
			{ // to avoid "Stack too deep"
			uint price = (priceHi*pool.soldRatio + priceLo*(RatioBase-pool.soldRatio))/RatioBase;
			uint soldStockOld = uint(pool.totalStock)*uint(pool.soldRatio)/RatioBase;
			uint leftStockOld = pool.totalStock-soldStockOld;
			uint gotMoneyOld = soldStockOld*(price+priceLo)/(2*PriceBase);
			uint stockFee = soldStockOld*fee/FeeBase;
			if(stockToSell >= soldStockOld+stockFee) { // get all money all in pool
				pool.soldRatio = 0;
				pool.totalStock += uint96(stockFee); // fee in stock
				stockToSell -= soldStockOld+stockFee;
				totalSoldStock += soldStockOld+stockFee;
				totalGotMoney += gotMoneyOld;
			} else { // cannot get all money all in pool
				stockFee = stockToSell*fee/FeeBase;
				pool.totalStock += uint96(stockFee); // fee in stock
				{ // to avoid "Stack too deep"
				uint soldStockNew = soldStockOld-stockToSell;
				pool.soldRatio = uint64(1/*for rounding error*/+RatioBase*soldStockNew/pool.totalStock);
				price = (priceHi*pool.soldRatio + priceLo*(RatioBase-pool.soldRatio))/RatioBase;
				soldStockNew = uint(pool.totalStock)*uint(pool.soldRatio)/RatioBase;
				uint leftStockNew = pool.totalStock - soldStockNew;
				               // ≈ totalStockOld+stockFee-soldStockOld+stockToSell
				uint gotMoneyNew = soldStockNew*(price+priceLo)/(2*PriceBase);
				totalSoldStock += leftStockNew-leftStockOld; //≈ stockFee+stockToSell
				totalGotMoney += gotMoneyOld-gotMoneyNew;
				} // to avoid "Stack too deep"
				stockToSell = 0;
			}
			} // to avoid "Stack too deep"
			pools[grid] = pool;
		}
	}

	function arbitrage(uint midGrid, uint highGrid, uint lowGrid) public 
					returns (uint totalGotStock, uint totalGotMoney) {
		uint fee = getFee();
		uint largeAmount = 1<<95;
		(uint paidMoney, uint gotStock) = _buyFromPools(largeAmount, lowGrid, midGrid, fee);
		(uint gotMoney, uint soldStock) = _sellToPools(largeAmount, midGrid+1, highGrid, fee);
		require(paidMoney <= gotMoney || soldStock <= gotStock, "no-benefit");
		uint stopGrid = midGrid+1;
		if(paidMoney > gotMoney) {
			(uint m, uint s) = _sellToPools(largeAmount, midGrid, stopGrid, fee);
			paidMoney -= m;
			soldStock += s;
		}
		if(soldStock > gotStock) {
			(uint m, uint s) = _buyFromPools(largeAmount, midGrid,stopGrid, fee);
			soldStock -= s;
			paidMoney += m;
		}
		require(paidMoney <= gotMoney && soldStock <= gotStock, "no-final-benefit");
		totalGotStock = gotStock - soldStock;
		totalGotMoney = gotMoney - paidMoney;
		Params memory params = loadParams();
		safeTransfer(params.stock, msg.sender, totalGotStock);
		safeTransfer(params.money, msg.sender, totalGotMoney);
	}

	function batchTrade(uint[] calldata sellArgs, uint[] calldata buyArgs, int maxAveragePrice,
				int minAveragePrice) external payable returns (int totalGotStock, int totalGotMoney) {
		uint fee = getFee();
		for(uint i=0; i<buyArgs.length; i++) {
			uint b = buyArgs[i];
			uint stockToBuy = b>>32;
			uint grid = (b>>16) & 0xFFFF;
			uint stopGrid = b & 0xFFFF;
			(uint paidMoney, uint gotStock) = _buyFromPools(stockToBuy, grid, stopGrid, fee);
			totalGotStock += int(gotStock);
			totalGotMoney -= int(paidMoney);
		}
		for(uint i=0; i<sellArgs.length; i++) {
			uint s = sellArgs[i];
			uint stockToSell = s>>32;
			uint grid = (s>>16) & 0xFFFF;
			uint stopGrid = s & 0xFFFF;
			(uint gotMoney, uint soldStock) = _sellToPools(stockToSell, grid, stopGrid, fee);
			totalGotStock -= int(soldStock);
			totalGotMoney += int(gotMoney);
		}
		require(totalGotMoney > 0 || totalGotStock > 0, "no-benefit");
		Params memory params = loadParams();
		if(totalGotMoney > 0 && totalGotStock > 0) { // arbitrage
			safeTransfer(params.stock, msg.sender, uint(totalGotStock));
			safeTransfer(params.money, msg.sender, uint(totalGotMoney));
		} else if (totalGotMoney < 0 && totalGotStock > 0) { // buy stock
			require(totalGotStock*maxAveragePrice >= -totalGotMoney*int(PriceBase), "price-too-high");
			safeReceive(params.money, uint(-totalGotMoney), params.money != SEP206Contract);
			safeTransfer(params.stock, msg.sender, uint(totalGotStock));
		} else if (totalGotMoney > 0 && totalGotStock < 0) { // sell stock
			require(-totalGotStock*minAveragePrice <= totalGotMoney*int(PriceBase), "price-too-low");
			safeReceive(params.stock, uint(-totalGotStock), params.stock != SEP206Contract);
			safeTransfer(params.money, msg.sender, uint(totalGotMoney));
		}
	}

	function extractNthU16(uint z, uint nth) internal pure returns (uint) {
		uint shiftAmount = nth*16;
		return (z>>shiftAmount)&MASK16;
	}
}

contract GridexLogic256 is GridexLogicAbstract {
	// alpha = 1.0027112750502025 = Math.pow(2, 1/256.);   Math.pow(alpha, 256) = 2  2**16=65536
	// for(var i=0; i<16; i++) {console.log(Math.round( Math.pow(2, 20) * Math.pow(alpha, i)))}
	uint constant X     = (uint(1048576-1048576)<< 0*16)| // extractNthU16(X, 0)==Math.pow(2,20)*(Math.pow(alpha,0) -1)
                          (uint(1051419-1048576)<< 1*16)| // extractNthU16(X, 1)==Math.pow(2,20)*(Math.pow(alpha,1) -1)
                          (uint(1054270-1048576)<< 2*16)| // extractNthU16(X, 2)==Math.pow(2,20)*(Math.pow(alpha,2) -1)
                          (uint(1057128-1048576)<< 3*16)| // extractNthU16(X, 3)==Math.pow(2,20)*(Math.pow(alpha,3) -1)
                          (uint(1059994-1048576)<< 4*16)| // extractNthU16(X, 4)==Math.pow(2,20)*(Math.pow(alpha,4) -1)
                          (uint(1062868-1048576)<< 5*16)| // extractNthU16(X, 5)==Math.pow(2,20)*(Math.pow(alpha,5) -1)
                          (uint(1065750-1048576)<< 6*16)| // extractNthU16(X, 6)==Math.pow(2,20)*(Math.pow(alpha,6) -1)
                          (uint(1068639-1048576)<< 7*16)| // extractNthU16(X, 7)==Math.pow(2,20)*(Math.pow(alpha,7) -1)
                          (uint(1071537-1048576)<< 8*16)| // extractNthU16(X, 8)==Math.pow(2,20)*(Math.pow(alpha,8) -1)
                          (uint(1074442-1048576)<< 9*16)| // extractNthU16(X, 9)==Math.pow(2,20)*(Math.pow(alpha,9) -1)
                          (uint(1077355-1048576)<<10*16)| // extractNthU16(X,10)==Math.pow(2,20)*(Math.pow(alpha,10)-1)
                          (uint(1080276-1048576)<<11*16)| // extractNthU16(X,11)==Math.pow(2,20)*(Math.pow(alpha,11)-1)
                          (uint(1083205-1048576)<<12*16)| // extractNthU16(X,12)==Math.pow(2,20)*(Math.pow(alpha,12)-1)
                          (uint(1086142-1048576)<<13*16)| // extractNthU16(X,13)==Math.pow(2,20)*(Math.pow(alpha,13)-1)
                          (uint(1089087-1048576)<<14*16)| // extractNthU16(X,14)==Math.pow(2,20)*(Math.pow(alpha,14)-1)
                          (uint(1092040-1048576)<<15*16); // extractNthU16(X,15)==Math.pow(2,20)*(Math.pow(alpha,15)-1)

	// for(var i=0; i<16; i++) {console.log(Math.round( Math.pow(2,16) * Math.pow(alpha, i*16)))}
	uint constant Y     = (uint(65536 -65536)<<( 0*16))| //extractNthU16(Y, 0)==Math.pow(2,16)*(Math.pow(alpha,16*0) -1) 
                          (uint(68438 -65536)<<( 1*16))| //extractNthU16(Y, 1)==Math.pow(2,16)*(Math.pow(alpha,16*1) -1) 
                          (uint(71468 -65536)<<( 2*16))| //extractNthU16(Y, 2)==Math.pow(2,16)*(Math.pow(alpha,16*2) -1) 
                          (uint(74632 -65536)<<( 3*16))| //extractNthU16(Y, 3)==Math.pow(2,16)*(Math.pow(alpha,16*3) -1) 
                          (uint(77936 -65536)<<( 4*16))| //extractNthU16(Y, 4)==Math.pow(2,16)*(Math.pow(alpha,16*4) -1) 
                          (uint(81386 -65536)<<( 5*16))| //extractNthU16(Y, 5)==Math.pow(2,16)*(Math.pow(alpha,16*5) -1) 
                          (uint(84990 -65536)<<( 6*16))| //extractNthU16(Y, 6)==Math.pow(2,16)*(Math.pow(alpha,16*6) -1) 
                          (uint(88752 -65536)<<( 7*16))| //extractNthU16(Y, 7)==Math.pow(2,16)*(Math.pow(alpha,16*7) -1) 
                          (uint(92682 -65536)<<( 8*16))| //extractNthU16(Y, 8)==Math.pow(2,16)*(Math.pow(alpha,16*8) -1) 
                          (uint(96785 -65536)<<( 9*16))| //extractNthU16(Y, 9)==Math.pow(2,16)*(Math.pow(alpha,16*9) -1) 
                          (uint(101070-65536)<<(10*16))| //extractNthU16(Y,10)==Math.pow(2,16)*(Math.pow(alpha,16*10)-1) 
                          (uint(105545-65536)<<(11*16))| //extractNthU16(Y,11)==Math.pow(2,16)*(Math.pow(alpha,16*11)-1) 
                          (uint(110218-65536)<<(12*16))| //extractNthU16(Y,12)==Math.pow(2,16)*(Math.pow(alpha,16*12)-1) 
                          (uint(115098-65536)<<(13*16))| //extractNthU16(Y,13)==Math.pow(2,16)*(Math.pow(alpha,16*13)-1) 
                          (uint(120194-65536)<<(14*16))| //extractNthU16(Y,14)==Math.pow(2,16)*(Math.pow(alpha,16*14)-1) 
                          (uint(125515-65536)<<(15*16)); //extractNthU16(Y,15)==Math.pow(2,16)*(Math.pow(alpha,16*15)-1) 

	constructor(string memory uri_)  ERC1155(uri_) {}	

	function getPrice(uint grid) internal pure override returns (uint) {
		require(grid < GridCount, "invalid-grid");
		(uint head, uint tail) = (grid/256, grid%256);
		uint x = extractNthU16(X, tail%16);
		uint y = extractNthU16(Y, tail/16);
		uint beforeShift = ((1<<20)+x) * ((1<<16)+y); // = Math.pow(alpha, tail) * Math.pow(2, 36)
		return beforeShift<<head;
	}

	function getMaskWords() view external override returns (uint[] memory masks) {
		masks = new uint[](MaskWordCount);
		for(uint i=0; i < masks.length; i++) {
			masks[i] = maskWords[i];
		}
	}
}

contract GridexLogic64 is GridexLogicAbstract {
	// alpha = 1.0108892860517005 = Math.pow(2, 1/64.);   Math.pow(alpha, 64) = 2  2**19=524288
	// for(var i=0; i<8; i++) {console.log(Math.round( Math.pow(2, 19) * Math.pow(alpha, i)))}
	uint constant X =     (uint(524288-524288)<< 0*16)| // extractNthU16(X, 0)==Math.pow(2,19)*(Math.pow(alpha,0) -1)
                          (uint(529997-524288)<< 1*16)| // extractNthU16(X, 1)==Math.pow(2,19)*(Math.pow(alpha,1) -1)
                          (uint(535768-524288)<< 2*16)| // extractNthU16(X, 2)==Math.pow(2,19)*(Math.pow(alpha,2) -1)
                          (uint(541603-524288)<< 3*16)| // extractNthU16(X, 3)==Math.pow(2,19)*(Math.pow(alpha,3) -1)
                          (uint(547500-524288)<< 4*16)| // extractNthU16(X, 4)==Math.pow(2,19)*(Math.pow(alpha,4) -1)
                          (uint(553462-524288)<< 5*16)| // extractNthU16(X, 5)==Math.pow(2,19)*(Math.pow(alpha,5) -1)
                          (uint(559489-524288)<< 6*16)| // extractNthU16(X, 6)==Math.pow(2,19)*(Math.pow(alpha,6) -1)
                          (uint(565581-524288)<< 7*16); // extractNthU16(X, 7)==Math.pow(2,19)*(Math.pow(alpha,7) -1)

	// for(var i=0; i<8; i++) {console.log(Math.round( Math.pow(2,16) * Math.pow(alpha, i*8)))}
	uint constant Y =     (uint(65536 -65536)<< 0*16)| // extractNthU16(Y, 0)==Math.pow(2,16)*(Math.pow(alpha,8*0) -1)
                          (uint(71468 -65536)<< 1*16)| // extractNthU16(Y, 1)==Math.pow(2,16)*(Math.pow(alpha,8*1) -1)
                          (uint(77936 -65536)<< 2*16)| // extractNthU16(Y, 2)==Math.pow(2,16)*(Math.pow(alpha,8*2) -1)
                          (uint(84990 -65536)<< 3*16)| // extractNthU16(Y, 3)==Math.pow(2,16)*(Math.pow(alpha,8*3) -1)
                          (uint(92682 -65536)<< 4*16)| // extractNthU16(Y, 4)==Math.pow(2,16)*(Math.pow(alpha,8*4) -1)
                          (uint(101070-65536)<< 5*16)| // extractNthU16(Y, 5)==Math.pow(2,16)*(Math.pow(alpha,8*5) -1)
                          (uint(110218-65536)<< 6*16)| // extractNthU16(Y, 6)==Math.pow(2,16)*(Math.pow(alpha,8*6) -1)
                          (uint(120194-65536)<< 7*16); // extractNthU16(Y, 7)==Math.pow(2,16)*(Math.pow(alpha,8*7) -1)

	constructor(string memory uri_)  ERC1155(uri_) {}	

	function getPrice(uint grid) internal pure override returns (uint) {
		// GridCount实际最大 15199
		require(grid < GridCount, "invalid-grid");
		(uint head, uint tail) = (grid/64, grid%64);
		uint x = extractNthU16(X, tail%8);
		uint y = extractNthU16(Y, tail/8);
		uint beforeShift = ((1<<19)+x) * ((1<<16)+y); // = Math.pow(alpha, tail) * Math.pow(2, 35)
		return beforeShift<<head;
	}

	function getMaskWords() view external override returns (uint[] memory masks) {
		masks = new uint[](MaskWordCount/8);
		for(uint i=0; i < masks.length; i++) {
			masks[i] = maskWords[i];
		}
	}
}

contract GridexLogic16 is GridexLogicAbstract {
	// alpha = 1.0442737824274138 = Math.pow(2, 1/16.);   Math.pow(alpha, 16) = 2  
	// for(var i=0; i<16; i++) {console.log(Math.round( Math.pow(2, 16) * Math.pow(alpha, i)))}
	uint constant X = (uint(65536 -65536)<< 0*16)| // extractNthU16(Y, 0)==Math.pow(2,16)*(Math.pow(alpha, 0) -1)
                          (uint(68438 -65536)<< 1*16)| // extractNthU16(Y, 1)==Math.pow(2,16)*(Math.pow(alpha, 1) -1)
                          (uint(71468 -65536)<< 2*16)| // extractNthU16(Y, 2)==Math.pow(2,16)*(Math.pow(alpha, 2) -1)
                          (uint(74632 -65536)<< 3*16)| // extractNthU16(Y, 3)==Math.pow(2,16)*(Math.pow(alpha, 3) -1)
                          (uint(77936 -65536)<< 4*16)| // extractNthU16(Y, 4)==Math.pow(2,16)*(Math.pow(alpha, 4) -1)
                          (uint(81386 -65536)<< 5*16)| // extractNthU16(Y, 5)==Math.pow(2,16)*(Math.pow(alpha, 5) -1)
                          (uint(84990 -65536)<< 6*16)| // extractNthU16(Y, 6)==Math.pow(2,16)*(Math.pow(alpha, 6) -1)
                          (uint(88752 -65536)<< 7*16)| // extractNthU16(Y, 7)==Math.pow(2,16)*(Math.pow(alpha, 7) -1)
                          (uint(92682 -65536)<< 8*16)| // extractNthU16(Y, 8)==Math.pow(2,16)*(Math.pow(alpha, 8) -1)
                          (uint(96785 -65536)<< 9*16)| // extractNthU16(Y, 9)==Math.pow(2,16)*(Math.pow(alpha, 9) -1)
                          (uint(101070-65536)<<10*16)| // extractNthU16(Y,10)==Math.pow(2,16)*(Math.pow(alpha,10) -1)
                          (uint(105545-65536)<<11*16)| // extractNthU16(Y,11)==Math.pow(2,16)*(Math.pow(alpha,11) -1)
                          (uint(110218-65536)<<12*16)| // extractNthU16(Y,12)==Math.pow(2,16)*(Math.pow(alpha,12) -1)
                          (uint(115098-65536)<<13*16)| // extractNthU16(Y,13)==Math.pow(2,16)*(Math.pow(alpha,13) -1)
                          (uint(120194-65536)<<14*16)| // extractNthU16(Y,14)==Math.pow(2,16)*(Math.pow(alpha,14) -1)
                          (uint(125515-65536)<<15*16); // extractNthU16(Y,15)==Math.pow(2,16)*(Math.pow(alpha,15) -1)

	constructor(string memory uri_)  ERC1155(uri_) {}	

	function getPrice(uint grid) internal pure override returns (uint) {
		require(grid < GridCount, "invalid-grid");
		(uint head, uint tail) = (grid/16, grid%16);
		uint x = extractNthU16(X, tail);
		uint beforeShift = ((1<<16)+x); // = Math.pow(alpha, tail) * Math.pow(2, 16)
		return beforeShift<<head;
	}

	function getMaskWords() view external override returns (uint[] memory masks) {
		masks = new uint[](MaskWordCount/64);
		for(uint i=0; i < masks.length; i++) {
			masks[i] = maskWords[i];
		}
	}
}

contract GridexProxy {
	uint public stock_priceDiv;
	uint public money_priceMul;
	uint immutable public implAddr;
	
	constructor(uint _stock_priceDiv, uint _money_priceMul, address _impl) {
		stock_priceDiv = _stock_priceDiv;
		money_priceMul = _money_priceMul;
		implAddr = uint(uint160(_impl));
	}
	
	receive() external payable {
		require(false);
	}

	fallback() external payable {
		uint impl=implAddr;
		assembly {
			let ptr := mload(0x40)
			calldatacopy(ptr, 0, calldatasize())
			let result := delegatecall(gas(), impl, ptr, calldatasize(), 0, 0)
			let size := returndatasize()
			returndatacopy(ptr, 0, size)
			switch result
			case 0 { revert(ptr, size) }
			default { return(ptr, size) }
		}
	}
}

contract GridexFactory is Ownable{
	address constant SEP206Contract = address(uint160(0x2711));

	event Created(address indexed stock, address indexed money, address indexed impl, address pairAddr);

	function getAddress(address stock, address money, address impl) public view returns (address) {
		(stock, money) = stock < money ? (stock, money) : (money, stock);
		bytes memory bytecode = type(GridexProxy).creationCode;
		(uint stock_priceDiv, uint money_priceMul) = getParams(stock, money);
		bytes32 codeHash = keccak256(abi.encodePacked(bytecode, abi.encode(
			stock_priceDiv, money_priceMul, impl)));
		bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(0), codeHash));
		return address(uint160(uint(hash)));
	}

	function getParams(address stock, address money) private view returns (uint stock_priceDiv, uint money_priceMul) {
		(stock, money) = stock < money ? (stock, money) : (money, stock);
		uint stockDecimals = stock == SEP206Contract ? 18 : IERC20Metadata(stock).decimals();
		uint moneyDecimals = money == SEP206Contract ? 18 : IERC20Metadata(money).decimals();
		uint priceMul = 1;
		uint priceDiv = 1;
		if(moneyDecimals >= stockDecimals) {
			priceMul = (10**(moneyDecimals - stockDecimals));
		} else {
			priceDiv = (10**(stockDecimals - moneyDecimals));
		}
		stock_priceDiv = (uint(uint160(stock))<<96)|priceDiv;
		money_priceMul = (uint(uint160(money))<<96)|priceMul;
	}

	function create(address stock, address money, address impl) external {
		(uint stock_priceDiv, uint money_priceMul) = getParams(stock, money);
		address pairAddr = address(new GridexProxy{salt: 0}(stock_priceDiv, money_priceMul, impl));
		emit Created(stock, money, impl, pairAddr);
	}

	function setFee(address stock, address money, address impl, uint fee) external onlyOwner {
		address pair = getAddress(stock, money, impl);
		GridexLogicAbstract(pair).setFee(fee);
	}
}
