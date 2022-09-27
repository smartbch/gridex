const fs = require('fs');
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { Contract } = require("ethers");
const { validateConfig } = require("hardhat/internal/core/config/config-validation");
const { getResult } = require("./utils/price_util")
const BigNumber = require('bignumber.js')

const gridexTypes = [16, 64, 256] // [16, 64, 256]
const GridCount = 64 * 256
gridexTypes.forEach(gridexType => {
  const { price2grid, grid2price } = getResult(gridexType)
  const maxGrid = GridCount / ({ 16: 16, 64: 4, 256: 1 }[gridexType])
  const alpha = Math.pow(2, 1 / gridexType)
  describe(`gridexLogic${gridexType}`, function () {
    let gridexLogic;

    before(async function () {
      const GridexLogic = await ethers.getContractFactory(`GridexLogic${gridexType}`);
      gridexLogic = await GridexLogic.deploy();
    })

    it("test grid2price", async function () {
      await expect(gridexLogic.grid2price(maxGrid)).to.be.revertedWith("invalid-grid")

      const minAlpha = Math.floor(alpha * 1000) / 1000
      const maxAlpha = alpha * (alpha ** 0.3)
      let flag = true;
      var last = await gridexLogic.grid2price(0)
      for (var i = 1; i < maxGrid; i++) {
        var curr = await gridexLogic.grid2price(i)
        var r = curr / last
        if (r < minAlpha || r > maxAlpha) {
          flag = false;
          console.log("Error:", i, curr, curr / last)
          break;
        }
        last = curr
      }
      expect(flag).to.equal(true)
    });

    it("test grid2Price", async function () {
      let flag = true;
      for (var i = 1; i < (maxGrid - 1); i++) {
        var curr = await grid2price(i)
        const price = curr * (1 + (alpha - 1) * Math.random() * Math.random());
        var j = price2grid(price)
        const str = new BigNumber(price).toFixed(0);
        var k = await gridexLogic.price2Grid(str)
        if (i != j || i != k) {
          flag = false
          console.log("Error:", i, j, k, str)
          break;
        }
      }
      expect(flag).to.equal(true)
    });
  });
})