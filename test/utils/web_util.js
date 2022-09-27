// eslint-disable-next-line
const { getResult } = require("./price_util")
// eslint-disable-next-line
const BigNumber = require('bignumber.js')
// eslint-disable-next-line

const RatioBase = BigNumber(10 ** 19)
const PriceBase = BigNumber(2 ** 68)

async function getSharesDeltaAndSoldRatio(params, gridexLogic, gridexType, curGridexPrice, beginGrid, stockIns, moneyIns) {
  // console.log("stockIns moneyIns", stockIns.map(v => v.toString()), moneyIns.map(v => v.toString()))
  let pools = [];
  if (gridexLogic.isContact()) {
    pools = await gridexLogic.getPools(beginGrid, stockIns.length)
  }
  const sharesDeltas = [];
  const soldRatios = []
  const grids = new Array(stockIns.length).fill(0).map((_, i) => i + beginGrid)
  // eslint-disable-next-line
  for (const [index, grid] of Object.entries(grids)) {
    const stock = stockIns[index]
    const money = moneyIns[index]
    const [sharesDelta, soldRatio] = getshareDelta(params, grid, gridexType, pools[index], curGridexPrice, stock, money)
    // eslint-disable-next-line
    if (sharesDelta == 0 && sharesDeltas.length === 0) {
      beginGrid++;
      // eslint-disable-next-line
    } else if (sharesDelta != 0) {
      sharesDeltas.push(sharesDelta)
      soldRatios.push(soldRatio)
      // eslint-disable-next-line
    } else if (sharesDelta == 0 && sharesDeltas.length !== 0) {
      break;
    }
  }
  // console.log("sharesDeltas", sharesDeltas.map(v => v.toString()), soldRatios)
  return {
    sharesDeltaAndSoldRatios: sharesDeltas.map((sharesDelta, i) => BigNumber(sharesDelta).times(BigNumber(2).pow(64)).plus(soldRatios[i]).toFixed(0)),
    beginGrid,
    sharesDeltas,
    soldRatios
  }
}

function getshareDelta(params, grid, gridexType, pool, curGridexPrice, stockIn, moneyIn) {
  const { grid2price, price2grid } = getResult(gridexType)
  // eslint-disable-next-line
  if (!pool || pool.totalShares.toString() == "0") {
    // eslint-disable-next-line
    if (stockIn.toString() != "0" && moneyIn.toString() == "0") { // 都是stock
      return [stockIn.integerValue(BigNumber.ROUND_DOWN).toFixed(0), 0]
    }
    const priceHi = BigNumber(grid2price(grid + 1));
    const priceLo = BigNumber(grid2price(grid));
    if (stockIn.toString() !== "0" && moneyIn.toString() !== "0") {  //  处在当前价格 stockIn money都有值
      const soldRatio = (curGridexPrice.minus(priceLo).multipliedBy(RatioBase)).dividedBy(priceHi.minus(priceLo))
      // const price = (priceHi.multipliedBy(params.priceMul).multipliedBy(soldRatio).plus(priceLo.multipliedBy(params.priceMul).multipliedBy(RatioBase.minus(soldRatio)))).dividedBy(RatioBase);
      return [stockIn.dividedBy((RatioBase.minus(soldRatio).dividedBy(RatioBase))).integerValue(BigNumber.ROUND_DOWN), soldRatio.toFixed(0)]
    }
    // 只有money
    const totalStock = moneyIn.multipliedBy(getTruePrice(params, params.money, params.stock, curGridexPrice))
    return [totalStock.integerValue(BigNumber.ROUND_DOWN).toFixed(0), RatioBase.toString()];
    // eslint-disable-next-line
  } else if (stockIn.isEqualTo(0)) { // 全是钱
    // eslint-disable-next-line
    const priceHigh = BigNumber(grid2price(grid + 1)).multipliedBy(params.priceMul);
    const priceLo = BigNumber(grid2price(grid)).multipliedBy(params.priceMul);
    const totalMoney = pool.totalStock.mul(priceLo.plus(priceHigh).toFixed(0)).mul(2).div(PriceBase.dividedBy(params.priceDiv).toString())
    return [moneyIn.multipliedBy(pool.totalShares.toString()).dividedBy(totalMoney.toString()).integerValue(BigNumber.ROUND_DOWN), RatioBase.toString()]
    // eslint-disable-next-line
  } else if (moneyIn.isEqualTo(0)) { // 全是stock
    return [stockIn.multipliedBy(pool.totalShares.toString()).dividedBy(pool.totalStock.toString()).integerValue(BigNumber.ROUND_DOWN), 0]
  } else { // 处在当前价格 stockIn money都有值
    return [stockIn.multipliedBy(pool.totalShares.toString()).dividedBy(pool.totalStock.toString()).integerValue(BigNumber.ROUND_DOWN), 0]
  }
}

