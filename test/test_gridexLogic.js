const { expect } = require("chai");
const { ethers } = require("hardhat");
const BigNumber = require('bignumber.js')
const { createERC20 } = require("./utils/util")
const { getResult } = require("./utils/price_util")

const RatioBase = BigNumber(10 ** 19)
const PriceBase = BigNumber(2 ** 68)
const FeeBase = 10000;

const gridexTypes = [16, 64, 256] // [16, 64, 256]
const decimalsArr = [[18, 18], [10, 18], [18, 15]]// [[18, 18], [10, 18], [18, 15]]

gridexTypes.forEach((gridexType, gridexTypeIndex) => {
  describe(`gridexLogic${gridexType} decimals:${decimalsArr[gridexTypeIndex]}`, function () {
    let owner;
    let stock;
    let money;
    let params;
    let gridexLogic;
    let fee;
    let gridexUtil;
    let arbitrageUtil;
    let sharesUtil;


    const { grid2price, price2grid } = getResult(gridexType)

    before(async function () {
      [owner] = await ethers.getSigners();
      const MaxAmount = ethers.utils.parseUnits("1", 50)
      stock = await createERC20(ethers, "stockName", "stockSymbol", [{ address: owner.address, amount: MaxAmount }], decimalsArr[gridexTypeIndex][0]);
      money = await createERC20(ethers, "moneyName", "moneySymbol", [{ address: owner.address, amount: MaxAmount }], decimalsArr[gridexTypeIndex][1]);
      const GridexLogic = await ethers.getContractFactory(`GridexLogic${gridexType}`);
      gridexLogic = await GridexLogic.deploy();
      const GridexFactory = await ethers.getContractFactory("GridexFactory");
      const gridexFactory = await GridexFactory.deploy();
      await gridexFactory.create(stock.address, money.address, gridexLogic.address)
      const gridexLogicAddress = await gridexFactory.getAddress(stock.address, money.address, gridexLogic.address)
      gridexLogic = await GridexLogic.attach(gridexLogicAddress)
      params = await gridexLogic.loadParams();
      fee = params.fee.toNumber()
      params = {
        ...params,
        priceMul: params.priceMul.toString(),
        priceDiv: params.priceDiv.toString(),
      }
      stock.approve(gridexLogicAddress, MaxAmount)
      money.approve(gridexLogicAddress, MaxAmount)

      gridexUtil = await (await ethers.getContractFactory(`GridexUtil`)).deploy();
      arbitrageUtil = await (await ethers.getContractFactory(`ArbitrageUtil`)).deploy(); //{ libraries: { GridexUtil: gridexUtil.address } }
      sharesUtil = await (await ethers.getContractFactory(`SharesUtil`)).deploy();
    })

    it("changeShares", async function () {
      await expect(gridexLogic.changeShares(100, BigNumber(-1).times(2 ** 64).plus(0).toFixed(0))).to.be.revertedWith("pool-not-init")

      const maxGrid = 64 * 256 / ({ 16: 16, 64: 4, 256: 1 }[gridexType])
      const grids = [0, 785, maxGrid - 2]//[0, 785, maxGrid]
      for (let grid of grids) {
        const sharesDeltas = ["1000000000000000", "22222", "444444444444", "200000000000000", "-423543636456", "-300000000000000"]
        const fullRemove = sharesDeltas.reduce((x, y) => BigNumber(x).plus(BigNumber(y))).multipliedBy(-1).toFixed(0)
        sharesDeltas.push(fullRemove)
        const soldRatios = [0, RatioBase, RatioBase.dividedBy(2)]
        for (const soldRatio of soldRatios) {
          const sharesDeltaAndSoldRatios = sharesDeltas.map(sharesDelta => BigNumber(sharesDelta).times(BigNumber(2).pow(64)).plus(soldRatio))
          for (let [index, sharesDelta] of sharesDeltas.entries()) {
            const poolWithMyShare = (await gridexLogic.getPoolAndMyShares(grid, grid + 1))[0];
            const stockBalance0 = await stock.balanceOf(gridexLogic.address);
            const moneyBalance0 = await money.balanceOf(owner.address);
            const pool = await gridexLogic.pools(grid);
            let { leftStockDelta, gotMoneyDelta } = await sharesUtil.calcChangeShares(gridexLogic.address, await gridexLogic.loadParams(), grid, pool, sharesDeltaAndSoldRatios[index].toFixed(0))
            const promise = gridexLogic.changeShares(grid, sharesDeltaAndSoldRatios[index].toFixed(0))
            if (sharesDelta.indexOf('-') === 0) {
              await expect(promise).to.emit(gridexLogic, "TransferSingle").withArgs(owner.address, owner.address, "0x0000000000000000000000000000000000000000", grid, Math.abs(sharesDelta))
            } else {
              await expect(promise).to.emit(gridexLogic, "TransferSingle").withArgs(owner.address, "0x0000000000000000000000000000000000000000", owner.address, grid, Math.abs(sharesDelta))
            }
            let changedPoolWithMyShare = (await gridexLogic.getPoolAndMyShares(grid, grid + 1))[0];
            expect(changedPoolWithMyShare.totalShares).to.equal(poolWithMyShare.totalShares.add(sharesDelta))
            expect(changedPoolWithMyShare.myShares).to.equal(poolWithMyShare.myShares.add(sharesDelta))
            const stockBalance1 = await stock.balanceOf(gridexLogic.address);
            const moneyBalance1 = await money.balanceOf(owner.address);
            expect(stockBalance1.sub(stockBalance0)).to.equal(leftStockDelta)
            expect(moneyBalance0.sub(moneyBalance1)).to.equal(gotMoneyDelta)
            const wordIdx = parseInt(grid / 256)
            const bitIdx = grid % 256
            const maskWords = await gridexLogic.getMaskWords()
            if (index !== sharesDeltas.length - 1) {
              expect(maskWords[wordIdx].toString()).to.equal(BigNumber(2).pow(bitIdx).toFixed(0))
            } else if (index === sharesDeltas.length - 1) {
              expect(maskWords[wordIdx]).to.equal(0)
              // 最后应该移除完了
              const s = await stock.balanceOf(gridexLogic.address)
              const m = await money.balanceOf(gridexLogic.address)
              expect(s.toString()).to.equal("0")
              expect(m.toString()).to.equal("0")
            }
          }
        }
      }
    });

    const price = BigNumber(1700).multipliedBy(PriceBase) // 不考虑精度的price
    it("batchChangeShares", async function () {
      const stockAmount = ethers.utils.parseUnits("1", 12)
      const minPrice = PriceBase.multipliedBy(1550)
      const maxPrice = PriceBase.multipliedBy(1800)
      let { deltaMoney, minGrid, sharesDeltas } = await sharesUtil.getSharesResult(gridexLogic.address, await gridexLogic.loadParams(), [minPrice.toFixed(0), price.toFixed(0), maxPrice.toFixed(0)], stockAmount)
      minGrid = minGrid.toNumber()
      const pools1 = await getPools(minGrid, sharesDeltas.length)
      await gridexLogic.batchChangeShares(minGrid, sharesDeltas, stockAmount, deltaMoney)
      const pools2 = await getPools(minGrid, sharesDeltas.length)
      pools2.forEach((pool, index) => {
        const sharesDeltaAndSoldRatio = BigNumber(sharesDeltas[index].toString())
        const soldRatio = sharesDeltaAndSoldRatio.mod(BigNumber(2).pow(64)).toFixed(0)
        const shareDelta = sharesDeltaAndSoldRatio.minus(soldRatio).dividedBy(BigNumber(2).pow(64)).toFixed(0)
        expect(pool.totalShares.toString()).to.equal(pools1[index].totalShares.add(shareDelta).toString())
        expect(pool.soldRatio.toString()).to.equal(soldRatio)
      })

      await expect(gridexLogic.batchChangeShares(minGrid, sharesDeltas, stockAmount, 0)).to.be.revertedWith("too-much-money-paid")
      await expect(gridexLogic.batchChangeShares(minGrid, sharesDeltas, 0, deltaMoney)).to.be.revertedWith("too-much-stock-paid")
    });

    it("initPool", async function () {
      const { prices, pools, grid } = await getGridexTradeResult(false, price);
      await expect(gridexLogic.initPool(grid, 1, RatioBase.plus(100).toFixed(0))).to.be.revertedWith("invalid-ratio")
      await expect(gridexLogic.initPool(grid, 1, 0)).to.be.revertedWith("already created")
    })

    it("arbitrage", async function () {
      const { prices, pools, grid } = await getGridexTradeResult(false, price);
      const sharesDelta = BigNumber(100000 * Math.random().toFixed(5)).times(BigNumber(2).pow(64)).plus(RatioBase.dividedBy(2)).toFixed(0)
      const changedGrids = [grid, grid - 5, grid + 5] // [grid, grid - 5, grid + 5]
      for (let i = 0; i < changedGrids.length; i++) {
        const changedGrid = changedGrids[i];
        const pool = await gridexLogic.pools(changedGrid)

        if (pool.totalShares == 0) {
          await gridexLogic.changeShares(changedGrid, sharesDelta);
        } else if (pool.soldRatio.eq(0)) {
          await gridexLogic.buyFromPools(ethers.utils.parseUnits("1", 50), 1000, changedGrid, changedGrid + 1)
        } else {
          await gridexLogic.sellToPools(0, 1000, changedGrid, changedGrid - 1)
        }
        const stockBalance0 = await stock.balanceOf(owner.address);
        const moneyBalance0 = await money.balanceOf(owner.address);
        const result = await arbitrageUtil.getArbitrageResult(gridexLogic.address, grid);
        if (changedGrid === grid) {
          expect(result[3]).to.equal(0);
          expect(result[4]).to.equal(0);
        }
        await gridexLogic.arbitrage(result[0], result[1], result[2])
        const stockBalance1 = await stock.balanceOf(owner.address);
        const moneyBalance1 = await money.balanceOf(owner.address);
        expect(stockBalance1.sub(stockBalance0)).to.equal(result[3])
        expect(moneyBalance1.sub(moneyBalance0)).to.equal(result[4])
        for (let index = 0; index < result[2] - result[0] + 1; index++) {
          const grid = result[0].add(index)
          const pool = await gridexLogic.pools(grid)
          if (pool.totalShares != 0 && grid < result[1]) {
            expect(pool.soldRatio.toString()).to.equal(RatioBase.toString())
          } else if (pool.totalShares != 0 && grid > result[1]) {
            expect(pool.soldRatio).to.equal(0)
          } else if (pool.totalShares != 0) {
            expect(pool.soldRatio.toString()).not.equals(["0", RatioBase.toString()])
          }
        }
      }
    });

    it("arbitrageAndBatchChangeShares", async function () {
      const { prices, pools, grid } = await getGridexTradeResult(false, price);
      await gridexLogic.sellToPools(0, 100, grid - 2, grid - 2 - 1)
      await gridexLogic.buyFromPools(BigNumber(PriceBase).pow(2).toFixed(0), 100, grid + 2, grid + 2 + 1)
      const sharesDelta = BigNumber(1000).times(BigNumber(2).pow(64)).plus(RatioBase.dividedBy(2)).toFixed(0)
      await gridexLogic.changeShares(grid + 100, sharesDelta);
      await gridexLogic.changeShares(grid - 100, sharesDelta);
      const result = await arbitrageUtil.getArbitrageResult(gridexLogic.address, grid);
      const stockAmount = "100000"
      const minPrice = PriceBase.multipliedBy(1600)
      const maxPrice = PriceBase.multipliedBy(1800)
      let { deltaMoney, minGrid, sharesDeltas } = await sharesUtil.getSharesResult(gridexLogic.address, await gridexLogic.loadParams(), [minPrice.toFixed(0), price.toFixed(0), maxPrice.toFixed(0)], stockAmount)
      minGrid = minGrid.toNumber()
      await gridexLogic.arbitrageAndBatchChangeShares(result[0], result[1], result[2], minGrid, sharesDeltas, stockAmount, deltaMoney)
      // 移除掉方便后续测试，否则后面会测试不通过
      await gridexLogic.changeShares(grid + 100, BigNumber(-1000).times(BigNumber(2).pow(64)).toFixed(0));
      await gridexLogic.changeShares(grid - 100, BigNumber(-1000).times(BigNumber(2).pow(64)).toFixed(0));
    });

    it("batchTrade", async function () {
      const stockBalance0 = await stock.balanceOf(owner.address);
      const moneyBalance0 = await money.balanceOf(owner.address);
      const amounts = [1000, 100, 10000]
      const finalSellAmount = 1000
      const { prices, pools, grid } = await getGridexTradeResult(true, price);
      const finalResult = await gridexUtil.getSellToPoolsResult(prices, pools, finalSellAmount, await gridexUtil.getFee_m_d(gridexLogic.address, 0))
      const buyArgs = amounts.map(amount => BigNumber(amount).times(BigNumber(2).pow(32)).plus(BigNumber(grid).times(BigNumber(2).pow(16))).plus(grid + 20)).map(v => v.toFixed(0))
      const sellArgs = amounts.reverse().concat(finalSellAmount).map(amount => BigNumber(amount).times(BigNumber(2).pow(32)).plus(BigNumber(grid).times(BigNumber(2).pow(16))).plus(grid - 20)).map(v => v.toFixed(0))
      await gridexLogic.batchTrade(sellArgs, buyArgs);
      const stockBalance1 = await stock.balanceOf(owner.address);
      const moneyBalance1 = await money.balanceOf(owner.address);
      const price0Mul = finalResult.totalGotMoney.mul(1000).div(finalResult.totalSoldStock)
      const price1Mul = moneyBalance1.sub(moneyBalance0).mul(1000).div(stockBalance0.sub(stockBalance1))
      const totalAmount = amounts.concat(amounts).concat(finalSellAmount).reduce((x, y) => x + y);
      const totalFee = Math.round(totalAmount * fee / FeeBase);
      expect((price0Mul - price1Mul) / price1Mul).to.be.above(totalFee / finalSellAmount * 0.8).below(totalFee / finalSellAmount * 1.1)
    });

    it("buyFromPools", async function () {
      const { prices, pools, grid } = await getGridexTradeResult(false, price);
      await expect(gridexLogic.buyFromPools(0, 10000, grid, grid + 20)).to.be.revertedWith("price-too-high")

      const stockToBuies = [3000000, 500000000000, "18000000000000"].map(v => ethers.BigNumber.from(v))
      for (let i = 0; i < stockToBuies.length; i++) {
        const stockToBuy = stockToBuies[i];
        const stockBalance0 = await stock.balanceOf(gridexLogic.address);
        const moneyBalance0 = await money.balanceOf(owner.address);
        const { prices, pools, grid } = await getGridexTradeResult(false, price);
        const noFeeResult = await gridexUtil.getBuyFromPoolsResult(prices, pools, stockToBuy, await gridexUtil.getFee_m_d(gridexLogic.address, 0))
        const { totalPaidMoney, totalGotStock } = await gridexUtil.getBuyFromPoolsResult(prices, pools, stockToBuy, await gridexUtil.getFee_m_d(gridexLogic.address, fee))
        expect(totalPaidMoney.mul(FeeBase * 10).mul(FeeBase * 10).div(totalGotStock).div(noFeeResult.totalPaidMoney.mul(FeeBase * 10).div(noFeeResult.totalGotStock))).to.be.above(FeeBase * 10 + (0.9 * fee) * 10).most(FeeBase * 10 + (1.1 * fee) * 10)
        const dealPrice = PriceBase.multipliedBy(noFeeResult.totalPaidMoney.toString()).dividedBy(noFeeResult.totalGotStock.toString()).dividedBy(params.priceMul).multipliedBy(params.priceDiv)
        expect(dealPrice.toNumber()).to.be.least(grid2price(grid)).below(grid2price(grid + pools.length))
        const tx = await gridexLogic.buyFromPools(BigNumber(PriceBase).times(PriceBase).toFixed(0), stockToBuy, grid, grid + pools.length)
        let { events } = await tx.wait()
        events = events.splice(0, events.length - 3)
        let totalGotStockByEvent = ethers.BigNumber.from(0)
        let totalPaidMoneyByEvent = ethers.BigNumber.from(0)
        for (const { args, event } of events) {
          expect(event).to.equal("Buy")
          const { grid: eventGrid, operator, gotStock, paidMoney } = args
          expect(operator).to.equal(owner.address)
          expect(eventGrid).to.gte(grid).lte(grid + pools.length)
          totalGotStockByEvent = totalGotStockByEvent.add(gotStock)
          totalPaidMoneyByEvent = totalPaidMoneyByEvent.add(paidMoney)
        }
        expect(totalGotStockByEvent).to.equal(totalGotStock)
        expect(totalPaidMoneyByEvent).to.equal(totalPaidMoney)
        const stockBalance1 = await stock.balanceOf(gridexLogic.address);
        const moneyBalance1 = await money.balanceOf(owner.address);
        expect(stockBalance0.sub(stockBalance1)).to.equal(totalGotStock)
        expect(moneyBalance0.sub(moneyBalance1)).to.equal(totalPaidMoney)
        if (i != stockToBuies.length - 1) {
          expect(totalGotStock).to.above(stockToBuy.mul(1e2 - 1).div(1e2)).most(stockToBuy)
        }
        if (i == stockToBuies.length - 1 && gridexType != 256) { // 最后一把买光了
          const s = await stock.balanceOf(gridexLogic.address)
          expect(s.toString()).to.equal("0")
        }
      }
    });

    it("sellToPools", async function () {
      const { prices, pools, grid } = await getGridexTradeResult(false, price);
      await expect(gridexLogic.sellToPools(ethers.utils.parseUnits("1", 50), 1000, grid, grid - 20)).to.be.revertedWith("price-too-low")

      const stockToSells = [3000000, 500000000000, "18000000000000"].map(v => ethers.BigNumber.from(v))
      for (let i = 0; i < stockToSells.length; i++) {
        const stockToSell = stockToSells[i];
        const stockBalance0 = await stock.balanceOf(gridexLogic.address);
        const moneyBalance0 = await money.balanceOf(owner.address);
        const { prices, pools, grid } = await getGridexTradeResult(true, price);
        const noFeeResult = await gridexUtil.getSellToPoolsResult(prices, pools, stockToSell, await gridexUtil.getFee_m_d(gridexLogic.address, 0))
        const { totalGotMoney, totalSoldStock } = await gridexUtil.getSellToPoolsResult(prices, pools, stockToSell, await gridexUtil.getFee_m_d(gridexLogic.address, fee))
        expect(noFeeResult.totalGotMoney.mul(FeeBase * 10).mul(FeeBase * 10).div(noFeeResult.totalSoldStock).div(totalGotMoney.mul(FeeBase * 10).div(totalSoldStock))).to.be.above(FeeBase * 10 + (0.9 * fee) * 10).most(FeeBase * 10 + (1.1 * fee) * 10)
        const dealPrice = PriceBase.multipliedBy(noFeeResult.totalGotMoney.toString()).dividedBy(noFeeResult.totalSoldStock.toString()).dividedBy(params.priceMul).multipliedBy(params.priceDiv)
        expect(dealPrice.toNumber()).to.be.most(grid2price(grid + 1)).above(grid2price(grid - pools.length))

        const tx = await (gridexLogic.sellToPools(0, stockToSell, grid, grid - pools.length))
        let { events } = await tx.wait()
        events = events.splice(0, events.length - 3)
        let totalGotMoneyByEvent = ethers.BigNumber.from(0)
        let totalSoldStockByEvent = ethers.BigNumber.from(0)
        for (const { args, event } of events) {
          expect(event).to.equal("Sell")
          const { grid: eventGrid, operator, gotMoney, soldStock } = args
          expect(operator).to.equal(owner.address)
          expect(operator).to.equal(owner.address)
          expect(eventGrid).to.gte(grid - pools.length).lte(grid)
          totalGotMoneyByEvent = totalGotMoneyByEvent.add(gotMoney)
          totalSoldStockByEvent = totalSoldStockByEvent.add(soldStock)
        }
        expect(totalGotMoneyByEvent).to.equal(totalGotMoney)
        expect(totalSoldStockByEvent).to.equal(totalSoldStock)
        const stockBalance1 = await stock.balanceOf(gridexLogic.address);
        const moneyBalance1 = await money.balanceOf(owner.address);
        expect(stockBalance1.sub(stockBalance0)).to.equal(totalSoldStock)
        expect(moneyBalance1.sub(moneyBalance0)).to.equal(totalGotMoney)
        if (i != stockToSells.length - 1) {
          expect(totalSoldStock).to.above(stockToSell.mul(1e2 - 1).div(1e2)).most(stockToSell)
        }
        if (i == stockToSells.length - 1 && gridexType != 256) { // 最后一把卖光了
          const m = await money.balanceOf(gridexLogic.address)
          expect(m.toString()).to.equal("0")
        }
      }
    });

    it("final-removeAllShares", async function () {
      const address = gridexLogic.address
      const { lowGrid, highGrid } = await gridexUtil.getLowGridAndHighGrid(address);
      const ids = new Array(highGrid - lowGrid + 1).fill(0).map((_, i) => parseInt(lowGrid) + i);
      for (const amount of [0, 1, 10, 100]) {
        let amounts = await gridexLogic.balanceOfBatch(ids.map(_ => owner.address), ids)
        await gridexLogic.batchChangeShares(lowGrid, amounts.map(v => BigNumber(v.toNumber() > amount ? amount : v.toNumber()).times(BigNumber(2).pow(64)).times(-1).toFixed(0)), 0, 0)
      }
      let amounts = await gridexLogic.balanceOfBatch(ids.map(_ => owner.address), ids)
      await gridexLogic.batchChangeShares(lowGrid, amounts.map(amount => BigNumber(amount.toString()).times(Math.random()).times(BigNumber(2).pow(64)).times(-1).toFixed(0)), 0, 0)
      amounts = await gridexLogic.balanceOfBatch(ids.map(_ => owner.address), ids)
      await gridexLogic.batchChangeShares(lowGrid, amounts.map(amount => BigNumber(amount.toString()).times(BigNumber(2).pow(64)).times(-1).toFixed(0)), 0, 0)
      const stockBalance = await stock.balanceOf(address);
      const moneyBalance = await money.balanceOf(address);
      expect(stockBalance).to.equal(0)
      expect(moneyBalance).to.equal(0)
    });

    async function getPools(beginGrid, length) {
      const grids = new Array(length).fill(0).map((_, i) => i + beginGrid)
      const pools = await Promise.all(grids.map(grid => gridexLogic.pools(grid)))
      return pools
    }

    async function getPrices(grid, length) {
      const prices = await Promise.all(new Array(length).fill(0).map((_, i) => grid + i).map(grid => gridexLogic.grid2price(grid)))
      return prices
    }

    async function getCurrentGrid(v2Price) {
      const length = 101; // 最多上下找50个 debug
      const mid = Math.floor(length / 2);
      const beginGrid = price2grid(v2Price) - mid;
      let minHasStockGrid = 100000000000000;
      let maxHasMoneyGrid = 0;
      let grid = 0;
      for (let index = 0; index < (length + 1); index++) {
        let ii = 0;
        if (index == 1) {
          continue;
        }
        if (index == 0) {
          ii = mid;
        } else {
          ii = index % 2 == 0 ? mid - Math.floor(index / 2) : mid + Math.floor(index / 2);
        }
        const curGrid = beginGrid + ii;
        const pool = await gridexLogic.pools(curGrid);
        if (pool.totalShares.toString() != 0 && pool.soldRatio.toString() != RatioBase.toFixed(0) && pool.soldRatio.toString() != 0) {
          grid = curGrid;
          break;
        } else if (pool.totalShares.toString() != 0 && pool.soldRatio.toString() == 0 && curGrid < minHasStockGrid) { // 全是stock
          minHasStockGrid = curGrid;
        } else if (pool.totalShares.toString() != 0 && pool.soldRatio.toString() == RatioBase.toFixed(0) && curGrid > maxHasMoneyGrid) { // 全是money
          maxHasMoneyGrid = curGrid;
        }
      }
      if (grid == 0) {
        if (minHasStockGrid == 100000000000000 && maxHasMoneyGrid != 0) { // 都是stock
          grid = maxHasMoneyGrid;
        } else if (minHasStockGrid != 100000000000000 && maxHasMoneyGrid == 0) { // 都是money
          grid = minHasStockGrid;
        } else if (minHasStockGrid != 100000000000000 && maxHasMoneyGrid != 0) {
          grid = Math.floor((minHasStockGrid + maxHasMoneyGrid) / 2);
        }
      }
      if (grid != 0) {
        return grid;
      }
      throw new Error("grid error")
    }

    async function getGridexTradeResult(isSell, price) {
      const grid = await getCurrentGrid(price);
      const length = 20;
      const beginGrid = isSell ? (grid - length + 1) : grid;
      const pools = await getPools(beginGrid, length);
      const prices = await getPrices(
        beginGrid,
        length + 1
      );

      return { pools, prices, grid }
    }
  });
})
