async function createERC20(ethers, name, symbol, acctounts = [], decimals = 18) {
  const TestERC20 = await ethers.getContractFactory("TestERC20");
  const erc20 = await TestERC20.deploy(name, symbol, decimals);
  for (let index = 0; index < acctounts.length; index++) {
    const { address, amount } = acctounts[index];
    await erc20.mint(address, amount)
  }
  return erc20
}
module.exports.createERC20 = createERC20
