// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.15;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
// import "hardhat/console.sol";

// GridexLogic256 can support the price range from 1/(2**32) to 2**32. The prices within this range is divided to 16384 grids,
// and the ratio between a pair of adjacent prices is alpha=2**(1/256.)=1.0027112750502025
// A bancor-style market-making pool can be created between a pair of adjacent prices, i.e. priceHi and priceLo.
// Theoretically, there can be 16383 pools. But in pratice, only a few pools with reasonable prices exist.
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
// of all the accounts' shares. Shares are like Uniswap-V2's liquidity token. But they are implemented as ERC1155 here,
// instead of ERC20.

contract GridexLogicBase{
	uint public stock_priceDiv;
	uint public money_fee_priceMul;
	address internal factoryAddress;
}

abstract contract GridexLogicAbstract is GridexLogicBase, ERC1155(""){
	struct Pool {
		uint96 totalShares;
		uint96 totalStock;
		uint64 soldRatio;
	}

	struct PoolWithMyShares {
		uint96 totalShares;
		uint96 totalStock;
		uint64 soldRatio;
		uint256 myShares;
	}

	struct Params {
		address stock;
		address money;
		uint priceDiv;
		uint priceMul;
		uint fee;
	}

	address constant private SEP206Contract = address(uint160(0x2711));
	uint constant internal GridCount = 64*256;
	uint constant internal MaskWordCount = 64;
	uint constant internal RatioBase = 10**19; // need 64 bits
	uint constant internal PriceBase = 2**68;
	uint constant internal MASK16 = (1<<16)-1;
	uint constant internal FeeBase = 10000;
	uint constant internal LargeAmount = 1<<95;

	Pool[GridCount] public pools;
	uint[MaskWordCount] internal maskWords;

	event Buy(address operator, uint totalPaidMoney, uint totalGotStock);
	event Sell(address operator, uint totalGotMoney, uint totalSoldStock);

	function grid2price(uint grid) public pure virtual returns (uint);
	function price2Grid(uint price) pure external virtual returns (uint);
	function getMaskWords() view external virtual returns (uint[] memory masks);
	function init(address _factoryAddress) virtual external;

	// Use binary search to find a grid number n, such that grid2price(n) <= price < grid2price(n+1)
	function findGrid(uint maxGrid, uint price) pure internal returns (uint n) {
		(uint i, uint j) = (0, maxGrid);
		while(i<j) {
			uint h = (i+j)>>1;
			if(grid2price(h) < price) {
				i = h + 1;
			} else {
				j = h;
			}
		}
		if(grid2price(i) > price) i--;
		return i;
	}
	
	function setFee(uint _fee) public {
		require(msg.sender == factoryAddress, 'only factoryAddress');
		require(_fee <= (FeeBase/10), 'too large');
		uint mask = 0xFFFFFFFF<<64;
		money_fee_priceMul = (money_fee_priceMul&~mask) | (_fee<<64);
	}

	function getPoolAndMyShares(uint start, uint end) view external returns (PoolWithMyShares[] memory arr) {
		arr = new PoolWithMyShares[](end-start);
		for(uint i=start; i<end; i++) {
			Pool memory pool = pools[i];
			uint j = i-start;
			arr[j].totalShares = pool.totalShares;
			arr[j].totalStock = pool.totalStock;
			arr[j].soldRatio = pool.soldRatio;
			arr[j].myShares = balanceOf(msg.sender, i);
		}
	}

	function loadParams() view public returns (Params memory params) {
		(params.stock, params.priceDiv) = (address(uint160(stock_priceDiv>>96)), uint64(stock_priceDiv));
		(params.money, params.fee, params.priceMul) = (
			address(uint160(money_fee_priceMul>>96)), uint32(money_fee_priceMul>>64), uint64(money_fee_priceMul));
	}

	function safeTransfer(address coinType, address receiver, uint amount) private {
		if(amount == 0) {
			return;
		}
		SafeERC20.safeTransfer(IERC20(coinType), receiver, amount);
	}

	function safeReceive(address coinType, uint amount, bool bchExclusive) private {
		if(amount == 0) {
			return;
		}
		if(coinType == SEP206Contract) {
			require(msg.value == amount, "value-mismatch");
		} else {
			require(!bchExclusive || msg.value == 0, "dont-send-bch");
			SafeERC20.safeTransferFrom(IERC20(coinType), msg.sender, address(this), amount);
		}
	}

	function calcPrice(
		uint priceLo,
		uint priceHi,
		uint64 soldRatio
	) public pure returns(uint price) {
 		price = (priceHi*uint(soldRatio) + priceLo*(RatioBase-uint(soldRatio)))/RatioBase;
	}

	function calcPool(
		uint priceDiv,
		uint priceLo,
		uint priceHi,
		uint96 totalStock,
		uint64 soldRatio
	) public pure returns(uint leftStock, uint soldStock, uint gotMoney) {
		soldStock = uint(totalStock)*uint(soldRatio)/RatioBase;
		leftStock = uint(totalStock)-soldStock;
		uint price = calcPrice(priceLo, priceHi, soldRatio);
		gotMoney = soldStock*(price+priceLo)/(2*PriceBase*priceDiv);
	}

	function initPool(uint grid, uint totalStock, uint soldRatio) public payable returns (uint leftStock, uint gotMoney) {
		require(soldRatio<=RatioBase, "invalid-ratio");
		Pool memory pool = pools[grid];
		require(pool.totalShares==0, "already created");
		pool.totalStock = uint96(totalStock);
		pool.totalShares = uint96(totalStock);
		pool.soldRatio = uint64(soldRatio);
		Params memory p = loadParams();
		uint priceLo = grid2price(grid) * p.priceMul;
		uint priceHi = grid2price(grid+1) * p.priceMul;
		(leftStock, ,gotMoney) = calcPool(p.priceDiv,priceLo,priceHi,pool.totalStock,pool.soldRatio);
		_mint(msg.sender, grid, pool.totalShares, "");
		pools[grid] = pool;
		bool bchExclusive = p.stock != SEP206Contract && p.money != SEP206Contract;
		safeReceive(p.stock, leftStock, bchExclusive);
		safeReceive(p.money, gotMoney, bchExclusive);
		(uint wordIdx, uint bitIdx) = (grid/256, grid%256);
		maskWords[wordIdx] |= (uint(1)<<bitIdx); // set bit
	}

	function arbitrageAndBatchChangeShares(uint lowGrid, uint midGrid, uint highGrid,
	                         uint grid, int160[] calldata sharesDelta, uint maxStock, uint maxMoney) public 
	                         payable returns (int paidStock, int paidMoney) {
		(int totalGotStock, int totalGotMoney) = arbitrage(lowGrid, midGrid, highGrid);
		maxStock = uint(int(maxStock)+totalGotStock);
		maxMoney = uint(int(maxMoney)+totalGotMoney);
		(paidStock, paidMoney) = batchChangeShares(grid, sharesDelta, maxStock, maxMoney);
		paidStock -= totalGotStock;
		paidMoney -= totalGotMoney;
	}

	function batchChangeShares(uint startGrid, int160[] calldata sharesDelta, uint maxStock, uint maxMoney) public 
	                                                       payable returns (int paidStock, int paidMoney) {
		for(uint i=0; i<sharesDelta.length; i++) {
			(int s, int m) = changeShares(startGrid+i, sharesDelta[i]);
			paidStock += s;
			paidMoney += m;
		}
		require(paidStock <= int(maxStock), "too-much-stock-paid");
		require(paidMoney <= int(maxMoney), "too-much-money-paid");
	}

	function changeShares(uint grid, int160 sharesDelta) public payable returns (int, int) {
		uint soldRatio = uint64(uint160(sharesDelta)); // encode soldRatio in the lowest 64 bits
		sharesDelta >>= 64; //remove the soldRatio
		if (sharesDelta == 0) {
			return (0,0);
		}

		Pool memory pool = pools[grid];
		if(pool.totalShares == 0) {
			require(sharesDelta > 0, "pool-not-init");
			(uint leftStock, uint gotMoney) = initPool(grid, uint(int(sharesDelta)), soldRatio);
			return (int(leftStock), int(gotMoney));
		}
		uint96 totalStockOld = pool.totalStock;
		if(sharesDelta>0) {
			pool.totalStock += uint96(uint(pool.totalStock)*uint(int(sharesDelta))/uint(pool.totalShares));
			pool.totalShares += uint96(int96(sharesDelta));
			_mint(msg.sender, grid, uint96(int96(sharesDelta)), "");
			pools[grid] = pool;
		} else {
			pool.totalStock -= uint96(uint(pool.totalStock)*uint(int(-sharesDelta))/uint(pool.totalShares));
			pool.totalShares -= uint96(int96(-sharesDelta));
			_burn(msg.sender, grid, uint96(int96(-sharesDelta)));
			if(pool.totalShares == 0) {
				(uint wordIdx, uint bitIdx) = (grid/256, grid%256);
				maskWords[wordIdx] &= ~(uint(1)<<bitIdx); // clear bit
				delete pools[grid];
			} else {
				pools[grid] = pool;
			}
		}
		Params memory p = loadParams();
		int leftStockDelta;
		int gotMoneyDelta;
		{ // to avoid "CompilerError: Stack too deep."
		uint priceLo = grid2price(grid) * p.priceMul;
		uint priceHi = grid2price(grid+1) * p.priceMul;
		(uint leftStockOld,, uint gotMoneyOld) = calcPool(p.priceDiv, priceLo, priceHi, totalStockOld, pool.soldRatio);
		(uint leftStockNew,,uint gotMoneyNew) = calcPool(p.priceDiv, priceLo, priceHi, pool.totalStock, pool.soldRatio);
		leftStockDelta = int(leftStockNew)-int(leftStockOld);
		gotMoneyDelta = int(gotMoneyNew)-int(gotMoneyOld);	     		             
		}

		bool bchExclusive = p.stock != SEP206Contract && p.money != SEP206Contract;
		if(sharesDelta>0) {
			safeReceive(p.stock, uint(leftStockDelta), bchExclusive);
			safeReceive(p.money, uint(gotMoneyDelta), bchExclusive);
		} else {
			safeTransfer(p.stock, msg.sender, uint(-leftStockDelta));
			safeTransfer(p.money, msg.sender, uint(-gotMoneyDelta));
		}
		return (leftStockDelta, gotMoneyDelta);
	}

	function buyFromPools(uint maxAveragePrice, uint stockToBuy, uint grid, uint stopGrid) external payable 
								returns (uint totalPaidMoney, uint totalGotStock) {
		Params memory p = loadParams();
		uint fee_m_d = (p.fee<<128)|(p.priceMul<<64)|p.priceDiv;
		(totalPaidMoney, totalGotStock) = _buyFromPools(stockToBuy, grid, stopGrid, fee_m_d);
		require(totalPaidMoney*PriceBase*p.priceDiv <= totalGotStock*maxAveragePrice*p.priceMul, "price-too-high");
		safeReceive(p.money, totalPaidMoney, p.money != SEP206Contract);
		safeTransfer(p.stock, msg.sender, totalGotStock);
	}

	function _buyFromPools(uint stockToBuy, uint grid, uint stopGrid, uint fee_m_d) private
								returns (uint totalPaidMoney, uint totalGotStock) {
		(totalPaidMoney, totalGotStock) = (0, 0);
		uint priceHi = grid2price(grid)*uint64(fee_m_d>>64);
		for(; stockToBuy != 0 && grid < stopGrid; grid++) {
			uint priceLo = priceHi;
			priceHi = grid2price(grid+1)*uint64(fee_m_d>>64);
			Pool memory pool = pools[grid];
			if(pool.totalStock == 0 || pool.soldRatio == RatioBase) { // cannot deal
				continue;
			}
			(uint leftStockOld, uint soldStockOld, uint gotMoneyOld) = calcPool(uint64(fee_m_d), priceLo, priceHi, pool.totalStock, pool.soldRatio);
			if(stockToBuy >= leftStockOld) { // buy all in pool
				uint price = calcPrice(priceLo, priceHi, pool.soldRatio);
				uint gotMoneyNew = gotMoneyOld+
				    /*MoneyIncr:*/ leftStockOld*(price+priceHi)*(FeeBase+(fee_m_d>>128))/
				                           (2*PriceBase*FeeBase*uint64(fee_m_d)); //fee in money
				uint totalStock = 1/*for rounding error*/+gotMoneyNew*2*PriceBase*uint64(fee_m_d)/
					                                     (priceHi+priceLo);
				pool.soldRatio = uint64(RatioBase);
				pool.totalStock = uint96(totalStock);
				(,, gotMoneyNew) = calcPool(uint64(fee_m_d), priceLo, priceHi, pool.totalStock, pool.soldRatio);
				stockToBuy -= leftStockOld;
				totalGotStock += leftStockOld;
				totalPaidMoney += gotMoneyNew-gotMoneyOld;
			} else { // cannot buy all in pool
				uint stockFee = stockToBuy*(fee_m_d>>128)/FeeBase; //fee in stock
				pool.totalStock += uint96(stockFee);
				uint soldStockNew = soldStockOld+stockToBuy;
				pool.soldRatio = uint64(RatioBase*soldStockNew/pool.totalStock);
				uint leftStockNew; // ≈ totalStockOld+stockFee-soldStockOld-stockToBuy
				uint gotMoneyNew;
				(leftStockNew, soldStockNew, gotMoneyNew) = calcPool(uint64(fee_m_d), priceLo, priceHi, pool.totalStock, pool.soldRatio);
				totalGotStock += leftStockOld-leftStockNew; //≈ stockToBuy-stockFee
				totalPaidMoney += gotMoneyNew-gotMoneyOld;
				stockToBuy = 0;
			}
			pools[grid] = pool;
		}
		emit Buy(msg.sender, totalPaidMoney, totalGotStock);
	}

	function sellToPools(uint minAveragePrice, uint stockToSell, uint grid, uint stopGrid) external payable 
								returns (uint totalGotMoney, uint totalSoldStock) {
		Params memory p = loadParams();
		uint fee_m_d = (p.fee<<128)|(p.priceMul<<64)|p.priceDiv;
		(totalGotMoney, totalSoldStock) = _sellToPools(stockToSell, grid, stopGrid, fee_m_d);
		require(totalSoldStock*minAveragePrice*p.priceMul <= totalGotMoney*PriceBase*p.priceDiv, "price-too-low");
		safeReceive(p.stock, totalSoldStock, p.stock != SEP206Contract);
		safeTransfer(p.money, msg.sender, totalGotMoney);
	}

	function _sellToPools(uint stockToSell, uint grid, uint stopGrid, uint fee_m_d) private
								returns (uint totalGotMoney, uint totalSoldStock) {
		(totalGotMoney, totalSoldStock) = (0, 0);
		uint priceLo = grid2price(grid+1)*uint64(fee_m_d>>64);
		for(; stockToSell != 0 && grid>stopGrid; grid--) {
			uint priceHi = priceLo;
			priceLo = grid2price(grid)*uint64(fee_m_d>>64);
			Pool memory pool = pools[grid];
			if(pool.totalStock == 0 || pool.soldRatio == 0) { // cannot deal
				continue;
			}
			(uint leftStockOld, uint soldStockOld, uint gotMoneyOld) = calcPool(uint64(fee_m_d), priceLo, priceHi, pool.totalStock, pool.soldRatio);
			uint stockFee = soldStockOld*(fee_m_d>>128)/FeeBase;
			uint soldStockOldAndFee = soldStockOld+stockFee;
			if(stockToSell >= soldStockOldAndFee) { // get all money all in pool
				pool.soldRatio = 0;
				pool.totalStock += uint96(stockFee); // fee in stock
				stockToSell -= soldStockOldAndFee;
				totalSoldStock += soldStockOldAndFee;
				totalGotMoney += gotMoneyOld;
			} else { // cannot get all money all in pool
				stockFee = stockToSell*(fee_m_d>>128)/FeeBase;
				pool.totalStock += uint96(stockFee); // fee in stock
				{ // to avoid "CompilerError: Stack too deep."
				uint soldStockNew = soldStockOld+stockFee-stockToSell;
				pool.soldRatio = uint64(1/*for rounding error*/+RatioBase*soldStockNew/pool.totalStock);
				(uint leftStockNew,, uint gotMoneyNew) = calcPool(uint64(fee_m_d), priceLo, priceHi, pool.totalStock, pool.soldRatio);
				totalSoldStock += leftStockNew-leftStockOld; //≈ stockToSell
				totalGotMoney += gotMoneyOld-gotMoneyNew;
				}
				stockToSell = 0;
			}
			pools[grid] = pool;
		}
		emit Sell(msg.sender, totalGotMoney, totalSoldStock);
	}

	function arbitrage(uint lowGrid, uint midGrid, uint highGrid) public 
					returns (int, int) {
		Params memory params = loadParams();
		uint fee_m_d = (params.priceMul<<64)|params.priceDiv; // zero fee
		(uint paidMoney, uint gotStock) = _buyFromPools(LargeAmount, lowGrid, midGrid, fee_m_d);
		(uint gotMoney, uint soldStock) = _sellToPools(LargeAmount, highGrid,  midGrid, fee_m_d);
		if(soldStock > gotStock && paidMoney < gotMoney) {
			(uint m, uint s) = _buyFromPools(soldStock-gotStock, midGrid, midGrid+1, fee_m_d);
			gotStock += s;
			paidMoney += m;
		}
		if(paidMoney > gotMoney && soldStock < gotStock) {
			(uint m, uint s) = _sellToPools(gotStock-soldStock, midGrid,  midGrid-1, fee_m_d);
			gotMoney += m;
			soldStock += s;
		}
		int totalGotStock = int(gotStock) - int(soldStock);
		int totalGotMoney = int(gotMoney) - int(paidMoney);
		transferTokens(params.stock, totalGotStock, params.money, totalGotMoney);
		return (totalGotStock, totalGotMoney);
	}

	function batchTrade(uint[] calldata sellArgs, uint[] calldata buyArgs) external payable returns (int totalGotStock, int totalGotMoney) {
		Params memory p = loadParams();
		uint fee_m_d = (p.fee<<128)|(p.priceMul<<64)|p.priceDiv;
		for(uint i=0; i<buyArgs.length; i++) {
			uint b = buyArgs[i];
			uint stockToBuy = b>>32;
			uint grid = (b>>16) & 0xFFFF;
			uint stopGrid = b & 0xFFFF;
			(uint paidMoney, uint gotStock) = _buyFromPools(stockToBuy, grid, stopGrid, fee_m_d);
			totalGotStock += int(gotStock);
			totalGotMoney -= int(paidMoney);
		}
		for(uint i=0; i<sellArgs.length; i++) {
			uint s = sellArgs[i];
			uint stockToSell = s>>32;
			uint grid = (s>>16) & 0xFFFF;
			uint stopGrid = s & 0xFFFF;
			(uint gotMoney, uint soldStock) = _sellToPools(stockToSell, grid, stopGrid, fee_m_d);
			totalGotStock -= int(soldStock);
			totalGotMoney += int(gotMoney);
		}
		transferTokens(p.stock, totalGotStock, p.money, totalGotMoney);
	}

	function transferTokens(address stock, int stockAmount, address money, int moneyAmount) private {
		if(stockAmount>0){
			safeTransfer(stock, msg.sender, uint(stockAmount));
		}else {
			safeReceive(stock, uint(-stockAmount), stock != SEP206Contract);
		}
		if(moneyAmount>0){
			safeTransfer(money, msg.sender, uint(moneyAmount));
		}else {
			safeReceive(money, uint(-moneyAmount), money != SEP206Contract);
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
	uint constant X = (uint(1048576-1048576)<< 0*16)| // extractNthU16(X, 0)==Math.pow(2,20)*(Math.pow(alpha,0) -1)
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
	uint constant Y = (uint(65536 -65536)<<( 0*16))| //extractNthU16(Y, 0)==Math.pow(2,16)*(Math.pow(alpha,16*0) -1) 
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

	function init(address _factoryAddress) override external {
		require(factoryAddress==address(0), "already init");
		factoryAddress = _factoryAddress;
		setFee(5);
	}

	function grid2price(uint grid) public pure override returns (uint) {
		require(grid < GridCount, "invalid-grid");
		(uint head, uint tail) = (grid/256, grid%256);
		uint x = extractNthU16(X, tail%16);
		uint y = extractNthU16(Y, tail/16);
		uint beforeShift = ((1<<20)+x) * ((1<<16)+y); // = Math.pow(alpha, tail) * Math.pow(2, 36)
		return beforeShift<<head;
	}

	function price2Grid(uint price) pure external override returns (uint){
		return findGrid(GridCount, price);
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
	uint constant X = (uint(524288-524288)<< 0*16)| // extractNthU16(X, 0)==Math.pow(2,19)*(Math.pow(alpha,0) -1)
	                  (uint(529997-524288)<< 1*16)| // extractNthU16(X, 1)==Math.pow(2,19)*(Math.pow(alpha,1) -1)
	                  (uint(535768-524288)<< 2*16)| // extractNthU16(X, 2)==Math.pow(2,19)*(Math.pow(alpha,2) -1)
	                  (uint(541603-524288)<< 3*16)| // extractNthU16(X, 3)==Math.pow(2,19)*(Math.pow(alpha,3) -1)
	                  (uint(547500-524288)<< 4*16)| // extractNthU16(X, 4)==Math.pow(2,19)*(Math.pow(alpha,4) -1)
	                  (uint(553462-524288)<< 5*16)| // extractNthU16(X, 5)==Math.pow(2,19)*(Math.pow(alpha,5) -1)
	                  (uint(559489-524288)<< 6*16)| // extractNthU16(X, 6)==Math.pow(2,19)*(Math.pow(alpha,6) -1)
	                  (uint(565581-524288)<< 7*16); // extractNthU16(X, 7)==Math.pow(2,19)*(Math.pow(alpha,7) -1)

	// for(var i=0; i<8; i++) {console.log(Math.round( Math.pow(2,16) * Math.pow(alpha, i*8)))}
	uint constant Y = (uint(65536 -65536)<< 0*16)| // extractNthU16(Y, 0)==Math.pow(2,16)*(Math.pow(alpha,8*0) -1)
	                  (uint(71468 -65536)<< 1*16)| // extractNthU16(Y, 1)==Math.pow(2,16)*(Math.pow(alpha,8*1) -1)
	                  (uint(77936 -65536)<< 2*16)| // extractNthU16(Y, 2)==Math.pow(2,16)*(Math.pow(alpha,8*2) -1)
	                  (uint(84990 -65536)<< 3*16)| // extractNthU16(Y, 3)==Math.pow(2,16)*(Math.pow(alpha,8*3) -1)
	                  (uint(92682 -65536)<< 4*16)| // extractNthU16(Y, 4)==Math.pow(2,16)*(Math.pow(alpha,8*4) -1)
	                  (uint(101070-65536)<< 5*16)| // extractNthU16(Y, 5)==Math.pow(2,16)*(Math.pow(alpha,8*5) -1)
	                  (uint(110218-65536)<< 6*16)| // extractNthU16(Y, 6)==Math.pow(2,16)*(Math.pow(alpha,8*6) -1)
	                  (uint(120194-65536)<< 7*16); // extractNthU16(Y, 7)==Math.pow(2,16)*(Math.pow(alpha,8*7) -1)

	function init(address _factoryAddress) override external {
		require(factoryAddress==address(0), "already init");
		factoryAddress = _factoryAddress;
		setFee(10);
	}

	function grid2price(uint grid) public pure override returns (uint) {
		require(grid < GridCount/4, "invalid-grid");
		(uint head, uint tail) = (grid/64, grid%64);
		uint x = extractNthU16(X, tail%8);
		uint y = extractNthU16(Y, tail/8);
		uint beforeShift = ((1<<19)+x) * ((1<<16)+y); // = Math.pow(alpha, tail) * Math.pow(2, 35)
		return beforeShift<<(1+head);
	}

	function price2Grid(uint price) pure external override returns (uint){
		return findGrid(GridCount/4, price);
	}

	function getMaskWords() view external override returns (uint[] memory masks) {
		masks = new uint[](MaskWordCount/4);
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

	function init(address _factoryAddress) override external {
		require(factoryAddress==address(0), "already init");
		factoryAddress = _factoryAddress;
		setFee(30);
	}

	function grid2price(uint grid) public pure override returns (uint) {
		require(grid < GridCount/16, "invalid-grid");
		(uint head, uint tail) = (grid/16, grid%16);
		uint x = extractNthU16(X, tail);
		uint beforeShift = ((1<<16)+x); // = Math.pow(alpha, tail) * Math.pow(2, 16)
		return beforeShift<<(20+head);
	}

	function price2Grid(uint price) pure external override returns (uint){
		return findGrid(GridCount/16, price);
	}

	function getMaskWords() view external override returns (uint[] memory masks) {
		masks = new uint[](MaskWordCount/16);
		for(uint i=0; i < masks.length; i++) {
			masks[i] = maskWords[i];
		}
	}
}

contract GridexProxy {
	uint public stock_priceDiv;
	uint public money_fee_priceMul;
	uint immutable public implAddr;
	
	constructor(uint _stock_priceDiv, uint _money_fee_priceMul, address _impl) {
		stock_priceDiv = _stock_priceDiv;
		money_fee_priceMul = _money_fee_priceMul;
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
	mapping(address => mapping(address => mapping(address => address))) public getPair;

	event Created(address indexed stock, address indexed money, address indexed impl, address pairAddr);

	function getAddress(address stock, address money, address impl) public view returns (address) {
		bytes memory bytecode = type(GridexProxy).creationCode;
		(uint stock_priceDiv, uint money_fee_priceMul) = getParams(stock, money);
		bytes32 codeHash = keccak256(abi.encodePacked(bytecode, abi.encode(
			stock_priceDiv, money_fee_priceMul, impl)));
		bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(0), codeHash));
		return address(uint160(uint(hash)));
	}

	function getParams(address stock, address money) private view returns (uint stock_priceDiv, uint money_fee_priceMul) {
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
		money_fee_priceMul = (uint(uint160(money))<<96)|priceMul;
	}

	function create(address stock, address money, address impl) external returns(address) {
		require(getPair[stock][money][impl] == address(0), 'GridexFactory: PAIR_EXISTS');
		(uint stock_priceDiv, uint money_fee_priceMul) = getParams(stock, money);
		address pairAddr = address(new GridexProxy{salt: 0}(stock_priceDiv, money_fee_priceMul, impl));
		GridexLogicAbstract(pairAddr).init(address(this));
		getPair[stock][money][impl] = pairAddr;
		emit Created(stock, money, impl, pairAddr);
		return pairAddr;
	}

	function setFee(address stock, address money, address impl, uint fee) external onlyOwner {
		address pair = getPair[stock][money][impl];
		GridexLogicAbstract(pair).setFee(fee);
	}
}
