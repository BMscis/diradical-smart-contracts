'reach 0.1';
'use strict';

// atomic units
const MEMBERSHIP_COST = 1000;

// custom types
const IpfsCid = Bytes(46);
const SongId = UInt;

const Song = Struct([
  ['id', SongId],
  ['creator', Address],
  ['art', IpfsCid],
  ['audio', IpfsCid],
  ['totalPlays', UInt],
  ['sessionPlays', UInt],
  ['paidPlays', UInt],
  ['percentAvailable', UInt], // i.e 12 = 12% ownership
]);

export const main = Reach.App(() => {
  setOptions({ connectors: [ETH] });
  const D = Participant('Deployer', {
    ready: Fun([], Null),
  });
  const A = API({
    buyMembership: Fun([], Null),
    addSong: Fun([IpfsCid, IpfsCid], SongId),
    incrementPlayCount: Fun([SongId], UInt),
    purchaseOwnership: Fun([SongId, UInt], Null),
    openToPublic: Fun([UInt, UInt], Null),
    getRoyalties: Fun([SongId], UInt),
    endPayPeriod: Fun([SongId], UInt),
    addWallet: Fun([Address], Null),
  });
  const V = View({
    getSong: Fun([SongId], Song),
    songRoyalties: Fun([SongId], UInt),
    userPayout: Fun([SongId, Address], UInt),
    userOwnership: Fun([SongId, Address], UInt),
    totalPlays: Fun([], UInt),
    totalBalance: Fun([], UInt),
    reserveBalance: Fun([], UInt),
  });
  const E = Events({
    songListenedTo: [SongId],
    songAdded: [SongId],
    royaltiesAccrued: [SongId, UInt],
    royaltiesPaid: [SongId, Address, UInt],
  });

  init();
  D.publish();

  const defaultSong = Song.fromObject({
    id: 0,
    creator: D,
    art: IpfsCid.pad(''),
    audio: IpfsCid.pad(''),
    sessionPlays: 0,
    totalPlays: 0,
    paidPlays: 0,
    percentAvailable: 0,
  });

  const acceptedAccounts = new Set();
  const songs = new Map(SongId, Song);
  const payouts = new Map(SongId, UInt);
  const ownership = new Map(Digest, UInt);
  const members = new Set();
  // will be used to track last listen time - prevent spam listens
  // const listens = new Map(UInt);

  commit();
  D.publish();
  D.interact.ready();

  const [totalPlays, totalMembers, trackedBal, reserveAmt] = parallelReduce([
    0, 0, 0, 0,
  ])
    .define(() => {
      const generateId = () => thisConsensusTime();
      const getSongFromId = songId =>
        Song.toObject(fromSome(songs[songId], defaultSong));
      const chkMembership = who => check(members.member(who), 'is member');
      const createOwnershipHash = (songId, user) => digest(songId, user);
      const getOwnershipPercent = (songId, user) => {
        const ownershipHash = createOwnershipHash(songId, user);
        const ownershipPercent = fromSome(ownership[ownershipHash], 0);
        return ownershipPercent;
      };
      const getSongPayout = songId => {
        const totalSongPayout = fromSome(payouts[songId], 0);
        return totalSongPayout;
      };
      const getPayoutForUser = (songId, user) => {
        const songPayoutAmt = getSongPayout(songId);
        const ownershipAmt = getOwnershipPercent(songId, user);
        const amtForUser = muldiv(songPayoutAmt, ownershipAmt, 100);
        return amtForUser;
      };
      V.songRoyalties.set(songId => fromSome(payouts[songId], 0));
      V.userPayout.set((songId, user) => getPayoutForUser(songId, user));
      V.userOwnership.set((songId, user) => getOwnershipPercent(songId, user));
      V.totalPlays.set(() => totalPlays);
      V.totalBalance.set(() => trackedBal);
      V.reserveBalance.set(() => reserveAmt);
      V.getSong.set(songId => fromSome(songs[songId], defaultSong));
    })
    .invariant(balance() === trackedBal + reserveAmt)
    .invariant(reserveAmt === payouts.sum())
    .while(true)
    .api_(A.addWallet, user => {
      check(this === D, 'is deployer');
      check(!acceptedAccounts.member(user), 'is not accepted');
      return [
        [0],
        notify => {
          acceptedAccounts.insert(user);
          notify(null);
          return [totalPlays, totalMembers, trackedBal, reserveAmt];
        },
      ];
    })
    .api_(A.buyMembership, () => {
      check(this !== D, 'not deployer');
      check(!members.member(this), 'is member');
      return [
        [MEMBERSHIP_COST],
        notify => {
          members.insert(this);
          notify(null);
          return [
            totalPlays,
            totalMembers + 1,
            trackedBal + MEMBERSHIP_COST,
            reserveAmt,
          ];
        },
      ];
    })
    .api_(A.addSong, (art, audio) => {
      check(this !== D, 'not deployer');
      chkMembership(this);
      return [
        [0],
        notify => {
          const songId = generateId();
          songs[songId] = Song.fromObject({
            id: generateId(),
            creator: this,
            art,
            audio,
            totalPlays: 0,
            sessionPlays: 0,
            paidPlays: 0,
            percentAvailable: 0,
          });
          const ownershipHash = createOwnershipHash(songId, this);
          ownership[ownershipHash] = 100;
          E.songAdded(songId);
          notify(songId);
          return [totalPlays, totalMembers, trackedBal, reserveAmt];
        },
      ];
    })
    .api_(A.incrementPlayCount, songId => {
      check(this !== D, 'not deployer');
      check(acceptedAccounts.member(this), 'is allowed');
      check(isSome(songs[songId]), 'song listed');
      const song = getSongFromId(songId);
      // const royaltyAmt = 1;
      // const lastListenTime = fromSome(listens[this], 0);
      // const reqElapsedTime = 10; // arbitrary for now
      // enforce(now - lastListenTime >= reqElapsedTime, 'can incriment play');
      // check for time from last listen is not too soon
      return [
        [0],
        notify => {
          const updatedSong = Song.fromObject({
            ...song,
            sessionPlays: song.sessionPlays + 1,
            totalPlays: song.totalPlays + 1,
          });
          songs[songId] = updatedSong;
          E.songListenedTo(songId);
          notify(song.totalPlays + 1);
          return [totalPlays + 1, totalMembers, trackedBal, reserveAmt];
        },
      ];
    })
    .api_(A.endPayPeriod, songId => {
      check(this !== D, 'not deployer');
      chkMembership(this);
      check(isSome(songs[songId]), 'song exists');
      const song = getSongFromId(songId);
      check(song.creator === this, 'is song creator');
      const unpaidPlays = song.sessionPlays - song.paidPlays;
      const royaltyAmt = muldiv(trackedBal, unpaidPlays, totalPlays);
      return [
        [0],
        notify => {
          payouts[songId] = fromSome(payouts[songId], 0) + royaltyAmt;
          E.royaltiesAccrued(songId, royaltyAmt);
          notify(royaltyAmt);
          return [
            totalPlays,
            totalMembers,
            trackedBal - royaltyAmt,
            reserveAmt + royaltyAmt,
          ];
        },
      ];
    })
    .api_(A.getRoyalties, songId => {
      check(this !== D, 'not deployer');
      chkMembership(this);
      check(isSome(songs[songId]), 'song exists');
      const ownerHash = createOwnershipHash(songId, this);
      check(isSome(ownership[ownerHash]), 'has ownership');
      const amt = getPayoutForUser(songId, this);
      check(amt > 0, 'royalties to receive');
      check(balance() >= amt, 'bal check');
      return [
        [0],
        notify => {
          transfer(amt).to(this);
          payouts[songId] = fromSome(payouts[songId], 0) - amt;
          E.royaltiesPaid(songId, this, amt);
          notify(amt);
          return [totalPlays, totalMembers, trackedBal, reserveAmt - amt];
        },
      ];
    })
    .api_(A.openToPublic, (songId, percentToOpen) => {
      check(this !== D, 'not deployer');
      chkMembership(this);
      check(isSome(songs[songId]), 'song exist');
      const currentSong = getSongFromId(songId);
      check(this === currentSong.creator, 'is creator');
      check(percentToOpen <= 100); // cannot open more than 100%
      return [
        [0],
        notify => {
          songs[songId] = Song.fromObject({
            ...currentSong,
            percentAvailable: percentToOpen,
          });
          notify(null);
          return [totalPlays, totalMembers, trackedBal, reserveAmt];
        },
      ];
    })
    .api_(A.purchaseOwnership, (songId, desiredPercent) => {
      check(this !== D, 'not deployer');

      chkMembership(this);
      check(isSome(songs[songId]), 'song exist');
      const currentSong = getSongFromId(songId);
      const creatorOwnershipAmt = getOwnershipPercent(
        songId,
        currentSong.creator
      );
      const currentOwnedPercent = getOwnershipPercent(songId, this);
      const deiredOwnershipAmt = desiredPercent + currentOwnedPercent;
      check(
        deiredOwnershipAmt <= currentSong.percentAvailable,
        'enough available'
      ); // cannot purchase more than 100%
      check(
        creatorOwnershipAmt -
          desiredPercent +
          (desiredPercent + currentOwnedPercent) ===
          100,
        'percent OK'
      );
      return [
        [0],
        notify => {
          const ownerHash = createOwnershipHash(songId, this);
          ownership[ownerHash] = creatorOwnershipAmt - desiredPercent;
          ownership[ownerHash] = desiredPercent + currentOwnedPercent;
          songs[songId] = Song.fromObject({
            ...currentSong,
            percentToOpen: currentSong.percentAvailable - deiredOwnershipAmt,
          });
          notify(null);
          return [totalPlays, totalMembers, trackedBal, reserveAmt];
        },
      ];
    });

  commit();
  exit();
});
