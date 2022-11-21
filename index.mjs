import { loadStdlib } from '@reach-sh/stdlib';
import * as backend from './build/index.main.mjs';

const stdlib = loadStdlib('ETH');
const gasLimit = 5000000;

const fmtNum = n => stdlib.bigNumberToNumber(n);
const bal = stdlib.parseCurrency(1000000000);

const accDeployer = await stdlib.newTestAccount(bal);
const accArtist = await stdlib.newTestAccount(bal);
const accListener = await stdlib.newTestAccount(bal);

accDeployer.setGasLimit(gasLimit);
accArtist.setGasLimit(gasLimit);
accListener.setGasLimit(gasLimit);

const royaltyCtc = accDeployer.contract(backend);
const IPFS_HASH = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'; // 46 chars

// deploy royalty contract
const deployRoyaltyCtc = async () => {
  await stdlib.withDisconnect(() =>
    royaltyCtc.p.Deployer({
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

const logViews = async (songId, acc) => {
  const totalPlays = await royaltyCtc.v.totalPlays();
  const totalBalance = await royaltyCtc.v.totalBalance();
  const reserveBalance = await royaltyCtc.v.reserveBalance();
  const views = {
    totalBalance: fmtNum(totalBalance[1]),
    totalPlays: fmtNum(totalPlays[1]),
    reserveBalance: fmtNum(reserveBalance[1]),
  };
  if (songId) {
    const song = await royaltyCtc.v.getSong(songId);
    const songRoyalties = await royaltyCtc.v.songRoyalties(songId);
    views.unpaidRoyalties = fmtNum(songRoyalties[1]);
  }
  if (songId && acc) {
    const payout = await royaltyCtc.v.userPayout(songId, acc.getAddress());
    const ownership = await royaltyCtc.v.userOwnership(
      songId,
      acc.getAddress()
    );
    views.payout = !payout[1] ? 0 : fmtNum(payout[1]);
    views.ownership = !ownership[1] ? 0 : fmtNum(ownership[1]);
  }
  console.log(views);
};
const addAccount = async wallet => {
  const ctc = accDeployer.contract(backend, royaltyCtcInfo);
  await ctc.a.addWallet(wallet);
};
const buyMembership = async acc => {
  const ctc = acc.contract(backend, royaltyCtcInfo);
  await ctc.a.buyMembership();
};
const addSong = async acc => {
  const ctc = acc.contract(backend, royaltyCtcInfo);
  const songId = await ctc.a.addSong(IPFS_HASH, IPFS_HASH);
  return songId;
};
const listen = async songId => {
  const ctc = accListener.contract(backend, royaltyCtcInfo);
  await ctc.a.incrementPlayCount(songId);
};
// amt in percent i.e. 10 = 10% of the song
const buyOwnership = async (acc, songId, amt = 1) => {
  const ctc = acc.contract(backend, royaltyCtcInfo);
  await ctc.a.purchaseOwnership(songId, amt);
};
const makeAvailable = async (acc, songId, amt = 10) => {
  const ctc = acc.contract(backend, royaltyCtcInfo);
  await ctc.a.openToPublic(songId, amt);
};
const receivePayout = async (acc, songId) => {
  const ctc = acc.contract(backend, royaltyCtcInfo);
  await ctc.a.getRoyalties(songId);
};
const endPayPeriod = async (acc, songId) => {
  const ctc = acc.contract(backend, royaltyCtcInfo);
  await ctc.a.endPayPeriod(songId);
};

await addAccount(accArtist);
await addAccount(accListener);
await buyMembership(accArtist);
await buyMembership(accListener);
const songId = await addSong(accArtist);
const songId2 = await addSong(accArtist);
const songId3 = await addSong(accArtist);
const songId4 = await addSong(accArtist);
await logViews(songId, accArtist);
await listen(songId);
await listen(songId2);
await makeAvailable(accArtist, songId);
await buyOwnership(accListener, songId);
await logViews(songId, accArtist);
await logViews(songId2, accArtist);
await logViews(songId, accListener);
// await receivePayout(accArtist, songId)
await logViews(songId, accArtist);
await logViews(songId, accArtist);
await endPayPeriod(accArtist, songId);
await logViews(songId, accListener);
await receivePayout(accListener, songId);
await logViews(songId, accListener);
await logViews(songId, accArtist);
