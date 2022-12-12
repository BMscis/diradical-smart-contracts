import { loadStdlib, ask } from '@reach-sh/stdlib';
import * as backend from './build/index.main.mjs';

const POLYGON_TESTNET = 'https://rpc.ankr.com/polygon_mumbai';
// const POLYGON_MAINNET = 'https://rpc-mainnet.matic.quiknode.pro';

const stdlib = loadStdlib({
  ETH_NODE_URI: POLYGON_TESTNET,
});
const gasLimit = 5000000;

const MATIC_DECIMALS = 18;

const MEMBERSHIP_COST = 0.01
const membershipCost = stdlib.parseCurrency(MEMBERSHIP_COST, MATIC_DECIMALS);

const getAccFromSecret = async (
  message = 'Please paste the secret of the deployer:'
) => {
  const secret = await ask.ask(message);
  const acc = await stdlib.newAccountFromSecret(`0x${secret}`);
  return acc;
};

const accDeployer = await getAccFromSecret();
accDeployer.setGasLimit(gasLimit);

// must be in seconds
const PERIOD_LENGTH = 2 * 60; // 5 minutes

// deploy royalty contract
const deployRoyaltyCtc = async () => {
  const royaltyCtc = accDeployer.contract(backend);
  await stdlib.withDisconnect(() =>
    royaltyCtc.p.Deployer({
      periodLength: PERIOD_LENGTH,
      membershipCost,
      ready: stdlib.disconnect,
    })
  );
  return await royaltyCtc.getInfo();
};

const royaltyCtcInfo = await deployRoyaltyCtc();

console.log('***********************************');
console.log('contract address:', royaltyCtcInfo);
console.log('***********************************');

process.exit(0);
