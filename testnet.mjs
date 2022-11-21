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
  acc.setGasLimit(gasLimit);
  return acc;
};

const viewAccount = await stdlib.createAccount();
const gasLimit = 5000000;
const IPFS_HASH = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'; // 46 chars

const accDeployer = await getAccFromSecret()

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

const viewCtc = viewAccount.contract(backend, royaltyCtcInfo);
const { e } = viewCtc;

e.songAdded.monitor(({ when, what }) => {
  const newSongId = stdlib.bigNumberToNumber(what[0]);
  console.log('song added with id:', newSongId);
});
e.songListenedTo.monitor(({ when, what }) => {
  const newSongId = stdlib.bigNumberToNumber(what[0]);
  console.log('song listened to:', newSongId);
});

const buyMembership = async acc => {
  const ctc = acc.contract(backend, royaltyCtcInfo);
  await ctc.a.buyMembership();
  console.log('Bought Membership!');
};
const addSong = async acc => {
  const ctc = acc.contract(backend, royaltyCtcInfo);
  const songId = await ctc.a.addSong(IPFS_HASH, IPFS_HASH);
  console.log('Added Song:', stdlib.bigNumberToNumber(songId));
  return songId;
};
const listen = async (acc, songId) => {
  const ctc = acc.contract(backend, royaltyCtcInfo);
  await ctc.a.incrementPlayCount(songId);
  console.log('Listened to song:', songId);
};

await buyMembership(accDeployer);
const songId = await addSong(accDeployer);

listen(accDeployer, songId);
