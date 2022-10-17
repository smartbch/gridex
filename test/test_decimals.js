const { expect } = require("chai");
const { ethers } = require("hardhat");
const BigNumber = require('bignumber.js')
const { createERC20 } = require("./utils/util")
const { getResult } = require("./utils/price_util")

const RatioBase = BigNumber(10 ** 19)
const PriceBase = BigNumber(2 ** 68)
const FeeBase = 10000;

const gridexTypes = [16, 64, 256]// [16, 64, 256]
const decimalsArr = [[10, 10], [10, 8], [8, 10]]  // [[10, 10], [10, 8], [8, 10]]

decimalsArr.forEach((decimals) => {
  describe(`test_decimals: ${decimals}`, function () {
    let owner;
    let stock;
    let money;
    let params;
    let gridexLogic;
    let fee;
    let grid;
    let stockDecimal;
    let moneyDecimal;
    let sharesUtil;

    const gridexType = gridexTypes[0]
    const { grid2price, price2grid } = getResult(gridexType)
    before(async function () {
      [owner] = await ethers.getSigners();
      [stockDecimal, moneyDecimal] = decimals
      const MaxAmount = ethers.utils.parseUnits("1", 50)
      stock = await createERC20(ethers, "stockName", "stockSymbol", [{ address: owner.address, amount: MaxAmount }], stockDecimal);
      money = await createERC20(ethers, "moneyName", "moneySymbol", [{ address: owner.address, amount: MaxAmount }], moneyDecimal);
      const GridexLogic = await ethers.getContractFactory(`GridexLogic${gridexType}`);
      gridexLogic = await GridexLogic.deploy();
      const GridexFactory = await ethers.getContractFactory("GridexFactory");
      const gridexFactory = await GridexFactory.deploy();
      await gridexFactory.create(stock.address, money.address, gridexLogic.address)
      const gridexLogicAddress = await gridexFactory.getAddress(stock.address, money.address, gridexLogic.address)
      gridexLogic = await GridexLogic.attach(gridexLogicAddress)
      params = await gridexLogic.loadParams();
      fee = params.fee.toNumber();
      params = {
        ...params,
        priceMul: params.priceMul.toString(),
        priceDiv: params.priceDiv.toString()
      }
      stock.approve(gridexLogicAddress, MaxAmount)
      money.approve(gridexLogicAddress, MaxAmount)

      await getDeltaAmout()

      sharesUtil = await (await ethers.getContractFactory(`SharesUtil`)).deploy();
    })

    it("batchChangeShares", async function () {
      const price = BigNumber(1.01).multipliedBy(PriceBase) // 不考虑精度的price
      grid = price2grid(price)
      const amount = ethers.utils.parseUnits("1", 14)
      const amountsList = [[amount, 0], [amount, 0], [0, amount]]
      const pricesList = [
        [price.multipliedBy(0.9).toFixed(), price.toFixed(), price.multipliedBy(1.1).toFixed()],
        [price.multipliedBy(1.1).toFixed(), price.toFixed(), price.multipliedBy(1.2).toFixed()],
        [price.multipliedBy(0.8).toFixed(), price.toFixed(), price.multipliedBy(0.9).toFixed()]
      ]
      for (let i = 0; i < amountsList.length; i++) {
        const amounts = amountsList[i];
        const prices = pricesList[i];
        let { deltaMoney, minGrid, sharesDeltas } = await sharesUtil.getSharesResult(gridexLogic.address, prices, amount)
        await gridexLogic.batchChangeShares(minGrid, sharesDeltas, amounts[0], deltaMoney)
        const { stockDetal, moneyDetal } = await getDeltaAmout()
        expect(stockDetal.mul(-1)).to.equal(amounts[0])
        expect(moneyDetal.mul(-1)).to.equal(deltaMoney)
        if (amounts[1] > 0) {
          expect(moneyDetal).to.below(amounts[1].mul(1000).div(997)).most(amounts[1])
        }
      }
    });

    it("trade amount: 0", async function () {
      const amount = 0;
      {
        await gridexLogic.sellToPools(PriceBase.multipliedBy(0.9).toFixed(0), amount, grid + 20, grid - 20)
        const { stockDetal, moneyDetal } = await getDeltaAmout()
        expect(moneyDetal).to.equal(stockDetal).equal(0)
      }
      {
        await gridexLogic.buyFromPools(PriceBase.multipliedBy(1.1).toFixed(0), amount, grid - 20, grid + 20)
        const { stockDetal, moneyDetal } = await getDeltaAmout()
        expect(moneyDetal).to.equal(stockDetal).equal(0)
      }
    });

    it("trade amount: 10", async function () {
      const amount = 10;
      if (stockDecimal > moneyDecimal) {
        {
          await gridexLogic.sellToPools(0, amount, grid + 20, grid - 20)
          const { stockDetal, moneyDetal } = await getDeltaAmout()
          expect(stockDetal).to.equal(-10)
          expect(moneyDetal).to.equal(0)
        }
        {
          await gridexLogic.buyFromPools(PriceBase.multipliedBy(1.1).toFixed(0), amount, grid - 20, grid + 20)
          const { stockDetal, moneyDetal } = await getDeltaAmout()
          expect(stockDetal).to.equal(9)
          expect(moneyDetal).to.equal(0)
        }
        return
      }
      {
        await gridexLogic.sellToPools(0, amount, grid + 20, grid - 20)
        const { stockDetal, moneyDetal } = await getDeltaAmout()
        expect(stockDetal.mul(-1)).to.least(Math.floor(amount * (FeeBase - fee) / FeeBase)).most(amount)
        expect(moneyDetal.mul(10 ** stockDecimal).mul(1000).div(stockDetal.mul(-1)).div(10 ** moneyDecimal)).to.above(900).below(1100)
      }
      {
        await gridexLogic.buyFromPools(PriceBase.multipliedBy(1.1).toFixed(0), amount, grid - 20, grid + 20)
        const { stockDetal, moneyDetal } = await getDeltaAmout()
        expect(stockDetal).to.least(Math.floor(amount * (FeeBase - fee) / FeeBase)).most(amount)
        expect(moneyDetal.mul(-1).mul(10 ** stockDecimal).mul(1000).div(stockDetal).div(10 ** moneyDecimal)).to.above(900).below(1100)
      }
    });

    it("trade amount: 100", async function () {
      const amount = 100
      {
        await gridexLogic.sellToPools(0, amount, grid + 20, grid - 20)
        const { stockDetal, moneyDetal } = await getDeltaAmout()
        expect(stockDetal.mul(-1)).to.least(Math.floor(amount * (FeeBase - fee) / FeeBase)).most(amount)
        expect(moneyDetal.mul(10 ** stockDecimal).mul(1000).div(stockDetal.mul(-1)).div(10 ** moneyDecimal)).to.above(900).below(1100)
      }
      {
        await gridexLogic.buyFromPools(PriceBase.multipliedBy(1.1).toFixed(0), amount, grid - 20, grid + 20)
        const { stockDetal, moneyDetal } = await getDeltaAmout()
        expect(stockDetal).to.least(Math.floor(amount * (FeeBase - fee) / FeeBase)).most(amount)
        expect(moneyDetal.mul(-1).mul(10 ** stockDecimal).mul(1000).div(stockDetal).div(10 ** moneyDecimal)).to.above(900).below(1100)
      }
    });

    it("trade amount: 1000", async function () {
      const amount = 1000
      {
        await gridexLogic.sellToPools(0, amount, grid + 20, grid - 20)
        const { stockDetal, moneyDetal } = await getDeltaAmout()
        expect(stockDetal.mul(-1)).to.least(Math.floor(amount * (FeeBase - fee) / FeeBase) - 1).most(amount)
        expect(moneyDetal.mul(10 ** stockDecimal).mul(1000).div(stockDetal.mul(-1)).div(10 ** moneyDecimal)).to.above(900).below(1100)
      }
      {
        await gridexLogic.buyFromPools(PriceBase.multipliedBy(1.1).toFixed(0), amount, grid - 20, grid + 20)
        const { stockDetal, moneyDetal } = await getDeltaAmout()
        expect(stockDetal).to.least(Math.floor(amount * (FeeBase - fee) / FeeBase) - 1).most(amount)
        expect(moneyDetal.mul(-1).mul(10 ** stockDecimal).mul(1000).div(stockDetal).div(10 ** moneyDecimal)).to.above(900).below(1100)
      }
    });

    it("trade amount: 5*1e13", async function () {
      const amount = 5 * 1e13
      {
        await gridexLogic.sellToPools(0, amount, grid + 20, grid - 20)
        const { stockDetal, moneyDetal } = await getDeltaAmout()
        expect(stockDetal.mul(-1)).to.least(Math.floor(amount * (FeeBase - fee) / FeeBase) - 1).most(amount)
        expect(moneyDetal.mul(10 ** stockDecimal).mul(1000).div(stockDetal.mul(-1)).div(10 ** moneyDecimal)).to.above(900).below(1100)
      }
      {
        await gridexLogic.buyFromPools(PriceBase.multipliedBy(1.1).toFixed(0), amount, grid - 20, grid + 20)
        const { stockDetal, moneyDetal } = await getDeltaAmout()
        expect(stockDetal).to.least(Math.floor(amount * (FeeBase - fee) / FeeBase) - 1).most(amount)
        expect(moneyDetal.mul(-1).mul(10 ** stockDecimal).mul(1000).div(stockDetal).div(10 ** moneyDecimal)).to.above(900).below(1100)
      }
    });

    const balanceCache = []
    async function getDeltaAmout(newIndex = -1, oldIndex = -1) {
      const stockBalance = await stock.balanceOf(owner.address);
      const moneyBalance = await money.balanceOf(owner.address);
      balanceCache[balanceCache.length] = [stockBalance, moneyBalance]
      if (balanceCache.length === 1) {
        return
      }
      const newBalance = balanceCache[newIndex === -1 ? (balanceCache.length - 1) : newIndex]
      const oldBalance = balanceCache[oldIndex === -1 ? (balanceCache.length - 2) : oldIndex]
      return {
        stockDetal: newBalance[0].sub(oldBalance[0]),
        moneyDetal: newBalance[1].sub(oldBalance[1])
      }
    }
  });
})