const WBCH = '0x3743eC0673453E5009310C727Ba4eaF7b3a1cc04' // 正式网的的
function isBch(token) {
  return token === "0x0000000000000000000000000000000000000000" || token === "0x0000000000000000000000000000000000002711"
}
function getStockAndMoney(tokenFrom, tokenTo) {
  if (isBch(tokenFrom)) {
    tokenFrom = WBCH
  }
  if (isBch(tokenTo)) {
    tokenTo = WBCH
  }

  const wbch = "0x3743eC0673453E5009310C727Ba4eaF7b3a1cc04";
  const eben = "0x77CB87b57F54667978Eb1B199b28a0db8C8E1c0B";
  const Law = "0x0b00366fBF7037E9d75E4A569ab27dAB84759302";
  const BcBCH =
    "0xBc9bD8DDe6C5a8e1CBE293356E02f5984693b195";
  const BcUSDT =
    "0xBc2F884680c95A02cea099dA2F524b366d9028Ba";
  const TanGO =
    "0x73BE9c8Edf5e951c9a0762EA2b1DE8c8F38B5e91";
  const Mist = "0x5fA664f69c2A4A3ec94FaC3cBf7049BD9CA73129";
  const ccUSDT =
    "0x383FF5f3f171cF245A33f650A7E9f0b2F7A8e4FB";
  const bbBUSD =
    "0xbb1Fcb08961d7fc7ab58dC608A0448aa30E66269";
  const bcBUSD =
    "0xbC6aEA0c2Cd7bFA073903ebdc23c8aAe79C7c826";
  const bcUSDC =
    "0xBcbd9990dcEC6a64741ea27BeC0cA8ff6B91Bc26";
  const ccUSDC =
    "0x75A695F13e59ddd19a327C8Af98D5a6E379a8105";
  const bcDAI =
    "0xBCCD70794BB199B0993E56Bfe277142246c2f43b";
  const ccDAI =
    "0x3ccb815805453D7828cc887E3cCeF17522C7bBac";
  const defaultMoneyWeights = [bbBUSD, BcUSDT, bcBUSD, bcUSDC, bcDAI, ccUSDT, ccUSDC, ccDAI, wbch, BcBCH, eben, Law, TanGO, Mist]
  let [stock, money] = [tokenFrom, tokenTo]
  const stockIndex = defaultMoneyWeights.findIndex(x => x === stock)
  const moneyIndex = defaultMoneyWeights.findIndex(x => x === money)
  stockIndex === -1 ? 1000000000000 : stockIndex
  moneyIndex === -1 ? 1000000000000 : moneyIndex

  if (stockIndex < moneyIndex) {
    [stock, money] = [tokenTo, tokenFrom]
  }
  if (stockIndex === moneyIndex) {
    [stock, money] = tokenFrom < tokenTo ? [tokenFrom, tokenTo] : [tokenTo, tokenFrom]
  }
  let isValidPair = false
  if (stock === tokenFrom || (isBch(tokenFrom) && stock === WBCH)) {
    isValidPair = true
  }
  return { stock, money, isValidPair }
}


