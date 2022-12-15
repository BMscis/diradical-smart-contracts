'reach 0.1';
'use strict';

// custom types - for clarity
const IpfsCid = Bytes(32);
const SongId = UInt;
const VotePeriod = UInt;
const Artist = Address;
const User = Address;

const Song = Struct([
  ['creator', Artist],
  ['art', IpfsCid],
  ['audio', IpfsCid],
  ['owner', User],
]);

export const main = Reach.App(() => {
  setOptions({ connectors: [ETH] });
  const D = Participant('Deployer', {
    membershipCost: UInt,
    periodLength: UInt,
    ready: Fun([], Null),
  });
  const A = API({
    buyMembership: Fun([], UInt),
    addSong: Fun([IpfsCid, IpfsCid], SongId),
    vote: Fun([Artist], Null),
    endVotingPeriod: Fun([], Null),
    receivePayout: Fun([VotePeriod], UInt),
    takeProfit: Fun([VotePeriod], UInt),
  });
  const V = View({
    getSong: Fun([SongId], Song),
    getOwnerPayout: Fun([Artist, VotePeriod], UInt),
    getMembershipExp: Fun([Address], UInt),
    getCurrentVotingPeriod: Fun([], VotePeriod),
    getMembershipCost: Fun([], UInt),
    getPeriodEndTime: Fun([], UInt),
    getPeriodPayouts: Fun([VotePeriod], UInt),
    getProfitAmt: Fun([VotePeriod], UInt),
    hasVoted: Fun([VotePeriod, Address], Bool),
  });
  const E = Events({
    songAdded: [SongId],
    membershipPurchased: [Address, UInt],
    voted: [Artist, VotePeriod],
    endedVotingPeriod: [VotePeriod],
    payoutReceived: [Artist, VotePeriod, UInt],
  });

  init();
  D.only(() => {
    const membershipCost = declassify(interact.membershipCost);
    const periodLength = declassify(interact.periodLength);
  });
  D.publish(membershipCost, periodLength);

  const defSong = {
    creator: D,
    owner: D,
    art: IpfsCid.pad(''),
    audio: IpfsCid.pad(''),
  };
  const defSongStruct = Song.fromObject(defSong);

  const getNow = () => thisConsensusSecs();

  const memberships = new Map(UInt);
  const songs = new Map(SongId, Song);
  const owners = new Set();

  const voteResults = new Map(Tuple(VotePeriod, Artist), UInt);
  const castedVotes = new Map(Tuple(VotePeriod, User), Bool); // cannot vote twice for same song in same voting period
  const totalVotesInPeriod = new Map(VotePeriod, UInt);

  const payouts = new Map(VotePeriod, UInt);
  const payoutsReceived = new Map(Tuple(VotePeriod, Artist), Bool);

  const profit = new Map(VotePeriod, UInt);
  const profitsReceived = new Map(VotePeriod, Bool);

  commit();
  D.publish();
  D.interact.ready();

  const deployTime = getNow();

  const [
    totalMembers,
    votingPeriod,
    endPeriodTime,
    votesForPeriod,
    totalVotes,
    songsAdded,
    profitAmt,
  ] = parallelReduce([0, 1, deployTime + periodLength, 0, 0, 0, 0])
    .define(() => {
      // checks
      const chkMembership = who => check(isSome(memberships[who]), 'is member');
      const enforceMembership = who => {
        const now = getNow();
        const memberishipExp = fromSome(memberships[who], 0);
        enforce(now <= memberishipExp, 'membership valid');
      };
      // helpers
      const getOwnerPayout = (artist, vPeriod) => {
        const totPayoutForPeriod = fromSome(payouts[vPeriod], 0);
        const totaltotalVotesInPeriod = fromSome(
          totalVotesInPeriod[vPeriod],
          0
        );
        return totaltotalVotesInPeriod === 0
          ? 0
          : muldiv(
              totPayoutForPeriod,
              fromSome(voteResults[[vPeriod, artist]], 0),
              totaltotalVotesInPeriod
            );
      };
      const handleVote = (artist, voter) => {
        const vote = [votingPeriod, artist];
        const currentVoteCount = fromSome(voteResults[vote], 0);
        voteResults[vote] = currentVoteCount + 1;
        castedVotes[[votingPeriod, voter]] = true;
        const currentVotesInPeriod = fromSome(
          totalVotesInPeriod[votingPeriod],
          0
        );
        totalVotesInPeriod[votingPeriod] = currentVotesInPeriod + 1;
      };
      // views
      V.getSong.set(songId => {
        check(isSome(songs[songId]), 'song exists');
        return fromSome(songs[songId], defSongStruct);
      });
      V.getPeriodPayouts.set(vPeriod => fromSome(payouts[vPeriod], 0));
      V.getProfitAmt.set(vPeriod => fromSome(profit[vPeriod], 0));
      V.getCurrentVotingPeriod.set(() => votingPeriod);
      V.getMembershipCost.set(() => membershipCost);
      V.getPeriodEndTime.set(() => endPeriodTime);
      V.getMembershipExp.set(who => {
        check(isSome(memberships[who]), 'is member');
        return fromSome(memberships[who], 0);
      });
      V.getOwnerPayout.set((artist, vPeriod) =>
        getOwnerPayout(artist, vPeriod)
      );
      V.hasVoted.set((vPeriod, who) =>
        fromSome(castedVotes[[vPeriod, who]], false)
      );
    })
    .invariant(profitAmt === profit.sum())
    .invariant(balance() === profit.sum() + payouts.sum())
    .invariant(totalVotes === voteResults.sum())
    .invariant(totalVotes === totalVotesInPeriod.sum())
    .while(true)
    .api_(A.buyMembership, () => {
      check(this !== D, 'not deployer');
      const currPayouts = fromSome(payouts[votingPeriod], 0);
      const currProfit = fromSome(profit[votingPeriod], 0);
      const amtForProfit = membershipCost / 3; // 1 third
      const amtForAtists = membershipCost - amtForProfit; // 2 thirds
      const now = getNow();
      const currMembershipExp = memberships[this];
      return [
        [membershipCost],
        notify => {
          switch (currMembershipExp) {
            case None:
              assert(true);
            case Some:
              enforce(now > currMembershipExp, 'membership expired');
          }
          const newMembExp = now + periodLength;
          memberships[this] = newMembExp;
          profit[votingPeriod] = currProfit + amtForProfit;
          payouts[votingPeriod] = currPayouts + amtForAtists;
          E.membershipPurchased(this, newMembExp);
          notify(newMembExp);
          return [
            totalMembers + 1,
            votingPeriod,
            endPeriodTime,
            votesForPeriod,
            totalVotes,
            songsAdded,
            profitAmt + amtForProfit,
          ];
        },
      ];
    })
    .api_(A.addSong, (art, audio) => {
      check(this !== D, 'not deployer');
      chkMembership(this);
      const creator = this;
      const songId = songsAdded + 1;
      check(isNone(songs[songId]), 'song id exist');
      return [
        [0],
        notify => {
          enforceMembership(creator);
          songs[songId] = Song.fromObject({
            creator: creator,
            owner: creator,
            art,
            audio,
          });
          if (!owners.member(creator)) {
            owners.insert(creator);
          }
          E.songAdded(songId);
          notify(songId);
          return [
            totalMembers,
            votingPeriod,
            endPeriodTime,
            votesForPeriod,
            totalVotes,
            songsAdded + 1,
            profitAmt,
          ];
        },
      ];
    })
    .api_(A.vote, artist => {
      const voter = this;
      check(voter !== D, 'not deployer');
      chkMembership(voter);
      check(owners.member(artist), 'is valid artist');
      check(isNone(castedVotes[[votingPeriod, voter]]), 'has voted');
      return [
        [0],
        notify => {
          enforceMembership(voter);
          handleVote(artist, voter);
          E.voted(voter, votingPeriod);
          notify(null);
          return [
            totalMembers,
            votingPeriod,
            endPeriodTime,
            votesForPeriod + 1,
            totalVotes + 1,
            songsAdded,
            profitAmt,
          ];
        },
      ];
    })
    .api_(A.endVotingPeriod, () => {
      const now = getNow();
      const hasVotendPeriodPassed = now > endPeriodTime;
      return [
        [0],
        notify => {
          enforce(hasVotendPeriodPassed, 'voting period over');
          E.endedVotingPeriod(votingPeriod);
          notify(null);
          return [
            totalMembers,
            votingPeriod + 1,
            now + periodLength,
            0,
            totalVotes,
            songsAdded,
            profitAmt,
          ];
        },
      ];
    })
    .api_(A.receivePayout, vPeriod => {
      const owner = this;
      chkMembership(owner);
      check(owners.member(owner), 'is owner');
      check(isNone(payoutsReceived[[vPeriod, owner]]), 'has received payout');
      const currPayouts = fromSome(payouts[vPeriod], 0);
      const amtForArtist = getOwnerPayout(owner, vPeriod);
      check(amtForArtist <= currPayouts, 'payouts balance check');
      check(balance() >= amtForArtist, 'enough balance');
      return [
        [0],
        notify => {
          transfer(amtForArtist).to(this);
          payoutsReceived[[vPeriod, owner]] = true;
          payouts[vPeriod] = currPayouts - amtForArtist;
          E.payoutReceived(owner, vPeriod, amtForArtist);
          notify(amtForArtist);
          return [
            totalMembers,
            votingPeriod,
            endPeriodTime,
            votesForPeriod,
            totalVotes,
            songsAdded,
            profitAmt,
          ];
        },
      ];
    })
    .api_(A.takeProfit, (vPeriod) => {
      const deployer = this;
      check(deployer === D, 'is deployer');
      check(
        isNone(profitsReceived[vPeriod]),
        'has received payout'
      );
      const profitForPeriod = fromSome(profit[vPeriod], 0);
      check(balance() >= profitForPeriod, 'enough balance');
      return [
        [0],
        notify => {
          transfer(profitForPeriod).to(deployer);
          profitsReceived[vPeriod] = true;
          profit[vPeriod] = 0;
          notify(profitForPeriod);
          return [
            totalMembers,
            votingPeriod,
            endPeriodTime,
            votesForPeriod,
            totalVotes,
            songsAdded,
            profitAmt - profitForPeriod,
          ];
        },
      ];
    });

  commit();
  exit();
});
