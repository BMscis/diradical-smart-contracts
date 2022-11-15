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
  ['payoutPreiod', UInt],
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
    endPayPeriod: Fun([SongId], Null),
    purchaseOwnership: Fun([SongId, UInt], Null),
    openToPublic: Fun([UInt, UInt], Null),
    getRoyalties: Fun([SongId], UInt),
  });
  const V = View({
    checkPayout: Fun([SongId, Address], UInt),
    checkOwnership: Fun([SongId, Address], UInt),
    totalPlays: Fun([], UInt),
    totalBal: Fun([], UInt),
  });
  const E = Events({
    songAdded: [SongId],
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
    payoutPreiod: 0,
  });

  const songs = new Map(SongId, Song);
  const payouts = new Map(Tuple(SongId, UInt), UInt);
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
      const getSongPayout = songId => {
        const song = getSongFromId(songId);
        const totalSongPayout = fromSome(
          payouts[[songId, song.payoutPreiod - 1]],
          0
        );
        return totalSongPayout;
      };
      const getPayoutForUser = (songId, user) => {
        const songPayoutAmt = getSongPayout(songId);
        const ownershipHash = digest(songId, user);
        const ownershipAmt = fromSome(ownership[ownershipHash], 0);
        const amtForUser = muldiv(songPayoutAmt, ownershipAmt, 100);
        return amtForUser;
      };
      V.checkPayout.set((songId, user) => getPayoutForUser(songId, user));
      V.checkOwnership.set((songId, user) => {
        const ownershipHash = digest(songId, user);
        return fromSome(ownership[ownershipHash], 0);
      });
      V.totalPlays.set(() => totalPlays);
      V.totalBal.set(() => trackedBal);
    })
    .invariant(balance() === trackedBal + reserveAmt)
    .while(true)
    .api_(A.buyMembership, () => {
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
            payoutPreiod: 1,
          });
          const ownershipHash = digest(songId, this);
          ownership[ownershipHash] = 100;
          E.songAdded(songId);
          notify(songId);
          return [totalPlays, totalMembers, trackedBal, reserveAmt];
        },
      ];
    })
    .api_(A.incrementPlayCount, songId => {
      chkMembership(this);
      check(isSome(songs[songId]), 'song listed');
      // const lastListenTime = fromSome(listens[this], 0);
      // const reqElapsedTime = 10; // arbitrary for now
      // enforce(now - lastListenTime >= reqElapsedTime, 'can incriment play');
      // check for time from last listen is not too soon
      const song = getSongFromId(songId);
      return [
        [0],
        notify => {
          const updatedSong = Song.fromObject({
            ...song,
            sessionPlays: song.sessionPlays + 1,
            totalPlays: song.totalPlays + 1,
          });
          songs[songId] = updatedSong;
          notify(song.totalPlays + 1);
          return [totalPlays + 1, totalMembers, trackedBal, reserveAmt];
        },
      ];
    })
    .api_(A.endPayPeriod, songId => {
      chkMembership(this);
      check(isSome(songs[songId]), 'song exists');
      const songToPayout = getSongFromId(songId);
      check(this === songToPayout.creator, 'is creator');
      const ownerHash = digest(songId, this);
      check(isSome(ownership[ownerHash]), 'has ownership');
      const amtForReserves = muldiv(
        trackedBal,
        songToPayout.sessionPlays,
        totalPlays - songToPayout.paidPlays
      );
      check(amtForReserves <= balance(), 'bal check');
      return [
        [0],
        notify => {
          payouts[[songId, songToPayout.payoutPreiod]] = amtForReserves;
          songs[songId] = Song.fromObject({
            ...songToPayout,
            paidPlays: songToPayout.paidPlays + songToPayout.sessionPlays,
            payoutPreiod: songToPayout.payoutPreiod + 1,
            sessionPlays: 0,
          });
          notify(null);
          return [
            totalPlays,
            totalMembers,
            trackedBal - amtForReserves,
            reserveAmt + amtForReserves,
          ];
        },
      ];
    })
    .api_(A.getRoyalties, songId => {
      chkMembership(this);
      check(isSome(songs[songId]), 'song exists');
      const ownerHash = digest(songId, this);
      check(isSome(ownership[ownerHash]), 'has ownership');
      const song = getSongFromId(songId);
      check(song.payoutPreiod > 1, 'pay period has occurred');
      const amt = getSongPayout(songId);
      check(amt > 0, 'royalties to receive');
      check(balance() >= amt, 'bal check');
      return [
        [0],
        notify => {
          transfer(amt).to(this);
          ownership[ownerHash] = 0;
          notify(amt);
          return [totalPlays, totalMembers, trackedBal, reserveAmt - amt];
        },
      ];
    })
    .api_(A.openToPublic, (songId, percentToOpen) => {
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
      chkMembership(this);
      check(isSome(songs[songId]), 'song exist');
      const currentSong = getSongFromId(songId);
      const creatorOwnershipDigest = digest(songId, currentSong.creator);
      const creatorOwnershipAmt = fromSome(
        ownership[creatorOwnershipDigest],
        0
      );
      const ownershipDigest = digest(songId, this);
      const currentOwnership = fromSome(ownership[ownershipDigest], 0);
      const deiredOwnershipAmt = desiredPercent + currentOwnership;
      check(
        deiredOwnershipAmt <= currentSong.percentAvailable,
        'enough available'
      ); // cannot purchase more than 100%
      check(
        creatorOwnershipAmt -
          desiredPercent +
          (desiredPercent + currentOwnership) ===
          100,
        'percent OK'
      );
      return [
        [0],
        notify => {
          ownership[creatorOwnershipDigest] =
            creatorOwnershipAmt - desiredPercent;
          ownership[ownershipDigest] = desiredPercent + currentOwnership;
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
