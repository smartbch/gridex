const fs = require('fs');
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { Contract } = require("ethers");
const { validateConfig } = require("hardhat/internal/core/config/config-validation");
const BigNumber = require('bignumber.js')

const { createERC20 } = require("./utils/util")

const gridexTypes = [16, 64, 256];

describe("GridexFactory", function () {
  let owner;
  let stock;
  let money;
  let gridexLogicImpls;
  let gridexLogics = [];
  let GridexLogics;

  before(async function () {
    [owner] = await ethers.getSigners();

    stock = await createERC20(ethers, "stockName", "stockSymbol", [{ address: owner.address, amount: 100000000000000 }]);
    money = await createERC20(ethers, "moneyName", "moneySymbol", [{ address: owner.address, amount: 100000000000000 }]);

    const GridexFactory = await ethers.getContractFactory("GridexFactory");
    gridexFactory = await GridexFactory.deploy();

    GridexLogics = await Promise.all(gridexTypes.map(async gridexType => {
      const GridexLogic = await ethers.getContractFactory(`GridexLogic${gridexType}`);
      return GridexLogic
    }))

    gridexLogicImpls = await Promise.all(gridexTypes.map(async (gridexType, i) => {
      const GridexLogic = GridexLogics[i];
      const gridexLogic = await GridexLogic.deploy();
      return gridexLogic
    }))
  })

  it("test loadParams", async function () {
    const gridexLogicImpl = gridexLogicImpls[0].address;
    for (const arr of [[0, 0], [-10, 0], [10, 0]]) {
      const stockDecimals = 18 + arr[0];
      const moneyDecimals = 18 + arr[1];

      const stock = await createERC20(ethers, "1", "2", [], 18 + arr[0])
      const money = await createERC20(ethers, "1", "2", [], 18 + arr[1])
      await gridexFactory.create(stock.address, money.address, gridexLogicImpl)
      const gridexLogicAddress = await gridexFactory.getPair(stock.address, money.address, gridexLogicImpl)
      const gridexLogic = await GridexLogics[0].attach(gridexLogicAddress)
      const { priceDiv, priceMul } = await gridexLogic.loadParams()
      let priceMul_ = 1;
      let priceDiv_ = 1;
      if (moneyDecimals >= stockDecimals) {
        priceMul_ = (10 ** (moneyDecimals - stockDecimals));
      } else {
        priceDiv_ = (10 ** (stockDecimals - moneyDecimals));
      }
      expect(priceDiv).to.equal(priceDiv_);
      expect(priceMul).to.equal(priceMul_);

    }
  })


  it("test create", async function () {
    for (let index = 0; index < gridexLogicImpls.length; index++) {
      const gridexLogicImpl = gridexLogicImpls[index];
      const pairAddr = await gridexFactory.getAddress(stock.address, money.address, gridexLogicImpl.address)
      await expect(gridexFactory.create(stock.address, money.address, gridexLogicImpl.address))
        .to.emit(gridexFactory, "Created").withArgs(stock.address, money.address, gridexLogicImpl.address, pairAddr)
      expect(await gridexFactory.getPair(stock.address, money.address, gridexLogicImpl.address))
        .to.equal(pairAddr)
      expect(await gridexFactory.getPair(money.address, stock.address, gridexLogicImpl.address))
        .to.equal("0x0000000000000000000000000000000000000000")
      const gridexLogicAddress = await gridexFactory.getPair(stock.address, money.address, gridexLogicImpl.address)
      const gridexLogic = await GridexLogics[index].attach(gridexLogicAddress)
      gridexLogics.push(gridexLogic)
      await expect(gridexLogic.init("0x0000000000000000000000000000000000000000")).to.be.revertedWith("already init")
      await expect(gridexFactory.create(stock.address, money.address, gridexLogicImpl.address)).to.be.revertedWith("GridexFactory: PAIR_EXISTS")
    }
  })


  it("test getAddress", async function () {
    for (let index = 0; index < gridexLogicImpls.length; index++) {
      const gridexLogicImpl = gridexLogicImpls[index];
      const address1 = await gridexFactory.getAddress(stock.address, money.address, gridexLogicImpl.address)
      const address2 = await gridexFactory.getAddress((await createERC20(ethers, "1", "2")).address, (await createERC20(ethers, "11", "222")).address, gridexLogicImpl.address)
      expect(address1).to.equal(gridexLogics[index].address)
      expect(address2).to.not.equal(address1)
    }
  })

  it("setFee", async function () {
    for (let index = 0; index < gridexLogicImpls.length; index++) {
      const gridexLogicImpl = gridexLogicImpls[index];
      const defaultFee = {
        "16": 30, "64": 10, "256": 5
      }
      const { fee } = await gridexLogics[index].loadParams()
      expect(fee).to.equal(defaultFee[gridexTypes[index].toString()])
      await gridexFactory.setFee(stock.address, money.address, gridexLogicImpl.address, 100)
      const p = await gridexLogics[index].loadParams()
      expect(p.fee).to.equal(100)
      await expect(gridexLogics[index].setFee(100)).to.be.revertedWith("only factoryAddress")
    }
  })

  it("setURL", async function () {
    for (let index = 0; index < gridexLogicImpls.length; index++) {
      let uri = await gridexLogics[index].uri(0)
      expect(uri).to.equal("")
      const gridexLogicImpl = gridexLogicImpls[index];
      await gridexFactory.setURI(stock.address, money.address, gridexLogicImpl.address, "100")
      uri = await gridexLogics[index].uri(0)
      expect(uri).to.equal("100")
      await expect(gridexLogics[index].setURI("100")).to.be.revertedWith("only factoryAddress")
    }
  })
})