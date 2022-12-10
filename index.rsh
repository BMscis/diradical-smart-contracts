'reach 0.1';
'use strict';

const ONE_DAY = 1 * 24 * 60 * 60; // in seconds

// custom types - for clarity
const IpfsCid = Bytes(32);
const SongId = UInt;
const VotePeriod = UInt;

const Song = Struct([
  ['id', SongId],
  ['creator', Address],
  ['art', IpfsCid],
  ['audio', IpfsCid],
  ['votes', UInt],
]);

export const main = Reach.App(() => {
  setOptions({ connectors: [ETH] });
  const D = Participant('Deployer', {
    membershipCost: UInt,
    ready: Fun([], Null),
  });
  const A = API({
    buyMembership: Fun([], UInt),
    addSong: Fun([IpfsCid, IpfsCid], SongId),
    vote: Fun([SongId], Null),
    endVotingPeriod: Fun([], Null),
    receivePayout: Fun([SongId, VotePeriod], UInt),
  });
  const V = View({
    getSong: Fun([SongId], Song),
    getContractBalance: Fun([], UInt),
    getSongPayout: Fun([SongId, VotePeriod], UInt),
    getMembershipExp: Fun([Address], UInt),
    getCurrentVotingPeriod: Fun([], VotePeriod),
    getMembershipCost: Fun([], UInt),
    getPeriodEndTime: Fun([], UInt),
    hasVoted: Fun([SongId, Address], Bool),
  });
  const E = Events({
    songAdded: [SongId],
    membershipPurchased: [Address, UInt],
    voted: [Address, SongId, VotePeriod],
    endedVotingPeriod: [VotePeriod],
    payoutReceived: [Address, SongId, VotePeriod, UInt],
  });

  init();
  D.only(() => {
    const membershipCost = declassify(interact.membershipCost);
  });
  D.publish(membershipCost);

  const defSong = {
    id: 0,
    creator: D,
    art: IpfsCid.pad(''),
    audio: IpfsCid.pad(''),
    votes: 0,
  };
  const defSongStruct = Song.fromObject(defSong);

  const getNow = () => thisConsensusSecs();

  const memberships = new Map(UInt);
  const songs = new Map(SongId, Song);

  const votes = new Map(Tuple(VotePeriod, SongId), UInt);
  const userVotes = new Map(Tuple(VotePeriod, SongId, Address), Bool); // cannot vote twice for same song in same voting period
  const totalVotesInPeriod = new Map(VotePeriod, UInt);

  const payouts = new Map(VotePeriod, UInt);
  const payoutsReceived = new Map(Tuple(VotePeriod, SongId, Address), Bool);

  commit();
  D.publish();
  D.interact.ready();

  const deployTime = getNow();

  const [
    totalMembers,
    profitAmt,
    payoutAmt,
    votingPeriod,
    endPeriodTime,
    votesForPeriod,
    totalVotes,
  ] = parallelReduce([0, 0, 0, 1, deployTime + ONE_DAY, 0, 0])
    .define(() => {
      // checks
      const chkMembership = who => check(isSome(memberships[who]), 'is member');
      const enforceMembership = who => {
        const now = getNow();
        const memberishipExp = fromSome(memberships[who], 0);
        enforce(memberishipExp > now, 'membership valid');
      };
      // helpers
      const generateId = () => thisConsensusSecs();
      const getSongFromId = songId =>
        Song.toObject(fromSome(songs[songId], defSongStruct));
      const getSongPayout = (songId, vPeriod) => {
        check(isSome(payouts[vPeriod]), 'voting period ended');
        const totPayoutForPeriod = fromSome(payouts[vPeriod], 0);
        const totaltotalVotesInPeriod = fromSome(
          totalVotesInPeriod[vPeriod],
          0
        );
        return muldiv(
          totPayoutForPeriod,
          fromSome(votes[[vPeriod, songId]], 0),
          totaltotalVotesInPeriod
        );
      };
      const handleVote = (songId, who) => {
        const song = getSongFromId(songId);
        const voteKey = [votingPeriod, songId];
        const currentVoteCount = fromSome(votes[voteKey], 0);
        votes[voteKey] = currentVoteCount + 1;
        userVotes[[votingPeriod, songId, who]] = true;
        totalVotesInPeriod[votingPeriod] =
          fromSome(totalVotesInPeriod[votingPeriod], 0) + 1;
        songs[songId] = Song.fromObject({
          ...song,
          votes: song.votes + 1,
        });
      };
      // views
      V.getSong.set(songId => {
        check(isSome(songs[songId]), 'song exists');
        return fromSome(songs[songId], defSongStruct);
      });
      V.getContractBalance.set(() => profitAmt + payoutAmt);
      V.getCurrentVotingPeriod.set(() => votingPeriod);
      V.getMembershipCost.set(() => membershipCost);
      V.getPeriodEndTime.set(() => endPeriodTime);
      V.getMembershipExp.set(who => {
        check(isSome(memberships[who]), 'is member');
        return fromSome(memberships[who], 0);
      });
      V.getSongPayout.set((songId, vPeriod) => getSongPayout(songId, vPeriod));
      V.hasVoted.set((songId, who) =>
        fromSome(userVotes[[votingPeriod, songId, who]], false)
      );
    })
    .invariant(balance() === profitAmt + payoutAmt)
    .invariant(payoutAmt === payouts.sum())
    .invariant(totalVotes === votes.sum())
    .invariant(totalVotes === totalVotesInPeriod.sum())
    .while(true)
    .api_(A.buyMembership, () => {
      check(this !== D, 'not deployer');
      const now = getNow();
      const newMembExp = now + ONE_DAY;
      const currMembershipExp = fromSome(memberships[this], 0);
      check(currMembershipExp < now, 'membership still valid');
      return [
        [membershipCost],
        notify => {
          memberships[this] = newMembExp;
          E.membershipPurchased(this, newMembExp);
          notify(newMembExp);
          return [
            totalMembers + 1,
            profitAmt + membershipCost,
            payoutAmt,
            votingPeriod,
            endPeriodTime,
            votesForPeriod,
            totalVotes,
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
          enforceMembership(this);
          const songId = generateId();
          songs[songId] = Song.fromObject({
            ...defSong,
            id: generateId(),
            creator: this,
            art,
            audio,
          });
          E.songAdded(songId);
          notify(songId);
          return [
            totalMembers,
            profitAmt,
            payoutAmt,
            votingPeriod,
            endPeriodTime,
            votesForPeriod,
            totalVotes,
          ];
        },
      ];
    })
    .api_(A.vote, songId => {
      check(this !== D, 'not deployer');
      chkMembership(this);
      check(isSome(songs[songId]), 'song does not exist');
      check(isNone(userVotes[[votingPeriod, songId, this]]), 'has voted');
      return [
        [0],
        notify => {
          enforceMembership(this);
          handleVote(songId, this);
          E.voted(this, songId, votingPeriod);
          notify(null);
          return [
            totalMembers,
            profitAmt,
            payoutAmt,
            votingPeriod,
            endPeriodTime,
            votesForPeriod + 1,
            totalVotes + 1,
          ];
        },
      ];
    })
    .api_(A.endVotingPeriod, () => {
      check(this !== D, 'not deployer');
      chkMembership(this);
      check(getNow() > endPeriodTime, 'voting period over');
      const currPayouts = fromSome(payouts[votingPeriod], 0);
      const amtForProfit = profitAmt / 3; // 1 third
      const amtForAtists = profitAmt - amtForProfit; // 2 thirds
      return [
        [0],
        notify => {
          enforceMembership(this);
          payouts[votingPeriod] = currPayouts + amtForAtists;
          E.endedVotingPeriod(votingPeriod);
          notify(null);
          return [
            totalMembers,
            profitAmt - amtForAtists,
            payoutAmt + amtForAtists,
            votingPeriod + 1,
            endPeriodTime + ONE_DAY,
            0,
            totalVotes,
          ];
        },
      ];
    })
    .api_(A.receivePayout, (songId, vPeriod) => {
      const song = getSongFromId(songId);
      check(this === song.creator, 'not song creator');
      chkMembership(this);
      check(isSome(songs[songId]), 'song does not exist');
      check(
        isNone(payoutsReceived[[vPeriod, songId, this]]),
        'has received payout'
      );
      const currPayouts = fromSome(payouts[vPeriod], 0);
      const amtForArtist = getSongPayout(songId, vPeriod);
      check(amtForArtist <= currPayouts, 'payouts balance check');
      check(balance() >= amtForArtist, 'enough balance');
      return [
        [0],
        notify => {
          transfer(amtForArtist).to(this);
          payoutsReceived[[vPeriod, songId, this]] = true;
          payouts[vPeriod] = currPayouts - amtForArtist;
          E.payoutReceived(this, songId, vPeriod, amtForArtist);
          notify(amtForArtist);
          return [
            totalMembers,
            profitAmt,
            payoutAmt - amtForArtist,
            votingPeriod,
            endPeriodTime,
            votesForPeriod,
            totalVotes,
          ];
        },
      ];
    });

  commit();
  exit();
});
