import { loadStdlib } from '@reach-sh/stdlib';
import * as backend from './build/index.main.mjs';

const stdlib = loadStdlib('ETH');
const gasLimit = 5000000;
const MATIC_DECIMALS = 18;
const membershipCost = stdlib.parseCurrency(1, MATIC_DECIMALS);

const fmtNum = n => stdlib.bigNumberToNumber(n);
const fmtCurrency = amt => stdlib.formatCurrency(amt, MATIC_DECIMALS);
const bal = stdlib.parseCurrency(1000000000);

const accDeployer = await stdlib.newTestAccount(bal);
const accArtist = await stdlib.newTestAccount(bal);
const accListener = await stdlib.newTestAccount(bal);

const wait = async t => {
  console.log('waiting for rent time to pass...');
  await stdlib.waitUntilSecs(stdlib.bigNumberify(t));
};

accDeployer.setGasLimit(gasLimit);
accArtist.setGasLimit(gasLimit);
accListener.setGasLimit(gasLimit);

const royaltyCtc = accDeployer.contract(backend);
const IPFS_HASH = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'; // 46 chars

// deploy royalty contract
const deployRoyaltyCtc = async () => {
  await stdlib.withDisconnect(() =>
    royaltyCtc.p.Deployer({
      membershipCost,
      ready: stdlib.disconnect,
    })
  );
  return await royaltyCtc.getInfo();
};
const royaltyCtcInfo = await deployRoyaltyCtc();
// listending to events
royaltyCtc.e.songAdded.monitor(({ when, what }) => {
  const newSongId = stdlib.bigNumberToNumber(what[0]);
  console.log('song added with id:', newSongId);
});

const logViews = async (acc, songId, votingPeriod = 1) => {
  const song = await royaltyCtc.v.getSong(songId);
  const contractBalance = await royaltyCtc.v.getContractBalance();
  const songPayout = await royaltyCtc.v.getSongPayout(songId, votingPeriod);
  const membershipExp = await royaltyCtc.v.getMembershipExp(acc);
  const views = {
    contractBalance: fmtCurrency(contractBalance[1]),
    membershipExp: membershipExp[1] ? fmtNum(membershipExp[1]) : 0,
    songPayout: songPayout[1] ? fmtCurrency(songPayout[1]) : 0,
  };
  console.log(views);
};
const buyMembership = async acc => {
  const ctc = acc.contract(backend, royaltyCtcInfo);
  const f = await ctc.a.buyMembership();
  console.log('weee', fmtNum(f))
};
const endVotingPeriod = async acc => {
  const ctc = acc.contract(backend, royaltyCtcInfo);
  await ctc.a.endVotingPeriod();
};
const addSong = async acc => {
  const ctc = acc.contract(backend, royaltyCtcInfo);
  const songId = await ctc.a.addSong(IPFS_HASH, IPFS_HASH);
  return songId;
};
const vote = async (acc, songId) => {
  const ctc = acc.contract(backend, royaltyCtcInfo);
  await ctc.a.vote(songId);
};
const receivePayout = async (acc, songId, vPeriod = 1) => {
  const ctc = acc.contract(backend, royaltyCtcInfo);
  await ctc.a.receivePayout(songId, vPeriod);
};

const t = await stdlib.getNetworkSecs();
console.log('time', fmtNum(t));

await buyMembership(accArtist);
await buyMembership(accListener);
const songId = await addSong(accArtist);
const songId2 = await addSong(accArtist);
const songId3 = await addSong(accArtist);
const songId4 = await addSong(accArtist);
await logViews(accArtist, songId);
await vote(accListener, songId);
await endVotingPeriod(accArtist);
await logViews(accArtist, songId);
await receivePayout(accArtist, songId);
await logViews(accArtist, songId);
