import { loadStdlib, ask } from '@reach-sh/stdlib';
import * as backend from './build/index.main.mjs';

const POLYGON_TESTNET = 'https://rpc.ankr.com/polygon_mumbai';
// const POLYGON_MAINNET = 'https://rpc-mainnet.matic.quiknode.pro';

const stdlib = loadStdlib({
  ETH_NODE_URI: POLYGON_TESTNET,
});

const getAccFromSecret = async (
  message = 'Please paste the secret of the deployer:'
) => {
  const secret = await ask.ask(message);
  const acc = await stdlib.newAccountFromSecret(`0x${secret}`);
  return acc;
};

const accDeployer = await getAccFromSecret();

// deploy royalty contract
const deployRoyaltyCtc = async () => {
  const royaltyCtc = accDeployer.contract(backend);
  await stdlib.withDisconnect(() =>
    royaltyCtc.p.Deployer({
      ready: stdlib.disconnect,
    })
  );
  return await royaltyCtc.getInfo();
};

const royaltyCtcInfo = await deployRoyaltyCtc();

console.log('***********************************');
console.log('contract address:', royaltyCtcInfo);
console.log('***********************************');