function getPairTokenResult(params, gridexType, gridexPrice, minPriceBasePrice, maxPriceBasePrice, stockAmount, moneyAmount) {
  const { stock, money } = params;
  const { grid2price, price2grid } = getResult(gridexType);
  const curGrid = price2grid(gridexPrice.toNumber());
  let minGrid;
  let maxGrid;
  minGrid = price2grid(minPriceBasePrice.toNumber());
  maxGrid = price2grid(maxPriceBasePrice.multipliedBy(0.99999).toNumber());     // 模糊处理，不应该包含那一格
  if (minGrid > maxGrid) {
    throw new Error("minGrid > maxGrid")
  }
  const sumLeft = curGrid >= minGrid ? new Array(curGrid - minGrid + 1).fill(0).map((_, i) => BigNumber(2).pow(i)).reduce((x, y) => x.plus(y), BigNumber(0)) : 0;
  const sumRight = maxGrid >= curGrid ? new Array(maxGrid - curGrid + 1).fill(0).map((_, i) => BigNumber(2).pow(i)).reduce((x, y) => x.plus(y), BigNumber(0)) : 0;
  stockAmount = BigNumber(stockAmount || 0);
  moneyAmount = BigNumber(moneyAmount || 0);
  let amount = BigNumber(0);
  if (minGrid > curGrid) {
    stockAmount = BigNumber(tokenFromAmount);
    moneyAmount = BigNumber(0)
  } else if (maxGrid < curGrid) {
    moneyAmount = BigNumber(tokenFromAmount);
    stockAmount = BigNumber(0)
  } else if (curGrid >= minGrid && curGrid <= maxGrid) {
    // eslint-disable-next-line
    if (stockAmount.toString() !== "0") {
      const currGridStockAmount = stockAmount.multipliedBy(2 ** (maxGrid - curGrid)).dividedBy(sumRight).integerValue(BigNumber.ROUND_DOWN)
      const currGridMoneyAmount = currGridStockAmount.multipliedBy(getTruePrice(params, stock, money, gridexPrice)).integerValue(BigNumber.ROUND_DOWN)
      moneyAmount = currGridMoneyAmount.multipliedBy(sumLeft).dividedBy(BigNumber(2).pow(curGrid - minGrid))
      const priceHi = BigNumber(grid2price(curGrid + 1));
      const priceLo = BigNumber(grid2price(curGrid));
      const soldRatio = (gridexPrice.minus(priceLo).multipliedBy(RatioBase)).dividedBy(priceHi.minus(priceLo))
      const totalStock = currGridStockAmount.dividedBy((RatioBase.minus(soldRatio).dividedBy(RatioBase)))
      amount = moneyAmount.plus(totalStock.minus(currGridStockAmount).multipliedBy(getTruePrice(params, stock, money, gridexPrice)).minus(currGridMoneyAmount));   // 需要加上不够的,估算
    } else {
      const currGridMoneyAmount = moneyAmount.multipliedBy(BigNumber(2).pow(curGrid - minGrid)).dividedBy(sumLeft).integerValue(BigNumber.ROUND_DOWN)
      const currGridStockAmount = currGridMoneyAmount.multipliedBy(getTruePrice(params, money, stock, gridexPrice)).integerValue(BigNumber.ROUND_DOWN)
      stockAmount = currGridStockAmount.multipliedBy(sumRight).dividedBy(BigNumber(2).pow(maxGrid - curGrid))
      amount = stockAmount // todo
    }
  }
  const moneyIns = new Array(maxGrid - minGrid + 1).fill(0).map((_, i) => {
    const grid = minGrid + i;
    if (grid > curGrid) {
      return 0;
      // eslint-disable-next-line
    }
    return moneyAmount.multipliedBy(BigNumber(2).pow(grid - minGrid)).dividedBy(sumLeft).integerValue(BigNumber.ROUND_DOWN).toFixed(0)
  })
  const stockIns = new Array(maxGrid - minGrid + 1).fill(0).map((_, i) => {
    const grid = minGrid + i;
    if (grid < curGrid) {
      return 0;
    }
    return stockAmount.multipliedBy(BigNumber(2).pow(maxGrid - grid)).dividedBy(sumRight).integerValue(BigNumber.ROUND_DOWN).toFixed(0)
  })

  const sharesResult = {}
  // eslint-disable-next-line
  sharesResult.beginGrid = minGrid // + moneyIns.findIndex((v, i) => v != 0 || stockIns[i] != 0)
  // eslint-disable-next-line
  sharesResult.moneyIns = moneyIns // .filter((_, i) => moneyIns[i] != 0 || stockIns[i] != 0)
  // eslint-disable-next-line
  sharesResult.stockIns = stockIns // .filter((_, i) => moneyIns[i] != 0 || stockIns[i] != 0)

  return {
    sharesResult,
    amount: amount.toFixed(0)
  }
}

function getTruePrice(params, tokenFrom, tokenTo, price) {  // 带精度的价格 且没有被priceBase
  if (isBch(tokenFrom)) {
    tokenFrom = WBCH
  }
  if (params.stock === tokenFrom) {
    const truePrice = BigNumber(price)
    return truePrice.multipliedBy(params.priceMul).dividedBy(PriceBase.multipliedBy(params.priceDiv))
  } else {
    const temp = PriceBase.multipliedBy(PriceBase)
    const truePrice = price.toString() !== "0" ? temp.div(price.toString()) : BigNumber(0);
    return truePrice.multipliedBy(params.priceDiv).dividedBy(PriceBase.multipliedBy(params.priceMul))
  }
}

// export {
//   getSharesDeltaAndSoldRatio, getStockAndMoney, getPairTokenResult, getTruePrice
// }

module.exports.getSharesDeltaAndSoldRatio = getSharesDeltaAndSoldRatio
module.exports.getStockAndMoney = getStockAndMoney
module.exports.getPairTokenResult = getPairTokenResult
module.exports.getTruePrice = getTruePrice
